//! Declaration artifacts for the remaining codegen compatibility edge.
//! Backends consume these through `codegen_request`, not raw declaration slices.

const ast = @import("ast.zig");
const mir = @import("mir_model.zig");
const module_parser = @import("module_parser.zig");
const std = @import("std");

/// Frontend-owned declarations that are callable while evaluating comptime
/// expressions. Its AST bodies are authority for const evaluation, not
/// ordinary code generation.
pub const ComptimeFunctionDeclarations = struct {
    functions: []const ast.FnDecl,

    pub const empty = ComptimeFunctionDeclarations{
        .functions = &.{},
    };
};

/// Transitional declaration artifacts isolated from backend lowering requests.
pub const EarlyDeclarationArtifacts = struct {
    comptime_functions: ComptimeFunctionDeclarations,
    source_map_artifacts: []const SourceMapArtifact,

    fn collectFromResolvedDeclItems(allocator: std.mem.Allocator, resolved_decls: anytype, typed_mir: *const mir.Module) !EarlyDeclarationArtifacts {
        _ = typed_mir;
        var comptime_functions: std.ArrayList(ast.FnDecl) = .empty;
        errdefer comptime_functions.deinit(allocator);
        var source_map_artifacts: std.ArrayList(SourceMapArtifact) = .empty;
        errdefer source_map_artifacts.deinit(allocator);

        for (resolved_decls, 0..) |item, ordinal| {
            const decl = item.decl;
            _ = ordinal;
            switch (decl.kind) {
                .fn_decl => |fn_decl| {
                    if (fn_decl.is_const) try comptime_functions.append(allocator, fn_decl);
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .extern_fn => |fn_decl| {
                    if (fn_decl.is_const) try comptime_functions.append(allocator, fn_decl);
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .global_decl => |global| {
                    _ = global;
                    // VerifiedProgram admission owns the required-plan check.
                    // This boundary retains source-map mechanics only, so it
                    // cannot mask a malformed MIR row with a source fallback.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .type_alias => {
                    // Alias targets are module-owned SignatureTypeTable facts.
                    // Keep source-map metadata, but never retain the alias AST
                    // on the ordinary codegen ingress.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .struct_decl => {
                    // Ordinary aggregate shape/layout is a module-owned MIR
                    // fact; preserve only source-map metadata here.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .enum_decl => {
                    // Enum representation and checked discriminants are
                    // module-owned MIR facts. Keep only source-map metadata;
                    // ordinary codegen must not retain an enum AST payload.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .union_decl => {
                    // Tags, payload shapes, and canonical aggregate layout are
                    // module-owned MIR facts. Keep only source-map metadata.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .packed_bits_decl => {
                    // Representation and bit positions are checked MIR facts.
                    // Preserve source-map metadata only; ordinary codegen no
                    // longer retains a packed-bits AST declaration payload.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .overlay_union_decl => {
                    // Storage and field layouts are checked MIR facts. Keep
                    // source-map metadata only; codegen owns no overlay AST
                    // declaration payload.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .opaque_decl => {
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .trait_decl => {
                    // Dynamic trait objects are an experimental frontend feature.
                    // Static trait calls have already been monomorphized into ordinary
                    // functions, so no trait declaration syntax belongs on the
                    // ordinary codegen ingress.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
                .impl_trait => {
                    // See `.trait_decl`: implementations do not carry backend
                    // payload unless the removed dynamic-vtable lowering is used.
                    if (sourceMapArtifactFromDecl(decl)) |artifact| try source_map_artifacts.append(allocator, artifact);
                },
            }
        }

        const owned_comptime_functions = try comptime_functions.toOwnedSlice(allocator);
        errdefer allocator.free(owned_comptime_functions);
        const owned_source_map_artifacts = try source_map_artifacts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_source_map_artifacts);

        return .{
            .comptime_functions = .{ .functions = owned_comptime_functions },
            .source_map_artifacts = owned_source_map_artifacts,
        };
    }

    /// Collect declaration artifacts from the per-file resolved declaration stream.
    pub fn collectFromResolvedDecls(
        allocator: std.mem.Allocator,
        resolved_decls: []const module_parser.ResolvedDecl,
        typed_mir: *const mir.Module,
    ) !EarlyDeclarationArtifacts {
        return collectFromResolvedDeclItems(allocator, resolved_decls, typed_mir);
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.comptime_functions.functions);
        allocator.free(self.source_map_artifacts);
        self.* = empty;
    }

    pub const empty = EarlyDeclarationArtifacts{
        .comptime_functions = .empty,
        .source_map_artifacts = &.{},
    };

    pub fn codegen(self: EarlyDeclarationArtifacts) CodegenDeclarationArtifacts {
        return .{
            .comptime_functions = self.comptime_functions,
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
    // Borrowed frontend comptime provider.  It crosses the compatibility
    // request only so existing backend setup can initialize eval.
    comptime_functions: ComptimeFunctionDeclarations = .empty,

    pub const empty = CodegenDeclarationArtifacts{
        .comptime_functions = .empty,
    };
};

fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |origin| return origin,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

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
            .def_id = .{ .file_id = 0, .ordinal = @intCast(i) },
            .file_id = @enumFromInt(0),
            .decl = decl,
        };
    }

    var module_mir = try @import("mir.zig").buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var from_resolved = try EarlyDeclarationArtifacts.collectFromResolvedDecls(std.testing.allocator, resolved_decls, &module_mir);
    defer from_resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), from_resolved.source_map_artifacts.len);
}

test "declaration artifacts omit folded scalar const globals but retain source-map rows" {
    const test_support = @import("test_support.zig");
    var parsed = try test_support.parseModule("declaration_artifacts_scalar_const.mc",
        \\const count: u32 = 1 + 2;
        \\fn read() -> u32 { return count; }
    );
    defer parsed.deinit();
    var module_mir = try @import("mir.zig").buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var resolved_decls = try std.testing.allocator.alloc(module_parser.ResolvedDecl, parsed.decls().len);
    defer std.testing.allocator.free(resolved_decls);
    for (parsed.decls(), 0..) |decl, index| {
        resolved_decls[index] = .{
            .def_id = .{ .file_id = 0, .ordinal = @intCast(index) },
            .file_id = @enumFromInt(0),
            .decl = decl,
        };
    }
    var artifacts = try EarlyDeclarationArtifacts.collectFromResolvedDecls(std.testing.allocator, resolved_decls, &module_mir);
    defer artifacts.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), artifacts.source_map_artifacts.len);
}
