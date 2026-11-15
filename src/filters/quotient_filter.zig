//! Quotient filter: a compact open-addressing hash table of p-bit
//! fingerprints that supports insert, lookup, delete, merge and in-order
//! iteration. See SPEC.md §5.5.
//!
//! A fingerprint f (p = q + r bits) is split into a quotient f_q (q bits,
//! the canonical slot) and a remainder f_r (r bits, the stored value).
//! Remainders with the same quotient form a sorted *run*; runs are stored
//! in quotient order, shifted forward (with wraparound) when their
//! canonical slot is taken. Three bits per slot make this decodable
//! (paper §3):
//!
//! - is_occupied (slot i): some stored fingerprint has quotient i.
//! - is_continuation (slot i): the remainder in i belongs to the same run
//!   as the one in i − 1.
//! - is_shifted (slot i): the remainder in i is not in its canonical slot.
//!
//! Lookup follows Figure 3 of the paper: walk back to the start of the
//! cluster, then forward over runs to the run of f_q. Insert and delete
//! locate the same position and shift the following remainders right or
//! left, updating the metadata bits.
//!
//! The filter stores a *set* of fingerprints: adding an item whose
//! fingerprint is already present changes nothing. False-positive rate
//! after n inserts: 1 − (1 − 2^−p)^n ≤ n / 2^p ≤ 2^−r (paper §3).
//!
//! # References
//!
//! - Michael A. Bender, Martin Farach-Colton, Rob Johnson, Russell Kraner,
//!   Bradley C. Kuszmaul, Dzejla Medjedovic, Pablo Montes, Pradeep Shetty,
//!   Richard P. Spillane, Erez Zadok, "Don't Thrash: How to Cache Your Hash
//!   on Flash", PVLDB 5(11):1627–1637, 2012. §3 "Quotient Filter",
//!   Figure 3 (lookup). https://doi.org/10.14778/2350229.2350275
//!   (PDF: https://vldb.org/pvldb/vol5/p1627_michaelabender_vldb2012.pdf)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const BitArray = @import("bit_array.zig").BitArray;
const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

/// 8-bit remainders: false-positive rate ≤ 1/256 at full load.
pub const DefaultQuotientFilter = QuotientFilter(8);

/// `r_bits`: remainder width, 1 to 32.
pub fn QuotientFilter(comptime r_bits: u16) type {
    if (r_bits < 1 or r_bits > 32) @compileError("QuotientFilter: r_bits must be 1..32");

    return struct {
        const Self = @This();
        pub const Remainder = std.meta.Int(.unsigned, r_bits);
        const Wire = std.meta.Int(.unsigned, ((r_bits + 7) / 8) * 8);

        q: u6,
        remainders: []Remainder,
        occupied: BitArray,
        continuation: BitArray,
        shifted: BitArray,
        len: u64,

        pub const Options = struct {
            /// log2 of the slot count; q + r_bits must be ≤ 64.
            q: u6,
        };

        pub const InitError = error{InvalidParameters} || Allocator.Error;
        pub const AddError = error{Full};

        /// A stored fingerprint, as (quotient, remainder).
        pub const Entry = struct { quotient: u64, remainder: Remainder };

        pub fn init(allocator: Allocator, options: Options) InitError!Self {
            if (options.q == 0 or @as(u32, options.q) + r_bits > 64) return error.InvalidParameters;
            const size = math.cast(usize, @as(u64, 1) << options.q) orelse return error.OutOfMemory;
            const remainders = try allocator.alloc(Remainder, size);
            errdefer allocator.free(remainders);
            @memset(remainders, 0);
            var occupied = try BitArray.init(allocator, size);
            errdefer occupied.deinit(allocator);
            var continuation = try BitArray.init(allocator, size);
            errdefer continuation.deinit(allocator);
            const shifted = try BitArray.init(allocator, size);
            return .{
                .q = options.q,
                .remainders = remainders,
                .occupied = occupied,
                .continuation = continuation,
                .shifted = shifted,
                .len = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.remainders);
            self.occupied.deinit(allocator);
            self.continuation.deinit(allocator);
            self.shifted.deinit(allocator);
            self.* = undefined;
        }

        pub fn slotCount(self: Self) u64 {
            return self.remainders.len;
        }

        /// Number of distinct fingerprints stored.
        pub fn count(self: Self) u64 {
            return self.len;
        }

        pub fn loadFactor(self: Self) f64 {
            return @as(f64, @floatFromInt(self.len)) / @as(f64, @floatFromInt(self.slotCount()));
        }

        /// Upper bound on the false-positive rate at the current load: n / 2^p.
        pub fn fpRateBound(self: Self) f64 {
            return self.loadFactor() / math.pow(f64, 2.0, r_bits);
        }

        /// Split a hash: f_r = h mod 2^r, f_q = (h >> r) mod 2^q.
        pub fn entryForHash(self: Self, h: u64) Entry {
            return .{
                .quotient = (h >> r_bits) & (self.slotCount() - 1),
                .remainder = @truncate(h),
            };
        }

        /// Insert an item. Returns false if its fingerprint was already
        /// present. Fails with `error.Full` when every slot is in use.
        pub fn add(self: *Self, item: []const u8) AddError!bool {
            return self.addHash(hashing.hashBytes(item));
        }

        pub fn addHash(self: *Self, h: u64) AddError!bool {
            return self.addEntry(self.entryForHash(h));
        }

        pub fn contains(self: Self, item: []const u8) bool {
            return self.containsHash(hashing.hashBytes(item));
        }

        pub fn containsHash(self: Self, h: u64) bool {
            return self.containsEntry(self.entryForHash(h));
        }

        /// Remove an item's fingerprint. Returns false if it was absent.
        /// Removing a false positive removes another item's fingerprint.
        pub fn remove(self: *Self, item: []const u8) bool {
            return self.removeHash(hashing.hashBytes(item));
        }

        pub fn removeHash(self: *Self, h: u64) bool {
            return self.removeEntry(self.entryForHash(h));
        }

        /// Paper Figure 3.
        pub fn containsEntry(self: Self, e: Entry) bool {
            if (!self.occupied.isSet(@intCast(e.quotient))) return false;
            var s = self.runStart(e.quotient);
            while (true) {
                const rem = self.remainders[@intCast(s)];
                if (rem == e.remainder) return true;
                if (rem > e.remainder) return false; // runs are sorted
                s = self.incr(s);
                if (!self.isContinuation(s)) return false;
            }
        }

        pub fn addEntry(self: *Self, e: Entry) AddError!bool {
            const fq = e.quotient;
            if (self.isEmpty(fq)) {
                self.write(fq, e.remainder, false, false);
                self.occupied.set(@intCast(fq));
                self.len += 1;
                return true;
            }

            const run_exists = self.occupied.isSet(@intCast(fq));
            // runStart requires the occupied bit of fq to be set. If the run
            // is new, `start` is where it must begin.
            self.occupied.set(@intCast(fq));
            const start = self.runStart(fq);
            var s = start;
            if (run_exists) {
                while (true) {
                    const rem = self.remainders[@intCast(s)];
                    if (rem == e.remainder) return false; // already present
                    if (rem > e.remainder) break;
                    s = self.incr(s);
                    if (!self.isContinuation(s)) break;
                }
            }
            if (self.len == self.slotCount()) {
                if (!run_exists) self.occupied.unset(@intCast(fq));
                return error.Full;
            }

            // The new remainder starts the run if it goes first; the old head
            // (if any) then becomes a continuation.
            const is_head = s == start;
            if (is_head and run_exists) self.continuation.set(@intCast(s));
            self.shiftRightFrom(s);
            self.write(s, e.remainder, !is_head, s != fq);
            self.len += 1;
            return true;
        }

        pub fn removeEntry(self: *Self, e: Entry) bool {
            const fq = e.quotient;
            if (!self.occupied.isSet(@intCast(fq))) return false;
            const start = self.runStart(fq);
            var s = start;
            while (true) {
                const rem = self.remainders[@intCast(s)];
                if (rem == e.remainder) break;
                if (rem > e.remainder) return false;
                s = self.incr(s);
                if (!self.isContinuation(s)) return false;
            }

            const was_head = s == start;
            const run_continues = self.isContinuation(self.incr(s));
            if (was_head and !run_continues) self.occupied.unset(@intCast(fq));

            // Shift the following remainders left while they are shifted (a
            // shifted remainder can always move one slot toward its
            // canonical slot). Track quotients of moved run heads to fix
            // their is_shifted bit.
            var cursor = fq;
            var hole = s;
            var p = self.incr(s);
            var first = true;
            var steps: u64 = 0;
            while (self.shifted.isSet(@intCast(p)) and steps < self.slotCount()) : (steps += 1) {
                const rem = self.remainders[@intCast(p)];
                var cont = self.isContinuation(p);
                var quotient: u64 = undefined;
                if (first and was_head and cont) {
                    cont = false; // new head of fq's run
                    quotient = fq;
                } else if (!cont) {
                    cursor = self.nextOccupied(cursor);
                    quotient = cursor;
                }
                self.write(hole, rem, cont, cont or quotient != hole);
                hole = p;
                p = self.incr(p);
                first = false;
            }
            self.write(hole, 0, false, false);
            self.len -= 1;
            return true;
        }

        /// Insert every fingerprint of `other`. Both must have the same q.
        /// On `error.Full`, `self` contains a subset of `other`'s entries.
        pub fn merge(self: *Self, other: Self) (AddError || error{IncompatibleFilters})!void {
            if (self.q != other.q) return error.IncompatibleFilters;
            var it = other.iterator();
            while (it.next()) |e| _ = try self.addEntry(e);
        }

        pub fn clear(self: *Self) void {
            @memset(self.remainders, 0);
            self.occupied.clear();
            self.continuation.clear();
            self.shifted.clear();
            self.len = 0;
        }

        pub fn memoryBytes(self: Self) usize {
            return self.remainders.len * @sizeOf(Remainder) + 3 * self.occupied.words.len * @sizeOf(u64);
        }

        /// Iterate over stored fingerprints, in quotient order starting at
        /// the first cluster start in slot order.
        pub fn iterator(self: *const Self) Iterator {
            // Begin at a slot that holds an unshifted remainder or is empty;
            // decoding is self-contained from there.
            var begin: u64 = 0;
            while (begin < self.slotCount() and self.shifted.isSet(@intCast(begin))) begin += 1;
            return .{ .qf = self, .pos = begin, .remaining = self.slotCount(), .quotient = begin };
        }

        pub const Iterator = struct {
            qf: *const Self,
            pos: u64,
            remaining: u64,
            /// Quotient of the run being decoded.
            quotient: u64,

            pub fn next(it: *Iterator) ?Entry {
                while (it.remaining > 0) {
                    const p = it.pos;
                    it.pos = it.qf.incr(p);
                    it.remaining -= 1;
                    if (it.qf.isEmpty(p)) continue;
                    if (!it.qf.isContinuation(p)) {
                        // A run head: its quotient is the next occupied slot.
                        it.quotient = if (!it.qf.shifted.isSet(@intCast(p))) p else it.qf.nextOccupied(it.quotient);
                    }
                    return .{ .quotient = it.quotient, .remainder = it.qf.remainders[@intCast(p)] };
                }
                return null;
            }
        };

        // -- internals ---------------------------------------------------

        inline fn incr(self: Self, i: u64) u64 {
            return (i + 1) & (self.slotCount() - 1);
        }

        inline fn decr(self: Self, i: u64) u64 {
            return (i -% 1) & (self.slotCount() - 1);
        }

        inline fn isContinuation(self: Self, i: u64) bool {
            return self.continuation.isSet(@intCast(i));
        }

        inline fn isEmpty(self: Self, i: u64) bool {
            const idx: usize = @intCast(i);
            return !self.occupied.isSet(idx) and !self.continuation.isSet(idx) and !self.shifted.isSet(idx);
        }

        fn write(self: *Self, i: u64, rem: Remainder, cont: bool, shift: bool) void {
            const idx: usize = @intCast(i);
            self.remainders[idx] = rem;
            if (cont) self.continuation.set(idx) else self.continuation.unset(idx);
            if (shift) self.shifted.set(idx) else self.shifted.unset(idx);
        }

        /// Next slot after `i` (circular) whose occupied bit is set.
        fn nextOccupied(self: Self, i: u64) u64 {
            var b = self.incr(i);
            while (!self.occupied.isSet(@intCast(b))) b = self.incr(b);
            return b;
        }

        /// Slot where the run of quotient `fq` starts (Figure 3).
        /// Requires `occupied[fq]`.
        fn runStart(self: Self, fq: u64) u64 {
            std.debug.assert(self.occupied.isSet(@intCast(fq)));
            var b = fq;
            while (self.shifted.isSet(@intCast(b))) b = self.decr(b);
            var s = b;
            while (b != fq) {
                // Skip the run of bucket b...
                s = self.incr(s);
                while (self.isContinuation(s)) s = self.incr(s);
                // ...and move b to the next occupied bucket.
                b = self.nextOccupied(b);
            }
            return s;
        }

        /// Move remainders in [s, first empty slot) one slot to the right.
        /// Occupied bits belong to slots and stay put; moved remainders are
        /// always shifted. Requires at least one empty slot.
        fn shiftRightFrom(self: *Self, s: u64) void {
            var end = s;
            while (!self.isEmpty(end)) end = self.incr(end);
            while (end != s) {
                const prev = self.decr(end);
                self.write(end, self.remainders[@intCast(prev)], self.isContinuation(prev), true);
                end = prev;
            }
        }

        /// Body (tag 5): u8 q, u8 r, u64 count, 2^q remainders (each
        /// little-endian in ceil(r / 8) bytes), then the occupied,
        /// continuation and shifted bit arrays (§3.1).
        pub fn serialize(self: Self, w: *std.Io.Writer) serde.WriteError!void {
            try serde.writeHeader(w, .quotient_filter);
            try w.writeByte(self.q);
            try w.writeByte(r_bits);
            try serde.writeInt(w, u64, self.len);
            for (self.remainders) |rem| try serde.writeInt(w, Wire, rem);
            try self.occupied.serialize(w);
            try self.continuation.serialize(w);
            try self.shifted.serialize(w);
        }

        pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!Self {
            try serde.readHeader(r, .quotient_filter);
            const q = try r.takeByte();
            if (q == 0 or q > 63 or try r.takeByte() != r_bits) return error.InvalidData;
            var self = init(allocator, .{ .q = @intCast(q) }) catch |err| return switch (err) {
                error.InvalidParameters => error.InvalidData,
                error.OutOfMemory => error.OutOfMemory,
            };
            errdefer self.deinit(allocator);
            self.len = try serde.readInt(r, u64);
            for (self.remainders) |*rem| rem.* = math.cast(Remainder, try serde.readInt(r, Wire)) orelse return error.InvalidData;
            inline for (.{ &self.occupied, &self.continuation, &self.shifted }) |bits| {
                var loaded = try BitArray.deserialize(allocator, r);
                defer loaded.deinit(allocator);
                if (loaded.len != bits.len) return error.InvalidData;
                @memcpy(bits.words, loaded.words);
            }
            var n: u64 = 0;
            for (0..self.remainders.len) |i| n += @intFromBool(!self.isEmpty(i));
            if (n != self.len) return error.InvalidData;
            return self;
        }
    };
}

const testing = std.testing;

test "init validates q" {
    try testing.expectError(error.InvalidParameters, DefaultQuotientFilter.init(testing.allocator, .{ .q = 0 }));
    try testing.expectError(error.InvalidParameters, QuotientFilter(32).init(testing.allocator, .{ .q = 33 }));
}

test "add, contains, remove" {
    var qf = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 8 });
    defer qf.deinit(testing.allocator);

    try testing.expect(try qf.add("hello"));
    try testing.expect(!try qf.add("hello"));
    try testing.expect(qf.contains("hello"));
    try testing.expect(!qf.contains("world"));
    try testing.expect(qf.remove("hello"));
    try testing.expect(!qf.contains("hello"));
    try testing.expect(!qf.remove("hello"));
    try testing.expectEqual(@as(u64, 0), qf.count());
}

test "regression: remove keeps every other item" {
    // The old implementation used plain linear probing; removing an item
    // could hide items stored after it.
    var qf = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 4 });
    defer qf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..14) |i| _ = try qf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    for (0..14) |i| {
        if (i % 2 == 0) try testing.expect(qf.remove(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
    }
    for (0..14) |i| {
        if (i % 2 == 1) try testing.expect(qf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
    }
}

test "fill to capacity, then Full" {
    var qf = try QuotientFilter(16).init(testing.allocator, .{ .q = 6 });
    defer qf.deinit(testing.allocator);
    var i: u64 = 0;
    while (qf.count() < qf.slotCount()) : (i += 1) _ = try qf.addHash(hashing.hashKey(i));
    try testing.expectError(error.Full, qf.addHash(hashing.hashKey(@as(u64, 1_000_000))));
    for (0..i) |j| try testing.expect(qf.containsHash(hashing.hashKey(@as(u64, j))));
}

/// Model-based test: random adds/removes against a set of fingerprints,
/// checking membership, count and iteration after every operation.
fn checkAgainstOracle(comptime r: u16, q: u6, ops: usize, seed: u64) !void {
    const QF = QuotientFilter(r);
    var qf = try QF.init(testing.allocator, .{ .q = q });
    defer qf.deinit(testing.allocator);
    var oracle: std.AutoHashMapUnmanaged(QF.Entry, void) = .empty;
    defer oracle.deinit(testing.allocator);

    var rng = hashing.SplitMix64.init(seed);
    const universe = qf.slotCount() * 2;
    for (0..ops) |_| {
        const e = qf.entryForHash(hashing.hashKey(rng.below(universe)));
        if (rng.below(3) == 0) {
            const was = oracle.remove(e);
            try testing.expectEqual(was, qf.removeEntry(e));
        } else if (oracle.count() < qf.slotCount()) {
            const fresh = !oracle.contains(e);
            try oracle.put(testing.allocator, e, {});
            try testing.expectEqual(fresh, try qf.addEntry(e));
        }
        try testing.expectEqual(@as(u64, oracle.count()), qf.count());

        // Every oracle entry is found, and iteration yields exactly the set.
        var it = oracle.keyIterator();
        while (it.next()) |k| try testing.expect(qf.containsEntry(k.*));
        var seen: usize = 0;
        var qit = qf.iterator();
        while (qit.next()) |k| {
            try testing.expect(oracle.contains(k));
            seen += 1;
        }
        try testing.expectEqual(oracle.count(), seen);
    }
}

test "model check: small tables with heavy collisions and wraparound" {
    try checkAgainstOracle(2, 3, 2000, 1);
    try checkAgainstOracle(3, 4, 3000, 2);
    try checkAgainstOracle(4, 5, 3000, 3);
    try checkAgainstOracle(8, 6, 3000, 4);
}

test "false-positive rate is below 2^-r" {
    var qf = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 14 });
    defer qf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..12_000) |i| _ = try qf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    var fp: usize = 0;
    for (0..100_000) |i| {
        if (qf.contains(try std.fmt.bufPrint(&buf, "absent-{d}", .{i}))) fp += 1;
    }
    try testing.expect(@as(f64, @floatFromInt(fp)) / 100_000 < 1.0 / 256.0);
}

test "merge" {
    var a = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 6 });
    defer a.deinit(testing.allocator);
    var b = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 6 });
    defer b.deinit(testing.allocator);
    _ = try a.add("x");
    _ = try b.add("y");
    _ = try b.add("x");
    try a.merge(b);
    try testing.expect(a.contains("x") and a.contains("y"));
    try testing.expectEqual(@as(u64, 2), a.count());
}

test "serialize round trip" {
    var qf = try DefaultQuotientFilter.init(testing.allocator, .{ .q = 5 });
    defer qf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..20) |i| _ = try qf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));

    const bytes = try serde.toOwnedBytes(testing.allocator, qf);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try DefaultQuotientFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(qf.count(), back.count());
    for (0..20) |i| try testing.expect(back.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
}
