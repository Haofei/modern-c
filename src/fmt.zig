// `mcc fmt` — a canonical source formatter for MC.
//
// The formatter is deliberately *token-preserving*: it rewrites leading indentation, trailing
// whitespace, runs of blank lines, and conservative spacing between unambiguous tokens. It never
// drops, adds, or reorders a token — the formatted output lexes to exactly the same token
// sequence as the input. Indentation is recomputed from the bracket nesting depth derived from
// the token stream (so a `{`/`(`/`[` inside a string or comment never shifts indentation), four
// spaces per level, with a line whose first token closes a bracket dedented one level so `}`
// lines align with their opener. Comment-only and blank lines indent to the surrounding depth.
//
// This is a safe, idempotent baseline (`fmt(fmt(x)) == fmt(x)`). Deeper AST-aware wrapping can
// layer on later without changing the interface.

const std = @import("std");
const lexer = @import("lexer.zig");
const token = @import("token.zig");
const diagnostics = @import("diagnostics.zig");

const INDENT = "    "; // four spaces per nesting level

// True if a token opens a bracket nesting level.
fn isOpener(kind: token.Kind) bool {
    return kind == .l_brace or kind == .l_paren or kind == .l_bracket;
}

// True if a token closes a bracket nesting level.
fn isCloser(kind: token.Kind) bool {
    return kind == .r_brace or kind == .r_paren or kind == .r_bracket;
}

const LineInfo = struct {
    indent_level: usize, // computed nesting level for this line's leading indentation
    has_token: bool, // whether any token begins on this line
};

// Compute the indentation level of every 1-based source line from the token stream.
// `depth` is the bracket nesting before the line; a line whose first token is a closer is
// rendered one level shallower so the closer aligns with its opener.
fn computeLineLevels(allocator: std.mem.Allocator, source: []const u8, line_count: usize) ![]LineInfo {
    const lines = try allocator.alloc(LineInfo, line_count + 2);
    for (lines) |*li| li.* = .{ .indent_level = 0, .has_token = false };

    var diag = diagnostics.Reporter.init(allocator, "<fmt>", source);
    defer diag.deinit();
    var lx = lexer.Lexer.init(source, &diag);

    var depth: usize = 0;
    var prev_line: usize = 0; // line of the previous token (0 = none yet)
    while (true) {
        const tok = lx.next();
        if (tok.kind == .eof) break;
        const tline = tok.span.line;
        if (tline > prev_line) {
            // This is the FIRST token on line `tline`. Lines strictly between the previous
            // token's line and this one are blank/comment-only and carry the current depth.
            var blank = prev_line + 1;
            while (blank < tline) : (blank += 1) {
                if (blank < lines.len) lines[blank].indent_level = depth;
            }
            // Line `tline`'s level is the depth at its start, dedented if its first token closes
            // a bracket (so `}` aligns with its opener). Set once, never overwritten.
            if (tline < lines.len) {
                lines[tline].has_token = true;
                var level = depth;
                if (isCloser(tok.kind) and level > 0) level -= 1;
                lines[tline].indent_level = level;
            }
        }
        if (isOpener(tok.kind)) depth += 1;
        if (isCloser(tok.kind) and depth > 0) depth -= 1;
        prev_line = tline;
    }
    // Any trailing lines beyond the last token carry the final depth.
    var tail = prev_line + 1;
    while (tail < lines.len) : (tail += 1) lines[tail].indent_level = depth;
    return lines;
}

fn rtrim(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn ltrim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    return s[start..];
}

fn hasCommentStart(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "//") != null or std.mem.indexOf(u8, s, "/*") != null;
}

fn hasAmbiguousOperator(s: []const u8) bool {
    // `*` and `&` are both unary/type and binary tokens in MC. Keep those lines interior-stable
    // until the formatter has AST context.
    return std.mem.indexOfScalar(u8, s, '*') != null or std.mem.indexOfScalar(u8, s, '&') != null;
}

fn isWordLike(kind: token.Kind) bool {
    return switch (kind) {
        .identifier,
        .integer_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .underscore,
        .kw_alignof,
        .kw_asm,
        .kw_assert,
        .kw_atomic,
        .kw_bool,
        .kw_break,
        .kw_comptime,
        .kw_const,
        .kw_continue,
        .kw_defer,
        .kw_else,
        .kw_enum,
        .kw_closure,
        .kw_err,
        .kw_export,
        .kw_extern,
        .kw_false,
        .kw_fn,
        .kw_for,
        .kw_if,
        .kw_let,
        .kw_match,
        .kw_mut,
        .kw_never,
        .kw_null,
        .kw_ok,
        .kw_open,
        .kw_overlay,
        .kw_packed,
        .kw_pub,
        .kw_return,
        .kw_sat,
        .kw_serial,
        .kw_sizeof,
        .kw_struct,
        .kw_switch,
        .kw_true,
        .kw_type,
        .kw_union,
        .kw_uninit,
        .kw_unsafe,
        .kw_unreachable,
        .kw_use,
        .kw_var,
        .kw_void,
        .kw_while,
        .kw_wrap,
        => true,
        else => false,
    };
}

fn isBinarySpaced(kind: token.Kind) bool {
    return switch (kind) {
        .equal,
        .plus,
        .minus,
        .slash,
        .percent,
        .pipe,
        .caret,
        .equal_equal,
        .bang_equal,
        .less,
        .greater,
        .less_equal,
        .greater_equal,
        .amp_amp,
        .pipe_pipe,
        .shift_left,
        .shift_right,
        .arrow,
        .fat_arrow,
        => true,
        else => false,
    };
}

fn needsSpace(prev: token.Kind, cur: token.Kind) bool {
    if (prev == .l_paren or prev == .l_bracket) return false;
    if (cur == .r_paren or cur == .r_bracket or cur == .comma or cur == .semicolon) return false;
    if (prev == .l_brace) return cur != .r_brace;
    if (cur == .r_brace) return prev != .l_brace;
    if (cur == .l_brace) return prev != .dot;
    if (prev == .dot or cur == .dot or prev == .double_colon or cur == .double_colon) return false;
    if (prev == .hash or prev == .at) return false;
    if (cur == .l_paren or cur == .l_bracket) return false;
    if (cur == .colon) return false;
    if (prev == .colon or prev == .comma or prev == .semicolon) return true;
    if (isBinarySpaced(prev) or isBinarySpaced(cur)) return true;
    if (isWordLike(prev) and isWordLike(cur)) return true;
    return true;
}

fn appendNormalizedContent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, content: []const u8) !void {
    if (hasCommentStart(content) or hasAmbiguousOperator(content)) {
        try out.appendSlice(allocator, content);
        return;
    }

    var diag = diagnostics.Reporter.init(allocator, "<fmt-line>", content);
    defer diag.deinit();
    var lx = lexer.Lexer.init(content, &diag);
    var toks: std.ArrayList(token.Token) = .empty;
    defer toks.deinit(allocator);

    while (true) {
        const tok = lx.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .invalid) {
            try out.appendSlice(allocator, content);
            return;
        }
        try toks.append(allocator, tok);
    }
    if (diag.has_errors or toks.items.len == 0) {
        try out.appendSlice(allocator, content);
        return;
    }

    for (toks.items, 0..) |tok, i| {
        if (i > 0 and needsSpace(toks.items[i - 1].kind, tok.kind)) try out.append(allocator, ' ');
        try out.appendSlice(allocator, tok.lexeme);
    }
}

// Produce the canonically-formatted text. Caller owns the returned buffer.
pub fn format(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // Count source lines (1-based).
    var line_count: usize = 1;
    for (source) |c| {
        if (c == '\n') line_count += 1;
    }
    const levels = try computeLineLevels(allocator, source, line_count);
    defer allocator.free(levels);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var pending_blank = false; // a blank line is buffered; emit it only before real content
    var emitted_any = false;
    while (it.next()) |raw| {
        line_no += 1;
        const content = rtrim(ltrim(raw));
        if (content.len == 0) {
            // Collapse runs of blank lines to a single one, and never lead with a blank.
            if (emitted_any) pending_blank = true;
            continue;
        }
        if (pending_blank) {
            try out.append(allocator, '\n');
            pending_blank = false;
        }
        const level = if (line_no < levels.len) levels[line_no].indent_level else 0;
        var n: usize = 0;
        while (n < level) : (n += 1) try out.appendSlice(allocator, INDENT);
        try appendNormalizedContent(&out, allocator, content);
        try out.append(allocator, '\n');
        emitted_any = true;
    }
    return out.toOwnedSlice(allocator);
}
