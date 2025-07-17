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
        .name = "riff_zig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
