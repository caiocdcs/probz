const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // p = 12: 4096 one-byte registers, standard error ~1.6%.
    var hll = try probz.HyperLogLog.init(allocator, .{ .precision = 12 });
    defer hll.deinit(allocator);

    var buf: [32]u8 = undefined;
    for (0..100_000) |i| hll.add(try std.fmt.bufPrint(&buf, "user-{d}", .{i % 50_000}));
    std.debug.print("distinct users (true 50000): {d:.0} (std error {d:.2}%)\n", .{ hll.cardinality(), hll.standardError() * 100 });

    // Union of two sketches: merge registers.
    var other = try probz.HyperLogLog.init(allocator, .{ .precision = 12 });
    defer other.deinit(allocator);
    for (40_000..60_000) |i| other.add(try std.fmt.bufPrint(&buf, "user-{d}", .{i}));
    try hll.merge(other);
    std.debug.print("after merge (true 60000): {d:.0}\n", .{hll.cardinality()});
}
