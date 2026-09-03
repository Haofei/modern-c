const std = @import("std");
const h = @import("helpers.zig");

/// Builds the private compiler executable, installs the public `mcc` launcher,
/// wires the `run` and `test`
/// (in-process unit tests) steps, and returns a Ctx whose install step the other
/// modules hang their per-fixture commands off of. The `test` command step is
/// registered into the Ctx so the tier aggregations can depend on it by name.
pub fn build(b: *std.Build) h.Ctx {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string reported by `mcc --version`") orelse "0.7.0-dev";
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only compile and run tests whose names contain this text")) |filter|
        b.allocator.dupe([]const u8, &.{filter}) catch @panic("OOM")
    else
        &.{};
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);
    root_module.addAnonymousImport("diagnostics_reference_md", .{
        .root_source_file = b.path("docs/diagnostics.md"),
    });

    const exe = b.addExecutable(.{
        .name = "mcc-real",
        .root_module = root_module,
    });
    b.installArtifact(exe);
    b.installBinFile("tools/toolchain/mcc-launcher.sh", "mcc");
    b.installFile("tools/toolchain/mcc-build.sh", "tools/toolchain/mcc-build.sh");
    b.installFile("tools/toolchain/mcc-cc.sh", "tools/toolchain/mcc-cc.sh");
    b.installFile("tools/toolchain/mcc-llvm-cc.sh", "tools/toolchain/mcc-llvm-cc.sh");

    var ctx = h.Ctx.init(b, b.getInstallStep());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MC compiler");
    run_step.dependOn(&run_cmd.step);

    // Preserve the historical `test-unit` coverage, while executing its four
    // test-disjoint roots in parallel. The root composition stays in
    // `src/test_root.zig`; this build registry owns the partition wiring.
    const unit_test_step = b.step("test-unit", "Run compiler unit tests");
    const unit_core_step = addTestShard(b, target, optimize, options, test_filters, "test-unit-core", "src/test_root_core.zig", "Run compiler core/front-end unit-test partition");
    const unit_mir_step = addTestShard(b, target, optimize, options, test_filters, "test-unit-mir", "src/test_root_mir.zig", "Run compiler MIR model/verifier unit-test partition");
    unit_test_step.dependOn(unit_core_step);
    unit_test_step.dependOn(unit_mir_step);

    const frontend_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-frontend", "src/test_shard_frontend.zig", "Run frontend lexer/parser/loader unit-test shard");
    const sema_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-sema", "src/test_shard_sema.zig", "Run semantic analysis and monomorphization unit-test shard");
    const mir_cleanup_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-mir-cleanup", "src/test_shard_mir_cleanup.zig", "Run MIR/ownership cleanup authority unit-test shard");
    const lower_c_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-lower-c", "src/test_shard_lower_c.zig", "Run C backend unit-test shard");
    const lower_llvm_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-lower-llvm", "src/test_shard_lower_llvm.zig", "Run LLVM backend unit-test shard");
    const backend_shard_step = addTestShard(b, target, optimize, options, test_filters, "test-shard-backend", "src/test_shard_backend.zig", "Run C/LLVM backend unit-test shard");
    unit_test_step.dependOn(lower_c_shard_step);
    unit_test_step.dependOn(lower_llvm_shard_step);

    const unit_shards_step = b.step("test-unit-shards", "Run compiler unit-test shards");
    unit_shards_step.dependOn(frontend_shard_step);
    unit_shards_step.dependOn(sema_shard_step);
    unit_shards_step.dependOn(mir_cleanup_shard_step);
    unit_shards_step.dependOn(lower_c_shard_step);
    unit_shards_step.dependOn(lower_llvm_shard_step);

    // Keep the specification fixture suite as an explicit build dependency.
    // Importing it through main is not sufficient for Zig's lazy test analysis.
    const spec_test_module = b.createModule(.{
        .root_source_file = b.path("src/spec_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_test_module.addOptions("build_options", options);
    spec_test_module.addAnonymousImport("diagnostics_reference_md", .{
        .root_source_file = b.path("docs/diagnostics.md"),
    });
    const spec_tests = b.addTest(.{
        .root_module = spec_test_module,
        .filters = test_filters,
    });
    const spec_test_cmd = b.addRunArtifact(spec_tests);
    const spec_test_step = b.step("test-spec", "Run specification fixture tests");
    spec_test_step.dependOn(&spec_test_cmd.step);

    // `test` has no install dep (in-process unit tests). Registered into ctx so
    // the tier aggregations can depend on its command step like the others.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(&spec_test_cmd.step);
    ctx.cmds.put("test-unit", unit_test_step) catch @panic("OOM");
    ctx.cmds.put("test-unit-core", unit_core_step) catch @panic("OOM");
    ctx.cmds.put("test-unit-mir", unit_mir_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-frontend", frontend_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-sema", sema_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-mir-cleanup", mir_cleanup_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-lower-c", lower_c_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-lower-llvm", lower_llvm_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-shard-backend", backend_shard_step) catch @panic("OOM");
    ctx.cmds.put("test-unit-shards", unit_shards_step) catch @panic("OOM");
    ctx.cmds.put("test-spec", spec_test_step) catch @panic("OOM");
    ctx.cmds.put("test", test_step) catch @panic("OOM");

    return ctx;
}

fn addTestShard(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    filters: []const []const u8,
    name: []const u8,
    root_source_file: []const u8,
    description: []const u8,
) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    module.addAnonymousImport("diagnostics_reference_md", .{
        .root_source_file = b.path("docs/diagnostics.md"),
    });
    const tests = b.addTest(.{ .root_module = module, .filters = filters });
    const run = b.addRunArtifact(tests);
    const step = b.step(name, description);
    step.dependOn(&run.step);
    return step;
}
