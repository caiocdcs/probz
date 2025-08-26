const std = @import("std");
const HyperLogLog = @import("probz").HyperLogLog;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a HyperLogLog with precision 10 (1024 buckets)
    var hll = try HyperLogLog.init(allocator, 10);
    defer hll.deinit();

    // Add some items to the estimator
    hll.add("apple");
    hll.add("banana");
    hll.add("cherry");

    const size1 = hll.estimatedSize();
    std.debug.print("Estimated size after 3 items: {d:.1}\n", .{size1});

    // Add more items
    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const item = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        hll.add(item);
    }

    const size2 = hll.estimatedSize();
    std.debug.print("Estimated size after 103 items: {d:.1}\n", .{size2});

    // Demonstrate merging
    var hll2 = try HyperLogLog.init(allocator, 10);
    defer hll2.deinit();

    hll2.add("orange");
    hll2.add("grape");

    const size_before_merge = hll.estimatedSize();
    try hll.merge(&hll2);
    const size_after_merge = hll.estimatedSize();

    std.debug.print("Size before merge: {d:.1}\n", .{size_before_merge});
    std.debug.print("Size after merge: {d:.1}\n", .{size_after_merge});
}
