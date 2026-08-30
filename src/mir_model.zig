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
    duration,
};

pub const DomainIntegerShape = struct {
    kind: IntegerDomainKind,
    child: []const u8,
};

pub const ArrayShape = struct {
    /// Presentation spelling of the immediate element type. Array identity is
    /// structural: equal element spellings with different known lengths must
    /// not share a TypeId or aggregate-layout entry.
    child: []const u8,
    length: ?usize,
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
    array: ArrayShape,
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
            // Array spelling is presentation-only. Structural identity lives
            // in ArrayShape and must not be reconstructed from this label.
            .array => "array",
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
            .array => |shape| shape.length == right.array.length and std.mem.eql(u8, shape.child, right.array.child),
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
    /// Arithmetic admitted by an exact `no_overflow` contract region. The
    /// frontend records the region on the binary operation and the MIR
    /// verifier checks the matching range fact before codegen admission.
    unchecked,
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
    integer_reinterpret,
    integer_resize,
    unsigned_resize,
    signed_widen,
    address_to_integer,
    integer_to_address,
    pointer_to_integer,
    pointer_to_address,
    pointer_to_nullable,
    pointer_const_narrow,
    integer_to_open_enum,
    enum_to_integer,
    integer_to_domain,
    domain_to_integer,
    float_resize,

    pub fn classify(source: ValueType, target: ValueType) ?ExecutableCastKind {
        if (ValueType.eql(source, target)) return .identity;
        if (source == .float and target == .float and floatBits(source.float) != null and floatBits(target.float) != null)
            return .float_resize;
        if (source == .address) {
            const target_integer = integerInfo(target) orelse return null;
            return if (!target_integer.signed and target_integer.bits == 64) .address_to_integer else null;
        }
        if (target == .address) {
            if (source == .pointer) return .pointer_to_address;
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
        if ((source == .closed_enum or source == .open_enum) and integerInfo(target) != null) return .enum_to_integer;
        if (source == .integer and target == .domain_integer and std.mem.eql(u8, source.integer, target.domain_integer.child))
            return .integer_to_domain;
        if (source == .domain_integer and target == .integer and std.mem.eql(u8, source.domain_integer.child, target.integer))
            return .domain_to_integer;
        const source_integer = integerInfo(source) orelse return null;
        const target_integer = integerInfo(target) orelse return null;
        if (source_integer.signed != target_integer.signed and source_integer.bits == target_integer.bits) return .integer_reinterpret;
        if (!source_integer.signed and !target_integer.signed) return .unsigned_resize;
        if (source_integer.signed and target_integer.signed and target_integer.bits >= source_integer.bits) return .signed_widen;
        // Every remaining integer conversion changes width: mixed-sign
        // extension follows the source signedness, while any narrowing is a
        // bit truncation. Same-width sign changes remain the distinct
        // representation-preserving case above.
        return .integer_resize;
    }

    fn pointerQualificationCompatible(source: PointerShape, target: PointerShape) bool {
        if (source.kind != target.kind or !std.mem.eql(u8, source.child, target.child)) return false;
        return source.mutability == target.mutability or
            (source.mutability == .mut and target.mutability == .@"const");
    }

    pub fn integerInfo(ty: ValueType) ?ExecutableIntegerInfo {
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

    pub fn floatBits(name: []const u8) ?u16 {
        if (std.mem.eql(u8, name, "f32")) return 32;
        if (std.mem.eql(u8, name, "f64")) return 64;
        return null;
    }
};

pub const ExecutableIntegerInfo = struct { signed: bool, bits: u16 };

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
        .serial_compare => serial_compare: {
            if (operands.len != 2 or !ValueType.eql(operands[0], operands[1])) break :serial_compare false;
            const domain = switch (operands[0]) {
                .domain_integer => |shape| shape,
                else => break :serial_compare false,
            };
            const storage = ExecutableCastKind.integerInfo(.{ .integer = domain.child }) orelse break :serial_compare false;
            if (domain.kind != .serial or storage.signed or storage.bits > 64) break :serial_compare false;
            break :serial_compare switch (result) {
                .result => |shape| std.mem.eql(u8, shape.ok, "Order") and
                    std.mem.eql(u8, shape.err, "AmbiguousSerialOrder"),
                else => false,
            };
        },
        .counter_delta_mod => operands.len == 2 and ValueType.eql(operands[0], operands[1]) and switch (operands[0]) {
            .domain_integer => |shape| shape.kind == .counter and ValueType.eql(result, .{ .domain_integer = .{ .kind = .wrap, .child = shape.child } }),
            else => false,
        },
        .counter_elapsed_bounded => counter_bounded: {
            if (operands.len != 3 or !ValueType.eql(operands[0], operands[1])) break :counter_bounded false;
            const counter = switch (operands[0]) {
                .domain_integer => |shape| shape,
                else => break :counter_bounded false,
            };
            const duration = switch (operands[2]) {
                .domain_integer => |shape| shape,
                else => break :counter_bounded false,
            };
            const storage = ExecutableCastKind.integerInfo(.{ .integer = counter.child }) orelse break :counter_bounded false;
            if (counter.kind != .counter or duration.kind != .duration or
                !std.mem.eql(u8, counter.child, duration.child) or storage.signed or storage.bits > 64)
                break :counter_bounded false;
            break :counter_bounded switch (result) {
                .result => |shape| durationTypeSpellingMatches(shape.ok, duration.child) and
                    std.mem.eql(u8, shape.err, "AmbiguousCounterInterval"),
                else => false,
            };
        },
        // The exact nominal enum/repr TypeId relationship is checked by the
        // executable-body verifier and each renderer against `enum_types`.
        .enum_raw => operands.len == 1 and switch (operands[0]) {
            .closed_enum, .open_enum => ExecutableCastKind.integerInfo(result) != null,
            else => false,
        },
        .conversion_from => operands.len == 1 and valuePreservingIntegerConversion(operands[0], result),
        .conversion_try_from => conversion_try: {
            if (operands.len != 1) break :conversion_try false;
            const shape = switch (result) {
                .result => |value| value,
                else => break :conversion_try false,
            };
            if (!std.mem.eql(u8, shape.err, "ConversionError")) break :conversion_try false;
            break :conversion_try executableIntegerConversion(operands[0], .{ .integer = shape.ok }) != null;
        },
        .conversion_trap_from => operands.len == 1 and executableTrapConversion(operands[0], result) != null,
        .conversion_wrap_from, .conversion_from_mod => operands.len == 1 and executableIntegerConversion(operands[0], result) != null,
        .conversion_sat_from => operands.len == 1 and executableIntegerConversion(operands[0], result) != null,
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
        .cpu_pause, .fence_full, .fence_release, .fence_acquire => operands.len == 0 and result == .void,
        else => false,
    };
}

fn durationTypeSpellingMatches(spelling: []const u8, child: []const u8) bool {
    // `ValueType.result` retains the nominal outer payload identity while the
    // executable Result table owns its complete structural payload type.
    // Accept that canonical split here; renderers additionally verify that
    // the Result payload is exactly Duration<child>.
    if (std.mem.eql(u8, spelling, "Duration")) return true;
    const prefix = "Duration<";
    return spelling.len == prefix.len + child.len + 1 and
        std.mem.startsWith(u8, spelling, prefix) and spelling[spelling.len - 1] == '>' and
        std.mem.eql(u8, spelling[prefix.len .. spelling.len - 1], child);
}

pub fn executableBuiltinRequiresUnsafe(kind: CallTargetKind) bool {
    return switch (kind) {
        .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .forget_unchecked, .cpu_pause => true,
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
    if (target == .domain_integer and source == .integer and std.mem.eql(u8, target.domain_integer.child, source.integer)) return true;
    const source_info = executableIntegerStorageInfo(source) orelse return false;
    const target_info = executableIntegerStorageInfo(target) orelse return false;
    return source_info.signed == target_info.signed and target_info.bits >= source_info.bits;
}

pub const ExecutableTrapConversion = struct {
    source: ExecutableIntegerInfo,
    target: ExecutableIntegerInfo,
    need_lower: bool,
    need_upper: bool,
};

/// Closed scalar subset for `T.trap_from(value)`.  The range relationship is
/// semantic data shared by verification and both mechanical renderers.  Keep
/// 128-bit conversions on the legacy path until C has a portable boundary
/// spelling for their extrema.
pub fn executableTrapConversion(source_ty: ValueType, target_ty: ValueType) ?ExecutableTrapConversion {
    const conversion = executableIntegerConversion(source_ty, target_ty) orelse return null;
    const source = conversion.source;
    const target = conversion.target;
    const need_lower = source.signed and (!target.signed or target.bits < source.bits);
    const need_upper = if (source.signed == target.signed)
        target.bits < source.bits
    else if (!source.signed and target.signed)
        target.bits <= source.bits
    else
        target.bits + 1 < source.bits;
    return .{ .source = source, .target = target, .need_lower = need_lower, .need_upper = need_upper };
}

pub fn executableIntegerConversion(source_ty: ValueType, target_ty: ValueType) ?struct {
    source: ExecutableIntegerInfo,
    target: ExecutableIntegerInfo,
} {
    const source = executableIntegerStorageInfo(source_ty) orelse return null;
    const target = executableIntegerStorageInfo(target_ty) orelse return null;
    if (source.bits > 64 or target.bits > 64) return null;
    return .{ .source = source, .target = target };
}

pub fn executableIntegerStorageInfo(ty: ValueType) ?ExecutableIntegerInfo {
    return switch (ty) {
        .integer => ExecutableCastKind.integerInfo(ty),
        .domain_integer => |shape| ExecutableCastKind.integerInfo(.{ .integer = shape.child }),
        else => null,
    };
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

/// Canonical ordering for a typed MMIO access.  Unlike atomic ordering, MMIO
/// ordering is implemented by a volatile access plus an explicit compiler/CPU
/// fence on one side of that access.
pub const ExecutableMmioOrdering = enum {
    relaxed,
    acquire,
    release,

    pub fn validForRead(ordering: ExecutableMmioOrdering) bool {
        return ordering == .relaxed or ordering == .acquire;
    }

    pub fn validForWrite(ordering: ExecutableMmioOrdering) bool {
        return ordering == .relaxed or ordering == .release;
    }
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
    valid_closed_enum,

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
            .valid_closed_enum => result == .closed_enum,
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
            .pointer, .nullable_pointer, .cstr, .address, .value => 8,
            else => null,
        };
    }
};

pub fn executableStorageAlignment(enum_types: []const ExecutableEnumType, ty: ValueType) ?u16 {
    if (ExecutableMemoryAccess.scalarAlignment(ty)) |alignment| return alignment;
    switch (ty) {
        .closed_enum, .open_enum => for (enum_types) |enum_ty| if (ValueType.eql(enum_ty.ty, ty))
            return ExecutableMemoryAccess.scalarAlignment(enum_ty.repr_ty),
        else => {},
    }
    return null;
}

/// Ordinary aggregate copies are represented as one typed MIR load/store,
/// not as an atomic scalar access. Alignment 1 is deliberately conservative:
/// the canonical layout remains in the aggregate type metadata and both
/// renderers copy the complete value mechanically.
pub fn executableAggregateCopyAlignment(ty: ValueType) ?u16 {
    return switch (ty) {
        .array, .struct_, .nullable_value => 1,
        else => null,
    };
}

pub fn executableMemoryAlignment(enum_types: []const ExecutableEnumType, ty: ValueType) ?u16 {
    return executableStorageAlignment(enum_types, ty) orelse executableAggregateCopyAlignment(ty);
}

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
        /// A syntax-free typed MMIO register read.  The frontend has already
        /// resolved the register field and layout; codegen must not reopen the
        /// declaring struct or infer ordering from an enum literal.
        mmio_read: struct {
            base: LocalId,
            byte_offset: u64,
            storage_ty: ValueType,
            storage_type_id: TypeId,
            ordering: ExecutableMmioOrdering,
        },
        /// A syntax-free typed MMIO register write.  Operand ExprIds preserve
        /// source evaluation order before the release fence and volatile store.
        mmio_write: struct {
            base: LocalId,
            byte_offset: u64,
            storage_ty: ValueType,
            storage_type_id: TypeId,
            value: ExprId,
            ordering: ExecutableMmioOrdering,
        },
        literal: ExecutableLiteral,
        unary: struct { op: ExecutableUnaryOp, operand: ExprId },
        binary: struct {
            op: ExecutableBinaryOp,
            left: ExprId,
            right: ExprId,
            arithmetic: ExecutableArithmeticSemantics = .ordinary,
            contract_region_id: ?usize = null,
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
        /// Construct a closure fat value from a checked function target and
        /// one captured environment pointer. The public call signature omits
        /// the erased environment parameter; codegen represents the value as
        /// `{ code, env }` and an indirect call supplies `env` first.
        closure_bind: struct {
            target: SymbolId,
            capture: ExprId,
            signature: ExecutableCallSignature,
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
        index: struct {
            base: ExprId,
            index: ExprId,
            kind: ExecutableIndexKind,
            /// Fixed-array bound. Slice length is evaluated from `base`.
            bound: ?usize = null,
            /// A checked index owns exactly one Bounds exceptional edge.
            /// An unchecked fixed-array index is admitted only when the
            /// operand is a canonical in-range integer literal.
            checked: bool = true,
        },
        range_slice: struct { base: ExprId, start: ExprId, end: ExprId, checked: bool = true },
        member: struct { base: ExprId, field_index: usize },
        slice_length: ExprId,
        /// Construct the tagged representation of a sized value optional.
        /// The result type is `.nullable_value`; `some` owns the payload
        /// expression while `none` owns no operand. Backends must not infer
        /// this coercion from source syntax or the surrounding return type.
        optional_some: ExprId,
        optional_none,
        /// Test the representation discriminant of an optional or Result.
        /// The operand is first stored in a synthetic local by the producer,
        /// so a call-valued `if let` subject is evaluated exactly once.
        variant_test: struct { operand: ExprId, kind: ExecutableVariantKind },
        /// Extract the payload selected by a preceding variant test. Control
        /// flow, not this operation, proves that the requested variant is live.
        variant_payload: struct { operand: ExprId, kind: ExecutableVariantKind },
        /// Consume a nullable pointer after an exact `Unwrap` exceptional
        /// edge. The result is the same machine pointer with its non-null
        /// obligation made explicit; backends only encode this checked MIR
        /// operation and never rediscover source `?` syntax.
        try_unwrap: ExprId,
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

pub const ExecutableIndexKind = enum {
    fixed_array,
    slice,
};

pub const ExecutableVariantKind = enum {
    optional_present,
    result_ok,
    result_err,
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
    /// Closures carry an erased environment pointer before the public
    /// parameters; plain function pointers do not.
    has_environment: bool = false,
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
    /// Exact source operation that owns this exceptional edge. This remains
    /// distinct from the owner's span because one indexed place may contain
    /// several checked projections owned by the same load/store expression.
    span_id: SpanId = .invalid,
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
        /// A checked indexed place owns the same bounds obligation as an
        /// indexed value expression. Keeping the bound and source identity on
        /// the place prevents codegen from reconstructing assignment-target
        /// semantics from source syntax.
        index: struct {
            value: ExprId,
            kind: ExecutableIndexKind,
            bound: ?usize = null,
            checked: bool = true,
            span_id: SpanId = .invalid,
        },
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
pub fn executableLocalAddressAliasTarget(
    statements: []const ExecutableStatement,
    expressions: []const ExecutableExpression,
    places: []const ExecutablePlace,
    local: LocalId,
    pointer_ty: ValueType,
    pointer_type_id: TypeId,
) ?PlaceId {
    // Any ordinary value use can copy or escape the pointer. Dereference
    // places refer to the LocalId directly and therefore do not need a
    // `.local` expression; keeping the accepted proof this narrow preserves
    // the existing conservative access mode after calls, returns, or copies.
    for (expressions) |expression| switch (expression.operation) {
        .local => |used| if (used.eql(local)) return null,
        .direct_call, .indirect_call, .builtin_call => return null,
        else => {},
    };
    var found: ?PlaceId = null;
    for (statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) {
            if (found != null or init.value == null or !ValueType.eql(init.ty, pointer_ty) or
                !init.type_id.eql(pointer_type_id)) return null;
            const value_id = init.value.?;
            if (!value_id.isValid() or value_id.index() >= expressions.len) return null;
            const value = expressions[value_id.index()];
            if (!value.id.eql(value_id) or !value.owner_statement.eql(statement.id) or
                !ValueType.eql(value.result_ty, pointer_ty) or !value.type_id.eql(pointer_type_id)) return null;
            const address = switch (value.operation) {
                .address_of => |address| address,
                else => return null,
            };
            if (!address.place.isValid() or address.place.index() >= places.len) return null;
            const target = places[address.place.index()];
            if (!target.id.eql(address.place) or target.projection_count > max_executable_projections or
                !target.type_id.isValid()) return null;
            switch (target.root) {
                .local, .symbol => {},
                .value => return null,
            }
            const pointer = switch (pointer_ty) {
                .pointer => |shape| shape,
                else => return null,
            };
            if (pointer.kind != .single or !std.mem.eql(u8, pointer.child, target.ty.name())) return null;
            found = address.place;
        },
        .store => |store| if (store.place.isValid() and store.place.index() < places.len) {
            const target = places[store.place.index()];
            if (target.projection_count == 0) switch (target.root) {
                .local => |stored| if (stored.eql(local)) return null,
                .symbol, .value => {},
            };
        },
        else => {},
    };
    return found;
}

pub fn executableLocalAddressAlias(
    statements: []const ExecutableStatement,
    expressions: []const ExecutableExpression,
    places: []const ExecutablePlace,
    local: LocalId,
    pointer_ty: ValueType,
    pointer_type_id: TypeId,
) bool {
    return executableLocalAddressAliasTarget(statements, expressions, places, local, pointer_ty, pointer_type_id) != null;
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
    /// Transparent scalar storage for packed-bits declarations. Ordinary
    /// aggregates leave these fields invalid/unknown.
    storage_ty: ValueType = .unknown,
    storage_type_id: TypeId = .invalid,
    /// Canonical presentation names for mechanical C member emission. Field
    /// identity is still the dense index; these spellings carry no semantic
    /// authority and LLVM does not consume them.
    field_spellings: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    field_types: [max_executable_operands]ValueType = [_]ValueType{.unknown} ** max_executable_operands,
    field_type_ids: [max_executable_operands]TypeId = [_]TypeId{.invalid} ** max_executable_operands,
    /// Exact function-pointer shape for fields whose deliberately opaque
    /// `.value` representation would otherwise be ambiguous.
    field_callable_signatures: [max_executable_operands]?ExecutableCallSignature = [_]?ExecutableCallSignature{null} ** max_executable_operands,
    /// Trait-object fields also use the deliberately opaque `.value` semantic
    /// type, but their storage is a fixed two-pointer fat value rather than a
    /// callable pointer. Keep that layout distinction in canonical aggregate
    /// metadata so LLVM never has to recover it from syntax.
    field_dyn_traits: [max_executable_operands]bool = [_]bool{false} ** max_executable_operands,
    /// Whether codegen has every nested layout needed to spell this field's
    /// storage type mechanically. This is currently meaningful for fixed-array
    /// fields: producers set it only after interning the nested layout. The
    /// conservative default keeps hand-built and legacy MIR from claiming a
    /// layout they do not own, so LLVM fails admission before a typed GEP.
    field_layout_complete: [max_executable_operands]bool = [_]bool{false} ** max_executable_operands,
    /// Logical element count for fixed arrays. Large arrays retain one
    /// element-type slot instead of expanding one metadata slot per element.
    array_length: ?usize = null,
    field_count: usize = 0,
};

/// Return the exact callable contract for an addressable aggregate place.
/// A callable can live in a named field or in a fixed-array element; both are
/// represented as opaque `.value` storage and must be disambiguated by the
/// aggregate metadata rather than by backend source-shape inference.
pub fn executableCallablePlace(
    aggregate_types: []const ExecutableAggregateType,
    place: ExecutablePlace,
) ?ExecutableCallSignature {
    if (!place.root_type_id.isValid() or !place.type_id.isValid() or place.ty != .value) return null;
    const Selection = struct { aggregate_ty: ValueType, field_index: usize };
    const selection: Selection = if (place.projection_count == 1) switch (place.projections[0]) {
        .field => |index| .{ .aggregate_ty = place.root_ty, .field_index = index },
        .index => |index| if (index.kind == .fixed_array and index.bound != null)
            .{ .aggregate_ty = place.root_ty, .field_index = 0 }
        else
            return null,
        .deref => return null,
    } else if (place.projection_count == 2) switch (place.projections[0]) {
        .deref => switch (place.projections[1]) {
            .field => |index| .{
                .aggregate_ty = switch (place.root_ty) {
                    .pointer => |shape| if (shape.kind == .single) .{ .struct_ = shape.child } else return null,
                    else => return null,
                },
                .field_index = index,
            },
            .deref, .index => return null,
        },
        .index => |array_index| array_field: {
            if (array_index.kind != .fixed_array or array_index.bound == null) return null;
            const field_index = switch (place.projections[1]) {
                .field => |index| index,
                .deref, .index => return null,
            };
            for (aggregate_types) |array_shape| {
                if (!array_shape.type_id.eql(place.root_type_id) or !ValueType.eql(array_shape.ty, place.root_ty) or
                    array_shape.array_length == null or array_shape.array_length.? != array_index.bound.? or
                    array_shape.field_count == 0) continue;
                for (aggregate_types) |element_shape| if (element_shape.type_id.eql(array_shape.field_type_ids[0])) {
                    break :array_field .{ .aggregate_ty = element_shape.ty, .field_index = field_index };
                };
            }
            return null;
        },
        .field => return null,
    } else return null;
    for (aggregate_types) |aggregate| {
        if (!ValueType.eql(aggregate.ty, selection.aggregate_ty) or selection.field_index >= aggregate.field_count or
            aggregate.field_types[selection.field_index] != .value or
            !aggregate.field_type_ids[selection.field_index].eql(place.type_id)) continue;
        return aggregate.field_callable_signatures[selection.field_index];
    }
    return null;
}

/// Canonical scalar representation for an enum used by an executable body.
/// The enum's nominal `TypeId` remains distinct from its integer repr; LLVM
/// consumes the repr while C keeps the nominal typedef spelling.
pub const ExecutableEnumType = struct {
    type_id: TypeId,
    ty: ValueType,
    repr_type_id: TypeId,
    repr_ty: ValueType,
    /// Exact accepted representation set for a closed enum. Open enums keep
    /// this empty because every value of the repr type is valid.
    valid_values: [max_executable_operands]i128 = [_]i128{0} ** max_executable_operands,
    valid_value_count: usize = 0,
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

/// A fully typed `for` loop header.  The iterable and cursor are initialized
/// once in the preheader; each visit binds exactly one in-range element before
/// entering `body_block`.  Keeping this operation in executable MIR prevents
/// C and LLVM from rebuilding iteration semantics from the source AST.
pub const ExecutableForEachTerminator = struct {
    iterable_local: LocalId,
    iterable_ty: ValueType,
    iterable_type_id: TypeId,
    index_local: LocalId,
    index_type_id: TypeId,
    binding_local: LocalId,
    element_ty: ValueType,
    element_type_id: TypeId,
    kind: ExecutableIndexKind,
    bound: ?usize = null,
    body_block: BlockId,
    after_block: BlockId,
};

pub const ExecutableForStepTerminator = struct {
    index_local: LocalId,
    index_type_id: TypeId,
    header_block: BlockId,
};

pub const ExecutableTerminator = struct {
    block_id: BlockId,
    source: SourcePoint = .{ .line = 0, .column = 0 },
    span_id: SpanId = .invalid,
    operation: union(enum) {
        fallthrough,
        jump: BlockId,
        branch: struct { condition: ExprId, true_block: BlockId, false_block: BlockId },
        for_each: ExecutableForEachTerminator,
        for_step: ExecutableForStepTerminator,
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
    unsupported_index,
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

/// Return the field index for a direct by-value aggregate local projection.
/// The local declaration/parameter, aggregate layout, and projected field
/// type must all agree.  This is intentionally shared by the producer,
/// verifier, and both renderers so `local.field` never becomes a backend-local
/// source-shape inference again.
pub fn executableDirectAggregateFieldPlace(
    locals: []const ExecutableLocalIdentity,
    statements: []const ExecutableStatement,
    aggregate_types: []const ExecutableAggregateType,
    place: ExecutablePlace,
    require_mutable: bool,
) ?usize {
    if (place.storage != .ordinary or place.projection_count != 1 or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        ExecutableMemoryAccess.scalarAlignment(place.ty) == null) return null;
    const field_index = switch (place.projections[0]) {
        .field => |index| index,
        .deref, .index => return null,
    };
    const local_id: ?LocalId = switch (place.root) {
        .local => |id| id,
        // Symbol kind and mutability live in the owning executable body.  The
        // shared shape predicate admits a read projection here; verifier and
        // renderers still require an exact global SymbolIdentity before use.
        .symbol => if (require_mutable) return null else null,
        .value => return null,
    };
    if (local_id) |id| if (!id.isValid() or id.index() >= locals.len or !locals[id.index()].id.eql(id)) return null;

    if (require_mutable) {
        var mutable = false;
        for (statements) |statement| switch (statement.operation) {
            .local_init => |init| if (init.local.eql(local_id.?)) {
                mutable = init.mutable;
                break;
            },
            else => {},
        };
        if (!mutable) return null;
    }

    var aggregate: ?ExecutableAggregateType = null;
    for (aggregate_types) |candidate| if (candidate.type_id.eql(place.root_type_id)) {
        aggregate = candidate;
        break;
    };
    const shape = aggregate orelse return null;
    if ((shape.construction != .declared_struct and shape.construction != .c_union) or
        !ValueType.eql(shape.ty, place.root_ty) or field_index >= shape.field_count or
        !shape.field_type_ids[field_index].eql(place.type_id) or
        !ValueType.eql(shape.field_types[field_index], place.ty)) return null;
    return field_index;
}

/// Validate a by-value aggregate local/global field chain such as
/// `local.outer.inner`.  The complete projection is checked against the
/// canonical aggregate table; source spelling is never consulted.
pub fn executableAggregateFieldPlace(
    locals: []const ExecutableLocalIdentity,
    statements: []const ExecutableStatement,
    aggregate_types: []const ExecutableAggregateType,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count == 0 or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        ExecutableMemoryAccess.scalarAlignment(place.ty) == null) return false;
    const local_id: ?LocalId = switch (place.root) {
        .local => |id| id,
        // The owning body carries global mutability; producer/verifier and
        // renderer access checks validate it after this shape check.
        .symbol => null,
        .value => return false,
    };
    if (local_id) |id| {
        if (!id.isValid() or id.index() >= locals.len or !locals[id.index()].id.eql(id)) return false;
        if (require_mutable) {
            var mutable = false;
            for (statements) |statement| switch (statement.operation) {
                .local_init => |init| if (init.local.eql(id)) {
                    mutable = init.mutable;
                    break;
                },
                else => {},
            };
            if (!mutable) return false;
        }
    }

    var current_ty = place.root_ty;
    var current_type_id = place.root_type_id;
    for (place.projections[0..place.projection_count]) |projection| {
        const field_index = switch (projection) {
            .field => |index| index,
            .deref, .index => return false,
        };
        var aggregate: ?ExecutableAggregateType = null;
        for (aggregate_types) |candidate| if (candidate.type_id.eql(current_type_id)) {
            aggregate = candidate;
            break;
        };
        const shape = aggregate orelse return false;
        if ((shape.construction != .declared_struct and shape.construction != .c_union) or
            !ValueType.eql(shape.ty, current_ty) or field_index >= shape.field_count) return false;
        current_ty = shape.field_types[field_index];
        current_type_id = shape.field_type_ids[field_index];
    }
    return current_type_id.eql(place.type_id) and ValueType.eql(current_ty, place.ty);
}

pub const ExecutableAggregatePointerFieldDeref = struct {
    field_index: usize,
    pointer_ty: ValueType,
};

/// Recognize `aggregate_local.pointer_field.*` from canonical place and layout
/// metadata.  The pointer-bearing field is the representation-guard subject;
/// the final dereference is the scalar access.  Keeping this predicate in MIR
/// prevents either backend from reconstructing alias shape from source text.
pub fn executableAggregatePointerFieldDerefPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) ?ExecutableAggregatePointerFieldDeref {
    if (place.storage != .ordinary or place.projection_count != 2 or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        ExecutableMemoryAccess.scalarAlignment(place.ty) == null) return null;
    const field_index = switch (place.projections[0]) {
        .field => |index| index,
        .deref, .index => return null,
    };
    if (place.projections[1] != .deref) return null;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return null,
    };
    if (!local.isValid() or local.index() >= body.locals.len or !body.locals[local.index()].id.eql(local)) return null;
    var aggregate: ?ExecutableAggregateType = null;
    for (body.aggregate_types) |candidate| if (candidate.type_id.eql(place.root_type_id)) {
        aggregate = candidate;
        break;
    };
    const shape = aggregate orelse return null;
    if (shape.construction != .declared_struct or !ValueType.eql(shape.ty, place.root_ty) or
        field_index >= shape.field_count) return null;
    const pointer_ty = shape.field_types[field_index];
    const pointer = switch (pointer_ty) {
        .pointer => |value| value,
        else => return null,
    };
    if (pointer.kind != .single or (require_mutable and pointer.mutability != .mut) or
        !std.mem.eql(u8, pointer.child, place.ty.name())) return null;
    return .{ .field_index = field_index, .pointer_ty = pointer_ty };
}

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

/// Return the canonical place borrowed by a scalar local-pointer
/// dereference.  Consumers use the target root to preserve the memory access
/// class: an alias of local storage is plain, while an alias of mutable global
/// storage remains race-unordered.
pub fn executableLocalAddressDerefTarget(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) ?PlaceId {
    if (!executableLocalAddressDerefPlace(body, place, require_mutable)) return null;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return null,
    };
    return executableLocalAddressAliasTarget(
        body.statements,
        body.expressions,
        body.places,
        local,
        place.root_ty,
        place.root_type_id,
    );
}

/// Check a scalar dereference through a pointer stored in a global. The
/// pointer value itself is race-tolerantly loaded before the pointee access;
/// the global symbol is never confused with the pointee address.
pub fn executableGlobalPointerDerefPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        executableStorageAlignment(body.enum_types, place.ty) == null) return false;
    const symbol_id = switch (place.root) {
        .symbol => |id| id,
        .local, .value => return false,
    };
    if (!symbol_id.isValid() or symbol_id.index() >= body.symbols.len) return false;
    const symbol = body.symbols[symbol_id.index()];
    if (!symbol.id.eql(symbol_id) or symbol.kind != .global) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single and (!require_mutable or pointer.mutability == .mut) and
        std.mem.eql(u8, pointer.child, place.ty.name());
}

/// Validate a typed projection chain containing at least one fixed-array
/// index. Every index and field advances through the canonical aggregate
/// table. Producer, verifier and both renderers share this predicate so nested
/// bounds, interleaved fields and element identity cannot drift.
pub fn executableFixedArrayIndexPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
) ?@FieldType(ExecutablePlace.Projection, "index") {
    if (place.storage != .ordinary or place.projection_count == 0 or
        !place.root_type_id.isValid() or !place.type_id.isValid()) return null;
    var current_ty = place.root_ty;
    var current_type_id = place.root_type_id;
    var first_index: ?@FieldType(ExecutablePlace.Projection, "index") = null;
    for (place.projections[0..place.projection_count], 0..) |item, projection_index| switch (item) {
        .index => |projection| {
            if (projection.kind != .fixed_array or projection.bound == null or
                !projection.span_id.isValid() or !projection.value.isValid() or
                projection.value.index() >= body.expressions.len) return null;
            const index = body.expressions[projection.value.index()];
            if (!index.id.eql(projection.value) or !ValueType.eql(index.result_ty, .{ .integer = "usize" })) return null;
            const array = switch (current_ty) {
                .array => |shape| shape,
                else => return null,
            };
            const bound = projection.bound.?;
            if (array.length == null or array.length.? != bound or bound == 0) return null;
            var aggregate: ?ExecutableAggregateType = null;
            for (body.aggregate_types) |candidate| if (candidate.type_id.eql(current_type_id)) {
                aggregate = candidate;
                break;
            };
            const shape = aggregate orelse return null;
            if (shape.array_length == null or shape.array_length.? != bound or shape.field_count == 0 or
                !ValueType.eql(shape.ty, current_ty)) return null;
            if (!projection.checked) switch (index.operation) {
                .literal => |literal| switch (literal) {
                    .integer => |value| if (value >= bound) return null,
                    else => return null,
                },
                else => return null,
            };
            if (first_index == null) first_index = projection;
            current_ty = shape.field_types[0];
            current_type_id = shape.field_type_ids[0];
        },
        .field => |field_index| {
            _ = projection_index;
            var aggregate: ?ExecutableAggregateType = null;
            for (body.aggregate_types) |candidate| if (candidate.type_id.eql(current_type_id)) {
                aggregate = candidate;
                break;
            };
            const shape = aggregate orelse return null;
            if (!ValueType.eql(shape.ty, current_ty) or field_index >= shape.field_count) return null;
            current_ty = shape.field_types[field_index];
            current_type_id = shape.field_type_ids[field_index];
        },
        .deref => return null,
    };
    if (!ValueType.eql(current_ty, place.ty) or !current_type_id.eql(place.type_id)) return null;
    return first_index;
}

pub fn executableFixedArrayCheckedProjectionCount(place: ExecutablePlace) usize {
    var count: usize = 0;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| count += @intFromBool(index.kind == .fixed_array and index.checked),
        .field, .deref => {},
    };
    return count;
}

pub fn executableCheckedIndexProjectionCount(place: ExecutablePlace) usize {
    var count: usize = 0;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| count += @intFromBool(index.checked),
        .field, .deref => {},
    };
    return count;
}

pub fn executableFixedArrayProjectionForSpan(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    span_id: SpanId,
) ?@FieldType(ExecutablePlace.Projection, "index") {
    _ = executableFixedArrayIndexPlace(body, place) orelse return null;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| if (index.kind == .fixed_array and index.checked and index.span_id.eql(span_id)) return index,
        .field, .deref => {},
    };
    return null;
}

pub fn executableSliceIndexPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
) ?@FieldType(ExecutablePlace.Projection, "index") {
    if (place.storage != .ordinary or place.projection_count != 1 or
        !place.root_type_id.isValid() or !place.type_id.isValid()) return null;
    const projection = switch (place.projections[0]) {
        .index => |index| index,
        .field, .deref => return null,
    };
    if (projection.kind != .slice or projection.bound != null or !projection.checked or
        !projection.span_id.isValid() or !projection.value.isValid() or
        projection.value.index() >= body.expressions.len) return null;
    const index = body.expressions[projection.value.index()];
    if (!index.id.eql(projection.value) or !ValueType.eql(index.result_ty, .{ .integer = "usize" })) return null;
    const child = switch (place.root_ty) {
        .pointer => |shape| if (shape.kind == .slice) shape.child else return null,
        .slice => |name| name,
        else => return null,
    };
    if (!std.mem.eql(u8, child, place.ty.name())) return null;
    return projection;
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
    typed_span_id: SpanId = .invalid,
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
