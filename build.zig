const std = @import("std");

const examples = [_][]const u8{
    "bloom_filter",
    "counting_bloom_filter",
    "scalable_bloom_filter",
    "quotient_filter",
    "cuckoo_filter",
    "hyperloglog",
    "count_min_sketch",
    "top_k_example",
    "tdigest",
    "qdigest",
    "lsh",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module: dependents use `dep.module("probz")`.
    const probz = b.addModule("probz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "probz",
        .root_module = probz,
    });
    b.installArtifact(lib);

    // zig build test
    const tests = b.addTest(.{ .root_module = probz });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Golden vectors (SPEC.md §4): generator module shared by the
    // gen-vectors tool and the staleness test.
    const testdata = b.createModule(.{ .root_source_file = b.path("testdata/vectors.zig") });
    const vectors = b.createModule(.{
        .root_source_file = b.path("tools/vectors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "probz", .module = probz },
            .{ .name = "testdata", .module = testdata },
        },
    });
    const vector_tests = b.addTest(.{ .root_module = vectors });
    test_step.dependOn(&b.addRunArtifact(vector_tests).step);

    const gen_vectors = b.addExecutable(.{
        .name = "gen_vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_vectors.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vectors", .module = vectors }},
        }),
    });
    const run_gen = b.addRunArtifact(gen_vectors);
    run_gen.addDirectoryArg(b.path("testdata"));
    b.step("gen-vectors", "Regenerate golden test vectors in testdata/").dependOn(&run_gen.step);

    // zig build docs
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // Examples: built once, shared by every example-related step.
    const examples_step = b.step("examples", "Build and install all examples");
    const run_examples_step = b.step("run-examples", "Run all examples");
    const run_example_step = b.step("run-example", "Run one example (zig build run-example -Dexample=<name>)");
    const selected = b.option([]const u8, "example", "Example to run with the run-example step");
    var selected_found = false;

    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "probz", .module = probz }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        run_examples_step.dependOn(&run.step);

        if (selected) |sel| if (std.mem.eql(u8, sel, name)) {
            run_example_step.dependOn(&b.addRunArtifact(exe).step);
            selected_found = true;
        };
    }

    if (!selected_found) {
        const msg = if (selected) |sel|
            b.fmt("unknown example '{s}'; available: {s}", .{ sel, examplesList(b) })
        else
            b.fmt("pass -Dexample=<name>; available: {s}", .{examplesList(b)});
        run_example_step.dependOn(&b.addFail(msg).step);
    }
}

fn examplesList(b: *std.Build) []const u8 {
    return std.mem.join(b.allocator, ", ", &examples) catch @panic("OOM");
}
