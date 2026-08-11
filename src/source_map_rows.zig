const ast = @import("ast.zig");

/// Transitional source-map rows view. Source maps still enumerate syntax spans
/// until map rows are normalized into MIR/source-span tables, but this keeps
/// map-only AST access separate from backend semantic lowering and early
/// declaration metadata.
pub const SourceMapRowsView = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) SourceMapRowsView {
        return .{ .decls = decls };
    }

    pub fn declsForRowEnumeration(self: SourceMapRowsView) []const ast.Decl {
        return self.decls;
    }
};
