const std = @import("std");
const Step = std.Build.Step;
const Run = std.Build.Step.Run;

/// Shared context threaded through every build module. `build()` constructs the
/// compiler exe + install step once, then each module's `register(ctx)` adds its
/// steps. The tiers module looks up the per-test *command* (Run) step handles the
/// other modules created (keyed by the public step name) so it can reproduce the
/// exact `m0_step.dependOn(&X_cmd.step)` edges the hand-written build had.
pub const Ctx = struct {
    b: *std.Build,
    install: *Step,
    /// step-name -> the addSystemCommand Run step that the named step depends on.
    /// This is the `&X_cmd.step` the tier aggregations reference.
    cmds: std.StringHashMap(*Step),

    pub fn init(b: *std.Build, install: *Step) Ctx {
        return .{
            .b = b,
            .install = install,
            .cmds = std.StringHashMap(*Step).init(b.allocator),
        };
    }

    /// Look up the command step previously registered under `name`. Panics if
    /// missing — that means a tier referenced a step no module created, a build
    /// bug we want to surface loudly rather than silently drop a gate.
    pub fn cmd(self: *Ctx, name: []const u8) *Step {
        return self.cmds.get(name) orelse std.debug.panic("build: no command step registered for '{s}'", .{name});
    }

    fn register(self: *Ctx, name: []const u8, s: *Step) void {
        self.cmds.put(name, s) catch @panic("OOM registering build step");
    }
};

/// Options for the per-test boilerplate. Defaults reproduce the canonical block:
/// the command depends on the install step.
pub const ScriptOpts = struct {
    /// false => omit the `cmd.step.dependOn(install)` edge (the handful of
    /// tool-free static checks that don't need the compiler built).
    install: bool = true,
    /// true => `cmd.stdio = .inherit` (the interactive `run-*ushell` steps).
    inherit_stdio: bool = false,
};

/// Collapses the repeated 5-line per-test boilerplate:
///   const X_cmd = b.addSystemCommand(argv);
///   X_cmd.step.dependOn(b.getInstallStep());
///   const X_step = b.step(name, desc);
///   X_step.dependOn(&X_cmd.step);
/// Registers the command (Run) step into ctx.cmds under `name` (so the tier
/// aggregations can depend on it) and returns the Run so callers can customize.
pub fn addScriptTest(ctx: *Ctx, name: []const u8, desc: []const u8, argv: []const []const u8) *Run {
    return addScriptTestOpts(ctx, name, desc, argv, .{});
}

pub fn addScriptTestOpts(ctx: *Ctx, name: []const u8, desc: []const u8, argv: []const []const u8, opts: ScriptOpts) *Run {
    const cmd = ctx.b.addSystemCommand(argv);
    if (opts.install) cmd.step.dependOn(ctx.install);
    if (opts.inherit_stdio) cmd.stdio = .inherit;
    const step = ctx.b.step(name, desc);
    step.dependOn(&cmd.step);
    ctx.register(name, &cmd.step);
    return cmd;
}

/// A command that is registered (so tiers can depend on it) but has NO named
/// public step of its own — e.g. the strict `demo-test`/`kernel-test` variants
/// that only exist as tier dependencies. `key` is the lookup name used by tiers.
pub fn addRawCmd(ctx: *Ctx, key: []const u8, argv: []const []const u8) *Run {
    const cmd = ctx.b.addSystemCommand(argv);
    cmd.step.dependOn(ctx.install);
    ctx.register(key, &cmd.step);
    return cmd;
}

/// Collapses the C-vs-LLVM PAIR block: the same script run with arg "c" producing
/// step "<base>" and with arg "llvm" producing step "llvm-<base>". `extraArgs` are
/// appended AFTER the backend arg, matching the existing argv shape
/// `&.{ interpreter, scriptPath, "zig-out/bin/mcc", <backend>, extraArgs... }`.
/// The two halves take distinct human-written descriptions.
pub fn addBackendPair(
    ctx: *Ctx,
    base: []const u8,
    cDesc: []const u8,
    llvmDesc: []const u8,
    interpreter: []const u8,
    scriptPath: []const u8,
    extraArgs: []const []const u8,
) void {
    const b = ctx.b;
    _ = addScriptTest(ctx, base, cDesc, buildArgv(b, interpreter, scriptPath, "c", extraArgs));
    const llvm_name = std.fmt.allocPrint(b.allocator, "llvm-{s}", .{base}) catch @panic("OOM");
    _ = addScriptTest(ctx, llvm_name, llvmDesc, buildArgv(b, interpreter, scriptPath, "llvm", extraArgs));
}

fn buildArgv(
    b: *std.Build,
    interpreter: []const u8,
    scriptPath: []const u8,
    backend: []const u8,
    extraArgs: []const []const u8,
) []const []const u8 {
    var list = std.ArrayList([]const u8).init(b.allocator);
    list.append(interpreter) catch @panic("OOM");
    list.append(scriptPath) catch @panic("OOM");
    list.append("zig-out/bin/mcc") catch @panic("OOM");
    list.append(backend) catch @panic("OOM");
    for (extraArgs) |a| list.append(a) catch @panic("OOM");
    return list.toOwnedSlice() catch @panic("OOM");
}
