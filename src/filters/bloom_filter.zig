//! Bloom filter: a set-membership filter with false positives but no
//! false negatives. See SPEC.md §5.1.
//!
//! Sizing for n expected items and target false-positive rate p
//! (Broder & Mitzenmacher, §2.1):
//!
//!   m = ceil(-n · ln p / (ln 2)²)        bits
//!   k = max(1, round((m / n) · ln 2))    hash functions
//!
//! The k bit positions come from double hashing over one XxHash64
//! (SPEC.md §2.2).
//!
//! # References
//!
//! - Burton H. Bloom, "Space/Time Trade-offs in Hash Coding with Allowable
//!   Errors", Communications of the ACM 13(7):422–426, 1970.
//!   https://doi.org/10.1145/362686.362692
//! - Andrei Broder, Michael Mitzenmacher, "Network Applications of Bloom
//!   Filters: A Survey", Internet Mathematics 1(4):485–509, 2004, §2.1
//!   (false-positive rate and optimal k). https://doi.org/10.1080/15427951.2004.10129096
//! - Adam Kirsch, Michael Mitzenmacher, "Less Hashing, Same Performance:
//!   Building a Better Bloom Filter", Random Structures & Algorithms
//!   33(2):187–218, 2008, Theorem 5.2 (double hashing).
//!   https://doi.org/10.1002/rsa.20208
//! - S. Joshua Swamidass, Pierre Baldi, "Mathematical Correction for
//!   Fingerprint Similarity Measures to Improve Chemical Retrieval",
//!   J. Chem. Inf. Model. 47(3):952–964, 2007 (estimate of the number of
//!   inserted items from the number of set bits).
//!   https://doi.org/10.1021/ci600526a

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const BitArray = @import("bit_array.zig").BitArray;
const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

pub const BloomFilter = struct {
    bits: BitArray,
    /// Number of hash functions.
    k: u32,

    pub const Options = struct {
        /// Number of distinct items the filter is sized for (n > 0).
        expected_items: u64,
        /// Target false-positive rate at `expected_items` (0 < p < 1).
        fp_rate: f64 = 0.01,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const MergeError = error{IncompatibleFilters};

    /// Create a filter sized for `options.expected_items` at `options.fp_rate`.
    pub fn init(allocator: Allocator, options: Options) InitError!BloomFilter {
        const m = try optimalBits(options.expected_items, options.fp_rate);
        return initExact(allocator, m, optimalHashes(m, options.expected_items));
    }

    /// Create a filter with exactly `bit_count` bits and `hash_count` hashes.
    pub fn initExact(allocator: Allocator, bit_count: u64, hash_count: u32) InitError!BloomFilter {
        if (bit_count == 0 or hash_count == 0) return error.InvalidParameters;
        const len = math.cast(usize, bit_count) orelse return error.OutOfMemory;
        return .{ .bits = try BitArray.init(allocator, len), .k = hash_count };
    }

    pub fn deinit(self: *BloomFilter, allocator: Allocator) void {
        self.bits.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: BloomFilter, allocator: Allocator) Allocator.Error!BloomFilter {
        return .{ .bits = try self.bits.clone(allocator), .k = self.k };
    }

    /// Insert an item.
    pub fn add(self: *BloomFilter, item: []const u8) void {
        self.addHash(hashing.hashBytes(item));
    }

    /// Insert a precomputed XxHash64 (see `probz.hash`).
    pub fn addHash(self: *BloomFilter, h: u64) void {
        const pair = hashing.HashPair.fromHash(h);
        for (0..self.k) |i| self.bits.set(@intCast(pair.index(@intCast(i), self.bits.len)));
    }

    /// True if the item may have been inserted; false means it definitely was not.
    pub fn contains(self: BloomFilter, item: []const u8) bool {
        return self.containsHash(hashing.hashBytes(item));
    }

    pub fn containsHash(self: BloomFilter, h: u64) bool {
        const pair = hashing.HashPair.fromHash(h);
        for (0..self.k) |i| {
            if (!self.bits.isSet(@intCast(pair.index(@intCast(i), self.bits.len)))) return false;
        }
        return true;
    }

    /// Estimated number of distinct items inserted (Swamidass & Baldi):
    /// n* = -(m / k) · ln(1 - X / m), where X is the number of set bits.
    /// Returns +inf when every bit is set. Runs in O(m / 64).
    pub fn estimatedItems(self: BloomFilter) f64 {
        const m: f64 = @floatFromInt(self.bits.len);
        const k: f64 = @floatFromInt(self.k);
        const x: f64 = @floatFromInt(self.bits.countSet());
        if (x >= m) return math.inf(f64);
        return -(m / k) * @log(1.0 - x / m);
    }

    /// Expected false-positive rate after `n` distinct inserts:
    /// (1 - e^(-k·n/m))^k.
    pub fn falsePositiveRate(self: BloomFilter, n: u64) f64 {
        const m: f64 = @floatFromInt(self.bits.len);
        const k: f64 = @floatFromInt(self.k);
        const nf: f64 = @floatFromInt(n);
        return math.pow(f64, 1.0 - @exp(-k * nf / m), k);
    }

    /// Union: afterwards `self` contains every item of either filter.
    /// Both filters must have the same bit count and hash count.
    pub fn merge(self: *BloomFilter, other: BloomFilter) MergeError!void {
        if (self.bits.len != other.bits.len or self.k != other.k) return error.IncompatibleFilters;
        self.bits.unionWith(other.bits);
    }

    pub fn clear(self: *BloomFilter) void {
        self.bits.clear();
    }

    pub fn bitCount(self: BloomFilter) u64 {
        return self.bits.len;
    }

    pub fn memoryBytes(self: BloomFilter) usize {
        return self.bits.words.len * @sizeOf(u64);
    }

    /// Wire body (after the header, tag 1): u32 k, then the bit array (§3.1).
    pub fn serialize(self: BloomFilter, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .bloom_filter);
        try serde.writeInt(w, u32, self.k);
        try self.bits.serialize(w);
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!BloomFilter {
        try serde.readHeader(r, .bloom_filter);
        const k = try serde.readInt(r, u32);
        var bits = try BitArray.deserialize(allocator, r);
        errdefer bits.deinit(allocator);
        if (k == 0 or bits.len == 0) return error.InvalidData;
        return .{ .bits = bits, .k = k };
    }
};

/// m = ceil(-n · ln p / (ln 2)²)
pub fn optimalBits(expected_items: u64, fp_rate: f64) error{InvalidParameters}!u64 {
    if (expected_items == 0 or !(fp_rate > 0.0 and fp_rate < 1.0)) return error.InvalidParameters;
    const n: f64 = @floatFromInt(expected_items);
    const m = @ceil(-n * @log(fp_rate) / (math.ln2 * math.ln2));
    if (m >= 0x1p63) return error.InvalidParameters;
    return @intFromFloat(m);
}

/// k = max(1, round((m / n) · ln 2))
pub fn optimalHashes(bit_count: u64, expected_items: u64) u32 {
    const ratio = @as(f64, @floatFromInt(bit_count)) / @as(f64, @floatFromInt(expected_items));
    const k = @round(ratio * math.ln2);
    return @intFromFloat(math.clamp(k, 1.0, 1 << 16));
}

const testing = std.testing;

test "sizing formulas" {
    try testing.expectEqual(@as(u64, 134191), try optimalBits(4000, 1.0e-7));
    try testing.expectEqual(@as(u32, 23), optimalHashes(134191, 4000));
    try testing.expectEqual(@as(u64, 9586), try optimalBits(1000, 0.01));
    try testing.expectEqual(@as(u32, 7), optimalHashes(9586, 1000));
    try testing.expectEqual(@as(u32, 1), optimalHashes(1, 1000));
}

test "invalid parameters" {
    try testing.expectError(error.InvalidParameters, BloomFilter.init(testing.allocator, .{ .expected_items = 0 }));
    try testing.expectError(error.InvalidParameters, BloomFilter.init(testing.allocator, .{ .expected_items = 10, .fp_rate = 0 }));
    try testing.expectError(error.InvalidParameters, BloomFilter.init(testing.allocator, .{ .expected_items = 10, .fp_rate = 1 }));
    try testing.expectError(error.InvalidParameters, BloomFilter.initExact(testing.allocator, 0, 3));
}

test "add and contains" {
    var bf = try BloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer bf.deinit(testing.allocator);

    try testing.expect(!bf.contains("test"));
    bf.add("test");
    try testing.expect(bf.contains("test"));
    try testing.expect(!bf.contains("test_2"));
    try testing.expect(bf.containsHash(hashing.hashBytes("test")));
}

test "estimated items" {
    var bf = try BloomFilter.init(testing.allocator, .{ .expected_items = 1000 });
    defer bf.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), bf.estimatedItems());

    var buf: [32]u8 = undefined;
    for (0..500) |i| bf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    const est = bf.estimatedItems();
    try testing.expect(est > 475 and est < 525);
}

test "regression: false-positive rate holds for large filters" {
    // 100k items at p = 1% needs ~958k bits. Before the bit-array fix every
    // index above 16384 bits aliased into the first 256 words, so the
    // observed rate was close to 100%.
    const n = 100_000;
    var bf = try BloomFilter.init(testing.allocator, .{ .expected_items = n, .fp_rate = 0.01 });
    defer bf.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 958506), bf.bitCount());

    var buf: [32]u8 = undefined;
    for (0..n) |i| bf.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    for (0..n) |i| try testing.expect(bf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));

    var fp: usize = 0;
    for (0..n) |i| {
        if (bf.contains(try std.fmt.bufPrint(&buf, "absent-{d}", .{i}))) fp += 1;
    }
    const rate = @as(f64, @floatFromInt(fp)) / n;
    try testing.expect(rate < 0.012);
}

test "merge is union and checks parameters" {
    var a = try BloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer a.deinit(testing.allocator);
    var b = try BloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer b.deinit(testing.allocator);
    a.add("a");
    b.add("b");
    try a.merge(b);
    try testing.expect(a.contains("a") and a.contains("b"));

    var c = try BloomFilter.init(testing.allocator, .{ .expected_items = 200 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatibleFilters, a.merge(c));

    a.clear();
    try testing.expect(!a.contains("a"));
}

test "serialize round trip" {
    var bf = try BloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer bf.deinit(testing.allocator);
    bf.add("x");

    const bytes = try serde.toOwnedBytes(testing.allocator, bf);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try BloomFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);

    try testing.expectEqual(bf.k, back.k);
    try testing.expectEqualSlices(u64, bf.bits.words, back.bits.words);
    try testing.expect(back.contains("x"));
}
