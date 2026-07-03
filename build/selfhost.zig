const h = @import("helpers.zig");

// Full self-hosting P0 gates. These are intentionally separate from m0 at first:
// they prove the harness/selector/stage contract without redefining the current
// production compiler gates.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "full-selfhost-diff", "P0: compare the Zig oracle and compiler-under-test on the tiny full-selfhost manifest", &.{ "bash", "tools/toolchain/full-selfhost-diff.sh" });
    _ = h.addScriptTest(ctx, "full-selfhost-stage", "P0: run the Stage0/Stage1/Stage2 self-host scaffold without claiming full replacement", &.{ "bash", "tools/toolchain/full-selfhost-stage.sh" });

    const p0_step = ctx.b.step("full-selfhost-p0", "Run the full-selfhost P0 harness gates");
    p0_step.dependOn(ctx.cmd("full-selfhost-diff"));
    p0_step.dependOn(ctx.cmd("full-selfhost-stage"));
}
