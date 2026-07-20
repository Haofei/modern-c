const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

pub const hasNoLangTrap = ast_query.hasNoLangTrap;

// Whether a declaration is part of its module's PUBLIC surface: explicitly `pub`, an
// `export fn` (external linkage), or an `extern` declaration (an external symbol). Anything
// else in a strict module is file-private.
pub fn declIsPublic(decl: ast.Decl) bool {
    if (decl.is_pub) return true;
    return switch (decl.kind) {
        .fn_decl => |f| f.exported,
        .extern_fn => true,
        else => false,
    };
}

pub fn declName(decl: ast.Decl) ast.Ident {
    return switch (decl.kind) {
        .fn_decl, .extern_fn => |fn_decl| fn_decl.name,
        .type_alias => |alias| alias.name,
        .struct_decl => |struct_decl| struct_decl.name,
        .enum_decl => |enum_decl| enum_decl.name,
        .union_decl => |union_decl| union_decl.name,
        .packed_bits_decl => |packed_bits| packed_bits.name,
        .overlay_union_decl => |overlay_union| overlay_union.name,
        .opaque_decl => |name| name,
        .global_decl => |global| global.name,
        .trait_decl => |t| t.name,
        // impl_trait is filtered out before declName is called.
        .impl_trait => |it| it.trait_name,
    };
}

// A declaration that introduces a value-level top-level name (function or global), as opposed
// to a type-level name. Used to reserve qualified-owner names against value shadows.
pub fn isValueLevelDecl(kind: ast.Decl.Kind) bool {
    return switch (kind) {
        .fn_decl, .extern_fn, .global_decl => true,
        else => false,
    };
}

pub fn findImplMethod(methods: []const ast.ImplTraitMethod, name: []const u8) ?ast.ImplTraitMethod {
    for (methods) |m| {
        if (std.mem.eql(u8, m.name.text, name)) return m;
    }
    return null;
}

pub fn findTraitMethod(methods: []const ast.TraitMethodSig, name: []const u8) ?ast.TraitMethodSig {
    for (methods) |m| {
        if (std.mem.eql(u8, m.name.text, name)) return m;
    }
    return null;
}

// A trait is object-safe (usable as `*dyn Trait`, traits-design section 5) iff every method
// takes `self` by pointer and is non-generic.
pub fn traitIsObjectSafe(t: ast.TraitDecl) bool {
    for (t.methods) |m| {
        switch (m.self_mode) {
            .by_ptr, .by_mut_ptr => {},
            else => return false,
        }
        for (m.params) |p| {
            if (p.is_comptime) return false;
        }
    }
    return true;
}

pub fn hasNaked(attrs: []ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .naked) return true;
    }
    return false;
}

pub fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
        else => {},
    };
    return false;
}

pub fn hasIrqContext(attrs: []ast.Attr) bool {
    return hasNamedAttr(attrs, "irq_context") or hasNamedAttr(attrs, "atomic_context");
}

pub fn hasMaySleep(attrs: []ast.Attr) bool {
    return hasNamedAttr(attrs, "may_sleep");
}

pub fn hasBoundedContext(attrs: []ast.Attr) bool {
    return hasIrqContext(attrs) or hasNamedAttr(attrs, "bounded");
}

pub fn backendNameAttr(attrs: []ast.Attr) ?[]const u8 {
    for (attrs) |attr| switch (attr.kind) {
        .backend_name => |name| return name,
        else => {},
    };
    return null;
}

// Whether a declaration carries `#[trivial_drop]` (the author's assertion that a `move`
// resource's completion needs no release, making `drop` of it a safe final use).
pub fn declHasTrivialDrop(decl: ast.Decl) bool {
    for (decl.attrs) |attr| {
        switch (attr.kind) {
            .named => |n| if (std.mem.eql(u8, n.text, "trivial_drop")) return true,
            else => {},
        }
    }
    return false;
}
