//! MinHash LSH: approximate nearest neighbours under Jaccard similarity.
//! See SPEC.md §5.11.
//!
//! A set of tokens is summarized by a MinHash signature of n values: for
//! each of n random hash functions h_i, the minimum h_i over the set's
//! tokens. Two signatures agree in position i with probability equal to
//! the Jaccard similarity J(A, B) = |A ∩ B| / |A ∪ B| (Broder), so the
//! fraction of agreeing positions estimates J.
//!
//! Banding: the signature is cut into b bands of r rows (n = b·r). Items
//! whose signatures agree on every row of at least one band become
//! candidates. A pair with similarity s is a candidate with probability
//! 1 − (1 − s^r)^b, an S-curve that rises steeply around s ≈ (1/b)^(1/r).
//!
//! Hash functions: h_i(x) = (a_i · x + b_i) mod p with p = 2^61 − 1 and
//! x = XxHash64(token) mod p. The coefficients come from SplitMix64(seed),
//! so indexes built with the same seed and parameters are comparable
//! and can be rebuilt in any language.
//!
//! # References
//!
//! - Andrei Z. Broder, "On the Resemblance and Containment of Documents",
//!   Compression and Complexity of SEQUENCES 1997, pp. 21–29.
//!   https://doi.org/10.1109/SEQUEN.1997.666900
//! - Jure Leskovec, Anand Rajaraman, Jeffrey D. Ullman, "Mining of Massive
//!   Datasets", Chapter 3 "Finding Similar Items" (minhashing, banding).
//!   http://www.mmds.org/

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("hash.zig");
const serde = @import("serde.zig");

/// Mersenne prime 2^61 − 1.
pub const prime: u64 = (1 << 61) - 1;

/// A candidate returned by `query`. `id` points into the index and stays
/// valid until the index is modified or freed.
pub const Candidate = struct {
    id: []const u8,
    /// Estimated Jaccard similarity (fraction of agreeing signature values).
    similarity: f64,
};

pub const MinHashLSH = struct {
    bands: u32,
    rows: u32,
    seed: u64,
    /// a_i, b_i for i in [0, n).
    coeffs: []Coeff,
    items: std.ArrayList(Item),
    by_id: std.StringHashMapUnmanaged(u32),
    /// One map per band: band hash → item indexes.
    buckets: []std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)),

    pub const Coeff = struct { a: u64, b: u64 };

    const Item = struct {
        id: []u8,
        signature: []u64,
    };

    pub const Options = struct {
        bands: u32,
        rows: u32,
        seed: u64 = 0,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const AddError = error{ DuplicateId, InvalidSignature } || Allocator.Error;

    pub fn init(allocator: Allocator, options: Options) InitError!MinHashLSH {
        if (options.bands == 0 or options.rows == 0) return error.InvalidParameters;
        const n = math.mul(u32, options.bands, options.rows) catch return error.InvalidParameters;

        const coeffs = try allocator.alloc(Coeff, n);
        errdefer allocator.free(coeffs);
        var g = hashing.SplitMix64.init(options.seed);
        for (coeffs) |*c| {
            c.a = 1 + g.below(prime - 1);
            c.b = g.below(prime);
        }
        const buckets = try allocator.alloc(std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)), options.bands);
        @memset(buckets, .empty);
        return .{
            .bands = options.bands,
            .rows = options.rows,
            .seed = options.seed,
            .coeffs = coeffs,
            .items = .empty,
            .by_id = .empty,
            .buckets = buckets,
        };
    }

    /// Choose (b, r) with b·r = num_hashes so that (1/b)^(1/r) is closest
    /// to `threshold`; ties go to the larger b (better recall).
    pub fn initWithThreshold(allocator: Allocator, threshold: f64, num_hashes: u32, seed: u64) InitError!MinHashLSH {
        const p = try paramsForThreshold(threshold, num_hashes);
        return init(allocator, .{ .bands = p.bands, .rows = p.rows, .seed = seed });
    }

    pub fn paramsForThreshold(threshold: f64, num_hashes: u32) error{InvalidParameters}!struct { bands: u32, rows: u32 } {
        if (!(threshold > 0 and threshold < 1) or num_hashes == 0) return error.InvalidParameters;
        var best_b: u32 = 1;
        var best_diff = math.inf(f64);
        var b: u32 = 1;
        while (b <= num_hashes) : (b += 1) {
            if (num_hashes % b != 0) continue;
            const r = num_hashes / b;
            const t = math.pow(f64, 1.0 / @as(f64, @floatFromInt(b)), 1.0 / @as(f64, @floatFromInt(r)));
            const diff = @abs(t - threshold);
            if (diff <= best_diff) {
                best_diff = diff;
                best_b = b;
            }
        }
        return .{ .bands = best_b, .rows = num_hashes / best_b };
    }

    pub fn deinit(self: *MinHashLSH, allocator: Allocator) void {
        for (self.items.items) |it| {
            allocator.free(it.id);
            allocator.free(it.signature);
        }
        self.items.deinit(allocator);
        self.by_id.deinit(allocator);
        for (self.buckets) |*band| {
            var it = band.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            band.deinit(allocator);
        }
        allocator.free(self.buckets);
        allocator.free(self.coeffs);
        self.* = undefined;
    }

    pub fn numHashes(self: MinHashLSH) u32 {
        return self.bands * self.rows;
    }

    /// Probability that a pair with Jaccard similarity s becomes a
    /// candidate: 1 − (1 − s^r)^b.
    pub fn candidateProbability(self: MinHashLSH, s: f64) f64 {
        return 1 - math.pow(f64, 1 - math.pow(f64, s, @floatFromInt(self.rows)), @floatFromInt(self.bands));
    }

    /// Compute a MinHash signature into `out` (length `numHashes()`).
    /// An empty token set gives all values equal to p (never a valid hash).
    pub fn signatureInto(self: MinHashLSH, tokens: []const []const u8, out: []u64) void {
        std.debug.assert(out.len == self.coeffs.len);
        @memset(out, prime);
        for (tokens) |token| {
            const x = hashing.hashBytes(token) % prime;
            for (self.coeffs, out) |c, *m| m.* = @min(m.*, permute(c, x));
        }
    }

    pub fn signature(self: MinHashLSH, allocator: Allocator, tokens: []const []const u8) Allocator.Error![]u64 {
        const out = try allocator.alloc(u64, self.coeffs.len);
        self.signatureInto(tokens, out);
        return out;
    }

    /// (a·x + b) mod (2^61 − 1), with x < p.
    pub fn permute(c: Coeff, x: u64) u64 {
        const prod = @as(u128, c.a) * x + c.b;
        return mod61(prod);
    }

    fn mod61(v: u128) u64 {
        // v = hi·2^61 + lo ≡ hi + lo (mod 2^61 − 1)
        var r: u128 = (v & prime) + (v >> 61);
        r = (r & prime) + (r >> 61);
        const out: u64 = @intCast(r);
        return if (out >= prime) out - prime else out;
    }

    /// Hash of band `band`: XxHash64 of its r signature values as
    /// little-endian u64s.
    pub fn bandHash(self: MinHashLSH, sig: []const u64, band: u32) u64 {
        var h = std.hash.XxHash64.init(hashing.seed);
        const start = band * self.rows;
        for (sig[start..][0..self.rows]) |v| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, v, .little);
            h.update(&buf);
        }
        return h.final();
    }

    /// Index an item. `id` must be unique; it and the signature are copied.
    pub fn add(self: *MinHashLSH, allocator: Allocator, id: []const u8, tokens: []const []const u8) AddError!void {
        const sig = try self.signature(allocator, tokens);
        defer allocator.free(sig);
        return self.addSignature(allocator, id, sig);
    }

    pub fn addSignature(self: *MinHashLSH, allocator: Allocator, id: []const u8, sig: []const u64) AddError!void {
        if (sig.len != self.coeffs.len) return error.InvalidSignature;
        if (self.by_id.contains(id)) return error.DuplicateId;

        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_sig = try allocator.dupe(u64, sig);
        errdefer allocator.free(owned_sig);
        const index: u32 = @intCast(self.items.items.len);

        try self.items.ensureUnusedCapacity(allocator, 1);
        try self.by_id.ensureUnusedCapacity(allocator, 1);
        // Phase 1 (may fail): make room in every band. A failure here can
        // only leave empty bucket lists behind, which queries ignore.
        for (self.buckets, 0..) |*band, b| {
            const gop = try band.getOrPut(allocator, self.bandHash(sig, @intCast(b)));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.ensureUnusedCapacity(allocator, 1);
        }
        // Phase 2 (cannot fail): publish the item in every band.
        for (self.buckets, 0..) |*band, b| {
            band.getPtr(self.bandHash(sig, @intCast(b))).?.appendAssumeCapacity(index);
        }
        self.items.appendAssumeCapacity(.{ .id = owned_id, .signature = owned_sig });
        self.by_id.putAssumeCapacity(owned_id, index);
    }

    /// Items sharing at least one band with `tokens`, with estimated
    /// similarity, sorted by similarity descending then id ascending.
    /// The caller frees the returned slice.
    pub fn query(self: MinHashLSH, allocator: Allocator, tokens: []const []const u8) Allocator.Error![]Candidate {
        const sig = try self.signature(allocator, tokens);
        defer allocator.free(sig);
        return self.querySignature(allocator, sig);
    }

    pub fn querySignature(self: MinHashLSH, allocator: Allocator, sig: []const u64) Allocator.Error![]Candidate {
        std.debug.assert(sig.len == self.coeffs.len);
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(allocator);
        var out: std.ArrayList(Candidate) = .empty;
        errdefer out.deinit(allocator);
        for (self.buckets, 0..) |band, b| {
            const list = band.get(self.bandHash(sig, @intCast(b))) orelse continue;
            for (list.items) |i| {
                const gop = try seen.getOrPut(allocator, i);
                if (gop.found_existing) continue;
                const item = self.items.items[i];
                try out.append(allocator, .{ .id = item.id, .similarity = estimateSimilarity(sig, item.signature) });
            }
        }
        std.mem.sort(Candidate, out.items, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                if (a.similarity != b.similarity) return a.similarity > b.similarity;
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lessThan);
        return out.toOwnedSlice(allocator);
    }

    /// Estimated Jaccard similarity of two indexed items.
    pub fn similarity(self: MinHashLSH, id1: []const u8, id2: []const u8) error{ItemNotFound}!f64 {
        const a = self.by_id.get(id1) orelse return error.ItemNotFound;
        const b = self.by_id.get(id2) orelse return error.ItemNotFound;
        return estimateSimilarity(self.items.items[a].signature, self.items.items[b].signature);
    }

    pub fn len(self: MinHashLSH) usize {
        return self.items.items.len;
    }

    /// Body (tag 11): u32 b, u32 r, u64 seed, u32 item count, then per item
    /// in insertion order: bytes id, b·r × u64 signature. Bands are rebuilt.
    pub fn serialize(self: MinHashLSH, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .minhash_lsh);
        try serde.writeInt(w, u32, self.bands);
        try serde.writeInt(w, u32, self.rows);
        try serde.writeInt(w, u64, self.seed);
        try serde.writeInt(w, u32, @intCast(self.items.items.len));
        for (self.items.items) |it| {
            try serde.writeBytes(w, it.id);
            try serde.writeIntSlice(w, u64, it.signature);
        }
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!MinHashLSH {
        try serde.readHeader(r, .minhash_lsh);
        const bands = try serde.readInt(r, u32);
        const rows = try serde.readInt(r, u32);
        const seed = try serde.readInt(r, u64);
        var self = init(allocator, .{ .bands = bands, .rows = rows, .seed = seed }) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        const n = try serde.readInt(r, u32);
        const sig = try allocator.alloc(u64, self.coeffs.len);
        defer allocator.free(sig);
        for (0..n) |_| {
            const id = try serde.readBytes(r, allocator);
            defer allocator.free(id);
            try serde.readIntSlice(r, u64, sig);
            for (sig) |v| if (v > prime) return error.InvalidData;
            self.addSignature(allocator, id, sig) catch |err| return switch (err) {
                error.DuplicateId, error.InvalidSignature => error.InvalidData,
                error.OutOfMemory => error.OutOfMemory,
            };
        }
        return self;
    }
};

/// Fraction of positions where two signatures agree.
pub fn estimateSimilarity(a: []const u64, b: []const u64) f64 {
    std.debug.assert(a.len == b.len);
    var same: usize = 0;
    for (a, b) |x, y| same += @intFromBool(x == y);
    return @as(f64, @floatFromInt(same)) / @as(f64, @floatFromInt(a.len));
}

const testing = std.testing;

test "init validates parameters" {
    try testing.expectError(error.InvalidParameters, MinHashLSH.init(testing.allocator, .{ .bands = 0, .rows = 4 }));
    try testing.expectError(error.InvalidParameters, MinHashLSH.init(testing.allocator, .{ .bands = 4, .rows = 0 }));
    try testing.expectError(error.InvalidParameters, MinHashLSH.paramsForThreshold(0, 64));
    try testing.expectError(error.InvalidParameters, MinHashLSH.paramsForThreshold(0.5, 0));
}

test "params for threshold" {
    // 128 = 16 · 8: (1/16)^(1/8) ≈ 0.707.
    const p = try MinHashLSH.paramsForThreshold(0.7, 128);
    try testing.expectEqual(@as(u32, 16), p.bands);
    try testing.expectEqual(@as(u32, 8), p.rows);
}

test "mod 2^61 - 1 arithmetic" {
    const c: MinHashLSH.Coeff = .{ .a = prime - 1, .b = prime - 1 };
    // (p−1)(p−1) + (p−1) = (p−1)·p ≡ 0
    try testing.expectEqual(@as(u64, 0), MinHashLSH.permute(c, prime - 1));
    try testing.expectEqual(@as(u64, 5), MinHashLSH.permute(.{ .a = 2, .b = 1 }, 2));
    try testing.expectEqual(@as(u64, 0), MinHashLSH.permute(.{ .a = 1, .b = 1 }, prime - 1)); // p mod p
}

fn tokenSet(allocator: Allocator, from: usize, to: usize) ![][]const u8 {
    const out = try allocator.alloc([]const u8, to - from);
    for (out, from..) |*t, i| t.* = try std.fmt.allocPrint(allocator, "tok-{d}", .{i});
    return out;
}

test "estimated similarity is close to the true Jaccard similarity" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lsh = try MinHashLSH.init(testing.allocator, .{ .bands = 32, .rows = 8, .seed = 1 }); // 256 hashes
    defer lsh.deinit(testing.allocator);

    // A = [0, 1000), B = [o, o + 1000): J = (1000 − o) / (1000 + o).
    const a = try tokenSet(arena, 0, 1000);
    try lsh.add(testing.allocator, "a", a);
    for ([_]usize{ 0, 100, 250, 500, 800, 1000 }, 0..) |o, i| {
        const b = try tokenSet(arena, o, o + 1000);
        const id = try std.fmt.allocPrint(arena, "b{d}", .{i});
        try lsh.add(testing.allocator, id, b);
        const truth = @as(f64, @floatFromInt(1000 - o)) / @as(f64, @floatFromInt(1000 + o));
        // Standard deviation of the estimate is ≤ 1/(2·√256) ≈ 0.031; allow 3σ.
        try testing.expect(@abs(try lsh.similarity("a", id) - truth) <= 0.1);
    }
}

test "query finds similar items and not dissimilar ones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lsh = try MinHashLSH.initWithThreshold(testing.allocator, 0.5, 128, 7);
    defer lsh.deinit(testing.allocator);
    try lsh.add(testing.allocator, "near", try tokenSet(arena, 0, 100)); // J = 90/110 ≈ 0.82
    try lsh.add(testing.allocator, "far", try tokenSet(arena, 95, 195)); // J = 5/195 ≈ 0.03
    try testing.expectError(error.DuplicateId, lsh.add(testing.allocator, "near", &.{"x"}));

    const results = try lsh.query(testing.allocator, try tokenSet(arena, 10, 100));
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("near", results[0].id);
}

test "bands are independent (no cross-band collisions)" {
    // With one map shared by all bands, two different bands holding the
    // same values would collide. Per-band maps prevent that.
    var lsh = try MinHashLSH.init(testing.allocator, .{ .bands = 2, .rows = 1 });
    defer lsh.deinit(testing.allocator);
    // Signatures [x, y] and [y, x]: bands 0 and 1 hash the same values.
    try lsh.addSignature(testing.allocator, "p", &.{ 10, 20 });
    const res = try lsh.querySignature(testing.allocator, &.{ 20, 10 });
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(usize, 0), res.len);
}

test "same seed gives comparable indexes; serialize round trip" {
    var a = try MinHashLSH.init(testing.allocator, .{ .bands = 4, .rows = 4, .seed = 99 });
    defer a.deinit(testing.allocator);
    var b = try MinHashLSH.init(testing.allocator, .{ .bands = 4, .rows = 4, .seed = 99 });
    defer b.deinit(testing.allocator);
    const tokens = [_][]const u8{ "x", "y", "z" };
    const sa = try a.signature(testing.allocator, &tokens);
    defer testing.allocator.free(sa);
    const sb = try b.signature(testing.allocator, &tokens);
    defer testing.allocator.free(sb);
    try testing.expectEqualSlices(u64, sa, sb);

    try a.add(testing.allocator, "doc", &tokens);
    const bytes = try serde.toOwnedBytes(testing.allocator, a);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try MinHashLSH.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    const res = try back.query(testing.allocator, &tokens);
    defer testing.allocator.free(res);
    try testing.expectEqualStrings("doc", res[0].id);
    try testing.expectEqual(@as(f64, 1), res[0].similarity);
}

test "a failed add leaves the index consistent" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var lsh = try MinHashLSH.init(alloc, .{ .bands = 3, .rows = 2 });
            defer lsh.deinit(alloc);
            try lsh.add(alloc, "a", &.{ "x", "y" });
            // If this add fails part-way, no band may reference a missing item.
            // Disjoint tokens: new bucket lists, so every band allocates.
            lsh.add(alloc, "b", &.{ "p", "q" }) catch |err| {
                for (lsh.buckets) |band| {
                    var it = band.valueIterator();
                    while (it.next()) |list| for (list.items) |i| try testing.expect(i < lsh.len());
                }
                return err;
            };
        }
    }.run, .{});
}
