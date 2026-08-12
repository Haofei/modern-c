//! Declaration artifacts for the remaining codegen compatibility edge.
//! Backends consume these through `codegen_request`, not raw declaration slices.

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const module_parser = @import("module_parser.zig");
const std = @import("std");

/// Transitional declaration artifacts isolated from backend lowering requests.
pub const EarlyDeclarationArtifacts = struct {
    decl_artifacts: []const DeclArtifact,
    source_map_artifacts: []const SourceMapArtifact,

    fn collectFromResolvedDeclItems(allocator: std.mem.Allocator, resolved_decls: anytype) !EarlyDeclarationArtifacts {
        var decl_artifacts: std.ArrayList(DeclArtifact) = .empty;
        errdefer decl_artifacts.deinit(allocator);
        var source_map_artifacts: std.ArrayList(SourceMapArtifact) = .empty;
        errdefer source_map_artifacts.deinit(allocator);

        for (resolved_decls) |item| {
            const decl = item.decl;
            switch (decl.kind) {
                .fn_decl => |fn_decl| {
                    try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, false) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .extern_fn => |fn_decl| {
                    try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, true) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .global_decl => |global| {
                    try decl_artifacts.append(allocator, .{ .global = GlobalArtifact.fromDecl(global) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .type_alias => |alias| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .type_alias = alias } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .struct_decl => |struct_decl| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .struct_decl = struct_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .enum_decl => |enum_decl| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .enum_decl = enum_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .union_decl => |union_decl| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .union_decl = union_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .packed_bits_decl => |packed_bits_decl| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .packed_bits_decl = packed_bits_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .overlay_union_decl => |overlay_union| {
                    try decl_artifacts.append(allocator, .{ .type_decl = .{ .overlay_union_decl = overlay_union } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .opaque_decl => {
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .trait_decl => |trait_decl| {
                    try decl_artifacts.append(allocator, .{ .trait_decl = TraitDeclArtifact.fromDecl(trait_decl) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .impl_trait => |impl_trait| {
                    try decl_artifacts.append(allocator, .{ .impl_trait = ImplTraitArtifact.fromDecl(impl_trait) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
            }
        }

        const owned_decl_artifacts = try decl_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_decl_artifacts);
        const owned_source_map_artifacts = try source_map_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_source_map_artifacts);

        return .{
            .decl_artifacts = owned_decl_artifacts,
            .source_map_artifacts = owned_source_map_artifacts,
        };
    }

    /// Collect declaration artifacts from the per-file resolved declaration stream.
    pub fn collectFromResolvedDecls(
        allocator: std.mem.Allocator,
        resolved_decls: []const module_parser.ResolvedDecl,
    ) !EarlyDeclarationArtifacts {
        return collectFromResolvedDeclItems(allocator, resolved_decls);
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.decl_artifacts);
        allocator.free(self.source_map_artifacts);
        self.* = empty;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .decl_artifacts = &.{},
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

        for (artifacts.decl_artifacts) |artifact| switch (artifact) {
            .global => |global| try globals.append(allocator, globalDeclFromArtifact(global)),
            .type_decl => |type_decl| switch (type_decl) {
                .type_alias => |alias| try type_aliases.append(allocator, alias),
                .struct_decl => |struct_decl| try structs.append(allocator, struct_decl),
                else => {},
            },
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

pub const FunctionArtifact = struct {
    name: ast.Ident,
    associated_owner: ?ast.Ident,
    abi: ?[]const u8,
    params: []ast.Param,
    return_type: ?ast.TypeExpr,
    return_borrow_source: ?ast.Ident,
    body: ?ast.Block,
    is_const: bool,
    exported: bool,
    is_variadic: bool,
    bounds: []ast.TraitBound,
    is_async: bool,
    attrs: []const ast.Attr,
    is_extern: bool,

    pub fn fromDecl(fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool) FunctionArtifact {
        return .{
            .name = fn_decl.name,
            .associated_owner = fn_decl.associated_owner,
            .abi = fn_decl.abi,
            .params = fn_decl.params,
            .return_type = fn_decl.return_type,
            .return_borrow_source = fn_decl.return_borrow_source,
            .body = fn_decl.body,
            .is_const = fn_decl.is_const,
            .exported = fn_decl.exported,
            .is_variadic = fn_decl.is_variadic,
            .bounds = fn_decl.bounds,
            .is_async = fn_decl.is_async,
            .attrs = attrs,
            .is_extern = is_extern,
        };
    }
};

pub fn comptimeFnDeclFromArtifact(function: FunctionArtifact) ast.FnDecl {
    return .{
        .name = function.name,
        .associated_owner = function.associated_owner,
        .abi = function.abi,
        .params = function.params,
        .return_type = function.return_type,
        .return_borrow_source = function.return_borrow_source,
        .body = function.body,
        .is_const = function.is_const,
        .exported = function.exported,
        .is_variadic = function.is_variadic,
        .bounds = function.bounds,
        .is_async = function.is_async,
    };
}

pub const GlobalArtifact = struct {
    name: ast.Ident,
    ty: ?ast.TypeExpr,
    init: ?ast.Expr,
    is_const: bool,
    exported: bool,
    is_extern: bool,

    pub fn fromDecl(global: ast.GlobalDecl) GlobalArtifact {
        return .{
            .name = global.name,
            .ty = global.ty,
            .init = global.init,
            .is_const = global.is_const,
            .exported = global.exported,
            .is_extern = global.is_extern,
        };
    }
};

fn globalDeclFromArtifact(global: GlobalArtifact) ast.GlobalDecl {
    return .{
        .name = global.name,
        .ty = global.ty,
        .init = global.init,
        .is_const = global.is_const,
        .exported = global.exported,
        .is_extern = global.is_extern,
    };
}

pub const TraitDeclArtifact = struct {
    name: ast.Ident,
    methods: []ast.TraitMethodSig,

    pub fn fromDecl(trait_decl: ast.TraitDecl) TraitDeclArtifact {
        return .{
            .name = trait_decl.name,
            .methods = trait_decl.methods,
        };
    }
};

pub const ImplTraitArtifact = struct {
    trait_name: ast.Ident,
    type_name: ast.Ident,
    methods: []ast.ImplTraitMethod,

    pub fn fromDecl(impl_trait: ast.ImplTrait) ImplTraitArtifact {
        return .{
            .trait_name = impl_trait.trait_name,
            .type_name = impl_trait.type_name,
            .methods = impl_trait.methods,
        };
    }
};

pub const DeclArtifact = union(enum) {
    function: FunctionArtifact,
    global: GlobalArtifact,
    trait_decl: TraitDeclArtifact,
    impl_trait: ImplTraitArtifact,
    type_decl: TypeDeclArtifact,
};

pub const TypeDeclArtifact = union(enum) {
    type_alias: ast.TypeAlias,
    struct_decl: ast.StructDecl,
    enum_decl: ast.EnumDecl,
    union_decl: ast.UnionDecl,
    packed_bits_decl: ast.PackedBitsDecl,
    overlay_union_decl: ast.OverlayUnionDecl,
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
        .fn_decl => |fn_decl| if (fn_decl.body != null) .{ .function = .{
            .symbol = fn_decl.name.text,
            .name_span = fn_decl.name.span,
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

test "declaration artifacts collect from resolved declaration stream" {
    const test_support = @import("test_support.zig");

    var parsed = try test_support.parseModule("declaration_artifacts_resolved.mc",
        \\struct Box {
        \\    value: u32,
        \\}
        \\
        \\global counter: u32 = 1;
        \\
        \\fn inc(x: u32) -> u32 {
        \\    return x + counter;
        \\}
    );
    defer parsed.deinit();

    var resolved_decls = try std.testing.allocator.alloc(module_parser.ResolvedDecl, parsed.decls().len);
    defer std.testing.allocator.free(resolved_decls);
    for (parsed.decls(), 0..) |decl, i| {
        resolved_decls[i] = .{
            .file_id = @enumFromInt(0),
            .decl = decl,
        };
    }

    var from_resolved = try EarlyDeclarationArtifacts.collectFromResolvedDecls(std.testing.allocator, resolved_decls);
    defer from_resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), from_resolved.decl_artifacts.len);
    try std.testing.expectEqual(@as(usize, 3), from_resolved.source_map_artifacts.len);
    var saw_function = false;
    var saw_global = false;
    var saw_struct = false;
    for (from_resolved.decl_artifacts) |artifact| switch (artifact) {
        .function => |function| {
            try std.testing.expectEqualStrings("inc", function.name.text);
            saw_function = true;
        },
        .global => |global| {
            try std.testing.expectEqualStrings("counter", global.name.text);
            saw_global = true;
        },
        .type_decl => |type_decl| {
            try std.testing.expectEqualStrings("Box", type_decl.struct_decl.name.text);
            saw_struct = true;
        },
        else => {},
    };
    try std.testing.expect(saw_function);
    try std.testing.expect(saw_global);
    try std.testing.expect(saw_struct);
}
