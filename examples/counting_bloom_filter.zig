const std = @import("std");
const CountingBloomFilter = @import("probz").CountingBloomFilter;

// Default counting bloom filter with u4 counters, up to 16 items
const DefaultCountingBloomFilter = @import("probz").DefaultCountingBloomFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create with custom counter size (u8 allows up to 255 occurrences)
    var cbf = try CountingBloomFilter(u8).init(allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.set("apple");
    try cbf.set("apple");
    try cbf.set("banana");

    const has_apple1 = cbf.has("apple"); // true
    const has_banana1 = cbf.has("banana"); // true
    const has_grape = cbf.has("grape"); // false

    std.debug.print("Initially:\n", .{});
    std.debug.print("Has 'apple': {}\n", .{has_apple1});
    std.debug.print("Has 'banana': {}\n", .{has_banana1});
    std.debug.print("Has 'grape': {}\n", .{has_grape});

    // Fast removal - caller ensures item exists
    _ = cbf.remove("apple");
    const still_has_apple = cbf.has("apple"); // true
    std.debug.print("After removing 'apple' once, still has 'apple': {}\n", .{still_has_apple});

    _ = cbf.remove("apple");
    const no_apple = cbf.has("apple"); // false
    std.debug.print("After removing 'apple' twice, has 'apple': {}\n", .{no_apple});

    try cbf.removeSafe("banana");
    const has_banana2 = cbf.has("banana"); // false
    std.debug.print("After safe removal of 'banana', has 'banana': {}\n", .{has_banana2});

    // removeSafe prevents underflow errors by checking if item exists first
    std.debug.print("Counting bloom filter example completed successfully\n", .{});
}
