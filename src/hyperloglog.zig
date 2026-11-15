//! HyperLogLog: distinct-count estimation in m = 2^p one-byte registers,
//! with standard error ≈ 1.04 / √m. See SPEC.md §5.6.
//!
//! Each item's 64-bit hash picks a register from its top p bits; the
//! register keeps the maximum ρ, the position of the leftmost 1-bit in
//! the remaining 64 − p bits (1-based, at most 64 − p + 1). The estimate
//! is the bias-corrected harmonic mean of 2^register (Flajolet et al.,
//! Figure 3), with linear counting below 5/2·m when some registers are
//! still zero.
//!
//! Because the hash has 64 bits, the original large-range correction for
//! cardinalities near 2^32 is not needed (Heule et al. §5.1). The
//! empirical bias tables and sparse representation of HyperLogLog++ are
//! not implemented.
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

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("hash.zig");
const serde = @import("serde.zig");

pub const HyperLogLog = struct {
    /// Index bits p; m = 2^p registers.
    precision: u5,
    registers: []u8,

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
        const registers = try allocator.alloc(u8, @as(usize, 1) << options.precision);
        @memset(registers, 0);
        return .{ .precision = options.precision, .registers = registers };
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
        if (rho > self.registers[j]) self.registers[j] = rho;
    }

    /// Estimated number of distinct items.
    pub fn cardinality(self: HyperLogLog) f64 {
        const m: f64 = @floatFromInt(self.registers.len);
        var sum: f64 = 0;
        var zeros: usize = 0;
        for (self.registers) |r| {
            sum += math.ldexp(@as(f64, 1.0), -@as(i32, r));
            zeros += @intFromBool(r == 0);
        }
        const raw = alpha(self.registers.len) * m * m / sum;
        if (raw <= 2.5 * m and zeros > 0) {
            // Small-range correction: linear counting.
            return m * @log(m / @as(f64, @floatFromInt(zeros)));
        }
        return raw;
    }

    /// Relative standard error 1.04 / √m.
    pub fn standardError(self: HyperLogLog) f64 {
        return 1.04 / @sqrt(@as(f64, @floatFromInt(self.registers.len)));
    }

    /// Union: register-wise maximum. Both must have the same precision.
    pub fn merge(self: *HyperLogLog, other: HyperLogLog) MergeError!void {
        if (self.precision != other.precision) return error.IncompatiblePrecision;
        for (self.registers, other.registers) |*a, b| a.* = @max(a.*, b);
    }

    pub fn clear(self: *HyperLogLog) void {
        @memset(self.registers, 0);
    }

    pub fn memoryBytes(self: HyperLogLog) usize {
        return self.registers.len;
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
        for (self.registers) |reg| if (reg > max_rho) return error.InvalidData;
        return self;
    }
};

/// α_m from Figure 3 of Flajolet et al.
fn alpha(m: usize) f64 {
    return switch (m) {
        16 => 0.673,
        32 => 0.697,
        64 => 0.709,
        else => 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(m))),
    };
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
