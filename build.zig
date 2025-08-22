const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "probz",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Example executables
    const examples = [_][]const u8{
        "bloom_filter",
        "counting_bloom_filter",
        "scalable_bloom_filter",
        "quotient_filter",
        "cuckoo_filter",
    };

    // Build all examples
    for (examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
                .target = target,
                .optimize = optimize,
            }),
        });

        example_exe.root_module.addImport("probz", lib_mod);
        b.installArtifact(example_exe);
    }

    // Create a single run-example command that takes the example name as argument
    const run_example_step = b.step("run-example", "Run a specific example (usage: zig build run-example -- <example_name>)");

    // Only validate and create executable if args are provided
    if (b.args) |args| {
        if (args.len == 0) {
            std.debug.print("Error: Please specify an example name\n", .{});
            for (examples) |example| {
                std.debug.print(" {s}", .{example});
            }
            std.debug.print("\n", .{});
            std.process.exit(1);
        }

        const selected_example = args[0];

        // Validate example name
        var found = false;
        for (examples) |example| {
            if (std.mem.eql(u8, selected_example, example)) {
                found = true;
                break;
            }
        }

        if (!found) {
            std.debug.print("Error: Unknown example '{s}'\n", .{selected_example});
            for (examples) |example| {
                std.debug.print(" {s}", .{example});
            }
            std.debug.print("\n", .{});
            std.process.exit(1);
        }

        // Create and run the specified example
        const example_exe = b.addExecutable(.{
            .name = b.fmt("run_{s}", .{selected_example}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{selected_example})),
                .target = target,
                .optimize = optimize,
            }),
        });

        example_exe.root_module.addImport("probz", lib_mod);
        const run_example = b.addRunArtifact(example_exe);
        run_example_step.dependOn(&run_example.step);
    }

    // Create a step to run all examples
    const run_all_examples_step = b.step("run-examples", "Run all examples");
    for (examples) |example| {
        const example_exe_all = b.addExecutable(.{
            .name = b.fmt("{s}_all", .{example}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
                .target = target,
                .optimize = optimize,
            }),
        });
        example_exe_all.root_module.addImport("probz", lib_mod);

        const run_example_all = b.addRunArtifact(example_exe_all);
        run_all_examples_step.dependOn(&run_example_all.step);
    }
}
