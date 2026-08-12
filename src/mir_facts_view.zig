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

pub const MirFactsView = struct {
    module: *const mir.Module,

    pub fn init(module: *const mir.Module) MirFactsView {
        return .{ .module = module };
    }

    /// Returns an unowned, verified target-type fact from the current function.
    ///
    /// This is the preferred source-spanned compatibility query while callers
    /// are being migrated to `targetTypeFactById`.
    pub fn targetTypeFactAt(self: MirFactsView, current: ?*const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        if (kind == .expression_result and !isSourcePoint(source)) return null;
        if (current) |function| {
            if (targetTypeFactInFunction(function, kind, source, null, null)) |fact| return fact;
        }
        return null;
    }

    /// Transitional generated-plumbing query.  It first checks the current
    /// function, then falls back to a unique module-wide source match.  Keeping
    /// this fallback explicitly named prevents broad scans from hiding behind
    /// the ordinary local facts query.
    pub fn targetTypeFactAtWithModuleFallback(self: MirFactsView, current: ?*const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint) ?mir.TargetTypeFact {
        if (self.targetTypeFactAt(current, kind, source)) |fact| return fact;
        if (!isSourcePoint(source)) return null;
        return uniqueModuleTargetTypeFact(self.module, kind, source, null, null);
    }

    /// Same local query for fact families whose target belongs to a typed owner
    /// and optional target index (for example atomic-init payload/result pairs).
    pub fn targetTypeFactAtOwned(self: MirFactsView, current: ?*const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: []const u8, index: ?usize) ?mir.TargetTypeFact {
        _ = self;
        if (current) |function| {
            if (targetTypeFactInFunction(function, kind, source, owner, index)) |fact| return fact;
        }
        return null;
    }

    /// Transitional generated-plumbing owner query with explicit module-wide
    /// fallback.  New code should prefer `targetTypeFactById`.
    pub fn targetTypeFactAtOwnedWithModuleFallback(self: MirFactsView, current: ?*const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: []const u8, index: ?usize) ?mir.TargetTypeFact {
        if (self.targetTypeFactAtOwned(current, kind, source, owner, index)) |fact| return fact;
        if (!isSourcePoint(source)) return null;
        return uniqueModuleTargetTypeFact(self.module, kind, source, owner, index);
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
};

fn uniqueModuleTargetTypeFact(module: *const mir.Module, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: ?[]const u8, index: ?usize) ?mir.TargetTypeFact {
    var matched: ?mir.TargetTypeFact = null;
    for (module.functions) |function| {
        const fact = targetTypeFactInFunction(&function, kind, source, owner, index) orelse continue;
        if (matched) |existing| {
            if (!sameFactIdentity(existing, fact)) return null;
        } else {
            matched = fact;
        }
    }
    return matched;
}

fn targetTypeFactInFunction(function: *const mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint, owner: ?[]const u8, index: ?usize) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or fact.target_index != index) continue;
        if (!ownerMatches(fact.target_owner, owner)) continue;
        if (!sourceMatches(kind, source, fact.source)) continue;
        if (!typedIdentityIsValid(function, fact)) return null;
        return fact;
    }
    return null;
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

fn isSourcePoint(source: mir.SourcePoint) bool {
    return source.offset != 0 or source.len != 0 or source.line != 0 or source.column != 0;
}
