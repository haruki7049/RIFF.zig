const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module declaration
    const lib_mod = b.addModule("riff_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library installation
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "riff_zig",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Library unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Benchmark (prototype): read() vs. stream.readTree()/stream.Iterator.
    // zig build bench -Doptimize=ReleaseFast -- <read|tree|tree_unsized|skip> <path> [iterations] [buffer_bytes] [--rss=none|single|first|subprocess] [--alloc-stats]
    // See bench/stream_bench.zig's doc comment for what each flag does.
    const bench_exe = b.addExecutable(.{
        .name = "stream-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/stream_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "riff", .module = lib_mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the streaming prototype benchmark");
    bench_step.dependOn(&run_bench.step);

    // Docs
    const docs_step = b.step("docs", "Emit docs");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "share/RIFF.zig/docs",
    });
    docs_step.dependOn(&docs_install.step);
}
