const ast = @import("ast.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const std = @import("std");

/// Transitional source-map row artifacts. Source maps still need syntax spans
/// until rows are generated from MIR/source-span tables, but declaration
/// enumeration is isolated here instead of being exposed through backend map
/// requests.
pub const SourceMapRows = struct {
    artifacts: []const RowArtifact,

    pub fn collectFromSourceArtifacts(
        allocator: std.mem.Allocator,
        source_artifacts: []const declaration_artifacts.SourceMapArtifact,
    ) !SourceMapRows {
        var artifacts: std.ArrayList(RowArtifact) = .empty;
        errdefer artifacts.deinit(allocator);
        for (source_artifacts) |artifact| try artifacts.append(allocator, RowArtifact.fromSourceMapArtifact(artifact));
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

    fn fromSourceMapArtifact(artifact: declaration_artifacts.SourceMapArtifact) RowArtifact {
        return switch (artifact) {
            .global => |global| .{ .global = .{
                .symbol = global.symbol,
                .name_span = global.name_span,
                .init_span = global.init_span,
                .is_const = global.is_const,
                .origin = global.origin,
            } },
            .function => |function| .{ .function = .{
                .symbol = function.symbol,
                .name_span = function.name_span,
                .body = function.body,
                .object_symbol = function.object_symbol,
                .exported = function.exported,
                .origin = function.origin,
            } },
            .extern_fn => |function| .{ .extern_fn = .{
                .symbol = function.symbol,
                .name_span = function.name_span,
                .origin = function.origin,
            } },
            .type_decl => |decl| .{ .type_decl = .{
                .kind = decl.kind,
                .symbol = decl.symbol,
                .name_span = decl.name_span,
                .origin = decl.origin,
            } },
        };
    }
};
