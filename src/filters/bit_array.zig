//! Fixed-size bit array stored as little-endian `u64` words.
//!
//! Bit `i` lives in word `i / 64` at bit position `i % 64` (LSB first).
//! Bits past `len` in the last word are always zero. This layout is
//! part of the serialization format (SPEC.md §3.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const serde = @import("../serde.zig");

pub const BitArray = struct {
    words: []u64,
    /// Number of addressable bits.
    len: usize,

    pub const empty: BitArray = .{ .words = &.{}, .len = 0 };

    pub fn wordCount(len: usize) usize {
        return std.math.divCeil(usize, len, 64) catch unreachable;
    }

    /// Allocate `len` bits, all zero.
    pub fn init(allocator: Allocator, len: usize) Allocator.Error!BitArray {
        const words = try allocator.alloc(u64, wordCount(len));
        @memset(words, 0);
        return .{ .words = words, .len = len };
    }

    pub fn deinit(self: *BitArray, allocator: Allocator) void {
        allocator.free(self.words);
        self.* = undefined;
    }

    pub fn clone(self: BitArray, allocator: Allocator) Allocator.Error!BitArray {
        return .{ .words = try allocator.dupe(u64, self.words), .len = self.len };
    }

    pub fn isSet(self: BitArray, idx: usize) bool {
        std.debug.assert(idx < self.len);
        return self.words[idx / 64] & mask(idx) != 0;
    }

    pub fn set(self: *BitArray, idx: usize) void {
        std.debug.assert(idx < self.len);
        self.words[idx / 64] |= mask(idx);
    }

    pub fn unset(self: *BitArray, idx: usize) void {
        std.debug.assert(idx < self.len);
        self.words[idx / 64] &= ~mask(idx);
    }

    pub fn toggle(self: *BitArray, idx: usize) void {
        std.debug.assert(idx < self.len);
        self.words[idx / 64] ^= mask(idx);
    }

    /// Number of bits set to 1.
    pub fn countSet(self: BitArray) usize {
        var total: usize = 0;
        for (self.words) |w| total += @popCount(w);
        return total;
    }

    /// Clear every bit.
    pub fn clear(self: *BitArray) void {
        @memset(self.words, 0);
    }

    /// Bitwise OR `other` into `self`. Lengths must match.
    pub fn unionWith(self: *BitArray, other: BitArray) void {
        std.debug.assert(self.len == other.len);
        for (self.words, other.words) |*a, b| a.* |= b;
    }

    /// Body: u64 bit length, then `wordCount(len)` u64 words.
    pub fn serialize(self: BitArray, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeInt(w, u64, self.len);
        try serde.writeIntSlice(w, u64, self.words);
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!BitArray {
        const len = std.math.cast(usize, try serde.readInt(r, u64)) orelse return error.InvalidData;
        var bits = try init(allocator, len);
        errdefer bits.deinit(allocator);
        try serde.readIntSlice(r, u64, bits.words);
        // Reject set bits beyond `len` so the "tail is zero" invariant holds.
        if (len % 64 != 0) {
            const tail = bits.words[bits.words.len - 1] >> @intCast(len % 64);
            if (tail != 0) return error.InvalidData;
        }
        return bits;
    }

    inline fn mask(idx: usize) u64 {
        return @as(u64, 1) << @intCast(idx % 64);
    }
};

const testing = std.testing;

test "set, unset, toggle" {
    var bits = try BitArray.init(testing.allocator, 1000);
    defer bits.deinit(testing.allocator);

    try testing.expect(!bits.isSet(200));
    bits.set(200);
    try testing.expect(bits.isSet(200));
    bits.unset(200);
    try testing.expect(!bits.isSet(200));
    bits.toggle(400);
    try testing.expect(bits.isSet(400));
}

test "countSet" {
    var bits = try BitArray.init(testing.allocator, 100);
    defer bits.deinit(testing.allocator);

    bits.set(1);
    bits.set(10);
    bits.set(28);
    bits.set(28);
    bits.set(99);
    try testing.expectEqual(@as(usize, 4), bits.countSet());
}

test "zero length array" {
    var bits = try BitArray.init(testing.allocator, 0);
    defer bits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), bits.countSet());
}

test "regression: indexes beyond 16384 bits do not alias low words" {
    // The old implementation truncated the word index to u8, so bit
    // 64*256 aliased bit 0.
    var bits = try BitArray.init(testing.allocator, 1 << 20);
    defer bits.deinit(testing.allocator);

    bits.set(64 * 256);
    try testing.expect(!bits.isSet(0));
    try testing.expect(bits.isSet(64 * 256));

    bits.set((1 << 20) - 1);
    try testing.expectEqual(@as(usize, 2), bits.countSet());
}

test "union" {
    var a = try BitArray.init(testing.allocator, 70);
    defer a.deinit(testing.allocator);
    var b = try BitArray.init(testing.allocator, 70);
    defer b.deinit(testing.allocator);
    a.set(1);
    b.set(69);
    a.unionWith(b);
    try testing.expect(a.isSet(1) and a.isSet(69));
}

test "serialize round trip and tail check" {
    var bits = try BitArray.init(testing.allocator, 70);
    defer bits.deinit(testing.allocator);
    bits.set(0);
    bits.set(69);

    const bytes = try serde.toOwnedBytes(testing.allocator, bits);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 8 + 16), bytes.len);

    var r: std.Io.Reader = .fixed(bytes);
    var back = try BitArray.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, bits.words, back.words);

    // A bit set past `len` must be rejected.
    const bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);
    bad[bad.len - 1] = 0x80;
    r = .fixed(bad);
    try testing.expectError(error.InvalidData, BitArray.deserialize(testing.allocator, &r));
}
