//! C aggregate declaration dependency ordering.
//!
//! Complete function bodies are rendered by `mir_executable_c.zig`; this
//! module retains only the declaration-level closure and ordering mechanics
//! needed to emit C aggregate definitions. It deliberately has no AST
//! expression or constructor lowering surface.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");
const signature_type_mechanics = @import("signature_type_mechanics.zig");
const type_bridge = @import("type_bridge.zig");

const AggregateEmitUnit = lower_c_model.AggregateEmitUnit;
const ArrayInfo = lower_c_model.ArrayInfo;
const ResultInfo = lower_c_model.ResultInfo;
const OptInfo = lower_c_model.OptInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;

pub const DepNameFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8;
pub const SignatureDepNameFn = *const fn (ctx: *anyopaque, id: mir.SignatureTypeId) anyerror![]const u8;
pub const EmitUnitFn = *const fn (ctx: *anyopaque, unit: AggregateEmitUnit) anyerror!void;

pub const DepContext = struct {
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    structs: *const std.StringHashMap(ast_bridge.StructDecl),
    tagged_unions: *const std.StringHashMap(ast_bridge.UnionDecl),
    enums: *const std.StringHashMap(ast_bridge.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    array_types: *const std.StringHashMap(ArrayInfo),
    result_types: *const std.StringHashMap(ResultInfo),
    opt_types: *const std.StringHashMap(OptInfo),
    signature_types: mir.SignatureTypeTable,
    name_ctx: *anyopaque,
    name_for_type: DepNameFn,
    name_for_signature: SignatureDepNameFn,
};

pub fn emitUnitsInDependencyOrder(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    units: []const AggregateEmitUnit,
    emit_ctx: *anyopaque,
    emit_unit: EmitUnitFn,
) !void {
    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();
    const done = try allocator.alloc(bool, units.len);
    @memset(done, false);

    var remaining = units.len;
    while (remaining > 0) {
        var progressed = false;
        for (units, 0..) |unit, i| {
            if (done[i]) continue;
            if (!try aggregateDepsSatisfied(ctx, unit, &emitted)) continue;
            try emit_unit(emit_ctx, unit);
            try emitted.put(aggregateUnitName(unit), {});
            done[i] = true;
            remaining -= 1;
            progressed = true;
        }
        if (progressed) continue;

        // No progress: emit the remaining units deterministically so the C
        // compiler can report an unexpected declaration cycle.
        for (units, 0..) |unit, i| {
            if (done[i]) continue;
            try emit_unit(emit_ctx, unit);
            done[i] = true;
        }
        break;
    }
}

/// Append `struct_decl` and every aggregate it embeds by value.
pub fn collectStructClosure(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    struct_decl: ast_bridge.StructDecl,
    units: *std.ArrayList(AggregateEmitUnit),
    seen: *std.StringHashMap(void),
    scalar_deps: *std.ArrayList([]const u8),
) anyerror!void {
    if ((try seen.getOrPut(struct_decl.name.text)).found_existing) return;
    for (struct_decl.fields) |field| try collectTypeClosure(ctx, allocator, field.ty, units, seen, scalar_deps);
    try units.append(allocator, .{ .struct_decl = struct_decl });
}

/// Pull in by-value aggregate references and named scalar typedef dependencies.
pub fn collectTypeClosure(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    ty: ast_bridge.TypeExpr,
    units: *std.ArrayList(AggregateEmitUnit),
    seen: *std.StringHashMap(void),
    scalar_deps: *std.ArrayList([]const u8),
) anyerror!void {
    const resolved = type_bridge.resolveAliasType(ctx.type_aliases, ty);
    switch (resolved.kind) {
        .array => {
            const wrapper = try ctx.name_for_type(ctx.name_ctx, resolved);
            if (ctx.array_types.get(wrapper)) |info| {
                if (!(try seen.getOrPut(wrapper)).found_existing) {
                    try collectSignatureTypeClosure(ctx, allocator, info.element_type_id, units, seen, scalar_deps);
                    try units.append(allocator, .{ .array = info });
                }
            }
        },
        .name => |ident| {
            if (ctx.structs.get(ident.text)) |nested| {
                try collectStructClosure(ctx, allocator, nested, units, seen, scalar_deps);
            } else if (ctx.tagged_unions.get(ident.text)) |union_decl| {
                if (!(try seen.getOrPut(ident.text)).found_existing) {
                    for (union_decl.cases) |case| {
                        if (case.ty) |case_ty| try collectTypeClosure(ctx, allocator, case_ty, units, seen, scalar_deps);
                    }
                    try units.append(allocator, .{ .tagged_union = union_decl });
                }
            } else if (ctx.enums.contains(ident.text) or ctx.packed_bits.contains(ident.text) or ctx.overlay_unions.contains(ident.text)) {
                if (!(try seen.getOrPut(ident.text)).found_existing) try scalar_deps.append(allocator, ident.text);
            }
        },
        .nullable => |child| {
            if (lower_c_type.nullablePayloadIsValueType(ctx.type_aliases, child.*)) {
                const opt_name = try ctx.name_for_type(ctx.name_ctx, resolved);
                const opt = ctx.opt_types.get(opt_name) orelse return error.MissingAggregateSignatureFact;
                if (!(try seen.getOrPut(opt_name)).found_existing) {
                    try collectTypeClosure(ctx, allocator, child.*, units, seen, scalar_deps);
                    try units.append(allocator, .{ .opt = opt });
                }
            } else {
                try collectTypeClosure(ctx, allocator, child.*, units, seen, scalar_deps);
            }
        },
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
            const name = try ctx.name_for_type(ctx.name_ctx, resolved);
            const result = ctx.result_types.get(name) orelse return error.MissingAggregateSignatureFact;
            if (!(try seen.getOrPut(name)).found_existing) {
                try collectSignatureTypeClosure(ctx, allocator, result.ok_type_id, units, seen, scalar_deps);
                try collectSignatureTypeClosure(ctx, allocator, result.err_type_id, units, seen, scalar_deps);
                try units.append(allocator, .{ .result = result });
            }
        },
        .qualified => |node| try collectTypeClosure(ctx, allocator, node.child.*, units, seen, scalar_deps),
        else => {},
    }
}

pub fn aggregateDepsSatisfied(ctx: DepContext, unit: AggregateEmitUnit, emitted: *std.StringHashMap(void)) !bool {
    switch (unit) {
        .struct_decl => |s| for (s.fields) |field| {
            if (try aggregateDepName(ctx, field.ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .array => |a| {
            if (try aggregateSignatureDepName(ctx, a.element_type_id)) |dep| if (!emitted.contains(dep)) return false;
        },
        .result => |r| {
            if (try aggregateSignatureDepName(ctx, r.ok_type_id)) |dep| if (!emitted.contains(dep)) return false;
            if (try aggregateSignatureDepName(ctx, r.err_type_id)) |dep| if (!emitted.contains(dep)) return false;
        },
        .tagged_union => |u| for (u.cases) |case| {
            if (case.ty) |ty| if (try aggregateDepName(ctx, ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .opt => |o| {
            if (try aggregateSignatureDepName(ctx, o.payload_type_id)) |dep| if (!emitted.contains(dep)) return false;
        },
    }
    return true;
}

fn collectSignatureTypeClosure(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    id: mir.SignatureTypeId,
    units: *std.ArrayList(AggregateEmitUnit),
    seen: *std.StringHashMap(void),
    scalar_deps: *std.ArrayList([]const u8),
) anyerror!void {
    const shape = signature_type_mechanics.shape(ctx.signature_types, id) catch return error.MissingAggregateSignatureFact;
    switch (shape) {
        .qualified => |node| try collectSignatureTypeClosure(ctx, allocator, node.child, units, seen, scalar_deps),
        .pointer, .raw_many_pointer, .slice, .fn_pointer, .closure_type, .dyn_trait => {},
        .nullable => |child| {
            try collectSignatureTypeClosure(ctx, allocator, child, units, seen, scalar_deps);
            if (signaturePointerLike(ctx.signature_types, child)) return;
            const name = try ctx.name_for_signature(ctx.name_ctx, id);
            const opt = ctx.opt_types.get(name) orelse return error.MissingAggregateSignatureFact;
            if (!(try seen.getOrPut(name)).found_existing) {
                try units.append(allocator, .{ .opt = opt });
            }
        },
        .array => |node| {
            try collectSignatureTypeClosure(ctx, allocator, node.child, units, seen, scalar_deps);
            const name = try ctx.name_for_signature(ctx.name_ctx, id);
            const array = ctx.array_types.get(name) orelse return error.MissingAggregateSignatureFact;
            if (!(try seen.getOrPut(name)).found_existing) try units.append(allocator, .{ .array = array });
        },
        .generic => |node| {
            for (node.args) |arg| try collectSignatureTypeClosure(ctx, allocator, arg, units, seen, scalar_deps);
            if (!std.mem.eql(u8, node.base, "Result")) return;
            if (node.args.len != 2) return error.MissingAggregateSignatureFact;
            const name = try ctx.name_for_signature(ctx.name_ctx, id);
            const result = ctx.result_types.get(name) orelse return error.MissingAggregateSignatureFact;
            if (!(try seen.getOrPut(name)).found_existing) try units.append(allocator, .{ .result = result });
        },
        .name => |name| if (ctx.structs.get(name)) |struct_decl| {
            try collectStructClosure(ctx, allocator, struct_decl, units, seen, scalar_deps);
        } else if (ctx.tagged_unions.get(name)) |union_decl| {
            if (!(try seen.getOrPut(name)).found_existing) try units.append(allocator, .{ .tagged_union = union_decl });
        } else if (ctx.enums.contains(name) or ctx.packed_bits.contains(name) or ctx.overlay_unions.contains(name)) {
            if (!(try seen.getOrPut(name)).found_existing) try scalar_deps.append(allocator, name);
        },
        .member, .enum_literal => return error.MissingAggregateSignatureFact,
    }
}

fn aggregateSignatureDepName(ctx: DepContext, id: mir.SignatureTypeId) !?[]const u8 {
    const shape = signature_type_mechanics.shape(ctx.signature_types, id) catch return error.MissingAggregateSignatureFact;
    return switch (shape) {
        .qualified => |node| aggregateSignatureDepName(ctx, node.child),
        .array => try ctx.name_for_signature(ctx.name_ctx, id),
        .nullable => |child| if (signaturePointerLike(ctx.signature_types, child)) null else try ctx.name_for_signature(ctx.name_ctx, id),
        .generic => |node| if (std.mem.eql(u8, node.base, "Result"))
            try ctx.name_for_signature(ctx.name_ctx, id)
        else if (signatureGenericIsTransparent(node.base) and node.args.len >= 1)
            aggregateSignatureDepName(ctx, node.args[0])
        else
            null,
        .name => |name| if (ctx.structs.contains(name) or ctx.tagged_unions.contains(name)) name else null,
        else => null,
    };
}

fn signaturePointerLike(types: mir.SignatureTypeTable, id: mir.SignatureTypeId) bool {
    const shape = signature_type_mechanics.shape(types, id) catch return false;
    return switch (shape) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| signaturePointerLike(types, node.child),
        else => false,
    };
}

fn signatureGenericIsTransparent(base: []const u8) bool {
    return std.mem.eql(u8, base, "wrap") or std.mem.eql(u8, base, "sat") or
        std.mem.eql(u8, base, "serial") or std.mem.eql(u8, base, "counter") or
        std.mem.eql(u8, base, "Secret") or std.mem.eql(u8, base, "Duration") or
        std.mem.eql(u8, base, "atomic") or std.mem.eql(u8, base, "MaybeUninit") or
        std.mem.eql(u8, base, "Reg") or std.mem.eql(u8, base, "RegBits");
}

pub fn aggregateDepName(ctx: DepContext, ty: ast_bridge.TypeExpr) !?[]const u8 {
    const resolved = type_bridge.resolveAliasType(ctx.type_aliases, ty);
    return switch (resolved.kind) {
        .array => try ctx.name_for_type(ctx.name_ctx, resolved),
        .qualified => |node| try aggregateDepName(ctx, node.child.*),
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result"))
            try ctx.name_for_type(ctx.name_ctx, resolved)
        else
            null,
        .nullable => |child| if (lower_c_type.nullablePayloadIsValueType(ctx.type_aliases, child.*))
            try ctx.name_for_type(ctx.name_ctx, resolved)
        else
            null,
        .name => |ident| if (ctx.structs.contains(ident.text) or ctx.tagged_unions.contains(ident.text)) ident.text else null,
        else => null,
    };
}

fn aggregateUnitName(unit: AggregateEmitUnit) []const u8 {
    return switch (unit) {
        .struct_decl => |s| s.name.text,
        .array => |a| a.name,
        .result => |r| r.name,
        .tagged_union => |u| u.name.text,
        .opt => |o| o.name,
    };
}
