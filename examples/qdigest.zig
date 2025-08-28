const std = @import("std");
const QDigest = @import("probz").QDigest;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a Q-digest with compression factor 50 and universe size 1024
    var qd = try QDigest.init(allocator, 50, 1024);
    defer qd.deinit();

    // Add some values to the digest
    try qd.add(10);
    try qd.add(20);
    try qd.add(30);

    const size1 = qd.size();
    std.debug.print("Size after 3 items: {d}\n", .{size1});

    // Add more values (1 to 100)
    for (1..101) |i| {
        try qd.add(@intCast(i));
    }

    const size2 = qd.size();
    std.debug.print("Size after 103 items: {d}\n", .{size2});

    // Test quantile estimation
    const median = try qd.quantile(0.5);
    const q25 = try qd.quantile(0.25);
    const q75 = try qd.quantile(0.75);

    std.debug.print("25th percentile: {d}\n", .{q25});
    std.debug.print("50th percentile (median): {d}\n", .{median});
    std.debug.print("75th percentile: {d}\n", .{q75});

    // Test rank estimation
    const rank_50 = qd.rank(50);
    const rank_25 = qd.rank(25);
    const rank_75 = qd.rank(75);

    std.debug.print("Rank of 25: {d:.2}\n", .{rank_25});
    std.debug.print("Rank of 50: {d:.2}\n", .{rank_50});
    std.debug.print("Rank of 75: {d:.2}\n", .{rank_75});

    // Demonstrate merging
    var qd2 = try QDigest.init(allocator, 50, 1024);
    defer qd2.deinit();

    try qd2.add(200);
    try qd2.add(300);

    const size_before_merge = qd.size();
    try qd.merge(&qd2);
    const size_after_merge = qd.size();

    std.debug.print("Size before merge: {d}\n", .{size_before_merge});
    std.debug.print("Size after merge: {d}\n", .{size_after_merge});

    const new_median = try qd.quantile(0.5);
    std.debug.print("Median after merge: {d}\n", .{new_median});
}
