const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // compression 100: at most 102 centroids, no allocation after init.
    var td = try probz.TDigest.init(allocator, .{ .compression = 100 });
    defer td.deinit(allocator);

    // Simulated request latencies in ms (exponential, mean 20).
    var rng = std.Random.DefaultPrng.init(1);
    for (0..100_000) |_| try td.add(rng.random().floatExp(f64) * 20);

    std.debug.print("latency quantiles over {d} requests:\n", .{td.count()});
    for ([_]f64{ 0.5, 0.9, 0.99, 0.999 }) |q| {
        std.debug.print("  p{d}: {d:.2} ms\n", .{ q * 100, try td.quantile(q) });
    }
    std.debug.print("  fraction <= 50 ms: {d:.4}\n", .{try td.cdf(50)});

    // Digests from different shards merge into one.
    var shard = try probz.TDigest.init(allocator, .{});
    defer shard.deinit(allocator);
    for (0..1000) |_| try shard.add(500 + rng.random().float(f64) * 100);
    try td.merge(shard);
    std.debug.print("after merging a slow shard: p99.9 = {d:.2} ms, max = {d:.2} ms\n", .{ try td.quantile(0.999), try td.quantile(1) });
}
