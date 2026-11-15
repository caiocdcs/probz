//! Canonical hashing shared by every probz structure.
//!
//! All structures hash keys with XxHash64 (seed 0) and derive per-structure
//! indexes from that single 64-bit value. Pinning one hash makes the
//! behaviour reproducible across languages: a port that implements
//! XxHash64 and the derivation rules below produces bit-identical filters.
//! See SPEC.md §2.
//!
//! # References
//!
//! - xxHash specification (XXH64):
//!   https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
//! - Adam Kirsch, Michael Mitzenmacher, "Less Hashing, Same Performance:
//!   Building a Better Bloom Filter", ESA 2006 / Random Structures &
//!   Algorithms 33(2):187–218, 2008. Theorem 5.2 justifies deriving k
//!   indexes as g_i(x) = h1(x) + i·h2(x) mod m.
//!   https://doi.org/10.1002/rsa.20208
//!   (author PDF: https://www.eecs.harvard.edu/~michaelm/postscripts/rsa2008.pdf)
//! - Guy L. Steele, Doug Lea, Christine H. Flood, "Fast Splittable
//!   Pseudorandom Number Generators", OOPSLA 2014 (ACM SIGPLAN Notices
//!   49(10):453–472). https://doi.org/10.1145/2714064.2660195
//!   SplitMix64 constants as in Vigna's reference code:
//!   https://prng.di.unimi.it/splitmix64.c

const std = @import("std");

/// Seed used for every key hash.
pub const seed: u64 = 0;

/// Hash a byte string with XxHash64(seed = 0).
pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(seed, bytes);
}

/// Hash a key with a portable encoding:
/// - `[]const u8`, `[]u8`, `*const [N]u8` (string literals): the raw bytes;
/// - integers: their little-endian two's-complement bytes (`@sizeOf(T)` bytes);
/// - floats: the little-endian bytes of their IEEE-754 bit pattern;
/// - `bool`: one byte, 0 or 1.
///
/// Other types are rejected at compile time; serialize them to bytes and
/// call `hashBytes` so the encoding stays portable.
pub fn hashKey(key: anytype) u64 {
    const T = @TypeOf(key);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const I = if (T == comptime_int) i64 else T;
            const Bytes = @Int(.unsigned, @sizeOf(I) * 8);
            var buf: [@sizeOf(I)]u8 = undefined;
            std.mem.writeInt(Bytes, &buf, @bitCast(@as(@Int(@typeInfo(I).int.signedness, @sizeOf(I) * 8), key)), .little);
            return hashBytes(&buf);
        },
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            return hashKey(@as(Bits, @bitCast(key)));
        },
        .bool => return hashBytes(&.{@intFromBool(key)}),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return hashBytes(key);
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return hashBytes(key);
        },
        else => {},
    }
    @compileError("probz.hashKey: unsupported key type " ++ @typeName(T) ++ "; encode it as bytes and use hashBytes");
}

/// Two 32-bit hashes derived from one 64-bit hash, for double hashing.
/// `h1` is the low half; `h2` is the high half with the lowest bit forced
/// to 1 so it is never zero (and is odd, which avoids short cycles when
/// the modulus is a power of two).
pub const HashPair = struct {
    h1: u32,
    h2: u32,

    pub fn fromHash(h: u64) HashPair {
        return .{ .h1 = @truncate(h), .h2 = @as(u32, @truncate(h >> 32)) | 1 };
    }

    /// The i-th derived index in [0, m): (h1 + i·h2) mod m, computed in
    /// 64-bit arithmetic. With i < 2^32 the sum cannot overflow.
    pub fn index(self: HashPair, i: u32, m: u64) u64 {
        std.debug.assert(m > 0);
        return (@as(u64, self.h1) + @as(u64, i) * @as(u64, self.h2)) % m;
    }
};

/// SplitMix64: the portable PRNG used wherever a structure needs random
/// choices (cuckoo evictions, MinHash coefficients). It is specified in
/// SPEC.md §2.3 so ports can reproduce the exact same sequence.
pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed_value: u64) SplitMix64 {
        return .{ .state = seed_value };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// Value in [0, n) as `next() mod n`. The modulo bias is negligible
    /// for the small n used here and keeps ports simple.
    pub fn below(self: *SplitMix64, n: u64) u64 {
        std.debug.assert(n > 0);
        return self.next() % n;
    }
};

const testing = std.testing;

test "hashBytes matches the XXH64 reference values" {
    // Reference values from the xxHash test suite (XXH64, seed 0).
    try testing.expectEqual(@as(u64, 0xef46db3751d8e999), hashBytes(""));
    try testing.expectEqual(@as(u64, 0xd24ec4f1a98c6e5b), hashBytes("a"));
    try testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), hashBytes("abc"));
}

test "hashKey encodings" {
    try testing.expectEqual(hashBytes("abc"), hashKey("abc"));
    const s: []const u8 = "abc";
    try testing.expectEqual(hashBytes("abc"), hashKey(s));
    try testing.expectEqual(hashBytes(&.{ 1, 0, 0, 0 }), hashKey(@as(u32, 1)));
    try testing.expectEqual(hashBytes(&.{ 0xff, 0xff }), hashKey(@as(i16, -1)));
    try testing.expectEqual(hashKey(@as(u64, 0x3ff0000000000000)), hashKey(@as(f64, 1.0)));
    try testing.expectEqual(hashBytes(&.{1}), hashKey(true));
}

test "HashPair derivation" {
    const p = HashPair.fromHash(0x0000_0002_0000_0005);
    try testing.expectEqual(@as(u32, 5), p.h1);
    try testing.expectEqual(@as(u32, 3), p.h2); // 2 | 1
    try testing.expectEqual(@as(u64, 5), p.index(0, 100));
    try testing.expectEqual(@as(u64, 11), p.index(2, 100));
    try testing.expectEqual(@as(u64, 1), p.index(2, 10));
}

test "SplitMix64 matches std and the reference sequence" {
    var ours = SplitMix64.init(0);
    var theirs = std.Random.SplitMix64.init(0);
    for (0..100) |_| try testing.expectEqual(theirs.next(), ours.next());

    // First outputs for seed 0 (https://prng.di.unimi.it/splitmix64.c).
    var g = SplitMix64.init(0);
    try testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), g.next());
    try testing.expectEqual(@as(u64, 0x6e789e6aa1b965f4), g.next());
    try testing.expectEqual(@as(u64, 0x06c45d188009454f), g.next());
}
