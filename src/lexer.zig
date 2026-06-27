const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    reporter: *diagnostics.Reporter,

    pub fn init(source: []const u8, reporter: *diagnostics.Reporter) Lexer {
        return .{ .source = source, .reporter = reporter };
    }

    pub fn next(self: *Lexer) token.Token {
        self.skipSpaceAndComments();
        const start = self.mark();
        if (self.isAtEnd()) return self.make(.eof, start);

        const c = self.advance();
        if (isIdentStart(c)) return self.identifier(start);
        if (std.ascii.isDigit(c)) return self.integer(start);

        return switch (c) {
            '(' => self.make(.l_paren, start),
            ')' => self.make(.r_paren, start),
            '{' => self.make(.l_brace, start),
            '}' => self.make(.r_brace, start),
            '[' => self.make(.l_bracket, start),
            ']' => self.make(.r_bracket, start),
            ',' => self.make(.comma, start),
            ':' => if (self.match(':')) self.make(.double_colon, start) else self.make(.colon, start),
            ';' => self.make(.semicolon, start),
            '?' => self.make(.question, start),
            '#' => self.make(.hash, start),
            '@' => self.make(.at, start),
            '~' => self.make(.tilde, start),
            '^' => self.make(.caret, start),
            '+' => self.make(.plus, start),
            '%' => self.make(.percent, start),
            '.' => if (self.match('.')) (if (self.match('.')) self.make(.dot_dot_dot, start) else self.make(.dot_dot, start)) else self.make(.dot, start),
            '-' => if (self.match('>')) self.make(.arrow, start) else self.make(.minus, start),
            '=' => if (self.match('=')) self.make(.equal_equal, start) else if (self.match('>')) self.make(.fat_arrow, start) else self.make(.equal, start),
            '!' => if (self.match('=')) self.make(.bang_equal, start) else self.make(.bang, start),
            '<' => blk: {
                if (self.match('<')) break :blk self.make(.shift_left, start);
                break :blk if (self.match('=')) self.make(.less_equal, start) else self.make(.less, start);
            },
            '>' => blk: {
                if (self.match('>')) break :blk self.make(.shift_right, start);
                break :blk if (self.match('=')) self.make(.greater_equal, start) else self.make(.greater, start);
            },
            '&' => if (self.match('&')) self.make(.amp_amp, start) else self.make(.amp, start),
            '|' => if (self.match('|')) self.make(.pipe_pipe, start) else self.make(.pipe, start),
            '/' => self.make(.slash, start),
            '*' => self.make(.star, start),
            '"' => self.string(start),
            '\'' => self.char(start),
            else => blk: {
                self.reporter.err(self.spanFrom(start), "unexpected byte '{c}'", .{c});
                break :blk self.make(.invalid, start);
            },
        };
    }

    fn skipSpaceAndComments(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
                continue;
            }
            if (c == '/' and self.peekNext() == '/') {
                while (!self.isAtEnd() and self.peek() != '\n') _ = self.advance();
                continue;
            }
            if (c == '/' and self.peekNext() == '*') {
                const start = self.mark();
                _ = self.advance();
                _ = self.advance();
                while (!self.isAtEnd()) {
                    if (self.peek() == '*' and self.peekNext() == '/') {
                        _ = self.advance();
                        _ = self.advance();
                        break;
                    }
                    _ = self.advance();
                } else {
                    self.reporter.err(self.spanFrom(start), "unterminated block comment", .{});
                }
                continue;
            }
            break;
        }
    }

    fn identifier(self: *Lexer, start: Mark) token.Token {
        while (!self.isAtEnd() and isIdentContinue(self.peek())) _ = self.advance();
        const lexeme = self.source[start.offset..self.index];
        if (std.mem.eql(u8, lexeme, "_")) return self.make(.underscore, start);
        // `inf` and `nan` are IEEE floating constants, not identifiers: lex them as
        // float literals so they typecheck and lower like any other float literal
        // (their lexeme text is consumed by parseFloat / the C backend's float emitter).
        if (std.mem.eql(u8, lexeme, "inf") or std.mem.eql(u8, lexeme, "nan")) {
            return self.make(.float_literal, start);
        }
        return self.make(token.keywordKind(lexeme) orelse .identifier, start);
    }

    fn integer(self: *Lexer, start: Mark) token.Token {
        var base: IntegerBase = .decimal;
        if (self.source[start.offset] == '0' and (self.peek() == 'x' or self.peek() == 'X')) {
            _ = self.advance();
            base = .hex;
        }

        var saw_digit = base == .decimal;
        var last_was_underscore = false;
        var invalid = false;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isDigitForBase(c, base)) {
                saw_digit = true;
                last_was_underscore = false;
                _ = self.advance();
            } else if (c == '_') {
                if (isIdentStart(self.peekNext())) break;
                if (last_was_underscore) invalid = true;
                last_was_underscore = true;
                _ = self.advance();
            } else {
                break;
            }
        }

        if (!saw_digit or last_was_underscore) invalid = true;

        // Decimal fractional part makes this a floating-point literal. A `.` that
        // is not followed by a digit (e.g. `x.field`, `x.0`-style) stays integer.
        var is_float = false;
        if (base == .decimal and !self.isAtEnd() and self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
            is_float = true;
            _ = self.advance();
            last_was_underscore = false;
            var saw_fraction_digit = false;
            while (!self.isAtEnd()) {
                const c = self.peek();
                if (std.ascii.isDigit(c)) {
                    saw_fraction_digit = true;
                    last_was_underscore = false;
                    _ = self.advance();
                } else if (c == '_') {
                    if (isIdentStart(self.peekNext())) break;
                    if (last_was_underscore) invalid = true;
                    last_was_underscore = true;
                    _ = self.advance();
                } else {
                    break;
                }
            }
            if (!saw_fraction_digit or last_was_underscore) invalid = true;
        }

        // Decimal scientific-notation exponent (`1e5`, `1.5e-3`, `2E+10`): an `e`/`E`,
        // an optional sign, then one or more digits. Its presence makes the literal a float.
        if (base == .decimal and !self.isAtEnd() and (self.peek() == 'e' or self.peek() == 'E') and
            isExponentTail(self.peekNext(), self.peekAt(2)))
        {
            is_float = true;
            _ = self.advance();
            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
            last_was_underscore = false;
            var saw_exp_digit = false;
            while (!self.isAtEnd()) {
                const c = self.peek();
                if (std.ascii.isDigit(c)) {
                    saw_exp_digit = true;
                    last_was_underscore = false;
                    _ = self.advance();
                } else if (c == '_') {
                    if (isIdentStart(self.peekNext())) break;
                    if (last_was_underscore) invalid = true;
                    last_was_underscore = true;
                    _ = self.advance();
                } else {
                    break;
                }
            }
            if (!saw_exp_digit or last_was_underscore) invalid = true;
        }

        if (!self.isAtEnd() and self.peek() == '_') {
            _ = self.advance();
            if (!isIdentStart(self.peek())) {
                invalid = true;
            } else {
                while (!self.isAtEnd() and isIdentContinue(self.peek())) _ = self.advance();
            }
        } else if (!self.isAtEnd() and isIdentStart(self.peek())) {
            invalid = true;
            while (!self.isAtEnd() and isIdentContinue(self.peek())) _ = self.advance();
        }

        if (invalid) {
            if (is_float) {
                self.reporter.err(self.spanFrom(start), "invalid float literal", .{});
            } else {
                self.reporter.err(self.spanFrom(start), "invalid integer literal", .{});
            }
        }
        return self.make(if (is_float) .float_literal else .integer_literal, start);
    }

    fn string(self: *Lexer, start: Mark) token.Token {
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\n') {
                self.reporter.err(self.spanFrom(start), "unterminated string literal", .{});
                return self.make(.invalid, start);
            }
            if (self.peek() == '\\') {
                _ = self.advance();
                if (!self.consumeEscape(start)) return self.make(.invalid, start);
                continue;
            }
            _ = self.advance();
        }
        if (self.isAtEnd()) {
            self.reporter.err(self.spanFrom(start), "unterminated string literal", .{});
            return self.make(.invalid, start);
        }
        _ = self.advance();
        return self.make(.string_literal, start);
    }

    fn char(self: *Lexer, start: Mark) token.Token {
        var units: usize = 0;
        while (!self.isAtEnd() and self.peek() != '\'') {
            if (self.peek() == '\n') {
                self.reporter.err(self.spanFrom(start), "unterminated char literal", .{});
                return self.make(.invalid, start);
            }
            if (self.peek() == '\\') {
                _ = self.advance();
                if (!self.consumeEscape(start)) return self.make(.invalid, start);
                units += 1;
                continue;
            }
            _ = self.advance();
            units += 1;
        }
        if (self.isAtEnd()) {
            self.reporter.err(self.spanFrom(start), "unterminated char literal", .{});
            return self.make(.invalid, start);
        }
        _ = self.advance();
        if (units != 1) self.reporter.err(self.spanFrom(start), "invalid char literal", .{});
        return self.make(.char_literal, start);
    }

    fn consumeEscape(self: *Lexer, start: Mark) bool {
        if (self.isAtEnd()) {
            self.reporter.err(self.spanFrom(start), "unterminated escape sequence", .{});
            return false;
        }

        switch (self.peek()) {
            '\\', '\'', '"', '0', 'n', 'r', 't' => {
                _ = self.advance();
                return true;
            },
            else => {
                _ = self.advance();
                self.reporter.err(self.spanFrom(start), "invalid escape sequence", .{});
                return true;
            },
        }
    }

    fn make(self: *Lexer, kind: token.Kind, start: Mark) token.Token {
        return .{
            .kind = kind,
            .lexeme = self.source[start.offset..self.index],
            .span = self.spanFrom(start),
        };
    }

    fn spanFrom(self: *Lexer, start: Mark) diagnostics.Span {
        return .{
            .offset = start.offset,
            .len = self.index - start.offset,
            .line = start.line,
            .column = start.column,
        };
    }

    fn mark(self: *Lexer) Mark {
        return .{ .offset = self.index, .line = self.line, .column = self.column };
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: *Lexer) u8 {
        return if (self.isAtEnd()) 0 else self.source[self.index];
    }

    fn peekNext(self: *Lexer) u8 {
        return if (self.index + 1 >= self.source.len) 0 else self.source[self.index + 1];
    }

    fn peekAt(self: *Lexer, ahead: usize) u8 {
        return if (self.index + ahead >= self.source.len) 0 else self.source[self.index + ahead];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd() or self.peek() != expected) return false;
        _ = self.advance();
        return true;
    }
};

const Mark = struct {
    offset: usize,
    line: usize,
    column: usize,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

// True when an `e`/`E` begins a valid scientific-notation exponent: it is followed either by a
// digit (`e5`) or by a sign and a digit (`e+5`). Guards against treating an identifier suffix
// (e.g. a hypothetical `1ex`) as an exponent.
fn isExponentTail(first: u8, second: u8) bool {
    if (std.ascii.isDigit(first)) return true;
    if ((first == '+' or first == '-') and std.ascii.isDigit(second)) return true;
    return false;
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

const IntegerBase = enum {
    decimal,
    hex,
};

fn isDigitForBase(c: u8, base: IntegerBase) bool {
    return switch (base) {
        .decimal => std.ascii.isDigit(c),
        .hex => std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
    };
}
