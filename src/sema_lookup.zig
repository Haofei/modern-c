const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const sema_builtin = @import("sema_builtin.zig");
const sema_model = @import("sema_model.zig");
const sema_type = @import("sema_type.zig");

const Context = sema_model.Context;
const LayoutFieldInfo = sema_model.LayoutFieldInfo;

const classifyTypeName = sema_type.classifyTypeName;
const genericTypeExpectedArgs = sema_builtin.genericTypeExpectedArgs;
const isPrimitiveLayoutType = sema_type.isPrimitiveLayoutType;
const typeName = ast_query.typeName;

pub fn isKnownLayoutType(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (ty.kind) {
        .name => |name| isPrimitiveLayoutType(name.text) or
            knownStructName(name.text, ctx) or
            knownPackedBitsName(name.text, ctx) or
            knownOverlayUnionName(name.text, ctx) or
            knownTaggedUnionName(name.text, ctx) or
            knownEnumName(name.text, ctx) or
            // A `comptime T: type` parameter is layout-capable once monomorphized;
            // `sizeof(T)`/`alignof(T)` in a generic body resolve per instantiation.
            (if (ctx.type_params) |tp| tp.contains(name.text) else false),
        .pointer, .raw_many_pointer, .slice, .array, .nullable => true,
        .fn_pointer => true, // a function pointer has pointer layout
        .closure_type => true, // a closure is a fixed {code, env} aggregate
        .dyn_trait => true, // a *dyn Trait is a fixed {data, vtable} aggregate
        .qualified => |node| isKnownLayoutType(node.child.*, ctx),
        .generic => |node| isKnownLayoutGeneric(node, ctx),
        .member, .enum_literal => false,
    };
}

pub fn isKnownTypeName(name: []const u8, ctx: Context) bool {
    if (classifyTypeName(name) != .unknown) return true;
    if (std.mem.eql(u8, name, "Error")) return true;
    if (std.mem.eql(u8, name, "AmbiguousSerialOrder")) return true;
    if (std.mem.eql(u8, name, "AmbiguousCounterInterval")) return true;
    if (std.mem.eql(u8, name, "ConversionError")) return true;
    if (std.mem.eql(u8, name, "Overflow")) return true;
    // `type` is the meta-type of a `comptime T: type` parameter; `T` and friends
    // are valid type names inside the generic function (section 22).
    if (std.mem.eql(u8, name, "type")) return true;
    if (ctx.type_params) |tps| {
        if (tps.contains(name)) return true;
    }
    // IrqOff (§19.1): a capability type witnessing that interrupts are disabled.
    // A function requiring a disabled-interrupt critical section takes a
    // `cs: IrqOff` parameter, so the operation cannot be written without one.
    if (std.mem.eql(u8, name, "IrqOff")) return true;
    if (std.mem.eql(u8, name, "c_void")) return true;
    // `va_list` — the C-ABI varargs cursor type for the `va.*` interop intrinsics.
    if (std.mem.eql(u8, name, "va_list")) return true;
    if (knownStructName(name, ctx)) return true;
    if (knownPackedBitsName(name, ctx)) return true;
    if (knownOverlayUnionName(name, ctx)) return true;
    if (knownTaggedUnionName(name, ctx)) return true;
    if (knownEnumName(name, ctx)) return true;
    if (ctx.type_aliases) |type_aliases| {
        if (type_aliases.contains(name)) return true;
    }
    return false;
}

pub fn isPackedBitsTypeName(ty: ast.TypeExpr, ctx: Context) bool {
    const name = typeName(ty) orelse return false;
    return knownPackedBitsName(name, ctx);
}

pub fn knownMmioStructName(name: []const u8, ctx: Context) bool {
    const mmio_structs = ctx.mmio_structs orelse return false;
    return mmio_structs.contains(name);
}

pub fn knownStructName(name: []const u8, ctx: Context) bool {
    const structs = ctx.structs orelse return false;
    return structs.contains(name);
}

pub fn knownPackedBitsName(name: []const u8, ctx: Context) bool {
    const packed_bits = ctx.packed_bits orelse return false;
    return packed_bits.contains(name);
}

pub fn knownOverlayUnionName(name: []const u8, ctx: Context) bool {
    const overlay_unions = ctx.overlay_unions orelse return false;
    return overlay_unions.contains(name);
}

pub fn knownTaggedUnionName(name: []const u8, ctx: Context) bool {
    const tagged_unions = ctx.tagged_unions orelse return false;
    return tagged_unions.contains(name);
}

pub fn knownEnumName(name: []const u8, ctx: Context) bool {
    const enums = ctx.enums orelse return false;
    return enums.contains(name);
}

pub fn layoutFieldInfo(name: []const u8, ctx: Context) ?LayoutFieldInfo {
    if (ctx.structs) |structs| {
        if (structs.get(name)) |info| return .{ .fields = info.fields, .ordered = info.ordered, .repr = null };
    }
    if (ctx.packed_bits) |packed_bits| {
        if (packed_bits.get(name)) |info| return info;
    }
    if (ctx.overlay_unions) |overlay_unions| {
        if (overlay_unions.get(name)) |info| return info;
    }
    return null;
}

fn isKnownLayoutGeneric(node: anytype, ctx: Context) bool {
    const expected = genericTypeExpectedArgs(node.base.text) orelse userGenericTypeExpectedArgs(node.base.text, ctx) orelse return false;
    if (node.args.len != expected) return false;
    for (node.args) |arg| {
        if (arg.kind == .enum_literal) continue;
        if (!isKnownLayoutType(arg, ctx)) return false;
    }
    return true;
}

fn userGenericTypeExpectedArgs(name: []const u8, ctx: Context) ?usize {
    if (ctx.structs) |structs| {
        if (structs.get(name)) |info| {
            if (info.type_param_count > 0) return info.type_param_count;
        }
    }
    if (ctx.tagged_unions) |tagged_unions| {
        if (tagged_unions.get(name)) |info| {
            if (info.type_param_count > 0) return info.type_param_count;
        }
    }
    return null;
}
