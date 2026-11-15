const std = @import("std");
const probz = @import("probz");

const DefaultCountMinSketch = probz.DefaultCountMinSketch;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cms = try DefaultCountMinSketch.init(allocator, .{ .width = 1024, .depth = 5 });
    defer cms.deinit(allocator);

    try cms.add("apple", 100);
    try cms.add("banana", 200);
    try cms.add("cherry", 50);
    try cms.add("date", 150);
    try cms.add("elderberry", 75);

    const tracker = probz.TopKTracker(DefaultCountMinSketch);
    const candidates = [_][]const u8{ "apple", "banana", "cherry", "date", "elderberry", "fig" };

    const top3 = try tracker.topK(&cms, allocator, &candidates, 3);
    defer tracker.freeTopK(allocator, top3);

    std.debug.print("Top 3 most frequent items:\n", .{});
    for (top3, 0..) |item, i| {
        std.debug.print("{}. {s} (frequency: {})\n", .{ i + 1, item.item, item.frequency });
    }
}
