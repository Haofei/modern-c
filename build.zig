const std = @import("std");
const compiler = @import("build/compiler.zig");
const sweep = @import("build/sweep.zig");
const selfhost = @import("build/selfhost.zig");
const fuzz = @import("build/fuzz.zig");
const hardening = @import("build/hardening.zig");
const qemu = @import("build/qemu.zig");
const tiers = @import("build/tiers.zig");

// Thin orchestrator. The build graph is declared across build/*.zig modules,
// each adding its steps via `register(&ctx)`. `compiler.build` constructs the
// `mcc` exe + install step and the `run`/`test` steps and returns the shared Ctx;
// the per-fixture modules register their command steps into `ctx.cmds` keyed by
// public step name; `tiers` then aggregates them by name into fast/c0/c1/m0.
// Modules MUST run before `tiers` so every command it looks up is registered.
//
// This is a pure-structure decomposition of the former 4,481-line single build():
// the set of step names, descriptions, argv, and dependency edges is unchanged.
pub fn build(b: *std.Build) void {
    var ctx = compiler.build(b);
    sweep.register(&ctx);
    selfhost.register(&ctx);
    fuzz.register(&ctx);
    hardening.register(&ctx);
    qemu.register(&ctx);
    tiers.register(&ctx);
}
