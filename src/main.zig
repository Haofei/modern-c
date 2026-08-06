const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const backend_registry = @import("backend_registry.zig");
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
const mangle_private_tests = @import("mangle_private_tests.zig");
const name_resolve = @import("name_resolve.zig");
const parser = @import("parser.zig");
const parser_tests = @import("parser_tests.zig");
const sema = @import("sema.zig");
const sema_tests = @import("sema_tests.zig");
const spec_tests = @import("spec_tests.zig");
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
    \\  mcc lower-hir <file.mc>
    \\  mcc verify-hir <file.mc>
    \\  mcc lower-mir <file.mc> [--checks=all|elide-proven]
    \\  mcc verify <file.mc> [--checks=all|elide-proven]
    \\  mcc lower-ir <file.mc>
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
    \\HIR commands are inspection-only; MIR verification remains the backend production boundary.
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
const max_artifact_metadata_bytes = 512 * 1024 * 1024;

const CompilationStageFailure = error{
    CheckFailed,
    LowerMirFailed,
    VerifyFailed,
    EmitCFailed,
    BuildFailed,
    EmitLlvmFailed,
    EmitLayoutFailed,
    EmitCStructFailed,
};

const CompilationSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // File-origin boundaries of the import-flattened source
    // (loader.loadCombinedSourceWithBoundaries), set once per source-loading
    // invocation and consumed by diagnostics/sema/name transforms. Null when no
    // module was loaded (e.g. `fmt`, which bypasses the loader).
    file_boundaries: ?[]const loader.FileBoundary = null,
    module_graph: ?*const loader.ModuleGraph = null,
    visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,

    fn init(allocator: std.mem.Allocator, io: std.Io) CompilationSession {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    fn writeStdout(self: *CompilationSession, bytes: []const u8) !void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }

    fn writeOutputPath(self: *CompilationSession, path: []const u8, bytes: []const u8) !void {
        // Materialize artifacts through a sibling temporary file and atomically
        // replace the destination only after the complete write succeeds. A
        // failed or killed compilation therefore cannot truncate a previously
        // valid artifact or expose a partially written one.
        var atomic_file = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer atomic_file.deinit(self.io);
        atomic_file.file.writeStreamingAll(self.io, bytes) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        atomic_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
    }

    const ArtifactMetadataDraft = struct {
        path: []const u8,
        bytes: std.ArrayList(u8),

        fn deinit(self: *ArtifactMetadataDraft, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.bytes.deinit(allocator);
        }
    };

    const MetadataSidecarSnapshot = union(enum) {
        absent,
        present: []u8,

        fn deinit(self: *MetadataSidecarSnapshot, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .absent => {},
                .present => |bytes| allocator.free(bytes),
            }
        }
    };

    fn ensureReplaceTargetNotDirectory(self: *CompilationSession, path: []const u8, label: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                std.debug.print("error: unable to inspect {s} \"{s}\": {s}\n", .{ label, path, @errorName(err) });
                return error.OutputWriteFailed;
            },
        };
        if (stat.kind == .directory) {
            std.debug.print("error: unable to replace {s} \"{s}\": destination is a directory\n", .{ label, path });
            return error.OutputWriteFailed;
        }
    }

    fn snapshotMetadataSidecar(self: *CompilationSession, path: []const u8) !MetadataSidecarSnapshot {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_artifact_metadata_bytes)) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => {
                std.debug.print("error: unable to snapshot metadata sidecar \"{s}\": {s}\n", .{ path, @errorName(err) });
                return error.OutputWriteFailed;
            },
        };
        return .{ .present = bytes };
    }

    fn restoreMetadataSidecar(self: *CompilationSession, path: []const u8, snapshot: MetadataSidecarSnapshot) !void {
        switch (snapshot) {
            .absent => {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
                    error.FileNotFound => return,
                    else => {
                        std.debug.print("error: unable to remove rolled-back metadata sidecar \"{s}\": {s}\n", .{ path, @errorName(err) });
                        return error.OutputWriteFailed;
                    },
                };
            },
            .present => |bytes| try self.writeOutputPath(path, bytes),
        }
    }

    fn prepareArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: backend.ArtifactBundle) !ArtifactMetadataDraft {
        const metadata_path = try artifactMetadataPath(self.allocator, output_path);
        errdefer self.allocator.free(metadata_path);

        var metadata: std.ArrayList(u8) = .empty;
        errdefer metadata.deinit(self.allocator);
        try backend.appendArtifactMetadata(self.allocator, &metadata, bundle);

        return .{
            .path = metadata_path,
            .bytes = metadata,
        };
    }

    fn writeArtifact(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8) !void {
        if (output_path) |path| return self.writeOutputPath(path, bytes);
        return self.writeStdout(bytes);
    }

    fn writeArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: backend.ArtifactBundle) !void {
        var metadata = try self.prepareArtifactMetadataSidecar(output_path, bundle);
        defer metadata.deinit(self.allocator);
        try self.writeOutputPath(metadata.path, metadata.bytes.items);
    }

    fn writeArtifactWithMetadata(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8, bundle: backend.ArtifactBundle) !void {
        const path = output_path orelse return self.writeStdout(bytes);

        var metadata = try self.prepareArtifactMetadataSidecar(path, bundle);
        defer metadata.deinit(self.allocator);
        try self.ensureReplaceTargetNotDirectory(path, "output");
        try self.ensureReplaceTargetNotDirectory(metadata.path, "metadata sidecar");
        var metadata_snapshot = try self.snapshotMetadataSidecar(metadata.path);
        defer metadata_snapshot.deinit(self.allocator);

        var metadata_file = std.Io.Dir.cwd().createFileAtomic(self.io, metadata.path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer metadata_file.deinit(self.io);
        metadata_file.file.writeStreamingAll(self.io, metadata.bytes.items) catch |err| {
            std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };

        var artifact_file = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer artifact_file.deinit(self.io);
        artifact_file.file.writeStreamingAll(self.io, bytes) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };

        // Publish the sidecar before the artifact. The artifact is the
        // consumer-visible commit point, so a newly visible artifact always has
        // its matching metadata in place. If the final artifact replace fails,
        // strict consumers compare the newer sidecar against the still-old
        // artifact and fail closed on the digest mismatch.
        metadata_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        artifact_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit output \"{s}\": {s}\n", .{ path, @errorName(err) });
            self.restoreMetadataSidecar(metadata.path, metadata_snapshot) catch |restore_err| {
                std.debug.print("error: unable to roll back metadata sidecar \"{s}\" after output commit failure: {s}\n", .{ metadata.path, @errorName(restore_err) });
            };
            return error.OutputWriteFailed;
        };
    }

    fn initReporter(self: *CompilationSession, path: []const u8, source: []const u8) diagnostics.Reporter {
        var reporter = diagnostics.Reporter.init(self.allocator, path, source);
        reporter.file_boundaries = self.file_boundaries;
        return reporter;
    }

    fn parseModuleOrReport(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter) !ast.Module {
        return self.parseModuleOrReportMode(source, allocator, diag, true);
    }

    fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module {
        var p = parser.Parser.init(source, diag);
        var module = p.parseModule(allocator) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        module.visibility_mode = self.visibility_mode;
        const resolved = name_resolve.transformWithGraph(allocator, module, self.module_graph) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        // Lower `async fn` / `await` to stackless Future state machines BEFORE
        // monomorphize/sema, so the move/borrow checker and both backends only
        // ever see ordinary MC. No-op for modules without any `async fn`
        // (passes the module through untouched).
        const lowered = async_lower.transform(allocator, resolved, diag) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        try generic_precheck.check(allocator, lowered, diag, self.file_boundaries);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return error.ParseFailed;
        }
        const specialized = monomorphize.transformReport(allocator, lowered, diag) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return error.ParseFailed;
        }
        return mangle_private.transform(allocator, specialized, self.file_boundaries) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
    }

    fn checkModule(self: *CompilationSession, module: ast.Module, diag: *diagnostics.Reporter, optimize: bool) void {
        var checker = sema.Checker.init(diag);
        checker.file_boundaries = self.file_boundaries;
        checker.optimize = optimize;
        checker.checkModule(module);
    }

    fn parseCheckedModuleOrReport(
        self: *CompilationSession,
        source: []const u8,
        allocator: std.mem.Allocator,
        diag: *diagnostics.Reporter,
        optimize: bool,
        render_errors: bool,
        failure_error: CompilationStageFailure,
    ) !ast.Module {
        const module = try self.parseModuleOrReportMode(source, allocator, diag, render_errors);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return failure_error;
        }
        self.checkModule(module, diag, optimize);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return failure_error;
        }
        return module;
    }

    fn buildVerifiedProgram(
        self: *CompilationSession,
        module: ast.Module,
        diag: *diagnostics.Reporter,
        optimize: bool,
        module_mir: *mir.Module,
        failure_error: CompilationStageFailure,
    ) !backend.VerifiedProgram {
        module_mir.* = try mir.buildOpt(self.allocator, module, .{ .optimize = optimize });
        errdefer module_mir.deinit();
        const program = backend.VerifiedProgram.initFromDecls(module.decls, module_mir, diag) catch |err| {
            if (diag.has_errors) return failure_error;
            return err;
        };
        if (diag.has_errors) return failure_error;
        return program;
    }
};

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

fn artifactMetadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.mcmeta", .{output_path});
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

    // `fmt` operates on the raw file (not the import-flattened source) and is token-preserving;
    // it bypasses the parse/sema pipeline entirely.
    if (std.mem.eql(u8, command, "fmt")) {
        try runFmt(&session, path, root_source, options.check_fmt);
        return;
    }

    // Resolve `import "path";` declarations by textual inclusion (section 22 /
    // module system). With no imports this is the original source plus a
    // trailing newline, so single-file behavior is unchanged.
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
        .platform = options.platform_flag,
        .std_dir = options.std_dir,
        .mc_path = mc_path_entries.items,
    }, &load_diag) catch |err| switch (err) {
        error.Reported => {
            if (std.mem.eql(u8, command, "check") and options.json_diagnostics) {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(allocator);
                try load_diag.appendJson(&out);
                try session.writeStdout(out.items);
            } else {
                load_diag.render();
            }
            return error.ImportNotFound;
        },
        else => return err,
    };
    defer loaded.deinit(allocator);
    const source = loaded.source;
    if (reads_stdin and loaded.boundaries.len > 0) {
        allocator.free(loaded.boundaries[0].path);
        loaded.boundaries[0].path = try allocator.dupe(u8, path);
    }
    load_diag.source = source;
    load_diag.file_boundaries = loaded.boundaries;
    if (load_diag.has_errors) {
        if (std.mem.eql(u8, command, "check") and options.json_diagnostics) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try load_diag.appendJson(&out);
            try session.writeStdout(out.items);
        } else {
            load_diag.render();
        }
        return error.ImportNotFound;
    }
    session.file_boundaries = loaded.boundaries;
    defer session.file_boundaries = null;
    session.module_graph = &loaded.graph;
    defer session.module_graph = null;

    if (std.mem.eql(u8, command, "lex")) {
        try runLex(&session, path, source);
    } else if (std.mem.eql(u8, command, "symbols")) {
        try runSymbols(&session, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(&session, path, source, options.json_diagnostics);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(&session, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(&session, path, source);
    } else if (std.mem.eql(u8, command, "lower-hir")) {
        try runLowerHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "verify-hir")) {
        try runVerifyHir(&session, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try runLowerMir(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try runVerify(&session, path, source, options.checks.optimize);
    } else if (std.mem.eql(u8, command, "lower-ir")) {
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
        error.BuildFailed,
        error.EmitLlvmFailed,
        error.EmitLayoutFailed,
        error.EmitCStructFailed,
        error.OutputWriteFailed,
        => true,
        else => false,
    };
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

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendDump(allocator, module, &output);
    try session.writeStdout(output.items);
}

fn runVerifyHir(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.VerifyHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendVerificationFacts(allocator, module, &output);
    try session.writeStdout(output.items);
}

fn runLowerMir(session: *CompilationSession, path: []const u8, source: []const u8, optimize: bool) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.LowerMirFailed);
    defer module.deinit(parse_allocator);

    var module_mir: mir.Module = undefined;
    _ = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.LowerMirFailed);
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

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.VerifyFailed);
    defer module.deinit(parse_allocator);

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
// the language server. Parse failures are reported as structured incomplete
// results; internal/resource failures return nonzero rather than masquerading as
// a clean empty file.
fn runSymbols(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = session.parseModuleOrReport(source, parse_allocator, &diag) catch |err| switch (err) {
        error.ParseFailed => {
            try session.writeStdout("{\"complete\":false,\"defs\":[],\"refs\":[],\"diagnostics\":[{\"severity\":\"error\",\"code\":\"E_PARSE_FAILED\",\"message\":\"symbol indexing aborted after parse diagnostics\"}]}\n");
            return error.ParseFailed;
        },
        else => {
            try session.writeStdout("{\"complete\":false,\"defs\":[],\"refs\":[],\"diagnostics\":[{\"severity\":\"error\",\"code\":\"E_SYMBOLS_INTERNAL\",\"message\":\"symbol indexing aborted by an internal error\"}]}\n");
            return err;
        },
    };
    defer module.deinit(parse_allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try symbols.emitJson(allocator, module, &diag, &output);
    try session.writeStdout(output.items);
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

    const module = session.parseCheckedModuleOrReport(source, parse_allocator, &diag, false, false, error.CheckFailed) catch |err| {
        if (diag.has_errors) {
            try emitCheckDiagnostics(session, &diag, json_diagnostics);
        }
        return err;
    };
    defer module.deinit(parse_allocator);

    if (json_diagnostics) {
        try emitCheckDiagnostics(session, &diag, true);
    } else {
        std.debug.print("parsed {d} top-level declarations\n", .{module.decls.len});
    }
}

fn emitCheckDiagnostics(session: *CompilationSession, diag: *diagnostics.Reporter, json_diagnostics: bool) !void {
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
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
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
    try session.writeStdout(out.items);
}

fn runFacts(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.FactsFailed;
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(allocator);
    try ir.appendFacts(allocator, module, &facts);
    try session.writeStdout(facts.items);
}

fn runLowerIr(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerIrFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try ir.appendLowerIr(allocator, module, &output);
    try session.writeStdout(output.items);
}

fn runTrap(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
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

fn runLowerC(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerCFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try lower_c.appendInspection(allocator, module, &output);
    try session.writeStdout(output.items);
}

fn runEmitC(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: backend.Profile, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = backend.sha256Bytes(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.EmitCFailed);
    defer module.deinit(parse_allocator);

    var module_mir: mir.Module = undefined;
    const program = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.EmitCFailed);
    defer module_mir.deinit();

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
    be.lower(allocator, program, &output, lower_opts) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };
    var bundle = backend.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "c",
        .backend_name = "c",
    });
    try attachCSourceMapDigests(allocator, be, program, output.items, lower_opts, &bundle);
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
}

fn runBuild(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, target_arch: backend.TargetArch, output_path: []const u8, clang_bin: []const u8) !void {
    const allocator = session.allocator;
    const io = session.io;
    const source_sha256 = backend.sha256Bytes(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, false, true, error.BuildFailed);
    defer module.deinit(parse_allocator);

    var module_mir: mir.Module = undefined;
    const program = try session.buildVerifiedProgram(module, &diag, false, &module_mir, error.BuildFailed);
    defer module_mir.deinit();

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
    be.lower(allocator, program, &raw_c, lower_opts) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "C");
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
    var bundle = backend.ArtifactBundle.forArtifact(executable_bytes, lower_opts, .{
        .artifact_kind = "host-executable",
        .backend_name = "c",
        .toolchain_identity = toolchain_identity,
    });
    try attachCSourceMapDigests(allocator, be, program, raw_c.items, lower_opts, &bundle);
    var metadata = try session.prepareArtifactMetadataSidecar(output_path, bundle);
    defer metadata.deinit(allocator);
    try session.ensureReplaceTargetNotDirectory(output_path, "output");
    try session.ensureReplaceTargetNotDirectory(metadata.path, "metadata sidecar");
    var metadata_snapshot = try session.snapshotMetadataSidecar(metadata.path);
    defer metadata_snapshot.deinit(allocator);

    var metadata_file = std.Io.Dir.cwd().createFileAtomic(io, metadata.path, .{
        .replace = true,
    }) catch |err| {
        std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
        return error.BuildFailed;
    };
    defer metadata_file.deinit(io);
    metadata_file.file.writeStreamingAll(io, metadata.bytes.items) catch |err| {
        std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
        return error.BuildFailed;
    };

    // Commit metadata before publishing the executable. A stale executable
    // paired with newer metadata is rejected by digest validation; a new
    // executable without its sidecar is the fail-open state to avoid.
    metadata_file.replace(io) catch |err| {
        std.debug.print("error: unable to commit metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
        return error.BuildFailed;
    };
    std.Io.Dir.cwd().rename(tmp_exe, std.Io.Dir.cwd(), output_path, io) catch |err| {
        std.debug.print("mcc build: unable to commit {s}: {s}\n", .{ output_path, @errorName(err) });
        session.restoreMetadataSidecar(metadata.path, metadata_snapshot) catch |restore_err| {
            std.debug.print("error: unable to roll back metadata sidecar \"{s}\" after executable commit failure: {s}\n", .{ metadata.path, @errorName(restore_err) });
        };
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
    generated_c: []const u8,
    lower_opts: backend.LowerOptions,
    bundle: *backend.ArtifactBundle,
) !void {
    if (!be.supportsEmitMap()) return;
    var map_bytes: std.ArrayList(u8) = .empty;
    defer map_bytes.deinit(allocator);
    try be.emitMap(allocator, program, &map_bytes, generated_c, lower_opts);
    bundle.source_map_generated_artifact_sha256 = try metadataDigestHeader(map_bytes.items, "generated_artifact_sha256");
    bundle.source_map_payload_sha256 = try metadataDigestHeader(map_bytes.items, "source_map_payload_sha256");
    bundle.mir_facts_sha256 = try metadataDigestHeader(map_bytes.items, "mir_facts_sha256");
}

fn metadataDigestHeader(bytes: []const u8, name: []const u8) !backend.Sha256Digest {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "# ")) continue;
        const body = line[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        if (!std.mem.eql(u8, body[0..eq], name)) continue;
        const value = body[eq + 1 ..];
        if (value.len != 64) return error.InvalidArtifactMetadata;
        var digest: backend.Sha256Digest = undefined;
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
    const digest = backend.sha256Bytes(bytes);
    const digest_hex = try allocHexDigest(allocator, digest);
    defer allocator.free(digest_hex);
    const identity = try std.fmt.allocPrint(allocator, "path={s};sha256={s}", .{ path, digest_hex });
    return identity;
}

fn allocHexDigest(allocator: std.mem.Allocator, digest: backend.Sha256Digest) ![]const u8 {
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
    var source_sha256: backend.Sha256Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &source_sha256, .{});
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.EmitCFailed);
    defer module.deinit(parse_allocator);

    var module_mir: mir.Module = undefined;
    const program = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.EmitCFailed);
    defer module_mir.deinit();

    const be = backend_registry.byName("c").?;
    var generated_c: std.ArrayList(u8) = .empty;
    defer generated_c.deinit(allocator);
    be.lower(allocator, program, &generated_c, .{
        .profile = profile,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.emitMap(allocator, program, &output, generated_c.items, .{
        .profile = profile,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    });
    try session.writeArtifact(output.items, output_path);
}

fn runEmitLlvm(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, linux_kernel: bool, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = backend.sha256Bytes(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.EmitLlvmFailed);
    defer module.deinit(parse_allocator);

    var module_mir: mir.Module = undefined;
    const program = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.EmitLlvmFailed);
    defer module_mir.deinit();

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
    be.lower(allocator, program, &output, lower_opts) catch |err| switch (err) {
        error.UnsupportedLlvmEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, module, "LLVM");
            diag.render();
            return error.EmitLlvmFailed;
        },
        else => return err,
    };
    const bundle = backend.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "llvm-ir",
        .backend_name = "llvm",
    });
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
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
fn runEmitLayout(session: *CompilationSession, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, false, true, error.EmitLayoutFailed);
    defer module.deinit(parse_allocator);

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

    const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, false, true, error.EmitCStructFailed);
    defer module.deinit(parse_allocator);

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
    try session.writeStdout(output.items);
}

test "CompilationSession keeps parse context request scoped" {
    const source = "fn answer() -> u32 { return 1; }\n";

    var boundaries_a = [_]loader.FileBoundary{.{ .start = 0, .path = "a.mc" }};
    var session_a = CompilationSession.init(std.testing.allocator, std.testing.io);
    session_a.visibility_mode = .explicit_public;
    session_a.file_boundaries = boundaries_a[0..];
    var diag_a = session_a.initReporter("root_a.mc", source);
    defer diag_a.deinit();
    try std.testing.expectEqualStrings("a.mc", diag_a.file_boundaries.?[0].path);
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    const module_a = try session_a.parseModuleOrReportMode(source, arena_a.allocator(), &diag_a, false);
    defer module_a.deinit(arena_a.allocator());
    try std.testing.expectEqual(ast.VisibilityMode.explicit_public, module_a.visibility_mode);

    var boundaries_b = [_]loader.FileBoundary{.{ .start = 0, .path = "b.mc" }};
    var session_b = CompilationSession.init(std.testing.allocator, std.testing.io);
    session_b.file_boundaries = boundaries_b[0..];
    var diag_b = session_b.initReporter("root_b.mc", source);
    defer diag_b.deinit();
    try std.testing.expectEqualStrings("b.mc", diag_b.file_boundaries.?[0].path);
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    const module_b = try session_b.parseModuleOrReportMode(source, arena_b.allocator(), &diag_b, false);
    defer module_b.deinit(arena_b.allocator());
    try std.testing.expectEqual(ast.VisibilityMode.legacy_pub_opt_in, module_b.visibility_mode);
}

test "CompilationSession restores artifact metadata sidecar snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const artifact_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/artifact", .{tmp.sub_path});
    defer allocator.free(artifact_path);
    const metadata_path = try artifactMetadataPath(allocator, artifact_path);
    defer allocator.free(metadata_path);

    var session = CompilationSession.init(allocator, std.testing.io);
    try session.writeOutputPath(metadata_path, "old metadata");
    var present_snapshot = try session.snapshotMetadataSidecar(metadata_path);
    defer present_snapshot.deinit(allocator);
    try session.writeOutputPath(metadata_path, "new metadata");
    try session.restoreMetadataSidecar(metadata_path, present_snapshot);
    const restored = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, metadata_path, allocator, .limited(1024));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("old metadata", restored);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path);
    var absent_snapshot = try session.snapshotMetadataSidecar(metadata_path);
    defer absent_snapshot.deinit(allocator);
    try session.writeOutputPath(metadata_path, "new metadata");
    try session.restoreMetadataSidecar(metadata_path, absent_snapshot);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, metadata_path, .{}));
}

test "CompilationSession diagnostic stage failures use a bounded error set" {
    const allowed = [_]CompilationStageFailure{
        error.CheckFailed,
        error.LowerMirFailed,
        error.VerifyFailed,
        error.EmitCFailed,
        error.BuildFailed,
        error.EmitLlvmFailed,
        error.EmitLayoutFailed,
        error.EmitCStructFailed,
    };
    comptime std.debug.assert(@TypeOf(allowed[0]) == CompilationStageFailure);
    try std.testing.expectEqual(@as(usize, 8), allowed.len);
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
    _ = mangle_private_tests;
    _ = name_resolve;
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
