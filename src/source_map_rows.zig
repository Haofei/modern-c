const ast = @import("ast.zig");
const early_declaration_metadata = @import("early_declaration_metadata.zig");
const std = @import("std");

/// Transitional source-map row artifacts. Source maps still need syntax spans
/// until rows are generated from MIR/source-span tables, but declaration
/// enumeration is isolated here instead of being exposed through backend map
/// requests.
pub const SourceMapRows = struct {
    artifacts: []const RowArtifact,

    pub fn collectFromArtifacts(
        allocator: std.mem.Allocator,
        decls: []const early_declaration_metadata.DeclArtifact,
        origins: []const []const u8,
    ) !SourceMapRows {
        if (decls.len != origins.len) return error.InvalidSourceMapRows;
        var artifacts: std.ArrayList(RowArtifact) = .empty;
        errdefer artifacts.deinit(allocator);
        for (decls, origins) |decl, origin| {
            if (RowArtifact.fromDeclArtifact(decl, origin)) |artifact| {
                try artifacts.append(allocator, artifact);
            }
        }
        return .{ .artifacts = try artifacts.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *SourceMapRows, allocator: std.mem.Allocator) void {
        allocator.free(self.artifacts);
        self.* = .{ .artifacts = &.{} };
    }
};

pub const RowArtifact = union(enum) {
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

    fn fromDeclArtifact(decl: early_declaration_metadata.DeclArtifact, origin: []const u8) ?RowArtifact {
        return switch (decl) {
            .global => |global| .{ .global = .{
                .symbol = global.name.text,
                .name_span = global.name.span,
                .init_span = if (global.init) |init| init.span else null,
                .is_const = global.is_const,
                .origin = origin,
            } },
            .function => |function| if (function.fn_decl.body) |body| .{ .function = .{
                .symbol = function.fn_decl.name.text,
                .name_span = function.fn_decl.name.span,
                .body = body,
                .object_symbol = backendNameOverride(function.attrs) orelse function.fn_decl.name.text,
                .exported = function.fn_decl.exported,
                .origin = origin,
            } } else .{ .extern_fn = .{
                .symbol = function.fn_decl.name.text,
                .name_span = function.fn_decl.name.span,
                .origin = origin,
            } },
            .extern_function => |function| .{ .extern_fn = .{
                .symbol = function.fn_decl.name.text,
                .name_span = function.fn_decl.name.span,
                .origin = origin,
            } },
            else => if (declArtifactTypeName(decl)) |name| .{ .type_decl = .{
                .kind = declArtifactKindName(decl),
                .symbol = name.text,
                .name_span = name.span,
                .origin = origin,
            } } else null,
        };
    }
};

fn backendNameOverride(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| switch (attr.kind) {
        .backend_name => |name| return name,
        else => {},
    };
    return null;
}

fn declArtifactTypeName(decl: early_declaration_metadata.DeclArtifact) ?ast.Ident {
    return switch (decl) {
        .struct_decl => |node| node.name,
        .enum_decl => |node| node.name,
        .union_decl => |node| node.name,
        .packed_bits => |node| node.name,
        .overlay_union => |node| node.name,
        .opaque_decl => |name| name,
        .type_alias => |node| node.name,
        else => null,
    };
}

fn declArtifactKindName(decl: early_declaration_metadata.DeclArtifact) []const u8 {
    return switch (decl) {
        .struct_decl => "struct",
        .enum_decl => "enum",
        .union_decl => "union",
        .packed_bits => "packed_bits",
        .overlay_union => "overlay_union",
        .opaque_decl => "opaque",
        .type_alias => "type_alias",
        else => "decl",
    };
}
