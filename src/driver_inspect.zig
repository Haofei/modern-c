//! CLI-only inspection and formatting commands.
//!
//! These commands consume existing compiler-session results; they do not own
//! checking, lowering, or backend semantics.
const std = @import("std");
const ast = @import("ast.zig");
const compiler_session = @import("compiler_session.zig");
const diagnostic_explain = @import("diagnostic_explain.zig");
const fmt = @import("fmt.zig");
const ir = @import("ir_inspection.zig");
const module_parser = @import("module_parser.zig");

const CompilationSession = compiler_session.CompilationSession;

pub fn runExplain(session: *CompilationSession, code: []const u8) !void {
    const allocator = session.allocator;
    const text = try diagnostic_explain.explain(allocator, code) orelse {
        std.debug.print("error: unknown diagnostic code: {s}\n", .{code});
        return error.ExplainFailed;
    };
    defer allocator.free(text);
    try session.writeStdout(text);
}

pub fn runFmt(session: *CompilationSession, path: []const u8, source: []const u8, check: bool) !void {
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

pub fn runListTests(session: *CompilationSession) !void {
    const allocator = session.allocator;
    const resolved_sources = session.resolved_sources orelse return error.MissingResolvedSources;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const decls = try resolved_sources.collectDecls(allocator);
    defer allocator.free(decls);
    try appendResolvedTests(allocator, decls, &out);
    try session.writeStdout(out.items);
}

fn appendResolvedTests(allocator: std.mem.Allocator, decls: []const module_parser.ResolvedDecl, out: *std.ArrayList(u8)) !void {
    for (decls) |entry| try appendDeclTest(allocator, entry.decl, out);
}

fn appendDeclTest(allocator: std.mem.Allocator, decl: ast.Decl, out: *std.ArrayList(u8)) !void {
    var is_test = false;
    for (decl.attrs) |attr| switch (attr.kind) {
        .named => |name| {
            if (std.mem.eql(u8, name.text, "test")) is_test = true;
        },
        else => {},
    };
    if (!is_test) return;
    const name = switch (decl.kind) {
        .fn_decl => |function| function.name.text,
        else => return,
    };
    try out.appendSlice(allocator, name);
    try out.append(allocator, '\n');
}

pub fn runFacts(session: *CompilationSession) !void {
    const allocator = session.allocator;
    const resolved_sources = session.resolved_sources orelse return error.MissingResolvedSources;
    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(allocator);
    try ir.appendFactsFromResolvedSources(allocator, resolved_sources.*, &facts);
    try session.writeStdout(facts.items);
}

pub fn runLowerIr(session: *CompilationSession) !void {
    const allocator = session.allocator;
    const resolved_sources = session.resolved_sources orelse return error.MissingResolvedSources;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try ir.appendLowerIrFromResolvedSources(allocator, resolved_sources.*, &output);
    try session.writeStdout(output.items);
}
