const ast = @import("ast.zig");
const std = @import("std");

/// Transitional source-map row artifacts. Source maps still need syntax spans
/// until rows are generated from MIR/source-span tables, but declaration
/// enumeration is isolated here instead of being exposed through backend map
/// requests.
pub const SourceMapRows = struct {
    artifacts: []const RowArtifact,

    pub fn collectFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl) !SourceMapRows {
        var artifacts: std.ArrayList(RowArtifact) = .empty;
        errdefer artifacts.deinit(allocator);
        for (decls) |decl| {
            if (RowArtifact.fromDecl(decl)) |artifact| {
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

    fn fromDecl(decl: ast.Decl) ?RowArtifact {
        return switch (decl.kind) {
            .global_decl => |global| .{ .global = .{
                .symbol = global.name.text,
                .name_span = global.name.span,
                .init_span = if (global.init) |init| init.span else null,
                .is_const = global.is_const,
                .origin = declOrigin(decl),
            } },
            .fn_decl => |fn_decl| if (fn_decl.body) |body| .{ .function = .{
                .symbol = fn_decl.name.text,
                .name_span = fn_decl.name.span,
                .body = body,
                .object_symbol = backendNameOverride(decl.attrs) orelse fn_decl.name.text,
                .exported = fn_decl.exported,
                .origin = declOrigin(decl),
            } } else .{ .extern_fn = .{
                .symbol = fn_decl.name.text,
                .name_span = fn_decl.name.span,
                .origin = declOrigin(decl),
            } },
            .extern_fn => |fn_decl| .{ .extern_fn = .{
                .symbol = fn_decl.name.text,
                .name_span = fn_decl.name.span,
                .origin = declOrigin(decl),
            } },
            else => if (declTypeName(decl.kind)) |name| .{ .type_decl = .{
                .kind = declKindName(decl.kind),
                .symbol = name.text,
                .name_span = name.span,
                .origin = declOrigin(decl),
            } } else null,
        };
    }
};

fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |origin| return origin,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

fn backendNameOverride(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| switch (attr.kind) {
        .backend_name => |name| return name,
        else => {},
    };
    return null;
}

fn declTypeName(kind: ast.Decl.Kind) ?ast.Ident {
    return switch (kind) {
        .struct_decl => |decl| decl.name,
        .enum_decl => |decl| decl.name,
        .union_decl => |decl| decl.name,
        .packed_bits_decl => |decl| decl.name,
        .overlay_union_decl => |decl| decl.name,
        .opaque_decl => |name| name,
        .type_alias => |decl| decl.name,
        else => null,
    };
}

fn declKindName(kind: ast.Decl.Kind) []const u8 {
    return switch (kind) {
        .struct_decl => "struct",
        .enum_decl => "enum",
        .union_decl => "union",
        .packed_bits_decl => "packed_bits",
        .overlay_union_decl => "overlay_union",
        .opaque_decl => "opaque",
        .type_alias => "type_alias",
        else => "decl",
    };
}
