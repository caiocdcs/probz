const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Values in [0, 2^16); k = 100 gives rank error <= 16/100 * n, <= 300 nodes.
    var qd = try probz.QDigest.init(allocator, .{ .log_universe = 16, .k = 100 });
    defer qd.deinit(allocator);

    // Response sizes in bytes, mostly small with a long tail.
    var rng = std.Random.DefaultPrng.init(9);
    for (0..50_000) |_| {
        const u = rng.random().intRangeLessThan(u64, 0, 256);
        try qd.add(allocator, u * u);
    }

    std.debug.print("{d} values in {d} nodes (error bound {d:.2})\n", .{ qd.count(), qd.nodeCount(), qd.errorBound() });
    for ([_]f64{ 0.25, 0.5, 0.9, 0.99 }) |q| {
        std.debug.print("  q={d}: {d}\n", .{ q, try qd.quantile(q) });
    }
    std.debug.print("  values <= 10000 (lower bound): {d}\n", .{qd.rank(10_000)});

    // Digests with the same universe and k merge exactly by bucket.
    var other = try probz.QDigest.init(allocator, .{ .log_universe = 16, .k = 100 });
    defer other.deinit(allocator);
    for (0..10_000) |_| try other.add(allocator, 60_000);
    try qd.merge(allocator, other);
    std.debug.print("after merge: q=0.99 -> {d}\n", .{try qd.quantile(0.99)});
}
