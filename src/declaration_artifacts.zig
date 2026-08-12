//! Syntax-backed declaration artifacts for the codegen compatibility edge.
//!
//! Declarations are still collected from top-level syntax while they are being
//! normalized into VerifiedProgram facts. Backend modules consume the collected
//! artifacts through `codegen_request` rather than importing this collector
//! directly or receiving a generic declaration slice.

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const std = @import("std");

pub const SyntaxDeclarationSlice = []const ast.Decl;

/// Transitional declaration artifacts.
///
/// Codegen compatibility prepasses still read top-level syntax declarations,
/// but declaration enumeration is isolated here instead of being exposed
/// through backend lowering requests as a generic legacy view.
pub const EarlyDeclarationArtifacts = struct {
    callable_value_artifacts: []const CallableValueArtifact,
    trait_artifacts: []const TraitArtifact,
    type_artifacts: []const TypeArtifact,
    source_map_artifacts: []const SourceMapArtifact,

    pub fn collectFromSyntaxDecls(allocator: std.mem.Allocator, decls: SyntaxDeclarationSlice) !EarlyDeclarationArtifacts {
        var callable_value_artifacts: std.ArrayList(CallableValueArtifact) = .empty;
        errdefer callable_value_artifacts.deinit(allocator);
        var trait_artifacts: std.ArrayList(TraitArtifact) = .empty;
        errdefer trait_artifacts.deinit(allocator);
        var type_artifacts: std.ArrayList(TypeArtifact) = .empty;
        errdefer type_artifacts.deinit(allocator);
        var source_map_artifacts: std.ArrayList(SourceMapArtifact) = .empty;
        errdefer source_map_artifacts.deinit(allocator);

        for (decls) |decl| switch (decl.kind) {
            .fn_decl => |fn_decl| {
                try callable_value_artifacts.append(allocator, .{ .function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .extern_fn => |fn_decl| {
                try callable_value_artifacts.append(allocator, .{ .extern_function = .{ .fn_decl = fn_decl, .attrs = decl.attrs } });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .global_decl => |global| {
                try callable_value_artifacts.append(allocator, .{ .global = global });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .type_alias => |alias| {
                try type_artifacts.append(allocator, .{ .type_alias = alias });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .struct_decl => |struct_decl| {
                try type_artifacts.append(allocator, .{ .struct_decl = struct_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .enum_decl => |enum_decl| {
                try type_artifacts.append(allocator, .{ .enum_decl = enum_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .union_decl => |union_decl| {
                try type_artifacts.append(allocator, .{ .union_decl = union_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .packed_bits_decl => |packed_bits_decl| {
                try type_artifacts.append(allocator, .{ .packed_bits = packed_bits_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .overlay_union_decl => |overlay_union| {
                try type_artifacts.append(allocator, .{ .overlay_union = overlay_union });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .opaque_decl => {
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .trait_decl => |trait_decl| {
                try trait_artifacts.append(allocator, .{ .trait_decl = trait_decl });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
            .impl_trait => |impl_trait| {
                try trait_artifacts.append(allocator, .{ .impl_trait = impl_trait });
                if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
            },
        };

        const owned_callable_value_artifacts = try callable_value_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_callable_value_artifacts);
        const owned_trait_artifacts = try trait_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_trait_artifacts);
        const owned_type_artifacts = try type_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_type_artifacts);
        const owned_source_map_artifacts = try source_map_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_source_map_artifacts);

        return .{
            .callable_value_artifacts = owned_callable_value_artifacts,
            .trait_artifacts = owned_trait_artifacts,
            .type_artifacts = owned_type_artifacts,
            .source_map_artifacts = owned_source_map_artifacts,
        };
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.callable_value_artifacts);
        allocator.free(self.trait_artifacts);
        allocator.free(self.type_artifacts);
        allocator.free(self.source_map_artifacts);
        self.* = empty;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .callable_value_artifacts = &.{},
        .trait_artifacts = &.{},
        .type_artifacts = &.{},
        .source_map_artifacts = &.{},
    };
};

pub const ComptimeDeclarationArtifacts = struct {
    globals: []const ast.GlobalDecl,
    type_aliases: []const ast.TypeAlias,
    structs: []const ast.StructDecl,

    pub fn collectFromArtifacts(allocator: std.mem.Allocator, artifacts: EarlyDeclarationArtifacts) !ComptimeDeclarationArtifacts {
        var globals: std.ArrayList(ast.GlobalDecl) = .empty;
        errdefer globals.deinit(allocator);
        var type_aliases: std.ArrayList(ast.TypeAlias) = .empty;
        errdefer type_aliases.deinit(allocator);
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        errdefer structs.deinit(allocator);

        for (artifacts.callable_value_artifacts) |artifact| switch (artifact) {
            .global => |global| try globals.append(allocator, global),
            else => {},
        };
        for (artifacts.type_artifacts) |artifact| switch (artifact) {
            .type_alias => |alias| try type_aliases.append(allocator, alias),
            .struct_decl => |struct_decl| try structs.append(allocator, struct_decl),
            else => {},
        };

        const owned_globals = try globals.toOwnedSlice(allocator);
        errdefer allocator.free(owned_globals);
        const owned_type_aliases = try type_aliases.toOwnedSlice(allocator);
        errdefer allocator.free(owned_type_aliases);
        const owned_structs = try structs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_structs);

        return .{
            .globals = owned_globals,
            .type_aliases = owned_type_aliases,
            .structs = owned_structs,
        };
    }

    pub fn deinit(self: *ComptimeDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.globals);
        allocator.free(self.type_aliases);
        allocator.free(self.structs);
        self.* = empty;
    }

    pub fn view(self: ComptimeDeclarationArtifacts) eval.ComptimeDeclarations {
        return .{
            .globals = self.globals,
            .type_aliases = self.type_aliases,
            .structs = self.structs,
        };
    }

    pub const empty = ComptimeDeclarationArtifacts{
        .globals = &.{},
        .type_aliases = &.{},
        .structs = &.{},
    };
};

fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |origin| return origin,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

pub const CallableValueArtifact = union(enum) {
    global: ast.GlobalDecl,
    function: Function,
    extern_function: Function,

    pub const Function = struct {
        fn_decl: ast.FnDecl,
        attrs: []const ast.Attr,
    };
};

pub const TraitArtifact = union(enum) {
    trait_decl: ast.TraitDecl,
    impl_trait: ast.ImplTrait,
};

pub const TypeArtifact = union(enum) {
    type_alias: ast.TypeAlias,
    struct_decl: ast.StructDecl,
    enum_decl: ast.EnumDecl,
    union_decl: ast.UnionDecl,
    packed_bits: ast.PackedBitsDecl,
    overlay_union: ast.OverlayUnionDecl,
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
