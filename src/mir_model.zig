const std = @import("std");

const ast = @import("ast.zig");

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
    detail: []const u8,
    const_index: ?usize = null,
    value_id: ?[]const u8 = null,
    contract_region_id: ?usize = null,
    line: usize,
    column: usize,

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
    source: SourcePoint,
};

pub const TargetTypeKind = enum {
    bind,
    result_ok,
    result_err,
    tagged_union,
    enum_literal,
    string_literal,
    array_literal,
    struct_literal,
    float_literal,
    null_literal,
    value_optional_coercion,
    dyn_coercion,
    conversion_source,
    conversion_target,
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
    atomic_payload,
    maybe_uninit_payload,
    explicit_cast_source,
    explicit_cast_target,
    view_const_narrow_source,
    view_const_narrow_target,
    raw_address,
    raw_payload,
    raw_result,
    va_start_result,
    va_arg_result,
    qualified_union_result,
    enum_variant_path_result,
    reflection_target,
    reflection_result,
    byte_view_source,
    byte_view_result,
};

pub const TargetTypeFact = struct {
    kind: TargetTypeKind,
    target_ty: ast.TypeExpr,
    result_ty: ValueType,
    source: SourcePoint,
};

pub const SourcePoint = struct {
    line: usize,
    column: usize,
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
    value_id: []const u8,
    source: SourcePoint,
};

pub const Block = struct {
    id: usize,
    kind: []const u8,
    instructions: []Instruction,
    successors: []usize,
    terminator: Terminator,
};

pub const Function = struct {
    name: []const u8,
    return_ty: ValueType,
    no_lang_trap: bool,
    irq_context: bool,
    blocks: []Block,
    trap_edges: []TrapEdge,
    contract_regions: []ContractRegion,
    range_facts: []RangeFact,
    bounds_facts: []BoundsFact = &.{},
    integer_facts: []IntegerFact = &.{},
    const_get_facts: []ConstGetFact = &.{},
    call_target_facts: []CallTargetFact = &.{},
    target_type_facts: []TargetTypeFact = &.{},
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
    functions: []Function,
    aggregate_return_summaries: []AggregateReturnSummaryFact = &.{},
    aggregate_return_pointer_facts: []AggregateReturnPointerFact = &.{},

    pub fn deinit(self: *Module) void {
        for (self.functions) |function| {
            for (function.blocks) |block| {
                self.allocator.free(block.instructions);
                self.allocator.free(block.successors);
            }
            self.allocator.free(function.blocks);
            self.allocator.free(function.trap_edges);
            self.allocator.free(function.contract_regions);
            self.allocator.free(function.range_facts);
            if (function.bounds_facts.len != 0) self.allocator.free(function.bounds_facts);
            if (function.integer_facts.len != 0) self.allocator.free(function.integer_facts);
            if (function.const_get_facts.len != 0) self.allocator.free(function.const_get_facts);
            if (function.call_target_facts.len != 0) self.allocator.free(function.call_target_facts);
            if (function.target_type_facts.len != 0) self.allocator.free(function.target_type_facts);
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
        self.allocator.free(self.functions);
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
