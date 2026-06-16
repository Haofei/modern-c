// Shared, target-agnostic switch classification.
//
// Both backends (lower_c.zig and lower_llvm.zig) lower a `switch` by first deciding which family
// it belongs to — Result, nullable, tagged-union, or plain enum/scalar — and then emitting target
// code (C `switch(){}` / if-else chains vs LLVM `switch i<w>` / `br`). The *family detection*
// itself is genuinely backend-specific: it inspects the subject's type via each backend's own
// type machinery (C `LocalInfo` strings and emitted temps vs LLVM `ast.TypeExpr` + `resultInfo`),
// and the two even disagree on the probe order. Forcing a single detector would mean porting one
// backend's type inference into the other and changing *what code each emits and when*, so that
// part stays per-backend.
//
// What the two backends *do* compute identically — purely from the AST, with no type lookups and
// no emission side effects — is the per-arm pattern shape: extracting `ok`/`err`/wildcard arms for
// a Result switch, the some/none arms for a nullable switch, and the tag / tag+binding name for a
// tagged-union arm. That AST-only analysis was duplicated (open-coded in lower_c, free functions in
// lower_llvm); this module is the single home for it. The target-specific emission keeps living in
// each backend.

const std = @import("std");
const ast = @import("ast.zig");

/// A Result-switch arm pattern: a `.tag` (`ok`/`err`) optionally carrying a payload binding.
/// `tag` is the raw pattern tag text; callers compare it against "ok"/"err" themselves.
pub const ResultArmPattern = struct {
    tag: []const u8,
    binding: ?ast.Ident = null,
};

/// Extract the Result-switch shape from a single arm pattern (`.tag` / `.tag_bind`), or null for
/// any other pattern kind (e.g. wildcard, which the caller handles separately).
pub fn resultArmPattern(pattern: ast.Pattern) ?ResultArmPattern {
    return switch (pattern.kind) {
        .tag => |tag| .{ .tag = tag.text },
        .tag_bind => |tag_bind| .{ .tag = tag_bind.tag.text, .binding = tag_bind.binding },
        else => null,
    };
}

/// A tagged-union arm that binds the case payload: the case tag name plus the binding identifier.
pub const TaggedUnionArmBinding = struct {
    tag: []const u8,
    binding: ast.Ident,
};

/// The case-tag name named by a tagged-union arm pattern (`.tag` or `.tag_bind`), or null for a
/// pattern that does not name a case (wildcard, literal, bare bind).
pub fn taggedUnionPatternName(pattern: ast.Pattern) ?[]const u8 {
    return switch (pattern.kind) {
        .tag => |tag| tag.text,
        .tag_bind => |tag_bind| tag_bind.tag.text,
        else => null,
    };
}

/// For a single-pattern tagged-union arm of the form `.Case(binding)`, return the case name and
/// the binding; null for any other arm shape (multiple patterns, or a non-`tag_bind` pattern).
pub fn taggedUnionArmBinding(arm: ast.SwitchArm) ?TaggedUnionArmBinding {
    if (arm.patterns.len != 1) return null;
    return switch (arm.patterns[0].kind) {
        .tag_bind => |tag_bind| .{ .tag = tag_bind.tag.text, .binding = tag_bind.binding },
        else => null,
    };
}

/// The some/none arm layout of a nullable switch. `some_index` is the arm whose single pattern is
/// a `.bind` (the non-null payload binding); `none_index` is the single `.wildcard` arm.
pub const NullableArms = struct {
    some_index: usize,
    none_index: usize,
    binding: ast.Ident,
};

/// Result of analysing a nullable switch's arm shapes. The non-ok variants are kept distinct
/// because the two backends react differently to each (e.g. lower_llvm falls through on a missing
/// half but hard-rejects a duplicate), so collapsing them would change behavior.
pub const NullableArmsResult = union(enum) {
    /// Exactly one `.bind` arm and one `.wildcard` arm — a well-formed nullable switch.
    ok: NullableArms,
    /// Two `.bind` arms or two `.wildcard` arms — kinds are right but the shape is over-specified.
    duplicate,
    /// Kinds are all `.bind`/`.wildcard` but one of the two required halves is absent.
    missing_half,
    /// At least one arm pattern is neither `.bind` nor `.wildcard` (or an arm has !=1 pattern);
    /// not a nullable switch — the caller should fall through to try other switch families.
    not_nullable,
};

/// Classify a nullable switch purely from its arm patterns: find the single `.bind` (some) arm and
/// the single `.wildcard` (none) arm. Type-level confirmation that the subject is actually nullable
/// stays in each backend.
pub fn classifyNullableArms(arms: []const ast.SwitchArm) NullableArmsResult {
    var bind_index: ?usize = null;
    var binding: ?ast.Ident = null;
    var wildcard_index: ?usize = null;
    for (arms, 0..) |arm, i| {
        if (arm.patterns.len != 1) return .not_nullable;
        switch (arm.patterns[0].kind) {
            .bind => |ident| {
                if (bind_index != null) return .duplicate;
                bind_index = i;
                binding = ident;
            },
            .wildcard => {
                if (wildcard_index != null) return .duplicate;
                wildcard_index = i;
            },
            else => return .not_nullable,
        }
    }
    const some_i = bind_index orelse return .missing_half;
    const none_i = wildcard_index orelse return .missing_half;
    const bind = binding orelse return .missing_half;
    return .{ .ok = .{ .some_index = some_i, .none_index = none_i, .binding = bind } };
}
