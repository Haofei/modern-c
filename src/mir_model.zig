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
pub const BodyId = TypedIndex("BodyId");
pub const InstId = TypedIndex("InstId");
pub const ExprId = TypedIndex("ExprId");
pub const LocalId = TypedIndex("LocalId");
pub const PlaceId = TypedIndex("PlaceId");

pub const CallableKind = enum {
    function,
    extern_function,
    global_initializer,
};

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

pub const IntegerDomainKind = enum {
    wrap,
    sat,
    serial,
    counter,
};

pub const DomainIntegerShape = struct {
    kind: IntegerDomainKind,
    child: []const u8,
};

pub const ValueType = union(enum) {
    void,
    never,
    bool,
    value,
    integer: []const u8,
    domain_integer: DomainIntegerShape,
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
            .domain_integer => |shape| shape.child,
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

    /// Structural equality for MIR types. `name()` remains a presentation
    /// spelling and is intentionally not an identity: for example `*T`,
    /// `?*T`, `[]T`, and a nominal `T` can share that spelling.
    pub fn eql(left: ValueType, right: ValueType) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .integer => |spelling| std.mem.eql(u8, spelling, right.integer),
            .domain_integer => |shape| shape.kind == right.domain_integer.kind and std.mem.eql(u8, shape.child, right.domain_integer.child),
            .float => |spelling| std.mem.eql(u8, spelling, right.float),
            .pointer => |shape| pointerShapeEql(shape, right.pointer),
            .nullable_pointer => |shape| pointerShapeEql(shape, right.nullable_pointer),
            .nullable_value => |spelling| std.mem.eql(u8, spelling, right.nullable_value),
            .slice => |spelling| std.mem.eql(u8, spelling, right.slice),
            .array => |spelling| std.mem.eql(u8, spelling, right.array),
            .address => |address_class| address_class == right.address,
            .closed_enum => |spelling| std.mem.eql(u8, spelling, right.closed_enum),
            .open_enum => |spelling| std.mem.eql(u8, spelling, right.open_enum),
            .struct_ => |spelling| std.mem.eql(u8, spelling, right.struct_),
            .result => |shape| std.mem.eql(u8, shape.ok, right.result.ok) and std.mem.eql(u8, shape.err, right.result.err),
            else => true,
        };
    }

    fn pointerShapeEql(left: PointerShape, right: PointerShape) bool {
        return left.kind == right.kind and left.mutability == right.mutability and std.mem.eql(u8, left.child, right.child);
    }
};

pub const Instruction = struct {
    pub const BuiltinMember = enum {
        slice_length,
    };

    pub const max_aggregate_operands: usize = 8;
    pub const max_switch_patterns: usize = 8;

    pub const SwitchPattern = union(enum) {
        unused,
        wildcard,
        scalar: struct {
            negative: bool,
            magnitude: u128,
        },
    };

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
    // Expression operators name their canonical operand occurrences directly.
    // These identities let shared MIR plans recover evaluation trees without
    // source offsets, relative columns, or backend AST queries. Unary
    // operators use only the left operand; binary operators use both.
    typed_left_operand_span_id: SpanId = .invalid,
    typed_right_operand_span_id: SpanId = .invalid,
    // Storage-shaped expressions and statements retain their semantic edges
    // explicitly. A member names its base occurrence and resolved field index;
    // assignments name target/value occurrences; return/local instructions may
    // name the value occurrence they consume. Shared lowering plans can then
    // reconstruct places without source-position arithmetic or an AST body.
    typed_base_operand_span_id: SpanId = .invalid,
    member_field_index: ?usize = null,
    builtin_member: ?BuiltinMember = null,
    // Fixed-array index expressions name both operands and carry the checked
    // constant/static-bound pair when it is known. This lets shared MIR plans
    // preserve the bounds trap without reading the source expression.
    typed_index_operand_span_id: SpanId = .invalid,
    constant_index_value: ?usize = null,
    static_index_bound: ?usize = null,
    // Integer literal expressions expose their canonical non-negative value so
    // the verifier can prove that an index instruction's constant metadata
    // agrees with its operand instead of trusting a duplicated producer field.
    constant_usize_value: ?usize = null,
    // Small aggregate literals own their immediate operand identities. Larger
    // literals remain valid MIR but are not admitted by the bounded shared
    // statement plan until a dynamic operand table replaces this inline form.
    // Struct literals additionally carry the resolved declaration field index
    // for each operand; array literals use the sentinel because their operand
    // order already is their element index.
    typed_aggregate_operand_span_ids: [max_aggregate_operands]SpanId = [_]SpanId{.invalid} ** max_aggregate_operands,
    typed_aggregate_field_indices: [max_aggregate_operands]usize = [_]usize{std.math.maxInt(usize)} ** max_aggregate_operands,
    typed_aggregate_operand_count: usize = 0,
    // A switch-arm marker may own a bounded, normalized set of scalar
    // patterns. Keeping signed magnitude here avoids source spelling and lets
    // shared lowering distinguish `-1`, character literals, and wildcard arms
    // without reopening the AST body.
    typed_switch_patterns: [max_switch_patterns]SwitchPattern = [_]SwitchPattern{.unused} ** max_switch_patterns,
    typed_switch_pattern_count: usize = 0,
    typed_target_operand_span_id: SpanId = .invalid,
    typed_value_operand_span_id: SpanId = .invalid,
    // Calls retain their enclosing expression span above for diagnostics and
    // source maps, while this ID names the callee occurrence shared by
    // call-result/argument/callee-signature facts.
    typed_callee_span_id: SpanId = .invalid,
    typed_operand_value_id: ValueId = .invalid,
    // Indirect calls may name a canonical callee storage root. A missing root
    // keeps the call outside shared mechanical lowering; a field index records
    // the one admitted projection without reconstructing it from source text.
    typed_callee_root_value_id: ValueId = .invalid,
    typed_callee_root_span_id: SpanId = .invalid,
    callee_field_index: ?usize = null,
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
        control_transfer,
        return_value,
    };
};

pub const max_executable_operands: usize = 16;
pub const max_executable_projections: usize = 8;

pub const ExecutableUnaryOp = enum { neg, bit_not, logical_not };
pub const ExecutableBinaryOp = enum {
    logical_or,
    logical_and,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    bit_or,
    bit_xor,
    bit_and,
    shl,
    shr,
    add,
    sub,
    mul,
    div,
    mod,
};

pub const ExecutableArithmeticSemantics = enum {
    ordinary,
    checked,
    wrapping,
    saturating,
};

pub const ExecutableTrapRequirement = struct {
    kind: TrapKind,
    source: TrapSource,
};

pub const ExecutableTrapRequirements = struct {
    items: [2]ExecutableTrapRequirement = undefined,
    count: usize,
};

/// Exact exceptional effects for one checked unary operation. Integer
/// negation is checked in MC; bitwise/logical operations are non-trapping.
pub fn executableCheckedUnaryTrapRequirements(op: ExecutableUnaryOp, ty: ValueType) ?ExecutableTrapRequirements {
    const info = ExecutableCastKind.integerInfo(ty) orelse return null;
    return switch (op) {
        .neg => if (info.signed) .{
            .items = .{ .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }, undefined },
            .count = 1,
        } else null,
        .bit_not, .logical_not => null,
    };
}

/// Exact exceptional effects for one checked integer binary operation.  This
/// table is shared by the producer, verifier and both mechanical renderers so
/// no backend can silently implement a weaker checked-arithmetic contract.
pub fn executableCheckedBinaryTrapRequirements(op: ExecutableBinaryOp, ty: ValueType) ?ExecutableTrapRequirements {
    const info = ExecutableCastKind.integerInfo(ty) orelse return null;
    return switch (op) {
        .add, .sub, .mul => .{
            .items = .{ .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }, undefined },
            .count = 1,
        },
        .div, .mod => if (info.signed) .{
            .items = .{
                .{ .kind = .DivideByZero, .source = .checked_arithmetic },
                .{ .kind = .IntegerOverflow, .source = .checked_arithmetic },
            },
            .count = 2,
        } else .{
            .items = .{ .{ .kind = .DivideByZero, .source = .checked_arithmetic }, undefined },
            .count = 1,
        },
        .shl => .{
            .items = .{
                .{ .kind = .InvalidShift, .source = .checked_shift },
                .{ .kind = .IntegerOverflow, .source = .checked_arithmetic },
            },
            .count = 2,
        },
        .shr => .{
            .items = .{ .{ .kind = .InvalidShift, .source = .checked_shift }, undefined },
            .count = 1,
        },
        else => null,
    };
}

pub const ExecutableCastKind = enum {
    identity,
    unsigned_resize,
    signed_widen,
    address_to_integer,
    integer_to_address,
    pointer_to_integer,
    pointer_to_nullable,
    pointer_const_narrow,
    integer_to_open_enum,

    pub fn classify(source: ValueType, target: ValueType) ?ExecutableCastKind {
        if (ValueType.eql(source, target)) return .identity;
        if (source == .address) {
            const target_integer = integerInfo(target) orelse return null;
            return if (!target_integer.signed and target_integer.bits == 64) .address_to_integer else null;
        }
        if (target == .address) {
            const source_integer = integerInfo(source) orelse return null;
            return if (!source_integer.signed and source_integer.bits == 64) .integer_to_address else null;
        }
        if (source == .pointer and integerInfo(target) != null) return .pointer_to_integer;
        if (source == .pointer and target == .nullable_pointer) {
            return if (pointerQualificationCompatible(source.pointer, target.nullable_pointer)) .pointer_to_nullable else null;
        }
        if (source == .pointer and target == .pointer and
            pointerQualificationCompatible(source.pointer, target.pointer) and
            source.pointer.mutability != target.pointer.mutability)
            return .pointer_const_narrow;
        if (integerInfo(source) != null and target == .open_enum) return .integer_to_open_enum;
        const source_integer = integerInfo(source) orelse return null;
        const target_integer = integerInfo(target) orelse return null;
        if (!source_integer.signed and !target_integer.signed) return .unsigned_resize;
        if (source_integer.signed and target_integer.signed and target_integer.bits >= source_integer.bits) return .signed_widen;
        return null;
    }

    fn pointerQualificationCompatible(source: PointerShape, target: PointerShape) bool {
        if (source.kind != target.kind or !std.mem.eql(u8, source.child, target.child)) return false;
        return source.mutability == target.mutability or
            (source.mutability == .mut and target.mutability == .@"const");
    }

    pub fn integerInfo(ty: ValueType) ?struct { signed: bool, bits: u16 } {
        const name = switch (ty) {
            .integer => |name| name,
            else => return null,
        };
        if (std.mem.eql(u8, name, "u8")) return .{ .signed = false, .bits = 8 };
        if (std.mem.eql(u8, name, "u16")) return .{ .signed = false, .bits = 16 };
        if (std.mem.eql(u8, name, "u32")) return .{ .signed = false, .bits = 32 };
        if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize")) return .{ .signed = false, .bits = 64 };
        if (std.mem.eql(u8, name, "u128")) return .{ .signed = false, .bits = 128 };
        if (std.mem.eql(u8, name, "i8")) return .{ .signed = true, .bits = 8 };
        if (std.mem.eql(u8, name, "i16")) return .{ .signed = true, .bits = 16 };
        if (std.mem.eql(u8, name, "i32")) return .{ .signed = true, .bits = 32 };
        if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize")) return .{ .signed = true, .bits = 64 };
        if (std.mem.eql(u8, name, "i128")) return .{ .signed = true, .bits = 128 };
        return null;
    }
};

pub fn executableBuiltinTypesValid(kind: CallTargetKind, result: ValueType, operands: []const ValueType) bool {
    return switch (kind) {
        .phys => operands.len == 1 and switch (result) {
            .address => |class| class == .paddr and unsignedIntegerAtLeast(operands[0], 64),
            else => false,
        },
        .wrapping_add => wrapping: {
            if (operands.len != 2) break :wrapping false;
            if (!ValueType.eql(result, operands[0]) or !ValueType.eql(result, operands[1])) break :wrapping false;
            break :wrapping switch (result) {
                .integer => (ExecutableCastKind.integerInfo(result) orelse break :wrapping false).signed == false,
                .domain_integer => |shape| shape.kind == .wrap and
                    (ExecutableCastKind.integerInfo(.{ .integer = shape.child }) orelse break :wrapping false).signed == false,
                else => false,
            };
        },
        .wrap_residue => operands.len == 1 and switch (operands[0]) {
            .domain_integer => |shape| shape.kind == .wrap and ValueType.eql(result, .{ .integer = shape.child }),
            else => false,
        },
        .serial_before, .serial_after => operands.len == 2 and result == .bool and
            ValueType.eql(operands[0], operands[1]) and switch (operands[0]) {
            .domain_integer => |shape| shape.kind == .serial and ExecutableCastKind.integerInfo(.{ .integer = shape.child }) != null,
            else => false,
        },
        .serial_distance => operands.len == 2 and ValueType.eql(operands[0], operands[1]) and switch (operands[0]) {
            .domain_integer => |shape| shape.kind == .serial and ValueType.eql(result, .{ .domain_integer = .{ .kind = .wrap, .child = shape.child } }),
            else => false,
        },
        .counter_delta_mod => operands.len == 2 and ValueType.eql(operands[0], operands[1]) and switch (operands[0]) {
            .domain_integer => |shape| shape.kind == .counter and ValueType.eql(result, .{ .domain_integer = .{ .kind = .wrap, .child = shape.child } }),
            else => false,
        },
        // The exact nominal enum/repr TypeId relationship is checked by the
        // executable-body verifier and each renderer against `enum_types`.
        .enum_raw => operands.len == 1 and switch (operands[0]) {
            .closed_enum, .open_enum => ExecutableCastKind.integerInfo(result) != null,
            else => false,
        },
        .conversion_from => operands.len == 1 and valuePreservingIntegerConversion(operands[0], result),
        // `bitcast` preserves the complete scalar bit pattern; it is neither a
        // numeric conversion nor a backend-selected coercion.  Keep this
        // first executable slice deliberately bounded to scalar integer/float
        // values of identical width.  Aggregate bitcasts need canonical layout
        // facts before they can cross the syntax-free boundary.
        .bitcast => operands.len == 1 and executableScalarBitWidth(operands[0]) != null and
            executableScalarBitWidth(operands[0]) == executableScalarBitWidth(result),
        .raw_many_offset => raw_many: {
            if (operands.len != 2 or !ValueType.eql(result, operands[0]))
                break :raw_many false;
            const pointer = switch (result) {
                .pointer => |shape| shape,
                else => break :raw_many false,
            };
            break :raw_many pointer.kind == .raw_many and ValueType.eql(operands[1], .{ .integer = "usize" });
        },
        .raw_load => operands.len == 1 and isExecutableRawScalar(result) and switch (operands[0]) {
            .address => |class| class == .paddr,
            else => false,
        },
        .raw_ptr => operands.len == 1 and switch (result) {
            .pointer => |shape| shape.kind == .single,
            else => false,
        } and switch (operands[0]) {
            .address => |class| class == .paddr,
            else => false,
        },
        .raw_store => operands.len == 2 and result == .void and isExecutableRawScalar(operands[1]) and switch (operands[0]) {
            .address => |class| class == .paddr,
            else => false,
        },
        // `forget_unchecked` consumes its operand at the ownership layer, but
        // deliberately has no runtime release action.  The executable body
        // still carries the operand so both mechanical renderers must evaluate
        // it exactly once before discarding the resulting value.
        .forget_unchecked => operands.len == 1 and result == .void,
        .fence_full, .fence_release, .fence_acquire => operands.len == 0 and result == .void,
        else => false,
    };
}

pub fn executableBuiltinRequiresUnsafe(kind: CallTargetKind) bool {
    return switch (kind) {
        .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .forget_unchecked => true,
        else => false,
    };
}

fn isExecutableRawScalar(ty: ValueType) bool {
    return switch (ty) {
        .bool, .address => true,
        .integer => |name| std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize") or
            std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "i32") or
            std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize"),
        .float => |name| std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64"),
        else => false,
    };
}

fn executableScalarBitWidth(ty: ValueType) ?u16 {
    if (ExecutableCastKind.integerInfo(ty)) |info| return info.bits;
    return switch (ty) {
        .float => |name| if (std.mem.eql(u8, name, "f32")) 32 else if (std.mem.eql(u8, name, "f64")) 64 else null,
        else => null,
    };
}

fn unsignedIntegerAtLeast(ty: ValueType, minimum_bits: u16) bool {
    const info = ExecutableCastKind.integerInfo(ty) orelse return false;
    return !info.signed and info.bits >= minimum_bits;
}

fn valuePreservingIntegerConversion(source: ValueType, target: ValueType) bool {
    if (ValueType.eql(source, target)) return true;
    const source_info = ExecutableCastKind.integerInfo(source) orelse return false;
    const target_info = ExecutableCastKind.integerInfo(target) orelse return false;
    return source_info.signed == target_info.signed and target_info.bits >= source_info.bits;
}

pub const ExecutableMemoryAccessKind = enum {
    plain,
    race_unordered,
};

/// Canonical ordering selected by semantic analysis for an atomic operation.
/// This is not a runtime enum operand: source spelling is discarded before
/// codegen and the executable-body verifier checks operation-specific legality.
pub const ExecutableAtomicOrdering = enum {
    relaxed,
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn validForLoad(ordering: ExecutableAtomicOrdering) bool {
        return switch (ordering) {
            .relaxed, .acquire, .seq_cst => true,
            .release, .acq_rel => false,
        };
    }

    pub fn validForStore(ordering: ExecutableAtomicOrdering) bool {
        return switch (ordering) {
            .relaxed, .release, .seq_cst => true,
            .acquire, .acq_rel => false,
        };
    }

    pub fn validForRmw(_: ExecutableAtomicOrdering) bool {
        return true;
    }
};

pub const ExecutableAtomicUpdateKind = enum {
    store,
    fetch_add,
    fetch_sub,
};

pub const ExecutablePlaceStorage = enum {
    ordinary,
    atomic,
};

/// A value-preserving runtime representation predicate. The wrapper owns its
/// exceptional edge; renderers expose the unchanged value only after the
/// predicate succeeds.
pub const ExecutableRepresentationCheckKind = enum {
    nonnull_pointer,
    valid_slice,

    pub fn typesValid(kind: ExecutableRepresentationCheckKind, result: ValueType, operand: ValueType) bool {
        if (!ValueType.eql(result, operand)) return false;
        return switch (kind) {
            .nonnull_pointer => switch (result) {
                .pointer => |shape| shape.kind == .single,
                else => false,
            },
            .valid_slice => switch (result) {
                .pointer => |shape| shape.kind == .slice,
                else => false,
            },
        };
    }
};

pub const ExecutableMemoryAccess = struct {
    kind: ExecutableMemoryAccessKind,
    alignment: u16,

    pub fn scalarAlignment(ty: ValueType) ?u16 {
        return switch (ty) {
            .bool => 1,
            .integer => |name| if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) 1 else if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) 2 else if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) 4 else if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) 8 else null,
            .domain_integer => |shape| if (std.mem.eql(u8, shape.child, "u8") or std.mem.eql(u8, shape.child, "i8")) 1 else if (std.mem.eql(u8, shape.child, "u16") or std.mem.eql(u8, shape.child, "i16")) 2 else if (std.mem.eql(u8, shape.child, "u32") or std.mem.eql(u8, shape.child, "i32")) 4 else if (std.mem.eql(u8, shape.child, "u64") or std.mem.eql(u8, shape.child, "i64") or std.mem.eql(u8, shape.child, "usize") or std.mem.eql(u8, shape.child, "isize")) 8 else null,
            .float => |name| if (std.mem.eql(u8, name, "f32")) 4 else if (std.mem.eql(u8, name, "f64")) 8 else null,
            .pointer, .nullable_pointer, .cstr, .address => 8,
            else => null,
        };
    }
};

pub const ExecutableLiteral = union(enum) {
    /// Canonical unsigned magnitude. A negative source expression is a
    /// separate unary operation, so radix, separators and suffix spelling do
    /// not leak into backend syntax.
    integer: u128,
    /// Canonical negative integer used when an enum case has a signed repr.
    /// Ordinary negative expressions remain `unary.neg(integer)`.
    signed_integer: i128,
    float: ExecutableFloatLiteral,
    string: []const u8,
    boolean: bool,
    null,
    uninit,
    void,
    enum_value: []const u8,
};

/// Canonical IEEE payload selected at the literal's checked semantic width.
/// Raw spelling remains syntax/source-map data and never reaches codegen.
pub const ExecutableFloatLiteral = union(enum) {
    f32_bits: u32,
    f64_bits: u64,
};

pub fn executableFloatMatchesType(value: ExecutableFloatLiteral, ty: ValueType) bool {
    return switch (value) {
        .f32_bits => switch (ty) {
            .float => |name| std.mem.eql(u8, name, "f32"),
            else => false,
        },
        .f64_bits => switch (ty) {
            .float => |name| std.mem.eql(u8, name, "f64"),
            else => false,
        },
    };
}

pub const ExecutableExpression = struct {
    id: ExprId,
    /// The basic block that owns this value operation. Operands are required
    /// to be earlier ExprIds in the same block, making source evaluation order
    /// explicit and preventing a backend from choosing its own AST traversal.
    block_id: BlockId,
    /// Statement whose evaluation owns this operation. ExprIds are dense and
    /// operands must precede their consumer within this statement.
    owner_statement: InstId,
    source: SourcePoint,
    span_id: SpanId = .invalid,
    result_ty: ValueType,
    type_id: TypeId = .invalid,
    operation: Operation,

    pub const Operation = union(enum) {
        local: LocalId,
        symbol: SymbolId,
        load: struct {
            place: PlaceId,
            access: ExecutableMemoryAccess,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        atomic_load: struct {
            place: PlaceId,
            ordering: ExecutableAtomicOrdering,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        /// Storage-normalized `atomic.init(value)`. `atomic<T>` has the same
        /// runtime representation as `T`; retaining this operation makes the
        /// checked initialization boundary explicit without exposing generic
        /// source syntax to codegen.
        atomic_init: ExprId,
        atomic_update: struct {
            kind: ExecutableAtomicUpdateKind,
            place: PlaceId,
            value: ExprId,
            ordering: ExecutableAtomicOrdering,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        literal: ExecutableLiteral,
        unary: struct { op: ExecutableUnaryOp, operand: ExprId },
        binary: struct {
            op: ExecutableBinaryOp,
            left: ExprId,
            right: ExprId,
            arithmetic: ExecutableArithmeticSemantics = .ordinary,
            /// Eager operand evaluation is equivalent to source short-circuit
            /// semantics for this logical operation.
            eager_safe: bool = false,
        },
        cast: struct { operand: ExprId, kind: ExecutableCastKind },
        representation_check: struct {
            operand: ExprId,
            kind: ExecutableRepresentationCheckKind,
        },
        direct_call: struct {
            callee: SymbolId,
            callee_source: SourcePoint,
            callee_span_id: SpanId = .invalid,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
        },
        builtin_call: struct {
            kind: CallTargetKind,
            /// Source-level unsafe authority carried by operations whose
            /// contract requires a lexical unsafe boundary.
            unsafe_authorized: bool = false,
            callee_source: SourcePoint,
            callee_span_id: SpanId = .invalid,
            /// Exact source location of a constrained builtin result
            /// representation check. `raw.ptr<T>` uses this to own its
            /// non-null pointer obligation in MIR rather than in a backend.
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
        },
        indirect_call: struct {
            callee: ExprId,
            signature: ExecutableCallSignature,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
        },
        address_of: struct {
            place: PlaceId,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        deref: ExprId,
        index: struct { base: ExprId, index: ExprId },
        range_slice: struct { base: ExprId, start: ExprId, end: ExprId },
        member: struct { base: ExprId, field_index: usize },
        slice_length: ExprId,
        /// Construct the tagged representation of a sized value optional.
        /// The result type is `.nullable_value`; `some` owns the payload
        /// expression while `none` owns no operand. Backends must not infer
        /// this coercion from source syntax or the surrounding return type.
        optional_some: ExprId,
        optional_none,
        result: struct {
            is_ok: bool,
            payload: ExprId,
        },
        array: struct {
            operands: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            operand_count: usize = 0,
        },
        struct_: struct {
            operands: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            field_indices: [max_executable_operands]usize = [_]usize{std.math.maxInt(usize)} ** max_executable_operands,
            operand_count: usize = 0,
            construction: AggregateConstructionKind,
        },
        unsupported,
    };
};

/// Canonical callable contract carried by an indirect call. Function values
/// intentionally remain opaque machine values; this bounded signature is the
/// semantic proof that the value is callable with these operands and result.
pub const ExecutableCallSignature = struct {
    parameter_types: [max_executable_operands]ValueType = [_]ValueType{.unknown} ** max_executable_operands,
    parameter_type_ids: [max_executable_operands]TypeId = [_]TypeId{.invalid} ** max_executable_operands,
    parameter_count: usize = 0,
    return_ty: ValueType = .unknown,
    return_type_id: TypeId = .invalid,
};

/// Typed exceptional control-flow owned by one executable operation.  The
/// source span remains diagnostic data on that operation; it is deliberately
/// not the semantic identity of this edge.
pub const ExecutableTrapOwner = union(enum) {
    expression: ExprId,
    statement: InstId,

    pub fn eql(left: ExecutableTrapOwner, right: ExecutableTrapOwner) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .expression => |id| id.eql(right.expression),
            .statement => |id| id.eql(right.statement),
        };
    }

    pub fn expressionId(self: ExecutableTrapOwner) ?ExprId {
        return switch (self) {
            .expression => |id| id,
            .statement => null,
        };
    }

    pub fn statementId(self: ExecutableTrapOwner) ?InstId {
        return switch (self) {
            .expression => null,
            .statement => |id| id,
        };
    }
};

pub const ExecutableTrapEdge = struct {
    owner: ExecutableTrapOwner,
    from_block: BlockId,
    trap_block: BlockId,
    kind: TrapKind,
    source: TrapSource,
};

/// Prove that eagerly evaluating a boolean expression tree preserves source
/// short-circuit semantics. Only side-effect-free locals/literals and ordinary
/// comparisons of those leaves are admitted; calls, loads, representation
/// checks, and every expression owning a trap edge fail closed.
pub fn executableEagerSafeBoolTree(
    expressions: []const ExecutableExpression,
    trap_edges: []const ExecutableTrapEdge,
    root: ExprId,
) bool {
    return executableEagerSafeBoolTreeDepth(expressions, trap_edges, root, 0);
}

fn executableEagerSafeBoolTreeDepth(
    expressions: []const ExecutableExpression,
    trap_edges: []const ExecutableTrapEdge,
    id: ExprId,
    depth: usize,
) bool {
    if (!id.isValid() or id.index() >= expressions.len or depth >= expressions.len) return false;
    const value = expressions[id.index()];
    if (!value.id.eql(id) or value.result_ty != .bool or executableExpressionOwnsTrap(trap_edges, id)) return false;
    return switch (value.operation) {
        .local => true,
        .literal => |literal| literal == .boolean,
        .unary => |unary| unary.op == .logical_not and
            executableEagerSafeBoolTreeDepth(expressions, trap_edges, unary.operand, depth + 1),
        .binary => |binary| if (binary.op == .logical_and or binary.op == .logical_or)
            binary.arithmetic == .ordinary and binary.eager_safe and
                executableEagerSafeBoolTreeDepth(expressions, trap_edges, binary.left, depth + 1) and
                executableEagerSafeBoolTreeDepth(expressions, trap_edges, binary.right, depth + 1)
        else
            executableComparisonIsPure(expressions, trap_edges, binary, depth + 1),
        else => false,
    };
}

fn executableComparisonIsPure(
    expressions: []const ExecutableExpression,
    trap_edges: []const ExecutableTrapEdge,
    binary: @FieldType(ExecutableExpression.Operation, "binary"),
    depth: usize,
) bool {
    if (binary.arithmetic != .ordinary or binary.eager_safe) return false;
    switch (binary.op) {
        .eq, .ne, .lt, .le, .gt, .ge => {},
        else => return false,
    }
    return executablePureComparisonLeaf(expressions, trap_edges, binary.left, depth) and
        executablePureComparisonLeaf(expressions, trap_edges, binary.right, depth);
}

fn executablePureComparisonLeaf(
    expressions: []const ExecutableExpression,
    trap_edges: []const ExecutableTrapEdge,
    id: ExprId,
    depth: usize,
) bool {
    if (!id.isValid() or id.index() >= expressions.len or depth >= expressions.len or
        executableExpressionOwnsTrap(trap_edges, id)) return false;
    const value = expressions[id.index()];
    if (!value.id.eql(id)) return false;
    return switch (value.operation) {
        .local => true,
        .literal => |literal| switch (literal) {
            .integer, .signed_integer, .float, .boolean, .null => true,
            .string, .uninit, .void, .enum_value => false,
        },
        else => false,
    };
}

fn executableExpressionOwnsTrap(trap_edges: []const ExecutableTrapEdge, id: ExprId) bool {
    for (trap_edges) |edge| if (edge.owner.expressionId()) |owner| {
        if (owner.eql(id)) return true;
    };
    return false;
}

pub const ExecutablePlace = struct {
    id: PlaceId,
    source: SourcePoint,
    span_id: SpanId = .invalid,
    /// A place can start at stable storage or at a previously evaluated
    /// pointer value.  `value` is deliberately narrow: the executable-body
    /// verifier currently admits only a raw-many `offset` result followed by
    /// exactly one dereference.
    root: union(enum) { local: LocalId, symbol: SymbolId, value: ExprId },
    root_ty: ValueType = .unknown,
    root_type_id: TypeId = .invalid,
    ty: ValueType = .unknown,
    type_id: TypeId = .invalid,
    storage: ExecutablePlaceStorage = .ordinary,
    projections: [max_executable_projections]Projection = [_]Projection{.deref} ** max_executable_projections,
    projection_count: usize = 0,

    pub const Projection = union(enum) {
        field: usize,
        index: ExprId,
        deref,
    };
};

pub const ExecutableStatement = struct {
    id: InstId,
    block_id: BlockId,
    source: SourcePoint,
    span_id: SpanId = .invalid,
    operation: Operation,

    pub const Operation = union(enum) {
        local_init: struct { local: LocalId, ty: ValueType, type_id: TypeId = .invalid, value: ?ExprId, mutable: bool },
        store: struct {
            place: PlaceId,
            value: ExprId,
            ty: ValueType,
            type_id: TypeId = .invalid,
            access: ExecutableMemoryAccess,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        eval: ExprId,
        guard: struct { kind: enum { if_, while_, switch_, assert_ }, condition: ExprId },
        contract_marker: struct {
            kind: enum { begin, end },
            name: []const u8,
        },
        return_: ?ExprId,
        control_transfer: enum { break_, continue_ },
        defer_cleanup,
        unsupported,
    };
};

/// Prove that `local` is initialized exactly once from the direct address of
/// another local and is never reassigned. This is the bounded provenance fact
/// needed to lower `*p` as local storage without reconstructing an AST alias.
pub fn executableLocalAddressAlias(
    statements: []const ExecutableStatement,
    expressions: []const ExecutableExpression,
    places: []const ExecutablePlace,
    local: LocalId,
    pointer_ty: ValueType,
    pointer_type_id: TypeId,
) bool {
    // Any ordinary value use can copy or escape the pointer. Dereference
    // places refer to the LocalId directly and therefore do not need a
    // `.local` expression; keeping the accepted proof this narrow preserves
    // the existing conservative access mode after calls, returns, or copies.
    for (expressions) |expression| switch (expression.operation) {
        .local => |used| if (used.eql(local)) return false,
        .direct_call, .indirect_call, .builtin_call => return false,
        else => {},
    };
    var found = false;
    for (statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) {
            if (found or init.value == null or !ValueType.eql(init.ty, pointer_ty) or
                !init.type_id.eql(pointer_type_id)) return false;
            const value_id = init.value.?;
            if (!value_id.isValid() or value_id.index() >= expressions.len) return false;
            const value = expressions[value_id.index()];
            if (!value.id.eql(value_id) or !value.owner_statement.eql(statement.id) or
                !ValueType.eql(value.result_ty, pointer_ty) or !value.type_id.eql(pointer_type_id)) return false;
            const address = switch (value.operation) {
                .address_of => |address| address,
                else => return false,
            };
            if (!address.place.isValid() or address.place.index() >= places.len) return false;
            const target = places[address.place.index()];
            if (!target.id.eql(address.place) or target.projection_count != 0 or
                !ValueType.eql(target.root_ty, target.ty)) return false;
            switch (target.root) {
                .local => {},
                .symbol, .value => return false,
            }
            found = true;
        },
        .store => |store| if (store.place.isValid() and store.place.index() < places.len) {
            const target = places[store.place.index()];
            if (target.projection_count == 0) switch (target.root) {
                .local => |stored| if (stored.eql(local)) return false,
                .symbol, .value => {},
            };
        },
        else => {},
    };
    return found;
}

pub const ExecutableParameter = struct {
    local: LocalId,
    ty: ValueType,
    type_id: TypeId = .invalid,
    /// Syntax-free proof that an otherwise opaque `.value` parameter has a
    /// function-pointer representation. This permits mechanical forwarding
    /// and indirect calls without treating every opaque value (for example a
    /// dynamic-trait payload) as an LLVM/C function pointer.
    callable_signature: ?ExecutableCallSignature = null,
    /// Payload identity when the source parameter is `atomic<T>` or a direct
    /// pointer to it. This is canonical frontend metadata, not a backend
    /// inference from pointer spelling.
    atomic_payload_type_id: TypeId = .invalid,
    source: SourcePoint,
    span_id: SpanId = .invalid,
};

pub const ExecutableLocalIdentity = struct { id: LocalId, spelling: []const u8 };

pub const ExecutableAggregateType = struct {
    type_id: TypeId,
    ty: ValueType,
    construction: AggregateConstructionKind,
    /// Canonical presentation names for mechanical C member emission. Field
    /// identity is still the dense index; these spellings carry no semantic
    /// authority and LLVM does not consume them.
    field_spellings: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    field_types: [max_executable_operands]ValueType = [_]ValueType{.unknown} ** max_executable_operands,
    field_type_ids: [max_executable_operands]TypeId = [_]TypeId{.invalid} ** max_executable_operands,
    field_count: usize = 0,
};

/// Canonical scalar representation for an enum used by an executable body.
/// The enum's nominal `TypeId` remains distinct from its integer repr; LLVM
/// consumes the repr while C keeps the nominal typedef spelling.
pub const ExecutableEnumType = struct {
    type_id: TypeId,
    ty: ValueType,
    repr_type_id: TypeId,
    repr_ty: ValueType,
};

/// Canonical payload layout for `Result<Ok, Err>`. The source spelling is
/// presentation-only; both renderers consume these typed payload identities.
pub const ExecutableResultType = struct {
    type_id: TypeId,
    ty: ValueType,
    ok_type_id: TypeId,
    ok_ty: ValueType,
    err_type_id: TypeId,
    err_ty: ValueType,
};

pub const max_executable_switch_cases: usize = 8;

pub const ExecutableSwitchValue = union(enum) {
    unsigned: u128,
    signed: i128,

    pub fn eql(self: ExecutableSwitchValue, other: ExecutableSwitchValue) bool {
        return switch (self) {
            .unsigned => |left| switch (other) {
                .unsigned => |right| left == right,
                .signed => |right| right >= 0 and left == @as(u128, @intCast(right)),
            },
            .signed => |left| switch (other) {
                .unsigned => |right| left >= 0 and @as(u128, @intCast(left)) == right,
                .signed => |right| left == right,
            },
        };
    }
};

pub const ExecutableSwitchCase = struct {
    value: ExecutableSwitchValue,
    target: BlockId,
};

pub const ExecutableSwitchTerminator = struct {
    subject: ExprId,
    cases: [max_executable_switch_cases]ExecutableSwitchCase = undefined,
    case_count: usize = 0,
    default_block: BlockId = .invalid,
};

pub const ExecutableTerminator = struct {
    block_id: BlockId,
    source: SourcePoint = .{ .line = 0, .column = 0 },
    span_id: SpanId = .invalid,
    operation: union(enum) {
        fallthrough,
        jump: BlockId,
        branch: struct { condition: ExprId, true_block: BlockId, false_block: BlockId },
        switch_: ExecutableSwitchTerminator,
        return_,
        trap_: TrapKind,
        unreachable_,
    },
};

/// Stable producer-owned reason for an expression that has not yet crossed
/// the canonical executable-MIR boundary. This is migration telemetry, not
/// source syntax: codegen never branches on it and complete bodies must carry
/// `.none`.
pub const ExecutableIncompleteReason = enum {
    none,
    unsupported_integer_literal,
    unsupported_float_literal,
    unsupported_character_literal,
    unsupported_cast,
    unsupported_address,
    unsupported_borrow,
    unsupported_member,
    unsupported_call,
    unsupported_array_literal,
    unsupported_struct_literal,
    unsupported_try,
    unsupported_block_expression,
    unsupported_unreachable_expression,
    unsupported_await,
};

pub const ExecutableBody = struct {
    complete: bool = true,
    incomplete_reason: ExecutableIncompleteReason = .none,
    return_type_id: TypeId = .invalid,
    parameters: []ExecutableParameter = &.{},
    locals: []ExecutableLocalIdentity = &.{},
    symbols: []SymbolIdentity = &.{},
    aggregate_types: []ExecutableAggregateType = &.{},
    enum_types: []ExecutableEnumType = &.{},
    result_types: []ExecutableResultType = &.{},
    expressions: []ExecutableExpression = &.{},
    trap_edges: []ExecutableTrapEdge = &.{},
    places: []ExecutablePlace = &.{},
    statements: []ExecutableStatement = &.{},
    terminators: []ExecutableTerminator = &.{},

    pub fn isComplete(self: *const ExecutableBody) bool {
        return self.complete;
    }

    pub fn deinit(self: *ExecutableBody, allocator: std.mem.Allocator) void {
        if (self.parameters.len != 0) allocator.free(self.parameters);
        if (self.locals.len != 0) allocator.free(self.locals);
        if (self.symbols.len != 0) allocator.free(self.symbols);
        if (self.aggregate_types.len != 0) allocator.free(self.aggregate_types);
        if (self.enum_types.len != 0) allocator.free(self.enum_types);
        if (self.result_types.len != 0) allocator.free(self.result_types);
        if (self.expressions.len != 0) allocator.free(self.expressions);
        if (self.trap_edges.len != 0) allocator.free(self.trap_edges);
        if (self.places.len != 0) allocator.free(self.places);
        if (self.statements.len != 0) allocator.free(self.statements);
        if (self.terminators.len != 0) allocator.free(self.terminators);
        self.* = .{};
    }
};

/// Check the complete typed shape of a scalar dereference through an
/// unescaped local-address alias. Producer, verifier, and renderers use this
/// single predicate so provenance admission cannot drift across backends.
pub fn executableLocalAddressDerefPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        ExecutableMemoryAccess.scalarAlignment(place.ty) == null) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    if (!executableLocalAddressAlias(
        body.statements,
        body.expressions,
        body.places,
        local,
        place.root_ty,
        place.root_type_id,
    )) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single and (!require_mutable or pointer.mutability == .mut) and
        std.mem.eql(u8, pointer.child, place.ty.name());
}

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
    typed_span_id: SpanId = .invalid,
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
    typed_span_id: SpanId = .invalid,
};

/// Resolved access semantics for expressions whose runtime representation is
/// not enough to recover their operand shapes. This intentionally stores only
/// structural types and stable source identities: backends do not need an AST
/// to distinguish an element index, a range slice, address construction, or a
/// dereference.
pub const AccessFact = union(enum) {
    index: struct {
        result_ty: ValueType,
        base_ty: ValueType,
        index_ty: ValueType,
        source: SourcePoint,
        typed_span_id: SpanId,
        base_span_id: SpanId,
        index_span_id: SpanId,
    },
    range_slice: struct {
        result_ty: ValueType,
        base_ty: ValueType,
        start_ty: ValueType,
        end_ty: ValueType,
        source: SourcePoint,
        typed_span_id: SpanId,
        base_span_id: SpanId,
        start_span_id: SpanId,
        end_span_id: SpanId,
    },
    address_of: struct {
        result_ty: ValueType,
        operand_ty: ValueType,
        source: SourcePoint,
        typed_span_id: SpanId,
        operand_span_id: SpanId,
    },
    deref: struct {
        result_ty: ValueType,
        operand_ty: ValueType,
        source: SourcePoint,
        typed_span_id: SpanId,
        operand_span_id: SpanId,
    },
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

pub fn explicitTrapKindForTarget(kind: CallTargetKind) ?TrapKind {
    return switch (kind) {
        .trap_bounds => .Bounds,
        .trap_null_unwrap => .Unwrap,
        .trap_integer_overflow => .IntegerOverflow,
        .trap_divide_by_zero => .DivideByZero,
        .trap_invalid_shift => .InvalidShift,
        .trap_invalid_representation => .InvalidRepresentation,
        .trap_assert => .Assert,
        .trap_unreachable => .Unreachable,
        else => null,
    };
}

pub const CallTargetFact = struct {
    kind: CallTargetKind,
    result_ty: ValueType,
    typed_span_id: SpanId = .invalid,
    source: SourcePoint,
};

pub const BindThunkFact = struct {
    target_fn: []const u8,
    typed_target_fn_symbol_id: SymbolId = .invalid,
    target_span_id: SpanId = .invalid,
    target_param_count: usize = 0,
    target_return_ty: TypeId = .invalid,
    capture_value_id: ValueId = .invalid,
    capture_span_id: SpanId = .invalid,
    capture_operand_span_id: SpanId = .invalid,
    capture_ty: TypeId = .invalid,
    target_capture_ty: TypeId = .invalid,
    closure_value_id: ValueId = .invalid,
    closure_span_id: SpanId = .invalid,
    closure_ty: TypeId = .invalid,
    closure_param_count: usize = 0,
    closure_return_ty: TypeId = .invalid,
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
    typed_unary_operand,
    typed_call_operand,
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
    indirect_call_argument,
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
    // Only indirect-call argument facts use this second span identity. It
    // binds an argument occurrence to one exact callee occurrence.
    typed_callee_span_id: SpanId = .invalid,
    typed_operand_value_id: ValueId = .invalid,
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
    file_id: u32 = std.math.maxInt(u32),
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
    /// `null` is retained for narrow synthetic fixtures. Producer-created
    /// identities always carry their structural MIR type.
    ty: ?ValueType = null,

    pub fn matches(self: TypeIdentity, ty: ValueType) bool {
        if (!std.mem.eql(u8, self.spelling, ty.name())) return false;
        return self.ty == null or ValueType.eql(self.ty.?, ty);
    }
};

pub const SymbolIdentity = struct {
    id: SymbolId,
    spelling: []const u8,
    kind: enum { unknown, function, global } = .unknown,
    mutable: bool = false,
    /// Payload identity for global `atomic<T>` storage.
    atomic_payload_type_id: TypeId = .invalid,
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
    param_types: []ValueType = &.{},
    is_extern: bool = false,
    c_abi: bool = false,
    is_variadic: bool = false,
    ffi_param_contracts: []FfiParamContract = &.{},
    no_lang_trap: bool,
    irq_context: bool,
    blocks: []Block,
    trap_edges: []TrapEdge,
    contract_regions: []ContractRegion,
    range_facts: []RangeFact,
    bounds_facts: []BoundsFact = &.{},
    access_facts: []AccessFact = &.{},
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
    /// Hand-built/legacy MIR fixtures may omit this projection. Production
    /// builders replace it with a populated body; omission is explicitly
    /// incomplete and can never reach mechanical codegen.
    executable_body: ExecutableBody = .{ .complete = false },
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

/// Syntax-free semantic summary shared by checking, MIR admission, and future
/// backend request narrowing. This deliberately does not duplicate expression
/// trees: bodies remain canonical MIR, while this table owns callable identity,
/// signature representation, ABI, and closed effect flags.
pub const CheckedCallableFact = struct {
    symbol_id: SymbolId,
    source_id: SourceId,
    body_id: BodyId,
    kind: CallableKind,
    return_ty: ValueType,
    param_count: usize,
    /// Independently owned semantic signature. Keeping this separate from the
    /// MIR function storage lets admission detect equal-arity type drift.
    param_types: []const ValueType = &.{},
    c_abi: bool,
    is_variadic: bool = false,
    no_lang_trap: bool,
    irq_context: bool,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    symbol_identities: []SymbolIdentity = &.{},
    source_identities: []SourceIdentity = &.{},
    checked_callables: []CheckedCallableFact = &.{},
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
            if (function.access_facts.len != 0) self.allocator.free(function.access_facts);
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
            var executable_body = function.executable_body;
            executable_body.deinit(self.allocator);
            if (function.ffi_param_contracts.len != 0) self.allocator.free(function.ffi_param_contracts);
            if (function.param_types.len != 0) self.allocator.free(function.param_types);
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
        if (self.checked_callables.len != 0) {
            for (self.checked_callables) |checked| {
                if (checked.param_types.len != 0) self.allocator.free(checked.param_types);
            }
            self.allocator.free(self.checked_callables);
        }
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
