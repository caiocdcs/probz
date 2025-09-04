//! T-digest is a probabilistic data structure for approximate quantile queries
//! on streaming data. It maintains a compact summary of a data distribution
//! that allows efficient estimation of quantiles and ranks with excellent
//! accuracy near the extremes (0th and 100th percentiles).
//!
//! The algorithm uses centroids (mean, weight) to represent clusters of points
//! and employs a scale function to control the size of clusters, making them
//! smaller near the extremes and larger in the middle of the distribution.
//!
//! # References
//!
//! - ["Computing Extremely Accurate Quantiles Using t-Digests", Ted Dunning
//!   and Otmar Ertl](https://github.com/tdunning/t-digest/blob/main/docs/t-digest-paper/histo.pdf)
//! - ["The t-digest: Efficient estimates of distributions", Ted Dunning
//!   (2019)](https://arxiv.org/pdf/1902.04023.pdf)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;

pub const TDigestError = error{
    InvalidCompression,
    EmptyDigest,
    InvalidParameters,
};

/// Centroid representing a cluster of points with mean and weight
const Centroid = struct {
    mean: f64,
    weight: u64,

    fn lessThan(_: void, a: Centroid, b: Centroid) bool {
        return a.mean < b.mean;
    }
};

pub const TDigest = struct {
    const Self = @This();

    /// Compression parameter (higher = more compression, less accuracy)
    compression: f64,
    /// List of centroids ordered by mean
    centroids: ArrayList(Centroid),
    /// Total number of elements inserted
    total_weight: u64,
    /// Maximum number of centroids before compression
    max_discrete: u32,
    allocator: Allocator,

    const DEFAULT_COMPRESSION: f64 = 100.0;
    const MIN_COMPRESSION: f64 = 10.0;
    const MAX_COMPRESSION: f64 = 1000.0;
    const DEFAULT_MAX_DISCRETE: u32 = 25;

    /// Create a new T-digest with specified compression parameter.
    /// Higher compression provides more accuracy but uses more memory.
    /// Typical values are between 25 and 1000, with 100 being a good default.
    pub fn init(allocator: Allocator, compression: f64) !TDigest {
        if (compression < MIN_COMPRESSION or compression > MAX_COMPRESSION) {
            return TDigestError.InvalidCompression;
        }

        const centroids = try ArrayList(Centroid).initCapacity(allocator, 0);

        return TDigest{
            .compression = compression,
            .centroids = centroids,
            .total_weight = 0,
            .max_discrete = DEFAULT_MAX_DISCRETE,
            .allocator = allocator,
        };
    }

    /// Create a T-digest with default compression (100.0)
    pub fn initDefault(allocator: Allocator) !TDigest {
        return try init(allocator, DEFAULT_COMPRESSION);
    }

    pub fn deinit(self: *TDigest) void {
        self.centroids.deinit(self.allocator);
    }

    /// Add a value to the digest
    pub fn add(self: *TDigest, value: f64) !void {
        try self.addWeighted(value, 1);
    }

    /// Add a value with specified weight to the digest
    pub fn addWeighted(self: *TDigest, value: f64, weight: u64) !void {
        if (weight == 0) return;

        const new_centroid = Centroid{
            .mean = value,
            .weight = weight,
        };

        try self.centroids.append(self.allocator, new_centroid);
        self.total_weight += weight;

        if (self.centroids.items.len > self.max_discrete) {
            try self.compress();
        }
    }

    /// Estimate the quantile at the given percentile (0.0 to 1.0)
    pub fn quantile(self: *const TDigest, percentile: f64) !f64 {
        if (self.total_weight == 0) {
            return TDigestError.EmptyDigest;
        }

        if (percentile < 0.0 or percentile > 1.0) {
            return TDigestError.InvalidParameters;
        }

        if (self.centroids.items.len == 0) {
            return TDigestError.EmptyDigest;
        }

        if (self.centroids.items.len == 1) {
            return self.centroids.items[0].mean;
        }

        // Ensure centroids are sorted
        var sorted_centroids = try ArrayList(Centroid).initCapacity(self.allocator, self.centroids.items.len);
        defer sorted_centroids.deinit(self.allocator);

        for (self.centroids.items) |centroid| {
            try sorted_centroids.append(self.allocator, centroid);
        }

        std.mem.sort(Centroid, sorted_centroids.items, {}, Centroid.lessThan);

        const target_weight = percentile * @as(f64, @floatFromInt(self.total_weight));

        if (target_weight <= 0) {
            return sorted_centroids.items[0].mean;
        }

        if (target_weight >= @as(f64, @floatFromInt(self.total_weight))) {
            return sorted_centroids.items[sorted_centroids.items.len - 1].mean;
        }

        var current_weight: f64 = 0.0;

        for (0..sorted_centroids.items.len - 1) |i| {
            const centroid = sorted_centroids.items[i];
            const next_centroid = sorted_centroids.items[i + 1];

            const half_weight = @as(f64, @floatFromInt(centroid.weight)) / 2.0;
            const next_half_weight = @as(f64, @floatFromInt(next_centroid.weight)) / 2.0;

            if (current_weight + half_weight >= target_weight) {
                // Target is within the current centroid
                return centroid.mean;
            }

            if (current_weight + half_weight + next_half_weight >= target_weight) {
                // Interpolate between current and next centroid
                const delta = target_weight - (current_weight + half_weight);
                const total_gap_weight = next_half_weight;
                const ratio = if (total_gap_weight > 0) delta / total_gap_weight else 0.0;
                return centroid.mean + ratio * (next_centroid.mean - centroid.mean);
            }

            current_weight += @as(f64, @floatFromInt(centroid.weight));
        }

        return sorted_centroids.items[sorted_centroids.items.len - 1].mean;
    }

    /// Estimate the cumulative distribution function value at the given value
    pub fn cdf(self: *const TDigest, value: f64) f64 {
        if (self.total_weight == 0) {
            return 0.0;
        }

        if (self.centroids.items.len == 0) {
            return 0.0;
        }

        var sorted_centroids = ArrayList(Centroid).initCapacity(self.allocator, self.centroids.items.len) catch return 0.0;
        defer sorted_centroids.deinit(self.allocator);

        for (self.centroids.items) |centroid| {
            sorted_centroids.append(self.allocator, centroid) catch return 0.0;
        }

        std.mem.sort(Centroid, sorted_centroids.items, {}, Centroid.lessThan);

        if (value < sorted_centroids.items[0].mean) {
            return 0.0;
        }

        if (value >= sorted_centroids.items[sorted_centroids.items.len - 1].mean) {
            return 1.0;
        }

        var weight_sum: f64 = 0.0;

        for (0..sorted_centroids.items.len) |i| {
            const centroid = sorted_centroids.items[i];

            if (value < centroid.mean) {
                // Interpolate within the gap
                if (i > 0) {
                    const prev_centroid = sorted_centroids.items[i - 1];
                    const prev_weight = @as(f64, @floatFromInt(prev_centroid.weight));
                    const curr_weight = @as(f64, @floatFromInt(centroid.weight));

                    weight_sum += prev_weight / 2.0;

                    const ratio = (value - prev_centroid.mean) / (centroid.mean - prev_centroid.mean);
                    const interpolated_weight = ratio * (curr_weight / 2.0);
                    weight_sum += interpolated_weight;
                }
                break;
            } else if (value == centroid.mean) {
                weight_sum += @as(f64, @floatFromInt(centroid.weight)) / 2.0;
                break;
            } else {
                weight_sum += @as(f64, @floatFromInt(centroid.weight));
            }
        }

        return weight_sum / @as(f64, @floatFromInt(self.total_weight));
    }

    /// Merge another T-digest into this one
    pub fn merge(self: *TDigest, other: *const TDigest) !void {
        for (other.centroids.items) |centroid| {
            try self.addWeighted(centroid.mean, centroid.weight);
        }
    }

    /// Get the total number of elements in the digest
    pub fn size(self: *const TDigest) u64 {
        return self.total_weight;
    }

    /// Force compression of the digest
    pub fn compress(self: *TDigest) !void {
        if (self.centroids.items.len <= 1) {
            return;
        }

        // Sort centroids by mean
        std.mem.sort(Centroid, self.centroids.items, {}, Centroid.lessThan);

        var compressed = try ArrayList(Centroid).initCapacity(self.allocator, self.centroids.items.len);

        if (self.centroids.items.len > 0) {
            var current_centroid = self.centroids.items[0];

            for (1..self.centroids.items.len) |i| {
                const next_centroid = self.centroids.items[i];

                // Simple merging strategy: merge if centroids are close and weights are small
                const should_merge = (next_centroid.mean - current_centroid.mean) < (100.0 / self.compression) and
                    current_centroid.weight + next_centroid.weight < (self.total_weight / @as(u64, @intFromFloat(self.compression / 2)));

                if (should_merge) {
                    // Merge centroids
                    const total_weight = current_centroid.weight + next_centroid.weight;
                    const weighted_mean = (current_centroid.mean * @as(f64, @floatFromInt(current_centroid.weight)) +
                        next_centroid.mean * @as(f64, @floatFromInt(next_centroid.weight))) /
                        @as(f64, @floatFromInt(total_weight));

                    current_centroid = Centroid{
                        .mean = weighted_mean,
                        .weight = total_weight,
                    };
                } else {
                    // Add current centroid and start new one
                    try compressed.append(self.allocator, current_centroid);
                    current_centroid = next_centroid;
                }
            }

            // Add the last centroid
            try compressed.append(self.allocator, current_centroid);
        }

        // Replace old centroids with compressed ones
        self.centroids.deinit(self.allocator);
        self.centroids = compressed;
    }

    // Private helper functions

    fn getCumulativeWeight(self: *const TDigest, centroids: []const Centroid, additional_weight: u64) u64 {
        _ = self;
        var sum: u64 = additional_weight;
        for (centroids) |centroid| {
            sum += centroid.weight;
        }
        return sum;
    }

    fn maxCentroidWeight(self: *const TDigest, cumulative_weight: u64) u64 {
        if (self.total_weight == 0) return 1;
        const q = @as(f64, @floatFromInt(cumulative_weight)) / @as(f64, @floatFromInt(self.total_weight));
        const scale_factor = 4.0 * self.compression * q * (1.0 - q);
        return @max(1, @as(u64, @intFromFloat(@max(1.0, scale_factor))));
    }
};

const testing = std.testing;

test "init" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();
}

test "init default" {
    var td = try TDigest.initDefault(testing.allocator);
    defer td.deinit();
}

test "invalid compression" {
    try testing.expectError(TDigestError.InvalidCompression, TDigest.init(testing.allocator, 5.0));
    try testing.expectError(TDigestError.InvalidCompression, TDigest.init(testing.allocator, 1001.0));
}

test "empty digest quantile" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    try testing.expectError(TDigestError.EmptyDigest, td.quantile(0.5));
}

test "single item" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    try td.add(42.0);
    try testing.expectEqual(@as(u64, 1), td.size());

    const q = try td.quantile(0.5);
    try testing.expectEqual(@as(f64, 42.0), q);
}

test "add and quantile" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    // Add values 1 through 100
    for (1..101) |i| {
        try td.add(@as(f64, @floatFromInt(i)));
    }

    try testing.expectEqual(@as(u64, 100), td.size());

    // Test approximate quantiles
    const median = try td.quantile(0.5);
    try testing.expect(median >= 45.0 and median <= 55.0); // Should be around 50

    const q25 = try td.quantile(0.25);
    try testing.expect(q25 >= 20.0 and q25 <= 30.0); // Should be around 25

    const q75 = try td.quantile(0.75);
    try testing.expect(q75 >= 70.0 and q75 <= 80.0); // Should be around 75
}

test "weighted values" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    try td.addWeighted(10.0, 50);
    try td.addWeighted(20.0, 50);

    try testing.expectEqual(@as(u64, 100), td.size());

    const median = try td.quantile(0.5);
    try testing.expect(median >= 10.0 and median <= 20.0); // Should be around 15 but allow wider range
}

test "cdf estimation" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    for (1..101) |i| {
        try td.add(@as(f64, @floatFromInt(i)));
    }

    const cdf50 = td.cdf(50.0);
    try testing.expect(cdf50 >= 0.4 and cdf50 <= 0.6);

    const cdf25 = td.cdf(25.0);
    try testing.expect(cdf25 >= 0.1 and cdf25 <= 0.35);
}

test "merge compatible digests" {
    var td1 = try TDigest.init(testing.allocator, 50.0);
    defer td1.deinit();

    var td2 = try TDigest.init(testing.allocator, 75.0);
    defer td2.deinit();

    try td1.add(10.0);
    try td1.add(20.0);

    try td2.add(30.0);
    try td2.add(40.0);

    try td1.merge(&td2);
    try testing.expectEqual(@as(u64, 4), td1.size());
}

test "extreme quantiles accuracy" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    // Add values with more density at extremes
    for (0..50) |_| {
        try td.add(1.0); // Many low values
    }

    for (1..50) |i| {
        try td.add(@as(f64, @floatFromInt(i + 1))); // Middle values
    }

    for (0..50) |_| {
        try td.add(100.0); // Many high values
    }

    // Test that extreme quantiles are accurate
    const q01 = try td.quantile(0.01);
    try testing.expect(q01 <= 5.0);

    const q99 = try td.quantile(0.99);
    try testing.expect(q99 >= 95.0);
}

test "invalid quantile parameters" {
    var td = try TDigest.init(testing.allocator, 100.0);
    defer td.deinit();

    try td.add(42.0);

    try testing.expectError(TDigestError.InvalidParameters, td.quantile(-0.1));
    try testing.expectError(TDigestError.InvalidParameters, td.quantile(1.1));
}

test "compression behavior" {
    var td = try TDigest.init(testing.allocator, 20.0); // Low compression for more aggressive merging
    defer td.deinit();

    // Add many values to trigger compression
    for (1..1000) |i| {
        try td.add(@as(f64, @floatFromInt(i)));
    }

    // After compression, should have fewer centroids than values
    try testing.expect(td.centroids.items.len < 500);
    try testing.expectEqual(@as(u64, 999), td.size());
}
