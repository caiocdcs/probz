const std = @import("std");
const Allocator = std.mem.Allocator;
const hash = std.hash;

const QuotientFilterError = error{UnsupportedSize};

const Slot = packed struct {
    remainder: u8,
    occupied: u1,
    continuation: u1,
    shifted: u1,
};

pub const QuotientFilter = struct {
    allocator: Allocator,
    slots: []Slot,
    q: u8, // quotient bits
    r: u8, // remainder bits
    length: u64,

    pub fn init(allocator: Allocator, q: u6, r: u8) !QuotientFilter {
        const length: u64 = @intCast(@as(u64, @intCast(1)) << q);
        if (length > std.math.maxInt(usize)) return QuotientFilterError.UnsupportedSize;

        const slots = try allocator.alloc(Slot, length);
        @memset(slots, Slot{ .remainder = 0, .occupied = 0, .continuation = 0, .shifted = 0 });

        return QuotientFilter{ .allocator = allocator, .slots = slots, .q = q, .r = r, .length = length };
    }

    pub fn deinit(self: *QuotientFilter) void {
        self.allocator.free(self.slots);
    }

    /// Insert an item into the quotient filter.
    pub fn set(self: *QuotientFilter, item: []const u8) !void {
        const hash_result = self.calcHash(item);
        const quotient = hash_result.quotient;
        const remainder = hash_result.remainder;

        var current_slot = quotient;

        // Find the correct position using linear probing
        while (current_slot < self.length) {
            if (self.slots[current_slot].occupied == 0) {
                self.slots[current_slot] = Slot{
                    .remainder = remainder,
                    .occupied = 1,
                    .continuation = if (current_slot == quotient) 0 else 1,
                    .shifted = if (current_slot == quotient) 0 else 1,
                };
                break;
            } else if (self.slots[current_slot].remainder == remainder and current_slot == quotient) {
                // Already exists in canonical position
                break;
            }
            current_slot += 1;
        }
    }

    /// Returns a bool reflecting if a given object might be in the quotient
    /// filter or not. There is a possibility for a false positive, but a false negative
    /// will never occur.
    pub fn has(self: *const QuotientFilter, item: []const u8) !bool {
        const hash_result = self.calcHash(item);
        const quotient = hash_result.quotient;
        const remainder = hash_result.remainder;

        if (self.slots[quotient].occupied == 0) {
            return false;
        }

        // Scan forward from the canonical slot
        var current_slot = quotient;
        while (current_slot < self.length) {
            if (self.slots[current_slot].remainder == remainder) {
                return true;
            }

            // Stop scanning if we hit an empty slot or end of run
            if (self.slots[current_slot].occupied == 0 or
                (self.slots[current_slot].continuation == 0 and current_slot > quotient))
            {
                break;
            }
            current_slot += 1;
        }

        return false;
    }

    const QuotientHash = struct {
        quotient: u64,
        remainder: u8,
    };

    /// Calculate hash and split into quotient and remainder
    inline fn calcHash(self: *const QuotientFilter, item: []const u8) QuotientHash {
        const h = hash.XxHash64.hash(0, item);
        const remainder_mask: u64 = (@as(u64, 1) << @intCast(self.r)) - 1;
        const quotient_mask: u64 = (@as(u64, 1) << @intCast(self.q)) - 1;

        const remainder = @as(u8, @intCast(h & remainder_mask));
        const quotient = (h >> @intCast(self.r)) & quotient_mask;

        return QuotientHash{ .quotient = quotient, .remainder = remainder };
    }
};

const testing = std.testing;

test "init" {
    var quotient_filter = try QuotientFilter.init(testing.allocator, 8, 8);

    defer quotient_filter.deinit();
}

test "set and has" {
    var qbf = try QuotientFilter.init(testing.allocator, 8, 8); // 256 slots, 8-bit remainder
    defer qbf.deinit();

    try qbf.set("hello");
    try testing.expect(try qbf.has("hello"));
    try testing.expectEqual(false, try qbf.has("world"));
}

test "multiple items" {
    var qbf = try QuotientFilter.init(testing.allocator, 4, 8); // 16 slots, 8-bit remainder
    defer qbf.deinit();

    try qbf.set("test1");
    try qbf.set("test2");
    try qbf.set("test3");

    try testing.expect(try qbf.has("test1"));
    try testing.expect(try qbf.has("test2"));
    try testing.expect(try qbf.has("test3"));
    try testing.expectEqual(false, try qbf.has("test4"));
}

test "hash calculation" {
    var qbf = try QuotientFilter.init(testing.allocator, 4, 8); // 16 slots, 8-bit remainder
    defer qbf.deinit();

    const hash_result = qbf.calcHash("test");
    try testing.expect(hash_result.quotient < 16); // Should fit in 4 bits
    // remainder is u8, so it should be valid
}
