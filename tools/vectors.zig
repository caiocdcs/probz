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
    .{ .name = "cuckoo_filter", .generate = genCuckoo },
    .{ .name = "quotient_filter", .generate = genQuotient },
    .{ .name = "hyperloglog", .generate = genHyperLogLog },
    .{ .name = "count_min_sketch", .generate = genCountMin },
    .{ .name = "splitmix64", .generate = genSplitMix },
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

fn genSplitMix(arena: Allocator) anyerror![]const u8 {
    const seeds = [_]u64{ 0, 1, 0xdeadbeef };
    const Seq = struct { seed: []const u8, outputs: [8][]const u8 };
    var seqs: [seeds.len]Seq = undefined;
    for (seeds, &seqs) |sd, *q| {
        var g = probz.hash.SplitMix64.init(sd);
        q.seed = try hex64(arena, sd);
        for (&q.outputs) |*o| o.* = try hex64(arena, g.next());
    }
    return toJson(arena, .{
        .description = "SplitMix64 outputs (SPEC.md §2.3)",
        .sequences = seqs,
    });
}

fn genCuckoo(arena: Allocator) anyerror![]const u8 {
    // 8-bit fingerprints, 4 slots, 16 buckets (64 slots): fill until Full so
    // the vector exercises evictions and the victim cache.
    const CF = probz.CuckooFilter(u8, 4);
    var cf = try CF.initBuckets(arena, 16, 0);
    const items = try inputs(arena, 100);
    var inserted: usize = 0;
    for (items) |item| {
        cf.add(item) catch break;
        inserted += 1;
    }
    const after_fill = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, cf));
    // Remove item-0..item-9.
    for (items[0..10]) |item| _ = cf.remove(item);

    const present = try arena.alloc(bool, items.len);
    for (items, present) |item, *p| p.* = cf.contains(item);

    return toJson(arena, .{
        .description = "Cuckoo filter (SPEC.md §5.4): fingerprint_bits=8, bucket_size=4, bucket_count=16, seed=0; add item-0, item-1, ... until Full; then remove item-0..item-9; query item-0..item-99",
        .params = .{ .fingerprint_bits = 8, .bucket_size = 4, .bucket_count = 16, .seed = 0 },
        .inserted_before_full = inserted,
        .serialized_after_fill = after_fill,
        .count_after_remove = cf.count(),
        .contains_after_remove = present,
        .serialized_after_remove = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, cf)),
    });
}

fn genQuotient(arena: Allocator) anyerror![]const u8 {
    // q = 5 (32 slots), r = 4: dense enough for long runs and wraparound.
    const QF = probz.QuotientFilter(4);
    var qf = try QF.init(arena, .{ .q = 5 });
    const items = try inputs(arena, 60);
    const added = try arena.alloc(bool, 28);
    for (items[0..28], added) |item, *a| a.* = try qf.add(item);
    const after_add = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, qf));
    for (items[0..28], 0..) |item, i| {
        if (i % 3 == 0) _ = qf.remove(item);
    }

    const Fp = struct { quotient: u64, remainder: u8 };
    var stored: std.ArrayList(Fp) = .empty;
    var it = qf.iterator();
    while (it.next()) |e| try stored.append(arena, .{ .quotient = e.quotient, .remainder = e.remainder });

    const present = try arena.alloc(bool, items.len);
    for (items, present) |item, *p| p.* = qf.contains(item);

    return toJson(arena, .{
        .description = "Quotient filter (SPEC.md §5.5): q=5, r=4; add item-0..item-27 (added = newly inserted); serialize; remove item-i for i < 28 with i mod 3 == 0; iterate; query item-0..item-59",
        .params = .{ .q = 5, .r = 4 },
        .added = added,
        .serialized_after_add = after_add,
        .count_after_remove = qf.count(),
        .entries_after_remove = stored.items,
        .contains_after_remove = present,
        .serialized_after_remove = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, qf)),
    });
}

fn genHyperLogLog(arena: Allocator) anyerror![]const u8 {
    var hll = try probz.HyperLogLog.init(arena, .{ .precision = 6 });
    const items = try inputs(arena, 5000);
    const Checkpoint = struct { n: usize, cardinality: f64 };
    var checkpoints: std.ArrayList(Checkpoint) = .empty;
    for (items, 1..) |item, n| {
        hll.add(item);
        if (n == 10 or n == 100 or n == 1000 or n == 5000) try checkpoints.append(arena, .{ .n = n, .cardinality = hll.cardinality() });
    }
    return toJson(arena, .{
        .description = "HyperLogLog (SPEC.md §5.6): precision=6; add item-0..item-4999; cardinality after n items",
        .params = .{ .precision = 6 },
        .checkpoints = checkpoints.items,
        .registers = hll.registers,
        .serialized = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, hll)),
    });
}

fn genCountMin(arena: Allocator) anyerror![]const u8 {
    var cms = try probz.CountMinSketch(u16).init(arena, .{ .width = 16, .depth = 3 });
    const items = try inputs(arena, 40);
    // item-i is added with amount i + 1 for i < 30.
    for (items[0..30], 0..) |item, i| try cms.add(item, @intCast(i + 1));
    const counts = try arena.alloc(u64, items.len);
    for (items, counts) |item, *c| c.* = cms.count(item);

    // Row indexes for the first three items, to pin the derivation.
    const Rows = struct { input: []const u8, columns: [3]u64 };
    var rows: [3]Rows = undefined;
    for (&rows, items[0..3]) |*r, item| {
        var g = probz.hash.SplitMix64.init(probz.hash.hashBytes(item));
        r.* = .{ .input = item, .columns = .{ g.below(16), g.below(16), g.below(16) } };
    }

    return toJson(arena, .{
        .description = "Count-Min sketch, u16 counters (SPEC.md §5.7): width=16, depth=3; add item-i with amount i+1 for i < 30; count(item-0..item-39)",
        .params = .{ .width = 16, .depth = 3, .counter_bits = 16 },
        .row_columns = rows,
        .total = cms.total,
        .counts = counts,
        .serialized = try hexBytes(arena, try probz.serde.toOwnedBytes(arena, cms)),
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
