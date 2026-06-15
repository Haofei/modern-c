const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const numeric = @import("numeric.zig");
const parser = @import("parser.zig");

// Numeric-literal and integer-bounds primitives shared with `sema.zig` and `lower_c.zig`
// (see `numeric.zig`); aliased here so the existing call sites read unchanged.
const LiteralValue = numeric.LiteralValue;
const IntBounds = numeric.IntBounds;
const maxUnsigned = numeric.maxUnsigned;
const maxSigned = numeric.maxSigned;
const signedBounds = numeric.signedBounds;
const parseIntegerLiteral = numeric.parseIntegerLiteral;
const parseUsizeLiteral = numeric.parseUsizeLiteral;
const parseCharLiteral = numeric.parseCharLiteral;
const integerLiteralValue = numeric.integerLiteralValue;

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
    pointer: PointerShape,
    nullable_pointer: PointerShape,
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

    fn name(self: ValueType) []const u8 {
        return switch (self) {
            .void => "void",
            .never => "never",
            .bool => "bool",
            .value => "value",
            .integer => |n| n,
            .float => |n| n,
            .pointer => |shape| pointerShapeName(shape),
            .nullable_pointer => |shape| pointerShapeName(shape),
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

    fn name(self: Terminator) []const u8 {
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
    // OPT (annex E): operand source points of checks the optimizer proved dead and elided
    // (`--optimize`) — a constant in-range array index's `Bounds` check, or an unsigned
    // division by a non-zero literal's `DivideByZero` check. Source points are unique per
    // location, so each backend site matches only its own kind. The backends key off these to
    // skip the emitted runtime check. Empty unless optimization is on, so the MIR is unchanged.
    elided_bounds: []SourcePoint,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    functions: []Function,

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
            self.allocator.free(function.elided_bounds);
        }
        self.allocator.free(self.functions);
    }
};

const FunctionSummary = struct {
    no_lang_trap: bool,
    irq_context: bool,
    return_ty: ValueType,
    return_type_expr: ?ast.TypeExpr,
    params: []const ast.Param,
};

const EnumSummary = struct {
    is_open: bool,
    cases: []const ast.EnumCase,
    repr: ?ast.TypeExpr,
};

const StructSummary = struct {
    fields: []const ast.Field,
};

const UnionSummary = struct {
    cases: []const ast.UnionCase,
};

const PackedBitsSummary = struct {
    repr: ast.TypeExpr,
    fields: []const ast.Field,
};

const MirReflectEnv = struct {
    enums: *const std.StringHashMap(EnumSummary),
    structs: *const std.StringHashMap(StructSummary),
    unions: *const std.StringHashMap(UnionSummary),
    packed_bits: *const std.StringHashMap(PackedBitsSummary),
    aliases: *const std.StringHashMap(ast.TypeExpr),
};

// Options for the MIR build/verify pipeline. `optimize` enables the fact-gated
// optimizer passes (annex E); off by default, so the standard pipeline and every
// existing caller are byte-for-byte unchanged.
pub const BuildOptions = struct {
    optimize: bool = false,
};

pub fn build(allocator: std.mem.Allocator, module: ast.Module) !Module {
    return buildOpt(allocator, module, .{});
}

pub fn buildOpt(allocator: std.mem.Allocator, module: ast.Module, options: BuildOptions) !Module {
    var enums = std.StringHashMap(EnumSummary).init(allocator);
    defer enums.deinit();
    var structs = std.StringHashMap(StructSummary).init(allocator);
    defer structs.deinit();
    var unions = std.StringHashMap(UnionSummary).init(allocator);
    defer unions.deinit();
    var packed_bits = std.StringHashMap(PackedBitsSummary).init(allocator);
    defer packed_bits.deinit();
    var aliases = std.StringHashMap(ast.TypeExpr).init(allocator);
    defer aliases.deinit();

    for (module.decls) |decl| {
        switch (decl.kind) {
            .enum_decl => |enum_decl| try enums.put(enum_decl.name.text, .{ .is_open = enum_decl.is_open, .cases = enum_decl.cases, .repr = enum_decl.repr }),
            .struct_decl => |struct_decl| try structs.put(struct_decl.name.text, .{ .fields = struct_decl.fields }),
            .union_decl => |union_decl| try unions.put(union_decl.name.text, .{ .cases = union_decl.cases }),
            .overlay_union_decl => |overlay_union_decl| try structs.put(overlay_union_decl.name.text, .{ .fields = overlay_union_decl.fields }),
            .packed_bits_decl => |decl_packed_bits| try packed_bits.put(decl_packed_bits.name.text, .{ .repr = decl_packed_bits.repr, .fields = decl_packed_bits.fields }),
            .type_alias => |alias| try aliases.put(alias.name.text, alias.ty),
            else => {},
        }
    }

    var summaries = std.StringHashMap(FunctionSummary).init(allocator);
    defer summaries.deinit();
    var const_fns = std.StringHashMap(ast.FnDecl).init(allocator);
    defer const_fns.deinit();
    var const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator);
    defer eval.deinitConstGlobals(allocator, &const_globals);
    var globals = std.StringHashMap(ValueType).init(allocator);
    defer globals.deinit();
    var global_type_exprs = std.StringHashMap(ast.TypeExpr).init(allocator);
    defer global_type_exprs.deinit();

    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                try summaries.put(fn_decl.name.text, .{
                    .no_lang_trap = hasAttr(decl.attrs, "no_lang_trap"),
                    .irq_context = hasAttr(decl.attrs, "irq_context"),
                    .return_ty = if (fn_decl.return_type) |ty| valueTypeFromTypeAlias(ty, &enums, &structs, &packed_bits, &aliases) else .void,
                    .return_type_expr = fn_decl.return_type,
                    .params = fn_decl.params,
                });
                if (decl.kind == .fn_decl and fn_decl.is_const and !const_fns.contains(fn_decl.name.text)) try const_fns.put(fn_decl.name.text, fn_decl);
            },
            .global_decl => |global| {
                if (global.ty) |ty| {
                    try globals.put(global.name.text, valueTypeFromTypeAlias(ty, &enums, &structs, &packed_bits, &aliases));
                    try global_type_exprs.put(global.name.text, ty);
                }
            },
            else => {},
        }
    }

    var reflect_env = MirReflectEnv{
        .enums = &enums,
        .structs = &structs,
        .unions = &unions,
        .packed_bits = &packed_bits,
        .aliases = &aliases,
    };
    try eval.collectConstGlobalsWithOptions(allocator, module, &const_fns, &const_globals, .{
        .reflect = mirComptimeReflectThunk,
        .reflect_ctx = &reflect_env,
    });

    var functions: std.ArrayList(Function) = .empty;
    errdefer {
        for (functions.items) |function| freeFunction(allocator, function);
        functions.deinit(allocator);
    }

    for (module.decls) |decl| {
        switch (decl.kind) {
            .global_decl => |global| {
                if (global.ty) |ty| {
                    if (global.init) |initializer| {
                        var builder = try FunctionBuilder.initGlobal(allocator, global.name.text, ty, initializer.span, &summaries, &enums, &structs, &unions, &packed_bits, &aliases, &const_fns, &const_globals, &globals, &global_type_exprs);
                        builder.optimize = options.optimize;
                        errdefer builder.deinit();
                        try builder.buildGlobalInitializer(ty, initializer);
                        try functions.append(allocator, try builder.finish());
                    }
                }
            },
            .fn_decl, .extern_fn => |fn_decl| {
                if (fn_decl.body) |body| {
                    var builder = try FunctionBuilder.init(allocator, fn_decl, decl.attrs, &summaries, &enums, &structs, &unions, &packed_bits, &aliases, &const_fns, &const_globals, &globals, &global_type_exprs);
                    builder.optimize = options.optimize;
                    errdefer builder.deinit();
                    try builder.buildBody(body);
                    try functions.append(allocator, try builder.finish());
                } else if (std.meta.activeTag(decl.kind) == .extern_fn) {
                    try functions.append(allocator, .{
                        .name = fn_decl.name.text,
                        .return_ty = if (fn_decl.return_type) |ty| valueTypeFromTypeAlias(ty, &enums, &structs, &packed_bits, &aliases) else .void,
                        .no_lang_trap = hasAttr(decl.attrs, "no_lang_trap"),
                        .irq_context = hasAttr(decl.attrs, "irq_context"),
                        .blocks = try allocator.alloc(Block, 0),
                        .trap_edges = try allocator.alloc(TrapEdge, 0),
                        .contract_regions = try allocator.alloc(ContractRegion, 0),
                        .range_facts = try allocator.alloc(RangeFact, 0),
                        .elided_bounds = try allocator.alloc(SourcePoint, 0),
                    });
                }
            },
            else => {},
        }
    }

    return .{ .allocator = allocator, .functions = try functions.toOwnedSlice(allocator) };
}

pub fn appendDump(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    return appendDumpOpt(allocator, module, out, .{});
}

pub fn appendDumpOpt(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), options: BuildOptions) !void {
    var mir = try buildOpt(allocator, module, options);
    defer mir.deinit();

    for (mir.functions) |function| {
        try out.print(
            allocator,
            "mir function name={s} return={s} no_lang_trap={} irq_context={} blocks={} trap_edges={} contract_regions={} range_facts={}\n",
            .{ function.name, function.return_ty.name(), function.no_lang_trap, function.irq_context, function.blocks.len, function.trap_edges.len, function.contract_regions.len, function.range_facts.len },
        );
        for (function.contract_regions) |region| {
            try out.print(
                allocator,
                "mir contract_region fn={s} id={} kind={s} begin_line={} end_line={}\n",
                .{ function.name, region.id, region.kind, region.begin_line, region.end_line },
            );
        }
        for (function.blocks) |block| {
            try out.print(
                allocator,
                "mir block fn={s} id={} kind={s} terminator={s} successors=",
                .{ function.name, block.id, block.kind, block.terminator.name() },
            );
            for (block.successors, 0..) |successor, i| {
                if (i != 0) try out.append(allocator, ',');
                try out.print(allocator, "{}", .{successor});
            }
            try out.append(allocator, '\n');
            for (block.instructions) |instruction| {
                if (instruction.contract_region_id) |region_id| {
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} contract_region_id={} line={} column={}\n",
                        .{ function.name, block.id, @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), region_id, instruction.line, instruction.column },
                    );
                } else {
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} contract_region_id=none line={} column={}\n",
                        .{ function.name, block.id, @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), instruction.line, instruction.column },
                    );
                }
            }
        }
        for (function.trap_edges) |edge| {
            try out.print(
                allocator,
                "mir trap_edge fn={s} from={} trap_block={} kind={s} source={s} explicit=true line={} column={}\n",
                .{ function.name, edge.from_block, edge.trap_block, @tagName(edge.kind), @tagName(edge.source), edge.line, edge.column },
            );
        }
        for (function.range_facts) |fact| {
            try out.print(
                allocator,
                "mir range_fact fn={s} region_id={} target={s} op={s} left={s} right={s} result_type={s} assumption=no_overflow recorded=true line={} column={}\n",
                .{ function.name, fact.region_id, fact.target, fact.op, fact.left, fact.right, fact.result_ty.name(), fact.line, fact.column },
            );
        }
    }
}

pub fn appendVerificationFacts(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var mir = try build(allocator, module);
    defer mir.deinit();
    try appendVerificationFactsFromMir(allocator, mir, out);
}

pub fn appendVerificationFactsFromMir(allocator: std.mem.Allocator, mir: Module, out: *std.ArrayList(u8)) !void {
    for (mir.functions) |function| {
        if (functionFallsThrough(function)) |point| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=core finding=fallthrough line={} column={}\n",
                .{ function.name, point.line, point.column },
            );
        }
        if (cfgHasStructuralError(function)) |point| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=cfg finding=malformed_cfg line={} column={}\n",
                .{ function.name, point.line, point.column },
            );
        }
        for (function.trap_edges) |edge| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=trap finding=trap_edge detail={s} source={s} no_lang_trap={} line={} column={}\n",
                .{ function.name, @tagName(edge.kind), @tagName(edge.source), function.no_lang_trap, edge.line, edge.column },
            );
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .unchecked_assume) continue;
                try out.print(
                    allocator,
                    "mir verify fn={s} pass=unsafe finding=unchecked_assume detail={s} contract_region_id={s} line={} column={}\n",
                    .{ function.name, instruction.detail, if (instruction.contract_region_id == null) "none" else "some", instruction.line, instruction.column },
                );
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .unsafe_check) continue;
                try out.print(
                    allocator,
                    "mir verify fn={s} pass=unsafe finding=unsafe_required detail={s} line={} column={}\n",
                    .{ function.name, instruction.detail, instruction.line, instruction.column },
                );
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind == .address_deref) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=direct_deref class={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .address_conversion) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=address_class_mismatch source={s} target={s} line={} column={}\n",
                        .{ function.name, instruction.result_ty.name(), instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .address_operation) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=opaque_operation detail={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .mmio_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=mmio finding=access_forbidden op={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .representation_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=representation finding=representation_check type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .representation_use) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=representation finding=representation_use detail={s} type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .typed_load and representationCheckKind(instruction.result_ty) != null) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=representation finding=typed_load detail={s} type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .nullability_conversion) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=nullability finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .conversion_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=conversion finding={s} source_type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .aggregate_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=aggregate finding={s} type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .result_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=result finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .switch_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .assignment_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .arithmetic_domain_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (instruction.kind == .operator_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.line, instruction.column },
                    );
                }
                if (irqContextCallFinding(mir, function, instruction)) |finding| {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=context finding={s} detail={s} line={} column={}\n",
                        .{ function.name, irqContextFindingName(finding), instruction.detail, instruction.line, instruction.column },
                    );
                }
            }
        }
        for (function.range_facts) |fact| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=range finding=no_overflow_range target={s} op={s} left={s} right={s} region_id={} recorded=true line={} column={}\n",
                .{ function.name, fact.target, fact.op, fact.left, fact.right, fact.region_id, fact.line, fact.column },
            );
        }
    }
}

pub fn verify(allocator: std.mem.Allocator, module: ast.Module, reporter: *diagnostics.Reporter) !void {
    return verifyOpt(allocator, module, reporter, .{});
}

pub fn verifyOpt(allocator: std.mem.Allocator, module: ast.Module, reporter: *diagnostics.Reporter, options: BuildOptions) !void {
    var mir = try buildOpt(allocator, module, options);
    defer mir.deinit();
    try verifyBuiltMir(mir, reporter);
}

pub fn verifyBuiltMir(mir: Module, reporter: *diagnostics.Reporter) !void {
    for (mir.functions) |function| {
        verifyFunctionCfg(function, reporter);

        if (!isVoidLike(function.return_ty)) {
            if (functionFallsThrough(function)) |point| {
                const code = if (function.return_ty == .never) "E_NEVER_FALLTHROUGH" else "E_RETURN_MISSING";
                reporter.err(sourcePointSpan(point), "{s}: MIR verifier found function fallthrough before backend lowering", .{code});
            }
        }

        if (function.no_lang_trap) {
            for (function.trap_edges) |edge| {
                reporter.err(
                    sourcePointSpan(.{ .line = edge.line, .column = edge.column }),
                    "E_NO_LANG_TRAP_EDGE: MIR verifier found language trap edge {s}",
                    .{@tagName(edge.kind)},
                );
            }
        }

        for (function.blocks, 0..) |block, block_index| {
            for (block.instructions, 0..) |instruction, instruction_index| {
                if (instruction.kind == .unchecked_assume and !uncheckedAssumeHasMatchingContract(function, instruction)) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "E_UNCHECKED_OUTSIDE_CONTRACT: MIR verifier found unchecked optimizer assumption outside matching contract region",
                        .{},
                    );
                }
                if (instruction.kind == .unsafe_check) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "E_UNSAFE_REQUIRED: MIR verifier found unsafe machine effect outside unsafe context",
                        .{},
                    );
                }
                if (instruction.kind == .address_deref) {
                    const address_class = addressClassFromName(instruction.detail) orelse .paddr;
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found illegal direct dereference of {s}",
                        .{ addressDerefDiagnostic(address_class), instruction.detail },
                    );
                }
                if (instruction.kind == .address_conversion) {
                    const source_class = switch (instruction.result_ty) {
                        .address => |kind| kind,
                        else => .paddr,
                    };
                    const target_class = addressClassFromName(instruction.detail) orelse .paddr;
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid address-class conversion",
                        .{addressClassMismatchDiagnostic(target_class, source_class)},
                    );
                }
                if (instruction.kind == .address_operation) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "E_ADDRESS_CLASS_OPERATION: MIR verifier found illegal operation on opaque address class",
                        .{},
                    );
                }
                if (instruction.kind == .ffi_check) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found illegal c_void FFI operation",
                        .{ffiFindingDiagnostic(instruction.detail)},
                    );
                }
                if (instruction.kind == .usage_check) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid typed-resource operation",
                        .{usageFindingDiagnostic(instruction.detail)},
                    );
                }
                if (instruction.kind == .mmio_check) {
                    if (std.mem.eql(u8, instruction.detail, "direct_assign")) {
                        reporter.err(
                            sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                            "E_MMIO_DIRECT_ASSIGN: MIR verifier found direct assignment to an MMIO register",
                            .{},
                        );
                    } else {
                        reporter.err(
                            sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                            "E_MMIO_ACCESS_FORBIDDEN: MIR verifier found MMIO register access disallowed by Reg/RegBits mode",
                            .{},
                        );
                    }
                }
                if (isRepresentationSensitiveProducer(instruction) and !producerHasDominatingRepresentationCheck(block, instruction_index, instruction.result_ty)) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "E_REPRESENTATION_CHECK_MISSING: MIR verifier found representation-sensitive value use without dominating check",
                        .{},
                    );
                }
                if (isRepresentationSensitiveUse(instruction) and !try useHasDominatingRepresentationCheck(mir.allocator, function, block_index, instruction_index, instruction.result_ty)) {
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "E_REPRESENTATION_CHECK_MISSING: MIR verifier found representation-sensitive value use without dominating check",
                        .{},
                    );
                }
                if (instruction.kind == .nullability_conversion) {
                    const code = nullabilityDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid nullability conversion",
                        .{code},
                    );
                }
                if (instruction.kind == .conversion_check) {
                    const code = conversionDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid implicit conversion",
                        .{code},
                    );
                }
                if (instruction.kind == .aggregate_check) {
                    const code = aggregateDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid aggregate literal shape",
                        .{code},
                    );
                }
                if (instruction.kind == .result_check) {
                    if (resultFindingDiagnostic(instruction.detail)) |code| {
                        reporter.err(
                            sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                            "{s}: MIR verifier found invalid Result control-flow handling",
                            .{code},
                        );
                    }
                }
                if (instruction.kind == .switch_check) {
                    const code = switchFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid switch pattern coverage",
                        .{code},
                    );
                }
                if (instruction.kind == .assignment_check) {
                    const code = assignmentFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid assignment target",
                        .{code},
                    );
                }
                if (instruction.kind == .arithmetic_domain_check) {
                    const code = arithmeticDomainFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid arithmetic-domain operation",
                        .{code},
                    );
                }
                if (instruction.kind == .operator_check) {
                    const code = operatorFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR verifier found invalid operator operand",
                        .{code},
                    );
                }
                if (irqContextCallFinding(mir, function, instruction)) |finding| {
                    const code = irqContextDiagnostic(finding);
                    reporter.err(
                        sourcePointSpan(.{ .line = instruction.line, .column = instruction.column }),
                        "{s}: MIR context verifier rejected call in #[irq_context]",
                        .{code},
                    );
                }
            }
        }
    }
}

const MutableBlock = struct {
    id: usize,
    kind: []const u8,
    instructions: std.ArrayList(Instruction) = .empty,
    successors: std.ArrayList(usize) = .empty,
    terminator: Terminator = .fallthrough,
};

pub const SourcePoint = struct {
    line: usize,
    column: usize,
};

const ConversionContext = enum {
    return_,
    initializer,
    assignment,
    call_arg,
    condition,
};

const IrqContextCallFinding = enum {
    unproven_call,
    blocking,
};

const MmioRegisterAccess = enum {
    read,
    write,
    read_write,

    fn allowsRead(self: MmioRegisterAccess) bool {
        return self == .read or self == .read_write;
    }

    fn allowsWrite(self: MmioRegisterAccess) bool {
        return self == .write or self == .read_write;
    }
};

const MmioOperation = enum {
    read,
    write,
};

const MmioAccessInfo = struct {
    access: MmioRegisterAccess,
    op: MmioOperation,
};

const ArithmeticDomain = enum {
    wrap,
    sat,
    serial,
    counter,
};

const FunctionBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    return_ty: ValueType,
    return_type_expr: ?ast.TypeExpr,
    no_lang_trap: bool,
    irq_context: bool,
    summaries: *const std.StringHashMap(FunctionSummary),
    enums: *const std.StringHashMap(EnumSummary),
    structs: *const std.StringHashMap(StructSummary),
    unions: *const std.StringHashMap(UnionSummary),
    packed_bits: *const std.StringHashMap(PackedBitsSummary),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    const_fns: *const std.StringHashMap(ast.FnDecl),
    const_globals: *const std.StringHashMap(eval.ComptimeValue),
    globals: *const std.StringHashMap(ValueType),
    global_type_exprs: *const std.StringHashMap(ast.TypeExpr),
    blocks: std.ArrayList(MutableBlock),
    trap_edges: std.ArrayList(TrapEdge),
    contract_regions: std.ArrayList(ContractRegion),
    range_facts: std.ArrayList(RangeFact),
    elided_bounds: std.ArrayList(SourcePoint),
    local_types: std.StringHashMap(ValueType),
    local_type_exprs: std.StringHashMap(ast.TypeExpr),
    local_mutability: std.StringHashMap(bool),
    // Escape analysis (section 2): names declared as `let`/`var` locals (origin
    // .local), and names whose value is the address of local storage.
    let_local_names: std.StringHashMap(void),
    local_address_origin: std.StringHashMap(void),
    wrap_values: std.StringHashMap(void),
    sat_values: std.StringHashMap(void),
    break_targets: std.ArrayList(usize),
    continue_targets: std.ArrayList(usize),
    current: usize,
    // Fact-gated optimizer toggle (annex E); set from BuildOptions. Off by default so
    // the standard pipeline emits identical MIR.
    optimize: bool = false,
    active_contract: ?[]const u8 = null,
    active_contract_region_id: ?usize = null,
    active_unsafe: bool = false,
    assignment_target: ?[]const u8 = null,
    assignment_target_ty: ValueType = .unknown,
    expr_depth: usize = 0,
    semantic_expr_depth: usize = 0,
    next_contract_region_id: usize = 1,

    fn init(allocator: std.mem.Allocator, fn_decl: ast.FnDecl, attrs: []const ast.Attr, summaries: *const std.StringHashMap(FunctionSummary), enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), unions: *const std.StringHashMap(UnionSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr), const_fns: *const std.StringHashMap(ast.FnDecl), const_globals: *const std.StringHashMap(eval.ComptimeValue), globals: *const std.StringHashMap(ValueType), global_type_exprs: *const std.StringHashMap(ast.TypeExpr)) !FunctionBuilder {
        var blocks: std.ArrayList(MutableBlock) = .empty;
        errdefer blocks.deinit(allocator);
        try blocks.append(allocator, .{ .id = 0, .kind = "entry" });

        var builder = FunctionBuilder{
            .allocator = allocator,
            .name = fn_decl.name.text,
            .return_ty = if (fn_decl.return_type) |ty| valueTypeFromTypeAlias(ty, enums, structs, packed_bits, aliases) else .void,
            .return_type_expr = fn_decl.return_type,
            .no_lang_trap = hasAttr(attrs, "no_lang_trap"),
            .irq_context = hasAttr(attrs, "irq_context"),
            .summaries = summaries,
            .enums = enums,
            .structs = structs,
            .unions = unions,
            .packed_bits = packed_bits,
            .aliases = aliases,
            .const_fns = const_fns,
            .const_globals = const_globals,
            .globals = globals,
            .global_type_exprs = global_type_exprs,
            .blocks = blocks,
            .trap_edges = .empty,
            .contract_regions = .empty,
            .range_facts = .empty,
            .elided_bounds = .empty,
            .local_types = std.StringHashMap(ValueType).init(allocator),
            .local_type_exprs = std.StringHashMap(ast.TypeExpr).init(allocator),
            .local_mutability = std.StringHashMap(bool).init(allocator),
            .let_local_names = std.StringHashMap(void).init(allocator),
            .local_address_origin = std.StringHashMap(void).init(allocator),
            .wrap_values = std.StringHashMap(void).init(allocator),
            .sat_values = std.StringHashMap(void).init(allocator),
            .break_targets = .empty,
            .continue_targets = .empty,
            .current = 0,
        };
        for (fn_decl.params) |param| {
            const param_ty = valueTypeFromTypeAlias(param.ty, enums, structs, packed_bits, aliases);
            try builder.addInstr(.param, param.name.text, param_ty, param.name.span);
            try builder.local_types.put(param.name.text, param_ty);
            try builder.local_type_exprs.put(param.name.text, param.ty);
            try builder.local_mutability.put(param.name.text, false);
            if (isWrapTypeAlias(param.ty, aliases)) try builder.wrap_values.put(param.name.text, {});
            if (isSatTypeAlias(param.ty, aliases)) try builder.sat_values.put(param.name.text, {});
        }
        return builder;
    }

    fn initGlobal(allocator: std.mem.Allocator, name: []const u8, ty: ast.TypeExpr, span: ast.Span, summaries: *const std.StringHashMap(FunctionSummary), enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), unions: *const std.StringHashMap(UnionSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr), const_fns: *const std.StringHashMap(ast.FnDecl), const_globals: *const std.StringHashMap(eval.ComptimeValue), globals: *const std.StringHashMap(ValueType), global_type_exprs: *const std.StringHashMap(ast.TypeExpr)) !FunctionBuilder {
        var blocks: std.ArrayList(MutableBlock) = .empty;
        errdefer blocks.deinit(allocator);
        try blocks.append(allocator, .{ .id = 0, .kind = "global_init" });

        var builder = FunctionBuilder{
            .allocator = allocator,
            .name = name,
            .return_ty = .void,
            .return_type_expr = null,
            .no_lang_trap = false,
            .irq_context = false,
            .summaries = summaries,
            .enums = enums,
            .structs = structs,
            .unions = unions,
            .packed_bits = packed_bits,
            .aliases = aliases,
            .const_fns = const_fns,
            .const_globals = const_globals,
            .globals = globals,
            .global_type_exprs = global_type_exprs,
            .blocks = blocks,
            .trap_edges = .empty,
            .contract_regions = .empty,
            .range_facts = .empty,
            .elided_bounds = .empty,
            .local_types = std.StringHashMap(ValueType).init(allocator),
            .local_type_exprs = std.StringHashMap(ast.TypeExpr).init(allocator),
            .local_mutability = std.StringHashMap(bool).init(allocator),
            .let_local_names = std.StringHashMap(void).init(allocator),
            .local_address_origin = std.StringHashMap(void).init(allocator),
            .wrap_values = std.StringHashMap(void).init(allocator),
            .sat_values = std.StringHashMap(void).init(allocator),
            .break_targets = .empty,
            .continue_targets = .empty,
            .current = 0,
        };
        const value_ty = valueTypeFromTypeAlias(ty, enums, structs, packed_bits, aliases);
        try builder.addInstr(.local, name, value_ty, span);
        try builder.local_types.put(name, value_ty);
        try builder.local_type_exprs.put(name, ty);
        try builder.local_mutability.put(name, true);
        if (isWrapTypeAlias(ty, aliases)) try builder.wrap_values.put(name, {});
        if (isSatTypeAlias(ty, aliases)) try builder.sat_values.put(name, {});
        return builder;
    }

    fn deinit(self: *FunctionBuilder) void {
        for (self.blocks.items) |*block| {
            block.instructions.deinit(self.allocator);
            block.successors.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
        self.trap_edges.deinit(self.allocator);
        self.contract_regions.deinit(self.allocator);
        self.range_facts.deinit(self.allocator);
        self.elided_bounds.deinit(self.allocator);
        self.local_types.deinit();
        self.local_type_exprs.deinit();
        self.local_mutability.deinit();
        self.let_local_names.deinit();
        self.local_address_origin.deinit();
        self.wrap_values.deinit();
        self.sat_values.deinit();
        self.break_targets.deinit(self.allocator);
        self.continue_targets.deinit(self.allocator);
    }

    fn finish(self: *FunctionBuilder) !Function {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            for (blocks.items) |block| {
                self.allocator.free(block.instructions);
                self.allocator.free(block.successors);
            }
            blocks.deinit(self.allocator);
        }

        for (self.blocks.items) |*block| {
            try blocks.append(self.allocator, .{
                .id = block.id,
                .kind = block.kind,
                .instructions = try block.instructions.toOwnedSlice(self.allocator),
                .successors = try block.successors.toOwnedSlice(self.allocator),
                .terminator = block.terminator,
            });
        }

        const trap_edges = try self.trap_edges.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(trap_edges);
        const contract_regions = try self.contract_regions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(contract_regions);
        const range_facts = try self.range_facts.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(range_facts);
        const elided_bounds = try self.elided_bounds.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(elided_bounds);

        self.blocks.deinit(self.allocator);
        self.blocks = .empty;
        self.local_types.deinit();
        self.local_types = std.StringHashMap(ValueType).init(self.allocator);
        self.local_type_exprs.deinit();
        self.local_type_exprs = std.StringHashMap(ast.TypeExpr).init(self.allocator);
        self.local_mutability.deinit();
        self.local_mutability = std.StringHashMap(bool).init(self.allocator);
        self.let_local_names.deinit();
        self.let_local_names = std.StringHashMap(void).init(self.allocator);
        self.local_address_origin.deinit();
        self.local_address_origin = std.StringHashMap(void).init(self.allocator);
        self.wrap_values.deinit();
        self.wrap_values = std.StringHashMap(void).init(self.allocator);
        self.sat_values.deinit();
        self.sat_values = std.StringHashMap(void).init(self.allocator);
        self.break_targets.deinit(self.allocator);
        self.break_targets = .empty;
        self.continue_targets.deinit(self.allocator);
        self.continue_targets = .empty;

        return .{
            .name = self.name,
            .return_ty = self.return_ty,
            .no_lang_trap = self.no_lang_trap,
            .irq_context = self.irq_context,
            .blocks = try blocks.toOwnedSlice(self.allocator),
            .trap_edges = trap_edges,
            .contract_regions = contract_regions,
            .range_facts = range_facts,
            .elided_bounds = elided_bounds,
        };
    }

    fn buildBody(self: *FunctionBuilder, body: ast.Block) anyerror!void {
        _ = try self.buildBlock(body);
    }

    fn buildGlobalInitializer(self: *FunctionBuilder, ty: ast.TypeExpr, initializer: ast.Expr) anyerror!void {
        const target_ty = valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases);
        const previous_target = self.assignment_target;
        const previous_target_ty = self.assignment_target_ty;
        self.assignment_target = self.name;
        self.assignment_target_ty = target_ty;
        try self.addNullabilityConversionCheck(target_ty, initializer, initializer.span);
        try self.addConversionCheck(target_ty, initializer, .initializer, initializer.span);
        try self.addResultPayloadConversionCheck(target_ty, initializer, initializer.span);
        try self.addTargetRepresentationCheck(target_ty, initializer, initializer.span);
        try self.addAggregateConversionChecks(ty, initializer, .initializer);
        try self.buildExpr(initializer);
        try self.addRepresentationUseForValue(target_ty, "initializer", initializer.span, exprText(initializer));
        self.assignment_target = previous_target;
        self.assignment_target_ty = previous_target_ty;
    }

    fn buildBlock(self: *FunctionBuilder, block: ast.Block) anyerror!bool {
        for (block.items) |stmt| {
            if (try self.buildStmt(stmt)) {
                try self.addUnhandledResultChecksForBlock(block);
                return true;
            }
        }
        try self.addUnhandledResultChecksForBlock(block);
        return false;
    }

    fn buildUnsafeBlock(self: *FunctionBuilder, block: ast.Block) anyerror!bool {
        const old_unsafe = self.active_unsafe;
        self.active_unsafe = true;
        defer self.active_unsafe = old_unsafe;
        return try self.buildBlock(block);
    }

    fn buildStmt(self: *FunctionBuilder, stmt: ast.Stmt) anyerror!bool {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                const ty = if (local.ty) |local_ty| valueTypeFromTypeAlias(local_ty, self.enums, self.structs, self.packed_bits, self.aliases) else if (local.init) |init_expr| self.exprType(init_expr) else .unknown;
                const ty_expr = local.ty orelse if (local.init) |init_expr| self.typeExprForExpr(init_expr) else null;
                const mutable = std.meta.activeTag(stmt.kind) == .var_decl;
                for (local.names) |name| {
                    try self.addInstr(.local, name.text, ty, stmt.span);
                    try self.local_types.put(name.text, ty);
                    if (ty_expr) |local_ty| try self.local_type_exprs.put(name.text, local_ty);
                    try self.local_mutability.put(name.text, mutable);
                    try self.let_local_names.put(name.text, {});
                    if (local.init) |init_expr| {
                        if (self.addressOriginIsLocal(init_expr)) try self.local_address_origin.put(name.text, {});
                    }
                }
                if (local.ty) |local_ty| {
                    if (isWrapTypeAlias(local_ty, self.aliases)) for (local.names) |name| try self.wrap_values.put(name.text, {});
                    if (isSatTypeAlias(local_ty, self.aliases)) for (local.names) |name| try self.sat_values.put(name.text, {});
                }
                if (local.init) |expr| {
                    const previous_target = self.assignment_target;
                    const previous_target_ty = self.assignment_target_ty;
                    self.assignment_target = if (local.names.len > 0) local.names[0].text else null;
                    self.assignment_target_ty = ty;
                    try self.addNullabilityConversionCheck(ty, expr, expr.span);
                    if (local.ty != null) try self.addConversionCheck(ty, expr, .initializer, expr.span);
                    if (local.ty != null) try self.addResultPayloadConversionCheck(ty, expr, expr.span);
                    if (local.ty != null) try self.addTargetRepresentationCheck(ty, expr, expr.span);
                    if (local.ty) |local_ty| try self.addAggregateConversionChecks(local_ty, expr, .initializer);
                    try self.buildExpr(expr);
                    if (local.ty != null) try self.addRepresentationUseForValue(ty, "initializer", expr.span, exprText(expr));
                    self.assignment_target = previous_target;
                    self.assignment_target_ty = previous_target_ty;
                }
                return false;
            },
            .assignment => |node| {
                try self.addInstr(.assign, exprText(node.target), .unknown, stmt.span);
                // Escape analysis: a reassignment updates the target local's
                // address provenance (e.g. `out = p` drops a prior `&local`).
                if (assignmentTargetIdentName(node.target)) |target_name| {
                    if (self.let_local_names.contains(target_name)) {
                        if (self.addressOriginIsLocal(node.value)) {
                            try self.local_address_origin.put(target_name, {});
                        } else {
                            _ = self.local_address_origin.remove(target_name);
                        }
                    }
                }
                if (self.isMmioRegisterExpr(node.target)) {
                    try self.addInstr(.mmio_check, "direct_assign", .value, stmt.span);
                }
                try self.addAssignmentTargetCheck(node.target);
                try self.buildExpr(node.target);
                const previous_target = self.assignment_target;
                const previous_target_ty = self.assignment_target_ty;
                self.assignment_target = exprText(node.target);
                self.assignment_target_ty = self.typeForAssignmentTarget(node.target);
                try self.addNullabilityConversionCheck(self.assignment_target_ty, node.value, node.value.span);
                try self.addConversionCheck(self.assignment_target_ty, node.value, .assignment, node.value.span);
                try self.addResultPayloadConversionCheck(self.assignment_target_ty, node.value, node.value.span);
                try self.addTargetRepresentationCheck(self.assignment_target_ty, node.value, node.value.span);
                if (self.typeExprForAssignmentTarget(node.target)) |target_ty| try self.addAggregateConversionChecks(target_ty, node.value, .assignment);
                try self.buildExpr(node.value);
                try self.addRepresentationUseForValue(self.assignment_target_ty, "assignment", node.value.span, exprText(node.value));
                self.assignment_target = previous_target;
                self.assignment_target_ty = previous_target_ty;
                return false;
            },
            .expr => |expr| {
                try self.addResultExpressionStatementCheck(expr);
                try self.buildExpr(expr);
                if (exprTerminates(expr)) {
                    self.setTerminator(.unreachable_);
                    return true;
                }
                return false;
            },
            .assert => |expr| {
                try self.addInstr(.assert_condition, "condition", .bool, stmt.span);
                try self.addConversionCheck(.bool, expr, .condition, expr.span);
                try self.buildExpr(expr);
                try self.addTrapEdge(.Assert, .assert_stmt, stmt.span);
                return false;
            },
            .@"return" => |maybe| {
                if (maybe) |expr| {
                    if (self.addressOriginIsLocal(expr)) {
                        try self.addInstr(.usage_check, "local_address_escape", .unknown, expr.span);
                    }
                    try self.addNullabilityConversionCheck(self.return_ty, expr, expr.span);
                    try self.addConversionCheck(self.return_ty, expr, .return_, expr.span);
                    try self.addTargetRepresentationCheck(self.return_ty, expr, expr.span);
                    if (self.return_type_expr) |return_ty| try self.addAggregateConversionChecks(return_ty, expr, .return_);
                    try self.addResultPayloadConversionCheck(self.return_ty, expr, expr.span);
                    const previous_target = self.assignment_target;
                    const previous_target_ty = self.assignment_target_ty;
                    self.assignment_target = "value";
                    self.assignment_target_ty = self.return_ty;
                    try self.buildExpr(expr);
                    self.assignment_target = previous_target;
                    self.assignment_target_ty = previous_target_ty;
                }
                try self.addInstrWithValue(.return_value, if (maybe) |_| "value" else "void", self.return_ty, stmt.span, if (maybe) |expr| exprText(expr) else null);
                self.setTerminator(.{ .return_ = self.return_ty });
                return true;
            },
            .@"break" => {
                if (self.break_targets.items.len > 0) {
                    const target = self.break_targets.items[self.break_targets.items.len - 1];
                    try self.addSuccessor(self.current, target);
                    self.setTerminator(.{ .jump = target });
                } else {
                    self.setTerminator(.unreachable_);
                }
                return true;
            },
            .@"continue" => {
                if (self.continue_targets.items.len > 0) {
                    const target = self.continue_targets.items[self.continue_targets.items.len - 1];
                    try self.addSuccessor(self.current, target);
                    self.setTerminator(.{ .jump = target });
                } else {
                    self.setTerminator(.unreachable_);
                }
                return true;
            },
            .asm_stmt => {
                if (!self.active_unsafe) try self.addInstr(.unsafe_check, "asm.opaque", .unknown, stmt.span);
                try self.addInstr(.asm_effect, "opaque", .value, stmt.span);
                self.setTerminator(.unreachable_);
                return true;
            },
            .@"defer" => |expr| {
                try self.addInstr(.defer_cleanup, "cleanup", .void, stmt.span);
                try self.addResultDeferCheck(expr);
                try self.buildExpr(expr);
                return false;
            },
            .block, .comptime_block => |body| return try self.buildBlock(body),
            .unsafe_block => |body| return try self.buildUnsafeBlock(body),
            .contract_block => |contract| return try self.buildContractBlock(contract, stmt.span),
            .if_let => |node| return try self.buildIfLet(node, stmt.span),
            .@"switch" => |node| return try self.buildSwitch(node, stmt.span),
            .loop => |node| return try self.buildLoop(node, stmt.span),
        }
    }

    fn buildContractBlock(self: *FunctionBuilder, contract: ast.ContractBlock, stmt_span: ast.Span) !bool {
        const id = self.next_contract_region_id;
        self.next_contract_region_id += 1;
        const name = contractName(contract.attr);
        try self.contract_regions.append(self.allocator, .{
            .id = id,
            .kind = name,
            .begin_line = contract.attr.span.line,
            .end_line = contractBlockEndLine(contract.block),
        });
        try self.addInstr(.contract_begin, name, .contract, contract.attr.span);

        const old_contract = self.active_contract;
        const old_region_id = self.active_contract_region_id;
        self.active_contract = name;
        self.active_contract_region_id = id;
        const terminated = try self.buildBlock(contract.block);
        self.active_contract = old_contract;
        self.active_contract_region_id = old_region_id;

        if (!terminated) try self.addInstr(.contract_end, name, .contract, stmt_span);
        return terminated;
    }

    fn buildIfLet(self: *FunctionBuilder, node: ast.IfLet, span: ast.Span) anyerror!bool {
        try self.addInstr(.binary, patternText(node.pattern), .branch, span);
        try self.buildExpr(node.value);
        try self.addIfLetPatternCheck(node);

        const dispatch_id = self.current;
        const then_id = try self.addBlock("if_then");
        const else_id = try self.addBlock(if (node.else_block == null) "if_after" else "if_else");
        const after_id = if (node.else_block == null) else_id else try self.addBlock("if_after");
        try self.addSuccessor(dispatch_id, then_id);
        try self.addSuccessor(dispatch_id, else_id);
        self.blocks.items[dispatch_id].terminator = .{ .branch = .{ .true_block = then_id, .false_block = else_id } };

        self.current = then_id;
        const narrowed_binding = self.ifLetNarrowedBinding(node);
        var had_previous_type = false;
        var previous_type: ValueType = .unknown;
        var had_previous_type_expr = false;
        var previous_type_expr: ast.TypeExpr = undefined;
        var had_previous_mutability = false;
        var previous_mutability = false;
        if (narrowed_binding) |binding| {
            if (self.local_types.get(binding.name)) |old| {
                had_previous_type = true;
                previous_type = old;
            }
            if (self.local_mutability.get(binding.name)) |old| {
                had_previous_mutability = true;
                previous_mutability = old;
            }
            if (self.local_type_exprs.get(binding.name)) |old| {
                had_previous_type_expr = true;
                previous_type_expr = old;
                _ = self.local_type_exprs.remove(binding.name);
            }
            try self.local_types.put(binding.name, binding.ty);
            if (binding.ty_expr) |ty_expr| try self.local_type_exprs.put(binding.name, ty_expr);
            try self.local_mutability.put(binding.name, false);
        }
        const then_term = try self.buildBlock(node.then_block);
        if (narrowed_binding) |binding| {
            if (had_previous_type) {
                try self.local_types.put(binding.name, previous_type);
            } else {
                _ = self.local_types.remove(binding.name);
            }
            if (had_previous_type_expr) {
                try self.local_type_exprs.put(binding.name, previous_type_expr);
            } else {
                _ = self.local_type_exprs.remove(binding.name);
            }
            if (had_previous_mutability) {
                try self.local_mutability.put(binding.name, previous_mutability);
            } else {
                _ = self.local_mutability.remove(binding.name);
            }
        }
        if (!then_term) {
            try self.addSuccessor(self.current, after_id);
            self.setTerminator(.{ .jump = after_id });
        }

        if (node.else_block) |else_block| {
            self.current = else_id;
            const else_term = try self.buildBlock(else_block);
            if (!else_term) {
                try self.addSuccessor(self.current, after_id);
                self.setTerminator(.{ .jump = after_id });
            }
        }

        self.current = after_id;
        return false;
    }

    const NarrowedBinding = struct {
        name: []const u8,
        ty: ValueType,
        ty_expr: ?ast.TypeExpr = null,
    };

    fn ifLetNarrowedBinding(self: *FunctionBuilder, node: ast.IfLet) ?NarrowedBinding {
        return switch (node.pattern.kind) {
            .bind => |ident| switch (self.exprType(node.value)) {
                .nullable_pointer => |shape| .{ .name = ident.text, .ty = .{ .pointer = shape }, .ty_expr = self.narrowedBindingTypeExpr(node.value, "ok") },
                else => null,
            },
            .tag_bind => |tag_bind| blk: {
                if (!isResultNarrowingTag(tag_bind.tag.text)) break :blk null;
                const shape = switch (self.exprType(node.value)) {
                    .result => |shape| shape,
                    else => break :blk null,
                };
                const payload_name = if (std.mem.eql(u8, tag_bind.tag.text, "ok")) shape.ok else shape.err;
                break :blk .{
                    .name = tag_bind.binding.text,
                    .ty = valueTypeFromTypeNameAlias(payload_name, self.enums, self.structs, self.packed_bits),
                    .ty_expr = self.narrowedBindingTypeExpr(node.value, tag_bind.tag.text),
                };
            },
            .wildcard, .tag, .literal => null,
        };
    }

    fn addIfLetPatternCheck(self: *FunctionBuilder, node: ast.IfLet) !void {
        const value_ty = self.exprType(node.value);
        if (value_ty == .unknown or value_ty == .never) return;
        switch (node.pattern.kind) {
            .bind => {
                if (!isMirNullableValue(value_ty)) {
                    try self.addInstr(.result_check, "if_let_optional_required", value_ty, node.pattern.span);
                }
            },
            .tag_bind => |tag_bind| {
                if (!isResultNarrowingTag(tag_bind.tag.text)) {
                    const finding = if (isResultType(value_ty)) "if_let_result_tag" else "if_let_narrow_pattern";
                    try self.addInstr(.result_check, finding, value_ty, tag_bind.tag.span);
                } else if (!isResultType(value_ty)) {
                    try self.addInstr(.result_check, "if_let_result_required", value_ty, node.pattern.span);
                }
            },
            .wildcard, .tag, .literal => {
                try self.addInstr(.result_check, "if_let_narrow_pattern", value_ty, node.pattern.span);
            },
        }
    }

    fn narrowedBindingTypeExpr(self: *FunctionBuilder, expr: ast.Expr, tag: []const u8) ?ast.TypeExpr {
        const ty = self.typeExprForExpr(expr) orelse return null;
        if (std.mem.eql(u8, tag, "ok")) {
            if (tryPayloadTypeExprAlias(ty, self.aliases)) |payload_ty| return payload_ty;
        }
        return resultPayloadTypeExprAlias(ty, tag, self.aliases);
    }

    fn switchNarrowedBinding(self: *FunctionBuilder, subject: ast.Expr, pattern: ast.Pattern) ?NarrowedBinding {
        return switch (pattern.kind) {
            .bind => |ident| switch (self.exprType(subject)) {
                .nullable_pointer => |shape| .{ .name = ident.text, .ty = .{ .pointer = shape }, .ty_expr = self.narrowedBindingTypeExpr(subject, "ok") },
                else => null,
            },
            .tag_bind => |tag_bind| blk: {
                if (!isResultNarrowingTag(tag_bind.tag.text)) break :blk null;
                const shape = switch (self.exprType(subject)) {
                    .result => |shape| shape,
                    else => break :blk null,
                };
                const payload_name = if (std.mem.eql(u8, tag_bind.tag.text, "ok")) shape.ok else shape.err;
                break :blk .{
                    .name = tag_bind.binding.text,
                    .ty = valueTypeFromTypeNameAlias(payload_name, self.enums, self.structs, self.packed_bits),
                    .ty_expr = self.narrowedBindingTypeExpr(subject, tag_bind.tag.text),
                };
            },
            .wildcard, .tag, .literal => null,
        };
    }

    fn buildSwitch(self: *FunctionBuilder, node: ast.Switch, span: ast.Span) anyerror!bool {
        try self.addInstr(.binary, "switch_subject", .branch, span);
        try self.buildExpr(node.subject);
        try self.addRepresentationUseForExpr("switch_subject", node.subject);
        try self.addSwitchPatternChecks(node);

        const dispatch_id = self.current;
        const after_id = try self.addBlock("switch_after");
        for (node.arms) |arm| {
            const arm_id = try self.addBlock("switch_arm");
            try self.addSuccessor(dispatch_id, arm_id);
            self.current = arm_id;
            try self.addInstr(.expr, if (arm.patterns.len == 0) "_" else patternText(arm.patterns[0]), .branch, span);
            const narrowed_binding = if (arm.patterns.len > 0) self.switchNarrowedBinding(node.subject, arm.patterns[0]) else null;
            var had_previous_type = false;
            var previous_type: ValueType = .unknown;
            var had_previous_type_expr = false;
            var previous_type_expr: ast.TypeExpr = undefined;
            var had_previous_mutability = false;
            var previous_mutability = false;
            if (narrowed_binding) |binding| {
                if (self.local_types.get(binding.name)) |old| {
                    had_previous_type = true;
                    previous_type = old;
                }
                if (self.local_mutability.get(binding.name)) |old| {
                    had_previous_mutability = true;
                    previous_mutability = old;
                }
                if (self.local_type_exprs.get(binding.name)) |old| {
                    had_previous_type_expr = true;
                    previous_type_expr = old;
                    _ = self.local_type_exprs.remove(binding.name);
                }
                try self.local_types.put(binding.name, binding.ty);
                if (binding.ty_expr) |ty_expr| try self.local_type_exprs.put(binding.name, ty_expr);
                try self.local_mutability.put(binding.name, false);
            }
            const terminated = switch (arm.body) {
                .block => |body| try self.buildBlock(body),
                .expr => |expr| blk: {
                    try self.addResultExpressionStatementCheck(expr);
                    try self.buildExpr(expr);
                    break :blk exprTerminates(expr);
                },
            };
            if (narrowed_binding) |binding| {
                if (had_previous_type) {
                    try self.local_types.put(binding.name, previous_type);
                } else {
                    _ = self.local_types.remove(binding.name);
                }
                if (had_previous_type_expr) {
                    try self.local_type_exprs.put(binding.name, previous_type_expr);
                } else {
                    _ = self.local_type_exprs.remove(binding.name);
                }
                if (had_previous_mutability) {
                    try self.local_mutability.put(binding.name, previous_mutability);
                } else {
                    _ = self.local_mutability.remove(binding.name);
                }
            }
            if (!terminated) {
                try self.addSuccessor(self.current, after_id);
                self.setTerminator(.{ .jump = after_id });
            }
        }
        self.blocks.items[dispatch_id].terminator = .switch_;
        self.current = after_id;
        return false;
    }

    fn addSwitchPatternChecks(self: *FunctionBuilder, node: ast.Switch) !void {
        const subject_ty = self.exprType(node.subject);
        if (subject_ty == .unknown or subject_ty == .never) return;
        var result_cases_seen = std.StringHashMap(void).init(self.allocator);
        defer result_cases_seen.deinit();
        var enum_cases_seen = std.StringHashMap(void).init(self.allocator);
        defer enum_cases_seen.deinit();
        var union_cases_seen = std.StringHashMap(void).init(self.allocator);
        defer union_cases_seen.deinit();
        var bool_cases_seen = std.StringHashMap(void).init(self.allocator);
        defer bool_cases_seen.deinit();
        var integer_cases_seen = std.AutoHashMap(LiteralValue, void).init(self.allocator);
        defer integer_cases_seen.deinit();
        const enum_info = self.enumSummaryForType(subject_ty);
        const union_info = self.unionSummaryForExpr(node.subject);
        var wildcard_seen = false;
        for (node.arms) |arm| {
            var binding_pattern_count: usize = 0;
            var arm_has_wildcard = false;
            for (arm.patterns) |pattern| {
                if (wildcard_seen) {
                    try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, pattern.span);
                    continue;
                }
                switch (pattern.kind) {
                    .tag => |tag| {
                        if (union_info) |info| {
                            if (!unionContainsCase(info, tag.text)) {
                                try self.addInstr(.switch_check, "unknown_union_case", subject_ty, tag.span);
                            } else {
                                try self.addDuplicateSwitchStringCaseCheck(&union_cases_seen, tag.text, subject_ty, tag.span);
                            }
                        } else if (isResultType(subject_ty) and !isResultNarrowingTag(tag.text)) {
                            try self.addInstr(.result_check, "switch_result_tag", subject_ty, tag.span);
                        } else if (!isResultType(subject_ty) and isResultNarrowingTag(tag.text) and !isMirEnum(subject_ty)) {
                            try self.addInstr(.result_check, "switch_result_required", subject_ty, tag.span);
                        }
                        if (enum_info) |info| {
                            if (!enumContainsCase(info, tag.text)) {
                                try self.addInstr(.switch_check, "unknown_enum_case", subject_ty, tag.span);
                            } else {
                                try self.addDuplicateSwitchStringCaseCheck(&enum_cases_seen, tag.text, subject_ty, tag.span);
                            }
                        }
                        if (isResultType(subject_ty) and isResultNarrowingTag(tag.text)) {
                            try self.addDuplicateSwitchStringCaseCheck(&result_cases_seen, tag.text, subject_ty, tag.span);
                        }
                    },
                    .tag_bind => |tag_bind| {
                        binding_pattern_count += 1;
                        if (union_info) |info| {
                            if (!unionContainsCase(info, tag_bind.tag.text)) {
                                try self.addInstr(.switch_check, "unknown_union_case", subject_ty, tag_bind.tag.span);
                            } else {
                                if (unionCasePayloadType(info, tag_bind.tag.text) == null) {
                                    try self.addInstr(.switch_check, "union_case_has_no_payload", subject_ty, pattern.span);
                                }
                                try self.addDuplicateSwitchStringCaseCheck(&union_cases_seen, tag_bind.tag.text, subject_ty, tag_bind.tag.span);
                            }
                        } else if (isResultType(subject_ty) and !isResultNarrowingTag(tag_bind.tag.text)) {
                            try self.addInstr(.result_check, "switch_result_tag", subject_ty, tag_bind.tag.span);
                        } else if (!isResultType(subject_ty) and isResultNarrowingTag(tag_bind.tag.text)) {
                            try self.addInstr(.result_check, "switch_result_required", subject_ty, pattern.span);
                        }
                        if (isResultType(subject_ty) and isResultNarrowingTag(tag_bind.tag.text)) {
                            try self.addDuplicateSwitchStringCaseCheck(&result_cases_seen, tag_bind.tag.text, subject_ty, tag_bind.tag.span);
                        }
                    },
                    .bind => binding_pattern_count += 1,
                    .wildcard => {
                        if (arm_has_wildcard) {
                            try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, pattern.span);
                        }
                        arm_has_wildcard = true;
                    },
                    .literal => |literal| {
                        if (arm_has_wildcard) {
                            try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, pattern.span);
                            continue;
                        }
                        if (subject_ty == .bool) {
                            if (switchBoolLiteralValue(literal)) |value| {
                                try self.addDuplicateSwitchStringCaseCheck(&bool_cases_seen, if (value) "true" else "false", subject_ty, pattern.span);
                            } else {
                                try self.addInstr(.switch_check, "switch_literal_type_mismatch", subject_ty, literal.span);
                            }
                        } else if (isMirIntegerLike(subject_ty)) {
                            if (integerLiteralValue(literal)) |value| {
                                if (integerLiteralRangeFinding(subject_ty, literal) != null) {
                                    try self.addInstr(.switch_check, "switch_literal_type_mismatch", subject_ty, literal.span);
                                    continue;
                                }
                                if (integer_cases_seen.contains(value)) {
                                    try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, pattern.span);
                                } else {
                                    try integer_cases_seen.put(value, {});
                                }
                            } else {
                                try self.addInstr(.switch_check, "switch_literal_type_mismatch", subject_ty, literal.span);
                            }
                        } else {
                            try self.addInstr(.switch_check, "switch_literal_type_mismatch", subject_ty, literal.span);
                        }
                    },
                }
                if (arm_has_wildcard and pattern.kind != .wildcard) {
                    try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, pattern.span);
                }
            }
            if (binding_pattern_count > 1 and arm.patterns.len > 0) {
                try self.addInstr(.result_check, "switch_multi_binding_arm", subject_ty, arm.patterns[0].span);
            }
            if (arm_has_wildcard) wildcard_seen = true;
        }
        if (enum_info) |info| {
            if (!info.is_open and !wildcard_seen and !switchCoversAllMirEnumCases(node, info)) {
                try self.addInstr(.switch_check, "closed_enum_switch_exhaustive", subject_ty, node.subject.span);
            }
        }
    }

    fn addDuplicateSwitchStringCaseCheck(self: *FunctionBuilder, seen: *std.StringHashMap(void), key: []const u8, subject_ty: ValueType, span: ast.Span) !void {
        if (seen.contains(key)) {
            try self.addInstr(.switch_check, "duplicate_switch_case", subject_ty, span);
        } else {
            try seen.put(key, {});
        }
    }

    fn enumSummaryForType(self: *FunctionBuilder, ty: ValueType) ?EnumSummary {
        const name = switch (ty) {
            .closed_enum, .open_enum => |name| name,
            else => return null,
        };
        return self.enums.get(name);
    }

    fn unionSummaryForExpr(self: *FunctionBuilder, expr: ast.Expr) ?UnionSummary {
        const ty = self.typeExprForExpr(expr) orelse return null;
        const name = unionTypeNameAlias(ty, self.aliases) orelse return null;
        return self.unions.get(name);
    }

    fn addAssignmentTargetCheck(self: *FunctionBuilder, target: ast.Expr) !void {
        switch (target.kind) {
            .ident => |ident| {
                if (self.local_mutability.get(ident.text)) |mutable| {
                    if (!mutable) try self.addInstr(.assignment_check, "assign_to_immutable_local", .unknown, target.span);
                }
            },
            .deref => |inner| {
                if (self.constStorageBase(inner.*)) {
                    try self.addInstr(.assignment_check, "assign_through_const_view", .unknown, target.span);
                }
            },
            .index => |node| {
                if (self.constStorageBase(node.base.*)) {
                    try self.addInstr(.assignment_check, "assign_through_const_view", .unknown, target.span);
                }
                if (self.immutableIndexedValueStorageBase(node.base.*)) {
                    try self.addInstr(.assignment_check, "assign_to_immutable_local", .unknown, target.span);
                }
            },
            .member => |node| {
                if (self.constStorageBase(node.base.*)) {
                    try self.addInstr(.assignment_check, "assign_through_const_view", .unknown, target.span);
                }
                if (self.immutableValueStorageBase(node.base.*)) {
                    try self.addInstr(.assignment_check, "assign_to_immutable_local", .unknown, target.span);
                }
            },
            .grouped => |inner| try self.addAssignmentTargetCheck(inner.*),
            else => {},
        }
    }

    fn addArithmeticDomainChecks(self: *FunctionBuilder, node: anytype, span: ast.Span) !void {
        const left_domain = self.exprArithmeticDomain(node.left.*);
        const right_domain = self.exprArithmeticDomain(node.right.*);
        if (mirIsArithmeticBinary(node.op) and self.arithmeticDomainsImplicitlyMix(node.left.*, left_domain, node.right.*, right_domain)) {
            try self.addInstr(.arithmetic_domain_check, "arith_policy_mix", .unknown, span);
        }
        if ((node.op == .div or node.op == .mod) and (left_domain != null or right_domain != null)) {
            try self.addInstr(.arithmetic_domain_check, "arith_domain_division", .unknown, span);
        }
        if (mirIsOrderedComparison(node.op) and (isMirForbiddenOrderingDomain(left_domain) or isMirForbiddenOrderingDomain(right_domain))) {
            try self.addInstr(.arithmetic_domain_check, "ordered_arith_domain_operand", .unknown, span);
        }
        if (mirIsBitwiseBinary(node.op) and (self.exprHasForbiddenBitwiseDomain(node.left.*) or self.exprHasForbiddenBitwiseDomain(node.right.*))) {
            try self.addInstr(.arithmetic_domain_check, "bitwise_arith_domain_operand", .unknown, span);
        }
    }

    fn addUnaryOperatorChecks(self: *FunctionBuilder, node: anytype, span: ast.Span) !void {
        const operand_ty = self.exprType(node.expr.*);
        switch (node.op) {
            .neg => {
                if (isCheckedUnsignedType(operand_ty)) try self.addInstr(.operator_check, "unsigned_negation", .unknown, span);
                if (!unaryNegOperandAllowed(self.exprArithmeticDomain(node.expr.*), operand_ty)) {
                    try self.addInstr(.operator_check, "operator_operand", .unknown, span);
                }
            },
            .bit_not => {
                try self.addBitwiseOperatorOperandChecks(operand_ty, span);
                if (!bitwiseOperandAllowed(self.exprArithmeticDomain(node.expr.*), operand_ty)) {
                    try self.addInstr(.operator_check, "operator_operand", .unknown, span);
                }
            },
            .logical_not => {
                if (operand_ty != .bool and operand_ty != .unknown and operand_ty != .never) {
                    try self.addInstr(.operator_check, "bool_operator_operand", .unknown, span);
                }
            },
        }
    }

    fn addBinaryOperatorChecks(self: *FunctionBuilder, node: anytype, span: ast.Span) !void {
        const left_ty = self.exprType(node.left.*);
        const right_ty = self.exprType(node.right.*);
        if (mirIsBitwiseBinary(node.op)) {
            try self.addBitwiseOperatorOperandChecks(left_ty, span);
            try self.addBitwiseOperatorOperandChecks(right_ty, span);
            if (!bitwiseOperandAllowed(self.exprArithmeticDomain(node.left.*), left_ty) or
                !bitwiseOperandAllowed(self.exprArithmeticDomain(node.right.*), right_ty))
            {
                try self.addInstr(.operator_check, "operator_operand", .unknown, span);
            }
        }
        if (mirIsLogicalBinary(node.op) and !logicalOperandsAllowed(left_ty, right_ty)) {
            try self.addInstr(.operator_check, "bool_operator_operand", .unknown, span);
        }
        if (mirIsArithmeticBinary(node.op) or mirIsComparisonBinary(node.op)) {
            if (floatBinaryFinding(node.op, left_ty, right_ty)) |finding| {
                try self.addInstr(.operator_check, finding, .unknown, span);
            }
            if (checkedIntegerBinaryFinding(left_ty, right_ty)) |finding| {
                try self.addInstr(.operator_check, finding, .unknown, span);
            }
        }
        // D.1 pointer operator legality (section 9).
        if (mirIsPointerArithmetic(node.op) and (isMirSingleObjectPointer(left_ty) or isMirSingleObjectPointer(right_ty))) {
            try self.addInstr(.operator_check, "pointer_arith_single_object", .unknown, span);
        }
        if (mirIsOrderedComparison(node.op) and (isMirPointerOrView(left_ty) or isMirPointerOrView(right_ty))) {
            try self.addInstr(.operator_check, "pointer_ordering", .unknown, span);
        }
    }

    fn addBitwiseOperatorOperandChecks(self: *FunctionBuilder, ty: ValueType, span: ast.Span) !void {
        if (isCheckedSignedType(ty)) {
            try self.addInstr(.operator_check, "bitwise_signed_operand", .unknown, span);
        } else if (ty == .bool) {
            try self.addInstr(.operator_check, "bitwise_bool_operand", .unknown, span);
        } else if (isPointerLikeType(ty)) {
            try self.addInstr(.operator_check, "bitwise_pointer_operand", .unknown, span);
        }
    }

    fn arithmeticDomainsImplicitlyMix(self: *FunctionBuilder, left: ast.Expr, left_domain: ?ArithmeticDomain, right: ast.Expr, right_domain: ?ArithmeticDomain) bool {
        if (left_domain) |left_known| {
            if (right_domain) |right_known| return left_known != right_known;
            return self.exprHasKnownNonDomainValue(right);
        }
        if (right_domain != null) return self.exprHasKnownNonDomainValue(left);
        return false;
    }

    fn exprHasForbiddenBitwiseDomain(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (self.exprArithmeticDomain(expr) orelse return false) {
            .sat, .serial, .counter => true,
            .wrap => false,
        };
    }

    fn exprHasKnownNonDomainValue(self: *FunctionBuilder, expr: ast.Expr) bool {
        if (self.exprArithmeticDomain(expr) != null) return false;
        return switch (expr.kind) {
            .grouped => |inner| self.exprHasKnownNonDomainValue(inner.*),
            .int_literal, .float_literal, .bool_literal, .null_literal, .char_literal, .string_literal, .void_literal, .enum_literal => true,
            else => self.typeExprForExpr(expr) != null or self.exprType(expr) != .unknown,
        };
    }

    fn exprArithmeticDomain(self: *FunctionBuilder, expr: ast.Expr) ?ArithmeticDomain {
        return switch (expr.kind) {
            .ident, .member, .deref, .index, .call => if (self.typeExprForExpr(expr)) |ty| arithmeticDomainTypeAlias(ty, self.aliases) else null,
            .grouped => |inner| self.exprArithmeticDomain(inner.*),
            .cast => |node| arithmeticDomainTypeAlias(node.ty.*, self.aliases),
            .binary => |node| self.binaryArithmeticDomain(node),
            else => null,
        };
    }

    fn binaryArithmeticDomain(self: *FunctionBuilder, node: anytype) ?ArithmeticDomain {
        const left_domain = self.exprArithmeticDomain(node.left.*) orelse return null;
        const right_domain = self.exprArithmeticDomain(node.right.*) orelse return null;
        if (left_domain != right_domain) return null;
        return switch (left_domain) {
            .wrap => if (isWrapPreservingBinary(node.op)) .wrap else null,
            .sat => if (isSatPreservingBinary(node.op)) .sat else null,
            .serial, .counter => null,
        };
    }

    fn constStorageBase(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| {
                if (self.local_type_exprs.get(ident.text)) |ty| return isConstStorageTypeAlias(ty, self.aliases);
                if (self.global_type_exprs.get(ident.text)) |ty| return isConstStorageTypeAlias(ty, self.aliases);
                return false;
            },
            .deref => |inner| self.constStorageBase(inner.*),
            .index => |node| self.constStorageBase(node.base.*),
            .slice => |node| self.constStorageBase(node.base.*),
            .member => |node| self.constStorageBase(node.base.*),
            .grouped => |inner| self.constStorageBase(inner.*),
            .cast => |node| isConstStorageTypeAlias(node.ty.*, self.aliases),
            else => false,
        };
    }

    fn immutableValueStorageBase(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                // A field reached through a pointer auto-derefs; its
                // assignability is the pointer's mutability (a const pointer is
                // caught by constStorageBase), not the binding's. So a `*mut T`
                // parameter permits `p.field = …`.
                switch (self.exprType(expr)) {
                    .pointer, .nullable_pointer => break :blk false,
                    else => {},
                }
                break :blk if (self.local_mutability.get(ident.text)) |mutable| !mutable else false;
            },
            .deref => false,
            .member => |node| self.immutableValueStorageBase(node.base.*),
            .grouped => |inner| self.immutableValueStorageBase(inner.*),
            else => false,
        };
    }

    fn immutableIndexedValueStorageBase(self: *FunctionBuilder, expr: ast.Expr) bool {
        const ty = self.typeExprForExpr(expr) orelse return false;
        if (!isArrayTypeAlias(ty, self.aliases)) return false;
        return self.immutableValueStorageBase(expr);
    }

    fn buildLoop(self: *FunctionBuilder, node: ast.Loop, span: ast.Span) anyerror!bool {
        try self.addInstr(.binary, @tagName(node.kind), .branch, span);
        if (node.iterable) |iterable| {
            if (node.kind == .@"while") try self.addConversionCheck(.bool, iterable, .condition, iterable.span);
            if (node.kind == .@"for") try self.addForIterableCheck(iterable, iterable.span);
            try self.buildExpr(iterable);
        }
        const header_id = self.current;
        const body_id = try self.addBlock("loop_body");
        const after_id = try self.addBlock("loop_after");
        try self.addSuccessor(header_id, body_id);
        if (node.kind == .@"while") try self.addSuccessor(header_id, after_id);
        self.blocks.items[header_id].terminator = if (node.kind == .@"while")
            .{ .branch = .{ .true_block = body_id, .false_block = after_id } }
        else
            .{ .jump = body_id };

        self.current = body_id;
        try self.break_targets.append(self.allocator, after_id);
        try self.continue_targets.append(self.allocator, header_id);
        var had_previous_type = false;
        var previous_type: ValueType = .unknown;
        var had_previous_type_expr = false;
        var previous_type_expr: ast.TypeExpr = undefined;
        var had_previous_mutability = false;
        var previous_mutability = false;
        const for_binding_ty_expr = if (node.kind == .@"for" and node.label != null and node.iterable != null)
            if (self.typeExprForExpr(node.iterable.?)) |iterable_ty| storageElementTypeAlias(iterable_ty, self.aliases) else null
        else
            null;
        if (node.kind == .@"for" and node.label != null) {
            const binding = node.label.?;
            if (self.local_types.get(binding.text)) |old| {
                had_previous_type = true;
                previous_type = old;
            }
            if (self.local_type_exprs.get(binding.text)) |old| {
                had_previous_type_expr = true;
                previous_type_expr = old;
                _ = self.local_type_exprs.remove(binding.text);
            }
            if (self.local_mutability.get(binding.text)) |old| {
                had_previous_mutability = true;
                previous_mutability = old;
            }
            if (for_binding_ty_expr) |ty_expr| {
                try self.local_types.put(binding.text, valueTypeFromTypeAlias(ty_expr, self.enums, self.structs, self.packed_bits, self.aliases));
                try self.local_type_exprs.put(binding.text, ty_expr);
            } else {
                try self.local_types.put(binding.text, .value);
            }
            try self.local_mutability.put(binding.text, false);
        }
        const terminated = try self.buildBlock(node.body);
        if (node.kind == .@"for" and node.label != null) {
            const binding = node.label.?;
            if (had_previous_type) {
                try self.local_types.put(binding.text, previous_type);
            } else {
                _ = self.local_types.remove(binding.text);
            }
            if (had_previous_type_expr) {
                try self.local_type_exprs.put(binding.text, previous_type_expr);
            } else {
                _ = self.local_type_exprs.remove(binding.text);
            }
            if (had_previous_mutability) {
                try self.local_mutability.put(binding.text, previous_mutability);
            } else {
                _ = self.local_mutability.remove(binding.text);
            }
        }
        _ = self.break_targets.pop();
        _ = self.continue_targets.pop();
        if (!terminated) {
            try self.addSuccessor(self.current, body_id);
            self.setTerminator(.{ .jump = body_id });
        }
        self.current = after_id;
        return false;
    }

    fn buildExpr(self: *FunctionBuilder, expr: ast.Expr) anyerror!void {
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
        const counts_for_semantic_depth = expr.kind != .grouped;
        if (counts_for_semantic_depth) self.semantic_expr_depth += 1;
        defer {
            if (counts_for_semantic_depth) self.semantic_expr_depth -= 1;
        }

        switch (expr.kind) {
            .ident => {
                const ty = self.exprType(expr);
                if (representationCheckKind(ty) != null) {
                    try self.addInstr(.typed_load, exprText(expr), ty, expr.span);
                    try self.addRuntimeRepresentationCheck(ty, expr.span, exprText(expr));
                }
                try self.addInstr(.expr, exprText(expr), ty, expr.span);
            },
            .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .null_literal, .uninit_literal, .void_literal, .enum_literal => {
                try self.addInstr(.expr, exprText(expr), self.exprType(expr), expr.span);
            },
            .array_literal => |items| {
                try self.addInstr(.expr, "array_literal", .{ .array = "array" }, expr.span);
                for (items) |item| try self.buildExpr(item);
            },
            .struct_literal => |fields| {
                try self.addInstr(.expr, "struct_literal", .value, expr.span);
                for (fields) |field| try self.buildExpr(field.value);
            },
            .unreachable_expr => {
                try self.addTrapEdge(.Unreachable, .unreachable_expr, expr.span);
            },
            .grouped, .address_of => |inner| try self.buildExpr(inner.*),
            .deref => |inner| {
                const inner_ty = self.exprType(inner.*);
                if (!self.active_unsafe and isRawManyPointerValue(inner_ty)) {
                    try self.addInstr(.unsafe_check, "raw_many.deref", .unknown, expr.span);
                }
                if (inner_ty == .address) {
                    try self.addInstr(.address_deref, inner_ty.name(), inner_ty, expr.span);
                }
                if (isMirCVoidPointer(inner_ty)) {
                    try self.addInstr(.ffi_check, "c_void_deref", .unknown, expr.span);
                }
                const ty = self.exprType(expr);
                if (representationCheckKind(ty) != null) {
                    try self.addInstr(.typed_load, exprText(expr), ty, expr.span);
                    try self.addRuntimeRepresentationCheck(ty, expr.span, exprText(expr));
                }
                try self.buildExpr(inner.*);
                if (!isRawManyPointerValue(inner_ty)) try self.addRepresentationUseForExpr("deref_base", inner.*);
            },
            .try_expr => |inner| {
                const inner_ty = self.exprType(inner.operand.*);
                if (isTryCapableType(inner_ty)) {
                    try self.addInstr(.result_check, "try_handled", inner_ty, expr.span);
                } else {
                    try self.addInstr(.result_check, "try_requires_result_or_nullable", inner_ty, expr.span);
                }
                const try_ty = self.exprType(expr);
                if (representationCheckKind(try_ty) != null) {
                    try self.addRuntimeRepresentationCheck(try_ty, expr.span, exprText(expr));
                }
                try self.addTrapEdge(.Unwrap, .unwrap, expr.span);
                try self.buildExpr(inner.operand.*);
                try self.addRepresentationUseForValue(try_ty, "try_unwrap", expr.span, exprText(expr));
            },
            .block => |block| _ = try self.buildBlock(block),
            .unary => |node| {
                try self.addInstr(.unary, @tagName(node.op), .value, expr.span);
                try self.addUnaryOperatorChecks(node, expr.span);
                if (node.op == .bit_not and self.exprType(node.expr.*) == .address) {
                    try self.addInstr(.address_operation, @tagName(node.op), self.exprType(node.expr.*), expr.span);
                }
                if (node.op == .bit_not and self.exprHasForbiddenBitwiseDomain(node.expr.*)) {
                    try self.addInstr(.arithmetic_domain_check, "bitwise_arith_domain_operand", .unknown, expr.span);
                }
                if (node.op == .neg and !self.exprIsWrap(node.expr.*) and !self.exprIsFloat(node.expr.*)) {
                    try self.addInstr(.add_overflow, "checked_neg", .bool, expr.span);
                    try self.addTrapEdge(.IntegerOverflow, .checked_arithmetic, expr.span);
                }
                try self.buildExpr(node.expr.*);
            },
            .binary => |node| {
                try self.addInstr(.binary, @tagName(node.op), .value, expr.span);
                try self.addBinaryOperatorChecks(node, expr.span);
                if (binaryChecksAddressClass(node.op) and (self.exprType(node.left.*) == .address or self.exprType(node.right.*) == .address)) {
                    try self.addInstr(.address_operation, @tagName(node.op), .value, expr.span);
                }
                try self.addArithmeticDomainChecks(node, expr.span);
                if (binaryMayOverflow(node.op) and !self.binaryIsNoTrapArithmeticDomain(node) and !self.binaryIsFloat(node)) {
                    try self.addInstr(.add_overflow, @tagName(node.op), .bool, expr.span);
                    try self.addBinaryTrapEdges(node, expr.span);
                } else if (isShiftOp(node.op) and !self.binaryIsNoTrapArithmeticDomain(node)) {
                    try self.addTrapEdge(.InvalidShift, .checked_shift, expr.span);
                }
                try self.addAggregateRangeFactForUncheckedExpr("binary_operand", self.rangeFactTypeForExpr(node.left.*), node.left.*);
                try self.addAggregateRangeFactForUncheckedExpr("binary_operand", self.rangeFactTypeForExpr(node.right.*), node.right.*);
                try self.buildExpr(node.left.*);
                try self.addRepresentationUseForExpr("binary_operand", node.left.*);
                try self.buildExpr(node.right.*);
                try self.addRepresentationUseForExpr("binary_operand", node.right.*);
            },
            .cast => |node| {
                const cast_target = valueTypeFromTypeAlias(node.ty.*, self.enums, self.structs, self.packed_bits, self.aliases);
                if (cast_target == .closed_enum and isMirIntegerType(self.exprType(node.value.*))) {
                    try self.addInstr(.usage_check, "closed_enum_conversion", .unknown, expr.span);
                }
                try self.addInstr(.expr, "cast", valueTypeFromTypeAlias(node.ty.*, self.enums, self.structs, self.packed_bits, self.aliases), expr.span);
                if (self.semantic_expr_depth == 1) {
                    try self.addAggregateRangeFactForUncheckedExpr(self.assignment_target orelse "value", valueTypeFromTypeAlias(node.ty.*, self.enums, self.structs, self.packed_bits, self.aliases), expr);
                }
                try self.buildExpr(node.value.*);
            },
            .call => |node| {
                if (self.constGetCallType(node)) |const_get_ty| {
                    try self.addInstr(.index, "const_get", const_get_ty, expr.span);
                    if (representationCheckKind(const_get_ty) != null) {
                        try self.addInstr(.typed_load, exprText(expr), const_get_ty, expr.span);
                        try self.addRuntimeRepresentationCheck(const_get_ty, expr.span, exprText(expr));
                    }
                    try self.buildExpr(constGetBase(node).?.*);
                    return;
                }
                const callee_name = self.calleeName(node.callee.*);
                const direct_call = self.isKnownDirectCall(node.callee.*, callee_name);
                const instr_kind: Instruction.Kind = if (isUncheckedCall(node.callee.*))
                    .unchecked_assume
                else if (direct_call)
                    .call
                else
                    .indirect_call;
                const call_ty = if (self.summaries.get(callee_name)) |summary| summary.return_ty else .unknown;
                try self.addInstr(instr_kind, callee_name, call_ty, expr.span);
                if (!self.active_unsafe and isUnsafeOperationCall(node.callee.*)) {
                    try self.addInstr(.unsafe_check, callee_name, .unknown, expr.span);
                }
                if (self.mmioReceiverAccessInfo(node.callee.*)) |access_info| {
                    if ((access_info.op == .read and !access_info.access.allowsRead()) or
                        (access_info.op == .write and !access_info.access.allowsWrite()))
                    {
                        try self.addInstr(.mmio_check, @tagName(access_info.op), .value, expr.span);
                    }
                }
                if ((instr_kind == .call or instr_kind == .indirect_call) and representationCheckKind(call_ty) != null) {
                    if (callResultRepresentationCheckTraps(callee_name)) {
                        try self.addRuntimeRepresentationCheck(call_ty, expr.span, callee_name);
                    } else {
                        try self.addInstrWithValue(.representation_check, representationTypeName(call_ty), call_ty, expr.span, callee_name);
                    }
                }
                if (self.summaries.get(callee_name)) |summary| {
                    const checked_len = @min(node.args.len, summary.params.len);
                    for (node.args[0..checked_len], summary.params[0..checked_len]) |arg, param| {
                        const param_ty = valueTypeFromTypeAlias(param.ty, self.enums, self.structs, self.packed_bits, self.aliases);
                        try self.addConversionCheck(param_ty, arg, .call_arg, arg.span);
                        try self.addResultPayloadConversionCheck(param_ty, arg, arg.span);
                        try self.addTargetRepresentationCheck(param_ty, arg, arg.span);
                        try self.addAggregateConversionChecks(param.ty, arg, .call_arg);
                    }
                }
                if (instr_kind == .unchecked_assume) try self.addRangeFactForUncheckedCall(callee_name, node.args, expr.span);
                if (isTrapCall(node.callee.*)) try self.addTrapEdge(.ExplicitTrap, .explicit_trap, expr.span);
                if (isUnwrapCall(node.callee.*)) try self.addTrapEdge(.Unwrap, .unwrap, expr.span);
                // Conversion/domain builtins have precise trap behaviour: `trap_from`
                // raises a range trap, the rest never trap. Modelling them exactly
                // avoids both the false negative (sema misses `trap_from`) and the
                // false positive (blanket `CallMayTrap` on pure casts like `from`).
                if (self.domainConversionCallFinding(node.callee.*)) |finding| {
                    try self.addInstr(.arithmetic_domain_check, finding, .unknown, expr.span);
                }
                if (self.typedResourceCallFinding(node.callee.*)) |finding| {
                    try self.addInstr(.usage_check, finding, .unknown, expr.span);
                }
                if (self.atomicOrderingFinding(node.callee.*, node.args)) |finding| {
                    try self.addInstr(.usage_check, finding, .unknown, expr.span);
                }
                if (self.mmioOrderingFinding(node.callee.*, node.args)) |finding| {
                    try self.addInstr(.usage_check, finding, .unknown, expr.span);
                }
                if (self.dmaCacheModeFinding(node.callee.*, node.args)) |finding| {
                    try self.addInstr(.usage_check, finding, .unknown, node.args[0].span);
                }
                if (isMirBitcastCallee(node.callee.*) and node.type_args.len == 1 and node.args.len == 1) {
                    if (!isMirBitcastLayout(valueTypeFromTypeAlias(node.type_args[0], self.enums, self.structs, self.packed_bits, self.aliases))) {
                        try self.addInstr(.usage_check, "bitcast_type", .unknown, node.type_args[0].span);
                    }
                    if (!isMirBitcastLayout(self.exprType(node.args[0]))) {
                        try self.addInstr(.usage_check, "bitcast_type", .unknown, node.args[0].span);
                    }
                }
                const conversion_trap = conversionDomainCallTrap(node.callee.*);
                if (conversion_trap == .traps) try self.addTrapEdge(.IntegerOverflow, .checked_arithmetic, expr.span);
                if (self.no_lang_trap and conversion_trap == .not_builtin) {
                    if (direct_call) {
                        if (self.summaries.get(callee_name)) |summary| {
                            if (!summary.no_lang_trap) try self.addTrapEdge(.CallMayTrap, .call, expr.span);
                        } else if (!isKnownNoLanguageTrapPrimitive(callee_name) and !isTrapCall(node.callee.*) and !isUnwrapCall(node.callee.*) and !isUncheckedCall(node.callee.*)) {
                            try self.addTrapEdge(.CallMayTrap, .call, expr.span);
                        }
                    } else {
                        try self.addTrapEdge(.CallMayTrap, .call, expr.span);
                    }
                }
                try self.buildExpr(node.callee.*);
                for (node.args, 0..) |arg, index| {
                    if (self.summaries.get(callee_name)) |summary| {
                        if (index < summary.params.len) {
                            const param_ty = valueTypeFromTypeAlias(summary.params[index].ty, self.enums, self.structs, self.packed_bits, self.aliases);
                            const previous_target = self.assignment_target;
                            const previous_target_ty = self.assignment_target_ty;
                            self.assignment_target = "call_arg";
                            self.assignment_target_ty = param_ty;
                            try self.buildExpr(arg);
                            try self.addRepresentationUseForValue(param_ty, "call_arg", arg.span, exprText(arg));
                            self.assignment_target = previous_target;
                            self.assignment_target_ty = previous_target_ty;
                            continue;
                        }
                    }
                    try self.buildExpr(arg);
                }
            },
            .index => |node| {
                try self.addIndexBaseCheck(node.base.*, node.base.span);
                try self.addIndexOperandCheck(node.index.*, node.index.span);
                // OPT (annex E) — const-index bounds-check elision. When optimization is on
                // and the index is a non-negative integer literal `k` into a fixed array of
                // statically-known length `N` with `k < N`, the bounds check provably never
                // traps, so the `cmp_bounds` instruction and its `Bounds` trap edge are
                // omitted. Proof obligation: `k < N` with both compile-time constants —
                // airtight, so the result is identical and a `#[no_lang_trap]` function may
                // now contain the access. Off by default, so the standard MIR is unchanged.
                const elide_bounds = self.optimize and self.indexProvablyInBounds(node.base.*, node.index.*);
                if (elide_bounds) {
                    // Record the operand source point so both backends can skip the emitted
                    // runtime bounds check for exactly this access (they consume the optimized
                    // MIR rather than re-deriving the proof).
                    try self.elided_bounds.append(self.allocator, .{ .line = node.index.span.line, .column = node.index.span.column });
                } else {
                    try self.addInstr(.cmp_bounds, "i < len", .bool, expr.span);
                    try self.addTrapEdge(.Bounds, .bounds_check, expr.span);
                }
                const ty = self.exprType(expr);
                try self.addInstr(.index, if (elide_bounds) "const_in_bounds" else "bounds_checked", ty, expr.span);
                if (representationCheckKind(ty) != null) {
                    try self.addInstr(.typed_load, exprText(expr), ty, expr.span);
                    try self.addRuntimeRepresentationCheck(ty, expr.span, exprText(expr));
                }
                try self.buildExpr(node.base.*);
                try self.buildExpr(node.index.*);
            },
            .slice => |node| {
                try self.addIndexBaseCheck(node.base.*, node.base.span);
                try self.addIndexOperandCheck(node.start.*, node.start.span);
                try self.addIndexOperandCheck(node.end.*, node.end.span);
                // OPT (annex E) — const-slice bounds-check elision. When optimization is on and
                // the range `[k0, k1)` is two non-negative integer literals into a fixed array of
                // statically-known length `N` with `k0 <= k1 <= N`, the `start <= end <= len`
                // check provably never traps, so the `cmp_bounds` instruction and its `Bounds`
                // trap edge are omitted and the slice operand source point is recorded for the
                // backends to skip the emitted check. Off by default; the standard MIR is
                // unchanged.
                const elide_slice = self.optimize and self.sliceProvablyInBounds(node.base.*, node.start.*, node.end.*);
                if (elide_slice) {
                    try self.elided_bounds.append(self.allocator, .{ .line = expr.span.line, .column = expr.span.column });
                } else {
                    try self.addInstr(.cmp_bounds, "start <= end <= len", .bool, expr.span);
                    try self.addTrapEdge(.Bounds, .bounds_check, expr.span);
                }
                try self.addInstr(.index, if (elide_slice) "range_slice_const_in_bounds" else "range_slice", self.exprType(expr), expr.span);
                try self.buildExpr(node.base.*);
                try self.buildExpr(node.start.*);
                try self.buildExpr(node.end.*);
            },
            .member => |node| {
                if (isMirCVoidPointer(self.exprType(node.base.*))) {
                    try self.addInstr(.ffi_check, "c_void_no_layout", .unknown, expr.span);
                }
                const ty = self.exprType(expr);
                if (representationCheckKind(ty) != null) {
                    try self.addInstr(.typed_load, exprText(expr), ty, expr.span);
                    try self.addRuntimeRepresentationCheck(ty, expr.span, exprText(expr));
                }
                try self.addInstr(.expr, node.name.text, ty, expr.span);
                try self.buildExpr(node.base.*);
            },
        }
    }

    fn isKnownDirectCall(self: *FunctionBuilder, callee: ast.Expr, callee_name: []const u8) bool {
        if (isKnownDirectPrimitive(callee_name) or isTrapCall(callee) or isUnwrapCall(callee) or isUncheckedCall(callee)) return true;
        if (directCalleeName(callee) == null) return false;
        if (self.summaries.contains(callee_name)) return true;
        return !self.calleeMayResolveToValue(callee);
    }

    fn calleeName(self: *FunctionBuilder, callee: ast.Expr) []const u8 {
        return self.atomicReceiverCalleeName(callee) orelse
            self.mmioReceiverCalleeName(callee) orelse
            directCalleeName(callee) orelse
            exprText(callee);
    }

    fn atomicReceiverCalleeName(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        return switch (callee.kind) {
            .member => |node| blk: {
                const base_ty = self.typeExprForExpr(node.base.*) orelse break :blk null;
                if (!isAtomicTypeExprAlias(base_ty, self.aliases)) break :blk null;
                if (std.mem.eql(u8, node.name.text, "load")) break :blk "atomic.load";
                if (std.mem.eql(u8, node.name.text, "store")) break :blk "atomic.store";
                if (std.mem.eql(u8, node.name.text, "fetch_add")) break :blk "atomic.fetch_add";
                if (std.mem.eql(u8, node.name.text, "fetch_sub")) break :blk "atomic.fetch_sub";
                break :blk null;
            },
            .grouped => |inner| self.atomicReceiverCalleeName(inner.*),
            else => null,
        };
    }

    fn mmioReceiverCalleeName(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const access_info = self.mmioReceiverAccessInfo(callee) orelse return null;
        return switch (access_info.op) {
            .read => "mmio.read",
            .write => "mmio.write",
        };
    }

    fn mmioReceiverAccessInfo(self: *FunctionBuilder, callee: ast.Expr) ?MmioAccessInfo {
        return switch (callee.kind) {
            .member => |node| blk: {
                const access = self.mmioRegisterAccessForExpr(node.base.*) orelse break :blk null;
                const op: MmioOperation = if (std.mem.eql(u8, node.name.text, "read"))
                    .read
                else if (std.mem.eql(u8, node.name.text, "write"))
                    .write
                else
                    break :blk null;
                break :blk .{ .access = access, .op = op };
            },
            .grouped => |inner| self.mmioReceiverAccessInfo(inner.*),
            else => null,
        };
    }

    fn mmioReceiverReadTypeExpr(self: *FunctionBuilder, callee: ast.Expr) ?ast.TypeExpr {
        return switch (callee.kind) {
            .member => |node| blk: {
                if (!std.mem.eql(u8, node.name.text, "read")) break :blk null;
                const register_ty = self.mmioRegisterTypeExprForExpr(node.base.*) orelse break :blk null;
                break :blk mmioRegisterReadValueTypeExprAlias(register_ty, self.aliases);
            },
            .grouped => |inner| self.mmioReceiverReadTypeExpr(inner.*),
            else => null,
        };
    }

    fn isMmioRegisterExpr(self: *FunctionBuilder, expr: ast.Expr) bool {
        return self.mmioRegisterAccessForExpr(expr) != null;
    }

    fn mmioRegisterTypeExprForExpr(self: *FunctionBuilder, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .member => |node| blk: {
                const base_ty = self.typeExprForExpr(node.base.*) orelse break :blk null;
                const struct_name = mmioPtrTargetTypeNameAlias(base_ty, self.aliases) orelse break :blk null;
                break :blk self.structFieldTypeExpr(struct_name, node.name.text);
            },
            .grouped => |inner| self.mmioRegisterTypeExprForExpr(inner.*),
            else => null,
        };
    }

    fn mmioRegisterAccessForExpr(self: *FunctionBuilder, expr: ast.Expr) ?MmioRegisterAccess {
        const field_ty = self.mmioRegisterTypeExprForExpr(expr) orelse return null;
        return mmioRegisterAccessFromTypeExprAlias(field_ty, self.aliases);
    }

    fn calleeMayResolveToValue(self: *FunctionBuilder, callee: ast.Expr) bool {
        return switch (callee.kind) {
            .ident => |ident| self.local_types.contains(ident.text) or self.globals.contains(ident.text),
            .grouped => |inner| self.calleeMayResolveToValue(inner.*),
            else => false,
        };
    }

    fn addTrapEdge(self: *FunctionBuilder, kind: TrapKind, source: TrapSource, span: ast.Span) !void {
        const from = self.current;
        const trap_block = try self.addBlock("trap");
        self.current = trap_block;
        self.setTerminator(.{ .trap_ = kind });
        self.current = from;
        try self.addSuccessor(from, trap_block);
        try self.trap_edges.append(self.allocator, .{
            .from_block = from,
            .trap_block = trap_block,
            .kind = kind,
            .source = source,
            .line = span.line,
            .column = span.column,
        });
    }

    fn addBinaryTrapEdges(self: *FunctionBuilder, node: anytype, span: ast.Span) !void {
        switch (node.op) {
            .div, .mod => {
                // OPT (annex E): a division/modulo by a non-zero integer literal can never
                // divide by zero; for a signed dividend it also cannot hit the only checked
                // overflow (`INT_MIN / -1`) unless the divisor is `-1`. When the divisor is
                // proven safe both the `DivideByZero` and the signed `IntegerOverflow` checks
                // are dead, so the trap edges are dropped and the divisor source point recorded
                // for the backends to skip the emitted check(s).
                if (self.optimize and self.divModProvablySafe(node)) {
                    try self.elided_bounds.append(self.allocator, .{ .line = node.right.span.line, .column = node.right.span.column });
                } else {
                    try self.addTrapEdge(.DivideByZero, .checked_arithmetic, span);
                    if (isCheckedSignedType(self.exprType(node.left.*))) {
                        try self.addTrapEdge(.IntegerOverflow, .checked_arithmetic, span);
                    }
                }
            },
            .shl => {
                try self.addTrapEdge(.InvalidShift, .checked_shift, span);
                try self.addTrapEdge(.IntegerOverflow, .checked_arithmetic, span);
            },
            .shr => try self.addTrapEdge(.InvalidShift, .checked_shift, span),
            .add, .sub, .mul => try self.addTrapEdge(.IntegerOverflow, .checked_arithmetic, span),
            else => {},
        }
    }

    fn addBlock(self: *FunctionBuilder, kind: []const u8) !usize {
        const id = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{ .id = id, .kind = kind });
        return id;
    }

    fn addSuccessor(self: *FunctionBuilder, from: usize, to: usize) !void {
        for (self.blocks.items[from].successors.items) |existing| {
            if (existing == to) return;
        }
        try self.blocks.items[from].successors.append(self.allocator, to);
    }

    fn addInstr(self: *FunctionBuilder, kind: Instruction.Kind, detail: []const u8, ty: ValueType, span: ast.Span) !void {
        try self.addInstrWithValue(kind, detail, ty, span, null);
    }

    fn addInstrWithValue(self: *FunctionBuilder, kind: Instruction.Kind, detail: []const u8, ty: ValueType, span: ast.Span, value_id: ?[]const u8) !void {
        try self.blocks.items[self.current].instructions.append(self.allocator, .{
            .kind = kind,
            .result_ty = ty,
            .detail = detail,
            .value_id = value_id orelse defaultInstructionValueId(kind, detail),
            .contract_region_id = if (kind == .unchecked_assume) self.active_contract_region_id else null,
            .line = span.line,
            .column = span.column,
        });
    }

    fn addRuntimeRepresentationCheck(self: *FunctionBuilder, ty: ValueType, span: ast.Span, value_id: []const u8) !void {
        try self.addInstrWithValue(.representation_check, representationTypeName(ty), ty, span, value_id);
        if (representationCheckTraps(ty)) {
            try self.addTrapEdge(.InvalidRepresentation, .representation_check, span);
        }
    }

    fn addRangeFactForUncheckedCall(self: *FunctionBuilder, callee_name: []const u8, args: []ast.Expr, span: ast.Span) !void {
        if (self.semantic_expr_depth != 1 and !self.isTopLevelCallArgContext()) return;
        const op = noOverflowUncheckedOp(callee_name) orelse return;
        if (args.len < 2) return;
        const region_id = self.active_contract_region_id orelse return;
        if (self.active_contract == null or !std.mem.eql(u8, self.active_contract.?, "no_overflow")) return;
        try self.range_facts.append(self.allocator, .{
            .region_id = region_id,
            .target = self.assignment_target orelse "value",
            .op = op,
            .left = exprText(args[0]),
            .right = exprText(args[1]),
            .result_ty = self.assignment_target_ty,
            .line = span.line,
            .column = span.column,
        });
    }

    fn addAggregateRangeFactForUncheckedExpr(self: *FunctionBuilder, target: []const u8, result_ty: ValueType, expr: ast.Expr) !void {
        const call = switch (expr.kind) {
            .grouped => |inner| return self.addAggregateRangeFactForUncheckedExpr(target, result_ty, inner.*),
            .cast => |node| return self.addAggregateRangeFactForUncheckedExpr(target, result_ty, node.value.*),
            .call => |node| node,
            else => return,
        };
        const op = noOverflowUncheckedOp(self.calleeName(call.callee.*)) orelse return;
        if (call.args.len < 2) return;
        const region_id = self.active_contract_region_id orelse return;
        if (self.active_contract == null or !std.mem.eql(u8, self.active_contract.?, "no_overflow")) return;
        try self.range_facts.append(self.allocator, .{
            .region_id = region_id,
            .target = target,
            .op = op,
            .left = exprText(call.args[0]),
            .right = exprText(call.args[1]),
            .result_ty = result_ty,
            .line = expr.span.line,
            .column = expr.span.column,
        });
    }

    fn rangeFactTypeForExpr(self: *FunctionBuilder, expr: ast.Expr) ValueType {
        const ty = self.exprType(expr);
        return if (ty == .unknown) self.assignment_target_ty else ty;
    }

    fn isTopLevelCallArgContext(self: *FunctionBuilder) bool {
        const target = self.assignment_target orelse return false;
        return std.mem.eql(u8, target, "call_arg");
    }

    fn addNullabilityConversionCheck(self: *FunctionBuilder, target_ty: ValueType, expr: ast.Expr, span: ast.Span) !void {
        const finding = nullabilityFinding(target_ty, self.exprType(expr)) orelse return;
        try self.addInstr(.nullability_conversion, finding, target_ty, span);
    }

    fn addConversionCheck(self: *FunctionBuilder, target_ty: ValueType, expr: ast.Expr, ctx: ConversionContext, span: ast.Span) !void {
        if (expr.kind == .try_expr) return;
        const source_ty = self.exprType(expr);
        if (nullabilityFinding(target_ty, source_ty) != null) return;
        if (integerLiteralRangeFinding(target_ty, expr)) |finding| {
            try self.addInstr(.conversion_check, finding, .{ .integer = "comptime_int" }, span);
            return;
        }
        if (self.packedBitsRawInitializerRangeFinding(target_ty, expr)) |finding| {
            try self.addInstr(.conversion_check, finding, .{ .integer = "comptime_int" }, span);
            return;
        }
        if (integerLiteralFitsTarget(target_ty, expr)) return;
        if (self.packedBitsRawInitializerFits(target_ty, source_ty, expr)) return;
        if (addressClassMismatch(target_ty, source_ty)) |source_class| {
            const target_class = switch (target_ty) {
                .address => |kind| kind,
                else => unreachable,
            };
            try self.addInstr(.address_conversion, addressClassName(target_class), .{ .address = source_class }, span);
            return;
        }
        if (mirTypesAreCompatible(target_ty, source_ty)) return;
        try self.addInstr(.conversion_check, conversionFinding(ctx, target_ty, source_ty), source_ty, span);
    }

    fn addForIterableCheck(self: *FunctionBuilder, expr: ast.Expr, span: ast.Span) !void {
        const source_ty = self.exprType(expr);
        if (isMirForIterable(source_ty)) return;
        try self.addInstr(.conversion_check, "for_base_not_iterable", source_ty, span);
    }

    fn addIndexBaseCheck(self: *FunctionBuilder, expr: ast.Expr, span: ast.Span) !void {
        const source_ty = self.exprType(expr);
        if (isMirIndexableBase(source_ty)) return;
        try self.addInstr(.conversion_check, "index_base_not_array_or_slice", source_ty, span);
    }

    fn addIndexOperandCheck(self: *FunctionBuilder, expr: ast.Expr, span: ast.Span) !void {
        const source_ty = self.exprType(expr);
        if (isMirIndexType(source_ty)) return;
        try self.addInstr(.conversion_check, "index_not_usize", source_ty, span);
    }

    fn addTargetRepresentationCheck(self: *FunctionBuilder, target_ty: ValueType, expr: ast.Expr, span: ast.Span) !void {
        if (representationCheckKind(target_ty) == null) return;
        if (!exprNeedsTargetRepresentationCheck(expr)) return;
        try self.addInstrWithValue(.representation_check, representationTypeName(target_ty), target_ty, span, exprText(expr));
    }

    fn addRepresentationUse(self: *FunctionBuilder, target_ty: ValueType, detail: []const u8, span: ast.Span) !void {
        if (representationCheckKind(target_ty) == null) return;
        try self.addInstr(.representation_use, detail, target_ty, span);
    }

    fn addRepresentationUseForValue(self: *FunctionBuilder, target_ty: ValueType, detail: []const u8, span: ast.Span, value_id: []const u8) !void {
        if (representationCheckKind(target_ty) == null) return;
        try self.addInstrWithValue(.representation_use, detail, target_ty, span, value_id);
    }

    fn addRepresentationUseForExpr(self: *FunctionBuilder, detail: []const u8, expr: ast.Expr) !void {
        const ty = self.exprType(expr);
        if (representationCheckKind(ty) == null) return;
        try self.addRepresentationUseForValue(ty, detail, expr.span, exprText(expr));
    }

    fn exprNeedsTargetRepresentationCheck(expr: ast.Expr) bool {
        return switch (expr.kind) {
            .enum_literal => true,
            .grouped => |inner| exprNeedsTargetRepresentationCheck(inner.*),
            .cast => |node| exprNeedsTargetRepresentationCheck(node.value.*),
            .address_of => true,
            .call => true,
            .member, .index, .slice, .deref => true,
            // A string literal is a non-null pointer to static storage by
            // construction, so its representation is statically proven at the
            // target site (like address_of); emitting the dominating check
            // discharges the nonnull_pointer obligation.
            .string_literal => true,
            else => false,
        };
    }

    fn packedBitsRawInitializerRangeFinding(self: *FunctionBuilder, target_ty: ValueType, expr: ast.Expr) ?[]const u8 {
        const repr_ty = self.packedBitsReprType(target_ty) orelse return null;
        return integerLiteralRangeFinding(repr_ty, expr);
    }

    fn packedBitsRawInitializerFits(self: *FunctionBuilder, target_ty: ValueType, source_ty: ValueType, expr: ast.Expr) bool {
        const repr_ty = self.packedBitsReprType(target_ty) orelse return false;
        if (integerLiteralValue(expr) != null) return integerLiteralRangeFinding(repr_ty, expr) == null;
        return switch (source_ty) {
            .integer => true,
            else => false,
        };
    }

    fn packedBitsReprType(self: *FunctionBuilder, target_ty: ValueType) ?ValueType {
        const name = switch (target_ty) {
            .struct_ => |name| name,
            else => return null,
        };
        const info = self.packed_bits.get(name) orelse return null;
        return valueTypeFromTypeAlias(info.repr, self.enums, self.structs, self.packed_bits, self.aliases);
    }

    fn addAggregateConversionChecks(self: *FunctionBuilder, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: ConversionContext) !void {
        switch (expr.kind) {
            .grouped => |inner| return self.addAggregateConversionChecks(target_ty, inner.*, ctx),
            .cast => |node| return self.addAggregateConversionChecks(node.ty.*, node.value.*, ctx),
            else => {},
        }

        const normalized_target = aggregateTargetTypeAlias(target_ty, self.aliases);
        switch (expr.kind) {
            .array_literal => |items| {
                const child_ty = arrayElementTypeAlias(normalized_target, self.aliases) orelse return;
                try self.addArrayLiteralShapeCheck(normalized_target, items.len, expr.span);
                const child_value_ty = valueTypeFromTypeAlias(child_ty, self.enums, self.structs, self.packed_bits, self.aliases);
                for (items) |item| {
                    try self.addNullabilityConversionCheck(child_value_ty, item, item.span);
                    try self.addConversionCheck(child_value_ty, item, ctx, item.span);
                    try self.addResultPayloadConversionCheck(child_value_ty, item, item.span);
                    try self.addTargetRepresentationCheck(child_value_ty, item, item.span);
                    if (exprNeedsTargetRepresentationCheck(item)) try self.addRepresentationUseForValue(child_value_ty, "aggregate_element", item.span, exprText(item));
                    try self.addAggregateRangeFactForUncheckedExpr("aggregate_element", child_value_ty, item);
                    try self.addAggregateConversionChecks(child_ty, item, ctx);
                }
            },
            .struct_literal => |fields| {
                const struct_name = structTypeNameAlias(normalized_target, self.aliases) orelse return;
                try self.addStructLiteralShapeChecks(struct_name, fields, expr.span);
                for (fields) |field| {
                    const field_ty = self.structFieldTypeExpr(struct_name, field.name.text) orelse continue;
                    const field_value_ty = valueTypeFromTypeAlias(field_ty, self.enums, self.structs, self.packed_bits, self.aliases);
                    try self.addNullabilityConversionCheck(field_value_ty, field.value, field.value.span);
                    try self.addConversionCheck(field_value_ty, field.value, ctx, field.value.span);
                    try self.addResultPayloadConversionCheck(field_value_ty, field.value, field.value.span);
                    try self.addTargetRepresentationCheck(field_value_ty, field.value, field.value.span);
                    if (exprNeedsTargetRepresentationCheck(field.value)) try self.addRepresentationUseForValue(field_value_ty, "aggregate_field", field.value.span, exprText(field.value));
                    try self.addAggregateRangeFactForUncheckedExpr(field.name.text, field_value_ty, field.value);
                    try self.addAggregateConversionChecks(field_ty, field.value, ctx);
                }
            },
            else => {},
        }
    }

    // OPT (annex E) proof obligation for const-index bounds-check elision: the index is a
    // non-negative integer literal `k`, the base names a fixed array of statically-known
    // length `N`, and `k < N`. All three are compile-time constants, so the bounds check
    // provably never traps. Conservative: returns false for any non-literal index or any
    // base whose length is not statically known (the check is then kept).
    fn indexProvablyInBounds(self: *FunctionBuilder, base: ast.Expr, index: ast.Expr) bool {
        const k = integerLiteralValue(index) orelse return false;
        if (k.negative) return false;
        const n = self.baseArrayLen(base) orelse return false;
        return k.magnitude < n;
    }

    // OPT (annex E) proof obligation for const-slice bounds elision: the range `[start, end)` is
    // two non-negative integer literals into a fixed array of statically-known length `N`, with
    // `start <= end <= N`. Conservative: false for any non-literal/negative bound or an unknown
    // base length, so it can never prove an out-of-range slice in-bounds.
    fn sliceProvablyInBounds(self: *FunctionBuilder, base: ast.Expr, start: ast.Expr, end: ast.Expr) bool {
        const lo = integerLiteralValue(start) orelse return false;
        if (lo.negative) return false;
        const hi = integerLiteralValue(end) orelse return false;
        if (hi.negative) return false;
        if (lo.magnitude > hi.magnitude) return false; // start <= end
        const n = self.baseArrayLen(base) orelse return false;
        return hi.magnitude <= n; // end <= len
    }

    // OPT (annex E) proof obligation for divide-by-zero elision: the division is on an
    // unsigned checked integer (no signed INT_MIN/-1 overflow case) and the divisor is a
    // non-zero integer literal — so it can never trap. Conservative: false for a signed
    // operand or any non-literal/zero divisor, keeping the check.
    // OPT (annex E) proof obligation for divide/modulo check elision: the divisor is
    // a non-zero integer literal. For an unsigned dividend that is the whole proof —
    // there is no INT_MIN/-1 overflow case. For a signed dividend the only checked
    // overflow is `INT_MIN / -1`, so the divisor must additionally not be `-1`; every
    // other non-zero literal divisor is safe. Conservative: false for any non-literal
    // or zero divisor (keeping both checks).
    fn divModProvablySafe(self: *FunctionBuilder, node: anytype) bool {
        const d = integerLiteralValue(node.right.*) orelse return false;
        if (d.magnitude == 0) return false;
        if (isCheckedSignedType(self.exprType(node.left.*))) {
            // Signed: safe for any non-zero divisor except `-1` (the INT_MIN overflow).
            return !(d.negative and d.magnitude == 1);
        }
        // Unsigned: any non-zero, non-negative literal divisor is safe.
        return !d.negative;
    }

    fn baseArrayLen(self: *FunctionBuilder, base: ast.Expr) ?usize {
        const ty = self.baseTypeExpr(base) orelse return null;
        const array = switch (aggregateTargetTypeAlias(ty, self.aliases).kind) {
            .array => |node| node,
            else => return null,
        };
        return parseArrayLen(array.len, self.const_fns, self.const_globals);
    }

    // The declared AST type of an index base, when it is a local/param/global name (the
    // cases whose array length is statically recoverable). A more general place analysis
    // could cover fields and nested indexing; this conservative subset is enough for the
    // first transform and never proves an out-of-range access in-bounds.
    fn baseTypeExpr(self: *FunctionBuilder, base: ast.Expr) ?ast.TypeExpr {
        return switch (base.kind) {
            .ident => |id| self.local_type_exprs.get(id.text) orelse self.global_type_exprs.get(id.text),
            .grouped => |inner| self.baseTypeExpr(inner.*),
            // A struct-field array base (`x.field[k]`): resolve the base's struct type (through
            // a pointer/alias) and look up the field's declared type, so a constant index into
            // a fixed-size struct field elides its bounds check too.
            .member => |m| {
                const base_ty = self.baseTypeExpr(m.base.*) orelse return null;
                const struct_name = structTypeNameAlias(base_ty, self.aliases) orelse return null;
                return self.structFieldTypeExpr(struct_name, m.name.text);
            },
            else => null,
        };
    }

    fn addArrayLiteralShapeCheck(self: *FunctionBuilder, target_ty: ast.TypeExpr, item_count: usize, span: ast.Span) !void {
        const array = switch (aggregateTargetTypeAlias(target_ty, self.aliases).kind) {
            .array => |node| node,
            else => return,
        };
        const expected_len = parseArrayLen(array.len, self.const_fns, self.const_globals) orelse {
            try self.addInstr(.aggregate_check, "array_literal_length", valueTypeFromTypeAlias(target_ty, self.enums, self.structs, self.packed_bits, self.aliases), span);
            return;
        };
        if (item_count != expected_len) {
            try self.addInstr(.aggregate_check, "array_literal_length", valueTypeFromTypeAlias(target_ty, self.enums, self.structs, self.packed_bits, self.aliases), span);
        }
    }

    fn addStructLiteralShapeChecks(self: *FunctionBuilder, struct_name: []const u8, fields: []const ast.StructLiteralField, span: ast.Span) !void {
        const expected_fields = if (self.structs.get(struct_name)) |info|
            info.fields
        else if (self.packed_bits.get(struct_name)) |info|
            info.fields
        else
            return;
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var has_unknown_field = false;

        for (fields) |field| {
            if (seen.contains(field.name.text)) {
                try self.addInstr(.aggregate_check, "struct_literal_duplicate_field", .{ .struct_ = struct_name }, field.name.span);
            } else {
                try seen.put(field.name.text, {});
            }
            if (self.structFieldTypeExpr(struct_name, field.name.text) == null) {
                has_unknown_field = true;
                try self.addInstr(.aggregate_check, "struct_literal_unknown_field", .{ .struct_ = struct_name }, field.name.span);
            }
        }

        if (has_unknown_field) return;
        for (expected_fields) |field| {
            if (!seen.contains(field.name.text)) {
                try self.addInstr(.aggregate_check, "struct_literal_missing_field", .{ .struct_ = struct_name }, span);
            }
        }
    }

    fn addUnhandledResultChecksForBlock(self: *FunctionBuilder, block: ast.Block) !void {
        for (block.items, 0..) |stmt, i| {
            const local = switch (stmt.kind) {
                .let_decl, .var_decl => |local| local,
                else => continue,
            };
            if (local.init == null) continue;
            const local_ty = if (local.ty) |local_ty| valueTypeFromTypeAlias(local_ty, self.enums, self.structs, self.packed_bits, self.aliases) else self.exprType(local.init.?);
            if (!isResultType(local_ty)) continue;
            for (local.names) |name| {
                if (!self.resultLocalHandledLater(name.text, block.items[i + 1 ..])) {
                    try self.addInstr(.result_check, "unhandled_result", unknownResultType(), name.span);
                }
            }
        }

        for (block.items, 0..) |stmt, i| {
            const assignment = switch (stmt.kind) {
                .assignment => |assignment| assignment,
                else => continue,
            };
            const target_name = directIdentName(assignment.target) orelse continue;
            if (!isResultType(self.typeForAssignmentTarget(assignment.target)) or !isResultType(self.exprType(assignment.value))) continue;
            if (self.resultLocalHasPendingValueBefore(target_name, block.items[0..i])) {
                try self.addInstr(.result_check, "unhandled_result", unknownResultType(), assignment.target.span);
            }
            if (!self.resultLocalHandledLater(target_name, block.items[i + 1 ..])) {
                try self.addInstr(.result_check, "unhandled_result", unknownResultType(), assignment.value.span);
            }
        }
    }

    fn addResultExpressionStatementCheck(self: *FunctionBuilder, expr: ast.Expr) !void {
        if (!isResultType(self.exprType(expr))) return;
        if (exprHandlesAnyResult(expr)) return;
        try self.addInstr(.result_check, "unhandled_result", unknownResultType(), expr.span);
    }

    fn addResultDeferCheck(self: *FunctionBuilder, expr: ast.Expr) !void {
        if (!isResultType(self.exprType(expr))) return;
        if (exprHandlesAnyResult(expr)) return;
        try self.addInstr(.result_check, "unhandled_result", unknownResultType(), expr.span);
    }

    fn addResultPayloadConversionCheck(self: *FunctionBuilder, target_ty: ValueType, expr: ast.Expr, span: ast.Span) !void {
        switch (expr.kind) {
            .grouped => |inner| return self.addResultPayloadConversionCheck(target_ty, inner.*, span),
            .cast => |node| return self.addResultPayloadConversionCheck(valueTypeFromTypeAlias(node.ty.*, self.enums, self.structs, self.packed_bits, self.aliases), node.value.*, span),
            .try_expr => {},
            else => return,
        }
        const source_ty = self.exprType(expr);
        if (!mirTypesAreCompatible(target_ty, source_ty)) {
            const finding = if (isCVoidPointerConversion(target_ty, source_ty)) "try_payload_c_void_conversion" else if (isPointerViewConversion(target_ty, source_ty)) "try_payload_pointer_conversion" else "try_payload_type_mismatch";
            try self.addInstr(.result_check, finding, source_ty, span);
        }
    }

    fn resultLocalHandledLater(self: *FunctionBuilder, name: []const u8, stmts: []const ast.Stmt) bool {
        for (stmts) |stmt| {
            if (self.stmtHandlesResultLocal(name, stmt)) return true;
        }
        return false;
    }

    fn resultLocalHasPendingValueBefore(self: *FunctionBuilder, name: []const u8, stmts: []const ast.Stmt) bool {
        var pending = false;
        for (stmts) |stmt| {
            if (self.stmtHandlesResultLocal(name, stmt)) {
                pending = false;
                continue;
            }
            switch (stmt.kind) {
                .let_decl, .var_decl => |local| {
                    if (!localDeclaresName(local, name)) continue;
                    const ty = if (local.ty) |local_ty| valueTypeFromTypeAlias(local_ty, self.enums, self.structs, self.packed_bits, self.aliases) else if (local.init) |init_expr| self.exprType(init_expr) else .unknown;
                    if (isResultType(ty) and local.init != null) pending = true;
                },
                .assignment => |assignment| {
                    if (!exprIsIdentNamed(assignment.target, name)) continue;
                    pending = isResultType(self.exprType(assignment.value));
                },
                else => {},
            }
        }
        return pending;
    }

    fn stmtHandlesResultLocal(self: *FunctionBuilder, name: []const u8, stmt: ast.Stmt) bool {
        return switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.init) |expr| self.exprHandlesResultLocal(name, expr) else false,
            .loop => |node| if (node.iterable) |iterable| self.exprHandlesResultLocal(name, iterable) else false,
            .if_let => |node| resultIfLetHandlesLocal(name, node) or self.exprHandlesResultLocal(name, node.value),
            .@"switch" => |node| resultSwitchHandlesLocal(name, node) or switchArmBodiesHandleResultLocal(self, name, node) or self.exprHandlesResultLocal(name, node.subject),
            .unsafe_block, .comptime_block, .block => |body| self.blockHandlesResultLocal(name, body),
            .contract_block => |contract| self.blockHandlesResultLocal(name, contract.block),
            .@"return" => |maybe| if (maybe) |expr| self.exprHandlesResultLocal(name, expr) else false,
            .@"break", .@"continue", .asm_stmt => false,
            .@"defer", .expr, .assert => |expr| self.exprHandlesResultLocal(name, expr),
            .assignment => |node| self.exprHandlesResultLocal(name, node.target) or self.exprHandlesResultLocal(name, node.value),
        };
    }

    fn blockHandlesResultLocal(self: *FunctionBuilder, name: []const u8, block: ast.Block) bool {
        for (block.items) |stmt| {
            if (self.stmtHandlesResultLocal(name, stmt)) return true;
        }
        return false;
    }

    fn exprHandlesResultLocal(self: *FunctionBuilder, name: []const u8, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .try_expr => |inner| exprIsIdentNamed(inner.operand.*, name) or self.exprHandlesResultLocal(name, inner.operand.*),
            .grouped, .address_of, .deref => |inner| self.exprHandlesResultLocal(name, inner.*),
            .block => |body| self.blockHandlesResultLocal(name, body),
            .array_literal => |items| {
                for (items) |item| {
                    if (self.exprHandlesResultLocal(name, item)) return true;
                }
                return false;
            },
            .struct_literal => |fields| {
                for (fields) |field| {
                    if (self.exprHandlesResultLocal(name, field.value)) return true;
                }
                return false;
            },
            .unary => |node| self.exprHandlesResultLocal(name, node.expr.*),
            .binary => |node| self.exprHandlesResultLocal(name, node.left.*) or self.exprHandlesResultLocal(name, node.right.*),
            .cast => |node| self.exprHandlesResultLocal(name, node.value.*),
            .call => |node| self.callHandlesResultLocal(name, node),
            .index => |node| self.exprHandlesResultLocal(name, node.base.*) or self.exprHandlesResultLocal(name, node.index.*),
            .slice => |node| self.exprHandlesResultLocal(name, node.base.*) or self.exprHandlesResultLocal(name, node.start.*) or self.exprHandlesResultLocal(name, node.end.*),
            .member => |node| self.exprHandlesResultLocal(name, node.base.*),
            else => false,
        };
    }

    fn callHandlesResultLocal(self: *FunctionBuilder, name: []const u8, node: anytype) bool {
        if (self.exprHandlesResultLocal(name, node.callee.*)) return true;
        for (node.args) |arg| {
            if (self.exprHandlesResultLocal(name, arg)) return true;
        }
        return false;
    }

    fn setTerminator(self: *FunctionBuilder, terminator: Terminator) void {
        self.blocks.items[self.current].terminator = terminator;
    }

    fn exprIsWrap(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.wrap_values.contains(ident.text),
            .grouped => |inner| self.exprIsWrap(inner.*),
            .cast => |node| isWrapTypeAlias(node.ty.*, self.aliases),
            .binary => |node| isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*),
            else => false,
        };
    }

    fn exprIsSat(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.sat_values.contains(ident.text),
            .grouped => |inner| self.exprIsSat(inner.*),
            .cast => |node| isSatTypeAlias(node.ty.*, self.aliases),
            .binary => |node| isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*),
            else => false,
        };
    }

    fn binaryIsNoTrapArithmeticDomain(self: *FunctionBuilder, node: anytype) bool {
        if (isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*)) return true;
        if (isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*)) return true;
        return false;
    }

    // IEEE floating-point arithmetic never raises a language trap (overflow and
    // divide-by-zero yield inf/NaN), so float `+ - * /` and unary `-` emit no
    // trap edge.
    fn exprIsFloat(self: *FunctionBuilder, expr: ast.Expr) bool {
        return std.meta.activeTag(self.exprType(expr)) == .float;
    }

    fn binaryIsFloat(self: *FunctionBuilder, node: anytype) bool {
        return self.exprIsFloat(node.left.*) or self.exprIsFloat(node.right.*);
    }

    // D.1 operation legality for static scalar/domain calls (`S.before(...)`,
    // `u32.from(...)`, ...): rejects an operation name that is not defined for the
    // base type's domain. Value-method calls and non-type bases are left alone.
    fn domainConversionCallFinding(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| return self.domainConversionCallFinding(inner.*),
            else => return null,
        };
        const ident = switch (member.base.*.kind) {
            .ident => |id| id,
            else => return null,
        };
        if (self.local_types.contains(ident.text) or self.globals.contains(ident.text)) return null;
        const op = member.name.text;
        const name_ty = ast.TypeExpr{ .span = ident.span, .kind = .{ .name = ident } };
        if (arithmeticDomainTypeAlias(name_ty, self.aliases)) |domain| {
            return switch (domain) {
                .serial => if (!isMirSerialOpName(op) and !isMirConversionName(op)) "serial_operation" else null,
                .counter => if (!isMirCounterOpName(op) and !isMirConversionName(op)) "counter_operation" else null,
                .wrap, .sat => if (!isMirConversionName(op)) "conversion_operation" else null,
            };
        }
        if (self.resolvesToScalarInt(ident.text, 0) and !isMirConversionName(op)) return "conversion_operation";
        return null;
    }

    // D-pass operation legality for typed-resource calls: unknown atomic method
    // on an atomic value, and `.raw()` on a closed enum.
    fn typedResourceCallFinding(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| return self.typedResourceCallFinding(inner.*),
            else => return null,
        };
        const m = member.name.text;
        if (self.typeExprForExpr(member.base.*)) |base_ty| {
            if (isAtomicTypeExprAlias(base_ty, self.aliases)) {
                if (!std.mem.eql(u8, m, "load") and !std.mem.eql(u8, m, "store") and !std.mem.eql(u8, m, "fetch_add") and !std.mem.eql(u8, m, "fetch_sub")) return "atomic_operation";
                return null;
            }
        }
        if (std.mem.eql(u8, m, "raw")) {
            if (self.enumSummaryForType(self.exprType(member.base.*))) |info| {
                if (!info.is_open) return "enum_raw_closed";
            }
        }
        return null;
    }

    // Validates the memory-ordering argument of an atomic load/store/RMW
    // (section 19): load forbids release, store forbids acquire.
    fn atomicOrderingFinding(self: *FunctionBuilder, callee: ast.Expr, args: []ast.Expr) ?[]const u8 {
        const name = self.atomicReceiverCalleeName(callee) orelse return null;
        const ordering_idx: usize = if (std.mem.eql(u8, name, "atomic.load")) 0 else 1;
        if (args.len <= ordering_idx) return null;
        const ord = enumLiteralText(args[ordering_idx]) orelse return "atomic_ordering";
        const ok = if (std.mem.eql(u8, name, "atomic.load"))
            isMirAtomicLoadOrdering(ord)
        else if (std.mem.eql(u8, name, "atomic.store"))
            isMirAtomicStoreOrdering(ord)
        else
            isMirAtomicOrdering(ord);
        return if (ok) null else "atomic_ordering";
    }

    // Validates the ordering argument of a typed MMIO read/write (section 17):
    // read allows .relaxed/.acquire, write allows .relaxed/.release.
    fn mmioOrderingFinding(self: *FunctionBuilder, callee: ast.Expr, args: []ast.Expr) ?[]const u8 {
        const info = self.mmioReceiverAccessInfo(callee) orelse return null;
        const idx: usize = if (info.op == .read) 0 else 1;
        if (args.len <= idx) return null;
        const ord = enumLiteralText(args[idx]) orelse return "mmio_ordering";
        const ok = if (info.op == .read) isMirMmioReadOrdering(ord) else isMirMmioWriteOrdering(ord);
        return if (ok) null else "mmio_ordering";
    }

    // cache.clean/invalidate are required only for noncoherent DmaBuf values
    // (section 18); calling them on a coherent buffer is rejected.
    fn dmaCacheModeFinding(self: *FunctionBuilder, callee: ast.Expr, args: []ast.Expr) ?[]const u8 {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| return self.dmaCacheModeFinding(inner.*, args),
            else => return null,
        };
        const base_is_cache = switch (member.base.*.kind) {
            .ident => |id| std.mem.eql(u8, id.text, "cache"),
            else => false,
        };
        if (!base_is_cache) return null;
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (args.len == 0) return null;
        const buf_ty = self.typeExprForExpr(args[0]) orelse return null;
        const mode = dmaBufModeName(buf_ty, self.aliases) orelse return null;
        if (!std.mem.eql(u8, mode, "noncoherent")) return "dma_cache_mode";
        return null;
    }

    // Escape analysis (section 2), matching sema's localStorageRoot: the address
    // of a `let`/`var` local (via member access), or of a local/param *array*
    // element (via index) — but NOT through a slice/pointer — escapes. Provenance
    // flows through `let p = &local`.
    fn addressOriginIsLocal(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .address_of => |inner| self.escapeStorageRoot(inner.*),
            .ident => |id| self.local_address_origin.contains(id.text),
            .grouped => |inner| self.addressOriginIsLocal(inner.*),
            else => false,
        };
    }

    fn escapeStorageRoot(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |id| self.let_local_names.contains(id.text),
            .member => |node| self.escapeStorageRoot(node.base.*),
            .index => |node| self.indexedArrayStorageRoot(node.base.*),
            .slice => |node| self.indexedArrayStorageRoot(node.base.*),
            .grouped => |inner| self.escapeStorageRoot(inner.*),
            else => false,
        };
    }

    fn indexedArrayStorageRoot(self: *FunctionBuilder, expr: ast.Expr) bool {
        if (std.meta.activeTag(self.exprType(expr)) != .array) return false;
        return switch (expr.kind) {
            .ident => |id| self.local_types.contains(id.text),
            .grouped => |inner| self.indexedArrayStorageRoot(inner.*),
            else => self.escapeStorageRoot(expr),
        };
    }

    fn resolvesToScalarInt(self: *FunctionBuilder, name: []const u8, depth: usize) bool {
        if (depth > 64) return false;
        if (checkedIntBoundsByName(name) != null) return true;
        const target = self.aliases.get(name) orelse return false;
        return switch (target.kind) {
            .name => |n| self.resolvesToScalarInt(n.text, depth + 1),
            else => false,
        };
    }

    fn typeForAssignmentTarget(self: *FunctionBuilder, target: ast.Expr) ValueType {
        if (self.typeExprForAssignmentTarget(target)) |ty| return valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases);
        return switch (target.kind) {
            .ident => |ident| self.local_types.get(ident.text) orelse self.globals.get(ident.text) orelse .unknown,
            .member => |node| self.memberType(node),
            .grouped => |inner| self.typeForAssignmentTarget(inner.*),
            else => .unknown,
        };
    }

    fn typeExprForAssignmentTarget(self: *FunctionBuilder, target: ast.Expr) ?ast.TypeExpr {
        return switch (target.kind) {
            .ident => |ident| self.local_type_exprs.get(ident.text) orelse self.global_type_exprs.get(ident.text),
            .member => |node| blk: {
                const base_ty = self.typeExprForExpr(node.base.*) orelse break :blk null;
                const struct_name = structTypeNameAlias(base_ty, self.aliases) orelse break :blk null;
                break :blk self.structFieldTypeExpr(struct_name, node.name.text);
            },
            .deref => |inner| if (self.typeExprForExpr(inner.*)) |base_ty| storageElementTypeAlias(base_ty, self.aliases) else null,
            .index => |node| if (self.typeExprForExpr(node.base.*)) |base_ty| storageElementTypeAlias(base_ty, self.aliases) else null,
            .slice => |node| if (self.typeExprForExpr(node.base.*)) |base_ty| sliceTypeForBaseAlias(base_ty, node.base.*.span, self.aliases) else null,
            .grouped => |inner| self.typeExprForAssignmentTarget(inner.*),
            else => null,
        };
    }

    fn typeExprForExpr(self: *FunctionBuilder, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.local_type_exprs.get(ident.text) orelse self.global_type_exprs.get(ident.text),
            .member => |node| blk: {
                const base_ty = self.typeExprForExpr(node.base.*) orelse break :blk null;
                const struct_name = structTypeNameAlias(base_ty, self.aliases) orelse break :blk null;
                break :blk self.structFieldTypeExpr(struct_name, node.name.text);
            },
            .call => |node| self.mmioReceiverReadTypeExpr(node.callee.*) orelse
                mmioMapCallPayloadType(node) orelse
                reduceCallReturnTypeExpr(node) orelse
                self.constGetCallTypeExpr(node) orelse
                self.ptrOffsetReceiverTypeExpr(node.callee.*) orelse
                if (self.summaries.get(self.calleeName(node.callee.*))) |summary| summary.return_type_expr else null,
            .deref => |inner| if (self.typeExprForExpr(inner.*)) |base_ty| storageElementTypeAlias(base_ty, self.aliases) else null,
            .index => |node| if (self.typeExprForExpr(node.base.*)) |base_ty| storageElementTypeAlias(base_ty, self.aliases) else null,
            .slice => |node| if (self.typeExprForExpr(node.base.*)) |base_ty| sliceTypeForBaseAlias(base_ty, node.base.*.span, self.aliases) else null,
            .grouped => |inner| self.typeExprForExpr(inner.*),
            .cast => |node| node.ty.*,
            .try_expr => |inner| if (mmioMapPayloadTypeForExpr(inner.operand.*)) |ty| ty else if (self.typeExprForExpr(inner.operand.*)) |ty| tryPayloadTypeExprAlias(ty, self.aliases) else null,
            else => null,
        };
    }

    fn exprType(self: *FunctionBuilder, expr: ast.Expr) ValueType {
        return switch (expr.kind) {
            .ident => |ident| self.local_types.get(ident.text) orelse self.globals.get(ident.text) orelse valueTypeFromExpr(expr),
            .grouped => |inner| self.exprType(inner.*),
            .cast => |node| valueTypeFromTypeAlias(node.ty.*, self.enums, self.structs, self.packed_bits, self.aliases),
            .call => |node| if (self.mmioReceiverReadTypeExpr(node.callee.*)) |ty|
                valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases)
            else if (self.constGetCallType(node)) |ty|
                ty
            else if (self.ptrOffsetReceiverType(node.callee.*)) |ty|
                ty
            else if (mmioMapCallPayloadType(node)) |ty|
                .{ .nullable_pointer = .{ .kind = .single, .mutability = .none, .child = typeText(ty) } }
            else if (reduceCallReturnTypeExpr(node)) |ty|
                valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases)
            else if (directCalleeName(node.callee.*)) |callee|
                if (self.summaries.get(callee)) |summary| summary.return_ty else .unknown
            else
                .unknown,
            .try_expr => |inner| if (mmioMapPayloadTypeForExpr(inner.operand.*)) |ty|
                valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases)
            else switch (self.exprType(inner.operand.*)) {
                .nullable_pointer => |name| .{ .pointer = name },
                .result => |shape| valueTypeFromTypeName(shape.ok, self.enums, self.structs),
                else => .unknown,
            },
            .unary => |node| switch (node.op) {
                .logical_not => .bool,
                .neg, .bit_not => self.exprType(node.expr.*),
            },
            .binary => |node| if (mirIsLogicalBinary(node.op) or mirIsComparisonBinary(node.op))
                .bool
            else
                self.exprType(node.left.*),
            .member => |node| self.memberType(node),
            .deref, .index, .slice => if (self.typeExprForExpr(expr)) |ty|
                valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases)
            else
                .unknown,
            else => valueTypeFromExpr(expr),
        };
    }

    fn memberType(self: *FunctionBuilder, node: anytype) ValueType {
        return switch (self.exprType(node.base.*)) {
            .struct_ => |name| self.structFieldType(name, node.name.text) orelse .value,
            // Member access auto-derefs a pointer-to-struct (`q.field` over
            // `q: *Virtq`), so resolve the field on the pointee struct.
            .pointer, .nullable_pointer => |shape| self.structFieldType(shape.child, node.name.text) orelse .value,
            else => .value,
        };
    }

    fn constGetCallType(self: *FunctionBuilder, call: anytype) ?ValueType {
        const ty = self.constGetCallTypeExpr(call) orelse return null;
        return valueTypeFromTypeAlias(ty, self.enums, self.structs, self.packed_bits, self.aliases);
    }

    fn constGetCallTypeExpr(self: *FunctionBuilder, call: anytype) ?ast.TypeExpr {
        const base = constGetBase(call) orelse return null;
        const base_ty = self.typeExprForExpr(base.*) orelse return null;
        return storageElementTypeAlias(base_ty, self.aliases);
    }

    fn ptrOffsetReceiverTypeExpr(self: *FunctionBuilder, callee: ast.Expr) ?ast.TypeExpr {
        return switch (callee.kind) {
            .member => |node| if (std.mem.eql(u8, node.name.text, "offset")) self.typeExprForExpr(node.base.*) else null,
            .grouped => |inner| self.ptrOffsetReceiverTypeExpr(inner.*),
            else => null,
        };
    }

    fn ptrOffsetReceiverType(self: *FunctionBuilder, callee: ast.Expr) ?ValueType {
        return switch (callee.kind) {
            .member => |node| blk: {
                if (!std.mem.eql(u8, node.name.text, "offset")) break :blk null;
                const base_ty = self.exprType(node.base.*);
                break :blk if (isRawManyPointerValue(base_ty)) base_ty else null;
            },
            .grouped => |inner| self.ptrOffsetReceiverType(inner.*),
            else => null,
        };
    }

    fn structFieldType(self: *FunctionBuilder, struct_name: []const u8, field_name: []const u8) ?ValueType {
        if (self.structs.get(struct_name)) |info| {
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name.text, field_name)) return valueTypeFromTypeAlias(field.ty, self.enums, self.structs, self.packed_bits, self.aliases);
            }
        }
        if (self.packed_bits.get(struct_name)) |info| {
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name.text, field_name)) return valueTypeFromTypeAlias(field.ty, self.enums, self.structs, self.packed_bits, self.aliases);
            }
        }
        return null;
    }

    fn structFieldTypeExpr(self: *FunctionBuilder, struct_name: []const u8, field_name: []const u8) ?ast.TypeExpr {
        if (self.structs.get(struct_name)) |info| {
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
            }
        }
        if (self.packed_bits.get(struct_name)) |info| {
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
            }
        }
        return null;
    }
};

fn freeFunction(allocator: std.mem.Allocator, function: Function) void {
    for (function.blocks) |block| {
        allocator.free(block.instructions);
        allocator.free(block.successors);
    }
    allocator.free(function.blocks);
    allocator.free(function.trap_edges);
    allocator.free(function.contract_regions);
    allocator.free(function.range_facts);
    allocator.free(function.elided_bounds);
}

fn functionFallsThrough(function: Function) ?SourcePoint {
    if (isVoidLike(function.return_ty)) return null;
    var stack_buf: [512]usize = undefined;
    var seen_buf: [512]bool = [_]bool{false} ** 512;
    if (function.blocks.len > stack_buf.len or function.blocks.len == 0) return null;

    var stack_len: usize = 1;
    stack_buf[0] = 0;
    seen_buf[0] = true;

    while (stack_len > 0) {
        stack_len -= 1;
        const id = stack_buf[stack_len];
        const block = function.blocks[id];
        if (block.successors.len == 0 and block.terminator == .fallthrough) return blockLastSpan(block);
        for (block.successors) |successor| {
            if (successor >= function.blocks.len or seen_buf[successor]) continue;
            seen_buf[successor] = true;
            stack_buf[stack_len] = successor;
            stack_len += 1;
        }
    }
    return null;
}

fn cfgHasStructuralError(function: Function) ?SourcePoint {
    if (function.blocks.len == 0) return null;
    for (function.blocks, 0..) |block, block_index| {
        if (block.id != block_index) return blockLastSpan(block);
        for (block.successors) |successor| {
            if (successor >= function.blocks.len) return blockLastSpan(block);
        }
        if (!terminatorSuccessorsAreConsistent(function, block)) return blockLastSpan(block);
    }
    for (function.trap_edges) |edge| {
        if (edge.from_block >= function.blocks.len or edge.trap_block >= function.blocks.len) {
            return .{ .line = edge.line, .column = edge.column };
        }
        const from = function.blocks[edge.from_block];
        if (!successorListed(from, edge.trap_block)) return .{ .line = edge.line, .column = edge.column };
        const trap_block = function.blocks[edge.trap_block];
        switch (trap_block.terminator) {
            .trap_ => |trap_kind| if (trap_kind != edge.kind) return .{ .line = edge.line, .column = edge.column },
            else => return .{ .line = edge.line, .column = edge.column },
        }
    }
    return null;
}

fn verifyFunctionCfg(function: Function, reporter: *diagnostics.Reporter) void {
    if (cfgHasStructuralError(function)) |point| {
        reporter.err(
            sourcePointSpan(point),
            "E_MIR_CFG: MIR verifier found malformed control-flow graph",
            .{},
        );
    }
}

fn terminatorSuccessorsAreConsistent(function: Function, block: Block) bool {
    return switch (block.terminator) {
        .fallthrough => normalSuccessorCount(function, block) == 0,
        .jump => |target| normalSuccessorCount(function, block) == 1 and normalSuccessorListed(function, block, target),
        .branch => |branch| normalSuccessorCount(function, block) == 2 and
            successorListed(block, branch.true_block) and
            successorListed(block, branch.false_block),
        .return_, .trap_, .unreachable_ => normalSuccessorCount(function, block) == 0,
        .switch_ => normalSuccessorCount(function, block) > 0,
    };
}

fn normalSuccessorCount(function: Function, block: Block) usize {
    var count: usize = 0;
    for (block.successors) |successor| {
        if (!isTrapSuccessor(function, block.id, successor)) count += 1;
    }
    return count;
}

fn normalSuccessorListed(function: Function, block: Block, target: usize) bool {
    return successorListed(block, target) and !isTrapSuccessor(function, block.id, target);
}

fn isTrapSuccessor(function: Function, from_block: usize, to_block: usize) bool {
    for (function.trap_edges) |edge| {
        if (edge.from_block == from_block and edge.trap_block == to_block) return true;
    }
    return false;
}

fn successorListed(block: Block, target: usize) bool {
    for (block.successors) |successor| {
        if (successor == target) return true;
    }
    return false;
}

fn blockLastSpan(block: Block) SourcePoint {
    if (block.instructions.len == 0) return .{ .line = 0, .column = 0 };
    const last = block.instructions[block.instructions.len - 1];
    return .{ .line = last.line, .column = last.column };
}

fn sourcePointSpan(point: SourcePoint) diagnostics.Span {
    return .{ .offset = 0, .len = 0, .line = point.line, .column = point.column };
}

fn functionByName(module: Module, name: []const u8) ?Function {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn calleeIsIrqContext(module: Module, name: []const u8) bool {
    const callee = functionByName(module, name) orelse return false;
    return callee.irq_context;
}

fn irqContextCallFinding(module: Module, function: Function, instruction: Instruction) ?IrqContextCallFinding {
    if (!function.irq_context) return null;
    if (instruction.kind != .call and instruction.kind != .indirect_call) return null;
    if (isNonBlockingPrimitive(instruction.detail)) return null;
    if (isKnownBlockingIrqCallee(instruction.detail)) return .blocking;
    if (instruction.kind == .indirect_call or !calleeIsIrqContext(module, instruction.detail)) return .unproven_call;
    return null;
}

fn irqContextFindingName(finding: IrqContextCallFinding) []const u8 {
    return switch (finding) {
        .unproven_call => "irq_call",
        .blocking => "irq_blocking",
    };
}

fn irqContextDiagnostic(finding: IrqContextCallFinding) []const u8 {
    return switch (finding) {
        .unproven_call => "E_IRQ_CONTEXT_CALL",
        .blocking => "E_IRQ_CONTEXT_BLOCKING",
    };
}

fn uncheckedAssumeHasMatchingContract(function: Function, instruction: Instruction) bool {
    const region_id = instruction.contract_region_id orelse return false;
    for (function.contract_regions) |region| {
        if (region.id != region_id) continue;
        return contractAllowsUnchecked(region.kind, instruction.detail);
    }
    return false;
}

fn contractAllowsUnchecked(contract: []const u8, callee: []const u8) bool {
    if (std.mem.eql(u8, contract, "no_overflow")) return noOverflowUncheckedOp(callee) != null;
    if (std.mem.eql(u8, contract, "noalias")) return std.mem.eql(u8, callee, "compiler.assume_noalias_unchecked");
    return false;
}

fn isRepresentationSensitiveProducer(instruction: Instruction) bool {
    return (instruction.kind == .call or instruction.kind == .indirect_call or instruction.kind == .typed_load) and representationCheckKind(instruction.result_ty) != null;
}

fn isRepresentationSensitiveUse(instruction: Instruction) bool {
    return (instruction.kind == .return_value or instruction.kind == .representation_use) and representationCheckKind(instruction.result_ty) != null;
}

fn defaultInstructionValueId(kind: Instruction.Kind, detail: []const u8) ?[]const u8 {
    return switch (kind) {
        .call, .indirect_call, .typed_load => detail,
        else => null,
    };
}

fn producerHasDominatingRepresentationCheck(block: Block, producer_index: usize, ty: ValueType) bool {
    const expected_kind = representationCheckKind(ty) orelse return true;
    const expected_value_id = block.instructions[producer_index].value_id;
    var i = producer_index + 1;
    while (i < block.instructions.len) : (i += 1) {
        const instruction = block.instructions[i];
        if (representationCheckMatches(instruction, expected_kind, expected_value_id)) {
            return true;
        }
        if (instruction.kind == .call or instruction.kind == .indirect_call or instruction.kind == .typed_load or instruction.kind == .return_value or instruction.kind == .representation_use or instruction.kind == .assign) return false;
    }
    return false;
}

fn useHasDominatingRepresentationCheck(allocator: std.mem.Allocator, function: Function, block_index: usize, instruction_index: usize, ty: ValueType) !bool {
    const expected_kind = representationCheckKind(ty) orelse return true;
    const expected_value_id = function.blocks[block_index].instructions[instruction_index].value_id;
    if (block_index >= function.blocks.len) return false;
    // The recursion guard must cover every block; a fixed cap would force a conservative
    // false-positive (E_REPRESENTATION_CHECK_MISSING) on large functions.
    const visiting = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(visiting);
    @memset(visiting, false);
    return blockHasDominatingRepresentationCheck(function, block_index, instruction_index, expected_kind, expected_value_id, visiting);
}

fn blockHasDominatingRepresentationCheck(function: Function, block_index: usize, before_index: usize, expected_kind: []const u8, expected_value_id: ?[]const u8, visiting: []bool) bool {
    if (block_index >= function.blocks.len) return false;
    const block = function.blocks[block_index];
    var i = before_index;
    while (i > 0) {
        i -= 1;
        const instruction = block.instructions[i];
        if (representationCheckMatches(instruction, expected_kind, expected_value_id)) {
            return true;
        }
    }

    if (block_index == 0) return false;
    if (visiting[block_index]) return false;
    visiting[block_index] = true;
    defer visiting[block_index] = false;

    var saw_predecessor = false;
    for (function.blocks, 0..) |candidate, predecessor_index| {
        if (!successorListed(candidate, block_index)) continue;
        saw_predecessor = true;
        if (!blockHasDominatingRepresentationCheck(function, predecessor_index, candidate.instructions.len, expected_kind, expected_value_id, visiting)) return false;
    }
    return saw_predecessor;
}

fn representationCheckMatches(instruction: Instruction, expected_kind: []const u8, expected_value_id: ?[]const u8) bool {
    if (instruction.kind != .representation_check) return false;
    const actual_kind = representationCheckKind(instruction.result_ty) orelse return false;
    if (!std.mem.eql(u8, actual_kind, expected_kind)) return false;
    const actual_value_id = instruction.value_id;
    if (expected_value_id) |expected| {
        if (actual_value_id) |actual| return std.mem.eql(u8, actual, expected);
        return false;
    }
    return actual_value_id == null;
}

fn representationCheckKind(ty: ValueType) ?[]const u8 {
    return switch (ty) {
        .pointer => "nonnull_pointer",
        .closed_enum => "closed_enum",
        else => null,
    };
}

fn representationTypeName(ty: ValueType) []const u8 {
    return switch (ty) {
        .pointer => "nonnull_pointer",
        .closed_enum => |name| name,
        else => "unknown",
    };
}

fn representationCheckTraps(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind != .raw_many,
        .closed_enum => true,
        else => false,
    };
}

fn noOverflowUncheckedOp(callee: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, callee, "unchecked.add") or std.mem.eql(u8, callee, "unchecked_add")) return "add";
    if (std.mem.eql(u8, callee, "unchecked.sub") or std.mem.eql(u8, callee, "unchecked_sub")) return "sub";
    if (std.mem.eql(u8, callee, "unchecked.mul") or std.mem.eql(u8, callee, "unchecked_mul")) return "mul";
    return null;
}

fn hasAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .no_lang_trap => if (std.mem.eql(u8, name, "no_lang_trap")) return true,
        .named => |ident| if (std.mem.eql(u8, ident.text, name)) return true,
        .unsafe_contract, .backend_name, .origin => {},
    };
    return false;
}

fn isVoidLike(ty: ValueType) bool {
    return ty == .void;
}

fn nullabilityFinding(target_ty: ValueType, source_ty: ValueType) ?[]const u8 {
    if (target_ty == .pointer and source_ty == .nullable_pointer) {
        return switch (source_ty) {
            .nullable_pointer => |shape| if (isNullPointerShape(shape)) "null_to_nonnull" else "nullable_to_nonnull",
            else => null,
        };
    }
    return null;
}

fn nullabilityDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "null_to_nonnull")) return "E_NULL_NON_NULL_POINTER";
    if (std.mem.eql(u8, finding, "nullable_to_nonnull")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    return "E_NO_IMPLICIT_POINTER_CONVERSION";
}

fn conversionFinding(ctx: ConversionContext, target: ValueType, source: ValueType) []const u8 {
    // Arrays never implicitly decay to pointers (section 9), in any context.
    if (source == .array and isPointerLikeType(target)) return "array_to_pointer_decay";
    const c_void_conversion = isCVoidPointerConversion(target, source);
    const pointer_conversion = isPointerViewConversion(target, source);
    return switch (ctx) {
        .return_ => if (c_void_conversion) "return_c_void_conversion" else if (pointer_conversion) "return_pointer_conversion" else "return_type_mismatch",
        .initializer => if (c_void_conversion) "initializer_c_void_conversion" else if (pointer_conversion) "initializer_pointer_conversion" else "initializer_type_mismatch",
        .assignment => if (c_void_conversion) "assignment_c_void_conversion" else if (pointer_conversion) "assignment_pointer_conversion" else "assignment_type_mismatch",
        .call_arg => if (c_void_conversion) "call_arg_c_void_conversion" else if (pointer_conversion) "call_arg_pointer_conversion" else "call_arg_type_mismatch",
        .condition => "condition_type_mismatch",
    };
}

fn conversionDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "integer_literal_out_of_range")) return "E_INTEGER_LITERAL_OUT_OF_RANGE";
    if (std.mem.eql(u8, finding, "for_base_not_iterable")) return "E_FOR_BASE_NOT_ARRAY_OR_SLICE";
    if (std.mem.eql(u8, finding, "index_base_not_array_or_slice")) return "E_INDEX_BASE_NOT_ARRAY_OR_SLICE";
    if (std.mem.eql(u8, finding, "index_not_usize")) return "E_INDEX_NOT_USIZE";
    if (std.mem.eql(u8, finding, "return_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "initializer_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "assignment_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "call_arg_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "condition_type_mismatch")) return "E_CONDITION_NOT_BOOL";
    if (std.mem.eql(u8, finding, "return_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "initializer_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "assignment_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "call_arg_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "return_type_mismatch")) return "E_RETURN_TYPE_MISMATCH";
    if (std.mem.eql(u8, finding, "array_to_pointer_decay")) return "E_ARRAY_TO_POINTER_DECAY";
    return "E_NO_IMPLICIT_CONVERSION";
}

fn aggregateDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "array_literal_length")) return "E_ARRAY_LITERAL_LENGTH";
    if (std.mem.eql(u8, finding, "struct_literal_duplicate_field")) return "E_DUPLICATE_STRUCT_LITERAL_FIELD";
    if (std.mem.eql(u8, finding, "struct_literal_unknown_field")) return "E_UNKNOWN_STRUCT_FIELD";
    if (std.mem.eql(u8, finding, "struct_literal_missing_field")) return "E_STRUCT_LITERAL_MISSING_FIELD";
    return "E_NO_IMPLICIT_CONVERSION";
}

fn resultFindingDiagnostic(finding: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, finding, "unhandled_result")) return "E_UNHANDLED_RESULT";
    if (std.mem.eql(u8, finding, "try_requires_result_or_nullable")) return "E_TRY_REQUIRES_RESULT_OR_NULLABLE";
    if (std.mem.eql(u8, finding, "try_payload_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "try_payload_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "try_payload_type_mismatch")) return "E_RETURN_TYPE_MISMATCH";
    if (std.mem.eql(u8, finding, "if_let_optional_required")) return "E_IF_LET_OPTIONAL_REQUIRED";
    if (std.mem.eql(u8, finding, "if_let_result_required")) return "E_IF_LET_RESULT_REQUIRED";
    if (std.mem.eql(u8, finding, "if_let_result_tag")) return "E_IF_LET_RESULT_TAG";
    if (std.mem.eql(u8, finding, "if_let_narrow_pattern")) return "E_IF_LET_NARROW_PATTERN";
    if (std.mem.eql(u8, finding, "switch_result_tag")) return "E_SWITCH_RESULT_TAG";
    if (std.mem.eql(u8, finding, "switch_result_required")) return "E_SWITCH_RESULT_REQUIRED";
    if (std.mem.eql(u8, finding, "switch_multi_binding_arm")) return "E_SWITCH_MULTI_BINDING_ARM";
    return null;
}

fn switchFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "duplicate_switch_case")) return "E_DUPLICATE_SWITCH_CASE";
    if (std.mem.eql(u8, finding, "unknown_enum_case")) return "E_UNKNOWN_ENUM_CASE";
    if (std.mem.eql(u8, finding, "closed_enum_switch_exhaustive")) return "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE";
    if (std.mem.eql(u8, finding, "unknown_union_case")) return "E_UNKNOWN_UNION_CASE";
    if (std.mem.eql(u8, finding, "union_case_has_no_payload")) return "E_UNION_CASE_HAS_NO_PAYLOAD";
    if (std.mem.eql(u8, finding, "switch_literal_type_mismatch")) return "E_NO_IMPLICIT_CONVERSION";
    return "E_DUPLICATE_SWITCH_CASE";
}

fn assignmentFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "assign_to_immutable_local")) return "E_ASSIGN_TO_IMMUTABLE_LOCAL";
    if (std.mem.eql(u8, finding, "assign_through_const_view")) return "E_ASSIGN_THROUGH_CONST_VIEW";
    return "E_INVALID_ASSIGNMENT_TARGET";
}

fn arithmeticDomainFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "arith_policy_mix")) return "E_ARITH_POLICY_MIX";
    if (std.mem.eql(u8, finding, "arith_domain_division")) return "E_ARITH_DOMAIN_DIVISION";
    if (std.mem.eql(u8, finding, "bitwise_arith_domain_operand")) return "E_BITWISE_ARITH_DOMAIN_OPERAND";
    if (std.mem.eql(u8, finding, "ordered_arith_domain_operand")) return "E_ORDERED_ARITH_DOMAIN_OPERAND";
    if (std.mem.eql(u8, finding, "serial_operation")) return "E_SERIAL_OPERATION";
    if (std.mem.eql(u8, finding, "counter_operation")) return "E_COUNTER_OPERATION";
    if (std.mem.eql(u8, finding, "conversion_operation")) return "E_CONVERSION_OPERATION";
    return "E_ARITH_POLICY_MIX";
}

fn operatorFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "unsigned_negation")) return "E_UNSIGNED_NEGATION";
    if (std.mem.eql(u8, finding, "bitwise_signed_operand")) return "E_BITWISE_SIGNED_OPERAND";
    if (std.mem.eql(u8, finding, "bitwise_bool_operand")) return "E_BITWISE_BOOL_OPERAND";
    if (std.mem.eql(u8, finding, "bitwise_pointer_operand")) return "E_BITWISE_POINTER_OPERAND";
    if (std.mem.eql(u8, finding, "bool_operator_operand")) return "E_BOOL_OPERATOR_OPERAND";
    if (std.mem.eql(u8, finding, "signed_unsigned_mix")) return "E_SIGNED_UNSIGNED_MIX";
    if (std.mem.eql(u8, finding, "integer_promotion")) return "E_NO_IMPLICIT_INTEGER_PROMOTION";
    if (std.mem.eql(u8, finding, "float_binary_conversion")) return "E_NO_IMPLICIT_CONVERSION";
    if (std.mem.eql(u8, finding, "pointer_arith_single_object")) return "E_POINTER_ARITH_SINGLE_OBJECT";
    if (std.mem.eql(u8, finding, "pointer_ordering")) return "E_POINTER_ORDERING";
    return "E_OPERATOR_OPERAND";
}


fn integerLiteralRangeFinding(target_ty: ValueType, expr: ast.Expr) ?[]const u8 {
    const value = integerLiteralValue(expr) orelse return null;
    const bounds = mirCheckedIntBounds(target_ty) orelse return null;
    if (value.negative) {
        if (!bounds.signed or value.magnitude > bounds.min_abs) return "integer_literal_out_of_range";
        return null;
    }
    if (value.magnitude > bounds.max) return "integer_literal_out_of_range";
    return null;
}

fn integerLiteralFitsTarget(target_ty: ValueType, expr: ast.Expr) bool {
    if (integerLiteralValue(expr) == null) return false;
    return mirCheckedIntBounds(target_ty) != null and integerLiteralRangeFinding(target_ty, expr) == null;
}

fn switchBoolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| switchBoolLiteralValue(inner.*),
        else => null,
    };
}

fn enumContainsCase(info: EnumSummary, case_name: []const u8) bool {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return true;
    }
    return false;
}

fn switchCoversAllMirEnumCases(node: ast.Switch, info: EnumSummary) bool {
    for (info.cases) |case| {
        if (!switchCoversMirEnumCase(node, case.name.text)) return false;
    }
    return true;
}

fn switchCoversMirEnumCase(node: ast.Switch, case_name: []const u8) bool {
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| if (std.mem.eql(u8, tag.text, case_name)) return true,
                .wildcard => return true,
                .tag_bind, .literal, .bind => {},
            }
        }
    }
    return false;
}

fn isArrayTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isArrayTypeAliasDepth(ty, aliases, 0);
}

fn isArrayTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isArrayTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .array => true,
        .qualified => |node| isArrayTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn isConstStorageTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isConstStorageTypeAliasDepth(ty, aliases, 0);
}

fn isConstStorageTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isConstStorageTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .pointer => |node| node.mutability == .@"const",
        .raw_many_pointer => |node| node.mutability == .@"const",
        .slice => |node| node.mutability == .@"const",
        .qualified => |node| isConstStorageTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn unionContainsCase(info: UnionSummary, case_name: []const u8) bool {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return true;
    }
    return false;
}

fn unionCasePayloadType(info: UnionSummary, case_name: []const u8) ?ast.TypeExpr {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return case.ty;
    }
    return null;
}

fn mirComptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const env: *MirReflectEnv = @ptrCast(@alignCast(ctx orelse return null));
    return mirComptimeReflect(env, call);
}

fn mirComptimeReflect(env: *const MirReflectEnv, call: ast.Expr) ?i128 {
    const node = switch (call.kind) {
        .call => |n| n,
        else => return null,
    };
    const kind = mirReflectionKind(node.callee.*) orelse return null;
    if (node.type_args.len != 1) return null;
    const ty = node.type_args[0];
    return switch (kind) {
        .size => if (node.args.len == 0) mirComptimeSizeOf(env, ty, 0) else null,
        .alignment => if (node.args.len == 0) mirComptimeAlignOf(env, ty, 0) else null,
        .repr => if (node.args.len == 0) mirComptimeReprOf(env, ty, 0) else null,
        .field_offset => if (node.args.len == 1) mirComptimeFieldOffset(env, ty, mirReflectionFieldName(node.args[0]) orelse return null, 0) else null,
        .bit_offset => if (node.args.len == 1) mirComptimeBitOffset(env, ty, mirReflectionFieldName(node.args[0]) orelse return null, 0) else null,
    };
}

const MirReflectionKind = enum { size, alignment, field_offset, bit_offset, repr };

fn mirReflectionKind(callee: ast.Expr) ?MirReflectionKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| mirReflectionKind(inner.*),
        else => null,
    };
}

fn mirReflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| mirReflectionFieldName(inner.*),
        else => null,
    };
}

fn mirComptimeSizeOf(env: *const MirReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (mirScalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return mirComptimeSizeOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| {
                const layout = mirComptimeStructLayout(env, info, depth + 1, null) orelse return null;
                return layout.size;
            }
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse mirSimpleNameType("isize", ty.span);
                return mirComptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return mirComptimeSizeOf(env, info.repr, depth + 1);
            return null;
        },
        .pointer, .raw_many_pointer => 8,
        .slice => 16,
        .generic => |g| {
            if (mirPointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return mirComptimeSizeOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return mirComptimeSizeOf(env, g.args[0], depth + 1);
            if (mirArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return mirComptimeSizeOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| {
            const len = mirStaticArrayLen(node.len) orelse return null;
            const elem = mirComptimeSizeOf(env, node.child.*, depth + 1) orelse return null;
            return @as(i128, @intCast(len)) * elem;
        },
        .qualified => |node| mirComptimeSizeOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn mirComptimeAlignOf(env: *const MirReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (mirScalarLayout(name.text)) |layout| return @intCast(layout.alignment);
            if (env.aliases.get(name.text)) |aliased| return mirComptimeAlignOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| {
                const layout = mirComptimeStructLayout(env, info, depth + 1, null) orelse return null;
                return layout.alignment;
            }
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse mirSimpleNameType("isize", ty.span);
                return mirComptimeAlignOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return mirComptimeAlignOf(env, info.repr, depth + 1);
            return null;
        },
        .pointer, .raw_many_pointer, .slice => 8,
        .generic => |g| {
            if (mirPointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return mirComptimeAlignOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return mirComptimeAlignOf(env, g.args[0], depth + 1);
            if (mirArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return mirComptimeAlignOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| mirComptimeAlignOf(env, node.child.*, depth + 1),
        .qualified => |node| mirComptimeAlignOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn mirComptimeReprOf(env: *const MirReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (mirScalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return mirComptimeReprOf(env, aliased, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse mirSimpleNameType("isize", ty.span);
                return mirComptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return mirComptimeSizeOf(env, info.repr, depth + 1);
            if (env.unions.contains(name.text)) return mirTaggedUnionTagSize();
            return mirComptimeSizeOf(env, ty, depth + 1);
        },
        .pointer, .raw_many_pointer, .slice, .array, .generic => mirComptimeSizeOf(env, ty, depth + 1),
        .qualified => |node| mirComptimeReprOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn mirComptimeFieldOffset(env: *const MirReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = mirTypeName(ty) orelse return null;
    if (env.aliases.get(name)) |aliased| return mirComptimeFieldOffset(env, aliased, field, depth + 1);
    if (env.structs.get(name)) |info| {
        const layout = mirComptimeStructLayout(env, info, depth + 1, field) orelse return null;
        return layout.field_offset;
    }
    return null;
}

fn mirComptimeBitOffset(env: *const MirReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = mirTypeName(ty) orelse return null;
    if (env.aliases.get(name)) |aliased| return mirComptimeBitOffset(env, aliased, field, depth + 1);
    if (env.packed_bits.get(name)) |info| {
        for (info.fields, 0..) |packed_field, bit| {
            if (std.mem.eql(u8, packed_field.name.text, field)) return @intCast(bit);
        }
        return null;
    }
    const byte_offset = mirComptimeFieldOffset(env, ty, field, depth + 1) orelse return null;
    return byte_offset * 8;
}

const MirStructLayout = struct {
    size: i128,
    alignment: i128,
    field_offset: ?i128,
};

fn mirComptimeStructLayout(env: *const MirReflectEnv, info: StructSummary, depth: usize, want_field: ?[]const u8) ?MirStructLayout {
    if (depth > 32) return null;
    var offset: i128 = 0;
    var max_align: i128 = 1;
    var found: ?i128 = null;
    for (info.fields) |field| {
        const size = mirComptimeSizeOf(env, field.ty, depth + 1) orelse return null;
        const alignment = mirComptimeAlignOf(env, field.ty, depth + 1) orelse return null;
        if (alignment <= 0) return null;
        if (alignment > max_align) max_align = alignment;
        if (field.offset) |explicit| {
            const explicit_offset: i128 = @intCast(explicit);
            if (explicit_offset < offset) return null;
            offset = explicit_offset;
        } else {
            offset = mirAlignForward(offset, alignment) orelse return null;
        }
        if (want_field) |wanted| {
            if (std.mem.eql(u8, field.name.text, wanted)) found = offset;
        }
        offset += size;
    }
    return .{
        .size = mirAlignForward(offset, max_align) orelse return null,
        .alignment = max_align,
        .field_offset = found,
    };
}

const MirScalarLayout = struct { size: u32, alignment: u32 };

fn mirScalarLayout(name: []const u8) ?MirScalarLayout {
    const table = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "u8", .s = 1 },      .{ .n = "i8", .s = 1 },    .{ .n = "bool", .s = 1 },
        .{ .n = "u16", .s = 2 },     .{ .n = "i16", .s = 2 },   .{ .n = "u32", .s = 4 },
        .{ .n = "i32", .s = 4 },     .{ .n = "f32", .s = 4 },   .{ .n = "u64", .s = 8 },
        .{ .n = "i64", .s = 8 },     .{ .n = "f64", .s = 8 },   .{ .n = "usize", .s = 8 },
        .{ .n = "isize", .s = 8 },   .{ .n = "PAddr", .s = 8 }, .{ .n = "VAddr", .s = 8 },
        .{ .n = "DmaAddr", .s = 8 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return .{ .size = entry.s, .alignment = entry.s };
    }
    return null;
}

fn mirTaggedUnionTagSize() i128 {
    return 4;
}

fn mirTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| mirTypeName(node.child.*),
        else => null,
    };
}

fn mirSimpleNameType(name: []const u8, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

fn mirPointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or std.mem.eql(u8, name, "UserPtr");
}

fn mirArithmeticLayoutGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

fn mirAlignForward(value: i128, alignment: i128) ?i128 {
    if (alignment <= 0) return null;
    const rem = @rem(value, alignment);
    if (rem == 0) return value;
    return std.math.add(i128, value, alignment - rem) catch null;
}

fn mirStaticArrayLen(expr: ast.Expr) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| mirStaticArrayLen(inner.*),
        .binary => |node| {
            const left = mirStaticArrayLen(node.left.*) orelse return null;
            const right = mirStaticArrayLen(node.right.*) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        else => null,
    };
}

fn parseArrayLen(expr: ast.Expr, const_fns: *const std.StringHashMap(ast.FnDecl), const_globals: *const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .char_literal => |literal| if (eval.parseCharLiteral(literal)) |value|
            if (value <= std.math.maxInt(usize)) @intCast(value) else null
        else
            null,
        .grouped => |inner| parseArrayLen(inner.*, const_fns, const_globals),
        // Section 22 comptime↔type: a `const fn` result or named `const` global
        // can drive a fixed-array length; fold it the way the front-end did.
        .call, .ident => comptimeUsizeArrayLen(expr, const_fns, const_globals),
        .binary => |node| {
            const left = parseArrayLen(node.left.*, const_fns, const_globals) orelse return null;
            const right = parseArrayLen(node.right.*, const_fns, const_globals) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        else => null,
    };
}

fn comptimeUsizeArrayLen(expr: ast.Expr, const_fns: *const std.StringHashMap(ast.FnDecl), const_globals: *const std.StringHashMap(eval.ComptimeValue)) ?usize {
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var scope = eval.ComptimeScope.init(fba.allocator());
    scope.funcs = const_fns;
    scope.globals = const_globals;
    return switch (eval.foldComptimeExpr(&scope, expr)) {
        .value => |v| switch (v) {
            .int => |n| if (n >= 0 and n <= std.math.maxInt(usize)) @intCast(n) else null,
            .void, .boolean, .float, .tag, .bytes, .array, .@"struct" => null,
        },
        else => null,
    };
}

fn mirCheckedIntBounds(ty: ValueType) ?IntBounds {
    return switch (ty) {
        .integer => |name| checkedIntBoundsByName(name),
        else => null,
    };
}

fn checkedIntBoundsByName(name: []const u8) ?IntBounds {
    if (std.mem.eql(u8, name, "u8")) return .{ .signed = false, .max = maxUnsigned(8) };
    if (std.mem.eql(u8, name, "u16")) return .{ .signed = false, .max = maxUnsigned(16) };
    if (std.mem.eql(u8, name, "u32")) return .{ .signed = false, .max = maxUnsigned(32) };
    if (std.mem.eql(u8, name, "u64")) return .{ .signed = false, .max = maxUnsigned(64) };
    if (std.mem.eql(u8, name, "usize")) return .{ .signed = false, .max = maxUnsigned(64) };
    if (std.mem.eql(u8, name, "i8")) return signedBounds(8);
    if (std.mem.eql(u8, name, "i16")) return signedBounds(16);
    if (std.mem.eql(u8, name, "i32")) return signedBounds(32);
    if (std.mem.eql(u8, name, "i64")) return signedBounds(64);
    if (std.mem.eql(u8, name, "isize")) return signedBounds(64);
    return null;
}

fn isTryCapableType(ty: ValueType) bool {
    return isResultType(ty) or ty == .nullable_pointer;
}

fn isResultType(ty: ValueType) bool {
    return std.meta.activeTag(ty) == .result;
}

fn isMirNullableValue(ty: ValueType) bool {
    return switch (ty) {
        .nullable_pointer, .unknown, .never => true,
        else => false,
    };
}

fn isMirEnum(ty: ValueType) bool {
    return switch (ty) {
        .closed_enum, .open_enum => true,
        else => false,
    };
}

fn isMirIntegerLike(ty: ValueType) bool {
    return switch (ty) {
        .integer => true,
        else => false,
    };
}

fn unknownResultType() ValueType {
    return .{ .result = .{ .ok = "unknown", .err = "unknown" } };
}

fn mirTypesAreCompatible(target: ValueType, source: ValueType) bool {
    if (target == .unknown or source == .unknown or source == .never) return true;
    if (target == .value or source == .value) return true;
    if (target == .nullable_pointer and source == .pointer) {
        return switch (target) {
            .nullable_pointer => |target_shape| samePointerShape(target_shape, switch (source) {
                .pointer => |source_shape| source_shape,
                else => unreachable,
            }),
            else => unreachable,
        };
    }
    if (target == .nullable_pointer and source == .nullable_pointer) {
        return switch (source) {
            .nullable_pointer => |source_shape| if (isNullPointerShape(source_shape)) true else samePointerShape(source_shape, switch (target) {
                .nullable_pointer => |target_shape| target_shape,
                else => unreachable,
            }),
            else => unreachable,
        };
    }
    if (std.meta.activeTag(target) != std.meta.activeTag(source)) return false;
    return switch (target) {
        .integer => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .integer => |source_name| source_name,
            else => unreachable,
        }) or std.mem.eql(u8, switch (source) {
            .integer => |source_name| source_name,
            else => unreachable,
        }, "comptime_int"),
        .float => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .float => |source_name| source_name,
            else => unreachable,
        }) or std.mem.eql(u8, switch (source) {
            .float => |source_name| source_name,
            else => unreachable,
        }, "comptime_float"),
        .pointer => |target_shape| samePointerShape(target_shape, switch (source) {
            .pointer => |source_shape| source_shape,
            else => unreachable,
        }),
        .nullable_pointer => |target_shape| samePointerShape(target_shape, switch (source) {
            .nullable_pointer => |source_shape| source_shape,
            else => unreachable,
        }),
        .slice => true,
        .array => true,
        .closed_enum => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .closed_enum => |source_name| source_name,
            else => unreachable,
        }),
        .open_enum => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .open_enum => |source_name| source_name,
            else => unreachable,
        }),
        .struct_ => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .struct_ => |source_name| source_name,
            else => unreachable,
        }),
        .address => |target_kind| target_kind == switch (source) {
            .address => |source_kind| source_kind,
            else => unreachable,
        },
        .result => |target_shape| blk: {
            const source_shape = switch (source) {
                .result => |shape| shape,
                else => unreachable,
            };
            break :blk std.mem.eql(u8, target_shape.ok, source_shape.ok) and std.mem.eql(u8, target_shape.err, source_shape.err);
        },
        .void, .never, .bool, .contract, .branch, .trap, .unknown, .value => true,
    };
}

fn isMirForIterable(ty: ValueType) bool {
    return switch (ty) {
        .array, .slice, .unknown, .never => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

fn isMirIndexableBase(ty: ValueType) bool {
    return switch (ty) {
        .array, .slice, .unknown, .never => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

fn isMirIndexType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "comptime_int"),
        .unknown, .never => true,
        else => false,
    };
}

fn isPointerViewConversion(target: ValueType, source: ValueType) bool {
    return isPointerLikeType(target) and isPointerLikeType(source);
}

fn isCVoidPointerConversion(target: ValueType, source: ValueType) bool {
    if (!isPointerLikeType(target) or !isPointerLikeType(source)) return false;
    return isCVoidPointerType(target) != isCVoidPointerType(source);
}

fn isCVoidPointerType(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        .nullable_pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        else => false,
    };
}

fn isPointerLikeType(ty: ValueType) bool {
    return ty == .pointer or ty == .nullable_pointer;
}

fn samePointerShape(left: PointerShape, right: PointerShape) bool {
    return left.kind == right.kind and
        left.mutability == right.mutability and
        std.mem.eql(u8, left.child, right.child);
}

fn isNullPointerShape(shape: PointerShape) bool {
    return std.mem.eql(u8, shape.child, "null");
}

fn pointerShapeName(shape: PointerShape) []const u8 {
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

fn directIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| directIdentName(inner.*),
        else => null,
    };
}

fn exprIsIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| exprIsIdentNamed(inner.*, name),
        else => false,
    };
}

fn localDeclaresName(local: ast.LocalDecl, name: []const u8) bool {
    for (local.names) |ident| {
        if (std.mem.eql(u8, ident.text, name)) return true;
    }
    return false;
}

fn resultIfLetHandlesLocal(name: []const u8, node: ast.IfLet) bool {
    if (node.else_block == null or !exprIsIdentNamed(node.value, name)) return false;
    return switch (node.pattern.kind) {
        .tag_bind => |tag_bind| isResultNarrowingTag(tag_bind.tag.text),
        else => false,
    };
}

fn resultSwitchHandlesLocal(name: []const u8, node: ast.Switch) bool {
    if (!exprIsIdentNamed(node.subject, name)) return false;
    var has_wildcard = false;
    var has_ok = false;
    var has_err = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag => |tag| {
                    if (std.mem.eql(u8, tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag.text, "err")) has_err = true;
                },
                .tag_bind => |tag_bind| {
                    if (std.mem.eql(u8, tag_bind.tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag_bind.tag.text, "err")) has_err = true;
                },
                .literal, .bind => {},
            }
        }
    }
    return has_wildcard or (has_ok and has_err);
}

fn switchArmBodiesHandleResultLocal(self: *FunctionBuilder, name: []const u8, node: ast.Switch) bool {
    for (node.arms) |arm| {
        switch (arm.body) {
            .block => |body| if (self.blockHandlesResultLocal(name, body)) return true,
            .expr => |expr| if (self.exprHandlesResultLocal(name, expr)) return true,
        }
    }
    return false;
}

fn exprHandlesAnyResult(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => true,
        .grouped, .address_of, .deref => |inner| exprHandlesAnyResult(inner.*),
        .block => |block| blockHandlesAnyResult(block),
        .array_literal => |items| {
            for (items) |item| {
                if (exprHandlesAnyResult(item)) return true;
            }
            return false;
        },
        .struct_literal => |fields| {
            for (fields) |field| {
                if (exprHandlesAnyResult(field.value)) return true;
            }
            return false;
        },
        .unary => |node| exprHandlesAnyResult(node.expr.*),
        .binary => |node| exprHandlesAnyResult(node.left.*) or exprHandlesAnyResult(node.right.*),
        .cast => |node| exprHandlesAnyResult(node.value.*),
        .call => |node| callHandlesAnyResult(node),
        .index => |node| exprHandlesAnyResult(node.base.*) or exprHandlesAnyResult(node.index.*),
        .slice => |node| exprHandlesAnyResult(node.base.*) or exprHandlesAnyResult(node.start.*) or exprHandlesAnyResult(node.end.*),
        .member => |node| exprHandlesAnyResult(node.base.*),
        else => false,
    };
}

fn blockHandlesAnyResult(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtHandlesAnyResult(stmt)) return true;
    }
    return false;
}

fn stmtHandlesAnyResult(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprHandlesAnyResult(expr) else false,
        .loop => |node| (if (node.iterable) |iterable| exprHandlesAnyResult(iterable) else false) or blockHandlesAnyResult(node.body),
        .if_let => |node| exprHandlesAnyResult(node.value) or blockHandlesAnyResult(node.then_block) or (if (node.else_block) |else_block| blockHandlesAnyResult(else_block) else false),
        .@"switch" => |node| switchHandlesAnyResult(node),
        .unsafe_block, .comptime_block, .block => |block| blockHandlesAnyResult(block),
        .contract_block => |contract| blockHandlesAnyResult(contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprHandlesAnyResult(expr) else false,
        .@"break", .@"continue", .asm_stmt => false,
        .@"defer", .expr, .assert => |expr| exprHandlesAnyResult(expr),
        .assignment => |node| exprHandlesAnyResult(node.target) or exprHandlesAnyResult(node.value),
    };
}

fn switchHandlesAnyResult(node: ast.Switch) bool {
    if (exprHandlesAnyResult(node.subject)) return true;
    for (node.arms) |arm| {
        const handles = switch (arm.body) {
            .block => |block| blockHandlesAnyResult(block),
            .expr => |expr| exprHandlesAnyResult(expr),
        };
        if (handles) return true;
    }
    return false;
}

fn callHandlesAnyResult(node: anytype) bool {
    if (exprHandlesAnyResult(node.callee.*)) return true;
    for (node.args) |arg| {
        if (exprHandlesAnyResult(arg)) return true;
    }
    return false;
}

fn isResultNarrowingTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err");
}

fn valueTypeFromExpr(expr: ast.Expr) ValueType {
    return switch (expr.kind) {
        .bool_literal => .bool,
        .void_literal => .void,
        .unreachable_expr => .never,
        .int_literal => .{ .integer = "comptime_int" },
        .float_literal => .{ .float = "comptime_float" },
        .null_literal => .{ .nullable_pointer = nullPointerShape() },
        else => .value,
    };
}

fn valueTypeFromType(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    return switch (ty.kind) {
        .name => |name| namedValueType(name.text, enums, structs),
        .enum_literal => .value,
        .member => .value,
        .nullable => |child| blk: {
            const child_ty = valueTypeFromType(child.*, enums, structs);
            break :blk switch (child_ty) {
                .pointer => |shape| .{ .nullable_pointer = shape },
                else => .value,
            };
        },
        .qualified => |node| valueTypeFromType(node.child.*, enums, structs),
        .pointer => |node| .{ .pointer = pointerShape(.single, node.mutability, node.child.*) },
        .raw_many_pointer => |node| .{ .pointer = pointerShape(.raw_many, node.mutability, node.child.*) },
        .slice => |node| .{ .pointer = pointerShape(.slice, node.mutability, node.child.*) },
        .array => .{ .array = "array" },
        .generic => |node| genericValueType(node, enums, structs),
    };
}

fn valueTypeFromTypeAlias(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr)) ValueType {
    return valueTypeFromTypeAliasDepth(ty, enums, structs, packed_bits, aliases, 0);
}

fn valueTypeFromTypeAliasDepth(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ValueType {
    if (depth > 64) return .value;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved|
            valueTypeFromTypeAliasDepth(resolved, enums, structs, packed_bits, aliases, depth + 1)
        else
            namedValueTypeAlias(name.text, enums, structs, packed_bits),
        .enum_literal => .value,
        .member => .value,
        .fn_pointer => .value, // a function pointer is a scalar value
        .closure_type => .value, // a closure is a {code, env} aggregate, treated as a value
        .nullable => |child| blk: {
            const child_ty = valueTypeFromTypeAliasDepth(child.*, enums, structs, packed_bits, aliases, depth + 1);
            break :blk switch (child_ty) {
                .pointer => |shape| .{ .nullable_pointer = shape },
                else => .value,
            };
        },
        .qualified => |node| valueTypeFromTypeAliasDepth(node.child.*, enums, structs, packed_bits, aliases, depth + 1),
        .pointer => |node| .{ .pointer = pointerShapeAlias(.single, node.mutability, node.child.*, aliases) },
        .raw_many_pointer => |node| .{ .pointer = pointerShapeAlias(.raw_many, node.mutability, node.child.*, aliases) },
        .slice => |node| .{ .pointer = pointerShapeAlias(.slice, node.mutability, node.child.*, aliases) },
        .array => .{ .array = "array" },
        .generic => |node| genericValueTypeAlias(node, enums, structs, packed_bits, aliases),
    };
}

fn valueTypeFromTypeName(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    if (std.mem.startsWith(u8, name, "*")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.startsWith(u8, name, "[*]")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.eql(u8, name, "[]")) return .{ .slice = "[]" };
    if (std.mem.eql(u8, name, "?")) return .{ .nullable_pointer = .{ .kind = .single, .mutability = .none, .child = "unknown" } };
    if (std.mem.eql(u8, name, "Result")) return unknownResultType();
    return namedValueType(name, enums, structs);
}

fn valueTypeFromTypeNameAlias(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary)) ValueType {
    if (std.mem.startsWith(u8, name, "*")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.startsWith(u8, name, "[*]")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.eql(u8, name, "[]")) return .{ .slice = "[]" };
    if (std.mem.eql(u8, name, "?")) return .{ .nullable_pointer = .{ .kind = .single, .mutability = .none, .child = "unknown" } };
    if (std.mem.eql(u8, name, "Result")) return unknownResultType();
    return namedValueTypeAlias(name, enums, structs, packed_bits);
}

fn aggregateTargetType(ty: ast.TypeExpr) ast.TypeExpr {
    return switch (ty.kind) {
        .qualified => |node| aggregateTargetType(node.child.*),
        else => ty,
    };
}

fn aggregateTargetTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ast.TypeExpr {
    return aggregateTargetTypeAliasDepth(ty, aliases, 0);
}

fn aggregateTargetTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| aggregateTargetTypeAliasDepth(resolved, aliases, depth + 1) else ty,
        .qualified => |node| aggregateTargetTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => ty,
    };
}

fn arrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| arrayElementType(node.child.*),
        else => null,
    };
}

fn arrayElementTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return arrayElementTypeAliasDepth(ty, aliases, 0);
}

fn arrayElementTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| arrayElementTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .array => |node| node.child.*,
        .qualified => |node| arrayElementTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn storageElementTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return storageElementTypeAliasDepth(ty, aliases, 0);
}

fn storageElementTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| storageElementTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| storageElementTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn sliceTypeForBaseAlias(ty: ast.TypeExpr, span: ast.Span, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return sliceTypeForBaseAliasDepth(ty, span, aliases, 0);
}

fn sliceTypeForBaseAliasDepth(ty: ast.TypeExpr, span: ast.Span, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| sliceTypeForBaseAliasDepth(resolved, span, aliases, depth + 1) else null,
        .slice => ty,
        .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
        .qualified => |node| sliceTypeForBaseAliasDepth(node.child.*, span, aliases, depth + 1),
        else => null,
    };
}

fn tryPayloadTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return tryPayloadTypeExprAliasDepth(ty, aliases, 0);
}

fn tryPayloadTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| tryPayloadTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .nullable => |child| child.*,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result") and node.args.len >= 1) aggregateTargetTypeAlias(node.args[0], aliases) else null,
        .qualified => |node| tryPayloadTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn mmioMapPayloadTypeForExpr(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| mmioMapCallPayloadType(call),
        .grouped => |inner| mmioMapPayloadTypeForExpr(inner.*),
        else => null,
    };
}

fn mmioMapCallPayloadType(call: anytype) ?ast.TypeExpr {
    if (!isMmioMapCallName(call.callee.*) or call.type_args.len != 1) return null;
    return .{
        .span = call.type_args[0].span,
        .kind = .{ .generic = .{
            .base = .{ .text = "MmioPtr", .span = call.type_args[0].span },
            .args = call.type_args[0..1],
        } },
    };
}

fn isMmioMapCallName(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "map") and isIdentNamed(member.base.*, "mmio"),
        .grouped => |inner| isMmioMapCallName(inner.*),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

const ReduceCallKind = enum { sum_checked, sum_left, sum_fast };

fn reduceCallKind(callee: ast.Expr) ?ReduceCallKind {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return reduceCallKind(inner.*),
        else => return null,
    };
    if (!isIdentNamed(member.base.*, "reduce")) return null;
    if (std.mem.eql(u8, member.name.text, "sum_checked")) return .sum_checked;
    if (std.mem.eql(u8, member.name.text, "sum_left")) return .sum_left;
    if (std.mem.eql(u8, member.name.text, "sum_fast")) return .sum_fast;
    return null;
}

fn reduceCallReturnTypeExpr(call: anytype) ?ast.TypeExpr {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    if (call.type_args.len != 1) return null;
    return switch (kind) {
        .sum_checked => null,
        .sum_left, .sum_fast => call.type_args[0],
    };
}

fn resultPayloadTypeExprAlias(ty: ast.TypeExpr, tag: []const u8, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return resultPayloadTypeExprAliasDepth(ty, tag, aliases, 0);
}

fn resultPayloadTypeExprAliasDepth(ty: ast.TypeExpr, tag: []const u8, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| resultPayloadTypeExprAliasDepth(resolved, tag, aliases, depth + 1) else null,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result")) blk: {
            if (std.mem.eql(u8, tag, "ok") and node.args.len >= 1) break :blk aggregateTargetTypeAlias(node.args[0], aliases);
            if (std.mem.eql(u8, tag, "err") and node.args.len >= 2) break :blk aggregateTargetTypeAlias(node.args[1], aliases);
            break :blk null;
        } else null,
        .qualified => |node| resultPayloadTypeExprAliasDepth(node.child.*, tag, aliases, depth + 1),
        else => null,
    };
}

fn structTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| structTypeName(node.child.*),
        else => null,
    };
}

fn structTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return structTypeNameAliasDepth(ty, aliases, 0);
}

fn structTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| structTypeNameAliasDepth(resolved, aliases, depth + 1) else name.text,
        .qualified => |node| structTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        // Member access auto-derefs a pointer-to-struct (`t.field` over `t: *mut T`),
        // so resolve the struct name through the pointee — matching the value-type
        // path (memberType) which already handles `.pointer`.
        .pointer => |node| structTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn unionTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return unionTypeNameAliasDepth(ty, aliases, 0);
}

fn unionTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| unionTypeNameAliasDepth(resolved, aliases, depth + 1) else name.text,
        .qualified => |node| unionTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn pointerShape(kind: PointerKind, mutability: ast.Mutability, child: ast.TypeExpr) PointerShape {
    return .{ .kind = kind, .mutability = mutability, .child = typeText(child) };
}

fn pointerShapeAlias(kind: PointerKind, mutability: ast.Mutability, child: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) PointerShape {
    return .{ .kind = kind, .mutability = mutability, .child = typeText(aggregateTargetTypeAlias(child, aliases)) };
}

fn nullPointerShape() PointerShape {
    return .{ .kind = .single, .mutability = .none, .child = "null" };
}

fn pointerShapeFromName(name: []const u8) PointerShape {
    if (std.mem.startsWith(u8, name, "[*]")) {
        return .{ .kind = .raw_many, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
    }
    if (std.mem.startsWith(u8, name, "[]")) {
        return .{ .kind = .slice, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
    }
    return .{ .kind = .single, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
}

fn pointerMutabilityFromName(name: []const u8) ast.Mutability {
    if (std.mem.indexOf(u8, name, "mut") != null) return .mut;
    if (std.mem.indexOf(u8, name, "const") != null) return .@"const";
    return .none;
}

fn pointerChildFromName(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "c_void") != null) return "c_void";
    if (std.mem.indexOf(u8, name, "u16") != null) return "u16";
    if (std.mem.indexOf(u8, name, "u32") != null) return "u32";
    if (std.mem.indexOf(u8, name, "u8") != null) return "u8";
    return "unknown";
}

fn namedValueType(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "never")) return .never;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "PAddr")) return .{ .address = .paddr };
    if (std.mem.eql(u8, name, "VAddr")) return .{ .address = .vaddr };
    if (std.mem.eql(u8, name, "DmaAddr")) return .{ .address = .dma_addr };
    if (enums.get(name)) |info| return if (info.is_open) .{ .open_enum = name } else .{ .closed_enum = name };
    if (structs.contains(name)) return .{ .struct_ = name };
    if (std.mem.startsWith(u8, name, "u") or std.mem.startsWith(u8, name, "i") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return .{ .integer = name };
    if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) return .{ .float = name };
    return .value;
}

fn namedValueTypeAlias(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary)) ValueType {
    if (packed_bits.contains(name)) return .{ .struct_ = name };
    return namedValueType(name, enums, structs);
}

fn genericValueType(node: anytype, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    const name = node.base.text;
    if (std.mem.eql(u8, name, "Result")) {
        return .{ .result = .{
            .ok = if (node.args.len >= 1) typeText(node.args[0]) else "unknown",
            .err = if (node.args.len >= 2) typeText(node.args[1]) else "unknown",
        } };
    }
    if (std.mem.eql(u8, name, "UserPtr")) return .{ .address = .user_ptr };
    if (std.mem.eql(u8, name, "MmioPtr")) return .{ .address = .mmio_ptr };
    if (std.mem.eql(u8, name, "PhysPtr")) return .{ .address = .phys_ptr };
    return namedValueType(name, enums, structs);
}

fn genericValueTypeAlias(node: anytype, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr)) ValueType {
    const name = node.base.text;
    if (std.mem.eql(u8, name, "Result")) {
        return .{ .result = .{
            .ok = if (node.args.len >= 1) typeText(aggregateTargetTypeAlias(node.args[0], aliases)) else "unknown",
            .err = if (node.args.len >= 2) typeText(aggregateTargetTypeAlias(node.args[1], aliases)) else "unknown",
        } };
    }
    if (std.mem.eql(u8, name, "UserPtr")) return .{ .address = .user_ptr };
    if (std.mem.eql(u8, name, "MmioPtr")) return .{ .address = .mmio_ptr };
    if (std.mem.eql(u8, name, "PhysPtr")) return .{ .address = .phys_ptr };
    if (aliases.get(name)) |resolved| return valueTypeFromTypeAlias(resolved, enums, structs, packed_bits, aliases);
    return namedValueTypeAlias(name, enums, structs, packed_bits);
}

fn addressClassName(kind: AddressClass) []const u8 {
    return switch (kind) {
        .paddr => "PAddr",
        .vaddr => "VAddr",
        .dma_addr => "DmaAddr",
        .user_ptr => "UserPtr",
        .mmio_ptr => "MmioPtr",
        .phys_ptr => "PhysPtr",
    };
}

fn addressClassFromName(name: []const u8) ?AddressClass {
    if (std.mem.eql(u8, name, "PAddr")) return .paddr;
    if (std.mem.eql(u8, name, "VAddr")) return .vaddr;
    if (std.mem.eql(u8, name, "DmaAddr")) return .dma_addr;
    if (std.mem.eql(u8, name, "UserPtr")) return .user_ptr;
    if (std.mem.eql(u8, name, "MmioPtr")) return .mmio_ptr;
    if (std.mem.eql(u8, name, "PhysPtr")) return .phys_ptr;
    return null;
}

fn addressDerefDiagnostic(kind: AddressClass) []const u8 {
    return switch (kind) {
        .paddr => "E_PADDR_DEREF",
        .vaddr => "E_VADDR_DEREF",
        .dma_addr => "E_DMA_ADDR_DEREF",
        .user_ptr => "E_USER_PTR_DEREF",
        .mmio_ptr => "E_MMIO_PTR_DEREF",
        .phys_ptr => "E_PHYS_PTR_DEREF",
    };
}

fn addressClassMismatch(target: ValueType, source: ValueType) ?AddressClass {
    const target_class = switch (target) {
        .address => |kind| kind,
        else => return null,
    };
    const source_class = switch (source) {
        .address => |kind| kind,
        else => return null,
    };
    if (target_class == source_class) return null;
    return source_class;
}

fn addressClassMismatchDiagnostic(target: AddressClass, source: AddressClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "E_DMA_ADDR_NOT_PADDR";
    if (source == .dma_addr and target == .vaddr) return "E_DMA_ADDR_NOT_VADDR";
    return "E_ADDRESS_CLASS_MISMATCH";
}

fn binaryMayOverflow(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

fn binaryTrapKind(op: ast.BinaryOp) TrapKind {
    return switch (op) {
        .div, .mod => .DivideByZero,
        .shl, .shr => .InvalidShift,
        .add, .sub, .mul => .IntegerOverflow,
        else => .Unknown,
    };
}

fn isShiftOp(op: ast.BinaryOp) bool {
    return op == .shl or op == .shr;
}

fn binaryChecksAddressClass(op: ast.BinaryOp) bool {
    return switch (op) {
        .logical_or,
        .logical_and,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .bit_or,
        .bit_xor,
        .bit_and,
        .shl,
        .shr,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        => true,
    };
}

fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

fn isWrapTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isWrapTypeAliasDepth(ty, aliases, 0);
}

fn isWrapTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isWrapTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

fn isSatTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isSatTypeAliasDepth(ty, aliases, 0);
}

fn isSatTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isSatTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn arithmeticDomainTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ArithmeticDomain {
    return arithmeticDomainTypeAliasDepth(ty, aliases, 0);
}

fn arithmeticDomainTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ArithmeticDomain {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| arithmeticDomainTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| arithmeticDomainName(node.base.text),
        .qualified => |node| arithmeticDomainTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn arithmeticDomainName(name: []const u8) ?ArithmeticDomain {
    if (std.mem.eql(u8, name, "wrap")) return .wrap;
    if (std.mem.eql(u8, name, "sat")) return .sat;
    if (std.mem.eql(u8, name, "serial")) return .serial;
    if (std.mem.eql(u8, name, "counter")) return .counter;
    return null;
}

fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}

fn mirIsArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

fn mirIsBitwiseBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

fn mirIsLogicalBinary(op: ast.BinaryOp) bool {
    return op == .logical_and or op == .logical_or;
}

fn mirIsOrderedComparison(op: ast.BinaryOp) bool {
    return switch (op) {
        .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn mirIsPointerArithmetic(op: ast.BinaryOp) bool {
    return op == .add or op == .sub;
}

// A single-object pointer (`*T`) supports no arithmetic (section 9); raw-many
// pointers (`[*]T`) do.
fn isMirSingleObjectPointer(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .single,
        else => false,
    };
}

// Pointers and views (slices) support only equality comparison, not ordering.
fn isMirPointerOrView(ty: ValueType) bool {
    return isPointerLikeType(ty) or ty == .slice;
}

fn isMirCVoidPointer(ty: ValueType) bool {
    return switch (ty) {
        .pointer, .nullable_pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        else => false,
    };
}

fn ffiFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "c_void_deref")) return "E_C_VOID_DEREF";
    return "E_C_VOID_NO_LAYOUT";
}

fn usageFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "atomic_operation")) return "E_ATOMIC_OPERATION";
    if (std.mem.eql(u8, finding, "dma_operation")) return "E_DMA_OPERATION";
    if (std.mem.eql(u8, finding, "enum_raw_closed")) return "E_ENUM_RAW_REQUIRES_OPEN_ENUM";
    if (std.mem.eql(u8, finding, "atomic_ordering")) return "E_ATOMIC_ORDERING";
    if (std.mem.eql(u8, finding, "mmio_ordering")) return "E_MMIO_ORDERING";
    if (std.mem.eql(u8, finding, "closed_enum_conversion")) return "E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION";
    if (std.mem.eql(u8, finding, "bitcast_type")) return "E_BITCAST_TYPE";
    if (std.mem.eql(u8, finding, "dma_cache_mode")) return "E_DMA_CACHE_MODE";
    if (std.mem.eql(u8, finding, "local_address_escape")) return "E_LOCAL_ADDRESS_ESCAPE";
    return "E_OPERATOR_OPERAND";
}

fn dmaBufModeName(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return dmaBufModeNameDepth(ty, aliases, 0);
}

fn dmaBufModeNameDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |n| if (aliases.get(n.text)) |t| dmaBufModeNameDepth(t, aliases, depth + 1) else null,
        .qualified => |node| dmaBufModeNameDepth(node.child.*, aliases, depth + 1),
        .generic => |node| if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2)
            (switch (node.args[1].kind) {
                .enum_literal => |id| id.text,
                else => null,
            })
        else
            null,
        else => null,
    };
}

fn isMirIntegerType(ty: ValueType) bool {
    return ty == .integer;
}

fn assignmentTargetIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| id.text,
        .grouped => |inner| assignmentTargetIdentName(inner.*),
        else => null,
    };
}

// bitcast operands must have a fixed scalar/pointer/address layout (section 15);
// `.unknown` is treated as valid to avoid false positives.
fn isMirBitcastLayout(ty: ValueType) bool {
    return switch (ty) {
        .integer, .float, .bool, .pointer, .nullable_pointer, .address, .unknown => true,
        else => false,
    };
}

fn isMirBitcastCallee(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |id| std.mem.eql(u8, id.text, "bitcast"),
        .grouped => |inner| isMirBitcastCallee(inner.*),
        else => false,
    };
}

fn isMirMmioReadOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire");
}

fn isMirMmioWriteOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "release");
}

fn enumLiteralText(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |ident| ident.text,
        .grouped => |inner| enumLiteralText(inner.*),
        else => null,
    };
}

fn isMirAtomicLoadOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire") or std.mem.eql(u8, o, "seq_cst");
}

fn isMirAtomicStoreOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "release") or std.mem.eql(u8, o, "seq_cst");
}

fn isMirAtomicOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire") or
        std.mem.eql(u8, o, "release") or std.mem.eql(u8, o, "acq_rel") or std.mem.eql(u8, o, "seq_cst");
}

// Ordered comparison is forbidden on wrap/serial/counter, allowed on sat
// (sections 5.2-5.5).
fn isMirForbiddenOrderingDomain(domain: ?ArithmeticDomain) bool {
    return switch (domain orelse return false) {
        .wrap, .serial, .counter => true,
        .sat => false,
    };
}

fn mirIsComparisonBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn logicalOperandsAllowed(left: ValueType, right: ValueType) bool {
    return logicalOperandAllowed(left) and logicalOperandAllowed(right);
}

fn logicalOperandAllowed(ty: ValueType) bool {
    return ty == .bool or ty == .unknown or ty == .never;
}

fn unaryNegOperandAllowed(domain: ?ArithmeticDomain, ty: ValueType) bool {
    if (domain != null) return true;
    if (isCheckedUnsignedType(ty)) return true;
    if (isCheckedSignedType(ty) or isFloatType(ty)) return true;
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "comptime_int"),
        // unary '-' on an untyped float literal (e.g. `-0.3`) is well-defined; the literal
        // is typed `comptime_float` until it unifies with f32/f64 at its use site.
        .float => |name| std.mem.eql(u8, name, "comptime_float"),
        .unknown, .never => true,
        else => false,
    };
}

fn bitwiseOperandAllowed(domain: ?ArithmeticDomain, ty: ValueType) bool {
    if (domain) |known| return known == .wrap or known == .sat or known == .serial or known == .counter;
    if (isCheckedUnsignedType(ty)) return true;
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "comptime_int"),
        .unknown, .never => true,
        else => false,
    };
}

fn checkedIntegerBinaryFinding(left: ValueType, right: ValueType) ?[]const u8 {
    if (!isCheckedIntegerType(left) or !isCheckedIntegerType(right)) return null;
    if (sameScalarTypeName(left, right)) return null;
    if ((isCheckedSignedType(left) and isCheckedUnsignedType(right)) or (isCheckedUnsignedType(left) and isCheckedSignedType(right))) {
        return "signed_unsigned_mix";
    }
    return "integer_promotion";
}

fn floatBinaryFinding(op: ast.BinaryOp, left: ValueType, right: ValueType) ?[]const u8 {
    if (!isFloatishType(left) and !isFloatishType(right)) return null;
    if (left == .unknown or right == .unknown or left == .never or right == .never) return null;
    if (op == .mod and (isFloatType(left) or isFloatType(right))) return "operator_operand";
    if (isFloatishType(left) and isFloatishType(right)) {
        if (isFloatType(left) and isFloatType(right) and !sameScalarTypeName(left, right)) return "float_binary_conversion";
        return null;
    }
    return "float_binary_conversion";
}

fn isCheckedIntegerType(ty: ValueType) bool {
    return isCheckedUnsignedType(ty) or isCheckedSignedType(ty);
}

fn isCheckedUnsignedType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "u8") or
            std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or
            std.mem.eql(u8, name, "u64") or
            std.mem.eql(u8, name, "usize"),
        else => false,
    };
}

fn isCheckedSignedType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "i8") or
            std.mem.eql(u8, name, "i16") or
            std.mem.eql(u8, name, "i32") or
            std.mem.eql(u8, name, "i64") or
            std.mem.eql(u8, name, "isize"),
        else => false,
    };
}

fn isFloatishType(ty: ValueType) bool {
    return switch (ty) {
        .float => true,
        else => false,
    };
}

fn isFloatType(ty: ValueType) bool {
    return switch (ty) {
        .float => |name| std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64"),
        else => false,
    };
}

fn sameScalarTypeName(left: ValueType, right: ValueType) bool {
    return switch (left) {
        .integer => |left_name| switch (right) {
            .integer => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        .float => |left_name| switch (right) {
            .float => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        else => false,
    };
}

fn exprTerminates(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => true,
        .grouped => |inner| exprTerminates(inner.*),
        .call => |node| isTrapCall(node.callee.*),
        else => false,
    };
}

fn exprText(expr: ast.Expr) []const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .int_literal => "int",
        .float_literal => "float",
        .string_literal => "string",
        .char_literal => "char",
        .bool_literal => "bool",
        .null_literal => "null",
        .uninit_literal => "uninit",
        .unreachable_expr => "unreachable",
        .void_literal => "void",
        .enum_literal => |ident| ident.text,
        .array_literal => "array_literal",
        .struct_literal => "struct_literal",
        .call => |node| exprText(node.callee.*),
        .member => |node| memberName(node),
        .grouped => |inner| exprText(inner.*),
        else => @tagName(expr.kind),
    };
}

fn memberName(node: anytype) []const u8 {
    if (node.base.kind == .ident) {
        const base = node.base.kind.ident.text;
        if (std.mem.eql(u8, base, "raw") or std.mem.eql(u8, base, "mmio") or std.mem.eql(u8, base, "atomic") or std.mem.eql(u8, base, "unchecked") or std.mem.eql(u8, base, "compiler")) {
            return node.name.text;
        }
    }
    return node.name.text;
}

fn patternText(pattern: ast.Pattern) []const u8 {
    return switch (pattern.kind) {
        .wildcard => "_",
        .bind => |ident| ident.text,
        .tag => |ident| ident.text,
        .tag_bind => |node| node.tag.text,
        .literal => "literal",
    };
}

fn typeText(ty: ast.TypeExpr) []const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .enum_literal => |literal| literal.text,
        .member => |node| node.field.text,
        .nullable => "?",
        .qualified => |node| typeText(node.child.*),
        .pointer => |node| pointerTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .raw_many_pointer => |node| rawManyPointerTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .slice => |node| sliceTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .array => "array",
        .generic => |node| node.base.text,
        .fn_pointer => "fn",
        .closure_type => "closure",
    };
}

fn pointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "*",
        .mut => "*mut",
        .@"const" => "*const",
    };
}

fn pointerTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "* u8",
        .mut => "*mut u8",
        .@"const" => "*const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "* u16",
        .mut => "*mut u16",
        .@"const" => "*const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "* u32",
        .mut => "*mut u32",
        .@"const" => "*const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "* c_void",
        .mut => "*mut c_void",
        .@"const" => "*const c_void",
    };
    return pointerTypeText(mutability);
}

fn rawManyPointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[*]",
        .mut => "[*]mut",
        .@"const" => "[*]const",
    };
}

fn rawManyPointerTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "[*] u8",
        .mut => "[*]mut u8",
        .@"const" => "[*]const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "[*] u16",
        .mut => "[*]mut u16",
        .@"const" => "[*]const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "[*] u32",
        .mut => "[*]mut u32",
        .@"const" => "[*]const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "[*] c_void",
        .mut => "[*]mut c_void",
        .@"const" => "[*]const c_void",
    };
    return rawManyPointerTypeText(mutability);
}

fn sliceTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[]",
        .mut => "[]mut",
        .@"const" => "[]const",
    };
}

fn sliceTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "[] u8",
        .mut => "[]mut u8",
        .@"const" => "[]const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "[] u16",
        .mut => "[]mut u16",
        .@"const" => "[]const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "[] u32",
        .mut => "[]mut u32",
        .@"const" => "[]const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "[] c_void",
        .mut => "[]mut c_void",
        .@"const" => "[]const c_void",
    };
    return sliceTypeText(mutability);
}

fn isTrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCall(inner.*),
        else => false,
    };
}

fn isUnwrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "unwrap"),
        .grouped => |inner| isUnwrapCall(inner.*),
        else => false,
    };
}

fn directCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .member => |node| qualifiedMemberName(node),
        .grouped => |inner| directCalleeName(inner.*),
        else => null,
    };
}

fn qualifiedMemberName(node: anytype) ?[]const u8 {
    if (std.mem.eql(u8, node.name.text, "offset")) return "ptr.offset";
    if (node.base.kind != .ident) return node.name.text;
    const base = node.base.kind.ident.text;
    if (std.mem.eql(u8, base, "lock") and std.mem.eql(u8, node.name.text, "acquire")) return "lock.acquire";
    if (std.mem.eql(u8, base, "heap") and std.mem.eql(u8, node.name.text, "alloc")) return "heap.alloc";
    if (std.mem.eql(u8, base, "device") and std.mem.eql(u8, node.name.text, "wait_irq")) return "device.wait_irq";
    if (std.mem.eql(u8, base, "fs") and std.mem.eql(u8, node.name.text, "read")) return "fs.read";
    if (std.mem.eql(u8, base, "wrapping")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "wrapping.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "wrapping.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "wrapping.mul";
        if (std.mem.eql(u8, node.name.text, "neg")) return "wrapping.neg";
    }
    if (std.mem.eql(u8, base, "saturating")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "saturating.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "saturating.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "saturating.mul";
    }
    if (std.mem.eql(u8, base, "unchecked")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "unchecked.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "unchecked.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "unchecked.mul";
        return node.name.text;
    }
    if (std.mem.eql(u8, base, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked")) return "compiler.assume_noalias_unchecked";
    if (std.mem.eql(u8, base, "raw")) {
        if (std.mem.eql(u8, node.name.text, "store")) return "raw.store";
        if (std.mem.eql(u8, node.name.text, "load")) return "raw.load";
    }
    if (std.mem.eql(u8, base, "mmio")) {
        if (std.mem.eql(u8, node.name.text, "read")) return "mmio.read";
        if (std.mem.eql(u8, node.name.text, "write")) return "mmio.write";
        if (std.mem.eql(u8, node.name.text, "map")) return "mmio.map";
    }
    if (std.mem.eql(u8, base, "atomic")) {
        if (std.mem.eql(u8, node.name.text, "init")) return "atomic.init";
        if (std.mem.eql(u8, node.name.text, "load")) return "atomic.load";
        if (std.mem.eql(u8, node.name.text, "store")) return "atomic.store";
        if (std.mem.eql(u8, node.name.text, "rmw")) return "atomic.rmw";
        if (std.mem.eql(u8, node.name.text, "fetch_add")) return "atomic.fetch_add";
        if (std.mem.eql(u8, node.name.text, "fetch_sub")) return "atomic.fetch_sub";
    }
    return node.name.text;
}

fn isAtomicTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isAtomicTypeExprAliasDepth(ty, aliases, 0);
}

fn isAtomicTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isAtomicTypeExprAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "atomic"),
        .qualified => |node| isAtomicTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn isMmioRegisterTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isMmioRegisterTypeExprAliasDepth(ty, aliases, 0);
}

fn isMmioRegisterTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isMmioRegisterTypeExprAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits"),
        .qualified => |node| isMmioRegisterTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

fn mmioRegisterAccessFromTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?MmioRegisterAccess {
    return mmioRegisterAccessFromTypeExprAliasDepth(ty, aliases, 0);
}

fn mmioRegisterReadValueTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return mmioRegisterReadValueTypeExprAliasDepth(ty, aliases, 0);
}

fn mmioRegisterReadValueTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioRegisterReadValueTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            if (std.mem.eql(u8, node.base.text, "Reg") and node.args.len == 2) break :blk node.args[0];
            if (std.mem.eql(u8, node.base.text, "RegBits") and node.args.len == 3) break :blk node.args[1];
            break :blk null;
        },
        .qualified => |node| mmioRegisterReadValueTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn mmioRegisterAccessFromTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?MmioRegisterAccess {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioRegisterAccessFromTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            const access_ty: ast.TypeExpr = if (std.mem.eql(u8, node.base.text, "Reg") and node.args.len == 2)
                node.args[1]
            else if (std.mem.eql(u8, node.base.text, "RegBits") and node.args.len == 3)
                node.args[2]
            else
                break :blk null;
            break :blk mmioRegisterAccessFromModeType(access_ty);
        },
        .qualified => |node| mmioRegisterAccessFromTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn mmioRegisterAccessFromModeType(ty: ast.TypeExpr) ?MmioRegisterAccess {
    const name = switch (ty.kind) {
        .enum_literal => |literal| literal.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "read_write")) return .read_write;
    return null;
}

fn mmioPtrTargetTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return mmioPtrTargetTypeNameAliasDepth(ty, aliases, 0);
}

fn mmioPtrTargetTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioPtrTargetTypeNameAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            if (!std.mem.eql(u8, node.base.text, "MmioPtr") or node.args.len != 1) break :blk null;
            break :blk structTypeNameAlias(node.args[0], aliases);
        },
        .qualified => |node| mmioPtrTargetTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn isUncheckedCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| if (node.base.kind == .ident)
            std.mem.eql(u8, node.base.kind.ident.text, "unchecked") or
                (std.mem.eql(u8, node.base.kind.ident.text, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked"))
        else
            false,
        .ident => |ident| std.mem.startsWith(u8, ident.text, "unchecked_") or std.mem.eql(u8, ident.text, "assume_noalias_unchecked"),
        .grouped => |inner| isUncheckedCall(inner.*),
        else => false,
    };
}

fn constGetBase(call: anytype) ?*ast.Expr {
    if (call.args.len != 0 or call.type_args.len != 1) return null;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
    return member.base;
}

fn isUnsafeOperationCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| {
            if (exprIsIdentNamed(node.base.*, "raw") and std.mem.eql(u8, node.name.text, "store")) return true;
            if (exprIsIdentNamed(node.base.*, "mmio") and std.mem.eql(u8, node.name.text, "map")) return true;
            return false;
        },
        .grouped => |inner| isUnsafeOperationCall(inner.*),
        else => false,
    };
}

fn isRawManyPointerValue(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .raw_many,
        else => false,
    };
}

fn isNonBlockingPrimitive(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "raw.") or
        std.mem.startsWith(u8, name, "mmio.") or
        std.mem.startsWith(u8, name, "atomic.") or
        std.mem.startsWith(u8, name, "raw_") or
        std.mem.startsWith(u8, name, "mmio_") or
        std.mem.startsWith(u8, name, "atomic_");
}

fn isKnownBlockingIrqCallee(name: []const u8) bool {
    return std.mem.eql(u8, name, "lock.acquire") or
        std.mem.eql(u8, name, "heap.alloc") or
        std.mem.eql(u8, name, "device.wait_irq") or
        std.mem.eql(u8, name, "fs.read");
}

fn isKnownNoLanguageTrapPrimitive(name: []const u8) bool {
    return isNonBlockingPrimitive(name) or
        std.mem.startsWith(u8, name, "wrapping.") or
        std.mem.startsWith(u8, name, "saturating.") or
        std.mem.eql(u8, name, "ptr.offset");
}

// Trap behaviour of the scalar/domain builtin member methods (sections 3, 5).
// `trap_from` raises a range trap; the rest are pure casts/clamps/modular ops or
// return a `Result`, and never raise a language trap.
const ConversionTrap = enum { not_builtin, no_trap, traps };

fn conversionDomainCallTrap(callee: ast.Expr) ConversionTrap {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return conversionDomainCallTrap(inner.*),
        else => return .not_builtin,
    };
    const m = member.name.text;
    if (std.mem.eql(u8, m, "trap_from")) return .traps;
    if (isMirConversionName(m) or isMirSerialOpName(m) or isMirCounterOpName(m) or std.mem.eql(u8, m, "residue")) return .no_trap;
    return .not_builtin;
}

fn isMirConversionName(m: []const u8) bool {
    return std.mem.eql(u8, m, "from") or
        std.mem.eql(u8, m, "try_from") or
        std.mem.eql(u8, m, "trap_from") or
        std.mem.eql(u8, m, "wrap_from") or
        std.mem.eql(u8, m, "sat_from") or
        std.mem.eql(u8, m, "from_mod");
}

fn isMirSerialOpName(m: []const u8) bool {
    return std.mem.eql(u8, m, "before") or
        std.mem.eql(u8, m, "after") or
        std.mem.eql(u8, m, "distance") or
        std.mem.eql(u8, m, "compare");
}

fn isMirCounterOpName(m: []const u8) bool {
    return std.mem.eql(u8, m, "delta_mod") or
        std.mem.eql(u8, m, "elapsed_assume_within") or
        std.mem.eql(u8, m, "elapsed_bounded");
}

fn callResultRepresentationCheckTraps(name: []const u8) bool {
    return !std.mem.eql(u8, name, "ptr.offset");
}

fn isKnownDirectPrimitive(name: []const u8) bool {
    return isKnownNoLanguageTrapPrimitive(name) or
        std.mem.startsWith(u8, name, "unchecked.") or
        std.mem.startsWith(u8, name, "unchecked_") or
        std.mem.eql(u8, name, "compiler.assume_noalias_unchecked") or
        std.mem.eql(u8, name, "assume_noalias_unchecked");
}

fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named, .backend_name, .origin => "unknown",
    };
}

fn contractBlockEndLine(block: ast.Block) usize {
    if (block.items.len == 0) return block.span.line;
    return block.items[block.items.len - 1].span.line;
}

fn functionHasInstruction(function: Function, kind: Instruction.Kind, detail: []const u8) bool {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind == kind and std.mem.eql(u8, instruction.detail, detail)) return true;
        }
    }
    return false;
}

fn countTrapEdges(function: Function, kind: TrapKind) usize {
    var count: usize = 0;
    for (function.trap_edges) |edge| {
        if (edge.kind == kind) count += 1;
    }
    return count;
}

test "MIR resolves type aliases for checked ints and arithmetic domains" {
    const source =
        \\type Count = u32;
        \\type HashWord = wrap<u32>;
        \\type Level = sat<u8>;
        \\
        \\fn checked_alias_add(a: Count, b: Count) -> Count {
        \\    return a + b;
        \\}
        \\
        \\fn wrap_alias_add(a: HashWord, b: HashWord) -> HashWord {
        \\    return a + b;
        \\}
        \\
        \\fn sat_alias_add(a: Level, b: Level) -> Level {
        \\    return a + b;
        \\}
        \\
        \\fn wrap_cast_add(a: u32, b: u32) -> HashWord {
        \\    return (a as HashWord) + (b as HashWord);
        \\}
        \\
        \\fn sat_cast_add(a: u8, b: u8) -> Level {
        \\    return (a as Level) + (b as Level);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_alias_domains.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const checked_fn = functionByName(typed_mir, "checked_alias_add").?;
    const wrap_fn = functionByName(typed_mir, "wrap_alias_add").?;
    const sat_fn = functionByName(typed_mir, "sat_alias_add").?;
    const wrap_cast_fn = functionByName(typed_mir, "wrap_cast_add").?;
    const sat_cast_fn = functionByName(typed_mir, "sat_cast_add").?;

    try std.testing.expect(functionHasInstruction(checked_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(wrap_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(sat_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(wrap_cast_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(sat_cast_fn, .add_overflow, "add"));
    try std.testing.expectEqual(@as(usize, 0), wrap_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), sat_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), wrap_cast_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), sat_cast_fn.trap_edges.len);
}

test "OPT const-index bounds-check elision drops only provably-dead Bounds trap edges" {
    const source =
        \\fn const_index(a: [4]u32) -> u32 {
        \\    return a[2];
        \\}
        \\fn var_index(a: [4]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
        \\fn const_div(x: u32) -> u32 {
        \\    return x / 7;
        \\}
        \\fn var_div(x: u32, y: u32) -> u32 {
        \\    return x / y;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_opt_bounds.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    // Default build keeps each check and its trap edge (Bounds for the indices, DivideByZero
    // for the divisions).
    var base = try build(std.testing.allocator, module);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_div").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_div").?.trap_edges.len);

    // Optimized build elides the provably-dead checks — the in-range constant index (2 < 4)
    // and the unsigned division by a non-zero literal (/ 7) — but keeps the variable index's
    // and variable divisor's checks; the proofs are conservative.
    var opt = try buildOpt(std.testing.allocator, module, .{ .optimize = true });
    defer opt.deinit();
    try std.testing.expectEqual(@as(usize, 0), functionByName(opt, "const_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(opt, "var_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), functionByName(opt, "const_div").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(opt, "var_div").?.trap_edges.len);
}

test "MIR verifier reports arithmetic-domain misuse" {
    const source =
        \\type HashWord = wrap<u32>;
        \\type Level = sat<u8>;
        \\type Seq = serial<u32>;
        \\type Ticks = counter<u64>;
        \\
        \\fn reject_wrap_checked_mix(a: HashWord, b: u32) -> HashWord {
        \\    return a + b;
        \\}
        \\
        \\fn reject_sat_bitwise(a: Level, b: Level) -> Level {
        \\    return a & b;
        \\}
        \\
        \\fn reject_wrap_div(a: HashWord, b: HashWord) -> HashWord {
        \\    return a / b;
        \\}
        \\
        \\fn reject_serial_checked_mix(a: Seq, b: u32) -> Seq {
        \\    return a + b;
        \\}
        \\
        \\fn reject_counter_bitwise(a: Ticks, b: Ticks) -> Ticks {
        \\    return a & b;
        \\}
        \\
        \\fn reject_cast_wrap_checked_mix(a: u32, b: u32) -> HashWord {
        \\    return (a as HashWord) + b;
        \\}
        \\
        \\fn reject_cast_sat_bitwise(a: u8, b: u8) -> Level {
        \\    return (a as Level) & (b as Level);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_arith_domains.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var found_mix = false;
    var found_division = false;
    var found_bitwise: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_ARITH_POLICY_MIX") != null) found_mix = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARITH_DOMAIN_DIVISION") != null) found_division = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_ARITH_DOMAIN_OPERAND") != null) found_bitwise += 1;
    }
    try std.testing.expect(found_mix);
    try std.testing.expect(found_division);
    try std.testing.expect(found_bitwise >= 2);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_wrap_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_sat_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_wrap_div pass=core finding=arith_domain_division") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_serial_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_counter_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_wrap_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_sat_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
}

test "MIR verifier reports invalid operator operands" {
    const source =
        \\fn reject_unsigned_negation(x: u32) -> u32 {
        \\    return -x;
        \\}
        \\
        \\fn reject_integer_not(n: u32) -> bool {
        \\    return !n;
        \\}
        \\
        \\fn reject_integer_logical_and(flag: bool, n: u32) -> bool {
        \\    return flag && n;
        \\}
        \\
        \\fn reject_signed_bitwise(a: i32, b: i32) -> i32 {
        \\    return a & b;
        \\}
        \\
        \\fn reject_bool_bitwise(a: bool, b: bool) -> bool {
        \\    return a & b;
        \\}
        \\
        \\fn reject_pointer_bitwise(a: *mut u8, b: *mut u8) -> *mut u8 {
        \\    return a & b;
        \\}
        \\
        \\fn reject_null_bitwise() -> void {
        \\    let value = null & null;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_operator_operands.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var found_unsigned_negation = false;
    var found_bool_operator: usize = 0;
    var found_signed_bitwise = false;
    var found_bool_bitwise = false;
    var found_pointer_bitwise = false;
    var found_operator_operand = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNSIGNED_NEGATION") != null) found_unsigned_negation = true;
        if (std.mem.indexOf(u8, diag.message, "E_BOOL_OPERATOR_OPERAND") != null) found_bool_operator += 1;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_SIGNED_OPERAND") != null) found_signed_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_BOOL_OPERAND") != null) found_bool_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_POINTER_OPERAND") != null) found_pointer_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_OPERATOR_OPERAND") != null) found_operator_operand = true;
    }
    try std.testing.expect(found_unsigned_negation);
    try std.testing.expect(found_bool_operator >= 2);
    try std.testing.expect(found_signed_bitwise);
    try std.testing.expect(found_bool_bitwise);
    try std.testing.expect(found_pointer_bitwise);
    try std.testing.expect(found_operator_operand);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unsigned_negation pass=core finding=unsigned_negation") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_not pass=core finding=bool_operator_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_logical_and pass=core finding=bool_operator_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_bitwise pass=core finding=bitwise_signed_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_bitwise pass=core finding=bitwise_bool_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_pointer_bitwise pass=core finding=bitwise_pointer_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_bitwise pass=core finding=operator_operand") != null);
}

test "MIR verifier reports binary numeric compatibility errors" {
    const source =
        \\fn reject_signed_unsigned_arithmetic(a: i32, b: u32) -> i32 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_unsigned_signed_comparison(a: u32, b: i32) -> bool {
        \\    return a < b;
        \\}
        \\
        \\fn reject_integer_width_arithmetic(a: u16, b: u32) -> u16 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_signed_width_comparison(a: i16, b: i32) -> bool {
        \\    return a == b;
        \\}
        \\
        \\fn reject_f32_f64_mix(a: f32, b: f64) -> f64 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_float_int_mix(a: f32, b: u32) -> f32 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_float_remainder(a: f64, b: f64) -> f64 {
        \\    return a % b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_numeric_compat.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var signed_unsigned_count: usize = 0;
    var promotion_count: usize = 0;
    var no_implicit_count: usize = 0;
    var operator_operand_found = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_SIGNED_UNSIGNED_MIX") != null) signed_unsigned_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_INTEGER_PROMOTION") != null) promotion_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) no_implicit_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_OPERATOR_OPERAND") != null) operator_operand_found = true;
    }
    try std.testing.expect(signed_unsigned_count >= 2);
    try std.testing.expect(promotion_count >= 2);
    try std.testing.expect(no_implicit_count >= 2);
    try std.testing.expect(operator_operand_found);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_unsigned_arithmetic pass=core finding=signed_unsigned_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unsigned_signed_comparison pass=core finding=signed_unsigned_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_width_arithmetic pass=core finding=integer_promotion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_width_comparison pass=core finding=integer_promotion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_f32_f64_mix pass=core finding=float_binary_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_float_int_mix pass=core finding=float_binary_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_float_remainder pass=core finding=operator_operand") != null);
}

test "builds typed MIR CFG with explicit trap edge" {
    const source =
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions.len);
    try std.testing.expect(typed_mir.functions[0].blocks.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions[0].trap_edges.len);
    try std.testing.expectEqual(TrapKind.IntegerOverflow, typed_mir.functions[0].trap_edges[0].kind);
}

test "MIR records complete checked binary trap edges for division remainder and shifts" {
    const source =
        \\fn unsigned_div(a: u32, b: u32) -> u32 {
        \\    return a / b;
        \\}
        \\
        \\fn unsigned_rem(a: u32, b: u32) -> u32 {
        \\    return a % b;
        \\}
        \\
        \\fn signed_div(a: i32, b: i32) -> i32 {
        \\    return a / b;
        \\}
        \\
        \\fn signed_rem(a: i32, b: i32) -> i32 {
        \\    return a % b;
        \\}
        \\
        \\fn checked_shl(a: u32, b: u32) -> u32 {
        \\    return a << b;
        \\}
        \\
        \\fn checked_shr(a: u32, b: u32) -> u32 {
        \\    return a >> b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_div(a: u32, b: u32) -> u32 {
        \\    return a / b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_binary_traps.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const unsigned_div_fn = functionByName(typed_mir, "unsigned_div").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(unsigned_div_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(unsigned_div_fn, .IntegerOverflow));

    const unsigned_rem_fn = functionByName(typed_mir, "unsigned_rem").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(unsigned_rem_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(unsigned_rem_fn, .IntegerOverflow));

    const signed_div_fn = functionByName(typed_mir, "signed_div").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_div_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_div_fn, .IntegerOverflow));

    const signed_rem_fn = functionByName(typed_mir, "signed_rem").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_rem_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_rem_fn, .IntegerOverflow));

    const checked_shl_fn = functionByName(typed_mir, "checked_shl").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shl_fn, .InvalidShift));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shl_fn, .IntegerOverflow));

    const checked_shr_fn = functionByName(typed_mir, "checked_shr").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shr_fn, .InvalidShift));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(checked_shr_fn, .IntegerOverflow));

    try verifyBuiltMir(typed_mir, &reporter);
    var found_no_lang = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang = true;
    }
    try std.testing.expect(found_no_lang);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=signed_div pass=trap finding=trap_edge detail=DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=signed_div pass=trap finding=trap_edge detail=IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shl pass=trap finding=trap_edge detail=InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shl pass=trap finding=trap_edge detail=IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shr pass=trap finding=trap_edge detail=InvalidShift") != null);
}

test "MIR const_get fixed indexing has no bounds trap edge" {
    const source =
        \\#[no_lang_trap]
        \\fn fixed(xs: [2]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
        \\
        \\#[no_lang_trap]
        \\fn rejected(xs: [2]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_const_get.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const fixed_fn = functionByName(typed_mir, "fixed").?;
    const rejected_fn = functionByName(typed_mir, "rejected").?;
    try std.testing.expect(functionHasInstruction(fixed_fn, .index, "const_get"));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(fixed_fn, .Bounds));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(rejected_fn, .Bounds));

    try verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(reporter.has_errors);
    var no_lang_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) no_lang_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), no_lang_count);
}

test "MIR verifier reports no_lang_trap, fallthrough, contract, and irq findings" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn blocking() -> void {}
        \\
        \\#[irq_context]
        \\fn irq_entry() -> void {
        \\    blocking();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_verify.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var found_missing_return = false;
    var found_no_lang_trap = false;
    var found_irq = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_MISSING") != null) found_missing_return = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) found_irq = true;
    }
    try std.testing.expect(found_missing_return);
    try std.testing.expect(found_no_lang_trap);
    try std.testing.expect(found_irq);
}

test "MIR verifier requires matching unsafe contract kind" {
    const source =
        \\fn wrong_overflow_contract(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        return unchecked.add(a, b);
        \\    }
        \\}
        \\
        \\fn wrong_noalias_contract(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_contract_kind.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNCHECKED_OUTSIDE_CONTRACT") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "MIR verifier reports strict unsafe effects outside unsafe blocks" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\fn reject_raw_store(addr: PAddr, value: u64) -> void {
        \\    raw.store<u64>(addr, value);
        \\}
        \\
        \\fn reject_mmio_map(pa: PAddr) -> void {
        \\    mmio.map<Uart16550>(pa);
        \\}
        \\
        \\fn reject_asm() -> void {
        \\    asm opaque volatile {
        \\        "cli"
        \\    }
        \\}
        \\
        \\fn reject_raw_many_deref(p: [*]mut u8) -> u8 {
        \\    return p.*;
        \\}
        \\
        \\fn accept_unsafe_effects(addr: PAddr, value: u64, pa: PAddr) -> void {
        \\    unsafe {
        \\        raw.store<u64>(addr, value);
        \\        mmio.map<Uart16550>(pa);
        \\        asm opaque volatile {
        \\            "cli"
        \\        }
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_strict_unsafe.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var unsafe_required_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNSAFE_REQUIRED") != null) unsafe_required_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), unsafe_required_count);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_store pass=unsafe finding=unsafe_required detail=raw.store") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_mmio_map pass=unsafe finding=unsafe_required detail=mmio.map") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_asm pass=unsafe finding=unsafe_required detail=asm.opaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_many_deref pass=unsafe finding=unsafe_required detail=raw_many.deref") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_unsafe_effects pass=unsafe finding=unsafe_required") == null);
}

test "MIR context verifier handles extern irq callees and ordinary store name" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    tx_empty: bool,
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\#[irq_context]
        \\extern fn irq_poll() -> void;
        \\
        \\type IrqCounter = atomic<u32>;
        \\type IrqUart = MmioPtr<Uart16550>;
        \\
        \\fn store() -> void {}
        \\
        \\#[irq_context]
        \\fn accepted_irq() -> void {
        \\    irq_poll();
        \\}
        \\
        \\#[irq_context]
        \\fn accepted_atomic(flag: atomic<u32>, counter: IrqCounter, value: u32) -> void {
        \\    flag.store(value, .release);
        \\    counter.fetch_add(value, .acq_rel);
        \\}
        \\
        \\#[irq_context]
        \\fn accepted_mmio(uart: IrqUart, value: u8) -> void {
        \\    uart.thr.write(value, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\}
        \\
        \\#[irq_context]
        \\fn rejected_store_name() -> void {
        \\    store();
        \\}
        \\
        \\#[irq_context]
        \\fn rejected_blocking(n: usize, path: u32) -> void {
        \\    lock.acquire();
        \\    heap.alloc(n);
        \\    device.wait_irq();
        \\    fs.read(path);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_irq.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    var irq_call_count: usize = 0;
    var irq_blocking_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) irq_call_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_BLOCKING") != null) irq_blocking_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), irq_call_count);
    try std.testing.expectEqual(@as(usize, 4), irq_blocking_count);
    try std.testing.expectEqual(@as(usize, 5), reporter.diagnostics.items.len);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const accepted_mmio_fn = functionByName(typed_mir, "accepted_mmio").?;
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.read"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_store_name pass=context finding=irq_call detail=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=lock.acquire") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=heap.alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=device.wait_irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=fs.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_irq pass=context finding=irq_call detail=irq_poll") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_atomic pass=context finding=irq_call") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_mmio pass=context finding=irq_call") == null);
}

test "MIR verifier enforces typed MMIO register access modes" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\type TxReg = Reg<u8, .write>;
        \\type StatusReg = RegBits<u8, Status, .read>;
        \\
        \\extern mmio struct Uart {
        \\    tx: TxReg,
        \\    status: StatusReg,
        \\    ctrl: Reg<u8, .read_write>,
        \\}
        \\
        \\fn reject_read_write_only(uart: MmioPtr<Uart>) -> u8 {
        \\    return uart.tx.read(.relaxed);
        \\}
        \\
        \\fn reject_write_read_only(uart: MmioPtr<Uart>, value: u8) -> void {
        \\    uart.status.write(value, .relaxed);
        \\}
        \\
        \\fn accept_read_write(uart: MmioPtr<Uart>, value: u8) -> u8 {
        \\    uart.ctrl.write(value, .relaxed);
        \\    return uart.ctrl.read(.relaxed);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_mmio_access.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const reject_read_fn = functionByName(typed_mir, "reject_read_write_only").?;
    const reject_write_fn = functionByName(typed_mir, "reject_write_read_only").?;
    const accept_fn = functionByName(typed_mir, "accept_read_write").?;
    try std.testing.expect(functionHasInstruction(reject_read_fn, .call, "mmio.read"));
    try std.testing.expect(functionHasInstruction(reject_read_fn, .mmio_check, "read"));
    try std.testing.expect(functionHasInstruction(reject_write_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(reject_write_fn, .mmio_check, "write"));
    try std.testing.expect(functionHasInstruction(accept_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(accept_fn, .call, "mmio.read"));
    try std.testing.expect(!functionHasInstruction(accept_fn, .mmio_check, "read"));
    try std.testing.expect(!functionHasInstruction(accept_fn, .mmio_check, "write"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_read_write_only pass=mmio finding=access_forbidden op=read") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_write_read_only pass=mmio finding=access_forbidden op=write") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_read_write pass=mmio finding=access_forbidden") == null);

    try verifyBuiltMir(typed_mir, &reporter);
    var mmio_errors: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_MMIO_ACCESS_FORBIDDEN") != null) mmio_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), mmio_errors);
}

test "MIR models local callee values as indirect calls" {
    const source =
        \\#[no_lang_trap]
        \\fn reject_indirect_no_lang_trap(callee: u32) -> void {
        \\    callee();
        \\}
        \\
        \\#[irq_context]
        \\fn reject_indirect_irq(callee: u32) -> void {
        \\    callee();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_indirect_call.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const no_trap_fn = functionByName(typed_mir, "reject_indirect_no_lang_trap").?;
    const irq_fn = functionByName(typed_mir, "reject_indirect_irq").?;
    try std.testing.expect(functionHasInstruction(no_trap_fn, .indirect_call, "callee"));
    try std.testing.expect(functionHasInstruction(irq_fn, .indirect_call, "callee"));

    try verifyBuiltMir(typed_mir, &reporter);

    var found_no_lang_trap = false;
    var found_irq = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) found_irq = true;
    }
    try std.testing.expect(found_no_lang_trap);
    try std.testing.expect(found_irq);
}

test "MIR CFG loop control uses explicit jump successors" {
    const source =
        \\fn loop_control(flag: bool) -> void {
        \\    while flag {
        \\        continue;
        \\    }
        \\    while flag {
        \\        break;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_loop_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const function = typed_mir.functions[0];
    var jump_blocks: usize = 0;
    for (function.blocks) |block| {
        for (block.successors) |successor| try std.testing.expect(successor < function.blocks.len);
        switch (block.terminator) {
            .jump => |target| {
                jump_blocks += 1;
                var listed = false;
                for (block.successors) |successor| {
                    if (successor == target) listed = true;
                }
                try std.testing.expect(listed);
            },
            .trap_ => try std.testing.expectEqual(@as(usize, 0), block.successors.len),
            .return_, .unreachable_ => try std.testing.expectEqual(@as(usize, 0), block.successors.len),
            else => {},
        }
    }
    try std.testing.expect(jump_blocks >= 2);
}

test "MIR verifier rejects malformed CFG structure" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{99};
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var blocks = [_]Block{
        .{
            .id = 0,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .{ .jump = 99 },
        },
    };
    var functions = [_]Function{
        .{
            .name = "bad_cfg",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_cfg.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);
}

test "MIR verifier rejects block id mismatch in CFG" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{};
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var blocks = [_]Block{
        .{
            .id = 7,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .{ .return_ = .void },
        },
    };
    var functions = [_]Function{
        .{
            .name = "bad_block_id",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_block_id.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFactsFromMir(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=bad_block_id pass=cfg finding=malformed_cfg") != null);
}

test "MIR verifier rejects fallthrough successors and trap kind mismatch" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{1};
    var trap_successors = [_]usize{};
    var blocks = [_]Block{
        .{
            .id = 0,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .fallthrough,
        },
        .{
            .id = 1,
            .kind = "trap",
            .instructions = instructions[0..],
            .successors = trap_successors[0..],
            .terminator = .{ .trap_ = .Bounds },
        },
    };
    var trap_edges = [_]TrapEdge{
        .{ .from_block = 0, .trap_block = 1, .kind = .IntegerOverflow, .source = .checked_arithmetic, .line = 1, .column = 1 },
    };
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "bad_cfg",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_cfg_2.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);
}

test "MIR records no_overflow range facts for unchecked add contract" {
    const source =
        \\fn accumulate(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.add(sum, b);
        \\    }
        \\    return sum;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_range.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions[0].range_facts.len);
    const fact = typed_mir.functions[0].range_facts[0];
    try std.testing.expectEqualStrings("sum", fact.target);
    try std.testing.expectEqualStrings("add", fact.op);
    try std.testing.expectEqualStrings("sum", fact.left);
    try std.testing.expectEqualStrings("b", fact.right);
    try std.testing.expectEqualStrings("u32", fact.result_ty.name());

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accumulate pass=range finding=no_overflow_range target=sum op=add left=sum right=b") != null);
}

test "MIR range facts are top-level and no_overflow operations are known" {
    const source =
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn id(value: u32) -> u32 { return value; }
        \\
        \\fn nested(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = id(unchecked.add(a, b));
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn cast_call_arg(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = id(unchecked.add(a, b) as u32);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn grouped_return(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b));
        \\    }
        \\}
        \\
        \\fn cast_return(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(a, b) as u32;
        \\    }
        \\}
        \\
        \\fn cast_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let value: u32 = unchecked.add(a, b) as u32;
        \\        return value;
        \\    }
        \\}
        \\
        \\fn cast_inferred_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(a, b) as u32;
        \\        return inferred;
        \\    }
        \\}
        \\
        \\fn grouped_assign(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = (unchecked.mul(sum, b));
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn cast_assign(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.mul(sum, b) as u32;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn nested_binary(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn aggregate_array_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn cast_aggregate_array_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
        \\
        \\fn cast_aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn known_ops(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.sub(sum, b);
        \\        sum = unchecked.mul(sum, b);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn unknown_op(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.foo(a, b);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_range_top_level.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const nested_fn = functionByName(typed_mir, "nested").?;
    try std.testing.expectEqual(@as(usize, 1), nested_fn.range_facts.len);
    try std.testing.expectEqualStrings("call_arg", nested_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", nested_fn.range_facts[0].op);
    const cast_call_arg_fn = functionByName(typed_mir, "cast_call_arg").?;
    try std.testing.expectEqual(@as(usize, 1), cast_call_arg_fn.range_facts.len);
    try std.testing.expectEqualStrings("call_arg", cast_call_arg_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_call_arg_fn.range_facts[0].op);
    const grouped_return_fn = functionByName(typed_mir, "grouped_return").?;
    try std.testing.expectEqual(@as(usize, 1), grouped_return_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", grouped_return_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", grouped_return_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", grouped_return_fn.range_facts[0].result_ty.name());
    const cast_return_fn = functionByName(typed_mir, "cast_return").?;
    try std.testing.expectEqual(@as(usize, 1), cast_return_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", cast_return_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_return_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_return_fn.range_facts[0].result_ty.name());
    const cast_local_fn = functionByName(typed_mir, "cast_local").?;
    try std.testing.expectEqual(@as(usize, 1), cast_local_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", cast_local_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_local_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_local_fn.range_facts[0].result_ty.name());
    const cast_inferred_local_fn = functionByName(typed_mir, "cast_inferred_local").?;
    try std.testing.expectEqual(@as(usize, 1), cast_inferred_local_fn.range_facts.len);
    try std.testing.expectEqualStrings("inferred", cast_inferred_local_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_inferred_local_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_inferred_local_fn.range_facts[0].result_ty.name());
    const grouped_assign_fn = functionByName(typed_mir, "grouped_assign").?;
    try std.testing.expectEqual(@as(usize, 1), grouped_assign_fn.range_facts.len);
    try std.testing.expectEqualStrings("sum", grouped_assign_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", grouped_assign_fn.range_facts[0].op);
    const cast_assign_fn = functionByName(typed_mir, "cast_assign").?;
    try std.testing.expectEqual(@as(usize, 1), cast_assign_fn.range_facts.len);
    try std.testing.expectEqualStrings("sum", cast_assign_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", cast_assign_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_assign_fn.range_facts[0].result_ty.name());
    const nested_binary_fn = functionByName(typed_mir, "nested_binary").?;
    try std.testing.expectEqual(@as(usize, 1), nested_binary_fn.range_facts.len);
    try std.testing.expectEqualStrings("binary_operand", nested_binary_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", nested_binary_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", nested_binary_fn.range_facts[0].result_ty.name());
    const aggregate_array_fn = functionByName(typed_mir, "aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 1), aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", aggregate_array_fn.range_facts[0].result_ty.name());
    const cast_aggregate_array_fn = functionByName(typed_mir, "cast_aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 1), cast_aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", cast_aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_aggregate_array_fn.range_facts[0].result_ty.name());
    const aggregate_field_fn = functionByName(typed_mir, "aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 1), aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", aggregate_field_fn.range_facts[0].result_ty.name());
    const cast_aggregate_field_fn = functionByName(typed_mir, "cast_aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 1), cast_aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", cast_aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", cast_aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", cast_aggregate_field_fn.range_facts[0].result_ty.name());
    const known_ops_fn = functionByName(typed_mir, "known_ops").?;
    try std.testing.expectEqual(@as(usize, 2), known_ops_fn.range_facts.len);
    try std.testing.expectEqualStrings("sub", known_ops_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("mul", known_ops_fn.range_facts[1].op);

    try verifyBuiltMir(typed_mir, &reporter);
    var found_unknown = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNCHECKED_OUTSIDE_CONTRACT") != null) found_unknown = true;
    }
    try std.testing.expect(found_unknown);
}

test "MIR verifier reports address-class deref and operations" {
    const source =
        \\extern fn make_paddr() -> PAddr;
        \\
        \\fn reject_paddr_deref(pa: PAddr) -> u8 {
        \\    return pa.*;
        \\}
        \\
        \\fn reject_vaddr_deref(va: VAddr) -> u8 {
        \\    return va.*;
        \\}
        \\
        \\fn reject_user_ptr_deref(buf: UserPtr<u8>) -> u8 {
        \\    return buf.*;
        \\}
        \\
        \\fn reject_mmio_ptr_deref(uart: MmioPtr<Uart>) -> Uart {
        \\    return uart.*;
        \\}
        \\
        \\fn reject_dma_addr_deref(addr: DmaAddr) -> u8 {
        \\    return addr.*;
        \\}
        \\
        \\fn reject_phys_ptr_deref(ptr: PhysPtr<Page>) -> Page {
        \\    return ptr.*;
        \\}
        \\
        \\fn reject_call_deref() -> u8 {
        \\    return make_paddr().*;
        \\}
        \\
        \\fn reject_paddr_arithmetic(addr: PAddr, offset: usize) -> PAddr {
        \\    return addr + offset;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_address.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    const expected = [_][]const u8{
        "E_PADDR_DEREF",
        "E_VADDR_DEREF",
        "E_USER_PTR_DEREF",
        "E_MMIO_PTR_DEREF",
        "E_DMA_ADDR_DEREF",
        "E_PHYS_PTR_DEREF",
        "E_ADDRESS_CLASS_OPERATION",
    };
    for (expected) |code| {
        var found = false;
        for (reporter.diagnostics.items) |diag| {
            if (std.mem.indexOf(u8, diag.message, code) != null) found = true;
        }
        try std.testing.expect(found);
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_deref pass=address finding=direct_deref class=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_deref pass=address finding=direct_deref class=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_arithmetic pass=address finding=opaque_operation detail=add") != null);
}

test "MIR verifier reports address-class conversion mismatches" {
    const source =
        \\extern fn takes_paddr(addr: PAddr) -> void;
        \\
        \\fn reject_dma_addr_return(addr: DmaAddr) -> PAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_dma_addr_as_vaddr(addr: DmaAddr) -> VAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_paddr_as_vaddr(addr: PAddr) -> VAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_dma_addr_local(addr: DmaAddr) -> void {
        \\    let pa: PAddr = addr;
        \\}
        \\
        \\fn reject_dma_addr_assignment(addr: DmaAddr, fallback: PAddr) -> void {
        \\    var pa: PAddr = fallback;
        \\    pa = addr;
        \\}
        \\
        \\fn reject_dma_addr_call_arg(addr: DmaAddr) -> void {
        \\    takes_paddr(addr);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_address_conversion.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    const expected = [_][]const u8{
        "E_DMA_ADDR_NOT_PADDR",
        "E_DMA_ADDR_NOT_VADDR",
        "E_ADDRESS_CLASS_MISMATCH",
    };
    for (expected) |code| {
        var found = false;
        for (reporter.diagnostics.items) |diag| {
            if (std.mem.indexOf(u8, diag.message, code) != null) found = true;
        }
        try std.testing.expect(found);
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_return pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_as_vaddr pass=address finding=address_class_mismatch source=DmaAddr target=VAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_as_vaddr pass=address finding=address_class_mismatch source=PAddr target=VAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_local pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_assignment pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_call_arg pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
}

test "MIR emits representation checks for nonnull pointer and closed enum call results" {
    const source =
        \\enum Irq: u8 {
        \\    timer,
        \\}
        \\
        \\open enum DeviceState: u8 {
        \\    ready,
        \\}
        \\
        \\struct Packet {
        \\    ptr: *mut u8,
        \\    irq: Irq,
        \\    state: DeviceState,
        \\}
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn make_irq() -> Irq;
        \\extern fn make_state() -> DeviceState;
        \\extern fn make_ptrs() -> [2]*mut u8;
        \\extern fn make_irqs() -> [2]Irq;
        \\extern fn make_packet() -> Packet;
        \\
        \\fn use_ptr() -> *mut u8 {
        \\    return make_ptr();
        \\}
        \\
        \\fn use_irq() -> Irq {
        \\    return make_irq();
        \\}
        \\
        \\fn use_open_enum() -> DeviceState {
        \\    return make_state();
        \\}
        \\
        \\fn use_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn use_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
        \\
        \\fn use_packet_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn use_packet_irq(packet: Packet) -> Irq {
        \\    return packet.irq;
        \\}
        \\
        \\fn use_packet_open_enum(packet: Packet) -> DeviceState {
        \\    return packet.state;
        \\}
        \\
        \\fn use_copied_packet_ptr(packet: Packet) -> *mut u8 {
        \\    let copy = packet;
        \\    return copy.ptr;
        \\}
        \\
        \\fn use_copied_packet_irq(packet: Packet) -> Irq {
        \\    let copy = packet;
        \\    return copy.irq;
        \\}
        \\
        \\fn use_copied_call_packet_ptr() -> *mut u8 {
        \\    let copy = make_packet();
        \\    return copy.ptr;
        \\}
        \\
        \\fn use_copied_call_packet_irq() -> Irq {
        \\    let copy = make_packet();
        \\    return copy.irq;
        \\}
        \\
        \\fn use_packet_ptr_deref(packet: Packet) -> u8 {
        \\    return packet.ptr.*;
        \\}
        \\
        \\fn compare_packet_ptrs(left: Packet, right: Packet) -> bool {
        \\    return left.ptr == right.ptr;
        \\}
        \\
        \\fn compare_irq_values(left: Packet, right: Packet) -> bool {
        \\    return left.irq == right.irq;
        \\}
        \\
        \\fn compare_irq_literal(irq: Irq) -> bool {
        \\    return .timer == irq;
        \\}
        \\
        \\fn use_array_ptr(values: [2]*mut u8) -> *mut u8 {
        \\    return values[0];
        \\}
        \\
        \\fn use_array_irq(values: [2]Irq) -> Irq {
        \\    return values[0];
        \\}
        \\
        \\fn use_copied_array_ptr(values: [2]*mut u8) -> *mut u8 {
        \\    let copy = values;
        \\    return copy[0];
        \\}
        \\
        \\fn use_copied_array_irq(values: [2]Irq) -> Irq {
        \\    let copy = values;
        \\    return copy[0];
        \\}
        \\
        \\fn use_call_array_ptr() -> *mut u8 {
        \\    return make_ptrs()[0];
        \\}
        \\
        \\fn use_call_array_irq() -> Irq {
        \\    return make_irqs()[0];
        \\}
        \\
        \\fn use_copied_call_array_ptr() -> *mut u8 {
        \\    let copy = make_ptrs();
        \\    return copy[0];
        \\}
        \\
        \\fn use_copied_call_array_irq() -> Irq {
        \\    let copy = make_irqs();
        \\    return copy[0];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const use_ptr_fn = functionByName(typed_mir, "use_ptr").?;
    const use_irq_fn = functionByName(typed_mir, "use_irq").?;
    const use_open_enum_fn = functionByName(typed_mir, "use_open_enum").?;
    const use_ptr_param_fn = functionByName(typed_mir, "use_ptr_param").?;
    const use_irq_param_fn = functionByName(typed_mir, "use_irq_param").?;
    const use_packet_ptr_fn = functionByName(typed_mir, "use_packet_ptr").?;
    const use_packet_irq_fn = functionByName(typed_mir, "use_packet_irq").?;
    const use_packet_open_enum_fn = functionByName(typed_mir, "use_packet_open_enum").?;
    const use_copied_packet_ptr_fn = functionByName(typed_mir, "use_copied_packet_ptr").?;
    const use_copied_packet_irq_fn = functionByName(typed_mir, "use_copied_packet_irq").?;
    const use_copied_call_packet_ptr_fn = functionByName(typed_mir, "use_copied_call_packet_ptr").?;
    const use_copied_call_packet_irq_fn = functionByName(typed_mir, "use_copied_call_packet_irq").?;
    const use_packet_ptr_deref_fn = functionByName(typed_mir, "use_packet_ptr_deref").?;
    const compare_packet_ptrs_fn = functionByName(typed_mir, "compare_packet_ptrs").?;
    const compare_irq_values_fn = functionByName(typed_mir, "compare_irq_values").?;
    const compare_irq_literal_fn = functionByName(typed_mir, "compare_irq_literal").?;
    const use_array_ptr_fn = functionByName(typed_mir, "use_array_ptr").?;
    const use_array_irq_fn = functionByName(typed_mir, "use_array_irq").?;
    const use_copied_array_ptr_fn = functionByName(typed_mir, "use_copied_array_ptr").?;
    const use_copied_array_irq_fn = functionByName(typed_mir, "use_copied_array_irq").?;
    const use_call_array_ptr_fn = functionByName(typed_mir, "use_call_array_ptr").?;
    const use_call_array_irq_fn = functionByName(typed_mir, "use_call_array_irq").?;
    const use_copied_call_array_ptr_fn = functionByName(typed_mir, "use_copied_call_array_ptr").?;
    const use_copied_call_array_irq_fn = functionByName(typed_mir, "use_copied_call_array_irq").?;
    try std.testing.expect(functionHasInstruction(use_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(!functionHasInstruction(use_open_enum_fn, .representation_check, "DeviceState"));
    try std.testing.expect(functionHasInstruction(use_ptr_param_fn, .typed_load, "p"));
    try std.testing.expect(functionHasInstruction(use_ptr_param_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_irq_param_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_irq_param_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(!functionHasInstruction(use_packet_open_enum_fn, .representation_check, "DeviceState"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_deref_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_deref_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(compare_packet_ptrs_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(compare_irq_values_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(compare_irq_literal_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(use_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_call_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_call_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_call_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_call_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_irq_fn, .representation_check, "Irq"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_ptr pass=representation finding=representation_check type=nonnull_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_irq pass=representation finding=representation_check type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_ptr_param pass=representation finding=typed_load detail=p type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_irq_param pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_ptr_deref pass=representation finding=representation_use detail=deref_base type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_packet_ptrs pass=representation finding=representation_use detail=binary_operand type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_values pass=representation finding=representation_use detail=binary_operand type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_literal pass=representation finding=representation_use detail=binary_operand type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_literal pass=representation finding=representation_use detail=binary_operand type=value") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_call_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_call_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);

    try verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR representation checks emit invalid-representation trap edges" {
    const source =
        \\enum Irq: u8 {
        \\    timer,
        \\}
        \\
        \\open enum DeviceState: u8 {
        \\    ready,
        \\}
        \\
        \\fn checked_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn checked_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
        \\
        \\fn checked_open_enum(state: DeviceState) -> DeviceState {
        \\    return state;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_traps.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const checked_ptr_fn = functionByName(typed_mir, "checked_ptr_param").?;
    const checked_irq_fn = functionByName(typed_mir, "checked_irq_param").?;
    const checked_open_fn = functionByName(typed_mir, "checked_open_enum").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_ptr_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_irq_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(checked_open_fn, .InvalidRepresentation));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_ptr_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_irq_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_open_enum pass=trap finding=trap_edge detail=InvalidRepresentation") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_no_lang_ptr_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_no_lang_irq_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check no_lang_trap=true") != null);

    try verifyBuiltMir(typed_mir, &reporter);
    var no_lang_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) no_lang_count += 1;
    }
    try std.testing.expect(no_lang_count >= 2);
}

test "MIR verifier rejects missing representation check" {
    var instructions = [_]Instruction{
        .{ .kind = .call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "make_ptr", .line = 1, .column = 1 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_rep_check.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects missing representation check on indirect call" {
    var instructions = [_]Instruction{
        .{ .kind = .indirect_call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "callee", .line = 1, .column = 1 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_indirect_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_indirect_rep_check.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects missing representation check on typed load" {
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = .{ .closed_enum = "Irq" }, .detail = "irq", .line = 1, .column = 1 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_load_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_load_rep_check.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier requires representation checks to dominate sensitive returns" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "dominated_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "dominated_return.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects representation return when one predecessor lacks check" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{};
    var join_instructions = [_]Instruction{
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "undominated_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "undominated_return.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier matches representation identity across predecessor paths" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .value_id = "p", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "identity_dominated_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "identity_dominated_use.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects predecessor representation check for wrong identity" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "q", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .value_id = "p", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "wrong_identity_predecessor_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "wrong_identity_predecessor_use.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier requires representation checks to dominate non-return typed uses" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = ptr_ty, .detail = "p", .line = 1, .column = 5 },
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 1, .column = 5 },
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "assignment", .line = 1, .column = 9 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "checked_non_return_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "checked_non_return_use.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects missing representation check on non-return typed use" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .line = 1, .column = 9 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_non_return_use_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_non_return_use_check.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects representation check for the wrong value identity" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = ptr_ty, .detail = "checked_ptr", .value_id = "checked_ptr", .line = 1, .column = 5 },
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "checked_ptr", .line = 1, .column = 9 },
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .value_id = "unchecked_ptr", .line = 2, .column = 5 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "wrong_identity_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "wrong_identity_return.mc", "");
    defer reporter.deinit();
    try verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR target representation checks see through casts" {
    const source =
        \\struct PtrPacket {
        \\    ptr: *mut u8,
        \\}
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn take_ptr(value: *mut u8) -> void;
        \\
        \\fn cast_pointer_return() -> *mut u8 {
        \\    return make_ptr() as *mut u8;
        \\}
        \\
        \\fn cast_pointer_local() -> *mut u8 {
        \\    let p: *mut u8 = make_ptr() as *mut u8;
        \\    return p;
        \\}
        \\
        \\fn cast_pointer_assignment() -> *mut u8 {
        \\    var p: *mut u8 = make_ptr();
        \\    p = make_ptr() as *mut u8;
        \\    return p;
        \\}
        \\
        \\fn cast_pointer_call_arg() -> void {
        \\    take_ptr(make_ptr() as *mut u8);
        \\}
        \\
        \\fn cast_pointer_aggregate_field() -> PtrPacket {
        \\    return .{ .ptr = make_ptr() as *mut u8 };
        \\}
        \\
        \\fn cast_pointer_aggregate_element() -> [1]*mut u8 {
        \\    return .{ make_ptr() as *mut u8 };
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_cast_representation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_return pass=representation finding=representation_check type=nonnull_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_local pass=representation finding=representation_use detail=initializer type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_assignment pass=representation finding=representation_use detail=assignment type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_call_arg pass=representation finding=representation_use detail=call_arg type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_element pass=representation finding=representation_use detail=aggregate_element type=*mut") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier reports nullability conversion violations" {
    const source =
        \\extern fn make_nullable() -> ?*mut u8;
        \\
        \\fn reject_null_local() -> *mut u8 {
        \\    let p: *mut u8 = null;
        \\    return p;
        \\}
        \\
        \\fn reject_null_assignment(fallback: *mut u8) -> *mut u8 {
        \\    var p: *mut u8 = fallback;
        \\    p = null;
        \\    return p;
        \\}
        \\
        \\fn reject_nullable_return(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe;
        \\}
        \\
        \\fn reject_nullable_call_return() -> *mut u8 {
        \\    return make_nullable();
        \\}
        \\
        \\fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
        \\    return p;
        \\}
        \\
        \\fn accept_null_nullable() -> ?*mut u8 {
        \\    return null;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_nullability.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_local pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_assignment pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_call_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nonnull_to_nullable pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_null_nullable pass=nullability") == null);

    try verify(std.testing.allocator, module, &reporter);
    var found_null_to_nonnull = false;
    var found_nullable_to_nonnull = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) found_nullable_to_nonnull = true;
    }
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_nullable_to_nonnull);
}

test "MIR verifier reports general return local and assignment conversions" {
    const source =
        \\extern fn make_u32() -> u32;
        \\extern fn make_mut_u8_pointer() -> *mut u8;
        \\extern fn make_c_void_pointer() -> *mut c_void;
        \\extern fn takes_u32(value: u32) -> void;
        \\extern fn takes_mut_pointer(value: *mut u8) -> void;
        \\extern fn takes_c_void_pointer(value: *mut c_void) -> void;
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\}
        \\
        \\fn accept_matching_return() -> u32 {
        \\    return make_u32();
        \\}
        \\
        \\fn reject_return_type() -> i32 {
        \\    return make_u32();
        \\}
        \\
        \\fn reject_local_initializer() -> void {
        \\    let value: i32 = make_u32();
        \\}
        \\
        \\fn reject_assignment() -> void {
        \\    var value: i32 = 0;
        \\    value = make_u32();
        \\}
        \\
        \\fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
        \\    return p;
        \\}
        \\
        \\fn reject_return_pointer_conversion(p: *mut u8) -> *const u8 {
        \\    return p;
        \\}
        \\
        \\fn reject_return_pointer_element_conversion(p: *mut u8) -> *mut u16 {
        \\    return p;
        \\}
        \\
        \\fn reject_return_c_void_conversion(p: *mut c_void) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn reject_initializer_pointer_conversion(p: *mut u8) -> void {
        \\    let q: *const u8 = p;
        \\}
        \\
        \\fn reject_initializer_pointer_element_conversion(p: *mut u8) -> void {
        \\    let q: *mut u16 = p;
        \\}
        \\
        \\fn reject_initializer_c_void_conversion(p: *mut u8) -> void {
        \\    let q: *mut c_void = p;
        \\}
        \\
        \\fn reject_nullable_initializer_pointer_conversion(p: *mut u8) -> void {
        \\    let q: ?*const u8 = p;
        \\}
        \\
        \\fn reject_call_argument_type(flag: bool) -> void {
        \\    takes_u32(flag);
        \\}
        \\
        \\fn reject_call_argument_pointer(p: *const u8) -> void {
        \\    takes_mut_pointer(p);
        \\}
        \\
        \\fn reject_call_argument_c_void(p: *mut u8) -> void {
        \\    takes_c_void_pointer(p);
        \\}
        \\
        \\fn reject_assert_condition_type(value: u32) -> void {
        \\    assert(value);
        \\}
        \\
        \\fn reject_while_condition_type(value: u32) -> void {
        \\    while value {
        \\        break;
        \\    }
        \\}
        \\
        \\fn reject_for_base_type(value: u32) -> void {
        \\    for x in value {
        \\    }
        \\}
        \\
        \\fn reject_index_base_type(value: u32, index: usize) -> u8 {
        \\    return value[index];
        \\}
        \\
        \\fn reject_index_operand_type(values: []const u8, flag: bool) -> u8 {
        \\    return values[flag];
        \\}
        \\
        \\fn reject_direct_call_return_pointer_element() -> *mut u16 {
        \\    return make_mut_u8_pointer();
        \\}
        \\
        \\fn reject_direct_call_return_c_void() -> *mut u8 {
        \\    return make_c_void_pointer();
        \\}
        \\
        \\fn reject_member_assignment_pointer_conversion(p: *const u8) -> void {
        \\    var packet: Packet = uninit;
        \\    packet.ptr = p;
        \\}
        \\
        \\fn reject_deref_assignment_type(p: *mut u32, flag: bool) -> void {
        \\    p.* = flag;
        \\}
        \\
        \\fn reject_index_assignment_pointer(xs: []mut *mut u8, p: *const u8) -> void {
        \\    xs[0] = p;
        \\}
        \\
        \\fn reject_cast_return_type() -> u32 {
        \\    return make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_local_initializer() -> void {
        \\    let value: u32 = make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_assignment() -> void {
        \\    var value: u32 = 0;
        \\    value = make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_call_argument() -> void {
        \\    takes_u32(make_u32() as i32);
        \\}
        \\
        \\fn reject_cast_nullable_to_nonnull(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe as ?*mut u8;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_conversions.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_matching_return pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nonnull_to_nullable pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_type pass=conversion finding=return_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_initializer pass=conversion finding=initializer_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment pass=conversion finding=assignment_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_pointer_conversion pass=conversion finding=return_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_pointer_element_conversion pass=conversion finding=return_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_c_void_conversion pass=conversion finding=return_c_void_conversion source_type=*mut c_void") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_initializer_pointer_conversion pass=conversion finding=initializer_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_initializer_pointer_element_conversion pass=conversion finding=initializer_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_initializer_c_void_conversion pass=conversion finding=initializer_c_void_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_initializer_pointer_conversion pass=conversion finding=initializer_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_type pass=conversion finding=call_arg_type_mismatch source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_pointer pass=conversion finding=call_arg_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_c_void pass=conversion finding=call_arg_c_void_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assert_condition_type pass=conversion finding=condition_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_while_condition_type pass=conversion finding=condition_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_for_base_type pass=conversion finding=for_base_not_iterable source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_base_type pass=conversion finding=index_base_not_array_or_slice source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_operand_type pass=conversion finding=index_not_usize source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_direct_call_return_pointer_element pass=conversion finding=return_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_direct_call_return_c_void pass=conversion finding=return_c_void_conversion source_type=*mut c_void") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_member_assignment_pointer_conversion pass=conversion finding=assignment_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_deref_assignment_type pass=conversion finding=assignment_type_mismatch source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_assignment_pointer pass=conversion finding=assignment_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_return_type pass=conversion finding=return_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_local_initializer pass=conversion finding=initializer_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_assignment pass=conversion finding=assignment_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_call_argument pass=conversion finding=call_arg_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_nullable_to_nonnull pass=nullability finding=nullable_to_nonnull") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);

    var found_return_mismatch = false;
    var found_no_implicit = false;
    var found_pointer_conversion = false;
    var found_c_void_conversion = false;
    var found_condition = false;
    var found_for_base = false;
    var found_index_base = false;
    var found_index_operand = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) found_return_mismatch = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) found_no_implicit = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) found_pointer_conversion = true;
        if (std.mem.indexOf(u8, diag.message, "E_C_VOID_CONVERSION") != null) found_c_void_conversion = true;
        if (std.mem.indexOf(u8, diag.message, "E_CONDITION_NOT_BOOL") != null) found_condition = true;
        if (std.mem.indexOf(u8, diag.message, "E_FOR_BASE_NOT_ARRAY_OR_SLICE") != null) found_for_base = true;
        if (std.mem.indexOf(u8, diag.message, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE") != null) found_index_base = true;
        if (std.mem.indexOf(u8, diag.message, "E_INDEX_NOT_USIZE") != null) found_index_operand = true;
    }
    try std.testing.expect(found_return_mismatch);
    try std.testing.expect(found_no_implicit);
    try std.testing.expect(found_pointer_conversion);
    try std.testing.expect(found_c_void_conversion);
    try std.testing.expect(found_condition);
    try std.testing.expect(found_for_base);
    try std.testing.expect(found_index_base);
    try std.testing.expect(found_index_operand);
}

test "MIR verifier reports invalid assignment targets for immutable locals and const views" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\}
        \\
        \\extern fn local_array() -> [4]u32;
        \\
        \\fn accept_assign_to_var() -> u32 {
        \\    var x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_let() -> u32 {
        \\    let x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_param(x: u32) -> u32 {
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_param_field(packet: Packet) -> u32 {
        \\    packet.value = 2;
        \\    return packet.value;
        \\}
        \\
        \\fn reject_assign_to_let_array_element(i: usize, value: u32) -> u32 {
        \\    let xs = local_array();
        \\    xs[i] = value;
        \\    return xs[i];
        \\}
        \\
        \\fn reject_assign_through_const_pointer(p: *const u32, value: u32) -> void {
        \\    p.* = value;
        \\}
        \\
        \\fn reject_assign_through_const_slice(xs: []const u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn reject_assign_field_through_const_pointer(packet: *const Packet, value: u32) -> void {
        \\    packet.*.value = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_pointer(p: *mut u32, value: u32) -> void {
        \\    (p as *const u32).* = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_raw_many(p: [*]mut u32, value: u32) -> void {
        \\    (p as [*]const u32).* = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    (xs as []const u32)[i] = value;
        \\}
        \\
        \\fn reject_assign_field_through_cast_const_pointer(packet: *mut Packet, value: u32) -> void {
        \\    (packet as *const Packet).*.value = value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_assignment_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_assign_to_var pass=core finding=assign_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_let pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_param pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_param_field pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_let_array_element pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_const_slice pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_field_through_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_raw_many pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_slice pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_field_through_cast_const_pointer pass=core finding=assign_through_const_view") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var found_immutable = false;
    var found_const_view = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_ASSIGN_TO_IMMUTABLE_LOCAL") != null) found_immutable = true;
        if (std.mem.indexOf(u8, diag.message, "E_ASSIGN_THROUGH_CONST_VIEW") != null) found_const_view = true;
    }
    try std.testing.expect(found_immutable);
    try std.testing.expect(found_const_view);
}

test "MIR verifier reports integer literal range conversions" {
    const source =
        \\extern fn takes_u8(value: u8) -> void;
        \\
        \\fn accept_literals() -> u8 {
        \\    let a: u8 = 255;
        \\    let b: i8 = -128;
        \\    takes_u8(0xff);
        \\    return 255;
        \\}
        \\
        \\fn reject_return_literal() -> u8 {
        \\    return 256;
        \\}
        \\
        \\fn reject_local_literal() -> u8 {
        \\    let y: u8 = 0x100;
        \\    return 0;
        \\}
        \\
        \\fn reject_negative_unsigned() -> u8 {
        \\    let y: u8 = -1;
        \\    return 0;
        \\}
        \\
        \\fn reject_i8_high() -> i8 {
        \\    let y: i8 = 128;
        \\    return 0;
        \\}
        \\
        \\fn reject_i8_low() -> i8 {
        \\    let y: i8 = -129;
        \\    return 0;
        \\}
        \\
        \\fn reject_assignment_literal() -> void {
        \\    var y: u8 = 0;
        \\    y = 300;
        \\}
        \\
        \\fn reject_call_arg_literal() -> void {
        \\    takes_u8(999);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_integer_literals.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_negative_unsigned pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_high pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_low pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_arg_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
    }
    try std.testing.expect(found_literal_range);
}

test "MIR verifier recurses into target typed aggregate literal conversions" {
    const source =
        \\struct Packet {
        \\    tag: u8,
        \\    ptr: *mut u8,
        \\    bytes: [2]u8,
        \\}
        \\
        \\struct PtrPacket {
        \\    ptr: *mut u8,
        \\}
        \\
        \\packed bits Flags: u8 {
        \\    ready: bool,
        \\    busy: bool,
        \\}
        \\
        \\type Byte = u8;
        \\type Bytes = [2]Byte;
        \\type PacketAlias = Packet;
        \\type BytePtr = *mut Byte;
        \\type FlagsAlias = Flags;
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn make_alias_ptr() -> BytePtr;
        \\extern fn take_bytes(value: [2]u8) -> void;
        \\extern fn take_alias_bytes(value: Bytes) -> void;
        \\extern fn take_flags(value: FlagsAlias) -> void;
        \\
        \\fn accept_aggregate_literals() -> Packet {
        \\    let xs: [2]u8 = .{1, 2};
        \\    return .{ .tag = 255, .ptr = make_ptr(), .bytes = xs };
        \\}
        \\
        \\fn accept_pointer_aggregate_field(cell: u8) -> PtrPacket {
        \\    return .{ .ptr = &cell };
        \\}
        \\
        \\fn accept_pointer_aggregate_element(cell: u8) -> [2]*mut u8 {
        \\    return .{ &cell, &cell };
        \\}
        \\
        \\fn accept_member_aggregate_field(packet: Packet) -> PtrPacket {
        \\    return .{ .ptr = packet.ptr };
        \\}
        \\
        \\fn accept_index_aggregate_field(values: [2]*mut u8) -> PtrPacket {
        \\    return .{ .ptr = values[0] };
        \\}
        \\
        \\fn reject_struct_fields() -> Packet {
        \\    return .{ .tag = 300, .ptr = null, .bytes = .{1, 999} };
        \\}
        \\
        \\fn reject_local_array_element() -> void {
        \\    let xs: [2]u8 = .{1, 300};
        \\}
        \\
        \\fn reject_assignment_array_element() -> void {
        \\    var xs: [2]u8 = uninit;
        \\    xs = .{1, 400};
        \\}
        \\
        \\fn reject_call_array_element() -> void {
        \\    take_bytes(.{1, 500});
        \\}
        \\
        \\fn reject_short_array() -> [2]u8 {
        \\    return .{1};
        \\}
        \\
        \\fn reject_long_array() -> [2]u8 {
        \\    return .{1, 2, 3};
        \\}
        \\
        \\fn reject_missing_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr() };
        \\}
        \\
        \\fn reject_duplicate_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr(), .tag = 2, .bytes = .{1, 2} };
        \\}
        \\
        \\fn reject_unknown_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr(), .extra = 2, .bytes = .{1, 2} };
        \\}
        \\
        \\fn accept_alias_aggregate_literals() -> PacketAlias {
        \\    let xs: Bytes = .{1, 2};
        \\    return .{ .tag = 3, .ptr = make_alias_ptr(), .bytes = xs };
        \\}
        \\
        \\fn reject_alias_array_element() -> Bytes {
        \\    return .{1, 600};
        \\}
        \\
        \\fn reject_alias_struct_fields() -> PacketAlias {
        \\    return .{ .tag = 700, .ptr = null, .bytes = .{1, 2} };
        \\}
        \\
        \\fn reject_alias_call_array_element() -> void {
        \\    take_alias_bytes(.{1, 800});
        \\}
        \\
        \\fn reject_cast_array_element() -> Bytes {
        \\    return (.{1, 900} as Bytes);
        \\}
        \\
        \\fn reject_cast_short_array() -> Bytes {
        \\    return (.{1} as Bytes);
        \\}
        \\
        \\fn reject_cast_struct_fields() -> PacketAlias {
        \\    return (.{ .tag = 901, .ptr = null, .bytes = .{1, 2} } as PacketAlias);
        \\}
        \\
        \\fn reject_cast_missing_struct_field() -> PacketAlias {
        \\    return (.{ .tag = 1, .ptr = make_ptr() } as PacketAlias);
        \\}
        \\
        \\fn accept_packed_bits_literals() -> FlagsAlias {
        \\    let flags: FlagsAlias = .{ .ready = true, .busy = false };
        \\    take_flags(.{ .ready = flags.ready, .busy = true });
        \\    return flags;
        \\}
        \\
        \\fn reject_packed_bits_field_type() -> FlagsAlias {
        \\    return .{ .ready = 1, .busy = false };
        \\}
        \\
        \\fn reject_packed_bits_missing_field() -> FlagsAlias {
        \\    return .{ .ready = true };
        \\}
        \\
        \\fn reject_packed_bits_duplicate_field() -> FlagsAlias {
        \\    return .{ .ready = true, .ready = false, .busy = false };
        \\}
        \\
        \\fn reject_packed_bits_unknown_field() -> FlagsAlias {
        \\    return .{ .ready = true, .missing = false, .busy = false };
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_aggregate_literals.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_aggregate_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_aggregate_literals pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_pointer_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_pointer_aggregate_element pass=representation finding=representation_use detail=aggregate_element type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_member_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_index_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_short_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_long_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_missing_struct_field pass=aggregate finding=struct_literal_missing_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_duplicate_struct_field pass=aggregate finding=struct_literal_duplicate_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unknown_struct_field pass=aggregate finding=struct_literal_unknown_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_alias_aggregate_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_alias_aggregate_literals pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_call_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_short_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_missing_struct_field pass=aggregate finding=struct_literal_missing_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_packed_bits_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_packed_bits_literals pass=aggregate") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_field_type pass=conversion finding=return_type_mismatch source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_missing_field pass=aggregate finding=struct_literal_missing_field type=Flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_duplicate_field pass=aggregate finding=struct_literal_duplicate_field type=Flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_unknown_field pass=aggregate finding=struct_literal_unknown_field type=Flags") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    var found_null_to_nonnull = false;
    var found_array_length = false;
    var found_missing_field = false;
    var found_duplicate_field = false;
    var found_unknown_field = false;
    var found_return_mismatch = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARRAY_LITERAL_LENGTH") != null) found_array_length = true;
        if (std.mem.indexOf(u8, diag.message, "E_STRUCT_LITERAL_MISSING_FIELD") != null) found_missing_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_STRUCT_LITERAL_FIELD") != null) found_duplicate_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_STRUCT_FIELD") != null) found_unknown_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) found_return_mismatch = true;
    }
    try std.testing.expect(found_literal_range);
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_array_length);
    try std.testing.expect(found_missing_field);
    try std.testing.expect(found_duplicate_field);
    try std.testing.expect(found_unknown_field);
    try std.testing.expect(found_return_mismatch);
}

test "MIR verifier validates typed global aggregate initializers" {
    const source =
        \\struct GlobalPacket {
        \\    tag: u8,
        \\    ptr: *mut u8,
        \\    bytes: [2]u8,
        \\}
        \\
        \\packed bits GlobalFlags: u8 {
        \\    ready: bool,
        \\    busy: bool,
        \\}
        \\
        \\type GlobalBytes = [2]u8;
        \\type GlobalPacketAlias = GlobalPacket;
        \\type GlobalFlagsAlias = GlobalFlags;
        \\
        \\global ok_bytes: GlobalBytes = .{1, 2};
        \\global ok_raw_flags: GlobalFlagsAlias = 0xff;
        \\global reject_global_array_element: GlobalBytes = .{1, 300};
        \\global reject_global_array_shape: GlobalBytes = .{1};
        \\global reject_global_struct_fields: GlobalPacketAlias = .{ .tag = 400, .ptr = null, .bytes = .{1, 999} };
        \\global reject_global_struct_missing: GlobalPacketAlias = .{ .tag = 1, .ptr = null };
        \\global reject_global_flags_type: GlobalFlagsAlias = .{ .ready = 1, .busy = false };
        \\global reject_global_flags_missing: GlobalFlagsAlias = .{ .ready = true };
        \\global reject_raw_flags_range: GlobalFlagsAlias = 0x100;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_global_aggregates.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_bytes pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_bytes pass=aggregate") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_raw_flags pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_array_shape pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_missing pass=aggregate finding=struct_literal_missing_field type=GlobalPacket") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_flags_type pass=conversion finding=initializer_type_mismatch source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_flags_missing pass=aggregate finding=struct_literal_missing_field type=GlobalFlags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_flags_range pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    var found_array_length = false;
    var found_null_to_nonnull = false;
    var found_missing_field = false;
    var found_no_implicit = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARRAY_LITERAL_LENGTH") != null) found_array_length = true;
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_STRUCT_LITERAL_MISSING_FIELD") != null) found_missing_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) found_no_implicit = true;
    }
    try std.testing.expect(found_literal_range);
    try std.testing.expect(found_array_length);
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_missing_field);
    try std.testing.expect(found_no_implicit);
}

test "MIR verifier reports unhandled Result expressions and locals" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\fn reject_unhandled_result_statement() -> void {
        \\    make_result_u32();
        \\}
        \\
        \\fn reject_unhandled_result_local() -> void {
        \\    let result = make_result_u32();
        \\}
        \\
        \\fn reject_defer_unhandled_result() -> void {
        \\    defer make_result_u32();
        \\}
        \\
        \\fn reject_switch_arm_unhandled_result(flag: bool) -> void {
        \\    switch flag {
        \\        true => make_result_u32(),
        \\        false => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_unhandled.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_statement pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_local pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_defer_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_arm_unhandled_result pass=result finding=unhandled_result") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var unhandled_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNHANDLED_RESULT") != null) unhandled_count += 1;
    }
    try std.testing.expect(unhandled_count >= 4);
}

test "MIR verifier accepts Result locals handled by try if-let-else and switch" {
    const source =
        \\struct ResultBox {
        \\    value: u32,
        \\}
        \\
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\fn accept_handled_result_local() -> u32 {
        \\    let result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn accept_if_let_else_result() -> void {
        \\    let result = make_result_u32();
        \\    if let ok(value) = result {
        \\        let copy: u32 = value;
        \\    } else {
        \\        let fallback: u32 = 0;
        \\    }
        \\}
        \\
        \\fn accept_result_switch_handles_both_tags() -> void {
        \\    let result = make_result_u32();
        \\    switch result {
        \\        ok(value) => {
        \\            let copy: u32 = value;
        \\        },
        \\        err(e) => {
        \\            let fallback: u32 = 0;
        \\        },
        \\    }
        \\}
        \\
        \\fn accept_array_literal_result_local() -> void {
        \\    let result = make_result_u32();
        \\    let values: [1]u32 = .{ result? };
        \\}
        \\
        \\fn accept_struct_literal_result_local() -> void {
        \\    let result = make_result_u32();
        \\    let boxed: ResultBox = .{ .value = result? };
        \\}
        \\
        \\fn accept_switch_arm_body_result_local(flag: bool) -> u32 {
        \\    let result = make_result_u32();
        \\    switch flag {
        \\        true => {
        \\            return result?;
        \\        },
        \\        false => {
        \\            return 0;
        \\        },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_handled.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_handled_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_array_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_struct_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_switch_arm_body_result_local pass=result finding=try_handled") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier reports invalid if-let and switch Result patterns" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\enum Status {
        \\    ready,
        \\    waiting,
        \\}
        \\
        \\fn reject_if_let_optional_required(value: u32) -> void {
        \\    if let x = value {
        \\    }
        \\}
        \\
        \\fn reject_if_let_result_required(maybe: ?*mut u8) -> void {
        \\    if let ok(value) = maybe {
        \\    }
        \\}
        \\
        \\fn reject_if_let_result_tag(result: Result<u32, Error>) -> void {
        \\    if let ready(value) = result {
        \\    }
        \\}
        \\
        \\fn reject_if_let_narrow_pattern(status: Status) -> void {
        \\    if let .ready = status {
        \\    }
        \\}
        \\
        \\fn reject_switch_result_tag(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ready(value) => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_switch_result_required(value: u32) -> void {
        \\    switch value {
        \\        .ok => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_switch_multi_binding_arm(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ok(value), err(error_value) => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn accept_valid_result_patterns() -> void {
        \\    let result = make_result_u32();
        \\    if let ok(value) = result {
        \\    }
        \\    switch result {
        \\        ok(value) => {},
        \\        err(error_value) => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_branch_patterns.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_optional_required pass=result finding=if_let_optional_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_required pass=result finding=if_let_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_tag pass=result finding=if_let_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_narrow_pattern pass=result finding=if_let_narrow_pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_tag pass=result finding=switch_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_required pass=result finding=switch_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_multi_binding_arm pass=result finding=switch_multi_binding_arm") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=if_let_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=switch_") == null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var found_if_optional = false;
    var found_if_required = false;
    var found_if_tag = false;
    var found_if_narrow = false;
    var found_switch_tag = false;
    var found_switch_required = false;
    var found_switch_multi = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_OPTIONAL_REQUIRED") != null) found_if_optional = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_RESULT_REQUIRED") != null) found_if_required = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_RESULT_TAG") != null) found_if_tag = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_NARROW_PATTERN") != null) found_if_narrow = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_RESULT_TAG") != null) found_switch_tag = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_RESULT_REQUIRED") != null) found_switch_required = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_MULTI_BINDING_ARM") != null) found_switch_multi = true;
    }
    try std.testing.expect(found_if_optional);
    try std.testing.expect(found_if_required);
    try std.testing.expect(found_if_tag);
    try std.testing.expect(found_if_narrow);
    try std.testing.expect(found_switch_tag);
    try std.testing.expect(found_switch_required);
    try std.testing.expect(found_switch_multi);
}

test "MIR verifier reports duplicate switch cases" {
    const source =
        \\fn reject_bool_duplicate(flag: bool) -> void {
        \\    switch flag {
        \\        true => {},
        \\        true => {},
        \\        false => {},
        \\    }
        \\}
        \\
        \\fn reject_integer_duplicate(value: u32) -> void {
        \\    switch value {
        \\        1 => {},
        \\        0x1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_result_duplicate(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ok(value) => {},
        \\        .ok => {},
        \\        err(error_value) => {},
        \\    }
        \\}
        \\
        \\fn reject_case_after_wildcard(value: u32) -> void {
        \\    switch value {
        \\        _ => {},
        \\        2 => {},
        \\    }
        \\}
        \\
        \\fn reject_same_arm_wildcard_cover(value: u32) -> void {
        \\    switch value {
        \\        _, 3 => {},
        \\    }
        \\}
        \\
        \\fn accept_distinct_switches(flag: bool, value: u32, result: Result<u32, Error>) -> void {
        \\    switch flag {
        \\        true => {},
        \\        false => {},
        \\    }
        \\    switch value {
        \\        1 => {},
        \\        2 => {},
        \\        _ => {},
        \\    }
        \\    switch result {
        \\        ok(value) => {},
        \\        err(error_value) => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_switch_duplicates.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_case_after_wildcard pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_same_arm_wildcard_cover pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_distinct_switches pass=core finding=duplicate_switch_case") == null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var duplicate_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) duplicate_count += 1;
    }
    try std.testing.expect(duplicate_count >= 5);
}

test "MIR verifier reports switch literal pattern type mismatches" {
    const source =
        \\enum Irq {
        \\    timer,
        \\    keyboard,
        \\}
        \\
        \\fn reject_bool_switch_integer_pattern(flag: bool) -> void {
        \\    switch flag {
        \\        1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_integer_switch_bool_pattern(value: u32) -> void {
        \\    switch value {
        \\        true => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_enum_switch_literal_pattern(irq: Irq) -> void {
        \\    switch irq {
        \\        1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn accept_scalar_switch_literals(flag: bool, value: u32) -> void {
        \\    switch flag {
        \\        true => {},
        \\        false => {},
        \\    }
        \\    switch value {
        \\        1 => {},
        \\        2 => {},
        \\        _ => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_switch_literal_patterns.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_switch_integer_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_switch_bool_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_switch_literal_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_scalar_switch_literals pass=core finding=switch_literal_type_mismatch") == null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var mismatch_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) mismatch_count += 1;
    }
    try std.testing.expect(mismatch_count >= 3);
}

test "MIR verifier validates enum switch cases and closed enum exhaustiveness" {
    const source =
        \\enum Irq {
        \\    timer,
        \\    keyboard,
        \\}
        \\
        \\open enum OpenError: u8 {
        \\    fault = 1,
        \\    busy = 2,
        \\}
        \\
        \\fn reject_closed_enum_nonexhaustive(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\    }
        \\}
        \\
        \\fn reject_closed_enum_unknown_case(irq: Irq) -> void {
        \\    switch irq {
        \\        .missing => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_open_enum_unknown_case(error_value: OpenError) -> void {
        \\    switch error_value {
        \\        .missing => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_enum_duplicate_case(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        .timer => {},
        \\        .keyboard => {},
        \\    }
        \\}
        \\
        \\fn accept_closed_enum_exhaustive(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        .keyboard => {},
        \\    }
        \\}
        \\
        \\fn accept_closed_enum_wildcard(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        _ => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_enum_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_nonexhaustive pass=core finding=closed_enum_switch_exhaustive") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_open_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_duplicate_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=representation finding=representation_use detail=switch_subject type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=core") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_wildcard pass=core") == null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var found_nonexhaustive = false;
    var found_unknown = false;
    var found_duplicate = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE") != null) found_nonexhaustive = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_ENUM_CASE") != null) found_unknown = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) found_duplicate = true;
    }
    try std.testing.expect(found_nonexhaustive);
    try std.testing.expect(found_unknown);
    try std.testing.expect(found_duplicate);
}

test "MIR verifier validates tagged union switch cases" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    ident: []const u8,
        \\    eof,
        \\}
        \\
        \\type TokenAlias = Token;
        \\
        \\fn reject_unknown_union_case(token: Token) -> void {
        \\    switch token {
        \\        .missing => {},
        \\        .int => {},
        \\        .ident => {},
        \\        .eof => {},
        \\    }
        \\}
        \\
        \\fn reject_payloadless_union_case_binding(token: Token) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        ident(name) => {},
        \\        eof(value) => {},
        \\    }
        \\}
        \\
        \\fn reject_duplicate_union_case(token: TokenAlias) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        .int => {},
        \\        .ident => {},
        \\        .eof => {},
        \\    }
        \\}
        \\
        \\fn accept_union_patterns(token: TokenAlias) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        ident(name) => {},
        \\        .eof => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_union_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unknown_union_case pass=core finding=unknown_union_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_payloadless_union_case_binding pass=core finding=union_case_has_no_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_duplicate_union_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_union_patterns pass=core") == null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var found_unknown = false;
    var found_payloadless = false;
    var found_duplicate = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_UNION_CASE") != null) found_unknown = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNION_CASE_HAS_NO_PAYLOAD") != null) found_payloadless = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) found_duplicate = true;
    }
    try std.testing.expect(found_unknown);
    try std.testing.expect(found_payloadless);
    try std.testing.expect(found_duplicate);
}

test "MIR verifier reports Result reassignment and invalid try operands" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\extern fn make_void() -> void;
        \\
        \\fn reject_overwrite_unhandled_result() -> u32 {
        \\    var result = make_result_u32();
        \\    result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn accept_assignment_handled_later() -> u32 {
        \\    var result: Result<u32, Error> = make_result_u32();
        \\    result?;
        \\    result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn reject_void_direct_call_try() -> void {
        \\    return make_void()?;
        \\}
        \\
        \\fn reject_integer_try(n: u32) -> u32 {
        \\    return n?;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_reassign_try.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_overwrite_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_assignment_handled_later pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_void_direct_call_try pass=result finding=try_requires_result_or_nullable") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_try pass=result finding=try_requires_result_or_nullable") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var found_unhandled = false;
    var found_invalid_try = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNHANDLED_RESULT") != null) found_unhandled = true;
        if (std.mem.indexOf(u8, diag.message, "E_TRY_REQUIRES_RESULT_OR_NULLABLE") != null) found_invalid_try = true;
    }
    try std.testing.expect(found_unhandled);
    try std.testing.expect(found_invalid_try);
}

test "MIR verifier reports Result try payload return mismatches" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\extern fn make_result_c_void_pointer() -> Result<*mut c_void, Error>;
        \\extern fn make_result_u16_pointer() -> Result<*mut u16, Error>;
        \\extern fn make_result_bytes() -> Result<[2]u8, Error>;
        \\extern fn make_nullable_mut_pointer() -> ?*mut u8;
        \\extern fn make_nullable_c_void_pointer() -> ?*mut c_void;
        \\extern fn takes_const_pointer(value: *const u8) -> void;
        \\
        \\struct PointerBox {
        \\    ptr: *const u8,
        \\}
        \\
        \\fn accept_result_try_payload() -> u32 {
        \\    return make_result_u32()?;
        \\}
        \\
        \\fn accept_result_pointer_try_payload() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn accept_nullable_pointer_try_payload() -> *mut u8 {
        \\    return make_nullable_mut_pointer()?;
        \\}
        \\
        \\fn reject_result_try_payload() -> *mut u8 {
        \\    return make_result_u32()?;
        \\}
        \\
        \\fn reject_pointer_payload_to_integer() -> u32 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_pointer_payload_conversion() -> *const u8 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_pointer_payload_element_conversion() -> *mut u16 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_c_void_payload_conversion() -> *mut u8 {
        \\    return make_result_c_void_pointer()?;
        \\}
        \\
        \\fn reject_result_typed_to_c_void_payload_conversion() -> *mut c_void {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_nullable_pointer_payload_conversion() -> *const u8 {
        \\    return make_nullable_mut_pointer()?;
        \\}
        \\
        \\fn reject_nullable_c_void_payload_conversion() -> *mut u8 {
        \\    return make_nullable_c_void_pointer()?;
        \\}
        \\
        \\fn reject_result_try_local_initializer() -> void {
        \\    let ptr: *const u8 = make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_try_assignment(fallback: *const u8) -> void {
        \\    var ptr: *const u8 = fallback;
        \\    ptr = make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_try_call_arg() -> void {
        \\    takes_const_pointer(make_result_pointer()?);
        \\}
        \\
        \\fn reject_result_try_aggregate_field() -> PointerBox {
        \\    return .{ .ptr = make_result_pointer()? };
        \\}
        \\
        \\fn reject_cast_result_try_payload() -> *const u8 {
        \\    return (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn reject_cast_result_try_local_initializer() -> void {
        \\    let ptr: *const u8 = (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn reject_cast_result_try_assignment(fallback: *const u8) -> void {
        \\    var ptr: *const u8 = fallback;
        \\    ptr = (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn reject_cast_result_try_call_arg() -> void {
        \\    takes_const_pointer(make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn reject_cast_result_try_aggregate_field() -> PointerBox {
        \\    return .{ .ptr = make_result_pointer()? as *const u8 };
        \\}
        \\
        \\fn reject_inferred_result_array_try_index() -> *mut u8 {
        \\    let bytes = make_result_bytes()?;
        \\    return bytes[0];
        \\}
        \\
        \\fn reject_if_let_result_array_binding() -> *mut u8 {
        \\    if let ok(bytes) = make_result_bytes() {
        \\        return bytes[0];
        \\    } else {
        \\        return make_result_pointer()?;
        \\    }
        \\}
        \\
        \\fn reject_switch_result_array_binding() -> *mut u8 {
        \\    let result = make_result_bytes();
        \\    switch result {
        \\        ok(bytes) => {
        \\            return bytes[0];
        \\        },
        \\        err(e) => {
        \\            return make_result_pointer()?;
        \\        },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_payload.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_payload pass=result finding=try_payload_type_mismatch") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_pointer_try_payload pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nullable_pointer_try_payload pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_pointer_try_payload pass=representation finding=representation_use detail=try_unwrap type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nullable_pointer_try_payload pass=representation finding=representation_use detail=try_unwrap type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_payload pass=result finding=try_payload_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_pointer_payload_to_integer pass=result finding=try_payload_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_pointer_payload_conversion pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_pointer_payload_element_conversion pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_typed_to_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_pointer_payload_conversion pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_local_initializer pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_assignment pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_call_arg pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_aggregate_field pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_result_try_payload pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_result_try_local_initializer pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_result_try_assignment pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_result_try_call_arg pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_result_try_aggregate_field pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_inferred_result_array_try_index pass=conversion finding=return_type_mismatch source_type=u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_array_binding pass=conversion finding=return_type_mismatch source_type=u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_array_binding pass=conversion finding=return_type_mismatch source_type=u8") != null);

    var typed_mir = try build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try verifyBuiltMir(typed_mir, &reporter);
    var mismatch_count: usize = 0;
    var pointer_conversion_count: usize = 0;
    var c_void_conversion_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) mismatch_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) pointer_conversion_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_C_VOID_CONVERSION") != null) c_void_conversion_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), mismatch_count);
    try std.testing.expectEqual(@as(usize, 12), pointer_conversion_count);
    try std.testing.expectEqual(@as(usize, 3), c_void_conversion_count);
}
