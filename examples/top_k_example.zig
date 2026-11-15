const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Streaming heavy hitters: 3 counters over a stream of unknown items.
    var ss = try probz.SpaceSaving.init(allocator, .{ .capacity = 3 });
    defer ss.deinit(allocator);
    const stream = [_][]const u8{ "banana", "apple", "banana", "date", "banana", "cherry", "date", "apple", "banana", "fig", "date" };
    for (stream) |item| try ss.add(allocator, item, 1);

    const top = try ss.topK(allocator, 3);
    defer allocator.free(top);
    std.debug.print("Space-Saving top 3 (count, guaranteed lower bound):\n", .{});
    for (top, 1..) |it, i| std.debug.print("  {d}. {s}: {d} (>= {d})\n", .{ i, it.key, it.count, it.guaranteedCount() });

    // Ranking a known candidate list with a Count-Min sketch.
    var cms = try probz.DefaultCountMinSketch.init(allocator, .{ .width = 1024, .depth = 5 });
    defer cms.deinit(allocator);
    try cms.add("apple", 100);
    try cms.add("banana", 200);
    try cms.add("cherry", 50);
    try cms.add("date", 150);

    const tracker = probz.TopKTracker(probz.DefaultCountMinSketch);
    const candidates = [_][]const u8{ "apple", "banana", "cherry", "date", "fig" };
    const ranked = try tracker.topK(&cms, allocator, &candidates, 3);
    defer tracker.freeTopK(allocator, ranked);
    std.debug.print("Count-Min top 3 of candidates:\n", .{});
    for (ranked, 1..) |it, i| std.debug.print("  {d}. {s}: {d}\n", .{ i, it.item, it.frequency });
}
