const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Each item's bits live in one 64-byte block, so every lookup reads
    // one cache line. Prefer it over BloomFilter when the filter is larger
    // than the CPU cache or lookups are mostly misses.
    const n = 100_000;
    var filter = try probz.BlockedBloomFilter.init(allocator, .{ .expected_items = n, .fp_rate = 0.01 });
    defer filter.deinit(allocator);

    var buf: [32]u8 = undefined;
    for (0..n) |i| filter.add(try std.fmt.bufPrint(&buf, "user-{d}", .{i}));

    std.debug.print("blocks: {d}, bits per item: {d:.2}, k: {d}\n", .{
        filter.blockCount(),
        @as(f64, @floatFromInt(filter.memoryBytes() * 8)) / n,
        filter.k,
    });
    std.debug.print("contains 'user-42': {}\n", .{filter.contains("user-42")});

    var fp: usize = 0;
    for (0..n) |i| fp += @intFromBool(filter.contains(try std.fmt.bufPrint(&buf, "other-{d}", .{i})));
    std.debug.print("false positives: {d:.2}% (expected {d:.2}%)\n", .{
        @as(f64, @floatFromInt(fp)) * 100 / n,
        filter.falsePositiveRate(n) * 100,
    });

    // Serialize and load back.
    const bytes = try probz.serde.toOwnedBytes(allocator, filter);
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var loaded = try probz.BlockedBloomFilter.deserialize(allocator, &reader);
    defer loaded.deinit(allocator);
    std.debug.print("serialized {d} bytes; loaded contains 'user-42': {}\n", .{ bytes.len, loaded.contains("user-42") });
}
