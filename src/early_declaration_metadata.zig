const ast = @import("ast.zig");
const std = @import("std");

pub const DeclarationSlice = []const ast.Decl;

/// Transitional early declaration artifacts.
///
/// Early declaration prepasses still read top-level syntax declarations, but
/// declaration enumeration is isolated here instead of being exposed through
/// backend lowering requests as a generic legacy view.
pub const EarlyDeclarationArtifacts = struct {
    decls: DeclarationSlice,
    const_fns: []const ast.FnDecl,
    const_globals: []const ast.GlobalDecl,
    type_aliases: []const ast.TypeAlias,
    structs: []const ast.StructDecl,
    enums: []const ast.EnumDecl,
    unions: []const ast.UnionDecl,
    packed_bits: []const ast.PackedBitsDecl,
    overlay_unions: []const ast.OverlayUnionDecl,
    decl_artifacts: []const DeclArtifact,

    pub fn collectFromDecls(allocator: std.mem.Allocator, decls: DeclarationSlice) !EarlyDeclarationArtifacts {
        var const_fns: std.ArrayList(ast.FnDecl) = .empty;
        errdefer const_fns.deinit(allocator);
        var const_globals: std.ArrayList(ast.GlobalDecl) = .empty;
        errdefer const_globals.deinit(allocator);
        var type_aliases: std.ArrayList(ast.TypeAlias) = .empty;
        errdefer type_aliases.deinit(allocator);
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        errdefer structs.deinit(allocator);
        var enums: std.ArrayList(ast.EnumDecl) = .empty;
        errdefer enums.deinit(allocator);
        var unions: std.ArrayList(ast.UnionDecl) = .empty;
        errdefer unions.deinit(allocator);
        var packed_bits: std.ArrayList(ast.PackedBitsDecl) = .empty;
        errdefer packed_bits.deinit(allocator);
        var overlay_unions: std.ArrayList(ast.OverlayUnionDecl) = .empty;
        errdefer overlay_unions.deinit(allocator);
        var decl_artifacts: std.ArrayList(DeclArtifact) = .empty;
        errdefer decl_artifacts.deinit(allocator);

        for (decls) |decl| switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (fn_decl.is_const) try const_fns.append(allocator, fn_decl);
                try decl_artifacts.append(allocator, .{ .function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
            },
            .extern_fn => |fn_decl| try decl_artifacts.append(allocator, .{ .extern_function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } }),
            .global_decl => |global| {
                if (global.is_const) try const_globals.append(allocator, global);
                try decl_artifacts.append(allocator, .{ .global = global });
            },
            .type_alias => |alias| {
                try type_aliases.append(allocator, alias);
                try decl_artifacts.append(allocator, .{ .type_alias = alias });
            },
            .struct_decl => |struct_decl| {
                try structs.append(allocator, struct_decl);
                try decl_artifacts.append(allocator, .{ .struct_decl = struct_decl });
            },
            .enum_decl => |enum_decl| {
                try enums.append(allocator, enum_decl);
                try decl_artifacts.append(allocator, .{ .enum_decl = enum_decl });
            },
            .union_decl => |union_decl| {
                try unions.append(allocator, union_decl);
                try decl_artifacts.append(allocator, .{ .union_decl = union_decl });
            },
            .packed_bits_decl => |packed_bits_decl| {
                try packed_bits.append(allocator, packed_bits_decl);
                try decl_artifacts.append(allocator, .{ .packed_bits = packed_bits_decl });
            },
            .overlay_union_decl => |overlay_union| {
                try overlay_unions.append(allocator, overlay_union);
                try decl_artifacts.append(allocator, .{ .overlay_union = overlay_union });
            },
            .trait_decl => |trait_decl| try decl_artifacts.append(allocator, .{ .trait_decl = trait_decl }),
            .impl_trait => |impl_trait| try decl_artifacts.append(allocator, .{ .impl_trait = impl_trait }),
            else => {},
        };

        const owned_const_fns = try const_fns.toOwnedSlice(allocator);
        errdefer allocator.free(owned_const_fns);
        const owned_const_globals = try const_globals.toOwnedSlice(allocator);
        errdefer allocator.free(owned_const_globals);
        const owned_type_aliases = try type_aliases.toOwnedSlice(allocator);
        errdefer allocator.free(owned_type_aliases);
        const owned_structs = try structs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_structs);
        const owned_enums = try enums.toOwnedSlice(allocator);
        errdefer allocator.free(owned_enums);
        const owned_unions = try unions.toOwnedSlice(allocator);
        errdefer allocator.free(owned_unions);
        const owned_packed_bits = try packed_bits.toOwnedSlice(allocator);
        errdefer allocator.free(owned_packed_bits);
        const owned_overlay_unions = try overlay_unions.toOwnedSlice(allocator);
        errdefer allocator.free(owned_overlay_unions);
        const owned_decl_artifacts = try decl_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_decl_artifacts);

        return .{
            .decls = decls,
            .const_fns = owned_const_fns,
            .const_globals = owned_const_globals,
            .type_aliases = owned_type_aliases,
            .structs = owned_structs,
            .enums = owned_enums,
            .unions = owned_unions,
            .packed_bits = owned_packed_bits,
            .overlay_unions = owned_overlay_unions,
            .decl_artifacts = owned_decl_artifacts,
        };
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.const_fns);
        allocator.free(self.const_globals);
        allocator.free(self.type_aliases);
        allocator.free(self.structs);
        allocator.free(self.enums);
        allocator.free(self.unions);
        allocator.free(self.packed_bits);
        allocator.free(self.overlay_unions);
        allocator.free(self.decl_artifacts);
        self.* = empty;
    }

    pub fn declsForComptimeEvaluation(self: EarlyDeclarationArtifacts) DeclarationSlice {
        return self.decls;
    }

    pub fn declsForLegacyArtifactEnumeration(self: EarlyDeclarationArtifacts) DeclarationSlice {
        return self.decls;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .decls = &.{},
        .const_fns = &.{},
        .const_globals = &.{},
        .type_aliases = &.{},
        .structs = &.{},
        .enums = &.{},
        .unions = &.{},
        .packed_bits = &.{},
        .overlay_unions = &.{},
        .decl_artifacts = &.{},
    };
};

pub const DeclArtifact = union(enum) {
    type_alias: ast.TypeAlias,
    global: ast.GlobalDecl,
    struct_decl: ast.StructDecl,
    enum_decl: ast.EnumDecl,
    union_decl: ast.UnionDecl,
    packed_bits: ast.PackedBitsDecl,
    overlay_union: ast.OverlayUnionDecl,
    function: Function,
    extern_function: Function,
    trait_decl: ast.TraitDecl,
    impl_trait: ast.ImplTrait,

    pub const Function = struct {
        fn_decl: ast.FnDecl,
        attrs: []const ast.Attr,
    };
};
