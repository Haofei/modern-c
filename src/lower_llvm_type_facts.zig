//! Syntax-free LLVM type rendering from verified module facts.
//!
//! This is intentionally independent of AST and declaration materialization:
//! module signature types plus checked declaration facts are the sole input.

const std = @import("std");
const mir = @import("mir_model.zig");
const scalar_repr = @import("scalar_repr.zig");

pub const Error = error{ InvalidType, UnsupportedType } || std.mem.Allocator.Error;

pub fn render(allocator: std.mem.Allocator, module: *const mir.Module, id: mir.SignatureTypeId) Error![]const u8 {
    const shape = module.signature_types.get(id) orelse return error.InvalidType;
    return switch (shape) {
        .name => |name| renderName(allocator, module, name),
        .qualified => |node| render(allocator, module, node.child),
        .pointer, .raw_many_pointer, .fn_pointer => "ptr",
        .slice => "{ ptr, i64 }",
        .array => |node| std.fmt.allocPrint(allocator, "[{d} x {s}]", .{ node.length orelse return error.UnsupportedType, try render(allocator, module, node.child) }),
        .nullable => |child| if (isPointerLike(module, child)) render(allocator, module, child) else std.fmt.allocPrint(allocator, "{{ i1, {s} }}", .{try render(allocator, module, child)}),
        .generic => |node| renderGeneric(allocator, module, node.base, node.args),
        .closure_type, .dyn_trait => "{ ptr, ptr }",
        .enum_literal, .member => error.UnsupportedType,
    };
}

pub fn isPointerLike(module: *const mir.Module, id: mir.SignatureTypeId) bool {
    const shape = module.signature_types.get(id) orelse return false;
    return switch (shape) {
        .pointer, .raw_many_pointer, .fn_pointer => true,
        .qualified => |node| isPointerLike(module, node.child),
        .name => |name| std.mem.eql(u8, name, "cstr") or std.mem.eql(u8, name, "va_list"),
        .generic => |node| std.mem.eql(u8, node.base, "MmioPtr") or std.mem.eql(u8, node.base, "UserPtr") or std.mem.eql(u8, node.base, "PhysPtr"),
        else => false,
    };
}

pub fn integerInfo(module: *const mir.Module, id: mir.SignatureTypeId) ?scalar_repr.Integer {
    const shape = module.signature_types.get(id) orelse return null;
    return switch (shape) {
        .qualified => |node| integerInfo(module, node.child),
        .name => |name| blk: {
            if (typeAlias(module, name)) |fact| break :blk integerInfo(module, fact.target_type_id);
            if (enumFact(module, name)) |fact| break :blk integerInfo(module, fact.repr_type_id);
            if (packedBitsFact(module, name)) |fact| break :blk integerInfo(module, fact.repr_type_id);
            break :blk scalar_repr.integer(name);
        },
        .generic => |node| if (isPayloadDomain(node.base) and node.args.len >= 1) integerInfo(module, node.args[0]) else null,
        else => null,
    };
}

pub fn isAggregateName(module: *const mir.Module, name: []const u8) bool {
    return structFact(module, name) != null or overlayFact(module, name) != null or taggedFact(module, name) != null;
}

/// Render a nominal or builtin spelling from the checked module namespace.
/// This is also used by the legacy executable-body renderer while it still
/// carries an AST type spelling; the declaration interpretation itself stays
/// entirely fact-owned.
pub fn renderName(allocator: std.mem.Allocator, module: *const mir.Module, name: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "cstr") or std.mem.eql(u8, name, "va_list")) return "ptr";
    if (std.mem.eql(u8, name, "bool")) return "i1";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    if (std.mem.eql(u8, name, "c_void") or std.mem.eql(u8, name, "IrqOff")) return "i8";
    if (std.mem.eql(u8, name, "PAddr") or std.mem.eql(u8, name, "VAddr") or std.mem.eql(u8, name, "DmaAddr")) return "i64";
    // A checked nominal fact wins over a scalar convention of the same
    // spelling.  In particular, user `enum Error: u16` must not inherit a
    // library `Error` scalar representation.
    if (typeAlias(module, name)) |fact| return render(allocator, module, fact.target_type_id);
    if (enumFact(module, name)) |fact| return render(allocator, module, fact.repr_type_id);
    if (packedBitsFact(module, name)) |fact| return render(allocator, module, fact.repr_type_id);
    if (overlayFact(module, name)) |fact| return std.fmt.allocPrint(allocator, "[{d} x i8]", .{fact.storage_size});
    if (taggedFact(module, name)) |fact| return taggedType(allocator, fact.layout);
    if (structFact(module, name)) |fact| return structType(allocator, module, fact);
    if (scalar_repr.integer(name)) |integer| return std.fmt.allocPrint(allocator, "i{d}", .{integer.bits});
    if (scalar_repr.isLibraryInteger(name)) return scalar_repr.integer(name).?.llvm_type;
    return error.UnsupportedType;
}

fn renderGeneric(allocator: std.mem.Allocator, module: *const mir.Module, base: []const u8, args: []const mir.SignatureTypeId) Error![]const u8 {
    if (std.mem.eql(u8, base, "Result") and args.len == 2) {
        const ok = if (isVoid(module, args[0])) "i8" else try render(allocator, module, args[0]);
        const err = if (isVoid(module, args[1])) "i8" else try render(allocator, module, args[1]);
        return std.fmt.allocPrint(allocator, "{{ i1, {s}, {s} }}", .{ ok, err });
    }
    if ((std.mem.eql(u8, base, "atomic") or std.mem.eql(u8, base, "MaybeUninit") or std.mem.eql(u8, base, "Reg") or std.mem.eql(u8, base, "RegBits") or isPayloadDomain(base)) and args.len >= 1)
        return render(allocator, module, args[0]);
    if (std.mem.eql(u8, base, "MmioPtr") and args.len == 1) return "ptr";
    if (std.mem.eql(u8, base, "DmaBuf") and args.len == 2) return "i64";
    if ((std.mem.eql(u8, base, "UserPtr") or std.mem.eql(u8, base, "PhysPtr")) and args.len >= 1) return "i64";
    return error.UnsupportedType;
}

fn structType(allocator: std.mem.Allocator, module: *const mir.Module, fact: mir.StructFact) Error![]const u8 {
    if (fact.is_c_union) {
        const size = fact.storage_size orelse return error.InvalidType;
        const alignment = fact.storage_alignment orelse return error.InvalidType;
        if (alignment == 0 or size == 0 or size % alignment != 0) return error.InvalidType;
        return std.fmt.allocPrint(allocator, "[{d} x i{d}]", .{ @max(@as(usize, 1), size / alignment), alignment * 8 });
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{ ");
    for (fact.fields, 0..) |field, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const type_id = if (fact.is_mmio) mmioStorageType(module, field.type_id) orelse return error.InvalidType else field.type_id;
        try out.appendSlice(allocator, try render(allocator, module, type_id));
    }
    try out.appendSlice(allocator, " }");
    return out.toOwnedSlice(allocator);
}

fn taggedType(allocator: std.mem.Allocator, layout: anytype) Error![]const u8 {
    const storage = try std.fmt.allocPrint(allocator, "[{d} x i{d}]", .{ layout.storage_count, layout.payload_alignment * 8 });
    return if (layout.padding_size == 0) std.fmt.allocPrint(allocator, "{{ i32, {s} }}", .{storage}) else std.fmt.allocPrint(allocator, "{{ i32, [{d} x i8], {s} }}", .{ layout.padding_size, storage });
}

fn mmioStorageType(module: *const mir.Module, id: mir.SignatureTypeId) ?mir.SignatureTypeId {
    return switch (module.signature_types.get(id) orelse return null) {
        .generic => |node| if ((std.mem.eql(u8, node.base, "Reg") and node.args.len == 2) or (std.mem.eql(u8, node.base, "RegBits") and node.args.len == 3)) node.args[0] else null,
        else => null,
    };
}

fn isVoid(module: *const mir.Module, id: mir.SignatureTypeId) bool {
    return switch (module.signature_types.get(id) orelse return false) {
        .name => |name| std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never"),
        .qualified => |node| isVoid(module, node.child),
        else => false,
    };
}

pub fn isPayloadDomain(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or std.mem.eql(u8, name, "sat") or std.mem.eql(u8, name, "serial") or std.mem.eql(u8, name, "counter") or std.mem.eql(u8, name, "Duration") or std.mem.eql(u8, name, "Secret");
}

pub fn isOpaqueAddressGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "UserPtr") or std.mem.eql(u8, name, "PhysPtr");
}

pub fn isOpaqueAddressName(name: []const u8) bool {
    return std.mem.eql(u8, name, "PAddr") or std.mem.eql(u8, name, "VAddr") or std.mem.eql(u8, name, "DmaAddr");
}

pub fn intrinsicBits(name: []const u8) ?u16 {
    if (std.mem.endsWith(u8, name, ".i8")) return 8;
    if (std.mem.endsWith(u8, name, ".i16")) return 16;
    if (std.mem.endsWith(u8, name, ".i32")) return 32;
    if (std.mem.endsWith(u8, name, ".i64")) return 64;
    return null;
}

fn spelling(module: *const mir.Module, id: mir.SymbolId) ?[]const u8 {
    if (!id.isValid() or id.index() >= module.symbol_identities.len) return null;
    const identity = module.symbol_identities[id.index()];
    return if (identity.id.eql(id) and identity.kind == .type_) identity.spelling else null;
}

pub fn typeAlias(module: *const mir.Module, name: []const u8) ?mir.TypeAliasFact {
    for (module.type_aliases) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
pub fn enumFact(module: *const mir.Module, name: []const u8) ?mir.EnumFact {
    for (module.enums) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
pub fn packedBitsFact(module: *const mir.Module, name: []const u8) ?mir.PackedBitsFact {
    for (module.packed_bits) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
pub fn overlayFact(module: *const mir.Module, name: []const u8) ?mir.OverlayUnionFact {
    for (module.overlay_unions) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
pub fn taggedFact(module: *const mir.Module, name: []const u8) ?mir.TaggedUnionFact {
    for (module.tagged_unions) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
pub fn structFact(module: *const mir.Module, name: []const u8) ?mir.StructFact {
    for (module.structs) |fact| if (spelling(module, fact.symbol_id)) |value| if (std.mem.eql(u8, value, name)) return fact;
    return null;
}
