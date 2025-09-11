//! Top K tracker for finding the most frequent items from frequency estimation data structures.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TopKError = error{
    InvalidK,
    OutOfMemory,
};

/// Result item for Top K queries.
pub const TopKItem = struct {
    item: []const u8,
    frequency: u64,

    pub fn lessThan(_: void, a: TopKItem, b: TopKItem) bool {
        return a.frequency > b.frequency;
    }
};

pub fn TopKTracker(comptime FrequencyEstimator: type) type {
    return struct {
        const Self = @This();

        /// Find the top K most frequent items from candidates.
        /// Returns items sorted by frequency in descending order.
        pub fn topK(estimator: *const FrequencyEstimator, allocator: Allocator, candidates: []const []const u8, k: usize) ![]TopKItem {
            if (k == 0) return TopKError.InvalidK;
            if (candidates.len == 0) return try allocator.alloc(TopKItem, 0);

            var items = try allocator.alloc(TopKItem, candidates.len);
            defer allocator.free(items);

            for (candidates, 0..) |candidate, i| {
                const freq = estimator.estimate(candidate);

                const owned_item = try allocator.dupe(u8, candidate);
                items[i] = TopKItem{
                    .item = owned_item,
                    .frequency = freq,
                };
            }

            std.mem.sort(TopKItem, items, {}, TopKItem.lessThan);

            const result_len = @min(k, items.len);
            const result = try allocator.alloc(TopKItem, result_len);

            for (result, 0..) |*dst, i| {
                dst.* = items[i];
            }

            for (items[result_len..]) |item| {
                allocator.free(item.item);
            }

            return result;
        }

        pub fn freeTopK(allocator: Allocator, items: []TopKItem) void {
            for (items) |item| {
                allocator.free(item.item);
            }
            allocator.free(items);
        }
    };
}

const testing = std.testing;

test "TopKTracker with mock estimator" {
    const MockEstimator = struct {
        const Self = @This();

        frequencies: std.StringHashMap(u64),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .frequencies = std.StringHashMap(u64).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.frequencies.deinit();
        }

        pub fn setFrequency(self: *Self, item: []const u8, freq: u64) !void {
            try self.frequencies.put(item, freq);
        }

        pub fn estimate(self: *const Self, item: []const u8) u64 {
            return self.frequencies.get(item) orelse 0;
        }
    };

    var estimator = MockEstimator.init(testing.allocator);
    defer estimator.deinit();

    try estimator.setFrequency("apple", 100);
    try estimator.setFrequency("banana", 200);
    try estimator.setFrequency("cherry", 50);
    try estimator.setFrequency("date", 150);

    const tracker = TopKTracker(MockEstimator);
    const candidates = [_][]const u8{ "apple", "banana", "cherry", "date", "elderberry" };
    const top3 = try tracker.topK(&estimator, testing.allocator, &candidates, 3);
    defer tracker.freeTopK(testing.allocator, top3);

    try testing.expectEqual(@as(usize, 3), top3.len);

    try testing.expect(std.mem.eql(u8, "banana", top3[0].item));
    try testing.expectEqual(@as(u64, 200), top3[0].frequency);

    try testing.expect(std.mem.eql(u8, "date", top3[1].item));
    try testing.expectEqual(@as(u64, 150), top3[1].frequency);

    try testing.expect(std.mem.eql(u8, "apple", top3[2].item));
    try testing.expectEqual(@as(u64, 100), top3[2].frequency);
}

test "TopKTracker edge cases" {
    const MockEstimator = struct {
        pub fn estimate(_: *const @This(), _: []const u8) u64 {
            return 42;
        }
    };

    const estimator = MockEstimator{};
    const tracker = TopKTracker(MockEstimator);

    const candidates = [_][]const u8{"test"};
    try testing.expectError(TopKError.InvalidK, tracker.topK(&estimator, testing.allocator, &candidates, 0));

    const empty_candidates = [_][]const u8{};
    const empty_result = try tracker.topK(&estimator, testing.allocator, &empty_candidates, 5);
    defer tracker.freeTopK(testing.allocator, empty_result);
    try testing.expectEqual(@as(usize, 0), empty_result.len);
}

test "TopKTracker with equal frequencies" {
    const MockEstimator = struct {
        pub fn estimate(_: *const @This(), _: []const u8) u64 {
            return 10;
        }
    };

    const estimator = MockEstimator{};
    const tracker = TopKTracker(MockEstimator);

    const candidates = [_][]const u8{ "a", "b", "c", "d" };
    const top2 = try tracker.topK(&estimator, testing.allocator, &candidates, 2);
    defer tracker.freeTopK(testing.allocator, top2);

    try testing.expectEqual(@as(usize, 2), top2.len);
    try testing.expectEqual(@as(u64, 10), top2[0].frequency);
    try testing.expectEqual(@as(u64, 10), top2[1].frequency);
}

test "TopKTracker with k larger than candidates" {
    const MockEstimator = struct {
        pub fn estimate(self: *const @This(), item: []const u8) u64 {
            _ = self;
            if (std.mem.eql(u8, item, "x")) return 5;
            if (std.mem.eql(u8, item, "y")) return 3;
            return 0;
        }
    };

    const estimator = MockEstimator{};
    const tracker = TopKTracker(MockEstimator);

    const candidates = [_][]const u8{ "x", "y" };
    const top5 = try tracker.topK(&estimator, testing.allocator, &candidates, 5);
    defer tracker.freeTopK(testing.allocator, top5);

    try testing.expectEqual(@as(usize, 2), top5.len);

    try testing.expect(std.mem.eql(u8, "x", top5[0].item));
    try testing.expectEqual(@as(u64, 5), top5[0].frequency);

    try testing.expect(std.mem.eql(u8, "y", top5[1].item));
    try testing.expectEqual(@as(u64, 3), top5[1].frequency);
}

test "TopKTracker with zero frequencies" {
    const MockEstimator = struct {
        pub fn estimate(self: *const @This(), item: []const u8) u64 {
            _ = self;
            if (std.mem.eql(u8, item, "existing")) return 42;
            return 0;
        }
    };

    const estimator = MockEstimator{};
    const tracker = TopKTracker(MockEstimator);

    const candidates = [_][]const u8{ "existing", "nonexistent1", "nonexistent2" };
    const top2 = try tracker.topK(&estimator, testing.allocator, &candidates, 2);
    defer tracker.freeTopK(testing.allocator, top2);

    try testing.expectEqual(@as(usize, 2), top2.len);

    try testing.expect(std.mem.eql(u8, "existing", top2[0].item));
    try testing.expectEqual(@as(u64, 42), top2[0].frequency);

    try testing.expectEqual(@as(u64, 0), top2[1].frequency);
}
