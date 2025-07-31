const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CountingBitArrayError = error{ UnsupportedArraySize, InvalidIndex, CounterOverflow, CounterUnderflow };

/// Default CountingBitArray with 4-bit counters
pub const DefaultCountingBitArray = CountingBitArray(u4);

pub fn CountingBitArray(comptime CounterType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        counters: []CounterType,
        length: u64,

        /// Initialize new CountingBitArray given allocator and length.
        pub fn init(allocator: Allocator, length: u64) !Self {
            if (length > std.math.maxInt(usize)) return CountingBitArrayError.UnsupportedArraySize;
            const counters = try allocator.alloc(CounterType, length);
            @memset(counters, 0);

            return Self{
                .allocator = allocator,
                .counters = counters,
                .length = length,
            };
        }

        /// Deinitialize and free resources
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counters);
        }

        /// Get counter value at index.
        pub fn get(self: *const Self, idx: u64) !CounterType {
            try self.checkIndex(idx);
            return self.counters[idx];
        }

        /// Increment counter at index.
        pub fn increment(self: *Self, idx: u64) !void {
            try self.checkIndex(idx);
            if (self.counters[idx] == std.math.maxInt(CounterType)) {
                return CountingBitArrayError.CounterOverflow;
            }
            self.counters[idx] += 1;
        }

        /// Decrement counter at index.
        pub fn decrement(self: *Self, idx: u64) !void {
            try self.checkIndex(idx);
            if (self.counters[idx] == 0) {
                return CountingBitArrayError.CounterUnderflow;
            }
            self.counters[idx] -= 1;
        }

        /// Decrement counter at index without safety check.
        /// Caller must ensure counter is greater than 0.
        pub fn decrementUnchecked(self: *Self, idx: u64) void {
            self.counters[idx] -= 1;
        }

        /// Check if counter at index is non-zero.
        pub fn isSet(self: *const Self, idx: u64) !bool {
            try self.checkIndex(idx);
            return self.counters[idx] > 0;
        }

        /// Count the number of non-zero counters.
        pub fn countNonZero(self: *const Self) u64 {
            var count: u64 = 0;
            for (self.counters) |counter| {
                if (counter > 0) {
                    count += 1;
                }
            }
            return count;
        }

        inline fn checkIndex(self: *const Self, idx: u64) !void {
            if (idx >= self.length) return CountingBitArrayError.InvalidIndex;
        }
    };
}

const testing = std.testing;

test "init" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 10);
    defer cba.deinit();
}

test "init with custom counter type" {
    var cba = try CountingBitArray(u8).init(testing.allocator, 10);
    defer cba.deinit();
}

test "get initial value" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try testing.expectEqual(0, try cba.get(50));
}

test "increment and get" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try testing.expectEqual(1, try cba.get(50));
}

test "multiple increments" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try cba.increment(50);
    try cba.increment(50);
    try testing.expectEqual(3, try cba.get(50));
}

test "increment and decrement" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try cba.increment(50);
    try cba.decrement(50);
    try testing.expectEqual(1, try cba.get(50));
}

test "decrement to zero" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try cba.decrement(50);
    try testing.expectEqual(0, try cba.get(50));
}

test "decrement underflow" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try testing.expectError(CountingBitArrayError.CounterUnderflow, cba.decrement(50));
}

test "increment overflow" {
    var cba = try CountingBitArray(u1).init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try testing.expectError(CountingBitArrayError.CounterOverflow, cba.increment(50));
}

test "isSet" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try testing.expectEqual(false, try cba.isSet(50));
    try cba.increment(50);
    try testing.expectEqual(true, try cba.isSet(50));
    try cba.decrement(50);
    try testing.expectEqual(false, try cba.isSet(50));
}

test "countNonZero" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try testing.expectEqual(0, cba.countNonZero());

    try cba.increment(10);
    try cba.increment(20);
    try cba.increment(30);
    try testing.expectEqual(3, cba.countNonZero());

    try cba.increment(10); // increment same index
    try testing.expectEqual(3, cba.countNonZero());

    try cba.decrement(20);
    try testing.expectEqual(2, cba.countNonZero());
}

test "decrementUnchecked" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 100);
    defer cba.deinit();

    try cba.increment(50);
    try cba.increment(50);

    cba.decrementUnchecked(50);
    try testing.expectEqual(1, try cba.get(50));

    cba.decrementUnchecked(50);
    try testing.expectEqual(0, try cba.get(50));
}

test "invalid index" {
    var cba = try DefaultCountingBitArray.init(testing.allocator, 10);
    defer cba.deinit();

    try testing.expectError(CountingBitArrayError.InvalidIndex, cba.get(10));
    try testing.expectError(CountingBitArrayError.InvalidIndex, cba.increment(10));
    try testing.expectError(CountingBitArrayError.InvalidIndex, cba.decrement(10));
    try testing.expectError(CountingBitArrayError.InvalidIndex, cba.isSet(10));
}
