//! Scalable Bloom Filter is a variant that can grow dynamically to maintain
//! a target false positive rate. It starts with a single bloom filter and
//! sets new filters when the current one reaches capacity. Each new filter
//! has a tighter false positive rate to maintain the overall target rate.

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const BloomFilter = @import("bloom_filter.zig").BloomFilter;

pub const ScalableBloomFilter = struct {
    allocator: Allocator,
    filters: ArrayList(BloomFilter),
    initial_capacity: u64,
    target_fp_rate: f64,
    growth_factor: u64,
    fp_tightening_ratio: f64,
    item_count: u64,

    /// Create a new Scalable Bloom Filter with initial capacity and target false positive rate.
    /// growth_factor: how much each new filter grows (default: 2x)
    /// fp_tightening_ratio: how much to tighten FP rate for each new filter (default: 0.5x)
    pub fn init(
        allocator: Allocator,
        initial_capacity: u64,
        target_fp_rate: f64,
        growth_factor: u64,
        fp_tightening_ratio: f64,
    ) !ScalableBloomFilter {
        var filters = ArrayList(BloomFilter).init(allocator);

        // Create initial filter
        const initial_filter = try BloomFilter.init(allocator, initial_capacity, target_fp_rate);
        try filters.append(initial_filter);

        return ScalableBloomFilter{
            .allocator = allocator,
            .filters = filters,
            .initial_capacity = initial_capacity,
            .target_fp_rate = target_fp_rate,
            .growth_factor = growth_factor,
            .fp_tightening_ratio = fp_tightening_ratio,
            .item_count = 0,
        };
    }

    /// Create with default parameters: 2x growth, 0.5x FP tightening
    pub fn initDefault(allocator: Allocator, initial_capacity: u64, target_fp_rate: f64) !ScalableBloomFilter {
        return init(allocator, initial_capacity, target_fp_rate, 2, 0.5);
    }

    pub fn deinit(self: *ScalableBloomFilter) void {
        for (self.filters.items) |*filter| {
            filter.deinit();
        }
        self.filters.deinit();
    }

    /// Set an item in the scalable bloom filter
    pub fn set(self: *ScalableBloomFilter, item: []const u8) !void {
        // Check if we need to set a new filter
        const current_filter = &self.filters.items[self.filters.items.len - 1];
        const estimated_size = current_filter.estimatedSize();
        const capacity = self.calculateFilterCapacity(self.filters.items.len - 1);

        if (estimated_size >= capacity) {
            try self.setNewFilter();
        }

        // Set in the most recent filter
        const latest_filter = &self.filters.items[self.filters.items.len - 1];
        try latest_filter.set(item);
        self.item_count += 1;
    }

    /// Check if an item might be in the filter
    pub fn has(self: *const ScalableBloomFilter, item: []const u8) bool {
        for (self.filters.items) |*filter| {
            if (filter.has(item)) {
                return true;
            }
        }
        return false;
    }

    /// Get the total estimated number of unique items
    pub fn estimatedSize(self: *const ScalableBloomFilter) u64 {
        return self.item_count;
    }

    /// Get current false positive rate
    pub fn currentFpRate(self: *const ScalableBloomFilter) f64 {
        var total_rate: f64 = 0.0;
        for (self.filters.items, 0..) |_, i| {
            total_rate += self.calculateFilterFpRate(i);
        }
        return total_rate;
    }

    /// Get number of filters currently in use
    pub fn filterCount(self: *const ScalableBloomFilter) usize {
        return self.filters.items.len;
    }

    fn setNewFilter(self: *ScalableBloomFilter) !void {
        const filter_index = self.filters.items.len;
        const capacity = self.calculateFilterCapacity(filter_index);
        const fp_rate = self.calculateFilterFpRate(filter_index);

        const new_filter = try BloomFilter.init(self.allocator, capacity, fp_rate);
        try self.filters.append(new_filter);
    }

    fn calculateFilterCapacity(self: *const ScalableBloomFilter, filter_index: usize) u64 {
        var capacity = self.initial_capacity;
        for (0..filter_index) |_| {
            capacity *= self.growth_factor;
        }
        return capacity;
    }

    fn calculateFilterFpRate(self: *const ScalableBloomFilter, filter_index: usize) f64 {
        var fp_rate = self.target_fp_rate;
        for (0..filter_index) |_| {
            fp_rate *= self.fp_tightening_ratio;
        }
        return fp_rate;
    }
};

const testing = std.testing;

test "init default" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 100, 0.01);
    defer sbf.deinit();

    try testing.expectEqual(@as(usize, 1), sbf.filterCount());
}

test "init with custom parameters" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, 50, 0.02, 3, 0.3);
    defer sbf.deinit();

    try testing.expectEqual(@as(usize, 1), sbf.filterCount());
}

test "set and has" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 100, 0.01);
    defer sbf.deinit();

    try testing.expectEqual(false, sbf.has("test"));
    try sbf.set("test");
    try testing.expect(sbf.has("test"));
}

test "multiple items" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 100, 0.01);
    defer sbf.deinit();

    try sbf.set("apple");
    try sbf.set("banana");
    try sbf.set("cherry");

    try testing.expect(sbf.has("apple"));
    try testing.expect(sbf.has("banana"));
    try testing.expect(sbf.has("cherry"));
    try testing.expectEqual(false, sbf.has("grape"));
}

test "scaling behavior" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 5, 0.01);
    defer sbf.deinit();

    // Set enough items to trigger scaling
    for (0..20) |i| {
        var buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item{}", .{i});
        try sbf.set(item);
    }

    // Should have created setitional filters
    try testing.expect(sbf.filterCount() > 1);
    try testing.expectEqual(@as(u64, 20), sbf.estimatedSize());
}

test "estimated size tracking" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 100, 0.01);
    defer sbf.deinit();

    try testing.expectEqual(@as(u64, 0), sbf.estimatedSize());

    try sbf.set("test2");
    try testing.expectEqual(@as(u64, 1), sbf.estimatedSize());

    try sbf.set("test2");
    try testing.expectEqual(@as(u64, 2), sbf.estimatedSize());
}

test "false positive rate calculation" {
    var sbf = try ScalableBloomFilter.initDefault(testing.allocator, 10, 0.01);
    defer sbf.deinit();

    const initial_fp = sbf.currentFpRate();
    try testing.expectEqual(0.01, initial_fp);

    // Set items to trigger scaling
    for (0..15) |i| {
        var buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item{}", .{i});
        try sbf.set(item);
    }

    // FP rate should still be reasonable
    const current_fp = sbf.currentFpRate();
    try testing.expect(current_fp <= 0.02); // Should be close to target
}
