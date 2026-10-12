const std = @import("std");

pub fn build(b: *std.Build) void {
    // Match Package.swift's deployment target rather than the build machine's OS.
    const default_target: std.Target.Query = if (@import("builtin").os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "talys_engine",
        .root_module = engine_module,
    });

    lib.bundle_compiler_rt = true;

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = engine_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const copy_step = b.step("copy-to-spm", "Copy lib to SPM Sources folder");
    const copy_lib = b.addSystemCommand(&.{"cp"});
    copy_lib.addFileArg(lib.getEmittedBin());
    copy_lib.addArg("../Sources/CTalysEngine/libtalys_engine.a");
    copy_lib.step.dependOn(b.getInstallStep());
    copy_step.dependOn(&copy_lib.step);
}
