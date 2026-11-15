//! probz: probabilistic data structures for Zig.
//!
//! Every structure hashes keys with the canonical XxHash64 (`hash`),
//! serializes to a portable wire format (`serde`), and follows the
//! language-neutral specification in SPEC.md, so other implementations
//! can produce identical results.

// Membership filters
pub const BloomFilter = bloom_filter.BloomFilter;
pub const CountingBloomFilter = counting_bloom_filter.CountingBloomFilter;
pub const DefaultCountingBloomFilter = counting_bloom_filter.DefaultCountingBloomFilter;
pub const ScalableBloomFilter = scalable_bloom_filter.ScalableBloomFilter;
pub const CuckooFilter = cuckoo_filter.CuckooFilter;
pub const DefaultCuckooFilter = cuckoo_filter.DefaultCuckooFilter;
pub const QuotientFilter = quotient_filter.QuotientFilter;
pub const DefaultQuotientFilter = quotient_filter.DefaultQuotientFilter;

// Cardinality
pub const HyperLogLog = hyperloglog.HyperLogLog;

// Frequency and heavy hitters
pub const CountMinSketch = count_min_sketch.CountMinSketch;
pub const DefaultCountMinSketch = count_min_sketch.DefaultCountMinSketch;
pub const SpaceSaving = space_saving.SpaceSaving;
pub const TopKTracker = top_k_tracker.TopKTracker;
pub const TopKItem = top_k_tracker.TopKItem;

// Quantiles
pub const TDigest = tdigest.TDigest;
pub const QDigest = qdigest.QDigest;

// Similarity
pub const MinHashLSH = lsh.MinHashLSH;
pub const Candidate = lsh.Candidate;

/// Canonical hashing (XxHash64, double hashing, SplitMix64). SPEC.md §2.
pub const hash = @import("hash.zig");
/// Wire-format helpers. SPEC.md §3.
pub const serde = @import("serde.zig");

const bloom_filter = @import("filters/bloom_filter.zig");
const counting_bloom_filter = @import("filters/counting_bloom_filter.zig");
const scalable_bloom_filter = @import("filters/scalable_bloom_filter.zig");
const cuckoo_filter = @import("filters/cuckoo_filter.zig");
const quotient_filter = @import("filters/quotient_filter.zig");
const hyperloglog = @import("hyperloglog.zig");
const count_min_sketch = @import("count_min_sketch.zig");
const space_saving = @import("space_saving.zig");
const top_k_tracker = @import("top_k_tracker.zig");
const tdigest = @import("tdigest.zig");
const qdigest = @import("qdigest.zig");
const lsh = @import("lsh.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("filters/bit_array.zig");
}
