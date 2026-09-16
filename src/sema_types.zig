//! Sema's interned resolved-type table, and the expression -> type side table
//! the MIR builder reads instead of re-inferring.
//!
//! Sema answers type questions with `ast.TypeExpr` — syntax — and the MIR
//! builder used to re-derive the same answers from the AST. Two
//! implementations of one judgement drift. This table is the fix: sema
//! resolves once, into a representation that is not syntax, and MIR reads it.
//!
//! A `ResolvedType` is structural. A scalar is a signedness plus a width, not
//! the string "u32"; a pointer is a kind, a mutability, a nullability and a
//! child type id; a signature is an interned run of parameter type ids and a
//! return type id. Equal types get equal ids, including equal parameter runs.
//! A nominal type is the declaration it names, carried as the `DefId`
//! `src/sema_symbols.zig` gave that declaration; its spelling travels beside
//! the type, in `Resolved.nominal_names`, for the emitters that still take
//! type names from syntax.
//!
//! Everything sema resolves that this table cannot model is simply absent:
//! `lookup` returns null and the caller keeps its existing path. The table is
//! authoritative where it answers, never a second guess. The remaining gaps
//! and the span-keyed expression identity are described in
//! `docs/typed-semantic-facts.md`.
//!
//! `toTypeExpr` is the one place syntax is produced from a resolved type. It
//! exists for the boundaries that still speak `ast.TypeExpr` — the signature
//! materializer and the emitters — and is a rendering of the fact, not a
//! second source of it.

const std = @import("std");

const ast = @import("ast.zig");
const numeric = @import("numeric.zig");
const semantic_ids = @import("semantic_ids.zig");

/// Declaration identity. A nominal type is the declaration it names, not the
/// spelling of that declaration: `src/sema_symbols.zig` gives every
/// declaration a `DefId` during checking and this table carries it.
pub const DefId = semantic_ids.DefId;

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

pub const FloatWidth = enum {
    f32,
    f64,
};

/// A builtin type that is neither a scalar nor a declaration: the language
/// names it and no source declares it. Each is its own identity, exactly as
/// sema's `TypeClass` already keeps them apart.
pub const Builtin = enum {
    never,
    order,
    cstr,
    paddr,
    vaddr,
    dma_addr,
    c_void,
    va_list,

    pub fn fromName(name: []const u8) ?Builtin {
        const table = .{
            .{ "never", Builtin.never },
            .{ "Order", Builtin.order },
            .{ "cstr", Builtin.cstr },
            .{ "PAddr", Builtin.paddr },
            .{ "VAddr", Builtin.vaddr },
            .{ "DmaAddr", Builtin.dma_addr },
            .{ "c_void", Builtin.c_void },
            .{ "va_list", Builtin.va_list },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn spelling(self: Builtin) []const u8 {
        return switch (self) {
            .never => "never",
            .order => "Order",
            .cstr => "cstr",
            .paddr => "PAddr",
            .vaddr => "VAddr",
            .dma_addr => "DmaAddr",
            .c_void => "c_void",
            .va_list => "va_list",
        };
    }
};

/// How a type may be written through. Mirrors the source qualifier without
/// being it: the table stores the fact, not the token.
pub const Mutability = enum {
    none,
    mut,
    constant,

    pub fn fromSyntax(mutability: ast.Mutability) Mutability {
        return switch (mutability) {
            .none => .none,
            .mut => .mut,
            .@"const" => .constant,
        };
    }

    pub fn toSyntax(self: Mutability) ast.Mutability {
        return switch (self) {
            .none => .none,
            .mut => .mut,
            .constant => .@"const",
        };
    }
};

/// What a nominal declaration is. The identity alone answers "which
/// declaration"; this answers "what kind of declaration", which several
/// consumers ask without wanting to look the declaration up again.
pub const NominalKind = enum {
    struct_,
    enum_,
    tagged_union,
    overlay_union,
    packed_bits,
    alias,
    opaque_type,
    trait,
};

pub const Nominal = struct {
    def_id: DefId,
    kind: NominalKind,

    pub fn eql(self: Nominal, other: Nominal) bool {
        return self.def_id.eql(other.def_id) and self.kind == other.kind;
    }
};

/// `*T` and `[*]T` are different pointers, not one pointer with a flag on the
/// side: a raw many-pointer indexes and a single pointer does not.
pub const PointerKind = enum {
    single,
    raw_many,
};

/// MC has no address class on the pointer type itself. A physical, virtual,
/// DMA, or MMIO address is a distinct builtin or nominal type (`PAddr`,
/// `VAddr`, `DmaAddr`, an MMIO register struct pointer), so the address class
/// is already an identity in this table rather than a qualifier to model here.
pub const Pointer = struct {
    kind: PointerKind,
    mutability: Mutability,
    /// `?*T`. Nullability of a pointer lives here rather than in `optional`,
    /// because a nullable pointer is a niche in the pointer itself, while
    /// `?T` for a value payload is a tagged aggregate. Keeping them apart is
    /// the distinction sema's own `nullable_pointer` / `nullable_value`
    /// classes already draw, and it gives the table exactly one spelling of
    /// each.
    nullable: bool,
    child: TypeId,

    pub fn eql(self: Pointer, other: Pointer) bool {
        return self.kind == other.kind and self.mutability == other.mutability and
            self.nullable == other.nullable and self.child.eql(other.child);
    }
};

pub const Slice = struct {
    mutability: Mutability,
    child: TypeId,

    pub fn eql(self: Slice, other: Slice) bool {
        return self.mutability == other.mutability and self.child.eql(other.child);
    }
};

/// A fixed array. The length is the evaluated count, not the expression that
/// spelled it; an array whose length sema could not evaluate is not recorded.
pub const Array = struct {
    len: u64,
    child: TypeId,

    pub fn eql(self: Array, other: Array) bool {
        return self.len == other.len and self.child.eql(other.child);
    }
};

pub const Result = struct {
    ok: TypeId,
    err: TypeId,

    pub fn eql(self: Result, other: Result) bool {
        return self.ok.eql(other.ok) and self.err.eql(other.err);
    }
};

pub const Qualified = struct {
    mutability: Mutability,
    child: TypeId,

    pub fn eql(self: Qualified, other: Qualified) bool {
        return self.mutability == other.mutability and self.child.eql(other.child);
    }
};

pub const SignatureKind = enum {
    fn_pointer,
    closure,
};

/// A callable type. `params` is a run in the table's own list storage, and
/// runs are interned too, so two signatures with the same parameter types
/// share one run and compare equal by reference.
pub const Signature = struct {
    kind: SignatureKind,
    params: TypeList,
    ret: TypeId,

    pub fn eql(self: Signature, other: Signature) bool {
        return self.kind == other.kind and self.params.eql(other.params) and self.ret.eql(other.ret);
    }
};

/// A generic the language itself provides. `Result` is not here: it is
/// common enough, and structural enough, to be its own variant.
pub const BuiltinGeneric = enum {
    atomic,
    dma_buf,
    user_ptr,
    mmio_ptr,
    phys_ptr,
    secret,
    wrap,
    sat,
    serial,
    counter,
    duration,
    maybe_uninit,

    pub fn fromName(name: []const u8) ?BuiltinGeneric {
        const table = .{
            .{ "atomic", BuiltinGeneric.atomic },
            .{ "DmaBuf", BuiltinGeneric.dma_buf },
            .{ "UserPtr", BuiltinGeneric.user_ptr },
            .{ "MmioPtr", BuiltinGeneric.mmio_ptr },
            .{ "PhysPtr", BuiltinGeneric.phys_ptr },
            .{ "Secret", BuiltinGeneric.secret },
            .{ "wrap", BuiltinGeneric.wrap },
            .{ "sat", BuiltinGeneric.sat },
            .{ "serial", BuiltinGeneric.serial },
            .{ "counter", BuiltinGeneric.counter },
            .{ "Duration", BuiltinGeneric.duration },
            .{ "MaybeUninit", BuiltinGeneric.maybe_uninit },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn spelling(self: BuiltinGeneric) []const u8 {
        return switch (self) {
            .atomic => "atomic",
            .dma_buf => "DmaBuf",
            .user_ptr => "UserPtr",
            .mmio_ptr => "MmioPtr",
            .phys_ptr => "PhysPtr",
            .secret => "Secret",
            .wrap => "wrap",
            .sat => "sat",
            .serial => "serial",
            .counter => "counter",
            .duration => "Duration",
            .maybe_uninit => "MaybeUninit",
        };
    }
};

pub const GenericBase = union(enum) {
    decl: DefId,
    builtin: BuiltinGeneric,

    pub fn eql(self: GenericBase, other: GenericBase) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .decl => |lhs| lhs.eql(other.decl),
            .builtin => |lhs| lhs == other.builtin,
        };
    }
};

/// A generic instantiation: the generic plus the arguments it was applied
/// to. `Container<u32>` and `Container<u64>` are two types of one
/// declaration, which is why the base is an identity and the arguments are
/// part of the structure.
pub const Generic = struct {
    base: GenericBase,
    args: TypeList,

    pub fn eql(self: Generic, other: Generic) bool {
        return self.base.eql(other.base) and self.args.eql(other.args);
    }
};

/// `*dyn Trait` / `*mut dyn Trait`: one fat pointer whose pointee is a trait.
pub const DynTrait = struct {
    mutability: Mutability,
    trait: DefId,

    pub fn eql(self: DynTrait, other: DynTrait) bool {
        return self.mutability == other.mutability and self.trait.eql(other.trait);
    }
};

/// A run of `TypeId`s in the table's list storage. The empty run is always
/// `empty`, so equality and hashing agree on it.
pub const TypeList = struct {
    start: u32,
    len: u32,

    pub const empty: TypeList = .{ .start = 0, .len = 0 };

    pub fn eql(self: TypeList, other: TypeList) bool {
        if (self.len != other.len) return false;
        return self.len == 0 or self.start == other.start;
    }
};

/// A resolved type. Scalars are structural, a nominal type is an identity,
/// and a composite is built out of other resolved types rather than out of
/// the syntax that spelled it.
pub const ResolvedType = union(enum) {
    void_,
    boolean,
    integer: Integer,
    float: FloatWidth,
    builtin: Builtin,
    nominal: Nominal,
    pointer: Pointer,
    slice: Slice,
    array: Array,
    /// `?T` for a value payload. Pointer nullability is `Pointer.nullable`.
    optional: TypeId,
    result: Result,
    signature: Signature,
    generic: Generic,
    qualified: Qualified,
    dyn_trait: DynTrait,

    pub const Integer = struct {
        signed: bool,
        width: IntWidth,
    };

    pub fn eql(self: ResolvedType, other: ResolvedType) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .void_, .boolean => true,
            .integer => |lhs| lhs.signed == other.integer.signed and lhs.width == other.integer.width,
            .float => |lhs| lhs == other.float,
            .builtin => |lhs| lhs == other.builtin,
            .nominal => |lhs| lhs.eql(other.nominal),
            .pointer => |lhs| lhs.eql(other.pointer),
            .slice => |lhs| lhs.eql(other.slice),
            .array => |lhs| lhs.eql(other.array),
            .optional => |lhs| lhs.eql(other.optional),
            .result => |lhs| lhs.eql(other.result),
            .signature => |lhs| lhs.eql(other.signature),
            .generic => |lhs| lhs.eql(other.generic),
            .qualified => |lhs| lhs.eql(other.qualified),
            .dyn_trait => |lhs| lhs.eql(other.dyn_trait),
        };
    }

    /// Render a scalar or builtin back to its MC spelling, or null for a type
    /// whose spelling only the owning `Resolved` can supply (a nominal) or
    /// that has no single-name spelling at all (a composite). The result is a
    /// static string, so it outlives any arena.
    pub fn scalarSpelling(self: ResolvedType) ?[]const u8 {
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
            .float => |width| switch (width) {
                .f32 => "f32",
                .f64 => "f64",
            },
            .builtin => |builtin| builtin.spelling(),
            .nominal, .pointer, .slice, .array, .optional, .result, .signature, .generic, .qualified, .dyn_trait => null,
        };
    }
};

/// The scalar type a builtin type name denotes, or null if the name is not a
/// builtin scalar.
pub fn scalarByName(name: []const u8) ?ResolvedType {
    const table = .{
        .{ "void", ResolvedType{ .void_ = {} } },
        .{ "bool", ResolvedType{ .boolean = {} } },
        .{ "u8", ResolvedType{ .integer = .{ .signed = false, .width = .w8 } } },
        .{ "u16", ResolvedType{ .integer = .{ .signed = false, .width = .w16 } } },
        .{ "u32", ResolvedType{ .integer = .{ .signed = false, .width = .w32 } } },
        .{ "u64", ResolvedType{ .integer = .{ .signed = false, .width = .w64 } } },
        .{ "u128", ResolvedType{ .integer = .{ .signed = false, .width = .w128 } } },
        .{ "usize", ResolvedType{ .integer = .{ .signed = false, .width = .pointer } } },
        .{ "i8", ResolvedType{ .integer = .{ .signed = true, .width = .w8 } } },
        .{ "i16", ResolvedType{ .integer = .{ .signed = true, .width = .w16 } } },
        .{ "i32", ResolvedType{ .integer = .{ .signed = true, .width = .w32 } } },
        .{ "i64", ResolvedType{ .integer = .{ .signed = true, .width = .w64 } } },
        .{ "i128", ResolvedType{ .integer = .{ .signed = true, .width = .w128 } } },
        .{ "isize", ResolvedType{ .integer = .{ .signed = true, .width = .pointer } } },
        .{ "f32", ResolvedType{ .float = .f32 } },
        .{ "f64", ResolvedType{ .float = .f64 } },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Index into a `Table`. Opaque on purpose: consumers ask the table, they do
/// not do arithmetic on ids.
pub const TypeId = struct {
    value: u32,

    pub fn eql(self: TypeId, other: TypeId) bool {
        return self.value == other.value;
    }
};

const TypeContext = struct {
    pub fn hash(_: TypeContext, ty: ResolvedType) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, ty);
        return hasher.final();
    }

    pub fn eql(_: TypeContext, lhs: ResolvedType, rhs: ResolvedType) bool {
        return lhs.eql(rhs);
    }
};

/// Structurally interned resolved types: equal types get the same `TypeId`,
/// and equal parameter runs get the same `TypeList`.
pub const Table = struct {
    types: std.ArrayList(ResolvedType) = .empty,
    index: std.HashMapUnmanaged(ResolvedType, TypeId, TypeContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Storage for every interned run, back to back.
    list_items: std.ArrayList(TypeId) = .empty,
    /// One entry per distinct run. Runs are few (one per distinct parameter
    /// list), so interning one is a scan over this list.
    list_runs: std.ArrayList(TypeList) = .empty,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.types.deinit(allocator);
        self.index.deinit(allocator);
        self.list_items.deinit(allocator);
        self.list_runs.deinit(allocator);
    }

    pub fn intern(self: *Table, allocator: std.mem.Allocator, ty: ResolvedType) !TypeId {
        const slot = try self.index.getOrPut(allocator, ty);
        if (slot.found_existing) return slot.value_ptr.*;
        errdefer self.index.removeByPtr(slot.key_ptr);
        try self.types.append(allocator, ty);
        const id: TypeId = .{ .value = @intCast(self.types.items.len - 1) };
        slot.value_ptr.* = id;
        return id;
    }

    /// Intern a run of type ids. The empty run is always `TypeList.empty`.
    pub fn internList(self: *Table, allocator: std.mem.Allocator, ids: []const TypeId) !TypeList {
        if (ids.len == 0) return TypeList.empty;
        for (self.list_runs.items) |run| {
            if (run.len != ids.len) continue;
            const existing = self.list_items.items[run.start .. run.start + run.len];
            var same = true;
            for (existing, ids) |lhs, rhs| {
                if (!lhs.eql(rhs)) {
                    same = false;
                    break;
                }
            }
            if (same) return run;
        }
        const start: u32 = @intCast(self.list_items.items.len);
        try self.list_items.appendSlice(allocator, ids);
        errdefer self.list_items.shrinkRetainingCapacity(start);
        const run: TypeList = .{ .start = start, .len = @intCast(ids.len) };
        try self.list_runs.append(allocator, run);
        return run;
    }

    pub fn get(self: Table, id: TypeId) ResolvedType {
        return self.types.items[id.value];
    }

    pub fn list(self: Table, run: TypeList) []const TypeId {
        return self.list_items.items[run.start .. run.start + run.len];
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

const IdentEntry = struct {
    def_id: DefId,
    /// Two identifier occurrences at one span resolved to different
    /// declarations, so the span is not an identity here. Fail closed, the
    /// way the type entry does.
    ambiguous: bool = false,
};

/// Sema's output: the interned types, where each resolved expression landed,
/// and which declaration each resolved identifier named.
pub const Resolved = struct {
    allocator: std.mem.Allocator,
    table: Table = .{},
    exprs: std.AutoHashMapUnmanaged(ExprKey, Entry) = .empty,
    /// Identifier occurrence -> the declaration it resolved to. Sema's scopes
    /// answer this while checking; recording it keeps the answer instead of
    /// making a later layer recover it from a name.
    ident_defs: std.AutoHashMapUnmanaged(ExprKey, IdentEntry) = .empty,
    /// Spellings of nominal declarations (and of generic and trait
    /// declarations a composite refers to), keyed by the declaration's
    /// identity. `ResolvedType` carries the identity; the spelling lives here
    /// for the boundaries that still emit syntax. Entries are borrowed slices
    /// of source text, which outlive the table within one request.
    nominal_names: std.AutoHashMapUnmanaged(DefId, []const u8) = .empty,
    /// What each type alias resolves to. An alias is recorded as written --
    /// `ResolvedType.nominal` with kind `.alias` -- because its spelling is
    /// what reaches the emitters today; the target is kept beside it so a
    /// later pass can collapse the alias without re-resolving it.
    alias_targets: std.AutoHashMapUnmanaged(DefId, TypeId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Resolved {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Resolved) void {
        self.exprs.deinit(self.allocator);
        self.ident_defs.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.nominal_names.deinit(self.allocator);
        self.alias_targets.deinit(self.allocator);
    }

    pub fn intern(self: *Resolved, ty: ResolvedType) !TypeId {
        return self.table.intern(self.allocator, ty);
    }

    pub fn internList(self: *Resolved, ids: []const TypeId) !TypeList {
        return self.table.internList(self.allocator, ids);
    }

    /// Remember a declaration's spelling for the syntax boundary.
    pub fn nameDecl(self: *Resolved, def_id: DefId, name: []const u8) !void {
        try self.nominal_names.put(self.allocator, def_id, name);
    }

    /// The nominal type of a declaration, remembering its spelling for the
    /// syntax boundary.
    pub fn nominal(self: *Resolved, def_id: DefId, kind: NominalKind, name: []const u8) !TypeId {
        try self.nameDecl(def_id, name);
        return self.intern(.{ .nominal = .{ .def_id = def_id, .kind = kind } });
    }

    pub fn recordAliasTarget(self: *Resolved, alias: DefId, target: TypeId) !void {
        try self.alias_targets.put(self.allocator, alias, target);
    }

    /// The resolved target of a type alias, or null when sema could not
    /// resolve it (or never met it).
    pub fn aliasTarget(self: Resolved, alias: DefId) ?TypeId {
        return self.alias_targets.get(alias);
    }

    /// The single-name MC spelling of a resolved type: structural for a
    /// scalar or builtin, the declaration's own name for a nominal. Null for
    /// a composite, whose spelling is a tree (`toTypeExpr`), and for a nominal
    /// this table never recorded, so a caller falls back instead of emitting
    /// a guess.
    pub fn spelling(self: Resolved, ty: ResolvedType) ?[]const u8 {
        if (ty.scalarSpelling()) |name| return name;
        return switch (ty) {
            .nominal => |info| self.nominal_names.get(info.def_id),
            else => null,
        };
    }

    /// Record which declaration an identifier occurrence named.
    pub fn recordIdentDef(self: *Resolved, span: ast.Span, def_id: DefId) !void {
        const key = ExprKey.fromSpan(span);
        const slot = try self.ident_defs.getOrPut(self.allocator, key);
        if (slot.found_existing) {
            if (!slot.value_ptr.def_id.eql(def_id)) slot.value_ptr.ambiguous = true;
            return;
        }
        slot.value_ptr.* = .{ .def_id = def_id };
    }

    /// The declaration an identifier occurrence named, or null when nothing
    /// was recorded or the span resolved two ways.
    pub fn identDef(self: Resolved, span: ast.Span) ?DefId {
        const entry = self.ident_defs.get(ExprKey.fromSpan(span)) orelse return null;
        if (entry.ambiguous) return null;
        return entry.def_id;
    }

    pub fn record(self: *Resolved, span: ast.Span, ty: ResolvedType) !void {
        try self.recordId(span, try self.intern(ty));
    }

    pub fn recordId(self: *Resolved, span: ast.Span, id: TypeId) !void {
        const key = ExprKey.fromSpan(span);
        const slot = try self.exprs.getOrPut(self.allocator, key);
        if (slot.found_existing) {
            if (!slot.value_ptr.type_id.eql(id)) slot.value_ptr.ambiguous = true;
            return;
        }
        slot.value_ptr.* = .{ .type_id = id };
    }

    pub fn lookupId(self: Resolved, span: ast.Span) ?TypeId {
        const entry = self.exprs.get(ExprKey.fromSpan(span)) orelse return null;
        if (entry.ambiguous) return null;
        return entry.type_id;
    }

    pub fn lookup(self: Resolved, span: ast.Span) ?ResolvedType {
        const id = self.lookupId(span) orelse return null;
        return self.table.get(id);
    }

    pub fn count(self: Resolved) usize {
        return self.exprs.count();
    }

    /// Render a resolved type back to the syntax that spells it. This is the
    /// only place syntax is produced from a resolved type; it serves the
    /// boundaries that still consume `ast.TypeExpr` (the signature
    /// materializer, the emitters) and is a rendering of the fact, not a
    /// second source of it.
    ///
    /// Every node is placed at `span`, because the type has no span of its
    /// own: it is a fact about an expression, not a piece of source. Child
    /// nodes and parameter lists are allocated from `allocator`; the caller
    /// owns them (an arena is the natural choice). Null when a declaration
    /// the type refers to has no recorded spelling, so the caller falls back
    /// rather than emitting a guess. An alias is rendered as written.
    pub fn toTypeExpr(self: *const Resolved, allocator: std.mem.Allocator, id: TypeId, span: ast.Span) std.mem.Allocator.Error!?ast.TypeExpr {
        const ty = self.table.get(id);
        return switch (ty) {
            .void_, .boolean, .integer, .float, .builtin => nameType(ty.scalarSpelling().?, span),
            .nominal => |info| nameType(self.nominal_names.get(info.def_id) orelse return null, span),
            .pointer => |info| {
                const child = (try self.boxedTypeExpr(allocator, info.child, span)) orelse return null;
                const mutability = info.mutability.toSyntax();
                const bare: ast.TypeExpr = switch (info.kind) {
                    .single => .{ .span = span, .kind = .{ .pointer = .{ .mutability = mutability, .child = child } } },
                    .raw_many => .{ .span = span, .kind = .{ .raw_many_pointer = .{ .mutability = mutability, .child = child } } },
                };
                if (!info.nullable) return bare;
                const boxed = try allocator.create(ast.TypeExpr);
                boxed.* = bare;
                return .{ .span = span, .kind = .{ .nullable = boxed } };
            },
            .slice => |info| .{ .span = span, .kind = .{ .slice = .{
                .mutability = info.mutability.toSyntax(),
                .child = (try self.boxedTypeExpr(allocator, info.child, span)) orelse return null,
            } } },
            .array => |info| .{ .span = span, .kind = .{ .array = .{
                .len = .{ .span = span, .kind = .{ .int_literal = try std.fmt.allocPrint(allocator, "{d}", .{info.len}) } },
                .child = (try self.boxedTypeExpr(allocator, info.child, span)) orelse return null,
            } } },
            .optional => |child| .{ .span = span, .kind = .{
                .nullable = (try self.boxedTypeExpr(allocator, child, span)) orelse return null,
            } },
            .result => |info| {
                const args = try allocator.alloc(ast.TypeExpr, 2);
                args[0] = (try self.toTypeExpr(allocator, info.ok, span)) orelse return null;
                args[1] = (try self.toTypeExpr(allocator, info.err, span)) orelse return null;
                return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "Result", .span = span }, .args = args } } };
            },
            .signature => |info| {
                const params = (try self.typeExprList(allocator, info.params, span)) orelse return null;
                const ret = (try self.boxedTypeExpr(allocator, info.ret, span)) orelse return null;
                return switch (info.kind) {
                    .fn_pointer => .{ .span = span, .kind = .{ .fn_pointer = .{ .params = params, .ret = ret } } },
                    .closure => .{ .span = span, .kind = .{ .closure_type = .{ .params = params, .ret = ret } } },
                };
            },
            .generic => |info| {
                const base = switch (info.base) {
                    .decl => |def_id| self.nominal_names.get(def_id) orelse return null,
                    .builtin => |builtin| builtin.spelling(),
                };
                const args = (try self.typeExprList(allocator, info.args, span)) orelse return null;
                return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = base, .span = span }, .args = args } } };
            },
            .qualified => |info| .{ .span = span, .kind = .{ .qualified = .{
                .mutability = info.mutability.toSyntax(),
                .child = (try self.boxedTypeExpr(allocator, info.child, span)) orelse return null,
            } } },
            .dyn_trait => |info| .{ .span = span, .kind = .{ .dyn_trait = .{
                .mutability = info.mutability.toSyntax(),
                .trait_name = .{ .text = self.nominal_names.get(info.trait) orelse return null, .span = span },
            } } },
        };
    }

    fn boxedTypeExpr(self: *const Resolved, allocator: std.mem.Allocator, id: TypeId, span: ast.Span) std.mem.Allocator.Error!?*ast.TypeExpr {
        const rendered = (try self.toTypeExpr(allocator, id, span)) orelse return null;
        const boxed = try allocator.create(ast.TypeExpr);
        boxed.* = rendered;
        return boxed;
    }

    fn typeExprList(self: *const Resolved, allocator: std.mem.Allocator, run: TypeList, span: ast.Span) std.mem.Allocator.Error!?[]ast.TypeExpr {
        const ids = self.table.list(run);
        const rendered = try allocator.alloc(ast.TypeExpr, ids.len);
        for (ids, 0..) |id, index| {
            rendered[index] = (try self.toTypeExpr(allocator, id, span)) orelse return null;
        }
        return rendered;
    }

    /// Whether a resolved type and a type expression spell the same type.
    /// This is the debug cross-check between the table and a consumer that
    /// still computes syntax of its own: it compares structure to structure
    /// without rendering, treats an alias as written on both sides, and
    /// compares an array length only when the syntax states it as a literal
    /// (the table holds the evaluated count, the syntax may hold `N`).
    pub fn agreesWithSyntax(self: Resolved, id: TypeId, syntax: ast.TypeExpr) bool {
        return self.agrees(self.table.get(id), syntax);
    }

    fn agreesId(self: Resolved, id: TypeId, syntax: ast.TypeExpr) bool {
        return self.agrees(self.table.get(id), syntax);
    }

    fn agrees(self: Resolved, ty: ResolvedType, syntax: ast.TypeExpr) bool {
        switch (syntax.kind) {
            .name => |name| {
                const spelled = self.spelling(ty) orelse return false;
                return std.mem.eql(u8, spelled, name.text);
            },
            .qualified => |node| return switch (ty) {
                .qualified => |info| info.mutability == Mutability.fromSyntax(node.mutability) and self.agreesId(info.child, node.child.*),
                else => false,
            },
            .pointer => |node| return switch (ty) {
                .pointer => |info| info.kind == .single and !info.nullable and
                    info.mutability == Mutability.fromSyntax(node.mutability) and self.agreesId(info.child, node.child.*),
                else => false,
            },
            .raw_many_pointer => |node| return switch (ty) {
                .pointer => |info| info.kind == .raw_many and !info.nullable and
                    info.mutability == Mutability.fromSyntax(node.mutability) and self.agreesId(info.child, node.child.*),
                else => false,
            },
            .slice => |node| return switch (ty) {
                .slice => |info| info.mutability == Mutability.fromSyntax(node.mutability) and self.agreesId(info.child, node.child.*),
                else => false,
            },
            .array => |node| return switch (ty) {
                .array => |info| self.agreesId(info.child, node.child.*) and arrayLenAgrees(info.len, node.len),
                else => false,
            },
            .nullable => |child| return switch (ty) {
                .pointer => |info| info.nullable and self.agrees(.{ .pointer = .{
                    .kind = info.kind,
                    .mutability = info.mutability,
                    .nullable = false,
                    .child = info.child,
                } }, child.*),
                .optional => |inner| self.agreesId(inner, child.*),
                else => false,
            },
            .generic => |node| {
                if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                    return switch (ty) {
                        .result => |info| self.agreesId(info.ok, node.args[0]) and self.agreesId(info.err, node.args[1]),
                        else => false,
                    };
                }
                const info = switch (ty) {
                    .generic => |info| info,
                    else => return false,
                };
                const base = switch (info.base) {
                    .decl => |def_id| self.nominal_names.get(def_id) orelse return false,
                    .builtin => |builtin| builtin.spelling(),
                };
                if (!std.mem.eql(u8, base, node.base.text)) return false;
                return self.listAgrees(info.args, node.args);
            },
            .fn_pointer => |node| return switch (ty) {
                .signature => |info| info.kind == .fn_pointer and self.listAgrees(info.params, node.params) and self.agreesId(info.ret, node.ret.*),
                else => false,
            },
            .closure_type => |node| return switch (ty) {
                .signature => |info| info.kind == .closure and self.listAgrees(info.params, node.params) and self.agreesId(info.ret, node.ret.*),
                else => false,
            },
            .dyn_trait => |node| return switch (ty) {
                .dyn_trait => |info| info.mutability == Mutability.fromSyntax(node.mutability) and
                    std.mem.eql(u8, self.nominal_names.get(info.trait) orelse return false, node.trait_name.text),
                else => false,
            },
            .enum_literal, .member => return false,
        }
    }

    fn listAgrees(self: Resolved, run: TypeList, syntax: []const ast.TypeExpr) bool {
        const ids = self.table.list(run);
        if (ids.len != syntax.len) return false;
        for (ids, syntax) |id, item| {
            if (!self.agreesId(id, item)) return false;
        }
        return true;
    }
};

fn arrayLenAgrees(len: u64, syntax: ast.Expr) bool {
    const literal = numeric.integerLiteralValue(syntax) orelse return true;
    if (literal.negative) return false;
    return literal.magnitude == len;
}

fn nameType(name: []const u8, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

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

    const a = try resolved.intern(.{ .integer = .{ .signed = false, .width = .w32 } });
    const b = try resolved.intern(.{ .integer = .{ .signed = false, .width = .w32 } });
    const c = try resolved.intern(.{ .integer = .{ .signed = true, .width = .w32 } });
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expectEqual(@as(usize, 2), resolved.table.len());
}

test "composite types intern structurally, including parameter runs" {
    var resolved = Resolved.init(std.testing.allocator);
    defer resolved.deinit();

    const u8_id = try resolved.intern(.{ .integer = .{ .signed = false, .width = .w8 } });
    const u32_id = try resolved.intern(.{ .integer = .{ .signed = false, .width = .w32 } });

    const p1 = try resolved.intern(.{ .pointer = .{ .kind = .single, .mutability = .mut, .nullable = false, .child = u8_id } });
    const p2 = try resolved.intern(.{ .pointer = .{ .kind = .single, .mutability = .mut, .nullable = false, .child = u8_id } });
    const p3 = try resolved.intern(.{ .pointer = .{ .kind = .single, .mutability = .mut, .nullable = true, .child = u8_id } });
    const p4 = try resolved.intern(.{ .pointer = .{ .kind = .raw_many, .mutability = .mut, .nullable = false, .child = u8_id } });
    try std.testing.expect(p1.eql(p2));
    try std.testing.expect(!p1.eql(p3));
    try std.testing.expect(!p1.eql(p4));

    const run_a = try resolved.internList(&.{ u8_id, u32_id });
    const run_b = try resolved.internList(&.{ u8_id, u32_id });
    const run_c = try resolved.internList(&.{ u32_id, u8_id });
    try std.testing.expect(run_a.eql(run_b));
    try std.testing.expect(!run_a.eql(run_c));
    try std.testing.expect((try resolved.internList(&.{})).eql(TypeList.empty));

    const s1 = try resolved.intern(.{ .signature = .{ .kind = .fn_pointer, .params = run_a, .ret = u32_id } });
    const s2 = try resolved.intern(.{ .signature = .{ .kind = .fn_pointer, .params = run_b, .ret = u32_id } });
    const s3 = try resolved.intern(.{ .signature = .{ .kind = .closure, .params = run_a, .ret = u32_id } });
    try std.testing.expect(s1.eql(s2));
    try std.testing.expect(!s1.eql(s3));

    const arr1 = try resolved.intern(.{ .array = .{ .len = 4, .child = u8_id } });
    const arr2 = try resolved.intern(.{ .array = .{ .len = 4, .child = u8_id } });
    const arr3 = try resolved.intern(.{ .array = .{ .len = 8, .child = u8_id } });
    try std.testing.expect(arr1.eql(arr2));
    try std.testing.expect(!arr1.eql(arr3));

    const def: DefId = .{ .file_id = 0, .ordinal = 3 };
    const n1 = try resolved.nominal(def, .struct_, "Point");
    const n2 = try resolved.nominal(def, .struct_, "Point");
    try std.testing.expect(n1.eql(n2));
    const g1 = try resolved.intern(.{ .generic = .{ .base = .{ .decl = def }, .args = run_a } });
    const g2 = try resolved.intern(.{ .generic = .{ .base = .{ .decl = def }, .args = run_b } });
    const g3 = try resolved.intern(.{ .generic = .{ .base = .{ .builtin = .sat }, .args = run_a } });
    try std.testing.expect(g1.eql(g2));
    try std.testing.expect(!g1.eql(g3));
}

test "toTypeExpr renders a composite that agreesWithSyntax accepts" {
    var resolved = Resolved.init(std.testing.allocator);
    defer resolved.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const span: ast.Span = .{ .offset = 0, .len = 1, .line = 1, .column = 1 };

    const u8_id = try resolved.intern(.{ .integer = .{ .signed = false, .width = .w8 } });
    const point = try resolved.nominal(.{ .file_id = 0, .ordinal = 1 }, .struct_, "Point");
    const arr = try resolved.intern(.{ .array = .{ .len = 4, .child = u8_id } });
    const ptr = try resolved.intern(.{ .pointer = .{ .kind = .single, .mutability = .constant, .nullable = true, .child = arr } });
    const params = try resolved.internList(&.{ ptr, point });
    const sig = try resolved.intern(.{ .signature = .{ .kind = .fn_pointer, .params = params, .ret = point } });
    const res = try resolved.intern(.{ .result = .{ .ok = sig, .err = u8_id } });

    const rendered = (try resolved.toTypeExpr(arena.allocator(), res, span)).?;
    // Result<fn(?*const [4]u8, Point) -> Point, u8>
    const generic = rendered.kind.generic;
    try std.testing.expectEqualStrings("Result", generic.base.text);
    try std.testing.expectEqual(@as(usize, 2), generic.args.len);
    const fn_ptr = generic.args[0].kind.fn_pointer;
    try std.testing.expectEqual(@as(usize, 2), fn_ptr.params.len);
    try std.testing.expect(fn_ptr.params[0].kind == .nullable);
    const pointer = fn_ptr.params[0].kind.nullable.*.kind.pointer;
    try std.testing.expect(pointer.mutability == .@"const");
    try std.testing.expectEqualStrings("4", pointer.child.*.kind.array.len.kind.int_literal);
    try std.testing.expectEqualStrings("u8", pointer.child.*.kind.array.child.*.kind.name.text);
    try std.testing.expectEqualStrings("Point", fn_ptr.params[1].kind.name.text);
    try std.testing.expectEqualStrings("Point", fn_ptr.ret.*.kind.name.text);
    try std.testing.expectEqualStrings("u8", generic.args[1].kind.name.text);

    try std.testing.expect(resolved.agreesWithSyntax(res, rendered));
    try std.testing.expect(!resolved.agreesWithSyntax(sig, rendered));
    try std.testing.expect(!resolved.agreesWithSyntax(res, generic.args[0]));
    // A nullable pointer is not an optional of a pointer.
    try std.testing.expect(resolved.agreesWithSyntax(ptr, fn_ptr.params[0]));
    const bare_ptr = try resolved.intern(.{ .pointer = .{ .kind = .single, .mutability = .constant, .nullable = false, .child = arr } });
    try std.testing.expect(!resolved.agreesWithSyntax(bare_ptr, fn_ptr.params[0]));
    try std.testing.expect(resolved.agreesWithSyntax(bare_ptr, fn_ptr.params[0].kind.nullable.*));
}

test "literal scalar rule covers suffixed, unsuffixed, bool and void" {
    const span: ast.Span = .{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    try std.testing.expectEqualStrings("u32", integerOfLiteral("7").scalarSpelling().?);
    try std.testing.expectEqualStrings("i64", integerOfLiteral("7_i64").scalarSpelling().?);
    try std.testing.expectEqualStrings("usize", integerOfLiteral("7_usize").scalarSpelling().?);
    try std.testing.expect(suffixedIntegerOfLiteral("7") == null);

    const bool_expr: ast.Expr = .{ .span = span, .kind = .{ .bool_literal = true } };
    try std.testing.expectEqualStrings("bool", scalarOfLiteral(bool_expr).?.scalarSpelling().?);

    const void_expr: ast.Expr = .{ .span = span, .kind = .void_literal };
    try std.testing.expectEqualStrings("void", scalarOfLiteral(void_expr).?.scalarSpelling().?);

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
