const std = @import("std");
const QuotientFilter = @import("probz").QuotientFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a quotient filter with 8 quotient bits (256 slots) and 8 remainder bits
    var qf = try QuotientFilter.init(allocator, 8, 8);
    defer qf.deinit();

    // Add some items to the filter
    try qf.set("apple");
    try qf.set("banana");
    try qf.set("cherry");

    const has_apple = qf.has("apple"); // true
    const has_banana = qf.has("banana"); // true
    const has_grape = qf.has("grape"); // false (or possibly true - false positive)

    std.debug.print("Has 'apple': {}\n", .{has_apple});
    std.debug.print("Has 'banana': {}\n", .{has_banana});
    std.debug.print("Has 'grape': {}\n", .{has_grape});

    const deleted_banana = qf.remove("banana"); // true
    std.debug.print("Deleted 'banana': {}\n", .{deleted_banana});

    const has_banana_after_delete = qf.has("banana"); // false
    std.debug.print("Has 'banana' after deletion: {}\n", .{has_banana_after_delete});

    std.debug.print("Filter has {} slots\n", .{qf.length});
}
