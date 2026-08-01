//! Read-only typed semantic facts exposed to code generators.
//!
//! MIR owns construction and verification.  This module deliberately exposes a
//! small query surface so backends do not each reimplement source-span matching
//! and typed-identity checks while looking up target-type facts.

const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir.zig");

pub const SemanticDb = struct {
    module: *const mir.Module,

    pub fn init(module: *const mir.Module) SemanticDb {
        return .{ .module = module };
    }

    /// Returns an unowned, verified target-type fact.  `current` is preferred
    /// to retain function-local meaning; a source-spanned fact may fall back to
    /// a unique matching module fact for generated cross-function plumbing.
    pub fn targetTypeFactAt(self: SemanticDb, current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast.Span) ?mir.TargetTypeFact {
        if (kind == .expression_result and !isSourceSpan(span)) return null;
        if (current) |function| {
            if (targetTypeFactInFunction(function, kind, span, null, null)) |fact| return fact;
        }
        if (!isSourceSpan(span)) return null;
        return uniqueModuleTargetTypeFact(self.module, kind, span, null, null);
    }

    /// Same query for fact families whose target belongs to a typed owner and
    /// optional target index (for example atomic-init payload/result pairs).
    pub fn targetTypeFactAtOwned(self: SemanticDb, current: ?*const mir.Function, kind: mir.TargetTypeKind, span: ast.Span, owner: []const u8, index: ?usize) ?mir.TargetTypeFact {
        if (current) |function| {
            if (targetTypeFactInFunction(function, kind, span, owner, index)) |fact| return fact;
        }
        if (!isSourceSpan(span)) return null;
        return uniqueModuleTargetTypeFact(self.module, kind, span, owner, index);
    }
};

fn uniqueModuleTargetTypeFact(module: *const mir.Module, kind: mir.TargetTypeKind, span: ast.Span, owner: ?[]const u8, index: ?usize) ?mir.TargetTypeFact {
    var matched: ?mir.TargetTypeFact = null;
    for (module.functions) |function| {
        const fact = targetTypeFactInFunction(&function, kind, span, owner, index) orelse continue;
        if (matched) |existing| {
            if (!sameFactIdentity(existing, fact)) return null;
        } else {
            matched = fact;
        }
    }
    return matched;
}

fn targetTypeFactInFunction(function: *const mir.Function, kind: mir.TargetTypeKind, span: ast.Span, owner: ?[]const u8, index: ?usize) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or fact.target_index != index) continue;
        if (!ownerMatches(fact.target_owner, owner)) continue;
        if (!sourceMatches(kind, span, fact.source)) continue;
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

fn ownerMatches(actual: ?[]const u8, expected: ?[]const u8) bool {
    if (actual == null or expected == null) return actual == null and expected == null;
    return std.mem.eql(u8, actual.?, expected.?);
}

fn sourceMatches(kind: mir.TargetTypeKind, span: ast.Span, source: mir.SourcePoint) bool {
    if (span.line != source.line or span.column != source.column) return false;
    return kind != .expression_result or (span.offset == source.offset and span.len == source.len);
}

fn isSourceSpan(span: ast.Span) bool {
    return span.offset != 0 or span.len != 0 or span.line != 0 or span.column != 0;
}
