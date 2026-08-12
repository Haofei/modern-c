//! C backend passive model types.
//!
//! Data-only records shared by the C emitter and inspection paths. Keeping
//! these out of `lower_c.zig` reduces the main emitter's surface area without
//! moving behavior.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const builtin_syntax = @import("builtin_syntax.zig");
const lower_c_op = @import("lower_c_op.zig");
const mir = @import("mir.zig");

const CheckedHelperParts = lower_c_op.CheckedHelperParts;

pub const LocalInfo = struct {
    source_ty: ?ast_bridge.TypeExpr = null,
    is_mutable: bool = false,
    c_type: ?[]const u8 = null,
    source_type_name: ?[]const u8 = null,
    // Value-range propagation: compile-time-constant value of an immutable (`let`)
    // integer local whose initializer is constant and in range.
    const_int: ?i128 = null,
    array_len: ?[]const u8 = null,
    array_elems_field: ?[]const u8 = null,
    slice_ptr_field: ?[]const u8 = null,
    slice_len_field: ?[]const u8 = null,
    iterable_element_c_type: ?[]const u8 = null,
    nullable_inner_c_type: ?[]const u8 = null,
    result_ty: ?ast_bridge.TypeExpr = null,
    result_ok_c_type: ?[]const u8 = null,
    result_err_c_type: ?[]const u8 = null,
    mmio_pointee: ?[]const u8 = null,
};

pub const ArrayInfo = struct {
    name: []const u8,
    element_ty: ast_bridge.TypeExpr,
    element_c_type: []const u8,
    len: []const u8,
};

// A by-value aggregate typedef emitted in dependency order (see
// `emitOrderedAggregates`).
pub const AggregateEmitUnit = union(enum) {
    struct_decl: ast_bridge.StructDecl,
    array: ArrayInfo,
    result: ResultInfo,
    tagged_union: ast_bridge.UnionDecl,
    opt: OptInfo,
};

pub const RawManyOffsetInfo = struct {
    base: ast_bridge.Expr,
    ty: ast_bridge.TypeExpr,
    element_ty: ast_bridge.TypeExpr,
};

// Which of `break`/`continue` does this loop body use targeting *this* loop
// (i.e. not nested inside an inner loop)? Each needs a labeled target so a
// `break`/`continue` inside a `switch` reaches the loop, not the switch.
pub const LoopJumps = struct {
    brk: bool = false,
    cont: bool = false,
};

pub const FnInfo = struct {
    params: []const ast_bridge.Param,
    return_type: ?ast_bridge.TypeExpr,
    is_extern: bool,
    is_variadic: bool = false,
    // G8: `#[error_from]` conversion `fn(E1) -> E2`, invoked by `?` on the error
    // path when the propagated error type differs from the function's error type.
    error_from: bool = false,

    pub fn acceptsArgCount(self: FnInfo, count: usize) bool {
        return if (self.is_variadic) count >= self.params.len else count == self.params.len;
    }
};

pub const SequencedArgTemp = struct {
    name: []const u8,
    ty: ast_bridge.TypeExpr,
};

pub const ResultTrySequenceMode = enum { local_init, stmt };

// A generated env-widening thunk for a `bind(scalar, f)` closure. `fname` is the
// real target function; the thunk receives the env as `void *`, narrows it back
// to the scalar env type via `uintptr_t`, and forwards the remaining arguments.
pub const BindThunk = struct {
    fname: []const u8,
    info: FnInfo,
};

pub const TryReplacement = struct {
    source: mir.SourcePoint,
    temp_name: []const u8,
};

pub const SequencedBinaryPlan = union(enum) {
    infix: []const u8,
    unsigned_infix: []const u8,
    helper: CheckedHelperParts,
};

pub const MmioReadReplacement = struct {
    source: mir.SourcePoint,
    temp_name: []const u8,
    source_type_name: []const u8,
    c_type: []const u8,
    access: MmioAccess,
};

pub const SliceAccess = struct {
    ptr_field: []const u8,
    len_field: []const u8,
};

pub const SliceInfo = struct {
    name: []const u8,
    ptr_type: []const u8,
    element_ty: ast_bridge.TypeExpr,
    mutability: ast_bridge.Mutability,
};

pub const PackedBitsInfo = struct {
    repr_name: []const u8,
    repr_c_type: []const u8,
    fields: std.StringHashMap(PackedBitsField),
};

pub const PackedBitsField = struct {
    bit_index: usize,
};

pub const OverlayUnionInfo = struct {
    size: usize,
    alignment: usize,
    fields: std.StringHashMap(OverlayFieldInfo),
};

pub const OverlayFieldInfo = struct {
    ty: ast_bridge.TypeExpr,
    layout: OverlayLayout,
    byte_array_len: ?[]const u8,
};

pub const OverlayFieldAccess = struct {
    base: ast_bridge.Expr,
    field: OverlayFieldInfo,
};

pub const OverlayLayout = struct {
    size: usize,
    alignment: usize,
};

pub const ReflectionCallKind = builtin_syntax.ReflectionCallKind;

pub const ResultInfo = struct {
    name: []const u8,
    ok_ty: ast_bridge.TypeExpr,
    err_ty: ast_bridge.TypeExpr,
};

// A value optional `?T`: the tagged aggregate `{ bool present; T value; }`.
pub const OptInfo = struct {
    name: []const u8,
    payload_ty: ast_bridge.TypeExpr,
};

pub const ResultSwitchSubject = struct {
    name: []const u8,
    ok_c_type: []const u8,
    err_c_type: []const u8,
    // The MC payload types (Result<T,E>'s T and E), so an arm binding can be registered with
    // full type info — e.g. a nested `switch e { .Variant => … }` on an enum err payload.
    ok_source_ty: ?ast_bridge.TypeExpr = null,
    err_source_ty: ?ast_bridge.TypeExpr = null,
};

pub const ResultSwitchBranch = struct {
    condition: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    binding_name: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    payload_field: ?[]const u8 = null,
};

pub const NullableSwitchSubject = struct {
    name: []const u8,
    inner_c_type: []const u8,
    // The narrowed inner type (`*dyn Trait`), so the some-binding carries enough type
    // information for trait dispatch (`d.m()` -> `d.vtable->m(d.data, …)`).
    inner_ty: ?ast_bridge.TypeExpr = null,
    // MIR-owned nullable representation. The switch/if-let helper may use
    // syntax spelling to emit fields, but it must not infer whether `?T` is
    // pointer-niche, dyn-trait-niche, or tagged-value from AST shape.
    representation: NullableRepresentation = .pointer,

    // Append the C boolean expression that is true when the subject is `some`
    // (present). This deliberately writes into the caller's artifact buffer
    // instead of formatting through a fixed scratch buffer: identifier length is
    // a lexer/input policy, and codegen must never translate formatting failure
    // into a semantic constant such as `0`.
    pub fn appendSomeCond(self: NullableSwitchSubject, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self.representation) {
            .value => try out.print(allocator, "{s}.present", .{self.name}),
            .dyn_trait => try out.print(allocator, "{s}.data != NULL", .{self.name}),
            .pointer => try out.print(allocator, "{s} != NULL", .{self.name}),
        }
    }

    // Append the C expression that yields the some-payload value.
    pub fn appendValueExpr(self: NullableSwitchSubject, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self.representation) {
            .value => try out.print(allocator, "{s}.value", .{self.name}),
            .dyn_trait, .pointer => try out.appendSlice(allocator, self.name),
        }
    }

    pub fn allocSomeCond(self: NullableSwitchSubject, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try self.appendSomeCond(allocator, &out);
        return out.toOwnedSlice(allocator);
    }
};

pub const NullableRepresentation = enum {
    pointer,
    dyn_trait,
    value,
};

pub const NullableSwitchBranch = struct {
    condition: ?[]const u8 = null,
    binding_name: ?[]const u8 = null,
};

pub const TaggedUnionSwitchSubject = struct {
    name: []const u8,
    type_name: []const u8,
    decl: ast_bridge.UnionDecl,
};

pub const TaggedUnionSwitchBranch = struct {
    condition: ?[]const u8 = null,
    is_wildcard: bool = false,
    binding_name: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    binding_source_ty: ?ast_bridge.TypeExpr = null,
    payload_field: ?[]const u8 = null,
};

pub const StructTypeStyle = enum { typedef_name, struct_tag };

pub const MmioSequenceState = struct {
    ordinary_store_seen: bool = false,
    pending_acquire: ?MmioAccess = null,
    // section 18: a cache.clean (clean-for-device) seen before a DMA-descriptor
    // handoff write composes with the section 17 MMIO .release ordering — the
    // clean may not be moved after the handoff.
    cache_clean_seen: bool = false,
};

pub const MmioStruct = struct {
    fields: std.StringHashMap(MmioField),
};

pub const MmioField = struct {
    value_type: []const u8,
    width: []const u8,
};

pub const MmioAccess = struct {
    kind: []const u8,
    param: []const u8 = "",
    struct_name: []const u8,
    field: []const u8,
    value_type: []const u8,
    width: []const u8,
    ordering: []const u8,
};

pub const AtomicAccess = struct {
    op: []const u8,
    object: []const u8,
    payload_type: []const u8,
    ordering: []const u8,
};

pub const DmaOperation = struct {
    kind: []const u8,
    object: []const u8,
    payload: []const u8,
    mode: []const u8,
};

pub const GlobalInfo = struct {
    type_name: []const u8,
    c_type: []const u8,
    race_type_name: []const u8,
    race_c_type: []const u8,
    width_bits: []const u8,
    pointer_like: bool,
    // An aggregate (struct) global: there is no scalar atomic race helper for it, so
    // load/store lower to a plain C struct copy rather than mc_race_load/store_<T>.
    aggregate: bool = false,
    is_const: bool = false,
    source_ty: ?ast_bridge.TypeExpr = null,
    array_element_info: ?GlobalElementInfo = null,
    array_len: ?[]const u8 = null,
};

pub const GlobalElementInfo = struct {
    source_ty: ast_bridge.TypeExpr,
    c_type: []const u8,
    race_type_name: []const u8,
    race_c_type: []const u8,
    aggregate: bool = false, // struct/union/closure element -> plain `.elems[i]` access
    pointer_like: bool = false, // pointer / fn-pointer element -> relaxed-atomic access
};

pub const GlobalAccess = struct {
    name: []const u8,
    info: GlobalInfo,
    owned_name: bool = false,
};

pub const GlobalArrayElementAccess = struct {
    base_name: []const u8,
    index: ast_bridge.Expr,
    len: []const u8,
    element_info: GlobalElementInfo,
};

pub const ConstGetCallInfo = struct {
    base: *ast_bridge.Expr,
    index: usize,
};
