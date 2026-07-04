const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const diagnostics = @import("diagnostics.zig");
const diagnostic_explain = @import("diagnostic_explain.zig");
const eval = @import("eval.zig");
const eval_tests = @import("eval_tests.zig");
const fmt = @import("fmt.zig");
const generic_precheck = @import("generic_precheck.zig");
const hir = @import("hir.zig");
const hir_tests = @import("hir_tests.zig");
const ir = @import("ir.zig");
const ir_tests = @import("ir_tests.zig");
const lexer = @import("lexer.zig");
const lexer_tests = @import("lexer_tests.zig");
const loader = @import("loader.zig");
const lower_c = @import("lower_c.zig");
const lower_c_tests = @import("lower_c_tests.zig");
// Lowering-coverage instrumentation (hardening V3.2). Zero-cost unless the
// `MC_LOWER_COV` env var is set; `tools/toolchain/lowering-coverage.sh` injects
// per-function `lower_cov.hit(...)` probes into split lower_c*/lower_llvm* modules
// in an isolated temporary checkout before building the instrumented compiler.
const lower_cov = @import("lower_cov.zig");
const lower_llvm = @import("lower_llvm.zig");
const lower_llvm_tests = @import("lower_llvm_tests.zig");
const mir = @import("mir.zig");
const mir_tests = @import("mir_tests.zig");
const monomorphize = @import("monomorphize.zig");
const monomorphize_tests = @import("monomorphize_tests.zig");
const async_lower = @import("async_lower.zig");
const mangle_private = @import("mangle_private.zig");
const parser = @import("parser.zig");
const parser_tests = @import("parser_tests.zig");
const sema = @import("sema.zig");
const sema_tests = @import("sema_tests.zig");
const spec_tests = @import("spec_tests.zig");
const symbols = @import("symbols.zig");

// File-origin boundaries of the import-flattened source (loader.loadCombinedSourceWithBoundaries),
// set once per invocation in `run` and consumed by the semantic checker to enforce the orphan
// rule for `impl` blocks of `opaque struct`s (a peer `impl` in a different file may not name the
// type's private fields). Null when no module was loaded (e.g. `fmt`, which bypasses the loader).
var combined_boundaries: ?[]const loader.FileBoundary = null;

const usage =
    \\usage:
    \\  mcc --help
    \\  mcc --version
    \\  mcc help
    \\  mcc explain E_CODE
    \\  mcc lex <file.mc>
    \\  mcc check <file.mc> [--json]
    \\  mcc run-trap <file.mc>
    \\  mcc facts <file.mc>
    \\  mcc lower-hir <file.mc>
    \\  mcc verify-hir <file.mc>
    \\  mcc lower-mir <file.mc> [--checks=all|elide-proven]
    \\  mcc verify <file.mc> [--checks=all|elide-proven]
    \\  mcc lower-ir <file.mc>
    \\  mcc lower-c <file.mc>
    \\  mcc emit-c <file.mc> [-o <out.c>] [--profile=kernel|hosted] [--checks=all|elide-proven] [--stub-asm] [--remap-prefix=FROM=TO]
    \\  mcc build <file.mc> -o <exe>
    \\  mcc emit-map <file.mc> [-o <out.mcmap>] [--profile=kernel|hosted] [--remap-prefix=FROM=TO]
    \\  mcc emit-llvm <file.mc> [-o <out.ll>] [--checks=all|elide-proven] [--stub-asm]
    \\  mcc emit-layout <file.mc> --structs=A,B,C
    \\  mcc emit-c-struct <file.mc> --structs=A,B,C
    \\  mcc fmt <file.mc> [--check]
    \\  mcc symbols <file.mc>
    \\  mcc list-tests <file.mc>
    \\
    \\input:
    \\  Use <file.mc> for normal file input, or - to read MC source from stdin.
    \\
    \\import fallback for installed layouts (source-loading commands only):
    \\  --std-dir=<dir>       after project-root search misses, resolve import "std/x.mc"
    \\                         as <dir>/x.mc.
    \\  MC_PATH=dir[:dir...]  after --std-dir misses, search entries left-to-right as
    \\                         import roots. For import "std/x.mc", an entry named std
    \\                         maps to <entry>/x.mc; otherwise to <entry>/std/x.mc.
    \\
    \\source artifact reproducibility (emit-c and emit-map only):
    \\  --remap-prefix=FROM=TO replace a matching source path prefix in emitted C
    \\                         #line directives and emit-map source_path metadata.
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
    \\machine-readable diagnostics:
    \\  mcc check <file.mc> --json
    \\                         print {"diagnostics":[...]} JSON to stdout. Text diagnostics
    \\                         remain the default and stay on stderr.
    \\  mcc explain E_CODE     print the embedded diagnostic reference entry for a code.
    \\
    \\exit codes:
    \\  0   success, --help, --version
    \\  1   expected user-facing failure after diagnostics/usage
    \\  >1  unexpected compiler/runtime failure
    \\
;

// Generated artifacts (lowered HIR/IR/C, facts, verification reports) go to
// stdout unless a command-specific output path is provided; diagnostics and logs
// stay on stderr.
var stdout_io: std.Io = undefined;
const max_input_bytes = 64 * 1024 * 1024;

fn writeStdout(bytes: []const u8) !void {
    std.Io.File.stdout().writeStreamingAll(stdout_io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

fn writeOutputPath(path: []const u8, bytes: []const u8) !void {
    const file = std.Io.Dir.cwd().createFile(stdout_io, path, .{ .truncate = true }) catch |err| {
        std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
        return error.OutputWriteFailed;
    };
    defer file.close(stdout_io);
    file.writeStreamingAll(stdout_io, bytes) catch |err| {
        std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
        return error.OutputWriteFailed;
    };
}

fn writeArtifact(bytes: []const u8, output_path: ?[]const u8) !void {
    if (output_path) |path| return writeOutputPath(path, bytes);
    return writeStdout(bytes);
}

fn readStdinAlloc(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var stdin_reader: std.Io.File.Reader = .initStreaming(std.Io.File.stdin(), io, &.{});
    return stdin_reader.interface.allocRemaining(allocator, .limited(max_input_bytes)) catch |err| switch (err) {
        error.ReadFailed => {
            if (stdin_reader.err) |read_err| return read_err;
            return error.ReadFailed;
        },
        else => |e| return e,
    };
}

fn readRootSource(io: std.Io, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.eql(u8, path, "-")) return readStdinAlloc(io, allocator);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_input_bytes));
}

fn stdinLoaderRootPath(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    return std.fs.path.join(allocator, &.{ cwd_buffer[0..cwd_len], "-" });
}

pub fn main(init: std.process.Init) !void {
    runMain(init) catch |err| {
        if (isExpectedCliFailure(err)) std.process.exit(1);
        return err;
    };
}

fn runMain(init: std.process.Init) !void {
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
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        if (args.next() != null) return failUsage();
        try writeStdout(usage);
        return;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        if (args.next() != null) return failUsage();
        try writeStdout("mcc " ++ build_options.version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, command, "explain")) {
        const code = args.next() orelse return failUsage();
        if (args.next() != null) return failUsage();
        try runExplain(allocator, code);
        return;
    }
    const path = args.next() orelse return failUsage();
    const options = cli.Options.parse(command, &args) catch |err| switch (err) {
        error.InvalidArgs => return failUsage(),
    };
    const is_emit_layout = cli.Options.isEmitLayout(command);
    const is_emit_c_struct = cli.Options.isEmitCStruct(command);
    const reads_stdin = std.mem.eql(u8, path, "-");
    const loader_root_path = if (reads_stdin) stdinLoaderRootPath(init.io, allocator) catch |err| {
        std.debug.print("error: unable to read input \"{s}\": {s}\n", .{ path, @errorName(err) });
        return error.InputReadFailed;
    } else path;
    defer if (reads_stdin) allocator.free(loader_root_path);

    const root_source = readRootSource(init.io, path, allocator) catch |err| {
        std.debug.print("error: unable to read input \"{s}\": {s}\n", .{ path, @errorName(err) });
        return error.InputReadFailed;
    };
    defer allocator.free(root_source);

    // `fmt` operates on the raw file (not the import-flattened source) and is token-preserving;
    // it bypasses the parse/sema pipeline entirely.
    if (std.mem.eql(u8, command, "fmt")) {
        try runFmt(allocator, path, root_source, options.check_fmt);
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
    var load_diag = diagnostics.Reporter.init(allocator, path, root_source);
    defer load_diag.deinit();
    var mc_path_entries: std.ArrayList([]const u8) = .empty;
    defer mc_path_entries.deinit(allocator);
    if (init.environ_map.get("MC_PATH")) |mc_path| {
        var entries = std.mem.splitScalar(u8, mc_path, std.fs.path.delimiter);
        while (entries.next()) |entry| {
            if (entry.len != 0) try mc_path_entries.append(allocator, entry);
        }
    }
    const source = try loader.loadCombinedSourceWithBoundariesOptionsReport(allocator, init.io, loader_root_path, root_source, &boundaries, .{
        .arch = options.arch_flag,
        .platform = options.platform_flag,
        .std_dir = options.std_dir,
        .mc_path = mc_path_entries.items,
    }, &load_diag);
    defer allocator.free(source);
    if (reads_stdin and boundaries.items.len > 0) {
        allocator.free(boundaries.items[0].path);
        boundaries.items[0].path = try allocator.dupe(u8, path);
    }
    load_diag.source = source;
    load_diag.file_boundaries = boundaries.items;
    if (load_diag.has_errors) {
        if (std.mem.eql(u8, command, "check") and options.json_diagnostics) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try load_diag.appendJson(&out);
            try writeStdout(out.items);
        } else {
            load_diag.render();
        }
        return error.ImportNotFound;
    }
    combined_boundaries = boundaries.items;
    defer combined_boundaries = null;

    if (std.mem.eql(u8, command, "lex")) {
        try runLex(allocator, path, source);
    } else if (std.mem.eql(u8, command, "symbols")) {
        try runSymbols(allocator, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, path, source, options.json_diagnostics);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(allocator, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-hir")) {
        try runLowerHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "verify-hir")) {
        try runVerifyHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try runLowerMir(allocator, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try runVerify(allocator, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "lower-ir")) {
        try runLowerIr(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(allocator, path, source);
    } else if (std.mem.eql(u8, command, "emit-c")) {
        const remapped_source_path = try options.remappedSourcePath(allocator, path);
        defer if (remapped_source_path) |p| allocator.free(p);
        try runEmitC(allocator, path, remapped_source_path orelse path, source, options.profile, options.checks, options.stub_asm, options.output_path);
    } else if (std.mem.eql(u8, command, "emit-map")) {
        const remapped_source_path = try options.remappedSourcePath(allocator, path);
        defer if (remapped_source_path) |p| allocator.free(p);
        try runEmitMap(allocator, path, remapped_source_path orelse path, source, options.profile, options.output_path);
    } else if (std.mem.eql(u8, command, "emit-llvm")) {
        try runEmitLlvm(allocator, path, source, options.checks, options.stub_asm, options.targetArch(), options.output_path);
    } else if (std.mem.eql(u8, command, "list-tests")) {
        try runListTests(allocator, path, source);
    } else if (is_emit_layout) {
        try runEmitLayout(allocator, path, source, options.structs_flag.?);
    } else if (is_emit_c_struct) {
        try runEmitCStruct(allocator, path, source, options.structs_flag.?);
    } else {
        return failUsage();
    }
}

fn isExpectedCliFailure(err: anyerror) bool {
    return switch (err) {
        error.InvalidArgs,
        error.ExplainFailed,
        error.InputReadFailed,
        error.ImportNotFound,
        error.FmtCheckFailed,
        error.LexFailed,
        error.ParseFailed,
        error.AsyncLowerFailed,
        error.CheckFailed,
        error.FactsFailed,
        error.LowerHirFailed,
        error.VerifyHirFailed,
        error.LowerMirFailed,
        error.VerifyFailed,
        error.LowerIrFailed,
        error.RunTrapFailed,
        error.LowerCFailed,
        error.EmitCFailed,
        error.EmitLlvmFailed,
        error.EmitLayoutFailed,
        error.EmitCStructFailed,
        error.OutputWriteFailed,
        => true,
        else => false,
    };
}

fn runExplain(allocator: std.mem.Allocator, code: []const u8) !void {
    const text = try diagnostic_explain.explain(allocator, code) orelse {
        std.debug.print("error: unknown diagnostic code: {s}\n", .{code});
        return error.ExplainFailed;
    };
    defer allocator.free(text);
    try writeStdout(text);
}

fn runLowerHir(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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

fn initReporter(allocator: std.mem.Allocator, path: []const u8, source: []const u8) diagnostics.Reporter {
    var reporter = diagnostics.Reporter.init(allocator, path, source);
    reporter.file_boundaries = combined_boundaries;
    return reporter;
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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

fn runCheck(allocator: std.mem.Allocator, path: []const u8, source: []const u8, json_diagnostics: bool) !void {
    var diag = initReporter(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = parseModuleOrReportMode(source, parse_allocator, &diag, false) catch |err| {
        if (diag.has_errors) {
            try emitCheckDiagnostics(allocator, &diag, json_diagnostics);
        }
        return err;
    };
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        try emitCheckDiagnostics(allocator, &diag, json_diagnostics);
        return error.CheckFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.file_boundaries = combined_boundaries;
    checker.checkModule(module);
    if (diag.has_errors) {
        try emitCheckDiagnostics(allocator, &diag, json_diagnostics);
        return error.CheckFailed;
    }

    if (json_diagnostics) {
        try emitCheckDiagnostics(allocator, &diag, true);
    } else {
        std.debug.print("parsed {d} top-level declarations\n", .{module.decls.len});
    }
}

fn emitCheckDiagnostics(allocator: std.mem.Allocator, diag: *diagnostics.Reporter, json_diagnostics: bool) !void {
    if (!json_diagnostics) {
        diag.render();
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try diag.appendJson(&out);
    try writeStdout(out.items);
}

// `mcc list-tests <file>` prints, one per line, the name of every `#[test]`-attributed
// function in the file. A test is an ordinary `fn name() -> u32 { ...; return 1; }`
// whose `assert(...)`s trap on failure; the harness (tools/test/mc-test-runner.sh) runs
// each in its own process (a trap => fail) and reports pass/fail per name. This is the
// language-side discovery hook — no codegen change, so a `#[test]` function lowers like
// any other on both backends.
fn runListTests(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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

fn runEmitC(allocator: std.mem.Allocator, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: lower_c.Profile, checks: backend.Checks, stub_asm: bool, output_path: ?[]const u8) !void {
    const optimize = checks.optimize;
    var diag = initReporter(allocator, path, source);
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

    var module_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &diag);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    lower_c.appendCProfileWithMir(allocator, module, &module_mir, &output, profile, artifact_source_path, checks, stub_asm, &diag) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };
    try writeArtifact(output.items, output_path);
}

fn runEmitMap(allocator: std.mem.Allocator, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: lower_c.Profile, output_path: ?[]const u8) !void {
    var diag = initReporter(allocator, path, source);
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
    try be.emitMap(allocator, module, &output, profile, artifact_source_path);
    try writeArtifact(output.items, output_path);
}

fn runEmitLlvm(allocator: std.mem.Allocator, path: []const u8, source: []const u8, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const optimize = checks.optimize;
    var diag = initReporter(allocator, path, source);
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

    var module_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &diag);
    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    lower_llvm.appendLlvmCheckedMir(allocator, module, &module_mir, &output, path, checks, stub_asm, target_arch, &diag) catch |err| switch (err) {
        error.UnsupportedLlvmEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "LLVM");
            diag.render();
            return error.EmitLlvmFailed;
        },
        else => return err,
    };
    try writeArtifact(output.items, output_path);
}

fn reportBackendUnsupportedFallback(diag: *diagnostics.Reporter, module: ast.Module, backend_name: []const u8) void {
    diag.err(backendUnsupportedFallbackSpan(module), "E_BACKEND_UNSUPPORTED: {s} backend does not yet support this construct", .{backend_name});
}

fn backendUnsupportedFallbackSpan(module: ast.Module) ast.Span {
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (fn_decl.body) |body| {
                    if (body.items.len > 0) return body.items[0].span;
                    return fn_decl.name.span;
                }
            },
            .global_decl => |global| if (global.init) |init| return init.span else return global.name.span,
            else => {},
        }
    }
    if (module.decls.len > 0) return module.decls[0].span;
    return .{ .offset = 0, .len = 1, .line = 1, .column = 1 };
}

// `emit-layout`: emit a generated C header asserting MC's authoritative layout (sizeof + each
// field offset) for the comma-separated structs in `--structs=`. A C runtime that hand-mirrors
// one of these structs includes the header, so any MC↔C layout drift becomes a compile error.
fn runEmitLayout(allocator: std.mem.Allocator, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    var diag = initReporter(allocator, path, source);
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
    var diag = initReporter(allocator, path, source);
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
    return parseModuleOrReportMode(source, allocator, diag, true);
}

fn parseModuleOrReportMode(source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module {
    var p = parser.Parser.init(source, diag);
    const module = p.parseModule(allocator) catch |err| {
        if (render_errors) diag.render();
        return err;
    };
    // Lower `async fn` / `await` to stackless Future state machines BEFORE monomorphize/sema, so
    // the move/borrow checker and both backends only ever see ordinary MC. No-op for modules
    // without any `async fn` (passes the module through untouched).
    const lowered = async_lower.transform(allocator, module, diag) catch |err| {
        if (render_errors) diag.render();
        return err;
    };
    try generic_precheck.check(allocator, lowered, diag, combined_boundaries);
    if (diag.has_errors) {
        if (render_errors) diag.render();
        return error.CheckFailed;
    }
    // Specialize comptime-parameter type-generic functions (section 22). This is
    // a no-op for modules without any such function, so non-generic code is
    // passed through untouched.
    const specialized = monomorphize.transformReport(allocator, lowered, diag) catch |err| {
        if (render_errors) diag.render();
        return err;
    };
    // G22: uniquify file-private top-level names that collide across imported files (§30).
    // No-op unless two strict files each define a file-private value of the same name; keeps
    // the flat namespace for every non-colliding `pub`/`export` name.
    return mangle_private.transform(allocator, specialized, combined_boundaries) catch |err| {
        if (render_errors) diag.render();
        return err;
    };
}

test {
    _ = diagnostics;
    _ = eval;
    _ = eval_tests;
    _ = ast;
    _ = backend;
    _ = generic_precheck;
    _ = hir;
    _ = hir_tests;
    _ = ir;
    _ = ir_tests;
    _ = lexer;
    _ = lexer_tests;
    _ = loader;
    _ = lower_c;
    _ = lower_c_tests;
    _ = lower_llvm;
    _ = lower_llvm_tests;
    _ = mir;
    _ = mir_tests;
    _ = monomorphize;
    _ = monomorphize_tests;
    _ = async_lower;
    _ = parser;
    _ = parser_tests;
    _ = sema;
    _ = sema_tests;
    _ = spec_tests;
}
