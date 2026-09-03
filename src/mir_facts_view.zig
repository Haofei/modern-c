//! Read-only MIR facts exposed to code generators.
//!
//! MIR owns construction and verification.  This module deliberately exposes a
//! small query surface so backends do not each reimplement source-span matching
//! and typed-identity checks while looking up target-type facts.

const std = @import("std");

const mir = @import("mir.zig");

pub const TargetTypeLookupKey = struct {
    kind: mir.TargetTypeKind,
    typed_span_id: mir.SpanId,
    typed_result_ty: ?mir.TypeId = null,
    typed_target_owner_id: ?mir.SymbolId = null,
    target_index: ?usize = null,
};

pub const CallTargetLookupKey = struct {
    kind: mir.CallTargetKind,
    typed_span_id: mir.SpanId,
};

pub const TargetTypeFactQuery = struct {
    kind: mir.TargetTypeKind,
    source: mir.SourcePoint,
    typed_target_owner_id: ?mir.SymbolId = null,
    index: ?usize = null,
};

pub const TargetTypeCurrentQuery = struct {
    current: ?*const mir.Function,
    fact: TargetTypeFactQuery,
};

pub const PointerFactQuery = struct {
    subject: []const u8,
    source: mir.SourcePoint,
    field_path: ?[]const u8 = null,
    element_index: ?usize = null,
};

pub const MirFactsView = struct {
    pub fn init() MirFactsView {
        return .{};
    }

    /// Returns an unowned, verified target-type fact from the current function.
    ///
    /// This is the preferred source-spanned compatibility query while callers
    /// are being migrated to `targetTypeFactById`.
    pub fn targetTypeFactAt(self: MirFactsView, current: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        if (kind == .expression_result and !isSourcePoint(source)) return null;
        return targetTypeFactInFunction(current, kind, source, null, null);
    }

    /// Current-function source-span compatibility entrypoint. It does not scan
    /// other functions; new code should prefer the ordinary local query or
    /// `targetTypeFactById`.
    pub fn targetTypeFactAtCurrentSpan(self: MirFactsView, query: TargetTypeCurrentQuery) ?mir.TargetTypeFact {
        if (query.current) |function| {
            if (self.targetTypeFactAt(function, query.fact.kind, query.fact.source)) |fact| return fact;
        }
        return null;
    }

    /// Float literal target types are a syntax-free fact family.  A duplicate
    /// or malformed row is intentionally indistinguishable from absence here;
    /// admission rejects it before either backend can render a literal.
    pub fn floatTargetTypeAtCurrentSpan(self: MirFactsView, current: ?*const mir.Function, source: mir.SourcePoint) ?mir.ValueType {
        _ = self;
        const function = current orelse return null;
        var found: ?mir.ValueType = null;
        for (function.float_facts) |fact| {
            if (!sourcePointExactMatches(source, fact.source)) continue;
            if (!floatFactSpanIdentityIsValid(function, fact)) return null;
            const target_ty = mir.floatFactTargetType(function, fact) orelse return null;
            if (found != null) return null;
            found = target_ty;
        }
        return found;
    }

    /// Same local query for fact families whose target belongs to a typed owner
    /// and optional target index (for example atomic-init payload/result pairs).
    pub fn targetTypeFactAtOwned(self: MirFactsView, current: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner_id: mir.SymbolId, index: ?usize) ?mir.TargetTypeFact {
        _ = self;
        if (!owner_id.isValid()) return null;
        return targetTypeFactInFunction(current, kind, source, owner_id, index);
    }

    /// Current-function owner source-span compatibility entrypoint. It does not
    /// scan other functions; new code should prefer `targetTypeFactById`.
    pub fn targetTypeFactAtOwnedCurrentSpan(self: MirFactsView, query: TargetTypeCurrentQuery) ?mir.TargetTypeFact {
        const owner_id = query.fact.typed_target_owner_id orelse return null;
        if (query.current) |function| {
            if (self.targetTypeFactAtOwned(function, query.fact.kind, query.fact.source, owner_id, query.fact.index)) |fact| return fact;
        }
        return null;
    }

    /// Returns a target-type fact by verified typed identities in `current`.
    ///
    /// Typed IDs are function-local interned identities, so this query
    /// intentionally does not fall back to scanning the whole module by source
    /// span or owner spelling.  Callers that already have MIR identities should
    /// use this entry point instead of rebuilding identity from source text.
    pub fn targetTypeFactById(self: MirFactsView, current: *const mir.Function, key: TargetTypeLookupKey) ?mir.TargetTypeFact {
        _ = self;
        return targetTypeFactInFunctionById(current, key);
    }

    /// Resolves a source spelling only at the syntax-to-MIR compatibility
    /// boundary. Facts themselves retain only the function-local SymbolId.
    pub fn targetOwnerIdBySpelling(self: MirFactsView, current: *const mir.Function, spelling: []const u8) ?mir.SymbolId {
        _ = self;
        return mir.targetOwnerIdBySpelling(current.*, spelling);
    }

    /// Returns a call-target fact by verified typed span identity in `current`.
    ///
    /// This is the typed-identity equivalent of the source-spanned call-target
    /// helpers below.  It deliberately has no line/column fallback.
    pub fn callTargetFactById(self: MirFactsView, current: *const mir.Function, key: CallTargetLookupKey) ?mir.CallTargetFact {
        _ = self;
        return callTargetFactInFunctionById(current, key);
    }

    pub fn firstCallTargetKindAt(self: MirFactsView, current: ?*const mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
        _ = self;
        const function = current orelse return null;
        for (function.call_target_facts) |fact| {
            if (sourcePointLineColumnMatches(source, fact.source)) return fact.kind;
        }
        return null;
    }

    pub fn uniqueCallTargetKindAt(self: MirFactsView, current: ?*const mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
        _ = self;
        const function = current orelse return null;
        var matched: ?mir.CallTargetKind = null;
        for (function.call_target_facts) |fact| {
            if (!callTargetSourceMatches(source, fact.source)) continue;
            if (matched) |kind| {
                if (kind != fact.kind) return null;
            } else {
                matched = fact.kind;
            }
        }
        return matched;
    }

    pub fn hasCallTargetKindAt(self: MirFactsView, current: ?*const mir.Function, kind: mir.CallTargetKind, source: mir.SourcePoint, strict_call_source: bool) bool {
        _ = self;
        const function = current orelse return false;
        for (function.call_target_facts) |fact| {
            if (fact.kind != kind) continue;
            const matches = if (strict_call_source)
                callTargetSourceMatches(source, fact.source)
            else
                sourcePointLineColumnMatches(source, fact.source);
            if (matches) return true;
        }
        return false;
    }

    pub fn uniqueConstGetIndexAt(self: MirFactsView, current: ?*const mir.Function, source: mir.SourcePoint) ?usize {
        _ = self;
        const function = current orelse return null;
        var matched: ?usize = null;
        for (function.const_get_facts) |fact| {
            if (!sourcePointLineColumnMatches(source, fact.source)) continue;
            if (matched) |index| {
                if (index != fact.index) return null;
            } else {
                matched = fact.index;
            }
        }
        return matched;
    }

    pub fn targetTypeFactMatchesQuery(self: MirFactsView, current: *const mir.Function, fact: mir.TargetTypeFact, query: TargetTypeFactQuery) bool {
        _ = self;
        return targetTypeFactMatches(current, fact, query);
    }

    pub fn targetTypeFactMatchesFamily(self: MirFactsView, current: *const mir.Function, fact: mir.TargetTypeFact, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner_id: ?mir.SymbolId) bool {
        _ = self;
        if (fact.kind != kind) return false;
        if (!typedOwnerIdMatches(fact.typed_target_owner_id, owner_id)) return false;
        if (!sourceMatches(kind, source, fact.source)) return false;
        return typedIdentityIsValid(current, fact);
    }

    pub fn pointerFactMatchesQuery(self: MirFactsView, fact: mir.PointerProvenanceFact, query: PointerFactQuery) bool {
        _ = self;
        if (!std.mem.eql(u8, fact.subject, query.subject)) return false;
        if (!optionalTextEql(fact.field_path, query.field_path)) return false;
        if (fact.element_index != query.element_index) return false;
        return sourcePointLineColumnMatches(query.source, fact.source);
    }

    pub fn pointerFactMatchesSubjectFieldAtSource(self: MirFactsView, fact: mir.PointerProvenanceFact, subject: []const u8, source: mir.SourcePoint) bool {
        _ = self;
        if (!std.mem.eql(u8, fact.subject, subject)) return false;
        if (fact.field_path == null) return false;
        return sourcePointLineColumnMatches(source, fact.source);
    }

    pub fn pointerFactIsCallInvalidationAt(self: MirFactsView, fact: mir.PointerProvenanceFact, source: mir.SourcePoint) bool {
        _ = self;
        if (!sourcePointLineColumnMatches(source, fact.source)) return false;
        return switch (fact.invalidation_reason) {
            .call, .indirect_call => true,
            else => false,
        };
    }
};

fn targetTypeFactInFunction(function: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner_id: ?mir.SymbolId, index: ?usize) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| {
        if (!targetTypeFactMatches(function, fact, .{ .kind = kind, .source = source, .typed_target_owner_id = owner_id, .index = index })) continue;
        return fact;
    }
    return null;
}

fn floatFactSpanIdentityIsValid(function: *const mir.Function, fact: mir.FloatFact) bool {
    if (!fact.typed_span_id.isValid()) return false;
    const span_index = fact.typed_span_id.index();
    return span_index < function.span_identities.len and
        sourcePointExactMatches(function.span_identities[span_index].source, fact.source);
}

fn targetTypeFactMatches(function: *const mir.Function, fact: mir.TargetTypeFact, query: TargetTypeFactQuery) bool {
    if (fact.kind != query.kind or fact.target_index != query.index) return false;
    if (!typedOwnerIdMatches(fact.typed_target_owner_id, query.typed_target_owner_id)) return false;
    if (!sourceMatches(query.kind, query.source, fact.source)) return false;
    return typedIdentityIsValid(function, fact);
}

fn targetTypeFactInFunctionById(function: *const mir.Function, key: TargetTypeLookupKey) ?mir.TargetTypeFact {
    if (!key.typed_span_id.isValid()) return null;
    if (key.typed_result_ty) |result_ty| if (!result_ty.isValid()) return null;
    if (key.typed_target_owner_id) |owner_id| if (!owner_id.isValid()) return null;

    for (function.target_type_facts) |fact| {
        if (fact.kind != key.kind or fact.target_index != key.target_index) continue;
        if (!fact.typed_span_id.eql(key.typed_span_id)) continue;
        if (key.typed_result_ty) |result_ty| {
            if (!fact.typed_result_ty.eql(result_ty)) continue;
        }
        if (!typedOwnerIdMatches(fact.typed_target_owner_id, key.typed_target_owner_id)) continue;
        if (!typedIdentityIsValid(function, fact)) return null;
        return fact;
    }
    return null;
}

fn callTargetFactInFunctionById(function: *const mir.Function, key: CallTargetLookupKey) ?mir.CallTargetFact {
    if (!key.typed_span_id.isValid()) return null;
    for (function.call_target_facts) |fact| {
        if (fact.kind != key.kind) continue;
        if (!fact.typed_span_id.eql(key.typed_span_id)) continue;
        if (!callTargetTypedIdentityIsValid(function, fact)) return null;
        return fact;
    }
    return null;
}

fn callTargetTypedIdentityIsValid(function: *const mir.Function, fact: mir.CallTargetFact) bool {
    if (!fact.typed_span_id.isValid()) return false;
    const span_index = fact.typed_span_id.index();
    if (span_index >= function.span_identities.len) return false;
    const source = function.span_identities[span_index].source;
    return sourcePointExactMatches(source, fact.source);
}

fn typedIdentityIsValid(function: *const mir.Function, fact: mir.TargetTypeFact) bool {
    if (!fact.typed_result_ty.isValid() or !fact.typed_span_id.isValid()) return false;
    const type_index = fact.typed_result_ty.index();
    const span_index = fact.typed_span_id.index();
    if (type_index >= function.type_identities.len or span_index >= function.span_identities.len) return false;
    if (!std.mem.eql(u8, function.type_identities[type_index].spelling, fact.result_ty.name())) return false;
    const source = function.span_identities[span_index].source;
    if (source.line != fact.source.line or source.column != fact.source.column or source.offset != fact.source.offset or source.len != fact.source.len) return false;
    if (!fact.typed_target_owner_id.isValid()) return true;
    const owner_index = fact.typed_target_owner_id.index();
    return owner_index < function.target_owner_identities.len and
        function.target_owner_identities[owner_index].id.eql(fact.typed_target_owner_id);
}

fn typedOwnerIdMatches(actual: mir.SymbolId, expected: ?mir.SymbolId) bool {
    if (expected) |owner_id| return actual.isValid() and actual.eql(owner_id);
    return !actual.isValid();
}

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn sourceMatches(kind: mir.TargetTypeKind, query: mir.SourcePoint, source: mir.SourcePoint) bool {
    if (!sourcePointLineColumnMatches(query, source)) return false;
    return kind != .expression_result or sourcePointOffsetsMatch(query, source);
}

pub fn sourcePointLineColumnMatches(query: mir.SourcePoint, source: mir.SourcePoint) bool {
    return query.line == source.line and query.column == source.column;
}

pub fn sourcePointExactMatches(query: mir.SourcePoint, source: mir.SourcePoint) bool {
    return sourcePointLineColumnMatches(query, source) and sourcePointOffsetsMatch(query, source);
}

pub fn sourcePointOffsetsMatch(query: mir.SourcePoint, source: mir.SourcePoint) bool {
    return query.offset == source.offset and query.len == source.len;
}

pub fn sourcePointHasLineColumn(source: mir.SourcePoint) bool {
    return source.line != 0 and source.column != 0;
}

pub fn callTargetSourceMatches(query: mir.SourcePoint, source: mir.SourcePoint) bool {
    if (!sourcePointLineColumnMatches(query, source)) return false;
    if (source.offset == 0 and source.len == 0) return true;
    return sourcePointOffsetsMatch(query, source);
}

pub fn targetTypeSourceMatches(kind: mir.TargetTypeKind, query: mir.SourcePoint, source: mir.SourcePoint) bool {
    if (!sourcePointLineColumnMatches(query, source)) return false;
    return kind != .expression_result or sourcePointOffsetsMatch(query, source);
}

pub fn pointerFactIsLiveGlobal(fact: mir.PointerProvenanceFact) bool {
    return fact.provenance == .global_storage and pointerFactReasonIsLive(fact);
}

/// A live local_storage/global_storage fact is the positive locality proof that
/// lets a backend use the ordinary pointer lowering. Any call/indirect-call,
/// address escape, or dynamic-index invalidation drops the proof to unknown.
pub fn pointerFactIsLiveLocal(fact: mir.PointerProvenanceFact) bool {
    return fact.provenance == .local_storage and pointerFactReasonIsLive(fact);
}

pub fn pointerFactLiveState(fact: mir.PointerProvenanceFact) mir.PointerProvenance {
    if (pointerFactIsLiveGlobal(fact)) return .global_storage;
    if (pointerFactIsLiveLocal(fact)) return .local_storage;
    return .unknown;
}

fn pointerFactReasonIsLive(fact: mir.PointerProvenanceFact) bool {
    return switch (fact.invalidation_reason) {
        .none, .reassignment => true,
        .dynamic_index_write, .call, .indirect_call, .address_escape => false,
    };
}

fn isSourcePoint(source: mir.SourcePoint) bool {
    return source.offset != 0 or source.len != 0 or source.line != 0 or source.column != 0;
}
