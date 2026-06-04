const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");
const lower_c = @import("lower_c.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const spec_tests = @import("spec_tests.zig");

const usage =
    \\usage:
    \\  mcc lex <file.mc>
    \\  mcc check <file.mc>
    \\  mcc run-trap <file.mc>
    \\  mcc facts <file.mc>
    \\  mcc lower-ir <file.mc>
    \\  mcc lower-c <file.mc>
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse return failUsage();
    const path = args.next() orelse return failUsage();
    if (args.next() != null) return failUsage();

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(source);

    if (std.mem.eql(u8, command, "lex")) {
        try runLex(allocator, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, path, source);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(allocator, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-ir")) {
        try runLowerIr(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(allocator, path, source);
    } else {
        return failUsage();
    }
}

fn failUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgs;
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
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    std.debug.print("parsed {d} top-level declarations\n", .{module.decls.len});
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
    std.debug.print("{s}", .{facts.items});
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
    std.debug.print("{s}", .{output.items});
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
    std.debug.print("{s}", .{output.items});
}

fn parseModuleOrReport(source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, diag);
    return p.parseModule(allocator) catch |err| {
        diag.render();
        return err;
    };
}

test {
    _ = diagnostics;
    _ = eval;
    _ = ast;
    _ = ir;
    _ = lexer;
    _ = lower_c;
    _ = parser;
    _ = sema;
    _ = spec_tests;
}
