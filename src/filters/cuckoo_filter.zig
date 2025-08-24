//! Cuckoo filter is a space-efficient probabilistic data structure
//! that supports membership queries, insertions, and deletions.
//! It uses cuckoo hashing with fingerprints stored in buckets,
//! providing better space efficiency than Bloom filters while
//! supporting deletions without false negatives. When buckets are
//! full, items are moved using a cuckoo eviction process that
//! relocates existing items to make space for new ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hash = std.hash;

const CuckooFilterError = error{FilterFull};

/// Default Cuckoo Filter with 16-bit fingerprints and 4 slots per bucket.
pub const DefaultCuckooFilter = CuckooFilter(u16, 4);

/// Generic Cuckoo Filter implementation.
/// Fingerprint: Type used to store fingerprints (e.g., u8, u16, u32)
/// bucket_size: Number of fingerprint slots per bucket
pub fn CuckooFilter(comptime Fingerprint: type, comptime bucket_size: comptime_int) type {
    return struct {
        const Bucket = [bucket_size]?Fingerprint;

        const BucketPair = struct { bucket1: usize, bucket2: usize, fingerprint: Fingerprint };

        const Self = @This();
        const max_kicks = 500;

        allocator: Allocator,
        buckets: []Bucket,
        length: usize,

        /// Initialize a new Cuckoo filter with the specified capacity.
        /// The actual number of buckets will be rounded up to the next power of two.
        pub fn init(allocator: Allocator, length: usize) !Self {
            const bucket_count = std.math.ceilPowerOfTwo(usize, length / bucket_size) catch unreachable;
            const buckets = try allocator.alloc(Bucket, bucket_count);
            for (buckets) |*bucket| {
                bucket.* = [_]?Fingerprint{null} ** bucket_size;
            }

            return Self{ .allocator = allocator, .buckets = buckets, .length = length };
        }

        /// Free the memory allocated for the filter.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buckets);
        }

        inline fn computeBucketPair(self: *const Self, item: []const u8, bucket_count: usize) BucketPair {
            const fp_hash = hash.Murmur3_32.hash(item);
            const fp = if (fp_hash == 0) 1 else @as(Fingerprint, @truncate(fp_hash));

            const first_hash = hash.XxHash32.hash(0, item);
            const bucket1 = @as(u32, @truncate(first_hash)) % @as(u32, @intCast(bucket_count));

            const bucket2 = self.getAltBucket(bucket1, fp);

            return BucketPair{ .bucket1 = bucket1, .bucket2 = bucket2, .fingerprint = fp };
        }

        /// Insert an item into the Cuckoo filter.
        /// Returns FilterFull error if the filter cannot accommodate the item
        /// after maximum eviction attempts.
        pub fn set(self: *Self, item: []const u8) !void {
            const bucketPair = self.computeBucketPair(item, self.buckets.len);

            if (self.insertToBucket(bucketPair.bucket1, bucketPair.fingerprint) or self.insertToBucket(bucketPair.bucket2, bucketPair.fingerprint)) {
                return;
            }

            // Both buckets are full, perform cuckoo eviction
            if (!try self.cuckooInsert(bucketPair)) {
                return CuckooFilterError.FilterFull;
            }
        }

        fn insertToBucket(self: *Self, bucket_idx: u64, fp: Fingerprint) bool {
            const bucket = &self.buckets[bucket_idx];
            for (bucket) |*slot| {
                if (slot.* == null) {
                    slot.* = fp;
                    return true;
                }
            }
            return false;
        }

        fn cuckooInsert(self: *Self, bucketPair: BucketPair) !bool {
            var current_bucket = bucketPair.bucket1;
            var current_fp = bucketPair.fingerprint;

            var kicks: u16 = 0;
            while (kicks < max_kicks) {
                const random_slot = std.crypto.random.intRangeLessThan(u8, 0, bucket_size);
                const bucket = &self.buckets[current_bucket];

                const temp_fp = bucket[random_slot].?;
                bucket[random_slot] = current_fp;
                current_fp = temp_fp;

                current_bucket = self.getAltBucket(current_bucket, current_fp);

                if (self.insertToBucket(current_bucket, current_fp)) {
                    return true;
                }

                kicks += 1;
            }

            return false;
        }

        fn getAltBucket(self: *const Self, bucket_idx: usize, fp: Fingerprint) u64 {
            const fp_bytes = std.mem.asBytes(&fp);
            const alt_hash = hash.Murmur3_32.hash(fp_bytes);
            return bucket_idx ^ (@as(u64, alt_hash) % self.buckets.len);
        }

        /// Check if an item might be in the filter.
        /// May return false positives but never false negatives.
        pub fn has(self: *const Self, item: []const u8) bool {
            const bucketPair = self.computeBucketPair(item, self.buckets.len);

            return self.checkBucket(bucketPair.bucket1, bucketPair.fingerprint) or self.checkBucket(bucketPair.bucket2, bucketPair.fingerprint);
        }

        fn checkBucket(self: *const Self, bucket_idx: usize, fp: Fingerprint) bool {
            const bucket = &self.buckets[bucket_idx];
            for (bucket) |slot| {
                if (slot == fp) {
                    return true;
                }
            }
            return false;
        }

        /// Remove an item from the Cuckoo filter.
        /// Returns true if the item was found and removed, false otherwise.
        pub fn remove(self: *Self, item: []const u8) bool {
            const bucketPair = self.computeBucketPair(item, self.buckets.len);

            return self.removeFromBucket(bucketPair.bucket1, bucketPair.fingerprint) or self.removeFromBucket(bucketPair.bucket2, bucketPair.fingerprint);
        }

        fn removeFromBucket(self: *Self, bucket_idx: usize, fp: Fingerprint) bool {
            const bucket = &self.buckets[bucket_idx];
            for (bucket) |*slot| {
                if (slot.* == fp) {
                    slot.* = null;
                    return true;
                }
            }
            return false;
        }

        /// Count the number of fingerprints currently stored in the filter.
        /// This provides an exact count of stored items, not an estimate.
        pub fn estimatedSize(self: *const Self) u64 {
            var count: u64 = 0;
            for (self.buckets) |bucket| {
                for (bucket) |slot| {
                    if (slot != null) {
                        count += 1;
                    }
                }
            }
            return count;
        }
    };
}

const testing = std.testing;

test "init" {
    var cuckoo_filter = try CuckooFilter(u8, 2).init(testing.allocator, 100);

    defer cuckoo_filter.deinit();
}

test "default cuckoo filter" {
    var cuckoo_filter = try DefaultCuckooFilter.init(testing.allocator, 100);
    defer cuckoo_filter.deinit();

    try cuckoo_filter.set("test");
    try testing.expect(cuckoo_filter.has("test"));

    _ = cuckoo_filter.remove("test");
    try testing.expectEqual(false, cuckoo_filter.has("test"));
}

test "set and has" {
    var cuckoo_filter = try CuckooFilter(u8, 2).init(testing.allocator, 100);
    defer cuckoo_filter.deinit();

    try testing.expectEqual(false, cuckoo_filter.has("test"));
    try cuckoo_filter.set("test");
    try testing.expect(cuckoo_filter.has("test"));
}

test "set, remove and has" {
    var cuckoo_filter = try CuckooFilter(u8, 2).init(testing.allocator, 100);
    defer cuckoo_filter.deinit();

    try cuckoo_filter.set("test");
    try testing.expect(cuckoo_filter.has("test"));

    _ = cuckoo_filter.remove("test");
    try testing.expectEqual(false, cuckoo_filter.has("test"));
}

test "multiple sets and single remove" {
    var cuckoo_filter = try CuckooFilter(u8, 2).init(testing.allocator, 100);
    defer cuckoo_filter.deinit();

    try cuckoo_filter.set("test");
    try cuckoo_filter.set("test");
    try testing.expect(cuckoo_filter.has("test"));

    _ = cuckoo_filter.remove("test");
    try testing.expect(cuckoo_filter.has("test"));

    _ = cuckoo_filter.remove("test");
    try testing.expectEqual(false, cuckoo_filter.has("test"));
}

test "estimated size" {
    var cuckoo_filter = try CuckooFilter(u8, 2).init(testing.allocator, 100);
    defer cuckoo_filter.deinit();

    try cuckoo_filter.set("test1");
    try cuckoo_filter.set("test2");
    try cuckoo_filter.set("test3");

    const estimated = cuckoo_filter.estimatedSize();
    try testing.expectEqual(3, estimated);
}
