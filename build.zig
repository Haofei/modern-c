const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mcc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MC compiler");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const c_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check-generated-c.sh",
        "zig-out/bin/mcc",
        "tests/c_emit_*.mc",
        "zig-out/c-test",
    });
    c_test_cmd.step.dependOn(b.getInstallStep());
    const c_test_step = b.step("c-test", "Emit C for smoke fixture and compile-check it with clang");
    c_test_step.dependOn(&c_test_cmd.step);

    const sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/spec-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    sweep_cmd.step.dependOn(b.getInstallStep());
    const sweep_step = b.step("sweep", "Emit C for every valid spec-corpus function and compile-check it with clang");
    sweep_step.dependOn(&sweep_cmd.step);

    const m0_step = b.step("m0", "Run M0 conformance gates");
    m0_step.dependOn(&test_cmd.step);
    m0_step.dependOn(&c_test_cmd.step);
    m0_step.dependOn(&sweep_cmd.step);
}
