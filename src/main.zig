const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const spec_tests = @import("spec_tests.zig");

const usage =
    \\usage:
    \\  mcc lex <file.mc>
    \\  mcc check <file.mc>
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

    var p = parser.Parser.init(source, &diag);
    const module = p.parseModule(parse_allocator) catch |err| {
        diag.render();
        return err;
    };
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

test {
    _ = diagnostics;
    _ = lexer;
    _ = parser;
    _ = sema;
    _ = spec_tests;
}
