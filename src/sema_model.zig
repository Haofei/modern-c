const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");

const MmioRegisterAccess = ast_query.MmioRegisterAccess;

pub const max_move_place_projections = 16;

pub const MovePlaceProjection = union(enum) {
    field: []const u8,
    constant_index: usize,
    symbolic_index: []const u8,
    wildcard_index,
};

pub const MovePlace = struct {
    root: []const u8,
    projections: [max_move_place_projections]MovePlaceProjection = undefined,
    projection_count: usize = 0,

    pub fn isSubplace(self: MovePlace) bool {
        return self.projection_count != 0;
    }

    pub fn project(self: MovePlace, projection: MovePlaceProjection) ?MovePlace {
        if (self.projection_count == max_move_place_projections) return null;
        var result = self;
        result.projections[result.projection_count] = projection;
        result.projection_count += 1;
        return result;
    }

    pub fn eql(self: MovePlace, other: MovePlace) bool {
        if (!std.mem.eql(u8, self.root, other.root) or self.projection_count != other.projection_count) return false;
        for (self.projections[0..self.projection_count], other.projections[0..other.projection_count]) |left, right| {
            if (!projectionEql(left, right)) return false;
        }
        return true;
    }

    // `self` is a strict ancestor of `other`, such as `packet.header` for
    // `packet.header.payload`. Whole-place moves deliberately use this relation
    // to reject partial-move aggregate reuse without reparsing display keys.
    pub fn isPrefixOf(self: MovePlace, other: MovePlace) bool {
        if (!std.mem.eql(u8, self.root, other.root) or self.projection_count >= other.projection_count) return false;
        for (self.projections[0..self.projection_count], other.projections[0..self.projection_count]) |left, right| {
            if (!projectionEql(left, right)) return false;
        }
        return true;
    }

    // A wildcard element represents an unknown element of the same array. It
    // conflicts with every concrete/symbolic element at that projection level.
    pub fn conflicts(self: MovePlace, other: MovePlace) bool {
        if (!std.mem.eql(u8, self.root, other.root) or self.projection_count != other.projection_count) return false;
        for (self.projections[0..self.projection_count], other.projections[0..other.projection_count]) |left, right| {
            if (projectionEql(left, right)) continue;
            if (projectionWildcardMatches(left, right)) continue;
            return false;
        }
        return true;
    }
};

fn projectionEql(left: MovePlaceProjection, right: MovePlaceProjection) bool {
    return switch (left) {
        .field => |left_name| switch (right) {
            .field => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        .constant_index => |left_index| switch (right) {
            .constant_index => |right_index| left_index == right_index,
            else => false,
        },
        .symbolic_index => |left_name| switch (right) {
            .symbolic_index => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        .wildcard_index => right == .wildcard_index,
    };
}

fn projectionWildcardMatches(left: MovePlaceProjection, right: MovePlaceProjection) bool {
    return (left == .wildcard_index and right != .field) or
        (right == .wildcard_index and left != .field);
}

pub const Context = struct {
    no_lang_trap: bool = false,
    // C2: the enclosing function runs in IRQ/atomic context (`#[irq_context]`/
    // `#[atomic]`); calling a `#[may_sleep]` op is "sleeping in interrupt".
    irq_context: bool = false,
    // T(term)1 + traits-design review #2: the enclosing function is `#[bounded]`
    // (or IRQ/atomic, which is also bounded). An INDIRECT call (fn pointer, closure,
    // or `*dyn` dispatch) is rejected here - the termination check cannot see through
    // it, so `dyn` cannot smuggle unbounded behavior into a bounded context.
    bounded: bool = false,
    in_unsafe: bool = false,
    in_comptime: bool = false,
    returns_never: bool = false,
    returns_void: bool = false,
    return_ty: ?ast.TypeExpr = null,
    return_kind: TypeClass = .void,
    loop_depth: usize = 0,
    // G7: stack of in-scope loop labels (`outer:`), innermost first, threaded on
    // the checker's call stack (no allocation). A labeled `break :outer` /
    // `continue :outer` resolves its target against this chain.
    loop_labels: ?*const LoopLabelNode = null,
    unsafe_contracts: UnsafeContracts = .{},
    scope: ?*Scope = null,
    allow_mmio_register_type: bool = false,
    mmio_structs: ?*const std.StringHashMap(MmioStruct) = null,
    mmio_params: ?*const std.StringHashMap([]const u8) = null,
    structs: ?*const std.StringHashMap(StructInfo) = null,
    packed_bits: ?*const std.StringHashMap(LayoutFieldInfo) = null,
    overlay_unions: ?*const std.StringHashMap(LayoutFieldInfo) = null,
    tagged_unions: ?*const std.StringHashMap(UnionInfo) = null,
    enums: ?*const std.StringHashMap(EnumInfo) = null,
    type_aliases: ?*const std.StringHashMap(ast.TypeExpr) = null,
    functions: ?*const std.StringHashMap(FunctionInfo) = null,
    globals: ?*const std.StringHashMap(GlobalInfo) = null,
    // Trait declarations, for resolving a `*dyn Trait` dispatch's return type in
    // exprResultType (so a dispatch result flows into a typed binding). Optional: when
    // absent, dyn-dispatch return-type lookup gracefully no-ops.
    trait_decls: ?*const std.StringHashMap(ast.TraitDecl) = null,
    // `const fn` bodies, for evaluating comptime const-fn calls (e.g. when a
    // const-fn result drives a fixed-array length - section 22 comptime<->type).
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Folded `const NAME: T = …` global values, for resolving named compile-time
    // constants in comptime contexts and array lengths.
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
    // Names of the current function's `comptime T: type` type parameters
    // (user-defined generics, section 22); valid as type names in its body.
    type_params: ?*const std.StringHashMap(void) = null,
    // `where T: Trait` bounds on the current function's comptime type parameters.
    // Used during generic-template precheck to validate `T.method(...)` calls
    // before an unused template can be dropped by monomorphization.
    trait_bounds: []const ast.TraitBound = &.{},
    // Names of the current function's non-type `comptime` parameters. Expressions
    // derived from these are compile-time constants once a generic caller is
    // instantiated, even if the template precheck cannot fold their concrete value.
    comptime_params: ?*const std.StringHashMap(void) = null,
};

// G7: one entry in the in-scope loop-label chain (see Context.loop_labels).
pub const LoopLabelNode = struct {
    label: []const u8,
    parent: ?*const LoopLabelNode,

    pub fn contains(self: ?*const LoopLabelNode, name: []const u8) bool {
        var cur = self;
        while (cur) |node| : (cur = node.parent) {
            if (std.mem.eql(u8, node.label, name)) return true;
        }
        return false;
    }
};

pub const MmioStruct = struct {
    fields: std.StringHashMap(MmioFieldInfo),
};

pub const MmioFieldInfo = struct {
    access: MmioRegisterAccess,
};

pub const StructInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
    ordered: []const ast.Field,
    abi: ?[]const u8 = null,
    type_param_count: usize = 0,
    // `opaque struct` - fields are private to the struct's associated functions.
    is_opaque: bool = false,
    // `#[c_union]` - compiler-internal addressable union (union layout; see ast.StructDecl).
    is_c_union: bool = false,
};

// Liveness slot for a linear `move` binding (section 18.1 / annex D.7).
pub const MoveSlot = struct {
    live: bool,
    span: diagnostics.Span,
    // Structured identity for the root, field, and element place represented by
    // this slot. The state map retains a display key as a compatibility index,
    // while ownership relations are evaluated from this value.
    place: ?MovePlace = null,
    // Reserved by a `defer` to be consumed at scope end: not a leak, not movable.
    deferred: bool = false,
    // A place borrowed by a deferred expression. Unlike `deferred`, this does not
    // consume the resource or suppress leak checks; it only prevents moving the
    // borrowed root/subplace before deferred cleanup runs.
    deferred_borrow: ?[]const u8 = null,
    deferred_borrow_place: ?MovePlace = null,
    // The binding's declared/inferred type, when known - used to look up a `move` field's
    // type for place-sensitive field-move tracking. Null for synthetic field place keys.
    ty: ?ast.TypeExpr = null,
    // Non-resource local whose type is retained only so place-sensitive helpers can resolve
    // fixed-array/member paths. It is not a linear value and must not participate in move,
    // borrow, or leak diagnostics.
    type_only: bool = false,
    // Non-live scalar locals proven to hold a constant array index. The move checker uses
    // these only to turn `arr[i]` into the same stable place as `arr[0]` when `i` was
    // initialized from a constant index literal.
    const_index: ?usize = null,
    // Non-live scalar locals/params that name a stable but runtime-known array index.
    // This is narrower than arbitrary symbolic arithmetic: `arr[i]` and a copied
    // immutable `let j = i` can share a precise dynamic place key, while concrete
    // and unrelated dynamic indexes still conflict conservatively.
    symbolic_index: ?[]const u8 = null,
    // T1.2: if this binding is a pointer/reference DERIVED from a tracked `move` binding
    // (taken via `&x` and bound to `let p = &x`), this is the referent's binding name. The
    // alias is itself a borrow - not a linear resource (`live`/leak rules do not apply to it)
    // - but reading through it (`*p`, `peek(p)`) after the referent was moved out is a
    // use-after-move (a stale derived alias). Null for non-alias bindings.
    alias_of: ?[]const u8 = null,
    // Typed identity of `alias_of` when the referent is a nameable move place.
    // `alias_of` remains a map-lookup/display compatibility key during the
    // transition; stale-alias ownership checks use this structured value.
    alias_place: ?MovePlace = null,
    // T1.2 (conservative rejection): a borrow of this move binding (or of one of its
    // subfields/elements) has been stored into MEMORY - an aggregate field, an array
    // element, or aliased through a subfield place - somewhere we cannot prove dead. Unlike
    // a tracked scalar pointer local (`let p = &t`, tracked by the stale-alias mechanism),
    // such an escaped borrow is unreachable to the use-after-move tracker, so we instead
    // refuse to MOVE the binding while this is set (the borrow could still be read after the
    // move). Holds the span of the escaping store, for the diagnostic. Null when no borrow
    // has escaped into untracked memory.
    escaped_borrow: ?diagnostics.Span = null,
    // True for bindings declared inside a deferred cleanup block. Aliases to these bindings
    // are checked for stale cleanup-order use, but they should not reserve an outer deferred
    // borrow because the referent itself only exists during cleanup execution.
    cleanup_local: bool = false,
    // Set when this alias was formed by taking the address of the move binding ITSELF
    // (`let p = &o;`, or copied from such an alias `let q = p;`), so dereferencing it
    // reconstitutes the whole move value: `*p` IS `o`. Moving `*p` out by value (e.g.
    // `own_free(T, *p)`) is then a move-out THROUGH the alias - unsound, because the
    // checker tracks the owning binding, not the pointee, so it can neither stop a later
    // free of `o` (a double-free) nor a use of the now moved-from pointee. The move-out
    // is rejected in moveConsume's `.deref` arm. False for DERIVED aliases (`p = f(&o)`,
    // `p = &o.field`) where `*p` is sub-data, not the move binding - those stay borrows.
    full_deref_alias: bool = false,
};

pub const LoopMoveFrame = struct {
    // Source loop label (`outer:`), when present. The move pass uses this to
    // route a labeled break/continue to the same loop edge as semantic checking
    // and backend lowering.
    label: ?[]const u8 = null,
    entry_names: std.StringHashMap(void),
    entry_state: std.StringHashMap(MoveSlot),
    invalidated_const_indexes: std.StringHashMap(void),
    invalidated_aliases: std.StringHashMap(void),

    pub fn deinit(self: *LoopMoveFrame) void {
        self.entry_names.deinit();
        self.entry_state.deinit();
        self.invalidated_const_indexes.deinit();
        self.invalidated_aliases.deinit();
    }
};

pub const LayoutFieldInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
    ordered: []const ast.Field,
    repr: ?ast.TypeExpr = null,
};

pub const EnumInfo = struct {
    cases: std.StringHashMap(void),
    is_open: bool,
    repr: ?ast.TypeExpr,
};

pub const UnionInfo = struct {
    cases: std.StringHashMap(?ast.TypeExpr),
    type_param_count: usize = 0,
};

pub const FunctionInfo = struct {
    params: []const ast.Param,
    return_ty: ?ast.TypeExpr,
    is_extern: bool = false,
    no_lang_trap: bool = false,
    is_const: bool = false,
    // C2: this function is a sleepable op (`#[may_sleep]`) - calling it from an
    // `#[irq_context]`/`#[atomic]` function is a compile error.
    may_sleep: bool = false,
    // C2: this function itself runs in IRQ/atomic context (`#[irq_context]`/
    // `#[atomic_context]`). An irq-context caller may ONLY call other irq-context
    // functions (or non-blocking primitives) - this mirrors the MIR verifier's
    // `E_IRQ_CONTEXT_CALL` discipline so `mcc check` and `mcc verify` agree.
    irq_context: bool = false,
    // T(term)1: this function has a statically-constrained termination context:
    // either `#[bounded]` directly or IRQ/atomic context, which is bounded too.
    bounded: bool = false,
    // G8: this function is an `#[error_from]` conversion `fn(E1) -> E2`, invoked by
    // `?` on the error path when the propagated error type differs from the
    // enclosing function's error type.
    error_from: bool = false,
};

pub const GlobalInfo = struct {
    ty: ast.TypeExpr,
};

pub const UnsafeContracts = struct {
    no_overflow: bool = false,
    noalias_contract: bool = false,
    precise_asm: bool = false,

    pub fn with(self: UnsafeContracts, attr: ast.Attr) UnsafeContracts {
        var next = self;
        switch (attr.kind) {
            .unsafe_contract => |contract| {
                if (std.mem.eql(u8, contract.name.text, "no_overflow")) next.no_overflow = true;
                if (std.mem.eql(u8, contract.name.text, "noalias")) next.noalias_contract = true;
                if (std.mem.eql(u8, contract.name.text, "precise_asm")) next.precise_asm = true;
            },
            .no_lang_trap, .naked, .@"noinline", .weak, .named, .backend_name, .origin, .section, .@"align" => {},
        }
        return next;
    }

    pub fn has(self: UnsafeContracts, required: ContractKind) bool {
        return switch (required) {
            .no_overflow => self.no_overflow,
            .noalias_contract => self.noalias_contract,
            .precise_asm => self.precise_asm,
        };
    }
};

pub const ContractKind = enum {
    no_overflow,
    noalias_contract,
    precise_asm,
};

pub const LocalInfo = struct {
    class: TypeClass,
    mutable: bool,
    ty: ?ast.TypeExpr,
    origin: BindingOrigin,
    scope_depth: usize = 0,
    address_origin: AddressOrigin = .none,
};

pub const BindingOrigin = enum {
    param,
    local,
};

pub const AddressOrigin = union(enum) {
    none,
    local: struct {
        scope_depth: usize,
    },
};

pub const Scope = std.StringHashMap(LocalInfo);

pub const TypeClass = enum {
    unknown,
    checked_u8,
    checked_u16,
    checked_u32,
    checked_u64,
    checked_u128,
    checked_usize,
    checked_i8,
    checked_i16,
    checked_i32,
    checked_i64,
    checked_i128,
    checked_isize,
    wrap,
    sat,
    serial,
    counter,
    pointer,
    raw_many_pointer,
    slice,
    array,
    c_void_pointer,
    cstr,
    nullable_pointer,
    nullable_c_void_pointer,
    // `?*dyn Trait` - a nullable trait object. Same two-word {data, vtable}
    // layout as `*dyn Trait`; `none` is the niche `data == null`. Eligible for
    // `if let` / switch narrowing and `?` unwrap like the thin nullables, but its
    // niche test and codegen are on the data word, not the whole value.
    nullable_dyn_trait,
    // `?T` for a sized VALUE payload T (e.g. `?u32`, `?usize`, `?SomeStruct`). Unlike
    // the pointer nullables there is no spare sentinel, so it lowers to a TAGGED
    // aggregate `{ present, value }` (see lower_c mc_opt_<T> / lower_llvm `{ i1, T }`).
    // Eligible for `if let` / `== null` / `.?` narrowing like the pointer nullables.
    nullable_value,
    paddr,
    vaddr,
    dma_addr,
    user_ptr,
    mmio_ptr,
    phys_ptr,
    // `Secret<T>` - a constant-time key/crypto-material tag. Carries T's value
    // and arithmetic but FORBIDS secret-dependent control flow and memory
    // access (branch/switch condition, array index, pointer offset, deref) so a
    // secret value can never steer a timing- or cache-observable decision.
    secret,
    atomic,
    dma_buf,
    result,
    fn_pointer,
    closure,
    never,
    void,
    bool,
    null_literal,
    int_literal,
    f32,
    f64,
    float_literal,
    duration,
    order,
};

pub const TypeMode = enum {
    normal,
    storage,
    return_type,
    ffi_opaque_pointer,
};
