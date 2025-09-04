const std = @import("std");
const TDigest = @import("probz").TDigest;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a T-digest with compression factor 100 (default)
    var td = try TDigest.initDefault(allocator);
    defer td.deinit();

    std.debug.print("T-Digest Example\n", .{});
    std.debug.print("================\n\n", .{});

    // Add some individual values
    try td.add(10.5);
    try td.add(20.0);
    try td.add(30.7);
    try td.add(15.2);

    std.debug.print("Added 4 values: 10.5, 20.0, 30.7, 15.2\n", .{});
    std.debug.print("Total count: {}\n\n", .{td.size()});

    // Add a range of values to demonstrate quantile estimation
    std.debug.print("Adding values 1-100...\n", .{});
    for (1..101) |i| {
        try td.add(@as(f64, @floatFromInt(i)));
    }

    std.debug.print("Total count after adding 1-100: {}\n\n", .{td.size()});

    // Test quantile estimation
    std.debug.print("Quantile Estimation:\n", .{});
    const percentiles = [_]f64{ 0.0, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99, 1.0 };
    for (percentiles) |p| {
        const q = try td.quantile(p);
        std.debug.print("  {d:>5.1}th percentile: {d:>6.2}\n", .{ p * 100, q });
    }

    // Test CDF estimation
    std.debug.print("\nCumulative Distribution Function:\n", .{});
    const test_values = [_]f64{ 10.0, 25.0, 50.0, 75.0, 90.0 };
    for (test_values) |value| {
        const cdf_value = td.cdf(value);
        std.debug.print("  CDF({d:>5.1}) = {d:>5.3} ({d:>5.1}%)\n", .{ value, cdf_value, cdf_value * 100 });
    }

    // Demonstrate weighted values
    std.debug.print("\nWeighted Values Example:\n", .{});
    var td_weighted = try TDigest.init(allocator, 50.0);
    defer td_weighted.deinit();

    try td_weighted.addWeighted(100.0, 10); // Value 100 with weight 10
    try td_weighted.addWeighted(200.0, 30); // Value 200 with weight 30
    try td_weighted.addWeighted(300.0, 20); // Value 300 with weight 20

    std.debug.print("Added weighted values: 100.0×10, 200.0×30, 300.0×20\n", .{});
    std.debug.print("Total weight: {}\n", .{td_weighted.size()});

    const weighted_median = try td_weighted.quantile(0.5);
    std.debug.print("Weighted median: {d:.2}\n", .{weighted_median});

    // Demonstrate merging
    std.debug.print("\nMerging T-Digests:\n", .{});
    var td1 = try TDigest.init(allocator, 100.0);
    defer td1.deinit();

    var td2 = try TDigest.init(allocator, 100.0);
    defer td2.deinit();

    // Add different ranges to each digest
    for (1..51) |i| {
        try td1.add(@as(f64, @floatFromInt(i)));
    }

    for (51..101) |i| {
        try td2.add(@as(f64, @floatFromInt(i)));
    }

    std.debug.print("Digest 1 size: {}, median: {d:.2}\n", .{ td1.size(), try td1.quantile(0.5) });
    std.debug.print("Digest 2 size: {}, median: {d:.2}\n", .{ td2.size(), try td2.quantile(0.5) });

    try td1.merge(&td2);
    std.debug.print("Merged digest size: {}, median: {d:.2}\n", .{ td1.size(), try td1.quantile(0.5) });

    // Demonstrate extreme quantile accuracy
    std.debug.print("\nExtreme Quantiles (T-digest strength):\n", .{});
    var td_extreme = try TDigest.init(allocator, 200.0); // Higher compression for better accuracy
    defer td_extreme.deinit();

    // Add values with more density at extremes
    for (0..100) |_| {
        try td_extreme.add(1.0); // Many values at 1.0
    }

    for (2..99) |i| {
        try td_extreme.add(@as(f64, @floatFromInt(i))); // Sparse middle values
    }

    for (0..100) |_| {
        try td_extreme.add(100.0); // Many values at 100.0
    }

    const extreme_percentiles = [_]f64{ 0.01, 0.05, 0.1, 0.9, 0.95, 0.99 };
    for (extreme_percentiles) |p| {
        const q = try td_extreme.quantile(p);
        std.debug.print("  {d:>5.2}th percentile: {d:>6.2}\n", .{ p * 100, q });
    }

    std.debug.print("\nT-digest provides excellent accuracy for extreme quantiles!\n", .{});
}
