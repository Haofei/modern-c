const std = @import("std");

const artifact_model = @import("artifact_model.zig");
const backend = @import("backend.zig");
const backend_registry = @import("backend_registry.zig");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const compiler_session = @import("compiler_session.zig");
const diagnostics = @import("diagnostics.zig");
const driver_build = @import("driver_build.zig");
const driver_check = @import("driver_check.zig");
const driver_inspect = @import("driver_inspect.zig");
const driver_codegen_inputs = @import("driver_codegen_inputs.zig");
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
        try driver_inspect.runExplain(&session, code);
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
        try driver_inspect.runFmt(&session, path, root_source, options.check_fmt);
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
            try driver_check.emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
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
        try driver_check.emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
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
        try driver_check.runLex(&session, path, source);
        return;
    }
    var module_parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer module_parse_arena.deinit();
    var parsed_sources: module_parser.ParsedSourceDatabase = undefined;
    var resolved_sources: module_parser.ResolvedSourceDatabase = undefined;
    session.attachLoadedProjectSyntax(&loaded, module_parse_arena.allocator(), &load_diag, &parsed_sources, &resolved_sources) catch |err| {
        try driver_check.emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
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
            try driver_check.emitDiagnostics(&session, &load_diag, std.mem.eql(u8, command, "check") and options.json_diagnostics);
            return err;
        };
        resolved_program_ready = true;
        session.resolved_program = &resolved_program;
    }

    if (std.mem.eql(u8, command, "symbols")) {
        try driver_check.runSymbols(&session, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try driver_check.runCheck(&session, path, source, options.json_diagnostics);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try driver_check.runTrap(&session, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try driver_inspect.runFacts(&session);
    } else if (std.mem.eql(u8, command, "inspect-hir")) {
        try driver_check.runLowerHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "verify-inspect-hir")) {
        try driver_check.runVerifyHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try driver_check.runLowerMir(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try driver_check.runVerify(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "inspect-ir")) {
        try driver_inspect.runLowerIr(&session);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(&session, path, source);
    } else if (std.mem.eql(u8, command, "emit-c")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitC(&session, path, artifact_source_path orelse path, source, options.profile, options.checks, options.stub_asm, options.targetArch(), options.output_path);
    } else if (std.mem.eql(u8, command, "build")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try driver_build.runBuild(&session, path, artifact_source_path orelse path, source, options.targetArch(), options.output_path.?, init.environ_map.get("CLANG") orelse "clang");
    } else if (std.mem.eql(u8, command, "emit-map")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitMap(&session, path, artifact_source_path orelse path, source, options.profile, options.checks, options.stub_asm, options.targetArch(), options.output_path);
    } else if (std.mem.eql(u8, command, "emit-llvm")) {
        const artifact_source_path = try artifactSourcePath(allocator, init.io, options, path);
        defer if (artifact_source_path) |p| allocator.free(p);
        try runEmitLlvm(&session, path, artifact_source_path orelse path, source, options.checks, options.stub_asm, options.targetArch(), options.linux_kernel, options.output_path);
    } else if (std.mem.eql(u8, command, "list-tests")) {
        try driver_inspect.runListTests(&session);
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

fn failUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgs;
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
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };
    var bundle = artifact_model.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "c",
        .backend_name = "c",
    });
    try driver_build.attachCSourceMapDigests(allocator, be, program, early_metadata, output.items, lower_opts, &bundle);
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
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
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "C");
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
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "LLVM");
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
