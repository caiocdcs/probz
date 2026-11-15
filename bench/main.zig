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
        report("TDigest (delta=100)", a, t.nsPerOp(100_000), td.centroids.items.len * @sizeOf(probz.TDigest.Centroid));
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

    std.debug.print("\n(checksum {d})\n", .{sink});
}
