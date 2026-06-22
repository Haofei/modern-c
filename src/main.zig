const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const fmt = @import("fmt.zig");
const hir = @import("hir.zig");
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");
const loader = @import("loader.zig");
const lower_c = @import("lower_c.zig");
// Lowering-coverage instrumentation (hardening V3.2). Zero-cost unless the
// `MC_LOWER_COV` env var is set; `tools/toolchain/lowering-coverage.sh` injects the
// per-function `lower_cov.hit(...)` probes into the two backend files at build time.
const lower_cov = @import("lower_cov.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const spec_tests = @import("spec_tests.zig");
const symbols = @import("symbols.zig");

// File-origin boundaries of the import-flattened source (loader.loadCombinedSourceWithBoundaries),
// set once per invocation in `run` and consumed by the semantic checker to enforce the orphan
// rule for `impl` blocks of `opaque struct`s (a peer `impl` in a different file may not name the
// type's private fields). Null when no module was loaded (e.g. `fmt`, which bypasses the loader).
var combined_boundaries: ?[]const loader.FileBoundary = null;

const usage =
    \\usage:
    \\  mcc lex <file.mc>
    \\  mcc check <file.mc>
    \\  mcc run-trap <file.mc>
    \\  mcc facts <file.mc>
    \\  mcc lower-hir <file.mc>
    \\  mcc verify-hir <file.mc>
    \\  mcc lower-mir <file.mc> [--checks=all|elide-proven]
    \\  mcc verify <file.mc> [--checks=all|elide-proven]
    \\  mcc lower-ir <file.mc>
    \\  mcc lower-c <file.mc>
    \\  mcc emit-c <file.mc> [--profile=kernel|hosted] [--checks=all|elide-proven] [--stub-asm]
    \\  mcc emit-map <file.mc> [--profile=kernel|hosted]
    \\  mcc emit-llvm <file.mc> [--checks=all|elide-proven] [--stub-asm]
    \\  mcc emit-layout <file.mc> --structs=A,B,C
    \\  mcc emit-c-struct <file.mc> --structs=A,B,C
    \\  mcc fmt <file.mc> [--check]
    \\  mcc symbols <file.mc>
    \\
    \\build-safety profile (orthogonal to the --profile target axis):
    \\  --checks=all           SAFE build (DEFAULT): keep every runtime trap check.
    \\  --checks=elide-proven  RELEASE build: elide ONLY the checks the fact-gated MIR
    \\                         optimizer (annex E.4) proved can never trap; all other
    \\                         checks are kept. Observable behavior is identical to
    \\                         --checks=all on every non-trapping program, since a
    \\                         proven-dead check could never have fired.
    \\  --optimize             deprecated alias for --checks=elide-proven.
    \\  --checks=ksan          KASAN profile (D2.1): instrument raw.load/raw.store with a
    \\                         shadow-memory check that traps on a poisoned (freed/redzone)
    \\                         access, catching use-after-free / out-of-bounds at ACCESS
    \\                         time. Composes: e.g. --checks=ksan,elide-proven.
    \\  --checks=msan          KMSAN profile (D2.2): builds on the ksan shadow to detect use
    \\                         of UNINITIALIZED heap memory. Implies ksan; additionally marks
    \\                         bytes initialized on raw.store (mc_ksan_store) so a raw.load of
    \\                         still-uninit heap bytes traps (KMSAN-DETECTED).
    \\  --checks=csan          KCSAN profile (D2.3): instrument the UNSYNCHRONIZED
    \\                         raw.load/raw.store path with a data-race watchpoint
    \\                         (mc_csan_read/mc_csan_write) on the shadow; a conflicting
    \\                         concurrent access (one a write) to the same location without
    \\                         synchronization traps (CSAN-DETECTED). The synchronized
    \\                         mc_race_* accessors stay plain atomics and are clean.
    \\
;

// Generated artifacts (lowered HIR/IR/C, facts, verification reports) go to
// stdout so they can be redirected with `>`; diagnostics and logs stay on stderr.
var stdout_io: std.Io = undefined;

fn writeStdout(bytes: []const u8) !void {
    std.Io.File.stdout().writeStreamingAll(stdout_io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    stdout_io = init.io;
    // Flush the lowering-coverage trace on every exit path (no-op unless armed via
    // the MC_LOWER_COV env var). Placed first so it covers all `try`/error returns.
    lower_cov.init(init.io, init.environ_map.get("MC_LOWER_COV"));
    defer lower_cov.dump();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse return failUsage();
    const path = args.next() orelse return failUsage();
    // Optional flags follow the path. `emit-c` and `emit-map` accept:
    // `--profile=kernel` (default) or `--profile=hosted` (the *target* axis).
    var profile: lower_c.Profile = .kernel;
    var saw_profile_flag = false;
    // Build-safety profile (orthogonal to the target `--profile`): `--checks=all` is the
    // SAFE default (keep every trap check); `--checks=elide-proven` is the RELEASE build
    // (the fact-gated MIR optimizer drops only provably-dead checks, annex E.4). `optimize`
    // is the single bool that selects RELEASE; `--optimize` is a deprecated alias.
    var optimize = false;
    // KASAN profile (D2.1): when set (`--checks=ksan`), instrumented memory accesses
    // (raw.load/raw.store — the pointer-deref / raw-access path) emit a shadow-memory
    // check that traps on a poisoned (freed/redzone) access. Orthogonal to `optimize`;
    // default builds leave it off, so no instrumentation hook is CALLED (the inert weak
    // stubs are always present, so the bytes differ from a no-hooks build).
    var ksan = false;
    // KMSAN profile (D2.2): when set (`--checks=msan`), builds on the ksan shadow to track
    // initialized-ness of heap bytes. It implies the ksan access instrumentation (so loads
    // still consult the shadow), and additionally wraps every raw.store with
    // `mc_ksan_store(addr, size)` which marks the written bytes initialized. The msan runtime
    // poisons fresh heap allocations as UNINIT; a load of still-uninit bytes traps. Default
    // builds leave it off, so no instrumentation hook is called (inert weak stubs persist).
    var msan = false;
    // KCSAN profile (D2.3): when set (`--checks=csan`), instruments the unsynchronized
    // raw.load/raw.store path with a data-race watchpoint (mc_csan_read/mc_csan_write) on the
    // shadow. Mutually exclusive with ksan/msan; default builds leave it off (no hook called).
    var csan = false;
    // True once any sanitizer profile token (ksan/msan/csan) is seen, so combination
    // validity can be checked once after parsing all `--checks=` tokens.
    var saw_checks_flag = false;
    var check_fmt = false;
    // `emit-layout --structs=A,B,C`: the comma-separated structs whose MC layout is asserted.
    var structs_flag: ?[]const u8 = null;
    // Arch-selection seam (R0b): `--arch=riscv64|x86_64|aarch64` picks which arch a
    // `import "kernel/arch/active/..."` resolves to. Null => loader default (riscv64), so the
    // existing riscv builds need no flag; only x86/aarch64 builds pass it.
    var arch_flag: ?[]const u8 = null;
    var saw_arch_flag = false;
    // Platform-selection seam (kernel-layering Wave 0): `--platform=qemu_virt` picks which
    // board a `import "kernel/platform/active/..."` resolves to. Null => loader default
    // (qemu_virt), so existing builds need no flag; only alternate boards pass it.
    var platform_flag: ?[]const u8 = null;
    var saw_platform_flag = false;
    // `--stub-asm` (test-only): lower inline asm to a host-neutral stub so an arch
    // module's portable logic can be built/run host-natively. Only the emit commands
    // accept it; kernel builds never pass it (so their asm is emitted unchanged).
    var stub_asm = false;
    var saw_stub_asm_flag = false;
    while (args.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "--arch=")) {
            saw_arch_flag = true;
            const value = flag["--arch=".len..];
            if (std.mem.eql(u8, value, "riscv64") or std.mem.eql(u8, value, "x86_64") or
                std.mem.eql(u8, value, "aarch64"))
            {
                arch_flag = value;
            } else {
                return failUsage();
            }
        } else if (std.mem.startsWith(u8, flag, "--platform=")) {
            saw_platform_flag = true;
            const value = flag["--platform=".len..];
            if (std.mem.eql(u8, value, "qemu_virt")) {
                platform_flag = value;
            } else {
                return failUsage();
            }
        } else if (std.mem.startsWith(u8, flag, "--structs=")) {
            structs_flag = flag["--structs=".len..];
        } else if (std.mem.startsWith(u8, flag, "--profile=")) {
            saw_profile_flag = true;
            const value = flag["--profile=".len..];
            if (std.mem.eql(u8, value, "kernel")) {
                profile = .kernel;
            } else if (std.mem.eql(u8, value, "hosted")) {
                profile = .hosted;
            } else {
                return failUsage();
            }
        } else if (std.mem.startsWith(u8, flag, "--checks=")) {
            saw_checks_flag = true;
            // Comma-separated tokens so the build-safety axis (`all`/`elide-proven`)
            // composes with the orthogonal `ksan` profile, e.g. `--checks=ksan` or
            // `--checks=ksan,elide-proven`. Default (no `ksan` token) leaves ksan off.
            const value = flag["--checks=".len..];
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |tok| {
                if (std.mem.eql(u8, tok, "all")) {
                    optimize = false;
                } else if (std.mem.eql(u8, tok, "elide-proven")) {
                    optimize = true;
                } else if (std.mem.eql(u8, tok, "ksan")) {
                    ksan = true;
                } else if (std.mem.eql(u8, tok, "msan")) {
                    // KMSAN (D2.2) builds on the ksan shadow and implies its instrumentation.
                    msan = true;
                    ksan = true;
                } else if (std.mem.eql(u8, tok, "csan")) {
                    // KCSAN (D2.3): data-race watchpoint on the unsynchronized raw path.
                    csan = true;
                } else {
                    return failUsage();
                }
            }
        } else if (std.mem.eql(u8, flag, "--optimize")) {
            // Deprecated alias for `--checks=elide-proven`.
            saw_checks_flag = true;
            optimize = true;
        } else if (std.mem.eql(u8, flag, "--check")) {
            check_fmt = true;
        } else if (std.mem.eql(u8, flag, "--stub-asm")) {
            saw_stub_asm_flag = true;
            stub_asm = true;
        } else {
            return failUsage();
        }
    }
    // `--profile` (target axis) is consumed only by the C artifact commands; `--checks=`
    // / `--optimize` (the build-safety axis: SAFE vs RELEASE, fact-gated MIR optimizer,
    // annex E) by the MIR-level and code-emitting commands; `--check` only by `fmt`. A
    // flag on any other command is an error.
    const is_c_artifact_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map");
    const accepts_checks = std.mem.eql(u8, command, "verify") or std.mem.eql(u8, command, "lower-mir") or
        std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-llvm");
    const is_emit_layout = std.mem.eql(u8, command, "emit-layout");
    const is_emit_c_struct = std.mem.eql(u8, command, "emit-c-struct");
    const needs_structs = is_emit_layout or is_emit_c_struct;
    if (saw_profile_flag and !is_c_artifact_command) return failUsage();
    if (saw_checks_flag and !accepts_checks) return failUsage();
    // `--stub-asm` only affects code emission, so it is meaningful solely on the two
    // emit commands. Reject it elsewhere rather than silently ignoring it.
    const is_emit_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-llvm");
    if (saw_stub_asm_flag and !is_emit_command) return failUsage();
    // `--arch` affects import resolution, so it is meaningful on any command that flattens
    // imports through the loader (the same set that accepts `--checks`, which are the compile
    // commands). Reject it elsewhere rather than silently ignoring it.
    if (saw_arch_flag and !accepts_checks) return failUsage();
    // `--platform` affects import resolution exactly like `--arch`, so it is meaningful only on
    // the import-flattening (compile) commands. Reject it elsewhere rather than silently ignoring.
    if (saw_platform_flag and !accepts_checks) return failUsage();
    // The sanitizer profiles are not all independently combinable: a single raw.load/
    // raw.store wraps exactly one shadow protocol. msan implies ksan (composable), but
    // csan is mutually exclusive with ksan/msan — `--checks=ksan,csan` (or `msan,csan`)
    // previously SILENTLY dropped csan (the C if-chain is exclusive; the LLVM path
    // ignored csan entirely). Reject the combination loudly instead of no-opping.
    if (csan and (ksan or msan)) {
        std.debug.print("error: --checks=csan cannot be combined with ksan/msan (a single raw access wraps one shadow protocol)\n", .{});
        return failUsage();
    }
    // Bundle the build-safety / sanitizer axis into one value (see backend.Checks); this is
    // threaded as a unit so a positional drop (the original KCSAN-on-LLVM no-op) can't recur.
    const checks: backend.Checks = .{ .optimize = optimize, .ksan = ksan, .msan = msan, .csan = csan };
    if (check_fmt and !std.mem.eql(u8, command, "fmt")) return failUsage();
    // `--structs=` is consumed only by the struct-from-MC commands, which both require it.
    if (structs_flag != null and !needs_structs) return failUsage();
    if (needs_structs and structs_flag == null) return failUsage();

    const root_source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(root_source);

    // `fmt` operates on the raw file (not the import-flattened source) and is token-preserving;
    // it bypasses the parse/sema pipeline entirely.
    if (std.mem.eql(u8, command, "fmt")) {
        try runFmt(allocator, path, root_source, check_fmt);
        return;
    }

    // Resolve `import "path";` declarations by textual inclusion (section 22 /
    // module system). With no imports this is the original source plus a
    // trailing newline, so single-file behavior is unchanged.
    var boundaries: std.ArrayList(loader.FileBoundary) = .empty;
    defer {
        for (boundaries.items) |b| allocator.free(b.path);
        boundaries.deinit(allocator);
    }
    const source = try loader.loadCombinedSourceWithBoundaries(allocator, init.io, path, root_source, &boundaries, arch_flag, platform_flag);
    defer allocator.free(source);
    combined_boundaries = boundaries.items;
    defer combined_boundaries = null;

    if (std.mem.eql(u8, command, "lex")) {
        try runLex(allocator, path, source);
    } else if (std.mem.eql(u8, command, "symbols")) {
        try runSymbols(allocator, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, path, source);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(allocator, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-hir")) {
        try runLowerHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "verify-hir")) {
        try runVerifyHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try runLowerMir(allocator, path, source, optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try runVerify(allocator, path, source, optimize);
    } else if (std.mem.eql(u8, command, "lower-ir")) {
        try runLowerIr(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(allocator, path, source);
    } else if (std.mem.eql(u8, command, "emit-c")) {
        try runEmitC(allocator, path, source, profile, checks, stub_asm);
    } else if (std.mem.eql(u8, command, "emit-map")) {
        try runEmitMap(allocator, path, source, profile);
    } else if (std.mem.eql(u8, command, "emit-llvm")) {
        try runEmitLlvm(allocator, path, source, checks, stub_asm);
    } else if (std.mem.eql(u8, command, "list-tests")) {
        try runListTests(allocator, path, source);
    } else if (is_emit_layout) {
        try runEmitLayout(allocator, path, source, structs_flag.?);
    } else if (is_emit_c_struct) {
        try runEmitCStruct(allocator, path, source, structs_flag.?);
    } else {
        return failUsage();
    }
}

fn runLowerHir(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendDump(allocator, module, &output);
    try writeStdout(output.items);
}

fn runVerifyHir(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.VerifyHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendVerificationFacts(allocator, module, &output);
    try writeStdout(output.items);
}

fn runLowerMir(allocator: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerMirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try mir.appendDumpOpt(allocator, module, &output, .{ .optimize = optimize });
    try writeStdout(output.items);
}

fn runVerify(allocator: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }
}

fn failUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgs;
}

// `mcc fmt <file>` prints the canonically-formatted source to stdout. `mcc fmt --check <file>`
// prints nothing and exits nonzero if the file is not already formatted (for CI / editors).
fn runFmt(allocator: std.mem.Allocator, path: []const u8, source: []const u8, check: bool) !void {
    const formatted = try fmt.format(allocator, source);
    defer allocator.free(formatted);
    if (check) {
        if (!std.mem.eql(u8, formatted, source)) {
            std.debug.print("{s}: not formatted (run `mcc fmt` to fix)\n", .{path});
            return error.FmtCheckFailed;
        }
        return;
    }
    try writeStdout(formatted);
}

// `mcc symbols <file>` prints a JSON symbol index (defs + refs with spans) for the language
// server. Best-effort: it needs only a parse (not sema), and on a hard parse failure it still
// prints a valid empty index so the client always gets parseable JSON.
fn runSymbols(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = parseModuleOrReport(source, parse_allocator, &diag) catch {
        try writeStdout("{\"defs\":[],\"refs\":[]}\n");
        return;
    };
    defer module.deinit(parse_allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try symbols.emitJson(allocator, module, &output);
    try writeStdout(output.items);
}

fn runLex(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var lx = lexer.Lexer.init(source, &diag);
    while (true) {
        const tok = lx.next();
        std.debug.print("{s}:{d}:{d}: {s}", .{
            path,
            tok.span.line,
            tok.span.column,
            @tagName(tok.kind),
        });
        if (tok.lexeme.len != 0) {
            std.debug.print(" `{s}`", .{tok.lexeme});
        }
        std.debug.print("\n", .{});
        if (tok.kind == .eof) break;
    }

    if (diag.has_errors) {
        diag.render();
        return error.LexFailed;
    }
}

fn runCheck(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    std.debug.print("parsed {d} top-level declarations\n", .{module.decls.len});
}

// `mcc list-tests <file>` prints, one per line, the name of every `#[test]`-attributed
// function in the file. A test is an ordinary `fn name() -> u32 { ...; return 1; }`
// whose `assert(...)`s trap on failure; the harness (tools/test/mc-test-runner.sh) runs
// each in its own process (a trap => fail) and reports pass/fail per name. This is the
// language-side discovery hook — no codegen change, so a `#[test]` function lowers like
// any other on both backends.
fn runListTests(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (module.decls) |decl| {
        var is_test = false;
        for (decl.attrs) |attr| {
            switch (attr.kind) {
                .named => |n| if (std.mem.eql(u8, n.text, "test")) {
                    is_test = true;
                },
                else => {},
            }
        }
        if (!is_test) continue;
        const name = switch (decl.kind) {
            .fn_decl => |fd| fd.name.text,
            else => continue,
        };
        try out.appendSlice(allocator, name);
        try out.append(allocator, '\n');
    }
    try writeStdout(out.items);
}

fn runFacts(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.FactsFailed;
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(allocator);
    try ir.appendFacts(allocator, module, &facts);
    try writeStdout(facts.items);
}

fn runLowerIr(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerIrFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try ir.appendLowerIr(allocator, module, &output);
    try writeStdout(output.items);
}

fn runTrap(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.RunTrapFailed;
    }

    var expectations = try eval.parseRunTrapExpectations(allocator, source);
    defer eval.freeRunTrapExpectations(allocator, &expectations);
    if (expectations.items.len == 0) {
        std.debug.print("{s}: no inline run trap expectations found\n", .{path});
        return error.RunTrapFailed;
    }

    for (expectations.items) |expectation| {
        const actual = try eval.runTrapExpectation(allocator, module, expectation.function_name, expectation.args);
        if (actual == null or actual.? != expectation.trap) {
            std.debug.print(
                "{s}:{d}: expected run {s}(...) to trap .{s}, got {s}\n",
                .{ path, expectation.line, expectation.function_name, @tagName(expectation.trap), if (actual) |trap| @tagName(trap) else "no trap" },
            );
            return error.RunTrapFailed;
        }
        std.debug.print(
            "run_trap fn={s} trap={s} reached=true line={d}\n",
            .{ expectation.function_name, @tagName(expectation.trap), expectation.line },
        );
    }
}

fn runLowerC(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerCFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try lower_c.appendInspection(allocator, module, &output);
    try writeStdout(output.items);
}

fn runEmitC(allocator: std.mem.Allocator, path: []const u8, source: []const u8, profile: lower_c.Profile, checks: backend.Checks, stub_asm: bool) !void {
    const optimize = checks.optimize;
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    const be = backend.byName("c").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.lower(allocator, module, &output, .{ .profile = profile, .source_path = path, .checks = checks, .stub_asm = stub_asm });
    try writeStdout(output.items);
}

fn runEmitMap(allocator: std.mem.Allocator, path: []const u8, source: []const u8, profile: lower_c.Profile) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    try mir.verify(allocator, module, &diag);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    const be = backend.byName("c").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.emitMap(allocator, module, &output, profile, path);
    try writeStdout(output.items);
}

fn runEmitLlvm(allocator: std.mem.Allocator, path: []const u8, source: []const u8, checks: backend.Checks, stub_asm: bool) !void {
    const optimize = checks.optimize;
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    const be = backend.byName("llvm").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.lower(allocator, module, &output, .{ .profile = .kernel, .source_path = path, .checks = checks, .stub_asm = stub_asm });
    try writeStdout(output.items);
}

// `emit-layout`: emit a generated C header asserting MC's authoritative layout (sizeof + each
// field offset) for the comma-separated structs in `--structs=`. A C runtime that hand-mirrors
// one of these structs includes the header, so any MC↔C layout drift becomes a compile error.
fn runEmitLayout(allocator: std.mem.Allocator, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitLayoutFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitLayoutFailed;
    }

    // Split `A,B,C` into struct names (arena-allocated so they outlive the loop).
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, structs_csv, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try names.append(allocator, name);
    }
    if (names.items.len == 0) return failUsage();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    lower_c.appendLayoutAsserts(allocator, module, &output, names.items) catch |err| switch (err) {
        error.LayoutStructNotFound => {
            std.debug.print("emit-layout: a struct named in --structs= was not found in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        error.LayoutUnresolved => {
            std.debug.print("emit-layout: could not resolve a struct's layout in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        else => return err,
    };
    try writeStdout(output.items);
}

// `emit-c-struct` (hardening A2): emit a generated C header with the FULL struct *definitions* for
// the comma-separated structs in `--structs=` — the actual `typedef struct { ... }` matching MC's
// field order/types/layout, plus the by-value array/struct wrappers they embed, plus the A1
// `_Static_assert`s as a cross-check. A C runtime includes this header and drops its hand-written
// mirror, so the MC struct becomes the single source of truth and MC↔C drift is impossible (there
// is no second declaration to diverge).
fn runEmitCStruct(allocator: std.mem.Allocator, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitCStructFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCStructFailed;
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, structs_csv, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try names.append(allocator, name);
    }
    if (names.items.len == 0) return failUsage();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    lower_c.appendStructDecls(allocator, module, &output, names.items) catch |err| switch (err) {
        error.LayoutStructNotFound => {
            std.debug.print("emit-c-struct: a struct named in --structs= was not found in {s}\n", .{path});
            return error.EmitCStructFailed;
        },
        error.LayoutUnresolved => {
            std.debug.print("emit-c-struct: could not resolve a struct's layout in {s}\n", .{path});
            return error.EmitCStructFailed;
        },
        else => return err,
    };
    try writeStdout(output.items);
}

fn parseModuleOrReport(source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, diag);
    const module = p.parseModule(allocator) catch |err| {
        diag.render();
        return err;
    };
    // Specialize comptime-parameter type-generic functions (section 22). This is
    // a no-op for modules without any such function, so non-generic code is
    // passed through untouched.
    return monomorphize.transformReport(allocator, module, diag) catch |err| {
        diag.render();
        return err;
    };
}

test {
    _ = diagnostics;
    _ = eval;
    _ = ast;
    _ = backend;
    _ = hir;
    _ = ir;
    _ = lexer;
    _ = loader;
    _ = lower_c;
    _ = lower_llvm;
    _ = mir;
    _ = monomorphize;
    _ = parser;
    _ = sema;
    _ = spec_tests;
}
