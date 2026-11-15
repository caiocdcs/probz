//! Golden test vectors for cross-language ports. See SPEC.md §4.
//!
//! Each case produces one JSON document under `testdata/vectors/`. Ports
//! replay the documented inputs and must reproduce the expected outputs
//! and serialized bytes exactly. Regenerate with `zig build gen-vectors`;
//! `zig build test` fails if the committed files are stale.
//!
//! Conventions:
//! - Inputs are the ASCII strings "item-0", "item-1", ... ("item-{i}").
//! - 64-bit values are hex strings ("0x" + 16 lowercase digits), because
//!   JSON numbers lose precision above 2^53.
//! - Serialized structures are lowercase hex strings.

const std = @import("std");
const probz = @import("probz");
const Allocator = std.mem.Allocator;

pub const Case = struct {
    name: []const u8,
    /// Returns the JSON document. All memory comes from `arena`.
    generate: *const fn (arena: Allocator) anyerror![]const u8,
};

pub const cases = [_]Case{
    .{ .name = "hash", .generate = genHash },
};

/// "item-{i}" for i in [0, n).
pub fn inputs(arena: Allocator, n: usize) ![]const []const u8 {
    const out = try arena.alloc([]const u8, n);
    for (out, 0..) |*s, i| s.* = try std.fmt.allocPrint(arena, "item-{d}", .{i});
    return out;
}

pub fn hex64(arena: Allocator, v: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "0x{x:0>16}", .{v});
}

pub fn hexBytes(arena: Allocator, bytes: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{x}", .{bytes});
}

pub fn toJson(arena: Allocator, value: anytype) ![]const u8 {
    const body = try std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .indent_2 });
    return std.mem.concat(arena, u8, &.{ body, "\n" });
}

fn genHash(arena: Allocator) anyerror![]const u8 {
    const Entry = struct {
        input: []const u8,
        xxh64: []const u8,
        h1: u32,
        h2: u32,
        /// HashPair.index(i, 1000) for i = 0..3
        indexes_mod_1000: [4]u64,
    };
    const items = try inputs(arena, 16);
    const entries = try arena.alloc(Entry, items.len);
    for (items, entries) |item, *e| {
        const h = probz.hash.hashBytes(item);
        const p = probz.hash.HashPair.fromHash(h);
        e.* = .{
            .input = item,
            .xxh64 = try hex64(arena, h),
            .h1 = p.h1,
            .h2 = p.h2,
            .indexes_mod_1000 = .{ p.index(0, 1000), p.index(1, 1000), p.index(2, 1000), p.index(3, 1000) },
        };
    }

    const KeyEntry = struct { key: []const u8, xxh64: []const u8 };
    const keys = [_]KeyEntry{
        .{ .key = "u32 1", .xxh64 = try hex64(arena, probz.hash.hashKey(@as(u32, 1))) },
        .{ .key = "u64 1", .xxh64 = try hex64(arena, probz.hash.hashKey(@as(u64, 1))) },
        .{ .key = "i64 -1", .xxh64 = try hex64(arena, probz.hash.hashKey(@as(i64, -1))) },
        .{ .key = "f64 1.0", .xxh64 = try hex64(arena, probz.hash.hashKey(@as(f64, 1.0))) },
        .{ .key = "bool true", .xxh64 = try hex64(arena, probz.hash.hashKey(true)) },
    };

    return toJson(arena, .{
        .description = "XxHash64(seed=0) of inputs, HashPair derivation (SPEC.md §2)",
        .strings = entries,
        .typed_keys = keys,
    });
}

test "golden vectors are up to date" {
    const testdata = @import("testdata");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cases) |case| {
        const expected = for (testdata.entries) |e| {
            if (std.mem.eql(u8, e.name, case.name)) break e.json;
        } else {
            std.debug.print("missing vector '{s}': run `zig build gen-vectors`\n", .{case.name});
            return error.MissingVector;
        };
        const actual = try case.generate(arena);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("stale vector '{s}': run `zig build gen-vectors`\n", .{case.name});
            return err;
        };
    }
    try std.testing.expectEqual(cases.len, testdata.entries.len);
}
