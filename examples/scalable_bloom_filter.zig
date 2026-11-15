const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start small; stages are added as items arrive while the compound
    // false-positive rate stays below 1%.
    var sbf = try probz.ScalableBloomFilter.init(allocator, .{ .initial_capacity = 100, .fp_rate = 0.01 });
    defer sbf.deinit(allocator);

    var buf: [32]u8 = undefined;
    for (0..1000) |i| {
        _ = try sbf.add(allocator, try std.fmt.bufPrint(&buf, "item{d}", .{i}));
    }

    std.debug.print("contains 'item500': {}\n", .{sbf.contains("item500")});
    std.debug.print("contains 'item9999': {}\n", .{sbf.contains("item9999")});
    std.debug.print("stages: {d}, items: {d}\n", .{ sbf.stageCount(), sbf.count() });
    std.debug.print("false-positive bound: {d:.5}\n", .{sbf.fpRateBound()});
}
