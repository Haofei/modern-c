const std = @import("std");

const ast = @import("ast.zig");

pub fn hasNakedAttr(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .naked) return true;
    }
    return false;
}

pub fn hasWeakAttr(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .weak) return true;
    }
    return false;
}

pub fn hasNoinlineAttr(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .@"noinline") return true;
    }
    return false;
}

// The `#[section("...")]` target name, or null if the declaration has no section attribute.
pub fn sectionAttr(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| {
        if (attr.kind == .section) return attr.kind.section;
    }
    return null;
}

// Effective alignment for a function: the explicit `#[align(N)]` value if present, else 4 for a
// `#[naked]` function. When both apply, the larger wins. Mirrors lower_c.zig's effectiveAlign so
// the backends stay in parity.
pub fn effectiveAlign(attrs: []const ast.Attr) ?u32 {
    var explicit: ?u32 = null;
    for (attrs) |attr| {
        if (attr.kind == .@"align") explicit = attr.kind.@"align";
    }
    const naked_min: ?u32 = if (hasNakedAttr(attrs)) 4 else null;
    if (explicit) |e| {
        if (naked_min) |n| return @max(e, n);
        return e;
    }
    return naked_min;
}

pub fn debugLine(span: ast.Span) usize {
    return if (span.line == 0) 1 else span.line;
}

pub fn debugColumn(span: ast.Span) usize {
    return if (span.column == 0) 1 else span.column;
}

pub fn escapedLlvmString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        switch (ch) {
            '\\' => try escaped.appendSlice(allocator, "\\5C"),
            '"' => try escaped.appendSlice(allocator, "\\22"),
            '\n' => try escaped.appendSlice(allocator, "\\0A"),
            '\r' => try escaped.appendSlice(allocator, "\\0D"),
            '\t' => try escaped.appendSlice(allocator, "\\09"),
            else => try escaped.append(allocator, ch),
        }
    }
    return escaped.toOwnedSlice(allocator);
}

pub const LlvmStringBytes = struct {
    escaped: []const u8,
    len: usize,
};

pub fn llvmAsmTemplate(allocator: std.mem.Allocator, templates: []const []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (templates, 0..) |template, i| {
        if (i != 0) try escaped.appendSlice(allocator, "\\0A\\09");
        try appendLlvmStringLiteralBody(allocator, &escaped, template, null);
    }
    return escaped.toOwnedSlice(allocator);
}

// Opaque (operand-less, incl. `#[naked]`) asm: like `llvmAsmTemplate`, but a literal `$` must be
// escaped to `$$` for LLVM IR inline asm, where a single `$` introduces an operand reference.
pub fn llvmOpaqueAsmTemplate(allocator: std.mem.Allocator, templates: []const []const u8) ![]const u8 {
    const template = try llvmAsmTemplate(allocator, templates);
    var converted: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        // `%%reg` (GCC-extended-asm escaping) -> a single `%reg` in LLVM IR inline asm.
        if (template[i] == '%' and i + 1 < template.len and template[i + 1] == '%') {
            try converted.append(allocator, '%');
            i += 2;
            continue;
        }
        if (template[i] == '$') {
            try converted.appendSlice(allocator, "$$");
            i += 1;
            continue;
        }
        try converted.append(allocator, template[i]);
        i += 1;
    }
    return converted.toOwnedSlice(allocator);
}

pub fn llvmPreciseAsmTemplate(allocator: std.mem.Allocator, templates: []const []const u8) ![]const u8 {
    const template = try llvmAsmTemplate(allocator, templates);
    var converted: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        // `%N` operand reference -> LLVM `$N`.
        if (template[i] == '%' and i + 1 < template.len and std.ascii.isDigit(template[i + 1])) {
            try converted.append(allocator, '$');
            i += 1;
            while (i < template.len and std.ascii.isDigit(template[i])) : (i += 1) {
                try converted.append(allocator, template[i]);
            }
            continue;
        }
        // `%%` literal-percent -> a single `%` in LLVM IR inline asm.
        if (template[i] == '%' and i + 1 < template.len and template[i + 1] == '%') {
            try converted.append(allocator, '%');
            i += 2;
            continue;
        }
        if (template[i] == '$') {
            try converted.appendSlice(allocator, "$$");
            i += 1;
            continue;
        }
        try converted.append(allocator, template[i]);
        i += 1;
    }
    return converted.toOwnedSlice(allocator);
}

pub fn llvmAsmClobbers(allocator: std.mem.Allocator, clobbers: []const []const u8) ![]const u8 {
    var constraints: std.ArrayList(u8) = .empty;
    if (clobbers.len == 0) {
        try constraints.appendSlice(allocator, "~{memory}");
        return constraints.toOwnedSlice(allocator);
    }
    for (clobbers, 0..) |clobber, i| {
        const name = try stringLiteralText(allocator, clobber);
        if (i != 0) try constraints.append(allocator, ',');
        try constraints.print(allocator, "~{{{s}}}", .{name});
    }
    return constraints.toOwnedSlice(allocator);
}

pub fn llvmPreciseAsmConstraints(allocator: std.mem.Allocator, asm_stmt: ast.AsmStmt) ![]const u8 {
    var constraints: std.ArrayList(u8) = .empty;
    var first = true;
    for (asm_stmt.outputs) |_| {
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.appendSlice(allocator, "=r");
    }
    for (asm_stmt.inputs) |_| {
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.append(allocator, 'r');
    }
    for (asm_stmt.clobbers) |clobber| {
        const name = try stringLiteralText(allocator, clobber);
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.print(allocator, "~{{{s}}}", .{name});
    }
    return constraints.toOwnedSlice(allocator);
}

pub fn llvmStringLiteralBytes(allocator: std.mem.Allocator, literal: []const u8) !LlvmStringBytes {
    var escaped: std.ArrayList(u8) = .empty;
    var len: usize = 0;
    try appendLlvmStringLiteralBody(allocator, &escaped, literal, &len);
    try appendLlvmStringByte(allocator, &escaped, 0);
    len += 1;
    return .{ .escaped = try escaped.toOwnedSlice(allocator), .len = len };
}

fn stringLiteralText(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    try appendLlvmStringLiteralBody(allocator, &escaped, literal, null);
    return escaped.toOwnedSlice(allocator);
}

fn appendLlvmStringLiteralBody(allocator: std.mem.Allocator, escaped: *std.ArrayList(u8), literal: []const u8, maybe_len: ?*usize) !void {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return error.UnsupportedLlvmEmission;
    var i: usize = 1;
    while (i + 1 < literal.len) {
        const byte = if (literal[i] == '\\') blk: {
            i += 1;
            if (i + 1 >= literal.len) return error.UnsupportedLlvmEmission;
            break :blk switch (literal[i]) {
                '\\' => @as(u8, '\\'),
                '\'' => @as(u8, '\''),
                '"' => @as(u8, '"'),
                '0' => @as(u8, 0),
                'n' => @as(u8, '\n'),
                'r' => @as(u8, '\r'),
                't' => @as(u8, '\t'),
                else => return error.UnsupportedLlvmEmission,
            };
        } else literal[i];
        try appendLlvmStringByte(allocator, escaped, byte);
        if (maybe_len) |len| len.* += 1;
        i += 1;
    }
}

fn appendLlvmStringByte(allocator: std.mem.Allocator, escaped: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '\\' => try escaped.appendSlice(allocator, "\\5C"),
        '"' => try escaped.appendSlice(allocator, "\\22"),
        0 => try escaped.appendSlice(allocator, "\\00"),
        32...33, 35...91, 93...126 => try escaped.append(allocator, byte),
        else => {
            try escaped.append(allocator, '\\');
            try escaped.append(allocator, hexDigit(byte >> 4));
            try escaped.append(allocator, hexDigit(byte & 0x0f));
        },
    }
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}
