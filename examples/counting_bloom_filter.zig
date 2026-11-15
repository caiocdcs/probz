const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // u8 counters track up to 255 copies per cell; the default is u4 (15).
    var cbf = try probz.CountingBloomFilter(u8).init(allocator, .{ .expected_items = 100, .fp_rate = 0.01 });
    defer cbf.deinit(allocator);

    cbf.add("apple");
    cbf.add("apple");
    cbf.add("banana");

    std.debug.print("contains 'apple': {}, count: {d}\n", .{ cbf.contains("apple"), cbf.count("apple") });
    std.debug.print("contains 'banana': {}\n", .{cbf.contains("banana")});
    std.debug.print("contains 'grape': {}\n", .{cbf.contains("grape")});

    _ = cbf.remove("apple");
    std.debug.print("after one remove, contains 'apple': {}\n", .{cbf.contains("apple")});
    _ = cbf.remove("apple");
    std.debug.print("after two removes, contains 'apple': {}\n", .{cbf.contains("apple")});

    // remove returns false when the item is definitely absent.
    std.debug.print("remove 'grape' -> {}\n", .{cbf.remove("grape")});
}
