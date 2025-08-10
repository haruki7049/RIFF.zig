const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // RIFF.zig
    const riff_zig = b.dependency("riff_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Executable declaration
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("riff_zig", riff_zig.module("riff_zig"));

    const exe = b.addExecutable(.{
        .name = "list_riff",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);
}
