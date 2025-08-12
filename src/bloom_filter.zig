//! Bloom filter is a space-efficient probabilistic data structure
//! that supports membership queries. It offers a compact probabilistic
//! way to represent a set that can result in hard collisions (false positives),
//! but never false negatives.
//! The classical variant of the filter was proposed by Burton Howard Bloom in 1970.
//! The formulas for the length and false probability rate are here: https://hur.st/bloomfilter/

const std = @import("std");
const hash = std.hash;
const math = std.math;

const Allocator = std.mem.Allocator;
const BitArray = @import("bit_array.zig").BitArray;

/// Hash pair for double hashing optimization
const HashPair = struct {
    hash1: u32,
    hash2: u32,
};

pub const BloomFilter = struct {
    /// number of hash functions
    k: u8,
    /// bit array to check for membership
    bit_array: BitArray,

    /// Return a new Bloom filter with a given number of expected entries
    /// and a desired false positive rate.
    pub fn init(allocator: Allocator, expected_entries: usize, fp_rate: f64) !BloomFilter {
        const m = calculateM(expected_entries, fp_rate);
        const k = calculateK(m, expected_entries);

        const bit_array = try BitArray.init(allocator, m);

        return BloomFilter{ .k = @truncate(k), .bit_array = bit_array };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.bit_array.deinit();
    }

    /// Set an object in the Bloom filter.
    pub fn set(self: *BloomFilter, item: []const u8) !void {
        const hashes = computeHashes(item);

        for (0..self.k) |i| {
            const b = self.calculateBit(&hashes, @truncate(i));
            try self.bit_array.set(b);
        }
    }

    /// Returns a bool reflecting if a given object might be in the Bloom
    /// filter or not. There is a possibility for a false positive with the
    /// probability being under the Bloom filter's p value, but a false negative
    /// will never occur.
    pub fn has(self: *const BloomFilter, item: []const u8) bool {
        const hashes = computeHashes(item);

        for (0..self.k) |i| {
            const b = self.calculateBit(&hashes, @truncate(i));
            const is_set = self.bit_array.isSet(b) catch false;
            if (!is_set) {
                return false;
            }
        }
        return true;
    }

    /// Approximately count number of unique elements in the filter.
    /// This function runs in O(b), e.g., it runs based on the length of the bit_array.
    /// An improvement would be to keep track of all set bits and just return it
    pub fn estimatedSize(self: *const BloomFilter) u64 {
        const m = @as(f64, @floatFromInt(self.bit_array.length));
        const k = @as(f64, @floatFromInt(self.k));
        const l = @as(f64, @floatFromInt(self.bit_array.count_bits_set()));

        return @intFromFloat(-(m / k) * math.log(f64, math.e, (1.0 - l / m)));
    }

    /// Double hashing technique: h1(x) + i * h2(x) mod m
    /// This reduces hash computations from k to 2 per operation
    pub inline fn calculateBit(self: *const BloomFilter, hash_pair: *const HashPair, i: u32) u64 {
        const combined = @as(u64, hash_pair.hash1) +% (@as(u64, i) *% @as(u64, hash_pair.hash2));
        return combined % self.bit_array.length;
    }
};

/// Uses the formula: m = ceil((n * log(p)) / log(1 / pow(2, log(2))));
fn calculateM(expected_entries: u64, fp_rate: f64) u64 {
    const numerator = @as(f64, @floatFromInt(expected_entries)) * -math.log(f64, math.e, fp_rate);
    const denominator = math.pow(f64, math.log(f64, math.e, 2), 2);
    return @intFromFloat(math.ceil(numerator / denominator));
}

/// Uses the formula: k = round((m / n) * log(2));
fn calculateK(length: u64, expected_entries: u64) u64 {
    const operand = @as(f64, @floatFromInt(length)) / @as(f64, @floatFromInt(expected_entries));
    const k = operand * math.log(f64, math.e, 2);
    return @intFromFloat(math.round(k));
}

/// Compute hash pair once for reuse, it uses a double hashing approach, to avoid calculate k hash functions
inline fn computeHashes(item: []const u8) HashPair {
    const hash1 = hash.Murmur3_32.hash(item);
    const hash2 = hash.XxHash32.hash(hash1, item);
    return HashPair{ .hash1 = hash1, .hash2 = hash2 };
}

const testing = std.testing;

test "calculate optimal M num of bits" {
    try testing.expectEqual(calculateM(4000, 1.0e-7), 134191);
}

test "calculate optimal k hash functions" {
    try testing.expectEqual(23, calculateK(134191, 4000));
}

test "init" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 100, 0.01);

    defer bloom_filter.deinit();
}

test "do not contains" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 100, 0.01);
    defer bloom_filter.deinit();

    try testing.expectEqual(false, bloom_filter.has("test"));
}

test "contains" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 100, 0.01);
    defer bloom_filter.deinit();
    try bloom_filter.set("test");

    try testing.expect(bloom_filter.has("test"));
}

test "add, has" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 100, 0.01);
    defer bloom_filter.deinit();
    try bloom_filter.set("test");

    try testing.expect(bloom_filter.has("test"));
    try testing.expectEqual(false, bloom_filter.has("test_2"));
}

test "double hashing produces different results" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 1000, 0.01);
    defer bloom_filter.deinit();

    const item = "test_item";
    const hashes = computeHashes(item);

    const bit1 = bloom_filter.calculateBit(&hashes, 0);
    const bit2 = bloom_filter.calculateBit(&hashes, 1);
    const bit3 = bloom_filter.calculateBit(&hashes, 2);

    try testing.expect(bit1 != bit2 or bit2 != bit3 or bit1 != bit3);
}

test "estimated size" {
    var bloom_filter = try BloomFilter.init(testing.allocator, 100, 0.01);
    defer bloom_filter.deinit();

    try bloom_filter.set("test1");
    try bloom_filter.set("test2");
    try bloom_filter.set("test3");

    try testing.expectEqual(3, bloom_filter.estimatedSize());
}
