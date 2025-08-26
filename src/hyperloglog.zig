//! HyperLogLog is a probabilistic cardinality estimator that uses a fixed
//! amount of memory to estimate the number of distinct elements in a set.
//! It provides excellent space efficiency with configurable accuracy.
//!
//! The algorithm uses the first p bits of a hash for bucketing and counts
//! leading zeros in the remaining bits to estimate cardinality.
//!
//!# References
//!
//! - ["HyperLogLog: the analysis of a near-optimal cardinality estimation
//!   algorithm", Philippe Flajolet, Éric Fusy, Olivier Gandouet and Frédéric
//!   Meunier.](http://algo.inria.fr/flajolet/Publications/FlFuGaMe07.pdf)

const std = @import("std");
const Allocator = std.mem.Allocator;
const hash = std.hash;
const math = std.math;

pub const HyperLogLogError = error{
    IncompatiblePrecision,
    InvalidPrecision,
};

pub const HyperLogLog = struct {
    const Self = @This();

    /// Number of bits used for bucketing (4-16)
    precision: u8,
    /// Registers storing maximum leading zero counts
    buckets: []u6,
    allocator: Allocator,

    const MIN_PRECISION: u8 = 4;
    const MAX_PRECISION: u8 = 16;

    /// Return a new HyperLogLog with specified precision.
    /// Higher precision provides better accuracy but uses more memory.
    pub fn init(allocator: Allocator, precision: u8) !HyperLogLog {
        if (precision < MIN_PRECISION or precision > MAX_PRECISION) {
            return HyperLogLogError.InvalidPrecision;
        }

        const bucket_count = @as(usize, 1) << @intCast(precision);
        const buckets = try allocator.alloc(u6, bucket_count);
        @memset(buckets, 0);

        return HyperLogLog{
            .precision = precision,
            .buckets = buckets,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HyperLogLog) void {
        self.allocator.free(self.buckets);
    }

    /// Add an element to the HyperLogLog estimator.
    pub fn add(self: *HyperLogLog, item: []const u8) void {
        const hash_value = hash.XxHash32.hash(0, item);

        // Use leftmost precision bits for bucket index
        const index = hash_value >> @intCast(32 - self.precision);

        // Shift out index bits and count leading zeros in remaining bits
        const w = hash_value << @intCast(self.precision);
        const leading_zeros = @clz(w);
        const rank = @min(@as(u6, 31), @as(u6, @intCast(leading_zeros + 1)));

        self.buckets[index] = @max(self.buckets[index], rank);
    }

    /// Approximately count number of unique elements in the estimator.
    pub fn estimatedSize(self: *const HyperLogLog) f64 {
        const m = @as(f64, @floatFromInt(self.buckets.len));
        var sum: f64 = 0.0;
        var zeros: usize = 0;

        for (self.buckets) |bucket| {
            sum += 1.0 / @as(f64, @floatFromInt(@as(u64, 1) << bucket));
            if (bucket == 0) zeros += 1;
        }

        const alpha_m = getAlpha(self.buckets.len);
        const raw_estimate = alpha_m * m * m / sum;

        // Apply range corrections
        const estimate = if (raw_estimate <= 2.5 * m and zeros > 0) // Small range correction (linear counting)
            m * math.log(f64, math.e, m / @as(f64, @floatFromInt(zeros)))
        else if (raw_estimate <= (1.0 / 30.0) * math.pow(f64, 2.0, 32.0)) // Intermediate range - use raw estimate
            raw_estimate
        else // Large range correction
            -1 * math.pow(f64, 2.0, 32.0) * math.log(f64, math.e, 1.0 - raw_estimate / math.pow(f64, 2.0, 32.0));

        return @max(0.0, estimate);
    }

    /// Merge another HyperLogLog into this one.
    /// Both instances must have the same precision.
    pub fn merge(self: *HyperLogLog, other: *const HyperLogLog) !void {
        if (self.precision != other.precision) {
            return HyperLogLogError.IncompatiblePrecision;
        }

        for (self.buckets, other.buckets) |*bucket, other_bucket| {
            bucket.* = @max(bucket.*, other_bucket);
        }
    }
};

/// Get the alpha constant for bias correction based on bucket count
inline fn getAlpha(m: usize) f64 {
    return switch (m) {
        16 => 0.673,
        32 => 0.697,
        64 => 0.709,
        else => 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(m))),
    };
}

const testing = std.testing;

test "init" {
    var hll = try HyperLogLog.init(testing.allocator, 8);
    defer hll.deinit();
}

test "invalid precision" {
    try testing.expectError(HyperLogLogError.InvalidPrecision, HyperLogLog.init(testing.allocator, 3));
    try testing.expectError(HyperLogLogError.InvalidPrecision, HyperLogLog.init(testing.allocator, 17));
}

test "empty estimator" {
    var hll = try HyperLogLog.init(testing.allocator, 8);
    defer hll.deinit();

    try testing.expectEqual(@as(f64, 0.0), hll.estimatedSize());
}

test "single item" {
    var hll = try HyperLogLog.init(testing.allocator, 8);
    defer hll.deinit();

    hll.add("test");
    const size = hll.estimatedSize();

    try testing.expect(size > 0 and size < 5);
}

test "add and estimated size" {
    var hll = try HyperLogLog.init(testing.allocator, 10);
    defer hll.deinit();

    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const item = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        hll.add(item);
    }

    const size = hll.estimatedSize();
    try testing.expect(size > 80 and size < 120);
}

test "merge compatible estimators" {
    var hll1 = try HyperLogLog.init(testing.allocator, 8);
    defer hll1.deinit();

    var hll2 = try HyperLogLog.init(testing.allocator, 8);
    defer hll2.deinit();

    hll1.add("item1");
    hll2.add("item2");

    try hll1.merge(&hll2);
    const size = hll1.estimatedSize();

    try testing.expect(size > 0);
}

test "merge incompatible precision" {
    var hll1 = try HyperLogLog.init(testing.allocator, 8);
    defer hll1.deinit();

    var hll2 = try HyperLogLog.init(testing.allocator, 10);
    defer hll2.deinit();

    try testing.expectError(HyperLogLogError.IncompatiblePrecision, hll1.merge(&hll2));
}
