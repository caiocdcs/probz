//! Space-Saving: streaming top-k / heavy hitters with m counters.
//! See SPEC.md §5.8.
//!
//! The summary monitors at most m distinct items. A monitored item's
//! counter is incremented. An unmonitored item replaces the item with the
//! smallest counter `min`, inheriting `min` as its over-estimation error
//! (paper §3). Guarantees (paper Lemmas 1–3):
//!
//! - Σ counters = N, the total weight of the stream;
//! - min ≤ N / m;
//! - for each monitored item: true ≤ count ≤ true + error, with error ≤ min;
//! - every item whose true frequency exceeds min is monitored, so m = ⌈1/ε⌉
//!   counters find every item with frequency > ε·N (paper §4).
//!
//! Weighted updates `add(item, w)` generalize the unit increment: a new
//! item replacing the minimum gets count = min + w and error = min.
//!
//! Eviction ties are broken deterministically: the evicted entry is the
//! one with the smallest (count, sequence), where sequence is the value of
//! a global update counter at the entry's last change. This makes results
//! identical across implementations.
//!
//! # References
//!
//! - Ahmed Metwally, Divyakant Agrawal, Amr El Abbadi, "Efficient
//!   Computation of Frequent and Top-k Elements in Data Streams", ICDT
//!   2005, LNCS 3363, pp. 398–412. §3 (algorithm, Lemmas 1–3), §4
//!   (queries). https://doi.org/10.1007/978-3-540-30570-5_27
//!   (technical report: https://www.cs.ucsb.edu/sites/default/files/documents/2005-23.pdf)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const SpaceSaving = struct {
    capacity: u32,
    entries: std.ArrayList(Entry),
    /// Min-heap of entry indexes, ordered by (count, seq).
    heap: std.ArrayList(u32),
    /// key -> entry index
    index: std.StringHashMapUnmanaged(u32),
    /// N
    total: u64,
    /// Global update counter, for deterministic tie-breaking.
    seq: u64,
    /// Index removals since the last rehash (tombstone cleanup).
    removals: u32 = 0,

    pub const Entry = struct {
        /// Owned copy of the item.
        key: []u8,
        /// Estimated count (an upper bound on the true count).
        count: u64,
        /// Maximum over-estimation: count − error ≤ true count.
        err: u64,
        seq: u64,
        /// Position of this entry in `heap`.
        heap_pos: u32,
    };

    /// One row of a top-k answer. `key` points into the summary and is
    /// valid until the next `add` or `deinit`.
    pub const Item = struct {
        key: []const u8,
        count: u64,
        err: u64,

        /// Lower bound on the true count.
        pub fn guaranteedCount(self: Item) u64 {
            return self.count - self.err;
        }
    };

    pub const Options = struct {
        /// Number of counters m (> 0). Use ⌈1/ε⌉ to find every item with
        /// frequency above ε·N.
        capacity: u32,
    };

    pub const InitError = error{InvalidParameters} || Allocator.Error;
    pub const AddError = error{Overflow} || Allocator.Error;

    pub fn init(allocator: Allocator, options: Options) InitError!SpaceSaving {
        if (options.capacity == 0) return error.InvalidParameters;
        var self: SpaceSaving = .{
            .capacity = options.capacity,
            .entries = .empty,
            .heap = .empty,
            .index = .empty,
            .total = 0,
            .seq = 0,
        };
        errdefer self.deinit(allocator);
        try self.entries.ensureTotalCapacity(allocator, options.capacity);
        try self.heap.ensureTotalCapacity(allocator, options.capacity);
        try self.index.ensureTotalCapacity(allocator, options.capacity);
        return self;
    }

    pub fn deinit(self: *SpaceSaving, allocator: Allocator) void {
        for (self.entries.items) |e| allocator.free(e.key);
        self.entries.deinit(allocator);
        self.heap.deinit(allocator);
        self.index.deinit(allocator);
        self.* = undefined;
    }

    /// Add `amount` occurrences of `item` (the key is copied when the item
    /// becomes monitored).
    pub fn add(self: *SpaceSaving, allocator: Allocator, item: []const u8, amount: u64) AddError!void {
        if (amount == 0) return;
        const new_total = math.add(u64, self.total, amount) catch return error.Overflow;

        if (self.index.get(item)) |i| {
            const e = &self.entries.items[i];
            e.count = math.add(u64, e.count, amount) catch return error.Overflow;
            self.seq += 1;
            e.seq = self.seq;
            self.siftDown(e.heap_pos);
        } else if (self.entries.items.len < self.capacity) {
            const key = try allocator.dupe(u8, item);
            errdefer allocator.free(key);
            const i: u32 = @intCast(self.entries.items.len);
            self.seq += 1;
            self.entries.appendAssumeCapacity(.{ .key = key, .count = amount, .err = 0, .seq = self.seq, .heap_pos = i });
            self.heap.appendAssumeCapacity(i);
            self.index.putAssumeCapacity(key, i);
            self.siftUp(i);
        } else {
            // Replacement step: evict the minimum.
            const i = self.heap.items[0];
            const e = &self.entries.items[i];
            const min = e.count;
            const new_count = math.add(u64, min, amount) catch return error.Overflow;
            const key = try allocator.dupe(u8, item);
            _ = self.index.remove(e.key);
            allocator.free(e.key);
            // Evictions leave tombstones in the index; rehash periodically
            // so lookups of absent keys stay short (amortized O(1)).
            self.removals += 1;
            if (self.removals >= self.index.capacity() / 2) {
                self.index.rehash(std.hash_map.StringContext{});
                self.removals = 0;
            }
            self.seq += 1;
            // Assign fields one by one: a struct literal assigned to `e.*`
            // would overwrite `e.count` before reading it.
            e.key = key;
            e.count = new_count;
            e.err = min;
            e.seq = self.seq;
            self.index.putAssumeCapacity(key, i);
            self.siftDown(0);
        }
        self.total = new_total;
    }

    /// Upper bound on the item's true count: its counter if monitored,
    /// otherwise the minimum counter (0 while fewer than m items are seen).
    pub fn count(self: SpaceSaving, item: []const u8) u64 {
        if (self.index.get(item)) |i| return self.entries.items[i].count;
        return self.minCount();
    }

    /// The monitored entry for an item, if any.
    pub fn get(self: SpaceSaving, item: []const u8) ?Item {
        const i = self.index.get(item) orelse return null;
        const e = self.entries.items[i];
        return .{ .key = e.key, .count = e.count, .err = e.err };
    }

    /// The smallest counter once all m counters are in use, else 0.
    pub fn minCount(self: SpaceSaving) u64 {
        if (self.entries.items.len < self.capacity) return 0;
        return self.entries.items[self.heap.items[0]].count;
    }

    /// The k entries with the largest counts, sorted by count descending,
    /// then key ascending. The caller frees the returned slice (not the keys).
    pub fn topK(self: SpaceSaving, allocator: Allocator, k: usize) Allocator.Error![]Item {
        const items = try allocator.alloc(Item, self.entries.items.len);
        for (self.entries.items, items) |e, *it| it.* = .{ .key = e.key, .count = e.count, .err = e.err };
        std.mem.sort(Item, items, {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
        const n = @min(k, items.len);
        if (n == items.len) return items;
        defer allocator.free(items);
        return allocator.dupe(Item, items[0..n]);
    }

    /// Number of monitored items.
    pub fn len(self: SpaceSaving) usize {
        return self.entries.items.len;
    }

    pub fn clear(self: *SpaceSaving, allocator: Allocator) void {
        for (self.entries.items) |e| allocator.free(e.key);
        self.entries.clearRetainingCapacity();
        self.heap.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.total = 0;
        self.seq = 0;
        self.removals = 0;
    }

    // -- heap ordered by (count, seq) -------------------------------------

    fn less(self: SpaceSaving, a: u32, b: u32) bool {
        const x = self.entries.items[a];
        const y = self.entries.items[b];
        if (x.count != y.count) return x.count < y.count;
        return x.seq < y.seq;
    }

    fn swapHeap(self: *SpaceSaving, i: u32, j: u32) void {
        const h = self.heap.items;
        std.mem.swap(u32, &h[i], &h[j]);
        self.entries.items[h[i]].heap_pos = i;
        self.entries.items[h[j]].heap_pos = j;
    }

    fn siftUp(self: *SpaceSaving, pos: u32) void {
        var i = pos;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!self.less(self.heap.items[i], self.heap.items[parent])) break;
            self.swapHeap(i, parent);
            i = parent;
        }
    }

    fn siftDown(self: *SpaceSaving, pos: u32) void {
        var i = pos;
        const n: u32 = @intCast(self.heap.items.len);
        while (true) {
            var smallest = i;
            const l = 2 * i + 1;
            const r = l + 1;
            if (l < n and self.less(self.heap.items[l], self.heap.items[smallest])) smallest = l;
            if (r < n and self.less(self.heap.items[r], self.heap.items[smallest])) smallest = r;
            if (smallest == i) break;
            self.swapHeap(i, smallest);
            i = smallest;
        }
    }

    /// Body (tag 8): u32 m, u64 N, u64 seq, u32 entry count, then per entry
    /// in insertion-slot order: bytes key, u64 count, u64 error, u64 seq.
    pub fn serialize(self: SpaceSaving, w: *std.Io.Writer) serde.WriteError!void {
        try serde.writeHeader(w, .space_saving);
        try serde.writeInt(w, u32, self.capacity);
        try serde.writeInt(w, u64, self.total);
        try serde.writeInt(w, u64, self.seq);
        try serde.writeInt(w, u32, @intCast(self.entries.items.len));
        for (self.entries.items) |e| {
            try serde.writeBytes(w, e.key);
            try serde.writeInt(w, u64, e.count);
            try serde.writeInt(w, u64, e.err);
            try serde.writeInt(w, u64, e.seq);
        }
    }

    pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!SpaceSaving {
        try serde.readHeader(r, .space_saving);
        const capacity = try serde.readInt(r, u32);
        var self = init(allocator, .{ .capacity = capacity }) catch |err| return serde.fromInitError(err);
        errdefer self.deinit(allocator);
        self.total = try serde.readInt(r, u64);
        self.seq = try serde.readInt(r, u64);
        const n = try serde.readInt(r, u32);
        if (n > capacity) return error.InvalidData;
        var sum: u64 = 0;
        for (0..n) |i| {
            const key = try serde.readBytes(r, allocator);
            errdefer allocator.free(key);
            const c = try serde.readInt(r, u64);
            const e = try serde.readInt(r, u64);
            const s = try serde.readInt(r, u64);
            if (e > c or s > self.seq or self.index.contains(key)) return error.InvalidData;
            sum = math.add(u64, sum, c) catch return error.InvalidData;
            self.entries.appendAssumeCapacity(.{ .key = key, .count = c, .err = e, .seq = s, .heap_pos = @intCast(i) });
            self.heap.appendAssumeCapacity(@intCast(i));
            self.index.putAssumeCapacity(key, @intCast(i));
            self.siftUp(@intCast(i));
        }
        if (sum != self.total) return error.InvalidData; // Lemma 1
        return self;
    }
};

const testing = std.testing;

test "exact while under capacity" {
    var ss = try SpaceSaving.init(testing.allocator, .{ .capacity = 10 });
    defer ss.deinit(testing.allocator);
    try ss.add(testing.allocator, "a", 5);
    try ss.add(testing.allocator, "b", 2);
    try ss.add(testing.allocator, "a", 1);
    try testing.expectEqual(@as(u64, 6), ss.count("a"));
    try testing.expectEqual(@as(u64, 2), ss.count("b"));
    try testing.expectEqual(@as(u64, 0), ss.count("c"));

    const top = try ss.topK(testing.allocator, 5);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 2), top.len);
    try testing.expectEqualStrings("a", top[0].key);
    try testing.expectEqual(@as(u64, 0), top[0].err);
}

test "replacement inherits the minimum as error" {
    var ss = try SpaceSaving.init(testing.allocator, .{ .capacity = 2 });
    defer ss.deinit(testing.allocator);
    try ss.add(testing.allocator, "a", 3);
    try ss.add(testing.allocator, "b", 1);
    try ss.add(testing.allocator, "c", 1); // evicts b (min 1)
    const c = ss.get("c").?;
    try testing.expectEqual(@as(u64, 2), c.count);
    try testing.expectEqual(@as(u64, 1), c.err);
    try testing.expect(ss.get("b") == null);
}

test "guarantees on a skewed stream" {
    const m = 100;
    var ss = try SpaceSaving.init(testing.allocator, .{ .capacity = m });
    defer ss.deinit(testing.allocator);
    var truth: std.StringHashMapUnmanaged(u64) = .empty;
    defer {
        var it = truth.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        truth.deinit(testing.allocator);
    }

    // Item i has weight ~ 10000 / (i + 1); interleave updates via an LCG.
    var buf: [32]u8 = undefined;
    var x: u64 = 1;
    for (0..200_000) |_| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const r = (x >> 33) % 10_000;
        const i = 10_000 / (r + 1) - 1; // skewed toward small i
        const item = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        try ss.add(testing.allocator, item, 1);
        const gop = try truth.getOrPut(testing.allocator, item);
        if (!gop.found_existing) {
            gop.key_ptr.* = try testing.allocator.dupe(u8, item);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    // Lemma 1: counters sum to N. Lemma 2: min <= N / m.
    var sum: u64 = 0;
    for (ss.entries.items) |e| sum += e.count;
    try testing.expectEqual(ss.total, sum);
    try testing.expect(ss.minCount() <= ss.total / m);

    // Lemma 3 for monitored items; every item with frequency > min is monitored.
    var it = truth.iterator();
    while (it.next()) |kv| {
        const f = kv.value_ptr.*;
        if (ss.get(kv.key_ptr.*)) |e| {
            try testing.expect(e.count >= f and e.count - e.err <= f and e.err <= ss.minCount());
        } else {
            try testing.expect(f <= ss.minCount());
        }
    }
}

test "serialize round trip" {
    var ss = try SpaceSaving.init(testing.allocator, .{ .capacity = 3 });
    defer ss.deinit(testing.allocator);
    for ([_][]const u8{ "a", "b", "a", "c", "d", "a", "e" }) |s| try ss.add(testing.allocator, s, 1);
    const bytes = try serde.toOwnedBytes(testing.allocator, ss);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try SpaceSaving.deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);

    const t1 = try ss.topK(testing.allocator, 3);
    defer testing.allocator.free(t1);
    const t2 = try back.topK(testing.allocator, 3);
    defer testing.allocator.free(t2);
    for (t1, t2) |a, b| {
        try testing.expectEqualStrings(a.key, b.key);
        try testing.expectEqual(a.count, b.count);
    }
    // The restored heap evicts the same entry next.
    try ss.add(testing.allocator, "z", 1);
    try back.add(testing.allocator, "z", 1);
    try testing.expectEqual(ss.get("z").?.err, back.get("z").?.err);
}
