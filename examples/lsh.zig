const std = @import("std");
const probz = @import("probz");

/// Character 3-grams ("shingles") of a string.
fn shingles(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    if (text.len < 3) return allocator.dupe([]const u8, &.{text});
    const out = try allocator.alloc([]const u8, text.len - 2);
    for (out, 0..) |*s, i| s.* = text[i..][0..3];
    return out;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 128 hashes; bands/rows chosen so the candidate threshold is ~0.5.
    var lsh = try probz.MinHashLSH.initWithThreshold(allocator, 0.5, 128, 42);
    defer lsh.deinit(allocator);
    std.debug.print("bands={d} rows={d}; P(candidate | s=0.3)={d:.3}, s=0.8: {d:.3}\n", .{
        lsh.bands, lsh.rows, lsh.candidateProbability(0.3), lsh.candidateProbability(0.8),
    });

    const docs = [_]struct { id: []const u8, text: []const u8 }{
        .{ .id = "doc1", .text = "the quick brown fox jumps over the lazy dog" },
        .{ .id = "doc2", .text = "the quick brown fox jumped over the lazy dog" },
        .{ .id = "doc3", .text = "a completely different sentence about zig" },
    };
    for (docs) |d| {
        const sh = try shingles(allocator, d.text);
        defer allocator.free(sh);
        try lsh.add(allocator, d.id, sh);
    }

    const q = try shingles(allocator, "the quick brown fox jumps over a lazy dog");
    defer allocator.free(q);
    const results = try lsh.query(allocator, q);
    defer allocator.free(results);
    std.debug.print("candidates for the query:\n", .{});
    for (results) |c| std.debug.print("  {s}: similarity ~ {d:.2}\n", .{ c.id, c.similarity });

    std.debug.print("similarity(doc1, doc2) ~ {d:.2}\n", .{try lsh.similarity("doc1", "doc2")});
    std.debug.print("similarity(doc1, doc3) ~ {d:.2}\n", .{try lsh.similarity("doc1", "doc3")});
}
