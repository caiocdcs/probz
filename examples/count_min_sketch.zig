const std = @import("std");
const CountMinSketch = @import("probz").CountMinSketch;
const DefaultCountMinSketch = @import("probz").DefaultCountMinSketch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize with error bounds:
    // epsilon = 0.01 (additive error about 1% of total count)
    // delta   = 0.01 (1% probability of exceeding the error bound)
    var cms = try DefaultCountMinSketch.initWithError(allocator, 0.01, 0.01);
    defer cms.deinit();

    std.debug.print("Initialized Count-Min Sketch (width={}, depth={})\n", .{ cms.width, cms.depth });

    // Increment some items
    try cms.set("apple"); // +1
    try cms.set("apple"); // +1
    try cms.setCount("banana", 3); // +3
    try cms.set("cherry"); // +1

    // Estimates (are >= true counts due to overestimation)
    const apple_count = cms.estimate("apple"); // >= 2
    const banana_count = cms.estimate("banana"); // >= 3
    const cherry_count = cms.estimate("cherry"); // >= 1
    const grape_count = cms.estimate("grape"); // 0 (not seen)

    std.debug.print("apple  ~ {}\n", .{apple_count});
    std.debug.print("banana ~ {}\n", .{banana_count});
    std.debug.print("cherry ~ {}\n", .{cherry_count});
    std.debug.print("grape  ~ {}\n", .{grape_count});

    // Initialize with explicit dimensions (width, depth)
    // width controls accuracy (columns), depth controls confidence (rows)
    var cms2 = try DefaultCountMinSketch.init(allocator, @intCast(cms.width), cms.depth);
    defer cms2.deinit();

    try cms2.setCount("banana", 2);
    try cms2.setCount("dragonfruit", 4);

    // Merge cms2 into cms (requires same width and depth)
    try cms.merge(&cms2);

    std.debug.print("\nAfter merge:\n", .{});
    std.debug.print("banana ~ {}\n", .{cms.estimate("banana")}); // >= 3 + 2
    std.debug.print("dragonfruit ~ {}\n", .{cms.estimate("dragonfruit")}); // >= 4
}
