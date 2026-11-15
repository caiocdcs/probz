const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2^10 slots with 8-bit remainders (false positives <= 1/256).
    var qf = try probz.DefaultQuotientFilter.init(allocator, .{ .q = 10 });
    defer qf.deinit(allocator);

    _ = try qf.add("hello");
    _ = try qf.add("world");
    std.debug.print("contains 'hello': {}\n", .{qf.contains("hello")});
    std.debug.print("contains 'zig': {}\n", .{qf.contains("zig")});

    _ = qf.remove("hello");
    std.debug.print("after remove, contains 'hello': {}\n", .{qf.contains("hello")});

    // Fingerprints can be listed in quotient order.
    var it = qf.iterator();
    while (it.next()) |e| std.debug.print("stored: quotient={d} remainder={d}\n", .{ e.quotient, e.remainder });

    std.debug.print("count: {d}, load: {d:.4}, fp bound: {d:.6}\n", .{ qf.count(), qf.loadFactor(), qf.fpRateBound() });
}
