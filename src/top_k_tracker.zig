//! Rank candidate items by the counts of any frequency estimator (for
//! example `CountMinSketch`, or `SpaceSaving`). Use this when the set of
//! candidates is known; for a stream with unknown heavy hitters, use
//! `SpaceSaving` directly.
//!
//! The estimator type must provide `fn count(self, item: []const u8) u64`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TopKError = error{ InvalidK, OutOfMemory };

/// Result item for top-k queries. `item` is an owned copy.
pub const TopKItem = struct {
    item: []const u8,
    frequency: u64,

    /// Frequency descending, then item bytes ascending (deterministic).
    pub fn lessThan(_: void, a: TopKItem, b: TopKItem) bool {
        if (a.frequency != b.frequency) return a.frequency > b.frequency;
        return std.mem.order(u8, a.item, b.item) == .lt;
    }
};

pub fn TopKTracker(comptime FrequencyEstimator: type) type {
    return struct {
        /// The k candidates with the highest estimated counts, sorted by
        /// `TopKItem.lessThan`. Duplicate candidates are counted once.
        /// Free the result with `freeTopK`.
        pub fn topK(estimator: *const FrequencyEstimator, allocator: Allocator, candidates: []const []const u8, k: usize) TopKError![]TopKItem {
            if (k == 0) return error.InvalidK;

            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            var ranked: std.ArrayList(TopKItem) = .empty;
            defer ranked.deinit(allocator);
            for (candidates) |candidate| {
                const gop = try seen.getOrPut(allocator, candidate);
                if (gop.found_existing) continue;
                // Borrowed for now; only the returned items are copied.
                try ranked.append(allocator, .{ .item = candidate, .frequency = estimator.count(candidate) });
            }
            std.mem.sort(TopKItem, ranked.items, {}, TopKItem.lessThan);

            const n = @min(k, ranked.items.len);
            const result = try allocator.alloc(TopKItem, n);
            var copied: usize = 0;
            errdefer {
                for (result[0..copied]) |r| allocator.free(r.item);
                allocator.free(result);
            }
            for (result, ranked.items[0..n]) |*dst, src| {
                dst.* = .{ .item = try allocator.dupe(u8, src.item), .frequency = src.frequency };
                copied += 1;
            }
            return result;
        }

        pub fn freeTopK(allocator: Allocator, items: []TopKItem) void {
            for (items) |item| allocator.free(item.item);
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

        pub fn count(self: *const Self, item: []const u8) u64 {
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
        pub fn count(_: *const @This(), _: []const u8) u64 {
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
        pub fn count(_: *const @This(), _: []const u8) u64 {
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
        pub fn count(self: *const @This(), item: []const u8) u64 {
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
        pub fn count(self: *const @This(), item: []const u8) u64 {
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

test "TopKTracker deduplicates and frees on OOM" {
    const Mock = struct {
        pub fn count(_: *const @This(), item: []const u8) u64 {
            return item.len;
        }
    };
    const tracker = TopKTracker(Mock);
    const candidates = [_][]const u8{ "aaa", "b", "aaa", "cc", "b" };
    const top = try tracker.topK(&Mock{}, testing.allocator, &candidates, 10);
    defer tracker.freeTopK(testing.allocator, top);
    try testing.expectEqual(@as(usize, 3), top.len);
    try testing.expectEqualStrings("aaa", top[0].item);
    try testing.expectEqualStrings("cc", top[1].item);

    // Every allocation failure point must leave nothing leaked.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            const t = try tracker.topK(&Mock{}, a, &candidates, 2);
            tracker.freeTopK(a, t);
        }
    }.run, .{});
}
