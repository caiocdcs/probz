//! Count-Min Sketch is a probabilistic frequency estimation data structure.
//! It supports approximate point queries (frequency of an item) with
//! sublinear space and O(1) update/query time.
//!
//! Typical parametrization is by error bounds (epsilon, delta), where:
//!  - epsilon controls the additive error (~ epsilon * total count)
//!  - delta controls the probability of the estimate exceeding the true count by the error bound
//!
//! The classic formulas are:
//!  - width (w)  = ceil(e / epsilon)
//!  - depth (d)  = ceil(ln(1 / delta))

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const hash = std.hash;

pub const CountMinSketchError = error{
    CounterOverflow,
    InvalidDimensions,
    InvalidParameters,
};

/// Default counter type for the Count-Min Sketch.
pub const DefaultCountMinSketch = CountMinSketch(u32);

/// Create a Count-Min Sketch parametrized by counter type.
/// CounterType must be an unsigned integer type.
pub fn CountMinSketch(comptime CounterType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        width: u64,
        depth: u8,
        counters: []CounterType,

        /// Initialize a Count-Min Sketch with explicit width and depth.
        /// width > 0, depth > 0
        pub fn init(allocator: Allocator, width: usize, depth: u8) !Self {
            if (width == 0 or depth == 0) return CountMinSketchError.InvalidDimensions;

            const total_len: usize = width * @as(usize, depth);
            const counters = try allocator.alloc(CounterType, total_len);
            @memset(counters, 0);

            return Self{
                .allocator = allocator,
                .width = width,
                .depth = depth,
                .counters = counters,
            };
        }

        /// Initialize a Count-Min Sketch using error bounds.
        /// epsilon controls additive error; delta controls confidence:
        ///  - width = ceil(e/epsilon)
        ///  - depth = ceil(ln(1/delta))
        pub fn initWithError(allocator: Allocator, epsilon: f64, delta: f64) !Self {
            if (!(epsilon > 0.0 and epsilon < 1.0)) return CountMinSketchError.InvalidParameters;
            if (!(delta > 0.0 and delta < 1.0)) return CountMinSketchError.InvalidParameters;

            const w = calculateWidth(epsilon);
            const d = calculateDepth(delta);
            return try Self.init(allocator, w, d);
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counters);
        }

        /// Increment the count of an item by 1.
        pub fn set(self: *Self, item: []const u8) CountMinSketchError!void {
            try self.setCount(item, 1);
        }

        /// Increment the count of an item by a given amount.
        pub fn setCount(self: *Self, item: []const u8, amount: CounterType) CountMinSketchError!void {
            if (amount == 0) return;

            const hashes = computeHashes(item);

            // For each row, increment the corresponding bucket
            var row: u32 = 0;
            while (row < self.depth) : (row += 1) {
                const idx = self.calculateIndex(&hashes, row);
                const cell_index = rowCellOffset(self.width, row) + idx;

                const old_val = self.counters[cell_index];
                const result = addChecked(CounterType, old_val, amount) catch return CountMinSketchError.CounterOverflow;
                self.counters[cell_index] = result;
            }
        }

        /// Estimate the count of an item.
        /// Returns the minimum over the rows for the item's hashed positions.
        pub fn estimate(self: *const Self, item: []const u8) u64 {
            const hashes = computeHashes(item);

            var min_val: u64 = std.math.maxInt(u64);

            var row: u32 = 0;
            while (row < self.depth) : (row += 1) {
                const idx = self.calculateIndex(&hashes, row);
                const cell_index = rowCellOffset(self.width, row) + idx;

                const v: u64 = self.counters[cell_index];
                if (v < min_val) {
                    min_val = v;
                }
            }

            if (min_val == std.math.maxInt(u64)) return 0 else return min_val;
        }

        /// Merge another sketch into this one by summing counters.
        /// Both sketches must have the same width and depth.
        pub fn merge(self: *Self, other: *const Self) CountMinSketchError!void {
            if (self.width != other.width or self.depth != other.depth) {
                return CountMinSketchError.InvalidDimensions;
            }

            // Merge counters with overflow checking
            for (self.counters, 0..) |*dst, i| {
                const src = other.counters[i];
                const summed = addChecked(CounterType, dst.*, src) catch return CountMinSketchError.CounterOverflow;
                dst.* = summed;
            }
        }

        /// Calculate array index using double hashing: h1(x) + i * h2(x) mod width.
        pub inline fn calculateIndex(self: *const Self, hash_pair: *const HashPair, row: u32) u64 {
            const combined = @as(u64, hash_pair.hash1) +% (@as(u64, row) *% @as(u64, hash_pair.hash2));
            return combined % self.width;
        }
    };
}

/// Compute width as ceil(e / epsilon)
fn calculateWidth(epsilon: f64) usize {
    return @intFromFloat(math.ceil(math.e / epsilon));
}

/// Compute depth as ceil(ln(1 / delta))
fn calculateDepth(delta: f64) u8 {
    const v = math.log(f64, math.e, 1.0 / delta);
    return @intFromFloat(math.ceil(v));
}

/// Single 64-bit hash split into two 32-bit halves for double hashing
const HashPair = struct {
    hash1: u32,
    hash2: u32,
};

inline fn computeHashes(item: []const u8) HashPair {
    const h = hash.XxHash64.hash(0, item);
    const h1: u32 = @truncate(h);
    const h2: u32 = @truncate(h >> 32);
    return HashPair{
        .hash1 = h1,
        .hash2 = h2 | 1, // ensure odd to avoid cycling when depth is large
    };
}

/// Row offset in the flattened 2D array
inline fn rowCellOffset(width: u64, row: u32) usize {
    return @intCast(@as(u64, row) * width);
}

/// Checked addition for arbitrary unsigned integer CounterType.
/// Returns error on overflow.
inline fn addChecked(comptime T: type, a: T, b: T) !T {
    const s = @addWithOverflow(a, b);
    if (s[1] == 1) return CountMinSketchError.CounterOverflow;
    return s[0];
}

const testing = std.testing;

test "init by dimensions" {
    var cms = try CountMinSketch(u16).init(testing.allocator, 1024, 5);
    defer cms.deinit();

    try testing.expectEqual(@as(u64, 1024), cms.width);
    try testing.expectEqual(@as(u8, 5), cms.depth);
}

test "init with error bounds" {
    var cms = try DefaultCountMinSketch.initWithError(testing.allocator, 0.01, 0.01);
    defer cms.deinit();

    // width = ceil(e / 0.01) = ceil(271.828...) = 272
    // depth = ceil(ln(1/0.01)) = ceil(4.6051...) = 5
    try testing.expectEqual(@as(u64, 272), cms.width);
    try testing.expectEqual(@as(u8, 5), cms.depth);
}

test "set and estimate single item" {
    var cms = try DefaultCountMinSketch.init(testing.allocator, 4096, 5);
    defer cms.deinit();

    try cms.set("apple");
    try cms.set("apple");
    try cms.set("apple");

    const est = cms.estimate("apple");
    try testing.expect(est >= 3); // due to overestimation, must be >= true count

    const est_unknown = cms.estimate("banana");
    try testing.expectEqual(@as(u64, 0), est_unknown);
}

test "setCount and estimate multiple items" {
    var cms = try CountMinSketch(u16).init(testing.allocator, 2048, 6);
    defer cms.deinit();

    try cms.setCount("banana", 10);
    try cms.setCount("apple", 5);
    try cms.set("apple"); // +1

    const c_banana = cms.estimate("banana");
    const c_apple = cms.estimate("apple");

    try testing.expect(c_banana >= 10);
    try testing.expect(c_apple >= 6);
}

test "merge two sketches" {
    var a = try DefaultCountMinSketch.init(testing.allocator, 1024, 5);
    defer a.deinit();

    var b = try DefaultCountMinSketch.init(testing.allocator, 1024, 5);
    defer b.deinit();

    try a.setCount("a", 2);
    try b.setCount("b", 3);

    try a.merge(&b);

    const ea = a.estimate("a");
    const eb = a.estimate("b");

    try testing.expect(ea >= 2);
    try testing.expect(eb >= 3);
}

test "overflow on small counter type" {
    var cms = try CountMinSketch(u8).init(testing.allocator, 128, 4);
    defer cms.deinit();

    try cms.setCount("x", 255);
    try testing.expectError(CountMinSketchError.CounterOverflow, cms.set("x"));
}

test "invalid parameters" {
    try testing.expectError(CountMinSketchError.InvalidDimensions, DefaultCountMinSketch.init(testing.allocator, 0, 1));
    try testing.expectError(CountMinSketchError.InvalidDimensions, DefaultCountMinSketch.init(testing.allocator, 10, 0));

    try testing.expectError(CountMinSketchError.InvalidParameters, DefaultCountMinSketch.initWithError(testing.allocator, 0.0, 0.1));
    try testing.expectError(CountMinSketchError.InvalidParameters, DefaultCountMinSketch.initWithError(testing.allocator, 1.1, 0.1));
    try testing.expectError(CountMinSketchError.InvalidParameters, DefaultCountMinSketch.initWithError(testing.allocator, 0.1, 0.0));
    try testing.expectError(CountMinSketchError.InvalidParameters, DefaultCountMinSketch.initWithError(testing.allocator, 0.1, 1.1));
}
