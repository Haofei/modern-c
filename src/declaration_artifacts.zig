//! Declaration artifacts for the remaining codegen compatibility edge.
//! Backends consume these through `codegen_request`, not raw declaration slices.

const ast = @import("ast.zig");
const attr_syntax = @import("attr_syntax.zig");
const codegen_attrs = @import("codegen_attrs.zig");
const module_parser = @import("module_parser.zig");
const std = @import("std");

/// Transitional declaration artifacts isolated from backend lowering requests.
pub const EarlyDeclarationArtifacts = struct {
    decl_artifacts: []const DeclArtifact,
    function_body_fallbacks: []const FunctionBodyFallbackArtifact,
    source_map_artifacts: []const SourceMapArtifact,

    fn collectFromResolvedDeclItems(allocator: std.mem.Allocator, resolved_decls: anytype) !EarlyDeclarationArtifacts {
        var decl_artifacts: std.ArrayList(DeclArtifact) = .empty;
        errdefer decl_artifacts.deinit(allocator);
        var function_body_fallbacks: std.ArrayList(FunctionBodyFallbackArtifact) = .empty;
        errdefer function_body_fallbacks.deinit(allocator);
        var source_map_artifacts: std.ArrayList(SourceMapArtifact) = .empty;
        errdefer source_map_artifacts.deinit(allocator);

        for (resolved_decls) |item| {
            const decl = item.decl;
            switch (decl.kind) {
                .fn_decl => |fn_decl| {
                    try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, false) });
                    if (fn_decl.body) |body| try function_body_fallbacks.append(allocator, .{ .name = fn_decl.name.text, .syntax = body });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .extern_fn => |fn_decl| {
                    try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, true) });
                    if (fn_decl.body) |body| try function_body_fallbacks.append(allocator, .{ .name = fn_decl.name.text, .syntax = body });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .global_decl => |global| {
                    try decl_artifacts.append(allocator, .{ .global = GlobalArtifact.fromDecl(global) });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .type_alias => |alias| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .type_alias = alias } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .struct_decl => |struct_decl| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .struct_decl = struct_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .enum_decl => |enum_decl| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .enum_decl = enum_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .union_decl => |union_decl| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .union_decl = union_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .packed_bits_decl => |packed_bits_decl| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .packed_bits_decl = packed_bits_decl } });
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .overlay_union_decl => |overlay_union| {
                    try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .overlay_union_decl = overlay_union } });
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
        const owned_function_body_fallbacks = try function_body_fallbacks.toOwnedSlice(allocator);
        errdefer allocator.free(owned_function_body_fallbacks);
        const owned_source_map_artifacts = try source_map_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_source_map_artifacts);

        return .{
            .decl_artifacts = owned_decl_artifacts,
            .function_body_fallbacks = owned_function_body_fallbacks,
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
        allocator.free(self.function_body_fallbacks);
        allocator.free(self.source_map_artifacts);
        self.* = empty;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .decl_artifacts = &.{},
        .function_body_fallbacks = &.{},
        .source_map_artifacts = &.{},
    };

    pub fn codegen(self: EarlyDeclarationArtifacts) CodegenDeclarationArtifacts {
        return .{
            .decl_artifacts = self.decl_artifacts,
            .function_body_fallbacks = self.function_body_fallbacks,
        };
    }
};

/// Transitional ordinary-codegen artifact view.
///
/// Source-map row mechanics are deliberately excluded from `LowerRequest`; only
/// `EmitMapRequest` receives `SourceMapArtifact` rows. This keeps ordinary
/// C/LLVM lowering from growing accidental source-map syntax ingress while the
/// remaining declaration-shaped payload is migrated into verified MIR facts.
pub const CodegenDeclarationArtifacts = struct {
    decl_artifacts: []const DeclArtifact,
    function_body_fallbacks: []const FunctionBodyFallbackArtifact,

    pub const empty = CodegenDeclarationArtifacts{
        .decl_artifacts = &.{},
        .function_body_fallbacks = &.{},
    };

    pub fn legacyFunctionBody(self: CodegenDeclarationArtifacts, name: []const u8) ?ast.Block {
        return findLegacyFunctionBody(self.function_body_fallbacks, name);
    }
};

pub fn findLegacyFunctionBody(fallbacks: []const FunctionBodyFallbackArtifact, name: []const u8) ?ast.Block {
    for (fallbacks) |fallback| {
        if (std.mem.eql(u8, fallback.name, name)) return fallback.syntax;
    }
    return null;
}

fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |origin| return origin,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

pub const FunctionArtifact = struct {
    signature: codegen_attrs.FunctionSignatureFacts,
    body_facts: codegen_attrs.FunctionBodyFacts,
    render_attrs: codegen_attrs.FunctionRenderAttrs,

    pub fn fromDecl(fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool) FunctionArtifact {
        return .{
            .signature = .{
                .name = fn_decl.name,
                .params = fn_decl.params,
                .return_type = fn_decl.return_type,
                .exported = fn_decl.exported,
                .is_extern = is_extern,
                .is_const = fn_decl.is_const,
                .is_variadic = fn_decl.is_variadic,
                .c_abi = fn_decl.is_variadic or fn_decl.abi != null or (fn_decl.exported and !hasNamedAttr(attrs, "mc_abi")),
                .error_from = hasNamedAttr(attrs, "error_from"),
                .backend_name = backendNameOverride(attrs),
            },
            .body_facts = .{
                .has_definition = fn_decl.body != null,
            },
            .render_attrs = attr_syntax.functionRenderAttrs(attrs),
        };
    }
};

/// Compatibility edge for function-body lowering that still needs source-shaped
/// blocks. It is kept out of `FunctionArtifact` so ordinary declaration facts do
/// not grow another syntax body authority while MIR-body lowering is completed.
pub const FunctionBodyFallbackArtifact = struct {
    name: []const u8,
    syntax: ast.Block,
};

pub const GlobalArtifact = struct {
    signature: codegen_attrs.GlobalSignatureFacts,
    initializer: codegen_attrs.GlobalInitFacts,

    pub fn fromDecl(global: ast.GlobalDecl) GlobalArtifact {
        return .{
            .signature = .{
                .name = global.name,
                .ty = global.ty,
                .is_const = global.is_const,
                .exported = global.exported,
                .is_extern = global.is_extern,
            },
            .initializer = .{
                .init = global.init,
            },
        };
    }
};

pub const TraitDeclArtifact = struct {
    facts: codegen_attrs.TraitDeclFacts,

    pub fn fromDecl(trait_decl: ast.TraitDecl) TraitDeclArtifact {
        return .{
            .facts = .{
                .name = trait_decl.name,
                .methods = trait_decl.methods,
            },
        };
    }
};

pub const ImplTraitArtifact = struct {
    facts: codegen_attrs.ImplTraitFacts,

    pub fn fromDecl(impl_trait: ast.ImplTrait) ImplTraitArtifact {
        return .{
            .facts = .{
                .trait_name = impl_trait.trait_name,
                .type_name = impl_trait.type_name,
                .methods = impl_trait.methods,
            },
        };
    }
};

pub const DeclArtifact = union(enum) {
    function: FunctionArtifact,
    global: GlobalArtifact,
    trait_decl: TraitDeclArtifact,
    impl_trait: ImplTraitArtifact,
    transitional_type_decl: TransitionalTypeDeclArtifact,
};

pub const TransitionalTypeDeclArtifact = union(enum) {
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

fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |named| if (std.mem.eql(u8, named.text, name)) return true,
        else => {},
    };
    return false;
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
            try std.testing.expectEqualStrings("inc", function.signature.name.text);
            saw_function = true;
        },
        .global => |global| {
            try std.testing.expectEqualStrings("counter", global.signature.name.text);
            saw_global = true;
        },
        .transitional_type_decl => |type_decl| {
            try std.testing.expectEqualStrings("Box", type_decl.struct_decl.name.text);
            saw_struct = true;
        },
        else => {},
    };
    try std.testing.expect(saw_function);
    try std.testing.expect(saw_global);
    try std.testing.expect(saw_struct);
}
