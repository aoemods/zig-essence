const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // tests

    const main_tests = b.addTest("essence.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    // sgatool

    const sgatool_exe = b.addExecutable("sgatool", "tools/sgatool.zig");
    sgatool_exe.addPackage(.{
        .name = "essence",
        .source = .{ .path = "essence.zig" },
    });
    sgatool_exe.setTarget(target);
    sgatool_exe.setBuildMode(mode);
    sgatool_exe.install();

    const sgatool_run_cmd = sgatool_exe.run();
    sgatool_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        sgatool_run_cmd.addArgs(args);
    }

    const sgatool_run_step = b.step("sgatool", "Run the app");
    sgatool_run_step.dependOn(&sgatool_run_cmd.step);
}
