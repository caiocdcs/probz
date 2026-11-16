//! Count-Min sketch: approximate frequencies for a stream of (item, count)
//! updates in d × w counters. See SPEC.md §5.7.
//!
//! Each update increments one counter per row; a point query returns the
//! minimum over the rows. With w = ⌈e / ε⌉ and d = ⌈ln(1 / δ)⌉ the
//! estimate â of an item's true count a satisfies â ≥ a and, with
//! probability at least 1 − δ, â ≤ a + ε·N, where N is the total of all
//! counts.
//!
//! The analysis assumes d pairwise-independent hash functions. probz
//! derives the d row indexes from one XxHash64 by taking successive
//! SplitMix64 outputs seeded with that hash (SPEC.md §2.3): a practical
//! substitute that keeps every row hash a function of H(item), so callers
//! can pass precomputed hashes.
//!
//! Conservative update (`.update = .conservative`, Estan & Varghese §3.3.2)
//! raises each of the item's counters only as far as needed: with current
//! estimate â, every counter becomes max(counter, â + c). Each counter still
//! bounds every item that maps to it, so estimates never undercount, the
//! ε·N guarantee still holds, and overestimates shrink (about 2× on the
//! streams in the tests). Unlike standard update it cannot represent
//! deletions, and the sketch is no longer a linear function of the stream:
//! merging two conservative sketches by addition is still a valid upper
//! bound but is not the sketch of the combined stream.
//!
//! # References
//!
//! - Graham Cormode, S. Muthukrishnan, "An Improved Data Stream Summary:
//!   The Count-Min Sketch and its Applications", Journal of Algorithms
//!   55(1):58–75, 2005. https://doi.org/10.1016/j.jalgor.2003.12.001
//! - The parameters and guarantee above are as restated in Kirsch &
//!   Mitzenmacher, Random Structures & Algorithms 33(2), 2008, §9.1
//!   "Count-Min Sketch Review". https://doi.org/10.1002/rsa.20208
//! - Cristian Estan, George Varghese, "New Directions in Traffic
//!   Measurement and Accounting", SIGCOMM 2002, §3.3.2 (conservative
//!   update). https://doi.org/10.1145/633025.633056

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const hashing = @import("hash.zig");
const serde = @import("serde.zig");

/// Count-Min sketch with 32-bit counters.
pub const DefaultCountMinSketch = CountMinSketch(u32);

/// `Counter`: unsigned integer of 8 to 64 bits.
pub fn CountMinSketch(comptime Counter: type) type {
    const info = @typeInfo(Counter);
    if (info != .int or info.int.signedness != .unsigned or info.int.bits < 8 or info.int.bits > 64)
        @compileError("CountMinSketch: Counter must be an unsigned integer of 8..64 bits");

    return struct {
        const Self = @This();
        const Wire = @Int(.unsigned, ((info.int.bits + 7) / 8) * 8);

        width: u64,
        depth: u32,
        /// Row-major, `depth * width` counters.
        counters: []Counter,
        /// N: the sum of all added amounts.
        total: u64,
        update: Update,

        pub const Update = enum(u1) {
            /// Add c to each of the item's d counters (Cormode & Muthukrishnan).
            standard = 0,
            /// Raise each counter to at least â + c (Estan & Varghese).
            conservative = 1,
        };

        pub const Options = struct {
            /// Counters per row (w > 0).
            width: u64,
            /// Number of rows (d > 0).
            depth: u32,
            update: Update = .standard,
        };

        pub const InitError = error{InvalidParameters} || Allocator.Error;
        pub const AddError = error{Overflow};
        pub const MergeError = error{ IncompatibleSketches, Overflow };

        pub fn init(allocator: Allocator, options: Options) InitError!Self {
            if (options.width == 0 or options.depth == 0) return error.InvalidParameters;
            const n = math.mul(u64, options.width, options.depth) catch return error.OutOfMemory;
            const counters = try allocator.alloc(Counter, math.cast(usize, n) orelse return error.OutOfMemory);
            @memset(counters, 0);
            return .{ .width = options.width, .depth = options.depth, .counters = counters, .total = 0, .update = options.update };
        }

        /// Size for additive error ε·N with probability 1 − δ:
        /// w = ⌈e / ε⌉, d = ⌈ln(1 / δ)⌉. Requires 0 < ε < 1 and 0 < δ < 1.
        pub fn initWithError(allocator: Allocator, epsilon: f64, delta: f64) InitError!Self {
            return init(allocator, try dimensionsForError(epsilon, delta));
        }

        pub fn dimensionsForError(epsilon: f64, delta: f64) error{InvalidParameters}!Options {
            if (!(epsilon > 0 and epsilon < 1) or !(delta > 0 and delta < 1)) return error.InvalidParameters;
            return .{
                .width = @intFromFloat(@ceil(math.e / epsilon)),
                .depth = @intFromFloat(@max(1.0, @ceil(@log(1.0 / delta)))),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.counters);
            self.* = undefined;
        }

        /// Add `amount` occurrences of an item. Fails without changing
        /// anything if a counter or the total would overflow.
        pub fn add(self: *Self, item: []const u8, amount: Counter) AddError!void {
            return self.addHash(hashing.hashBytes(item), amount);
        }

        pub fn addHash(self: *Self, h: u64, amount: Counter) AddError!void {
            if (amount == 0) return;
            const new_total = math.add(u64, self.total, amount) catch return error.Overflow;
            switch (self.update) {
                .standard => {
                    var rows = RowIterator.init(self, h);
                    while (rows.next()) |i| {
                        if (math.maxInt(Counter) - self.counters[i] < amount) return error.Overflow;
                    }
                    rows = RowIterator.init(self, h);
                    while (rows.next()) |i| self.counters[i] += amount;
                },
                .conservative => {
                    const est: Counter = @intCast(self.countHash(h));
                    if (math.maxInt(Counter) - est < amount) return error.Overflow;
                    const v = est + amount;
                    var rows = RowIterator.init(self, h);
                    while (rows.next()) |i| self.counters[i] = @max(self.counters[i], v);
                },
            }
            self.total = new_total;
        }

        /// Estimated count: never below the true count.
        pub fn count(self: Self, item: []const u8) u64 {
            return self.countHash(hashing.hashBytes(item));
        }

        pub fn countHash(self: Self, h: u64) u64 {
            var min: u64 = math.maxInt(u64);
            var rows = RowIterator.init(&self, h);
            while (rows.next()) |i| min = @min(min, self.counters[i]);
            return min;
        }

        /// Additive error bound ε·N for the current total, with ε = e / w.
        pub fn errorBound(self: Self) f64 {
            return math.e / @as(f64, @floatFromInt(self.width)) * @as(f64, @floatFromInt(self.total));
        }

        /// Sum of two sketches of the same dimensions (the sketch of the
        /// combined stream). Fails without changes on overflow. With
        /// conservative update the sum is still an upper bound for every
        /// item, but looser than updating one sketch with both streams.
        pub fn merge(self: *Self, other: Self) MergeError!void {
            if (self.width != other.width or self.depth != other.depth) return error.IncompatibleSketches;
            const new_total = math.add(u64, self.total, other.total) catch return error.Overflow;
            for (self.counters, other.counters) |a, b| {
                if (math.maxInt(Counter) - a < b) return error.Overflow;
            }
            for (self.counters, other.counters) |*a, b| a.* += b;
            self.total = new_total;
        }

        pub fn clear(self: *Self) void {
            @memset(self.counters, 0);
            self.total = 0;
        }

        pub fn memoryBytes(self: Self) usize {
            return self.counters.len * @sizeOf(Counter);
        }

        /// Counter indexes for one item: row j uses the j-th SplitMix64
        /// output seeded with the item hash, modulo w.
        const RowIterator = struct {
            sketch: *const Self,
            rng: hashing.SplitMix64,
            row: u32 = 0,

            fn init(sketch: *const Self, h: u64) RowIterator {
                return .{ .sketch = sketch, .rng = .init(h) };
            }

            fn next(it: *RowIterator) ?usize {
                if (it.row == it.sketch.depth) return null;
                const col = it.rng.below(it.sketch.width);
                const idx = @as(u64, it.row) * it.sketch.width + col;
                it.row += 1;
                return @intCast(idx);
            }
        };

        /// Body (tag 7): u8 flags (counter bits in bits 0–6, conservative
        /// update in bit 7), u32 d, u64 w, u64 N, then d·w counters
        /// row-major, each little-endian in ceil(bits / 8) bytes.
        pub fn serialize(self: Self, w: *std.Io.Writer) serde.WriteError!void {
            try serde.writeHeader(w, .count_min_sketch);
            try w.writeByte(@as(u8, info.int.bits) | @as(u8, @backingInt(self.update)) << 7);
            try serde.writeInt(w, u32, self.depth);
            try serde.writeInt(w, u64, self.width);
            try serde.writeInt(w, u64, self.total);
            for (self.counters) |c| try serde.writeInt(w, Wire, c);
        }

        pub fn deserialize(allocator: Allocator, r: *std.Io.Reader) serde.ReadError!Self {
            try serde.readHeader(r, .count_min_sketch);
            const flags = try r.takeByte();
            if (flags & 0x7f != info.int.bits) return error.InvalidData;
            const update: Update = @fromBackingInt(@intCast(flags >> 7));
            const depth = try serde.readInt(r, u32);
            const width = try serde.readInt(r, u64);
            var self = init(allocator, .{ .width = width, .depth = depth, .update = update }) catch |err| return serde.fromInitError(err);
            errdefer self.deinit(allocator);
            self.total = try serde.readInt(r, u64);
            for (self.counters) |*c| c.* = math.cast(Counter, try serde.readInt(r, Wire)) orelse return error.InvalidData;
            return self;
        }
    };
}

const testing = std.testing;

test "dimensions from error bounds" {
    const d = try DefaultCountMinSketch.dimensionsForError(0.01, 0.01);
    try testing.expectEqual(@as(u64, 272), d.width); // ceil(e / 0.01)
    try testing.expectEqual(@as(u32, 5), d.depth); // ceil(ln 100)
    try testing.expectError(error.InvalidParameters, DefaultCountMinSketch.dimensionsForError(0, 0.1));
    try testing.expectError(error.InvalidParameters, DefaultCountMinSketch.dimensionsForError(0.1, 1));
    try testing.expectError(error.InvalidParameters, DefaultCountMinSketch.init(testing.allocator, .{ .width = 0, .depth = 1 }));
}

test "add and count" {
    var cms = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 2048, .depth = 5 });
    defer cms.deinit(testing.allocator);

    try cms.add("apple", 3);
    try cms.add("banana", 10);
    try cms.add("apple", 1);
    try testing.expectEqual(@as(u64, 4), cms.count("apple"));
    try testing.expectEqual(@as(u64, 10), cms.count("banana"));
    try testing.expectEqual(@as(u64, 0), cms.count("cherry"));
    try testing.expectEqual(@as(u64, 14), cms.total);
}

test "overflow is detected without partial updates" {
    var cms = try CountMinSketch(u8).init(testing.allocator, .{ .width = 128, .depth = 4 });
    defer cms.deinit(testing.allocator);
    try cms.add("x", 255);
    try testing.expectError(error.Overflow, cms.add("x", 1));
    try testing.expectEqual(@as(u64, 255), cms.count("x"));
    try testing.expectEqual(@as(u64, 255), cms.total);
}

test "error bound holds with probability 1 - delta" {
    const epsilon = 0.001;
    const delta = 0.01;
    var cms = try DefaultCountMinSketch.initWithError(testing.allocator, epsilon, delta);
    defer cms.deinit(testing.allocator);

    // Zipf-like stream: item-i appears floor(1000 / (i + 1)) times.
    const distinct = 20_000;
    var buf: [32]u8 = undefined;
    for (0..distinct) |i| {
        const c: u32 = @intCast(@max(1, 1000 / (i + 1)));
        try cms.add(try std.fmt.bufPrint(&buf, "item-{d}", .{i}), c);
    }
    const bound = epsilon * @as(f64, @floatFromInt(cms.total));
    var violations: usize = 0;
    for (0..distinct) |i| {
        const truth: u64 = @max(1, 1000 / (i + 1));
        const est = cms.count(try std.fmt.bufPrint(&buf, "item-{d}", .{i}));
        try testing.expect(est >= truth);
        if (@as(f64, @floatFromInt(est - truth)) > bound) violations += 1;
    }
    try testing.expect(@as(f64, @floatFromInt(violations)) / distinct <= delta);
}

test "conservative update: never undercounts, overcounts less" {
    // Zipf-like stream over 20k items into a deliberately small sketch.
    var std_s = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 1024, .depth = 4 });
    defer std_s.deinit(testing.allocator);
    var cu = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 1024, .depth = 4, .update = .conservative });
    defer cu.deinit(testing.allocator);

    const distinct = 20_000;
    var rng = hashing.SplitMix64.init(42);
    const truth = try testing.allocator.alloc(u64, distinct);
    defer testing.allocator.free(truth);
    @memset(truth, 0);
    for (0..200_000) |_| {
        // P(i) ~ 1/(i+1): pick i = floor(distinct^u) - 1.
        const u = @as(f64, @floatFromInt(rng.next() >> 11)) / 0x1p53;
        const i: usize = @min(distinct - 1, @as(usize, @intFromFloat(@floor(math.pow(f64, distinct, u)))) - 1);
        truth[i] += 1;
        const h = hashing.hashKey(@as(u64, i));
        try std_s.addHash(h, 1);
        try cu.addHash(h, 1);
    }
    try testing.expectEqual(std_s.total, cu.total);
    var err_std: u64 = 0;
    var err_cu: u64 = 0;
    for (truth, 0..) |t, i| {
        const h = hashing.hashKey(@as(u64, i));
        const a = std_s.countHash(h);
        const b = cu.countHash(h);
        try testing.expect(b >= t and b <= a);
        err_std += a - t;
        err_cu += b - t;
    }
    try testing.expect(err_cu * 3 < err_std * 2); // at least 1.5x lower
}

test "conservative update: overflow and serialization" {
    var cms = try CountMinSketch(u8).init(testing.allocator, .{ .width = 64, .depth = 3, .update = .conservative });
    defer cms.deinit(testing.allocator);
    try cms.add("x", 200);
    try testing.expectError(error.Overflow, cms.add("x", 56));
    try cms.add("x", 55);
    try testing.expectEqual(@as(u64, 255), cms.count("x"));

    const bytes = try serde.toOwnedBytes(testing.allocator, cms);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 0x88), bytes[6]); // 8 bits | conservative
    var r: std.Io.Reader = .fixed(bytes);
    var back = try CountMinSketch(u8).deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expect(back.update == .conservative);
}

test "merge equals the combined stream" {
    var a = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 512, .depth = 4 });
    defer a.deinit(testing.allocator);
    var b = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 512, .depth = 4 });
    defer b.deinit(testing.allocator);
    var all = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 512, .depth = 4 });
    defer all.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..1000) |i| {
        const item = try std.fmt.bufPrint(&buf, "item-{d}", .{i % 300});
        if (i % 2 == 0) try a.add(item, 1) else try b.add(item, 1);
        try all.add(item, 1);
    }
    try a.merge(b);
    try testing.expectEqualSlices(u32, all.counters, a.counters);
    try testing.expectEqual(all.total, a.total);

    var c = try DefaultCountMinSketch.init(testing.allocator, .{ .width = 256, .depth = 4 });
    defer c.deinit(testing.allocator);
    try testing.expectError(error.IncompatibleSketches, a.merge(c));
}

test "serialize round trip" {
    var cms = try CountMinSketch(u16).init(testing.allocator, .{ .width = 32, .depth = 3 });
    defer cms.deinit(testing.allocator);
    try cms.add("x", 7);
    const bytes = try serde.toOwnedBytes(testing.allocator, cms);
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var back = try CountMinSketch(u16).deserialize(testing.allocator, &r);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, cms.counters, back.counters);
    try testing.expectEqual(@as(u64, 7), back.count("x"));
}
