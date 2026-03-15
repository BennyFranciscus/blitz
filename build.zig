const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Blitz framework module
    const blitz_mod = b.addModule("blitz", .{
        .root_source_file = b.path("src/blitz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // HttpArena benchmark server
    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/blitz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
