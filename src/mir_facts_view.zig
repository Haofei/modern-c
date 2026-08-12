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

pub const TargetTypeFactQuery = struct {
    kind: mir.TargetTypeKind,
    source: mir.SourcePoint,
    owner: ?[]const u8 = null,
    index: ?usize = null,
};

pub const TargetTypeModuleFallbackQuery = struct {
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
    module: *const mir.Module,

    pub fn init(module: *const mir.Module) MirFactsView {
        return .{ .module = module };
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

    /// Transitional generated-plumbing query.  It first checks the current
    /// function, then falls back to a unique module-wide source match.  Keeping
    /// this fallback explicitly named prevents broad scans from hiding behind
    /// the ordinary local facts query.
    pub fn targetTypeFactAtSpanWithExplicitModuleFallback(self: MirFactsView, query: TargetTypeModuleFallbackQuery) ?mir.TargetTypeFact {
        if (query.current) |function| {
            if (self.targetTypeFactAt(function, query.fact.kind, query.fact.source)) |fact| return fact;
        }
        if (!targetTypeKindAllowsModuleFallback(query.fact.kind)) return null;
        if (!isSourcePoint(query.fact.source)) return null;
        return uniqueModuleTargetTypeFact(self.module, query.fact);
    }

    /// Same local query for fact families whose target belongs to a typed owner
    /// and optional target index (for example atomic-init payload/result pairs).
    pub fn targetTypeFactAtOwned(self: MirFactsView, current: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: []const u8, index: ?usize) ?mir.TargetTypeFact {
        _ = self;
        return targetTypeFactInFunction(current, kind, source, owner, index);
    }

    /// Transitional generated-plumbing owner query with explicit module-wide
    /// fallback.  New code should prefer `targetTypeFactById`.
    pub fn targetTypeFactAtOwnedSpanWithExplicitModuleFallback(self: MirFactsView, query: TargetTypeModuleFallbackQuery) ?mir.TargetTypeFact {
        if (query.fact.owner == null) return null;
        if (query.current) |function| {
            if (self.targetTypeFactAtOwned(function, query.fact.kind, query.fact.source, query.fact.owner.?, query.fact.index)) |fact| return fact;
        }
        if (!isSourcePoint(query.fact.source)) return null;
        if (!targetTypeKindAllowsModuleFallback(query.fact.kind)) return null;
        return uniqueModuleTargetTypeFact(self.module, query.fact);
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

    pub fn targetTypeFactMatchesFamily(self: MirFactsView, current: *const mir.Function, fact: mir.TargetTypeFact, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: ?[]const u8) bool {
        _ = self;
        if (fact.kind != kind) return false;
        if (!ownerMatches(fact.target_owner, owner)) return false;
        if (!sourceMatches(kind, source, fact.source)) return false;
        return typedIdentityIsValid(current, fact);
    }

    pub fn pointerFactMatchesQuery(self: MirFactsView, fact: mir.PointerProvenanceFact, query: PointerFactQuery) bool {
        _ = self;
        if (!std.mem.eql(u8, fact.subject, query.subject)) return false;
        if (!ownerMatches(fact.field_path, query.field_path)) return false;
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

fn uniqueModuleTargetTypeFact(module: *const mir.Module, query: TargetTypeFactQuery) ?mir.TargetTypeFact {
    var matched: ?mir.TargetTypeFact = null;
    for (module.functions) |function| {
        const fact = targetTypeFactInFunction(&function, query.kind, query.source, query.owner, query.index) orelse continue;
        if (matched) |existing| {
            if (!sameFactIdentity(existing, fact)) return null;
        } else {
            matched = fact;
        }
    }
    return matched;
}

fn targetTypeKindAllowsModuleFallback(kind: mir.TargetTypeKind) bool {
    return switch (kind) {
        .direct_call_result,
        .direct_call_argument,
        .dyn_dispatch_result,
        .dyn_dispatch_argument,
        .atomic_init_payload,
        .atomic_init_result,
        .indirect_call_callee,
        .const_get_base,
        .const_get_result,
        .qualified_union_result,
        .enum_variant_path_result,
        .bind,
        .result_ok,
        .result_err,
        .tagged_union,
        .string_literal,
        .array_literal,
        .struct_literal,
        => true,
        else => false,
    };
}

fn targetTypeFactInFunction(function: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: ?[]const u8, index: ?usize) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| {
        if (!targetTypeFactMatches(function, fact, .{ .kind = kind, .source = source, .owner = owner, .index = index })) continue;
        return fact;
    }
    return null;
}

fn targetTypeFactMatches(function: *const mir.Function, fact: mir.TargetTypeFact, query: TargetTypeFactQuery) bool {
    if (fact.kind != query.kind or fact.target_index != query.index) return false;
    if (!ownerMatches(fact.target_owner, query.owner)) return false;
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

fn sameFactIdentity(left: mir.TargetTypeFact, right: mir.TargetTypeFact) bool {
    // IDs are intentionally function-local interned identities.  They prove a
    // fact is well-formed inside its producer, but equal numeric IDs from two
    // different functions are not globally comparable; retain syntax equality
    // for the unique cross-function fallback.
    return std.meta.eql(left.target_ty, right.target_ty);
}

fn typedIdentityIsValid(function: *const mir.Function, fact: mir.TargetTypeFact) bool {
    if (!fact.typed_result_ty.isValid() or !fact.typed_span_id.isValid()) return false;
    const type_index = fact.typed_result_ty.index();
    const span_index = fact.typed_span_id.index();
    if (type_index >= function.type_identities.len or span_index >= function.span_identities.len) return false;
    if (!std.mem.eql(u8, function.type_identities[type_index].spelling, fact.result_ty.name())) return false;
    const source = function.span_identities[span_index].source;
    if (source.line != fact.source.line or source.column != fact.source.column or source.offset != fact.source.offset or source.len != fact.source.len) return false;
    if (fact.target_owner) |owner| {
        if (!fact.typed_target_owner_id.isValid()) return false;
        const owner_index = fact.typed_target_owner_id.index();
        return owner_index < function.target_owner_identities.len and std.mem.eql(u8, function.target_owner_identities[owner_index].spelling, owner);
    }
    return !fact.typed_target_owner_id.isValid();
}

fn typedOwnerIdMatches(actual: mir.SymbolId, expected: ?mir.SymbolId) bool {
    if (expected) |owner_id| return actual.isValid() and actual.eql(owner_id);
    return !actual.isValid();
}

fn ownerMatches(actual: ?[]const u8, expected: ?[]const u8) bool {
    if (actual == null or expected == null) return actual == null and expected == null;
    return std.mem.eql(u8, actual.?, expected.?);
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
