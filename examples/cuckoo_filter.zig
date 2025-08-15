const std = @import("std");
const CuckooFilter = @import("probz").CuckooFilter;

// Default cuckoo filter with 16-bit fingerprints and 4 slots per bucket
const DefaultCuckooFilter = @import("probz").DefaultCuckooFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a cuckoo filter with capacity for ~1000 items
    var cf = try DefaultCuckooFilter.init(allocator, 1000);
    defer cf.deinit();

    // Add some items to the filter
    try cf.set("apple");
    try cf.set("banana");
    try cf.set("cherry");

    const has_apple = cf.has("apple"); // true
    const has_banana = cf.has("banana"); // true
    const has_grape = cf.has("grape"); // false (or possibly true - false positive)

    std.debug.print("Has 'apple': {}\n", .{has_apple});
    std.debug.print("Has 'banana': {}\n", .{has_banana});
    std.debug.print("Has 'grape': {}\n", .{has_grape});

    // Cuckoo filters support deletion without false negatives
    const removed_banana = cf.remove("banana"); // true - item was removed
    std.debug.print("Removed 'banana': {}\n", .{removed_banana});

    const has_banana_after_remove = cf.has("banana"); // false
    std.debug.print("Has 'banana' after removal: {}\n", .{has_banana_after_remove});

    const item_count = cf.estimatedSize();
    std.debug.print("Items in filter: {}\n", .{item_count});
}
