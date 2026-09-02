const ast_bridge = @import("ast_bridge.zig");
const codegen_signature = @import("codegen_signature.zig");
const mir_model = @import("mir_model.zig");
const type_layout = @import("layout.zig");

pub const LocalSlot = struct {
    ty: ast_bridge.TypeExpr,
    ptr: []const u8,
    kind: LocalSlotKind = .normal,
    is_mutable: bool = false,
};

pub const LocalSlotKind = enum {
    normal,
    va_list_local,
    va_list_param,
};

pub const FnSig = struct {
    ret: ast_bridge.TypeExpr,
    params: []const codegen_signature.FunctionParamFact,
    c_abi: bool = false,
    is_variadic: bool = false,
    debug_id: ?usize = null,
    // G8: `#[error_from]` conversion `fn(E1) -> E2`, invoked by `?` on the error
    // path when the propagated error type differs from the function's error type.
    error_from: bool = false,
};

// A generated env-widening thunk for a scalar-env `bind`. `fname` is the real
// target; the thunk takes the env as `ptr`, narrows it back to the scalar env
// type via `ptrtoint`, and forwards the remaining arguments.
pub const BindThunk = struct {
    fname: []const u8,
    sig: FnSig,
};

pub const PackedBitsInfo = struct {
    repr: ast_bridge.TypeExpr,
    fields: []const ast_bridge.Field,
};

pub const OverlayUnionInfo = struct {
    fields: []const ast_bridge.Field,
    size: u64,
    alignment: u64,
};

pub const OverlayLayout = struct {
    size: u64,
    alignment: u64,
};

pub const TaggedUnionLayout = type_layout.ComptimeTaggedUnionLayout;

pub const MmioFieldInfo = struct {
    storage_ty: ast_bridge.TypeExpr,
    value_ty: ast_bridge.TypeExpr,
};

pub const MmioAccessInfo = struct {
    op: []const u8,
    base: ast_bridge.Expr,
    struct_ty: ast_bridge.TypeExpr,
    storage_ty: ast_bridge.TypeExpr,
    value_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
    offset: u64,
};

pub const MmioMapInfo = struct {
    source_ty: ast_bridge.TypeExpr,
    payload_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const RawCallInfo = struct {
    kind: mir_model.CallTargetKind,
    address_ty: ast_bridge.TypeExpr,
    payload_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const ByteViewCallInfo = struct {
    kind: mir_model.CallTargetKind,
    source_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const ReflectionCallInfo = struct {
    kind: mir_model.CallTargetKind,
    target_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const VaCallInfo = struct {
    kind: mir_model.CallTargetKind,
    cursor_ty: ?ast_bridge.TypeExpr = null,
    payload_ty: ?ast_bridge.TypeExpr = null,
    result_ty: ast_bridge.TypeExpr,
};

pub const MmioFencePlacement = enum {
    before_store,
    after_load,
};

pub const DmaBufCallInfo = struct {
    base: ast_bridge.Expr,
    op: []const u8,
    dma_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const DmaCacheCallInfo = struct {
    op: []const u8,
    dma_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const ArgValue = struct {
    ty: ast_bridge.TypeExpr,
    value: []const u8,
};

pub const StringLiteralGlobal = struct {
    name: []const u8,
    escaped_bytes: []const u8,
    len: usize,
};

pub const DebugFunction = struct {
    id: usize,
    name: []const u8,
    source_path: []const u8,
    line: usize,
    column: usize,
};

pub const DebugLocation = struct {
    id: usize,
    scope: usize,
    line: usize,
    column: usize,
};

pub const DebugLocalKind = enum {
    parameter,
    variable,
};

pub const DebugLocal = struct {
    id: usize,
    name: []const u8,
    scope: usize,
    line: usize,
    ty: ast_bridge.TypeExpr,
    kind: DebugLocalKind,
    arg_index: ?usize = null,
};

pub const LoopLabels = struct {
    break_label: []const u8,
    continue_label: []const u8,
    // G7: source loop label naming this loop (`outer:`), or null when unlabeled.
    // A labeled `break :outer` / `continue :outer` resolves against this.
    label: ?[]const u8 = null,
};

pub const RawManyOffsetInfo = struct {
    base: ast_bridge.Expr,
    base_ty: ast_bridge.TypeExpr,
    element_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

pub const EnumRawCallInfo = struct {
    base: ast_bridge.Expr,
    enum_ty: ast_bridge.TypeExpr,
    repr_ty: ast_bridge.TypeExpr,
};

pub const DomainResidueCallInfo = struct {
    base: ast_bridge.Expr,
    domain_ty: ast_bridge.TypeExpr,
    payload_ty: ast_bridge.TypeExpr,
};

pub const DomainOpCallInfo = struct {
    domain_ty: ast_bridge.TypeExpr,
    payload_ty: ast_bridge.TypeExpr,
    return_ty: ast_bridge.TypeExpr,
    interval_ty: ?ast_bridge.TypeExpr,
    op: []const u8,
};

pub const ConversionCallInfo = struct {
    source_ty: ast_bridge.TypeExpr,
    target_ty: ast_bridge.TypeExpr,
    op: []const u8,
};

pub const ReduceCallInfo = struct {
    source_ty: ast_bridge.TypeExpr,
    element_ty: ast_bridge.TypeExpr,
    return_ty: ast_bridge.TypeExpr,
    op: []const u8,
};

pub const ConstGetCallInfo = struct {
    base: ast_bridge.Expr,
    array_ty: ast_bridge.TypeExpr,
    element_ty: ast_bridge.TypeExpr,
    index: u64,
};

pub const IntRange = struct {
    min: i128,
    max: i128,
};

pub const AtomicCallInfo = struct {
    base: ast_bridge.Expr,
    op: []const u8,
    payload_ty: ast_bridge.TypeExpr,
    // True when the base is a `*atomic<T>` (the atomic accessed by pointer): the pointer value
    // is the atomic's address, rather than the base needing `&place`.
    base_is_pointer: bool = false,
};

pub const MaybeUninitCallInfo = struct {
    base: ast_bridge.Expr,
    op: []const u8,
    payload_ty: ast_bridge.TypeExpr,
};

pub const ResultTypeInfo = struct {
    ok_ty: ast_bridge.TypeExpr,
    err_ty: ast_bridge.TypeExpr,
};
