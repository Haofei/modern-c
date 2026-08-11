const ast = @import("ast.zig");

pub const DeclarationSlice = []const ast.Decl;

/// Transitional early declaration metadata view.
///
/// Early declaration prepasses still read top-level syntax declarations, but
/// callers must name that specific metadata dependency instead of opening a
/// generic legacy declaration handle for arbitrary scans.
pub const EarlyDeclarationMetadataView = struct {
    decls: DeclarationSlice,

    pub fn forDecls(decls: DeclarationSlice) EarlyDeclarationMetadataView {
        return .{ .decls = decls };
    }

    pub fn declsForEarlyDeclarationScan(self: EarlyDeclarationMetadataView) DeclarationSlice {
        return self.decls;
    }
};
