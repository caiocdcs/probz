//! Counting Bloom filter: a Bloom filter whose cells are small counters,
//! so items can be removed. See SPEC.md §5.2.
//!
//! Sizing and index derivation are identical to `BloomFilter` (m cells,
//! k positions via double hashing). `add` increments the k counters and
//! `remove` decrements them.
//!
//! Overflow: Fan et al. use 4-bit counters and let a counter that would
//! exceed its maximum stay at the maximum. They note that decrementing
//! such a counter later can produce false negatives. This implementation
//! saturates the same way and additionally never decrements a saturated
//! counter, so false negatives cannot occur. The cost is that saturated
//! cells stay set permanently.
//!
//! `remove` must only be called for items that were added. Removing a
//! false-positive item decrements counters that belong to other items and
//! can cause false negatives. This holds for any counting Bloom filter.
//!
//! # References
//!
//! - Li Fan, Pei Cao, Jussara Almeida, Andrei Z. Broder, "Summary Cache: A
//!   Scalable Wide-Area Web Cache Sharing Protocol", IEEE/ACM Transactions
//!   on Networking 8(3):281–293, 2000, section "Bloom Filters—the Math"
//!   (counting filters, 4-bit counters, overflow handling).
//!   https://doi.org/10.1109/90.851975
//!   (online version: https://pages.cs.wisc.edu/~cao/papers/summary-cache/node8.html)
//! - Sizing and double hashing: see `bloom_filter.zig`.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const bloom = @import("bloom_filter.zig");
const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

/// Counting Bloom filter with 4-bit counters, as recommended by Fan et al.
pub const DefaultCountingBloomFilter = CountingBloomFilter(u4);

/// `Counter` must be an unsigned integer of 2 to 32 bits.
pub fn CountingBloomFilter(comptime Counter: type) type {
    const info = @typeInfo(Counter);
    if (info != .int or info.int.signedness != .unsigned or info.int.bits < 2 or info.int.bits > 32)
        @compileError("CountingBloomFilter: Counter must be an unsigned integer of 2..32 bits");

    return struct {
        const Self = @This();
        const max = math.maxInt(Counter);
        /// Bytes per counter on the wire.
        const wire_bytes = (info.int.bits + 7) / 8;
        const Wire = std.meta.Int(.unsigned, wire_bytes * 8);

        counters: []Counter,
        /// Number of hash functions.
        k: u32,

        pub const Options = bloom.BloomFilter.Options;
        pub const InitError = bloom.BloomFilter.InitError;
        pub const MergeError = bloom.BloomFilter.MergeError;

        pub fn init(allocator: Allocator, options: Options) InitError!Self {
            const m = try bloom.optimalBits(options.expected_items, options.fp_rate);
            return initExact(allocator, m, bloom.optimalHashes(m, options.expected_items));
        }

        /// Exactly `cell_count` counters and `hash_count` hashes.
        pub fn initExact(allocator: Allocator, cell_count: u64, hash_count: u32) InitError!Self {
            if (cell_count == 0 or hash_count == 0) return error.InvalidParameters;
            const len = math.cast(usize, cell_count) orelse return error.OutOfMemory;
            const counters = try allocator.alloc(Counter, len);
            @memset(counters, 0);
            return .{ .counters = counters, .k = hash_count };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.counters);
            self.* = undefined;
        }

        pub fn add(self: *Self, item: []const u8) void {
            self.addHash(hashing.hashBytes(item));
        }

        /// Increment the k counters; counters at the maximum stay there.
        pub fn addHash(self: *Self, h: u64) void {
            const pair = hashing.HashPair.fromHash(h);
            for (0..self.k) |i| {
                const c = &self.counters[self.index(pair, i)];
                if (c.* != max) c.* += 1;
            }
        }

        pub fn contains(self: Self, item: []const u8) bool {
            return self.containsHash(hashing.hashBytes(item));
        }

        pub fn containsHash(self: Self, h: u64) bool {
            return self.countHash(h) > 0;
        }

        /// Upper bound on how many times the item was added: the minimum of
        /// its k counters (saturated counters report the maximum).
        pub fn count(self: Self, item: []const u8) Counter {
            return self.countHash(hashing.hashBytes(item));
        }

        pub fn countHash(self: Self, h: u64) Counter {
            const pair = hashing.HashPair.fromHash(h);
            var min: Counter = max;
            for (0..self.k) |i| min = @min(min, self.counters[self.index(pair, i)]);
            return min;
        }

        /// Remove one occurrence. Returns false (and changes nothing) if the
        /// item is definitely not present. Saturated counters are left
        /// unchanged.
        pub fn remove(self: *Self, item: []const u8) bool {
            return self.removeHash(hashing.hashBytes(item));
        }

        pub fn removeHash(self: *Self, h: u64) bool {
            if (!self.containsHash(h)) return false;
            const pair = hashing.HashPair.fromHash(h);
            for (0..self.k) |i| {
                const c = &self.counters[self.index(pair, i)];
                if (c.* != max) c.* -= 1;
            }
            return true;
        }

        /// Estimated number of distinct items, from the number of non-zero
        /// counters (same estimator as `BloomFilter.estimatedItems`).
        pub fn estimatedItems(self: Self) f64 {
            const m: f64 = @floatFromInt(self.counters.len);
            const k: f64 = @floatFromInt(self.k);
            const x: f64 = @floatFromInt(self.nonZeroCount());
            if (x >= m) return math.inf(f64);
            return -(m / k) * @log(1.0 - x / m);
        }

        pub fn nonZeroCount(self: Self) usize {
            var n: usize = 0;
            for (self.counters) |c| n += @intFromBool(c != 0);
            return n;
        }

        /// Multiset union: adds counters (saturating). Both filters must
        /// have the same cell count and hash count.
        pub fn merge(self: *Self, other: Self) MergeError!void {
            if (self.counters.len != other.counters.len or self.k != other.k) return error.IncompatibleFilters;
            for (self.counters, other.counters) |*a, b| a.* +|= b;
        }

        pub fn clear(self: *Self) void {
            @memset(self.counters, 0);
        }

        pub fn cellCount(self: Self) u64 {
            return self.counters.len;
        }

        pub fn memoryBytes(self: Self) usize {
            return self.counters.len * @sizeOf(Counter);
        }

        /// Body (tag 2): u8 counter bits, u32 k, u64 m, then m counters, each
        /// little-endian in ceil(bits / 8) bytes.
        pub fn serialize(self: Self, w: *std.Io.Writer) serde.WriteError!void {
            try serde.writeHeader(w, .counting_bloom_filter);
            try w.writeByte(info.int.bits);
            try serde.writeInt(w, u32, self.k);
            try serde.writeInt(w, u64, self.counters.len);
            for (self.counters) |c| try serde.writeInt(w, Wire, c);
        }

        pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!Self {
            try serde.readHeader(r, .counting_bloom_filter);
            if (try r.takeByte() != info.int.bits) return error.InvalidData;
            const k = try serde.readInt(r, u32);
            const m = math.cast(usize, try serde.readInt(r, u64)) orelse return error.InvalidData;
            if (k == 0 or m == 0) return error.InvalidData;
            const counters = try allocator.alloc(Counter, m);
            errdefer allocator.free(counters);
            for (counters) |*c| c.* = math.cast(Counter, try serde.readInt(r, Wire)) orelse return error.InvalidData;
            return .{ .counters = counters, .k = k };
        }

        inline fn index(self: Self, pair: hashing.HashPair, i: usize) usize {
            return @intCast(pair.index(@intCast(i), self.counters.len));
        }
    };
}

const testing = std.testing;

test "add, contains, remove" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer cbf.deinit(testing.allocator);

    try testing.expect(!cbf.contains("test"));
    cbf.add("test");
    try testing.expect(cbf.contains("test"));
    try testing.expect(cbf.remove("test"));
    try testing.expect(!cbf.contains("test"));
    try testing.expect(!cbf.remove("test"));
}

test "multiplicity" {
    var cbf = try CountingBloomFilter(u8).init(testing.allocator, .{ .expected_items = 100 });
    defer cbf.deinit(testing.allocator);

    cbf.add("test");
    cbf.add("test");
    try testing.expectEqual(@as(u8, 2), cbf.count("test"));
    _ = cbf.remove("test");
    try testing.expect(cbf.contains("test"));
    _ = cbf.remove("test");
    try testing.expect(!cbf.contains("test"));
}

test "remove keeps other items" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 1000 });
    defer cbf.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..1000) |i| cbf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    for (0..500) |i| try testing.expect(cbf.remove(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
    for (500..1000) |i| try testing.expect(cbf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
}

test "saturated counters never cause false negatives" {
    // 2-bit counters saturate at 3; add "a" 5 times and "b" once.
    var cbf = try CountingBloomFilter(u2).initExact(testing.allocator, 64, 3);
    defer cbf.deinit(testing.allocator);
    for (0..5) |_| cbf.add("a");
    cbf.add("b");
    try testing.expectEqual(@as(u2, 3), cbf.count("a"));
    // Removing "a" five times must never drop "b".
    for (0..5) |_| _ = cbf.remove("a");
    try testing.expect(cbf.contains("b"));
}

test "estimated items" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer cbf.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), cbf.estimatedItems());
    cbf.add("test1");
    cbf.add("test2");
    cbf.add("test3");
    try testing.expectEqual(@as(f64, 3), @round(cbf.estimatedItems()));
}

test "merge" {
    var a = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer a.deinit(testing.allocator);
    var b = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer b.deinit(testing.allocator);
    a.add("x");
    b.add("x");
    b.add("y");
    try a.merge(b);
    try testing.expectEqual(@as(u4, 2), a.count("x"));
    try testing.expect(a.contains("y"));

    var c = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 10 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatibleFilters, a.merge(c));
}

test "serialize round trip" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, .{ .expected_items = 50 });
    defer cbf.deinit(testing.allocator);
    cbf.add("x");
    cbf.add("x");

    const bytes = try serde.toOwnedBytes(testing.allocator, cbf);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try DefaultCountingBloomFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u4, cbf.counters, back.counters);

    // A filter with a different counter width must be rejected.
    r = .fixed(bytes);
    try testing.expectError(error.InvalidData, CountingBloomFilter(u8).deserialize(testing.allocator, &r));
}
