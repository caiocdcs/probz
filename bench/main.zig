//! Throughput and memory for each structure: zig build bench
//!
//! Built with ReleaseFast regardless of -Doptimize. Numbers are
//! single-threaded and indicative only.

const std = @import("std");
const probz = @import("probz");

const n = 1_000_000;

var io: std.Io = undefined;

const Timer = struct {
    start: std.Io.Timestamp,

    fn begin() Timer {
        return .{ .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn nsPerOp(t: Timer, ops: usize) f64 {
        const ns: f64 = @floatFromInt(t.start.untilNow(io, .awake).nanoseconds);
        return ns / @as(f64, @floatFromInt(ops));
    }
};

fn report(name: []const u8, add_ns: f64, query_ns: f64, bytes: usize) void {
    std.debug.print("{s:<28} add {d:>7.1} ns/op   query {d:>7.1} ns/op   {d:>9} bytes\n", .{ name, add_ns, query_ns, bytes });
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const gpa = init.gpa;

    // Keys are pre-hashed so the numbers measure the structures, not
    // string formatting. Each structure also accepts raw bytes.
    const keys = try gpa.alloc(u64, n);
    defer gpa.free(keys);
    for (keys, 0..) |*k, i| k.* = probz.hash.hashKey(@as(u64, i));
    var sink: u64 = 0;

    std.debug.print("probz benchmarks, n = {d}\n\n", .{n});

    {
        var bf = try probz.BloomFilter.init(gpa, .{ .expected_items = n, .fp_rate = 0.01 });
        defer bf.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| bf.addHash(k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink += @intFromBool(bf.containsHash(k));
        report("BloomFilter (p=1%)", a, t.nsPerOp(n), bf.memoryBytes());
    }
    {
        var cbf = try probz.DefaultCountingBloomFilter.init(gpa, .{ .expected_items = n, .fp_rate = 0.01 });
        defer cbf.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| cbf.addHash(k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink += @intFromBool(cbf.containsHash(k));
        report("CountingBloomFilter (u4)", a, t.nsPerOp(n), cbf.memoryBytes());
    }
    {
        var sbf = try probz.ScalableBloomFilter.init(gpa, .{ .initial_capacity = 10_000, .fp_rate = 0.01 });
        defer sbf.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| _ = try sbf.addHash(gpa, k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink += @intFromBool(sbf.containsHash(k));
        report("ScalableBloomFilter", a, t.nsPerOp(n), sbf.memoryBytes());
    }
    {
        var cf = try probz.DefaultCuckooFilter.init(gpa, .{ .capacity = n });
        defer cf.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| try cf.addHash(k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink += @intFromBool(cf.containsHash(k));
        report("CuckooFilter (u16, b=4)", a, t.nsPerOp(n), cf.memoryBytes());
    }
    {
        var qf = try probz.DefaultQuotientFilter.init(gpa, .{ .q = 21 }); // 2M slots, ~48% load
        defer qf.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| _ = try qf.addHash(k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink += @intFromBool(qf.containsHash(k));
        report("QuotientFilter (r=8, q=21)", a, t.nsPerOp(n), qf.memoryBytes());
    }
    {
        var hll = try probz.HyperLogLog.init(gpa, .{ .precision = 14 });
        defer hll.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| hll.addHash(k);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (0..1000) |_| sink +%= @intFromFloat(hll.cardinality());
        report("HyperLogLog (p=14)", a, t.nsPerOp(1000), hll.memoryBytes());
    }
    {
        var cms = try probz.DefaultCountMinSketch.initWithError(gpa, 0.001, 0.01);
        defer cms.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| try cms.addHash(k, 1);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| sink +%= cms.countHash(k);
        report("CountMinSketch (e=.001)", a, t.nsPerOp(n), cms.memoryBytes());
    }
    {
        var ss = try probz.SpaceSaving.init(gpa, .{ .capacity = 1000 });
        defer ss.deinit(gpa);
        var buf: [8]u8 = undefined;
        var t = Timer.begin();
        for (keys) |k| {
            // Skewed stream over 100k distinct keys.
            std.mem.writeInt(u64, &buf, keys[(k % 1000) * (k % 100)], .little);
            try ss.add(gpa, &buf, 1);
        }
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (keys) |k| {
            std.mem.writeInt(u64, &buf, k, .little);
            sink +%= ss.count(&buf);
        }
        report("SpaceSaving (m=1000)", a, t.nsPerOp(n), ss.len() * @sizeOf(probz.SpaceSaving.Entry));
    }
    {
        var td = try probz.TDigest.init(gpa, .{ .compression = 100 });
        defer td.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| try td.add(@floatFromInt(k >> 11));
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (0..100_000) |i| sink +%= @intFromFloat(try td.quantile(@as(f64, @floatFromInt(i)) / 100_000));
        report("TDigest (delta=100)", a, t.nsPerOp(100_000), td.memoryBytes());
    }
    {
        var qd = try probz.QDigest.init(gpa, .{ .log_universe = 32, .k = 256 });
        defer qd.deinit(gpa);
        var t = Timer.begin();
        for (keys) |k| try qd.add(gpa, k >> 32);
        const a = t.nsPerOp(n);
        t = Timer.begin();
        for (0..1000) |i| sink +%= try qd.quantile(@as(f64, @floatFromInt(i)) / 1000);
        report("QDigest (2^32, k=256)", a, t.nsPerOp(1000), qd.nodeCount() * 16);
    }
    {
        var lsh = try probz.MinHashLSH.init(gpa, .{ .bands = 16, .rows = 8 });
        defer lsh.deinit(gpa);
        const docs = 10_000;
        var tok: [20][8]u8 = undefined;
        var tokens: [20][]const u8 = undefined;
        var t = Timer.begin();
        for (0..docs) |d| {
            for (&tok, &tokens, 0..) |*b, *s, j| {
                std.mem.writeInt(u64, b, keys[(d + j) % n], .little);
                s.* = b;
            }
            var idbuf: [16]u8 = undefined;
            try lsh.add(gpa, try std.fmt.bufPrint(&idbuf, "{d}", .{d}), &tokens);
        }
        const a = t.nsPerOp(docs);
        t = Timer.begin();
        for (0..1000) |d| {
            for (&tok, &tokens, 0..) |*b, *s, j| {
                std.mem.writeInt(u64, b, keys[(d + j) % n], .little);
                s.* = b;
            }
            const res = try lsh.query(gpa, &tokens);
            sink +%= res.len;
            gpa.free(res);
        }
        report("MinHashLSH (128 h, 20 tok)", a, t.nsPerOp(1000), lsh.len() * lsh.numHashes() * @sizeOf(u64));
    }

    try comparable(gpa, &sink);

    std.debug.print("\n(checksum {d})\n", .{sink});
}

// Section 2: the same setup as github.com/nalgeon/unsure's bench/ package,
// so numbers can be compared side by side on one machine. Keys are 16 bytes
// (u64 seed, u64 index, little-endian) and every operation hashes its key.
// A loop cycles through 1M distinct keys. Structures are pre-filled so the
// timed loop measures the steady state.

const cycle = 1_000_000;

fn makeKeys(gpa: std.mem.Allocator, seed: u64, count: usize) ![][16]u8 {
    const ks = try gpa.alloc([16]u8, count);
    for (ks, 0..) |*k, i| {
        std.mem.writeInt(u64, k[0..8], seed, .little);
        std.mem.writeInt(u64, k[8..16], i, .little);
    }
    return ks;
}

fn row(comptime fmt: []const u8, args: anytype, ns: f64) void {
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, fmt, args) catch "?";
    std.debug.print("  {s:<40} {d:>10.1} ns/op\n", .{ name, ns });
}

/// Normally distributed values (Box–Muller over SplitMix64), as in
/// unsure's t-digest benchmarks.
fn normals(gpa: std.mem.Allocator, seed: u64, count: usize) ![]f64 {
    var rng = probz.hash.SplitMix64.init(seed);
    const xs = try gpa.alloc(f64, count);
    for (xs) |*x| {
        const u1_: f64 = (@as(f64, @floatFromInt(rng.next() >> 11)) + 1) / 0x1p53;
        const u2_: f64 = @as(f64, @floatFromInt(rng.next() >> 11)) / 0x1p53;
        x.* = @sqrt(-2 * @log(u1_)) * @cos(2 * std.math.pi * u2_);
    }
    return xs;
}

fn comparable(gpa: std.mem.Allocator, sink: *u64) !void {
    std.debug.print("\nComparable to nalgeon/unsure (16-byte keys, hashing included)\n\n", .{});

    const keys1 = try makeKeys(gpa, 1, cycle);
    defer gpa.free(keys1);
    const keys2 = try makeKeys(gpa, 2, cycle);
    defer gpa.free(keys2);
    const keys3 = try makeKeys(gpa, 3, cycle);
    defer gpa.free(keys3);

    // Bloom, p = 1%.
    for ([_]usize{ 10_000, 1_000_000, 50_000_000 }) |size| {
        inline for (.{probz.BloomFilter}) |F| {
            const label = if (F == probz.BloomFilter) "Bloom" else "BlockedBloom";
            var f = try F.init(gpa, .{ .expected_items = size, .fp_rate = 0.01 });
            defer f.deinit(gpa);
            var key: [16]u8 = undefined;
            std.mem.writeInt(u64, key[0..8], 1, .little);
            for (0..size) |i| {
                std.mem.writeInt(u64, key[8..16], i, .little);
                f.add(&key);
            }
            const live = keys1[0..@min(size, cycle)];
            const ops = cycle;
            var t = Timer.begin();
            for (0..ops) |i| sink.* += @intFromBool(f.contains(&live[i % live.len]));
            row("{s} hit n={d}", .{ label, size }, t.nsPerOp(ops));
            t = Timer.begin();
            for (0..ops) |i| sink.* += @intFromBool(f.contains(&keys2[i % live.len]));
            row("{s} miss n={d}", .{ label, size }, t.nsPerOp(ops));
            var fp: usize = 0;
            for (keys2) |*k| fp += @intFromBool(f.contains(k));
            std.debug.print("  {s} n={d}: {d:.2} bits/item, measured FPR {d:.3}%\n", .{
                label,
                size,
                @as(f64, @floatFromInt(f.memoryBytes() * 8)) / @as(f64, @floatFromInt(size)),
                @as(f64, @floatFromInt(fp)) * 100 / cycle,
            });
            // Add last: it overfills the filter. Its cost doesn't depend on load.
            t = Timer.begin();
            for (0..ops) |i| f.add(&keys3[i % cycle]);
            row("{s} add n={d}", .{ label, size }, t.nsPerOp(ops));
        }
    }

    // Count-Min, δ = 0.01.
    for ([_]f64{ 1e-3, 1e-5, 1e-6 }) |eps| {
        inline for (.{false}) |conservative| {
            const label = if (conservative) "CountMin(cu)" else "CountMin";
            var s = try probz.DefaultCountMinSketch.initWithError(gpa, eps, 0.01);
            defer s.deinit(gpa);
            for (keys3) |*k| try s.add(k, 1);
            var t = Timer.begin();
            for (keys1) |*k| try s.add(k, 1);
            row("{s} add eps={e}", .{ label, eps }, t.nsPerOp(cycle));
            t = Timer.begin();
            for (keys1) |*k| sink.* +%= s.count(k);
            row("{s} count eps={e}", .{ label, eps }, t.nsPerOp(cycle));
        }
    }

    // HyperLogLog.
    for ([_]u5{ 10, 14, 18 }) |p| {
        var s = try probz.HyperLogLog.init(gpa, .{ .precision = p });
        defer s.deinit(gpa);
        for (keys3) |*k| s.add(k);
        var t = Timer.begin();
        for (keys1) |*k| s.add(k);
        row("HLL add p={d}", .{p}, t.nsPerOp(cycle));
        const reps = 10_000;
        t = Timer.begin();
        for (0..reps) |_| sink.* +%= @intFromFloat(s.cardinality());
        row("HLL count p={d}", .{p}, t.nsPerOp(reps));

        var other = try probz.HyperLogLog.init(gpa, .{ .precision = p });
        defer other.deinit(gpa);
        for (keys2) |*k| other.add(k);
        try s.merge(other);
        t = Timer.begin();
        for (0..1000) |_| try s.merge(other);
        row("HLL merge(same) p={d}", .{p}, t.nsPerOp(1000));
    }

    // t-digest over normal values.
    const xs1 = try normals(gpa, 1, cycle);
    defer gpa.free(xs1);
    const xs2 = try normals(gpa, 2, cycle);
    defer gpa.free(xs2);
    for ([_]f64{ 50, 100, 500 }) |delta| {
        var d = try probz.TDigest.init(gpa, .{ .compression = delta });
        defer d.deinit(gpa);
        for (xs2) |x| try d.add(x);
        var t = Timer.begin();
        for (xs1) |x| try d.add(x);
        row("TDigest add delta={d}", .{delta}, t.nsPerOp(cycle));
        d.flush();
        const qs = [_]f64{ 0.5, 0.9, 0.99, 0.999, 0.1, 0.01 };
        const reps = 1_000_000;
        t = Timer.begin();
        for (0..reps) |i| sink.* +%= @bitCast(try d.quantile(qs[i % qs.len]));
        row("TDigest quantile delta={d}", .{delta}, t.nsPerOp(reps));

        var others: [8]probz.TDigest = undefined;
        for (&others, 0..) |*o, i| {
            o.* = try probz.TDigest.init(gpa, .{ .compression = delta });
            const vs = try normals(gpa, i + 2, cycle / 10);
            defer gpa.free(vs);
            for (vs) |x| try o.add(x);
            o.flush();
        }
        defer for (&others) |*o| o.deinit(gpa);
        const merges = 10_000;
        t = Timer.begin();
        for (0..merges) |i| try d.merge(others[i % others.len]);
        row("TDigest merge delta={d}", .{delta}, t.nsPerOp(merges));
        std.debug.print("  TDigest delta={d}: {d} bytes\n", .{ delta, d.memoryBytes() });
    }
}
