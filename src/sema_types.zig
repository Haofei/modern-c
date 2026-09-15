//! Sema's interned resolved-type table, and the expression -> type side table
//! the MIR builder reads instead of re-inferring.
//!
//! This is the first slice of the sema-to-MIR typed handoff. Today sema
//! answers type questions with `ast.TypeExpr` — syntax — and the MIR builder
//! re-derives the same answers from the AST. Two implementations of one
//! judgement drift. The fix is for sema to resolve once, into a
//! representation that is not syntax, and for MIR to read it.
//!
//! Scope of this slice, deliberately small and complete rather than broad and
//! scaffolded: the scalar literal result types (`int_literal`, `bool_literal`,
//! `void_literal`). For those, `ResolvedType` is structural — an integer is a
//! signedness plus a width, not the string "u32" — and `scalarOfLiteral` below
//! is the single implementation of the rule. Sema records it during its walk;
//! the MIR builder reads the recording. Neither has its own copy.
//!
//! Everything sema resolves that this table does not yet model structurally is
//! simply absent: `lookup` returns null and the caller keeps its existing
//! path. The table is authoritative where it answers, never a second guess.

const std = @import("std");

const ast = @import("ast.zig");
const numeric = @import("numeric.zig");

/// Integer width as a fact, not a spelling. `pointer` is `usize`/`isize`,
/// whose bit count is a target property rather than a literal one.
pub const IntWidth = enum {
    w8,
    w16,
    w32,
    w64,
    w128,
    pointer,
};

/// A resolved type. Scalars are structural; everything else is out of scope
/// for this slice and is not interned at all.
pub const ResolvedType = union(enum) {
    void_,
    boolean,
    integer: Integer,

    pub const Integer = struct {
        signed: bool,
        width: IntWidth,
    };

    pub fn eql(self: ResolvedType, other: ResolvedType) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .void_, .boolean => true,
            .integer => |lhs| lhs.signed == other.integer.signed and lhs.width == other.integer.width,
        };
    }

    /// Render the resolved type back to its MC spelling. This is the one
    /// place a name is produced, at the boundary with code that still speaks
    /// `ast.TypeExpr`; it is a rendering of the fact, not a second source of
    /// it. The result is a static string, so it outlives any arena.
    pub fn spelling(self: ResolvedType) []const u8 {
        return switch (self) {
            .void_ => "void",
            .boolean => "bool",
            .integer => |info| if (info.signed) switch (info.width) {
                .w8 => "i8",
                .w16 => "i16",
                .w32 => "i32",
                .w64 => "i64",
                .w128 => "i128",
                .pointer => "isize",
            } else switch (info.width) {
                .w8 => "u8",
                .w16 => "u16",
                .w32 => "u32",
                .w64 => "u64",
                .w128 => "u128",
                .pointer => "usize",
            },
        };
    }
};

/// Index into a `Table`. Opaque on purpose: consumers ask the table, they do
/// not do arithmetic on ids.
pub const TypeId = struct {
    value: u32,

    pub fn eql(self: TypeId, other: TypeId) bool {
        return self.value == other.value;
    }
};

/// Structurally interned resolved types: equal types get the same `TypeId`.
pub const Table = struct {
    types: std.ArrayList(ResolvedType) = .empty,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.types.deinit(allocator);
    }

    pub fn intern(self: *Table, allocator: std.mem.Allocator, ty: ResolvedType) !TypeId {
        for (self.types.items, 0..) |existing, index| {
            if (existing.eql(ty)) return .{ .value = @intCast(index) };
        }
        try self.types.append(allocator, ty);
        return .{ .value = @intCast(self.types.items.len - 1) };
    }

    pub fn get(self: Table, id: TypeId) ResolvedType {
        return self.types.items[id.value];
    }

    pub fn len(self: Table) usize {
        return self.types.items.len;
    }
};

/// Expression identity. The AST carries no node id, and MIR already keys its
/// own facts on the source span, so the span is the identity both layers
/// already agree on.
pub const ExprKey = struct {
    file_id: u32,
    offset: u32,
    len: u32,

    pub fn fromSpan(span: ast.Span) ExprKey {
        return .{
            .file_id = span.file_id,
            .offset = @intCast(span.offset),
            .len = @intCast(span.len),
        };
    }
};

const Entry = struct {
    type_id: TypeId,
    /// Two different expressions resolved at the same span to different
    /// types. The span is then not an identity here, so the entry stops
    /// answering rather than answering arbitrarily.
    ambiguous: bool = false,
};

/// Sema's output: the interned types plus where each resolved expression
/// landed.
pub const Resolved = struct {
    allocator: std.mem.Allocator,
    table: Table = .{},
    exprs: std.AutoHashMapUnmanaged(ExprKey, Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Resolved {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Resolved) void {
        self.exprs.deinit(self.allocator);
        self.table.deinit(self.allocator);
    }

    pub fn record(self: *Resolved, span: ast.Span, ty: ResolvedType) !void {
        const id = try self.table.intern(self.allocator, ty);
        const key = ExprKey.fromSpan(span);
        const slot = try self.exprs.getOrPut(self.allocator, key);
        if (slot.found_existing) {
            if (!slot.value_ptr.type_id.eql(id)) slot.value_ptr.ambiguous = true;
            return;
        }
        slot.value_ptr.* = .{ .type_id = id };
    }

    pub fn lookup(self: Resolved, span: ast.Span) ?ResolvedType {
        const entry = self.exprs.get(ExprKey.fromSpan(span)) orelse return null;
        if (entry.ambiguous) return null;
        return self.table.get(entry.type_id);
    }

    pub fn count(self: Resolved) usize {
        return self.exprs.count();
    }
};

/// The single implementation of "what scalar type does this literal have".
///
/// Sema calls it while walking, to record. The MIR builder calls it only when
/// no recording is available (unit tests that build MIR without running the
/// checker). There is no second copy of this rule in the builder.
pub fn scalarOfLiteral(expr: ast.Expr) ?ResolvedType {
    return switch (expr.kind) {
        .bool_literal => .boolean,
        .void_literal => .void_,
        .int_literal => |literal| integerOfLiteral(literal),
        else => null,
    };
}

/// An unsuffixed integer literal has no type of its own; `u32` is the
/// language's default for one that reaches a context with nothing to say.
/// That default is the rule, so it lives here rather than in the builder.
pub fn integerOfLiteral(literal: []const u8) ResolvedType {
    const parsed = numeric.parseIntegerLiteralParts(literal) orelse
        return .{ .integer = .{ .signed = false, .width = .w32 } };
    const suffix = parsed.suffix orelse
        return .{ .integer = .{ .signed = false, .width = .w32 } };
    return integerOfSuffix(suffix);
}

pub fn integerOfSuffix(suffix: numeric.IntegerSuffix) ResolvedType {
    return .{ .integer = switch (suffix) {
        .u8 => .{ .signed = false, .width = .w8 },
        .u16 => .{ .signed = false, .width = .w16 },
        .u32 => .{ .signed = false, .width = .w32 },
        .u64 => .{ .signed = false, .width = .w64 },
        .u128 => .{ .signed = false, .width = .w128 },
        .usize => .{ .signed = false, .width = .pointer },
        .i8 => .{ .signed = true, .width = .w8 },
        .i16 => .{ .signed = true, .width = .w16 },
        .i32 => .{ .signed = true, .width = .w32 },
        .i64 => .{ .signed = true, .width = .w64 },
        .i128 => .{ .signed = true, .width = .w128 },
        .isize => .{ .signed = true, .width = .pointer },
    } };
}

/// Only a suffixed integer literal names its own type; used where the caller
/// must distinguish "typed by the literal" from "typed by its context".
pub fn suffixedIntegerOfLiteral(literal: []const u8) ?ResolvedType {
    const parsed = numeric.parseIntegerLiteralParts(literal) orelse return null;
    const suffix = parsed.suffix orelse return null;
    return integerOfSuffix(suffix);
}

test "resolved scalar types intern structurally" {
    var resolved = Resolved.init(std.testing.allocator);
    defer resolved.deinit();

    const a = try resolved.table.intern(std.testing.allocator, .{ .integer = .{ .signed = false, .width = .w32 } });
    const b = try resolved.table.intern(std.testing.allocator, .{ .integer = .{ .signed = false, .width = .w32 } });
    const c = try resolved.table.intern(std.testing.allocator, .{ .integer = .{ .signed = true, .width = .w32 } });
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expectEqual(@as(usize, 2), resolved.table.len());
}

test "literal scalar rule covers suffixed, unsuffixed, bool and void" {
    const span: ast.Span = .{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    try std.testing.expectEqualStrings("u32", integerOfLiteral("7").spelling());
    try std.testing.expectEqualStrings("i64", integerOfLiteral("7_i64").spelling());
    try std.testing.expectEqualStrings("usize", integerOfLiteral("7_usize").spelling());
    try std.testing.expect(suffixedIntegerOfLiteral("7") == null);

    const bool_expr: ast.Expr = .{ .span = span, .kind = .{ .bool_literal = true } };
    try std.testing.expectEqualStrings("bool", scalarOfLiteral(bool_expr).?.spelling());

    const void_expr: ast.Expr = .{ .span = span, .kind = .void_literal };
    try std.testing.expectEqualStrings("void", scalarOfLiteral(void_expr).?.spelling());

    const ident_expr: ast.Expr = .{ .span = span, .kind = .{ .ident = .{ .text = "x", .span = span } } };
    try std.testing.expect(scalarOfLiteral(ident_expr) == null);
}

test "a span that resolves two ways stops answering" {
    var resolved = Resolved.init(std.testing.allocator);
    defer resolved.deinit();

    const span: ast.Span = .{ .offset = 4, .len = 2, .line = 1, .column = 5, .file_id = 1 };
    try resolved.record(span, .boolean);
    try std.testing.expect(resolved.lookup(span).?.eql(.boolean));

    try resolved.record(span, .{ .integer = .{ .signed = false, .width = .w8 } });
    try std.testing.expect(resolved.lookup(span) == null);
}
