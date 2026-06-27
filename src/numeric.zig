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

/// Parse an integer literal's magnitude, stripping `_` digit-group separators. Every `_` is
/// dropped and the full magnitude parsed; we do NOT break at `_<letter>`, because in a hex
/// literal the letter can be a hex digit (`0xAB_C` == 0xABC) — treating it as a type-suffix
/// boundary truncated the value and let an out-of-range literal slip past the range check into
/// a narrower, truncating C emission. Matches the C backend and `eval.zig`.
pub fn parseIntegerLiteral(raw: []const u8) ?u128 {
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        cleaned[len] = ch;
        len += 1;
    }
    return std.fmt.parseInt(u128, cleaned[0..len], 0) catch null;
}

/// `parseIntegerLiteral` narrowed to `usize` (array lengths, indices).
pub fn parseUsizeLiteral(literal: []const u8) ?usize {
    var cleaned: [128]u8 = undefined;
    if (literal.len > cleaned.len) return null;
    var len: usize = 0;
    for (literal) |ch| {
        if (ch != '_') {
            cleaned[len] = ch;
            len += 1;
        }
    }
    return std.fmt.parseInt(usize, cleaned[0..len], 0) catch null;
}

/// `parseIntegerLiteral` narrowed to `i128`, accepting MC digit separators.
pub fn parseI128Literal(raw: []const u8) ?i128 {
    var cleaned: [160]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch != '_') {
            cleaned[len] = ch;
            len += 1;
        }
    }
    return std.fmt.parseInt(i128, cleaned[0..len], 0) catch null;
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
