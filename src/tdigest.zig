//! t-digest (merging variant): quantile and CDF estimates for a stream of
//! real values, most accurate near the tails. See SPEC.md §5.9.
//!
//! The digest is a sorted list of centroids (mean, weight). New values go
//! to a buffer; when it fills, buffer and centroids are sorted together and
//! merged left to right by Algorithm 1 of Dunning & Ertl. A cluster may
//! absorb the next element while k(q_right) − k(q_left) ≤ 1 (Eq. 4), with
//! the k₁ scale function (Eq. 3):
//!
//!   k₁(q) = δ / (2π) · asin(2q − 1),   k₁⁻¹(k) = (sin(2πk / δ) + 1) / 2
//!
//! k₁ makes clusters small near q = 0 and q = 1, which is what gives the
//! t-digest its accuracy at extreme quantiles. Two consecutive clusters
//! always span more than 1 in k, and k₁ spans δ/2 in total, so a merge
//! produces at most ⌈δ⌉ + 2 centroids. probz preallocates that, so `add`,
//! `quantile` and `cdf` never allocate.
//!
//! Interpolation (not fixed by the paper; specified in SPEC.md §5.9):
//! quantiles are piecewise linear through (0, min), each centroid's
//! (center of mass, mean), and (N, max). `cdf` is the inverse of that
//! function.
//!
//! # References
//!
//! - Ted Dunning, Otmar Ertl, "Computing Extremely Accurate Quantiles Using
//!   t-Digests", arXiv:1902.04023, 2019. Eq. 3 (k₁), Eq. 4 (size bound),
//!   Algorithm 1 (merging). https://arxiv.org/abs/1902.04023
//! - Reference implementation (MergingDigest): https://github.com/tdunning/t-digest

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const TDigest = struct {
    compression: f64,
    /// Sorted by (mean, weight), fully merged.
    centroids: std.ArrayList(Centroid),
    /// Unmerged points. Also used as scratch space during a merge.
    buffer: std.ArrayList(Centroid),
    buffer_limit: usize,
    max_centroids: usize,
    /// Total weight N (centroids + buffer).
    total: u64,
    min: f64,
    max: f64,

    pub const Centroid = struct {
        mean: f64,
        weight: u64,

        fn lessThan(_: void, a: Centroid, b: Centroid) bool {
            if (a.mean != b.mean) return a.mean < b.mean;
            return a.weight < b.weight;
        }
    };

    pub const Options = struct {
        /// δ in [10, 10000]. Larger is more accurate; at most ⌈δ⌉ + 2
        /// centroids are kept.
        compression: f64 = 100,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const AddError = error{ InvalidValue, Overflow };
    pub const QueryError = error{ EmptyDigest, InvalidParameters };

    pub fn init(allocator: Allocator, options: Options) InitError!TDigest {
        const delta = options.compression;
        if (!(delta >= 10 and delta <= 10_000)) return error.InvalidParameters;
        const max_centroids: usize = @as(usize, @intFromFloat(@ceil(delta))) + 2;
        const buffer_limit: usize = 5 * @as(usize, @intFromFloat(@ceil(delta)));

        var centroids = try std.ArrayList(Centroid).initCapacity(allocator, max_centroids);
        errdefer centroids.deinit(allocator);
        const buffer = try std.ArrayList(Centroid).initCapacity(allocator, buffer_limit + max_centroids);
        return .{
            .compression = delta,
            .centroids = centroids,
            .buffer = buffer,
            .buffer_limit = buffer_limit,
            .max_centroids = max_centroids,
            .total = 0,
            .min = math.inf(f64),
            .max = -math.inf(f64),
        };
    }

    pub fn deinit(self: *TDigest, allocator: Allocator) void {
        self.centroids.deinit(allocator);
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn add(self: *TDigest, value: f64) AddError!void {
        return self.addWeighted(value, 1);
    }

    /// Add `value` with integer weight. Rejects NaN and infinities.
    pub fn addWeighted(self: *TDigest, value: f64, weight: u64) AddError!void {
        if (!math.isFinite(value)) return error.InvalidValue;
        if (weight == 0) return;
        self.total = math.add(u64, self.total, weight) catch return error.Overflow;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.buffer.appendAssumeCapacity(.{ .mean = value, .weight = weight });
        if (self.buffer.items.len >= self.buffer_limit) self.flush();
    }

    /// Merge buffered points into the centroids (Algorithm 1).
    pub fn flush(self: *TDigest) void {
        if (self.buffer.items.len == 0) return;
        self.buffer.appendSliceAssumeCapacity(self.centroids.items);
        const xs = self.buffer.items;
        std.mem.sort(Centroid, xs, {}, Centroid.lessThan);

        const n: f64 = @floatFromInt(self.total);
        self.centroids.clearRetainingCapacity();
        var q0: f64 = 0;
        var q_limit = self.kInverse(self.k(q0) + 1);
        var sigma = xs[0];
        for (xs[1..]) |x| {
            const q = q0 + @as(f64, @floatFromInt(sigma.weight + x.weight)) / n;
            // The second condition only triggers if rounding ever broke the
            // ⌈δ⌉ + 2 bound; it keeps the preallocated capacity sufficient.
            if (q <= q_limit or self.centroids.items.len + 1 == self.max_centroids) {
                sigma = combine(sigma, x);
            } else {
                self.centroids.appendAssumeCapacity(sigma);
                q0 += @as(f64, @floatFromInt(sigma.weight)) / n;
                q_limit = self.kInverse(self.k(q0) + 1);
                sigma = x;
            }
        }
        self.centroids.appendAssumeCapacity(sigma);
        self.buffer.clearRetainingCapacity();
    }

    /// Weighted mean, computed as m₁ + (m₂ − m₁) · w₂ / (w₁ + w₂).
    fn combine(a: Centroid, b: Centroid) Centroid {
        const w = a.weight + b.weight;
        const ratio = @as(f64, @floatFromInt(b.weight)) / @as(f64, @floatFromInt(w));
        return .{ .mean = a.mean + (b.mean - a.mean) * ratio, .weight = w };
    }

    /// k₁(q) = δ / (2π) · asin(2q − 1)
    fn k(self: TDigest, q: f64) f64 {
        return self.compression / (2 * math.pi) * math.asin(2 * q - 1);
    }

    /// k₁⁻¹(k) = (sin(2πk / δ) + 1) / 2, clamped at k ≥ δ/4 to 1.
    fn kInverse(self: TDigest, kv: f64) f64 {
        if (kv >= self.compression / 4) return 1;
        return (@sin(2 * math.pi * kv / self.compression) + 1) / 2;
    }

    /// Estimated value at quantile q in [0, 1].
    pub fn quantile(self: *TDigest, q: f64) QueryError!f64 {
        if (!(q >= 0 and q <= 1)) return error.InvalidParameters;
        if (self.total == 0) return error.EmptyDigest;
        self.flush();
        const n: f64 = @floatFromInt(self.total);
        const t = q * n;
        if (t <= 0) return self.min;
        if (t >= n) return self.max;

        // Walk the knots (0, min), (center_i, mean_i), (N, max).
        var prev_t: f64 = 0;
        var prev_v: f64 = self.min;
        var cum: f64 = 0;
        for (self.centroids.items) |c| {
            const w: f64 = @floatFromInt(c.weight);
            const center = cum + w / 2;
            if (t <= center) return lerp(prev_t, prev_v, center, c.mean, t);
            prev_t = center;
            prev_v = c.mean;
            cum += w;
        }
        return lerp(prev_t, prev_v, n, self.max, t);
    }

    /// Estimated fraction of values ≤ x: the inverse of `quantile`'s
    /// piecewise-linear function. Where that function is flat at x, the
    /// midpoint of the flat range is returned.
    pub fn cdf(self: *TDigest, x: f64) QueryError!f64 {
        if (math.isNan(x)) return error.InvalidParameters;
        if (self.total == 0) return error.EmptyDigest;
        self.flush();
        if (x < self.min) return 0;
        if (x > self.max) return 1;
        const n: f64 = @floatFromInt(self.total);

        // t_lo = first t with f(t) ≥ x; t_hi = last t with f(t) ≤ x.
        var t_lo: ?f64 = null;
        var t_hi: f64 = 0;
        var it = self.knots();
        var a = it.next().?;
        if (a.v >= x) t_lo = a.t;
        while (it.next()) |b| {
            if (t_lo == null and b.v >= x) t_lo = if (b.v == a.v) a.t else inverseLerp(a, b, x);
            if (a.v <= x) t_hi = if (b.v <= x) b.t else inverseLerp(a, b, x);
            a = b;
        }
        return ((t_lo orelse n) + t_hi) / 2 / n;
    }

    const Knot = struct { t: f64, v: f64 };

    const KnotIterator = struct {
        digest: *const TDigest,
        i: usize = 0,
        cum: f64 = 0,
        done: bool = false,

        fn next(it: *KnotIterator) ?Knot {
            const d = it.digest;
            if (it.done) return null;
            if (it.i == 0 and it.cum == 0) {
                it.cum = -1; // marker: start knot emitted
                return .{ .t = 0, .v = d.min };
            }
            if (it.cum < 0) it.cum = 0;
            if (it.i < d.centroids.items.len) {
                const c = d.centroids.items[it.i];
                const w: f64 = @floatFromInt(c.weight);
                const knot: Knot = .{ .t = it.cum + w / 2, .v = c.mean };
                it.cum += w;
                it.i += 1;
                return knot;
            }
            it.done = true;
            return .{ .t = @floatFromInt(d.total), .v = d.max };
        }
    };

    fn knots(self: *const TDigest) KnotIterator {
        return .{ .digest = self };
    }

    fn lerp(t0: f64, v0: f64, t1: f64, v1: f64, t: f64) f64 {
        if (t1 <= t0) return v1;
        return v0 + (v1 - v0) * ((t - t0) / (t1 - t0));
    }

    fn inverseLerp(a: Knot, b: Knot, x: f64) f64 {
        if (b.v == a.v) return a.t;
        return a.t + (b.t - a.t) * ((x - a.v) / (b.v - a.v));
    }

    /// Add every centroid and buffered point of `other`. The result uses
    /// this digest's compression.
    pub fn merge(self: *TDigest, other: TDigest) AddError!void {
        for (other.centroids.items) |c| try self.addWeighted(c.mean, c.weight);
        for (other.buffer.items) |c| try self.addWeighted(c.mean, c.weight);
        // Centroid means lie inside [other.min, other.max]; keep the true extremes.
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
    }

    /// Total weight N.
    pub fn count(self: TDigest) u64 {
        return self.total;
    }

    pub fn clear(self: *TDigest) void {
        self.centroids.clearRetainingCapacity();
        self.buffer.clearRetainingCapacity();
        self.total = 0;
        self.min = math.inf(f64);
        self.max = -math.inf(f64);
    }

    /// Body (tag 9): f64 δ, u64 N, f64 min, f64 max, u32 centroid count,
    /// centroids, u32 buffer count, buffered points; each entry is
    /// (f64 mean, u64 weight). Empty digests write min = +inf, max = −inf.
    pub fn serialize(self: TDigest, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .tdigest);
        try serde.writeF64(w, self.compression);
        try serde.writeInt(w, u64, self.total);
        try serde.writeF64(w, self.min);
        try serde.writeF64(w, self.max);
        inline for (.{ self.centroids.items, self.buffer.items }) |list| {
            try serde.writeInt(w, u32, @intCast(list.len));
            for (list) |c| {
                try serde.writeF64(w, c.mean);
                try serde.writeInt(w, u64, c.weight);
            }
        }
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!TDigest {
        try serde.readHeader(r, .tdigest);
        var self = init(allocator, .{ .compression = try serde.readF64(r) }) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        self.total = try serde.readInt(r, u64);
        self.min = try serde.readF64(r);
        self.max = try serde.readF64(r);
        var sum: u64 = 0;
        inline for (.{ &self.centroids, &self.buffer }, .{ self.max_centroids, self.buffer_limit }) |list, cap| {
            const n = try serde.readInt(r, u32);
            if (n > cap) return error.InvalidData;
            for (0..n) |_| {
                const c: Centroid = .{ .mean = try serde.readF64(r), .weight = try serde.readInt(r, u64) };
                if (!math.isFinite(c.mean) or c.weight == 0) return error.InvalidData;
                sum = math.add(u64, sum, c.weight) catch return error.InvalidData;
                list.appendAssumeCapacity(c);
            }
        }
        if (sum != self.total) return error.InvalidData;
        if (!std.sort.isSorted(Centroid, self.centroids.items, {}, Centroid.lessThan)) return error.InvalidData;
        return self;
    }
};

const testing = std.testing;

test "init validates compression" {
    try testing.expectError(error.InvalidParameters, TDigest.init(testing.allocator, .{ .compression = 5 }));
    try testing.expectError(error.InvalidParameters, TDigest.init(testing.allocator, .{ .compression = 20_000 }));
}

test "empty and single value" {
    var td = try TDigest.init(testing.allocator, .{});
    defer td.deinit(testing.allocator);
    try testing.expectError(error.EmptyDigest, td.quantile(0.5));
    try testing.expectError(error.InvalidValue, td.add(math.nan(f64)));
    try td.add(42);
    try testing.expectEqual(@as(f64, 42), try td.quantile(0.5));
    try testing.expectEqual(@as(f64, 42), try td.quantile(0));
    try testing.expectEqual(@as(f64, 0.5), try td.cdf(42));
    try testing.expectError(error.InvalidParameters, td.quantile(1.5));
}

test "centroid count stays within ceil(delta) + 2" {
    var td = try TDigest.init(testing.allocator, .{ .compression = 50 });
    defer td.deinit(testing.allocator);
    var rng = std.Random.DefaultPrng.init(7);
    for (0..200_000) |_| try td.add(rng.random().floatNorm(f64));
    td.flush();
    try testing.expect(td.centroids.items.len <= 52);
    try testing.expect(td.centroids.items.len >= 25); // roughly δ/2 or more
}

/// Rank error |rank(estimate) / n − q| against exact sorted data.
fn rankError(sorted: []const f64, estimate: f64, q: f64) f64 {
    const below = std.sort.upperBound(f64, sorted, estimate, struct {
        fn order(ctx: f64, item: f64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.order);
    return @abs(@as(f64, @floatFromInt(below)) / @as(f64, @floatFromInt(sorted.len)) - q);
}

test "rank error within one k1 unit around q" {
    // The size bound k(q_right) − k(q_left) ≤ 1 limits every cluster to one
    // unit of k₁. The estimate for q should land within the q-range of one
    // k-unit centred on q: [k⁻¹(k(q) − ½), k⁻¹(k(q) + ½)].
    const n = 100_000;
    const delta = 100.0;
    const data = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(data);

    for (0..3) |dist| {
        var rng = std.Random.DefaultPrng.init(42);
        for (data) |*x| x.* = switch (dist) {
            0 => rng.random().floatExp(f64),
            1 => rng.random().float(f64),
            else => rng.random().floatNorm(f64),
        };
        var td = try TDigest.init(testing.allocator, .{ .compression = delta });
        defer td.deinit(testing.allocator);
        for (data) |x| try td.add(x);
        std.mem.sort(f64, data, {}, std.sort.asc(f64));

        for ([_]f64{ 0.0001, 0.001, 0.01, 0.1, 0.5, 0.9, 0.99, 0.999, 0.9999 }) |q| {
            const kq = td.k(q);
            const tol = td.kInverse(kq + 0.5) - td.kInverse(@max(kq - 0.5, -delta / 4));
            const est = try td.quantile(q);
            try testing.expect(rankError(data, est, q) <= tol);
            try testing.expect(@abs(try td.cdf(est) - q) <= tol);
        }
        try testing.expectEqual(data[0], try td.quantile(0));
        try testing.expectEqual(data[n - 1], try td.quantile(1));
    }
}

test "merge matches a single digest" {
    var a = try TDigest.init(testing.allocator, .{});
    defer a.deinit(testing.allocator);
    var b = try TDigest.init(testing.allocator, .{});
    defer b.deinit(testing.allocator);
    for (0..10_000) |i| {
        const x: f64 = @floatFromInt(i);
        if (i % 2 == 0) try a.add(x) else try b.add(x);
    }
    try a.merge(b);
    try testing.expectEqual(@as(u64, 10_000), a.count());
    const median = try a.quantile(0.5);
    try testing.expect(@abs(median - 5000) < 50);
    try testing.expectEqual(@as(f64, 0), try a.quantile(0));
    try testing.expectEqual(@as(f64, 9999), try a.quantile(1));
}

test "weighted values" {
    var td = try TDigest.init(testing.allocator, .{});
    defer td.deinit(testing.allocator);
    try td.addWeighted(10, 50);
    try td.addWeighted(20, 50);
    const m = try td.quantile(0.5);
    try testing.expect(m >= 10 and m <= 20);
    try testing.expectEqual(@as(u64, 100), td.count());
}

test "serialize round trip" {
    var td = try TDigest.init(testing.allocator, .{ .compression = 20 });
    defer td.deinit(testing.allocator);
    for (0..1000) |i| try td.add(@floatFromInt(i % 97));
    try td.add(3.5); // leave something in the buffer
    const bytes = try serde.toOwnedBytes(testing.allocator, td);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try TDigest.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    for ([_]f64{ 0, 0.1, 0.5, 0.9, 1 }) |q| try testing.expectEqual(try td.quantile(q), try back.quantile(q));
}
