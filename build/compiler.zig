const std = @import("std");
const h = @import("helpers.zig");

/// Builds the `mcc` compiler executable, installs it, wires the `run` and `test`
/// (in-process unit tests) steps, and returns a Ctx whose install step the other
/// modules hang their per-fixture commands off of. The `test` command step is
/// registered into the Ctx so the tier aggregations can depend on it by name.
pub fn build(b: *std.Build) h.Ctx {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string reported by `mcc --version`") orelse "0.7.0-dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "mcc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    var ctx = h.Ctx.init(b, b.getInstallStep());

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
    // `test` has no install dep (in-process unit tests). Registered into ctx so
    // the tier aggregations can depend on its command step like the others.
    ctx.cmds.put("test", &test_cmd.step) catch @panic("OOM");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    return ctx;
}
