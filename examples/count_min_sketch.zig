const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Additive error <= 1% of the total count, with probability 99%.
    var cms = try probz.DefaultCountMinSketch.initWithError(allocator, 0.01, 0.01);
    defer cms.deinit(allocator);
    std.debug.print("width={d}, depth={d}\n", .{ cms.width, cms.depth });

    try cms.add("apple", 2);
    try cms.add("banana", 3);
    try cms.add("cherry", 1);

    // Estimates are never below the true counts.
    std.debug.print("apple  ~ {d}\n", .{cms.count("apple")});
    std.debug.print("banana ~ {d}\n", .{cms.count("banana")});
    std.debug.print("grape  ~ {d}\n", .{cms.count("grape")});
    std.debug.print("error bound now: {d:.2}\n", .{cms.errorBound()});

    // Sketches with the same dimensions merge into the sketch of both streams.
    var other = try probz.DefaultCountMinSketch.init(allocator, .{ .width = cms.width, .depth = cms.depth });
    defer other.deinit(allocator);
    try other.add("banana", 2);
    try other.add("dragonfruit", 4);
    try cms.merge(other);
    std.debug.print("after merge: banana ~ {d}, dragonfruit ~ {d}\n", .{ cms.count("banana"), cms.count("dragonfruit") });
}
