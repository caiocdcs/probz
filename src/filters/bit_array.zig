const std = @import("std");

const Allocator = std.mem.Allocator;

const BITS_PER_CELL = 64;
const CELL_TYPE = u64;

pub const BitArrayError = error{InvalidBit};

pub const BitArray = struct {
    allocator: Allocator,
    cells: []CELL_TYPE,
    length: u64,

    /// Initialize new BitArray given allocator and length in bits of BitArray.
    pub fn init(allocator: Allocator, length: usize) !BitArray {
        // determine number of bytes of memory needed
        const num_cells: u64 = if (length % BITS_PER_CELL > 0) (length / BITS_PER_CELL) + 1 else (length / BITS_PER_CELL);

        const cells = try allocator.alloc(CELL_TYPE, num_cells);
        @memset(cells, 0);

        return BitArray{
            .allocator = allocator,
            .cells = cells,
            .length = length,
        };
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *BitArray) void {
        self.allocator.free(self.cells);
    }

    /// Get value of bit.
    pub fn get(self: *const BitArray, idx: u64) BitArrayError!u1 {
        try self.checkIndex(idx);
        const offset = bitOffset(idx);
        return @truncate(
            ((self.cells[cellIdx(idx)] & (@as(CELL_TYPE, 1) << offset))) >> offset,
        );
    }

    /// Set value of bit to 1.
    pub fn set(self: *BitArray, idx: u64) BitArrayError!void {
        try self.checkIndex(idx);
        const offset = bitOffset(idx);
        self.cells[cellIdx(idx)] |= (@as(CELL_TYPE, 1) << offset);
    }

    /// Check if bit is set (non-zero).
    pub fn isSet(self: *const BitArray, idx: u64) BitArrayError!bool {
        try self.checkIndex(idx);
        const offset = bitOffset(idx);
        return (self.cells[cellIdx(idx)] & (@as(CELL_TYPE, 1) << offset)) != 0;
    }

    /// Clear value of bit to 0.
    pub fn unset(self: *BitArray, idx: u64) BitArrayError!void {
        try self.checkIndex(idx);
        const offset = bitOffset(idx);
        self.cells[cellIdx(idx)] &= ~(@as(CELL_TYPE, 1) << offset);
    }

    /// Toggle value of bit.
    pub fn toggle(self: *BitArray, idx: u64) BitArrayError!void {
        try self.checkIndex(idx);
        const offset = bitOffset(idx);
        self.cells[cellIdx(idx)] ^= @as(CELL_TYPE, 1) << offset;
    }

    /// Count the number of bits set (1)
    pub fn count_bits_set(self: *const BitArray) u64 {
        var total: u64 = 0;

        for (self.cells[0 .. self.cells.len - 1]) |cell| {
            total += @popCount(cell);
        }

        // This only counts the supposed used bits in the last cell,
        // it´s just to ensure that no unused bits are counted, even though they are possible zeros
        if (self.cells.len > 0) {
            const last_cell = self.cells[self.cells.len - 1];
            const bits_in_last_cell = self.length % BITS_PER_CELL;
            if (bits_in_last_cell == 0) {
                total += @popCount(last_cell);
            } else {
                const mask = (@as(u64, 1) << @intCast(bits_in_last_cell)) - 1;
                total += @popCount(last_cell & mask);
            }
        }

        return total;
    }

    inline fn checkIndex(self: *const BitArray, idx: u64) BitArrayError!void {
        if (idx >= self.length) return BitArrayError.InvalidBit;
    }
};

inline fn cellIdx(bit_idx: u64) u8 {
    return @truncate(bit_idx / BITS_PER_CELL);
}

inline fn bitOffset(bit_idx: u64) u6 {
    return @truncate(bit_idx % BITS_PER_CELL);
}

const testing = std.testing;

test "test init" {
    var bit_array = try BitArray.init(testing.allocator, 10);
    defer bit_array.deinit();
}

test "get" {
    var bits = try BitArray.init(testing.allocator, 1000);
    defer bits.deinit();

    try testing.expectEqual(0, bits.get(200));
}

test "set" {
    var bits = try BitArray.init(testing.allocator, 1000);
    defer bits.deinit();

    try bits.set(200);
    try testing.expectEqual(1, try bits.get(200));
}

test "clear" {
    var bits = try BitArray.init(testing.allocator, 1000);
    defer bits.deinit();

    try bits.set(400);
    try bits.unset(400);
    try testing.expectEqual(0, try bits.get(400));
}

test "toggle" {
    var bits = try BitArray.init(testing.allocator, 1000);
    defer bits.deinit();

    try bits.toggle(400);
    try testing.expectEqual(1, try bits.get(400));
}

test "isSet" {
    var bits = try BitArray.init(testing.allocator, 100);
    defer bits.deinit();

    try testing.expectEqual(false, try bits.isSet(50));
    try bits.set(50);
    try testing.expect(try bits.isSet(50));
}

test "count bit set" {
    var bits = try BitArray.init(testing.allocator, 100);
    defer bits.deinit();

    try bits.set(1);
    try bits.set(10);
    try bits.set(28);
    try bits.set(28);

    try testing.expectEqual(3, bits.count_bits_set());
}
