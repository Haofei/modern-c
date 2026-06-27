const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const token = @import("token.zig");

const Lexer = lexer.Lexer;

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
    var lx = Lexer.init(reporter.source, &reporter);

    while (lx.next().kind != .eof) {}

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(reporter.diagnostics.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items[0].span.line);
    try std.testing.expectEqual(@as(usize, 9), reporter.diagnostics.items[0].span.column);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items[1].span.line);
}
