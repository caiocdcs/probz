const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 16-bit fingerprints, 4 slots per bucket, room for 1000 items.
    var cf = try probz.DefaultCuckooFilter.init(allocator, .{ .capacity = 1000 });
    defer cf.deinit(allocator);

    try cf.add("apple");
    try cf.add("banana");

    std.debug.print("contains 'apple': {}\n", .{cf.contains("apple")});
    std.debug.print("contains 'grape': {}\n", .{cf.contains("grape")});

    _ = cf.remove("apple");
    std.debug.print("after remove, contains 'apple': {}\n", .{cf.contains("apple")});

    std.debug.print("items: {d}, load: {d:.4}, fp bound: {d:.6}\n", .{
        cf.count(),
        cf.loadFactor(),
        probz.DefaultCuckooFilter.fpRateBound(),
    });

    // add returns error.Full once the table cannot take more items;
    // items already stored are never lost.
    var small = try probz.CuckooFilter(u8, 4).init(allocator, .{ .capacity = 64 });
    defer small.deinit(allocator);
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    while (true) : (n += 1) {
        small.add(try std.fmt.bufPrint(&buf, "item-{d}", .{n})) catch break;
    }
    std.debug.print("small filter took {d} items before reporting Full\n", .{n});
}
