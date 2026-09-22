const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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
    const copy_lib = b.addSystemCommand(&.{
        "cp",
        b.fmt("{s}/lib/libtalys_engine.a", .{b.install_path}),
        "../Sources/CTalysEngine/libtalys_engine.a",
    });
    copy_lib.step.dependOn(b.getInstallStep());
    copy_step.dependOn(&copy_lib.step);
}
