//! Counting Bloom filter is a variant of the classical Bloom filter that supports
//! both insertions and deletions. Instead of using single bits, it uses counters
//! for each position, allowing items to be deleted without affecting other items.
//! When an item is seted, counters are incremented; when deleted, they are decremented.
//! This eliminates the false negative problem of trying to delete from a standard bloom filter.
const std = @import("std");
const hash = std.hash;
const math = std.math;

const Allocator = std.mem.Allocator;
const CountingBitArray = @import("counting_bit_array.zig").CountingBitArray;
const DefaultCountingBitArray = @import("counting_bit_array.zig").DefaultCountingBitArray;

pub const CountingBloomFilterError = error{
    CounterUnderflow,
} || @import("counting_bit_array.zig").CountingBitArrayError;

/// Hash pair for double hashing optimization
const HashPair = struct {
    hash1: u32,
    hash2: u32,
};

pub fn CountingBloomFilter(comptime CounterType: type) type {
    return struct {
        const Self = @This();

        /// number of hash functions
        k: u8,
        /// counting bit array to track occurrences
        counting_array: CountingBitArray(CounterType),

        /// Return a new Counting Bloom filter with a given number of expected entries
        /// and a desired false positive rate.
        pub fn init(allocator: Allocator, expected_entries: u64, fp_rate: f64) !Self {
            const m = calculateM(expected_entries, fp_rate);
            const k = calculateK(m, expected_entries);

            const counting_array = try CountingBitArray(CounterType).init(allocator, m);

            return Self{
                .k = @truncate(k),
                .counting_array = counting_array,
            };
        }

        pub fn deinit(self: *Self) void {
            self.counting_array.deinit();
        }

        /// Add an item to the Counting Bloom filter.
        pub fn set(self: *Self, item: []const u8) CountingBloomFilterError!void {
            const hashes = computeHashes(item);

            for (0..self.k) |i| {
                const idx = self.calculateIndex(&hashes, @truncate(i));
                try self.counting_array.increment(idx);
            }
        }

        /// Remove an item from the Counting Bloom filter.
        /// Returns true if the item was found and removed, false otherwise.
        pub fn remove(self: *Self, item: []const u8) bool {
            const hashes = computeHashes(item);

            // Check if item exists before removing
            if (!self.has(item)) {
                return false;
            }

            for (0..self.k) |i| {
                const idx = self.calculateIndex(&hashes, @truncate(i));
                self.counting_array.decrementUnchecked(idx);
            }
            return true;
        }

        /// Remove an item with automatic safety checking.
        /// Returns `CounterUnderflow` if item doesn't exist in the filter.
        pub fn removeSafe(self: *Self, item: []const u8) CountingBloomFilterError!void {
            const hashes = computeHashes(item);

            // Check if removal is safe for all positions
            for (0..self.k) |i| {
                const idx = self.calculateIndex(&hashes, @truncate(i));
                const counter = self.counting_array.get(idx) catch 0;
                if (counter == 0) {
                    return CountingBloomFilterError.CounterUnderflow;
                }
            }

            // Perform the removal
            for (0..self.k) |i| {
                const idx = self.calculateIndex(&hashes, @truncate(i));
                try self.counting_array.decrement(idx);
            }
        }

        /// Check if an item might be in the filter.
        /// May return false positives but never false negatives.
        /// Also indicates if the item can be safely removed.
        pub fn has(self: *const Self, item: []const u8) bool {
            const hashes = computeHashes(item);

            for (0..self.k) |i| {
                const idx = self.calculateIndex(&hashes, @truncate(i));
                const is_set = self.counting_array.isSet(idx) catch false;
                if (!is_set) {
                    return false;
                }
            }
            return true;
        }

        /// Estimate the number of unique elements in the filter.
        /// Runs in O(m) where m is the counter array length.
        pub fn estimatedSize(self: *const Self) u64 {
            const m = @as(f64, @floatFromInt(self.counting_array.length));
            const k = @as(f64, @floatFromInt(self.k));
            const l = @as(f64, @floatFromInt(self.counting_array.countNonZero()));

            if (l == 0) return 0;
            return @intFromFloat(-(m / k) * math.log(f64, math.e, (1.0 - l / m)));
        }

        /// Calculate array index using double hashing: h1(x) + i * h2(x) mod m.
        /// Reduces hash computations from k to 2 per operation.
        pub inline fn calculateIndex(self: *const Self, hash_pair: *const HashPair, i: u32) u64 {
            const combined = @as(u64, hash_pair.hash1) +% (@as(u64, i) *% @as(u64, hash_pair.hash2));
            return combined % self.counting_array.length;
        }
    };
}

/// Default Counting Bloom Filter with 4-bit counters.
pub const DefaultCountingBloomFilter = CountingBloomFilter(u4);

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

/// Compute hash pair for double hashing to avoid calculating k hash functions.
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

test "init default counting bloom filter" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();
}

test "init with custom counter type" {
    var cbf = try CountingBloomFilter(u8).init(testing.allocator, 100, 0.01);
    defer cbf.deinit();
}

test "set and has" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try testing.expectEqual(false, cbf.has("test"));
    try cbf.set("test");
    try testing.expect(cbf.has("test"));
}

test "set, remove and has" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.set("test");
    try testing.expect(cbf.has("test"));

    _ = cbf.remove("test");
    try testing.expectEqual(false, cbf.has("test"));
}

test "multiple sets and single remove" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.set("test");
    try cbf.set("test");
    try testing.expect(cbf.has("test"));

    _ = cbf.remove("test");
    try testing.expect(cbf.has("test"));

    _ = cbf.remove("test");
    try testing.expectEqual(false, cbf.has("test"));
}

test "removeSafe from empty filter" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try testing.expectError(CountingBloomFilterError.CounterUnderflow, cbf.removeSafe("test"));
}

test "estimated size" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.set("test1");
    try cbf.set("test2");
    try cbf.set("test3");

    const estimated = cbf.estimatedSize();
    try testing.expectEqual(3, estimated);
}

test "different items" {
    var cbf = try DefaultCountingBloomFilter.init(testing.allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.set("test1");
    try cbf.set("test2");

    try testing.expect(cbf.has("test1"));
    try testing.expect(cbf.has("test2"));
    try testing.expectEqual(false, cbf.has("test3"));

    try testing.expect(cbf.remove("test1"));
    try testing.expectEqual(false, cbf.has("test1"));
    try testing.expect(cbf.has("test2"));

    // Test removing non-existent item
    try testing.expectEqual(false, cbf.remove("nonexistent"));
}
