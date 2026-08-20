const std = @import("std");

const ast = @import("ast.zig");

fn TypedIndex(comptime name: []const u8) type {
    _ = name;
    return struct {
        raw: u32,

        pub const invalid: @This() = .{ .raw = std.math.maxInt(u32) };

        pub fn fromIndex(index_value: usize) @This() {
            std.debug.assert(index_value < std.math.maxInt(u32));
            return .{ .raw = @intCast(index_value) };
        }

        pub fn index(self: @This()) usize {
            std.debug.assert(self.raw != invalid.raw);
            return self.raw;
        }

        pub fn isValid(self: @This()) bool {
            return self.raw != invalid.raw;
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return self.raw == other.raw;
        }
    };
}

pub const SourceId = TypedIndex("SourceId");
pub const NodeId = TypedIndex("NodeId");
pub const SymbolId = TypedIndex("SymbolId");
pub const TypeId = TypedIndex("TypeId");
pub const ValueId = TypedIndex("ValueId");
pub const BlockId = TypedIndex("BlockId");
pub const SpanId = TypedIndex("SpanId");

pub const TrapKind = enum {
    IntegerOverflow,
    DivideByZero,
    InvalidShift,
    Bounds,
    Assert,
    Unreachable,
    ExplicitTrap,
    Unwrap,
    CallMayTrap,
    InvalidRepresentation,
    Unknown,
};

pub const TrapSource = enum {
    checked_arithmetic,
    checked_shift,
    bounds_check,
    assert_stmt,
    unreachable_expr,
    explicit_trap,
    unwrap,
    call,
    representation_check,
};

pub const AddressClass = enum {
    paddr,
    vaddr,
    dma_addr,
    user_ptr,
    mmio_ptr,
    phys_ptr,
};

pub const PointerKind = enum {
    single,
    raw_many,
    slice,
};

pub const PointerShape = struct {
    kind: PointerKind,
    mutability: ast.Mutability,
    child: []const u8,
};

pub const ResultShape = struct {
    ok: []const u8,
    err: []const u8,
};

pub const ValueType = union(enum) {
    void,
    never,
    bool,
    value,
    integer: []const u8,
    float: []const u8,
    cstr,
    pointer: PointerShape,
    nullable_pointer: PointerShape,
    // `?*dyn Trait` - nullable trait object; niche is `data == null`. Narrows to a
    // bare `*dyn Trait` (`.value`) under `if let` / switch / unwrap.
    nullable_dyn_trait,
    // `?T` for a sized VALUE payload T (tagged repr `{ present, value }`). The string
    // is the payload type's text (e.g. "u32", "Point"), used to name the backend's
    // `mc_opt_<T>` aggregate. Narrows to the bare payload under `if let` / `?`.
    nullable_value: []const u8,
    slice: []const u8,
    array: []const u8,
    address: AddressClass,
    closed_enum: []const u8,
    open_enum: []const u8,
    struct_: []const u8,
    result: ResultShape,
    contract,
    branch,
    trap,
    unknown,

    pub fn name(self: ValueType) []const u8 {
        return switch (self) {
            .void => "void",
            .never => "never",
            .bool => "bool",
            .value => "value",
            .integer => |n| n,
            .float => |n| n,
            .cstr => "cstr",
            .pointer => |shape| pointerShapeName(shape),
            .nullable_pointer => |shape| pointerShapeName(shape),
            .nullable_dyn_trait => "?dyn",
            .nullable_value => |n| n,
            .slice => |n| n,
            .array => |n| n,
            .address => |kind| addressClassName(kind),
            .closed_enum => |n| n,
            .open_enum => |n| n,
            .struct_ => |n| n,
            .result => "Result",
            .contract => "contract",
            .branch => "branch",
            .trap => "language_trap",
            .unknown => "unknown",
        };
    }
};

pub const Instruction = struct {
    kind: Kind,
    result_ty: ValueType,
    typed_result_ty: TypeId = .invalid,
    detail: []const u8,
    // Target-type instructions retain the complete semantic type separately
    // from their runtime representation.
    target_ty: ?ast.TypeExpr = null,
    aggregate_construction: ?AggregateConstructionKind = null,
    const_index: ?usize = null,
    target_index: ?usize = null,
    target_owner: ?[]const u8 = null,
    typed_target_owner_id: ?SymbolId = null,
    value_id: ?[]const u8 = null,
    contract_region_id: ?usize = null,
    typed_value_id: ?ValueId = null,
    typed_span_id: SpanId = .invalid,
    line: usize,
    column: usize,
    source_offset: usize = 0,
    source_len: usize = 0,

    pub const Kind = enum {
        param,
        local,
        assign,
        expr,
        unary,
        binary,
        add_overflow,
        cmp_bounds,
        index,
        typed_load,
        call,
        indirect_call,
        call_target,
        target_type,
        contract_begin,
        contract_end,
        unchecked_assume,
        address_deref,
        address_conversion,
        address_operation,
        ffi_check,
        usage_check,
        mmio_check,
        representation_check,
        representation_use,
        integer_literal_conversion,
        nullability_conversion,
        conversion_check,
        aggregate_check,
        result_check,
        switch_check,
        assignment_check,
        arithmetic_domain_check,
        operator_check,
        unsafe_check,
        assert_condition,
        asm_effect,
        defer_cleanup,
        return_value,
    };
};

pub const Terminator = union(enum) {
    fallthrough,
    jump: usize,
    branch: struct { true_block: usize, false_block: usize },
    return_: ValueType,
    trap_: TrapKind,
    unreachable_,
    switch_,

    pub fn name(self: Terminator) []const u8 {
        return switch (self) {
            .fallthrough => "fallthrough",
            .jump => "jump",
            .branch => "branch",
            .return_ => "return",
            .trap_ => "trap",
            .unreachable_ => "unreachable",
            .switch_ => "switch",
        };
    }
};

pub const TrapEdge = struct {
    from_block: usize,
    trap_block: usize,
    kind: TrapKind,
    source: TrapSource,
    line: usize,
    column: usize,
    source_offset: usize = 0,
    source_len: usize = 0,
};

pub const ContractRegion = struct {
    id: usize,
    kind: []const u8,
    begin_line: usize,
    end_line: usize,
};

pub const RangeFact = struct {
    region_id: usize,
    target: []const u8,
    op: []const u8,
    left: []const u8,
    right: []const u8,
    result_ty: ValueType,
    line: usize,
    column: usize,
};

pub const BoundsFactKind = enum { index, slice };

pub const BoundsFact = struct {
    kind: BoundsFactKind,
    source: SourcePoint,
};

pub const IntegerFact = struct {
    literal: []const u8,
    target_ty: ValueType,
    source: SourcePoint,
};

pub const BoolFact = struct {
    value: bool,
    source: SourcePoint,
};

pub const FloatFact = struct {
    literal: []const u8,
    target_ty: ValueType,
    source: SourcePoint,
};

pub const ConstGetFact = struct {
    index: usize,
    source: SourcePoint,
};

pub const CallTargetKind = enum {
    bind,
    result_ok,
    result_err,
    reduce_sum_checked,
    reduce_sum_left,
    reduce_sum_fast,
    enum_raw,
    wrap_residue,
    serial_before,
    serial_after,
    serial_distance,
    serial_compare,
    counter_delta_mod,
    counter_elapsed_assume_within,
    counter_elapsed_bounded,
    const_get,
    dma_cache_clean,
    dma_cache_invalidate,
    dma_addr,
    dma_as_slice,
    raw_many_offset,
    mmio_map,
    mmio_read,
    mmio_write,
    atomic_init,
    atomic_load,
    atomic_store,
    atomic_fetch_add,
    atomic_fetch_sub,
    maybe_uninit_write,
    maybe_uninit_assume_init,
    bitcast,
    phys,
    raw_load,
    raw_ptr,
    raw_store,
    va_start,
    va_arg,
    va_end,
    trap_bounds,
    trap_null_unwrap,
    trap_integer_overflow,
    trap_divide_by_zero,
    trap_invalid_shift,
    trap_invalid_representation,
    trap_assert,
    trap_unreachable,
    cpu_pause,
    fence_full,
    fence_release,
    fence_acquire,
    reflection_size,
    reflection_alignment,
    reflection_field_offset,
    reflection_bit_offset,
    reflection_repr,
    byte_view_as_bytes,
    byte_view_equal,
    wrapping_add,
    unchecked_add,
    unchecked_sub,
    unchecked_mul,
    drop,
    forget_unchecked,
    declassify,
    assume_noalias,
    conversion_from,
    conversion_try_from,
    conversion_trap_from,
    conversion_wrap_from,
    conversion_sat_from,
    conversion_from_mod,
};

pub const CallTargetFact = struct {
    kind: CallTargetKind,
    result_ty: ValueType,
    typed_span_id: SpanId = .invalid,
    source: SourcePoint,
};

pub const BindThunkFact = struct {
    target_fn: []const u8,
    source: SourcePoint,
};

pub const BodyTypeArtifactFact = struct {
    ty: ast.TypeExpr,
    source: SourcePoint,
};

pub const DeferCleanupExprFact = struct {
    expr: ast.Expr,
    source: SourcePoint,
};

pub const DropGlueFact = struct {
    resource_type: []const u8,
    typed_resource_symbol_id: SymbolId = .invalid,
    release_fn: []const u8,
    typed_release_symbol_id: SymbolId = .invalid,
    source: SourcePoint,
};

pub const TypeOwnershipKind = enum {
    copy,
    affine,
    linear,
    region,
    view,
};

pub const TypeOwnershipFact = struct {
    type_name: []const u8,
    typed_type_symbol_id: SymbolId = .invalid,
    kind: TypeOwnershipKind,
    drop_glue_symbol_id: SymbolId = .invalid,
    thread_move: bool = false,
    source: SourcePoint,
};

pub const TargetTypeKind = enum {
    assert_condition,
    direct_call_result,
    direct_call_argument,
    dyn_dispatch_result,
    dyn_dispatch_argument,
    bind,
    result_ok,
    result_err,
    tagged_union,
    enum_literal,
    string_literal,
    array_literal,
    struct_literal,
    float_literal,
    char_literal,
    null_literal,
    value_optional_coercion,
    dyn_coercion,
    dyn_coercion_source,
    paddr_coercion_source,
    conversion_source,
    conversion_target,
    wrapping_left,
    wrapping_right,
    wrapping_result,
    unchecked_left,
    unchecked_right,
    unchecked_result,
    reduce_source,
    reduce_element,
    enum_raw_source,
    enum_raw_result,
    domain_type,
    domain_payload,
    domain_result,
    domain_interval,
    const_get_base,
    const_get_result,
    dma_buffer,
    dma_payload,
    dma_result,
    raw_many_offset_base,
    raw_many_offset_element,
    raw_many_offset_result,
    mmio_map_source,
    mmio_map_payload,
    mmio_map_result,
    mmio_struct,
    mmio_storage,
    mmio_value,
    mmio_result,
    bitcast_source,
    bitcast_target,
    phys_result,
    declassify_source,
    declassify_result,
    assume_noalias_source,
    assume_noalias_result,
    atomic_init_payload,
    atomic_init_result,
    atomic_payload,
    maybe_uninit_payload,
    explicit_cast_source,
    explicit_cast_target,
    view_const_narrow_source,
    view_const_narrow_target,
    raw_address,
    raw_payload,
    raw_result,
    va_cursor,
    va_payload,
    va_result,
    qualified_union_result,
    enum_variant_path_result,
    reflection_target,
    reflection_result,
    byte_view_source,
    byte_view_result,
    discard_argument,
    indirect_call_callee,
    loop_condition,
    switch_subject,
    if_let_subject,
    try_operand,
    for_iterable,
    for_element,
    inferred_local,
    expression_result,
};

/// MIR-owned lowering class for a source struct literal.  The target type says
/// which value is being built; this fact says which representation-sensitive
/// constructor family is semantically required.  Backends may consult their
/// declaration/layout tables to validate the class and emit fields, but not to
/// select a different family when this fact is absent.
pub const AggregateConstructionKind = enum {
    declared_struct,
    c_union,
    packed_bits,
};

pub const TargetTypeFact = struct {
    kind: TargetTypeKind,
    target_ty: ast.TypeExpr,
    result_ty: ValueType,
    typed_result_ty: TypeId = .invalid,
    typed_span_id: SpanId = .invalid,
    aggregate_construction: ?AggregateConstructionKind = null,
    target_index: ?usize = null,
    target_owner: ?[]const u8 = null,
    typed_target_owner_id: SymbolId = .invalid,
    source: SourcePoint,
};

pub const SourcePoint = struct {
    line: usize,
    column: usize,
    offset: usize = 0,
    len: usize = 0,
};

pub const max_ownership_place_projections = 16;

pub const OwnershipEventKind = enum {
    storage_live,
    init,
    reinit,
    move_out,
    forget,
    explicit_drop,
    auto_drop,
    storage_dead,
    borrow_begin,
    borrow_end,
    set_drop_flag,
};

pub const OwnershipLoanKind = enum {
    shared,
    mutable,
};

pub const OwnershipPlaceProjection = union(enum) {
    field: SymbolId,
    constant_index: usize,
    deref,
    wildcard_index,
};

pub const OwnershipPlace = struct {
    root_value_id: ValueId = .invalid,
    root_symbol_id: SymbolId = .invalid,
    root_type_symbol_id: SymbolId = .invalid,
    projections: [max_ownership_place_projections]OwnershipPlaceProjection = undefined,
    projection_count: usize = 0,

    pub fn hasValidRoot(self: OwnershipPlace) bool {
        return self.root_value_id.isValid() or self.root_symbol_id.isValid();
    }
};

pub const OwnershipEvent = struct {
    kind: OwnershipEventKind,
    place: OwnershipPlace,
    generation: u32 = 0,
    loan_id: u32 = std.math.maxInt(u32),
    loan_kind: ?OwnershipLoanKind = null,
    drop_glue_symbol_id: SymbolId = .invalid,
    block_id: BlockId = .invalid,
    instruction_index: ?u32 = null,
    source: SourcePoint,
};

pub const CleanupActionKind = enum {
    auto_drop,
    explicit_drop,
};

pub const CleanupActionPlanEntry = struct {
    kind: CleanupActionKind,
    primary_event_index: usize,
    storage_dead_event_index: usize = std.math.maxInt(usize),
    place: OwnershipPlace,
    generation: u32 = 0,
    drop_glue_symbol_id: SymbolId,
    block_id: BlockId,
    source: SourcePoint,
};

pub const CleanupCancellationKind = enum {
    move_out,
    explicit_drop,
};

pub const CleanupCancellationPlanEntry = struct {
    kind: CleanupCancellationKind,
    event_index: usize,
    place: OwnershipPlace,
    generation: u32 = 0,
    drop_glue_symbol_id: SymbolId,
    block_id: BlockId,
    source: SourcePoint,
};

pub const OwnershipCleanupPlan = struct {
    actions: []CleanupActionPlanEntry = &.{},
    cancellations: []CleanupCancellationPlanEntry = &.{},

    pub fn deinit(self: OwnershipCleanupPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.actions);
        allocator.free(self.cancellations);
    }
};

pub const OwnershipCleanupEdgeKind = enum {
    scope_exit,
    return_exit,
    break_exit,
    continue_exit,
    error_exit,
};

pub const OwnershipCleanupEdgeActionRef = struct {
    cleanup_action_index: usize,
    kind: CleanupActionKind,
    primary_event_index: usize,
    storage_dead_event_index: usize = std.math.maxInt(usize),
    root_value_id: ValueId,
    resource_type_symbol_id: SymbolId,
    drop_glue_symbol_id: SymbolId,
    generation: u32 = 0,
    block_id: BlockId,
    source: SourcePoint,
};

pub const OwnershipCleanupEdge = struct {
    kind: OwnershipCleanupEdgeKind,
    source_block: BlockId = .invalid,
    target_block: ?BlockId = null,
    source: SourcePoint = .{ .line = 0, .column = 0 },
    actions: []OwnershipCleanupEdgeActionRef = &.{},
};

pub const OwnershipCleanupEdgeTable = struct {
    edges: []OwnershipCleanupEdge = &.{},

    pub fn deinit(self: *OwnershipCleanupEdgeTable, allocator: std.mem.Allocator) void {
        for (self.edges) |edge| allocator.free(edge.actions);
        allocator.free(self.edges);
        self.edges = &.{};
    }
};

pub const DeferCleanupEdgeKind = enum {
    scope_exit,
    return_exit,
    break_exit,
    continue_exit,
    error_exit,
};

pub const DeferCleanupEdgeActionRef = struct {
    block_id: BlockId,
    instruction_index: usize,
    source: SourcePoint,
};

pub const DeferCleanupEdge = struct {
    kind: DeferCleanupEdgeKind,
    source_block: BlockId = .invalid,
    target_block: ?BlockId = null,
    source: SourcePoint = .{ .line = 0, .column = 0 },
    actions: []DeferCleanupEdgeActionRef = &.{},
};

pub const DeferCleanupEdgeTable = struct {
    edges: []DeferCleanupEdge = &.{},

    pub fn deinit(self: *DeferCleanupEdgeTable, allocator: std.mem.Allocator) void {
        for (self.edges) |edge| allocator.free(edge.actions);
        allocator.free(self.edges);
        self.edges = &.{};
    }
};

pub const CleanupCfgEdgeKind = enum {
    scope_exit,
    return_exit,
    break_exit,
    continue_exit,
    error_exit,
};

pub const CleanupCfgActionRef = union(enum) {
    ownership: OwnershipCleanupEdgeActionRef,
    defer_cleanup: DeferCleanupEdgeActionRef,
};

pub const CleanupCfgEdge = struct {
    kind: CleanupCfgEdgeKind,
    source_block: BlockId = .invalid,
    target_block: ?BlockId = null,
    source: SourcePoint = .{ .line = 0, .column = 0 },
    actions: []CleanupCfgActionRef = &.{},
};

pub const CleanupCfg = struct {
    edges: []CleanupCfgEdge = &.{},

    pub fn deinit(self: *CleanupCfg, allocator: std.mem.Allocator) void {
        for (self.edges) |edge| allocator.free(edge.actions);
        allocator.free(self.edges);
        self.edges = &.{};
    }
};

pub const PointerProvenance = enum {
    global_storage,
    local_storage,
    unknown,
};

pub const PointerProvenanceInvalidationReason = enum {
    none,
    reassignment,
    dynamic_index_write,
    call,
    indirect_call,
    address_escape,
};

pub const PointerProvenanceInvalidationPolicy = enum {
    invalidate_on_mutation_escape_or_call,
};

pub const PointerProvenanceFact = struct {
    subject: []const u8,
    field_path: ?[]const u8,
    element_index: ?usize,
    storage: ?[]const u8,
    provenance: PointerProvenance,
    pointer_shape: PointerShape,
    invalidation_reason: PointerProvenanceInvalidationReason,
    invalidation_policy: PointerProvenanceInvalidationPolicy,
    source: SourcePoint,
};

// A summary marker says that MIR owns the aggregate-return provenance domain for
// this callee. Consumers must treat an absent field fact under that marker as
// unknown rather than reconstructing provenance from the AST.
pub const AggregateReturnSummaryFact = struct {
    callee: []const u8,
    source: SourcePoint,
};

pub const AggregateReturnPointerFact = struct {
    callee: []const u8,
    field_path: []const u8,
    provenance: PointerProvenance,
    pointer_shape: PointerShape,
    source: SourcePoint,
};

pub const RepresentationFact = struct {
    kind: Instruction.Kind,
    detail: []const u8,
    result_ty: ValueType,
    typed_result_ty: TypeId = .invalid,
    value_id: []const u8,
    typed_value_id: ValueId = .invalid,
    typed_span_id: SpanId = .invalid,
    source: SourcePoint,
};

pub const TypeIdentity = struct {
    id: TypeId,
    spelling: []const u8,
};

pub const SymbolIdentity = struct {
    id: SymbolId,
    spelling: []const u8,
};

pub const SourceIdentity = struct {
    id: SourceId,
    file_id: u32,
};

pub const SpanIdentity = struct {
    id: SpanId,
    source: SourcePoint,
};

pub const ValueIdentity = struct {
    id: ValueId,
    spelling: []const u8,
};

pub const Block = struct {
    id: usize,
    typed_id: BlockId = .invalid,
    kind: []const u8,
    instructions: []Instruction,
    successors: []usize,
    typed_successors: []BlockId = &.{},
    terminator: Terminator,
};

pub const FfiParamContract = struct {
    pub const Kind = enum { pointer, raw_many_pointer, slice, address };
    pub const Nullability = enum { nonnull, nullable, when_nonempty, not_applicable };
    pub const Access = enum { read, read_write, not_applicable };
    pub const Extent = enum { extern_contract, slice_length, not_applicable };

    index: usize,
    name: []const u8,
    kind: Kind,
    nullability: Nullability,
    access: Access,
    extent: Extent,
    address_class: ?AddressClass = null,
};

pub const Function = struct {
    name: []const u8,
    typed_symbol_id: SymbolId = .invalid,
    typed_source_id: SourceId = .invalid,
    return_ty: ValueType,
    // Signature obligations are produced once as typed MIR facts. Consumers
    // must not reconstruct them by rescanning source declarations.
    param_count: usize = 0,
    is_extern: bool = false,
    c_abi: bool = false,
    ffi_param_contracts: []FfiParamContract = &.{},
    no_lang_trap: bool,
    irq_context: bool,
    blocks: []Block,
    trap_edges: []TrapEdge,
    contract_regions: []ContractRegion,
    range_facts: []RangeFact,
    bounds_facts: []BoundsFact = &.{},
    integer_facts: []IntegerFact = &.{},
    bool_facts: []BoolFact = &.{},
    float_facts: []FloatFact = &.{},
    const_get_facts: []ConstGetFact = &.{},
    call_target_facts: []CallTargetFact = &.{},
    bind_thunk_facts: []BindThunkFact = &.{},
    body_type_artifact_facts: []BodyTypeArtifactFact = &.{},
    defer_cleanup_expr_facts: []DeferCleanupExprFact = &.{},
    target_type_facts: []TargetTypeFact = &.{},
    span_identities: []SpanIdentity = &.{},
    type_identities: []TypeIdentity = &.{},
    value_identities: []ValueIdentity = &.{},
    target_owner_identities: []SymbolIdentity = &.{},
    ownership_events: []OwnershipEvent = &.{},
    ownership_cleanup_plan: OwnershipCleanupPlan = .{},
    cleanup_cfg: CleanupCfg = .{},
    generated_type_expr_nodes: []*ast.TypeExpr = &.{},
    generated_type_expr_args: [][]ast.TypeExpr = &.{},
    pointer_provenance_facts: []PointerProvenanceFact,
    representation_facts: []RepresentationFact,
    // OPT (annex E): operand source points of checks the optimizer proved dead and elided
    // (`--optimize`) - a constant in-range array index's `Bounds` check, or an unsigned
    // division by a non-zero literal's `DivideByZero` check. Source points are unique per
    // location, so each backend site matches only its own kind. The backends key off these to
    // skip the emitted runtime check. Empty unless optimization is on, so the MIR is unchanged.
    elided_bounds: []SourcePoint,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    symbol_identities: []SymbolIdentity = &.{},
    source_identities: []SourceIdentity = &.{},
    functions: []Function,
    drop_glue_facts: []DropGlueFact = &.{},
    type_ownership_facts: []TypeOwnershipFact = &.{},
    aggregate_return_summaries: []AggregateReturnSummaryFact = &.{},
    aggregate_return_pointer_facts: []AggregateReturnPointerFact = &.{},

    pub fn deinit(self: *Module) void {
        for (self.functions) |function| {
            for (function.blocks) |block| {
                self.allocator.free(block.instructions);
                self.allocator.free(block.successors);
                if (block.typed_successors.len != 0) self.allocator.free(block.typed_successors);
            }
            self.allocator.free(function.blocks);
            self.allocator.free(function.trap_edges);
            self.allocator.free(function.contract_regions);
            self.allocator.free(function.range_facts);
            if (function.bounds_facts.len != 0) self.allocator.free(function.bounds_facts);
            if (function.integer_facts.len != 0) self.allocator.free(function.integer_facts);
            if (function.bool_facts.len != 0) self.allocator.free(function.bool_facts);
            if (function.float_facts.len != 0) self.allocator.free(function.float_facts);
            if (function.const_get_facts.len != 0) self.allocator.free(function.const_get_facts);
            if (function.call_target_facts.len != 0) self.allocator.free(function.call_target_facts);
            if (function.bind_thunk_facts.len != 0) self.allocator.free(function.bind_thunk_facts);
            if (function.body_type_artifact_facts.len != 0) self.allocator.free(function.body_type_artifact_facts);
            if (function.defer_cleanup_expr_facts.len != 0) self.allocator.free(function.defer_cleanup_expr_facts);
            if (function.target_type_facts.len != 0) self.allocator.free(function.target_type_facts);
            if (function.span_identities.len != 0) self.allocator.free(function.span_identities);
            if (function.type_identities.len != 0) self.allocator.free(function.type_identities);
            if (function.value_identities.len != 0) self.allocator.free(function.value_identities);
            if (function.target_owner_identities.len != 0) self.allocator.free(function.target_owner_identities);
            if (function.ownership_events.len != 0) self.allocator.free(function.ownership_events);
            function.ownership_cleanup_plan.deinit(self.allocator);
            var cleanup_cfg = function.cleanup_cfg;
            cleanup_cfg.deinit(self.allocator);
            if (function.ffi_param_contracts.len != 0) self.allocator.free(function.ffi_param_contracts);
            for (function.generated_type_expr_nodes) |node| self.allocator.destroy(node);
            if (function.generated_type_expr_nodes.len != 0) self.allocator.free(function.generated_type_expr_nodes);
            for (function.generated_type_expr_args) |args| self.allocator.free(args);
            if (function.generated_type_expr_args.len != 0) self.allocator.free(function.generated_type_expr_args);
            for (function.pointer_provenance_facts) |fact| {
                if (fact.field_path) |field_path| self.allocator.free(field_path);
            }
            self.allocator.free(function.pointer_provenance_facts);
            self.allocator.free(function.representation_facts);
            self.allocator.free(function.elided_bounds);
        }
        if (self.symbol_identities.len != 0) self.allocator.free(self.symbol_identities);
        if (self.source_identities.len != 0) self.allocator.free(self.source_identities);
        self.allocator.free(self.functions);
        if (self.drop_glue_facts.len != 0) self.allocator.free(self.drop_glue_facts);
        if (self.type_ownership_facts.len != 0) self.allocator.free(self.type_ownership_facts);
        if (self.aggregate_return_summaries.len != 0) self.allocator.free(self.aggregate_return_summaries);
        for (self.aggregate_return_pointer_facts) |fact| self.allocator.free(fact.field_path);
        if (self.aggregate_return_pointer_facts.len != 0) self.allocator.free(self.aggregate_return_pointer_facts);
    }
};

// Options for the MIR build/verify pipeline. `optimize` enables the fact-gated
// optimizer passes (annex E); off by default, so the standard pipeline and every
// existing caller are byte-for-byte unchanged.
pub const BuildOptions = struct {
    optimize: bool = false,
};

pub fn pointerShapeName(shape: PointerShape) []const u8 {
    if (isNullPointerShape(shape)) return "null";
    if (std.mem.eql(u8, shape.child, "c_void")) {
        return switch (shape.kind) {
            .single => switch (shape.mutability) {
                .none => "* c_void",
                .mut => "*mut c_void",
                .@"const" => "*const c_void",
            },
            .raw_many => switch (shape.mutability) {
                .none => "[*] c_void",
                .mut => "[*]mut c_void",
                .@"const" => "[*]const c_void",
            },
            .slice => switch (shape.mutability) {
                .none => "[] c_void",
                .mut => "[]mut c_void",
                .@"const" => "[]const c_void",
            },
        };
    }
    return switch (shape.kind) {
        .single => pointerTypeText(shape.mutability),
        .raw_many => rawManyPointerTypeText(shape.mutability),
        .slice => sliceTypeText(shape.mutability),
    };
}

pub fn addressClassName(kind: AddressClass) []const u8 {
    return switch (kind) {
        .paddr => "PAddr",
        .vaddr => "VAddr",
        .dma_addr => "DmaAddr",
        .user_ptr => "UserPtr",
        .mmio_ptr => "MmioPtr",
        .phys_ptr => "PhysPtr",
    };
}

fn isNullPointerShape(shape: PointerShape) bool {
    return std.mem.eql(u8, shape.child, "null");
}

fn pointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "*",
        .mut => "*mut",
        .@"const" => "*const",
    };
}

fn rawManyPointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[*]",
        .mut => "[*]mut",
        .@"const" => "[*]const",
    };
}

fn sliceTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[]",
        .mut => "[]mut",
        .@"const" => "[]const",
    };
}
