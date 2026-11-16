//! Blocked Bloom filter: a Bloom filter whose k bits per item all fall in
//! one 512-bit block (one 64-byte cache line). See SPEC.md §5.12.
//!
//! A standard Bloom filter touches k random cache lines per operation.
//! Here every add or lookup touches one, and a lookup tests all k bits
//! with one branch-free mask check, so misses cost the same as hits. On
//! filters larger than the CPU cache this is several times faster (see
//! `zig build bench`).
//!
//! The cost is memory: blocks receive a Poisson-distributed number of
//! items, and overfull blocks raise the false-positive rate, so the filter
//! needs more bits per item than a standard one for the same rate (about
//! 3% more at p = 1%, 8% at 0.1%, growing at lower rates). Sizing uses the
//! blocked false-positive rate of Putze et al.:
//!
//!   FPR(λ, k) = Σ_j Poisson_λ(j) · (1 − (1 − 1/512)^(j·k))^k
//!
//! where λ is the average number of items per block. `init` picks the k in
//! [1, 16] that allows the largest λ with FPR(λ, k) ≤ p, then allocates
//! ⌈n / λ⌉ blocks.
//!
//! With h = H(item), the block is ⌊(h >> 32) · blocks / 2^32⌋ (Lemire's
//! multiply-shift range reduction), and bit i in the block is the top 9 bits
//! of (h mod 2^32) · s_i mod 2^32 (Dietzfelbinger et al. multiply-shift
//! hashing). The odd salts s_i come from SplitMix64 (SPEC.md §2.3).
//!
//! # References
//!
//! - Felix Putze, Peter Sanders, Johannes Singler, "Cache-, Hash- and
//!   Space-Efficient Bloom Filters", WEA 2007, LNCS 4525, pp. 108–121
//!   (blocked Bloom filters and their false-positive rate).
//!   https://doi.org/10.1007/978-3-540-72845-0_9
//!   Journal version: ACM JEA 14, 2009. https://doi.org/10.1145/1498698.1594230
//! - Martin Dietzfelbinger, Torben Hagerup, Jyrki Katajainen, Martti
//!   Penttonen, "A Reliable Randomized Algorithm for the Closest-Pair
//!   Problem", Journal of Algorithms 25(1):19–51, 1997 (multiply-shift
//!   hashing). https://doi.org/10.1006/jagm.1997.0873
//! - Daniel Lemire, "Fast Random Integer Generation in an Interval",
//!   ACM TOMACS 29(1), 2019 (multiply-shift range reduction).
//!   https://doi.org/10.1145/3230636

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("../hash.zig");
const serde = @import("../serde.zig");

/// One cache line: 512 bits.
pub const Block = [8]u64;
pub const block_bits = 512;
pub const max_k = 16;

/// s_i = (i-th SplitMix64 output from seed 0, truncated to 32 bits) | 1.
const salt_table: [max_k]u32 = blk: {
    var rng = hashing.SplitMix64.init(0);
    var s: [max_k]u32 = undefined;
    for (&s) |*x| x.* = @as(u32, @truncate(rng.next())) | 1;
    break :blk s;
};

pub const BlockedBloomFilter = struct {
    blocks: []align(64) Block,
    /// Bits set per item, in [1, 16].
    k: u32,

    pub const Options = struct {
        /// Number of distinct items the filter is sized for (n > 0).
        expected_items: u64,
        /// Target false-positive rate at `expected_items` (0 < p < 1).
        fp_rate: f64 = 0.01,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const MergeError = error{IncompatibleFilters};

    /// The 16 odd multipliers s_i (SPEC.md §5.12).
    pub const salts = salt_table;
    pub const Params = SizeParams;
    pub const optimalParams = optimalSize;

    pub fn init(allocator: Allocator, options: Options) InitError!BlockedBloomFilter {
        const params = try optimalSize(options.expected_items, options.fp_rate);
        return initExact(allocator, params.blocks, params.k);
    }

    /// Create a filter with exactly `block_count` blocks and `hash_count` bits per item.
    pub fn initExact(allocator: Allocator, block_count: u64, hash_count: u32) InitError!BlockedBloomFilter {
        if (block_count == 0 or block_count > 1 << 32 or hash_count == 0 or hash_count > max_k)
            return error.InvalidParameters;
        const n = math.cast(usize, block_count) orelse return error.OutOfMemory;
        const blocks = try allocator.alignedAlloc(Block, .@"64", n);
        @memset(blocks, @splat(0));
        return .{ .blocks = blocks, .k = hash_count };
    }

    pub fn deinit(self: *BlockedBloomFilter, allocator: Allocator) void {
        allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn clone(self: BlockedBloomFilter, allocator: Allocator) Allocator.Error!BlockedBloomFilter {
        const blocks = try allocator.alignedAlloc(Block, .@"64", self.blocks.len);
        @memcpy(blocks, self.blocks);
        return .{ .blocks = blocks, .k = self.k };
    }

    pub fn add(self: *BlockedBloomFilter, item: []const u8) void {
        self.addHash(hashing.hashBytes(item));
    }

    pub fn addHash(self: *BlockedBloomFilter, h: u64) void {
        const b = &self.blocks[self.blockIndex(h)];
        const x: u32 = @truncate(h);
        for (salt_table[0..self.k]) |s| {
            const pos = (x *% s) >> 23;
            b[pos >> 6] |= @as(u64, 1) << @intCast(pos & 63);
        }
    }

    /// True if the item may have been inserted; false means it definitely was not.
    pub fn contains(self: BlockedBloomFilter, item: []const u8) bool {
        return self.containsHash(hashing.hashBytes(item));
    }

    pub fn containsHash(self: BlockedBloomFilter, h: u64) bool {
        const b = &self.blocks[self.blockIndex(h)];
        const x: u32 = @truncate(h);
        // No early exit: every bit is in the same cache line, and a
        // data-dependent branch would mispredict on most misses.
        var all: u64 = 1;
        for (salt_table[0..self.k]) |s| {
            const pos = (x *% s) >> 23;
            all &= b[pos >> 6] >> @intCast(pos & 63);
        }
        return all & 1 != 0;
    }

    inline fn blockIndex(self: BlockedBloomFilter, h: u64) usize {
        return @intCast(((h >> 32) * @as(u64, self.blocks.len)) >> 32);
    }

    /// Expected false-positive rate after `n` distinct inserts.
    pub fn falsePositiveRate(self: BlockedBloomFilter, n: u64) f64 {
        const load = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(self.blocks.len));
        return blockedFpr(load, self.k);
    }

    /// Union. Both filters must have the same block count and k.
    pub fn merge(self: *BlockedBloomFilter, other: BlockedBloomFilter) MergeError!void {
        if (self.blocks.len != other.blocks.len or self.k != other.k) return error.IncompatibleFilters;
        const a: []u64 = @ptrCast(self.blocks);
        const b: []const u64 = @ptrCast(other.blocks);
        for (a, b) |*x, y| x.* |= y;
    }

    pub fn clear(self: *BlockedBloomFilter) void {
        @memset(self.blocks, @splat(0));
    }

    pub fn blockCount(self: BlockedBloomFilter) u64 {
        return self.blocks.len;
    }

    pub fn memoryBytes(self: BlockedBloomFilter) usize {
        return self.blocks.len * @sizeOf(Block);
    }

    /// Body (tag 12): u32 k, then a bit array (§3.1) of 512 · blocks bits.
    pub fn serialize(self: BlockedBloomFilter, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .blocked_bloom_filter);
        try serde.writeInt(w, u32, self.k);
        try serde.writeInt(w, u64, @as(u64, self.blocks.len) * block_bits);
        try serde.writeIntSlice(w, u64, @ptrCast(self.blocks));
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!BlockedBloomFilter {
        try serde.readHeader(r, .blocked_bloom_filter);
        const k = try serde.readInt(r, u32);
        const len = try serde.readInt(r, u64);
        if (len == 0 or len % block_bits != 0) return error.InvalidData;
        var self = initExact(allocator, len / block_bits, k) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        try serde.readIntSlice(r, u64, @ptrCast(self.blocks));
        return self;
    }
};

const SizeParams = struct { blocks: u64, k: u32 };

/// Choose k and the block count for n items at rate p: for each k in
/// [1, 16], the largest load λ (items per block) with FPR(λ, k) ≤ p, found
/// by 64 bisection steps on [0, 512]; keep the k with the largest λ (the
/// smallest k on ties); blocks = max(1, ⌈n / λ⌉).
fn optimalSize(expected_items: u64, fp_rate: f64) error{InvalidParameters}!SizeParams {
    if (expected_items == 0 or !(fp_rate > 0 and fp_rate < 1)) return error.InvalidParameters;
    var best: SizeParams = undefined;
    var best_load: f64 = 0;
    for (1..max_k + 1) |kk| {
        const k: u32 = @intCast(kk);
        var lo: f64 = 0;
        var hi: f64 = block_bits;
        if (blockedFpr(hi, k) <= fp_rate) {
            lo = hi;
        } else for (0..64) |_| {
            const mid = (lo + hi) / 2;
            if (blockedFpr(mid, k) <= fp_rate) lo = mid else hi = mid;
        }
        if (lo > best_load) {
            best_load = lo;
            best.k = k;
        }
    }
    if (best_load == 0) return error.InvalidParameters;
    const blocks = @ceil(@as(f64, @floatFromInt(expected_items)) / best_load);
    if (blocks > 1 << 32) return error.InvalidParameters;
    best.blocks = @max(1, @as(u64, @intFromFloat(blocks)));
    return best;
}

/// FPR(λ, k) = Σ_{j ≥ 1} Poisson_λ(j) · (1 − (1 − 1/512)^(j·k))^k, summed
/// for j up to λ + 12·√λ + 20 (the remaining tail is far below 1e-15).
fn blockedFpr(load: f64, k: u32) f64 {
    if (load <= 0) return 0;
    const j_max: usize = @intFromFloat(load + 12 * @sqrt(load) + 20);
    const q = math.pow(f64, 1.0 - 1.0 / @as(f64, block_bits), @floatFromInt(k));
    var pmf = @exp(-load);
    var qj: f64 = 1;
    var rate: f64 = 0;
    for (1..j_max + 1) |j| {
        pmf *= load / @as(f64, @floatFromInt(j));
        qj *= q;
        rate += pmf * math.pow(f64, 1 - qj, @floatFromInt(k));
    }
    return rate;
}

const testing = std.testing;

test "sizing" {
    const p = try optimalSize(1_000_000, 0.01);
    const bits_per_item = @as(f64, @floatFromInt(p.blocks * block_bits)) / 1e6;
    // Standard Bloom needs 9.59 bits/item at 1%; blocked needs a few % more.
    try testing.expect(bits_per_item > 9.59 and bits_per_item < 10.2);
    try testing.expect(p.k >= 6 and p.k <= 9);

    try testing.expectError(error.InvalidParameters, optimalSize(0, 0.01));
    try testing.expectError(error.InvalidParameters, optimalSize(10, 0));
    try testing.expectError(error.InvalidParameters, optimalSize(10, 1));
    try testing.expectError(error.InvalidParameters, BlockedBloomFilter.initExact(testing.allocator, 1, 17));
    try testing.expectEqual(@as(u64, 1), (try optimalSize(1, 0.5)).blocks);
}

test "no false negatives, measured FPR near target" {
    inline for (.{ 0.1, 0.01, 0.001 }) |p| {
        const n = 200_000;
        var f = try BlockedBloomFilter.init(testing.allocator, .{ .expected_items = n, .fp_rate = p });
        defer f.deinit(testing.allocator);
        for (0..n) |i| f.addHash(hashing.hashKey(@as(u64, i)));
        for (0..n) |i| try testing.expect(f.containsHash(hashing.hashKey(@as(u64, i))));
        var fp: usize = 0;
        const probes = 1_000_000;
        for (n..n + probes) |i| fp += @intFromBool(f.containsHash(hashing.hashKey(@as(u64, i))));
        const rate = @as(f64, @floatFromInt(fp)) / probes;
        try testing.expect(rate < p * 1.15);
        try testing.expect(@abs(f.falsePositiveRate(n) - p) < p * 0.01);
    }
}

test "add, contains, merge, clear" {
    var a = try BlockedBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer a.deinit(testing.allocator);
    var b = try BlockedBloomFilter.init(testing.allocator, .{ .expected_items = 100 });
    defer b.deinit(testing.allocator);
    try testing.expect(!a.contains("a"));
    a.add("a");
    b.add("b");
    try testing.expect(a.contains("a") and !a.contains("b"));
    try a.merge(b);
    try testing.expect(a.contains("a") and a.contains("b"));

    var c = try BlockedBloomFilter.init(testing.allocator, .{ .expected_items = 100_000 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatibleFilters, a.merge(c));

    var copy = try a.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    a.clear();
    try testing.expect(!a.contains("a") and copy.contains("a"));
}

test "blocks are cache-line aligned" {
    var f = try BlockedBloomFilter.initExact(testing.allocator, 3, 8);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(f.blocks.ptr) % 64);
}

test "serialize round trip and validation" {
    var f = try BlockedBloomFilter.initExact(testing.allocator, 2, 5);
    defer f.deinit(testing.allocator);
    f.add("x");
    const bytes = try serde.toOwnedBytes(testing.allocator, f);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 6 + 4 + 8 + 2 * 64), bytes.len);

    var r: std.Io.Reader = .fixed(bytes);
    var back = try BlockedBloomFilter.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(f.k, back.k);
    try testing.expect(back.contains("x"));

    // k out of range.
    var bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);
    bad[6] = 17;
    var r2: std.Io.Reader = .fixed(bad);
    try testing.expectError(error.InvalidData, BlockedBloomFilter.deserialize(testing.allocator, &r2));
}
