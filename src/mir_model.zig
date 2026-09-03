const std = @import("std");

const ast = @import("ast.zig");
const semantic_ids = @import("semantic_ids.zig");

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
pub const DefId = semantic_ids.DefId;
pub const NodeId = TypedIndex("NodeId");
pub const SymbolId = TypedIndex("SymbolId");
pub const TypeId = TypedIndex("TypeId");
/// Module-owned source-signature type graph identity.  This is deliberately
/// distinct from `TypeId`, whose scope is one lowered executable body.
pub const SignatureTypeId = TypedIndex("SignatureTypeId");
pub const ValueId = TypedIndex("ValueId");
pub const BlockId = TypedIndex("BlockId");
pub const SpanId = TypedIndex("SpanId");
pub const BodyId = TypedIndex("BodyId");
pub const InstId = TypedIndex("InstId");
pub const ExprId = TypedIndex("ExprId");
pub const LocalId = TypedIndex("LocalId");
pub const PlaceId = TypedIndex("PlaceId");
pub const CleanupActionId = TypedIndex("CleanupActionId");

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

/// Syntax-free mutability used by the module-owned signature type table.
///
/// Do not use `ast.Mutability` here: this model is shared by checked-program
/// admission and must not gain a syntax dependency while declaration-shaped
/// codegen artifacts still exist.
pub const TypeMutability = enum {
    none,
    mut,
    @"const",
};

/// A recursive, source-independent representation of every `ast.TypeExpr`
/// form that can occur in a callable signature.  It deliberately models the
/// source type shape rather than `ValueType`: `ValueType` is the executable
/// representation of a value and intentionally erases distinctions such as
/// nested pointers, function pointers, closures, and generic arguments.
///
/// Child links always target earlier entries in `SignatureTypeTable`, which
/// keeps validation finite and makes the table an owned, acyclic type graph.
pub const TypeShape = union(enum) {
    name: []const u8,
    enum_literal: []const u8,
    member: struct { base: SignatureTypeId, field: []const u8 },
    nullable: SignatureTypeId,
    qualified: struct { mutability: TypeMutability, child: SignatureTypeId },
    pointer: struct { mutability: TypeMutability, child: SignatureTypeId },
    raw_many_pointer: struct { mutability: TypeMutability, child: SignatureTypeId },
    slice: struct { mutability: TypeMutability, child: SignatureTypeId },
    array: struct { length: ?usize, child: SignatureTypeId },
    generic: struct { base: []const u8, args: []const SignatureTypeId },
    fn_pointer: struct { params: []const SignatureTypeId, ret: SignatureTypeId },
    closure_type: struct { params: []const SignatureTypeId, ret: SignatureTypeId },
    dyn_trait: struct { mutability: TypeMutability, trait_name: []const u8 },

    pub fn eql(left: TypeShape, right: TypeShape) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .name => |name| std.mem.eql(u8, name, right.name),
            .enum_literal => |name| std.mem.eql(u8, name, right.enum_literal),
            .member => |member| member.base.eql(right.member.base) and std.mem.eql(u8, member.field, right.member.field),
            .nullable => |child| child.eql(right.nullable),
            .qualified => |shape| shape.mutability == right.qualified.mutability and shape.child.eql(right.qualified.child),
            .pointer => |shape| shape.mutability == right.pointer.mutability and shape.child.eql(right.pointer.child),
            .raw_many_pointer => |shape| shape.mutability == right.raw_many_pointer.mutability and shape.child.eql(right.raw_many_pointer.child),
            .slice => |shape| shape.mutability == right.slice.mutability and shape.child.eql(right.slice.child),
            .array => |shape| shape.length == right.array.length and shape.child.eql(right.array.child),
            .generic => |shape| typeIdSliceEql(shape.args, right.generic.args) and std.mem.eql(u8, shape.base, right.generic.base),
            .fn_pointer => |shape| shape.ret.eql(right.fn_pointer.ret) and typeIdSliceEql(shape.params, right.fn_pointer.params),
            .closure_type => |shape| shape.ret.eql(right.closure_type.ret) and typeIdSliceEql(shape.params, right.closure_type.params),
            .dyn_trait => |shape| shape.mutability == right.dyn_trait.mutability and std.mem.eql(u8, shape.trait_name, right.dyn_trait.trait_name),
        };
    }

    pub fn deinit(self: TypeShape, allocator: std.mem.Allocator) void {
        switch (self) {
            .name => |name| allocator.free(name),
            .enum_literal => |name| allocator.free(name),
            .member => |member| allocator.free(member.field),
            .generic => |shape| {
                allocator.free(shape.base);
                allocator.free(shape.args);
            },
            .fn_pointer => |shape| allocator.free(shape.params),
            .closure_type => |shape| allocator.free(shape.params),
            .dyn_trait => |shape| allocator.free(shape.trait_name),
            else => {},
        }
    }
};

fn typeIdSliceEql(left: []const SignatureTypeId, right: []const SignatureTypeId) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!a.eql(b)) return false;
    return true;
}

/// Module-owned canonical signature type graph.  It is distinct from the
/// per-function executable `TypeIdentity` tables and is the future syntax-free
/// ingress for function/global declaration artifacts.
pub const SignatureTypeTable = struct {
    shapes: []const TypeShape = &.{},

    pub const empty: SignatureTypeTable = .{};

    pub fn get(self: SignatureTypeTable, id: SignatureTypeId) ?TypeShape {
        if (!id.isValid() or id.index() >= self.shapes.len) return null;
        return self.shapes[id.index()];
    }

    pub fn contains(self: SignatureTypeTable, id: SignatureTypeId) bool {
        return self.get(id) != null;
    }

    pub fn validate(self: SignatureTypeTable) bool {
        for (self.shapes, 0..) |shape, index| {
            if (!typeShapeChildrenPrecede(shape, index)) return false;
        }
        return true;
    }

    pub fn deinit(self: *SignatureTypeTable, allocator: std.mem.Allocator) void {
        for (self.shapes) |shape| shape.deinit(allocator);
        if (self.shapes.len != 0) allocator.free(self.shapes);
        self.* = .{};
    }
};

fn typeShapeChildrenPrecede(shape: TypeShape, index: usize) bool {
    const preceding = struct {
        fn check(id: SignatureTypeId, current_index: usize) bool {
            return id.isValid() and id.index() < current_index;
        }
        fn checkSlice(ids: []const SignatureTypeId, current_index: usize) bool {
            for (ids) |id| if (!check(id, current_index)) return false;
            return true;
        }
    };
    return switch (shape) {
        .name, .enum_literal, .dyn_trait => true,
        .member => |value| preceding.check(value.base, index),
        .nullable => |value| preceding.check(value, index),
        .qualified => |value| preceding.check(value.child, index),
        .pointer => |value| preceding.check(value.child, index),
        .raw_many_pointer => |value| preceding.check(value.child, index),
        .slice => |value| preceding.check(value.child, index),
        .array => |value| preceding.check(value.child, index),
        .generic => |value| preceding.checkSlice(value.args, index),
        .fn_pointer => |value| preceding.check(value.ret, index) and preceding.checkSlice(value.params, index),
        .closure_type => |value| preceding.check(value.ret, index) and preceding.checkSlice(value.params, index),
    };
}

test "signature type table rejects invalid, self, and forward child rows" {
    const invalid = SignatureTypeTable{ .shapes = &.{.{ .nullable = .invalid }} };
    try std.testing.expect(!invalid.validate());

    const self_referential = SignatureTypeTable{ .shapes = &.{.{ .nullable = SignatureTypeId.fromIndex(0) }} };
    try std.testing.expect(!self_referential.validate());

    const forward = SignatureTypeTable{ .shapes = &.{
        .{ .nullable = SignatureTypeId.fromIndex(1) },
        .{ .name = "u32" },
    } };
    try std.testing.expect(!forward.validate());
}

pub const PointerShape = struct {
    kind: PointerKind,
    mutability: TypeMutability,
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
    tagged_union: []const u8,
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
            .tagged_union => |n| n,
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
            .tagged_union => |spelling| std.mem.eql(u8, spelling, right.tagged_union),
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
    typed_target_owner_id: ?SymbolId = null,
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
    // source maps, while this ID names the call-target anchor shared by
    // call-result/argument/callee-signature facts and `CallTargetFact` rows.
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

/// Syntax-free operand-less inline assembly. Template and clobber entries are
/// decoded byte strings owned by `ExecutableBody.owned_bytes`; source string
/// literal quoting is never exposed to codegen.
pub const ExecutableOpaqueAsm = struct {
    is_volatile: bool,
    templates: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    template_count: usize = 0,
    clobbers: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    clobber_count: usize = 0,
};

pub const ExecutableAsmOutput = struct {
    constraint: []const u8,
    local: LocalId,
    ty: ValueType,
    type_id: TypeId = .invalid,
};

pub const ExecutableAsmInput = struct {
    constraint: []const u8,
    value: ExprId,
    ty: ValueType,
    type_id: TypeId = .invalid,
};

pub const ExecutablePreciseAsm = struct {
    is_volatile: bool,
    templates: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    template_count: usize = 0,
    clobbers: [max_executable_operands][]const u8 = [_][]const u8{""} ** max_executable_operands,
    clobber_count: usize = 0,
    outputs: [max_executable_operands]ExecutableAsmOutput = undefined,
    output_count: usize = 0,
    inputs: [max_executable_operands]ExecutableAsmInput = undefined,
    input_count: usize = 0,
};

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
    bool_to_integer,
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
        if (source == .bool and integerInfo(target) != null) return .bool_to_integer;
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
            (source.mutability == .mut and (target.mutability == .@"const" or target.mutability == .none));
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

pub const ExecutableDmaBufferMode = enum {
    coherent,
    noncoherent,
};

pub fn executableBuiltinTypesValid(kind: CallTargetKind, result: ValueType, operands: []const ValueType) bool {
    return switch (kind) {
        .const_get => operands.len == 1 and switch (operands[0]) {
            .array => |shape| shape.length != null and std.mem.eql(u8, shape.child, result.name()),
            else => false,
        },
        .phys => operands.len == 1 and switch (result) {
            .address => |class| class == .paddr and unsignedIntegerAtLeast(operands[0], 64),
            else => false,
        },
        .reduce_sum_checked => reduce_checked: {
            if (operands.len != 1) break :reduce_checked false;
            const element = executableSliceElementName(operands[0]) orelse break :reduce_checked false;
            const info = ExecutableCastKind.integerInfo(.{ .integer = element }) orelse break :reduce_checked false;
            if (info.bits > 64) break :reduce_checked false;
            break :reduce_checked switch (result) {
                .result => |shape| std.mem.eql(u8, shape.ok, element) and std.mem.eql(u8, shape.err, "Overflow"),
                else => false,
            };
        },
        .reduce_sum_left, .reduce_sum_fast => operands.len == 1 and switch (result) {
            .float => |name| if (executableSliceElementName(operands[0])) |element|
                std.mem.eql(u8, name, element) and ExecutableCastKind.floatBits(name) != null
            else
                false,
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
        .byte_view_as_bytes => operands.len == 1 and switch (operands[0]) {
            .pointer => |shape| shape.kind == .single,
            else => false,
        } and switch (result) {
            .pointer => |shape| shape.kind == .slice and shape.mutability == .@"const" and
                std.mem.eql(u8, shape.child, "u8"),
            else => false,
        },
        .byte_view_equal => operands.len == 2 and result == .bool and
            ValueType.eql(operands[0], operands[1]) and switch (operands[0]) {
            .pointer => |shape| shape.kind == .slice and shape.mutability == .@"const" and
                std.mem.eql(u8, shape.child, "u8"),
            else => false,
        },
        // Secret<T> is representation-transparent. Sema proves that the source
        // is Secret<T> and records the escape facts; executable MIR retains the
        // payload ValueType and the unsafe authorization, so lowering is an
        // identity operation only when the structural types still agree.
        .declassify => operands.len == 1 and ValueType.eql(result, operands[0]),
        // The contract checker owns the no-alias promise. Executable MIR only
        // carries the value-preserving operation and the checked byte length;
        // both operands are evaluated, while codegen returns the first.
        .assume_noalias => operands.len == 2 and ValueType.eql(result, operands[0]) and
            ValueType.eql(operands[1], .{ .integer = "usize" }),
        // `forget_unchecked` consumes its operand at the ownership layer, but
        // deliberately has no runtime release action.  The executable body
        // still carries the operand so both mechanical renderers must evaluate
        // it exactly once before discarding the resulting value.
        .forget_unchecked => operands.len == 1 and result == .void,
        .dma_cache_clean, .dma_cache_invalidate => operands.len == 0 and result == .void,
        .dma_addr => operands.len == 0 and switch (result) {
            .address => |class| class == .dma_addr,
            else => false,
        },
        .dma_as_slice => operands.len == 0 and switch (result) {
            .pointer => |shape| shape.kind == .slice and shape.mutability == .mut,
            .slice => true,
            else => false,
        },
        .va_start => operands.len == 0 and result == .value,
        .va_arg => operands.len == 0 and executableVaArgPayloadType(result),
        .va_end => operands.len == 0 and result == .void,
        .cpu_pause, .fence_full, .fence_release, .fence_acquire => operands.len == 0 and result == .void,
        else => false,
    };
}

pub fn executableVaArgPayloadType(ty: ValueType) bool {
    if (ExecutableCastKind.integerInfo(ty)) |info| return info.bits == 32 or info.bits == 64;
    return switch (ty) {
        .float => |name| std.mem.eql(u8, name, "f64"),
        .pointer, .nullable_pointer => |shape| shape.kind != .slice,
        .cstr, .address => true,
        else => false,
    };
}

fn executableSliceElementName(ty: ValueType) ?[]const u8 {
    return switch (ty) {
        .pointer => |shape| if (shape.kind == .slice) shape.child else null,
        .slice => |child| child,
        else => null,
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
        .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .declassify, .forget_unchecked, .cpu_pause => true,
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
                .cstr => true,
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
            .integer => |name| if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) 1 else if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) 2 else if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) 4 else if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) 8 else if (std.mem.eql(u8, name, "u128") or std.mem.eql(u8, name, "i128")) 16 else null,
            .domain_integer => |shape| if (std.mem.eql(u8, shape.child, "u8") or std.mem.eql(u8, shape.child, "i8")) 1 else if (std.mem.eql(u8, shape.child, "u16") or std.mem.eql(u8, shape.child, "i16")) 2 else if (std.mem.eql(u8, shape.child, "u32") or std.mem.eql(u8, shape.child, "i32")) 4 else if (std.mem.eql(u8, shape.child, "u64") or std.mem.eql(u8, shape.child, "i64") or std.mem.eql(u8, shape.child, "usize") or std.mem.eql(u8, shape.child, "isize")) 8 else if (std.mem.eql(u8, shape.child, "u128") or std.mem.eql(u8, shape.child, "i128")) 16 else null,
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
        .array, .struct_, .tagged_union, .result, .nullable_value => 1,
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
    /// Decoded source bytes without the implicit trailing NUL. The body owns
    /// this slice through `ExecutableBody.owned_bytes`; renderers must encode
    /// these bytes mechanically and never parse source-literal spelling.
    string: []const u8,
    boolean: bool,
    null,
    uninit,
    void,
    enum_value: []const u8,
};

/// `uninit` is a local-storage policy, never a runtime value. One typed local
/// declaration must be the literal's sole consumer.
pub fn executableUninitLocalInitializer(body: *const ExecutableBody, expression: ExecutableExpression) bool {
    switch (expression.operation) {
        .literal => |literal| switch (literal) {
            .uninit => {},
            else => return false,
        },
        else => return false,
    }
    var owner_count: usize = 0;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |local| if (local.value != null and local.value.?.eql(expression.id)) {
            if (!ValueType.eql(local.ty, expression.result_ty) or !local.type_id.eql(expression.type_id)) return false;
            owner_count += 1;
        },
        else => {},
    };
    return owner_count == 1;
}

/// Generated aggregate state machines use `uninit` fields as zeroed dormant
/// storage, matching the established lowering contract. Keep that use
/// distinct from a standalone uninitialized local, whose declaration emits no
/// initializer at all.
pub fn executableUninitAggregateOperand(body: *const ExecutableBody, expression: ExecutableExpression) bool {
    switch (expression.operation) {
        .literal => |literal| if (literal != .uninit) return false,
        else => return false,
    }
    var owners: usize = 0;
    for (body.expressions) |candidate| switch (candidate.operation) {
        .struct_ => |aggregate| for (aggregate.operands[0..aggregate.operand_count]) |operand| {
            if (!operand.eql(expression.id)) continue;
            owners += 1;
            if (owners > 1) return false;
        },
        else => {},
    };
    return owners == 1;
}

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
        /// Store the first initialized payload into a source-level
        /// `MaybeUninit<T>` local. The wrapper is representation-erased to
        /// `T`; the local identity records that this access is authorized.
        maybe_uninit_write: struct {
            local: LocalId,
            value: ExprId,
        },
        /// Read the initialized payload from a source-level `MaybeUninit<T>`
        /// local after semantic analysis has discharged the initialization
        /// obligation.
        maybe_uninit_assume_init: struct {
            local: LocalId,
            /// Earlier write in the same CFG block that establishes the
            /// initialized state consumed by this load.
            initialized_by: ExprId,
        },
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
        /// Checked `mmio.map<T>(PAddr)?` lowered as one machine operation.
        /// The nullable source representation is a pointer niche, not the
        /// ordinary tagged value-optional layout. The operation therefore
        /// owns its exact Unwrap edge and yields the non-null MMIO address
        /// class directly.
        mmio_map_checked: struct {
            address: ExprId,
            unsafe_authorized: bool,
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
        /// one captured environment. The public call signature omits the
        /// erased environment parameter; codegen represents the value as
        /// `{ code, env }` and an indirect call supplies `env` first. Scalar
        /// captures use a producer-owned widening thunk selected by `code`.
        closure_bind: struct {
            /// Source function whose first parameter is the captured value.
            target: SymbolId,
            /// Callable stored in the closure code slot. This equals `target`
            /// for pointer captures and names a generated thunk for scalars.
            code: SymbolId,
            capture: ExprId,
            capture_encoding: ExecutableClosureCaptureEncoding,
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
            /// Compile-time index owned by `const_get`; absent for every other
            /// builtin kind. Keeping it on the verified operation prevents a
            /// renderer from reopening generic syntax to recover the index.
            const_index: ?usize = null,
            /// Canonical cursor storage for `va.arg` / `va.end`. `va.start`
            /// is tied to its local-init owner instead. Keeping a LocalId here
            /// avoids rebuilding `&ap` from call syntax in codegen.
            vararg_cursor: LocalId = .invalid,
            /// Canonical source buffer for DMA operations. The parameter owns
            /// its payload and coherence metadata; codegen never reopens the
            /// generic source type or call syntax.
            dma_buffer: LocalId = .invalid,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
        },
        indirect_call: struct {
            callee: ExprId,
            signature: ExecutableCallSignature,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
        },
        /// Virtual call through a checked `*dyn Trait` fat value. The trait
        /// identity, vtable slot, public method signature, and receiver place
        /// are semantic MIR data; neither backend may reopen member-call AST
        /// syntax to recover dispatch behavior.
        dyn_call: struct {
            receiver: PlaceId,
            trait_symbol: SymbolId,
            method_spelling: []const u8,
            method_index: usize,
            signature: ExecutableCallSignature,
            arguments: [max_executable_operands]ExprId = [_]ExprId{.invalid} ** max_executable_operands,
            argument_count: usize = 0,
            representation_source: ?SourcePoint = null,
            representation_span_id: SpanId = .invalid,
        },
        /// Construct a checked dynamic-trait fat value from a concrete
        /// pointer. The frontend has already selected the exact conformance;
        /// codegen only combines the data pointer with its vtable symbol.
        dyn_bind: struct {
            source: ExprId,
            trait_symbol: SymbolId,
            concrete_type_symbol: SymbolId,
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
        /// Construct one case of a nominal tagged union. `case_index` is the
        /// declaration-order discriminant owned by ExecutableTaggedUnionType.
        tagged_union_construct: struct { case_index: u32, payload: ?ExprId = null },
        /// Read the fixed u32 discriminant from a materialized tagged union.
        tagged_union_tag: ExprId,
        /// Read the payload for the case selected by the enclosing switch.
        tagged_union_payload: struct { operand: ExprId, case_index: u32 },
        /// Consume a nullable pointer after an exact `Unwrap` exceptional
        /// edge. The result is the same machine pointer with its non-null
        /// obligation made explicit; backends only encode this checked MIR
        /// operation and never rediscover source `?` syntax.
        try_unwrap: ExprId,
        /// Extract the success payload of a Result while returning the exact
        /// operand unchanged on its error edge. Admission requires the
        /// enclosing function to return the same canonical Result type.
        try_propagate: struct {
            operand: ExprId,
            error_cleanup_actions: []const CleanupActionId = &.{},
        },
        /// Propagate a Result error after converting it to the enclosing
        /// function's error type. The success payload remains the value of the
        /// expression; the error edge returns from the current function.
        try_map_error: struct {
            operand: ExprId,
            mapper: ExecutableTryErrorMapper,
            error_cleanup_actions: []const CleanupActionId = &.{},
        },
        result: struct {
            is_ok: bool,
            payload: ExprId,
        },
        array: struct {
            operands: []const ExprId = &.{},
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

/// Error-path mapping for Result propagation. Arbitrary source expressions
/// are deliberately excluded: a direct checked converter remains lazy on the
/// error edge, while a canonical literal is pure and may be materialized by a
/// backend without changing observable evaluation order.
pub const ExecutableTryErrorMapper = union(enum) {
    conversion: struct {
        callee: SymbolId,
        signature: ExecutableCallSignature,
    },
    literal: ExprId,
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

    pub fn eql(left: ExecutableCallSignature, right: ExecutableCallSignature) bool {
        if (left.parameter_count != right.parameter_count or left.has_environment != right.has_environment or
            !ValueType.eql(left.return_ty, right.return_ty) or
            !left.return_type_id.eql(right.return_type_id)) return false;
        for (left.parameter_types[0..left.parameter_count], right.parameter_types[0..right.parameter_count]) |left_ty, right_ty|
            if (!ValueType.eql(left_ty, right_ty)) return false;
        for (left.parameter_type_ids[0..left.parameter_count], right.parameter_type_ids[0..right.parameter_count]) |left_id, right_id|
            if (!left_id.eql(right_id)) return false;
        return true;
    }
};

/// Representation of a captured closure environment in the erased pointer
/// slot. Integer captures are limited by the producer to the qualified
/// pointer width and always call through a generated narrowing thunk.
pub const ExecutableClosureCaptureEncoding = enum {
    pointer,
    integer,
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
    /// Provenance of the pointer value at this exact place generation. This
    /// is meaningful for a dereference rooted at a local pointer. Keeping it
    /// on the canonical place prevents codegen from consulting the legacy
    /// string-keyed pointer-fact log to choose plain versus unordered access.
    pointer_provenance: PointerProvenance = .unknown,
    /// Statement that initialized a local pointer root before this projected
    /// access. Parameters and direct aggregate roots leave this invalid.
    root_initialization: InstId = .invalid,
    /// The root pointer was produced by unwrapping the present arm of an
    /// optional. This is an executable-MIR proof, not a request for codegen
    /// to rediscover source control flow. Complete bodies may set it only for
    /// locals whose initializer is an `optional_present` payload operation.
    root_nonnull_proven: bool = false,
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

pub fn executableLocalInitializedByOptionalPresentPayload(
    body: *const ExecutableBody,
    local_id: LocalId,
) bool {
    var initializer: ?ExprId = null;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local_id)) {
            if (initializer != null or init.mutable or init.value == null) return false;
            initializer = init.value.?;
        },
        else => {},
    };
    const id = initializer orelse return false;
    if (!id.isValid() or id.index() >= body.expressions.len) return false;
    const expression = body.expressions[id.index()];
    if (!expression.id.eql(id)) return false;
    return switch (expression.operation) {
        .variant_payload => |payload| payload.kind == .optional_present,
        else => false,
    };
}

/// A function symbol is represented as an opaque callable value in executable
/// MIR. Its explicit conversion to an integer is nevertheless a pointer cast,
/// and is admitted only when the operand identity resolves to a function.
pub fn executableFunctionPointerToIntegerCast(
    body: *const ExecutableBody,
    operand: ExecutableExpression,
    target_ty: ValueType,
    kind: ExecutableCastKind,
) bool {
    if (kind != .pointer_to_integer or operand.result_ty != .value or
        ExecutableCastKind.integerInfo(target_ty) == null) return false;
    const symbol_id = switch (operand.operation) {
        .symbol => |id| id,
        else => return false,
    };
    if (!symbol_id.isValid() or symbol_id.index() >= body.symbols.len) return false;
    const identity = body.symbols[symbol_id.index()];
    return identity.id.eql(symbol_id) and identity.kind == .function;
}

/// A deferred expression graph registered by one executable statement.
/// Roots are evaluated in source order only when a cleanup execution point
/// names this action; registration itself has no runtime effect.
pub const ExecutableCleanupAction = struct {
    id: CleanupActionId,
    registration: InstId,
    block_id: BlockId,
    source: SourcePoint,
    span_id: SpanId = .invalid,
    roots: []const ExprId = &.{},
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
        /// Update one boolean field in a packed-bits value.  The place names
        /// the complete scalar-backed aggregate; codegen performs one
        /// read-modify-write of its canonical storage representation.
        packed_field_store: struct {
            place: PlaceId,
            field_index: usize,
            value: ExprId,
            access: ExecutableMemoryAccess,
        },
        eval: ExprId,
        guard: struct { kind: enum { if_, while_, switch_, assert_ }, condition: ExprId },
        return_: ?ExprId,
        control_transfer: enum { break_, continue_ },
        opaque_asm: ExecutableOpaqueAsm,
        precise_asm: ExecutablePreciseAsm,
        defer_register: CleanupActionId,
        cleanup_run: []const CleanupActionId,
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
    /// Exact dynamic-trait identity for an opaque two-pointer parameter.
    /// Mutually exclusive with `callable_signature`.
    dyn_trait_symbol_id: SymbolId = .invalid,
    /// Payload identity when the source parameter is `atomic<T>` or a direct
    /// pointer to it. This is canonical frontend metadata, not a backend
    /// inference from pointer spelling.
    atomic_payload_ty: ValueType = .unknown,
    atomic_payload_type_id: TypeId = .invalid,
    /// Payload/coherence identity for an otherwise opaque `DmaBuf<T, mode>`
    /// parameter. Mutually exclusive with the other `.value` refinements.
    dma_payload_ty: ValueType = .unknown,
    dma_payload_type_id: TypeId = .invalid,
    dma_mode: ?ExecutableDmaBufferMode = null,
    source: SourcePoint,
    span_id: SpanId = .invalid,
};

pub const ExecutableLocalIdentity = struct {
    id: LocalId,
    spelling: []const u8,
    /// This local owns target-ABI `va_list` cursor storage. The ordinary
    /// `.value` type is intentionally insufficient to select that storage:
    /// callable and dynamic-trait values also use the opaque value class.
    is_va_list: bool = false,
    /// Exact dynamic-trait identity for an opaque local fat value.
    dyn_trait_symbol_id: SymbolId = .invalid,
    /// Payload identity for representation-erased `MaybeUninit<T>` storage.
    /// This is invalid for ordinary locals, preventing a renderer from
    /// treating an arbitrary uninitialized `T` as an admitted wrapper access.
    maybe_uninit_payload_type_id: TypeId = .invalid,
};

pub const ExecutableAggregateType = struct {
    type_id: TypeId,
    ty: ValueType,
    construction: AggregateConstructionKind,
    /// Transparent scalar storage for packed-bits declarations. Ordinary
    /// aggregates leave these fields invalid/unknown.
    storage_ty: ValueType = .unknown,
    storage_type_id: TypeId = .invalid,
    /// Exact byte extent/alignment for union storage. `storage_unit_size` is
    /// the LLVM array element width used by the module ABI: overlay unions
    /// retain byte storage, while native C unions encode their alignment in
    /// the integer element width. Non-union aggregates leave all three zero.
    storage_size: usize = 0,
    storage_alignment: usize = 0,
    storage_unit_size: usize = 0,
    is_overlay_union: bool = false,
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
    field_dyn_trait_symbols: [max_executable_operands]SymbolId = [_]SymbolId{.invalid} ** max_executable_operands,
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
    if (place.ty != .value or place.projection_count == 0) return null;
    var current_ty = place.root_ty;
    var projection_start: usize = 0;
    if (place.projections[0] == .deref) {
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return null,
        };
        if (pointer.kind != .single) return null;
        current_ty = .{ .struct_ = pointer.child };
        var found = false;
        for (aggregate_types) |aggregate| if (ValueType.eql(aggregate.ty, current_ty)) {
            found = true;
            break;
        };
        if (!found) return null;
        projection_start = 1;
    }
    for (place.projections[projection_start..place.projection_count], projection_start..) |projection, ordinal| {
        var aggregate: ?ExecutableAggregateType = null;
        for (aggregate_types) |candidate| if (ValueType.eql(candidate.ty, current_ty)) {
            aggregate = candidate;
            break;
        };
        const shape = aggregate orelse return null;
        const field_index = switch (projection) {
            .field => |index| index,
            .index => |index| if (index.kind == .fixed_array and index.bound != null and
                shape.array_length != null and shape.array_length.? == index.bound.?) 0 else return null,
            .deref => return null,
        };
        if (field_index >= shape.field_count) return null;
        const last = ordinal + 1 == place.projection_count;
        if (last) {
            if (shape.field_types[field_index] != .value) return null;
            return shape.field_callable_signatures[field_index];
        }
        current_ty = shape.field_types[field_index];
    }
    return null;
}

/// Resolve the exact trait carried by a dynamic receiver place. This first
/// slice deliberately admits direct dynamic parameters and fields projected
/// through a typed aggregate parameter; both shapes are fully described by
/// executable parameter/layout metadata.
pub fn executableDynTraitPlace(body: *const ExecutableBody, place: ExecutablePlace) ?SymbolId {
    if (place.storage != .ordinary or place.ty != .value or !place.type_id.isValid()) return null;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return null,
    };
    if (place.projection_count == 0) {
        for (body.parameters) |parameter| if (parameter.local.eql(local) and
            parameter.type_id.eql(place.type_id) and ValueType.eql(parameter.ty, place.ty) and
            parameter.dyn_trait_symbol_id.isValid()) return parameter.dyn_trait_symbol_id;
        for (body.locals) |identity| if (identity.id.eql(local) and identity.dyn_trait_symbol_id.isValid())
            return identity.dyn_trait_symbol_id;
        return null;
    }
    // A local aggregate carries the exact trait identity on its canonical
    // field layout. Resolve field projections directly instead of requiring
    // the root to be a pointer parameter.
    if (place.root_ty == .struct_) {
        var current: ?ExecutableAggregateType = null;
        for (body.aggregate_types) |candidate| if (candidate.type_id.eql(place.root_type_id) and
            ValueType.eql(candidate.ty, place.root_ty))
        {
            current = candidate;
            break;
        };
        var aggregate = current orelse return null;
        for (place.projections[0..place.projection_count], 0..) |projection, ordinal| {
            const field_index = switch (projection) {
                .field => |index| index,
                .deref, .index => return null,
            };
            if (field_index >= aggregate.field_count) return null;
            if (ordinal + 1 == place.projection_count)
                return if (aggregate.field_dyn_trait_symbols[field_index].isValid())
                    aggregate.field_dyn_trait_symbols[field_index]
                else
                    null;
            const next_id = aggregate.field_type_ids[field_index];
            var next: ?ExecutableAggregateType = null;
            for (body.aggregate_types) |candidate| if (candidate.type_id.eql(next_id)) {
                next = candidate;
                break;
            };
            aggregate = next orelse return null;
        }
        return null;
    }
    if (!executableParameterProjectedPlace(body, place, false)) return null;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return null,
    };
    var aggregate: ?ExecutableAggregateType = null;
    for (body.aggregate_types) |candidate| if (ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
        aggregate = candidate;
        break;
    };
    var current = aggregate orelse return null;
    for (place.projections[1..place.projection_count], 0..) |projection, ordinal| {
        const field_index = switch (projection) {
            .field => |index| index,
            .deref, .index => return null,
        };
        if (field_index >= current.field_count) return null;
        if (ordinal + 2 == place.projection_count)
            return if (current.field_dyn_trait_symbols[field_index].isValid()) current.field_dyn_trait_symbols[field_index] else null;
        const next_id = current.field_type_ids[field_index];
        var next: ?ExecutableAggregateType = null;
        for (body.aggregate_types) |candidate| if (candidate.type_id.eql(next_id)) {
            next = candidate;
            break;
        };
        current = next orelse return null;
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
    /// Preserves the declaration's explicit-representation choice for stable
    /// generated C helper names.  LLVM consumes only `repr_ty`.
    explicit_repr: bool = false,
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

pub const ExecutableTaggedUnionCase = struct {
    spelling: []const u8 = "",
    payload_ty: ValueType = .void,
    payload_type_id: TypeId = .invalid,
    has_payload: bool = false,
};

/// Canonical nominal identity, cases, and machine layout for a tagged union.
/// Both renderers consume this table; neither may reopen the AST declaration.
pub const ExecutableTaggedUnionType = struct {
    type_id: TypeId,
    ty: ValueType,
    tag_type_id: TypeId,
    cases: [max_executable_switch_cases]ExecutableTaggedUnionCase = [_]ExecutableTaggedUnionCase{.{}} ** max_executable_switch_cases,
    case_count: usize = 0,
    size: u64,
    alignment: u64,
    payload_size: u64,
    payload_alignment: u64,
    padding_size: u64,
    storage_count: u64,
    payload_field_index: u8,
};

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
    /// Cleanup stack live on entry to this block, in registration order.
    /// The verifier uses it to check joins and loop back-edges without
    /// reconstructing source scopes.
    entry_cleanup_stack: []const CleanupActionId = &.{},
    /// Actions executed immediately before this terminator, in LIFO order.
    exit_cleanup_actions: []const CleanupActionId = &.{},
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
    unsupported_targetless_array_literal,
    unsupported_struct_literal,
    unsupported_try,
    unsupported_block_expression,
    unsupported_unreachable_expression,
    unsupported_await,
    unsupported_opaque_asm,
    compile_time_statement,
};

pub const ExecutableBody = struct {
    complete: bool = true,
    incomplete_reason: ExecutableIncompleteReason = .none,
    /// Vararg cursor operations need the function's fixed-parameter boundary,
    /// but must not recover it from a declaration AST in either backend.
    is_variadic: bool = false,
    last_named_parameter: LocalId = .invalid,
    return_type_id: TypeId = .invalid,
    /// Exact dynamic-trait identity for an opaque two-pointer return value.
    return_dyn_trait_symbol_id: SymbolId = .invalid,
    parameters: []ExecutableParameter = &.{},
    locals: []ExecutableLocalIdentity = &.{},
    symbols: []SymbolIdentity = &.{},
    aggregate_types: []ExecutableAggregateType = &.{},
    enum_types: []ExecutableEnumType = &.{},
    result_types: []ExecutableResultType = &.{},
    tagged_union_types: []ExecutableTaggedUnionType = &.{},
    expressions: []ExecutableExpression = &.{},
    trap_edges: []ExecutableTrapEdge = &.{},
    places: []ExecutablePlace = &.{},
    statements: []ExecutableStatement = &.{},
    terminators: []ExecutableTerminator = &.{},
    cleanup_actions: []ExecutableCleanupAction = &.{},
    /// Allocations referenced by syntax-free executable operations. Keeping
    /// ownership on the body makes operation payloads self-contained without
    /// embedding AST nodes or source-literal spellings.
    owned_bytes: []const []const u8 = &.{},
    /// Variable-width operand lists owned by expression operations such as
    /// fixed-array construction. Keeping ownership here avoids an arbitrary
    /// language limit inherited from call/asm inline storage.
    owned_expr_id_slices: []const []const ExprId = &.{},
    owned_cleanup_action_id_slices: []const []const CleanupActionId = &.{},

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
        if (self.tagged_union_types.len != 0) allocator.free(self.tagged_union_types);
        if (self.expressions.len != 0) allocator.free(self.expressions);
        if (self.trap_edges.len != 0) allocator.free(self.trap_edges);
        if (self.places.len != 0) allocator.free(self.places);
        if (self.statements.len != 0) allocator.free(self.statements);
        if (self.terminators.len != 0) allocator.free(self.terminators);
        if (self.cleanup_actions.len != 0) allocator.free(self.cleanup_actions);
        for (self.owned_bytes) |bytes| allocator.free(bytes);
        if (self.owned_bytes.len != 0) allocator.free(self.owned_bytes);
        for (self.owned_expr_id_slices) |ids| allocator.free(ids);
        if (self.owned_expr_id_slices.len != 0) allocator.free(self.owned_expr_id_slices);
        for (self.owned_cleanup_action_id_slices) |ids| allocator.free(ids);
        if (self.owned_cleanup_action_id_slices.len != 0) allocator.free(self.owned_cleanup_action_id_slices);
        self.* = .{};
    }
};

pub fn executableVaListLocal(body: *const ExecutableBody, id: LocalId) bool {
    return id.isValid() and id.index() < body.locals.len and
        body.locals[id.index()].id.eql(id) and body.locals[id.index()].is_va_list;
}

pub fn executableDmaBufferParameter(body: *const ExecutableBody, id: LocalId) ?ExecutableParameter {
    for (body.parameters) |parameter| {
        if (!parameter.local.eql(id)) continue;
        if (parameter.ty != .value or parameter.dma_mode == null or
            parameter.dma_payload_ty == .unknown or !parameter.dma_payload_type_id.isValid()) return null;
        return parameter;
    }
    return null;
}

pub fn executableVaStartLocal(body: *const ExecutableBody, expression: ExprId) ?LocalId {
    if (!expression.isValid() or expression.index() >= body.expressions.len) return null;
    const value = body.expressions[expression.index()];
    if (!value.id.eql(expression) or value.operation != .builtin_call or
        value.operation.builtin_call.kind != .va_start or
        !value.owner_statement.isValid() or value.owner_statement.index() >= body.statements.len)
        return null;
    const statement = body.statements[value.owner_statement.index()];
    if (!statement.id.eql(value.owner_statement) or !statement.block_id.eql(value.block_id)) return null;
    const local = switch (statement.operation) {
        .local_init => |init| if (init.value != null and init.value.?.eql(expression)) init.local else return null,
        else => return null,
    };
    return if (executableVaListLocal(body, local)) local else null;
}

/// Validate the representation-erased storage backing a canonical
/// `MaybeUninit<T>` operation. The source wrapper is admitted once by the
/// frontend and recorded on the local identity; codegen only sees `T`.
pub fn executableMaybeUninitLocal(
    body: *const ExecutableBody,
    local_id: LocalId,
    payload_ty: ValueType,
    payload_type_id: TypeId,
) bool {
    if (!local_id.isValid() or local_id.index() >= body.locals.len or !payload_type_id.isValid()) return false;
    const identity = body.locals[local_id.index()];
    if (!identity.id.eql(local_id) or !identity.maybe_uninit_payload_type_id.eql(payload_type_id)) return false;

    var declarations: usize = 0;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local_id)) {
            if (!ValueType.eql(init.ty, payload_ty) or !init.type_id.eql(payload_type_id) or init.value != null) return false;
            declarations += 1;
        },
        else => {},
    };
    return declarations == 1;
}

/// A canonical MMIO base is either a function parameter or a local storage
/// generation whose checked type is `MmioPtr<T>`. The pointee layout and field
/// offset are already resolved by the producer; renderers only need the
/// address-valued local identity.
pub fn executableMmioBase(body: *const ExecutableBody, local: LocalId) bool {
    for (body.parameters) |parameter| if (parameter.local.eql(local)) return switch (parameter.ty) {
        .address => |class| class == .mmio_ptr and parameter.type_id.isValid(),
        else => false,
    };
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) return switch (init.ty) {
            .address => |class| class == .mmio_ptr and init.type_id.isValid(),
            else => false,
        },
        else => {},
    };
    return false;
}

/// Recognize a direct `atomic<T>` parameter place. Atomic wrappers are opaque
/// source types, so their executable parameter identity carries the canonical
/// payload type separately from the `.value` wrapper representation.
pub fn executableDirectAtomicParameterPlace(parameters: []const ExecutableParameter, place: ExecutablePlace) bool {
    if (place.storage != .atomic or place.projection_count != 0 or
        !place.root_type_id.isValid() or !place.type_id.isValid()) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    for (parameters) |parameter| if (parameter.local.eql(local)) {
        return parameter.ty == .value and ValueType.eql(parameter.atomic_payload_ty, place.root_ty) and
            parameter.atomic_payload_type_id.eql(place.root_type_id) and ValueType.eql(parameter.atomic_payload_ty, place.ty) and
            parameter.atomic_payload_type_id.eql(place.type_id);
    };
    return false;
}

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
        (ExecutableMemoryAccess.scalarAlignment(place.ty) == null and
            executableAggregateCopyAlignment(place.ty) == null)) return false;
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

fn executableParameterPointerRoot(
    body: *const ExecutableBody,
    local: LocalId,
    pointer_ty: ValueType,
    pointer_type_id: TypeId,
) bool {
    for (body.parameters) |parameter| if (parameter.local.eql(local)) {
        return parameter.type_id.eql(pointer_type_id) and ValueType.eql(parameter.ty, pointer_ty);
    };
    var initializer: ?ExprId = null;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) {
            if (initializer != null or init.mutable or init.value == null or
                !init.type_id.eql(pointer_type_id) or !ValueType.eql(init.ty, pointer_ty)) return false;
            initializer = init.value.?;
        },
        .store => |store| if (store.place.isValid() and store.place.index() < body.places.len) {
            const target = body.places[store.place.index()];
            if (target.projection_count == 0) switch (target.root) {
                .local => |stored| if (stored.eql(local)) return false,
                .symbol, .value => {},
            };
        },
        else => {},
    };
    const value_id = initializer orelse return false;
    if (!value_id.isValid() or value_id.index() >= body.expressions.len) return false;
    const value = body.expressions[value_id.index()];
    if (!value.id.eql(value_id) or !ValueType.eql(value.result_ty, pointer_ty) or
        !value.type_id.eql(pointer_type_id)) return false;
    const source = switch (value.operation) {
        .representation_check => |check| blk: {
            if (check.kind != .nonnull_pointer or !check.operand.isValid() or check.operand.index() >= body.expressions.len)
                return false;
            const operand = body.expressions[check.operand.index()];
            if (!operand.id.eql(check.operand) or !ValueType.eql(operand.result_ty, pointer_ty) or
                !operand.type_id.eql(pointer_type_id)) return false;
            break :blk operand;
        },
        else => value,
    };
    const source_local = switch (source.operation) {
        .local => |id| id,
        else => return false,
    };
    for (body.parameters) |parameter| if (parameter.local.eql(source_local)) {
        return parameter.type_id.eql(pointer_type_id) and ValueType.eql(parameter.ty, pointer_ty);
    };
    return false;
}

/// Recognize a field selected through a single-pointer parameter (`p->field`)
/// or an immutable local initialized exactly once from that parameter. Unlike
/// scalar-access predicates, this also admits aggregate fields so an address-
/// of operation can pass them to another function without loading or copying
/// the aggregate.
pub fn executableParameterFieldPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count != 2 or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        place.projections[0] != .deref) return false;
    const field_index = switch (place.projections[1]) {
        .field => |index| index,
        .deref, .index => return false,
    };
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    if (!executableParameterPointerRoot(body, local, place.root_ty, place.root_type_id)) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single or (require_mutable and pointer.mutability != .mut)) return false;
    var aggregate: ?ExecutableAggregateType = null;
    for (body.aggregate_types) |candidate| if (ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
        aggregate = candidate;
        break;
    };
    const shape = aggregate orelse return false;
    return (shape.construction == .declared_struct or shape.construction == .c_union) and
        field_index < shape.field_count and shape.field_type_ids[field_index].eql(place.type_id) and
        ValueType.eql(shape.field_types[field_index], place.ty);
}

/// Recognize a field projection rooted at a typed single-pointer local.  The
/// local may be a parameter, an immutable alias of one, or an ordinary local
/// pointer generation.  The operation's representation edge proves that the
/// current pointer value is non-null; this predicate proves only the canonical
/// local/type/projection shape.  The complete projection is represented by the
/// place (`p.*.outer.inner`), so consumers never recover aggregate nesting from
/// source syntax.
pub fn executableParameterProjectedPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count < 2 or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        place.projections[0] != .deref) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    const parameter_root = executableParameterPointerRoot(body, local, place.root_ty, place.root_type_id);
    const typed_root = if (parameter_root)
        !place.root_initialization.isValid()
    else
        executableLocalPointerInitialization(body, place, local);
    if (!typed_root) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single or (require_mutable and pointer.mutability != .mut)) return false;

    var current_ty: ValueType = .{ .struct_ = pointer.child };
    var current_type_id: ?TypeId = null;
    for (body.aggregate_types) |candidate| if (ValueType.eql(candidate.ty, current_ty)) {
        current_type_id = candidate.type_id;
        break;
    };
    var type_id = current_type_id orelse return false;
    for (place.projections[1..place.projection_count]) |projection| {
        const field_index = switch (projection) {
            .field => |index| index,
            .deref, .index => return false,
        };
        var aggregate: ?ExecutableAggregateType = null;
        for (body.aggregate_types) |candidate| if (candidate.type_id.eql(type_id)) {
            aggregate = candidate;
            break;
        };
        const shape = aggregate orelse return false;
        if ((shape.construction != .declared_struct and shape.construction != .c_union) or
            !ValueType.eql(shape.ty, current_ty) or field_index >= shape.field_count) return false;
        current_ty = shape.field_types[field_index];
        type_id = shape.field_type_ids[field_index];
    }
    return type_id.eql(place.type_id) and ValueType.eql(current_ty, place.ty);
}

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

/// Check an aggregate dereference through a typed local pointer. The pointer
/// value is guarded at the dereference, so no source-level provenance recovery
/// is required; the local generation, pointer type, and aggregate result type
/// are all canonical executable-body facts.
pub fn executableGuardedLocalAggregateDerefPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        executableAggregateCopyAlignment(place.ty) == null) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    if (!local.isValid() or local.index() >= body.locals.len or !body.locals[local.index()].id.eql(local)) return false;

    var root_matches = false;
    for (body.parameters) |parameter| if (parameter.local.eql(local)) {
        root_matches = parameter.type_id.eql(place.root_type_id) and ValueType.eql(parameter.ty, place.root_ty);
        break;
    };
    if (!root_matches) for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) {
            root_matches = init.value != null and init.type_id.eql(place.root_type_id) and ValueType.eql(init.ty, place.root_ty);
            break;
        },
        else => {},
    };
    if (!root_matches) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single or (require_mutable and pointer.mutability != .mut)) return false;
    return executableRaceAggregateTypeSupported(body, place.type_id, place.ty);
}

/// Check a scalar dereference through a typed local pointer value. Unlike an
/// address alias, the local stores the pointer itself (for example `let q =
/// p; q.* = value`). The representation edge guards that pointer generation;
/// no source-name alias reconstruction is involved.
pub fn executableGuardedLocalScalarDerefPlace(
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
    if (!local.isValid() or local.index() >= body.locals.len or !body.locals[local.index()].id.eql(local)) return false;

    var root_matches = false;
    for (body.parameters) |parameter| if (parameter.local.eql(local)) {
        root_matches = parameter.type_id.eql(place.root_type_id) and ValueType.eql(parameter.ty, place.root_ty);
        break;
    };
    if (!root_matches) for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(local)) {
            root_matches = init.value != null and init.type_id.eql(place.root_type_id) and ValueType.eql(init.ty, place.root_ty);
            break;
        },
        else => {},
    };
    if (!root_matches) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single and (!require_mutable or pointer.mutability == .mut) and
        std.mem.eql(u8, pointer.child, place.ty.name());
}

/// Whether an aggregate can be lowered as a deterministic sequence of
/// race-unordered scalar leaf accesses. C unions intentionally fail closed:
/// their active storage member is not represented by ordinary field recursion.
pub fn executableRaceAggregateTypeSupported(body: *const ExecutableBody, type_id: TypeId, ty: ValueType) bool {
    return executableRaceAggregateTypeSupportedDepth(body, type_id, ty, 0);
}

/// Packed-bit and union values keep their single-storage representation. They
/// cannot be decomposed into independent race-unordered fields without
/// changing active-member or bitfield semantics.
pub fn executableAggregateRequiresPlainAccess(body: *const ExecutableBody, type_id: TypeId, ty: ValueType) bool {
    if (executableAggregateCopyAlignment(ty) == null or !type_id.isValid()) return false;
    // Result is a tagged aggregate. Splitting a mutable global read into
    // independent unordered tag/payload atomics could observe a value that
    // never existed, so it has the same indivisible-copy policy as a tagged
    // union rather than the field-wise policy of an ordinary struct.
    if (ty == .result) for (body.result_types) |shape|
        if (shape.type_id.eql(type_id) and ValueType.eql(shape.ty, ty)) return true;
    for (body.tagged_union_types) |shape| if (shape.type_id.eql(type_id) and ValueType.eql(shape.ty, ty)) return true;
    for (body.aggregate_types) |shape| {
        if (!shape.type_id.eql(type_id) or !ValueType.eql(shape.ty, ty)) continue;
        return shape.construction == .packed_bits or shape.construction == .c_union;
    }
    return false;
}

fn executableRaceAggregateTypeSupportedDepth(body: *const ExecutableBody, type_id: TypeId, ty: ValueType, depth: usize) bool {
    if (depth >= max_executable_projections) return false;
    if (executableAggregateCopyAlignment(ty) == null)
        return executableMemoryAlignment(body.enum_types, ty) != null;
    var aggregate: ?ExecutableAggregateType = null;
    for (body.aggregate_types) |candidate| if (candidate.type_id.eql(type_id)) {
        aggregate = candidate;
        break;
    };
    const shape = aggregate orelse return false;
    if (shape.construction != .declared_struct or !ValueType.eql(shape.ty, ty) or shape.field_count == 0) return false;
    const count: usize = if (shape.array_length != null) 1 else shape.field_count;
    for (shape.field_types[0..count], shape.field_type_ids[0..count]) |field_ty, field_type_id| {
        if (!executableRaceAggregateTypeSupportedDepth(body, field_type_id, field_ty, depth + 1)) return false;
    }
    return true;
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

/// Select the checked memory class for an indirect place. Pointer provenance
/// belongs to the canonical place generation; the legacy source-fact log is
/// not a codegen input. Address aliases use their canonical target place, and
/// every unresolved pointer remains conservatively race-unordered.
pub fn executablePointerDerefAccessKind(
    body: *const ExecutableBody,
    place: ExecutablePlace,
) ?ExecutableMemoryAccessKind {
    if (place.storage != .ordinary or place.projection_count == 0) return null;
    switch (place.pointer_provenance) {
        .local_storage => return .plain,
        .global_storage => return .race_unordered,
        .unknown => {},
    }
    const target_id = executableLocalAddressDerefTarget(body, place, false) orelse return .race_unordered;
    if (!target_id.isValid() or target_id.index() >= body.places.len) return null;
    return switch (body.places[target_id.index()].root) {
        .local => .plain,
        .symbol => |id| if (id.isValid() and id.index() < body.symbols.len and body.symbols[id.index()].id.eql(id))
            if (body.symbols[id.index()].mutable) .race_unordered else .plain
        else
            null,
        .value => .race_unordered,
    };
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

pub const ExecutableFixedArrayIndexPlace = struct {
    first_index: @FieldType(ExecutablePlace.Projection, "index"),
    /// The place starts at a checked single-pointer parameter and its first
    /// projection dereferences that parameter.  Consumers must preserve the
    /// representation guard before walking the remaining field/index chain.
    parameter_pointee: bool,
    /// The same checked pointer projection rooted in an addressable local.
    /// Its initialization witness is carried by `place.root_initialization`.
    local_pointee: bool,

    pub fn indirectPointee(self: ExecutableFixedArrayIndexPlace) bool {
        return self.parameter_pointee or self.local_pointee;
    }
};

fn executableLocalPointerInitialization(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    local_id: LocalId,
) bool {
    if (!place.root_initialization.isValid() or place.root_initialization.index() >= body.statements.len) return false;
    const witness = body.statements[place.root_initialization.index()];
    if (!witness.id.eql(place.root_initialization)) return false;
    return switch (witness.operation) {
        .local_init => |init| init.local.eql(local_id) and init.value != null and
            ValueType.eql(init.ty, place.root_ty),
        .store => |store| initialized: {
            if (!ValueType.eql(store.ty, place.root_ty) or
                !store.place.isValid() or store.place.index() >= body.places.len or
                !store.value.isValid() or store.value.index() >= body.expressions.len) break :initialized false;
            const target = body.places[store.place.index()];
            const value = body.expressions[store.value.index()];
            break :initialized target.id.eql(store.place) and target.root == .local and
                target.root.local.eql(local_id) and target.projection_count == 0 and
                value.id.eql(store.value) and ValueType.eql(value.result_ty, place.root_ty) and
                value.type_id.eql(place.root_type_id);
        },
        else => false,
    };
}

/// Validate a typed projection chain containing at least one fixed-array
/// index. Every index and field advances through the canonical aggregate
/// table. A single leading dereference is admitted only for a typed pointer
/// parameter; it is reported explicitly so consumers cannot confuse the
/// parameter value with addressable local storage. Producer, verifier and
/// both renderers share this predicate so nested bounds, representation
/// guards, interleaved fields and element identity cannot drift.
pub fn executableFixedArrayIndexPlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
) ?ExecutableFixedArrayIndexPlace {
    if (place.storage != .ordinary or place.projection_count == 0 or
        !place.root_type_id.isValid() or !place.type_id.isValid()) return null;
    var current_ty = place.root_ty;
    var current_type_id = place.root_type_id;
    var projection_start: usize = 0;
    var parameter_pointee = false;
    var local_pointee = false;
    if (place.projections[0] == .deref) {
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return null,
        };
        var parameter: ?ExecutableParameter = null;
        for (body.parameters) |candidate| if (candidate.local.eql(local_id)) {
            parameter = candidate;
            break;
        };
        if (parameter) |root| {
            if (!root.type_id.eql(place.root_type_id) or !ValueType.eql(root.ty, place.root_ty) or
                place.root_initialization.isValid()) return null;
            parameter_pointee = true;
        } else {
            if (!executableLocalPointerInitialization(body, place, local_id)) return null;
            local_pointee = true;
        }
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return null,
        };
        if (pointer.kind != .single) return null;
        var pointee: ?ExecutableAggregateType = null;
        for (body.aggregate_types) |candidate| if (ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
            pointee = candidate;
            break;
        };
        const aggregate = pointee orelse return null;
        if (aggregate.construction != .declared_struct and aggregate.construction != .c_union) return null;
        current_ty = aggregate.ty;
        current_type_id = aggregate.type_id;
        projection_start = 1;
    }
    var first_index: ?@FieldType(ExecutablePlace.Projection, "index") = null;
    for (place.projections[projection_start..place.projection_count]) |item| switch (item) {
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
    return .{
        .first_index = first_index orelse return null,
        .parameter_pointee = parameter_pointee,
        .local_pointee = local_pointee,
    };
}

/// A fixed-array projection whose storage begins behind a checked pointer
/// parameter.  Such a place owns one representation edge in addition to its
/// checked index edges, and accesses external pointee storage rather than the
/// local parameter slot.
pub fn executableFixedArrayParameterPointeePlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    const indexed = executableFixedArrayIndexPlace(body, place) orelse return false;
    if (!indexed.parameter_pointee) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single and (!require_mutable or pointer.mutability == .mut);
}

pub fn executableFixedArrayIndirectPointeePlace(
    body: *const ExecutableBody,
    place: ExecutablePlace,
    require_mutable: bool,
) bool {
    const indexed = executableFixedArrayIndexPlace(body, place) orelse return false;
    if (!indexed.indirectPointee()) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single and (!require_mutable or pointer.mutability == .mut);
}

pub fn executableFixedArrayCheckedProjectionCount(place: ExecutablePlace) usize {
    var count: usize = 0;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| count += @intFromBool(index.kind == .fixed_array and index.checked),
        .field, .deref => {},
    };
    return count;
}

/// A fixed-array place may take the address of an element in a direct-call
/// result. The call value is materialized once by each renderer before the
/// projection is addressed; arbitrary computed aggregate roots remain closed.
pub fn executableFixedArrayCallResultRoot(body: *const ExecutableBody, place: ExecutablePlace) bool {
    const root_id = switch (place.root) {
        .value => |id| id,
        .local, .symbol => return false,
    };
    if (!root_id.isValid() or root_id.index() >= body.expressions.len) return false;
    const root = body.expressions[root_id.index()];
    if (!root.id.eql(root_id) or !root.type_id.eql(place.root_type_id) or
        !ValueType.eql(root.result_ty, place.root_ty)) return false;
    return root.operation == .direct_call and std.meta.activeTag(root.result_ty) == .array;
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

/// Return whether a slice-index place is rooted in the canonical checked
/// slice value. The representation-check expression owns the slice validity
/// trap; the load/store/address operation rooted here owns only its bounds
/// edge.
pub fn executableCheckedSliceValueRoot(
    body: *const ExecutableBody,
    place: ExecutablePlace,
) bool {
    _ = executableSliceIndexPlace(body, place) orelse return false;
    const id = switch (place.root) {
        .value => |value| value,
        .local, .symbol => return false,
    };
    if (!id.isValid() or id.index() >= body.expressions.len) return false;
    const value = body.expressions[id.index()];
    if (!value.id.eql(id) or !ValueType.eql(value.result_ty, place.root_ty) or
        !value.type_id.eql(place.root_type_id)) return false;
    const check = switch (value.operation) {
        .representation_check => |operation| operation,
        else => return false,
    };
    return check.kind == .valid_slice;
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
    /// Sole source identity for the proved unchecked operation. Display
    /// coordinates are recovered from the owning function's span table.
    typed_span_id: SpanId = .invalid,
};

pub const BoundsFactKind = enum { index, slice };

pub const BoundsFact = struct {
    kind: BoundsFactKind,
    /// Sole source identity for the checked access. Display coordinates are
    /// recovered from the owning function's span table.
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
    /// The canonical target type identity. Integer facts deliberately do not
    /// duplicate its structural `ValueType`; consumers resolve it through the
    /// owning function's type-identity table.
    target_type_id: TypeId = .invalid,
    typed_span_id: SpanId = .invalid,
};

pub const FloatFact = struct {
    literal: []const u8,
    /// The canonical type identity. Float facts deliberately do not duplicate
    /// its structural `ValueType`; consumers resolve it through the owning
    /// function's type-identity table.
    target_type_id: TypeId = .invalid,
    typed_span_id: SpanId = .invalid,
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
    /// Sole source identity for this call-target fact. Display coordinates are
    /// recovered from the owning function's span table.
    typed_span_id: SpanId = .invalid,
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
    typed_value_id: ValueId = .invalid,
    /// Sole source identity for this representation-sensitive operation.
    /// Display coordinates are recovered from the owning function's span
    /// table.
    typed_span_id: SpanId = .invalid,
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
    kind: enum { unknown, function, global, trait, type_ } = .unknown,
    mutable: bool = false,
    /// Exact function-value shape when this symbol is used as a first-class
    /// callable rather than only as a direct-call target.
    callable_signature: ?ExecutableCallSignature = null,
    /// Exact dynamic-trait representation returned by a function symbol.
    return_dyn_trait_symbol_id: SymbolId = .invalid,
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
    typed_def_id: DefId = .invalid,
    typed_symbol_id: SymbolId = .invalid,
    typed_source_id: SourceId = .invalid,
    return_ty: ValueType,
    /// Module-owned recursive source type shape for the callable result.
    /// This is intentionally separate from executable-body TypeIds, which are
    /// local to a lowered function.
    signature_return_type_id: SignatureTypeId = .invalid,
    /// Exact callable representation for an otherwise opaque `.value`
    /// return. A closure is a two-pointer value; a plain function pointer is
    /// one pointer. Backends must not recover this distinction from syntax.
    return_callable_signature: ?ExecutableCallSignature = null,
    // Signature obligations are produced once as typed MIR facts. Consumers
    // must not reconstruct them by rescanning source declarations.
    param_count: usize = 0,
    param_types: []ValueType = &.{},
    signature_param_type_ids: []SignatureTypeId = &.{},
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
    float_facts: []FloatFact = &.{},
    const_get_facts: []ConstGetFact = &.{},
    call_target_facts: []CallTargetFact = &.{},
    bind_thunk_facts: []BindThunkFact = &.{},
    body_type_artifact_facts: []BodyTypeArtifactFact = &.{},
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
    def_id: DefId = .invalid,
    symbol_id: SymbolId,
    source_id: SourceId,
    body_id: BodyId,
    kind: CallableKind,
    return_ty: ValueType,
    signature_return_type_id: SignatureTypeId = .invalid,
    param_count: usize,
    /// Independently owned semantic signature. Keeping this separate from the
    /// MIR function storage lets admission detect equal-arity type drift.
    param_types: []const ValueType = &.{},
    signature_param_type_ids: []const SignatureTypeId = &.{},
    c_abi: bool,
    is_variadic: bool = false,
    no_lang_trap: bool,
    irq_context: bool,
};

/// Syntax-free module-global declaration facts. Initializer expressions are
/// represented by the referenced MIR body rather than copied into this table.
pub const CheckedGlobalFact = struct {
    symbol_id: SymbolId,
    source_id: SourceId,
    /// Syntax-free declaration origin used by C line directives and source
    /// maps when a global has no declaration-shaped codegen artifact.
    declaration_source: SourcePoint = .{ .line = 0, .column = 0 },
    ty: ValueType,
    /// Module-owned recursive declaration shape.  Global codegen must use
    /// this instead of retaining an AST TypeExpr in declaration artifacts.
    signature_type_id: SignatureTypeId = .invalid,
    /// Exact dynamic-trait representation when this otherwise opaque
    /// `.value` global is `*dyn Trait` (or its nullable form).  This keeps
    /// qualified-backend admission syntax-free.
    dyn_trait_symbol_id: SymbolId = .invalid,
    initializer_body_id: BodyId = .invalid,
    /// Codegen must consume this frontend-verified plan rather than recreate
    /// a scalar initializer from declaration syntax.
    has_initializer_plan: bool = false,
    is_const: bool,
    exported: bool,
    is_extern: bool,
};

/// Syntax-free transparent type-alias declaration. The target is interned in
/// the module-owned signature graph, so codegen never needs an alias AST
/// payload merely to resolve a nominal spelling.
pub const TypeAliasFact = struct {
    symbol_id: SymbolId,
    source_id: SourceId,
    target_type_id: SignatureTypeId,
};

/// One checked enum discriminant.  The spelling is presentation data for the
/// generated enumerator; identity of the enclosing enum always flows through
/// `EnumFact.symbol_id`.
pub const EnumCaseFact = struct {
    spelling: []const u8,
    negative: bool,
    magnitude: u128,
};

/// Syntax-free enum declaration ingress.  The enum name is resolved through
/// `symbol_id`, its representation through the module-owned signature graph,
/// and each case is already reduced to its checked integer value.  This keeps
/// C/LLVM from retaining an `ast.EnumDecl` merely to emit a nominal scalar.
pub const EnumFact = struct {
    symbol_id: SymbolId,
    source_id: SourceId,
    /// Checked runtime representation. The recursive signature shape remains
    /// the rendering source; this field lets admission reject a stale
    /// non-integer enum representation without reopening syntax.
    repr_ty: ValueType,
    repr_type_id: SignatureTypeId,
    is_open: bool,
    cases: []const EnumCaseFact,
};

/// One checked packed-bit field. Packed-bit fields are always boolean after
/// semantic checking; only their spelling and declaration order remain
/// relevant to code generation.
pub const PackedBitsFieldFact = struct {
    spelling: []const u8,
};

/// Syntax-free packed-bits declaration ingress. The representation and field
/// order have already been checked by the frontend. Backends may materialize
/// a narrow rendering view from this fact, but must not retain the source
/// declaration as an ingress payload.
pub const PackedBitsFact = struct {
    symbol_id: SymbolId,
    source_id: SourceId,
    repr_ty: ValueType,
    repr_type_id: SignatureTypeId,
    fields: []const PackedBitsFieldFact,
};

/// Syntax-free scalar value already evaluated by the frontend for a `const`
/// global initializer.  This deliberately excludes aggregates and enum tags:
/// their rendering still depends on transitional aggregate/type artifacts.
pub const ConstScalarValue = union(enum) {
    int: i128,
    uint: u128,
    boolean: bool,
    float: struct {
        bits: u64,
        width: u8,
    },

    pub fn isCompatibleWith(self: ConstScalarValue, ty: ValueType) bool {
        return switch (self) {
            .int => |value| integerConstValueFits(value, ty),
            .uint => |value| unsignedConstValueFits(value, ty),
            .boolean => ty == .bool,
            .float => |value| switch (ty) {
                .float => |name| (value.width == 32 and std.mem.eql(u8, name, "f32")) or
                    (value.width == 64 and std.mem.eql(u8, name, "f64")),
                else => false,
            },
        };
    }
};

fn integerConstValueFits(value: i128, ty: ValueType) bool {
    const info = executableIntegerStorageInfo(ty) orelse return false;
    if (!info.signed) return value >= 0 and unsignedConstValueFits(@intCast(value), ty);
    if (info.bits == 128) return true;
    if (info.bits == 0 or info.bits > 128) return false;
    const shift: std.math.Log2Int(i128) = @intCast(info.bits - 1);
    const minimum = -(@as(i128, 1) << shift);
    const maximum = (@as(i128, 1) << shift) - 1;
    return value >= minimum and value <= maximum;
}

fn unsignedConstValueFits(value: u128, ty: ValueType) bool {
    const info = executableIntegerStorageInfo(ty) orelse return false;
    if (info.bits == 0 or info.bits > 128) return false;
    if (info.signed) {
        if (info.bits == 128) return value <= @as(u128, @intCast(std.math.maxInt(i128)));
        const shift: std.math.Log2Int(u128) = @intCast(info.bits - 1);
        return value <= (@as(u128, 1) << shift) - 1;
    }
    if (info.bits == 128) return true;
    const shift: std.math.Log2Int(u128) = @intCast(info.bits);
    return value <= (@as(u128, 1) << shift) - 1;
}

/// Syntax-free global-initializer payloads admitted by the frontend. This
/// starts with folded scalar values and zero-initialized storage. Aggregate
/// literals and relocations still need an explicit recursive plan and remain
/// outside this representation.
pub const GlobalInitializerPlan = union(enum) {
    scalar: ConstScalarValue,
    zero,
};

/// A plan is keyed by its checked global identity, never source spelling.
/// Scalar plans additionally retain their checked initializer body; zero
/// plans intentionally have no body because they describe storage with no
/// source initializer.
pub const GlobalInitializerFact = struct {
    global_symbol_id: SymbolId,
    initializer_body_id: BodyId = .invalid,
    value_ty: ValueType,
    plan: GlobalInitializerPlan,

    pub fn scalarValue(self: GlobalInitializerFact) ConstScalarValue {
        return switch (self.plan) {
            .scalar => |value| value,
            .zero => unreachable,
        };
    }
};

pub fn valueTypeRequiresScalarGlobalInitializerFact(ty: ValueType) bool {
    return switch (ty) {
        .bool, .integer, .domain_integer, .float => true,
        else => false,
    };
}

pub const Module = struct {
    allocator: std.mem.Allocator,
    symbol_identities: []SymbolIdentity = &.{},
    source_identities: []SourceIdentity = &.{},
    signature_types: SignatureTypeTable = .{},
    checked_callables: []CheckedCallableFact = &.{},
    checked_globals: []CheckedGlobalFact = &.{},
    type_aliases: []TypeAliasFact = &.{},
    enums: []EnumFact = &.{},
    packed_bits: []PackedBitsFact = &.{},
    global_initializer_facts: []GlobalInitializerFact = &.{},
    functions: []Function,
    drop_glue_facts: []DropGlueFact = &.{},
    type_ownership_facts: []TypeOwnershipFact = &.{},
    aggregate_return_summaries: []AggregateReturnSummaryFact = &.{},
    aggregate_return_pointer_facts: []AggregateReturnPointerFact = &.{},

    pub fn globalInitializerFact(self: Module, body_id: BodyId) ?GlobalInitializerFact {
        if (!body_id.isValid()) return null;
        var found: ?GlobalInitializerFact = null;
        for (self.global_initializer_facts) |fact| {
            if (!fact.initializer_body_id.eql(body_id)) continue;
            if (found != null) return null;
            found = fact;
        }
        return found;
    }

    pub fn globalInitializerFactForGlobal(self: Module, global: CheckedGlobalFact) ?GlobalInitializerFact {
        if (!global.symbol_id.isValid()) return null;
        var found: ?GlobalInitializerFact = null;
        for (self.global_initializer_facts) |fact| {
            if (!fact.global_symbol_id.eql(global.symbol_id)) continue;
            if (found != null) return null;
            found = fact;
        }
        return found;
    }

    /// Returns a fully admitted syntax-free declaration plan.  Backends must
    /// use this gate rather than infer a missing initializer from AST syntax.
    pub fn checkedGlobalInitializer(self: Module, global: CheckedGlobalFact) ?GlobalInitializerFact {
        if (global.is_extern or !global.has_initializer_plan) return null;
        const fact = self.globalInitializerFactForGlobal(global) orelse return null;
        if (!ValueType.eql(global.ty, fact.value_ty)) return null;
        return switch (fact.plan) {
            .scalar => |value| if (global.initializer_body_id.isValid() and
                global.initializer_body_id.eql(fact.initializer_body_id) and
                value.isCompatibleWith(fact.value_ty)) fact else null,
            .zero => if (!global.initializer_body_id.isValid() and !fact.initializer_body_id.isValid()) fact else null,
        };
    }

    /// Returns the one scalar global plan that is complete enough for
    /// syntax-free declaration emission. This is intentionally stricter than
    /// `globalInitializerFact`: callers must not turn a stale, aggregate, or
    /// extern declaration into a codegen fast path.
    pub fn checkedScalarGlobal(self: Module, global: CheckedGlobalFact) ?GlobalInitializerFact {
        if (global.is_extern or !global.initializer_body_id.isValid() or !global.has_initializer_plan) return null;
        if (!valueTypeRequiresScalarGlobalInitializerFact(global.ty)) return null;
        const fact = self.checkedGlobalInitializer(global) orelse return null;
        return switch (fact.plan) {
            .scalar => fact,
            .zero => null,
        };
    }

    pub fn checkedZeroGlobal(self: Module, global: CheckedGlobalFact) ?GlobalInitializerFact {
        const fact = self.checkedGlobalInitializer(global) orelse return null;
        return switch (fact.plan) {
            .zero => fact,
            .scalar => null,
        };
    }

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
            if (function.float_facts.len != 0) self.allocator.free(function.float_facts);
            if (function.const_get_facts.len != 0) self.allocator.free(function.const_get_facts);
            if (function.call_target_facts.len != 0) self.allocator.free(function.call_target_facts);
            if (function.bind_thunk_facts.len != 0) self.allocator.free(function.bind_thunk_facts);
            if (function.body_type_artifact_facts.len != 0) self.allocator.free(function.body_type_artifact_facts);
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
            if (function.signature_param_type_ids.len != 0) self.allocator.free(function.signature_param_type_ids);
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
        self.signature_types.deinit(self.allocator);
        if (self.checked_callables.len != 0) {
            for (self.checked_callables) |checked| {
                if (checked.param_types.len != 0) self.allocator.free(checked.param_types);
                if (checked.signature_param_type_ids.len != 0) self.allocator.free(checked.signature_param_type_ids);
            }
            self.allocator.free(self.checked_callables);
        }
        if (self.checked_globals.len != 0) self.allocator.free(self.checked_globals);
        if (self.type_aliases.len != 0) self.allocator.free(self.type_aliases);
        for (self.enums) |enum_fact| if (enum_fact.cases.len != 0) self.allocator.free(enum_fact.cases);
        if (self.enums.len != 0) self.allocator.free(self.enums);
        for (self.packed_bits) |packed_bits_fact| if (packed_bits_fact.fields.len != 0) self.allocator.free(packed_bits_fact.fields);
        if (self.packed_bits.len != 0) self.allocator.free(self.packed_bits);
        if (self.global_initializer_facts.len != 0) self.allocator.free(self.global_initializer_facts);
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

fn pointerTypeText(mutability: TypeMutability) []const u8 {
    return switch (mutability) {
        .none => "*",
        .mut => "*mut",
        .@"const" => "*const",
    };
}

fn rawManyPointerTypeText(mutability: TypeMutability) []const u8 {
    return switch (mutability) {
        .none => "[*]",
        .mut => "[*]mut",
        .@"const" => "[*]const",
    };
}

fn sliceTypeText(mutability: TypeMutability) []const u8 {
    return switch (mutability) {
        .none => "[]",
        .mut => "[]mut",
        .@"const" => "[]const",
    };
}
