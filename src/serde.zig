//! Binary serialization shared by every probz structure. See SPEC.md §3.
//!
//! Every serialized structure starts with a 6-byte header:
//!
//!   offset 0  4 bytes  magic "PRBZ"
//!   offset 4  1 byte   format version (currently 1)
//!   offset 5  1 byte   structure tag (`Tag`)
//!
//! followed by a structure-specific body. All integers are little-endian;
//! floats are written as the little-endian bytes of their IEEE-754 bits.

const std = @import("std");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub const magic = "PRBZ";
pub const version: u8 = 1;

/// Structure tags. Values are part of the wire format and never reused.
pub const Tag = enum(u8) {
    bloom_filter = 1,
    counting_bloom_filter = 2,
    scalable_bloom_filter = 3,
    cuckoo_filter = 4,
    quotient_filter = 5,
    hyperloglog = 6,
    count_min_sketch = 7,
    space_saving = 8,
    tdigest = 9,
    qdigest = 10,
    minhash_lsh = 11,
    _,
};

pub const WriteError = Writer.Error;

pub const ReadError = error{
    InvalidMagic,
    UnsupportedVersion,
    WrongStructure,
    /// The body is inconsistent (bad lengths or parameters).
    InvalidData,
} || Reader.Error || std.mem.Allocator.Error;

/// Map a structure's `init` error to a read error: parameters read from the
/// wire that `init` rejects make the data invalid.
pub fn fromInitError(err: error{ InvalidParameters, OutOfMemory }) ReadError {
    return switch (err) {
        error.InvalidParameters => error.InvalidData,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn writeHeader(w: *Writer, tag: Tag) WriteError!void {
    try w.writeAll(magic);
    try w.writeByte(version);
    try w.writeByte(@backingInt(tag));
}

pub fn readHeader(r: *Reader, expected: Tag) ReadError!void {
    const m = try r.takeArray(4);
    if (!std.mem.eql(u8, m, magic)) return error.InvalidMagic;
    if (try r.takeByte() != version) return error.UnsupportedVersion;
    if (try r.takeByte() != @backingInt(expected)) return error.WrongStructure;
}

pub fn writeInt(w: *Writer, comptime T: type, value: T) WriteError!void {
    try w.writeInt(T, value, .little);
}

pub fn readInt(r: *Reader, comptime T: type) ReadError!T {
    return r.takeInt(T, .little);
}

pub fn writeF64(w: *Writer, value: f64) WriteError!void {
    try writeInt(w, u64, @bitCast(value));
}

pub fn readF64(r: *Reader) ReadError!f64 {
    return @bitCast(try readInt(r, u64));
}

/// Write a length-prefixed (u32) byte string.
pub fn writeBytes(w: *Writer, bytes: []const u8) WriteError!void {
    try writeInt(w, u32, @intCast(bytes.len));
    try w.writeAll(bytes);
}

/// Read a length-prefixed (u32) byte string into newly allocated memory.
pub fn readBytes(r: *Reader, allocator: std.mem.Allocator) ReadError![]u8 {
    const len = try readInt(r, u32);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

/// Write a slice of integers, each little-endian, without a length prefix.
pub fn writeIntSlice(w: *Writer, comptime T: type, values: []const T) WriteError!void {
    for (values) |v| try writeInt(w, T, v);
}

/// Fill `out` with little-endian integers.
pub fn readIntSlice(r: *Reader, comptime T: type, out: []T) ReadError!void {
    for (out) |*v| v.* = try readInt(r, T);
}

/// Serialize `value` (anything with `serialize(*const T, *Writer)`) into
/// newly allocated bytes. Convenience for tests and callers without a stream.
pub fn toOwnedBytes(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // The allocating writer only fails when it runs out of memory.
    value.serialize(&aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "header round trip" {
    var buf: [16]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeHeader(&w, .bloom_filter);
    try testing.expectEqualSlices(u8, "PRBZ\x01\x01", w.buffered());

    var r: Reader = .fixed(w.buffered());
    try readHeader(&r, .bloom_filter);

    r = .fixed(w.buffered());
    try testing.expectError(error.WrongStructure, readHeader(&r, .hyperloglog));

    r = .fixed("XXXX\x01\x01");
    try testing.expectError(error.InvalidMagic, readHeader(&r, .bloom_filter));

    r = .fixed("PRBZ\x09\x01");
    try testing.expectError(error.UnsupportedVersion, readHeader(&r, .bloom_filter));
}

test "ints, floats and bytes are little-endian" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeInt(&w, u32, 0x01020304);
    try writeF64(&w, 1.0);
    try writeBytes(&w, "hi");
    try testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f, 2, 0, 0, 0, 'h', 'i' }, w.buffered());

    var r: Reader = .fixed(w.buffered());
    try testing.expectEqual(@as(u32, 0x01020304), try readInt(&r, u32));
    try testing.expectEqual(@as(f64, 1.0), try readF64(&r));
    const s = try readBytes(&r, testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hi", s);
}
