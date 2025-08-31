pub const BloomFilter = bloom_filter.BloomFilter;
pub const CountingBloomFilter = counting_bloom_filter.CountingBloomFilter;
pub const DefaultCountingBloomFilter = counting_bloom_filter.DefaultCountingBloomFilter;
pub const ScalableBloomFilter = scalable_bloom_filter.ScalableBloomFilter;
pub const QuotientFilter = quotient_filter.QuotientFilter;
pub const CuckooFilter = cuckoo_filter.CuckooFilter;
pub const DefaultCuckooFilter = cuckoo_filter.DefaultCuckooFilter;

pub const CountMinSketch = count_min_sketch.CountMinSketch;
pub const DefaultCountMinSketch = count_min_sketch.DefaultCountMinSketch;
pub const HyperLogLog = hyperloglog.HyperLogLog;

const bloom_filter = @import("filters/bloom_filter.zig");
const counting_bloom_filter = @import("filters/counting_bloom_filter.zig");
const scalable_bloom_filter = @import("filters/scalable_bloom_filter.zig");
const quotient_filter = @import("filters/quotient_filter.zig");
const cuckoo_filter = @import("filters/cuckoo_filter.zig");
const count_min_sketch = @import("filters/count_min_sketch.zig");
const hyperloglog = @import("hyperloglog.zig");

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
