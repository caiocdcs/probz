//! Q-digest is a probabilistic data structure for approximate quantile queries
//! on streaming data. It maintains a compact summary of a data distribution
//! that allows efficient estimation of quantiles, ranks, and range queries.
//!
//! The algorithm uses a binary tree structure where each node represents a
//! range of values and stores a count. The digest is compressed to maintain
//! at most O(log(n)/ε) nodes where n is the universe size and ε is the
//! compression parameter.
//!
//! # References
//!
//! - ["The space complexity of approximating the frequency moments", Noga Alon,
//!   Yossi Matias, Mario Szegedy](https://www.tau.ac.il/~nogaa/PDFS/amsz4.pdf)
//! - ["Approximate quantiles and the order statistics problem", Gurmeet Singh Manku,
//!   Sridhar Rajagopalan, Bruce G. Lindsay](https://web.stanford.edu/class/cs369g/files/lectures/lec5.pdf)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;

pub const QDigestError = error{
    InvalidCompressionFactor,
    InvalidUniverseSize,
    EmptyDigest,
};

/// Node in the q-digest tree representing a range [left, right] with count
const Node = struct {
    range_left: u64,
    range_right: u64,
    count: u64,
};

pub const QDigest = struct {
    const Self = @This();

    /// Compression parameter (higher = more compression, less accuracy)
    compression_factor: u32,
    /// Size of the universe (maximum value that can be inserted)
    universe_size: u64,
    /// Tree nodes stored as a list (simplified approach)
    nodes: ArrayList(Node),
    /// Total number of elements inserted
    total_count: u64,
    allocator: Allocator,

    const MIN_COMPRESSION_FACTOR: u32 = 1;
    const MAX_COMPRESSION_FACTOR: u32 = 1000;

    /// Create a new Q-digest with specified compression factor and universe size.
    /// Lower compression factor provides better accuracy but uses more memory.
    /// Universe size must be a power of 2.
    pub fn init(allocator: Allocator, compression_factor: u32, universe_size: u64) !QDigest {
        if (compression_factor < MIN_COMPRESSION_FACTOR or compression_factor > MAX_COMPRESSION_FACTOR) {
            return QDigestError.InvalidCompressionFactor;
        }

        if (universe_size == 0 or (universe_size & (universe_size - 1)) != 0) {
            return QDigestError.InvalidUniverseSize;
        }

        const nodes = try ArrayList(Node).initCapacity(allocator, 0);

        return QDigest{
            .compression_factor = compression_factor,
            .universe_size = universe_size,
            .nodes = nodes,
            .total_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QDigest) void {
        self.nodes.deinit(self.allocator);
    }

    /// Add a value to the digest
    pub fn add(self: *QDigest, value: u64) !void {
        if (value >= self.universe_size) {
            return;
        }

        // Find existing node or create new one
        var found = false;
        for (self.nodes.items) |*node| {
            if (node.range_left <= value and value <= node.range_right) {
                node.count += 1;
                found = true;
                break;
            }
        }

        if (!found) {
            const new_node = Node{
                .range_left = value,
                .range_right = value,
                .count = 1,
            };
            try self.nodes.append(self.allocator, new_node);
        }

        self.total_count += 1;

        // Compress the digest
        try self.compress();
    }

    /// Estimate the quantile at the given rank (0.0 to 1.0)
    pub fn quantile(self: *const QDigest, percentile: f64) !u64 {
        if (self.total_count == 0) {
            return QDigestError.EmptyDigest;
        }

        const target_count = @as(u64, @intFromFloat(@round(percentile * @as(f64, @floatFromInt(self.total_count)))));
        var current_count: u64 = 0;

        // Create a copy for sorting
        var node_list = try ArrayList(Node).initCapacity(self.allocator, self.nodes.items.len);
        defer node_list.deinit(self.allocator);

        for (self.nodes.items) |node| {
            try node_list.append(self.allocator, node);
        }

        std.mem.sort(Node, node_list.items, {}, struct {
            fn lessThan(_: void, a: Node, b: Node) bool {
                return a.range_left < b.range_left;
            }
        }.lessThan);

        for (node_list.items) |node| {
            current_count += node.count;
            if (current_count >= target_count) {
                // Linear interpolation within the range
                const range_size = node.range_right - node.range_left + 1;
                const offset = if (node.count > 0)
                    @min(range_size - 1, (target_count - (current_count - node.count)) * range_size / node.count)
                else
                    0;
                return node.range_left + offset;
            }
        }

        return self.universe_size - 1;
    }

    /// Estimate the rank of a given value (returns value between 0.0 and 1.0)
    pub fn rank(self: *const QDigest, value: u64) f64 {
        if (self.total_count == 0) {
            return 0.0;
        }

        var count_below: u64 = 0;

        for (self.nodes.items) |node| {
            if (node.range_right < value) {
                count_below += node.count;
            } else if (node.range_left <= value and value <= node.range_right) {
                // Value falls within this range, interpolate
                const range_size = node.range_right - node.range_left + 1;
                const position_in_range = value - node.range_left;
                const partial_count = node.count * position_in_range / range_size;
                count_below += partial_count;
            }
        }

        return @as(f64, @floatFromInt(count_below)) / @as(f64, @floatFromInt(self.total_count));
    }

    /// Merge another Q-digest into this one
    pub fn merge(self: *QDigest, other: *const QDigest) !void {
        if (self.compression_factor != other.compression_factor or
            self.universe_size != other.universe_size)
        {
            return QDigestError.InvalidCompressionFactor;
        }

        for (other.nodes.items) |other_node| {
            // Add each value from the other digest
            for (0..other_node.count) |_| {
                // Use the midpoint of the range as representative value
                const representative_value = (other_node.range_left + other_node.range_right) / 2;
                try self.add(representative_value);
            }
        }
    }

    /// Get the total number of elements in the digest
    pub fn size(self: *const QDigest) u64 {
        return self.total_count;
    }

    // Private helper functions

    fn compress(self: *QDigest) !void {
        if (self.nodes.items.len <= 1) {
            return;
        }

        const threshold = self.total_count / self.compression_factor;
        if (threshold == 0) {
            return;
        }

        var i: usize = 0;
        while (i < self.nodes.items.len) {
            const node = &self.nodes.items[i];

            if (node.count < threshold) {
                // Try to merge with adjacent node
                var merged = false;

                // Try to merge with next node
                if (i + 1 < self.nodes.items.len) {
                    const next_node = &self.nodes.items[i + 1];
                    if (node.range_right + 1 == next_node.range_left) {
                        // Merge nodes
                        next_node.range_left = node.range_left;
                        next_node.count += node.count;
                        _ = self.nodes.orderedRemove(i);
                        merged = true;
                    }
                }

                // Try to merge with previous node
                if (!merged and i > 0) {
                    const prev_node = &self.nodes.items[i - 1];
                    if (prev_node.range_right + 1 == node.range_left) {
                        // Merge nodes
                        prev_node.range_right = node.range_right;
                        prev_node.count += node.count;
                        _ = self.nodes.orderedRemove(i);
                        merged = true;
                        i -= 1; // Adjust index since we removed current node
                    }
                }

                if (!merged) {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
    }
};

const testing = std.testing;

test "init" {
    var qd = try QDigest.init(testing.allocator, 10, 1024);
    defer qd.deinit();
}

test "invalid compression factor" {
    try testing.expectError(QDigestError.InvalidCompressionFactor, QDigest.init(testing.allocator, 0, 1024));
    try testing.expectError(QDigestError.InvalidCompressionFactor, QDigest.init(testing.allocator, 1001, 1024));
}

test "invalid universe size" {
    try testing.expectError(QDigestError.InvalidUniverseSize, QDigest.init(testing.allocator, 10, 0));
    try testing.expectError(QDigestError.InvalidUniverseSize, QDigest.init(testing.allocator, 10, 100)); // Not power of 2
}

test "empty digest quantile" {
    var qd = try QDigest.init(testing.allocator, 10, 1024);
    defer qd.deinit();

    try testing.expectError(QDigestError.EmptyDigest, qd.quantile(0.5));
}

test "single item" {
    var qd = try QDigest.init(testing.allocator, 10, 1024);
    defer qd.deinit();

    try qd.add(42);
    try testing.expectEqual(@as(u64, 1), qd.size());

    const q = try qd.quantile(0.5);
    try testing.expectEqual(@as(u64, 42), q);
}

test "add and quantile" {
    var qd = try QDigest.init(testing.allocator, 50, 1024);
    defer qd.deinit();

    // Add values 1 through 100
    for (1..101) |i| {
        try qd.add(@intCast(i));
    }

    try testing.expectEqual(@as(u64, 100), qd.size());

    // Test approximate quantiles
    const median = try qd.quantile(0.5);
    try testing.expect(median >= 40 and median <= 60); // Should be around 50

    const q25 = try qd.quantile(0.25);
    try testing.expect(q25 >= 15 and q25 <= 35); // Should be around 25

    const q75 = try qd.quantile(0.75);
    try testing.expect(q75 >= 65 and q75 <= 85); // Should be around 75
}

test "rank estimation" {
    var qd = try QDigest.init(testing.allocator, 50, 1024);
    defer qd.deinit();

    for (1..101) |i| {
        try qd.add(@intCast(i));
    }

    const rank50 = qd.rank(50);
    try testing.expect(rank50 >= 0.4 and rank50 <= 0.6);

    const rank25 = qd.rank(25);
    try testing.expect(rank25 >= 0.1 and rank25 <= 0.35);
}

test "merge compatible digests" {
    var qd1 = try QDigest.init(testing.allocator, 20, 256);
    defer qd1.deinit();

    var qd2 = try QDigest.init(testing.allocator, 20, 256);
    defer qd2.deinit();

    try qd1.add(10);
    try qd1.add(20);

    try qd2.add(30);
    try qd2.add(40);

    try qd1.merge(&qd2);
    try testing.expectEqual(@as(u64, 4), qd1.size());
}
