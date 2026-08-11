const ast = @import("ast.zig");

/// Transitional declaration slice for backend mechanics that still need
/// not-yet-normalized declarations. This is narrower than exposing a syntax
/// module at backend entrypoints: every call site must name the remaining
/// legacy declaration dependency explicitly.
pub const LegacyDeclarationSlice = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) LegacyDeclarationSlice {
        return .{ .decls = decls };
    }

    pub fn declsForEarlyDeclarationScan(self: LegacyDeclarationSlice) []const ast.Decl {
        return self.decls;
    }
};

/// Transitional source-map mechanics view. Source maps still enumerate syntax
/// spans until map rows are normalized into MIR/source-span tables, but this
/// keeps that escape separate from backend semantic lowering and declaration
/// metadata.
pub const SourceMapMechanicsView = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) SourceMapMechanicsView {
        return .{ .decls = decls };
    }

    pub fn declsForRowEnumeration(self: SourceMapMechanicsView) []const ast.Decl {
        return self.decls;
    }
};
