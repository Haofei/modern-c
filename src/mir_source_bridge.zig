//! Transitional AST-span to MIR-source-point bridge.
//!
//! Backends still receive syntax while MIR facts are keyed by `SourcePoint`.
//! Keep that compatibility conversion here so C/LLVM do not each define their
//! own source matching policy while the VerifiedProgram boundary is being
//! migrated to typed identities.

const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_facts_view = @import("mir_facts_view.zig");

const MirFactsView = mir_facts_view.MirFactsView;

pub fn sourcePointMatchesSpan(source: mir.SourcePoint, span: ast.Span) bool {
    return mir_facts_view.sourcePointExactMatches(source, mir.sourcePointFromSpan(span));
}

pub fn sourcePointFromOptionalSpan(span: ?ast.Span) ?mir.SourcePoint {
    return if (span) |value| mir.sourcePointFromSpan(value) else null;
}

pub fn isSourceSpan(span: ast.Span) bool {
    return mir_facts_view.sourcePointHasLineColumn(mir.sourcePointFromSpan(span));
}

pub fn firstCallTargetKindAt(module: *const mir.Module, current: ?*const mir.Function, span: ast.Span) ?mir.CallTargetKind {
    return MirFactsView.init(module).firstCallTargetKindAt(current, mir.sourcePointFromSpan(span));
}

pub fn uniqueCallTargetKindAt(module: *const mir.Module, current: ?*const mir.Function, span: ast.Span) ?mir.CallTargetKind {
    return MirFactsView.init(module).uniqueCallTargetKindAt(current, mir.sourcePointFromSpan(span));
}

pub fn hasCallTargetKindAt(module: *const mir.Module, current: ?*const mir.Function, kind: mir.CallTargetKind, span: ast.Span, strict_call_source: bool) bool {
    return MirFactsView.init(module).hasCallTargetKindAt(current, kind, mir.sourcePointFromSpan(span), strict_call_source);
}

pub fn targetTypeFactAtWithModuleFallback(module: *const mir.Module, current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast.Span) ?mir.TargetTypeFact {
    return MirFactsView.init(module).targetTypeFactAtWithModuleFallback(current, kind, mir.sourcePointFromSpan(span));
}

pub fn targetTypeFactAtOwnedWithModuleFallback(module: *const mir.Module, current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?mir.TargetTypeFact {
    return MirFactsView.init(module).targetTypeFactAtOwnedWithModuleFallback(current, kind, mir.sourcePointFromSpan(span), target_owner, target_index);
}

pub fn uniqueConstGetIndexAt(module: *const mir.Module, current: ?*const mir.Function, span: ast.Span) ?usize {
    return MirFactsView.init(module).uniqueConstGetIndexAt(current, mir.sourcePointFromSpan(span));
}
