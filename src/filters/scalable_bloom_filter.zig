//! Scalable Bloom filter: a chain of Bloom filters that grows as items
//! arrive while keeping the compound false-positive rate below a target.
//! See SPEC.md §5.3.
//!
//! Stage i has capacity n_i = n_0 · s^i and error rate P_i = P_0 · r^i,
//! with P_0 = P · (1 − r). The compound rate is therefore bounded by
//! Σ P_0 · r^i ≤ P_0 / (1 − r) = P (paper §3). A new stage is appended
//! when the newest stage has received n_i items. Items that the filter
//! already reports as present (true duplicates, or rare false positives)
//! are not inserted again, so duplicates do not consume capacity; `count`
//! can therefore be slightly lower than the number of distinct items.
//!
//! Deviation from the paper: each stage is a standard Bloom filter
//! (`BloomFilter`) sized for (n_i, P_i), rather than a partitioned
//! ("sliced") filter with a fill-ratio limit. Both meet P_i at n_i items.
//!
//! # References
//!
//! - Paulo Sérgio Almeida, Carlos Baquero, Nuno Preguiça, David Hutchison,
//!   "Scalable Bloom Filters", Information Processing Letters
//!   101(6):255–261, 2007. §3 (compound error bound P ≤ P_0 / (1 − r)),
//!   §4.1 (growth factor s = 2 or 4), §4.2 (tightening ratio r ≈ 0.8–0.9).
//!   https://doi.org/10.1016/j.ipl.2006.10.007
//!   (author PDF: https://gsd.di.uminho.pt/members/cbm/ps/dbloom.pdf)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const BloomFilter = @import("bloom_filter.zig").BloomFilter;
const BitArray = @import("bit_array.zig").BitArray;
const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

pub const ScalableBloomFilter = struct {
    options: Options,
    /// P_0 = P · (1 − r).
    first_fp_rate: f64,
    stages: std.ArrayList(Stage),

    pub const Stage = struct {
        filter: BloomFilter,
        /// Items inserted into this stage.
        count: u64,
        capacity: u64,
    };

    pub const Options = struct {
        /// Capacity n_0 of the first stage (> 0).
        initial_capacity: u64,
        /// Target compound false-positive rate P (0 < P < 1).
        fp_rate: f64 = 0.01,
        /// Capacity growth factor s per stage (≥ 2). The paper recommends 2 or 4.
        growth: u32 = 2,
        /// Error tightening ratio r (0 < r < 1). The paper recommends 0.8–0.9.
        tightening: f64 = 0.9,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;

    pub fn init(allocator: Allocator, options: Options) InitError!ScalableBloomFilter {
        if (options.initial_capacity == 0 or options.growth < 2 or
            !(options.fp_rate > 0 and options.fp_rate < 1) or
            !(options.tightening > 0 and options.tightening < 1))
            return error.InvalidParameters;

        var self: ScalableBloomFilter = .{
            .options = options,
            .first_fp_rate = options.fp_rate * (1.0 - options.tightening),
            .stages = .empty,
        };
        errdefer self.deinit(allocator);
        try self.addStage(allocator);
        return self;
    }

    pub fn deinit(self: *ScalableBloomFilter, allocator: Allocator) void {
        for (self.stages.items) |*s| s.filter.deinit(allocator);
        self.stages.deinit(allocator);
        self.* = undefined;
    }

    /// Insert an item. Returns false if the item was already reported as
    /// present (it is then not inserted again). Allocates when a new stage
    /// is needed.
    pub fn add(self: *ScalableBloomFilter, allocator: Allocator, item: []const u8) InitError!bool {
        return self.addHash(allocator, hashing.hashBytes(item));
    }

    pub fn addHash(self: *ScalableBloomFilter, allocator: Allocator, h: u64) InitError!bool {
        if (self.containsHash(h)) return false;
        var last = &self.stages.items[self.stages.items.len - 1];
        if (last.count >= last.capacity) {
            try self.addStage(allocator);
            last = &self.stages.items[self.stages.items.len - 1];
        }
        last.filter.addHash(h);
        last.count += 1;
        return true;
    }

    pub fn contains(self: ScalableBloomFilter, item: []const u8) bool {
        return self.containsHash(hashing.hashBytes(item));
    }

    pub fn containsHash(self: ScalableBloomFilter, h: u64) bool {
        // Newest stages hold the most items; check them first.
        var i = self.stages.items.len;
        while (i > 0) {
            i -= 1;
            if (self.stages.items[i].filter.containsHash(h)) return true;
        }
        return false;
    }

    /// Number of items inserted (excluding ones skipped as already present).
    pub fn count(self: ScalableBloomFilter) u64 {
        var n: u64 = 0;
        for (self.stages.items) |s| n += s.count;
        return n;
    }

    pub fn stageCount(self: ScalableBloomFilter) usize {
        return self.stages.items.len;
    }

    /// Upper bound on the current compound false-positive rate:
    /// Σ P_i over the existing stages. Always below `options.fp_rate`.
    pub fn fpRateBound(self: ScalableBloomFilter) f64 {
        var total: f64 = 0;
        for (0..self.stages.items.len) |i| total += self.stageFpRate(i);
        return total;
    }

    /// Drop all stages but the first and empty it.
    pub fn clear(self: *ScalableBloomFilter, allocator: Allocator) void {
        for (self.stages.items[1..]) |*s| s.filter.deinit(allocator);
        self.stages.shrinkRetainingCapacity(1);
        self.stages.items[0].filter.clear();
        self.stages.items[0].count = 0;
    }

    pub fn memoryBytes(self: ScalableBloomFilter) usize {
        var n: usize = 0;
        for (self.stages.items) |s| n += s.filter.memoryBytes();
        return n;
    }

    fn stageCapacity(self: ScalableBloomFilter, i: usize) u64 {
        const growth = math.powi(u64, self.options.growth, @intCast(i)) catch return math.maxInt(u64);
        return math.mul(u64, self.options.initial_capacity, growth) catch math.maxInt(u64);
    }

    fn stageFpRate(self: ScalableBloomFilter, i: usize) f64 {
        return self.first_fp_rate * math.pow(f64, self.options.tightening, @floatFromInt(i));
    }

    fn addStage(self: *ScalableBloomFilter, allocator: Allocator) InitError!void {
        const i = self.stages.items.len;
        const capacity = self.stageCapacity(i);
        var filter = try BloomFilter.init(allocator, .{ .expected_items = capacity, .fp_rate = self.stageFpRate(i) });
        errdefer filter.deinit(allocator);
        try self.stages.append(allocator, .{ .filter = filter, .count = 0, .capacity = capacity });
    }

    /// Body (tag 3): u64 n_0, f64 P, u32 s, f64 r, u32 stage count, then per
    /// stage: u64 count, u32 k, bit array (§3.1).
    pub fn serialize(self: ScalableBloomFilter, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .scalable_bloom_filter);
        try serde.writeInt(w, u64, self.options.initial_capacity);
        try serde.writeF64(w, self.options.fp_rate);
        try serde.writeInt(w, u32, self.options.growth);
        try serde.writeF64(w, self.options.tightening);
        try serde.writeInt(w, u32, @intCast(self.stages.items.len));
        for (self.stages.items) |s| {
            try serde.writeInt(w, u64, s.count);
            try serde.writeInt(w, u32, s.filter.k);
            try s.filter.bits.serialize(w);
        }
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!ScalableBloomFilter {
        try serde.readHeader(r, .scalable_bloom_filter);
        const options: Options = .{
            .initial_capacity = try serde.readInt(r, u64),
            .fp_rate = try serde.readF64(r),
            .growth = try serde.readInt(r, u32),
            .tightening = try serde.readF64(r),
        };
        var self = init(allocator, options) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);

        const stage_count = try serde.readInt(r, u32);
        if (stage_count == 0) return error.InvalidData;
        for (0..stage_count) |i| {
            if (i > 0) self.addStage(allocator) catch |err| return serde.fromInitError(err);
            const stage = &self.stages.items[i];
            stage.count = try serde.readInt(r, u64);
            const k = try serde.readInt(r, u32);
            var bits = try BitArray.deserialize(allocator, r);
            defer bits.deinit(allocator);
            // Stage layout is fully determined by the options; reject anything else.
            if (k != stage.filter.k or bits.len != stage.filter.bits.len or stage.count > stage.capacity)
                return error.InvalidData;
            @memcpy(stage.filter.bits.words, bits.words);
        }
        return self;
    }
};

const testing = std.testing;

test "init validates options" {
    try testing.expectError(error.InvalidParameters, ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 0 }));
    try testing.expectError(error.InvalidParameters, ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 10, .growth = 1 }));
    try testing.expectError(error.InvalidParameters, ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 10, .tightening = 1 }));
    try testing.expectError(error.InvalidParameters, ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 10, .fp_rate = 0 }));
}

test "add and contains" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 100 });
    defer sbf.deinit(testing.allocator);

    try testing.expect(!sbf.contains("apple"));
    try testing.expect(try sbf.add(testing.allocator, "apple"));
    try testing.expect(!try sbf.add(testing.allocator, "apple")); // duplicate
    try testing.expect(sbf.contains("apple"));
    try testing.expectEqual(@as(u64, 1), sbf.count());
}

test "grows by stages and keeps every item" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 100, .fp_rate = 0.01 });
    defer sbf.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..10_000) |i| _ = try sbf.add(testing.allocator, try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    // 100 + 200 + ... + 6400 = 12700 >= 10000, so 7 stages.
    try testing.expectEqual(@as(usize, 7), sbf.stageCount());
    for (0..10_000) |i| try testing.expect(sbf.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
    try testing.expect(sbf.fpRateBound() < 0.01);
}

test "compound false-positive rate stays under the target" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 1000, .fp_rate = 0.01 });
    defer sbf.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..50_000) |i| _ = try sbf.add(testing.allocator, try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    var fp: usize = 0;
    for (0..50_000) |i| {
        if (sbf.contains(try std.fmt.bufPrint(&buf, "absent-{d}", .{i}))) fp += 1;
    }
    try testing.expect(@as(f64, @floatFromInt(fp)) / 50_000 < 0.01);
}

test "clear" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 5 });
    defer sbf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..50) |i| _ = try sbf.add(testing.allocator, try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
    try testing.expect(sbf.stageCount() > 1);
    sbf.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sbf.stageCount());
    try testing.expectEqual(@as(u64, 0), sbf.count());
    try testing.expect(!sbf.contains("item-0"));
}

test "serialize round trip" {
    var sbf = try ScalableBloomFilter.init(testing.allocator, .{ .initial_capacity = 10 });
    defer sbf.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    for (0..40) |i| _ = try sbf.add(testing.allocator, try std.fmt.bufPrint(&buf, "item-{d}", .{i}));

    const bytes = try serde.toOwnedBytes(testing.allocator, sbf);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try ScalableBloomFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);

    try testing.expectEqual(sbf.stageCount(), back.stageCount());
    try testing.expectEqual(sbf.count(), back.count());
    for (0..40) |i| try testing.expect(back.contains(try std.fmt.bufPrint(&buf, "item-{d}", .{i})));
}
