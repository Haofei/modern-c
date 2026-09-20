//! C backend registry collection helpers.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const mir = @import("mir.zig");
const signature_type_mechanics = @import("signature_type_mechanics.zig");

const MmioStruct = lower_c_model.MmioStruct;
const PackedBitsField = lower_c_model.PackedBitsField;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const SliceInfo = lower_c_model.SliceInfo;
const mmioFieldFromType = lower_c_shape.mmioFieldFromType;

pub const SignatureSliceTypeNameFn = *const fn (ctx: *anyopaque, child: mir.SignatureTypeId, mutability: mir.TypeMutability) anyerror![]const u8;

/// Syntax-free typedef artifact ingress.  The registry is keyed by the
/// declaration spelling, but every collision check is against the verified
/// alias-resolved signature identity, never a materialized TypeExpr.
pub const SignatureSliceArtifactContext = struct {
    emit_ctx: *anyopaque,
    signature_types: mir.SignatureTypeTable,
    slice_type_name: SignatureSliceTypeNameFn,
    same_type: *const fn (*anyopaque, mir.SignatureTypeId, mir.SignatureTypeId) anyerror!bool,
    pointer_type_for_slice_element: SignatureSliceTypeNameFn,
    slice_types: *std.StringHashMap(SliceInfo),
};

pub fn collectPackedBits(
    allocator: std.mem.Allocator,
    packed_bits_map: *std.StringHashMap(PackedBitsInfo),
    packed_bits: ast_bridge.PackedBitsDecl,
    repr_name: []const u8,
    repr_c_type: []const u8,
) !void {
    var fields = std.StringHashMap(PackedBitsField).init(allocator);
    errdefer fields.deinit();
    for (packed_bits.fields, 0..) |field, bit_index| {
        try fields.put(field.name.text, .{ .bit_index = bit_index });
    }
    try packed_bits_map.put(packed_bits.name.text, .{
        .repr_name = repr_name,
        .repr_c_type = repr_c_type,
        .fields = fields,
    });
}

pub fn collectMmioStruct(
    allocator: std.mem.Allocator,
    mmio_structs: *std.StringHashMap(MmioStruct),
    struct_decl: ast_bridge.StructDecl,
) !void {
    var fields = std.StringHashMap(lower_c_model.MmioField).init(allocator);
    errdefer fields.deinit();
    for (struct_decl.fields) |field| {
        if (mmioFieldFromType(field.ty)) |info| try fields.put(field.name.text, info);
    }
    try mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
}

/// Register every slice typedef required by `id`.  This is intentionally a
/// walk over the immutable signature graph rather than the old AST-shaped
/// declaration/body collectors.  The extra mutable companion preserves C
/// lowering of a const-narrowed range and is represented by the same child ID
/// with `TypeMutability.mut`.
pub fn collectSignatureSliceType(ctx: SignatureSliceArtifactContext, id: mir.SignatureTypeId) anyerror!void {
    const shape = signature_type_mechanics.shape(ctx.signature_types, id) catch return error.InvalidSignatureType;
    switch (shape) {
        .slice => |node| {
            try collectSignatureSliceType(ctx, node.child);
            try putSignatureSliceType(ctx, id, node.child, node.mutability);
            if (node.mutability == .@"const") try putSignatureSliceType(ctx, id, node.child, .mut);
        },
        .pointer => |node| try collectSignatureSliceType(ctx, node.child),
        .raw_many_pointer => |node| try collectSignatureSliceType(ctx, node.child),
        .nullable => |child| try collectSignatureSliceType(ctx, child),
        .qualified => |node| try collectSignatureSliceType(ctx, node.child),
        .array => |node| try collectSignatureSliceType(ctx, node.child),
        .generic => |node| {
            if (std.mem.eql(u8, node.base, "DmaBuf") and node.args.len == 2)
                try putSignatureSliceType(ctx, id, node.args[0], .mut);
            for (node.args) |arg| try collectSignatureSliceType(ctx, arg);
        },
        .fn_pointer => |node| {
            try collectSignatureSliceType(ctx, node.ret);
            for (node.params) |param| try collectSignatureSliceType(ctx, param);
        },
        .closure_type => |node| {
            try collectSignatureSliceType(ctx, node.ret);
            for (node.params) |param| try collectSignatureSliceType(ctx, param);
        },
        .member => |node| try collectSignatureSliceType(ctx, node.base),
        .name, .enum_literal, .dyn_trait => {},
    }
}

fn putSignatureSliceType(ctx: SignatureSliceArtifactContext, type_id: mir.SignatureTypeId, child: mir.SignatureTypeId, mutability: mir.TypeMutability) !void {
    const name = try ctx.slice_type_name(ctx.emit_ctx, child, mutability);
    const ptr_type = try ctx.pointer_type_for_slice_element(ctx.emit_ctx, child, mutability);
    if (ctx.slice_types.get(name)) |existing| {
        if (!try ctx.same_type(ctx.emit_ctx, existing.element_type_id, child) or existing.mutability != mutability or !std.mem.eql(u8, existing.ptr_type, ptr_type)) return error.GeneratedTypeNameCollision;
    } else {
        try ctx.slice_types.put(name, .{
            .type_id = type_id,
            .name = name,
            .ptr_type = ptr_type,
            .element_type_id = child,
            .mutability = mutability,
        });
    }
}
