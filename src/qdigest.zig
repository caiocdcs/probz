//! q-digest: quantiles over integer values in [0, σ) using a sparse,
//! compressed binary tree of buckets. See SPEC.md §5.10.
//!
//! The universe [0, σ), σ = 2^b, is the leaf level of a complete binary
//! tree; every tree node is a bucket covering a dyadic range and may hold
//! a count. With compression parameter k and total count n, a node is kept
//! only if (paper §3.1):
//!
//!   (1) count(v) ≤ ⌊n/k⌋                                   (except leaves)
//!   (2) count(v) + count(parent) + count(sibling) > ⌊n/k⌋   (except the root)
//!
//! COMPRESS (Algorithm 1) restores (2) bottom-up by folding small sibling
//! pairs into their parent. Quantiles scan the nodes in post-order
//! (increasing range end, smaller ranges first) and report the range end
//! where the running count first exceeds q·n (§4.1). The reported value's
//! rank is between q·n and (q + ε)·n with ε = log₂(σ) / k (Theorem 1), and
//! a compressed digest has at most 3k nodes (Lemma 1). Merging adds the
//! counts of identical buckets and compresses (Algorithm 2).
//!
//! Notes: the paper indexes values 1..σ; probz uses 0..σ−1. Algorithm 1
//! as printed merges when the sum is < ⌊n/k⌋; probz merges when it is
//! ≤ ⌊n/k⌋, which is exactly a violation of property (2). For streaming
//! use, probz compresses whenever the digest grows past 6k nodes.
//!
//! # References
//!
//! - Nisheeth Shrivastava, Chiranjeeb Buragohain, Divyakant Agrawal,
//!   Subhash Suri, "Medians and Beyond: New Aggregation Techniques for
//!   Sensor Networks", SenSys 2004, pp. 239–249. §3.1 (digest property),
//!   Algorithm 1 (COMPRESS), Algorithm 2 (MERGE), §4.1 (quantile query).
//!   https://doi.org/10.1145/1031495.1031524
//!   (arXiv: https://arxiv.org/abs/cs/0408039)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const QDigest = struct {
    /// log₂ σ.
    log_universe: u6,
    k: u32,
    /// Node id → count. Root is 1; node i has children 2i and 2i+1; the
    /// leaf for value v is σ + v.
    nodes: std.AutoHashMapUnmanaged(u64, u64),
    total: u64,
    /// Sort buffer for queries; kept at least as large as `nodes`.
    scratch: std.ArrayList(Node),

    pub const Node = struct {
        id: u64,
        count: u64,

        /// Inclusive value range [lo, hi] covered by the node.
        pub fn range(self: Node, log_universe: u6) struct { lo: u64, hi: u64 } {
            const depth: u6 = @intCast(63 - @clz(self.id));
            const width = @as(u64, 1) << (log_universe - depth);
            const lo = (self.id - (@as(u64, 1) << depth)) * width;
            return .{ .lo = lo, .hi = lo + width - 1 };
        }
    };

    pub const Options = struct {
        /// Values are in [0, 2^log_universe); 1..63.
        log_universe: u6,
        /// Compression k ≥ 1: rank error ≤ log_universe / k · n, at most
        /// 3k nodes after compression.
        k: u32,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const AddError = error{ OutOfRange, Overflow } || Allocator.Error;
    pub const MergeError = error{ IncompatibleDigests, Overflow } || Allocator.Error;
    pub const QueryError = error{ EmptyDigest, InvalidParameters };

    pub fn init(allocator: Allocator, options: Options) InitError!QDigest {
        if (options.log_universe == 0 or options.k == 0) return error.InvalidParameters;
        var self: QDigest = .{
            .log_universe = options.log_universe,
            .k = options.k,
            .nodes = .empty,
            .total = 0,
            .scratch = .empty,
        };
        errdefer self.deinit(allocator);
        try self.nodes.ensureTotalCapacity(allocator, self.compressThreshold() + 1);
        try self.scratch.ensureTotalCapacity(allocator, self.compressThreshold() + 1);
        return self;
    }

    pub fn deinit(self: *QDigest, allocator: Allocator) void {
        self.nodes.deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = undefined;
    }

    pub fn universe(self: QDigest) u64 {
        return @as(u64, 1) << self.log_universe;
    }

    /// Relative rank error bound ε = log₂ σ / k.
    pub fn errorBound(self: QDigest) f64 {
        return @as(f64, @floatFromInt(self.log_universe)) / @as(f64, @floatFromInt(self.k));
    }

    fn compressThreshold(self: QDigest) u32 {
        return 6 * self.k;
    }

    pub fn add(self: *QDigest, allocator: Allocator, value: u64) AddError!void {
        return self.addWeighted(allocator, value, 1);
    }

    /// Add `weight` copies of `value` (must be < σ).
    pub fn addWeighted(self: *QDigest, allocator: Allocator, value: u64, weight: u64) AddError!void {
        if (value >= self.universe()) return error.OutOfRange;
        if (weight == 0) return;
        const new_total = math.add(u64, self.total, weight) catch return error.Overflow;
        const gop = try self.nodes.getOrPut(allocator, self.universe() + value);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = math.add(u64, gop.value_ptr.*, weight) catch {
            if (gop.value_ptr.* == 0) _ = self.nodes.remove(self.universe() + value);
            return error.Overflow;
        };
        self.total = new_total;
        if (self.nodes.count() > self.compressThreshold()) try self.compress(allocator);
        try self.scratch.ensureTotalCapacity(allocator, self.nodes.count());
    }

    /// Algorithm 1: from the leaf level up to the root's children, fold a
    /// sibling pair into its parent when count(v) + count(sibling) +
    /// count(parent) ≤ ⌊n/k⌋.
    pub fn compress(self: *QDigest, allocator: Allocator) Allocator.Error!void {
        const limit = self.total / self.k;
        // Collect ids by depth, deepest first; parents created on the way
        // are appended to the next level's list.
        var levels: [64]std.ArrayList(u64) = @splat(.empty);
        defer for (&levels) |*l| l.deinit(allocator);
        var it = self.nodes.keyIterator();
        while (it.next()) |id| try levels[63 - @clz(id.*)].append(allocator, id.*);

        var depth: usize = self.log_universe;
        while (depth >= 1) : (depth -= 1) {
            const ids = levels[depth].items;
            std.mem.sort(u64, ids, {}, std.sort.asc(u64));
            for (ids) |id| {
                // Each pair once, from its left child; skip ids already folded.
                const left = id & ~@as(u64, 1);
                if (id != left and self.nodes.contains(left)) continue;
                const right = left | 1;
                const parent = left >> 1;
                const cl = self.nodes.get(left) orelse 0;
                const cr = self.nodes.get(right) orelse 0;
                if (cl == 0 and cr == 0) continue;
                const cp = self.nodes.get(parent) orelse 0;
                if (cl + cr + cp <= limit) {
                    _ = self.nodes.remove(left);
                    _ = self.nodes.remove(right);
                    if (cp == 0) try levels[depth - 1].append(allocator, parent);
                    try self.nodes.put(allocator, parent, cp + cl + cr);
                }
            }
        }
        try self.scratch.ensureTotalCapacity(allocator, self.nodes.count());
    }

    /// Nodes in post-order: increasing range end, then smaller ranges
    /// (deeper nodes, larger ids) first. Uses the scratch buffer.
    fn sortedNodes(self: *QDigest) []Node {
        self.scratch.clearRetainingCapacity();
        var it = self.nodes.iterator();
        while (it.next()) |e| self.scratch.appendAssumeCapacity(.{ .id = e.key_ptr.*, .count = e.value_ptr.* });
        const Ctx = struct {
            b: u6,
            fn lessThan(ctx: @This(), a: Node, c: Node) bool {
                const ra = a.range(ctx.b);
                const rc = c.range(ctx.b);
                if (ra.hi != rc.hi) return ra.hi < rc.hi;
                return a.id > c.id;
            }
        };
        std.mem.sort(Node, self.scratch.items, Ctx{ .b = self.log_universe }, Ctx.lessThan);
        return self.scratch.items;
    }

    /// §4.1: the range end of the first node (in post-order) where the
    /// running count exceeds q·n. For q = 1 the largest range end.
    pub fn quantile(self: *QDigest, q: f64) QueryError!u64 {
        if (!(q >= 0 and q <= 1)) return error.InvalidParameters;
        if (self.total == 0) return error.EmptyDigest;
        const target = q * @as(f64, @floatFromInt(self.total));
        const nodes = self.sortedNodes();
        var sum: u64 = 0;
        for (nodes) |node| {
            sum += node.count;
            if (@as(f64, @floatFromInt(sum)) > target) return node.range(self.log_universe).hi;
        }
        return nodes[nodes.len - 1].range(self.log_universe).hi;
    }

    /// Lower bound on the number of values ≤ x: the total count of nodes
    /// whose whole range is ≤ x.
    pub fn rank(self: QDigest, x: u64) u64 {
        var sum: u64 = 0;
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            const node: Node = .{ .id = e.key_ptr.*, .count = e.value_ptr.* };
            if (node.range(self.log_universe).hi <= x) sum += node.count;
        }
        return sum;
    }

    /// Algorithm 2: add counts of identical buckets, then compress with the
    /// combined total. Both digests must share σ and k.
    pub fn merge(self: *QDigest, allocator: Allocator, other: QDigest) MergeError!void {
        if (self.log_universe != other.log_universe or self.k != other.k) return error.IncompatibleDigests;
        const new_total = math.add(u64, self.total, other.total) catch return error.Overflow;
        var it = other.nodes.iterator();
        while (it.next()) |e| {
            const gop = try self.nodes.getOrPut(allocator, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += e.value_ptr.*; // cannot overflow: sum ≤ new_total
        }
        self.total = new_total;
        try self.compress(allocator);
    }

    pub fn count(self: QDigest) u64 {
        return self.total;
    }

    pub fn nodeCount(self: QDigest) usize {
        return self.nodes.count();
    }

    pub fn clear(self: *QDigest) void {
        self.nodes.clearRetainingCapacity();
        self.total = 0;
    }

    /// Body (tag 10): u8 log σ, u32 k, u64 n, u32 node count, then nodes
    /// sorted by id ascending, each u64 id, u64 count.
    pub fn serialize(self: QDigest, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .qdigest);
        try w.writeByte(self.log_universe);
        try serde.writeInt(w, u32, self.k);
        try serde.writeInt(w, u64, self.total);
        try serde.writeInt(w, u32, @intCast(self.nodes.count()));
        // Ascending id order without allocating: repeated minimum search is
        // O(nodes²) but keeps serialize allocation-free and deterministic.
        var last: u64 = 0;
        for (0..self.nodes.count()) |_| {
            var best: u64 = math.maxInt(u64);
            var it = self.nodes.keyIterator();
            while (it.next()) |id| {
                if (id.* > last and id.* < best) best = id.*;
            }
            try serde.writeInt(w, u64, best);
            try serde.writeInt(w, u64, self.nodes.get(best).?);
            last = best;
        }
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!QDigest {
        try serde.readHeader(r, .qdigest);
        const b = try r.takeByte();
        if (b == 0 or b > 63) return error.InvalidData;
        var self = init(allocator, .{ .log_universe = @intCast(b), .k = try serde.readInt(r, u32) }) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        self.total = try serde.readInt(r, u64);
        const n = try serde.readInt(r, u32);
        var sum: u64 = 0;
        var prev: u64 = 0;
        for (0..n) |_| {
            const id = try serde.readInt(r, u64);
            const c = try serde.readInt(r, u64);
            if (id <= prev or id >= 2 * self.universe() or c == 0) return error.InvalidData;
            sum = math.add(u64, sum, c) catch return error.InvalidData;
            try self.nodes.put(allocator, id, c);
            prev = id;
        }
        if (sum != self.total) return error.InvalidData;
        try self.scratch.ensureTotalCapacity(allocator, self.nodes.count());
        return self;
    }
};

const testing = std.testing;

test "init and range checks" {
    try testing.expectError(error.InvalidParameters, QDigest.init(testing.allocator, .{ .log_universe = 0, .k = 10 }));
    try testing.expectError(error.InvalidParameters, QDigest.init(testing.allocator, .{ .log_universe = 10, .k = 0 }));
    var qd = try QDigest.init(testing.allocator, .{ .log_universe = 4, .k = 4 });
    defer qd.deinit(testing.allocator);
    try testing.expectError(error.OutOfRange, qd.add(testing.allocator, 16));
    try testing.expectError(error.EmptyDigest, qd.quantile(0.5));
}

test "node ranges" {
    const b: u6 = 3; // values 0..7
    try testing.expectEqual(@as(u64, 0), (QDigest.Node{ .id = 1, .count = 0 }).range(b).lo);
    try testing.expectEqual(@as(u64, 7), (QDigest.Node{ .id = 1, .count = 0 }).range(b).hi);
    try testing.expectEqual(@as(u64, 4), (QDigest.Node{ .id = 3, .count = 0 }).range(b).lo);
    try testing.expectEqual(@as(u64, 5), (QDigest.Node{ .id = 13, .count = 0 }).range(b).lo); // leaf 8 + 5
    try testing.expectEqual(@as(u64, 5), (QDigest.Node{ .id = 13, .count = 0 }).range(b).hi);
}

test "digest property holds after compress (n = 15, k = 5, sigma = 8)" {
    // Same sizes as the paper's running example (§3.2), with our own values.
    var qd = try QDigest.init(testing.allocator, .{ .log_universe = 3, .k = 5 });
    defer qd.deinit(testing.allocator);
    for ([_]u64{ 0, 2, 3, 3, 3, 4, 4, 5, 5, 5, 5, 6, 6, 7, 7 }) |v| try qd.add(testing.allocator, v);
    try qd.compress(testing.allocator);
    try checkDigestProperty(qd);
}

fn checkDigestProperty(qd: QDigest) !void {
    const limit = qd.total / qd.k;
    var it = qd.nodes.iterator();
    while (it.next()) |e| {
        const id = e.key_ptr.*;
        const c = e.value_ptr.*;
        const is_leaf = id >= qd.universe();
        if (!is_leaf) try testing.expect(c <= limit); // property (1)
        if (id != 1) { // property (2)
            const sib = qd.nodes.get(id ^ 1) orelse 0;
            const par = qd.nodes.get(id >> 1) orelse 0;
            try testing.expect(c + sib + par > limit);
        }
    }
}

test "rank error within log(sigma)/k and size within 3k" {
    var qd = try QDigest.init(testing.allocator, .{ .log_universe = 16, .k = 200 });
    defer qd.deinit(testing.allocator);
    const n = 100_000;
    const data = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(data);
    var rng = std.Random.DefaultPrng.init(3);
    for (data) |*v| {
        // Skewed: square of a uniform value.
        const u = rng.random().intRangeLessThan(u64, 0, 256);
        v.* = u * u;
        try qd.add(testing.allocator, v.*);
    }
    try qd.compress(testing.allocator);
    try checkDigestProperty(qd);
    try testing.expect(qd.nodeCount() <= 3 * qd.k);

    std.mem.sort(u64, data, {}, std.sort.asc(u64));
    const eps = qd.errorBound();
    for ([_]f64{ 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99 }) |q| {
        const est = try qd.quantile(q);
        // Rank of the estimate: number of values <= est.
        const r = std.sort.upperBound(u64, data, est, struct {
            fn order(ctx: u64, item: u64) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.order);
        const rq = @as(f64, @floatFromInt(r)) / n;
        // §4.1: rank in [q, q + eps].
        try testing.expect(rq >= q and rq <= q + eps);
    }
}

test "merge" {
    var a = try QDigest.init(testing.allocator, .{ .log_universe = 10, .k = 20 });
    defer a.deinit(testing.allocator);
    var b = try QDigest.init(testing.allocator, .{ .log_universe = 10, .k = 20 });
    defer b.deinit(testing.allocator);
    for (0..1000) |i| {
        if (i % 2 == 0) try a.add(testing.allocator, i) else try b.add(testing.allocator, i);
    }
    try a.merge(testing.allocator, b);
    try testing.expectEqual(@as(u64, 1000), a.count());
    try checkDigestProperty(a);
    const median = try a.quantile(0.5);
    try testing.expect(median >= 500 and median <= 500 + 1000 * 10 / 20);

    var c = try QDigest.init(testing.allocator, .{ .log_universe = 11, .k = 20 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatibleDigests, a.merge(testing.allocator, c));
}

test "serialize round trip" {
    var qd = try QDigest.init(testing.allocator, .{ .log_universe = 8, .k = 10 });
    defer qd.deinit(testing.allocator);
    for (0..500) |i| try qd.add(testing.allocator, (i * 37) % 256);
    try qd.compress(testing.allocator);
    const bytes = try serde.toOwnedBytes(testing.allocator, qd);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try QDigest.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(qd.nodeCount(), back.nodeCount());
    for ([_]f64{ 0.1, 0.5, 0.9 }) |q| try testing.expectEqual(try qd.quantile(q), try back.quantile(q));
}
