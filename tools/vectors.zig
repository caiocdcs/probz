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
    .{ .name = "bloom_filter", .generate = genBloom },
    .{ .name = "counting_bloom_filter", .generate = genCountingBloom },
    .{ .name = "scalable_bloom_filter", .generate = genScalableBloom },
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

fn genBloom(arena: Allocator) anyerror![]const u8 {
    const n = 100;
    var bf = try probz.BloomFilter.init(arena, .{ .expected_items = 1000, .fp_rate = 0.01 });
    const items = try inputs(arena, 200);
    for (items[0..n]) |item| bf.add(item);

    // Which of item-0..item-199 the filter reports as present.
    const present = try arena.alloc(bool, items.len);
    for (items, present) |item, *p| p.* = bf.contains(item);

    return toJson(arena, .{
        .description = "Bloom filter (SPEC.md §5.1): init(expected_items=1000, fp_rate=0.01), add item-0..item-99, query item-0..item-199",
        .params = .{ .expected_items = 1000, .fp_rate = 0.01 },
        .bit_count = bf.bitCount(),
        .hash_count = bf.k,
        .inserted = n,
        .contains = present,
        .set_bits = bf.bits.countSet(),
        .estimated_items = bf.estimatedItems(),
        .serialized = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, bf)),
    });
}

fn genCountingBloom(arena: Allocator) anyerror![]const u8 {
    // Small 4-bit filter so the serialized body stays short.
    var cbf = try probz.DefaultCountingBloomFilter.init(arena, .{ .expected_items = 50, .fp_rate = 0.01 });
    const items = try inputs(arena, 100);
    // item-i is added (i % 3) + 1 times for i < 50, then item-0..item-9 are removed once.
    for (items[0..50], 0..) |item, i| {
        for (0..(i % 3) + 1) |_| cbf.add(item);
    }
    for (items[0..10]) |item| _ = cbf.remove(item);

    const counts = try arena.alloc(u8, items.len);
    for (items, counts) |item, *c| c.* = cbf.count(item);

    return toJson(arena, .{
        .description = "Counting Bloom filter, u4 counters (SPEC.md §5.2): init(expected_items=50, fp_rate=0.01); add item-i ((i mod 3)+1) times for i < 50; remove item-0..item-9 once; count(item-0..item-99)",
        .params = .{ .expected_items = 50, .fp_rate = 0.01, .counter_bits = 4 },
        .cell_count = cbf.cellCount(),
        .hash_count = cbf.k,
        .counts = counts,
        .non_zero = cbf.nonZeroCount(),
        .serialized = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, cbf)),
    });
}

fn genScalableBloom(arena: Allocator) anyerror![]const u8 {
    var sbf = try probz.ScalableBloomFilter.init(arena, .{ .initial_capacity = 20, .fp_rate = 0.01, .growth = 2, .tightening = 0.9 });
    const items = try inputs(arena, 200);
    for (items[0..100]) |item| _ = try sbf.add(arena, item);

    const Stage = struct { capacity: u64, count: u64, bit_count: u64, hash_count: u32 };
    const stages = try arena.alloc(Stage, sbf.stageCount());
    for (sbf.stages.items, stages) |s, *out| out.* = .{
        .capacity = s.capacity,
        .count = s.count,
        .bit_count = s.filter.bitCount(),
        .hash_count = s.filter.k,
    };
    const present = try arena.alloc(bool, items.len);
    for (items, present) |item, *p| p.* = sbf.contains(item);

    return toJson(arena, .{
        .description = "Scalable Bloom filter (SPEC.md §5.3): init(initial_capacity=20, fp_rate=0.01, growth=2, tightening=0.9), add item-0..item-99, query item-0..item-199",
        .params = .{ .initial_capacity = 20, .fp_rate = 0.01, .growth = 2, .tightening = 0.9 },
        .stages = stages,
        .contains = present,
        .serialized = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, sbf)),
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
