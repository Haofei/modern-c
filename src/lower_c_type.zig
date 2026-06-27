//! C backend — scalar/primitive type mapping helpers.
//!
//! Pure (no `CEmitter` state) helpers that map MC scalar/primitive types to
//! their C spellings and classify C keywords. Extracted from `lower_c.zig`
//! verbatim as part of the Phase-2a structural split; behavior is unchanged.
//! Call sites in the spine reference these through re-export aliases.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_model = @import("lower_c_model.zig");

const typeName = ast_query.typeName;
const isOpaqueAddressTypeName = ast_query.isOpaqueAddressTypeName;

const MmioStruct = lower_c_model.MmioStruct;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const StructTypeStyle = lower_c_model.StructTypeStyle;

pub const SliceTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8;
pub const ArrayTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, len_expr: ast.Expr) anyerror![]const u8;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8;
pub const TypeNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const DynTypeNameFn = *const fn (ctx: *anyopaque, trait_name: []const u8) anyerror![]const u8;

pub const TypeEmitContext = struct {
    scratch: std.mem.Allocator,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    enums: *const std.StringHashMap(ast.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    structs: *const std.StringHashMap(ast.StructDecl),
    mmio_structs: *const std.StringHashMap(MmioStruct),
    fn_ptr_types: *std.StringHashMap(ast.TypeExpr),
    closure_types: *std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    slice_type_name: SliceTypeNameFn,
    array_type_name: ArrayTypeNameFn,
    result_type_name: ResultTypeNameFn,
    fn_ptr_type_name: TypeNameFn,
    closure_type_name: TypeNameFn,
    dyn_type_name: DynTypeNameFn,
};

pub fn appendType(ctx: TypeEmitContext, out: *std.ArrayList(u8), ty: ast.TypeExpr, style: StructTypeStyle) anyerror!void {
    if (lower_c_alias.aliasTargetType(ctx.type_aliases, ty)) |target| return appendType(ctx, out, target, style);
    switch (ty.kind) {
        .pointer => |node| return appendPointerType(ctx, out, node.child.*, node.mutability, style),
        .raw_many_pointer => |node| return appendPointerType(ctx, out, node.child.*, node.mutability, style),
        .slice => |node| return out.appendSlice(ctx.scratch, try ctx.slice_type_name(ctx.emit_ctx, node.child.*, node.mutability)),
        .array => |node| return out.appendSlice(ctx.scratch, try ctx.array_type_name(ctx.emit_ctx, node.child.*, node.len)),
        .nullable => |child| return appendType(ctx, out, child.*, style),
        .qualified => |node| return appendType(ctx, out, node.child.*, style),
        .generic => |node| {
            if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                return out.appendSlice(ctx.scratch, try ctx.result_type_name(ctx.emit_ctx, node.args[0], node.args[1]));
            }
            if ((std.mem.eql(u8, node.base.text, "wrap") or
                std.mem.eql(u8, node.base.text, "sat") or
                std.mem.eql(u8, node.base.text, "serial") or
                std.mem.eql(u8, node.base.text, "counter") or
                // `Secret<T>` is a transparent constant-time tag: it emits as T.
                std.mem.eql(u8, node.base.text, "Secret") or
                std.mem.eql(u8, node.base.text, "Duration")) and node.args.len == 1)
            {
                return appendType(ctx, out, node.args[0], style);
            }
            if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1) {
                return appendType(ctx, out, node.args[0], style);
            }
            if (std.mem.eql(u8, node.base.text, "MaybeUninit") and node.args.len == 1) {
                return appendType(ctx, out, node.args[0], style);
            }
            if ((std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits")) and node.args.len >= 1) {
                return appendType(ctx, out, node.args[0], style);
            }
            if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2) {
                return appendPointerType(ctx, out, node.args[0], .mut, style);
            }
            if (std.mem.eql(u8, node.base.text, "UserPtr") or std.mem.eql(u8, node.base.text, "PhysPtr")) {
                return out.appendSlice(ctx.scratch, "uintptr_t");
            }
            if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1) {
                const pointee = typeName(node.args[0]) orelse return out.appendSlice(ctx.scratch, "void *");
                if (ctx.mmio_structs.contains(pointee)) {
                    try out.appendSlice(ctx.scratch, pointee);
                    return out.appendSlice(ctx.scratch, " volatile *");
                }
            }
        },
        .fn_pointer => {
            const name = try ctx.fn_ptr_type_name(ctx.emit_ctx, ty);
            if (!ctx.fn_ptr_types.contains(name)) try ctx.fn_ptr_types.put(name, ty);
            return out.appendSlice(ctx.scratch, name);
        },
        .closure_type => {
            const name = try ctx.closure_type_name(ctx.emit_ctx, ty);
            if (!ctx.closure_types.contains(name)) try ctx.closure_types.put(name, ty);
            return out.appendSlice(ctx.scratch, name);
        },
        // A `*dyn Trait` lowers to its fat-pointer typedef `mc_dyn_Trait`
        // (`struct { void *data; const VT_Trait *vtable; }`).
        .dyn_trait => |node| return out.appendSlice(ctx.scratch, try ctx.dyn_type_name(ctx.emit_ctx, node.trait_name.text)),
        else => {},
    }
    if (typeName(ty)) |name| {
        if (std.mem.eql(u8, name, "c_void")) return out.appendSlice(ctx.scratch, "void");
        if (ctx.enums.contains(name)) return out.appendSlice(ctx.scratch, name);
        if (ctx.packed_bits.contains(name)) return out.appendSlice(ctx.scratch, name);
        if (ctx.overlay_unions.contains(name)) return out.appendSlice(ctx.scratch, name);
        if (ctx.tagged_unions.contains(name)) return out.appendSlice(ctx.scratch, name);
        if (ctx.structs.contains(name)) {
            if (style == .struct_tag) try out.appendSlice(ctx.scratch, "struct ");
            return out.appendSlice(ctx.scratch, name);
        }
    }
    try out.appendSlice(ctx.scratch, cType(ty));
}

pub fn appendPointerType(ctx: TypeEmitContext, out: *std.ArrayList(u8), child: ast.TypeExpr, mutability: ast.Mutability, style: StructTypeStyle) anyerror!void {
    try appendType(ctx, out, child, style);
    if (mutability == .@"const") {
        try out.appendSlice(ctx.scratch, " const *");
    } else {
        try out.appendSlice(ctx.scratch, " *");
    }
}

pub fn cType(ty: ast.TypeExpr) []const u8 {
    switch (ty.kind) {
        .pointer => |node| return ptrCType(node.child.*, node.mutability),
        .raw_many_pointer => |node| return ptrCType(node.child.*, node.mutability),
        .slice => |node| return ptrCType(node.child.*, node.mutability),
        .array => |node| return ptrCType(node.child.*, .none),
        .nullable => |child| return cType(child.*),
        else => {},
    }
    const name = typeName(ty) orelse return "void *";
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "c_void")) return "void";
    if (std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "u8")) return "uint8_t";
    if (std.mem.eql(u8, name, "u16")) return "uint16_t";
    if (std.mem.eql(u8, name, "u32")) return "uint32_t";
    if (std.mem.eql(u8, name, "u64")) return "uint64_t";
    if (std.mem.eql(u8, name, "u128")) return "unsigned __int128";
    if (std.mem.eql(u8, name, "usize")) return "uintptr_t";
    if (isOpaqueAddressTypeName(name)) return "uintptr_t";
    // IrqOff (§19.1) capability token: a 1-byte witness value.
    if (std.mem.eql(u8, name, "IrqOff")) return "uint8_t";
    if (std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "i128")) return "__int128";
    if (std.mem.eql(u8, name, "isize")) return "intptr_t";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    // Library result/order types (sections 5.4, 5.5). Order is a three-way
    // comparison (-1/0/+1); the ambiguity error types carry no payload.
    if (std.mem.eql(u8, name, "Order")) return "int8_t";
    if (std.mem.eql(u8, name, "AmbiguousSerialOrder")) return "uint8_t";
    if (std.mem.eql(u8, name, "AmbiguousCounterInterval")) return "uint8_t";
    if (std.mem.eql(u8, name, "ConversionError")) return "uint8_t";
    if (std.mem.eql(u8, name, "Overflow")) return "uint8_t";
    if (std.mem.eql(u8, name, "va_list")) return "__builtin_va_list";
    return "void *";
}

// Is `ty` the `va_list` named type? (Used to copy va_list temps with __builtin_va_copy rather
// than `=`, which is ill-formed for x86-64's array-typed __builtin_va_list.)
pub fn isVaListType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |n| std.mem.eql(u8, n.text, "va_list"),
        else => false,
    };
}

pub fn checkedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8")) return "u8";
    if (std.mem.eql(u8, name, "u16")) return "u16";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "u64")) return "u64";
    if (std.mem.eql(u8, name, "u128")) return "u128";
    if (std.mem.eql(u8, name, "usize")) return "usize";
    if (std.mem.eql(u8, name, "i8")) return "i8";
    if (std.mem.eql(u8, name, "i16")) return "i16";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "i64")) return "i64";
    if (std.mem.eql(u8, name, "i128")) return "i128";
    if (std.mem.eql(u8, name, "isize")) return "isize";
    return null;
}

// Scalar element types valid for `raw.load`/`raw.store`. A superset of the
// checked-arithmetic scalars: it also admits the IEEE floats `f32`/`f64`, which
// are legal raw memory cells (the round-trip float-buffer kernel reads/writes
// them) even though they have no checked-arithmetic helpers.
pub fn rawScalarSuffix(name: []const u8) ?[]const u8 {
    if (checkedTypeSuffix(name)) |s| return s;
    if (std.mem.eql(u8, name, "f32")) return "f32";
    if (std.mem.eql(u8, name, "f64")) return "f64";
    return null;
}

pub fn unsignedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8")) return "u8";
    if (std.mem.eql(u8, name, "u16")) return "u16";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "u64")) return "u64";
    if (std.mem.eql(u8, name, "u128")) return "u128";
    if (std.mem.eql(u8, name, "usize")) return "usize";
    return null;
}

pub fn signedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "i8")) return "i8";
    if (std.mem.eql(u8, name, "i16")) return "i16";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "i64")) return "i64";
    if (std.mem.eql(u8, name, "i128")) return "i128";
    if (std.mem.eql(u8, name, "isize")) return "isize";
    return null;
}

pub const IntTypeRange = struct {
    min: i128,
    max: i128,
    c_min: []const u8,
    c_max: []const u8,
};

// Value ranges for the scalar integer types, used to elide unnecessary bound
// checks in `trap_from`/`sat_from` lowering. `usize`/`isize` are treated as
// 64-bit for elision; the emitted bounds use the portable limit macros.
pub fn intTypeRange(name: []const u8) ?IntTypeRange {
    if (std.mem.eql(u8, name, "u8")) return .{ .min = 0, .max = 255, .c_min = "0", .c_max = "UINT8_MAX" };
    if (std.mem.eql(u8, name, "u16")) return .{ .min = 0, .max = 65535, .c_min = "0", .c_max = "UINT16_MAX" };
    if (std.mem.eql(u8, name, "u32")) return .{ .min = 0, .max = 4294967295, .c_min = "0", .c_max = "UINT32_MAX" };
    if (std.mem.eql(u8, name, "u64")) return .{ .min = 0, .max = 18446744073709551615, .c_min = "0", .c_max = "UINT64_MAX" };
    if (std.mem.eql(u8, name, "usize")) return .{ .min = 0, .max = 18446744073709551615, .c_min = "0", .c_max = "UINTPTR_MAX" };
    if (std.mem.eql(u8, name, "i8")) return .{ .min = -128, .max = 127, .c_min = "INT8_MIN", .c_max = "INT8_MAX" };
    if (std.mem.eql(u8, name, "i16")) return .{ .min = -32768, .max = 32767, .c_min = "INT16_MIN", .c_max = "INT16_MAX" };
    if (std.mem.eql(u8, name, "i32")) return .{ .min = -2147483648, .max = 2147483647, .c_min = "INT32_MIN", .c_max = "INT32_MAX" };
    if (std.mem.eql(u8, name, "i64")) return .{ .min = -9223372036854775808, .max = 9223372036854775807, .c_min = "INT64_MIN", .c_max = "INT64_MAX" };
    if (std.mem.eql(u8, name, "isize")) return .{ .min = -9223372036854775808, .max = 9223372036854775807, .c_min = "INTPTR_MIN", .c_max = "INTPTR_MAX" };
    return null;
}

pub fn signedMinMacroForInner(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return "INT8_MIN";
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "INT16_MIN";
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "INT32_MIN";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return "INT64_MIN";
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "INTPTR_MIN";
    return null;
}

pub fn signedCTypeForInner(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "intptr_t";
    return null;
}

pub fn isCReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{
        // C keywords (C11).
        "auto",     "break",      "case",           "char",          "const",
        "continue", "default",    "do",             "double",        "else",
        "enum",     "extern",     "float",          "for",           "goto",
        "if",       "inline",     "int",            "long",          "register",
        "restrict", "return",     "short",          "signed",        "sizeof",
        "static",   "struct",     "switch",         "typedef",       "union",
        "unsigned", "void",       "volatile",       "while",         "_Bool",
        "_Complex", "_Imaginary", "_Alignas",       "_Alignof",      "_Atomic",
        "_Generic", "_Noreturn",  "_Static_assert", "_Thread_local",
        // Macros from the headers the prelude includes.
        "bool",
        "true",     "false",      "NULL",
    };
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

pub fn floatCTypeName(ty: ast.TypeExpr) ?[]const u8 {
    const name = typeName(ty) orelse return null;
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    return null;
}

pub fn mmioFieldWidthBytes(width: []const u8) u64 {
    if (std.mem.eql(u8, width, "u8") or std.mem.eql(u8, width, "i8") or std.mem.eql(u8, width, "bool")) return 1;
    if (std.mem.eql(u8, width, "u16") or std.mem.eql(u8, width, "i16")) return 2;
    if (std.mem.eql(u8, width, "u32") or std.mem.eql(u8, width, "i32")) return 4;
    if (std.mem.eql(u8, width, "u64") or std.mem.eql(u8, width, "i64") or std.mem.eql(u8, width, "usize")) return 8;
    return 4;
}

pub fn primitiveCTypeName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "c_void")) return "void";
    if (std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "u8")) return "uint8_t";
    if (std.mem.eql(u8, name, "u16")) return "uint16_t";
    if (std.mem.eql(u8, name, "u32")) return "uint32_t";
    if (std.mem.eql(u8, name, "u64")) return "uint64_t";
    if (std.mem.eql(u8, name, "u128")) return "unsigned __int128";
    if (std.mem.eql(u8, name, "usize")) return "uintptr_t";
    if (isOpaqueAddressTypeName(name)) return "uintptr_t";
    // IrqOff (§19.1) capability token: a 1-byte witness value.
    if (std.mem.eql(u8, name, "IrqOff")) return "uint8_t";
    if (std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "i128")) return "__int128";
    if (std.mem.eql(u8, name, "isize")) return "intptr_t";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    // C-ABI varargs cursor (the `va.*` intrinsics operate on it). Maps to the
    // compiler's native va_list so it is passed/used with the exact target ABI.
    if (std.mem.eql(u8, name, "va_list")) return "__builtin_va_list";
    return null;
}

pub fn ptrCType(child: ast.TypeExpr, mutability: ast.Mutability) []const u8 {
    const child_ty = cType(child);
    const is_const = mutability == .@"const";
    if (std.mem.eql(u8, child_ty, "uint8_t")) return if (is_const) "uint8_t const *" else "uint8_t *";
    if (std.mem.eql(u8, child_ty, "uint16_t")) return if (is_const) "uint16_t const *" else "uint16_t *";
    if (std.mem.eql(u8, child_ty, "uint32_t")) return if (is_const) "uint32_t const *" else "uint32_t *";
    if (std.mem.eql(u8, child_ty, "uint64_t")) return if (is_const) "uint64_t const *" else "uint64_t *";
    if (std.mem.eql(u8, child_ty, "int8_t")) return if (is_const) "int8_t const *" else "int8_t *";
    if (std.mem.eql(u8, child_ty, "int16_t")) return if (is_const) "int16_t const *" else "int16_t *";
    if (std.mem.eql(u8, child_ty, "int32_t")) return if (is_const) "int32_t const *" else "int32_t *";
    if (std.mem.eql(u8, child_ty, "int64_t")) return if (is_const) "int64_t const *" else "int64_t *";
    if (std.mem.eql(u8, child_ty, "bool")) return if (is_const) "bool const *" else "bool *";
    return "void *";
}

pub fn isCVoidType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never");
}

pub fn isVoidType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "void");
}

pub fn cTaggedUnionTagSize() i128 {
    return 4;
}

pub fn isCKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "auto",           "break",         "case",     "char",     "const",      "continue",
        "default",        "do",            "double",   "else",     "enum",       "extern",
        "float",          "for",           "goto",     "if",       "inline",     "int",
        "long",           "register",      "restrict", "return",   "short",      "signed",
        "sizeof",         "static",        "struct",   "switch",   "typedef",    "union",
        "unsigned",       "void",          "volatile", "while",    "_Alignas",   "_Alignof",
        "_Atomic",        "_Bool",         "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

pub fn cPayloadFieldName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!isCKeyword(name)) return name;
    return std.fmt.allocPrint(allocator, "{s}_", .{name});
}

pub fn isNumericStorageType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |ident| checkedTypeSuffix(ident.text) != null,
        .generic => |node| {
            // wrap/sat/serial/counter all lower to their unsigned inner integer, so a
            // `.from()` cast into any of them is a plain numeric storage conversion (the
            // LLVM backend recognizes the same set via isPayloadDomainGenericName).
            if ((!std.mem.eql(u8, node.base.text, "wrap") and !std.mem.eql(u8, node.base.text, "sat") and
                !std.mem.eql(u8, node.base.text, "serial") and !std.mem.eql(u8, node.base.text, "counter")) or node.args.len != 1) return false;
            return isNumericStorageType(node.args[0]);
        },
        .qualified => |node| isNumericStorageType(node.child.*),
        else => false,
    };
}

pub fn sameCStorageType(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    return switch (left.kind) {
        .name => |left_name| switch (right.kind) {
            .name => |right_name| std.mem.eql(u8, left_name.text, right_name.text),
            .qualified => |right_node| sameCStorageType(left, right_node.child.*),
            else => false,
        },
        .generic => |left_node| switch (right.kind) {
            .generic => |right_node| {
                if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) return false;
                if (left_node.args.len != right_node.args.len) return false;
                for (left_node.args, right_node.args) |left_arg, right_arg| {
                    if (!sameCStorageType(left_arg, right_arg)) return false;
                }
                return true;
            },
            .qualified => |right_node| sameCStorageType(left, right_node.child.*),
            else => false,
        },
        .qualified => |left_node| sameCStorageType(left_node.child.*, right),
        else => false,
    };
}

pub fn isNonNullPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isNonNullPointerType(node.child.*),
        else => false,
    };
}

pub fn rawManyElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .raw_many_pointer => |node| node.child.*,
        .qualified => |node| rawManyElementType(node.child.*),
        else => null,
    };
}

pub fn isDynCTypeName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mc_dyn_");
}

// The inner (non-null) type of a `?T` TypeExpr — e.g. `?*dyn Trait` -> `*dyn Trait`.
pub fn nullableInnerTypeExpr(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .nullable => |child| child.*,
        .qualified => |node| nullableInnerTypeExpr(node.child.*),
        else => null,
    };
}

pub fn isBoolType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "bool"),
        .qualified => |node| isBoolType(node.child.*),
        else => false,
    };
}

pub fn isPAddrType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "PAddr");
}

pub fn isPointerLikeAddressType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isPointerLikeAddressType(node.child.*),
        else => false,
    };
}
