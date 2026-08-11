const ast = @import("ast.zig");

pub const DeclarationSlice = []const ast.Decl;

/// Transitional declaration slice for backend mechanics that still need
/// not-yet-normalized declarations. This is narrower than exposing a syntax
/// module at backend entrypoints: every call site must name the remaining
/// legacy declaration dependency explicitly.
pub const LegacyDeclarationSlice = struct {
    decls: DeclarationSlice,

    pub fn forDecls(decls: DeclarationSlice) LegacyDeclarationSlice {
        return .{ .decls = decls };
    }

    pub fn earlyDeclarationMetadata(self: LegacyDeclarationSlice) EarlyDeclarationMetadataView {
        return .{ .decls = self.decls };
    }
};

/// Transitional early declaration metadata view.
///
/// This is intentionally distinct from `LegacyDeclarationSlice`: early
/// declaration prepasses still read top-level syntax declarations, but callers
/// must now name that specific metadata dependency instead of opening the full
/// legacy declaration slice for arbitrary scans.
pub const EarlyDeclarationMetadataView = struct {
    decls: DeclarationSlice,

    pub fn declsForEarlyDeclarationScan(self: EarlyDeclarationMetadataView) DeclarationSlice {
        return self.decls;
    }
};
