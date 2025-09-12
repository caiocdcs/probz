const std = @import("std");
const LSH = @import("probz").LSH;
const DefaultLSH = @import("probz").DefaultLSH;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create LSH for document similarity detection
    // Using 64 hash functions, 16 bands, 4 rows per band
    var lsh = try DefaultLSH.init(allocator, 64, 16, 4);
    defer lsh.deinit();

    // Sample documents represented as word sets (simplified)
    const doc1_words = [_][]const u8{ "machine", "learning", "algorithm", "data", "model" };
    const doc2_words = [_][]const u8{ "machine", "learning", "neural", "network", "model" };
    const doc3_words = [_][]const u8{ "cooking", "recipe", "kitchen", "food", "ingredient" };
    const doc4_words = [_][]const u8{ "machine", "learning", "artificial", "intelligence", "model" };

    // Add documents to LSH
    try lsh.add("paper1", &doc1_words);
    try lsh.add("paper2", &doc2_words);
    try lsh.add("paper3", &doc3_words);
    try lsh.add("paper4", &doc4_words);

    std.debug.print("=== LSH Document Similarity Example ===\n\n", .{});

    // Query for similar documents
    const query_words = [_][]const u8{ "machine", "learning", "deep", "model" };
    std.debug.print("Query: machine learning deep model\n\n", .{});

    var candidates = try lsh.query(&query_words);
    defer candidates.deinit(allocator);

    std.debug.print("Similar documents found:\n", .{});
    for (candidates.items) |candidate| {
        std.debug.print("  {s}: similarity = {d:.3}\n", .{ candidate.id, candidate.similarity });
    }

    // Check pairwise similarities
    std.debug.print("\n=== Pairwise Similarities ===\n", .{});

    const sim12 = try lsh.similarity("paper1", "paper2");
    std.debug.print("paper1 vs paper2: {d:.3}\n", .{sim12});

    const sim13 = try lsh.similarity("paper1", "paper3");
    std.debug.print("paper1 vs paper3: {d:.3}\n", .{sim13});

    const sim14 = try lsh.similarity("paper1", "paper4");
    std.debug.print("paper1 vs paper4: {d:.3}\n", .{sim14});

    // Demonstrate LSH with automatic threshold selection
    std.debug.print("\n=== LSH with Automatic Parameters ===\n", .{});
    var auto_lsh = try DefaultLSH.initWithThreshold(allocator, 0.7, 64);
    defer auto_lsh.deinit();

    std.debug.print("Auto-configured LSH for 70% similarity threshold:\n", .{});
    std.debug.print("  Bands: {}\n", .{auto_lsh.bands});
    std.debug.print("  Rows per band: {}\n", .{auto_lsh.rows_per_band});
    std.debug.print("  Total hash functions: {}\n", .{auto_lsh.num_hashes});

    // Add same documents to auto-configured LSH
    try auto_lsh.add("paper1", &doc1_words);
    try auto_lsh.add("paper2", &doc2_words);
    try auto_lsh.add("paper3", &doc3_words);
    try auto_lsh.add("paper4", &doc4_words);

    // Query again
    var auto_candidates = try auto_lsh.query(&query_words);
    defer auto_candidates.deinit(allocator);

    std.debug.print("\nSimilar documents with auto-config:\n", .{});
    for (auto_candidates.items) |candidate| {
        std.debug.print("  {s}: similarity = {d:.3}\n", .{ candidate.id, candidate.similarity });
    }

    // Demonstrate text document similarity using shingles
    std.debug.print("\n=== Text Similarity with Shingles ===\n", .{});

    const text1 = "the quick brown fox jumps over the lazy dog";
    const text2 = "the quick brown fox jumps over a lazy dog";
    const text3 = "a completely different sentence about cats and birds";

    // Create 3-grams (shingles) from text
    const shingles1 = try createShingles(allocator, text1, 3);
    defer freeShingles(allocator, shingles1);

    const shingles2 = try createShingles(allocator, text2, 3);
    defer freeShingles(allocator, shingles2);

    const shingles3 = try createShingles(allocator, text3, 3);
    defer freeShingles(allocator, shingles3);

    var text_lsh = try DefaultLSH.init(allocator, 128, 32, 4);
    defer text_lsh.deinit();

    try text_lsh.add("text1", shingles1);
    try text_lsh.add("text2", shingles2);
    try text_lsh.add("text3", shingles3);

    const text_sim12 = try text_lsh.similarity("text1", "text2");
    const text_sim13 = try text_lsh.similarity("text1", "text3");

    std.debug.print("Text1 vs Text2 similarity: {d:.3}\n", .{text_sim12});
    std.debug.print("Text1 vs Text3 similarity: {d:.3}\n", .{text_sim13});

    std.debug.print("\nLSH provides fast approximate similarity search!\n", .{});
}

fn createShingles(allocator: std.mem.Allocator, text: []const u8, k: usize) ![][]const u8 {
    var shingles = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    if (text.len < k) return shingles.toOwnedSlice(allocator);

    for (0..text.len - k + 1) |i| {
        const shingle = try allocator.dupe(u8, text[i .. i + k]);
        try shingles.append(allocator, shingle);
    }

    return shingles.toOwnedSlice(allocator);
}

fn freeShingles(allocator: std.mem.Allocator, shingles: [][]const u8) void {
    for (shingles) |shingle| {
        allocator.free(shingle);
    }
    allocator.free(shingles);
}
