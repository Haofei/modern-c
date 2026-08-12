//! Transitional AST-span to MIR-source-point bridge.
//!
//! Backends still receive syntax while MIR facts are keyed by `SourcePoint`.
//! Keep that compatibility conversion here so C/LLVM do not each define their
//! own source matching policy while the VerifiedProgram boundary is being
//! migrated to typed identities.

const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_facts_view = @import("mir_facts_view.zig");

pub fn sourcePointMatchesSpan(source: mir.SourcePoint, span: ast.Span) bool {
    return mir_facts_view.sourcePointExactMatches(source, mir.sourcePointFromSpan(span));
}

pub fn sourcePointFromOptionalSpan(span: ?ast.Span) ?mir.SourcePoint {
    return if (span) |value| mir.sourcePointFromSpan(value) else null;
}

pub fn isSourceSpan(span: ast.Span) bool {
    return mir_facts_view.sourcePointHasLineColumn(mir.sourcePointFromSpan(span));
}
