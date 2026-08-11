const ast = @import("ast.zig");
const std = @import("std");

/// Transitional early declaration artifacts.
///
/// Early declaration prepasses still read top-level syntax declarations, but
/// declaration enumeration is isolated here instead of being exposed through
/// backend lowering requests as a generic legacy view.
pub const EarlyDeclarationArtifacts = struct {
    globals: []const ast.GlobalDecl,
    type_aliases: []const ast.TypeAlias,
    structs: []const ast.StructDecl,
    enums: []const ast.EnumDecl,
    unions: []const ast.UnionDecl,
    packed_bits: []const ast.PackedBitsDecl,
    overlay_unions: []const ast.OverlayUnionDecl,
    decl_artifacts: []const DeclArtifact,
    callable_value_artifacts: []const CallableValueArtifact,
    source_map_artifacts: []const SourceMapArtifact,

    pub fn collectFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl) !EarlyDeclarationArtifacts {
        var globals: std.ArrayList(ast.GlobalDecl) = .empty;
        errdefer globals.deinit(allocator);
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
        var callable_value_artifacts: std.ArrayList(CallableValueArtifact) = .empty;
        errdefer callable_value_artifacts.deinit(allocator);
        var source_map_artifacts: std.ArrayList(SourceMapArtifact) = .empty;
        errdefer source_map_artifacts.deinit(allocator);

        for (decls) |decl| switch (decl.kind) {
            .fn_decl => |fn_decl| {
                try decl_artifacts.append(allocator, .{ .function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                try callable_value_artifacts.append(allocator, .{ .function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .extern_fn => |fn_decl| {
                try decl_artifacts.append(allocator, .{ .extern_function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                try callable_value_artifacts.append(allocator, .{ .extern_function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .global_decl => |global| {
                try globals.append(allocator, global);
                try decl_artifacts.append(allocator, .{ .global = global });
                try callable_value_artifacts.append(allocator, .{ .global = global });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .type_alias => |alias| {
                try type_aliases.append(allocator, alias);
                try decl_artifacts.append(allocator, .{ .type_alias = alias });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .struct_decl => |struct_decl| {
                try structs.append(allocator, struct_decl);
                try decl_artifacts.append(allocator, .{ .struct_decl = struct_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .enum_decl => |enum_decl| {
                try enums.append(allocator, enum_decl);
                try decl_artifacts.append(allocator, .{ .enum_decl = enum_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .union_decl => |union_decl| {
                try unions.append(allocator, union_decl);
                try decl_artifacts.append(allocator, .{ .union_decl = union_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .packed_bits_decl => |packed_bits_decl| {
                try packed_bits.append(allocator, packed_bits_decl);
                try decl_artifacts.append(allocator, .{ .packed_bits = packed_bits_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .overlay_union_decl => |overlay_union| {
                try overlay_unions.append(allocator, overlay_union);
                try decl_artifacts.append(allocator, .{ .overlay_union = overlay_union });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .opaque_decl => |name| {
                try decl_artifacts.append(allocator, .{ .opaque_decl = name });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .trait_decl => |trait_decl| {
                try decl_artifacts.append(allocator, .{ .trait_decl = trait_decl });
                try callable_value_artifacts.append(allocator, .{ .trait_decl = trait_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .impl_trait => |impl_trait| {
                try decl_artifacts.append(allocator, .{ .impl_trait = impl_trait });
                try callable_value_artifacts.append(allocator, .{ .impl_trait = impl_trait });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
        };

        const owned_globals = try globals.toOwnedSlice(allocator);
        errdefer allocator.free(owned_globals);
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
        const owned_callable_value_artifacts = try callable_value_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_callable_value_artifacts);
        const owned_source_map_artifacts = try source_map_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_source_map_artifacts);

        return .{
            .globals = owned_globals,
            .type_aliases = owned_type_aliases,
            .structs = owned_structs,
            .enums = owned_enums,
            .unions = owned_unions,
            .packed_bits = owned_packed_bits,
            .overlay_unions = owned_overlay_unions,
            .decl_artifacts = owned_decl_artifacts,
            .callable_value_artifacts = owned_callable_value_artifacts,
            .source_map_artifacts = owned_source_map_artifacts,
        };
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.globals);
        allocator.free(self.type_aliases);
        allocator.free(self.structs);
        allocator.free(self.enums);
        allocator.free(self.unions);
        allocator.free(self.packed_bits);
        allocator.free(self.overlay_unions);
        allocator.free(self.decl_artifacts);
        allocator.free(self.callable_value_artifacts);
        allocator.free(self.source_map_artifacts);
        self.* = empty;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .globals = &.{},
        .type_aliases = &.{},
        .structs = &.{},
        .enums = &.{},
        .unions = &.{},
        .packed_bits = &.{},
        .overlay_unions = &.{},
        .decl_artifacts = &.{},
        .callable_value_artifacts = &.{},
        .source_map_artifacts = &.{},
    };
};

fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |origin| return origin,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

pub const DeclArtifact = union(enum) {
    type_alias: ast.TypeAlias,
    global: ast.GlobalDecl,
    struct_decl: ast.StructDecl,
    enum_decl: ast.EnumDecl,
    union_decl: ast.UnionDecl,
    packed_bits: ast.PackedBitsDecl,
    overlay_union: ast.OverlayUnionDecl,
    opaque_decl: ast.Ident,
    function: Function,
    extern_function: Function,
    trait_decl: ast.TraitDecl,
    impl_trait: ast.ImplTrait,

    pub const Function = struct {
        fn_decl: ast.FnDecl,
        attrs: []const ast.Attr,
    };
};

pub const CallableValueArtifact = union(enum) {
    global: ast.GlobalDecl,
    function: Function,
    extern_function: Function,
    trait_decl: ast.TraitDecl,
    impl_trait: ast.ImplTrait,

    pub const Function = struct {
        fn_decl: ast.FnDecl,
        attrs: []const ast.Attr,
    };
};

pub const SourceMapArtifact = union(enum) {
    global: Global,
    function: Function,
    extern_fn: ExternFn,
    type_decl: TypeDecl,

    pub const Global = struct {
        symbol: []const u8,
        name_span: ast.Span,
        init_span: ?ast.Span,
        is_const: bool,
        origin: []const u8,
    };

    pub const Function = struct {
        symbol: []const u8,
        name_span: ast.Span,
        body: ast.Block,
        object_symbol: []const u8,
        exported: bool,
        origin: []const u8,
    };

    pub const ExternFn = struct {
        symbol: []const u8,
        name_span: ast.Span,
        origin: []const u8,
    };

    pub const TypeDecl = struct {
        kind: []const u8,
        symbol: []const u8,
        name_span: ast.Span,
        origin: []const u8,
    };
};

fn sourceMapArtifactFromDecl(decl: ast.Decl) ?SourceMapArtifact {
    const origin = declOrigin(decl);
    return switch (decl.kind) {
        .global_decl => |global| .{ .global = .{
            .symbol = global.name.text,
            .name_span = global.name.span,
            .init_span = if (global.init) |init| init.span else null,
            .is_const = global.is_const,
            .origin = origin,
        } },
        .fn_decl => |fn_decl| if (fn_decl.body) |body| .{ .function = .{
            .symbol = fn_decl.name.text,
            .name_span = fn_decl.name.span,
            .body = body,
            .object_symbol = backendNameOverride(decl.attrs) orelse fn_decl.name.text,
            .exported = fn_decl.exported,
            .origin = origin,
        } } else .{ .extern_fn = .{
            .symbol = fn_decl.name.text,
            .name_span = fn_decl.name.span,
            .origin = origin,
        } },
        .extern_fn => |fn_decl| .{ .extern_fn = .{
            .symbol = fn_decl.name.text,
            .name_span = fn_decl.name.span,
            .origin = origin,
        } },
        .struct_decl => |node| typeSourceMapArtifact("struct", node.name, origin),
        .enum_decl => |node| typeSourceMapArtifact("enum", node.name, origin),
        .union_decl => |node| typeSourceMapArtifact("union", node.name, origin),
        .packed_bits_decl => |node| typeSourceMapArtifact("packed_bits", node.name, origin),
        .overlay_union_decl => |node| typeSourceMapArtifact("overlay_union", node.name, origin),
        .opaque_decl => |name| typeSourceMapArtifact("opaque", name, origin),
        .type_alias => |node| typeSourceMapArtifact("type_alias", node.name, origin),
        else => null,
    };
}

fn typeSourceMapArtifact(kind: []const u8, name: ast.Ident, origin: []const u8) SourceMapArtifact {
    return .{ .type_decl = .{
        .kind = kind,
        .symbol = name.text,
        .name_span = name.span,
        .origin = origin,
    } };
}

fn backendNameOverride(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| switch (attr.kind) {
        .backend_name => |name| return name,
        else => {},
    };
    return null;
}
