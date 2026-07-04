const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const token = @import("token.zig");

const Lexer = lexer.Lexer;

fn lexAll(reporter: *diagnostics.Reporter) void {
    var lx = Lexer.init(reporter.source, reporter);
    while (lx.next().kind != .eof) {}
}

fn expectDiagnosticCode(source: []const u8, code: []const u8) !void {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "test.mc", source);
    defer reporter.deinit();
    lexAll(&reporter);

    try std.testing.expect(reporter.has_errors);
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code)) return;
    }
    std.debug.print("missing diagnostic code {s}; got:\n", .{code});
    for (reporter.diagnostics.items) |diag| std.debug.print("  {s}\n", .{diag.message});
    return error.MissingDiagnosticCode;
}

test "lexer recognizes checked arithmetic snippet" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "test.mc", "let z = x + y;");
    defer reporter.deinit();
    var lx = Lexer.init(reporter.source, &reporter);
    try std.testing.expectEqual(token.Kind.kw_let, lx.next().kind);
    try std.testing.expectEqual(token.Kind.identifier, lx.next().kind);
    try std.testing.expectEqual(token.Kind.equal, lx.next().kind);
    try std.testing.expectEqual(token.Kind.identifier, lx.next().kind);
    try std.testing.expectEqual(token.Kind.plus, lx.next().kind);
    try std.testing.expectEqual(token.Kind.identifier, lx.next().kind);
    try std.testing.expectEqual(token.Kind.semicolon, lx.next().kind);
    try std.testing.expectEqual(token.Kind.eof, lx.next().kind);
}

test "lexer skips UTF-8 BOM at start of file" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bom.mc", "\xEF\xBB\xBFlet z = 1;");
    defer reporter.deinit();
    var lx = Lexer.init(reporter.source, &reporter);

    const first = lx.next();
    try std.testing.expectEqual(token.Kind.kw_let, first.kind);
    try std.testing.expectEqual(@as(usize, 1), first.span.line);
    try std.testing.expectEqual(@as(usize, 1), first.span.column);
    try std.testing.expect(!reporter.has_errors);
}

test "lexer recognizes MC literal and operator forms" {
    const source =
        \\#[unsafe_contract(no_overflow)]
        \\let a = 123_456 + 0x20_u8;
        \\let b = "quoted \"text\"";
        \\let c = '\n';
        \\switch flags { .ok(v) => return ok(v >> 1), _ => return err(.Bounds); }
        \\x += y; x -= y; x *= y; x /= y; x %= y; x <<= 1; x >>= 1;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "test.mc", source);
    defer reporter.deinit();
    var lx = Lexer.init(reporter.source, &reporter);

    var saw_hex_suffix = false;
    var saw_fat_arrow = false;
    var saw_shift_right = false;
    var saw_underscore = false;

    while (true) {
        const tok = lx.next();
        if (tok.kind == .integer_literal and std.mem.eql(u8, tok.lexeme, "0x20_u8")) saw_hex_suffix = true;
        if (tok.kind == .fat_arrow) saw_fat_arrow = true;
        if (tok.kind == .shift_right) saw_shift_right = true;
        if (tok.kind == .underscore) saw_underscore = true;
        if (tok.kind == .eof) break;
    }

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(saw_hex_suffix);
    try std.testing.expect(saw_fat_arrow);
    try std.testing.expect(saw_shift_right);
    try std.testing.expect(saw_underscore);
}

test "lexer reports diagnostic positions" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "test.mc", "let x = 1abc;\nlet y = \"unterminated\n");
    defer reporter.deinit();
    lexAll(&reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(reporter.diagnostics.items.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, reporter.diagnostics.items[0].message, "E_LEX_INVALID_INTEGER_LITERAL"));
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items[0].span.line);
    try std.testing.expectEqual(@as(usize, 9), reporter.diagnostics.items[0].span.column);
    try std.testing.expect(std.mem.startsWith(u8, reporter.diagnostics.items[1].message, "E_LEX_UNTERMINATED_STRING_LITERAL"));
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items[1].span.line);
}

test "lexer diagnostic codes are stable" {
    // DIAGNOSTIC_UNIT: E_LEX_UNEXPECTED_BYTE
    try expectDiagnosticCode("$", "E_LEX_UNEXPECTED_BYTE");

    // DIAGNOSTIC_UNIT: E_LEX_UNTERMINATED_BLOCK_COMMENT
    try expectDiagnosticCode("/* open", "E_LEX_UNTERMINATED_BLOCK_COMMENT");

    // DIAGNOSTIC_UNIT: E_LEX_INVALID_INTEGER_LITERAL
    try expectDiagnosticCode("let x = 1abc;", "E_LEX_INVALID_INTEGER_LITERAL");

    // DIAGNOSTIC_UNIT: E_LEX_INVALID_FLOAT_LITERAL
    try expectDiagnosticCode("let x = 1.2_;", "E_LEX_INVALID_FLOAT_LITERAL");

    // DIAGNOSTIC_UNIT: E_LEX_UNTERMINATED_STRING_LITERAL
    try expectDiagnosticCode("\"open", "E_LEX_UNTERMINATED_STRING_LITERAL");

    // DIAGNOSTIC_UNIT: E_LEX_UNTERMINATED_CHAR_LITERAL
    try expectDiagnosticCode("'x", "E_LEX_UNTERMINATED_CHAR_LITERAL");

    // DIAGNOSTIC_UNIT: E_LEX_INVALID_CHAR_LITERAL
    try expectDiagnosticCode("'xy'", "E_LEX_INVALID_CHAR_LITERAL");

    // DIAGNOSTIC_UNIT: E_LEX_UNTERMINATED_ESCAPE_SEQUENCE
    try expectDiagnosticCode("\"\\", "E_LEX_UNTERMINATED_ESCAPE_SEQUENCE");

    // DIAGNOSTIC_UNIT: E_LEX_INVALID_ESCAPE_SEQUENCE
    try expectDiagnosticCode("\"\\q\"", "E_LEX_INVALID_ESCAPE_SEQUENCE");
}
