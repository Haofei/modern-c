//! Sema's declaration symbol table: one `DefId` per declaration.
//!
//! Sema used to answer "which declaration is this name?" with the name
//! itself. Every registry (`structs`, `enums`, `functions`, `globals`, …) and
//! every scope was a `StringHashMap`, so a declaration's identity was its
//! spelling and two declarations that share a spelling were indistinguishable
//! downstream. `sema_types.ResolvedType.nominal` had to be a dense name index
//! for exactly that reason.
//!
//! This table gives every declaration an identity instead. `DefId` is the
//! compile-local identity `src/semantic_ids.zig` already defines and MIR
//! already joins declaration facts on; top-level declarations are numbered
//! here by the same rule `compiler_session.prepareResolvedProgram` uses (a
//! per-file ordinal in declaration order), so the two spaces agree for a
//! checked program rather than being two numbering schemes for one thing.
//!
//! Body-local bindings — parameters, `let`/`var`, pattern and loop bindings —
//! are declarations too, and they get ids from the reserved local half of the
//! ordinal range (`semantic_ids.local_ordinal_base`), so a local can never
//! collide with a top-level declaration of the same file.
//!
//! Name lookup survives as a thin layer over the table: `typeDef` and
//! `valueDef` map a spelling to the declaration it currently denotes, with
//! the same first-wins policy sema's name-keyed registries have always had.
//! The registries keep answering shape questions; this table answers identity
//! questions.

const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const semantic_ids = @import("semantic_ids.zig");

pub const DefId = semantic_ids.DefId;

/// What a declaration is. This is the declaring syntax, not a type: an
/// identity does not change when a consumer asks a different question of it.
pub const DefKind = enum {
    function,
    extern_fn,
    global,
    struct_,
    enum_,
    tagged_union,
    overlay_union,
    packed_bits,
    type_alias,
    opaque_type,
    trait,
    impl_trait,
    param,
    local,

    /// A declaration that introduces a type name. Its spelling lives in the
    /// type namespace; everything else lives in the value namespace.
    pub fn isType(self: DefKind) bool {
        return switch (self) {
            .struct_, .enum_, .tagged_union, .overlay_union, .packed_bits, .type_alias, .opaque_type, .trait => true,
            .function, .extern_fn, .global, .impl_trait, .param, .local => false,
        };
    }
};

pub const Def = struct {
    id: DefId,
    kind: DefKind,
    /// The declared spelling, borrowed from source text. Presentation and
    /// linkage only: nothing downstream should compare these to decide
    /// identity now that the id exists.
    name: []const u8,
    span: ast.Span,
};

/// The declarations of one compilation request.
pub const Table = struct {
    allocator: std.mem.Allocator,
    defs: std.ArrayList(Def) = .empty,
    types_by_name: std.StringHashMapUnmanaged(DefId) = .empty,
    values_by_name: std.StringHashMapUnmanaged(DefId) = .empty,
    index_by_id: std.AutoHashMapUnmanaged(DefId, u32) = .empty,
    next_decl_ordinal: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    next_local_ordinal: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        self.defs.deinit(self.allocator);
        self.types_by_name.deinit(self.allocator);
        self.values_by_name.deinit(self.allocator);
        self.index_by_id.deinit(self.allocator);
        self.next_decl_ordinal.deinit(self.allocator);
        self.next_local_ordinal.deinit(self.allocator);
    }

    /// A span's file, with the legacy/synthetic invalid id folded to file 0.
    /// Single-file requests and in-process unit tests parse without file ids;
    /// they still need one identity space.
    fn fileOf(span: ast.Span) u32 {
        return if (span.file_id == diagnostics.invalid_file_id) 0 else span.file_id;
    }

    /// Give a top-level declaration its id. Call once per declaration, in
    /// declaration order, so the ordinals match the session's.
    pub fn declare(self: *Table, kind: DefKind, name: []const u8, span: ast.Span) !DefId {
        const file_id = fileOf(span);
        const slot = try self.next_decl_ordinal.getOrPut(self.allocator, file_id);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        const ordinal = slot.value_ptr.*;
        if (ordinal >= semantic_ids.local_ordinal_base) return error.TooManyDeclarationsInFile;
        slot.value_ptr.* = ordinal + 1;
        return self.append(.{ .file_id = file_id, .ordinal = ordinal }, kind, name, span);
    }

    /// Give a body-local binding its id, from the reserved local half of the
    /// ordinal range. Locals are never looked up by spelling here: a scope
    /// binding carries its id, so shadowing is a fact about the binding rather
    /// than about the name.
    pub fn declareLocal(self: *Table, kind: DefKind, name: []const u8, span: ast.Span) !DefId {
        const file_id = fileOf(span);
        const slot = try self.next_local_ordinal.getOrPut(self.allocator, file_id);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        const offset = slot.value_ptr.*;
        if (offset == std.math.maxInt(u32) - semantic_ids.local_ordinal_base) return error.TooManyLocalBindingsInFile;
        slot.value_ptr.* = offset + 1;
        return self.append(.{ .file_id = file_id, .ordinal = semantic_ids.local_ordinal_base + offset }, kind, name, span);
    }

    fn append(self: *Table, id: DefId, kind: DefKind, name: []const u8, span: ast.Span) !DefId {
        try self.defs.append(self.allocator, .{ .id = id, .kind = kind, .name = name, .span = span });
        try self.index_by_id.put(self.allocator, id, @intCast(self.defs.items.len - 1));
        if (kind != .local and kind != .param and kind != .impl_trait) {
            var namespace = if (kind.isType()) &self.types_by_name else &self.values_by_name;
            const slot = try namespace.getOrPut(self.allocator, name);
            // First wins, which is what every name-keyed registry in sema
            // already does. A second declaration of the same spelling still
            // gets its own id; what it does not get is the name.
            if (!slot.found_existing) slot.value_ptr.* = id;
        }
        return id;
    }

    /// The declaration a type name currently denotes.
    pub fn typeDef(self: Table, name: []const u8) ?DefId {
        return self.types_by_name.get(name);
    }

    /// The declaration a value name currently denotes at module scope.
    pub fn valueDef(self: Table, name: []const u8) ?DefId {
        return self.values_by_name.get(name);
    }

    pub fn get(self: Table, id: DefId) ?Def {
        const index = self.index_by_id.get(id) orelse return null;
        return self.defs.items[index];
    }

    /// The declared spelling of an id, for the boundaries that still speak
    /// syntax. A rendering of the fact, never a second source of it.
    pub fn spelling(self: Table, id: DefId) ?[]const u8 {
        const def = self.get(id) orelse return null;
        return def.name;
    }

    pub fn count(self: Table) usize {
        return self.defs.items.len;
    }
};

/// The declaration kind of a top-level declaration, or null for a form that
/// declares no name of its own.
pub fn declKind(decl: ast.Decl) ?DefKind {
    return switch (decl.kind) {
        .fn_decl => .function,
        .extern_fn => .extern_fn,
        .global_decl => .global,
        .struct_decl => .struct_,
        .enum_decl => .enum_,
        .union_decl => .tagged_union,
        .overlay_union_decl => .overlay_union,
        .packed_bits_decl => .packed_bits,
        .type_alias => .type_alias,
        .opaque_decl => .opaque_type,
        .trait_decl => .trait,
        .impl_trait => .impl_trait,
    };
}

/// The declared name of a top-level declaration. `impl Trait for Type` has no
/// importable name of its own; it is identified by the pair it records.
pub fn declName(decl: ast.Decl) []const u8 {
    return switch (decl.kind) {
        .fn_decl, .extern_fn => |node| node.name.text,
        .global_decl => |node| node.name.text,
        .struct_decl => |node| node.name.text,
        .enum_decl => |node| node.name.text,
        .union_decl => |node| node.name.text,
        .overlay_union_decl => |node| node.name.text,
        .packed_bits_decl => |node| node.name.text,
        .type_alias => |node| node.name.text,
        .opaque_decl => |node| node.text,
        .trait_decl => |node| node.name.text,
        .impl_trait => |node| node.type_name.text,
    };
}

/// Assign an id to every declaration of a module, in declaration order.
pub fn declareAll(table: *Table, decls: []const ast.Decl) !void {
    for (decls) |decl| {
        const kind = declKind(decl) orelse continue;
        _ = try table.declare(kind, declName(decl), decl.span);
    }
}

test "declarations of the same spelling in different files get distinct ids" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const first = try table.declare(.struct_, "Point", .{ .offset = 0, .len = 5, .line = 1, .column = 1, .file_id = 1 });
    const second = try table.declare(.struct_, "Point", .{ .offset = 0, .len = 5, .line = 1, .column = 1, .file_id = 2 });
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(first.isValid() and second.isValid());
    // The name resolves to the first declaration, as every name-keyed sema
    // registry already resolved it; the second still has its own identity.
    try std.testing.expect(table.typeDef("Point").?.eql(first));
    try std.testing.expectEqualStrings("Point", table.spelling(second).?);
}

test "declaration ordinals are per file and local ordinals are disjoint" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const span_a: ast.Span = .{ .offset = 0, .len = 1, .line = 1, .column = 1, .file_id = 3 };
    const span_b: ast.Span = .{ .offset = 0, .len = 1, .line = 1, .column = 1, .file_id = 4 };
    const a0 = try table.declare(.function, "f", span_a);
    const a1 = try table.declare(.function, "g", span_a);
    const b0 = try table.declare(.function, "h", span_b);
    try std.testing.expectEqual(@as(u32, 0), a0.ordinal);
    try std.testing.expectEqual(@as(u32, 1), a1.ordinal);
    try std.testing.expectEqual(@as(u32, 0), b0.ordinal);

    const local = try table.declareLocal(.local, "x", span_a);
    try std.testing.expect(semantic_ids.isLocalOrdinal(local.ordinal));
    try std.testing.expect(!semantic_ids.isLocalOrdinal(a0.ordinal));
    try std.testing.expectEqual(@as(u32, 3), local.file_id);
    // A local is not a module-scope name.
    try std.testing.expect(table.valueDef("x") == null);
}
