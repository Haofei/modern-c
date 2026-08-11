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
