pub const BloomFilter = bloom_filter.BloomFilter;

const std = @import("std");
const bloom_filter = @import("bloom_filter.zig");

test {
    std.testing.refAllDecls(@This());
}
