const std = @import("std");
const ScalableBloomFilter = @import("probz").ScalableBloomFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create with initial capacity 100, target 1% false positive rate
    var sbf = try ScalableBloomFilter.initDefault(allocator, 100, 0.01);
    defer sbf.deinit();

    // Add many items - filter automatically scales
    for (0..1000) |i| {
        var buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item{}", .{i});
        try sbf.set(item);
    }

    const has_item500 = sbf.has("item500"); // true
    const has_item9999 = sbf.has("item9999"); // false

    std.debug.print("Has 'item500': {}\n", .{has_item500});
    std.debug.print("Has 'item9999': {}\n", .{has_item9999});

    std.debug.print("Filters used: {}\n", .{sbf.filterCount()});
    std.debug.print("Items added: {}\n", .{sbf.estimatedSize()});
}
