//! HyperLogLog: distinct-count estimation in m = 2^p one-byte registers,
//! with standard error ≈ 1.04 / √m. See SPEC.md §5.6.
//!
//! Each item's 64-bit hash picks a register from its top p bits; the
//! register keeps the maximum ρ, the position of the leftmost 1-bit in
//! the remaining 64 − p bits (1-based, at most q + 1 with q = 64 − p).
//!
//! The estimate is Ertl's improved raw estimator (Ertl 2017, §3.3 Eq. 32,
//! Algorithm 6). It works from the register histogram C_0 … C_{q+1} and
//! needs no bias tables, linear-counting switch, or large-range correction.
//! It is accurate over the whole range, including the small and medium
//! cardinalities where Flajolet's raw estimate is biased. probz keeps the
//! histogram up to date as registers grow, so `cardinality` runs in
//! O(q) rather than O(m).
//!
//! The sparse representation of HyperLogLog++ is not implemented.
//!
//! # References
//!
//! - Philippe Flajolet, Éric Fusy, Olivier Gandouet, Frédéric Meunier,
//!   "HyperLogLog: the analysis of a near-optimal cardinality estimation
//!   algorithm", AofA 2007, DMTCS Proceedings AH:137–156. Figure 3 (the
//!   program, α_m constants, small-range correction), standard error
//!   1.04 / √m. https://doi.org/10.46298/dmtcs.3545
//!   (PDF: https://algo.inria.fr/flajolet/Publications/FlFuGaMe07.pdf)
//! - Stefan Heule, Marc Nunkesser, Alexander Hall, "HyperLogLog in Practice:
//!   Algorithmic Engineering of a State of The Art Cardinality Estimation
//!   Algorithm", EDBT 2013, pp. 683–692. §5.1 (64-bit hash, no large-range
//!   correction). https://doi.org/10.1145/2452376.2452456
//! - Otmar Ertl, "New cardinality estimation algorithms for HyperLogLog
//!   sketches", arXiv:1702.01284, 2017. §3.3 Eq. 32 (improved raw
//!   estimator), §3.4 Algorithm 6 (σ and τ). https://arxiv.org/abs/1702.01284

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("hash.zig");
const serde = @import("serde.zig");

pub const HyperLogLog = struct {
    /// Index bits p; m = 2^p registers.
    precision: u5,
    registers: []u8,
    /// hist[k]: number of registers equal to k, for k in [0, q + 1].
    hist: [64]u32,

    pub const min_precision = 4;
    pub const max_precision = 18;

    pub const Options = struct {
        /// p in [4, 18]. 14 gives m = 16384 registers (16 KiB), error ≈ 0.81%.
        precision: u5 = 14,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const MergeError = error{IncompatiblePrecision};

    pub fn init(allocator: Allocator, options: Options) InitError!HyperLogLog {
        if (options.precision < min_precision or options.precision > max_precision) return error.InvalidParameters;
        const m = @as(usize, 1) << options.precision;
        const registers = try allocator.alloc(u8, m);
        @memset(registers, 0);
        var hist: [64]u32 = @splat(0);
        hist[0] = @intCast(m);
        return .{ .precision = options.precision, .registers = registers, .hist = hist };
    }

    pub fn deinit(self: *HyperLogLog, allocator: Allocator) void {
        allocator.free(self.registers);
        self.* = undefined;
    }

    pub fn add(self: *HyperLogLog, item: []const u8) void {
        self.addHash(hashing.hashBytes(item));
    }

    /// j = h >> (64 − p); ρ = clz((h << p) | 2^(p−1)) + 1.
    /// The OR'd sentinel bit caps ρ at 64 − p + 1 when the low bits are zero.
    pub fn addHash(self: *HyperLogLog, h: u64) void {
        const p: u6 = self.precision;
        const j: usize = @intCast(h >> @intCast(64 - @as(u7, p)));
        const w = (h << p) | (@as(u64, 1) << (p - 1));
        const rho: u8 = @as(u8, @clz(w)) + 1;
        const old = self.registers[j];
        if (rho > old) {
            self.registers[j] = rho;
            self.hist[old] -= 1;
            self.hist[rho] += 1;
        }
    }

    /// Estimated number of distinct items (Ertl, Algorithm 6):
    ///
    ///   z = m·τ(1 − C_{q+1}/m);  z = (z + C_k) / 2 for k = q … 1;
    ///   z += m·σ(C_0/m);  E = α_∞·m² / z,  α_∞ = 1 / (2 ln 2).
    ///
    /// Runs in O(q), independent of m. Returns +inf when every register
    /// is at its maximum q + 1.
    pub fn cardinality(self: HyperLogLog) f64 {
        const m: f64 = @floatFromInt(self.registers.len);
        const q: usize = 64 - @as(usize, self.precision);
        var z = m * tau(1.0 - @as(f64, @floatFromInt(self.hist[q + 1])) / m);
        var k = q;
        while (k >= 1) : (k -= 1) z = 0.5 * (z + @as(f64, @floatFromInt(self.hist[k])));
        z += m * sigma(@as(f64, @floatFromInt(self.hist[0])) / m);
        return alpha_inf * m * m / z;
    }

    /// Relative standard error 1.04 / √m.
    pub fn standardError(self: HyperLogLog) f64 {
        return 1.04 / @sqrt(@as(f64, @floatFromInt(self.registers.len)));
    }

    /// Union: register-wise maximum. Both must have the same precision.
    pub fn merge(self: *HyperLogLog, other: HyperLogLog) MergeError!void {
        if (self.precision != other.precision) return error.IncompatiblePrecision;
        // Eight registers per u64. Registers are < 128, so per byte
        // (x | 0x80) − y never borrows, and its high bit is clear exactly
        // when x < y. Most words of overlapping sketches have no such byte.
        const hi: u64 = 0x8080_8080_8080_8080;
        var i: usize = 0;
        while (i < self.registers.len) : (i += 8) {
            const a = self.registers[i..][0..8];
            const b = other.registers[i..][0..8];
            const x = std.mem.readInt(u64, a, .little);
            const y = std.mem.readInt(u64, b, .little);
            const grow = ~((x | hi) -% y) & hi;
            if (grow == 0) continue;
            var g = grow;
            while (g != 0) : (g &= g - 1) {
                const j = @ctz(g) >> 3;
                self.hist[a[j]] -= 1;
                self.hist[b[j]] += 1;
            }
            const mask = (grow >> 7) *% 0xff;
            std.mem.writeInt(u64, a, (x & ~mask) | (y & mask), .little);
        }
    }

    pub fn clear(self: *HyperLogLog) void {
        @memset(self.registers, 0);
        self.hist = @splat(0);
        self.hist[0] = @intCast(self.registers.len);
    }

    /// Registers plus the 256-byte histogram.
    pub fn memoryBytes(self: HyperLogLog) usize {
        return self.registers.len + @sizeOf(@TypeOf(self.hist));
    }

    /// Body (tag 6): u8 p, then m register bytes.
    pub fn serialize(self: HyperLogLog, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .hyperloglog);
        try w.writeByte(self.precision);
        try w.writeAll(self.registers);
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!HyperLogLog {
        try serde.readHeader(r, .hyperloglog);
        const p = try r.takeByte();
        if (p < min_precision or p > max_precision) return error.InvalidData;
        var self = init(allocator, .{ .precision = @intCast(p) }) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        try r.readSliceAll(self.registers);
        const max_rho = 64 - p + 1;
        self.hist = @splat(0);
        for (self.registers) |reg| {
            if (reg > max_rho) return error.InvalidData;
            self.hist[reg] += 1;
        }
        return self;
    }
};

/// α_∞ = 1 / (2 ln 2) (Ertl, Eq. 32).
const alpha_inf = 1.0 / (2.0 * math.ln2);

/// σ(x) = x + Σ_{k≥1} x^(2^k) · 2^(k−1) (Ertl, Algorithm 6), summed until
/// the result stops changing. σ(1) = +inf.
fn sigma(x_in: f64) f64 {
    if (x_in == 1) return math.inf(f64);
    var x = x_in;
    var y: f64 = 1;
    var z = x;
    while (true) {
        x *= x;
        const prev = z;
        z += x * y;
        y += y;
        if (z == prev) return z;
    }
}

/// τ(x) = (1 − x − Σ_{k≥1} (1 − x^(2^−k))² · 2^−k) / 3 (Ertl, Algorithm 6),
/// summed until the result stops changing. τ(0) = τ(1) = 0.
fn tau(x_in: f64) f64 {
    if (x_in == 0 or x_in == 1) return 0;
    var x = x_in;
    var y: f64 = 1;
    var z = 1 - x;
    while (true) {
        x = @sqrt(x);
        const prev = z;
        y *= 0.5;
        z -= (1 - x) * (1 - x) * y;
        if (z == prev) return z / 3;
    }
}

const testing = std.testing;

test "precision bounds" {
    try testing.expectError(error.InvalidParameters, HyperLogLog.init(testing.allocator, .{ .precision = 3 }));
    try testing.expectError(error.InvalidParameters, HyperLogLog.init(testing.allocator, .{ .precision = 19 }));
}

test "empty and single item" {
    var hll = try HyperLogLog.init(testing.allocator, .{ .precision = 8 });
    defer hll.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), hll.cardinality());
    hll.add("test");
    hll.add("test");
    try testing.expectEqual(@as(f64, 1), @round(hll.cardinality()));
}

test "rank uses all 64 - p bits" {
    var hll = try HyperLogLog.init(testing.allocator, .{ .precision = 4 });
    defer hll.deinit(testing.allocator);
    // Register 0, all remaining bits zero: maximum rank 64 - 4 + 1 = 61.
    hll.addHash(0);
    try testing.expectEqual(@as(u8, 61), hll.registers[0]);
    // Register 15, first remaining bit set: rank 1.
    hll.addHash(0xf800_0000_0000_0000);
    try testing.expectEqual(@as(u8, 1), hll.registers[15]);
}

test "relative error within 3 standard errors" {
    var hll = try HyperLogLog.init(testing.allocator, .{ .precision = 12 });
    defer hll.deinit(testing.allocator);
    const bound = 3 * hll.standardError();

    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for ([_]usize{ 100, 1_000, 10_000, 100_000, 1_000_000 }) |target| {
        while (n < target) : (n += 1) hll.add(try std.fmt.bufPrint(&buf, "item-{d}", .{n}));
        const est = hll.cardinality();
        const err = @abs(est - @as(f64, @floatFromInt(n))) / @as(f64, @floatFromInt(n));
        try testing.expect(err <= bound);
    }
}

fn expectHistogramMatches(hll: HyperLogLog) !void {
    var want: [64]u32 = @splat(0);
    for (hll.registers) |r| want[r] += 1;
    try testing.expectEqualSlices(u32, &want, &hll.hist);
}

test "relative RMSE stays near 1.04 / sqrt(m) across the range" {
    // Includes 2.5·m … 5·m, where Flajolet's raw estimate is most biased.
    const p = 10;
    const m = 1 << p;
    const trials = 50;
    for ([_]usize{ 10, 100, 1000, 2 * m, 3 * m, 4 * m, 20 * m, 200 * m }) |n| {
        var sq: f64 = 0;
        for (0..trials) |t| {
            var hll = try HyperLogLog.init(testing.allocator, .{ .precision = p });
            defer hll.deinit(testing.allocator);
            for (0..n) |i| hll.addHash(hashing.hashKey(@as(u64, t) << 32 | i));
            const rel = (hll.cardinality() - @as(f64, @floatFromInt(n))) / @as(f64, @floatFromInt(n));
            sq += rel * rel;
        }
        const rmse = @sqrt(sq / trials);
        try testing.expect(rmse <= 1.25 * 1.04 / @sqrt(@as(f64, m)));
    }
}

test "histogram tracks registers through add, merge, clear, deserialize" {
    var a = try HyperLogLog.init(testing.allocator, .{ .precision = 6 });
    defer a.deinit(testing.allocator);
    var b = try HyperLogLog.init(testing.allocator, .{ .precision = 6 });
    defer b.deinit(testing.allocator);
    for (0..500) |i| a.addHash(hashing.hashKey(@as(u64, i)));
    for (300..2000) |i| b.addHash(hashing.hashKey(@as(u64, i)));
    try expectHistogramMatches(a);
    try a.merge(b);
    try expectHistogramMatches(a);

    const bytes = try serde.toOwnedBytes(testing.allocator, a);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try HyperLogLog.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try expectHistogramMatches(back);
    try testing.expectEqual(a.cardinality(), back.cardinality());

    a.clear();
    try expectHistogramMatches(a);
    try testing.expectEqual(@as(f64, 0), a.cardinality());
}

test "saturated sketch reports infinity" {
    var hll = try HyperLogLog.init(testing.allocator, .{ .precision = 4 });
    defer hll.deinit(testing.allocator);
    for (0..16) |j| hll.addHash(@as(u64, j) << 60); // rank q + 1 everywhere
    try testing.expect(math.isInf(hll.cardinality()));
}

test "merge equals the union" {
    var a = try HyperLogLog.init(testing.allocator, .{ .precision = 10 });
    defer a.deinit(testing.allocator);
    var b = try HyperLogLog.init(testing.allocator, .{ .precision = 10 });
    defer b.deinit(testing.allocator);
    var all = try HyperLogLog.init(testing.allocator, .{ .precision = 10 });
    defer all.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..3000) |i| {
        const item = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        if (i < 2000) a.add(item);
        if (i >= 1000) b.add(item);
        all.add(item);
    }
    try a.merge(b);
    try testing.expectEqualSlices(u8, all.registers, a.registers);

    var c = try HyperLogLog.init(testing.allocator, .{ .precision = 8 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatiblePrecision, a.merge(c));
}

test "serialize round trip" {
    var hll = try HyperLogLog.init(testing.allocator, .{ .precision = 6 });
    defer hll.deinit(testing.allocator);
    hll.add("x");
    const bytes = try serde.toOwnedBytes(testing.allocator, hll);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 6 + 1 + 64), bytes.len);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try HyperLogLog.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, hll.registers, back.registers);
}
