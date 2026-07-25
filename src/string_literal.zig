const std = @import("std");

pub const DecodeError = error{
    InvalidStringLiteral,
    InvalidEscapeSequence,
};

/// Decode an MC string literal into caller-provided storage. The returned slice aliases `out`.
/// `out.len >= literal.len - 2` is always sufficient.
pub fn decodeInto(out: []u8, literal: []const u8) DecodeError![]u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"')
        return error.InvalidStringLiteral;
    const body = literal[1 .. literal.len - 1];
    if (out.len < body.len) return error.InvalidStringLiteral;

    var written: usize = 0;
    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        if (body[index] != '\\') {
            out[written] = body[index];
            written += 1;
            continue;
        }
        index += 1;
        if (index >= body.len) return error.InvalidEscapeSequence;
        out[written] = switch (body[index]) {
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            '0' => 0,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidEscapeSequence,
        };
        written += 1;
    }
    return out[0..written];
}

test "string literal decoding is shared and exact" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "dir\\module\".mc",
        try decodeInto(&storage, "\"dir\\\\module\\\".mc\""),
    );
    try std.testing.expectError(error.InvalidEscapeSequence, decodeInto(&storage, "\"bad\\q\""));
}
