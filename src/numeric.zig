// Shared numeric-literal and integer-bounds primitives.
//
// These pure helpers parse MC integer/char literals and describe the value range of the
// fixed-width checked integer types. They were previously copied verbatim into `sema.zig`,
// `mir.zig`, and `lower_c.zig`; keeping one definition here means the frontend range check,
// the MIR optimizer's literal reasoning, and the C backend's literal emission can never drift
// apart on what a literal means or how wide a type is. Callers keep their own *type → bounds*
// keying (sema keys on `TypeClass`, MIR on a type-name string) and build on `signedBounds` /
// `maxUnsigned` here.

const std = @import("std");

const ast = @import("ast.zig");

/// A parsed integer-literal value as a sign plus magnitude, so the full unsigned and signed
/// ranges are representable without a 129th bit (e.g. `i64`'s `INT_MIN` is `negative` with
/// `magnitude == 2^63`).
pub const LiteralValue = struct {
    negative: bool,
    magnitude: u128,
};

pub const IntegerSuffix = enum {
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,

    pub fn typeName(self: IntegerSuffix) []const u8 {
        return @tagName(self);
    }

    pub fn bounds(self: IntegerSuffix) IntBounds {
        return switch (self) {
            .u8 => .{ .signed = false, .max = maxUnsigned(8) },
            .u16 => .{ .signed = false, .max = maxUnsigned(16) },
            .u32 => .{ .signed = false, .max = maxUnsigned(32) },
            .u64 => .{ .signed = false, .max = maxUnsigned(64) },
            .u128 => .{ .signed = false, .max = maxUnsigned(128) },
            .usize => .{ .signed = false, .max = maxUnsigned(64) },
            .i8 => signedBounds(8),
            .i16 => signedBounds(16),
            .i32 => signedBounds(32),
            .i64 => signedBounds(64),
            .i128 => signedBounds(128),
            .isize => signedBounds(64),
        };
    }
};

pub const ParsedIntegerLiteral = struct {
    magnitude: u128,
    suffix: ?IntegerSuffix,
};

/// The value range of a fixed-width checked integer type. `max` is the largest representable
/// value; `min_abs` is the magnitude of the most-negative value (`0` for unsigned types).
pub const IntBounds = struct {
    signed: bool,
    max: u128,
    min_abs: u128 = 0,
};

pub fn maxUnsigned(bits: u8) u128 {
    // A 128-bit shift is inexpressible (u128's shift amount is u7, 0..127), so the full u128
    // range is returned directly; narrower widths use the shift.
    if (bits >= 128) return std.math.maxInt(u128);
    return (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
}

pub fn maxSigned(bits: u8) u128 {
    return (@as(u128, 1) << @as(u7, @intCast(bits - 1))) - 1;
}

pub fn signedBounds(bits: u8) IntBounds {
    return .{
        .signed = true,
        .max = maxSigned(bits),
        .min_abs = @as(u128, 1) << @as(u7, @intCast(bits - 1)),
    };
}

pub fn integerSuffix(raw: []const u8) ?IntegerSuffix {
    inline for (std.meta.tags(IntegerSuffix)) |suffix| {
        if (std.mem.eql(u8, raw, suffix.typeName())) return suffix;
    }
    return null;
}

/// Parse and validate an MC integer literal. Separators are accepted only
/// between digits; a final `_<integer-type>` is retained as a semantic suffix.
pub fn parseIntegerLiteralParts(raw: []const u8) ?ParsedIntegerLiteral {
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    const digit_start: usize = if (std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X")) 2 else 0;
    const radix: u8 = if (digit_start == 2) 16 else 10;
    if (raw.len == digit_start) return null;

    var digit_end = raw.len;
    var suffix: ?IntegerSuffix = null;
    var suffix_pos = raw.len;
    while (suffix_pos > digit_start) {
        suffix_pos -= 1;
        if (raw[suffix_pos] != '_') continue;
        if (integerSuffix(raw[suffix_pos + 1 ..])) |found| {
            digit_end = suffix_pos;
            suffix = found;
        }
        break;
    }
    if (digit_end == digit_start) return null;

    var len: usize = 0;
    var previous_separator = false;
    for (raw[0..digit_end], 0..) |ch, index| {
        if (index < digit_start) {
            cleaned[len] = ch;
            len += 1;
            continue;
        }
        if (ch == '_') {
            if (index == digit_start or index + 1 == digit_end or previous_separator) return null;
            previous_separator = true;
            continue;
        }
        const valid_digit = if (radix == 16) std.ascii.isHex(ch) else std.ascii.isDigit(ch);
        if (!valid_digit) return null;
        previous_separator = false;
        cleaned[len] = ch;
        len += 1;
    }
    const magnitude = std.fmt.parseInt(u128, cleaned[0..len], 0) catch return null;
    return .{ .magnitude = magnitude, .suffix = suffix };
}

pub fn parseIntegerLiteral(raw: []const u8) ?u128 {
    return (parseIntegerLiteralParts(raw) orelse return null).magnitude;
}

/// `parseIntegerLiteral` narrowed to `usize` (array lengths, indices).
pub fn parseUsizeLiteral(literal: []const u8) ?usize {
    return std.math.cast(usize, parseIntegerLiteral(literal) orelse return null);
}

/// `parseIntegerLiteral` narrowed to `i128`, accepting MC digit separators.
pub fn parseI128Literal(raw: []const u8) ?i128 {
    return std.math.cast(i128, parseIntegerLiteral(raw) orelse return null);
}

/// The code-point value of a char literal (`'a'`, `'\n'`, …), or null if it is not a
/// single-character or recognized-escape literal.
pub fn parseCharLiteral(literal: []const u8) ?u128 {
    if (literal.len < 3 or literal[0] != '\'' or literal[literal.len - 1] != '\'') return null;
    const body = literal[1 .. literal.len - 1];
    if (body.len == 1) return body[0];
    if (body.len != 2 or body[0] != '\\') return null;
    return switch (body[1]) {
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        '0' => 0,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => null,
    };
}

/// Round `value` up to the next multiple of `alignment` (returning `value` when already
/// aligned), or null on a non-positive alignment or `i128` overflow.
pub fn alignForward(value: i128, alignment: i128) ?i128 {
    if (alignment <= 0) return null;
    const rem = @rem(value, alignment);
    if (rem == 0) return value;
    return std.math.add(i128, value, alignment - rem) catch null;
}

/// The signed-magnitude value of a constant integer expression — an integer or char literal,
/// possibly grouped or negated — or null if it is not a compile-time integer constant.
pub fn integerLiteralValue(expr: ast.Expr) ?LiteralValue {
    return switch (expr.kind) {
        .int_literal => |literal| if (parseIntegerLiteral(literal)) |magnitude| .{
            .negative = false,
            .magnitude = magnitude,
        } else null,
        .char_literal => |literal| if (parseCharLiteral(literal)) |value| .{
            .negative = false,
            .magnitude = value,
        } else null,
        .grouped => |inner| integerLiteralValue(inner.*),
        .unary => |node| {
            if (node.op != .neg) return null;
            const literal = integerLiteralValue(node.expr.*) orelse return null;
            if (literal.negative) return null;
            return .{ .negative = true, .magnitude = literal.magnitude };
        },
        else => null,
    };
}

test "integer literal parser separates suffixes and validates separators" {
    const typed = parseIntegerLiteralParts("0x20_u8").?;
    try std.testing.expectEqual(@as(u128, 32), typed.magnitude);
    try std.testing.expectEqual(IntegerSuffix.u8, typed.suffix.?);
    try std.testing.expectEqual(@as(u128, 0xabc), parseIntegerLiteral("0xAB_C").?);
    try std.testing.expectEqual(@as(u128, 123456), parseIntegerLiteral("123_456").?);

    const invalid = [_][]const u8{
        "1__2", "1_", "0x_1", "0x1_", "0x1__2", "1__u8", "1_u7",
    };
    for (invalid) |literal| try std.testing.expect(parseIntegerLiteralParts(literal) == null);
}
