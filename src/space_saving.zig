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
//! Entries are kept in the paper's Stream-Summary structure (§3.2): a
//! list of buckets in ascending count order, each holding its entries in
//! ascending sequence order. A unit increment moves an entry to the tail of
//! the next bucket and an eviction takes the head of the first bucket, both
//! in O(1). An increment by w > 1 walks forward over the buckets with
//! counts below the new count.
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

const hashing = @import("hash.zig");
const serde = @import("serde.zig");

const nil = math.maxInt(u32);

pub const SpaceSaving = struct {
    capacity: u32,
    entries: std.ArrayList(Entry),
    /// Bucket pool; `first_bucket` heads the list in ascending count order.
    buckets: std.ArrayList(Bucket),
    first_bucket: u32 = nil,
    free_bucket: u32 = nil,
    /// Open-addressing index (linear probing): slot -> entry index or nil.
    /// Power-of-two size ≥ 2m, so the load factor stays ≤ 1/2.
    slots: []u32,
    /// N
    total: u64,
    /// Global update counter, for deterministic tie-breaking.
    seq: u64,

    pub const Entry = struct {
        /// Owned copy of the item: the first `key.len` bytes of a buffer of
        /// `key_cap` bytes, reused by later evictions when the key fits.
        key: []u8,
        key_cap: usize = 0,
        /// XxHash64 of the key (SPEC.md §2.1), for the index.
        hash: u64 = 0,
        /// Estimated count (an upper bound on the true count).
        count: u64,
        /// Maximum over-estimation: count − error ≤ true count.
        err: u64,
        seq: u64,
        /// Neighbours within the bucket (ascending seq) and the bucket.
        prev: u32 = nil,
        next: u32 = nil,
        bucket: u32 = nil,
    };

    /// All entries with one count, oldest (smallest seq) at `head`.
    const Bucket = struct {
        count: u64,
        head: u32,
        tail: u32,
        prev: u32,
        /// Next bucket (larger count), or the next free bucket.
        next: u32,
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
            .buckets = .empty,
            .slots = &.{},
            .total = 0,
            .seq = 0,
        };
        errdefer self.deinit(allocator);
        try self.entries.ensureTotalCapacity(allocator, options.capacity);
        // One bucket per distinct count, plus one while an entry moves.
        try self.buckets.ensureTotalCapacity(allocator, @as(usize, options.capacity) + 1);
        const slot_count = math.ceilPowerOfTwo(usize, 2 * @as(usize, options.capacity)) catch return error.OutOfMemory;
        self.slots = try allocator.alloc(u32, slot_count);
        @memset(self.slots, nil);
        return self;
    }

    pub fn deinit(self: *SpaceSaving, allocator: Allocator) void {
        for (self.entries.items) |e| allocator.free(e.key.ptr[0..e.key_cap]);
        self.entries.deinit(allocator);
        self.buckets.deinit(allocator);
        allocator.free(self.slots);
        self.* = undefined;
    }

    /// Add `amount` occurrences of `item` (the key is copied when the item
    /// becomes monitored).
    pub fn add(self: *SpaceSaving, allocator: Allocator, item: []const u8, amount: u64) AddError!void {
        if (amount == 0) return;
        const new_total = math.add(u64, self.total, amount) catch return error.Overflow;
        const h = hashing.hashBytes(item);

        if (self.lookup(h, item)) |i| {
            const e = &self.entries.items[i];
            const new_count = math.add(u64, e.count, amount) catch return error.Overflow;
            self.seq += 1;
            e.seq = self.seq;
            self.moveTo(i, new_count);
        } else if (self.entries.items.len < self.capacity) {
            const key = try allocator.dupe(u8, item);
            errdefer allocator.free(key);
            const i: u32 = @intCast(self.entries.items.len);
            self.seq += 1;
            self.entries.appendAssumeCapacity(.{ .key = key, .key_cap = key.len, .hash = h, .count = amount, .err = 0, .seq = self.seq });
            self.insertIndex(i);
            self.attach(i, self.findBucket(nil, amount));
        } else {
            // Replacement step: evict the oldest entry with the minimum count.
            const i = self.buckets.items[self.first_bucket].head;
            const e = &self.entries.items[i];
            const min = e.count;
            const new_count = math.add(u64, min, amount) catch return error.Overflow;
            // Reuse the evicted key's buffer when the new key fits.
            const fresh: ?[]u8 = if (item.len > e.key_cap) try allocator.dupe(u8, item) else null;
            self.removeIndex(i);
            const key = if (fresh) |f| blk: {
                allocator.free(e.key.ptr[0..e.key_cap]);
                e.key_cap = f.len;
                break :blk f;
            } else blk: {
                const k = e.key.ptr[0..item.len];
                @memcpy(k, item);
                break :blk k;
            };
            self.seq += 1;
            // Assign fields one by one: a struct literal assigned to `e.*`
            // would overwrite `e.count` before reading it.
            e.key = key;
            e.hash = h;
            e.err = min;
            e.seq = self.seq;
            self.insertIndex(i);
            self.moveTo(i, new_count);
        }
        self.total = new_total;
    }

    /// Upper bound on the item's true count: its counter if monitored,
    /// otherwise the minimum counter (0 while fewer than m items are seen).
    pub fn count(self: SpaceSaving, item: []const u8) u64 {
        if (self.lookup(hashing.hashBytes(item), item)) |i| return self.entries.items[i].count;
        return self.minCount();
    }

    /// The monitored entry for an item, if any.
    pub fn get(self: SpaceSaving, item: []const u8) ?Item {
        const i = self.lookup(hashing.hashBytes(item), item) orelse return null;
        const e = self.entries.items[i];
        return .{ .key = e.key, .count = e.count, .err = e.err };
    }

    /// The smallest counter once all m counters are in use, else 0.
    pub fn minCount(self: SpaceSaving) u64 {
        if (self.entries.items.len < self.capacity) return 0;
        return self.buckets.items[self.first_bucket].count;
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
        for (self.entries.items) |e| allocator.free(e.key.ptr[0..e.key_cap]);
        self.entries.clearRetainingCapacity();
        self.buckets.clearRetainingCapacity();
        self.first_bucket = nil;
        self.free_bucket = nil;
        @memset(self.slots, nil);
        self.total = 0;
        self.seq = 0;
    }

    // -- index ------------------------------------------------------------

    fn lookup(self: SpaceSaving, h: u64, key: []const u8) ?u32 {
        const mask = self.slots.len - 1;
        var pos: usize = @intCast(h & mask);
        while (true) : (pos = (pos + 1) & mask) {
            const i = self.slots[pos];
            if (i == nil) return null;
            const e = &self.entries.items[i];
            if (e.hash == h and std.mem.eql(u8, e.key, key)) return i;
        }
    }

    fn insertIndex(self: *SpaceSaving, i: u32) void {
        const mask = self.slots.len - 1;
        var pos: usize = @intCast(self.entries.items[i].hash & mask);
        while (self.slots[pos] != nil) pos = (pos + 1) & mask;
        self.slots[pos] = i;
    }

    /// Remove entry i with backward-shift deletion: later entries of the
    /// probe run move back into the hole, so no tombstones are left.
    fn removeIndex(self: *SpaceSaving, i: u32) void {
        const mask = self.slots.len - 1;
        var hole: usize = @intCast(self.entries.items[i].hash & mask);
        while (self.slots[hole] != i) hole = (hole + 1) & mask;
        var j = hole;
        while (true) {
            j = (j + 1) & mask;
            const s = self.slots[j];
            if (s == nil) break;
            const home: usize = @intCast(self.entries.items[s].hash & mask);
            // Keep s if its home lies cyclically in (hole, j]; else move it.
            const stays = if (hole <= j) (hole < home and home <= j) else (hole < home or home <= j);
            if (!stays) {
                self.slots[hole] = s;
                hole = j;
            }
        }
        self.slots[hole] = nil;
    }

    // -- Stream-Summary ---------------------------------------------------

    /// The bucket with count `c`, created if needed. Searches forward from
    /// the bucket after `from` (or from the first bucket if `from` is nil);
    /// every bucket up to `from` must have a count below `c`.
    fn findBucket(self: *SpaceSaving, from: u32, c: u64) u32 {
        const bs = self.buckets.items;
        var prev = from;
        var cur = if (from == nil) self.first_bucket else bs[from].next;
        while (cur != nil and bs[cur].count < c) {
            prev = cur;
            cur = bs[cur].next;
        }
        if (cur != nil and bs[cur].count == c) return cur;
        // Insert a new bucket between prev and cur.
        const b = if (self.free_bucket != nil) blk: {
            const f = self.free_bucket;
            self.free_bucket = self.buckets.items[f].next;
            break :blk f;
        } else blk: {
            self.buckets.appendAssumeCapacity(undefined);
            break :blk @as(u32, @intCast(self.buckets.items.len - 1));
        };
        const all = self.buckets.items;
        all[b] = .{ .count = c, .head = nil, .tail = nil, .prev = prev, .next = cur };
        if (prev == nil) self.first_bucket = b else all[prev].next = b;
        if (cur != nil) all[cur].prev = b;
        return b;
    }

    /// Append entry i at the tail of bucket b (it has the newest seq).
    fn attach(self: *SpaceSaving, i: u32, b: u32) void {
        const bucket = &self.buckets.items[b];
        const e = &self.entries.items[i];
        e.bucket = b;
        e.count = bucket.count;
        e.prev = bucket.tail;
        e.next = nil;
        if (bucket.tail == nil) bucket.head = i else self.entries.items[bucket.tail].next = i;
        bucket.tail = i;
    }

    /// Unlink entry i from its bucket, freeing the bucket if it empties.
    fn detach(self: *SpaceSaving, i: u32) void {
        const e = self.entries.items[i];
        const bs = self.buckets.items;
        const bucket = &bs[e.bucket];
        if (e.prev == nil) bucket.head = e.next else self.entries.items[e.prev].next = e.next;
        if (e.next == nil) bucket.tail = e.prev else self.entries.items[e.next].prev = e.prev;
        if (bucket.head != nil) return;
        if (bucket.prev == nil) self.first_bucket = bucket.next else bs[bucket.prev].next = bucket.next;
        if (bucket.next != nil) bs[bucket.next].prev = bucket.prev;
        bucket.next = self.free_bucket;
        self.free_bucket = e.bucket;
    }

    /// Move entry i (seq already updated) to the bucket for `new_count`.
    fn moveTo(self: *SpaceSaving, i: u32, new_count: u64) void {
        const target = self.findBucket(self.entries.items[i].bucket, new_count);
        self.detach(i);
        self.attach(i, target);
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
            const h = hashing.hashBytes(key);
            if (e > c or s > self.seq or self.lookup(h, key) != null) return error.InvalidData;
            sum = math.add(u64, sum, c) catch return error.InvalidData;
            self.entries.appendAssumeCapacity(.{ .key = key, .key_cap = key.len, .hash = h, .count = c, .err = e, .seq = s });
            self.insertIndex(@intCast(i));
        }
        if (sum != self.total) return error.InvalidData; // Lemma 1

        // Rebuild the Stream-Summary: attach in (count, seq) order.
        const order = try allocator.alloc(u32, n);
        defer allocator.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, self.entries.items, struct {
            fn lessThan(es: []const Entry, a: u32, b: u32) bool {
                if (es[a].count != es[b].count) return es[a].count < es[b].count;
                if (es[a].seq != es[b].seq) return es[a].seq < es[b].seq;
                return a < b;
            }
        }.lessThan);
        var last: u32 = nil;
        for (order) |i| {
            const c = self.entries.items[i].count;
            if (last == nil or self.buckets.items[last].count != c) last = self.findBucket(last, c);
            self.attach(i, last);
        }
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

/// Reference model: evict the entry with the smallest (count, seq) by
/// linear scan, as SPEC.md §5.8 states it.
const Model = struct {
    keys: [64][]const u8 = undefined,
    counts: [64]u64 = undefined,
    errs: [64]u64 = undefined,
    seqs: [64]u64 = undefined,
    n: usize = 0,
    seq: u64 = 0,

    fn add(m: *Model, cap: usize, key: []const u8, w: u64) void {
        for (0..m.n) |i| if (std.mem.eql(u8, m.keys[i], key)) {
            m.counts[i] += w;
            m.seq += 1;
            m.seqs[i] = m.seq;
            return;
        };
        m.seq += 1;
        if (m.n < cap) {
            m.keys[m.n] = key;
            m.counts[m.n] = w;
            m.errs[m.n] = 0;
            m.seqs[m.n] = m.seq;
            m.n += 1;
            return;
        }
        var v: usize = 0;
        for (1..m.n) |i| {
            if (m.counts[i] < m.counts[v] or (m.counts[i] == m.counts[v] and m.seqs[i] < m.seqs[v])) v = i;
        }
        m.keys[v] = key;
        m.errs[v] = m.counts[v];
        m.counts[v] += w;
        m.seqs[v] = m.seq;
    }
};

test "matches the linear-scan model, including weighted adds and ties" {
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" };
    for ([_]u32{ 1, 2, 3, 5, 8 }) |cap| {
        var ss = try SpaceSaving.init(testing.allocator, .{ .capacity = cap });
        defer ss.deinit(testing.allocator);
        var model: Model = .{};
        var rng = @import("hash.zig").SplitMix64.init(cap);
        for (0..5000) |step| {
            const key = names[@min(rng.below(names.len), rng.below(names.len))];
            const w: u64 = if (rng.below(4) == 0) 1 + rng.below(5) else 1;
            try ss.add(testing.allocator, key, w);
            model.add(cap, key, w);
            if (step % 97 == 0) {
                // Round-trip mid-stream: the rebuilt structure must agree.
                const bytes = try serde.toOwnedBytes(testing.allocator, ss);
                defer testing.allocator.free(bytes);
                var r: std.Io.Reader = .fixed(bytes);
                const back = try SpaceSaving.deserialize(testing.allocator, &r);
                ss.deinit(testing.allocator);
                ss = back;
            }
        }
        try testing.expectEqual(model.n, ss.len());
        for (0..model.n) |i| {
            const e = ss.entries.items[i];
            try testing.expectEqualStrings(model.keys[i], e.key);
            try testing.expectEqual(model.counts[i], e.count);
            try testing.expectEqual(model.errs[i], e.err);
            try testing.expectEqual(model.seqs[i], e.seq);
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
    // The restored structure evicts the same entry next.
    try ss.add(testing.allocator, "z", 1);
    try back.add(testing.allocator, "z", 1);
    try testing.expectEqual(ss.get("z").?.err, back.get("z").?.err);
}
