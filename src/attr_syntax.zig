//! Narrow attribute-syntax helpers shared by codegen and declaration-artifact
//! collection.
//!
//! This module may inspect AST attributes while declaration artifacts are being
//! normalized. Backend modules should consume `codegen_attrs.FunctionRenderAttrs`
//! facts rather than re-scanning declaration attribute payloads.

const std = @import("std");

const ast = @import("ast.zig");
const codegen_attrs = @import("codegen_attrs.zig");

pub fn functionRenderAttrs(attrs: []const ast.Attr) codegen_attrs.FunctionRenderAttrs {
    return .{
        .naked = hasNakedAttr(attrs),
        .weak = hasWeakAttr(attrs),
        .noinline_attr = hasNoinlineAttr(attrs),
        .section = sectionAttr(attrs),
        .effective_align = effectiveAlign(attrs),
    };
}

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
