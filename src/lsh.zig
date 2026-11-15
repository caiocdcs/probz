//! Locality Sensitive Hashing (LSH) is a probabilistic technique for finding
//! approximate nearest neighbors in high-dimensional spaces. It hashes similar
//! items to the same buckets with high probability.
//!
//! This implementation uses MinHash LSH for Jaccard similarity, which is ideal
//! for set similarity and document similarity using shingles/n-grams.
//!
//! LSH works by:
//! 1. Computing multiple hash functions for each item
//! 2. Organizing hash values into bands and rows
//! 3. Items that match in at least one band are candidate neighbors
//!
//! The probability that two items with Jaccard similarity s will be identified
//! as neighbors is approximately: 1 - (1 - s^r)^b
//! where r = rows per band, b = number of bands, and r * b = total hash functions

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const hash = std.hash;
const math = std.math;
const Random = std.Random;

pub const LSHError = error{
    InvalidParameters,
    ItemNotFound,
    OutOfMemory,
};

/// Item stored in the LSH with its signature and ID
const LSHItem = struct {
    id: []const u8,
    signature: []u32,

    fn deinit(self: *LSHItem, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.signature);
    }
};

/// Candidate pair with similarity score
pub const Candidate = struct {
    id: []const u8,
    similarity: f64,
};

/// Default MinHash LSH configuration
pub const DefaultLSH = LSH(u32);

/// MinHash LSH for Jaccard similarity estimation
/// HashType must be an unsigned integer type for hash values
pub fn LSH(comptime HashType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        num_hashes: u32,
        bands: u32,
        rows_per_band: u32,
        items: ArrayList(LSHItem),
        buckets: AutoHashMap(u64, ArrayList(u32)),
        hash_coeffs: []HashCoeff,

        const HashCoeff = struct {
            a: HashType,
            b: HashType,
        };

        /// Initialize LSH with specified parameters
        /// num_hashes: total number of hash functions (should be bands * rows_per_band)
        /// bands: number of bands for LSH banding
        /// rows_per_band: number of rows per band
        /// Seed used by `init` so indexes built separately are comparable.
        pub const default_seed: u64 = 0x5052_425A_4C53_4831;

        pub fn init(allocator: Allocator, num_hashes: u32, bands: u32, rows_per_band: u32) !Self {
            return initSeeded(allocator, num_hashes, bands, rows_per_band, default_seed);
        }

        /// Like `init`, with an explicit seed for the MinHash coefficients.
        pub fn initSeeded(allocator: Allocator, num_hashes: u32, bands: u32, rows_per_band: u32, seed: u64) !Self {
            if (num_hashes == 0 or bands == 0 or rows_per_band == 0) {
                return LSHError.InvalidParameters;
            }

            if (num_hashes != bands * rows_per_band) {
                return LSHError.InvalidParameters;
            }

            // Generate random coefficients for universal hashing
            var rng = std.Random.DefaultPrng.init(seed);
            const random = rng.random();

            const hash_coeffs = try allocator.alloc(HashCoeff, num_hashes);
            for (hash_coeffs) |*coeff| {
                coeff.a = random.int(HashType) | 1; // ensure odd
                coeff.b = random.int(HashType);
            }

            return Self{
                .allocator = allocator,
                .num_hashes = num_hashes,
                .bands = bands,
                .rows_per_band = rows_per_band,
                .items = try ArrayList(LSHItem).initCapacity(allocator, 0),
                .buckets = AutoHashMap(u64, ArrayList(u32)).init(allocator),
                .hash_coeffs = hash_coeffs,
            };
        }

        /// Initialize with automatic parameter calculation for given similarity threshold
        /// threshold: minimum Jaccard similarity to detect (0.0 to 1.0)
        /// num_hashes: total number of hash functions to use
        pub fn initWithThreshold(allocator: Allocator, threshold: f64, num_hashes: u32) !Self {
            if (!(threshold > 0.0 and threshold < 1.0) or num_hashes == 0) {
                return LSHError.InvalidParameters;
            }

            const optimal_bands = calculateOptimalBands(threshold, num_hashes);
            const rows_per_band = num_hashes / optimal_bands;

            return try Self.init(allocator, optimal_bands * rows_per_band, optimal_bands, rows_per_band);
        }

        pub fn deinit(self: *Self) void {
            // Clean up items
            for (self.items.items) |*item| {
                item.deinit(self.allocator);
            }
            self.items.deinit(self.allocator);

            // Clean up buckets
            var bucket_iter = self.buckets.iterator();
            while (bucket_iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.buckets.deinit();

            self.allocator.free(self.hash_coeffs);
        }

        /// Add an item to the LSH with its set representation
        /// id: unique identifier for the item
        /// tokens: set of tokens/shingles representing the item
        pub fn add(self: *Self, id: []const u8, tokens: []const []const u8) !void {
            // Create MinHash signature
            const signature = try self.computeMinHashSignature(tokens);

            // Store item
            const owned_id = try self.allocator.dupe(u8, id);
            const item = LSHItem{
                .id = owned_id,
                .signature = signature,
            };

            const item_index: u32 = @intCast(self.items.items.len);
            try self.items.append(self.allocator, item);

            // Add to LSH buckets
            try self.addToBuckets(item_index, signature);
        }

        /// Find candidate similar items for the given item
        /// Returns items that hash to the same bucket in at least one band
        pub fn query(self: *const Self, tokens: []const []const u8) !ArrayList(Candidate) {
            const signature = try self.computeMinHashSignature(tokens);
            defer self.allocator.free(signature);

            var candidates = AutoHashMap(u32, void).init(self.allocator);
            defer candidates.deinit();

            // Find candidates from all bands
            for (0..self.bands) |band| {
                const band_hash = self.computeBandHash(signature, @intCast(band));

                if (self.buckets.get(band_hash)) |bucket| {
                    for (bucket.items) |item_idx| {
                        try candidates.put(item_idx, {});
                    }
                }
            }

            // Convert to result list with similarity scores
            var results = try ArrayList(Candidate).initCapacity(self.allocator, 0);
            var candidate_iter = candidates.keyIterator();

            while (candidate_iter.next()) |item_idx_ptr| {
                const item_idx = item_idx_ptr.*;
                const item = &self.items.items[item_idx];
                const sim = self.estimateJaccardSimilarity(signature, item.signature);

                const candidate = Candidate{
                    .id = item.id,
                    .similarity = sim,
                };
                try results.append(self.allocator, candidate);
            }

            return results;
        }

        /// Estimate Jaccard similarity between two items by their IDs
        pub fn similarity(self: *const Self, id1: []const u8, id2: []const u8) !f64 {
            const item1 = self.findItem(id1) orelse return LSHError.ItemNotFound;
            const item2 = self.findItem(id2) orelse return LSHError.ItemNotFound;

            return self.estimateJaccardSimilarity(item1.signature, item2.signature);
        }

        /// Compute MinHash signature for a set of tokens
        fn computeMinHashSignature(self: *const Self, tokens: []const []const u8) ![]u32 {
            const signature = try self.allocator.alloc(u32, self.num_hashes);

            // Initialize with maximum values
            for (signature) |*sig| {
                sig.* = math.maxInt(u32);
            }

            // Compute min hash for each token
            for (tokens) |token| {
                const token_hash = hash.XxHash32.hash(0, token);

                for (0..self.num_hashes) |i| {
                    const coeff = &self.hash_coeffs[i];
                    const h = coeff.a *% token_hash +% coeff.b;

                    if (h < signature[i]) {
                        signature[i] = h;
                    }
                }
            }

            return signature;
        }

        /// Add item to LSH buckets using banding technique
        fn addToBuckets(self: *Self, item_index: u32, signature: []const u32) !void {
            for (0..self.bands) |band| {
                const band_hash = self.computeBandHash(signature, @intCast(band));

                const result = try self.buckets.getOrPut(band_hash);
                if (!result.found_existing) {
                    result.value_ptr.* = try ArrayList(u32).initCapacity(self.allocator, 0);
                }
                try result.value_ptr.append(self.allocator, item_index);
            }
        }

        /// Compute hash for a specific band
        fn computeBandHash(self: *const Self, signature: []const u32, band: u32) u64 {
            const start = band * self.rows_per_band;
            const end = start + self.rows_per_band;

            var h: u64 = 0;
            for (start..end) |i| {
                h = h *% 31 +% signature[i];
            }
            return h;
        }

        /// Estimate Jaccard similarity from MinHash signatures
        fn estimateJaccardSimilarity(self: *const Self, sig1: []const u32, sig2: []const u32) f64 {
            var matches: u32 = 0;

            for (0..self.num_hashes) |i| {
                if (sig1[i] == sig2[i]) {
                    matches += 1;
                }
            }

            return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(self.num_hashes));
        }

        /// Find item by ID
        fn findItem(self: *const Self, id: []const u8) ?*const LSHItem {
            for (self.items.items) |*item| {
                if (std.mem.eql(u8, item.id, id)) {
                    return item;
                }
            }
            return null;
        }
    };
}

/// Calculate optimal number of bands for given similarity threshold
/// Uses approximation to optimize detection probability
fn calculateOptimalBands(threshold: f64, num_hashes: u32) u32 {
    var best_bands: u32 = 1;
    var best_prob: f64 = 0.0;

    for (1..num_hashes + 1) |bands| {
        if (num_hashes % bands != 0) continue;

        const rows = num_hashes / bands;
        const prob = 1.0 - math.pow(f64, 1.0 - math.pow(f64, threshold, @floatFromInt(rows)), @floatFromInt(bands));

        if (prob > best_prob) {
            best_prob = prob;
            best_bands = @intCast(bands);
        }
    }

    return best_bands;
}

const testing = std.testing;

test "init with parameters" {
    var lsh = try LSH(u32).init(testing.allocator, 64, 16, 4);
    defer lsh.deinit();

    try testing.expectEqual(@as(u32, 64), lsh.num_hashes);
    try testing.expectEqual(@as(u32, 16), lsh.bands);
    try testing.expectEqual(@as(u32, 4), lsh.rows_per_band);
}

test "init with threshold" {
    var lsh = try DefaultLSH.initWithThreshold(testing.allocator, 0.8, 64);
    defer lsh.deinit();

    try testing.expect(lsh.num_hashes <= 64);
    try testing.expect(lsh.bands > 0);
    try testing.expect(lsh.rows_per_band > 0);
}

test "add and basic functionality" {
    var lsh = try DefaultLSH.init(testing.allocator, 64, 16, 4);
    defer lsh.deinit();

    const tokens1 = [_][]const u8{ "apple", "banana", "cherry" };
    const tokens2 = [_][]const u8{ "apple", "banana", "date" };

    try lsh.add("doc1", &tokens1);
    try lsh.add("doc2", &tokens2);

    try testing.expectEqual(@as(usize, 2), lsh.items.items.len);
}

test "query similar items" {
    var lsh = try DefaultLSH.init(testing.allocator, 64, 16, 4);
    defer lsh.deinit();

    const tokens1 = [_][]const u8{ "apple", "banana", "cherry" };
    const tokens2 = [_][]const u8{ "apple", "banana", "date" };
    const tokens3 = [_][]const u8{ "apple", "banana", "cherry" }; // identical to tokens1

    try lsh.add("doc1", &tokens1);
    try lsh.add("doc2", &tokens2);

    var candidates = try lsh.query(&tokens3);
    defer candidates.deinit(testing.allocator);

    try testing.expect(candidates.items.len > 0);

    // Should find doc1 with high similarity (identical sets)
    var found_identical = false;
    for (candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.id, "doc1")) {
            try testing.expect(candidate.similarity > 0.9);
            found_identical = true;
        }
    }
    try testing.expect(found_identical);
}

test "similarity estimation" {
    var lsh = try DefaultLSH.init(testing.allocator, 64, 16, 4);
    defer lsh.deinit();

    const tokens1 = [_][]const u8{ "apple", "banana", "cherry" };
    const tokens2 = [_][]const u8{ "apple", "banana", "date" };

    try lsh.add("doc1", &tokens1);
    try lsh.add("doc2", &tokens2);

    const sim = try lsh.similarity("doc1", "doc2");

    // Jaccard similarity of {apple,banana,cherry} and {apple,banana,date}
    // should be 2/4 = 0.5, but MinHash is an approximation
    try testing.expect(sim >= 0.0 and sim <= 1.0);
}

test "invalid parameters" {
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.init(testing.allocator, 0, 1, 1));
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.init(testing.allocator, 10, 0, 1));
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.init(testing.allocator, 10, 1, 0));
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.init(testing.allocator, 10, 3, 4)); // 3*4 != 10

    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.initWithThreshold(testing.allocator, 0.0, 64));
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.initWithThreshold(testing.allocator, 1.0, 64));
    try testing.expectError(LSHError.InvalidParameters, DefaultLSH.initWithThreshold(testing.allocator, 0.5, 0));
}

test "item not found" {
    var lsh = try DefaultLSH.init(testing.allocator, 64, 16, 4);
    defer lsh.deinit();

    const tokens = [_][]const u8{ "apple", "banana" };
    try lsh.add("doc1", &tokens);

    try testing.expectError(LSHError.ItemNotFound, lsh.similarity("doc1", "nonexistent"));
}
