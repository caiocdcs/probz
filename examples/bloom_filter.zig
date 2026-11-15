const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sized for 1000 items at a 1% false-positive rate.
    var bloom = try probz.BloomFilter.init(allocator, .{ .expected_items = 1000, .fp_rate = 0.01 });
    defer bloom.deinit(allocator);

    bloom.add("apple");
    bloom.add("banana");

    std.debug.print("bits: {d}, hashes: {d}\n", .{ bloom.bitCount(), bloom.k });
    std.debug.print("contains 'apple': {}\n", .{bloom.contains("apple")});
    std.debug.print("contains 'banana': {}\n", .{bloom.contains("banana")});
    std.debug.print("contains 'grape': {}\n", .{bloom.contains("grape")});
    std.debug.print("estimated items: {d:.1}\n", .{bloom.estimatedItems()});

    // Hash once, query by hash (useful across several structures).
    const h = probz.hash.hashBytes("apple");
    std.debug.print("containsHash(apple): {}\n", .{bloom.containsHash(h)});

    // Serialize and load back.
    const bytes = try probz.serde.toOwnedBytes(allocator, bloom);
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var loaded = try probz.BloomFilter.deserialize(allocator, &reader);
    defer loaded.deinit(allocator);
    std.debug.print("serialized {d} bytes; loaded contains 'apple': {}\n", .{ bytes.len, loaded.contains("apple") });
}
