const ast = @import("ast.zig");

/// Transitional source-map mechanics view. Source maps still enumerate syntax
/// spans until map rows are normalized into MIR/source-span tables, but this
/// keeps map-only AST access separate from backend semantic lowering and early
/// declaration metadata.
pub const SourceMapMechanicsView = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) SourceMapMechanicsView {
        return .{ .decls = decls };
    }

    pub fn declsForRowEnumeration(self: SourceMapMechanicsView) []const ast.Decl {
        return self.decls;
    }
};
