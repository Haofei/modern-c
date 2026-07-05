const std = @import("std");

const array_len = @import("array_len.zig");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const numeric = @import("numeric.zig");
const parser = @import("parser.zig");

// Pure AST-shape queries shared with `sema.zig`/`lower_c.zig` (see `ast_query.zig`).
const MmioRegisterAccess = ast_query.MmioRegisterAccess;
const mmioRegisterAccessFromModeType = ast_query.mmioRegisterAccessFromModeType;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const exprHandlesAnyResult = ast_query.exprHandlesAnyResult;
const isResultNarrowingTag = ast_query.isResultNarrowingTag;
const localDeclaresName = ast_query.localDeclaresName;
const resultIfLetHandlesLocal = ast_query.resultIfLetHandlesLocal;
const resultSwitchHandlesLocal = ast_query.resultSwitchHandlesLocal;
const contractName = ast_query.contractName;
const isSatPreservingBinary = ast_query.isSatPreservingBinary;
const isWrapPreservingBinary = ast_query.isWrapPreservingBinary;
const reduceCallKind = ast_query.reduceCallKind;
const calleeIdentName = ast_query.calleeIdentName;
const memberExpr = ast_query.memberExpr;

// Numeric-literal and integer-bounds primitives shared with `sema.zig` and `lower_c.zig`
// (see `numeric.zig`); aliased here so the existing call sites read unchanged.
const LiteralValue = numeric.LiteralValue;
const IntBounds = numeric.IntBounds;
const maxUnsigned = numeric.maxUnsigned;
const signedBounds = numeric.signedBounds;
const integerLiteralValue = numeric.integerLiteralValue;
const parseArrayLen = array_len.parseArrayLen;

const mir_model = @import("mir_model.zig");
const mir_operator = @import("mir_operator.zig");
const mir_representation = @import("mir_representation.zig");
const mir_reflect = @import("mir_reflect.zig");
const mir_summary = @import("mir_summary.zig");
const mir_syntax = @import("mir_syntax.zig");
const mir_type = @import("mir_type.zig");
const mir_verify_util = @import("mir_verify_util.zig");

pub const TrapKind = mir_model.TrapKind;
pub const TrapSource = mir_model.TrapSource;
pub const AddressClass = mir_model.AddressClass;
pub const PointerKind = mir_model.PointerKind;
pub const PointerShape = mir_model.PointerShape;
pub const ResultShape = mir_model.ResultShape;
pub const ValueType = mir_model.ValueType;
pub const Instruction = mir_model.Instruction;
pub const Terminator = mir_model.Terminator;
pub const TrapEdge = mir_model.TrapEdge;
pub const ContractRegion = mir_model.ContractRegion;
pub const RangeFact = mir_model.RangeFact;
pub const SourcePoint = mir_model.SourcePoint;
pub const PointerProvenance = mir_model.PointerProvenance;
pub const PointerProvenanceFact = mir_model.PointerProvenanceFact;
pub const PointerProvenanceInvalidationPolicy = mir_model.PointerProvenanceInvalidationPolicy;
pub const PointerProvenanceInvalidationReason = mir_model.PointerProvenanceInvalidationReason;
pub const Block = mir_model.Block;
pub const Function = mir_model.Function;
pub const Module = mir_model.Module;
pub const BuildOptions = mir_model.BuildOptions;
const addressClassName = mir_model.addressClassName;

const FunctionSummary = mir_summary.FunctionSummary;
const EnumSummary = mir_summary.EnumSummary;
const StructSummary = mir_summary.StructSummary;
const UnionSummary = mir_summary.UnionSummary;
const PackedBitsSummary = mir_summary.PackedBitsSummary;
const MirReflectEnv = mir_summary.ReflectEnv;

const directCalleeName = mir_syntax.directCalleeName;
const directIdentName = mir_syntax.directIdentName;
const exprTerminates = mir_syntax.exprTerminates;
const exprText = mir_syntax.exprText;
const enumLiteralText = mir_syntax.enumLiteralText;
const isTrapCall = mir_syntax.isTrapCall;
const isUnwrapCall = mir_syntax.isUnwrapCall;
const assignmentTargetIdentName = mir_syntax.assignmentTargetIdentName;
const constGetBase = mir_syntax.constGetBase;
const patternText = mir_syntax.patternText;
const typeText = mir_syntax.typeText;
const ConversionContext = mir_verify_util.ConversionContext;
const IrqContextCallFinding = mir_verify_util.IrqContextCallFinding;
const MmioOperation = mir_verify_util.MmioOperation;
const MmioAccessInfo = mir_verify_util.MmioAccessInfo;
const ArithmeticDomain = mir_verify_util.ArithmeticDomain;
const irqContextFindingName = mir_verify_util.irqContextFindingName;
const irqContextDiagnostic = mir_verify_util.irqContextDiagnostic;
const contractAllowsUnchecked = mir_verify_util.contractAllowsUnchecked;
const noOverflowUncheckedOp = mir_verify_util.noOverflowUncheckedOp;
const hasAttr = mir_verify_util.hasAttr;
const nullabilityDiagnostic = mir_verify_util.nullabilityDiagnostic;
const conversionDiagnostic = mir_verify_util.conversionDiagnostic;
const aggregateDiagnostic = mir_verify_util.aggregateDiagnostic;
const resultFindingDiagnostic = mir_verify_util.resultFindingDiagnostic;
const switchFindingDiagnostic = mir_verify_util.switchFindingDiagnostic;
const assignmentFindingDiagnostic = mir_verify_util.assignmentFindingDiagnostic;
const arithmeticDomainFindingDiagnostic = mir_verify_util.arithmeticDomainFindingDiagnostic;
const operatorFindingDiagnostic = mir_verify_util.operatorFindingDiagnostic;
const addressDerefDiagnostic = mir_verify_util.addressDerefDiagnostic;
const addressClassMismatchDiagnostic = mir_verify_util.addressClassMismatchDiagnostic;
const ffiFindingDiagnostic = mir_verify_util.ffiFindingDiagnostic;
const usageFindingDiagnostic = mir_verify_util.usageFindingDiagnostic;
const isRepresentationSensitiveProducer = mir_representation.isSensitiveProducer;
const isRepresentationSensitiveUse = mir_representation.isSensitiveUse;
const defaultInstructionValueId = mir_representation.defaultInstructionValueId;
const producerHasDominatingRepresentationCheck = mir_representation.producerHasDominatingCheck;
const useHasDominatingRepresentationCheck = mir_representation.useHasDominatingCheck;
const representationCheckKind = mir_representation.checkKind;
const representationTypeName = mir_representation.typeName;
const representationCheckTraps = mir_representation.checkTraps;
const isVoidLike = mir_type.isVoidLike;
const nullabilityFinding = mir_type.nullabilityFinding;
const conversionFinding = mir_type.conversionFinding;
const integerLiteralRangeFinding = mir_type.integerLiteralRangeFinding;
const integerLiteralFitsTarget = mir_type.integerLiteralFitsTarget;
const checkedIntBoundsByName = mir_type.checkedIntBoundsByName;
const isDynTraitMirType = mir_type.isDynTraitMirType;
const isViewConstNarrowCast = mir_type.isViewConstNarrowCast;
const valueTypeFromExpr = mir_type.valueTypeFromExpr;
const valueTypeFromType = mir_type.valueTypeFromType;
const valueTypeFromTypeAlias = mir_type.valueTypeFromTypeAlias;
const valueTypeFromTypeName = mir_type.valueTypeFromTypeName;
const valueTypeFromTypeNameAlias = mir_type.valueTypeFromTypeNameAlias;
const aggregateTargetType = mir_type.aggregateTargetType;
const aggregateTargetTypeAlias = mir_type.aggregateTargetTypeAlias;
const arrayElementType = mir_type.arrayElementType;
const arrayElementTypeAlias = mir_type.arrayElementTypeAlias;
const storageElementTypeAlias = mir_type.storageElementTypeAlias;
const sliceTypeForBaseAlias = mir_type.sliceTypeForBaseAlias;
const tryPayloadTypeExprAlias = mir_type.tryPayloadTypeExprAlias;
const resultPayloadTypeExprAlias = mir_type.resultPayloadTypeExprAlias;
const structTypeNameAlias = mir_type.structTypeNameAlias;
const isDynTraitTypeAlias = mir_type.isDynTraitTypeAlias;
const unionTypeNameAlias = mir_type.unionTypeNameAlias;
const pointerShape = mir_type.pointerShape;
const pointerShapeAlias = mir_type.pointerShapeAlias;
const nullPointerShape = mir_type.nullPointerShape;
const pointerShapeFromName = mir_type.pointerShapeFromName;
const addressClassFromName = mir_type.addressClassFromName;
const isWrapTypeAlias = mir_type.isWrapTypeAlias;
const isSatTypeAlias = mir_type.isSatTypeAlias;
const arithmeticDomainTypeAlias = mir_type.arithmeticDomainTypeAlias;
const isTryCapableType = mir_type.isTryCapableType;
const isResultType = mir_type.isResultType;
const isMirNullableValue = mir_type.isMirNullableValue;
const isMirEnum = mir_type.isMirEnum;
const isMirIntegerLike = mir_type.isMirIntegerLike;
const unknownResultType = mir_type.unknownResultType;
const mirTypesAreCompatible = mir_type.typesAreCompatible;
const isMirForIterable = mir_type.isMirForIterable;
const isMirIndexableBase = mir_type.isMirIndexableBase;
const isMirIndexType = mir_type.isMirIndexType;
const isPointerViewConversion = mir_type.isPointerViewConversion;
const isCVoidPointerConversion = mir_type.isCVoidPointerConversion;
const isCVoidPointerType = mir_type.isCVoidPointerType;
const isPointerLikeType = mir_type.isPointerLikeType;
const samePointerShape = mir_type.samePointerShape;
const isNullPointerShape = mir_type.isNullPointerShape;
const addressClassMismatch = mir_type.addressClassMismatch;
const binaryMayOverflow = mir_operator.binaryMayOverflow;
const binaryTrapKind = mir_operator.binaryTrapKind;
const isShiftOp = mir_operator.isShiftOp;
const binaryChecksAddressClass = mir_operator.binaryChecksAddressClass;
const mirIsArithmeticBinary = mir_operator.isArithmeticBinary;
const mirIsBitwiseBinary = mir_operator.isBitwiseBinary;
const mirIsLogicalBinary = mir_operator.isLogicalBinary;
const mirIsOrderedComparison = mir_operator.isOrderedComparison;
const mirIsPointerArithmetic = mir_operator.isPointerArithmetic;
const isMirSingleObjectPointer = mir_operator.isSingleObjectPointer;
const isMirPointerOrView = mir_operator.isPointerOrView;
const isMirCVoidPointer = mir_operator.isCVoidPointer;
const isMirForbiddenOrderingDomain = mir_operator.isForbiddenOrderingDomain;
const mirIsComparisonBinary = mir_operator.isComparisonBinary;
const logicalOperandsAllowed = mir_operator.logicalOperandsAllowed;
const unaryNegOperandAllowed = mir_operator.unaryNegOperandAllowed;
const bitwiseOperandAllowed = mir_operator.bitwiseOperandAllowed;
const checkedIntegerBinaryFinding = mir_operator.checkedIntegerBinaryFinding;
const floatBinaryFinding = mir_operator.floatBinaryFinding;
const isCheckedUnsignedType = mir_operator.isCheckedUnsignedType;
const isCheckedSignedType = mir_operator.isCheckedSignedType;

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
        .reflect = mir_reflect.comptimeReflectThunk,
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
                        .pointer_provenance_facts = try allocator.alloc(PointerProvenanceFact, 0),
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
            "mir function name={s} return={s} no_lang_trap={} irq_context={} blocks={} trap_edges={} contract_regions={} range_facts={} pointer_provenance_facts={}\n",
            .{ function.name, function.return_ty.name(), function.no_lang_trap, function.irq_context, function.blocks.len, function.trap_edges.len, function.contract_regions.len, function.range_facts.len, function.pointer_provenance_facts.len },
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
        for (function.pointer_provenance_facts) |fact| {
            const element = if (fact.element_index) |index| try std.fmt.allocPrint(allocator, "{}", .{index}) else "none";
            defer if (fact.element_index != null) allocator.free(element);
            try out.print(
                allocator,
                "mir pointer_provenance_fact fn={s} subject={s} element={s} provenance={s} storage={s} pointer_kind={s} mutability={s} child={s} invalidation_reason={s} invalidation_policy={s} line={} column={}\n",
                .{
                    function.name,
                    fact.subject,
                    element,
                    @tagName(fact.provenance),
                    fact.storage orelse "none",
                    @tagName(fact.pointer_shape.kind),
                    @tagName(fact.pointer_shape.mutability),
                    fact.pointer_shape.child,
                    @tagName(fact.invalidation_reason),
                    @tagName(fact.invalidation_policy),
                    fact.source.line,
                    fact.source.column,
                },
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

// OPT (annex E) — a range fact proven true on every path reaching the current program point,
// gathered from `if`/`while` guards and `assert`s so a later `arr[i]`/`x / d` can drop a
// provably-dead bounds/divide check. Facts are conservative and SOUND-ONLY: the operands are
// restricted to simple identifiers (whose only mutation vectors — assignment or `&`/`&mut` —
// clear all facts) so no aliased write can invalidate a fact behind our back. A fact is never
// removed once invalidated (`valid=false`); it is only dropped when its scope pops.
const ProvenFact = struct {
    kind: enum { lt, positive, nonzero },
    // `lt`: `a < b`. `positive`: `a > 0`. `nonzero`: `a != 0`.
    a: ast.Expr,
    b: ast.Expr = undefined,
    valid: bool = true,
};

const LivePointerProvenance = struct {
    subject: []const u8,
    element_index: ?usize,
    pointer_shape: PointerShape,
};

const DirectPointerProvenance = struct {
    kind: PointerProvenance,
    storage: []const u8,
};

const IndexedAssignmentTarget = struct {
    subject: []const u8,
    base: ast.Expr,
    index: usize,
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
    pointer_provenance_facts: std.ArrayList(PointerProvenanceFact),
    live_pointer_provenance: std.ArrayList(LivePointerProvenance),
    elided_bounds: std.ArrayList(SourcePoint),
    // OPT (annex E) — guard/assert-proven facts live for check elision (see ProvenFact).
    proven_facts: std.ArrayList(ProvenFact) = .empty,
    // OPT (annex E) — identifiers whose address is taken ANYWHERE in the function body (a
    // pre-pass, so ordering is irrelevant). A pointer to such a local can outlive an `&`/`&mut`
    // site and mutate it through an opaque call we cannot see, so these names never become fact
    // operands. Populated only under `--optimize`.
    address_taken: std.StringHashMap(void),
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
            // `#[naked]` is an implicit strict-unsafe context (the asm body needs no
            // `unsafe {}` wrapper), matching sema — so no `.unsafe_check` is emitted.
            .active_unsafe = hasAttr(attrs, "naked"),
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
            .pointer_provenance_facts = .empty,
            .live_pointer_provenance = .empty,
            .elided_bounds = .empty,
            .address_taken = std.StringHashMap(void).init(allocator),
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
            .pointer_provenance_facts = .empty,
            .live_pointer_provenance = .empty,
            .elided_bounds = .empty,
            .address_taken = std.StringHashMap(void).init(allocator),
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
        self.pointer_provenance_facts.deinit(self.allocator);
        self.live_pointer_provenance.deinit(self.allocator);
        self.elided_bounds.deinit(self.allocator);
        self.proven_facts.deinit(self.allocator);
        self.address_taken.deinit();
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
        const pointer_provenance_facts = try self.pointer_provenance_facts.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(pointer_provenance_facts);
        const elided_bounds = try self.elided_bounds.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(elided_bounds);

        self.blocks.deinit(self.allocator);
        self.blocks = .empty;
        self.proven_facts.deinit(self.allocator);
        self.proven_facts = .empty;
        self.live_pointer_provenance.deinit(self.allocator);
        self.live_pointer_provenance = .empty;
        self.address_taken.deinit();
        self.address_taken = std.StringHashMap(void).init(self.allocator);
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
            .pointer_provenance_facts = pointer_provenance_facts,
            .elided_bounds = elided_bounds,
        };
    }

    fn buildBody(self: *FunctionBuilder, body: ast.Block) anyerror!void {
        // OPT (annex E) — collect address-taken locals up front so no fact is ever formed about a
        // name a hidden alias could mutate (see `address_taken`). Only needed under `--optimize`.
        if (self.optimize) try self.collectAddressTakenBlock(body);
        _ = try self.buildBlock(body);
    }

    fn collectAddressTakenBlock(self: *FunctionBuilder, block: ast.Block) anyerror!void {
        for (block.items) |stmt| try self.collectAddressTakenStmt(stmt);
    }

    fn collectAddressTakenStmt(self: *FunctionBuilder, stmt: ast.Stmt) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (local.init) |init_expr| try self.collectAddressTakenExpr(init_expr);
            },
            .assignment => |node| {
                try self.collectAddressTakenExpr(node.target);
                try self.collectAddressTakenExpr(node.value);
            },
            .expr, .@"defer", .assert => |expr| try self.collectAddressTakenExpr(expr),
            .@"return" => |maybe| if (maybe) |expr| try self.collectAddressTakenExpr(expr),
            .block, .comptime_block, .unsafe_block => |b| try self.collectAddressTakenBlock(b),
            .contract_block => |c| try self.collectAddressTakenBlock(c.block),
            .if_let => |node| {
                try self.collectAddressTakenExpr(node.value);
                try self.collectAddressTakenBlock(node.then_block);
                if (node.else_block) |eb| try self.collectAddressTakenBlock(eb);
            },
            .@"switch" => |node| {
                try self.collectAddressTakenExpr(node.subject);
                for (node.arms) |arm| switch (arm.body) {
                    .block => |b| try self.collectAddressTakenBlock(b),
                    .expr => |e| try self.collectAddressTakenExpr(e),
                };
            },
            .loop => |node| {
                if (node.iterable) |it| try self.collectAddressTakenExpr(it);
                try self.collectAddressTakenBlock(node.body);
            },
            .@"break", .@"continue", .asm_stmt => {},
        }
    }

    fn collectAddressTakenExpr(self: *FunctionBuilder, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .address_of => |inner| {
                if (identBaseName(inner.*)) |name| try self.address_taken.put(name, {});
                try self.collectAddressTakenExpr(inner.*);
            },
            .grouped, .deref, .await_expr => |inner| try self.collectAddressTakenExpr(inner.*),
            .unary => |node| try self.collectAddressTakenExpr(node.expr.*),
            .cast => |node| try self.collectAddressTakenExpr(node.value.*),
            .binary => |node| {
                try self.collectAddressTakenExpr(node.left.*);
                try self.collectAddressTakenExpr(node.right.*);
            },
            .index => |node| {
                try self.collectAddressTakenExpr(node.base.*);
                try self.collectAddressTakenExpr(node.index.*);
            },
            .slice => |node| {
                try self.collectAddressTakenExpr(node.base.*);
                try self.collectAddressTakenExpr(node.start.*);
                try self.collectAddressTakenExpr(node.end.*);
            },
            .member => |node| try self.collectAddressTakenExpr(node.base.*),
            .call => |node| {
                try self.collectAddressTakenExpr(node.callee.*);
                for (node.args) |arg| try self.collectAddressTakenExpr(arg);
            },
            .try_expr => |node| {
                try self.collectAddressTakenExpr(node.operand.*);
                if (node.mapped) |m| try self.collectAddressTakenExpr(m.*);
            },
            .array_literal => |items| for (items) |item| try self.collectAddressTakenExpr(item),
            .struct_literal => |fields| for (fields) |field| try self.collectAddressTakenExpr(field.value),
            .block => |b| try self.collectAddressTakenBlock(b),
            else => {},
        }
    }

    // The base identifier of an address-of target: `&x`, `&x.f`, `&x[i]`, `&(x)` all pin `x`.
    fn identBaseName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |id| id.text,
            .grouped => |inner| identBaseName(inner.*),
            .member => |m| identBaseName(m.base.*),
            .index => |n| identBaseName(n.base.*),
            .deref => |inner| identBaseName(inner.*),
            else => null,
        };
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
        // OPT (annex E) — facts proven inside this block (by `assert`s or nested guards) do not
        // outlive it: drop everything appended while building it. Invalidations of outer facts
        // (valid=false) intentionally persist — keeping a check that is still live is always sound.
        const facts_save = self.proven_facts.items.len;
        defer self.proven_facts.items.len = facts_save;
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
                    try self.recordPointerProvenanceForLocalInitializer(local.names, ty_expr, ty, expr);
                    self.assignment_target = previous_target;
                    self.assignment_target_ty = previous_target_ty;
                }
                // OPT (annex E) — a new binding may shadow a fact operand; drop all facts (after
                // the initializer was built, so a use in it still saw the pre-decl facts).
                self.invalidateFacts();
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
                try self.recordPointerProvenanceForAssignment(node.target, node.value, stmt.span);
                self.assignment_target = previous_target;
                self.assignment_target_ty = previous_target_ty;
                // OPT (annex E) — a store may change any fact operand; drop all facts (after the
                // RHS/target were built, so a use on this line still saw the pre-write facts).
                self.invalidateFacts();
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
                // OPT (annex E) — control only continues past the assert when its condition held,
                // so its range facts are proven for the rest of this block (dropped when it pops).
                try self.recordTrueCondFacts(expr);
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
                .nullable_dyn_trait => .{ .name = ident.text, .ty = .value, .ty_expr = self.narrowedBindingTypeExpr(node.value, "ok") },
                .nullable_value => |child| .{ .name = ident.text, .ty = valueTypeFromTypeNameAlias(child, self.enums, self.structs, self.packed_bits), .ty_expr = self.narrowedBindingTypeExpr(node.value, "ok") },
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
                .nullable_dyn_trait => .{ .name = ident.text, .ty = .value, .ty_expr = self.narrowedBindingTypeExpr(subject, "ok") },
                .nullable_value => |child| .{ .name = ident.text, .ty = valueTypeFromTypeNameAlias(child, self.enums, self.structs, self.packed_bits), .ty_expr = self.narrowedBindingTypeExpr(subject, "ok") },
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
            // OPT (annex E) — a plain `if (cond) {…}` is desugared to `switch cond { true => …,
            // false => … }`, so the `true` arm runs only when `cond` held: record its facts for
            // that arm and drop them afterwards. Any single-pattern `.literal true` arm qualifies.
            const facts_save = self.proven_facts.items.len;
            if (arm.patterns.len == 1 and patternIsBoolTrue(arm.patterns[0])) {
                try self.recordTrueCondFacts(node.subject);
            }
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
            // Drop this arm's guard facts before the next arm (invalidations of outer facts made
            // inside the arm intentionally persist — the arm may have run, so a later use of an
            // outer fact must stay conservative).
            self.proven_facts.items.len = facts_save;
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
        // `&`/`|`/`^` on two bools is allowed inside `unsafe` as a C-compat escape hatch
        // (mirrors sema): skip the per-operand bool/operand checks for exactly that shape.
        const both_bool_bitwise = self.active_unsafe and mirIsBitwiseBinary(node.op) and left_ty == .bool and right_ty == .bool;
        if (mirIsBitwiseBinary(node.op) and !both_bool_bitwise) {
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
        // OPT (annex E) — facts proven before the loop do NOT survive the back-edge (a later
        // iteration may have mutated their operands), so invalidate them all. A `while (cond)`
        // re-tests `cond` on entry to every iteration, so its facts DO hold at the top of the
        // body — record them there (valid until the first in-body write clears them).
        const facts_save = self.proven_facts.items.len;
        self.invalidateFacts();
        if (node.kind == .@"while") {
            if (node.iterable) |cond| try self.recordTrueCondFacts(cond);
        }
        const terminated = try self.buildBlock(node.body);
        self.proven_facts.items.len = facts_save;
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
            // The async transform eliminates every `await_expr` pre-sema.
            .await_expr => unreachable,
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
            .grouped => |inner| try self.buildExpr(inner.*),
            .address_of => |inner| {
                // OPT (annex E) — taking an address exposes the target to a later aliased write we
                // cannot see; conservatively drop all facts so none is used past this point.
                try self.recordPointerProvenanceAddressEscape(inner.*, expr.span);
                self.invalidateFacts();
                try self.buildExpr(inner.*);
            },
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
                // A `[]mut T as []const T` (G12) or `*mut T as *const T` (G30) const-narrowing
                // cast is a statically-safe reinterpret (the source pointer/slice is already a
                // valid representation). Emit its own dominating representation check keyed on the
                // cast's own text so the enclosing representation_use (initializer/call_arg, keyed
                // on the cast text) is discharged — the same way `.ident`/`address_of`
                // self-discharge their nonnull obligation.
                if (isViewConstNarrowCast(cast_target, self.exprType(node.value.*)) and representationCheckKind(cast_target) != null) {
                    try self.addInstr(.typed_load, exprText(expr), cast_target, expr.span);
                    try self.addRuntimeRepresentationCheck(cast_target, expr.span, exprText(expr));
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
                // A `*dyn Trait` method call is a virtual dispatch — its return type is the trait
                // method's, not a same-named free function's. The verifier carries no trait sigs,
                // so leave it `.unknown` rather than mis-binding to `summaries[method_name]`.
                const is_dyn_dispatch = self.isDynDispatchMember(node.callee.*);
                const call_ty: ValueType = if (is_dyn_dispatch)
                    .unknown
                else if (self.summaries.get(callee_name)) |summary| summary.return_ty else .unknown;
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
                if (!is_dyn_dispatch) {
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
                }
                if (instr_kind == .unchecked_assume) try self.addRangeFactForUncheckedCall(callee_name, node.args, expr.span);
                if (instr_kind == .call) try self.recordPointerProvenanceCallInvalidation(.call, expr.span);
                if (instr_kind == .indirect_call) try self.recordPointerProvenanceCallInvalidation(.indirect_call, expr.span);
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

    // A method call dispatched through a `*dyn Trait` receiver (`a.alloc()` on `a: *mut dyn
    // Allocator`). The MIR verifier holds no trait method signatures, so it must NOT type such a
    // call from `summaries[method_name]` — a free function of the same name (e.g. `std/dma.alloc`)
    // would otherwise hijack the return/arg types. Callers treat these as `.unknown` (unverified).
    fn isDynDispatchMember(self: *FunctionBuilder, callee: ast.Expr) bool {
        const member = memberExpr(callee) orelse return false;
        const base_ty = self.typeExprForExpr(member.base.*) orelse return false;
        return isDynTraitTypeAlias(base_ty, self.aliases);
    }

    fn calleeName(self: *FunctionBuilder, callee: ast.Expr) []const u8 {
        return self.atomicReceiverCalleeName(callee) orelse
            self.mmioReceiverCalleeName(callee) orelse
            directCalleeName(callee) orelse
            exprText(callee);
    }

    fn atomicReceiverCalleeName(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const member = memberExpr(callee) orelse return null;
        const base_ty = self.typeExprForExpr(member.base.*) orelse return null;
        if (!isAtomicTypeExprAlias(base_ty, self.aliases)) return null;
        if (std.mem.eql(u8, member.name.text, "load")) return "atomic.load";
        if (std.mem.eql(u8, member.name.text, "store")) return "atomic.store";
        if (std.mem.eql(u8, member.name.text, "fetch_add")) return "atomic.fetch_add";
        if (std.mem.eql(u8, member.name.text, "fetch_sub")) return "atomic.fetch_sub";
        return null;
    }

    fn mmioReceiverCalleeName(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const access_info = self.mmioReceiverAccessInfo(callee) orelse return null;
        return switch (access_info.op) {
            .read => "mmio.read",
            .write => "mmio.write",
        };
    }

    fn mmioReceiverAccessInfo(self: *FunctionBuilder, callee: ast.Expr) ?MmioAccessInfo {
        const member = memberExpr(callee) orelse return null;
        const access = self.mmioRegisterAccessForExpr(member.base.*) orelse return null;
        const op: MmioOperation = if (std.mem.eql(u8, member.name.text, "read"))
            .read
        else if (std.mem.eql(u8, member.name.text, "write"))
            .write
        else
            return null;
        return .{ .access = access, .op = op };
    }

    fn mmioReceiverReadTypeExpr(self: *FunctionBuilder, callee: ast.Expr) ?ast.TypeExpr {
        const member = memberExpr(callee) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "read")) return null;
        const register_ty = self.mmioRegisterTypeExprForExpr(member.base.*) orelse return null;
        return mmioRegisterReadValueTypeExprAlias(register_ty, self.aliases);
    }

    fn isMmioRegisterExpr(self: *FunctionBuilder, expr: ast.Expr) bool {
        return self.mmioRegisterAccessForExpr(expr) != null;
    }

    fn mmioRegisterTypeExprForExpr(self: *FunctionBuilder, expr: ast.Expr) ?ast.TypeExpr {
        const member = memberExpr(expr) orelse return null;
        const base_ty = self.typeExprForExpr(member.base.*) orelse return null;
        const struct_name = mmioPtrTargetTypeNameAlias(base_ty, self.aliases) orelse return null;
        return self.structFieldTypeExpr(struct_name, member.name.text);
    }

    fn mmioRegisterAccessForExpr(self: *FunctionBuilder, expr: ast.Expr) ?MmioRegisterAccess {
        const field_ty = self.mmioRegisterTypeExprForExpr(expr) orelse return null;
        return mmioRegisterAccessFromTypeExprAlias(field_ty, self.aliases);
    }

    fn calleeMayResolveToValue(self: *FunctionBuilder, callee: ast.Expr) bool {
        const name = calleeIdentName(callee) orelse return false;
        return self.local_types.contains(name) or self.globals.contains(name);
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

    fn recordPointerProvenanceForLocalInitializer(self: *FunctionBuilder, names: []ast.Ident, ty_expr: ?ast.TypeExpr, value_ty: ValueType, initializer: ast.Expr) !void {
        if (pointerShapeFromValueType(value_ty)) |shape| {
            const provenance = self.directAddressProvenance(initializer) orelse return;
            for (names) |name| try self.appendPointerProvenanceFact(name.text, null, provenance, shape, .none, initializer.span);
            return;
        }
        const array_ty = ty_expr orelse return;
        const shape = self.fixedPointerArrayElementShape(array_ty) orelse return;
        const items = arrayLiteralItems(initializer) orelse return;
        for (names) |name| {
            for (items, 0..) |item, index| {
                const provenance = self.directAddressProvenance(item) orelse continue;
                try self.appendPointerProvenanceFact(name.text, index, provenance, shape, .none, item.span);
            }
        }
    }

    fn recordPointerProvenanceForAssignment(self: *FunctionBuilder, target: ast.Expr, value: ast.Expr, span: ast.Span) !void {
        if (assignmentTargetIdentName(target)) |target_name| {
            const target_ty = self.typeForAssignmentTarget(target);
            if (pointerShapeFromValueType(target_ty)) |shape| {
                if (self.directAddressProvenance(value)) |provenance| {
                    try self.appendPointerProvenanceFact(target_name, null, provenance, shape, .reassignment, value.span);
                } else {
                    try self.appendUnknownPointerProvenanceFact(target_name, null, shape, .reassignment, span);
                }
                return;
            }
            if (self.typeExprForAssignmentTarget(target)) |target_ty_expr| {
                if (self.fixedPointerArrayElementShape(target_ty_expr)) |shape| {
                    const items = arrayLiteralItems(value) orelse {
                        try self.appendUnknownPointerProvenanceFact(target_name, null, shape, .reassignment, span);
                        return;
                    };
                    try self.invalidatePointerProvenanceSubject(target_name, null, shape, .reassignment, span);
                    for (items, 0..) |item, index| {
                        const provenance = self.directAddressProvenance(item) orelse continue;
                        try self.appendPointerProvenanceFact(target_name, index, provenance, shape, .reassignment, item.span);
                    }
                }
            }
            return;
        }

        const indexed = constantIndexAssignmentTarget(target) orelse {
            if (dynamicIndexAssignmentSubject(target)) |subject| {
                if (self.local_type_exprs.get(subject)) |ty_expr| {
                    if (self.fixedPointerArrayElementShape(ty_expr)) |shape| {
                        try self.appendUnknownPointerProvenanceFact(subject, null, shape, .dynamic_index_write, span);
                    }
                }
            }
            return;
        };
        const shape = self.fixedPointerArrayElementShapeForExpr(indexed.base) orelse return;
        if (self.directAddressProvenance(value)) |provenance| {
            try self.appendPointerProvenanceFact(indexed.subject, indexed.index, provenance, shape, .reassignment, value.span);
        } else {
            try self.appendUnknownPointerProvenanceFact(indexed.subject, indexed.index, shape, .reassignment, span);
        }
    }

    fn recordPointerProvenanceCallInvalidation(self: *FunctionBuilder, reason: PointerProvenanceInvalidationReason, span: ast.Span) !void {
        if (self.live_pointer_provenance.items.len == 0) return;
        for (self.live_pointer_provenance.items) |live| {
            try self.pointer_provenance_facts.append(self.allocator, .{
                .subject = live.subject,
                .element_index = live.element_index,
                .storage = null,
                .provenance = .unknown,
                .pointer_shape = live.pointer_shape,
                .invalidation_reason = reason,
                .invalidation_policy = .invalidate_on_mutation_escape_or_call,
                .source = .{ .line = span.line, .column = span.column },
            });
        }
        self.live_pointer_provenance.clearRetainingCapacity();
    }

    fn recordPointerProvenanceAddressEscape(self: *FunctionBuilder, expr: ast.Expr, span: ast.Span) !void {
        const subject = identBaseName(expr) orelse return;
        var index = self.live_pointer_provenance.items.len;
        while (index > 0) {
            index -= 1;
            const live = self.live_pointer_provenance.items[index];
            if (!std.mem.eql(u8, live.subject, subject)) continue;
            try self.pointer_provenance_facts.append(self.allocator, .{
                .subject = live.subject,
                .element_index = live.element_index,
                .storage = null,
                .provenance = .unknown,
                .pointer_shape = live.pointer_shape,
                .invalidation_reason = .address_escape,
                .invalidation_policy = .invalidate_on_mutation_escape_or_call,
                .source = .{ .line = span.line, .column = span.column },
            });
            _ = self.live_pointer_provenance.orderedRemove(index);
        }
    }

    fn appendPointerProvenanceFact(self: *FunctionBuilder, subject: []const u8, element_index: ?usize, provenance: DirectPointerProvenance, shape: PointerShape, reason: PointerProvenanceInvalidationReason, span: ast.Span) !void {
        try self.pointer_provenance_facts.append(self.allocator, .{
            .subject = subject,
            .element_index = element_index,
            .storage = provenance.storage,
            .provenance = provenance.kind,
            .pointer_shape = shape,
            .invalidation_reason = reason,
            .invalidation_policy = .invalidate_on_mutation_escape_or_call,
            .source = .{ .line = span.line, .column = span.column },
        });
        try self.setLivePointerProvenance(subject, element_index, shape);
    }

    fn appendUnknownPointerProvenanceFact(self: *FunctionBuilder, subject: []const u8, element_index: ?usize, shape: PointerShape, reason: PointerProvenanceInvalidationReason, span: ast.Span) !void {
        try self.pointer_provenance_facts.append(self.allocator, .{
            .subject = subject,
            .element_index = element_index,
            .storage = null,
            .provenance = .unknown,
            .pointer_shape = shape,
            .invalidation_reason = reason,
            .invalidation_policy = .invalidate_on_mutation_escape_or_call,
            .source = .{ .line = span.line, .column = span.column },
        });
        self.clearLivePointerProvenance(subject, element_index);
    }

    fn invalidatePointerProvenanceSubject(self: *FunctionBuilder, subject: []const u8, element_index: ?usize, shape: PointerShape, reason: PointerProvenanceInvalidationReason, span: ast.Span) !void {
        try self.appendUnknownPointerProvenanceFact(subject, element_index, shape, reason, span);
    }

    fn setLivePointerProvenance(self: *FunctionBuilder, subject: []const u8, element_index: ?usize, shape: PointerShape) !void {
        self.clearLivePointerProvenance(subject, element_index);
        try self.live_pointer_provenance.append(self.allocator, .{
            .subject = subject,
            .element_index = element_index,
            .pointer_shape = shape,
        });
    }

    fn clearLivePointerProvenance(self: *FunctionBuilder, subject: []const u8, element_index: ?usize) void {
        var index = self.live_pointer_provenance.items.len;
        while (index > 0) {
            index -= 1;
            const live = self.live_pointer_provenance.items[index];
            if (!std.mem.eql(u8, live.subject, subject)) continue;
            if (element_index) |wanted| {
                if (live.element_index == null or live.element_index.? != wanted) continue;
            }
            _ = self.live_pointer_provenance.orderedRemove(index);
        }
    }

    fn directAddressProvenance(self: *FunctionBuilder, expr: ast.Expr) ?DirectPointerProvenance {
        return switch (expr.kind) {
            .grouped => |inner| self.directAddressProvenance(inner.*),
            .cast => |node| self.directAddressProvenance(node.value.*),
            .address_of => |inner| self.directAddressTargetProvenance(inner.*),
            else => null,
        };
    }

    fn directAddressTargetProvenance(self: *FunctionBuilder, expr: ast.Expr) ?DirectPointerProvenance {
        return switch (expr.kind) {
            .grouped => |inner| self.directAddressTargetProvenance(inner.*),
            .ident => |ident| {
                if (self.globals.contains(ident.text)) return .{ .kind = .global_storage, .storage = ident.text };
                if (self.let_local_names.contains(ident.text) or self.local_types.contains(ident.text)) return .{ .kind = .local_storage, .storage = ident.text };
                return null;
            },
            else => null,
        };
    }

    fn fixedPointerArrayElementShape(self: *FunctionBuilder, ty: ast.TypeExpr) ?PointerShape {
        const normalized = aggregateTargetTypeAlias(ty, self.aliases);
        const array = switch (normalized.kind) {
            .array => |node| node,
            else => return null,
        };
        if (parseArrayLen(array.len, self.const_fns, self.const_globals) == null) return null;
        const child_ty = valueTypeFromTypeAlias(array.child.*, self.enums, self.structs, self.packed_bits, self.aliases);
        return pointerShapeFromValueType(child_ty);
    }

    fn fixedPointerArrayElementShapeForExpr(self: *FunctionBuilder, expr: ast.Expr) ?PointerShape {
        const ty = self.typeExprForExpr(expr) orelse return null;
        return self.fixedPointerArrayElementShape(ty);
    }

    // OPT (annex E) — invalidate every currently-live fact. Called on any write vector that
    // could change a fact operand: an assignment, a new local declaration (possible shadow),
    // or an address-of (aliased future write). Marking (not removing) keeps the scope stack's
    // length invariant intact; a stale-but-invalid fact is simply never used again.
    fn invalidateFacts(self: *FunctionBuilder) void {
        if (!self.optimize) return;
        for (self.proven_facts.items) |*fact| fact.valid = false;
    }

    // OPT (annex E) — record the range facts implied by `cond` being TRUE on this path. Only a
    // strict `<`/`>` comparison, a `!= 0`, or a conjunction of those yields a usable fact, and
    // only when the constrained operand is a bare identifier (so the invalidation vectors above
    // are exhaustive). `<=`/`>=`/`==` and non-ident operands are ignored — a missed fact only
    // costs a kept check, never soundness.
    fn recordTrueCondFacts(self: *FunctionBuilder, cond: ast.Expr) !void {
        if (!self.optimize) return;
        switch (cond.kind) {
            .grouped => |inner| try self.recordTrueCondFacts(inner.*),
            .binary => |b| switch (b.op) {
                .logical_and => {
                    try self.recordTrueCondFacts(b.left.*);
                    try self.recordTrueCondFacts(b.right.*);
                },
                // `a < b`.
                .lt => try self.recordLessThan(b.left.*, b.right.*),
                // `a > b` ≡ `b < a`.
                .gt => try self.recordLessThan(b.right.*, b.left.*),
                // `a != b`: if either side is the literal 0, the other is proven non-zero.
                .ne => {
                    if (isZeroLiteral(b.right.*) and self.factIdentAllowed(b.left.*)) {
                        try self.proven_facts.append(self.allocator, .{ .kind = .nonzero, .a = b.left.* });
                    }
                    if (isZeroLiteral(b.left.*) and self.factIdentAllowed(b.right.*)) {
                        try self.proven_facts.append(self.allocator, .{ .kind = .nonzero, .a = b.right.* });
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    // `lo < hi`: records `lo < hi` (when `lo` is an ident, for bounds elision) and, when `lo`
    // is the literal 0, `hi > 0` (positive, for divisor elision).
    fn recordLessThan(self: *FunctionBuilder, lo: ast.Expr, hi: ast.Expr) !void {
        if (self.factIdentAllowed(lo)) {
            try self.proven_facts.append(self.allocator, .{ .kind = .lt, .a = lo, .b = hi });
        }
        if (isZeroLiteral(lo) and self.factIdentAllowed(hi)) {
            try self.proven_facts.append(self.allocator, .{ .kind = .positive, .a = hi });
        }
    }

    // A fact operand must be a bare identifier whose address is never taken in this function, so
    // the only writes to it are visible assignments/`&`-sites that clear all facts.
    fn factIdentAllowed(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (unwrapGrouped(expr).kind) {
            .ident => |id| !self.address_taken.contains(id.text),
            else => false,
        };
    }

    fn isSimpleIdent(expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => true,
            .grouped => |inner| isSimpleIdent(inner.*),
            else => false,
        };
    }

    fn isZeroLiteral(expr: ast.Expr) bool {
        const v = integerLiteralValue(expr) orelse return false;
        return !v.negative and v.magnitude == 0;
    }

    fn patternIsBoolTrue(pattern: ast.Pattern) bool {
        return switch (pattern.kind) {
            .literal => |expr| switch (unwrapGrouped(expr).kind) {
                .bool_literal => |value| value,
                else => false,
            },
            else => false,
        };
    }

    // Structural equality of two simple place expressions (identifiers and `base.field` chains),
    // by text. Sound because facts only ever hold ident operands, and any binding change to an
    // ident clears all facts, so equal text at a use site denotes the same live value.
    fn sameSimplePlace(a: ast.Expr, b: ast.Expr) bool {
        return switch (a.kind) {
            .grouped => |inner| sameSimplePlace(inner.*, b),
            .ident => |ai| switch (unwrapGrouped(b).kind) {
                .ident => |bi| std.mem.eql(u8, ai.text, bi.text),
                else => false,
            },
            .member => |am| switch (unwrapGrouped(b).kind) {
                .member => |bm| std.mem.eql(u8, am.name.text, bm.name.text) and sameSimplePlace(am.base.*, bm.base.*),
                else => false,
            },
            else => false,
        };
    }

    fn unwrapGrouped(expr: ast.Expr) ast.Expr {
        return switch (expr.kind) {
            .grouped => |inner| unwrapGrouped(inner.*),
            else => expr,
        };
    }

    // The compile-time usize value of a length-bound expression (integer literal or named
    // const), or null when not statically known.
    fn constUsizeValue(self: *FunctionBuilder, expr: ast.Expr) ?usize {
        if (integerLiteralValue(expr)) |v| {
            if (v.negative) return null;
            return std.math.cast(usize, v.magnitude);
        }
        return parseArrayLen(expr, self.const_fns, self.const_globals);
    }

    // `expr` is `base.len` for the same fixed-array place as `base` — so `i < expr` is exactly
    // `i < N` for that array's static length.
    fn isLenMemberOf(expr: ast.Expr, base: ast.Expr) bool {
        return switch (unwrapGrouped(expr).kind) {
            .member => |m| std.mem.eql(u8, m.name.text, "len") and sameSimplePlace(m.base.*, base),
            else => false,
        };
    }

    // OPT (annex E) proof obligation for const-index bounds-check elision: the index is a
    // non-negative integer literal `k`, the base names a fixed array of statically-known
    // length `N`, and `k < N`. All three are compile-time constants, so the bounds check
    // provably never traps. Conservative: returns false for any non-literal index or any
    // base whose length is not statically known (the check is then kept).
    fn indexProvablyInBounds(self: *FunctionBuilder, base: ast.Expr, index: ast.Expr) bool {
        if (integerLiteralValue(index)) |k| {
            if (!k.negative) {
                if (self.baseArrayLen(base)) |n| {
                    if (k.magnitude < n) return true;
                }
            }
        }
        return self.indexInBoundsByFact(base, index);
    }

    // OPT (annex E) — a guard/assert proved `index < B` where `B` is provably `<= N` (the base
    // array's static length): `index < B <= N` ⇒ `index < N`, so the bounds check is dead. `B`
    // is accepted either as a compile-time constant (`i < 16`, `i < CAP`) or as the base's own
    // `.len` member (`i < arr.len`, which for a fixed array is exactly `N`). The index must be a
    // bare identifier; any write to it clears the fact. Fixed arrays only — a slice's length is
    // dynamic and is not consumed by the array-index elision path.
    fn indexInBoundsByFact(self: *FunctionBuilder, base: ast.Expr, index: ast.Expr) bool {
        if (!isSimpleIdent(index)) return false;
        const n = self.baseArrayLen(base) orelse return false;
        for (self.proven_facts.items) |fact| {
            if (!fact.valid or fact.kind != .lt) continue;
            if (!sameSimplePlace(fact.a, index)) continue;
            if (self.constUsizeValue(fact.b)) |bound| {
                if (bound <= n) return true;
            }
            if (isLenMemberOf(fact.b, base)) return true;
        }
        return false;
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
        const signed = isCheckedSignedType(self.exprType(node.left.*));
        if (integerLiteralValue(node.right.*)) |d| {
            if (d.magnitude != 0) {
                if (signed) {
                    // Signed: safe for any non-zero divisor except `-1` (the INT_MIN overflow).
                    if (!(d.negative and d.magnitude == 1)) return true;
                } else {
                    // Unsigned: any non-zero, non-negative literal divisor is safe.
                    if (!d.negative) return true;
                }
            }
        }
        return self.divisorProvablySafeByFact(node.right.*, signed);
    }

    // OPT (annex E) — a guard/assert proved the divisor safe. The backend elides BOTH the
    // divide-by-zero and (for a signed dividend) the INT_MIN/-1 overflow check from one source
    // point, so the proof must cover both: a `positive` fact (`d > 0`) proves `d != 0 && d != -1`
    // and is sufficient for either signedness; a bare `nonzero` fact (`d != 0`) is sufficient
    // only for an unsigned dividend (a signed one could still be `-1`). The divisor must be a
    // bare identifier; any write to it clears the fact.
    fn divisorProvablySafeByFact(self: *FunctionBuilder, divisor: ast.Expr, signed: bool) bool {
        if (!isSimpleIdent(divisor)) return false;
        for (self.proven_facts.items) |fact| {
            if (!fact.valid) continue;
            if (!sameSimplePlace(fact.a, divisor)) continue;
            switch (fact.kind) {
                .positive => return true,
                .nonzero => if (!signed) return true,
                .lt => {},
            }
        }
        return false;
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
        const member = memberExpr(callee) orelse return null;
        const ident_name = calleeIdentName(member.base.*) orelse return null;
        if (self.local_types.contains(ident_name) or self.globals.contains(ident_name)) return null;
        const op = member.name.text;
        const ident = ast.Ident{ .text = ident_name, .span = member.base.*.span };
        const name_ty = ast.TypeExpr{ .span = ident.span, .kind = .{ .name = ident } };
        if (arithmeticDomainTypeAlias(name_ty, self.aliases)) |domain| {
            return switch (domain) {
                .serial => if (!isMirSerialOpName(op) and !isMirConversionName(op)) "serial_operation" else null,
                .counter => if (!isMirCounterOpName(op) and !isMirConversionName(op)) "counter_operation" else null,
                .wrap, .sat => if (!isMirConversionName(op)) "conversion_operation" else null,
            };
        }
        if (self.resolvesToScalarInt(ident_name, 0) and !isMirConversionName(op)) return "conversion_operation";
        return null;
    }

    // D-pass operation legality for typed-resource calls: unknown atomic method
    // on an atomic value, and `.raw()` on a closed enum.
    fn typedResourceCallFinding(self: *FunctionBuilder, callee: ast.Expr) ?[]const u8 {
        const member = memberExpr(callee) orelse return null;
        const m = member.name.text;
        if (self.typeExprForExpr(member.base.*)) |base_ty| {
            if (isAtomicTypeExprAlias(base_ty, self.aliases)) {
                if (!std.mem.eql(u8, m, "load") and !std.mem.eql(u8, m, "store") and !std.mem.eql(u8, m, "fetch_add") and !std.mem.eql(u8, m, "fetch_sub")) return "atomic_operation";
                return null;
            }
        }
        // `.raw()` reads the representation ordinal out; it is safe on both open and
        // closed enums (reading can never mint an out-of-range enum value), so no
        // usage-check finding is emitted here for either enum flavor.
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
        const member = memberExpr(callee) orelse return null;
        if (!exprIsIdentNamed(member.base.*, "cache")) return null;
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
            // Member access whose base is a POINTER auto-derefs (`p.f` == `p->f`), so the
            // address points into the POINTED-TO storage, not this frame — not a local
            // escape (G14). Mirrors sema's placeGoesThroughPointer.
            .member => |node| if (self.baseGoesThroughPointer(node.base.*)) false else self.escapeStorageRoot(node.base.*),
            .index => |node| self.indexedArrayStorageRoot(node.base.*),
            .slice => |node| self.indexedArrayStorageRoot(node.base.*),
            .grouped => |inner| self.escapeStorageRoot(inner.*),
            else => false,
        };
    }

    // Whether reaching a place through `expr` dereferences a POINTER (`.field`/`[i]` on a
    // pointer-typed base auto-derefs). Taking such an address points into pointed-to
    // storage that outlives this frame, so it is never a local-storage-escape root.
    fn baseGoesThroughPointer(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (self.exprType(expr)) {
            .pointer, .nullable_pointer => true,
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
                // A `*dyn Trait` method call dispatches virtually to the trait method; its return
                // type is the trait's, which the verifier does not carry. Resolve to `null`
                // (unknown) rather than a same-named free function's summary return type.
                (if (self.isDynDispatchMember(node.callee.*)) null else if (self.summaries.get(self.calleeName(node.callee.*))) |summary| summary.return_type_expr else null),
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
            else if (self.isDynDispatchMember(node.callee.*))
                .unknown
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
        const member = memberExpr(callee) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        return self.typeExprForExpr(member.base.*);
    }

    fn ptrOffsetReceiverType(self: *FunctionBuilder, callee: ast.Expr) ?ValueType {
        const member = memberExpr(callee) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        const base_ty = self.exprType(member.base.*);
        return if (isRawManyPointerValue(base_ty)) base_ty else null;
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
    allocator.free(function.pointer_provenance_facts);
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

fn uncheckedAssumeHasMatchingContract(function: Function, instruction: Instruction) bool {
    const region_id = instruction.contract_region_id orelse return false;
    for (function.contract_regions) |region| {
        if (region.id != region_id) continue;
        return contractAllowsUnchecked(region.kind, instruction.detail);
    }
    return false;
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

fn switchArmBodiesHandleResultLocal(self: *FunctionBuilder, name: []const u8, node: ast.Switch) bool {
    for (node.arms) |arm| {
        switch (arm.body) {
            .block => |body| if (self.blockHandlesResultLocal(name, body)) return true,
            .expr => |expr| if (self.exprHandlesResultLocal(name, expr)) return true,
        }
    }
    return false;
}

fn mmioMapPayloadTypeForExpr(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| mmioMapCallPayloadType(call),
        .grouped => |inner| mmioMapPayloadTypeForExpr(inner.*),
        else => null,
    };
}

fn reduceCallReturnTypeExpr(call: anytype) ?ast.TypeExpr {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    if (call.type_args.len != 1) return null;
    return switch (kind) {
        .sum_checked => null,
        .sum_left, .sum_fast => call.type_args[0],
    };
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

// bitcast operands must have a fixed scalar/pointer/address layout (section 15);
// `.unknown` is treated as valid to avoid false positives.
fn isMirBitcastLayout(ty: ValueType) bool {
    return switch (ty) {
        .integer, .float, .bool, .cstr, .pointer, .nullable_pointer, .address, .unknown => true,
        else => false,
    };
}

fn isMirBitcastCallee(callee: ast.Expr) bool {
    const name = calleeIdentName(callee) orelse return false;
    return std.mem.eql(u8, name, "bitcast");
}

fn isMirMmioReadOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire");
}

fn isMirMmioWriteOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "release");
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
    if (memberExpr(callee)) |member| {
        const base_name = calleeIdentName(member.base.*) orelse return false;
        return std.mem.eql(u8, base_name, "unchecked") or
            (std.mem.eql(u8, base_name, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked"));
    }
    const name = calleeIdentName(callee) orelse return false;
    return std.mem.startsWith(u8, name, "unchecked_") or std.mem.eql(u8, name, "assume_noalias_unchecked");
}

fn isUnsafeOperationCall(callee: ast.Expr) bool {
    const member = memberExpr(callee) orelse return false;
    if (exprIsIdentNamed(member.base.*, "raw") and std.mem.eql(u8, member.name.text, "store")) return true;
    if (exprIsIdentNamed(member.base.*, "mmio") and std.mem.eql(u8, member.name.text, "map")) return true;
    return false;
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
        std.mem.startsWith(u8, name, "atomic_") or
        // Pure compiler builtins that emit no blocking work and no call: `phys`/`pa`
        // construct an address (an integer cast), `drop`/`forget_unchecked`
        // evaluate-and-discard a value (no destructor). All are legal on an
        // #[irq_context] path — sema already accepts them; the MIR verifier must agree.
        std.mem.eql(u8, name, "phys") or
        std.mem.eql(u8, name, "pa") or
        std.mem.eql(u8, name, "drop") or
        std.mem.eql(u8, name, "forget_unchecked");
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
    const member = memberExpr(callee) orelse return .not_builtin;
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

fn pointerShapeFromValueType(ty: ValueType) ?PointerShape {
    return switch (ty) {
        .pointer => |shape| shape,
        .nullable_pointer => |shape| if (isNullPointerShape(shape)) null else shape,
        else => null,
    };
}

fn arrayLiteralItems(expr: ast.Expr) ?[]ast.Expr {
    return switch (expr.kind) {
        .array_literal => |items| items,
        .grouped => |inner| arrayLiteralItems(inner.*),
        .cast => |node| arrayLiteralItems(node.value.*),
        else => null,
    };
}

fn constIndexValue(expr: ast.Expr) ?usize {
    const value = integerLiteralValue(expr) orelse return null;
    if (value.negative or value.magnitude > std.math.maxInt(usize)) return null;
    return @intCast(value.magnitude);
}

fn constantIndexAssignmentTarget(expr: ast.Expr) ?IndexedAssignmentTarget {
    return switch (expr.kind) {
        .grouped => |inner| constantIndexAssignmentTarget(inner.*),
        .index => |node| {
            const subject = switch (node.base.kind) {
                .ident => |ident| ident.text,
                .grouped => |inner| exprBaseIdentName(inner.*) orelse return null,
                else => return null,
            };
            const index = constIndexValue(node.index.*) orelse return null;
            return .{ .subject = subject, .base = node.base.*, .index = index };
        },
        else => null,
    };
}

fn dynamicIndexAssignmentSubject(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| dynamicIndexAssignmentSubject(inner.*),
        .index => |node| if (constIndexValue(node.index.*) == null) exprBaseIdentName(node.base.*) else null,
        else => null,
    };
}

fn exprBaseIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| exprBaseIdentName(inner.*),
        .member => |node| exprBaseIdentName(node.base.*),
        .index => |node| exprBaseIdentName(node.base.*),
        .deref => |inner| exprBaseIdentName(inner.*),
        else => null,
    };
}

fn isKnownDirectPrimitive(name: []const u8) bool {
    return isKnownNoLanguageTrapPrimitive(name) or
        std.mem.startsWith(u8, name, "unchecked.") or
        std.mem.startsWith(u8, name, "unchecked_") or
        std.mem.eql(u8, name, "compiler.assume_noalias_unchecked") or
        std.mem.eql(u8, name, "assume_noalias_unchecked");
}

fn contractBlockEndLine(block: ast.Block) usize {
    if (block.items.len == 0) return block.span.line;
    return block.items[block.items.len - 1].span.line;
}
