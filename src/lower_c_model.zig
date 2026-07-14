//! C backend passive model types.
//!
//! Data-only records shared by the C emitter and inspection paths. Keeping
//! these out of `lower_c.zig` reduces the main emitter's surface area without
//! moving behavior.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_op = @import("lower_c_op.zig");

const CheckedHelperParts = lower_c_op.CheckedHelperParts;

pub const LocalInfo = struct {
    source_ty: ?ast.TypeExpr = null,
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
    result_ty: ?ast.TypeExpr = null,
    result_ok_c_type: ?[]const u8 = null,
    result_err_c_type: ?[]const u8 = null,
    mmio_pointee: ?[]const u8 = null,
};

pub const ArrayInfo = struct {
    name: []const u8,
    element_ty: ast.TypeExpr,
    element_c_type: []const u8,
    len: []const u8,
};

// A by-value aggregate typedef emitted in dependency order (see
// `emitOrderedAggregates`).
pub const AggregateEmitUnit = union(enum) {
    struct_decl: ast.StructDecl,
    array: ArrayInfo,
    result: ResultInfo,
    tagged_union: ast.UnionDecl,
    opt: OptInfo,
};

pub const RawManyOffsetInfo = struct {
    base: ast.Expr,
    ty: ast.TypeExpr,
    element_ty: ast.TypeExpr,
};

// Which of `break`/`continue` does this loop body use targeting *this* loop
// (i.e. not nested inside an inner loop)? Each needs a labeled target so a
// `break`/`continue` inside a `switch` reaches the loop, not the switch.
pub const LoopJumps = struct {
    brk: bool = false,
    cont: bool = false,
};

pub const FnInfo = struct {
    params: []const ast.Param,
    return_type: ?ast.TypeExpr,
    is_extern: bool,
    // G8: `#[error_from]` conversion `fn(E1) -> E2`, invoked by `?` on the error
    // path when the propagated error type differs from the function's error type.
    error_from: bool = false,
};

pub const SequencedArgTemp = struct {
    name: []const u8,
    ty: ast.TypeExpr,
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
    span: ast.Span,
    temp_name: []const u8,
};

pub const SequencedBinaryPlan = union(enum) {
    infix: []const u8,
    unsigned_infix: []const u8,
    helper: CheckedHelperParts,
};

pub const MmioReadReplacement = struct {
    span: ast.Span,
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
    ty: ast.TypeExpr,
    layout: OverlayLayout,
    byte_array_len: ?[]const u8,
};

pub const OverlayFieldAccess = struct {
    base: ast.Expr,
    field: OverlayFieldInfo,
};

pub const OverlayLayout = struct {
    size: usize,
    alignment: usize,
};

pub const ReflectionCallKind = enum {
    size,
    alignment,
    field_offset,
    bit_offset,
    repr,
};

pub const ResultInfo = struct {
    name: []const u8,
    ok_ty: ast.TypeExpr,
    err_ty: ast.TypeExpr,
};

// A value optional `?T`: the tagged aggregate `{ bool present; T value; }`.
pub const OptInfo = struct {
    name: []const u8,
    payload_ty: ast.TypeExpr,
};

pub const ResultSwitchSubject = struct {
    name: []const u8,
    ok_c_type: []const u8,
    err_c_type: []const u8,
    // The MC payload types (Result<T,E>'s T and E), so an arm binding can be registered with
    // full type info — e.g. a nested `switch e { .Variant => … }` on an enum err payload.
    ok_source_ty: ?ast.TypeExpr = null,
    err_source_ty: ?ast.TypeExpr = null,
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
    // A `?*dyn Trait` is a two-word fat pointer; its niche is `data == NULL`, so the
    // none/some test is on the `.data` field, not the whole value.
    is_dyn: bool = false,
    // The narrowed inner type (`*dyn Trait`), so the some-binding carries enough type
    // information for trait dispatch (`d.m()` -> `d.vtable->m(d.data, …)`).
    inner_ty: ?ast.TypeExpr = null,
    // A value optional `?T` (tagged repr `{ present, value }`): the some-test reads the
    // `.present` tag and the some-binding reads the `.value` payload (not the whole word).
    is_value_opt: bool = false,

    // The C boolean expression that is true when the subject is `some` (present).
    pub fn someCond(self: NullableSwitchSubject, buf: []u8) []const u8 {
        if (self.is_value_opt)
            return std.fmt.bufPrint(buf, "{s}.present", .{self.name}) catch "0";
        return if (self.is_dyn)
            std.fmt.bufPrint(buf, "{s}.data != NULL", .{self.name}) catch "0"
        else
            std.fmt.bufPrint(buf, "{s} != NULL", .{self.name}) catch "0";
    }

    // The C expression that yields the some-payload value.
    pub fn valueExpr(self: NullableSwitchSubject, buf: []u8) []const u8 {
        if (self.is_value_opt)
            return std.fmt.bufPrint(buf, "{s}.value", .{self.name}) catch self.name;
        return self.name;
    }
};

pub const NullableSwitchBranch = struct {
    condition: ?[]const u8 = null,
    binding_name: ?[]const u8 = null,
};

pub const TaggedUnionSwitchSubject = struct {
    name: []const u8,
    type_name: []const u8,
    decl: ast.UnionDecl,
};

pub const TaggedUnionSwitchBranch = struct {
    condition: ?[]const u8 = null,
    is_wildcard: bool = false,
    binding_name: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    binding_source_ty: ?ast.TypeExpr = null,
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
    source_ty: ?ast.TypeExpr = null,
    array_element_info: ?GlobalElementInfo = null,
    array_len: ?[]const u8 = null,
};

pub const GlobalElementInfo = struct {
    source_ty: ast.TypeExpr,
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
    index: ast.Expr,
    len: []const u8,
    element_info: GlobalElementInfo,
};

pub const ConstGetCallInfo = struct {
    base: *ast.Expr,
    index: usize,
};
