// `mcc fmt` — a canonical source formatter for MC.
//
// The formatter is deliberately *token-preserving*: it only ever rewrites the leading
// indentation and trailing whitespace of each line (and collapses runs of blank lines /
// fixes the trailing newline). It never edits the interior of a line, so it cannot lose or
// reorder a single token — the formatted output lexes to exactly the same token sequence as
// the input. Indentation is recomputed from the bracket nesting depth derived from the token
// stream (so a `{`/`(`/`[` inside a string or comment never shifts indentation), four spaces
// per level, with a line whose first token closes a bracket dedented one level so `}` lines
// align with their opener. Comment-only and blank lines indent to the surrounding depth.
//
// This is a safe, idempotent baseline (`fmt(fmt(x)) == fmt(x)`); a full AST pretty-printer
// that also normalizes intra-line spacing can layer on later without changing the interface.

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
        try out.appendSlice(allocator, content);
        try out.append(allocator, '\n');
        emitted_any = true;
    }
    return out.toOwnedSlice(allocator);
}
