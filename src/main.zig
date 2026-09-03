const std = @import("std");

const artifact_model = @import("artifact_model.zig");
const ast = @import("ast.zig");
const backend = @import("backend.zig");
const backend_registry = @import("backend_registry.zig");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const compiler_session = @import("compiler_session.zig");
const diagnostics = @import("diagnostics.zig");
const diagnostic_explain = @import("diagnostic_explain.zig");
const driver_codegen_inputs = @import("driver_codegen_inputs.zig");
const eval = @import("eval.zig");
const fmt = @import("fmt.zig");
const hir = @import("hir_inspection.zig");
const ir = @import("ir_inspection.zig");
const lexer = @import("lexer.zig");
const loader = @import("loader.zig");
const lower_c = @import("lower_c.zig");
// Lowering-coverage instrumentation (hardening V3.2). Zero-cost unless the
// `MC_LOWER_COV` env var is set; `tools/toolchain/lowering-coverage.sh` injects
// per-function `lower_cov.hit(...)` probes into split lower_c*/lower_llvm* modules
// in an isolated temporary checkout before building the instrumented compiler.
const lower_cov = @import("lower_cov.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const module_parser = @import("module_parser.zig");
const symbols = @import("symbols.zig");

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
    \\  mcc inspect-hir <file.mc>
    \\  mcc verify-inspect-hir <file.mc>
    \\  mcc lower-mir <file.mc> [--checks=all|elide-proven]
    \\  mcc verify <file.mc> [--checks=all|elide-proven]
    \\  mcc inspect-ir <file.mc>
    \\  mcc lower-c <file.mc>
    \\  mcc emit-c <file.mc> [-o <out.c>] [--profile=kernel|hosted] [--checks=all|elide-proven] [--stub-asm] [--remap-prefix=FROM=TO]
    \\  mcc build <file.mc> -o <exe> [--remap-prefix=FROM=TO]
    \\  mcc emit-map <file.mc> [-o <out.mcmap>] [--profile=kernel|hosted] [--checks=all|elide-proven] [--stub-asm] [--remap-prefix=FROM=TO]
    \\  mcc emit-llvm <file.mc> [-o <out.ll>] [--checks=all|elide-proven] [--stub-asm] [--linux-kernel] [--remap-prefix=FROM=TO]
    \\  mcc emit-layout <file.mc> --structs=A,B,C
    \\  mcc emit-c-struct <file.mc> --structs=A,B,C
    \\  mcc fmt <file.mc> [--check]
    \\  mcc symbols <file.mc>
    \\  mcc list-tests <file.mc>
    \\
    \\Inspection commands are not backend pipeline inputs; MIR verification remains the backend semantic boundary.
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
    \\  --visibility=legacy|explicit
    \\                         legacy keeps per-file `pub` opt-in visibility; explicit
    \\                         makes every file private-by-default except `pub`/`export`.
    \\
    \\source artifact reproducibility (artifact commands only):
    \\  --remap-prefix=FROM=TO replace a matching source path prefix in emitted C
    \\                         #line directives, LLVM debug paths, and metadata.
    \\                         Without an explicit remap, absolute source paths are
    \\                         redacted to deterministic /src/... artifact paths.
    \\  -o artifacts            emit-c, emit-llvm, and build also write a sibling
    \\                         <output>.mcmeta sidecar with artifact/source/options
    \\                         provenance; C artifacts also bind source-map and
    \\                         MIR-fact digests. emit-map embeds the same metadata
    \\                         in the .mcmap header.
    \\
    \\build-safety profile (orthogonal to the --profile target axis):
    \\  --checks=all           checks=all (default): keep every runtime trap check.
    \\  --checks=elide-proven  checks=elide-proven: elide ONLY the checks the fact-gated MIR
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
    \\  --linux-kernel         LLVM IR profile with external runtime hooks, nounwind
    \\                         functions, and x86 IBT/rethunk metadata.
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

const max_input_bytes = 64 * 1024 * 1024;
const CompilationSession = compiler_session.CompilationSession;
const CompilationStageFailure = compiler_session.StageFailure;
const max_artifact_metadata_bytes = compiler_session.max_artifact_metadata_bytes;

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

fn artifactSourcePath(allocator: std.mem.Allocator, io: std.Io, options: cli.Options, path: []const u8) !?[]const u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = if (std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer)) |cwd_len|
        cwd_buffer[0..cwd_len]
    else |_|
        null;
    return options.artifactSourcePath(allocator, path, cwd);
}

pub fn main(init: std.process.Init) !void {
    runMain(init) catch |err| {
        if (isExpectedCliFailure(err)) std.process.exit(1);
        return err;
    };
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    var session = CompilationSession.init(allocator, init.io);
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
        try session.writeStdout(usage);
        return;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        if (args.next() != null) return failUsage();
        try session.writeStdout("mcc " ++ build_options.version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, command, "explain")) {
        const code = args.next() orelse return failUsage();
        if (args.next() != null) return failUsage();
        try runExplain(&session, code);
        return;
    }
    const path = args.next() orelse return failUsage();
    const options = cli.Options.parse(command, &args) catch |err| switch (err) {
        error.InvalidArgs => return failUsage(),
    };
    if (!std.mem.eql(u8, command, "fmt") and !cli.Options.isSourceLoadingCommand(command)) return failUsage();
    session.visibility_mode = options.visibility_mode;
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

    // `fmt` operates on the raw root file and is token-preserving;
    // it bypasses the parse/sema pipeline entirely.
    if (std.mem.eql(u8, command, "fmt")) {
        try runFmt(&session, path, root_source, options.check_fmt);
        return;
    }

    // Resolve imports into a per-file source database and module graph. The
    // compiler pipeline below parses those files independently; it does not
    // parse the loader's legacy diagnostic projection.
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
    var loaded = loader.loadProjectOptionsReport(allocator, init.io, loader_root_path, root_source, .{
        .arch = options.arch_flag,
        .std_dir = options.std_dir,
        .mc_path = mc_path_entries.items,
    }, &load_diag) catch |err| switch (err) {
        error.Reported => {
            try emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
            return error.ImportNotFound;
        },
        else => return err,
    };
    defer loaded.deinit(allocator);
    if (reads_stdin and loaded.graph.files.len > 0) {
        allocator.free(loaded.graph.files[0].display_path);
        loaded.graph.files[0].display_path = try allocator.dupe(u8, path);
    }
    const diagnostic_sources = try loaded.source_db.diagnosticViews(allocator, loaded.graph);
    defer allocator.free(diagnostic_sources);
    const root_file_id = if (loaded.graph.files.len != 0) loaded.graph.files[0].id else return error.ImportNotFound;
    const source = loaded.source_db.parserSourceForFile(root_file_id) orelse return error.ImportNotFound;
    load_diag.source = source;
    load_diag.source_views = diagnostic_sources;
    if (load_diag.has_errors) {
        try emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
        return error.ImportNotFound;
    }
    session.source_views = diagnostic_sources;
    defer session.source_views = null;
    session.module_graph = &loaded.graph;
    defer session.module_graph = null;
    session.source_db = &loaded.source_db;
    defer session.source_db = null;
    session.project_source_digest = loaded.source_db.digest();
    defer session.project_source_digest = null;

    // Lexing is intentionally a root-file operation. It must not be blocked by
    // parse, generic, async or semantic errors in another module.
    if (std.mem.eql(u8, command, "lex")) {
        try runLex(&session, path, source);
        return;
    }
    var module_parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer module_parse_arena.deinit();
    var parsed_sources: module_parser.ParsedSourceDatabase = undefined;
    var resolved_sources: module_parser.ResolvedSourceDatabase = undefined;
    session.attachLoadedProjectSyntax(&loaded, module_parse_arena.allocator(), &load_diag, &parsed_sources, &resolved_sources) catch |err| {
        try emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
        return err;
    };
    defer session.resolved_sources = null;
    defer resolved_sources.deinit(module_parse_arena.allocator());
    defer parsed_sources.deinit(module_parse_arena.allocator());
    var resolved_program: module_parser.ResolvedProgram = undefined;
    var resolved_program_ready = false;
    defer if (resolved_program_ready) resolved_program.deinit(module_parse_arena.allocator());
    defer session.resolved_program = null;
    if (commandNeedsResolvedProgram(command)) {
        resolved_program = session.prepareResolvedProgram(module_parse_arena.allocator(), &load_diag) catch |err| {
            try emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
            return err;
        };
        resolved_program_ready = true;
        session.resolved_program = &resolved_program;
    }

    if (std.mem.eql(u8, command, "symbols")) {
        try runSymbols(&session, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(&session, path, source, options.json_diagnostics);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(&session, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(&session, path, source);
    } else if (std.mem.eql(u8, command, "inspect-hir")) {
        try runLowerHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "verify-inspect-hir")) {
        try runVerifyHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try runLowerMir(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try runVerify(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "inspect-ir")) {
        try runLowerIr(&session, path, source);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(&session, path, source);
    } else if (std.mem.eql(u8, command, "emit-c")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitC(&session, path, artifact_source_path orelse path, source, options.profile, options.checks, options.stub_asm, options.targetArch(), options.output_path);
    } else if (std.mem.eql(u8, command, "build")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runBuild(&session, path, artifact_source_path orelse path, source, options.targetArch(), options.output_path.?, init.environ_map.get("CLANG") orelse "clang");
    } else if (std.mem.eql(u8, command, "emit-map")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitMap(&session, path, artifact_source_path orelse path, source, options.profile, options.checks, options.stub_asm, options.targetArch(), options.output_path);
    } else if (std.mem.eql(u8, command, "emit-llvm")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitLlvm(&session, path, artifact_source_path orelse path, source, options.checks, options.stub_asm, options.targetArch(), options.linux_kernel, options.output_path);
    } else if (std.mem.eql(u8, command, "list-tests")) {
        try runListTests(&session, path, source);
    } else if (is_emit_layout) {
        try runEmitLayout(&session, path, source, options.structs_flag.?);
    } else if (is_emit_c_struct) {
        try runEmitCStruct(&session, path, source, options.structs_flag.?);
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
        error.SymbolsFailed,
        error.ParseFailed,
        error.MonomorphizationLimit,
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
        error.BuildFailed,
        error.EmitLlvmFailed,
        error.EmitLayoutFailed,
        error.EmitCStructFailed,
        error.OutputWriteFailed,
        => true,
        else => false,
    };
}

fn commandNeedsResolvedProgram(command: []const u8) bool {
    return std.mem.eql(u8, command, "check") or
        std.mem.eql(u8, command, "run-trap") or
        std.mem.eql(u8, command, "inspect-hir") or
        std.mem.eql(u8, command, "verify-inspect-hir") or
        std.mem.eql(u8, command, "lower-mir") or
        std.mem.eql(u8, command, "verify") or
        std.mem.eql(u8, command, "lower-c") or
        std.mem.eql(u8, command, "emit-c") or
        std.mem.eql(u8, command, "build") or
        std.mem.eql(u8, command, "emit-map") or
        std.mem.eql(u8, command, "emit-llvm") or
        cli.Options.isEmitLayout(command) or
        cli.Options.isEmitCStruct(command);
}

fn runExplain(session: *CompilationSession, code: []const u8) !void {
    const allocator = session.allocator;
    const text = try diagnostic_explain.explain(allocator, code) orelse {
        std.debug.print("error: unknown diagnostic code: {s}\n", .{code});
        return error.ExplainFailed;
    };
    defer allocator.free(text);
    try session.writeStdout(text);
}

fn runLowerHir(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.LowerHirFailed);
    const decls = try resolved.astDecls(parse_allocator);
    defer parse_allocator.free(decls);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendDumpFromDecls(allocator, decls, &output);
    try session.writeStdout(output.items);
}

fn runVerifyHir(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.VerifyHirFailed);
    const decls = try resolved.astDecls(parse_allocator);
    defer parse_allocator.free(decls);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendVerificationFactsFromDecls(allocator, decls, &output);
    try session.writeStdout(output.items);
}

fn runLowerMir(session: *CompilationSession, path: []const u8, source: []const u8, optimize: bool) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.LowerMirFailed);

    var module_mir: mir.Module = undefined;
    _ = try session.buildVerifiedProgramFromResolvedDecls(resolved.decls, &diag, optimize, &module_mir, error.LowerMirFailed);
    defer module_mir.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try mir.appendDumpFromMir(allocator, module_mir, &output);
    try session.writeStdout(output.items);
}

fn runVerify(session: *CompilationSession, path: []const u8, source: []const u8, optimize: bool) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.VerifyFailed);
    var module_mir: mir.Module = undefined;
    _ = try session.buildVerifiedProgramFromResolvedDecls(resolved.decls, &diag, optimize, &module_mir, error.VerifyFailed);
    defer module_mir.deinit();
}

fn failUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgs;
}

// `mcc fmt <file>` prints the canonically-formatted source to stdout. `mcc fmt --check <file>`
// prints nothing and exits nonzero if the file is not already formatted (for CI / editors).
fn runFmt(session: *CompilationSession, path: []const u8, source: []const u8, check: bool) !void {
    const allocator = session.allocator;
    const formatted = try fmt.format(allocator, source);
    defer allocator.free(formatted);
    if (check) {
        if (!std.mem.eql(u8, formatted, source)) {
            std.debug.print("{s}: not formatted (run `mcc fmt` to fix)\n", .{path});
            return error.FmtCheckFailed;
        }
        return;
    }
    try session.writeStdout(formatted);
}

// `mcc symbols <file>` prints a JSON symbol index (defs + refs with spans) for
// local tooling. Parse failures are reported as structured incomplete results;
// internal/resource failures return nonzero rather than masquerading as a clean
// empty file.
fn runSymbols(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    if (session.resolved_sources) |resolved_sources| {
        const module_graph = session.module_graph orelse {
            try session.writeStdout("{\"complete\":false,\"defs\":[],\"refs\":[],\"diagnostics\":[{\"severity\":\"error\",\"code\":\"E_SYMBOLS_INTERNAL\",\"message\":\"symbol indexing aborted by an internal error\"}]}\n");
            return error.SymbolsFailed;
        };
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        try symbols.emitJsonFromResolvedSources(allocator, module_graph.*, resolved_sources.*, &diag, &output);
        try session.writeStdout(output.items);
        return;
    }
    try session.writeStdout("{\"complete\":false,\"defs\":[],\"refs\":[],\"diagnostics\":[{\"severity\":\"error\",\"code\":\"E_SYMBOLS_INTERNAL\",\"message\":\"symbol indexing aborted before resolved sources were attached\"}]}\n");
    return error.MissingResolvedSources;
}

fn runLex(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    var diag = session.initReporter(path, source);
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

fn runCheck(session: *CompilationSession, path: []const u8, source: []const u8, json_diagnostics: bool) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.CheckFailed) catch |err| {
        if (diag.has_errors) {
            try emitDiagnostics(session, &diag, json_diagnostics);
        }
        return err;
    };

    if (json_diagnostics) {
        try emitDiagnostics(session, &diag, true);
    } else {
        std.debug.print("parsed {d} top-level declarations\n", .{resolved.decls.len});
    }
}

fn emitDiagnostics(session: *CompilationSession, diag: *diagnostics.Reporter, json_diagnostics: bool) !void {
    if (!json_diagnostics) {
        diag.render();
        return;
    }
    const allocator = session.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try diag.appendJson(&out);
    try session.writeStdout(out.items);
}

// `mcc list-tests <file>` prints, one per line, the name of every `#[test]`-attributed
// function in the file. A test is an ordinary `fn name() -> u32 { ...; return 1; }`
// whose `assert(...)`s trap on failure; the harness (tools/test/mc-test-runner.sh) runs
// each in its own process (a trap => fail) and reports pass/fail per name. This is the
// language-side discovery hook — no codegen change, so a `#[test]` function lowers like
// any other on both backends.
fn runListTests(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    _ = path;
    _ = source;

    if (session.resolved_sources) |resolved_sources| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const decls = try resolved_sources.collectDecls(allocator);
        defer allocator.free(decls);
        try appendResolvedTests(allocator, decls, &out);
        try session.writeStdout(out.items);
        return;
    }
    return error.MissingResolvedSources;
}

fn appendResolvedTests(allocator: std.mem.Allocator, decls: []const module_parser.ResolvedDecl, out: *std.ArrayList(u8)) !void {
    for (decls) |entry| try appendDeclTest(allocator, entry.decl, out);
}

fn appendDeclTest(allocator: std.mem.Allocator, decl: ast.Decl, out: *std.ArrayList(u8)) !void {
    var is_test = false;
    for (decl.attrs) |attr| {
        switch (attr.kind) {
            .named => |n| if (std.mem.eql(u8, n.text, "test")) {
                is_test = true;
            },
            else => {},
        }
    }
    if (!is_test) return;
    const name = switch (decl.kind) {
        .fn_decl => |fd| fd.name.text,
        else => return,
    };
    try out.appendSlice(allocator, name);
    try out.append(allocator, '\n');
}

fn runFacts(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    _ = path;
    _ = source;

    if (session.resolved_sources) |resolved_sources| {
        var facts: std.ArrayList(u8) = .empty;
        defer facts.deinit(allocator);
        try ir.appendFactsFromResolvedSources(allocator, resolved_sources.*, &facts);
        try session.writeStdout(facts.items);
        return;
    }
    return error.MissingResolvedSources;
}

fn runLowerIr(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    _ = path;
    _ = source;

    if (session.resolved_sources) |resolved_sources| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        try ir.appendLowerIrFromResolvedSources(allocator, resolved_sources.*, &output);
        try session.writeStdout(output.items);
        return;
    }
    return error.MissingResolvedSources;
}

fn runTrap(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.RunTrapFailed);
    const decls = try resolved.astDecls(parse_allocator);
    defer parse_allocator.free(decls);

    const source_db = session.source_db orelse return error.MissingResolvedSources;
    const graph = session.module_graph orelse return error.MissingModuleGraph;
    var expectation_count: usize = 0;
    for (source_db.files) |source_file| {
        var expectations = try eval.parseRunTrapExpectations(allocator, source_file.source);
        defer eval.freeRunTrapExpectations(allocator, &expectations);
        expectation_count += expectations.items.len;
        const expectation_path = if (graph.fileById(source_file.id)) |file| file.display_path else path;

        for (expectations.items) |expectation| {
            const actual = try eval.runTrapExpectationFromDecls(allocator, decls, expectation.function_name, expectation.args);
            if (actual == null or actual.? != expectation.trap) {
                std.debug.print(
                    "{s}:{d}: expected run {s}(...) to trap .{s}, got {s}\n",
                    .{ expectation_path, expectation.line, expectation.function_name, @tagName(expectation.trap), if (actual) |trap| @tagName(trap) else "no trap" },
                );
                return error.RunTrapFailed;
            }
            std.debug.print(
                "run_trap fn={s} trap={s} reached=true path={s} line={d}\n",
                .{ expectation.function_name, @tagName(expectation.trap), expectation_path, expectation.line },
            );
        }
    }
    if (expectation_count == 0) {
        std.debug.print("{s}: no inline run trap expectations found\n", .{path});
        return error.RunTrapFailed;
    }
}

fn runLowerC(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.LowerCFailed);
    const decls = try resolved.astDecls(parse_allocator);
    defer parse_allocator.free(decls);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try lower_c.appendInspectionFromDecls(allocator, decls, &output);
    try session.writeStdout(output.items);
}

fn runEmitC(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: backend.Profile, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitCFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitCFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const be = backend_registry.byName("c").?;
    const lower_opts = backend.LowerOptions{
        .profile = profile,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &output,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };
    var bundle = artifact_model.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "c",
        .backend_name = "c",
    });
    try attachCSourceMapDigests(allocator, be, program, early_metadata, output.items, lower_opts, &bundle);
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
}

fn runBuild(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, target_arch: backend.TargetArch, output_path: []const u8, clang_bin: []const u8) !void {
    const allocator = session.allocator;
    const io = session.io;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.BuildFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, false, &module_mir, &early_metadata, error.BuildFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var raw_c: std.ArrayList(u8) = .empty;
    defer raw_c.deinit(allocator);
    const be = backend_registry.byName("c").?;
    const lower_opts = backend.LowerOptions{
        .profile = .hosted,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &raw_c,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.BuildFailed;
        },
        else => return err,
    };

    var hosted_c: std.ArrayList(u8) = .empty;
    defer hosted_c.deinit(allocator);
    try appendHostedBuildWrapper(allocator, raw_c.items, &hosted_c, path);

    const tmp_c = try writeExclusiveBuildTemp(allocator, io, output_path, "c", hosted_c.items);
    defer allocator.free(tmp_c);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_c) catch {};

    const tmp_exe = try reserveExclusiveBuildTemp(allocator, io, output_path, "out");
    defer allocator.free(tmp_exe);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_exe) catch {};

    const argv = [_][]const u8{
        clang_bin,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-fno-strict-aliasing",
        "-fno-delete-null-pointer-checks",
        "-fwrapv",
        tmp_c,
        "-lm",
        "-o",
        tmp_exe,
    };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    }) catch |err| {
        std.debug.print("mcc build: clang invocation failed: {s}\n", .{@errorName(err)});
        return error.BuildFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    const clang_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!clang_ok) {
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        std.debug.print("mcc build: clang failed while linking {s}\n", .{output_path});
        return error.BuildFailed;
    }

    const executable_bytes = std.Io.Dir.cwd().readFileAlloc(io, tmp_exe, allocator, .limited(max_artifact_metadata_bytes)) catch |err| {
        std.debug.print("mcc build: unable to read linked temporary executable {s}: {s}\n", .{ tmp_exe, @errorName(err) });
        return error.BuildFailed;
    };
    defer allocator.free(executable_bytes);
    const toolchain_identity = try clangToolchainIdentity(allocator, io, clang_bin);
    defer allocator.free(toolchain_identity);
    var bundle = artifact_model.ArtifactBundle.forArtifact(executable_bytes, lower_opts, .{
        .artifact_kind = "host-executable",
        .backend_name = "c",
        .toolchain_identity = toolchain_identity,
    });
    try attachCSourceMapDigests(allocator, be, program, early_metadata, raw_c.items, lower_opts, &bundle);
    session.publishExistingArtifactWithMetadata(tmp_exe, output_path, bundle, "executable") catch {
        return error.BuildFailed;
    };
    try session.writeStdout("mcc build: wrote ");
    try session.writeStdout(output_path);
    try session.writeStdout("\n");
}

fn attachCSourceMapDigests(
    allocator: std.mem.Allocator,
    be: backend.Backend,
    program: backend.VerifiedProgram,
    declaration_artifacts: driver_codegen_inputs.DeclarationArtifacts,
    generated_c: []const u8,
    lower_opts: backend.LowerOptions,
    bundle: *artifact_model.ArtifactBundle,
) !void {
    if (!be.supportsEmitMap()) return;
    var map_bytes: std.ArrayList(u8) = .empty;
    defer map_bytes.deinit(allocator);
    try be.emitMapRequest(allocator, .{
        .program = program,
        .source_map_artifacts = declaration_artifacts.source_map_artifacts,
        .out = &map_bytes,
        .generated_artifact = generated_c,
        .opts = lower_opts,
    });
    bundle.source_map_generated_artifact_sha256 = try metadataDigestHeader(map_bytes.items, "generated_artifact_sha256");
    bundle.source_map_payload_sha256 = try metadataDigestHeader(map_bytes.items, "source_map_payload_sha256");
    bundle.mir_facts_sha256 = try metadataDigestHeader(map_bytes.items, "mir_facts_sha256");
}

fn metadataDigestHeader(bytes: []const u8, name: []const u8) !artifact_model.Sha256Digest {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "# ")) continue;
        const body = line[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        if (!std.mem.eql(u8, body[0..eq], name)) continue;
        const value = body[eq + 1 ..];
        if (value.len != 64) return error.InvalidArtifactMetadata;
        var digest: artifact_model.Sha256Digest = undefined;
        var index: usize = 0;
        while (index < digest.len) : (index += 1) {
            digest[index] = try std.fmt.parseInt(u8, value[index * 2 .. index * 2 + 2], 16);
        }
        return digest;
    }
    return error.InvalidArtifactMetadata;
}

fn buildTempPath(allocator: std.mem.Allocator, output_path: []const u8, suffix: []const u8, attempt: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.mc-build-{d}-{d}-{d}.{s}", .{
        output_path,
        std.posix.system.getpid(),
        std.Thread.getCurrentId(),
        attempt,
        suffix,
    });
}

fn isExistingPathError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "PathAlreadyExists") or
        std.mem.eql(u8, name, "FileAlreadyExists");
}

fn reserveExclusiveBuildTemp(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, suffix: []const u8) ![]const u8 {
    for (0..64) |attempt| {
        const path = try buildTempPath(allocator, output_path, suffix, attempt);
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            if (isExistingPathError(err)) {
                allocator.free(path);
                continue;
            }
            std.debug.print("mcc build: unable to reserve temporary {s} artifact {s}: {s}\n", .{ suffix, path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.close(io);
        return path;
    }
    std.debug.print("mcc build: unable to reserve unique temporary {s} artifact for {s}\n", .{ suffix, output_path });
    return error.BuildFailed;
}

fn writeExclusiveBuildTemp(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, suffix: []const u8, bytes: []const u8) ![]const u8 {
    for (0..64) |attempt| {
        const path = try buildTempPath(allocator, output_path, suffix, attempt);
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            if (isExistingPathError(err)) {
                allocator.free(path);
                continue;
            }
            std.debug.print("mcc build: unable to reserve temporary {s} artifact {s}: {s}\n", .{ suffix, path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.writeStreamingAll(io, bytes) catch |err| {
            file.close(io);
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            std.debug.print("mcc build: unable to write temporary {s}: {s}\n", .{ path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.close(io);
        return path;
    }
    std.debug.print("mcc build: unable to reserve unique temporary {s} artifact for {s}\n", .{ suffix, output_path });
    return error.BuildFailed;
}

fn clangToolchainIdentity(allocator: std.mem.Allocator, io: std.Io, clang_bin: []const u8) ![]const u8 {
    const fallback = struct {
        fn make(a: std.mem.Allocator, bin: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "clang={s}", .{bin});
        }
    }.make;

    const digest_identity = try clangExecutableDigestIdentity(allocator, io, clang_bin);
    defer if (digest_identity) |identity| allocator.free(identity);

    const argv = [_][]const u8{ clang_bin, "--version" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .expand_arg0 = .expand,
    }) catch {
        return fallback(allocator, clang_bin);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok or result.stdout.len == 0) return fallback(allocator, clang_bin);

    const first_line_end = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse result.stdout.len;
    const first_line = std.mem.trim(u8, result.stdout[0..first_line_end], "\r\n\t ");
    if (first_line.len == 0) return fallback(allocator, clang_bin);
    if (digest_identity) |identity| {
        return std.fmt.allocPrint(allocator, "clang={s};{s};version={s}", .{ clang_bin, identity, first_line });
    }
    return std.fmt.allocPrint(allocator, "clang={s};version={s}", .{ clang_bin, first_line });
}

fn clangExecutableDigestIdentity(allocator: std.mem.Allocator, io: std.Io, clang_bin: []const u8) !?[]const u8 {
    if (hasPathSeparator(clang_bin)) {
        const path = try resolveExplicitToolPath(allocator, io, clang_bin);
        defer allocator.free(path);
        return try toolDigestIdentityForPath(allocator, io, path);
    }

    const raw_path = std.c.getenv("PATH") orelse return null;
    var entries = std.mem.splitScalar(u8, std.mem.span(raw_path), std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, clang_bin });
        defer allocator.free(candidate);
        if (try toolDigestIdentityForPath(allocator, io, candidate)) |identity| return identity;
    }
    return null;
}

fn hasPathSeparator(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null or
        std.mem.indexOfScalar(u8, path, '\\') != null;
}

fn resolveExplicitToolPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    return std.fs.path.join(allocator, &.{ cwd_buffer[0..cwd_len], path });
}

fn toolDigestIdentityForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_artifact_metadata_bytes)) catch return null;
    defer allocator.free(bytes);
    const digest = artifact_model.sha256Bytes(bytes);
    const digest_hex = try allocHexDigest(allocator, digest);
    defer allocator.free(digest_hex);
    const identity = try std.fmt.allocPrint(allocator, "path={s};sha256={s}", .{ path, digest_hex });
    return identity;
}

fn allocHexDigest(allocator: std.mem.Allocator, digest: artifact_model.Sha256Digest) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (digest) |byte| {
        try out.print(allocator, "{x:0>2}", .{byte});
    }
    return out.toOwnedSlice(allocator);
}

fn appendHostedBuildWrapper(allocator: std.mem.Allocator, raw_c: []const u8, out: *std.ArrayList(u8), source_path: []const u8) !void {
    const entry_ret = findHostedMainReturnType(raw_c) orelse {
        std.debug.print("mcc build: expected exported no-argument main() entry point in {s}\n", .{source_path});
        return error.BuildFailed;
    };

    var lines = std.mem.splitScalar(u8, raw_c, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (cMainReturnTypeForSuffix(line, " main(void);")) |ret| {
            try out.appendSlice(allocator, ret);
            try out.appendSlice(allocator, " mc_user_main(void);");
        } else if (cMainReturnTypeForSuffix(line, " main(void) {")) |ret| {
            try out.appendSlice(allocator, ret);
            try out.appendSlice(allocator, " mc_user_main(void) {");
        } else {
            try out.appendSlice(allocator, raw_line);
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "\nint main(void) {\n");
    if (std.mem.eql(u8, entry_ret, "void")) {
        try out.appendSlice(allocator, "    mc_user_main();\n    return 0;\n");
    } else {
        try out.appendSlice(allocator, "    return (int)mc_user_main();\n");
    }
    try out.appendSlice(allocator, "}\n");
}

fn findHostedMainReturnType(raw_c: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw_c, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (cMainReturnTypeForSuffix(line, " main(void);")) |ret| return ret;
    }
    return null;
}

fn cMainReturnTypeForSuffix(line: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, line, suffix)) return null;
    const ret = line[0 .. line.len - suffix.len];
    if (!isCIdentifier(ret)) return null;
    return ret;
}

fn isCIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isCIdentifierStart(text[0])) return false;
    for (text[1..]) |ch| {
        if (!isCIdentifierContinue(ch)) return false;
    }
    return true;
}

fn isCIdentifierStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

fn isCIdentifierContinue(ch: u8) bool {
    return isCIdentifierStart(ch) or (ch >= '0' and ch <= '9');
}

fn runEmitMap(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: backend.Profile, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitCFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitCFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    const be = backend_registry.byName("c").?;
    var generated_c: std.ArrayList(u8) = .empty;
    defer generated_c.deinit(allocator);
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &generated_c,
        .opts = .{
            .profile = profile,
            .source_path = artifact_source_path,
            .target_arch = target_arch,
            .checks = checks,
            .stub_asm = stub_asm,
            .reporter = &diag,
            .source_sha256 = source_sha256,
            .compiler_version = build_options.version,
        },
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.emitMapRequest(allocator, .{
        .program = program,
        .source_map_artifacts = early_metadata.source_map_artifacts,
        .out = &output,
        .generated_artifact = generated_c.items,
        .opts = .{
            .profile = profile,
            .source_path = artifact_source_path,
            .target_arch = target_arch,
            .checks = checks,
            .stub_asm = stub_asm,
            .reporter = &diag,
            .source_sha256 = source_sha256,
            .compiler_version = build_options.version,
        },
    });
    try session.writeArtifact(output.items, output_path);
}

fn runEmitLlvm(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, linux_kernel: bool, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitLlvmFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitLlvmFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const be = backend_registry.byName("llvm").?;
    const lower_opts = backend.LowerOptions{
        .profile = .kernel,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .linux_kernel = linux_kernel,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &output,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedLlvmEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, "LLVM");
            diag.render();
            return error.EmitLlvmFailed;
        },
        else => return err,
    };
    const bundle = artifact_model.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "llvm-ir",
        .backend_name = "llvm",
    });
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
}

fn reportBackendUnsupportedFallback(diag: *diagnostics.Reporter, backend_name: []const u8) void {
    diag.err(.{ .offset = 0, .len = 1, .line = 1, .column = 1 }, "E_BACKEND_UNSUPPORTED: {s} backend does not yet support this construct", .{backend_name});
}

// `emit-layout`: emit a generated C header asserting MC's authoritative layout (sizeof + each
// field offset) for the comma-separated structs in `--structs=`. A C runtime that hand-mirrors
// one of these structs includes the header, so any MC↔C layout drift becomes a compile error.
fn runEmitLayout(session: *CompilationSession, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.EmitLayoutFailed);

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
    var typed_mir: mir.Module = undefined;
    var artifacts = driver_codegen_inputs.DeclarationArtifacts.empty;
    try driver_codegen_inputs.buildCArtifactInputs(session, &typed_mir, &artifacts);
    defer typed_mir.deinit();
    defer artifacts.deinit(allocator);
    lower_c.appendLayoutAssertsWithMirArtifacts(allocator, artifacts.codegen(), &typed_mir, &output, names.items) catch |err| switch (err) {
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
    try session.writeStdout(output.items);
}

// `emit-c-struct` (hardening A2): emit a generated C header with the FULL struct *definitions* for
// the comma-separated structs in `--structs=` — the actual `typedef struct { ... }` matching MC's
// field order/types/layout, plus the by-value array/struct wrappers they embed, plus the A1
// `_Static_assert`s as a cross-check. A C runtime includes this header and drops its hand-written
// mirror, so the MC struct becomes the single source of truth and MC↔C drift is impossible (there
// is no second declaration to diverge).
fn runEmitCStruct(session: *CompilationSession, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.EmitCStructFailed);

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
    var typed_mir: mir.Module = undefined;
    var artifacts = driver_codegen_inputs.DeclarationArtifacts.empty;
    try driver_codegen_inputs.buildCArtifactInputs(session, &typed_mir, &artifacts);
    defer typed_mir.deinit();
    defer artifacts.deinit(allocator);
    lower_c.appendStructDeclsWithMirArtifacts(allocator, artifacts.codegen(), &typed_mir, &output, names.items) catch |err| switch (err) {
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
    try session.writeStdout(output.items);
}
