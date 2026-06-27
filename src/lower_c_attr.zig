//! C backend attribute helpers.

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

pub fn emitFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: []const ast.Attr) !void {
    try emitLinkageFunctionAttrs(allocator, out, attrs);
    try emitLayoutFunctionAttrs(allocator, out, attrs);
    try emitInliningFunctionAttrs(allocator, out, attrs);
}

fn emitLinkageFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: []const ast.Attr) !void {
    if (hasWeakAttr(attrs)) try out.appendSlice(allocator, "MC_WEAK ");
    if (sectionAttr(attrs)) |sec| {
        try out.appendSlice(allocator, "__attribute__((section(\"");
        try out.appendSlice(allocator, sec);
        try out.appendSlice(allocator, "\"))) ");
    }
}

fn emitLayoutFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: []const ast.Attr) !void {
    if (effectiveAlign(attrs)) |al| {
        var buf: [32]u8 = undefined;
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "__attribute__((aligned({d}))) ", .{al}) catch unreachable);
    }
}

fn emitInliningFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: []const ast.Attr) !void {
    if (hasNoinlineAttr(attrs)) try out.appendSlice(allocator, "__attribute__((noinline)) ");
    if (hasNakedAttr(attrs)) try out.appendSlice(allocator, "__attribute__((naked)) ");
}

// The `#[section("...")]` target name, or null if the declaration has no section attribute.
pub fn sectionAttr(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| {
        if (attr.kind == .section) return attr.kind.section;
    }
    return null;
}

// The `#[backend_name("Y")]` override string for a declaration, if present.
pub fn backendNameOverride(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| {
        switch (attr.kind) {
            .backend_name => |name| return name,
            else => {},
        }
    }
    return null;
}

// Effective alignment for a function: the explicit `#[align(N)]` value if present, else 4 for
// a `#[naked]` function (trap-vector / entry code whose address is loaded into an
// alignment-sensitive register — e.g. a RISC-V `stvec`/`mtvec` base must be 4-byte aligned),
// else null (no alignment directive). Returns the larger of the two when both apply.
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
