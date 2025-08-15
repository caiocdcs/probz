const std = @import("std");
const BloomFilter = @import("probz").BloomFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a bloom filter expecting 1000 items with 1% false positive rate
    var bloom = try BloomFilter.init(allocator, 1000, 0.01);
    defer bloom.deinit();

    // Add some items to the filter
    try bloom.set("apple");
    try bloom.set("banana");

    const has_apple = bloom.has("apple"); // true
    const has_banana = bloom.has("banana"); // true
    const has_grape = bloom.has("grape"); // false

    std.debug.print("Has 'apple': {}\n", .{has_apple});
    std.debug.print("Has 'banana': {}\n", .{has_banana});
    std.debug.print("Has 'grape': {}\n", .{has_grape});

    const estimated_size = bloom.estimatedSize();
    std.debug.print("Estimated items in filter: {}\n", .{estimated_size});
}
