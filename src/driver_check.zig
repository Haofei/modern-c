//! CLI commands that inspect or check frontend and MIR state.
//!
//! This module deliberately owns only command presentation and temporary
//! allocation. `CompilationSession` remains the sole compiler pipeline entry.
const std = @import("std");
const compiler_session = @import("compiler_session.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const hir = @import("hir_inspection.zig");
const lexer = @import("lexer.zig");
const mir = @import("mir.zig");
const symbols = @import("symbols.zig");

const CompilationSession = compiler_session.CompilationSession;

pub fn runLowerHir(session: *CompilationSession, path: []const u8, source: []const u8) !void {
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

pub fn runVerifyHir(session: *CompilationSession, path: []const u8, source: []const u8) !void {
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

pub fn runLowerMir(session: *CompilationSession, path: []const u8, source: []const u8, optimize: bool) !void {
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

pub fn runVerify(session: *CompilationSession, path: []const u8, source: []const u8, optimize: bool) !void {
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

pub fn runSymbols(session: *CompilationSession, path: []const u8, source: []const u8) !void {
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

pub fn runLex(session: *CompilationSession, path: []const u8, source: []const u8) !void {
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
        if (tok.lexeme.len != 0) std.debug.print(" `{s}`", .{tok.lexeme});
        std.debug.print("\n", .{});
        if (tok.kind == .eof) break;
    }

    if (diag.has_errors) {
        diag.render();
        return error.LexFailed;
    }
}

pub fn runCheck(session: *CompilationSession, path: []const u8, source: []const u8, json_diagnostics: bool) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.CheckFailed) catch |err| {
        if (diag.has_errors) try emitDiagnostics(session, &diag, json_diagnostics);
        return err;
    };

    if (json_diagnostics) {
        try emitDiagnostics(session, &diag, true);
    } else {
        std.debug.print("parsed {d} top-level declarations\n", .{resolved.decls.len});
    }
}

pub fn emitDiagnostics(session: *CompilationSession, diag: *diagnostics.Reporter, json_diagnostics: bool) !void {
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

pub fn runTrap(session: *CompilationSession, path: []const u8, source: []const u8) !void {
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
