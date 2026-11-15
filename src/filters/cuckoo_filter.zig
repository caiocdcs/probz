//! Cuckoo filter: a membership filter that supports deletion, storing
//! short fingerprints in a cuckoo hash table with b slots per bucket.
//! See SPEC.md §5.4.
//!
//! Partial-key cuckoo hashing (paper §3, Eq. 1): an item lives in one of
//! two buckets, i1 = hash(x) and i2 = i1 ⊕ hash(f), where f is its
//! fingerprint. Either bucket can be computed from the other and f alone,
//! so a fingerprint can be moved without knowing the original item.
//! Insert (§3.1, Algorithm 1) relocates fingerprints for up to 500 kicks;
//! lookup (§3.2, Algorithm 2) checks both buckets; delete (§3.3) removes
//! one matching copy.
//!
//! Like the authors' reference implementation, an insert that runs out of
//! kicks parks the last displaced fingerprint in a one-entry victim cache
//! instead of dropping it. Once the victim is occupied the filter reports
//! `error.Full`, so no inserted item is ever lost (no false negatives).
//!
//! False-positive rate ≈ 2b / 2^f (paper Eq. 5), e.g. b = 4, f = 16 gives
//! about 0.012%.
//!
//! # References
//!
//! - Bin Fan, David G. Andersen, Michael Kaminsky, Michael D. Mitzenmacher,
//!   "Cuckoo Filter: Practically Better Than Bloom", CoNEXT 2014, pp. 75–88.
//!   https://doi.org/10.1145/2674005.2674994
//!   (author PDF: https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)
//! - Reference implementation (victim cache, AltIndex with the MurmurHash2
//!   constant 0x5bd1e995, 96% load sizing rule):
//!   https://github.com/efficient/cuckoofilter/blob/master/src/cuckoofilter.h

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

/// 16-bit fingerprints, 4 slots per bucket (the paper's recommended b).
pub const DefaultCuckooFilter = CuckooFilter(u16, 4);

/// `Fingerprint`: unsigned integer of 4 to 32 bits. `bucket_size`: 1 to 8.
pub fn CuckooFilter(comptime Fingerprint: type, comptime bucket_size: comptime_int) type {
    const info = @typeInfo(Fingerprint);
    if (info != .int or info.int.signedness != .unsigned or info.int.bits < 4 or info.int.bits > 32)
        @compileError("CuckooFilter: Fingerprint must be an unsigned integer of 4..32 bits");
    if (bucket_size < 1 or bucket_size > 8) @compileError("CuckooFilter: bucket_size must be 1..8");

    return struct {
        const Self = @This();
        const fp_bits = info.int.bits;
        const Wire = std.meta.Int(.unsigned, ((fp_bits + 7) / 8) * 8);
        /// Paper Algorithm 1, MaxNumKicks.
        pub const max_kicks = 500;
        const empty: Fingerprint = 0;

        /// `bucket_count * bucket_size` slots; 0 means empty.
        slots: []Fingerprint,
        bucket_count: u64,
        /// Number of stored fingerprints, including the victim.
        len: u64,
        victim: ?Entry,
        rng: hashing.SplitMix64,

        pub const Entry = struct { bucket: u64, fingerprint: Fingerprint };

        pub const Options = struct {
            /// Number of items the filter should hold (> 0).
            capacity: u64,
            /// Seed for the eviction PRNG (SPEC.md §2.3).
            seed: u64 = 0,
        };

        pub const InitError = error{InvalidParameters} || Allocator.Error;
        pub const AddError = error{Full};

        /// Buckets: next power of two ≥ max(1, capacity / b), doubled again
        /// if that would mean a load above 96% (reference implementation).
        pub fn init(allocator: Allocator, options: Options) InitError!Self {
            if (options.capacity == 0) return error.InvalidParameters;
            var buckets = math.ceilPowerOfTwo(u64, @max(1, options.capacity / bucket_size)) catch return error.InvalidParameters;
            const load = @as(f64, @floatFromInt(options.capacity)) / @as(f64, @floatFromInt(buckets * bucket_size));
            if (load > 0.96) buckets = math.mul(u64, buckets, 2) catch return error.InvalidParameters;
            return initBuckets(allocator, buckets, options.seed);
        }

        /// Exactly `bucket_count` buckets (must be a power of two).
        pub fn initBuckets(allocator: Allocator, bucket_count: u64, seed: u64) InitError!Self {
            if (bucket_count == 0 or !math.isPowerOfTwo(bucket_count)) return error.InvalidParameters;
            const n = math.mul(u64, bucket_count, bucket_size) catch return error.OutOfMemory;
            const slots = try allocator.alloc(Fingerprint, math.cast(usize, n) orelse return error.OutOfMemory);
            @memset(slots, empty);
            return .{ .slots = slots, .bucket_count = bucket_count, .len = 0, .victim = null, .rng = .init(seed) };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.slots);
            self.* = undefined;
        }

        /// Insert an item. Duplicates are stored again (up to 2b copies),
        /// so each `add` can be undone by one `remove`.
        pub fn add(self: *Self, item: []const u8) AddError!void {
            return self.addHash(hashing.hashBytes(item));
        }

        pub fn addHash(self: *Self, h: u64) AddError!void {
            if (self.victim != null) return error.Full;
            const key = self.locate(h);
            self.insertFingerprint(key.i1, key.i2, key.fp);
        }

        /// Algorithm 1. Always stores `fp`: in a bucket, or (out of kicks)
        /// by leaving the last displaced fingerprint in the victim cache.
        /// Requires the victim cache to be empty.
        fn insertFingerprint(self: *Self, b1: u64, b2: u64, fp_in: Fingerprint) void {
            std.debug.assert(self.victim == null);
            self.len += 1;
            if (self.insertIntoBucket(b1, fp_in) or self.insertIntoBucket(b2, fp_in)) return;

            var bucket = if (self.rng.below(2) == 0) b1 else b2;
            var fp = fp_in;
            for (0..max_kicks) |_| {
                const slot = &self.bucketSlots(bucket)[@intCast(self.rng.below(bucket_size))];
                std.mem.swap(Fingerprint, &fp, slot);
                bucket = self.altIndex(bucket, fp);
                if (self.insertIntoBucket(bucket, fp)) return;
            }
            self.victim = .{ .bucket = bucket, .fingerprint = fp };
        }

        pub fn contains(self: Self, item: []const u8) bool {
            return self.containsHash(hashing.hashBytes(item));
        }

        /// Algorithm 2, plus the victim cache.
        pub fn containsHash(self: Self, h: u64) bool {
            const key = self.locate(h);
            if (std.mem.indexOfScalar(Fingerprint, self.bucketSlots(key.i1), key.fp) != null) return true;
            if (std.mem.indexOfScalar(Fingerprint, self.bucketSlots(key.i2), key.fp) != null) return true;
            if (self.victim) |v| return v.fingerprint == key.fp and (v.bucket == key.i1 or v.bucket == key.i2);
            return false;
        }

        /// Remove one copy. Only remove items that were added: removing a
        /// false positive deletes another item's fingerprint.
        pub fn remove(self: *Self, item: []const u8) bool {
            return self.removeHash(hashing.hashBytes(item));
        }

        pub fn removeHash(self: *Self, h: u64) bool {
            const key = self.locate(h);
            if (self.removeFromBucket(key.i1, key.fp) or self.removeFromBucket(key.i2, key.fp)) {
                self.len -= 1;
                self.reinsertVictim();
                return true;
            }
            if (self.victim) |v| {
                if (v.fingerprint == key.fp and (v.bucket == key.i1 or v.bucket == key.i2)) {
                    self.victim = null;
                    self.len -= 1;
                    return true;
                }
            }
            return false;
        }

        /// Exact number of stored fingerprints.
        pub fn count(self: Self) u64 {
            return self.len;
        }

        /// Fraction of slots in use.
        pub fn loadFactor(self: Self) f64 {
            return @as(f64, @floatFromInt(self.len)) / @as(f64, @floatFromInt(self.slots.len));
        }

        /// Upper bound on the false-positive rate, 2b / 2^f (paper Eq. 5).
        pub fn fpRateBound() f64 {
            return 2.0 * bucket_size / math.pow(f64, 2.0, fp_bits);
        }

        pub fn clear(self: *Self) void {
            @memset(self.slots, empty);
            self.len = 0;
            self.victim = null;
        }

        pub fn memoryBytes(self: Self) usize {
            return self.slots.len * @sizeOf(Fingerprint);
        }

        const Key = struct { i1: u64, i2: u64, fp: Fingerprint };

        /// fp = (h >> 32) truncated to f bits, 0 mapped to 1;
        /// i1 = (h mod 2^32) mod buckets; i2 = altIndex(i1, fp).
        fn locate(self: Self, h: u64) Key {
            const raw: Fingerprint = @truncate(h >> 32);
            const fp = if (raw == empty) 1 else raw;
            const first = (h & 0xffff_ffff) & (self.bucket_count - 1);
            return .{ .i1 = first, .i2 = self.altIndex(first, fp), .fp = fp };
        }

        /// (i XOR (fp · 0x5bd1e995 mod 2^32)) mod buckets. An involution, so
        /// altIndex(altIndex(i, fp), fp) == i.
        fn altIndex(self: Self, i: u64, fp: Fingerprint) u64 {
            const mixed: u32 = @as(u32, fp) *% 0x5bd1e995;
            return (i ^ mixed) & (self.bucket_count - 1);
        }

        fn bucketSlots(self: Self, i: u64) []Fingerprint {
            const start: usize = @intCast(i * bucket_size);
            return self.slots[start..][0..bucket_size];
        }

        fn insertIntoBucket(self: Self, i: u64, fp: Fingerprint) bool {
            const slot = std.mem.indexOfScalar(Fingerprint, self.bucketSlots(i), empty) orelse return false;
            self.bucketSlots(i)[slot] = fp;
            return true;
        }

        fn removeFromBucket(self: Self, i: u64, fp: Fingerprint) bool {
            const slot = std.mem.indexOfScalar(Fingerprint, self.bucketSlots(i), fp) orelse return false;
            self.bucketSlots(i)[slot] = empty;
            return true;
        }

        /// After a delete frees a slot, re-run the insert for the victim
        /// (as the reference implementation does). It may end up as the
        /// victim again if the table is still too full.
        fn reinsertVictim(self: *Self) void {
            const v = self.victim orelse return;
            self.victim = null;
            self.len -= 1;
            self.insertFingerprint(v.bucket, self.altIndex(v.bucket, v.fingerprint), v.fingerprint);
        }

        /// Body (tag 4): u8 f, u8 b, u64 bucket count, u64 len, u64 PRNG
        /// state, u8 victim flag, u64 victim bucket, fingerprint victim, then
        /// bucket_count·b fingerprints; each fingerprint is little-endian in
        /// ceil(f / 8) bytes.
        pub fn serialize(self: Self, w: *std.Io.Writer) serde.WriteError!void {
            try serde.writeHeader(w, .cuckoo_filter);
            try w.writeByte(fp_bits);
            try w.writeByte(bucket_size);
            try serde.writeInt(w, u64, self.bucket_count);
            try serde.writeInt(w, u64, self.len);
            try serde.writeInt(w, u64, self.rng.state);
            const v = self.victim orelse Entry{ .bucket = 0, .fingerprint = empty };
            try w.writeByte(@intFromBool(self.victim != null));
            try serde.writeInt(w, u64, v.bucket);
            try serde.writeInt(w, Wire, v.fingerprint);
            for (self.slots) |s| try serde.writeInt(w, Wire, s);
        }

        pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!Self {
            try serde.readHeader(r, .cuckoo_filter);
            if (try r.takeByte() != fp_bits or try r.takeByte() != bucket_size) return error.InvalidData;
            const buckets = try serde.readInt(r, u64);
            var self = initBuckets(allocator, buckets, 0) catch |err| return serde.fromInitError(err);
            errdefer self.deinit(allocator);
            self.len = try serde.readInt(r, u64);
            self.rng.state = try serde.readInt(r, u64);
            const has_victim = try r.takeByte();
            const vb = try serde.readInt(r, u64);
            const vf = math.cast(Fingerprint, try serde.readInt(r, Wire)) orelse return error.InvalidData;
            if (has_victim > 1 or vb >= buckets) return error.InvalidData;
            if (has_victim == 1) {
                if (vf == empty) return error.InvalidData;
                self.victim = .{ .bucket = vb, .fingerprint = vf };
            }
            var stored: u64 = @intFromBool(self.victim != null);
            for (self.slots) |*s| {
                s.* = math.cast(Fingerprint, try serde.readInt(r, Wire)) orelse return error.InvalidData;
                stored += @intFromBool(s.* != empty);
            }
            if (stored != self.len) return error.InvalidData;
            return self;
        }
    };
}

const testing = std.testing;

test "sizing" {
    var a = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 1 });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), a.bucket_count);

    var b = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 1000 });
    defer b.deinit(testing.allocator);
    // 1000 / 4 = 250 -> 256 buckets; load 1000 / 1024 = 0.977 > 0.96, so doubled.
    try testing.expectEqual(@as(u64, 512), b.bucket_count);
    try testing.expectError(error.InvalidParameters, DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 0 }));
}

test "add, contains, remove" {
    var cf = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 100 });
    defer cf.deinit(testing.allocator);

    try testing.expect(!cf.contains("test"));
    try cf.add("test");
    try testing.expect(cf.contains("test"));
    try testing.expect(cf.remove("test"));
    try testing.expect(!cf.contains("test"));
    try testing.expect(!cf.remove("test"));
}

test "duplicates are counted" {
    var cf = try CuckooFilter(u8, 2).init(testing.allocator, .{ .capacity = 100 });
    defer cf.deinit(testing.allocator);
    try cf.add("test");
    try cf.add("test");
    try testing.expectEqual(@as(u64, 2), cf.count());
    _ = cf.remove("test");
    try testing.expect(cf.contains("test"));
    _ = cf.remove("test");
    try testing.expect(!cf.contains("test"));
}

test "alt index is an involution" {
    var cf = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 4096 });
    defer cf.deinit(testing.allocator);
    for (0..1000) |i| {
        const k = cf.locate(hashing.hashKey(@as(u64, i)));
        try testing.expectEqual(k.i1, cf.altIndex(k.i2, k.fp));
    }
}

test "regression: filling to capacity never loses an item" {
    // The old implementation dropped the last displaced fingerprint when it
    // ran out of kicks, creating false negatives.
    var cf = try CuckooFilter(u8, 4).initBuckets(testing.allocator, 64, 0);
    defer cf.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    var inserted: usize = 0;
    while (true) : (inserted += 1) {
        cf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{inserted})) catch break;
    }
    try testing.expect(cf.loadFactor() > 0.9);
    for (0..inserted) |i| try testing.expect(cf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));

    // Deleting frees space; after a few deletes the victim moves back into
    // the table and the filter accepts inserts again. Nothing is lost.
    var removed: usize = 0;
    while (cf.victim != null) : (removed += 1) {
        try testing.expect(cf.remove(try std.fmt.bufPrint(&buf, "item-{d}", .{removed})));
        try testing.expect(removed < 16);
    }
    for (removed..inserted) |i| try testing.expect(cf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
    try cf.add("new-item");
    try testing.expect(cf.contains("new-item"));
}

test "false-positive rate is near 2b/2^f" {
    var cf = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 20_000 });
    defer cf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..20_000) |i| try cf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    var fp: usize = 0;
    for (0..100_000) |i| {
        if (cf.contains(try std.fmt.bufPrint(&buf, "absent-{d}", .{i}))) fp += 1;
    }
    try testing.expect(@as(f64, @floatFromInt(fp)) / 100_000 <= DefaultCuckooFilter.fpRateBound());
}

test "serialize round trip" {
    var cf = try DefaultCuckooFilter.init(testing.allocator, .{ .capacity = 64 });
    defer cf.deinit(testing.allocator);
    try cf.add("x");
    try cf.add("y");

    const bytes = try serde.toOwnedBytes(testing.allocator, cf);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try DefaultCuckooFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, cf.slots, back.slots);
    try testing.expect(back.contains("x") and back.contains("y"));
    try testing.expectEqual(@as(u64, 2), back.count());
}
