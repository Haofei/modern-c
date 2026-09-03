//! Transitional AST-span to MIR-source-point bridge.
//!
//! Backends still receive syntax while MIR facts are keyed by `SourcePoint`.
//! Keep that compatibility conversion here so C/LLVM do not each define their
//! own source matching policy while the VerifiedProgram boundary is being
//! migrated to typed identities.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const mir = @import("mir.zig");
const mir_facts_view = @import("mir_facts_view.zig");
const signature_type_materializer = @import("signature_type_materializer.zig");
const type_bridge = @import("type_bridge.zig");

const MirFactsView = mir_facts_view.MirFactsView;
pub const TargetTypeLookupKey = mir_facts_view.TargetTypeLookupKey;

pub fn sourcePointFromOptionalSpan(span: ?ast_bridge.Span) ?mir.SourcePoint {
    return if (span) |value| mir.sourcePointFromSpan(value) else null;
}

pub fn isSourceSpan(span: ast_bridge.Span) bool {
    return mir_facts_view.sourcePointHasLineColumn(mir.sourcePointFromSpan(span));
}

pub fn firstCallTargetKindAt(current: ?*const mir.Function, span: ast_bridge.Span) ?mir.CallTargetKind {
    return MirFactsView.init().firstCallTargetKindAt(current, mir.sourcePointFromSpan(span));
}

pub fn uniqueCallTargetKindAt(current: ?*const mir.Function, span: ast_bridge.Span) ?mir.CallTargetKind {
    return MirFactsView.init().uniqueCallTargetKindAt(current, mir.sourcePointFromSpan(span));
}

pub fn hasCallTargetKindAt(current: ?*const mir.Function, kind: mir.CallTargetKind, span: ast_bridge.Span) bool {
    return MirFactsView.init().hasCallTargetKindAt(current, kind, mir.sourcePointFromSpan(span));
}

pub fn targetTypeFactById(current: *const mir.Function, key: TargetTypeLookupKey) ?mir.TargetTypeFact {
    return MirFactsView.init().targetTypeFactById(current, key);
}

pub fn targetTypeFactAtCurrentSpan(current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?mir.TargetTypeFact {
    return MirFactsView.init().targetTypeFactAtCurrentSpan(.{
        .current = current,
        .fact = .{
            .kind = kind,
            .source = mir.sourcePointFromSpan(span),
        },
    });
}

/// Syntax-to-MIR compatibility lookup for a float literal's canonical MIR
/// type. Unlike `TargetTypeFact`, this carries no `ast.TypeExpr`.
pub fn floatTargetTypeAtCurrentSpan(current: ?*const mir.Function, span: ast_bridge.Span) ?mir.ValueType {
    return MirFactsView.init().floatTargetTypeAtCurrentSpan(current, mir.sourcePointFromSpan(span));
}

pub fn atomicInitPayloadTypeAt(allocator: std.mem.Allocator, current: ?*const mir.Function, signature_types: mir.SignatureTypeTable, type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr), span: ast_bridge.Span, expected_result_ty: ast_bridge.TypeExpr, expected_payload_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    const function = current orelse return null;
    const view = MirFactsView.init();
    const source = mir.sourcePointFromSpan(span);
    const owner_id = view.targetOwnerIdBySpelling(function, "atomic.init") orelse return null;
    const resolved_result_ty = type_bridge.resolveAliasType(type_aliases, expected_result_ty);
    const resolved_expected_payload_ty = type_bridge.resolveAliasType(type_aliases, expected_payload_ty);
    var matched_payload_ty: ?ast_bridge.TypeExpr = null;
    var found_result = false;
    for (function.target_type_facts) |result_fact| {
        if (result_fact.target_index == null or !view.targetTypeFactMatchesFamily(function, result_fact, .atomic_init_result, source, owner_id)) continue;
        const result_ty = signature_type_materializer.typeExpr(allocator, signature_types, result_fact.target_type_id, expected_result_ty.span) catch return null;
        if (!type_bridge.sameTypeSyntax(type_bridge.resolveAliasType(type_aliases, result_ty), resolved_result_ty)) continue;
        found_result = true;

        var group_payload_ty: ?ast_bridge.TypeExpr = null;
        for (function.target_type_facts) |payload_fact| {
            if (payload_fact.target_index != result_fact.target_index or !view.targetTypeFactMatchesFamily(function, payload_fact, .atomic_init_payload, source, owner_id)) continue;
            const payload_ty = signature_type_materializer.typeExpr(allocator, signature_types, payload_fact.target_type_id, expected_payload_ty.span) catch return null;
            if (!type_bridge.sameTypeSyntax(type_bridge.resolveAliasType(type_aliases, payload_ty), resolved_expected_payload_ty)) return null;
            if (group_payload_ty) |known| {
                if (!type_bridge.sameTypeSyntax(type_bridge.resolveAliasType(type_aliases, known), type_bridge.resolveAliasType(type_aliases, payload_ty))) return null;
            }
            group_payload_ty = payload_ty;
        }
        const payload_ty = group_payload_ty orelse return null;
        if (matched_payload_ty) |known| {
            if (!type_bridge.sameTypeSyntax(type_bridge.resolveAliasType(type_aliases, known), type_bridge.resolveAliasType(type_aliases, payload_ty))) return null;
        }
        matched_payload_ty = payload_ty;
    }
    if (!found_result) return null;
    return matched_payload_ty;
}

pub fn targetTypeFactAtOwnedCurrentSpan(current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast_bridge.Span, owner_id: mir.SymbolId, target_index: ?usize) ?mir.TargetTypeFact {
    const function = current orelse return null;
    const view = MirFactsView.init();
    if (!owner_id.isValid()) return null;
    return view.targetTypeFactAtOwnedCurrentSpan(.{
        .current = function,
        .fact = .{
            .kind = kind,
            .source = mir.sourcePointFromSpan(span),
            .typed_target_owner_id = owner_id,
            .index = target_index,
        },
    });
}

pub fn uniqueConstGetIndexAt(current: ?*const mir.Function, span: ast_bridge.Span) ?usize {
    return MirFactsView.init().uniqueConstGetIndexAt(current, mir.sourcePointFromSpan(span));
}

pub fn pointerFactMatchesAt(fact: mir.PointerProvenanceFact, subject: []const u8, element_index: ?usize, span: ast_bridge.Span) bool {
    return MirFactsView.init().pointerFactMatchesQuery(fact, .{
        .subject = subject,
        .element_index = element_index,
        .source = mir.sourcePointFromSpan(span),
    });
}

pub fn aggregatePointerFieldFactMatchesAt(fact: mir.PointerProvenanceFact, subject: []const u8, field_path: []const u8, element_index: ?usize, span: ast_bridge.Span) bool {
    return MirFactsView.init().pointerFactMatchesQuery(fact, .{
        .subject = subject,
        .field_path = field_path,
        .element_index = element_index,
        .source = mir.sourcePointFromSpan(span),
    });
}

pub fn pointerFactIsCallInvalidationAt(fact: mir.PointerProvenanceFact, span: ast_bridge.Span) bool {
    return MirFactsView.init().pointerFactIsCallInvalidationAt(fact, mir.sourcePointFromSpan(span));
}

pub fn pointerFactMatchesSubjectFieldAt(fact: mir.PointerProvenanceFact, subject: []const u8, span: ast_bridge.Span) bool {
    return MirFactsView.init().pointerFactMatchesSubjectFieldAtSource(fact, subject, mir.sourcePointFromSpan(span));
}

pub fn pointerFactIsLiveGlobal(fact: mir.PointerProvenanceFact) bool {
    return mir_facts_view.pointerFactIsLiveGlobal(fact);
}

pub fn pointerFactIsLiveLocal(fact: mir.PointerProvenanceFact) bool {
    return mir_facts_view.pointerFactIsLiveLocal(fact);
}

pub fn pointerFactLiveState(fact: mir.PointerProvenanceFact) mir.PointerProvenance {
    return mir_facts_view.pointerFactLiveState(fact);
}
