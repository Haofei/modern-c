const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const diagnostics = @import("diagnostics.zig");
const error_from = @import("error_from.zig");
const eval = @import("eval.zig");
const switch_lower = @import("switch_lower.zig");
const mir = @import("mir.zig");
const sema_type = @import("sema_type.zig");

// Pure AST-shape queries shared with sema/mir/lower_c (see `ast_query.zig`); aliased so the
// existing call sites read unchanged.
const isIdentNamed = ast_query.isIdentNamed;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const typeName = ast_query.typeName;
const ByteViewCallKind = ast_query.ByteViewCallKind;
const byteViewCallKind = ast_query.byteViewCallKind;
const byteViewCallReturnType = ast_query.byteViewCallReturnType;
const reflectionValueCallReturnType = ast_query.reflectionValueCallReturnType;
const constGetCallTarget = ast_query.constGetCallTarget;
const byteViewAddressTarget = ast_query.byteViewAddressTarget;
const calleeIdentName = ast_query.calleeIdentName;
const memberExpr = ast_query.memberExpr;
const indexExpr = ast_query.indexExpr;
const vaCallMember = ast_query.vaCallMember;
const vaCallReturnType = ast_query.vaCallReturnType;
const isVaStartCall = ast_query.isVaStartCall;
const isOpaqueAddressTypeName = ast_query.isOpaqueAddressTypeName;
const isStringLiteralTarget = ast_query.isStringLiteralTarget;
const isMmioStructAbi = ast_query.isMmioStructAbi;
const overlayByteArrayElementType = ast_query.overlayByteArrayElementType;
const overlayArrayElementType = ast_query.overlayArrayElementType;
const overlayMemberFromIndexBase = ast_query.overlayMemberFromIndexBase;
const taggedUnionCase = ast_query.taggedUnionCase;
const qualifiedTaggedUnionConstructorType = ast_query.qualifiedTaggedUnionConstructorType;
const enumVariantPathType = ast_query.enumVariantPathType;

const backend_mod = @import("backend.zig");
const lower_llvm_alias = @import("lower_llvm_alias.zig");
const lower_llvm_lookup = @import("lower_llvm_lookup.zig");
const lower_llvm_shape = @import("lower_llvm_shape.zig");

// Phase-2c split: pure type-mapping/classification helpers moved verbatim to
// `lower_llvm_type.zig`. Re-exported here so call sites read unchanged.
const lower_llvm_type = @import("lower_llvm_type.zig");
const simpleType = lower_llvm_type.simpleType;
const isDynTraitLlvmType = lower_llvm_type.isDynTraitLlvmType;
const alignForward = lower_llvm_type.alignForward;
const isPointerWidthIntegerTypeName = lower_llvm_type.isPointerWidthIntegerTypeName;
const isOpaqueAddressGenericName = lower_llvm_type.isOpaqueAddressGenericName;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;
const libraryScalarLlvmType = lower_llvm_type.libraryScalarLlvmType;
const typeNameEql = lower_llvm_type.typeNameEql;
const secretInnerType = lower_llvm_type.secretInnerType;
const constGetIndexArg = lower_llvm_type.constGetIndexArg;
const rawScalarTypeName = lower_llvm_type.rawScalarTypeName;
const parseU64Literal = lower_llvm_type.parseU64Literal;
const integerBits = lower_llvm_type.integerBits;
const isSignedInteger = lower_llvm_type.isSignedInteger;
const isFloatType = lower_llvm_type.isFloatType;
const signedMinLiteral = lower_llvm_type.signedMinLiteral;
const intrinsicBits = lower_llvm_type.intrinsicBits;

// Phase-2c split: operator/predicate spelling, trap-helper, and literal
// normalization helpers moved verbatim to `lower_llvm_op.zig`. Re-exported
// here so call sites read unchanged.
const lower_llvm_op = @import("lower_llvm_op.zig");
const binaryIsComparison = lower_llvm_op.binaryIsComparison;
const comparisonPredicate = lower_llvm_op.comparisonPredicate;
const floatComparisonPredicate = lower_llvm_op.floatComparisonPredicate;
const wrappingBuiltinOp = lower_llvm_op.wrappingBuiltinOp;
const uncheckedBuiltinOp = lower_llvm_op.uncheckedBuiltinOp;
const trapHelperForCall = lower_llvm_op.trapHelperForCall;
const trapHelperForKind = lower_llvm_op.trapHelperForKind;
const normalizedIntLiteral = lower_llvm_op.normalizedIntLiteral;
const normalizedFloatLiteral = lower_llvm_op.normalizedFloatLiteral;
const charLiteralValue = lower_llvm_op.charLiteralValue;

// LLVM module prelude emission and target metadata.
const lower_llvm_prelude = @import("lower_llvm_prelude.zig");
const emitTrapDecl = lower_llvm_prelude.emitTrapDecl;
const emitTargetTypeDecls = lower_llvm_prelude.emitTargetTypeDecls;
const isKsanHook = lower_llvm_prelude.isKsanHook;
const llvmTargetDataLayout = lower_llvm_prelude.targetDataLayout;
const llvmTargetTriple = lower_llvm_prelude.targetTriple;

// LLVM textual escaping, inline-asm spelling, debug line normalization, and
// declaration attribute helpers.
const lower_llvm_text = @import("lower_llvm_text.zig");
const debugColumn = lower_llvm_text.debugColumn;
const debugLine = lower_llvm_text.debugLine;
const effectiveAlign = lower_llvm_text.effectiveAlign;
const escapedLlvmString = lower_llvm_text.escapedLlvmString;
const hasNakedAttr = lower_llvm_text.hasNakedAttr;
const hasNoinlineAttr = lower_llvm_text.hasNoinlineAttr;
const hasWeakAttr = lower_llvm_text.hasWeakAttr;
const llvmAsmClobbers = lower_llvm_text.llvmAsmClobbers;
const llvmOpaqueAsmTemplate = lower_llvm_text.llvmOpaqueAsmTemplate;
const llvmPreciseAsmConstraints = lower_llvm_text.llvmPreciseAsmConstraints;
const llvmPreciseAsmTemplate = lower_llvm_text.llvmPreciseAsmTemplate;
const llvmStringLiteralBytes = lower_llvm_text.llvmStringLiteralBytes;
const sectionAttr = lower_llvm_text.sectionAttr;

// LLVM backend AST/call-shape queries and small pure lowering helpers.
const lower_llvm_query = @import("lower_llvm_query.zig");
const assignmentIdent = lower_llvm_query.assignmentIdent;
const builtinCallReturnType = lower_llvm_query.builtinCallReturnType;
const comptimeStructFieldValue = lower_llvm_query.comptimeStructFieldValue;
const derefTarget = lower_llvm_query.derefTarget;
const implMethodMangledLlvm = lower_llvm_query.implMethodMangledLlvm;
const isAssumeNoaliasCall = lower_llvm_query.isAssumeNoaliasCall;
const isBindCallExpr = ast_query.isBindCallExpr;
const isBindCallNode = ast_query.isBindCallNode;
const isDeclassifyCall = ast_query.isDeclassifyCall;
const isDropCall = lower_llvm_query.isDropCall;
const resultConstructorCallTag = ast_query.resultConstructorCallTag;
const isUninitExpr = lower_llvm_query.isUninitExpr;
const llvmTraitIsObjectSafe = lower_llvm_query.llvmTraitIsObjectSafe;
const memberCallee = lower_llvm_query.memberCallee;
const packedBitsClearMask = lower_llvm_query.packedBitsClearMask;
const packedBitsMask = lower_llvm_query.packedBitsMask;
const structFieldIndex = lower_llvm_query.structFieldIndex;
const structLiteralField = lower_llvm_query.structLiteralField;
const taggedUnionConstructorName = lower_llvm_query.taggedUnionConstructorName;
const traitMethodIndex = lower_llvm_query.traitMethodIndex;

// LLVM backend model records used by the emitter implementation.
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_reflect = @import("lower_llvm_reflect.zig");
const LlvmReflectEnv = lower_llvm_reflect.ReflectEnv;

// Phase-2c split: atomic-ordering & fence helpers moved verbatim to
// `lower_llvm_atomic.zig`. Re-exported here so call sites read unchanged.
const lower_llvm_atomic = @import("lower_llvm_atomic.zig");
const AtomicOrderContext = lower_llvm_atomic.AtomicOrderContext;
const atomicOrderingArg = lower_llvm_atomic.atomicOrderingArg;
const atomicOrderingExpr = lower_llvm_atomic.atomicOrderingExpr;
const orderingArg = lower_llvm_atomic.orderingArg;
const atomicLlvmOrdering = lower_llvm_atomic.atomicLlvmOrdering;
const isAtomicInitCall = lower_llvm_atomic.isAtomicInitCall;
const isAtomicInitExpr = lower_llvm_atomic.isAtomicInitExpr;
const atomicInitValue = lower_llvm_atomic.atomicInitValue;
const LocalSlot = lower_llvm_model.LocalSlot;
const LocalSlotKind = lower_llvm_model.LocalSlotKind;
const FnSig = lower_llvm_model.FnSig;
const BindThunk = lower_llvm_model.BindThunk;
const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const OverlayUnionInfo = lower_llvm_model.OverlayUnionInfo;
const OverlayLayout = lower_llvm_model.OverlayLayout;
const TaggedUnionLayout = lower_llvm_model.TaggedUnionLayout;
const MmioFieldInfo = lower_llvm_model.MmioFieldInfo;
const MmioAccessInfo = lower_llvm_model.MmioAccessInfo;
const MmioFencePlacement = lower_llvm_model.MmioFencePlacement;
const DmaBufInfo = lower_llvm_model.DmaBufInfo;
const DmaBufCallInfo = lower_llvm_model.DmaBufCallInfo;
const DmaCacheCallInfo = lower_llvm_model.DmaCacheCallInfo;
const ArgValue = lower_llvm_model.ArgValue;
const StringLiteralGlobal = lower_llvm_model.StringLiteralGlobal;
const DebugFunction = lower_llvm_model.DebugFunction;
const DebugLocation = lower_llvm_model.DebugLocation;
const DebugLocal = lower_llvm_model.DebugLocal;
const DebugLocalKind = lower_llvm_model.DebugLocalKind;
const LoopLabels = lower_llvm_model.LoopLabels;
const RawManyOffsetInfo = lower_llvm_model.RawManyOffsetInfo;
const EnumRawCallInfo = lower_llvm_model.EnumRawCallInfo;
const DomainResidueCallInfo = lower_llvm_model.DomainResidueCallInfo;
const DomainOpCallInfo = lower_llvm_model.DomainOpCallInfo;
const ConversionCallInfo = lower_llvm_model.ConversionCallInfo;
const ReduceCallInfo = lower_llvm_model.ReduceCallInfo;
const ConstGetCallInfo = lower_llvm_model.ConstGetCallInfo;
const IntRange = lower_llvm_model.IntRange;
const AtomicCallInfo = lower_llvm_model.AtomicCallInfo;
const MaybeUninitCallInfo = lower_llvm_model.MaybeUninitCallInfo;
const ResultTypeInfo = lower_llvm_model.ResultTypeInfo;

const DebugBasicType = struct {
    name: []const u8,
    size_bits: u16,
    encoding: []const u8,
};

const LocalSlicePointerArrayRange = struct {
    start: u64,
    end: u64,
    start_exact: bool,
};

const AggregatePointerFieldPath = struct {
    local_name: []const u8,
    field_path: []const u8,
};

const LocalArrayPointerElementPath = struct {
    local_name: []const u8,
    index: u64,
};

const LocalSlicePointerArrayBase = struct {
    name: []const u8,
    range: LocalSlicePointerArrayRange,
};

const LocalSliceAggregatePointerArrayBase = struct {
    path: AggregatePointerFieldPath,
    range: LocalSlicePointerArrayRange,
};

/// Construct the `Backend` registry entry for the LLVM backend. The LLVM
/// backend is profile-agnostic and has no source-map artifact.
pub fn mcBackend() backend_mod.Backend {
    return .{
        .name = "llvm",
        .artifact_ext = ".ll",
        .supports_profiles = false,
        .ctx = undefined,
        .lowerFn = backendLower,
    };
}

fn backendLower(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    module: ast.Module,
    out: *std.ArrayList(u8),
    opts: backend_mod.LowerOptions,
) anyerror!void {
    _ = ctx;
    try appendLlvmCheckedReport(allocator, module, out, opts.source_path orelse "input.mc", opts.checks, opts.stub_asm, opts.target_arch, opts.reporter);
}

pub fn appendLlvm(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    try appendLlvmWithSourcePath(allocator, module, out, "input.mc", false);
}

pub fn appendLlvmWithSourcePath(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), source_path: []const u8, optimize: bool) !void {
    try appendLlvmChecked(allocator, module, out, source_path, .{ .optimize = optimize }, false, .riscv64);
}

pub fn appendLlvmChecked(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target_arch: backend_mod.TargetArch) !void {
    try appendLlvmCheckedReport(allocator, module, out, source_path, checks, stub_asm, target_arch, null);
}

fn appendLlvmCheckedReport(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target_arch: backend_mod.TargetArch, reporter: ?*diagnostics.Reporter) !void {
    const optimize = checks.optimize;
    var module_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
    defer module_mir.deinit();
    try appendLlvmCheckedMir(allocator, module, &module_mir, out, source_path, checks, stub_asm, target_arch, reporter);
}

pub fn appendLlvmCheckedMir(allocator: std.mem.Allocator, module: ast.Module, module_mir: *const mir.Module, out: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target_arch: backend_mod.TargetArch, reporter: ?*diagnostics.Reporter) !void {
    try mir.validateRepresentationFactsForLowering(module_mir.*);
    try mir.validateIntegerFactsForLowering(module_mir.*);
    try mir.validateCallTargetFactsForLowering(module_mir.*);
    try mir.validateTargetTypeFactsForLowering(module_mir.*);
    const ksan = checks.ksan;
    const msan = checks.msan;
    const csan = checks.csan;
    const escaped_source_path = try escapedLlvmString(allocator, source_path);
    defer allocator.free(escaped_source_path);
    try out.print(allocator, "source_filename = \"{s}\"\n", .{escaped_source_path});
    try out.print(allocator, "target datalayout = \"{s}\"\n", .{llvmTargetDataLayout(target_arch)});
    try out.print(allocator, "target triple = \"{s}\"\n", .{llvmTargetTriple(target_arch)});
    try out.appendSlice(allocator, "; MC LLVM IR backend v0\n");
    try out.appendSlice(allocator, "; semantic checks: sema + MIR policy/CFG verification\n\n");
    try emitTargetTypeDecls(allocator, out, target_arch);
    try emitTrapDecl(allocator, out, module);

    var ctx = LlvmEmitter{
        .allocator = allocator,
        .out = out,
        .mir_module = module_mir.*,
        .scratch = std.heap.ArenaAllocator.init(allocator),
        .need_uadd = std.StringHashMap(void).init(allocator),
        .need_usub = std.StringHashMap(void).init(allocator),
        .need_umul = std.StringHashMap(void).init(allocator),
        .need_sadd = std.StringHashMap(void).init(allocator),
        .need_ssub = std.StringHashMap(void).init(allocator),
        .need_smul = std.StringHashMap(void).init(allocator),
        .const_fns = std.StringHashMap(ast.FnDecl).init(allocator),
        .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
        .const_global_widths = std.StringHashMap(u16).init(allocator),
        .type_aliases = std.StringHashMap(ast.TypeExpr).init(allocator),
        .enum_types = std.StringHashMap(ast.EnumDecl).init(allocator),
        .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
        .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
        .tagged_unions = std.StringHashMap(ast.UnionDecl).init(allocator),
        .struct_types = std.StringHashMap(ast.StructDecl).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .trait_decls = std.StringHashMap(ast.TraitDecl).init(allocator),
        .impl_methods = std.StringHashMap([]const ast.ImplTraitMethod).init(allocator),
        .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
        .backend_names = std.StringHashMap([]const u8).init(allocator),
        .global_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .global_initializers = std.StringHashMap(ast.Expr).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
        .pointer_local_provenance = std.StringHashMap(mir.PointerProvenance).init(allocator),
        .local_function_pointer_aliases = std.StringHashMap([]const u8).init(allocator),
        .local_aggregate_pointer_aliases = std.StringHashMap([]const u8).init(allocator),
        .local_pointer_array_aliases = std.StringHashMap([]const u8).init(allocator),
        .aggregate_global_pointer_fields = std.StringHashMap(mir.PointerProvenance).init(allocator),
        .local_array_global_pointer_elements = std.StringHashMap(mir.PointerProvenance).init(allocator),
        .local_slice_global_pointer_arrays = std.StringHashMap([]const u8).init(allocator),
        .local_slice_pointer_array_ranges = std.StringHashMap(LocalSlicePointerArrayRange).init(allocator),
        .local_slice_aggregate_pointer_array_fields = std.StringHashMap([]const u8).init(allocator),
        .aggregate_return_pointer_fields = std.StringHashMap(mir.PointerProvenance).init(allocator),
        .loop_stack = std.ArrayList(LoopLabels).empty,
        .defer_stack = std.ArrayList(ast.Expr).empty,
        .string_literals = std.ArrayList(StringLiteralGlobal).empty,
        .debug_functions = std.ArrayList(DebugFunction).empty,
        .debug_locations = std.ArrayList(DebugLocation).empty,
        .debug_locals = std.ArrayList(DebugLocal).empty,
        .source_path = source_path,
        .target_arch = target_arch,
        .reporter = reporter,
        .ksan = ksan,
        .msan = msan,
        .csan = csan,
        .stub_asm = stub_asm,
    };
    defer ctx.deinit();
    for (module.decls) |decl| {
        if (decl.kind == .fn_decl) {
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.is_const and !ctx.const_fns.contains(fn_decl.name.text)) try ctx.const_fns.put(fn_decl.name.text, fn_decl);
            for (decl.attrs) |attr| switch (attr.kind) {
                .backend_name => |name| try ctx.backend_names.put(fn_decl.name.text, name),
                else => {},
            };
        }
    }
    try ctx.preRegisterTypeDecls(module);
    var reflect_env = ctx.reflectEnv();
    try eval.collectConstGlobalsWithOptions(allocator, module, &ctx.const_fns, &ctx.const_globals, .{
        .reflect = lower_llvm_reflect.comptimeReflectThunk,
        .reflect_ctx = &reflect_env,
    });
    try ctx.collectConstGlobalWidths(module);
    for (module.decls) |decl| {
        switch (decl.kind) {
            .packed_bits_decl => |packed_bits| try ctx.collectPackedBits(packed_bits),
            .overlay_union_decl => |overlay_union| try ctx.collectOverlayUnion(overlay_union),
            .union_decl => |union_decl| try ctx.collectTaggedUnion(union_decl),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .type_alias => |alias| try ctx.collectTypeAlias(alias),
            .enum_decl => |enum_decl| try ctx.collectEnum(enum_decl),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .struct_decl => |struct_decl| try ctx.collectStruct(struct_decl),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| try ctx.collectFunction(fn_decl, decl.attrs),
            .extern_fn => |fn_decl| try ctx.collectFunction(fn_decl, decl.attrs),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .global_decl => |global| try ctx.collectGlobal(global),
            .trait_decl => |t| try ctx.trait_decls.put(t.name.text, t),
            .impl_trait => |it| {
                const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ it.trait_name.text, it.type_name.text });
                try ctx.impl_methods.put(key, it.methods);
            },
            else => {},
        }
    }
    try ctx.collectMirAggregateReturnPointerFieldFacts();
    // Tier 2: one rodata vtable global per `impl Trait for Type` of an object-safe
    // trait. Function pointers may be forward-referenced in LLVM IR, so this can run
    // before the function bodies are emitted.
    try ctx.emitVtables();
    for (module.decls) |decl| {
        switch (decl.kind) {
            .global_decl => |global| try ctx.emitGlobal(global),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| if (fn_decl.body) |body| try ctx.emitFunction(fn_decl, body, decl.attrs),
            .extern_fn => |fn_decl| try ctx.emitExternFunction(fn_decl),
            else => {},
        }
    }
    // Scalar-env closure thunks discovered while emitting bodies. LLVM IR allows
    // forward references to these `@mc_envthunk_*` symbols, so emitting them after
    // the function bodies is fine.
    try ctx.emitBindThunks();
    try ctx.emitBackendNameAliases(module);
    try ctx.emitStringLiteralGlobals();
    try ctx.emitIntrinsicDecls();
    try ctx.emitDebugMetadata();
}

const LlvmEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mir_module: mir.Module,
    scratch: std.heap.ArenaAllocator,
    temp_index: usize = 0,
    trap_index: usize = 0,
    need_uadd: std.StringHashMap(void) = undefined,
    need_usub: std.StringHashMap(void) = undefined,
    need_umul: std.StringHashMap(void) = undefined,
    need_sadd: std.StringHashMap(void) = undefined,
    need_ssub: std.StringHashMap(void) = undefined,
    need_smul: std.StringHashMap(void) = undefined,
    const_fns: std.StringHashMap(ast.FnDecl) = undefined,
    const_globals: std.StringHashMap(eval.ComptimeValue) = undefined,
    const_global_widths: std.StringHashMap(u16) = undefined,
    type_aliases: std.StringHashMap(ast.TypeExpr) = undefined,
    enum_types: std.StringHashMap(ast.EnumDecl) = undefined,
    packed_bits: std.StringHashMap(PackedBitsInfo) = undefined,
    overlay_unions: std.StringHashMap(OverlayUnionInfo) = undefined,
    tagged_unions: std.StringHashMap(ast.UnionDecl) = undefined,
    struct_types: std.StringHashMap(ast.StructDecl) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    // Tier 2 trait objects (traits-design §8): every `trait` by name (vtable layout +
    // dispatch slot resolution) and each `impl Trait for Type`'s mangled methods (the
    // rodata vtable's function-pointer list).
    trait_decls: std.StringHashMap(ast.TraitDecl) = undefined,
    impl_methods: std.StringHashMap([]const ast.ImplTraitMethod) = undefined,
    // `bind(scalar, f)` closures whose env is a non-pointer integer scalar. The
    // closure's env slot is `ptr`, so the scalar is widened via `inttoptr` and the
    // code pointer points at a generated thunk that narrows it back with `ptrtoint`
    // before calling `f`. Keyed by target function name.
    bind_thunks: std.StringHashMap(BindThunk) = undefined,
    // Source function name -> `#[backend_name("Y")]` override; emitted as a module-level
    // alias `@Y = alias <fnty>, ptr @name` so the override symbol is linkable (the C backend
    // achieves the same via an asm label).
    backend_names: std.StringHashMap([]const u8) = undefined,
    global_types: std.StringHashMap(ast.TypeExpr) = undefined,
    global_initializers: std.StringHashMap(ast.Expr) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,
    // Proven storage class per pointer-typed local: .global_storage entries feed
    // the visible-global provenance ladders; .local_storage entries are the
    // positive locality proof that gates PLAIN deref lowering (spec §I.13 —
    // absent/unknown pointers lower race-tolerantly). Sourced from live MIR
    // pointer-provenance facts plus the syntactic global inference ladder.
    pointer_local_provenance: std.StringHashMap(mir.PointerProvenance) = undefined,
    local_function_pointer_aliases: std.StringHashMap([]const u8) = undefined,
    local_aggregate_pointer_aliases: std.StringHashMap([]const u8) = undefined,
    local_pointer_array_aliases: std.StringHashMap([]const u8) = undefined,
    aggregate_global_pointer_fields: std.StringHashMap(mir.PointerProvenance) = undefined,
    local_array_global_pointer_elements: std.StringHashMap(mir.PointerProvenance) = undefined,
    local_slice_global_pointer_arrays: std.StringHashMap([]const u8) = undefined,
    local_slice_pointer_array_ranges: std.StringHashMap(LocalSlicePointerArrayRange) = undefined,
    local_slice_aggregate_pointer_array_fields: std.StringHashMap([]const u8) = undefined,
    aggregate_return_pointer_fields: std.StringHashMap(mir.PointerProvenance) = undefined,
    // While a function body is being emitted, `entry_allocas` collects every `alloca`
    // so they land at the TOP of the entry block (the LLVM rule: an alloca in a non-entry
    // block — e.g. a loop body — is a DYNAMIC stack allocation that grows the stack every
    // iteration and is never reclaimed until the function returns). Routing all allocas to
    // the entry block makes them static, so the slot is reused across iterations. Null
    // outside a function body, in which case `emitAlloca` falls back to streaming inline.
    entry_allocas: ?*std.ArrayList(u8) = null,
    loop_stack: std.ArrayList(LoopLabels) = undefined,
    defer_stack: std.ArrayList(ast.Expr) = undefined,
    string_literals: std.ArrayList(StringLiteralGlobal) = undefined,
    debug_functions: std.ArrayList(DebugFunction) = undefined,
    debug_locations: std.ArrayList(DebugLocation) = undefined,
    debug_locals: std.ArrayList(DebugLocal) = undefined,
    debug_next_id: usize = 6,
    need_dbg_declare: bool = false,
    need_dbg_value: bool = false,
    current_debug_scope: ?usize = null,
    current_debug_span: ?ast.Span = null,
    current_return_ty: ?ast.TypeExpr = null,
    current_function: ?[]const u8 = null,
    current_mir_range_target: ?[]const u8 = null,
    source_path: []const u8,
    target_arch: backend_mod.TargetArch,
    reporter: ?*diagnostics.Reporter = null,
    // KASAN profile (D2.1): when true, each raw.load/raw.store emits a
    // `call void @mc_ksan_check(i64 addr, i64 size)` before the volatile access, so a
    // poisoned (freed/redzone) access traps at access time. Default false = no hook call.
    ksan: bool = false,
    // KMSAN profile (D2.2, implies ksan): raw.store calls @mc_ksan_store before the volatile
    // store. The runtime hook rejects poison/freed bytes, tolerates UNINIT/CLEAN bytes, and
    // marks the range initialized before the write.
    msan: bool = false,
    // KCSAN profile (D2.3): when true, each unsynchronized raw.store/raw.load brackets the
    // volatile access with a `call void @mc_csan_write/@mc_csan_read(i64 addr, i64 size)`
    // watchpoint hook. Mutually exclusive with ksan/msan (main.zig enforces this). The C
    // backend's csan path is mirrored here so KCSAN is sound on the LLVM backend too.
    csan: bool = false,
    // `--stub-asm` (test-only): replace each inline-asm block with a host-neutral stub so an
    // arch module's portable logic can be compiled/run host-natively (where the host assembler
    // cannot encode the target ISA). Default false → asm is emitted verbatim. Mirrors the C
    // backend so llvm-* host-native logic tests behave identically.
    stub_asm: bool = false,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.const_fns.deinit();
        self.const_global_widths.deinit();
        eval.deinitConstGlobals(self.allocator, &self.const_globals);
        self.type_aliases.deinit();
        self.enum_types.deinit();
        self.packed_bits.deinit();
        self.overlay_unions.deinit();
        self.tagged_unions.deinit();
        self.struct_types.deinit();
        self.fn_sigs.deinit();
        self.trait_decls.deinit();
        {
            var it = self.impl_methods.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
        }
        self.impl_methods.deinit();
        self.bind_thunks.deinit();
        self.backend_names.deinit();
        self.global_types.deinit();
        self.global_initializers.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.pointer_local_provenance.deinit();
        self.local_function_pointer_aliases.deinit();
        self.local_aggregate_pointer_aliases.deinit();
        self.local_pointer_array_aliases.deinit();
        self.deinitOwnedStringProvenanceMap(&self.aggregate_global_pointer_fields);
        self.deinitOwnedStringProvenanceMap(&self.local_array_global_pointer_elements);
        self.local_slice_global_pointer_arrays.deinit();
        self.local_slice_pointer_array_ranges.deinit();
        self.deinitOwnedStringValueMap(&self.local_slice_aggregate_pointer_array_fields);
        self.deinitOwnedStringProvenanceMap(&self.aggregate_return_pointer_fields);
        self.loop_stack.deinit(self.allocator);
        self.defer_stack.deinit(self.allocator);
        self.string_literals.deinit(self.allocator);
        self.debug_functions.deinit(self.allocator);
        self.debug_locations.deinit(self.allocator);
        self.debug_locals.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn collectConstGlobalWidths(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            if (!global.is_const) continue;
            const ty = global.ty orelse continue;
            const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
            try self.const_global_widths.put(global.name.text, bits);
        }
    }

    fn preRegisterTypeDecls(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .enum_decl => |enum_decl| try self.enum_types.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.tagged_unions.put(union_decl.name.text, union_decl),
                .packed_bits_decl => |packed_bits| try self.packed_bits.put(packed_bits.name.text, .{
                    .repr = packed_bits.repr,
                    .fields = packed_bits.fields,
                }),
                .struct_decl => |struct_decl| {
                    if (struct_decl.type_params.len != 0) continue;
                    if (struct_decl.abi) |abi| {
                        if (!std.mem.eql(u8, abi, "mmio")) return error.UnsupportedLlvmEmission;
                    }
                    try self.struct_types.put(struct_decl.name.text, struct_decl);
                },
                else => {},
            }
        }
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast.StructDecl) !void {
        if (struct_decl.type_params.len != 0) return;
        if (struct_decl.abi) |abi| {
            if (!std.mem.eql(u8, abi, "mmio")) return error.UnsupportedLlvmEmission;
        }
        for (struct_decl.fields) |field| {
            if (isMmioStructAbi(struct_decl)) {
                _ = self.mmioFieldInfo(field) orelse return error.UnsupportedLlvmEmission;
            } else {
                _ = try self.llvmType(field.ty);
            }
        }
        try self.struct_types.put(struct_decl.name.text, struct_decl);
    }

    fn collectTypeAlias(self: *LlvmEmitter, alias: ast.TypeAlias) !void {
        _ = try self.llvmType(alias.ty);
        try self.type_aliases.put(alias.name.text, alias.ty);
    }

    fn collectEnum(self: *LlvmEmitter, enum_decl: ast.EnumDecl) !void {
        const repr = enumReprType(enum_decl);
        if (self.integerBitsOf(repr) == null) return error.UnsupportedLlvmEmission;
        for (enum_decl.cases) |case| _ = try self.enumCaseValue(enum_decl, case);
        try self.enum_types.put(enum_decl.name.text, enum_decl);
    }

    fn collectPackedBits(self: *LlvmEmitter, packed_bits: ast.PackedBitsDecl) !void {
        if (self.integerBitsOf(packed_bits.repr) == null) return error.UnsupportedLlvmEmission;
        try self.packed_bits.put(packed_bits.name.text, .{
            .repr = packed_bits.repr,
            .fields = packed_bits.fields,
        });
    }

    fn collectOverlayUnion(self: *LlvmEmitter, overlay_union: ast.OverlayUnionDecl) !void {
        var size: u64 = 1;
        var alignment: u64 = 1;
        for (overlay_union.fields) |field| {
            const layout = self.overlayFieldLayout(field.ty, 0) orelse return error.UnsupportedLlvmEmission;
            size = @max(size, layout.size);
            alignment = @max(alignment, layout.alignment);
        }
        try self.overlay_unions.put(overlay_union.name.text, .{
            .fields = overlay_union.fields,
            .size = size,
            .alignment = alignment,
        });
    }

    fn collectTaggedUnion(self: *LlvmEmitter, union_decl: ast.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| _ = try self.llvmType(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
    }

    fn collectFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, attrs: []const ast.Attr) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        _ = try self.llvmType(ret_ty);
        for (fn_decl.params) |param| _ = try self.llvmType(param.ty);
        const debug_id: ?usize = if (fn_decl.body != null) blk: {
            const id = self.debug_next_id;
            self.debug_next_id += 1;
            try self.debug_functions.append(self.allocator, .{
                .id = id,
                .name = fn_decl.name.text,
                .line = debugLine(fn_decl.name.span),
                .column = debugColumn(fn_decl.name.span),
            });
            break :blk id;
        } else null;
        try self.fn_sigs.put(fn_decl.name.text, .{ .ret = ret_ty, .params = fn_decl.params, .debug_id = debug_id, .error_from = error_from.hasAttr(attrs) });
    }

    fn collectGlobal(self: *LlvmEmitter, global: ast.GlobalDecl) !void {
        const ty = global.ty orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(ty);
        try self.global_types.put(global.name.text, ty);
        if (global.init) |expr| try self.global_initializers.put(global.name.text, expr);
    }

    fn aggregateReturnPointerFieldKey(self: *LlvmEmitter, fn_name: []const u8, field_path: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ fn_name, field_path });
    }

    fn aggregateReturnPointerFieldKeyPrefix(self: *LlvmEmitter, fn_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}\x00", .{fn_name});
    }

    fn aggregateReturnPointerFieldKeyPath(self: *LlvmEmitter, key: []const u8, fn_name: []const u8) ?[]const u8 {
        const prefix = self.aggregateReturnPointerFieldKeyPrefix(fn_name) catch return null;
        if (!std.mem.startsWith(u8, key, prefix)) return null;
        return key[prefix.len..];
    }

    fn collectMirAggregateReturnPointerFieldFacts(self: *LlvmEmitter) !void {
        self.clearOwnedStringProvenanceMapRetainingCapacity(&self.aggregate_return_pointer_fields);
        for (self.mir_module.aggregate_return_pointer_facts) |fact| {
            const key = try self.aggregateReturnPointerFieldKey(fact.callee, fact.field_path);
            errdefer self.allocator.free(key);
            try self.aggregate_return_pointer_fields.put(key, fact.provenance);
        }
    }

    fn intersectOwnedStringVoidMap(self: *LlvmEmitter, common: *std.StringHashMap(void), branch: *const std.StringHashMap(void)) !void {
        var removals: std.ArrayList([]const u8) = .empty;
        defer removals.deinit(self.scratch.allocator());

        var it = common.keyIterator();
        while (it.next()) |key| {
            if (!branch.contains(key.*)) try removals.append(self.scratch.allocator(), key.*);
        }

        for (removals.items) |key| {
            if (common.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        }
    }

    fn resetTransientPointerProvenance(self: *LlvmEmitter) void {
        self.local_types.clearRetainingCapacity();
        self.local_slots.clearRetainingCapacity();
        self.pointer_local_provenance.clearRetainingCapacity();
        self.local_function_pointer_aliases.clearRetainingCapacity();
        self.local_aggregate_pointer_aliases.clearRetainingCapacity();
        self.local_pointer_array_aliases.clearRetainingCapacity();
        self.clearAggregateGlobalPointerFields();
        self.clearLocalArrayGlobalPointerElements();
        self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
    }

    fn emitGlobal(self: *LlvmEmitter, global: ast.GlobalDecl) !void {
        const previous_function = self.current_function;
        self.current_function = global.name.text;
        defer self.current_function = previous_function;
        const ty = global.ty orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        // `extern global NAME: T;` — a declaration only; storage lives in another unit.
        if (global.is_extern) {
            try self.out.print(self.allocator, "@{s} = external global {s}\n", .{ global.name.text, llvm_ty });
            return;
        }
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        // Mirror the C backend's `static` vs external split (lower_c.zig emitGlobal): a plain
        // `global`/`const` stays module-private (LLVM `internal` linkage), so two separately
        // compiled units may each define the same name (e.g. `PAGE`) without a link-time
        // duplicate-symbol error. Only `export global` keeps default (external) linkage.
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const init = if (global.init) |expr| try self.emitGlobalInitializer(expr, ty) else try self.zeroInitializer(ty);
        try self.out.print(self.allocator, "@{s} = {s}{s} {s} {s}\n", .{ global.name.text, visibility, kind, llvm_ty, init });
    }

    fn emitGlobalInitializer(self: *LlvmEmitter, expr: ast.Expr, ty: ast.TypeExpr) ![]const u8 {
        const view_narrow_target = self.mirTargetTypeFactAt(.view_const_narrow_target, expr.span);
        if (view_narrow_target) |fact| {
            _ = self.mirTargetTypeFactAt(.view_const_narrow_source, expr.span) orelse return error.UnsupportedLlvmEmission;
            if (!sema_type.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(ty))) return error.UnsupportedLlvmEmission;
        }
        const semantic_ty = switch (expr.kind) {
            .array_literal => if (self.mirTargetTypeFactAt(.array_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission,
            .struct_literal => if (self.mirTargetTypeFactAt(.struct_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission,
            .null_literal => if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission,
            else => if (view_narrow_target) |fact| fact.target_ty else ty,
        };
        const resolved_ty = self.resolveAliasType(semantic_ty);
        if (self.foldConstGlobalValue(expr)) |value| {
            return try self.comptimeValueInitializer(value, semantic_ty);
        }
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| {
            if (isAtomicInitExpr(expr)) return try self.emitGlobalInitializer(atomicInitValue(expr).?, payload_ty);
            return try self.emitGlobalInitializer(expr, payload_ty);
        }
        if (self.enumDeclForType(semantic_ty)) |enum_decl| {
            return switch (expr.kind) {
                .enum_literal => |literal| if (self.mirTargetTypeFactAt(.enum_literal, expr.span)) |fact|
                    if (self.enumDeclForType(fact.target_ty)) |fact_enum|
                        try self.enumCaseValueByName(fact_enum, literal.text)
                    else
                        error.UnsupportedLlvmEmission
                else
                    error.UnsupportedLlvmEmission,
                .grouped => |inner| try self.emitGlobalInitializer(inner.*, semantic_ty),
                else => try self.emitGlobalInitializer(expr, enumReprType(enum_decl)),
            };
        }
        if (self.packedBitsInfoForType(semantic_ty)) |info| {
            return switch (expr.kind) {
                .struct_literal => |fields| try self.packedBitsLiteralValue(info, fields),
                .grouped => |inner| try self.emitGlobalInitializer(inner.*, semantic_ty),
                else => try self.emitGlobalInitializer(expr, info.repr),
            };
        }
        switch (expr.kind) {
            .ident => |ident| {
                if (!self.isFnPointerType(semantic_ty)) {
                    if (self.global_initializers.get(ident.text)) |initializer| {
                        return try self.emitGlobalInitializer(initializer, semantic_ty);
                    }
                }
            },
            .cast => |node| {
                _ = self.mirTargetTypeFactAt(.explicit_cast_source, expr.span) orelse return error.UnsupportedLlvmEmission;
                const target_fact = self.mirTargetTypeFactAt(.explicit_cast_target, expr.span) orelse return error.UnsupportedLlvmEmission;
                return try self.emitGlobalInitializer(node.value.*, target_fact.target_ty);
            },
            else => {},
        }
        switch (resolved_ty.kind) {
            .closure_type => if (isBindCallExpr(expr)) {
                return try self.emitGlobalBindInitializer(expr, resolved_ty);
            },
            .array => |array| {
                const items = switch (expr.kind) {
                    .array_literal => |items| items,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, semantic_ty),
                    else => return error.UnsupportedLlvmEmission,
                };
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                if (items.len != len) return error.UnsupportedLlvmEmission;
                var text: std.ArrayList(u8) = .empty;
                try text.append(self.scratch.allocator(), '[');
                for (items, 0..) |item, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(array.child.*), try self.emitGlobalInitializer(item, array.child.*) });
                }
                try text.append(self.scratch.allocator(), ']');
                return text.toOwnedSlice(self.scratch.allocator());
            },
            .name => if (self.structDeclForType(resolved_ty)) |struct_decl| {
                const fields = switch (expr.kind) {
                    .struct_literal => |fields| fields,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, resolved_ty),
                    else => return error.UnsupportedLlvmEmission,
                };
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(self.scratch.allocator(), "{ ");
                for (struct_decl.fields, 0..) |field, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    const value_expr = structLiteralField(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(field.ty), try self.emitGlobalInitializer(value_expr, field.ty) });
                }
                try text.appendSlice(self.scratch.allocator(), " }");
                return text.toOwnedSlice(self.scratch.allocator());
            },
            else => {},
        }
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .string_literal => |literal| blk: {
                const fact = self.mirTargetTypeFactAt(.string_literal, expr.span) orelse break :blk error.UnsupportedLlvmEmission;
                if (!isStringLiteralTarget(self.resolveAliasType(fact.target_ty))) break :blk error.UnsupportedLlvmEmission;
                const global = try self.internStringLiteral(literal);
                break :blk try std.fmt.allocPrint(
                    self.scratch.allocator(),
                    "getelementptr ([{d} x i8], ptr @{s}, i64 0, i64 0)",
                    .{ global.len, global.name },
                );
            },
            .float_literal => |literal| if (self.mirTargetTypeFactAt(.float_literal, expr.span)) |fact|
                try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(fact.target_ty))
            else
                error.UnsupportedLlvmEmission,
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                if (self.isFloatTypeOf(semantic_ty)) {
                    const literal = switch ((node.expr.*).kind) {
                        .float_literal => |literal| literal,
                        .grouped => |inner| switch (inner.kind) {
                            .float_literal => |literal| literal,
                            else => break :blk error.UnsupportedLlvmEmission,
                        },
                        else => break :blk error.UnsupportedLlvmEmission,
                    };
                    break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(semantic_ty))});
                }
                if (self.integerBitsOf(semantic_ty) != null) {
                    const literal = switch ((node.expr.*).kind) {
                        .int_literal => |literal| literal,
                        .grouped => |inner| switch (inner.kind) {
                            .int_literal => |literal| literal,
                            else => break :blk error.UnsupportedLlvmEmission,
                        },
                        else => break :blk error.UnsupportedLlvmEmission,
                    };
                    break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)});
                }
                break :blk error.UnsupportedLlvmEmission;
            },
            .bool_literal => |value| if (value) "1" else "0",
            .null_literal => if (self.targetIsValueOptional(semantic_ty) or self.targetIsDynOrNullableDyn(semantic_ty)) "zeroinitializer" else "null",
            .grouped => |inner| try self.emitGlobalInitializer(inner.*, semantic_ty),
            .ident => |ident| if (self.isFnPointerType(semantic_ty) and self.fn_sigs.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .address_of => |inner| try self.globalAddressInitializer(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn globalAddressInitializer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.global_types.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .index => |node| try self.globalIndexAddressInitializer(node),
            .member => |node| try self.globalMemberAddressInitializer(node),
            .grouped => |inner| try self.globalAddressInitializer(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitGlobalBindInitializer(self: *LlvmEmitter, expr: ast.Expr, closure_ty: ast.TypeExpr) ![]const u8 {
        const call = switch (expr.kind) {
            .call => |call| call,
            .grouped => |inner| return self.emitGlobalBindInitializer(inner.*, closure_ty),
            else => return error.UnsupportedLlvmEmission,
        };
        if (self.resolveAliasType(closure_ty).kind != .closure_type) return error.UnsupportedLlvmEmission;
        const fname = calleeIdentName(call.args[1]) orelse return error.UnsupportedLlvmEmission;
        if (!self.fn_sigs.contains(fname)) return error.UnsupportedLlvmEmission;
        const env = try self.globalAddressInitializer(call.args[0]);
        return try std.fmt.allocPrint(self.scratch.allocator(), "{{ ptr @{s}, ptr {s} }}", .{ fname, env });
    }

    fn globalIndexAddressInitializer(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const resolved_base_ty = self.resolveAliasType(base_ty);
        const index = self.globalConstIndexValue(node.index.*) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.globalAddressInitializer(node.base.*);
        return switch (resolved_base_ty.kind) {
            .array => try std.fmt.allocPrint(
                self.scratch.allocator(),
                "getelementptr ({s}, ptr {s}, i64 0, i64 {d})",
                .{ try self.llvmType(resolved_base_ty), base_ptr, index },
            ),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn globalMemberAddressInitializer(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.globalAddressInitializer(node.base.*);
        return std.fmt.allocPrint(
            self.scratch.allocator(),
            "getelementptr ({s}, ptr {s}, i64 0, i32 {d})",
            .{ try self.llvmType(struct_ty), base_ptr, index },
        );
    }

    fn globalConstIndexValue(self: *LlvmEmitter, expr: ast.Expr) ?u64 {
        if (self.foldConstGlobalValue(expr)) |value| {
            return switch (value) {
                .int => |n| if (n >= 0 and n <= std.math.maxInt(u64)) @intCast(n) else null,
                else => null,
            };
        }
        return switch (expr.kind) {
            .ident => |ident| if (self.global_initializers.get(ident.text)) |initializer|
                self.globalConstIndexValue(initializer)
            else
                null,
            .grouped => |inner| self.globalConstIndexValue(inner.*),
            else => null,
        };
    }

    fn foldConstGlobalValue(self: *LlvmEmitter, expr: ast.Expr) ?eval.ComptimeValue {
        var fb_arena: ?std.heap.ArenaAllocator = null;
        defer if (fb_arena) |*a| a.deinit();
        const fold_alloc = eval.tryFoldScratch() orelse blk: {
            fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            break :blk fb_arena.?.allocator();
        };
        defer if (fb_arena == null) eval.releaseFoldScratch();
        var scope = eval.ComptimeScope.init(fold_alloc);
        defer scope.deinit();
        var reflect_env = self.reflectEnv();
        if (!self.seedConstFoldScope(&scope, &reflect_env)) return null;
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| eval.cloneComptimeValue(self.scratch.allocator(), v) catch null,
            else => null,
        };
    }

    fn seedConstFoldScope(self: *LlvmEmitter, scope: *eval.ComptimeScope, reflect_env: *LlvmReflectEnv) bool {
        _ = self;
        return lower_llvm_reflect.seedConstFoldScope(reflect_env, scope);
    }

    fn reflectEnv(self: *LlvmEmitter) LlvmReflectEnv {
        return .{
            .type_aliases = &self.type_aliases,
            .enum_types = &self.enum_types,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .struct_types = &self.struct_types,
            .const_fns = &self.const_fns,
            .const_globals = &self.const_globals,
            .const_global_widths = &self.const_global_widths,
        };
    }

    fn comptimeValueInitializer(self: *LlvmEmitter, value: eval.ComptimeValue, target_ty: ast.TypeExpr) anyerror![]const u8 {
        const resolved = self.resolveAliasType(target_ty);
        return switch (value) {
            .int => |n| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
            .boolean => |b| if (b) "1" else "0",
            .tag => |tag| blk: {
                const enum_decl = self.enumDeclForType(resolved) orelse return error.UnsupportedLlvmEmission;
                break :blk try self.enumCaseValueByName(enum_decl, tag);
            },
            .array => |items| blk: {
                const array = switch (resolved.kind) {
                    .array => |node| node,
                    else => return error.UnsupportedLlvmEmission,
                };
                var text: std.ArrayList(u8) = .empty;
                try text.append(self.scratch.allocator(), '[');
                for (items, 0..) |item, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(array.child.*), try self.comptimeValueInitializer(item, array.child.*) });
                }
                try text.append(self.scratch.allocator(), ']');
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .@"struct" => |fields| blk: {
                if (self.packedBitsInfoForType(resolved)) |info| break :blk try self.packedBitsComptimeValue(info, fields);
                const struct_decl = self.structDeclForType(resolved) orelse return error.UnsupportedLlvmEmission;
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(self.scratch.allocator(), "{ ");
                for (struct_decl.fields, 0..) |field, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    const field_value = comptimeStructFieldValue(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(field.ty), try self.comptimeValueInitializer(field_value, field.ty) });
                }
                try text.appendSlice(self.scratch.allocator(), " }");
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            // LLVM float/double constants accept the exact f64 bit pattern in hex. For an
            // f32 target, round to f32 first (then widen) so the value is representable.
            .float => |f| blk: {
                const tname = switch (resolved.kind) {
                    .name => |n| n.text,
                    else => "",
                };
                const fv: f64 = if (std.mem.eql(u8, tname, "f32")) @floatCast(@as(f32, @floatCast(f))) else f;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "0x{X:0>16}", .{@as(u64, @bitCast(fv))});
            },
            .void, .bytes => error.UnsupportedLlvmEmission,
        };
    }

    fn zeroInitializer(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool"))
                "0"
            else if (self.isFloatTypeOf(resolved_ty))
                "0.0"
            else if (isOpaqueAddressTypeName(name.text))
                "0"
            else if (self.integerBitsOf(resolved_ty) != null or self.enumDeclForType(resolved_ty) != null)
                "0"
            else if (self.overlayInfoForType(resolved_ty) != null)
                "zeroinitializer"
            else if (self.taggedUnionForType(resolved_ty) != null)
                "zeroinitializer"
            else if (self.structDeclForType(resolved_ty) != null)
                "zeroinitializer"
            else if (libraryScalarLlvmType(name.text) != null)
                "0"
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer, .nullable => "null",
            .slice => "zeroinitializer",
            .array => "zeroinitializer",
            .qualified => |node| try self.zeroInitializer(node.child.*),
            .generic => |node| if (self.resultInfo(resolved_ty)) |_|
                "zeroinitializer"
            else if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1)
                // MmioPtr<T> lowers to `ptr` (see llvmType); its zero is a null pointer.
                "null"
            else if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2)
                // DmaBuf<T,U> lowers to i64 (an opaque DMA address); its zero is 0.
                "0"
            else if ((std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits")) and node.args.len >= 1)
                // Reg<T,..>/RegBits<T,..> lower to their payload T (see llvmType).
                try self.zeroInitializer(node.args[0])
            else if (isPayloadDomainGenericName(node.base.text) and node.args.len == 1)
                try self.zeroInitializer(node.args[0])
            else if (isOpaqueAddressGenericName(node.base.text) and node.args.len == 1)
                // UserPtr<T>/PhysPtr<T> lower to i64 (see llvmType); their zero is 0.
                "0"
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    // `#[backend_name("Y")]`: a module-level alias exposing the override symbol, pointing at the
    // function emitted under its source name. The aliasee type is the function type.
    fn emitBackendNameAliases(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            if (decl.kind != .fn_decl) continue;
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.body == null) continue;
            const backend = self.backend_names.get(fn_decl.name.text) orelse continue;
            const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
            try self.out.print(self.allocator, "@{s} = alias {s} (", .{ backend, try self.llvmType(ret_ty) });
            for (fn_decl.params, 0..) |param, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
            }
            try self.out.print(self.allocator, "), ptr @{s}\n", .{fn_decl.name.text});
        }
    }

    fn emitFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, body: ast.Block, attrs: []const ast.Attr) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_return_ty = self.current_return_ty;
        const old_function = self.current_function;
        self.current_debug_scope = if (self.fn_sigs.get(fn_decl.name.text)) |sig| sig.debug_id else null;
        self.current_debug_span = fn_decl.name.span;
        self.current_return_ty = ret_ty;
        self.current_function = fn_decl.name.text;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_return_ty = old_return_ty;
            self.current_function = old_function;
        }
        // `#[naked]`: the `naked` function attribute tells LLVM to emit no prologue or
        // epilogue. The body is a single inline-asm statement that performs the
        // ABI-correct jump/return itself; we terminate the entry block with
        // `unreachable` because the asm — not a synthesized `ret` — transfers control.
        const naked = hasNakedAttr(attrs);
        // `#[noinline]`: the LLVM `noinline` function attribute keeps a distinct physical call
        // frame (e.g. a frame-pointer backtrace must walk nested frames). Composes with naked.
        const attr_str: []const u8 = if (naked and hasNoinlineAttr(attrs))
            " naked noinline"
        else if (naked)
            " naked"
        else if (hasNoinlineAttr(attrs))
            " noinline"
        else
            "";
        // `#[section("...")]`: emit an LLVM `section "..."` clause so the symbol lands in the
        // named linker section (bare-metal entry points pinned by the linker script, e.g.
        // OpenSBI's `_start` at 0x80200000 via `KEEP(*(.text.boot))`).
        var section_buf: std.ArrayList(u8) = .empty;
        defer section_buf.deinit(self.allocator);
        if (sectionAttr(attrs)) |sec| {
            try section_buf.print(self.allocator, " section \"{s}\"", .{sec});
        }
        const section_str: []const u8 = section_buf.items;
        // `#[align(N)]`: emit an LLVM `align N` function attribute. `#[naked]` functions default
        // to 4-byte alignment — they are trap/entry code whose address is loaded into an
        // alignment-sensitive register (a RISC-V `stvec`/`mtvec` base must be 4-byte aligned;
        // its low two bits are the MODE field, so a 2-byte-aligned vector traps to a bad PC).
        var align_buf: [32]u8 = undefined;
        const align_str: []const u8 = if (effectiveAlign(attrs)) |al|
            std.fmt.bufPrint(&align_buf, " align {d}", .{al}) catch unreachable
        else
            "";
        // Linkage specifier (before the return type):
        // - `#[weak]` -> `weak` (a strong definition in another unit overrides this default);
        // - a NON-`export` function -> `internal`, the analogue of the C backend's `static`.
        //   MC inlines an imported module's source into every importer's object, so a non-export
        //   helper (e.g. std/fmt_sink.mc's `fmt_put_*`) is COPIED into each object; without
        //   internal linkage the copies collide at link time (`ld.lld: duplicate symbol`).
        //   Exported functions keep external linkage so the C bring-up glue / cross-object
        //   references resolve.
        const weak_str: []const u8 = if (hasWeakAttr(attrs))
            "weak "
        else if (!fn_decl.exported)
            "internal "
        else
            "";
        try self.out.print(self.allocator, "define {s}{s} @{s}(", .{ weak_str, ret_llvm, fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} %{s}", .{ try self.llvmType(param.ty), param.name.text });
        }
        // C-ABI variadic tail: `define T @f(named..., ...)`. The body's `va.*` intrinsics
        // (llvm.va_start / the va_arg instruction / llvm.va_end) read the extra args.
        if (fn_decl.is_variadic) {
            if (fn_decl.params.len != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "...");
        }
        // The naked path needs no entry-alloca buffering: its body is a single asm stmt.
        if (naked) {
            if (self.current_debug_scope) |scope| {
                try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\nbb_entry:\n", .{ attr_str, section_str, align_str, scope });
            } else {
                try self.out.print(self.allocator, "){s}{s}{s} {{\nbb_entry:\n", .{ attr_str, section_str, align_str });
            }
            self.temp_index = 0;
            try self.emitAsmStmt(ast_query.nakedAsmStmt(body) orelse return error.UnsupportedLlvmEmission);
            try self.out.appendSlice(self.allocator, "  unreachable\n}\n\n");
            return;
        }

        // Emit the body into a scratch buffer while routing every alloca to a separate
        // entry-block buffer (see `entry_allocas`). After the body is built we splice them:
        //   define …(…) {  bb_entry:  <all allocas>  <body>  }
        // so each local slot is a STATIC entry-block alloca — reused across loop iterations
        // rather than re-allocated each time (which would grow the stack without bound and
        // eventually corrupt memory).
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);
        var alloca_buf: std.ArrayList(u8) = .empty;
        defer alloca_buf.deinit(self.allocator);
        const real_out = self.out;
        self.out = &body_buf;
        self.entry_allocas = &alloca_buf;
        defer {
            self.out = real_out;
            self.entry_allocas = null;
        }

        self.temp_index = 0;
        self.trap_index = 0;
        self.local_types.clearRetainingCapacity();
        self.local_slots.clearRetainingCapacity();
        self.pointer_local_provenance.clearRetainingCapacity();
        self.local_function_pointer_aliases.clearRetainingCapacity();
        self.local_aggregate_pointer_aliases.clearRetainingCapacity();
        self.local_pointer_array_aliases.clearRetainingCapacity();
        self.clearAggregateGlobalPointerFields();
        self.clearLocalArrayGlobalPointerElements();
        self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
        self.defer_stack.clearRetainingCapacity();
        for (fn_decl.params, 0..) |param, i| {
            try self.local_types.put(param.name.text, param.ty);
            if (self.isVaListType(param.ty)) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.emitAlloca(ptr, "ptr");
                try self.out.print(self.allocator, "  store ptr %{s}, ptr {s}\n", .{ param.name.text, ptr });
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr, .kind = .va_list_param });
            } else if (self.isAggregateType(param.ty) or self.atomicPayloadType(param.ty) != null) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.emitAlloca(ptr, try self.llvmType(param.ty));
                try self.out.print(self.allocator, "  store {s} %{s}, ptr {s}\n", .{ try self.llvmType(param.ty), param.name.text, ptr });
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr });
            } else {
                const value = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{param.name.text});
                try self.emitDebugValue(param.name.text, param.ty, value, param.name.span, i + 1);
            }
        }

        if (!try self.emitBlock(body, ret_ty)) {
            if (typeNameEql(ret_ty, "void")) {
                try self.emitReturnVoid(fn_decl.name.span);
            } else if (typeNameEql(ret_ty, "never")) {
                try self.out.appendSlice(self.allocator, "  unreachable\n");
            } else {
                return error.UnsupportedLlvmEmission;
            }
        }

        // Splice signature + entry label + hoisted allocas + body into the real output.
        self.out = real_out;
        self.entry_allocas = null;
        if (self.current_debug_scope) |scope| {
            try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\nbb_entry:\n", .{ attr_str, section_str, align_str, scope });
        } else {
            try self.out.print(self.allocator, "){s}{s}{s} {{\nbb_entry:\n", .{ attr_str, section_str, align_str });
        }
        try self.out.appendSlice(self.allocator, alloca_buf.items);
        try self.out.appendSlice(self.allocator, body_buf.items);
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitExternFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl) !void {
        // The KASAN shadow hooks (D2.1) get weak no-op `define`s in emitTrapDecl so every
        // build links; skip the `declare` here to avoid an LLVM declare-vs-define clash.
        if (isKsanHook(fn_decl.name.text)) return;
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        try self.out.print(self.allocator, "declare {s} @{s}(", .{ try self.llvmType(ret_ty), fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
        }
        try self.out.appendSlice(self.allocator, ")\n\n");
    }

    fn reportUnsupported(self: *LlvmEmitter, span: ast.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            reporter.err(self.diagnosticSpan(span), "E_BACKEND_UNSUPPORTED: LLVM backend does not yet support {s}", .{construct});
        }
    }

    fn reportUnsupportedIfNone(self: *LlvmEmitter, span: ast.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            if (!reporter.has_errors) {
                reporter.err(self.diagnosticSpan(span), "E_BACKEND_UNSUPPORTED: LLVM backend does not yet support {s}", .{construct});
            }
        }
    }

    fn diagnosticSpan(self: *LlvmEmitter, span: ast.Span) ast.Span {
        if (isSourceSpan(span)) return span;
        if (self.current_debug_span) |current| {
            if (isSourceSpan(current)) return current;
        }
        return span;
    }

    fn unsupportedExprValue(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        self.reportUnsupported(expr.span, @tagName(expr.kind));
        return error.UnsupportedLlvmEmission;
    }

    fn emitExpr(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) anyerror![]const u8 {
        return self.emitExprInner(expr, expected_ty) catch |err| switch (err) {
            error.UnsupportedLlvmEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprWithMirRangeTarget(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr, target: []const u8) anyerror![]const u8 {
        const previous = self.current_mir_range_target;
        self.current_mir_range_target = target;
        defer self.current_mir_range_target = previous;
        return self.emitExpr(expr, expected_ty);
    }

    fn emitExprInner(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) anyerror![]const u8 {
        const semantic_expected_ty = if (expr.kind == .null_literal)
            if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission
        else
            expected_ty;
        // Tier 2 coercion: a `*T` value -> `*dyn Trait` builds the fat pointer
        // { data = <ptr>, vtable = @__vt_T_Trait } (the only safe path to a `*dyn`).
        // This runs UNIFORMLY wherever `expected_ty` is threaded — let-init, return,
        // call arg, struct field, array element — not just at `&x`. The vtable is keyed
        // on the STATIC pointee type T of the source `*T` (a `&x`, a `*Square` param, a
        // `*T` field — all uniform). Sema has already verified conformance + forge-safety;
        // a `*dyn` pass-through value (same trait) returns null and emits normally.
        if (self.targetIsDynOrNullableDyn(semantic_expected_ty)) {
            if (try self.emitDynCoercion(expr, semantic_expected_ty)) |value| return value;
        }
        // Value optional `?T`: wrap a `null` (absent) or payload value (present) into the
        // tagged `{ i1, T }` aggregate. A source already yielding `?T` passes through.
        if (self.targetIsValueOptional(semantic_expected_ty)) {
            if (try self.emitValueOptionalCoercion(expr, semantic_expected_ty)) |value| return value;
        }
        const value = try switch (expr.kind) {
            .ident => |ident| try self.emitIdent(ident),
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .string_literal => |literal| try self.emitStringLiteral(literal, expr.span),
            .float_literal => |literal| if (self.mirTargetTypeFactAt(.float_literal, expr.span)) |fact|
                try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(fact.target_ty))
            else
                error.UnsupportedLlvmEmission,
            .bool_literal => |value| if (value) "1" else "0",
            .null_literal => "null",
            .enum_literal => |literal| if (self.mirTargetTypeFactAt(.enum_literal, expr.span)) |fact|
                if (self.enumDeclForType(fact.target_ty)) |enum_decl|
                    try self.enumCaseValueByName(enum_decl, literal.text)
                else
                    error.UnsupportedLlvmEmission
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| self.emitExpr(inner.*, expected_ty),
            .call => |call| try self.emitCall(call, expected_ty, expr.span),
            .array_literal => |items| if (self.mirTargetTypeFactAt(.array_literal, expr.span)) |fact|
                try self.emitArrayLiteralValue(fact.target_ty, items)
            else
                error.UnsupportedLlvmEmission,
            .struct_literal => |fields| if (self.mirTargetTypeFactAt(.struct_literal, expr.span)) |fact|
                if (self.packedBitsInfoForType(fact.target_ty)) |info|
                    try self.emitPackedBitsLiteralValue(info, fields)
                else
                    try self.emitStructLiteralValue(fact.target_ty, fields)
            else
                error.UnsupportedLlvmEmission,
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            .cast => |node| try self.emitCast(expr.span, node.value.*),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .deref => |inner| try self.emitDeref(inner.*, expected_ty),
            .index => |node| try self.emitIndexLoad(node),
            .slice => |node| try self.emitSlice(node, expr.span),
            .member => |node| if (enumVariantPathType(&self.enum_types, node, self.memberBaseIsValue(node))) |variant_ty|
                (if (self.enumDeclForType(variant_ty)) |enum_decl|
                    try self.enumCaseValueByName(enum_decl, node.name.text)
                else
                    error.UnsupportedLlvmEmission)
            else
                try self.emitMemberLoad(node),
            .try_expr => |node| try self.emitTryExpr(node.operand.*, node.mapped, expected_ty),
            else => self.unsupportedExprValue(expr),
        };
        return try self.coerceExprValue(value, expr, expected_ty);
    }

    fn coerceExprValue(self: *LlvmEmitter, value: []const u8, expr: ast.Expr, expected_ty: ast.TypeExpr) ![]const u8 {
        if (self.mirTargetTypeFactAt(.view_const_narrow_target, expr.span)) |target_fact| {
            const source_fact = self.mirTargetTypeFactAt(.view_const_narrow_source, expr.span) orelse return error.UnsupportedLlvmEmission;
            if (sema_type.sameTypeSyntax(self.resolveAliasType(target_fact.target_ty), self.resolveAliasType(expected_ty))) {
                if (!std.mem.eql(u8, try self.llvmType(source_fact.target_ty), try self.llvmType(target_fact.target_ty))) return error.UnsupportedLlvmEmission;
                return value;
            }
        }
        const source_ty = self.exprType(expr) orelse return value;
        if (std.mem.eql(u8, try self.llvmType(source_ty), try self.llvmType(expected_ty))) return value;
        if ((self.integerBitsOf(source_ty) != null or self.enumDeclForType(source_ty) != null) and
            (self.integerBitsOf(expected_ty) != null or self.enumDeclForType(expected_ty) != null))
        {
            return try self.castValue(value, source_ty, expected_ty);
        }
        if (self.pointerAddressCoercion(source_ty, expected_ty)) {
            return try self.emitBitcastValue(value, source_ty, expected_ty);
        }
        return value;
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            if (self.isVaListType(slot.ty)) return try self.emitVaListValueFromSlot(slot);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr, try self.debugCallSuffix() });
            return result;
        }
        if (self.local_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
        if (self.global_types.get(ident.text)) |ty| {
            const global_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
            try self.emitOrdinaryShadowHook(global_ptr, ty, .load_pre);
            return try self.emitOrdinaryLoad(ty, global_ptr, true);
        }
        if (self.fn_sigs.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
        return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
    }

    fn isVaListType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |name| std.mem.eql(u8, name.text, "va_list"),
            else => false,
        };
    }

    fn vaListStorageType(self: *LlvmEmitter) ![]const u8 {
        return switch (self.target_arch) {
            .riscv64 => "ptr",
            .x86_64 => "[1 x %mc.va_list.x86_64]",
            .aarch64 => "%mc.va_list.aarch64",
        };
    }

    fn vaListCursorPtrFromStorage(self: *LlvmEmitter, storage_ptr: []const u8) ![]const u8 {
        return switch (self.target_arch) {
            .riscv64, .aarch64 => storage_ptr,
            .x86_64 => blk: {
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds [1 x %mc.va_list.x86_64], ptr {s}, i64 0, i64 0\n", .{ result, storage_ptr });
                break :blk result;
            },
        };
    }

    fn emitVaListValueFromSlot(self: *LlvmEmitter, slot: LocalSlot) ![]const u8 {
        switch (slot.kind) {
            .normal => return error.UnsupportedLlvmEmission,
            .va_list_param => {
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load ptr, ptr {s}{s}\n", .{ result, slot.ptr, try self.debugCallSuffix() });
                return result;
            },
            .va_list_local => return switch (self.target_arch) {
                .riscv64 => blk: {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = load ptr, ptr {s}{s}\n", .{ result, slot.ptr, try self.debugCallSuffix() });
                    break :blk result;
                },
                .x86_64, .aarch64 => try self.vaListCursorPtrFromStorage(slot.ptr),
            },
        }
    }

    fn vaListCursorPtrFromSlot(self: *LlvmEmitter, slot: LocalSlot) ![]const u8 {
        switch (slot.kind) {
            .normal => return error.UnsupportedLlvmEmission,
            .va_list_local => return self.vaListCursorPtrFromStorage(slot.ptr),
            .va_list_param => return switch (self.target_arch) {
                .riscv64 => slot.ptr,
                .x86_64, .aarch64 => try self.emitVaListValueFromSlot(slot),
            },
        }
    }

    fn emitVaListCursorForCopySource(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        if (expr.kind == .ident) {
            const ident = expr.kind.ident;
            if (self.local_slots.get(ident.text)) |slot| {
                if (self.isVaListType(slot.ty)) return self.vaListCursorPtrFromSlot(slot);
            }
        }
        const value = try self.emitExpr(expr, simpleType(expr.span, "va_list"));
        return switch (self.target_arch) {
            .riscv64 => blk: {
                const tmp = try self.nextTemp();
                try self.emitAlloca(tmp, "ptr");
                try self.out.print(self.allocator, "  store ptr {s}, ptr {s}{s}\n", .{ value, tmp, try self.debugCallSuffix() });
                break :blk tmp;
            },
            .x86_64, .aarch64 => value,
        };
    }

    fn emitVaListCursorArg(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .grouped => |inner| try self.emitVaListCursorArg(inner.*),
            else => try self.emitExpr(expr, self.exprType(expr) orelse return error.UnsupportedLlvmEmission),
        };
    }

    fn emitVaArg(self: *LlvmEmitter, ap_ptr: []const u8, ty: ast.TypeExpr) ![]const u8 {
        if (self.target_arch == .aarch64) return try self.emitAarch64VaArg(ap_ptr, ty);

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = va_arg ptr {s}, {s}{s}\n", .{ result, ap_ptr, try self.llvmType(ty), try self.debugCallSuffix() });
        return result;
    }

    fn emitAarch64VaArg(self: *LlvmEmitter, ap_ptr: []const u8, ty: ast.TypeExpr) ![]const u8 {
        const result_ty = try self.llvmType(ty);
        if (!std.mem.eql(u8, result_ty, "ptr")) {
            const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
            if (bits != 32 and bits != 64) return error.UnsupportedLlvmEmission;
        }

        const result_slot = try self.nextTemp();
        try self.emitAlloca(result_slot, result_ty);

        const offs_ptr = try self.nextTemp();
        const offs = try self.nextTemp();
        const in_regs = try self.nextTemp();
        const reg_label = try self.nextLabel("va_arg_reg");
        const reg_use_label = try self.nextLabel("va_arg_reg_use");
        const stack_label = try self.nextLabel("va_arg_stack");
        const done_label = try self.nextLabel("va_arg_done");

        try self.out.print(self.allocator, "  {s} = getelementptr %mc.va_list.aarch64, ptr {s}, i32 0, i32 3\n", .{ offs_ptr, ap_ptr });
        try self.out.print(self.allocator, "  {s} = load i32, ptr {s}{s}\n", .{ offs, offs_ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = icmp slt i32 {s}, 0\n", .{ in_regs, offs });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ in_regs, reg_label, stack_label, try self.debugCallSuffix() });

        try self.out.print(self.allocator, "{s}:\n", .{reg_label});
        const new_offs = try self.nextTemp();
        const reg_fits = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = add i32 {s}, 8\n", .{ new_offs, offs });
        try self.out.print(self.allocator, "  store i32 {s}, ptr {s}{s}\n", .{ new_offs, offs_ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = icmp sle i32 {s}, 0\n", .{ reg_fits, new_offs });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ reg_fits, reg_use_label, stack_label, try self.debugCallSuffix() });

        try self.out.print(self.allocator, "{s}:\n", .{reg_use_label});
        const gr_top_ptr = try self.nextTemp();
        const gr_top = try self.nextTemp();
        const reg_addr = try self.nextTemp();
        const reg_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr %mc.va_list.aarch64, ptr {s}, i32 0, i32 1\n", .{ gr_top_ptr, ap_ptr });
        try self.out.print(self.allocator, "  {s} = load ptr, ptr {s}{s}\n", .{ gr_top, gr_top_ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i32 {s}\n", .{ reg_addr, gr_top, offs });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ reg_value, result_ty, reg_addr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ result_ty, reg_value, result_slot, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ done_label, try self.debugCallSuffix() });

        try self.out.print(self.allocator, "{s}:\n", .{stack_label});
        const stack_ptr = try self.nextTemp();
        const stack = try self.nextTemp();
        const next_stack = try self.nextTemp();
        const stack_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr %mc.va_list.aarch64, ptr {s}, i32 0, i32 0\n", .{ stack_ptr, ap_ptr });
        try self.out.print(self.allocator, "  {s} = load ptr, ptr {s}{s}\n", .{ stack, stack_ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 8\n", .{ next_stack, stack });
        try self.out.print(self.allocator, "  store ptr {s}, ptr {s}{s}\n", .{ next_stack, stack_ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ stack_value, result_ty, stack, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ result_ty, stack_value, result_slot, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ done_label, try self.debugCallSuffix() });

        try self.out.print(self.allocator, "{s}:\n", .{done_label});
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, result_ty, result_slot, try self.debugCallSuffix() });
        return result;
    }

    fn emitBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) anyerror!bool {
        const defer_start = self.defer_stack.items.len;
        errdefer self.defer_stack.items.len = defer_start;
        for (block.items) |stmt| {
            const old_debug_span = self.current_debug_span;
            if (isSourceSpan(stmt.span)) self.current_debug_span = stmt.span;
            defer self.current_debug_span = old_debug_span;

            const terminated = self.emitStmt(stmt, ret_ty) catch |err| switch (err) {
                error.UnsupportedLlvmEmission => {
                    self.reportUnsupportedIfNone(stmt.span, @tagName(stmt.kind));
                    return err;
                },
                else => return err,
            };
            if (terminated) return true;
        }
        try self.emitDeferredCleanupsFrom(defer_start, ret_ty);
        self.defer_stack.items.len = defer_start;
        return false;
    }

    fn emitStmt(self: *LlvmEmitter, stmt: ast.Stmt, ret_ty: ast.TypeExpr) anyerror!bool {
        switch (stmt.kind) {
            .let_decl => |local| try self.emitLocalDecl(local),
            .var_decl => |local| try self.emitLocalDecl(local),
            .assignment => |node| try self.emitAssignment(node.target, node.value, stmt.span),
            .@"defer" => |expr| try self.defer_stack.append(self.allocator, expr),
            .loop => |node| {
                if (try self.emitLoop(node, ret_ty)) return true;
            },
            .block => |node| {
                if (try self.emitScopedBlock(node, ret_ty)) return true;
            },
            .comptime_block => {},
            .unsafe_block => |node| {
                if (try self.emitScopedBlock(node, ret_ty)) return true;
            },
            .contract_block => |node| {
                if (try self.emitScopedBlock(node.block, ret_ty)) return true;
            },
            .assert => |expr| try self.emitAssert(expr),
            .@"return" => |maybe_expr| {
                if (maybe_expr) |expr| {
                    if (try self.emitNeverExpr(expr)) return true;
                }
                if (typeNameEql(ret_ty, "void")) {
                    if (maybe_expr) |expr| switch (expr.kind) {
                        .void_literal => {},
                        .grouped => |inner| if ((inner.*).kind != .void_literal) return error.UnsupportedLlvmEmission,
                        else => return error.UnsupportedLlvmEmission,
                    };
                    try self.emitDeferredCleanupsFrom(0, ret_ty);
                    try self.emitReturnVoid(stmt.span);
                } else if (typeNameEql(ret_ty, "never")) {
                    return error.UnsupportedLlvmEmission;
                } else {
                    const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                    const value = try self.emitExprWithMirRangeTarget(expr, ret_ty, "value");
                    try self.emitDeferredCleanupsFrom(0, ret_ty);
                    try self.emitReturnValue(ret_ty, value, stmt.span);
                }
                return true;
            },
            .@"switch" => |node| {
                if (try self.emitNullableSwitch(node, ret_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitResultSwitch(node, ret_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitTaggedUnionSwitch(node, ret_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitScalarSwitch(node, ret_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                self.reportUnsupported(stmt.span, "switch statement");
                return error.UnsupportedLlvmEmission;
            },
            .if_let => |node| {
                if (try self.emitResultIfLet(node, ret_ty)) return true;
                if (try self.emitNullableIfLet(node, ret_ty)) return true;
            },
            .@"break" => |target| {
                const labels = self.resolveLoopLabels(target) orelse return error.UnsupportedLlvmEmission;
                try self.emitDeferredCleanupsFrom(labels.cleanup_start, ret_ty);
                self.defer_stack.items.len = labels.cleanup_start;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ labels.break_label, try self.debugCallSuffix() });
                return true;
            },
            .@"continue" => |target| {
                const labels = self.resolveLoopLabels(target) orelse return error.UnsupportedLlvmEmission;
                try self.emitDeferredCleanupsFrom(labels.cleanup_start, ret_ty);
                self.defer_stack.items.len = labels.cleanup_start;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ labels.continue_label, try self.debugCallSuffix() });
                return true;
            },
            .expr => |expr| {
                try self.emitExprStatement(expr);
                // A diverging statement (`trap(...)`, `unreachable`, a `-> never` call) emits
                // its own `unreachable` terminator, so the block ends here — even if the
                // function returns a value, this path does not fall through.
                if (self.exprStatementDiverges(expr)) return true;
            },
            .asm_stmt => |asm_stmt| try self.emitAsmStmt(asm_stmt),
        }
        return false;
    }

    // G7: resolve a break/continue target to the loop-stack record. A labeled
    // target searches outward for the matching source label; a bare target picks
    // the innermost loop. Sema rejects labels not in scope, so a labeled target
    // resolves whenever the program type-checked.
    fn resolveLoopLabels(self: *LlvmEmitter, target: ?ast.Ident) ?LoopLabels {
        if (target) |t| {
            var i = self.loop_stack.items.len;
            while (i > 0) {
                i -= 1;
                if (self.loop_stack.items[i].label) |lbl| {
                    if (std.mem.eql(u8, lbl, t.text)) return self.loop_stack.items[i];
                }
            }
            return null;
        }
        return self.loop_stack.getLastOrNull();
    }

    fn emitDeferredCleanupsFrom(self: *LlvmEmitter, start: usize, ret_ty: ast.TypeExpr) !void {
        var index = self.defer_stack.items.len;
        while (index > start) {
            index -= 1;
            try self.emitDeferredCleanup(self.defer_stack.items[index], ret_ty);
        }
    }

    fn emitDeferredCleanup(self: *LlvmEmitter, expr: ast.Expr, ret_ty: ast.TypeExpr) !void {
        switch (expr.kind) {
            .block => |block| {
                if (try self.emitScopedBlock(block, ret_ty)) return error.UnsupportedLlvmEmission;
            },
            else => try self.emitExprStatement(expr),
        }
    }

    fn emitScopedBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) !bool {
        var saved_types = std.StringHashMap(ast.TypeExpr).init(self.allocator);
        var restore_installed = false;
        errdefer if (!restore_installed) saved_types.deinit();
        var type_it = self.local_types.iterator();
        while (type_it.next()) |entry| try saved_types.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_slots = std.StringHashMap(LocalSlot).init(self.allocator);
        errdefer if (!restore_installed) saved_slots.deinit();
        var slot_it = self.local_slots.iterator();
        while (slot_it.next()) |entry| try saved_slots.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_pointer_local_provenance = std.StringHashMap(mir.PointerProvenance).init(self.allocator);
        errdefer if (!restore_installed) saved_pointer_local_provenance.deinit();
        var pointer_provenance_it = self.pointer_local_provenance.iterator();
        while (pointer_provenance_it.next()) |entry| try saved_pointer_local_provenance.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_local_aggregate_pointer_aliases = std.StringHashMap([]const u8).init(self.allocator);
        errdefer if (!restore_installed) saved_local_aggregate_pointer_aliases.deinit();
        var aggregate_pointer_alias_it = self.local_aggregate_pointer_aliases.iterator();
        while (aggregate_pointer_alias_it.next()) |entry| try saved_local_aggregate_pointer_aliases.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_local_pointer_array_aliases = std.StringHashMap([]const u8).init(self.allocator);
        errdefer if (!restore_installed) saved_local_pointer_array_aliases.deinit();
        var pointer_array_alias_it = self.local_pointer_array_aliases.iterator();
        while (pointer_array_alias_it.next()) |entry| try saved_local_pointer_array_aliases.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_aggregate_global_pointer_fields = try self.cloneOwnedStringProvenanceMap(&self.aggregate_global_pointer_fields);
        errdefer if (!restore_installed) self.deinitOwnedStringProvenanceMap(&saved_aggregate_global_pointer_fields);

        var saved_local_array_global_pointer_elements = try self.cloneOwnedStringProvenanceMap(&self.local_array_global_pointer_elements);
        errdefer if (!restore_installed) self.deinitOwnedStringProvenanceMap(&saved_local_array_global_pointer_elements);

        var saved_local_slice_global_pointer_arrays = std.StringHashMap([]const u8).init(self.allocator);
        errdefer if (!restore_installed) saved_local_slice_global_pointer_arrays.deinit();
        var local_slice_it = self.local_slice_global_pointer_arrays.iterator();
        while (local_slice_it.next()) |entry| try saved_local_slice_global_pointer_arrays.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_local_slice_pointer_array_ranges = std.StringHashMap(LocalSlicePointerArrayRange).init(self.allocator);
        errdefer if (!restore_installed) saved_local_slice_pointer_array_ranges.deinit();
        var local_slice_range_it = self.local_slice_pointer_array_ranges.iterator();
        while (local_slice_range_it.next()) |entry| try saved_local_slice_pointer_array_ranges.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_local_slice_aggregate_pointer_array_fields = try self.cloneOwnedStringValueMap(&self.local_slice_aggregate_pointer_array_fields);
        errdefer if (!restore_installed) self.deinitOwnedStringValueMap(&saved_local_slice_aggregate_pointer_array_fields);

        restore_installed = true;
        defer {
            self.local_types.deinit();
            self.local_slots.deinit();
            self.pointer_local_provenance.deinit();
            self.local_aggregate_pointer_aliases.deinit();
            self.local_pointer_array_aliases.deinit();
            self.deinitOwnedStringProvenanceMap(&self.aggregate_global_pointer_fields);
            self.deinitOwnedStringProvenanceMap(&self.local_array_global_pointer_elements);
            self.local_slice_global_pointer_arrays.deinit();
            self.local_slice_pointer_array_ranges.deinit();
            self.deinitOwnedStringValueMap(&self.local_slice_aggregate_pointer_array_fields);
            self.local_types = saved_types;
            self.local_slots = saved_slots;
            self.pointer_local_provenance = saved_pointer_local_provenance;
            self.local_aggregate_pointer_aliases = saved_local_aggregate_pointer_aliases;
            self.local_pointer_array_aliases = saved_local_pointer_array_aliases;
            self.aggregate_global_pointer_fields = saved_aggregate_global_pointer_fields;
            self.local_array_global_pointer_elements = saved_local_array_global_pointer_elements;
            self.local_slice_global_pointer_arrays = saved_local_slice_global_pointer_arrays;
            self.local_slice_pointer_array_ranges = saved_local_slice_pointer_array_ranges;
            self.local_slice_aggregate_pointer_array_fields = saved_local_slice_aggregate_pointer_array_fields;
        }

        const terminated = try self.emitBlock(block, ret_ty);
        try self.preserveOuterPointerLocalProvenanceAfterScope(&saved_types, &saved_pointer_local_provenance);
        try self.preserveOuterAggregatePointerFieldProvenanceAfterScope(&saved_types, &saved_aggregate_global_pointer_fields);
        try self.preserveOuterLocalArrayPointerElementProvenanceAfterScope(&saved_types, &saved_local_array_global_pointer_elements);
        return terminated;
    }

    fn preserveOuterPointerLocalProvenanceAfterScope(
        self: *LlvmEmitter,
        saved_types: *const std.StringHashMap(ast.TypeExpr),
        saved_pointer_local_provenance: *std.StringHashMap(mir.PointerProvenance),
    ) !void {
        var it = saved_types.keyIterator();
        while (it.next()) |name| {
            if (self.pointer_local_provenance.get(name.*)) |provenance| {
                try saved_pointer_local_provenance.put(name.*, provenance);
            } else {
                _ = saved_pointer_local_provenance.remove(name.*);
            }
        }
    }

    fn preserveOuterAggregatePointerFieldProvenanceAfterScope(
        self: *LlvmEmitter,
        saved_types: *const std.StringHashMap(ast.TypeExpr),
        saved_aggregate_global_pointer_fields: *std.StringHashMap(mir.PointerProvenance),
    ) !void {
        var local_it = saved_types.keyIterator();
        while (local_it.next()) |name| {
            self.removeOwnedAggregatePointerFieldsForLocal(saved_aggregate_global_pointer_fields, name.*);

            var field_it = self.aggregate_global_pointer_fields.iterator();
            while (field_it.next()) |entry| {
                if (!aggregatePointerFieldKeyMatchesLocal(entry.key_ptr.*, name.*)) continue;
                const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(owned_key);
                try saved_aggregate_global_pointer_fields.put(owned_key, entry.value_ptr.*);
            }
        }
    }

    fn preserveOuterLocalArrayPointerElementProvenanceAfterScope(
        self: *LlvmEmitter,
        saved_types: *const std.StringHashMap(ast.TypeExpr),
        saved_local_array_global_pointer_elements: *std.StringHashMap(mir.PointerProvenance),
    ) !void {
        var local_it = saved_types.keyIterator();
        while (local_it.next()) |name| {
            self.removeOwnedLocalArrayPointerElementsForLocal(saved_local_array_global_pointer_elements, name.*);

            var element_it = self.local_array_global_pointer_elements.iterator();
            while (element_it.next()) |entry| {
                if (!localArrayPointerElementKeyMatchesLocal(entry.key_ptr.*, name.*)) continue;
                const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(owned_key);
                try saved_local_array_global_pointer_elements.put(owned_key, entry.value_ptr.*);
            }
        }
    }

    fn removeOwnedLocalArrayPointerElementsForLocal(self: *LlvmEmitter, map: *std.StringHashMap(mir.PointerProvenance), local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = map.keyIterator();
            while (it.next()) |key| {
                if (localArrayPointerElementKeyMatchesLocal(key.*, local_name)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (map.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn removeOwnedAggregatePointerFieldsForLocal(self: *LlvmEmitter, map: *std.StringHashMap(mir.PointerProvenance), local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = map.keyIterator();
            while (it.next()) |key| {
                if (aggregatePointerFieldKeyMatchesLocal(key.*, local_name)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (map.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn emitAsmStmt(self: *LlvmEmitter, asm_stmt: ast.AsmStmt) !void {
        if (asm_stmt.form == .precise) return self.emitPreciseAsmStmt(asm_stmt);
        if (asm_stmt.form != .@"opaque" or asm_stmt.inputs.len != 0 or asm_stmt.outputs.len != 0) return error.UnsupportedLlvmEmission;
        // `--stub-asm` (host-native logic test): opaque asm is operand-less; preserve only the
        // memory barrier (an empty asm string with a `~{memory}` clobber) so the host backend
        // never emits the arch instruction while memory ordering is kept.
        if (self.stub_asm) {
            const sideeffect: []const u8 = if (asm_stmt.is_volatile) " sideeffect" else "";
            try self.out.print(self.allocator, "  call void asm{s} \"\", \"~{{memory}}\"(){s}\n", .{ sideeffect, try self.debugCallSuffix() });
            return;
        }
        const template = try llvmOpaqueAsmTemplate(self.scratch.allocator(), asm_stmt.templates);
        const constraints = try llvmAsmClobbers(self.scratch.allocator(), asm_stmt.clobbers);
        const sideeffect: []const u8 = if (asm_stmt.is_volatile) " sideeffect" else "";
        try self.out.print(self.allocator, "  call void asm{s} \"{s}\", \"{s}\"(){s}\n", .{ sideeffect, template, constraints, try self.debugCallSuffix() });
    }

    fn emitPreciseAsmStmt(self: *LlvmEmitter, asm_stmt: ast.AsmStmt) !void {
        // `--stub-asm` (host-native logic test): replace the arch instruction with a neutral
        // stub — evaluate each input (preserving any side effect) and define each output as
        // zero. The portable logic under test must not depend on the instruction's effect.
        if (self.stub_asm) {
            for (asm_stmt.inputs) |input| {
                _ = try self.emitExpr(input.value, input.ty);
            }
            for (asm_stmt.outputs) |output| {
                const slot = self.local_slots.get(output.name.text) orelse return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "  store {s} 0, ptr {s}{s}\n", .{ try self.llvmType(output.ty), slot.ptr, try self.debugCallSuffix() });
            }
            return;
        }
        const template = try llvmPreciseAsmTemplate(self.scratch.allocator(), asm_stmt.templates);
        const constraints = try llvmPreciseAsmConstraints(self.scratch.allocator(), asm_stmt);
        const ret_ty = try self.preciseAsmReturnType(asm_stmt.outputs);
        const sideeffect: []const u8 = if (asm_stmt.is_volatile) " sideeffect" else "";

        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (asm_stmt.inputs) |input| {
            try args.append(self.allocator, .{ .ty = input.ty, .value = try self.emitExpr(input.value, input.ty) });
        }

        const result: ?[]const u8 = if (asm_stmt.outputs.len == 0) null else try self.nextTemp();
        if (result) |name| {
            try self.out.print(self.allocator, "  {s} = call {s} asm{s} \"{s}\", \"{s}\"(", .{ name, ret_ty, sideeffect, template, constraints });
        } else {
            try self.out.print(self.allocator, "  call void asm{s} \"{s}\", \"{s}\"(", .{ sideeffect, template, constraints });
        }
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});

        const asm_result = result orelse return;
        for (asm_stmt.outputs, 0..) |output, i| {
            const slot = self.local_slots.get(output.name.text) orelse return error.UnsupportedLlvmEmission;
            const value = if (asm_stmt.outputs.len == 1) asm_result else blk: {
                const extracted = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ extracted, ret_ty, asm_result, i });
                break :blk extracted;
            };
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(output.ty), value, slot.ptr, try self.debugCallSuffix() });
        }
    }

    fn preciseAsmReturnType(self: *LlvmEmitter, outputs: []const ast.AsmOutput) ![]const u8 {
        if (outputs.len == 0) return "void";
        if (outputs.len == 1) return try self.llvmType(outputs[0].ty);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.scratch.allocator(), "{ ");
        for (outputs, 0..) |output, i| {
            if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
            try text.appendSlice(self.scratch.allocator(), try self.llvmType(output.ty));
        }
        try text.appendSlice(self.scratch.allocator(), " }");
        return text.toOwnedSlice(self.scratch.allocator());
    }

    fn emitExprStatement(self: *LlvmEmitter, expr: ast.Expr) anyerror!void {
        self.emitExprStatementInner(expr) catch |err| switch (err) {
            error.UnsupportedLlvmEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprStatementInner(self: *LlvmEmitter, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .unreachable_expr => {
                _ = try self.emitNeverExpr(expr);
                return;
            },
            .call => |call| {
                // A diverging call statement — `trap(.Assert);` or a `-> never` function — halts
                // the program; emit the trap/call followed by `unreachable` (no value needed even
                // in a value-returning function, since this path does not fall through).
                if (try self.emitNeverExpr(expr)) return;
                if (isDropCall(call.callee.*)) {
                    if (call.args.len != 1) return error.UnsupportedLlvmEmission;
                    const arg_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
                    _ = try self.emitExpr(call.args[0], arg_ty);
                    return;
                }
                // A trait-object dispatch as a statement (`d.m(args);`) — including a
                // `-> void` method, whose result is simply discarded.
                if (self.dynDispatchTrait(call.callee.*)) |trait| {
                    _ = try self.emitDynDispatch(call, trait);
                    return;
                }
                if (try self.emitBuiltinVoidCall(call)) return;
                // A `va.*` intrinsic as a statement (`va.end(&ap);`): route through emitCall,
                // which emits the call/instruction; any result (none for va.end) is discarded.
                if (vaCallMember(call.callee.*) != null) {
                    _ = try self.emitCall(call, simpleType(expr.span, "void"), expr.span);
                    return;
                }
                if (self.callReturnType(call)) |ret_ty| {
                    // A `void` or `-> never` call statement produces no value, so it is emitted
                    // without a result name (a named void instruction is invalid LLVM).
                    if (typeNameEql(ret_ty, "void") or typeNameEql(ret_ty, "never")) {
                        try self.emitVoidStatementCall(call, expr.span);
                        return;
                    }
                    _ = try self.emitCall(call, ret_ty, expr.span);
                    return;
                }
                self.reportUnsupported(expr.span, "call statement");
                return error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| try self.emitExprStatement(inner.*),
            else => {
                const ty = self.exprType(expr) orelse {
                    self.reportUnsupported(expr.span, @tagName(expr.kind));
                    return error.UnsupportedLlvmEmission;
                };
                _ = try self.emitExpr(expr, ty);
            },
        }
    }

    /// Emit a single `alloca` for a function-local slot. It is routed to the entry-block
    /// buffer (`entry_allocas`) so the slot is a STATIC alloca regardless of where the
    /// declaration textually appears — critical for declarations inside loops, where an
    /// alloca emitted in the loop body would grow the stack every iteration (a real bug
    /// that corrupts memory once the loop runs enough times). Falls back to inline emission
    /// if used outside a function body (defensive; all real callers run inside one).
    fn emitAlloca(self: *LlvmEmitter, ptr: []const u8, ty: []const u8) !void {
        if (self.entry_allocas) |buf| {
            try buf.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, ty });
        } else {
            try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, ty });
        }
    }

    /// Emit the common "allocate a slot then store a value into it" idiom:
    ///   {ptr} = alloca {ty}   (hoisted to the entry block)
    ///   store {ty} {value}, ptr {ptr}{dbg}   (at the current position)
    fn emitAllocaStore(self: *LlvmEmitter, ptr: []const u8, ty: []const u8, value: []const u8) !void {
        try self.emitAlloca(ptr, ty);
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ ty, value, ptr, try self.debugCallSuffix() });
    }

    /// Emit a conditional branch where one side leads to a trap-and-unreachable block.
    /// `label1`/`label2` are the true/false branch targets; `block_label` is the label
    /// whose block contains the trap call (followed by `unreachable`), and `after_label`
    /// is the continuation label printed after that block. This faithfully reproduces
    /// both branch polarities — callers choose which label is the trap target.
    fn emitTrapBranch(
        self: *LlvmEmitter,
        cond: []const u8,
        label1: []const u8,
        label2: []const u8,
        block_label: []const u8,
        after_label: []const u8,
        trap_fn: []const u8,
    ) !void {
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n  call void @mc_trap_{s}(){s}\n  unreachable\n{s}:\n", .{ cond, label1, label2, try self.debugCallSuffix(), block_label, trap_fn, try self.debugCallSuffix(), after_label });
    }

    fn emitAssert(self: *LlvmEmitter, expr: ast.Expr) !void {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        const condition = try self.emitExpr(expr, ty);
        const cont = try self.nextLabel("assert_ok");
        const trap = try self.nextLabel("trap_assert");
        try self.emitTrapBranch(condition, cont, trap, trap, cont, "Assert");
    }

    fn emitTryExpr(self: *LlvmEmitter, operand: ast.Expr, mapped: ?*ast.Expr, expected_ty: ast.TypeExpr) ![]const u8 {
        const operand_ty = self.exprType(operand) orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(expected_ty);
        if (self.resultInfo(operand_ty)) |info| {
            _ = try self.resultPayloadLlvmType(info.ok_ty);
            const value = try self.emitExpr(operand, operand_ty);
            if (try self.emitResultPropagationCheck(value, operand_ty, info, mapped, operand.span)) {
                // continued in the ok block
            } else {
                try self.emitResultUnwrapCheck(value, operand_ty);
            }
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, try self.llvmType(operand_ty), value });
            return payload;
        }
        const inner_ty = self.nullableInnerType(operand_ty) orelse return error.UnsupportedLlvmEmission;
        // Value optional `?T`: trap on absent (present tag false), then yield the payload.
        if (self.targetIsValueOptional(operand_ty)) {
            const value = try self.emitExpr(operand, operand_ty);
            const opt_ty = try self.llvmType(operand_ty);
            const present = try self.nextTemp();
            const is_absent = try self.nextTemp();
            const trap = try self.nextLabel("trap_null");
            const cont = try self.nextLabel("nonnull");
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ present, opt_ty, value });
            try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ is_absent, present });
            try self.emitTrapBranch(is_absent, trap, cont, trap, cont, "NullUnwrap");
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, opt_ty, value });
            return payload;
        }
        const value = try self.emitExpr(operand, operand_ty);
        try self.emitNullUnwrapCheck(value, inner_ty);
        return value;
    }

    fn emitResultPropagationCheck(self: *LlvmEmitter, value: []const u8, operand_ty: ast.TypeExpr, info: ResultTypeInfo, mapped: ?*ast.Expr, span: ast.Span) !bool {
        const return_ty = self.current_return_ty orelse return false;
        const return_info = self.resultInfo(return_ty) orelse return false;
        // G8: when the operand error (E1) differs from the function error (E2), a
        // `#[error_from]` conversion is invoked on the propagated error. When the
        // error types match no conversion resolves and the same-repr fast path is
        // preserved byte-for-byte. A genuine E1!=E2 with no conversion is rejected
        // by sema (E_NO_ERROR_CONVERSION), so it never reaches here.
        const convert_fn = error_from.resolveTypes(&self.fn_sigs, info.err_ty, return_info.err_ty);
        if (mapped == null and convert_fn == null and !std.mem.eql(u8, try self.llvmType(info.err_ty), try self.llvmType(return_info.err_ty))) return false;

        const is_ok = try self.nextTemp();
        const ok_label = try self.nextLabel("try_ok");
        const err_label = try self.nextLabel("try_err");
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(operand_ty), value });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ is_ok, ok_label, err_label, try self.debugCallSuffix(), err_label });
        const propagated_err = if (mapped) |mapped_expr|
            try self.emitExpr(mapped_expr.*, return_info.err_ty)
        else blk: {
            const err_value = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 2\n", .{ err_value, try self.llvmType(operand_ty), value });
            if (convert_fn) |cf| {
                const converted = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}){s}\n", .{ converted, try self.llvmType(return_info.err_ty), cf, try self.llvmType(info.err_ty), err_value, try self.debugCallSuffix() });
                break :blk converted;
            }
            break :blk err_value;
        };
        const ok_zero = try self.resultPayloadZero(return_info.ok_ty);
        const propagated_value = try self.emitResultValue(return_ty, "false", ok_zero, propagated_err);
        // `?` returns from the function on the error branch, so it must run every active
        // defer first — exactly like an explicit `return`. Flush from 0 (whole function
        // scope) without truncating: the ok path continues after this block with the same
        // active defers.
        try self.emitDeferredCleanupsFrom(0, return_ty);
        try self.emitReturnValue(return_ty, propagated_value, span);
        try self.out.print(self.allocator, "{s}:\n", .{ok_label});
        return true;
    }

    fn emitResultUnwrapCheck(self: *LlvmEmitter, value: []const u8, result_ty: ast.TypeExpr) !void {
        const is_ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_result");
        const cont = try self.nextLabel("result_ok");
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(result_ty), value });
        try self.emitTrapBranch(is_ok, cont, trap, trap, cont, "InvalidRepresentation");
    }

    // The pointer word a nullable niche-tests against: a thin `?*T` value IS the pointer;
    // a `?*dyn Trait` fat pointer's niche is its data word (`extractvalue … , 0`).
    fn nullableDataWord(self: *LlvmEmitter, value: []const u8, inner_ty: ast.TypeExpr) ![]const u8 {
        if (!isDynTraitLlvmType(self.resolveAliasType(inner_ty))) return value;
        const data = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {{ ptr, ptr }} {s}, 0\n", .{ data, value });
        return data;
    }

    fn emitNullableSomeTest(self: *LlvmEmitter, dest: []const u8, value: []const u8, inner_ty: ast.TypeExpr) !void {
        const word = try self.nullableDataWord(value, inner_ty);
        try self.out.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ dest, word });
    }

    fn emitNullUnwrapCheck(self: *LlvmEmitter, value: []const u8, inner_ty: ast.TypeExpr) !void {
        const word = try self.nullableDataWord(value, inner_ty);
        const is_null = try self.nextTemp();
        const trap = try self.nextLabel("trap_null");
        const cont = try self.nextLabel("nonnull");
        try self.out.print(self.allocator, "  {s} = icmp eq ptr {s}, null\n", .{ is_null, word });
        try self.emitTrapBranch(is_null, trap, cont, trap, cont, "NullUnwrap");
    }

    fn emitNullableIfLet(self: *LlvmEmitter, node: ast.IfLet, ret_ty: ast.TypeExpr) !bool {
        const binding = switch (node.pattern.kind) {
            .bind => |ident| ident,
            else => return false,
        };
        const subject_ty = self.exprType(node.value) orelse return false;
        const inner_ty = self.nullableInnerType(subject_ty) orelse return false;
        const subject = try self.emitExpr(node.value, subject_ty);
        const is_value_opt = self.targetIsValueOptional(subject_ty);
        const then_label = try self.nextLabel("nullable_some");
        const else_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        if (is_value_opt) {
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_some, try self.llvmType(subject_ty), subject });
        } else {
            try self.emitNullableSomeTest(is_some, subject, inner_ty);
        }
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ is_some, then_label, else_label, try self.debugCallSuffix(), then_label });

        const old_type = self.local_types.fetchRemove(binding.text);
        const old_slot = self.local_slots.fetchRemove(binding.text);
        const old_global_pointer = self.pointer_local_provenance.fetchRemove(binding.text);
        const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(binding.text);
        const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(binding.text);
        const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(binding.text);
        const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(binding.text);
        const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(binding.text);
        var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(binding.text);
        var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(binding.text);
        defer restoreLocal(&self.local_types, binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, binding.text, old_slot) catch {};
        defer restoreLocal(&self.pointer_local_provenance, binding.text, old_global_pointer) catch {};
        defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.text, old_aggregate_pointer_alias) catch {};
        defer restoreLocal(&self.local_pointer_array_aliases, binding.text, old_pointer_array_alias) catch {};
        defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.text, old_slice_global_pointer_array) catch {};
        defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.text, old_slice_pointer_array_range) catch {};
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.text, old_slice_aggregate_pointer_array_field) catch {};
        defer self.restoreAggregatePointerFieldsForLocal(binding.text, &old_aggregate_pointer_fields) catch {};
        defer self.restoreLocalArrayPointerElementsForLocal(binding.text, &old_local_array_pointer_elements) catch {};

        const binding_ptr = try self.nextBindingPtr(binding.text);
        const binding_value = if (is_value_opt) blk: {
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, try self.llvmType(subject_ty), subject });
            break :blk payload;
        } else subject;
        try self.emitAllocaStore(binding_ptr, try self.llvmType(inner_ty), binding_value);
        try self.local_types.put(binding.text, inner_ty);
        try self.local_slots.put(binding.text, .{ .ty = inner_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlock(node.then_block, ret_ty);
        if (!then_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });

        _ = self.local_types.remove(binding.text);
        _ = self.local_slots.remove(binding.text);
        _ = self.pointer_local_provenance.remove(binding.text);
        _ = self.local_aggregate_pointer_aliases.remove(binding.text);
        _ = self.local_pointer_array_aliases.remove(binding.text);
        self.clearLocalSliceGlobalPointerArray(binding.text);
        self.clearAggregatePointerFieldsForLocal(binding.text);
        self.clearLocalArrayPointerElementsForLocal(binding.text);

        try self.out.print(self.allocator, "{s}:\n", .{else_label});
        const else_terminated = if (node.else_block) |else_block| try self.emitBlock(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultIfLet(self: *LlvmEmitter, node: ast.IfLet, ret_ty: ast.TypeExpr) !bool {
        const tag_bind = switch (node.pattern.kind) {
            .tag_bind => |tag_bind| tag_bind,
            else => return false,
        };
        const is_ok_pattern = if (std.mem.eql(u8, tag_bind.tag.text, "ok"))
            true
        else if (std.mem.eql(u8, tag_bind.tag.text, "err"))
            false
        else
            return false;
        const subject_ty = self.exprType(node.value) orelse return false;
        const info = self.resultInfo(subject_ty) orelse return false;
        const binding_ty = if (is_ok_pattern) info.ok_ty else info.err_ty;
        const payload_index: u8 = if (is_ok_pattern) 1 else 2;
        const subject = try self.emitExpr(node.value, subject_ty);
        const then_label = try self.nextLabel(if (is_ok_pattern) "result_ok" else "result_err");
        const else_label = try self.nextLabel(if (is_ok_pattern) "result_err" else "result_ok");
        const end_label = try self.nextLabel("result_end");
        const is_ok = try self.nextTemp();
        const matches = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(subject_ty), subject });
        if (is_ok_pattern) {
            try self.out.print(self.allocator, "  {s} = icmp eq i1 {s}, true\n", .{ matches, is_ok });
        } else {
            try self.out.print(self.allocator, "  {s} = icmp eq i1 {s}, false\n", .{ matches, is_ok });
        }
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ matches, then_label, else_label, try self.debugCallSuffix(), then_label });

        const old_type = self.local_types.fetchRemove(tag_bind.binding.text);
        const old_slot = self.local_slots.fetchRemove(tag_bind.binding.text);
        const old_global_pointer = self.pointer_local_provenance.fetchRemove(tag_bind.binding.text);
        const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(tag_bind.binding.text);
        const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(tag_bind.binding.text);
        const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(tag_bind.binding.text);
        const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(tag_bind.binding.text);
        const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(tag_bind.binding.text);
        var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(tag_bind.binding.text);
        var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(tag_bind.binding.text);
        defer restoreLocal(&self.local_types, tag_bind.binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, tag_bind.binding.text, old_slot) catch {};
        defer restoreLocal(&self.pointer_local_provenance, tag_bind.binding.text, old_global_pointer) catch {};
        defer restoreLocal(&self.local_aggregate_pointer_aliases, tag_bind.binding.text, old_aggregate_pointer_alias) catch {};
        defer restoreLocal(&self.local_pointer_array_aliases, tag_bind.binding.text, old_pointer_array_alias) catch {};
        defer restoreLocal(&self.local_slice_global_pointer_arrays, tag_bind.binding.text, old_slice_global_pointer_array) catch {};
        defer restoreLocal(&self.local_slice_pointer_array_ranges, tag_bind.binding.text, old_slice_pointer_array_range) catch {};
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, tag_bind.binding.text, old_slice_aggregate_pointer_array_field) catch {};
        defer self.restoreAggregatePointerFieldsForLocal(tag_bind.binding.text, &old_aggregate_pointer_fields) catch {};
        defer self.restoreLocalArrayPointerElementsForLocal(tag_bind.binding.text, &old_local_array_pointer_elements) catch {};

        const binding_ptr = try self.nextBindingPtr(tag_bind.binding.text);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
        try self.emitAllocaStore(binding_ptr, try self.resultPayloadLlvmType(binding_ty), payload);
        try self.local_types.put(tag_bind.binding.text, binding_ty);
        try self.local_slots.put(tag_bind.binding.text, .{ .ty = binding_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlock(node.then_block, ret_ty);
        if (!then_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });

        _ = self.local_types.remove(tag_bind.binding.text);
        _ = self.local_slots.remove(tag_bind.binding.text);
        _ = self.pointer_local_provenance.remove(tag_bind.binding.text);
        _ = self.local_aggregate_pointer_aliases.remove(tag_bind.binding.text);
        _ = self.local_pointer_array_aliases.remove(tag_bind.binding.text);
        self.clearLocalSliceGlobalPointerArray(tag_bind.binding.text);
        self.clearAggregatePointerFieldsForLocal(tag_bind.binding.text);
        self.clearLocalArrayPointerElementsForLocal(tag_bind.binding.text);

        try self.out.print(self.allocator, "{s}:\n", .{else_label});
        const else_terminated = if (node.else_block) |else_block| try self.emitBlock(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitNeverExpr(self: *LlvmEmitter, expr: ast.Expr) !bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.out.print(self.allocator, "  call void @mc_trap_Unreachable(){s}\n  unreachable\n", .{try self.debugCallSuffix()});
                return true;
            },
            .call => |call| if (trapHelperForCall(call)) |helper| {
                try self.out.print(self.allocator, "  call void @{s}(){s}\n  unreachable\n", .{ helper, try self.debugCallSuffix() });
                return true;
            },
            .grouped => |inner| return try self.emitNeverExpr(inner.*),
            else => return false,
        }
        return false;
    }

    // True when an expression *statement* emits its own `unreachable` terminator: `unreachable`
    // or a `trap(...)`. Such a statement terminates its block, so even in a value-returning
    // function the block ends there with no fall-through. (A `-> never` call is NOT included: it
    // lowers as an ordinary call and the enclosing block falls through to its normal terminator.)
    fn exprStatementDiverges(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .unreachable_expr => true,
            .call => |call| trapHelperForCall(call) != null,
            .grouped => |inner| self.exprStatementDiverges(inner.*),
            else => false,
        };
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast.LocalDecl) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const ty = local.ty orelse self.exprType(init) orelse return error.UnsupportedLlvmEmission;
        const resolved_ty = self.resolveAliasType(ty);
        const name = local.names[0].text;
        const ptr = try self.nextBindingPtr(name);
        self.clearAggregatePointerAliasesToLocal(name);
        _ = self.local_pointer_array_aliases.remove(name);
        self.clearLocalPointerArrayAliasesBackedByArray(name);
        self.clearLocalSliceGlobalPointerArray(name);
        self.clearLocalSlicesBackedByArray(name);
        if (self.isVaListType(ty)) {
            try self.emitAlloca(ptr, try self.vaListStorageType());
            try self.local_types.put(name, ty);
            try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr, .kind = .va_list_local });
            const dst = try self.vaListCursorPtrFromStorage(ptr);
            if (init.kind == .call and isVaStartCall(init.kind.call.callee.*)) {
                try self.out.print(self.allocator, "  call void @llvm.va_start(ptr {s})\n", .{dst});
                return;
            }
            const src = try self.emitVaListCursorForCopySource(init);
            try self.out.print(self.allocator, "  call void @llvm.va_copy(ptr {s}, ptr {s})\n", .{ dst, src });
            return;
        }
        const llvm_ty = try self.llvmType(ty);
        try self.emitAlloca(ptr, llvm_ty);
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr });
        try self.updatePointerProvenanceFromMirOrLocalProof(name, ty, init, .emit_comment);
        try self.updateAggregatePointerAliasProvenance(name, ty, init);
        try self.updateLocalPointerArrayAliasProvenanceFromInit(name, ty, init);
        try self.updateAggregatePointerFieldProvenanceFromInit(name, ty, init);
        try self.updateLocalArrayPointerElementProvenanceFromInit(name, ty, init);
        try self.updateLocalSlicePointerElementProvenanceFromInit(name, ty, init);
        if (!self.isPointerLikeType(ty)) try self.applyMirPointerProvenanceForLocalInitializer(name, ty, init);
        try self.emitDebugDeclare(name, ty, ptr, local.names[0].span, null);
        // `var ap: va_list = va.start();` — the slot IS the va_list cursor storage; initialize
        // it in place with llvm.va_start (it has no value to store).
        if (init.kind == .call and isVaStartCall(init.kind.call.callee.*)) {
            try self.out.print(self.allocator, "  call void @llvm.va_start(ptr {s})\n", .{ptr});
            return;
        }
        if (isUninitExpr(init)) {
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, try self.zeroInitializer(ty), ptr, try self.debugCallSuffix() });
            return;
        }
        if (resolved_ty.kind == .array) {
            if (init.kind == .array_literal) {
                try self.emitArrayLiteralStores(ptr, resolved_ty, init.kind.array_literal);
            } else {
                const value = try self.emitExprWithMirRangeTarget(init, ty, name);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            }
            return;
        }
        if (self.structDeclForType(resolved_ty)) |_| {
            if (init.kind == .struct_literal) {
                try self.emitStructLiteralStores(ptr, resolved_ty, init.kind.struct_literal);
            } else {
                const value = try self.emitExprWithMirRangeTarget(init, ty, name);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            }
            return;
        }
        const value = try self.emitExprWithMirRangeTarget(init, ty, name);
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
    }

    fn emitAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr, span: ast.Span) !void {
        if (try self.emitIndexAssignment(target, value_expr, span)) return;
        if (try self.emitMemberAssignment(target, value_expr)) return;
        if (assignmentIdent(target)) |ident| {
            if (self.local_slots.get(ident.text)) |slot| {
                if (self.isVaListType(slot.ty)) {
                    const dst = try self.vaListCursorPtrFromSlot(slot);
                    const src = try self.emitVaListCursorForCopySource(value_expr);
                    try self.out.print(self.allocator, "  call void @llvm.va_copy(ptr {s}, ptr {s})\n", .{ dst, src });
                    return;
                }
                const llvm_ty = try self.llvmType(slot.ty);
                const value = try self.emitExprWithMirRangeTarget(value_expr, slot.ty, ident.text);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, slot.ptr, try self.debugCallSuffix() });
                try self.updatePointerProvenanceAssignmentFromMirOrLocalProof(ident.text, slot.ty, value_expr, span);
                _ = self.local_aggregate_pointer_aliases.remove(ident.text);
                _ = self.local_pointer_array_aliases.remove(ident.text);
                self.clearLocalSlicesBackedByArray(ident.text);
                self.clearLocalPointerArrayAliasesBackedByArray(ident.text);
                try self.updateAggregatePointerFieldProvenanceFromInit(ident.text, slot.ty, value_expr);
                try self.updateLocalArrayPointerElementProvenanceFromInit(ident.text, slot.ty, value_expr);
                try self.updateLocalSlicePointerElementProvenanceFromInit(ident.text, slot.ty, value_expr);
                if (!self.isPointerLikeType(slot.ty)) try self.applyMirPointerProvenanceForAssignment(ident.text, slot.ty, value_expr, span);
                return;
            }
            if (self.global_types.get(ident.text)) |ty| {
                const llvm_ty = try self.llvmType(ty);
                const value = try self.emitExprWithMirRangeTarget(value_expr, ty, ident.text);
                const global_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                try self.emitOrdinaryShadowHook(global_ptr, ty, .store_pre);
                try self.emitOrdinaryStore(ty, llvm_ty, value, global_ptr, true);
                try self.emitOrdinaryShadowHook(global_ptr, ty, .store_post);
                return;
            }
            return error.UnsupportedLlvmEmission;
        }
        if (derefTarget(target)) |ptr_expr| {
            const pointee_ty = self.derefPointeeType(ptr_expr) orelse return error.UnsupportedLlvmEmission;
            const llvm_ty = try self.llvmType(pointee_ty);
            const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
            const value = try self.emitExprWithMirRangeTarget(value_expr, pointee_ty, "value");
            if (self.isAggregateType(pointee_ty) and !self.pointerExprHasProvenLocalStorage(ptr_expr)) {
                try self.emitRaceTolerantAggregateDerefStore(ptr, pointee_ty, value);
                if (self.localPointerArrayAliasBaseName(target)) |array_name| {
                    self.invalidateLocalPointerArrayBackedByArrayWrite(array_name);
                }
                self.invalidateAggregatePointerDerefAssignment(ptr_expr);
                return;
            }
            const use_atomic = self.derefUsesRaceTolerantLowering(ptr_expr, pointee_ty);
            if (use_atomic) try self.emitOrdinaryShadowHook(ptr, pointee_ty, .store_pre);
            try self.emitOrdinaryStore(pointee_ty, llvm_ty, value, ptr, use_atomic);
            if (use_atomic) try self.emitOrdinaryShadowHook(ptr, pointee_ty, .store_post);
            if (self.localPointerArrayAliasBaseName(target)) |array_name| {
                self.invalidateLocalPointerArrayBackedByArrayWrite(array_name);
            }
            self.invalidateAggregatePointerDerefAssignment(ptr_expr);
            return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitIndexAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr, span: ast.Span) !bool {
        return switch (target.kind) {
            .index => |node| blk: {
                if (overlayMemberFromIndexBase(node.base.*)) |member| {
                    if (self.overlayField(member.base.*, member.name.text)) |field| {
                        const element_ty = overlayArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                        const ptr = try self.emitIndexAddress(node);
                        const value = try self.emitExpr(value_expr, element_ty);
                        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(element_ty), value, ptr, try self.debugCallSuffix() });
                        break :blk true;
                    }
                }
                const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const value = try self.emitExpr(value_expr, element_ty);
                if (self.aggregateIndexUsesRaceTolerantLowering(node.base.*, element_ty)) {
                    try self.emitRaceTolerantAggregateDerefStore(ptr, element_ty, value);
                    try self.updateLocalArrayPointerElementProvenanceFromAssignment(target, element_ty, value_expr);
                    try self.updateAggregateArrayPointerElementProvenanceFromAssignment(target, element_ty, value_expr);
                    self.invalidateLocalSlicePointerElementProvenanceFromAssignment(target);
                    try self.applyMirPointerProvenanceForIndexAssignment(target, value_expr, span);
                    break :blk true;
                }
                const is_global = self.indexBaseIsGlobal(node);
                const use_atomic = is_global or self.scalarIndexUsesRaceTolerantLowering(node.base.*, element_ty);
                try self.emitOrdinaryShadowHook(ptr, element_ty, .store_pre);
                try self.emitOrdinaryStore(element_ty, try self.llvmType(element_ty), value, ptr, use_atomic);
                if (use_atomic) try self.emitOrdinaryShadowHook(ptr, element_ty, .store_post);
                try self.updateLocalArrayPointerElementProvenanceFromAssignment(target, element_ty, value_expr);
                try self.updateAggregateArrayPointerElementProvenanceFromAssignment(target, element_ty, value_expr);
                self.invalidateLocalSlicePointerElementProvenanceFromAssignment(target);
                try self.applyMirPointerProvenanceForIndexAssignment(target, value_expr, span);
                break :blk true;
            },
            .grouped => |inner| try self.emitIndexAssignment(inner.*, value_expr, span),
            else => false,
        };
    }

    fn emitBuiltinVoidCall(self: *LlvmEmitter, call: anytype) !bool {
        if (self.maybeUninitCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "write")) return false;
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const ptr = try self.storageBaseAddress(info.base);
            const value = try self.emitExpr(call.args[0], info.payload_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(info.payload_ty), value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (self.mirCallTargetKindAt(call.callee.*.span) == .raw_store) {
            if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const value_ty = call.type_args[0];
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const value = try self.emitExpr(call.args[1], value_ty);
            const ptr = try self.nextTemp();
            const llvm_ty = try self.llvmType(value_ty);
            if (rawScalarTypeName(value_ty) == null) {
                // Aggregate (non-scalar) T: whole-object typed store, mirroring how
                // `raw.ptr<T>(addr)` + deref already lowers a struct assignment. The
                // sanitizer hooks below key off scalar-sized accesses, so aggregate
                // stores lower to a plain (uninstrumented) typed store, matching the C
                // backend where aggregate stores bypass the mc_raw_store_* helpers.
                try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}, align {d}{s}\n", .{ llvm_ty, value, ptr, self.llvmAlignOf(value_ty), try self.debugCallSuffix() });
                return true;
            }
            // KASAN (D2.1): consult the shadow before the store — a poisoned (freed/
            // redzone) target traps in mc_ksan_check. Scalar size == llvmAlignOf here.
            // KMSAN (D2.2): call mc_ksan_store before the write. The hook must not reject
            // UNINIT bytes because first writes initialize them, but it does reject POISON.
            if (self.msan) {
                try self.out.print(self.allocator, "  call void @mc_ksan_store(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(value_ty) });
            } else if (self.ksan) {
                try self.out.print(self.allocator, "  call void @mc_ksan_check(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(value_ty) });
            }
            // KCSAN (D2.3): bracket the unsynchronized store with a write watchpoint hook so a
            // concurrent access lands inside the watch window. Mirrors the C backend's csan path.
            if (self.csan) try self.out.print(self.allocator, "  call void @mc_csan_write(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(value_ty) });
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "write")) return false;
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const ordering = orderingArg(call.args[1]) orelse return error.UnsupportedLlvmEmission;
            const raw_value = try self.emitExpr(call.args[0], info.value_ty);
            const value = if (std.mem.eql(u8, try self.llvmType(info.value_ty), try self.llvmType(info.storage_ty)))
                raw_value
            else
                try self.castValue(raw_value, info.value_ty, info.storage_ty);
            try self.emitMmioFence(ordering, .before_store);
            const ptr = try self.emitMmioRegisterAddress(info);
            try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(info.storage_ty), value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (self.dmaCacheCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            _ = try self.emitExpr(call.args[0], info.dma_ty);
            if (std.mem.eql(u8, info.op, "clean")) {
                try self.out.print(self.allocator, "  fence release{s}\n", .{try self.debugCallSuffix()});
            } else if (std.mem.eql(u8, info.op, "invalidate")) {
                try self.out.print(self.allocator, "  fence acquire{s}\n", .{try self.debugCallSuffix()});
            } else {
                return error.UnsupportedLlvmEmission;
            }
            return true;
        }
        if (self.mirCallTargetKindAt(call.callee.*.span) == .cpu_pause) {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            try self.out.print(self.allocator, "  call void asm sideeffect \"pause\", \"~{{memory}}\"(){s}\n", .{try self.debugCallSuffix()});
            return true;
        }
        if (self.mirCallTargetKindAt(call.callee.*.span)) |fence_kind| {
            const ordering: ?[]const u8 = switch (fence_kind) {
                .fence_full => "seq_cst",
                .fence_release => "release",
                .fence_acquire => "acquire",
                else => null,
            };
            if (ordering) |value| {
                if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "  fence {s}{s}\n", .{ value, try self.debugCallSuffix() });
                return true;
            }
        }
        if (self.atomicCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "store")) return false;
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const ordering = atomicOrderingArg(call.args, 1) orelse return error.UnsupportedLlvmEmission;
            const llvm_order = atomicLlvmOrdering(ordering, .store) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.atomicAddress(info);
            const value = try self.emitAtomicValueForStorage(call.args[0], info.payload_ty);
            try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} {s}, align {d}{s}\n", .{ try self.atomicStorageLlvmType(info.payload_ty), value, ptr, llvm_order, self.llvmAlignOf(info.payload_ty), try self.debugCallSuffix() });
            return true;
        }
        return false;
    }

    fn emitMemberAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !bool {
        return switch (target.kind) {
            .member => |node| blk: {
                const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
                if (self.packedBitsInfoForType(base_ty)) |info| {
                    const bit_index = self.packedBitsFieldIndex(info, node.name.text) orelse return error.UnsupportedLlvmEmission;
                    const ptr = try self.packedBitsBaseAddress(node.base.*);
                    const llvm_ty = try self.llvmType(info.repr);
                    const current = try self.nextTemp();
                    const set_value = try self.nextTemp();
                    const clear_value = try self.nextTemp();
                    const result = try self.nextTemp();
                    const flag = try self.emitExpr(value_expr, simpleType(value_expr.span, "bool"));
                    try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ current, llvm_ty, ptr });
                    try self.out.print(self.allocator, "  {s} = or {s} {s}, {d}\n", .{ set_value, llvm_ty, current, packedBitsMask(bit_index) });
                    try self.out.print(self.allocator, "  {s} = and {s} {s}, {d}\n", .{ clear_value, llvm_ty, current, packedBitsClearMask(info, bit_index) orelse return error.UnsupportedLlvmEmission });
                    try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} {s}\n", .{ result, flag, llvm_ty, set_value, llvm_ty, clear_value });
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, result, ptr, try self.debugCallSuffix() });
                    break :blk true;
                }
                if (self.overlayField(node.base.*, node.name.text)) |field| {
                    // Array views (byte or non-byte) are written element-wise via the
                    // index path; a bare member store only applies to scalar members.
                    if (overlayArrayElementType(field.ty) != null) return error.UnsupportedLlvmEmission;
                    const ptr = try self.emitOverlayFieldAddress(node.base.*, field);
                    const value = try self.emitExpr(value_expr, field.ty);
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, ptr, try self.debugCallSuffix() });
                    break :blk true;
                }
                const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitMemberAddress(node);
                const value = try self.emitExpr(value_expr, field.ty);
                if (self.isAggregateType(field.ty) and self.pointerMemberBaseUsesRaceTolerantLowering(node.base.*)) {
                    try self.emitRaceTolerantAggregateDerefStore(ptr, field.ty, value);
                    try self.updateAggregatePointerFieldProvenanceFromAssignment(node.base.*, node.name.text, field.ty, value_expr);
                    break :blk true;
                }
                if (self.aggregateIndexedMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
                    try self.emitRaceTolerantAggregateDerefStore(ptr, field.ty, value);
                    try self.updateAggregatePointerFieldProvenanceFromAssignment(node.base.*, node.name.text, field.ty, value_expr);
                    break :blk true;
                }
                if (self.scalarPointerMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
                    try self.emitOrdinaryShadowHook(ptr, field.ty, .store_pre);
                    try self.emitOrdinaryStore(field.ty, try self.llvmType(field.ty), value, ptr, true);
                    try self.emitOrdinaryShadowHook(ptr, field.ty, .store_post);
                    try self.updateAggregatePointerFieldProvenanceFromAssignment(node.base.*, node.name.text, field.ty, value_expr);
                    break :blk true;
                }
                if (self.scalarIndexedMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
                    try self.emitOrdinaryShadowHook(ptr, field.ty, .store_pre);
                    try self.emitOrdinaryStore(field.ty, try self.llvmType(field.ty), value, ptr, true);
                    try self.emitOrdinaryShadowHook(ptr, field.ty, .store_post);
                    try self.updateAggregatePointerFieldProvenanceFromAssignment(node.base.*, node.name.text, field.ty, value_expr);
                    break :blk true;
                }
                const field_global = self.memberBaseIsGlobal(node);
                try self.emitOrdinaryShadowHook(ptr, field.ty, .store_pre);
                try self.emitOrdinaryStore(field.ty, try self.llvmType(field.ty), value, ptr, field_global);
                if (field_global) try self.emitOrdinaryShadowHook(ptr, field.ty, .store_post);
                try self.updateAggregatePointerFieldProvenanceFromAssignment(node.base.*, node.name.text, field.ty, value_expr);
                break :blk true;
            },
            .grouped => |inner| try self.emitMemberAssignment(inner.*, value_expr),
            else => false,
        };
    }

    fn emitLoop(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        return switch (loop.kind) {
            .@"while" => try self.emitWhile(loop, ret_ty),
            .@"for" => try self.emitFor(loop, ret_ty),
        };
    }

    fn emitWhile(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        if (loop.kind != .@"while") return error.UnsupportedLlvmEmission;
        const condition_expr = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const condition_ty = self.exprType(condition_expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(condition_ty, "bool")) return error.UnsupportedLlvmEmission;

        const cond_label = try self.nextLabel("while_cond");
        const body_label = try self.nextLabel("while_body");
        const end_label = try self.nextLabel("while_end");

        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const condition = try self.emitExpr(condition_expr, condition_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_label, end_label, try self.debugCallSuffix(), body_label });
        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = cond_label, .cleanup_start = self.defer_stack.items.len, .label = if (loop.loop_label) |l| l.text else null });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ cond_label, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitFor(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        const binding = loop.label orelse return error.UnsupportedLlvmEmission;
        const iterable = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const iterable_ty = self.exprType(iterable) orelse return error.UnsupportedLlvmEmission;
        const element_ty = self.indexElementType(iterable) orelse return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);

        const index_ptr = try self.nextTemp();
        const binding_ptr = try self.nextBindingPtr(binding.text);
        try self.emitAlloca(index_ptr, "i64");
        try self.emitAlloca(binding_ptr, element_llvm);
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});

        var iterable_slot: ?LocalSlot = null;
        var iterable_ptr: ?[]const u8 = null;
        switch (iterable_ty.kind) {
            .slice => {
                const ptr = try self.nextTemp();
                const value = try self.emitExpr(iterable, iterable_ty);
                try self.emitAlloca(ptr, try self.llvmType(iterable_ty));
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(iterable_ty), value, ptr });
                iterable_slot = .{ .ty = iterable_ty, .ptr = ptr };
                iterable_ptr = ptr;
            },
            .array => if (!self.isStableAggregateAddress(iterable)) {
                iterable_ptr = try self.aggregateBasePointer(iterable);
            },
            else => {},
        }

        const old_type = self.local_types.fetchRemove(binding.text);
        const old_slot = self.local_slots.fetchRemove(binding.text);
        const old_global_pointer = self.pointer_local_provenance.fetchRemove(binding.text);
        const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(binding.text);
        const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(binding.text);
        const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(binding.text);
        const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(binding.text);
        const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(binding.text);
        var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(binding.text);
        var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(binding.text);
        defer restoreLocal(&self.local_types, binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, binding.text, old_slot) catch {};
        defer restoreLocal(&self.pointer_local_provenance, binding.text, old_global_pointer) catch {};
        defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.text, old_aggregate_pointer_alias) catch {};
        defer restoreLocal(&self.local_pointer_array_aliases, binding.text, old_pointer_array_alias) catch {};
        defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.text, old_slice_global_pointer_array) catch {};
        defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.text, old_slice_pointer_array_range) catch {};
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.text, old_slice_aggregate_pointer_array_field) catch {};
        defer self.restoreAggregatePointerFieldsForLocal(binding.text, &old_aggregate_pointer_fields) catch {};
        defer self.restoreLocalArrayPointerElementsForLocal(binding.text, &old_local_array_pointer_elements) catch {};
        try self.local_types.put(binding.text, element_ty);
        try self.local_slots.put(binding.text, .{ .ty = element_ty, .ptr = binding_ptr });

        const cond_label = try self.nextLabel("for_cond");
        const body_label = try self.nextLabel("for_body");
        const step_label = try self.nextLabel("for_step");
        const end_label = try self.nextLabel("for_end");

        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        const len = try self.emitIterableLen(iterable, iterable_ty, iterable_slot);
        const ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ ok, body_label, end_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.emitForElementPtr(iterable, iterable_ty, iterable_ptr, index);
        const element_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element_value, element_llvm, element_ptr });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ element_llvm, element_value, binding_ptr, try self.debugCallSuffix() });

        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = step_label, .cleanup_start = self.defer_stack.items.len, .label = if (loop.loop_label) |l| l.text else null });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ step_label, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "{s}:\n", .{step_label});
        const step_index = try self.nextTemp();
        const next_index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ step_index, index_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, step_index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), end_label });
        return false;
    }

    fn emitIterableLen(self: *LlvmEmitter, iterable: ast.Expr, iterable_ty: ast.TypeExpr, iterable_slot: ?LocalSlot) ![]const u8 {
        return switch (iterable_ty.kind) {
            .array => |array| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission}),
            .slice => blk: {
                const slot = iterable_slot orelse return error.UnsupportedLlvmEmission;
                _ = iterable;
                const value = try self.nextTemp();
                const len = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(iterable_ty), slot.ptr });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(iterable_ty), value });
                break :blk len;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitForElementPtr(self: *LlvmEmitter, iterable: ast.Expr, iterable_ty: ast.TypeExpr, iterable_ptr: ?[]const u8, index: []const u8) ![]const u8 {
        return switch (iterable_ty.kind) {
            .array => blk: {
                const base_ptr = iterable_ptr orelse try self.arrayBasePointer(iterable);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(iterable_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const ptr = iterable_ptr orelse return error.UnsupportedLlvmEmission;
                const value = try self.nextTemp();
                const data = try self.nextTemp();
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(iterable_ty), ptr });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(iterable_ty), value });
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), data, index });
                break :blk result;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitNullableSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        const inner_ty = self.nullableInnerType(subject_ty) orelse return null;
        if (node.arms.len == 0) return error.UnsupportedLlvmEmission;

        const arms = switch (switch_lower.classifyNullableArms(node.arms)) {
            .ok => |a| a,
            .duplicate => return false,
            .missing_half, .not_nullable => return null,
        };
        const some_i = arms.some_index;
        const none_i = arms.none_index;
        const bind = arms.binding;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const some_label = try self.nextLabel("nullable_some");
        const none_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        try self.emitNullableSomeTest(is_some, subject, inner_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ is_some, some_label, none_label, try self.debugCallSuffix() });

        var all_terminated = true;
        try self.out.print(self.allocator, "{s}:\n", .{some_label});
        const old_type = self.local_types.fetchRemove(bind.text);
        const old_slot = self.local_slots.fetchRemove(bind.text);
        const old_global_pointer = self.pointer_local_provenance.fetchRemove(bind.text);
        const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(bind.text);
        const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(bind.text);
        const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(bind.text);
        const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(bind.text);
        const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(bind.text);
        var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(bind.text);
        var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(bind.text);
        defer restoreLocal(&self.local_types, bind.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, bind.text, old_slot) catch {};
        defer restoreLocal(&self.pointer_local_provenance, bind.text, old_global_pointer) catch {};
        defer restoreLocal(&self.local_aggregate_pointer_aliases, bind.text, old_aggregate_pointer_alias) catch {};
        defer restoreLocal(&self.local_pointer_array_aliases, bind.text, old_pointer_array_alias) catch {};
        defer restoreLocal(&self.local_slice_global_pointer_arrays, bind.text, old_slice_global_pointer_array) catch {};
        defer restoreLocal(&self.local_slice_pointer_array_ranges, bind.text, old_slice_pointer_array_range) catch {};
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, bind.text, old_slice_aggregate_pointer_array_field) catch {};
        defer self.restoreAggregatePointerFieldsForLocal(bind.text, &old_aggregate_pointer_fields) catch {};
        defer self.restoreLocalArrayPointerElementsForLocal(bind.text, &old_local_array_pointer_elements) catch {};

        const binding_ptr = try self.nextBindingPtr(bind.text);
        try self.emitAllocaStore(binding_ptr, try self.llvmType(inner_ty), subject);
        try self.local_types.put(bind.text, inner_ty);
        try self.local_slots.put(bind.text, .{ .ty = inner_ty, .ptr = binding_ptr });
        const some_terminated = try self.emitSwitchBody(node.arms[some_i].body, ret_ty);
        if (!some_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        _ = self.local_types.remove(bind.text);
        _ = self.local_slots.remove(bind.text);
        _ = self.pointer_local_provenance.remove(bind.text);
        _ = self.local_aggregate_pointer_aliases.remove(bind.text);
        _ = self.local_pointer_array_aliases.remove(bind.text);
        self.clearLocalSliceGlobalPointerArray(bind.text);
        self.clearAggregatePointerFieldsForLocal(bind.text);
        self.clearLocalArrayPointerElementsForLocal(bind.text);

        try self.out.print(self.allocator, "{s}:\n", .{none_label});
        const none_terminated = try self.emitSwitchBody(node.arms[none_i].body, ret_ty);
        if (!none_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        const info = self.resultInfo(subject_ty) orelse return null;
        if (node.arms.len != 2) return error.UnsupportedLlvmEmission;

        var ok_index: ?usize = null;
        var ok_binding: ?ast.Ident = null;
        var err_index: ?usize = null;
        var err_binding: ?ast.Ident = null;
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            if (arm.patterns.len != 1) return null;
            const pattern = arm.patterns[0];
            if (pattern.kind == .wildcard) {
                if (wildcard_index != null) return error.UnsupportedLlvmEmission;
                wildcard_index = i;
                continue;
            }
            const tag_info = resultSwitchPattern(pattern) orelse return null;
            if (std.mem.eql(u8, tag_info.tag, "ok")) {
                if (ok_index != null) return error.UnsupportedLlvmEmission;
                ok_index = i;
                ok_binding = tag_info.binding;
            } else if (std.mem.eql(u8, tag_info.tag, "err")) {
                if (err_index != null) return error.UnsupportedLlvmEmission;
                err_index = i;
                err_binding = tag_info.binding;
            } else {
                return null;
            }
        }
        const ok_i = ok_index orelse wildcard_index orelse return null;
        const err_i = err_index orelse wildcard_index orelse return null;
        if (ok_index == null and err_index == null) return null;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const ok_label = try self.nextLabel("result_ok");
        const err_label = try self.nextLabel("result_err");
        const end_label = try self.nextLabel("result_end");
        const is_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(subject_ty), subject });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ is_ok, ok_label, err_label, try self.debugCallSuffix() });

        var all_terminated = true;
        try self.out.print(self.allocator, "{s}:\n", .{ok_label});
        const ok_terminated = try self.emitResultSwitchArm(node.arms[ok_i], ret_ty, subject, subject_ty, info.ok_ty, 1, if (ok_index != null) ok_binding else null);
        if (!ok_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }

        try self.out.print(self.allocator, "{s}:\n", .{err_label});
        const err_terminated = try self.emitResultSwitchArm(node.arms[err_i], ret_ty, subject, subject_ty, info.err_ty, 2, if (err_index != null) err_binding else null);
        if (!err_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultSwitchArm(self: *LlvmEmitter, arm: ast.SwitchArm, ret_ty: ast.TypeExpr, subject: []const u8, subject_ty: ast.TypeExpr, payload_ty: ast.TypeExpr, payload_index: u8, binding: ?ast.Ident) !bool {
        if (binding) |bind| {
            const old_type = self.local_types.fetchRemove(bind.text);
            const old_slot = self.local_slots.fetchRemove(bind.text);
            const old_global_pointer = self.pointer_local_provenance.fetchRemove(bind.text);
            const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(bind.text);
            const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(bind.text);
            const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(bind.text);
            const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(bind.text);
            const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(bind.text);
            var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(bind.text);
            var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(bind.text);
            defer restoreLocal(&self.local_types, bind.text, old_type) catch {};
            defer restoreLocal(&self.local_slots, bind.text, old_slot) catch {};
            defer restoreLocal(&self.pointer_local_provenance, bind.text, old_global_pointer) catch {};
            defer restoreLocal(&self.local_aggregate_pointer_aliases, bind.text, old_aggregate_pointer_alias) catch {};
            defer restoreLocal(&self.local_pointer_array_aliases, bind.text, old_pointer_array_alias) catch {};
            defer restoreLocal(&self.local_slice_global_pointer_arrays, bind.text, old_slice_global_pointer_array) catch {};
            defer restoreLocal(&self.local_slice_pointer_array_ranges, bind.text, old_slice_pointer_array_range) catch {};
            defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, bind.text, old_slice_aggregate_pointer_array_field) catch {};
            defer self.restoreAggregatePointerFieldsForLocal(bind.text, &old_aggregate_pointer_fields) catch {};
            defer self.restoreLocalArrayPointerElementsForLocal(bind.text, &old_local_array_pointer_elements) catch {};

            const binding_ptr = try self.nextBindingPtr(bind.text);
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
            try self.emitAllocaStore(binding_ptr, try self.resultPayloadLlvmType(payload_ty), payload);
            try self.local_types.put(bind.text, payload_ty);
            try self.local_slots.put(bind.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitTaggedUnionSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.taggedUnionSwitchSubjectType(node) orelse return null;
        const union_decl = self.taggedUnionForType(subject_ty) orelse return null;
        const subject = try self.emitExpr(node.subject, subject_ty);
        const subject_ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        const tag = try self.nextTemp();
        const union_llvm = try self.llvmType(subject_ty);
        try self.emitAllocaStore(subject_ptr, union_llvm, subject);
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, subject_ptr });
        try self.out.print(self.allocator, "  {s} = load i32, ptr {s}{s}\n", .{ tag, tag_ptr, try self.debugCallSuffix() });

        const end_label = try self.nextLabel("union_switch_end");
        const trap_label = try self.nextLabel("union_switch_trap");
        var arm_labels = try self.scratch.allocator().alloc([]const u8, node.arms.len);
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            arm_labels[i] = try self.nextLabel("union_switch_arm");
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard and wildcard_index == null) wildcard_index = i;
            }
        }
        const default_label = if (wildcard_index) |index| arm_labels[index] else trap_label;
        try self.out.print(self.allocator, "  switch i32 {s}, label %{s} [\n", .{ tag, default_label });
        for (node.arms, 0..) |arm, i| {
            for (arm.patterns) |pattern| {
                const case_name = taggedUnionPatternName(pattern) orelse continue;
                const case_index = self.taggedUnionCaseIndex(union_decl, case_name) orelse return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "    i32 {d}, label %{s}\n", .{ case_index, arm_labels[i] });
            }
        }
        try self.out.print(self.allocator, "  ]{s}\n", .{try self.debugCallSuffix()});

        var all_terminated = true;
        for (node.arms, 0..) |arm, i| {
            try self.out.print(self.allocator, "{s}:\n", .{arm_labels[i]});
            const terminated = try self.emitTaggedUnionSwitchArm(arm, ret_ty, subject_ptr, subject_ty, union_decl);
            if (!terminated) {
                all_terminated = false;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
            }
        }
        if (wildcard_index == null) {
            try self.out.print(self.allocator, "{s}:\n  call void @mc_trap_InvalidRepresentation(){s}\n  unreachable\n", .{ trap_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn taggedUnionSwitchSubjectType(self: *LlvmEmitter, node: ast.Switch) ?ast.TypeExpr {
        if (self.exprType(node.subject)) |subject_ty| {
            if (self.taggedUnionForType(subject_ty) != null) return subject_ty;
        }

        var candidate: ?ast.TypeExpr = null;
        var unions = self.tagged_unions.iterator();
        union_candidate: while (unions.next()) |entry| {
            var matched_named_pattern = false;
            for (node.arms) |arm| {
                for (arm.patterns) |pattern| {
                    const case_name = taggedUnionPatternName(pattern) orelse continue;
                    if (taggedUnionCase(entry.value_ptr.*, case_name) == null) continue :union_candidate;
                    matched_named_pattern = true;
                }
            }
            if (!matched_named_pattern) continue;
            if (candidate != null) return null;
            candidate = simpleType(node.subject.span, entry.key_ptr.*);
        }
        return candidate;
    }

    fn emitTaggedUnionSwitchArm(self: *LlvmEmitter, arm: ast.SwitchArm, ret_ty: ast.TypeExpr, subject_ptr: []const u8, subject_ty: ast.TypeExpr, union_decl: ast.UnionDecl) !bool {
        if (taggedUnionBindingPattern(arm)) |binding| {
            const case = taggedUnionCase(union_decl, binding.tag) orelse return error.UnsupportedLlvmEmission;
            const payload_ty = case.ty orelse return error.UnsupportedLlvmEmission;
            const old_type = self.local_types.fetchRemove(binding.binding.text);
            const old_slot = self.local_slots.fetchRemove(binding.binding.text);
            const old_global_pointer = self.pointer_local_provenance.fetchRemove(binding.binding.text);
            const old_aggregate_pointer_alias = self.local_aggregate_pointer_aliases.fetchRemove(binding.binding.text);
            const old_pointer_array_alias = self.local_pointer_array_aliases.fetchRemove(binding.binding.text);
            const old_slice_global_pointer_array = self.local_slice_global_pointer_arrays.fetchRemove(binding.binding.text);
            const old_slice_pointer_array_range = self.local_slice_pointer_array_ranges.fetchRemove(binding.binding.text);
            const old_slice_aggregate_pointer_array_field = self.local_slice_aggregate_pointer_array_fields.fetchRemove(binding.binding.text);
            var old_aggregate_pointer_fields = try self.saveAndRemoveAggregatePointerFieldsForLocal(binding.binding.text);
            var old_local_array_pointer_elements = try self.saveAndRemoveLocalArrayPointerElementsForLocal(binding.binding.text);
            defer restoreLocal(&self.local_types, binding.binding.text, old_type) catch {};
            defer restoreLocal(&self.local_slots, binding.binding.text, old_slot) catch {};
            defer restoreLocal(&self.pointer_local_provenance, binding.binding.text, old_global_pointer) catch {};
            defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.binding.text, old_aggregate_pointer_alias) catch {};
            defer restoreLocal(&self.local_pointer_array_aliases, binding.binding.text, old_pointer_array_alias) catch {};
            defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.binding.text, old_slice_global_pointer_array) catch {};
            defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.binding.text, old_slice_pointer_array_range) catch {};
            defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.binding.text, old_slice_aggregate_pointer_array_field) catch {};
            defer self.restoreAggregatePointerFieldsForLocal(binding.binding.text, &old_aggregate_pointer_fields) catch {};
            defer self.restoreLocalArrayPointerElementsForLocal(binding.binding.text, &old_local_array_pointer_elements) catch {};

            const binding_ptr = try self.nextBindingPtr(binding.binding.text);
            const payload = try self.taggedUnionLoadPayload(subject_ptr, subject_ty, payload_ty);
            try self.emitAllocaStore(binding_ptr, try self.llvmType(payload_ty), payload);
            try self.local_types.put(binding.binding.text, payload_ty);
            try self.local_slots.put(binding.binding.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitScalarSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        if (!typeNameEql(self.resolveAliasType(subject_ty), "bool") and self.integerBitsOf(subject_ty) == null and self.enumDeclForType(subject_ty) == null) return null;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const subject_llvm = try self.llvmType(subject_ty);
        const end_label = try self.nextLabel("switch_end");
        var arm_labels = try self.scratch.allocator().alloc([]const u8, node.arms.len);
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            arm_labels[i] = try self.nextLabel("switch_arm");
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard and wildcard_index == null) wildcard_index = i;
            }
        }

        const default_label = if (wildcard_index) |index| arm_labels[index] else end_label;
        try self.out.print(self.allocator, "  switch {s} {s}, label %{s} [\n", .{ subject_llvm, subject, default_label });
        for (node.arms, 0..) |arm, i| {
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard) continue;
                const value = try self.switchPatternValue(pattern, subject_ty);
                try self.out.print(self.allocator, "    {s} {s}, label %{s}\n", .{ subject_llvm, value, arm_labels[i] });
            }
        }
        try self.out.print(self.allocator, "  ]{s}\n", .{try self.debugCallSuffix()});

        var all_terminated = true;
        for (node.arms, 0..) |arm, i| {
            try self.out.print(self.allocator, "{s}:\n", .{arm_labels[i]});
            const terminated = try self.emitSwitchBody(arm.body, ret_ty);
            if (!terminated) {
                all_terminated = false;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
            }
        }
        if (wildcard_index == null and !typeNameEql(self.resolveAliasType(subject_ty), "bool") and self.enumDeclForType(subject_ty) == null) all_terminated = false;
        if (all_terminated) {
            if (wildcard_index == null) {
                try self.out.print(self.allocator, "{s}:\n  call void @mc_trap_InvalidRepresentation(){s}\n  unreachable\n", .{ end_label, try self.debugCallSuffix() });
            }
            return true;
        }
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn switchPatternValue(self: *LlvmEmitter, pattern: ast.Pattern, subject_ty: ast.TypeExpr) ![]const u8 {
        const expr = switch (pattern.kind) {
            .literal => |expr| expr,
            .tag => |tag| {
                const enum_decl = self.enumDeclForType(subject_ty) orelse return error.UnsupportedLlvmEmission;
                return try self.enumCaseValueByName(enum_decl, tag.text);
            },
            else => return error.UnsupportedLlvmEmission,
        };
        if (typeNameEql(self.resolveAliasType(subject_ty), "bool")) {
            return switch (expr.kind) {
                .bool_literal => |value| if (value) "1" else "0",
                .grouped => |inner| self.switchLiteralValue(inner.*, subject_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        return self.switchLiteralValue(expr, subject_ty);
    }

    fn switchLiteralValue(self: *LlvmEmitter, expr: ast.Expr, subject_ty: ast.TypeExpr) ![]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .enum_literal => |literal| if (self.enumDeclForType(subject_ty)) |enum_decl|
                try self.enumCaseValueByName(enum_decl, literal.text)
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| self.switchLiteralValue(inner.*, subject_ty),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                const literal = switch ((node.expr.*).kind) {
                    .int_literal => |literal| literal,
                    .grouped => |inner| switch (inner.kind) {
                        .int_literal => |literal| literal,
                        else => break :blk error.UnsupportedLlvmEmission,
                    },
                    else => break :blk error.UnsupportedLlvmEmission,
                };
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)});
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitSwitchBody(self: *LlvmEmitter, body: ast.SwitchBody, ret_ty: ast.TypeExpr) !bool {
        return switch (body) {
            .block => |block| try self.emitBlock(block, ret_ty),
            .expr => |expr| blk: {
                if (typeNameEql(ret_ty, "void")) {
                    try self.emitExprStatement(expr);
                    break :blk false;
                }
                const value = try self.emitExpr(expr, ret_ty);
                try self.emitReturnValue(ret_ty, value, expr.span);
                break :blk true;
            },
        };
    }

    fn emitReturnVoid(self: *LlvmEmitter, span: ast.Span) !void {
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "  ret void, !dbg !{d}\n", .{dbg});
        } else {
            try self.out.appendSlice(self.allocator, "  ret void\n");
        }
    }

    fn emitReturnValue(self: *LlvmEmitter, ret_ty: ast.TypeExpr, value: []const u8, span: ast.Span) !void {
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "  ret {s} {s}, !dbg !{d}\n", .{ try self.llvmType(ret_ty), value, dbg });
        } else {
            try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
        }
    }

    // Tier 2: if `expected_ty` is `*dyn Trait`, build the fat pointer
    // `{ data = <ptr>, vtable = @__vt_T_Trait }` from a `*T` source and return it. The
    // STATIC pointee type T selects the rodata vtable, UNIFORMLY for:
    //   - `&x` / `&mut x`     : data = address-of x,  T = typeof(x)
    //   - a `*T` value (param, field, returned `*T`, …): data = the pointer value, T = pointee
    // An existing `*dyn Trait` value (pass-through, same trait) returns null so it emits
    // normally. Returns null when not applicable. Sema verified conformance + forge-safety.
    // True when `ty` is `*dyn Trait` or `?*dyn Trait` — both route through emitDynCoercion.
    fn targetIsDynOrNullableDyn(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => true,
            .nullable => |child| self.resolveAliasType(child.*).kind == .dyn_trait,
            else => false,
        };
    }

    // A `?T` payload T uses the tagged `{ i1, T }` repr iff T is a sized VALUE type (named
    // scalar/struct/enum/address, not a pointer, slice, fn-pointer, or `*dyn`).
    fn nullablePayloadIsValueType(self: *LlvmEmitter, child: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(child);
        return switch (resolved.kind) {
            .name => |n| !std.mem.eql(u8, n.text, "c_void"),
            .qualified => |node| self.nullablePayloadIsValueType(node.child.*),
            else => false,
        };
    }

    fn targetIsValueOptional(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return resolved.kind == .nullable and self.nullablePayloadIsValueType(resolved.kind.nullable.*);
    }

    // Coerce a `null` (absent) or a payload value (present) into a value optional `?T`'s
    // tagged `{ i1, T }` aggregate. A source already yielding `?T` returns null (pass-through).
    fn emitValueOptionalCoercion(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) !?[]const u8 {
        var resolved = self.resolveAliasType(expected_ty);
        // `null` -> absent: `{ i1 false, T zero }` == zeroinitializer.
        if (expr.kind == .null_literal) return "zeroinitializer";
        // Pass-through: the source already produces the optional aggregate.
        if (self.exprType(expr)) |src_ty| {
            if (self.resolveAliasType(src_ty).kind == .nullable) return null;
        }
        const fact = self.mirTargetTypeFactAt(.value_optional_coercion, expr.span) orelse return error.UnsupportedLlvmEmission;
        resolved = self.resolveAliasType(fact.target_ty);
        if (resolved.kind != .nullable) return error.UnsupportedLlvmEmission;
        const child = resolved.kind.nullable.*;
        if (!self.nullablePayloadIsValueType(child)) return error.UnsupportedLlvmEmission;
        const opt_ty = try self.llvmType(resolved);
        const payload_ty = try self.llvmType(child);
        const payload = try self.emitExpr(expr, child);
        const with_tag = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 true, 0\n", .{ with_tag, opt_ty });
        const with_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_value, opt_ty, with_tag, payload_ty, payload });
        return with_value;
    }

    fn emitDynCoercion(self: *LlvmEmitter, expr: ast.Expr, _: ast.TypeExpr) !?[]const u8 {
        if (expr.kind == .null_literal) return "zeroinitializer";
        if (self.exprType(expr)) |source_ty| {
            if (self.targetIsDynOrNullableDyn(source_ty)) return null;
        }
        const fact = self.mirTargetTypeFactAt(.dyn_coercion, expr.span) orelse return error.UnsupportedLlvmEmission;
        const resolved = self.resolveAliasType(fact.target_ty);
        // `*dyn Trait` or `?*dyn Trait` (nullable trait object) target.
        const trait_name = switch (resolved.kind) {
            .dyn_trait => |d| d.trait_name.text,
            .nullable => |child| switch (self.resolveAliasType(child.*).kind) {
                .dyn_trait => |d| d.trait_name.text,
                else => return null,
            },
            else => return null,
        };
        // `?*dyn Trait = null`: `none` is the zero fat pointer (data == null). The value is
        // emitted in a typed context (store/insertvalue prefix the `{ ptr, ptr }` type).
        var type_name: []const u8 = undefined;
        var data_ptr: []const u8 = undefined;
        switch (expr.kind) {
            .grouped => |inner| return self.emitDynCoercion(inner.*, fact.target_ty),
            .address_of => |inner| {
                // `&x` -> data = &x, vtable keyed on typeof(x).
                const source_ty = self.exprType(inner.*) orelse return null;
                type_name = typeName(self.resolveAliasType(source_ty)) orelse return null;
                data_ptr = try self.emitAddressOf(inner.*);
            },
            else => {
                // A `*T` value: data = the pointer itself, vtable keyed on the pointee T.
                const source_ty = self.resolveAliasType(self.exprType(expr) orelse return null);
                // An existing `*dyn Trait` value passes through (no re-wrap).
                if (self.targetIsDynOrNullableDyn(source_ty)) return null;
                const pointee = switch (source_ty.kind) {
                    .pointer => |node| node.child.*,
                    else => return null,
                };
                type_name = typeName(self.resolveAliasType(pointee)) orelse return null;
                // Emit the pointer VALUE as the data word (it already points at the T).
                data_ptr = try self.emitExpr(expr, source_ty);
            },
        }
        const dyn_llvm = try self.llvmType(resolved); // "{ ptr, ptr }"
        const with_data = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_data, dyn_llvm, data_ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, ptr @__vt_{s}_{s}, 1\n", .{ result, dyn_llvm, with_data, type_name, trait_name });
        return result;
    }

    fn emitAddressOf(self: *LlvmEmitter, target: ast.Expr) ![]const u8 {
        switch (target.kind) {
            .ident => |ident| {
                if (self.local_slots.get(ident.text)) |slot| {
                    if (self.isVaListType(slot.ty)) return try self.vaListCursorPtrFromSlot(slot);
                    return slot.ptr;
                }
                if (self.global_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                // `&f` where f is a function: the function's address IS the symbol `@f`
                // (a code pointer). Used for installing trap/entry vectors by address.
                if (self.fn_sigs.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                return error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| return self.emitAddressOf(inner.*),
            .deref => |inner| return self.emitExpr(inner.*, self.exprType(inner.*) orelse return error.UnsupportedLlvmEmission),
            .index => |node| return self.emitIndexAddress(node),
            .member => |node| return self.emitMemberAddress(node),
            else => return error.UnsupportedLlvmEmission,
        }
    }

    fn emitDeref(self: *LlvmEmitter, ptr_expr: ast.Expr, pointee_ty: ast.TypeExpr) ![]const u8 {
        const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
        if (self.isAggregateType(pointee_ty) and !self.pointerExprHasProvenLocalStorage(ptr_expr)) {
            return try self.emitRaceTolerantAggregateDerefLoad(ptr, pointee_ty);
        }
        const use_atomic = self.derefUsesRaceTolerantLowering(ptr_expr, pointee_ty);
        if (use_atomic) try self.emitOrdinaryShadowHook(ptr, pointee_ty, .load_pre);
        return try self.emitOrdinaryLoad(pointee_ty, ptr, use_atomic);
    }

    fn emitMemberLoad(self: *LlvmEmitter, node: anytype) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        if (base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) {
            const base = try self.emitExpr(node.base.*, base_ty);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ result, try self.llvmType(base_ty), base });
            return result;
        }
        if (self.packedBitsInfoForType(base_ty)) |info| {
            const bit_index = self.packedBitsFieldIndex(info, node.name.text) orelse return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(node.base.*, base_ty);
            const masked = try self.nextTemp();
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = and {s} {s}, {d}\n", .{ masked, try self.llvmType(info.repr), base, packedBitsMask(bit_index) });
            try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, 0\n", .{ result, try self.llvmType(info.repr), masked });
            return result;
        }
        if (self.overlayField(node.base.*, node.name.text)) |field| {
            // Array views (byte or non-byte) are read element-wise via the index path;
            // a bare member load only applies to scalar members.
            if (overlayArrayElementType(field.ty) != null) return error.UnsupportedLlvmEmission;
            const ptr = try self.emitOverlayFieldAddress(node.base.*, field);
            try self.emitOrdinaryShadowHook(ptr, field.ty, .load_pre);
            return try self.emitOrdinaryLoad(field.ty, ptr, self.memberBaseIsGlobal(node));
        }
        const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMemberAddress(node);
        if (self.isAggregateType(field.ty) and self.pointerMemberBaseUsesRaceTolerantLowering(node.base.*)) {
            return try self.emitRaceTolerantAggregateDerefLoad(ptr, field.ty);
        }
        if (self.aggregateIndexedMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
            return try self.emitRaceTolerantAggregateDerefLoad(ptr, field.ty);
        }
        if (self.scalarPointerMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
            try self.emitOrdinaryShadowHook(ptr, field.ty, .load_pre);
            return try self.emitOrdinaryLoad(field.ty, ptr, true);
        }
        if (self.scalarIndexedMemberBaseUsesRaceTolerantLowering(node.base.*, field.ty)) {
            try self.emitOrdinaryShadowHook(ptr, field.ty, .load_pre);
            return try self.emitOrdinaryLoad(field.ty, ptr, true);
        }
        try self.emitOrdinaryShadowHook(ptr, field.ty, .load_pre);
        return try self.emitOrdinaryLoad(field.ty, ptr, self.memberBaseIsGlobal(node));
    }

    fn emitMemberAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        if (isMmioStructAbi(struct_decl)) {
            const offset = self.mmioFieldOffset(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
            const base_ptr = try self.emitExpr(node.base.*, base_ty);
            if (offset == 0) return base_ptr;
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {d}\n", .{ result, base_ptr, offset });
            return result;
        }
        // `#[c_union]`: every arm lives at offset 0, so the arm's address IS the union's own
        // address (opaque pointers — no GEP, no bitcast). The load/store at the call site uses
        // the arm's own type, reinterpreting the shared storage. Strict-aliasing safe: the C
        // backend emits a real `union` member access, the canonical aliasing exception.
        if (struct_decl.is_c_union) {
            return if (self.resolveAliasType(base_ty).kind == .pointer)
                try self.emitExpr(node.base.*, base_ty)
            else
                try self.aggregateBasePointer(node.base.*);
        }
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = if (self.resolveAliasType(base_ty).kind == .pointer)
            try self.emitExpr(node.base.*, base_ty)
        else
            try self.aggregateBasePointer(node.base.*);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ result, try self.llvmType(struct_ty), base_ptr, index });
        return result;
    }

    // Splice the sanitizer shadow hook before/after an ordinary (non-raw) scalar access. Used
    // at the access classes that have a parity-matched hook on the C backend:
    //   - a struct-FIELD load (emitMemberAccess) — C wraps the same load in a comma expression;
    //   - member/index stores — C emits a pre-store check statement before assigning the lvalue;
    //   - a scalar-GLOBAL load (emitIdent) and store (emitAssignment) — C instruments these
    //     inside the `mc_race_load_<T>`/`mc_race_store_<T>` macro body.
    // Here the address is the GEP/global `ptr` SSA value, which we `ptrtoint` to the i64 the
    // hooks expect; size matches the access (scalar == llvmAlignOf, same as the C `sizeof`).
    // Default builds emit nothing (all three flags false), keeping codegen byte-identical.
    //   - ksan (non-msan): pre-load + pre-store mc_ksan_check (poisoned/freed/redzone traps).
    //   - msan:            pre-load mc_ksan_check (+ uninit trap) + PRE-store mc_ksan_store
    //                      (poison/freed trap; UNINIT first writes become CLEAN).
    //   - csan:            NO watchpoint hook. This is the SYNCHRONIZED (global / mc_race_*,
    //     relaxed-atomic) access class — a "marked atomic" in the KCSAN model, which does NOT
    //     participate in the unsynchronized-watchpoint conflict check. Hooking it (as a prior
    //     version did, mirroring the C `mc_race_*` macro) made a synchronized-vs-synchronized
    //     global access FALSE-POSITIVE as a race. Only the genuinely-unsynchronized raw path
    //     (emitRawLoad/emitRawStore) sets a csan watchpoint. Mirrors the C backend fix.
    // `phase` is .load_pre, .store_pre, or .store_post. MSAN uses store_pre for init-marking
    // because mc_ksan_store also rejects poison/freed bytes before the actual write.
    fn emitOrdinaryShadowHook(self: *LlvmEmitter, ptr: []const u8, ty: ast.TypeExpr, phase: enum { load_pre, store_pre, store_post }) !void {
        if (!self.ksan and !self.msan and !self.csan) return;
        const size = self.llvmAlignOf(ty);
        const hook: ?[]const u8 = switch (phase) {
            .load_pre => if (self.ksan) "mc_ksan_check" else null,
            .store_pre => if (self.msan) "mc_ksan_store" else if (self.ksan) "mc_ksan_check" else null,
            .store_post => null,
        };
        const name = hook orelse return;
        const addr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = ptrtoint ptr {s} to i64\n", .{ addr, ptr });
        try self.out.print(self.allocator, "  call void @{s}(i64 {s}, i64 {d})\n", .{ name, addr, size });
    }

    fn emitOrdinaryLoad(self: *LlvmEmitter, ty: ast.TypeExpr, ptr: []const u8, use_atomic: bool) ![]const u8 {
        const result = try self.nextTemp();
        const llvm_ty = try self.llvmType(ty);
        if (use_atomic and self.canUseOrdinaryAtomicAccess(ty)) {
            if (self.ordinaryAtomicScalarTooWide(ty)) return error.UnsupportedLlvmEmission;
            if (typeNameEql(self.resolveAliasType(ty), "bool")) {
                try self.out.print(self.allocator, "  {s} = load atomic i8, ptr {s} unordered, align 1{s}\n", .{ result, ptr, try self.debugCallSuffix() });
                const bool_result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ bool_result, result });
                return bool_result;
            }
            try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} unordered, align {d}{s}\n", .{ result, llvm_ty, ptr, self.llvmAlignOf(ty), try self.debugCallSuffix() });
        } else {
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, llvm_ty, ptr, try self.debugCallSuffix() });
        }
        return result;
    }

    fn emitOrdinaryStore(self: *LlvmEmitter, ty: ast.TypeExpr, llvm_ty: []const u8, value: []const u8, ptr: []const u8, use_atomic: bool) !void {
        if (use_atomic and self.canUseOrdinaryAtomicAccess(ty)) {
            if (self.ordinaryAtomicScalarTooWide(ty)) return error.UnsupportedLlvmEmission;
            if (typeNameEql(self.resolveAliasType(ty), "bool")) {
                const widened = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ widened, value });
                try self.out.print(self.allocator, "  store atomic i8 {s}, ptr {s} unordered, align 1{s}\n", .{ widened, ptr, try self.debugCallSuffix() });
                return;
            }
            try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} unordered, align {d}{s}\n", .{ llvm_ty, value, ptr, self.llvmAlignOf(ty), try self.debugCallSuffix() });
        } else {
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
        }
    }

    fn canUseOrdinaryAtomicAccess(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return !self.isAggregateType(ty);
    }

    // Race-tolerant lowering (`load/store atomic ... unordered`) is only sound for
    // scalars up to the native 8-byte word: a 128-bit atomic would lower to an
    // `__atomic_load_16`/`__atomic_store_16` libcall that the freestanding kernel
    // image cannot link. Spec §I.13: with no sound race-tolerant lowering, the
    // backend must fail emission rather than guess.
    fn ordinaryAtomicScalarTooWide(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const bits = self.integerBitsOf(ty) orelse return false;
        return bits > 64;
    }

    fn aggregatePointerFieldKey(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ local_name, field_path });
    }

    fn aggregatePointerFieldKeyMatchesLocal(key: []const u8, local_name: []const u8) bool {
        return key.len > local_name.len and std.mem.eql(u8, key[0..local_name.len], local_name) and key[local_name.len] == 0;
    }

    fn aggregatePointerFieldKeyMatchesLocalPath(key: []const u8, local_name: []const u8, field_path: []const u8) bool {
        if (!aggregatePointerFieldKeyMatchesLocal(key, local_name)) return false;
        const existing_path = key[local_name.len + 1 ..];
        if (std.mem.eql(u8, existing_path, field_path)) return true;
        return existing_path.len > field_path.len and
            std.mem.eql(u8, existing_path[0..field_path.len], field_path) and
            (existing_path[field_path.len] == '.' or existing_path[field_path.len] == '[');
    }

    fn deinitOwnedStringVoidMap(self: *LlvmEmitter, map: *std.StringHashMap(void)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.deinit();
    }

    fn clearOwnedStringVoidMapRetainingCapacity(self: *LlvmEmitter, map: *std.StringHashMap(void)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.clearRetainingCapacity();
    }

    fn cloneOwnedStringVoidMap(self: *LlvmEmitter, source: *std.StringHashMap(void)) !std.StringHashMap(void) {
        var clone = std.StringHashMap(void).init(self.allocator);
        errdefer self.deinitOwnedStringVoidMap(&clone);
        var it = source.keyIterator();
        while (it.next()) |key| {
            const owned_key = try self.allocator.dupe(u8, key.*);
            errdefer self.allocator.free(owned_key);
            try clone.put(owned_key, {});
        }
        return clone;
    }

    fn deinitOwnedStringProvenanceMap(self: *LlvmEmitter, map: *std.StringHashMap(mir.PointerProvenance)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.deinit();
    }

    fn clearOwnedStringProvenanceMapRetainingCapacity(self: *LlvmEmitter, map: *std.StringHashMap(mir.PointerProvenance)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.clearRetainingCapacity();
    }

    fn cloneOwnedStringProvenanceMap(self: *LlvmEmitter, source: *std.StringHashMap(mir.PointerProvenance)) !std.StringHashMap(mir.PointerProvenance) {
        var clone = std.StringHashMap(mir.PointerProvenance).init(self.allocator);
        errdefer self.deinitOwnedStringProvenanceMap(&clone);
        var it = source.iterator();
        while (it.next()) |entry| {
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_key);
            try clone.put(owned_key, entry.value_ptr.*);
        }
        return clone;
    }

    fn deinitOwnedStringValueMap(self: *LlvmEmitter, map: *std.StringHashMap([]const u8)) void {
        var it = map.valueIterator();
        while (it.next()) |value| self.allocator.free(value.*);
        map.deinit();
    }

    fn clearOwnedStringValueMapRetainingCapacity(self: *LlvmEmitter, map: *std.StringHashMap([]const u8)) void {
        var it = map.valueIterator();
        while (it.next()) |value| self.allocator.free(value.*);
        map.clearRetainingCapacity();
    }

    fn cloneOwnedStringValueMap(self: *LlvmEmitter, source: *std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
        var clone = std.StringHashMap([]const u8).init(self.allocator);
        errdefer self.deinitOwnedStringValueMap(&clone);
        var it = source.iterator();
        while (it.next()) |entry| {
            const owned_value = try self.allocator.dupe(u8, entry.value_ptr.*);
            errdefer self.allocator.free(owned_value);
            try clone.put(entry.key_ptr.*, owned_value);
        }
        return clone;
    }

    fn restoreLocalOwnedStringValue(self: *LlvmEmitter, map: *std.StringHashMap([]const u8), key: []const u8, old: anytype) !void {
        if (map.fetchRemove(key)) |entry| self.allocator.free(entry.value);
        if (old) |entry| try map.put(key, entry.value);
    }

    fn clearAggregateGlobalPointerFields(self: *LlvmEmitter) void {
        var it = self.aggregate_global_pointer_fields.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.aggregate_global_pointer_fields.clearRetainingCapacity();
    }

    fn localArrayPointerElementKey(self: *LlvmEmitter, local_name: []const u8, index: u64) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ local_name, index });
    }

    fn localArrayPointerElementKeyMatchesLocal(key: []const u8, local_name: []const u8) bool {
        return key.len > local_name.len and std.mem.eql(u8, key[0..local_name.len], local_name) and key[local_name.len] == 0;
    }

    fn clearLocalArrayGlobalPointerElements(self: *LlvmEmitter) void {
        var it = self.local_array_global_pointer_elements.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.local_array_global_pointer_elements.clearRetainingCapacity();
    }

    fn clearLocalArrayPointerElementsForLocal(self: *LlvmEmitter, local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.local_array_global_pointer_elements.keyIterator();
            while (it.next()) |key| {
                if (localArrayPointerElementKeyMatchesLocal(key.*, local_name)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (self.local_array_global_pointer_elements.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn clearLocalSliceGlobalPointerArray(self: *LlvmEmitter, slice_name: []const u8) void {
        _ = self.local_slice_global_pointer_arrays.remove(slice_name);
        _ = self.local_slice_pointer_array_ranges.remove(slice_name);
        if (self.local_slice_aggregate_pointer_array_fields.fetchRemove(slice_name)) |entry| {
            self.allocator.free(entry.value);
        }
    }

    fn clearLocalSlicesBackedByArray(self: *LlvmEmitter, array_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.local_slice_global_pointer_arrays.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, array_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            const key = found_key orelse return;
            self.clearLocalSliceGlobalPointerArray(key);
        }
    }

    fn clearLocalPointerArrayAliasesBackedByArray(self: *LlvmEmitter, array_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.local_pointer_array_aliases.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, array_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            const key = found_key orelse return;
            _ = self.local_pointer_array_aliases.remove(key);
        }
    }

    fn invalidateLocalPointerArrayBackedByArrayWrite(self: *LlvmEmitter, array_name: []const u8) void {
        self.clearLocalArrayPointerElementsForLocal(array_name);
        self.clearLocalSlicesBackedByArray(array_name);
        self.clearLocalPointerArrayAliasesBackedByArray(array_name);
    }

    fn invalidateProvenSliceWrite(self: *LlvmEmitter, slice_name: []const u8) void {
        const array_name = self.local_slice_global_pointer_arrays.get(slice_name) orelse {
            self.clearLocalSliceGlobalPointerArray(slice_name);
            return;
        };
        self.clearLocalArrayPointerElementsForLocal(array_name);
        self.clearAggregatePointerFieldsForLocal(array_name);
        self.clearLocalSlicesBackedByArray(array_name);
        self.clearLocalPointerArrayAliasesBackedByArray(array_name);
    }

    fn directLocalSliceBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const slot = self.local_slots.get(ident.text) orelse break :blk null;
                if (self.resolveAliasType(slot.ty).kind != .slice) break :blk null;
                break :blk ident.text;
            },
            .grouped => |inner| self.directLocalSliceBaseName(inner.*),
            else => null,
        };
    }

    fn provenLocalSliceBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        const slice_name = self.directLocalSliceBaseName(expr) orelse return null;
        if (!self.local_slice_global_pointer_arrays.contains(slice_name)) return null;
        return slice_name;
    }

    fn localSliceElementHasGlobalPointerProvenance(self: *LlvmEmitter, slice_name: []const u8, index: u64) bool {
        const backing_name = self.local_slice_global_pointer_arrays.get(slice_name) orelse return false;
        const range = self.local_slice_pointer_array_ranges.get(slice_name) orelse return false;
        if (!range.start_exact) {
            if (self.local_slice_aggregate_pointer_array_fields.get(slice_name)) |field_path| {
                return self.localAggregateArrayRangeAnyElementHasGlobalPointerProvenance(backing_name, field_path, range.start, range.end);
            }
            return self.localArrayRangeAnyElementHasGlobalPointerProvenance(backing_name, range.start, range.end);
        }
        if (index >= range.end - range.start) return false;
        const backing_index = range.start + index;
        if (self.local_slice_aggregate_pointer_array_fields.get(slice_name)) |field_path| {
            const element_path = self.aggregatePointerArrayElementPath(field_path, backing_index) catch return false;
            return self.localAggregateFieldHasGlobalPointerProvenance(backing_name, element_path);
        }
        return self.localArrayElementHasGlobalPointerProvenance(backing_name, backing_index);
    }

    fn localSliceAnyElementHasGlobalPointerProvenance(self: *LlvmEmitter, slice_name: []const u8) bool {
        const backing_name = self.local_slice_global_pointer_arrays.get(slice_name) orelse return false;
        const range = self.local_slice_pointer_array_ranges.get(slice_name) orelse return false;
        if (self.local_slice_aggregate_pointer_array_fields.get(slice_name)) |field_path| {
            return self.localAggregateArrayRangeAnyElementHasGlobalPointerProvenance(backing_name, field_path, range.start, range.end);
        }
        return self.localArrayRangeAnyElementHasGlobalPointerProvenance(backing_name, range.start, range.end);
    }

    fn localSliceElementHasLocalPointerProvenance(self: *LlvmEmitter, slice_name: []const u8, index: u64) bool {
        const backing_name = self.local_slice_global_pointer_arrays.get(slice_name) orelse return false;
        const range = self.local_slice_pointer_array_ranges.get(slice_name) orelse return false;
        if (!range.start_exact) return self.localSliceAllElementsHaveLocalPointerProvenance(slice_name);
        if (index >= range.end - range.start) return false;
        const backing_index = range.start + index;
        if (self.local_slice_aggregate_pointer_array_fields.get(slice_name)) |field_path| {
            const element_path = self.aggregatePointerArrayElementPath(field_path, backing_index) catch return false;
            return self.localAggregateFieldHasLocalPointerProvenance(backing_name, element_path);
        }
        return self.localArrayElementHasLocalPointerProvenance(backing_name, backing_index);
    }

    fn localSliceAllElementsHaveLocalPointerProvenance(self: *LlvmEmitter, slice_name: []const u8) bool {
        const backing_name = self.local_slice_global_pointer_arrays.get(slice_name) orelse return false;
        const range = self.local_slice_pointer_array_ranges.get(slice_name) orelse return false;
        if (self.local_slice_aggregate_pointer_array_fields.get(slice_name)) |field_path| {
            return self.localAggregateArrayRangeAllElementsHaveLocalPointerProvenance(backing_name, field_path, range.start, range.end);
        }
        return self.localArrayRangeAllElementsHaveLocalPointerProvenance(backing_name, range.start, range.end);
    }

    fn saveAndRemoveLocalArrayPointerElementsForLocal(self: *LlvmEmitter, local_name: []const u8) !std.StringHashMap(mir.PointerProvenance) {
        var saved = std.StringHashMap(mir.PointerProvenance).init(self.allocator);
        errdefer self.deinitOwnedStringProvenanceMap(&saved);

        var it = self.local_array_global_pointer_elements.iterator();
        while (it.next()) |entry| {
            if (!localArrayPointerElementKeyMatchesLocal(entry.key_ptr.*, local_name)) continue;
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_key);
            try saved.put(owned_key, entry.value_ptr.*);
        }

        self.clearLocalArrayPointerElementsForLocal(local_name);
        return saved;
    }

    fn restoreLocalArrayPointerElementsForLocal(self: *LlvmEmitter, local_name: []const u8, saved: *std.StringHashMap(mir.PointerProvenance)) !void {
        self.clearLocalArrayPointerElementsForLocal(local_name);
        defer saved.deinit();

        var it = saved.iterator();
        while (it.next()) |entry| {
            try self.local_array_global_pointer_elements.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn setLocalArrayPointerElementProvenance(self: *LlvmEmitter, local_name: []const u8, index: u64, provenance: mir.PointerProvenance) !void {
        const lookup_key = try self.localArrayPointerElementKey(local_name, index);
        defer self.allocator.free(lookup_key);

        if (provenance == .unknown) {
            if (self.local_array_global_pointer_elements.fetchRemove(lookup_key)) |entry| {
                self.allocator.free(entry.key);
            }
            return;
        }

        if (self.local_array_global_pointer_elements.getPtr(lookup_key)) |existing| {
            existing.* = provenance;
            return;
        }
        const owned_key = try self.localArrayPointerElementKey(local_name, index);
        errdefer self.allocator.free(owned_key);
        try self.local_array_global_pointer_elements.put(owned_key, provenance);
    }

    fn localArrayElementPointerProvenance(self: *LlvmEmitter, local_name: []const u8, index: u64) ?mir.PointerProvenance {
        const lookup_key = self.localArrayPointerElementKey(local_name, index) catch return null;
        defer self.allocator.free(lookup_key);
        return self.local_array_global_pointer_elements.get(lookup_key);
    }

    fn localArrayElementHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, index: u64) bool {
        return self.localArrayElementPointerProvenance(local_name, index) == .global_storage;
    }

    fn localArrayElementHasLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, index: u64) bool {
        return self.localArrayElementPointerProvenance(local_name, index) == .local_storage;
    }

    fn localArrayHasAtLeastPointerElementFacts(self: *LlvmEmitter, local_name: []const u8, len: u64) bool {
        var count: u64 = 0;
        var it = self.local_array_global_pointer_elements.keyIterator();
        while (it.next()) |key| {
            if (!localArrayPointerElementKeyMatchesLocal(key.*, local_name)) continue;
            count += 1;
            if (count >= len) return true;
        }
        return false;
    }

    fn localArrayAllElementsHaveGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, len: u64) bool {
        if (len == 0) return false;
        if (!self.localArrayHasAtLeastPointerElementFacts(local_name, len)) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            if (!self.localArrayElementHasGlobalPointerProvenance(local_name, index)) return false;
        }
        return true;
    }

    fn localArrayAnyElementHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, len: u64) bool {
        if (len == 0) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            if (self.localArrayElementHasGlobalPointerProvenance(local_name, index)) return true;
        }
        return false;
    }

    fn localArrayAllElementsHaveLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, len: u64) bool {
        if (len == 0) return false;
        if (!self.localArrayHasAtLeastPointerElementFacts(local_name, len)) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            if (!self.localArrayElementHasLocalPointerProvenance(local_name, index)) return false;
        }
        return true;
    }

    fn localArrayRangeAnyElementHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, start: u64, end: u64) bool {
        if (start >= end) return false;
        var index = start;
        while (index < end) : (index += 1) {
            if (self.localArrayElementHasGlobalPointerProvenance(local_name, index)) return true;
        }
        return false;
    }

    fn localArrayRangeAllElementsHaveLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, start: u64, end: u64) bool {
        if (start >= end) return false;
        var index = start;
        while (index < end) : (index += 1) {
            if (!self.localArrayElementHasLocalPointerProvenance(local_name, index)) return false;
        }
        return true;
    }

    fn clearAggregatePointerFieldsForLocal(self: *LlvmEmitter, local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.aggregate_global_pointer_fields.keyIterator();
            while (it.next()) |key| {
                if (aggregatePointerFieldKeyMatchesLocal(key.*, local_name)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (self.aggregate_global_pointer_fields.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn clearAggregatePointerFieldsForLocalPath(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.aggregate_global_pointer_fields.keyIterator();
            while (it.next()) |key| {
                if (aggregatePointerFieldKeyMatchesLocalPath(key.*, local_name, field_path)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (self.aggregate_global_pointer_fields.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn saveAndRemoveAggregatePointerFieldsForLocal(self: *LlvmEmitter, local_name: []const u8) !std.StringHashMap(mir.PointerProvenance) {
        var saved = std.StringHashMap(mir.PointerProvenance).init(self.allocator);
        errdefer self.deinitOwnedStringProvenanceMap(&saved);

        var it = self.aggregate_global_pointer_fields.iterator();
        while (it.next()) |entry| {
            if (!aggregatePointerFieldKeyMatchesLocal(entry.key_ptr.*, local_name)) continue;
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_key);
            try saved.put(owned_key, entry.value_ptr.*);
        }

        self.clearAggregatePointerFieldsForLocal(local_name);
        return saved;
    }

    fn restoreAggregatePointerFieldsForLocal(self: *LlvmEmitter, local_name: []const u8, saved: *std.StringHashMap(mir.PointerProvenance)) !void {
        self.clearAggregatePointerFieldsForLocal(local_name);
        defer saved.deinit();

        var it = saved.iterator();
        while (it.next()) |entry| {
            try self.aggregate_global_pointer_fields.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn setAggregatePointerFieldProvenance(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8, provenance: mir.PointerProvenance) !void {
        const lookup_key = try self.aggregatePointerFieldKey(local_name, field_path);
        defer self.allocator.free(lookup_key);

        if (provenance == .unknown) {
            if (self.aggregate_global_pointer_fields.fetchRemove(lookup_key)) |entry| {
                self.allocator.free(entry.key);
            }
            return;
        }

        if (self.aggregate_global_pointer_fields.getPtr(lookup_key)) |existing| {
            existing.* = provenance;
            return;
        }
        const owned_key = try self.aggregatePointerFieldKey(local_name, field_path);
        errdefer self.allocator.free(owned_key);
        try self.aggregate_global_pointer_fields.put(owned_key, provenance);
    }

    fn localAggregateFieldPointerProvenance(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8) ?mir.PointerProvenance {
        const lookup_key = self.aggregatePointerFieldKey(local_name, field_path) catch return null;
        defer self.allocator.free(lookup_key);
        return self.aggregate_global_pointer_fields.get(lookup_key);
    }

    fn localAggregateFieldHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8) bool {
        return self.localAggregateFieldPointerProvenance(local_name, field_path) == .global_storage;
    }

    fn localAggregateFieldHasLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, field_path: []const u8) bool {
        return self.localAggregateFieldPointerProvenance(local_name, field_path) == .local_storage;
    }

    fn aggregatePointerFieldKeyMatchesLocalArrayPath(key: []const u8, local_name: []const u8, array_path: []const u8) bool {
        if (!aggregatePointerFieldKeyMatchesLocal(key, local_name)) return false;
        const existing_path = key[local_name.len + 1 ..];
        return existing_path.len > array_path.len and
            std.mem.eql(u8, existing_path[0..array_path.len], array_path) and
            existing_path[array_path.len] == '[';
    }

    fn localAggregateArrayHasAtLeastPointerElementFacts(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, len: u64) bool {
        var count: u64 = 0;
        var it = self.aggregate_global_pointer_fields.keyIterator();
        while (it.next()) |key| {
            if (!aggregatePointerFieldKeyMatchesLocalArrayPath(key.*, local_name, array_path)) continue;
            count += 1;
            if (count >= len) return true;
        }
        return false;
    }

    fn localAggregateArrayAllElementsHaveGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, len: u64) bool {
        if (len == 0) return false;
        if (!self.localAggregateArrayHasAtLeastPointerElementFacts(local_name, array_path, len)) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            const element_path = self.aggregatePointerArrayElementPath(array_path, index) catch return false;
            if (!self.localAggregateFieldHasGlobalPointerProvenance(local_name, element_path)) return false;
        }
        return true;
    }

    fn localAggregateArrayAllElementsHaveLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, len: u64) bool {
        if (len == 0) return false;
        if (!self.localAggregateArrayHasAtLeastPointerElementFacts(local_name, array_path, len)) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            const element_path = self.aggregatePointerArrayElementPath(array_path, index) catch return false;
            if (!self.localAggregateFieldHasLocalPointerProvenance(local_name, element_path)) return false;
        }
        return true;
    }

    fn localAggregateArrayAnyElementHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, len: u64) bool {
        if (len == 0) return false;
        var index: u64 = 0;
        while (index < len) : (index += 1) {
            const element_path = self.aggregatePointerArrayElementPath(array_path, index) catch return false;
            if (self.localAggregateFieldHasGlobalPointerProvenance(local_name, element_path)) return true;
        }
        return false;
    }

    fn localAggregateArrayRangeAnyElementHasGlobalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, start: u64, end: u64) bool {
        if (start >= end) return false;
        var index = start;
        while (index < end) : (index += 1) {
            const element_path = self.aggregatePointerArrayElementPath(array_path, index) catch return false;
            if (self.localAggregateFieldHasGlobalPointerProvenance(local_name, element_path)) return true;
        }
        return false;
    }

    fn localAggregateArrayRangeAllElementsHaveLocalPointerProvenance(self: *LlvmEmitter, local_name: []const u8, array_path: []const u8, start: u64, end: u64) bool {
        if (start >= end) return false;
        var index = start;
        while (index < end) : (index += 1) {
            const element_path = self.aggregatePointerArrayElementPath(array_path, index) catch return false;
            if (!self.localAggregateFieldHasLocalPointerProvenance(local_name, element_path)) return false;
        }
        return true;
    }

    fn directLocalAggregateBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.local_slots.contains(ident.text)) ident.text else null,
            .grouped => |inner| self.directLocalAggregateBaseName(inner.*),
            .cast => |node| self.directLocalAggregateBaseName(node.value.*),
            .call => |call| if (isAssumeNoaliasCall(call))
                self.directLocalAggregateBaseName(call.args[0])
            else
                null,
            else => null,
        };
    }

    fn directStructTypeName(self: *LlvmEmitter, ty: ast.TypeExpr) ?[]const u8 {
        const name = typeName(self.resolveAliasType(ty)) orelse return null;
        if (!self.struct_types.contains(name)) return null;
        return name;
    }

    fn directAggregateCopySourceExpr(self: *LlvmEmitter, expr: ast.Expr, target_ty: ast.TypeExpr) bool {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return false;
        return self.directAggregateCopySourceExprForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceBaseName(self: *LlvmEmitter, expr: ast.Expr, target_ty: ast.TypeExpr) ?[]const u8 {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return null;
        return self.directAggregateCopySourceBaseNameForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceExprForStruct(self: *LlvmEmitter, expr: ast.Expr, target_struct_name: []const u8) bool {
        return self.directAggregateCopySourceBaseNameForStruct(expr, target_struct_name) != null or
            self.directAggregateCopySourceMemberForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceBaseNameForStruct(self: *LlvmEmitter, expr: ast.Expr, target_struct_name: []const u8) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.directAggregateCopySourceBaseNameForStruct(inner.*, target_struct_name),
            .cast => |node| self.directAggregateCopySourceBaseNameForStruct(node.value.*, target_struct_name),
            .call => |call| if (isAssumeNoaliasCall(call))
                self.directAggregateCopySourceBaseNameForStruct(call.args[0], target_struct_name)
            else
                null,
            .ident => |ident| blk: {
                if (!self.local_slots.contains(ident.text)) break :blk null;
                const source_ty = self.local_types.get(ident.text) orelse break :blk null;
                const source_struct_name = self.directStructTypeName(source_ty) orelse break :blk null;
                if (!std.mem.eql(u8, source_struct_name, target_struct_name)) break :blk null;
                break :blk ident.text;
            },
            else => null,
        };
    }

    fn directAggregateCopySourceMemberForStruct(self: *LlvmEmitter, expr: ast.Expr, target_struct_name: []const u8) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directAggregateCopySourceMemberForStruct(inner.*, target_struct_name),
            .cast => |node| self.directAggregateCopySourceMemberForStruct(node.value.*, target_struct_name),
            .call => |call| isAssumeNoaliasCall(call) and
                self.directAggregateCopySourceMemberForStruct(call.args[0], target_struct_name),
            .member => blk: {
                _ = self.directLocalAggregateMemberPath(expr) orelse break :blk false;
                const source_ty = self.exprType(expr) orelse break :blk false;
                const source_struct_name = self.directStructTypeName(source_ty) orelse break :blk false;
                break :blk std.mem.eql(u8, source_struct_name, target_struct_name);
            },
            else => false,
        };
    }

    fn localAggregatePointerAliasBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| self.local_aggregate_pointer_aliases.get(ident.text),
            .grouped => |inner| self.localAggregatePointerAliasBaseName(inner.*),
            else => null,
        };
    }

    fn joinAggregatePointerFieldPath(self: *LlvmEmitter, prefix: []const u8, field_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{ prefix, field_name });
    }

    fn aggregatePointerArrayElementPath(self: *LlvmEmitter, array_path: []const u8, index: u64) ![]const u8 {
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}[{d}]", .{ array_path, index });
    }

    fn directLocalAggregateMemberPath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalAggregateMemberPath(inner.*),
            .member => |node| blk: {
                const base_ty = self.exprType(node.base.*) orelse break :blk null;
                if (self.resolveAliasType(base_ty).kind == .pointer) break :blk null;
                _ = self.memberField(node.base.*, node.name.text) orelse break :blk null;
                if (self.directLocalAggregateBaseName(node.base.*)) |local_name| {
                    break :blk .{ .local_name = local_name, .field_path = node.name.text };
                }
                const base_path = self.directLocalAggregateMemberPath(node.base.*) orelse
                    self.directLocalAggregateArrayElementPath(node.base.*) orelse
                    break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.joinAggregatePointerFieldPath(base_path.field_path, node.name.text) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn directLocalAggregateArrayElementPath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalAggregateArrayElementPath(inner.*),
            .index => |node| blk: {
                const base_path = self.directLocalAggregateMemberPath(node.base.*) orelse
                    self.directLocalAggregateArrayElementPath(node.base.*) orelse
                    break :blk null;
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                const array = switch (base_ty.kind) {
                    .array => |array| array,
                    else => break :blk null,
                };
                const child_ty = self.resolveAliasType(array.child.*);
                if (!self.isPointerLikeType(child_ty) and self.directStructTypeName(child_ty) == null and child_ty.kind != .array) break :blk null;
                const index = self.localArrayConstIndexValue(node.index.*) orelse break :blk null;
                const len = self.arrayLenValue(array.len) orelse break :blk null;
                if (index >= len) break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.aggregatePointerArrayElementPath(base_path.field_path, index) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn directLocalAggregateArrayBasePath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        const path = self.directLocalAggregateMemberPath(expr) orelse return null;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(array.child.*)) return null;
        return path;
    }

    fn directLocalAggregateArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAnyElementHasGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveLocalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasMemberPath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.aggregatePointerAliasMemberPath(inner.*),
            .member => |node| blk: {
                const base_ty = self.exprType(node.base.*) orelse break :blk null;
                _ = self.memberField(node.base.*, node.name.text) orelse break :blk null;
                if (self.resolveAliasType(base_ty).kind == .pointer) {
                    const local_name = self.localAggregatePointerAliasBaseName(node.base.*) orelse break :blk null;
                    break :blk .{ .local_name = local_name, .field_path = node.name.text };
                }
                const base_path = self.aggregatePointerAliasMemberPath(node.base.*) orelse break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.joinAggregatePointerFieldPath(base_path.field_path, node.name.text) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn aggregatePointerAliasArrayElementPath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.aggregatePointerAliasArrayElementPath(inner.*),
            .index => |node| blk: {
                const base_path = self.aggregatePointerAliasMemberPath(node.base.*) orelse break :blk null;
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                const array = switch (base_ty.kind) {
                    .array => |array| array,
                    else => break :blk null,
                };
                if (!self.isPointerLikeType(array.child.*)) break :blk null;
                const index = self.localArrayConstIndexValue(node.index.*) orelse break :blk null;
                const len = self.arrayLenValue(array.len) orelse break :blk null;
                if (index >= len) break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.aggregatePointerArrayElementPath(base_path.field_path, index) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn aggregatePointerAliasArrayBasePath(self: *LlvmEmitter, expr: ast.Expr) ?AggregatePointerFieldPath {
        const path = self.aggregatePointerAliasMemberPath(expr) orelse return null;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(array.child.*)) return null;
        return path;
    }

    fn aggregatePointerAliasArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAnyElementHasGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveLocalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateAssignmentPath(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) !?AggregatePointerFieldPath {
        const base_ty = self.exprType(base) orelse return null;
        if (self.resolveAliasType(base_ty).kind == .pointer) return null;
        if (self.directLocalAggregateBaseName(base)) |local_name| {
            return .{ .local_name = local_name, .field_path = field_name };
        }
        const base_path = self.directLocalAggregateMemberPath(base) orelse return null;
        return .{
            .local_name = base_path.local_name,
            .field_path = try self.joinAggregatePointerFieldPath(base_path.field_path, field_name),
        };
    }

    fn aggregatePointerAliasAssignmentPath(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) !?AggregatePointerFieldPath {
        const base_ty = self.exprType(base) orelse return null;
        if (self.resolveAliasType(base_ty).kind == .pointer) {
            const local_name = self.localAggregatePointerAliasBaseName(base) orelse return null;
            return .{ .local_name = local_name, .field_path = field_name };
        }
        const base_path = self.aggregatePointerAliasMemberPath(base) orelse return null;
        return .{
            .local_name = base_path.local_name,
            .field_path = try self.joinAggregatePointerFieldPath(base_path.field_path, field_name),
        };
    }

    fn localArrayConstIndexValue(self: *LlvmEmitter, expr: ast.Expr) ?u64 {
        if (self.globalConstIndexValue(expr)) |index| return index;
        return switch (expr.kind) {
            .int_literal => |literal| parseU64Literal(literal),
            .grouped => |inner| self.localArrayConstIndexValue(inner.*),
            else => null,
        };
    }

    fn directLocalArrayBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const slot = self.local_slots.get(ident.text) orelse break :blk null;
                if (self.resolveAliasType(slot.ty).kind != .array) break :blk null;
                break :blk ident.text;
            },
            .grouped => |inner| self.directLocalArrayBaseName(inner.*),
            else => null,
        };
    }

    fn directLocalArrayElementPath(self: *LlvmEmitter, expr: ast.Expr) ?LocalArrayPointerElementPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalArrayElementPath(inner.*),
            .index => |node| blk: {
                const local_name = self.directLocalArrayBaseName(node.base.*) orelse break :blk null;
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                const array = switch (base_ty.kind) {
                    .array => |array| array,
                    else => break :blk null,
                };
                if (!self.isPointerLikeType(array.child.*)) break :blk null;
                const index = self.localArrayConstIndexValue(node.index.*) orelse break :blk null;
                const len = self.arrayLenValue(array.len) orelse break :blk null;
                if (index >= len) break :blk null;
                break :blk .{ .local_name = local_name, .index = index };
            },
            else => null,
        };
    }

    fn directLocalArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveGlobalPointerProvenance(local_name, len);
    }

    fn directLocalArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAnyElementHasGlobalPointerProvenance(local_name, len);
    }

    fn directLocalArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveLocalPointerProvenance(local_name, len);
    }

    fn directLocalPointerArrayAddressBaseName(self: *LlvmEmitter, ty: ast.TypeExpr, init: ast.Expr) ?[]const u8 {
        const pointee_ty = switch (self.resolveAliasType(ty).kind) {
            .pointer => |pointer| self.resolveAliasType(pointer.child.*),
            else => return null,
        };
        const pointee_array = switch (pointee_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(pointee_array.child.*)) return null;

        const init_target = switch (init.kind) {
            .address_of => |inner| inner.*,
            .grouped => |inner| return self.directLocalPointerArrayAddressBaseName(ty, inner.*),
            else => return null,
        };
        const array_name = self.directLocalArrayBaseName(init_target) orelse return null;
        const source_ty = self.resolveAliasType((self.local_slots.get(array_name) orelse return null).ty);
        const source_array = switch (source_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(source_array.child.*)) return null;
        const pointee_len = self.arrayLenValue(pointee_array.len) orelse return null;
        const source_len = self.arrayLenValue(source_array.len) orelse return null;
        if (pointee_len != source_len) return null;
        if (!sema_type.sameTypeSyntax(self.resolveAliasType(pointee_array.child.*), self.resolveAliasType(source_array.child.*))) return null;
        return array_name;
    }

    fn updateLocalPointerArrayAliasProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        _ = self.local_pointer_array_aliases.remove(local_name);
        const array_name = self.directLocalPointerArrayAddressBaseName(ty, init) orelse return;
        if (std.mem.eql(u8, array_name, local_name)) return;
        try self.local_pointer_array_aliases.put(local_name, array_name);
    }

    fn localPointerArrayAliasPointerName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| self.localPointerArrayAliasPointerName(inner.*),
            else => null,
        };
    }

    fn localPointerArrayAliasBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.localPointerArrayAliasBaseName(inner.*),
            .deref => |inner| if (self.localPointerArrayAliasPointerName(inner.*)) |name|
                self.local_pointer_array_aliases.get(name)
            else
                null,
            else => null,
        };
    }

    fn localPointerArrayAliasBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveGlobalPointerProvenance(array_name, len);
    }

    fn localPointerArrayAliasBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAnyElementHasGlobalPointerProvenance(array_name, len);
    }

    fn localPointerArrayAliasBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveLocalPointerProvenance(array_name, len);
    }

    fn setLocalSliceAggregatePointerArrayField(self: *LlvmEmitter, slice_name: []const u8, field_path: []const u8) !void {
        if (self.local_slice_aggregate_pointer_array_fields.fetchRemove(slice_name)) |entry| {
            self.allocator.free(entry.value);
        }
        const owned_path = try self.allocator.dupe(u8, field_path);
        errdefer self.allocator.free(owned_path);
        try self.local_slice_aggregate_pointer_array_fields.put(slice_name, owned_path);
    }

    fn directLocalArraySliceBase(self: *LlvmEmitter, ty: ast.TypeExpr, init: ast.Expr) ?LocalSlicePointerArrayBase {
        const resolved_ty = self.resolveAliasType(ty);
        const slice_ty = switch (resolved_ty.kind) {
            .slice => |slice| slice,
            else => return null,
        };
        if (!self.isPointerLikeType(slice_ty.child.*)) return null;

        const node = switch (init.kind) {
            .slice => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .slice => |node| node,
                else => return null,
            },
            else => return null,
        };
        const array_name = self.directLocalArrayBaseName(node.base.*) orelse return null;
        const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(array.child.*)) return null;
        const len = self.arrayLenValue(array.len) orelse return null;
        const maybe_start = self.localArrayConstIndexValue(node.start.*);
        const maybe_end = self.localArrayConstIndexValue(node.end.*);
        const start = maybe_start orelse 0;
        const end = maybe_end orelse len;
        const start_exact = maybe_start != null;
        if (start >= end or end > len) return null;
        if (!self.localArrayRangeAnyElementHasGlobalPointerProvenance(array_name, start, end) and
            !self.localArrayRangeAllElementsHaveLocalPointerProvenance(array_name, start, end)) return null;
        return .{ .name = array_name, .range = .{ .start = start, .end = end, .start_exact = start_exact } };
    }

    fn directLocalAggregateArraySliceBase(self: *LlvmEmitter, ty: ast.TypeExpr, init: ast.Expr) ?LocalSliceAggregatePointerArrayBase {
        const resolved_ty = self.resolveAliasType(ty);
        const slice_ty = switch (resolved_ty.kind) {
            .slice => |slice| slice,
            else => return null,
        };
        if (!self.isPointerLikeType(slice_ty.child.*)) return null;

        const node = switch (init.kind) {
            .slice => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .slice => |node| node,
                else => return null,
            },
            else => return null,
        };
        const path = self.directLocalAggregateArrayBasePath(node.base.*) orelse
            self.aggregatePointerAliasArrayBasePath(node.base.*) orelse
            return null;
        const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(array.child.*)) return null;
        const len = self.arrayLenValue(array.len) orelse return null;
        const maybe_start = self.localArrayConstIndexValue(node.start.*);
        const maybe_end = self.localArrayConstIndexValue(node.end.*);
        const start = maybe_start orelse 0;
        const end = maybe_end orelse len;
        const start_exact = maybe_start != null;
        if (start >= end or end > len) return null;
        if (!self.localAggregateArrayRangeAnyElementHasGlobalPointerProvenance(path.local_name, path.field_path, start, end) and
            !self.localAggregateArrayRangeAllElementsHaveLocalPointerProvenance(path.local_name, path.field_path, start, end)) return null;
        return .{ .path = path, .range = .{ .start = start, .end = end, .start_exact = start_exact } };
    }

    fn updateLocalSlicePointerElementProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        self.clearLocalSliceGlobalPointerArray(local_name);
        if (self.directLocalArraySliceBase(ty, init)) |base| {
            try self.local_slice_global_pointer_arrays.put(local_name, base.name);
            try self.local_slice_pointer_array_ranges.put(local_name, base.range);
            return;
        }
        if (self.directLocalAggregateArraySliceBase(ty, init)) |base| {
            try self.local_slice_global_pointer_arrays.put(local_name, base.path.local_name);
            try self.local_slice_pointer_array_ranges.put(local_name, base.range);
            try self.setLocalSliceAggregatePointerArrayField(local_name, base.path.field_path);
        }
    }

    fn tryCopyAggregatePointerFieldProvenanceFromCall(
        self: *LlvmEmitter,
        dest_name: []const u8,
        dest_struct_decl: ast.StructDecl,
        init: ast.Expr,
    ) !bool {
        const call = switch (init.kind) {
            .call => |call| call,
            .grouped => |inner| return self.tryCopyAggregatePointerFieldProvenanceFromCall(dest_name, dest_struct_decl, inner.*),
            else => return false,
        };
        const callee = self.directCallName(call.callee.*) orelse return false;
        const sig = self.fn_sigs.get(callee) orelse return false;
        const source_struct_decl = self.structDeclForType(sig.ret) orelse return false;
        if (source_struct_decl.is_c_union) return false;
        if (!std.mem.eql(u8, source_struct_decl.name.text, dest_struct_decl.name.text)) return false;

        const ReturnField = struct {
            path: []const u8,
            provenance: mir.PointerProvenance,
        };
        var copied_fields: std.ArrayList(ReturnField) = .empty;
        const scratch = self.scratch.allocator();
        var it = self.aggregate_return_pointer_fields.iterator();
        while (it.next()) |entry| {
            const field_path = self.aggregateReturnPointerFieldKeyPath(entry.key_ptr.*, callee) orelse continue;
            // Only visible global storage survives an aggregate return as a usable
            // provenance fact. local_storage in the callee would name dead stack
            // storage from the caller's perspective, so it must stay conservative.
            if (entry.value_ptr.* != .global_storage) continue;
            try copied_fields.append(scratch, .{
                .path = try scratch.dupe(u8, field_path),
                .provenance = entry.value_ptr.*,
            });
            if (self.mirAggregateReturnPointerFact(callee, field_path)) |fact| {
                try self.emitMirAggregateReturnPointerFactConsumedComment(fact);
            }
        }

        for (copied_fields.items) |field| {
            try self.setAggregatePointerFieldProvenance(dest_name, field.path, field.provenance);
        }
        return copied_fields.items.len != 0;
    }

    fn mirAggregateReturnPointerFact(self: *LlvmEmitter, callee: []const u8, field_path: []const u8) ?mir.AggregateReturnPointerFact {
        for (self.mir_module.aggregate_return_pointer_facts) |fact| {
            if (!std.mem.eql(u8, fact.callee, callee)) continue;
            if (!std.mem.eql(u8, fact.field_path, field_path)) continue;
            return fact;
        }
        return null;
    }

    fn emitMirAggregateReturnPointerFactConsumedComment(self: *LlvmEmitter, fact: mir.AggregateReturnPointerFact) !void {
        const caller = self.current_function orelse return;
        try self.out.print(
            self.allocator,
            "  ; mir aggregate_return_pointer consumed caller={s} callee={s} field={s} provenance={s} source={d}:{d}\n",
            .{ caller, fact.callee, fact.field_path, @tagName(fact.provenance), fact.source.line, fact.source.column },
        );
    }

    fn pointerExprStorageProvenance(self: *LlvmEmitter, expr: ast.Expr) mir.PointerProvenance {
        if (self.pointerExprHasGlobalStorageProvenance(expr)) return .global_storage;
        if (self.pointerExprHasProvenLocalStorage(expr)) return .local_storage;
        return .unknown;
    }

    fn updateAggregatePointerFieldProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        const struct_decl = self.structDeclForType(ty) orelse {
            self.clearAggregatePointerFieldsForLocal(local_name);
            return;
        };
        if (struct_decl.is_c_union) {
            self.clearAggregatePointerFieldsForLocal(local_name);
            return;
        }
        if (self.directAggregateCopySourceBaseName(init, ty)) |source_name| {
            if (std.mem.eql(u8, source_name, local_name)) return;
        }

        self.clearAggregatePointerFieldsForLocal(local_name);
        if (self.directAggregateCopySourceExpr(init, ty)) {
            _ = try self.applyMirAggregatePointerFieldFactsForSubjectAtSource(local_name, init.span);
            return;
        }
        if (try self.tryCopyAggregatePointerFieldProvenanceFromCall(local_name, struct_decl, init)) return;
        const fields = self.structLiteralFields(init) orelse return;
        try self.updateAggregatePointerFieldProvenanceFromStructLiteral(local_name, struct_decl, fields, null);
    }

    fn structLiteralFields(self: *LlvmEmitter, expr: ast.Expr) ?[]const ast.StructLiteralField {
        _ = self;
        return switch (expr.kind) {
            .struct_literal => |fields| fields,
            .grouped => |inner| switch (inner.kind) {
                .struct_literal => |fields| fields,
                else => null,
            },
            else => null,
        };
    }

    fn updateAggregatePointerFieldProvenanceFromStructLiteral(
        self: *LlvmEmitter,
        local_name: []const u8,
        struct_decl: ast.StructDecl,
        fields: []const ast.StructLiteralField,
        path_prefix: ?[]const u8,
    ) !void {
        for (struct_decl.fields) |field| {
            const value_expr = structLiteralField(fields, field.name.text) orelse continue;
            const field_path = if (path_prefix) |prefix|
                try self.joinAggregatePointerFieldPath(prefix, field.name.text)
            else
                field.name.text;
            if (self.isPointerLikeType(field.ty)) {
                if (try self.applyMirAggregatePointerFieldFactsAtSource(local_name, field_path, null, value_expr.span)) continue;
                if (self.directMirPointerContainerValueExpr(value_expr)) {
                    try self.setAggregatePointerFieldProvenance(local_name, field_path, .unknown);
                    continue;
                }
                try self.setAggregatePointerFieldProvenance(local_name, field_path, self.pointerExprStorageProvenance(value_expr));
                continue;
            }
            if (try self.updateAggregateArrayPointerElementProvenanceFromLiteral(local_name, field_path, field.ty, value_expr)) continue;
            const nested_struct_decl = self.structDeclForType(field.ty) orelse continue;
            if (nested_struct_decl.is_c_union) continue;
            const nested_fields = self.structLiteralFields(value_expr) orelse continue;
            try self.updateAggregatePointerFieldProvenanceFromStructLiteral(local_name, nested_struct_decl, nested_fields, field_path);
        }
    }

    fn updateAggregateArrayPointerElementProvenanceFromLiteral(
        self: *LlvmEmitter,
        local_name: []const u8,
        array_path: []const u8,
        array_ty: ast.TypeExpr,
        init: ast.Expr,
    ) !bool {
        const resolved_ty = self.resolveAliasType(array_ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!self.isPointerLikeType(array.child.*)) return false;

        self.clearAggregatePointerFieldsForLocalPath(local_name, array_path);
        const items = self.arrayLiteralItems(init) orelse return true;
        const len = self.arrayLenValue(array.len) orelse return true;
        if (items.len != len) return true;
        for (items, 0..) |item, index| {
            const element_path = try self.aggregatePointerArrayElementPath(array_path, @intCast(index));
            if (try self.applyMirAggregatePointerFieldFactsAtSource(local_name, array_path, index, item.span)) continue;
            if (self.directMirPointerContainerValueExpr(item)) {
                try self.setAggregatePointerFieldProvenance(local_name, element_path, .unknown);
                continue;
            }
            try self.setAggregatePointerFieldProvenance(local_name, element_path, self.pointerExprStorageProvenance(item));
        }
        return true;
    }

    fn updateAggregatePointerFieldProvenanceFromAssignment(
        self: *LlvmEmitter,
        base: ast.Expr,
        field_name: []const u8,
        field_ty: ast.TypeExpr,
        value_expr: ast.Expr,
    ) !void {
        const direct_target_path = try self.directLocalAggregateAssignmentPath(base, field_name);
        const target_path = direct_target_path orelse
            (try self.aggregatePointerAliasAssignmentPath(base, field_name)) orelse return;
        if (self.isPointerLikeType(field_ty)) {
            if (direct_target_path != null and try self.applyMirAggregatePointerFieldFactsAtSource(target_path.local_name, target_path.field_path, null, value_expr.span)) return;
            if (direct_target_path != null and self.directMirPointerContainerValueExpr(value_expr)) {
                try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, .unknown);
                return;
            }
            try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, self.pointerExprStorageProvenance(value_expr));
            return;
        }

        self.clearLocalSlicesBackedByArray(target_path.local_name);
        if (try self.updateAggregateArrayPointerElementProvenanceFromLiteral(target_path.local_name, target_path.field_path, field_ty, value_expr)) return;

        const struct_decl = self.structDeclForType(field_ty) orelse return;
        self.clearAggregatePointerFieldsForLocalPath(target_path.local_name, target_path.field_path);
        if (struct_decl.is_c_union) return;
        if (direct_target_path != null and self.directAggregateCopySourceExpr(value_expr, field_ty) and try self.applyMirAggregatePointerFieldFactsForSubjectAtSource(target_path.local_name, value_expr.span)) return;
        const fields = self.structLiteralFields(value_expr) orelse return;
        try self.updateAggregatePointerFieldProvenanceFromStructLiteral(target_path.local_name, struct_decl, fields, target_path.field_path);
    }

    fn arrayLiteralItems(self: *LlvmEmitter, expr: ast.Expr) ?[]const ast.Expr {
        _ = self;
        return switch (expr.kind) {
            .array_literal => |items| items,
            .grouped => |inner| switch (inner.kind) {
                .array_literal => |items| items,
                else => null,
            },
            else => null,
        };
    }

    fn updateLocalArrayPointerElementProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        const resolved_ty = self.resolveAliasType(ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => {
                self.clearLocalArrayPointerElementsForLocal(local_name);
                return;
            },
        };
        self.clearLocalSlicesBackedByArray(local_name);
        self.clearLocalPointerArrayAliasesBackedByArray(local_name);
        if (!self.isPointerLikeType(array.child.*)) {
            self.clearLocalArrayPointerElementsForLocal(local_name);
            return;
        }

        self.clearLocalArrayPointerElementsForLocal(local_name);
        const items = self.arrayLiteralItems(init) orelse return;
        const len = self.arrayLenValue(array.len) orelse return;
        if (items.len != len) return;
        for (items, 0..) |item, index| {
            if (try self.applyMirPointerProvenanceFactsAtSourceWithMode(local_name, index, item.span, .silent)) continue;
            if (self.directMirPointerContainerValueExpr(item)) {
                try self.setLocalArrayPointerElementProvenance(local_name, @intCast(index), .unknown);
                continue;
            }
            const provenance: mir.PointerProvenance = if (self.pointerExprHasGlobalStorageProvenance(item))
                .global_storage
            else if (self.pointerExprHasProvenLocalStorage(item))
                .local_storage
            else
                .unknown;
            try self.setLocalArrayPointerElementProvenance(local_name, @intCast(index), provenance);
        }
    }

    fn updateLocalArrayPointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast.Expr, element_ty: ast.TypeExpr, value_expr: ast.Expr) !void {
        const node = switch (target.kind) {
            .index => |node| node,
            .grouped => |inner| return self.updateLocalArrayPointerElementProvenanceFromAssignment(inner.*, element_ty, value_expr),
            else => return,
        };
        const local_name = self.directLocalArrayBaseName(node.base.*) orelse {
            if (self.localPointerArrayAliasBaseName(node.base.*)) |array_name| {
                self.invalidateLocalPointerArrayBackedByArrayWrite(array_name);
            }
            return;
        };
        self.clearLocalPointerArrayAliasesBackedByArray(local_name);
        if (!self.isPointerLikeType(element_ty)) return;
        const index = self.localArrayConstIndexValue(node.index.*) orelse {
            self.clearLocalArrayPointerElementsForLocal(local_name);
            return;
        };
        const path = self.directLocalArrayElementPath(target) orelse {
            self.clearLocalArrayPointerElementsForLocal(local_name);
            return;
        };
        if (try self.applyMirPointerProvenanceFactsAtSourceWithMode(path.local_name, path.index, value_expr.span, .silent)) return;
        if (self.directMirPointerContainerValueExpr(value_expr)) {
            try self.setLocalArrayPointerElementProvenance(path.local_name, path.index, .unknown);
            return;
        }
        const provenance: mir.PointerProvenance = if (self.pointerExprHasGlobalStorageProvenance(value_expr))
            .global_storage
        else if (self.pointerExprHasProvenLocalStorage(value_expr))
            .local_storage
        else
            .unknown;
        try self.setLocalArrayPointerElementProvenance(path.local_name, index, provenance);
    }

    fn invalidateLocalSlicePointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast.Expr) void {
        const node = switch (target.kind) {
            .index => |node| node,
            .grouped => |inner| return self.invalidateLocalSlicePointerElementProvenanceFromAssignment(inner.*),
            else => return,
        };
        if (self.directLocalArrayBaseName(node.base.*)) |array_name| {
            self.clearLocalSlicesBackedByArray(array_name);
            return;
        }
        if (self.provenLocalSliceBaseName(node.base.*)) |slice_name| {
            self.invalidateProvenSliceWrite(slice_name);
        }
    }

    fn updateAggregateArrayPointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast.Expr, element_ty: ast.TypeExpr, value_expr: ast.Expr) !void {
        const node = switch (target.kind) {
            .index => |node| node,
            .grouped => |inner| return self.updateAggregateArrayPointerElementProvenanceFromAssignment(inner.*, element_ty, value_expr),
            else => return,
        };
        const direct_array_path = self.directLocalAggregateArrayBasePath(node.base.*);
        const array_path = direct_array_path orelse
            self.aggregatePointerAliasArrayBasePath(node.base.*) orelse return;
        self.clearLocalSlicesBackedByArray(array_path.local_name);
        if (!self.isPointerLikeType(element_ty)) return;
        if (self.localArrayConstIndexValue(node.index.*) == null) {
            self.clearAggregatePointerFieldsForLocalPath(array_path.local_name, array_path.field_path);
            return;
        }
        const element_path = self.directLocalAggregateArrayElementPath(target) orelse
            self.aggregatePointerAliasArrayElementPath(target) orelse {
            self.clearAggregatePointerFieldsForLocalPath(array_path.local_name, array_path.field_path);
            return;
        };
        if (direct_array_path != null and try self.applyMirAggregatePointerFieldFactsAtSource(array_path.local_name, array_path.field_path, @intCast(self.localArrayConstIndexValue(node.index.*).?), value_expr.span)) return;
        if (direct_array_path != null and self.directMirPointerContainerValueExpr(value_expr)) {
            try self.setAggregatePointerFieldProvenance(element_path.local_name, element_path.field_path, .unknown);
            return;
        }
        try self.setAggregatePointerFieldProvenance(element_path.local_name, element_path.field_path, self.pointerExprStorageProvenance(value_expr));
    }

    fn currentMirFunction(self: *LlvmEmitter) ?*const mir.Function {
        const function_name = self.current_function orelse return null;
        for (self.mir_module.functions) |*function| {
            if (std.mem.eql(u8, function.name, function_name)) return function;
        }
        return null;
    }

    fn mirCallTargetKindAt(self: *LlvmEmitter, span: ast.Span) ?mir.CallTargetKind {
        const function = self.currentMirFunction() orelse return null;
        for (function.call_target_facts) |fact| {
            if (mirSourceMatches(span, fact.source)) return fact.kind;
        }
        return null;
    }

    fn mirTargetTypeFactAt(self: *LlvmEmitter, kind: mir.TargetTypeKind, span: ast.Span) ?mir.TargetTypeFact {
        if (self.currentMirFunction()) |function| {
            for (function.target_type_facts) |fact| {
                if (fact.kind == kind and mirSourceMatches(span, fact.source)) return fact;
            }
        }
        if (span.line == 0 or span.column == 0) return null;
        var matched: ?mir.TargetTypeFact = null;
        for (self.mir_module.functions) |function| for (function.target_type_facts) |fact| {
            if (fact.kind != kind or !mirSourceMatches(span, fact.source)) continue;
            if (matched) |existing| {
                if (!std.meta.eql(existing.target_ty, fact.target_ty)) return null;
            } else {
                matched = fact;
            }
        };
        return matched;
    }

    fn mirSourceMatches(span: ast.Span, source: mir.SourcePoint) bool {
        return span.line == source.line and span.column == source.column;
    }

    fn mirPointerFactIsLiveGlobal(fact: mir.PointerProvenanceFact) bool {
        if (fact.provenance != .global_storage) return false;
        return mirPointerFactReasonIsLive(fact);
    }

    // A live local_storage fact is the positive locality proof that lets a deref
    // keep PLAIN lowering under the spec I.13 conservative default. Liveness is
    // symmetric with the global side: any call/indirect-call/address-escape/
    // dynamic-index invalidation drops the proof back to unknown (-> atomic).
    fn mirPointerFactIsLiveLocal(fact: mir.PointerProvenanceFact) bool {
        if (fact.provenance != .local_storage) return false;
        return mirPointerFactReasonIsLive(fact);
    }

    fn mirPointerFactReasonIsLive(fact: mir.PointerProvenanceFact) bool {
        return switch (fact.invalidation_reason) {
            .none, .reassignment => true,
            .dynamic_index_write, .call, .indirect_call, .address_escape => false,
        };
    }

    fn mirFactSubjectSupportedNow(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) bool {
        const ty = self.local_types.get(fact.subject) orelse return false;
        if (fact.element_index != null) return self.fixedLocalPointerArrayElementType(ty) != null;
        return self.isPointerLikeType(ty) or self.fixedLocalPointerArrayElementType(ty) != null;
    }

    fn fixedLocalPointerArrayElementType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!self.isPointerLikeType(array.child.*)) return null;
        if (self.arrayLenValue(array.len) == null) return null;
        return array.child.*;
    }

    fn emitMirPointerProvenanceConsumedComment(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) !void {
        const fn_name = self.current_function orelse return;
        if (fact.field_path) |field_path| {
            if (fact.element_index) |index| {
                try self.out.print(self.allocator, "  ; mir pointer_provenance consumed fn={s} subject={s} field={s} element={d} provenance={s} reason={s} source={d}:{d}\n", .{
                    fn_name,
                    fact.subject,
                    field_path,
                    index,
                    @tagName(fact.provenance),
                    @tagName(fact.invalidation_reason),
                    fact.source.line,
                    fact.source.column,
                });
            } else {
                try self.out.print(self.allocator, "  ; mir pointer_provenance consumed fn={s} subject={s} field={s} provenance={s} reason={s} source={d}:{d}\n", .{
                    fn_name,
                    fact.subject,
                    field_path,
                    @tagName(fact.provenance),
                    @tagName(fact.invalidation_reason),
                    fact.source.line,
                    fact.source.column,
                });
            }
        } else if (fact.element_index) |index| {
            try self.out.print(self.allocator, "  ; mir pointer_provenance consumed fn={s} subject={s} element={d} provenance={s} reason={s} source={d}:{d}\n", .{
                fn_name,
                fact.subject,
                index,
                @tagName(fact.provenance),
                @tagName(fact.invalidation_reason),
                fact.source.line,
                fact.source.column,
            });
        } else {
            try self.out.print(self.allocator, "  ; mir pointer_provenance consumed fn={s} subject={s} provenance={s} reason={s} source={d}:{d}\n", .{
                fn_name,
                fact.subject,
                @tagName(fact.provenance),
                @tagName(fact.invalidation_reason),
                fact.source.line,
                fact.source.column,
            });
        }
    }

    fn mirPointerFactState(fact: mir.PointerProvenanceFact) mir.PointerProvenance {
        if (mirPointerFactIsLiveGlobal(fact)) return .global_storage;
        if (mirPointerFactIsLiveLocal(fact)) return .local_storage;
        return .unknown;
    }

    fn applyMirPointerProvenanceFact(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) !void {
        if (!self.mirFactSubjectSupportedNow(fact)) return;
        try self.emitMirPointerProvenanceConsumedComment(fact);
        try self.applyMirPointerProvenanceFactState(fact);
    }

    fn applyMirPointerProvenanceFactState(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) !void {
        if (fact.field_path) |field_path| {
            if (fact.element_index) |index| {
                const element_path = try self.aggregatePointerArrayElementPath(field_path, @intCast(index));
                try self.setAggregatePointerFieldProvenance(fact.subject, element_path, mirPointerFactState(fact));
            } else {
                try self.setAggregatePointerFieldProvenance(fact.subject, field_path, mirPointerFactState(fact));
            }
            return;
        }
        if (fact.element_index) |index| {
            try self.setLocalArrayPointerElementProvenance(fact.subject, @intCast(index), mirPointerFactState(fact));
            return;
        }
        const live_global = mirPointerFactIsLiveGlobal(fact);
        if (self.fixedLocalPointerArrayElementType(self.local_types.get(fact.subject) orelse return) != null) {
            self.clearLocalArrayPointerElementsForLocal(fact.subject);
            return;
        }
        if (live_global) {
            try self.pointer_local_provenance.put(fact.subject, .global_storage);
        } else if (mirPointerFactIsLiveLocal(fact)) {
            try self.pointer_local_provenance.put(fact.subject, .local_storage);
        } else {
            _ = self.pointer_local_provenance.remove(fact.subject);
        }
    }

    fn applyMirPointerProvenanceFactsAtSourceWithMode(self: *LlvmEmitter, subject: []const u8, element_index: ?usize, span: ast.Span, comment_mode: MirFactCommentMode) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (fact.field_path != null) continue;
            if (!std.mem.eql(u8, fact.subject, subject)) continue;
            if (element_index) |wanted| {
                if (fact.element_index == null or fact.element_index.? != wanted) continue;
            } else if (fact.element_index != null) {
                continue;
            }
            if (!mirSourceMatches(span, fact.source)) continue;
            matched = true;
            switch (comment_mode) {
                .silent => {
                    if (!self.mirFactSubjectSupportedNow(fact)) continue;
                    try self.applyMirPointerProvenanceFactState(fact);
                },
                .emit_comment => try self.applyMirPointerProvenanceFact(fact),
            }
        }
        return matched;
    }

    fn applyMirPointerProvenanceInvalidationsAtCall(self: *LlvmEmitter, span: ast.Span) void {
        const function = self.currentMirFunction() orelse return;
        for (function.pointer_provenance_facts) |fact| {
            if (!mirSourceMatches(span, fact.source)) continue;
            switch (fact.invalidation_reason) {
                .call, .indirect_call => {},
                else => continue,
            }
            if (fact.field_path) |field_path| {
                self.clearAggregatePointerFieldsForLocalPath(fact.subject, field_path);
                continue;
            }
            if (!self.mirFactSubjectSupportedNow(fact)) continue;
            if (fact.element_index != null) {
                self.clearLocalArrayPointerElementsForLocal(fact.subject);
            } else if (self.fixedLocalPointerArrayElementType(self.local_types.get(fact.subject) orelse continue) != null) {
                self.clearLocalArrayPointerElementsForLocal(fact.subject);
            } else {
                _ = self.pointer_local_provenance.remove(fact.subject);
            }
        }
    }

    fn applyMirPointerProvenanceFactsAtSource(self: *LlvmEmitter, subject: []const u8, element_index: ?usize, span: ast.Span) !bool {
        return self.applyMirPointerProvenanceFactsAtSourceWithMode(subject, element_index, span, .emit_comment);
    }

    fn applyMirAggregatePointerFieldFactsAtSource(self: *LlvmEmitter, subject: []const u8, field_path: []const u8, element_index: ?usize, span: ast.Span) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!std.mem.eql(u8, fact.subject, subject)) continue;
            const fact_field = fact.field_path orelse continue;
            if (!std.mem.eql(u8, fact_field, field_path)) continue;
            if (element_index) |wanted| {
                if (fact.element_index == null or fact.element_index.? != wanted) continue;
            } else if (fact.element_index != null) {
                continue;
            }
            if (!mirSourceMatches(span, fact.source)) continue;
            matched = true;
            try self.emitMirPointerProvenanceConsumedComment(fact);
            try self.applyMirPointerProvenanceFactState(fact);
        }
        return matched;
    }

    fn applyMirAggregatePointerFieldFactsForSubjectAtSource(self: *LlvmEmitter, subject: []const u8, span: ast.Span) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!std.mem.eql(u8, fact.subject, subject)) continue;
            if (fact.field_path == null) continue;
            if (!mirSourceMatches(span, fact.source)) continue;
            matched = true;
            try self.emitMirPointerProvenanceConsumedComment(fact);
            try self.applyMirPointerProvenanceFactState(fact);
        }
        return matched;
    }

    fn directMirAddressProvenanceExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceExpr(inner.*),
            .cast => |node| self.directMirAddressProvenanceExpr(node.value.*),
            .address_of => |inner| self.directMirAddressProvenanceTarget(inner.*),
            .call => |call| isAssumeNoaliasCall(call) and self.directMirAddressProvenanceExpr(call.args[0]),
            else => false,
        };
    }

    fn directMirAddressProvenanceTarget(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceTarget(inner.*),
            .ident => |ident| self.global_types.contains(ident.text) or self.local_types.contains(ident.text),
            else => false,
        };
    }

    fn mirPointerProvenanceCoversDirectLocalUpdate(self: *LlvmEmitter, ty: ast.TypeExpr, expr: ast.Expr) bool {
        return self.isPointerLikeType(ty) and self.directMirPointerContainerValueExpr(expr);
    }

    fn directMirRawManyZeroOffsetExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirRawManyZeroOffsetExpr(inner.*),
            .cast => |node| self.directMirRawManyZeroOffsetExpr(node.value.*),
            .call => |call| blk: {
                if (isAssumeNoaliasCall(call)) {
                    break :blk self.directMirRawManyZeroOffsetExpr(call.args[0]);
                }
                if (call.type_args.len != 0 or call.args.len != 1) break :blk false;
                const member = memberExpr(call.callee.*) orelse break :blk false;
                if (!std.mem.eql(u8, member.name.text, "offset")) break :blk false;
                if (self.localArrayConstIndexValue(call.args[0]) != 0) break :blk false;
                const base_name = self.directRawManyLocalName(member.base.*) orelse break :blk false;
                _ = base_name;
                break :blk true;
            },
            else => false,
        };
    }

    fn directRawManyLocalName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.directRawManyLocalName(inner.*),
            .ident => |ident| blk: {
                const ty = self.local_types.get(ident.text) orelse break :blk null;
                if (self.resolveAliasType(ty).kind != .raw_many_pointer) break :blk null;
                break :blk ident.text;
            },
            else => null,
        };
    }

    fn directMirPointerLocalCopyExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirPointerLocalCopyExpr(inner.*),
            .cast => |node| self.directMirPointerLocalCopyExpr(node.value.*),
            .call => |call| isAssumeNoaliasCall(call) and self.directMirPointerLocalCopyExpr(call.args[0]),
            .ident => |ident| blk: {
                const ty = self.local_types.get(ident.text) orelse break :blk false;
                break :blk self.isPointerLikeType(ty);
            },
            else => false,
        };
    }

    fn directMirFixedPointerArrayElementExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirFixedPointerArrayElementExpr(inner.*),
            .cast => |node| self.directMirFixedPointerArrayElementExpr(node.value.*),
            .call => |call| isAssumeNoaliasCall(call) and self.directMirFixedPointerArrayElementExpr(call.args[0]),
            .index => |node| self.directLocalArrayElementPath(expr) != null or
                self.localPointerArrayAliasBaseName(node.base.*) != null,
            else => false,
        };
    }

    fn directMirAggregatePointerFieldExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerFieldExpr(inner.*),
            .cast => |node| self.directMirAggregatePointerFieldExpr(node.value.*),
            .call => |call| isAssumeNoaliasCall(call) and self.directMirAggregatePointerFieldExpr(call.args[0]),
            else => self.directLocalAggregateMemberPath(expr) != null or
                self.aggregatePointerAliasMemberPath(expr) != null,
        };
    }

    fn directMirAggregatePointerArrayElementExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerArrayElementExpr(inner.*),
            .cast => |node| self.directMirAggregatePointerArrayElementExpr(node.value.*),
            .call => |call| isAssumeNoaliasCall(call) and self.directMirAggregatePointerArrayElementExpr(call.args[0]),
            else => self.directLocalAggregateArrayElementPath(expr) != null or
                self.aggregatePointerAliasArrayElementPath(expr) != null,
        };
    }

    fn directMirPointerContainerValueExpr(self: *LlvmEmitter, expr: ast.Expr) bool {
        switch (expr.kind) {
            .call => |call| {
                if (isAssumeNoaliasCall(call)) {
                    return self.directMirPointerContainerValueExpr(call.args[0]);
                }
            },
            else => {},
        }
        return self.directMirAddressProvenanceExpr(expr) or
            self.directMirRawManyZeroOffsetExpr(expr) or
            self.directMirPointerLocalCopyExpr(expr) or
            self.directMirFixedPointerArrayElementExpr(expr) or
            self.directMirAggregatePointerFieldExpr(expr) or
            self.directMirAggregatePointerArrayElementExpr(expr);
    }

    fn applyMirPointerProvenanceForLocalInitializer(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        if (self.isPointerLikeType(ty)) {
            const matched = try self.applyMirPointerProvenanceFactsAtSource(name, null, init.span);
            if (!matched and self.directMirPointerContainerValueExpr(init)) _ = self.pointer_local_provenance.remove(name);
            return;
        }
        if (self.fixedLocalPointerArrayElementType(ty) == null) return;
        const items = self.arrayLiteralItems(init) orelse return;
        for (items, 0..) |item, index| {
            const matched = try self.applyMirPointerProvenanceFactsAtSource(name, index, item.span);
            if (!matched and self.directMirPointerContainerValueExpr(item)) {
                try self.setLocalArrayPointerElementProvenance(name, @intCast(index), .unknown);
            }
        }
    }

    fn applyMirPointerProvenanceForAssignment(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, value_expr: ast.Expr, span: ast.Span) !void {
        if (self.isPointerLikeType(ty)) {
            const matched_value = try self.applyMirPointerProvenanceFactsAtSource(name, null, value_expr.span);
            _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, span);
            if (!matched_value and self.directMirPointerContainerValueExpr(value_expr)) _ = self.pointer_local_provenance.remove(name);
            return;
        }
        if (self.fixedLocalPointerArrayElementType(ty) == null) return;
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, span);
        const items = self.arrayLiteralItems(value_expr) orelse return;
        for (items, 0..) |item, index| {
            const matched = try self.applyMirPointerProvenanceFactsAtSource(name, index, item.span);
            if (!matched and self.directMirPointerContainerValueExpr(item)) {
                try self.setLocalArrayPointerElementProvenance(name, @intCast(index), .unknown);
            }
        }
    }

    fn applyMirPointerProvenanceForIndexAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr, span: ast.Span) !void {
        const path = self.directLocalArrayElementPath(target) orelse {
            const node = switch (target.kind) {
                .index => |node| node,
                .grouped => |inner| return self.applyMirPointerProvenanceForIndexAssignment(inner.*, value_expr, span),
                else => return,
            };
            if (self.directLocalArrayBaseName(node.base.*)) |local_name| {
                _ = try self.applyMirPointerProvenanceFactsAtSource(local_name, null, span);
            }
            return;
        };
        const matched_value = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, path.index, value_expr.span);
        _ = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, path.index, span);
        _ = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, null, span);
        if (!matched_value and self.directMirPointerContainerValueExpr(value_expr)) {
            try self.setLocalArrayPointerElementProvenance(path.local_name, path.index, .unknown);
        }
    }

    fn directGlobalStorageRoot(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| !self.local_slots.contains(ident.text) and !self.local_types.contains(ident.text) and self.global_types.contains(ident.text),
            .grouped => |inner| self.directGlobalStorageRoot(inner.*),
            .index => |node| self.directGlobalStorageRoot(node.base.*),
            .member => |node| self.directGlobalStorageRoot(node.base.*),
            else => false,
        };
    }

    fn isPointerLikeType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return switch (self.resolveAliasType(ty).kind) {
            .pointer, .raw_many_pointer => true,
            else => false,
        };
    }

    const MirFactCommentMode = enum {
        silent,
        emit_comment,
    };

    fn updatePointerProvenanceFromMirOrLocalProof(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, init: ast.Expr, comment_mode: MirFactCommentMode) !void {
        if (!self.isPointerLikeType(ty)) {
            _ = self.pointer_local_provenance.remove(name);
            return;
        }
        _ = self.pointer_local_provenance.remove(name);
        if (try self.applyMirPointerProvenanceFactsAtSourceWithMode(name, null, init.span, comment_mode)) return;
        if (self.mirPointerProvenanceCoversDirectLocalUpdate(ty, init)) return;
        if (self.pointerExprHasProvenLocalStorage(init)) {
            try self.pointer_local_provenance.put(name, .local_storage);
        }
    }

    fn updatePointerProvenanceAssignmentFromMirOrLocalProof(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, value_expr: ast.Expr, span: ast.Span) !void {
        if (!self.isPointerLikeType(ty)) {
            _ = self.pointer_local_provenance.remove(name);
            return;
        }
        _ = self.pointer_local_provenance.remove(name);
        const matched_value = try self.applyMirPointerProvenanceFactsAtSourceWithMode(name, null, value_expr.span, .emit_comment);
        _ = try self.applyMirPointerProvenanceFactsAtSourceWithMode(name, null, span, .emit_comment);
        if (matched_value or self.mirPointerProvenanceCoversDirectLocalUpdate(ty, value_expr)) return;
        if (self.pointerExprHasProvenLocalStorage(value_expr)) {
            try self.pointer_local_provenance.put(name, .local_storage);
        }
    }

    fn clearAggregatePointerAliasesToLocal(self: *LlvmEmitter, local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.local_aggregate_pointer_aliases.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, local_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            const key = found_key orelse return;
            _ = self.local_aggregate_pointer_aliases.remove(key);
        }
    }

    fn localAggregateAddressBaseName(self: *LlvmEmitter, expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .address_of => |inner| blk: {
                const local_name = self.directLocalAggregateBaseName(inner.*) orelse break :blk null;
                const slot = self.local_slots.get(local_name) orelse break :blk null;
                const struct_decl = self.structDeclForType(slot.ty) orelse break :blk null;
                if (struct_decl.is_c_union) break :blk null;
                break :blk local_name;
            },
            .grouped => |inner| self.localAggregateAddressBaseName(inner.*),
            else => null,
        };
    }

    fn updateAggregatePointerAliasProvenance(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, init: ast.Expr) !void {
        const resolved_ty = self.resolveAliasType(ty);
        const pointee_ty = switch (resolved_ty.kind) {
            .pointer => |node| node.child.*,
            else => {
                _ = self.local_aggregate_pointer_aliases.remove(name);
                return;
            },
        };
        const struct_decl = self.structDeclForType(pointee_ty) orelse {
            _ = self.local_aggregate_pointer_aliases.remove(name);
            return;
        };
        if (struct_decl.is_c_union) {
            _ = self.local_aggregate_pointer_aliases.remove(name);
            return;
        }
        const base_name = self.localAggregateAddressBaseName(init) orelse {
            _ = self.local_aggregate_pointer_aliases.remove(name);
            return;
        };
        if (std.mem.eql(u8, base_name, name)) {
            _ = self.local_aggregate_pointer_aliases.remove(name);
            return;
        }
        try self.local_aggregate_pointer_aliases.put(name, base_name);
    }

    fn invalidateAggregatePointerDerefAssignment(self: *LlvmEmitter, ptr_expr: ast.Expr) void {
        const local_name = self.localAggregatePointerAliasBaseName(ptr_expr) orelse return;
        self.clearAggregatePointerFieldsForLocal(local_name);
        self.clearLocalSlicesBackedByArray(local_name);
    }

    fn pointerExprHasGlobalStorageProvenance(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| if (self.pointer_local_provenance.get(ident.text)) |provenance| provenance == .global_storage else false,
            .address_of => |inner| self.directGlobalStorageRoot(inner.*),
            .grouped => |inner| self.pointerExprHasGlobalStorageProvenance(inner.*),
            .cast => |node| self.pointerExprHasGlobalStorageProvenance(node.value.*),
            .member => if (self.directLocalAggregateMemberPath(expr)) |path|
                self.localAggregateFieldHasGlobalPointerProvenance(path.local_name, path.field_path)
            else if (self.aggregatePointerAliasMemberPath(expr)) |path|
                self.localAggregateFieldHasGlobalPointerProvenance(path.local_name, path.field_path)
            else
                false,
            .index => |node| if (self.directLocalAggregateArrayElementPath(expr)) |path|
                self.localAggregateFieldHasGlobalPointerProvenance(path.local_name, path.field_path)
            else if (self.aggregatePointerAliasArrayElementPath(expr)) |path|
                self.localAggregateFieldHasGlobalPointerProvenance(path.local_name, path.field_path)
            else if (self.directLocalArrayElementPath(expr)) |path|
                self.localArrayElementHasGlobalPointerProvenance(path.local_name, path.index)
            else if (self.provenLocalSliceBaseName(node.base.*)) |slice_name|
                if (self.localArrayConstIndexValue(node.index.*)) |index|
                    self.localSliceElementHasGlobalPointerProvenance(slice_name, index)
                else
                    self.localSliceAnyElementHasGlobalPointerProvenance(slice_name)
            else
                self.localArrayConstIndexValue(node.index.*) == null and
                    (self.directLocalAggregateArrayBaseHasAnyGlobalPointerProvenance(node.base.*) or
                        self.aggregatePointerAliasArrayBaseHasAnyGlobalPointerProvenance(node.base.*) or
                        self.directLocalArrayBaseHasAnyGlobalPointerProvenance(node.base.*) or
                        self.localPointerArrayAliasBaseHasAnyGlobalPointerProvenance(node.base.*)),
            .call => |call| if (isAssumeNoaliasCall(call))
                self.pointerExprHasGlobalStorageProvenance(call.args[0])
            else if (self.rawManyOffsetCallInfo(call)) |info|
                call.args.len == 1 and
                    self.localArrayConstIndexValue(call.args[0]) == 0 and
                    self.pointerExprHasGlobalStorageProvenance(info.base)
            else
                false,
            else => false,
        };
    }

    // Positive locality proof for the bare pointer-deref access class (spec I.13):
    // PLAIN deref lowering is allowed only when the pointer provably names the
    // current function's own storage — a live MIR local_storage fact for the
    // pointer local, or a syntactic address-of a named local (through grouped/
    // cast). Everything else (params, unknown calls, invalidated facts, member/
    // element-derived pointers without a fact) lowers race-tolerantly.
    fn pointerExprHasProvenLocalStorage(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| if (self.pointer_local_provenance.get(ident.text)) |provenance| provenance == .local_storage else false,
            .address_of => |inner| self.directLocalStorageRoot(inner.*),
            .grouped => |inner| self.pointerExprHasProvenLocalStorage(inner.*),
            .cast => |node| self.pointerExprHasProvenLocalStorage(node.value.*),
            .member => if (self.directLocalAggregateMemberPath(expr)) |path|
                self.localAggregateFieldHasLocalPointerProvenance(path.local_name, path.field_path)
            else if (self.aggregatePointerAliasMemberPath(expr)) |path|
                self.localAggregateFieldHasLocalPointerProvenance(path.local_name, path.field_path)
            else
                false,
            .index => |node| if (self.directLocalAggregateArrayElementPath(expr)) |path|
                self.localAggregateFieldHasLocalPointerProvenance(path.local_name, path.field_path)
            else if (self.aggregatePointerAliasArrayElementPath(expr)) |path|
                self.localAggregateFieldHasLocalPointerProvenance(path.local_name, path.field_path)
            else if (self.directLocalArrayElementPath(expr)) |path|
                self.localArrayElementHasLocalPointerProvenance(path.local_name, path.index)
            else if (self.provenLocalSliceBaseName(node.base.*)) |slice_name|
                if (self.localArrayConstIndexValue(node.index.*)) |index|
                    self.localSliceElementHasLocalPointerProvenance(slice_name, index)
                else
                    self.localSliceAllElementsHaveLocalPointerProvenance(slice_name)
            else
                self.localArrayConstIndexValue(node.index.*) == null and
                    (self.directLocalAggregateArrayBaseHasAllLocalPointerProvenance(node.base.*) or
                        self.aggregatePointerAliasArrayBaseHasAllLocalPointerProvenance(node.base.*) or
                        self.directLocalArrayBaseHasAllLocalPointerProvenance(node.base.*) or
                        self.localPointerArrayAliasBaseHasAllLocalPointerProvenance(node.base.*)),
            else => false,
        };
    }

    // Only a bare named local counts: member/index roots may reach through a
    // pointer-typed base (auto-deref), which does NOT prove the storage is local.
    fn directLocalStorageRoot(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalStorageRoot(inner.*),
            .ident => |ident| self.local_slots.contains(ident.text) or self.local_types.contains(ident.text),
            else => false,
        };
    }

    // Spec I.13 conservative default for the bare pointer-deref class: ordinary
    // scalar derefs lower race-tolerantly (unordered atomic) unless positively
    // proven local. Unproven aggregate dereferences take the separate recursive
    // race-tolerant path in emitDeref; this helper covers scalar atomics only.
    fn derefUsesRaceTolerantLowering(self: *LlvmEmitter, ptr_expr: ast.Expr, pointee_ty: ast.TypeExpr) bool {
        if (self.isAggregateType(pointee_ty)) return false;
        return !self.pointerExprHasProvenLocalStorage(ptr_expr);
    }

    fn emitRaceTolerantAggregateDerefLoad(self: *LlvmEmitter, ptr: []const u8, ty: ast.TypeExpr) ![]const u8 {
        const aggregate_ty = try self.llvmType(ty);
        var result: []const u8 = "zeroinitializer";
        const resolved_ty = self.resolveAliasType(ty);
        switch (resolved_ty.kind) {
            .closure_type => {
                for (0..2) |i| {
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = load atomic ptr, ptr {s} unordered, align 8{s}\n", .{ field_value, field_ptr, try self.debugCallSuffix() });
                    const next = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, ptr {s}, {d}\n", .{ next, aggregate_ty, result, field_value, i });
                    result = next;
                }
            },
            .array => |array| {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const len_usize = std.math.cast(usize, len) orelse return error.UnsupportedLlvmEmission;
                for (0..len_usize) |i| {
                    const element_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ element_ptr, aggregate_ty, ptr, i });
                    const element_value = if (self.isAggregateType(array.child.*))
                        try self.emitRaceTolerantAggregateDerefLoad(element_ptr, array.child.*)
                    else blk: {
                        try self.emitOrdinaryShadowHook(element_ptr, array.child.*, .load_pre);
                        break :blk try self.emitOrdinaryLoad(array.child.*, element_ptr, true);
                    };
                    const next = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ next, aggregate_ty, result, try self.llvmType(array.child.*), element_value, i });
                    result = next;
                }
            },
            else => {
                const struct_decl = self.structDeclForType(ty) orelse return error.UnsupportedLlvmEmission;
                if (struct_decl.is_c_union) return error.UnsupportedLlvmEmission;
                for (struct_decl.fields, 0..) |field, i| {
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    const field_value = if (self.isAggregateType(field.ty))
                        try self.emitRaceTolerantAggregateDerefLoad(field_ptr, field.ty)
                    else blk: {
                        try self.emitOrdinaryShadowHook(field_ptr, field.ty, .load_pre);
                        break :blk try self.emitOrdinaryLoad(field.ty, field_ptr, true);
                    };
                    const next = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ next, aggregate_ty, result, try self.llvmType(field.ty), field_value, i });
                    result = next;
                }
            },
        }
        return result;
    }

    fn emitRaceTolerantAggregateDerefStore(self: *LlvmEmitter, ptr: []const u8, ty: ast.TypeExpr, value: []const u8) !void {
        const aggregate_ty = try self.llvmType(ty);
        const resolved_ty = self.resolveAliasType(ty);
        switch (resolved_ty.kind) {
            .closure_type => {
                for (0..2) |i| {
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, aggregate_ty, value, i });
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    try self.out.print(self.allocator, "  store atomic ptr {s}, ptr {s} unordered, align 8{s}\n", .{ field_value, field_ptr, try self.debugCallSuffix() });
                }
            },
            .array => |array| {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const len_usize = std.math.cast(usize, len) orelse return error.UnsupportedLlvmEmission;
                for (0..len_usize) |i| {
                    const element_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ element_value, aggregate_ty, value, i });
                    const element_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ element_ptr, aggregate_ty, ptr, i });
                    if (self.isAggregateType(array.child.*)) {
                        try self.emitRaceTolerantAggregateDerefStore(element_ptr, array.child.*, element_value);
                    } else {
                        try self.emitOrdinaryShadowHook(element_ptr, array.child.*, .store_pre);
                        try self.emitOrdinaryStore(array.child.*, try self.llvmType(array.child.*), element_value, element_ptr, true);
                        try self.emitOrdinaryShadowHook(element_ptr, array.child.*, .store_post);
                    }
                }
            },
            else => {
                const struct_decl = self.structDeclForType(ty) orelse return error.UnsupportedLlvmEmission;
                if (struct_decl.is_c_union) return error.UnsupportedLlvmEmission;
                for (struct_decl.fields, 0..) |field, i| {
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, aggregate_ty, value, i });
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    if (self.isAggregateType(field.ty)) {
                        try self.emitRaceTolerantAggregateDerefStore(field_ptr, field.ty, field_value);
                    } else {
                        try self.emitOrdinaryShadowHook(field_ptr, field.ty, .store_pre);
                        try self.emitOrdinaryStore(field.ty, try self.llvmType(field.ty), field_value, field_ptr, true);
                        try self.emitOrdinaryShadowHook(field_ptr, field.ty, .store_post);
                    }
                }
            },
        }
    }

    // True when an index expression's base is direct global array storage. The C backend
    // instruments global array-element loads via `mc_race_load_<T>`, whose macro body is
    // hook-instrumented; stores are hooked directly in emitIndexAssignment.
    fn indexBaseIsGlobal(self: *LlvmEmitter, node: anytype) bool {
        const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse return false);
        if (base_ty.kind != .array) return false;
        return self.directGlobalStorageRoot(node.base.*);
    }

    // True for `base.field[i]` value-loads where `field` is an ordinary array member. The C
    // backend observes this as a struct-field load before the element selection, so KASAN already
    // checks the poisoned aggregate; LLVM must hook the precise element pointer to keep parity.
    fn indexBaseIsOrdinaryArrayMember(self: *LlvmEmitter, node: anytype) bool {
        const base = switch (node.base.*.kind) {
            .member => node.base.*,
            .grouped => |inner| switch (inner.*.kind) {
                .member => inner.*,
                else => return false,
            },
            else => return false,
        };
        const ty = self.resolveAliasType(self.exprType(base) orelse return false);
        return ty.kind == .array;
    }

    // True when a member expression's base is a (non-local) global struct. The C backend
    // routes a global struct-field LOAD through `mc_race_load_<T>`; stores are hooked directly
    // in emitMemberAssignment.
    fn memberBaseIsGlobal(self: *LlvmEmitter, node: anytype) bool {
        if (self.resolveAliasType(self.exprType(node.base.*) orelse return false).kind == .pointer) return false;
        return self.directGlobalStorageRoot(node.base.*);
    }

    fn scalarPointerMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr, field_ty: ast.TypeExpr) bool {
        if (self.isAggregateType(field_ty)) return false;
        return self.pointerMemberBaseUsesRaceTolerantLowering(base_expr);
    }

    fn pointerMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr) bool {
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        const root = if (base_ty.kind == .pointer) base_expr else self.pointerMemberRoot(base_expr) orelse return false;
        return !self.pointerExprHasProvenLocalStorage(root);
    }

    fn pointerMemberRoot(self: *LlvmEmitter, expr: ast.Expr) ?ast.Expr {
        return switch (expr.kind) {
            .grouped => |inner| self.pointerMemberRoot(inner.*),
            .member => |node| blk: {
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                if (base_ty.kind == .pointer) break :blk node.base.*;
                break :blk self.pointerMemberRoot(node.base.*);
            },
            else => null,
        };
    }

    fn scalarIndexedMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr, field_ty: ast.TypeExpr) bool {
        if (self.isAggregateType(field_ty)) return false;
        const indexed = self.indexedMemberRoot(base_expr) orelse return false;
        const element_ty = self.indexElementType(indexed.base.*) orelse return false;
        return self.aggregateIndexUsesRaceTolerantLowering(indexed.base.*, element_ty);
    }

    fn aggregateIndexedMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr, field_ty: ast.TypeExpr) bool {
        if (!self.isAggregateType(field_ty)) return false;
        const indexed = self.indexedMemberRoot(base_expr) orelse return false;
        const element_ty = self.indexElementType(indexed.base.*) orelse return false;
        return self.aggregateIndexUsesRaceTolerantLowering(indexed.base.*, element_ty);
    }

    fn indexedMemberRoot(self: *LlvmEmitter, expr: ast.Expr) ?ast_query.IndexExpr {
        if (indexExpr(expr)) |indexed| return indexed;
        return switch (expr.kind) {
            .grouped => |inner| self.indexedMemberRoot(inner.*),
            .member => |node| self.indexedMemberRoot(node.base.*),
            else => null,
        };
    }

    fn scalarIndexUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr, element_ty: ast.TypeExpr) bool {
        if (self.isAggregateType(element_ty)) return false;
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        if (base_ty.kind == .slice) return true;
        return switch (base_expr.kind) {
            .grouped => |inner| self.scalarIndexUsesRaceTolerantLowering(inner.*, element_ty),
            .deref => |ptr_expr| !self.pointerExprHasProvenLocalStorage(ptr_expr.*),
            else => false,
        };
    }

    fn aggregateIndexUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast.Expr, element_ty: ast.TypeExpr) bool {
        if (!self.isAggregateType(element_ty)) return false;
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        if (base_ty.kind == .slice) return true;
        return switch (base_expr.kind) {
            .grouped => |inner| self.aggregateIndexUsesRaceTolerantLowering(inner.*, element_ty),
            .deref => |ptr_expr| !self.pointerExprHasProvenLocalStorage(ptr_expr.*),
            else => false,
        };
    }

    fn emitIndexLoad(self: *LlvmEmitter, node: anytype) ![]const u8 {
        if (overlayMemberFromIndexBase(node.base.*)) |member| {
            if (self.overlayField(member.base.*, member.name.text)) |field| {
                // Any array-view element (byte or non-byte): the byte offset is
                // `index * sizeof(elem)`, computed by `emitIndexAddress` via a typed GEP
                // over the storage base, so the load just uses the element type.
                const element_ty = overlayArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(element_ty), ptr, try self.debugCallSuffix() });
                return result;
            }
        }
        const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitIndexAddress(node);
        if (self.aggregateIndexUsesRaceTolerantLowering(node.base.*, element_ty)) {
            return try self.emitRaceTolerantAggregateDerefLoad(ptr, element_ty);
        }
        const use_atomic = self.indexBaseIsGlobal(node) or self.scalarIndexUsesRaceTolerantLowering(node.base.*, element_ty);
        // Global and struct-field array element loads are instrumented to match the C backend.
        if (use_atomic or self.indexBaseIsOrdinaryArrayMember(node)) {
            try self.emitOrdinaryShadowHook(ptr, element_ty, .load_pre);
        }
        return try self.emitOrdinaryLoad(element_ty, ptr, use_atomic);
    }

    fn emitIndexAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const resolved_base_ty = self.resolveAliasType(base_ty);
        const index = try self.emitExpr(node.index.*, simpleType((node.index.*).span, "usize"));
        if (overlayMemberFromIndexBase(node.base.*)) |member| {
            if (self.overlayField(member.base.*, member.name.text)) |field| {
                // Non-byte views (`[N]uW`) lower identically to byte views: the storage
                // base is byte 0, and a typed GEP scales the (bounds-checked) element
                // index by `sizeof(elem)`, landing on the element's byte offset.
                const element_ty = overlayArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                const array = switch (field.ty.kind) {
                    .array => |array| array,
                    else => return error.UnsupportedLlvmEmission,
                };
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.aggregateBasePointer(member.base.*);
                try self.requireMirBoundsFact(.index, (node.index.*).span);
                try self.emitBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(element_ty), base_ptr, index });
                return result;
            }
        }
        return switch (resolved_base_ty.kind) {
            .array => |array| blk: {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.arrayBasePointer(node.base.*);
                // OPT (annex E): skip the bounds check when the optimized MIR proved this
                // constant index in range (consumes the optimizer's `elided_bounds`).
                if (!self.mirCheckElided((node.index.*).span)) {
                    try self.requireMirBoundsFact(.index, (node.index.*).span);
                    try self.emitBoundsCheck(index, len);
                }
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(resolved_base_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const base = try self.emitExpr(node.base.*, resolved_base_ty);
                const base_llvm = try self.llvmType(resolved_base_ty);
                const ptr = try self.nextTemp();
                const len = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ ptr, base_llvm, base });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, base_llvm, base });
                try self.requireMirBoundsFact(.index, (node.index.*).span);
                try self.emitDynamicBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), ptr, index });
                break :blk result;
            },
            else => return error.UnsupportedLlvmEmission,
        };
    }

    fn arrayBasePointer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return self.aggregateBasePointer(expr);
    }

    fn aggregateBasePointer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| break :blk slot.ptr;
                if (self.global_types.contains(ident.text)) break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                break :blk error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| self.aggregateBasePointer(inner.*),
            .deref => |inner| self.emitExpr(inner.*, self.exprType(inner.*) orelse return error.UnsupportedLlvmEmission),
            .index => |node| self.emitIndexAddress(node),
            .member => |node| self.emitMemberAddress(node),
            .call, .array_literal, .struct_literal => self.materializeAggregateRvalue(expr),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn materializeAggregateRvalue(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!self.isAggregateType(ty)) return error.UnsupportedLlvmEmission;
        const value = try self.emitExpr(expr, ty);
        const ptr = try self.nextTemp();
        const llvm_ty = try self.llvmType(ty);
        try self.emitAllocaStore(ptr, llvm_ty, value);
        return ptr;
    }

    fn isStableAggregateAddress(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.local_slots.contains(ident.text) or self.global_types.contains(ident.text),
            .grouped => |inner| self.isStableAggregateAddress(inner.*),
            .index => |node| self.isStableAggregateAddress(node.base.*),
            .member => |node| self.isStableAggregateAddress(node.base.*),
            else => false,
        };
    }

    // OPT (annex E): true when the optimizer recorded this operand's source point in
    // `elided_bounds` (only under `--optimize`) — a proven-in-range constant index's Bounds
    // check, or an unsigned div-by-literal's DivideByZero check. Source points are unique per
    // location within a function; the same file-local line/column can appear in another
    // function when sources are combined from multiple files. Without the flag the list is
    // empty and the check is emitted — the backend consumes the optimized MIR, not re-derived
    // proof.
    fn mirCheckElided(self: *LlvmEmitter, span: ast.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.elided_bounds) |pt| {
                if (pt.line == span.line and pt.column == span.column) return true;
            }
        }
        return false;
    }

    fn requireMirBoundsFact(self: *LlvmEmitter, kind: mir.BoundsFactKind, span: ast.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        for (function.bounds_facts) |fact| {
            if (fact.kind == kind and fact.source.line == span.line and fact.source.column == span.column) return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn requireMirNoOverflowRangeFact(self: *LlvmEmitter, op: []const u8, span: ast.Span) !void {
        const function_name = self.current_function orelse return error.UnsupportedLlvmEmission;
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        const expected_target = self.current_mir_range_target orelse "value";
        for (function.range_facts) |fact| {
            if (!std.mem.eql(u8, fact.target, expected_target)) continue;
            if (!std.mem.eql(u8, fact.op, op)) continue;
            if (fact.line != span.line or fact.column != span.column) continue;
            try self.out.print(self.allocator, "  ; mir range_fact consumed fn={s} target={s} op={s} assumption=no_overflow source={d}:{d}\n", .{
                function_name,
                fact.target,
                fact.op,
                fact.line,
                fact.column,
            });
            return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitBoundsCheck(self: *LlvmEmitter, index: []const u8, len: u64) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {d}\n", .{ ok, index, len });
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
    }

    fn emitDynamicBoundsCheck(self: *LlvmEmitter, index: []const u8, len: []const u8) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
    }

    fn emitSliceBoundsCheck(self: *LlvmEmitter, start: []const u8, end: []const u8, len: []const u8) !void {
        const ordered = try self.nextTemp();
        const in_len = try self.nextTemp();
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ule i64 {s}, {s}\n", .{ ordered, start, end });
        try self.out.print(self.allocator, "  {s} = icmp ule i64 {s}, {s}\n", .{ in_len, end, len });
        try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ ok, ordered, in_len });
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
    }

    fn emitSlice(self: *LlvmEmitter, node: anytype, slice_span: ast.Span) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedLlvmEmission;
        const slice = switch (slice_ty.kind) {
            .slice => |slice| slice,
            else => return error.UnsupportedLlvmEmission,
        };
        // OPT (annex E): the optimized MIR proves a constant range in bounds and elides the
        // `start <= end <= len` guard — parity with the C backend and the index elision.
        const elide = self.mirCheckElided(slice_span);
        const start = try self.emitExpr(node.start.*, simpleType((node.start.*).span, "usize"));
        const end = try self.emitExpr(node.end.*, simpleType((node.end.*).span, "usize"));
        const base_ptr = switch (base_ty.kind) {
            .array => |array| blk: {
                const array_ptr = try self.arrayBasePointer(node.base.*);
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const elem_ptr = try self.nextTemp();
                if (!elide) {
                    try self.requireMirBoundsFact(.slice, slice_span);
                    try self.emitSliceBoundsCheck(start, end, try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{len}));
                }
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ elem_ptr, try self.llvmType(base_ty), array_ptr, start });
                break :blk elem_ptr;
            },
            .slice => blk: {
                const base = try self.emitExpr(node.base.*, base_ty);
                const base_llvm = try self.llvmType(base_ty);
                const ptr = try self.nextTemp();
                const len = try self.nextTemp();
                const elem_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ ptr, base_llvm, base });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, base_llvm, base });
                if (!elide) {
                    try self.requireMirBoundsFact(.slice, slice_span);
                    try self.emitSliceBoundsCheck(start, end, len);
                }
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ elem_ptr, try self.llvmType(slice.child.*), ptr, start });
                break :blk elem_ptr;
            },
            else => return error.UnsupportedLlvmEmission,
        };
        const result0 = try self.nextTemp();
        const slice_len = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ result0, try self.llvmType(slice_ty), base_ptr });
        try self.out.print(self.allocator, "  {s} = sub i64 {s}, {s}\n", .{ slice_len, end, start });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {s}, 1\n", .{ result, try self.llvmType(slice_ty), result0, slice_len });
        return result;
    }

    fn emitArrayLiteralStores(self: *LlvmEmitter, array_ptr: []const u8, array_ty: ast.TypeExpr, items: []const ast.Expr) !void {
        const array = switch (array_ty.kind) {
            .array => |array| array,
            else => return error.UnsupportedLlvmEmission,
        };
        const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
        if (items.len != len) return error.UnsupportedLlvmEmission;
        const element_ty = array.child.*;
        const element_llvm = try self.llvmType(element_ty);
        for (items, 0..) |item, i| {
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(array_ty), array_ptr, i });
            const value = if (isUninitExpr(item))
                try self.zeroInitializer(element_ty)
            else
                try self.emitExprWithMirRangeTarget(item, element_ty, "aggregate_element");
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ element_llvm, value, ptr, try self.debugCallSuffix() });
        }
    }

    fn emitExprOrTargetTypedUninit(self: *LlvmEmitter, expr: ast.Expr, target_ty: ast.TypeExpr) ![]const u8 {
        if (isUninitExpr(expr)) return try self.zeroInitializer(target_ty);
        return self.emitExpr(expr, target_ty);
    }

    fn cUnionLiteralActiveField(self: *LlvmEmitter, fields: []const ast.StructLiteralField) ?ast.StructLiteralField {
        _ = self;
        var active: ?ast.StructLiteralField = null;
        for (fields) |field| {
            if (!isUninitExpr(field.value)) active = field;
        }
        return active orelse if (fields.len > 0) fields[0] else null;
    }

    fn structDeclField(self: *LlvmEmitter, struct_decl: ast.StructDecl, name: []const u8) ?ast.Field {
        _ = self;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, name)) return field;
        }
        return null;
    }

    fn emitStructLiteralStores(self: *LlvmEmitter, struct_ptr: []const u8, struct_ty: ast.TypeExpr, fields: []const ast.StructLiteralField) !void {
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        if (struct_decl.is_c_union) {
            const active = self.cUnionLiteralActiveField(fields) orelse return error.UnsupportedLlvmEmission;
            const field = self.structDeclField(struct_decl, active.name.text) orelse return error.UnsupportedLlvmEmission;
            const value = if (isUninitExpr(active.value))
                try self.zeroInitializer(field.ty)
            else
                try self.emitExprWithMirRangeTarget(active.value, field.ty, field.name.text);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, struct_ptr, try self.debugCallSuffix() });
            return;
        }
        for (struct_decl.fields, 0..) |field, i| {
            const value_expr = structLiteralField(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ ptr, try self.llvmType(struct_ty), struct_ptr, i });
            const value = if (isUninitExpr(value_expr))
                try self.zeroInitializer(field.ty)
            else
                try self.emitExprWithMirRangeTarget(value_expr, field.ty, field.name.text);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, ptr, try self.debugCallSuffix() });
        }
    }

    fn emitArrayLiteralValue(self: *LlvmEmitter, array_ty: ast.TypeExpr, items: []const ast.Expr) ![]const u8 {
        if (array_ty.kind != .array) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.emitAlloca(ptr, try self.llvmType(array_ty));
        try self.emitArrayLiteralStores(ptr, array_ty, items);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(array_ty), ptr });
        return value;
    }

    fn emitStructLiteralValue(self: *LlvmEmitter, struct_ty: ast.TypeExpr, fields: []const ast.StructLiteralField) ![]const u8 {
        if (self.structDeclForType(struct_ty) == null) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.emitAlloca(ptr, try self.llvmType(struct_ty));
        try self.emitStructLiteralStores(ptr, struct_ty, fields);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(struct_ty), ptr });
        return value;
    }

    fn emitCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr, span: ast.Span) ![]const u8 {
        defer self.applyMirPointerProvenanceInvalidationsAtCall(span);
        defer self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        defer self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        defer self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
        defer self.local_pointer_array_aliases.clearRetainingCapacity();
        if (isDropCall(call.callee.*)) return error.UnsupportedLlvmEmission;
        if (isBindCallNode(call)) {
            const fact = self.mirTargetTypeFactAt(.bind, span) orelse return error.UnsupportedLlvmEmission;
            return try self.emitBindValue(call, fact.target_ty);
        }
        // `Union.variant(...)` qualified constructor — self-typed from the owner (no target).
        if (try self.emitQualifiedUnionConstructor(call)) |value| return value;
        if (self.mirTargetTypeFactAt(.tagged_union, span)) |fact| {
            return (try self.emitTaggedUnionConstructor(call, fact.target_ty)) orelse error.UnsupportedLlvmEmission;
        }
        if (try self.emitBuiltinValueCall(call, expected_ty, span)) |value| return value;
        if (self.directCallName(call.callee.*)) |callee| {
            return try self.emitDirectCall(callee, call, expected_ty);
        }
        // Tier 2 dynamic dispatch: `d.method(args)` through a `*dyn Trait`.
        if (self.dynDispatchTrait(call.callee.*)) |trait| {
            return try self.emitDynDispatch(call, trait);
        }
        if (self.closureCalleeType(call.callee.*)) |closure_ty| return try self.emitClosureCall(call.callee.*, call.args, closure_ty);
        const fn_ty = self.fnPointerCalleeType(call.callee.*) orelse return error.UnsupportedLlvmEmission;
        return try self.emitFnPointerCall(call.callee.*, call.args, fn_ty);
    }

    fn emitBindValue(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
        const closure_ty = self.resolveAliasType(expected_ty);
        if (closure_ty.kind != .closure_type) return error.UnsupportedLlvmEmission;
        const fname = calleeIdentName(call.args[1]) orelse return error.UnsupportedLlvmEmission;
        const sig = self.fn_sigs.get(fname) orelse return error.UnsupportedLlvmEmission;
        if (sig.params.len == 0) return error.UnsupportedLlvmEmission;
        // The function's first parameter type is the env type. Use it as the
        // expected type so address-of-param / scalar envs (whose `exprType` may be
        // null) still resolve, instead of the previous `exprType(...) orelse fail`.
        const env_ty = sig.params[0].ty;
        const env_llvm = try self.llvmType(env_ty);

        const code_ptr: []const u8 = blk: {
            if (std.mem.eql(u8, env_llvm, "ptr")) break :blk fname;
            // Scalar env: must be an integer type to widen into the `ptr` slot. A
            // generated thunk narrows it back before calling the real function.
            if (self.integerBitsOf(env_ty) == null) return error.UnsupportedLlvmEmission;
            const thunk_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_envthunk_{s}", .{fname});
            if (!self.bind_thunks.contains(thunk_name)) try self.bind_thunks.put(thunk_name, .{ .fname = fname, .sig = sig });
            break :blk thunk_name;
        };

        const env_value = try self.emitExpr(call.args[0], env_ty);
        // Widen an integer scalar env into the closure's `ptr` env slot.
        const env_ptr: []const u8 = if (std.mem.eql(u8, env_llvm, "ptr")) env_value else widen: {
            const p = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr {s} {s} to ptr\n", .{ p, env_llvm, env_value });
            break :widen p;
        };

        const with_code = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr @{s}, 0\n", .{ with_code, try self.llvmType(closure_ty), code_ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, ptr {s}, 1\n", .{ result, try self.llvmType(closure_ty), with_code, env_ptr });
        return result;
    }

    // ----- Tier 2 trait objects (traits-design §8) ------------------------------
    // The LLVM struct type of a `*dyn Trait`'s vtable: one `ptr` per trait method.
    fn dynVtableLlvmType(self: *LlvmEmitter, trait: ast.TraitDecl) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.scratch.allocator(), "{ ");
        for (trait.methods, 0..) |_, i| {
            if (i != 0) try buf.appendSlice(self.scratch.allocator(), ", ");
            try buf.appendSlice(self.scratch.allocator(), "ptr");
        }
        try buf.appendSlice(self.scratch.allocator(), " }");
        return buf.toOwnedSlice(self.scratch.allocator());
    }

    // One rodata vtable global per `impl Trait for Type` of an object-safe trait:
    //   @__vt_Type_Trait = internal constant { ptr, ... } { ptr @Type__m1, ... }
    // The function pointers are listed in trait-method order. This is rodata — no
    // heap. (LLVM's opaque `ptr` makes the void*-self erasure representation-free.)
    fn emitVtables(self: *LlvmEmitter) !void {
        var it = self.impl_methods.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
            const trait_name = key[0..sep];
            const type_name = key[sep + 1 ..];
            const trait = self.trait_decls.get(trait_name) orelse continue;
            if (!llvmTraitIsObjectSafe(trait)) continue;
            const vt_ty = try self.dynVtableLlvmType(trait);
            try self.out.print(self.allocator, "@__vt_{s}_{s} = internal constant {s} {{ ", .{ type_name, trait_name, vt_ty });
            for (trait.methods, 0..) |m, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                const mangled = implMethodMangledLlvm(entry.value_ptr.*, m.name.text) orelse return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "ptr @{s}", .{mangled});
            }
            try self.out.appendSlice(self.allocator, " }\n");
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    // Emit a `define` for each collected scalar-env thunk:
    //   define RET @mc_envthunk_f(ptr %env, P...) { %i = ptrtoint ptr %env to <iN>; ... call @f(<iN> %i, P...) ... }
    // The first parameter is genuinely `ptr`, matching the closure's code-pointer slot.
    fn emitBindThunks(self: *LlvmEmitter) !void {
        var it = self.bind_thunks.iterator();
        while (it.next()) |entry| {
            const thunk = entry.value_ptr.*;
            const sig = thunk.sig;
            const ret_llvm = try self.llvmType(sig.ret);
            const env_llvm = try self.llvmType(sig.params[0].ty);
            self.temp_index = 0;
            try self.out.print(self.allocator, "define {s} @{s}(ptr %env", .{ ret_llvm, entry.key_ptr.* });
            for (sig.params[1..], 0..) |param, i| {
                try self.out.print(self.allocator, ", {s} %a{d}", .{ try self.llvmType(param.ty), i });
            }
            try self.out.appendSlice(self.allocator, ") {\nbb_entry:\n");
            const narrowed = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = ptrtoint ptr %env to {s}\n", .{ narrowed, env_llvm });
            const returns_void = typeNameEql(sig.ret, "void");
            const result = if (returns_void) "" else try self.nextTemp();
            if (returns_void) {
                try self.out.print(self.allocator, "  call void @{s}({s} {s}", .{ thunk.fname, env_llvm, narrowed });
            } else {
                try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}", .{ result, ret_llvm, thunk.fname, env_llvm, narrowed });
            }
            for (sig.params[1..], 0..) |param, i| {
                try self.out.print(self.allocator, ", {s} %a{d}", .{ try self.llvmType(param.ty), i });
            }
            try self.out.appendSlice(self.allocator, ")\n");
            if (returns_void) {
                try self.out.appendSlice(self.allocator, "  ret void\n");
            } else {
                try self.out.print(self.allocator, "  ret {s} {s}\n", .{ ret_llvm, result });
            }
            try self.out.appendSlice(self.allocator, "}\n\n");
        }
    }

    fn emitDirectCall(self: *LlvmEmitter, callee: []const u8, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        const ret_ast_ty = if (self.fn_sigs.get(callee)) |sig| sig.ret else expected_ty;
        const ret_ty = try self.llvmType(ret_ast_ty);
        if (typeNameEql(ret_ast_ty, "void")) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const arg_ty = self.expectedTyForCallArg(callee, i) orelse expected_ty;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}(", .{ result, ret_ty, callee });
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitFnPointerCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, fn_ty: ast.TypeExpr) ![]const u8 {
        const sig = fn_ty.kind.fn_pointer;
        if (typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, fn_ty);
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(", .{ result, try self.llvmType(sig.ret.*), callee });
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitFnPointerVoidCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, fn_ty: ast.TypeExpr) !void {
        const sig = fn_ty.kind.fn_pointer;
        if (!typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, fn_ty);
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        try self.out.print(self.allocator, "  call void {s}(", .{callee});
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    // If `callee` is `d.method` where `d` has a `*dyn Trait` type, return its TraitDecl.
    fn dynDispatchTrait(self: *LlvmEmitter, callee: ast.Expr) ?ast.TraitDecl {
        const member = memberExpr(callee) orelse return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const trait_name = switch (self.resolveAliasType(base_ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            else => return null,
        };
        return self.trait_decls.get(trait_name);
    }

    // `d.method(args)` -> load the method slot from `d.vtable`, call it with `d.data`
    // first. A genuine load-through-vtable indirect call (no devirtualization).
    fn emitDynDispatch(self: *LlvmEmitter, call: anytype, trait: ast.TraitDecl) ![]const u8 {
        const member = memberCallee(call) orelse return error.UnsupportedLlvmEmission;
        const slot = traitMethodIndex(trait, member.name.text) orelse return error.UnsupportedLlvmEmission;
        const msig = trait.methods[slot];
        const dyn_ty = self.exprType(member.base.*) orelse return error.UnsupportedLlvmEmission;
        const dyn_llvm = try self.llvmType(self.resolveAliasType(dyn_ty));
        const fat = try self.emitExpr(member.base.*, self.resolveAliasType(dyn_ty));
        const data = try self.nextTemp();
        const vtable = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, dyn_llvm, fat });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ vtable, dyn_llvm, fat });
        // Load the method pointer from the vtable struct at the method's slot index.
        const vt_ty = try self.dynVtableLlvmType(trait);
        const slot_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ slot_ptr, vt_ty, vtable, slot });
        const code = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load ptr, ptr {s}\n", .{ code, slot_ptr });
        // Evaluate the real arguments (the trait method's params after `self`).
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const arg_ty = if (i + 1 < msig.params.len) msig.params[i + 1].ty else self.exprType(arg) orelse return error.UnsupportedLlvmEmission;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        const ret_ty: ast.TypeExpr = msig.return_type orelse simpleType(member.name.span, "void");
        if (typeNameEql(ret_ty, "void")) {
            try self.out.print(self.allocator, "  call void {s}(ptr {s}", .{ code, data });
            for (args.items) |arg| try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
            try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
            return "0";
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(ptr {s}", .{ result, try self.llvmType(ret_ty), code, data });
        for (args.items) |arg| try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitClosureCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, closure_ty: ast.TypeExpr) ![]const u8 {
        const sig = closure_ty.kind.closure_type;
        if (typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, closure_ty);
        const code = try self.nextTemp();
        const env = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ code, try self.llvmType(closure_ty), callee });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ env, try self.llvmType(closure_ty), callee });
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(ptr {s}", .{ result, try self.llvmType(sig.ret.*), code, env });
        for (args.items) |arg| {
            try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitClosureVoidCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, closure_ty: ast.TypeExpr) !void {
        const sig = closure_ty.kind.closure_type;
        if (!typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, closure_ty);
        const code = try self.nextTemp();
        const env = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ code, try self.llvmType(closure_ty), callee });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ env, try self.llvmType(closure_ty), callee });
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        try self.out.print(self.allocator, "  call void {s}(ptr {s}", .{ code, env });
        for (args.items) |arg| {
            try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitBuiltinValueCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr, span: ast.Span) !?[]const u8 {
        if (self.reflectionCallValue(call)) |value| return value;
        // `declassify(x)` / `reveal(x)` strip the constant-time `Secret<T>` tag.
        // Secret shares T's representation, so this is a value-identity pass-through.
        if (isDeclassifyCall(call)) {
            if (self.mirCallTargetKindAt(call.callee.*.span) != .declassify) return error.UnsupportedLlvmEmission;
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse expected_ty;
            const value = try self.emitExpr(call.args[0], source_ty);
            return try self.coerceExprValue(value, call.args[0], expected_ty);
        }
        if (isAssumeNoaliasCall(call)) {
            if (self.mirCallTargetKindAt(call.callee.*.span) != .assume_noalias) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse expected_ty;
            const value = try self.emitExpr(call.args[0], source_ty);
            _ = try self.emitExpr(call.args[1], simpleType(call.args[1].span, "usize"));
            return try self.coerceExprValue(value, call.args[0], expected_ty);
        }
        if (self.constGetCallInfo(call)) |info| {
            if (call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base_ptr = try self.arrayBasePointer(info.base);
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(info.array_ty), base_ptr, info.index });
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.element_ty), ptr });
            return result;
        }
        if (self.bitcastCallTargetType(call)) |target_ty| {
            const source_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(call.args[0], source_ty);
            return try self.emitBitcastValue(value, source_ty, target_ty);
        }
        if (self.mirCallTargetKindAt(call.callee.*.span) == .phys) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
        }
        if (mmioMapCallPayloadType(call)) |_| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (self.dmaBufCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(info.base, info.dma_ty);
            if (std.mem.eql(u8, info.op, "dma_addr")) return base;
            if (std.mem.eql(u8, info.op, "as_slice")) {
                const ptr = try self.nextTemp();
                const with_ptr = try self.nextTemp();
                const result = try self.nextTemp();
                const slice_ty = try self.sliceTypeFor(info.payload_ty, .mut, call.callee.*.span);
                try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, base });
                try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, try self.llvmType(slice_ty), ptr });
                try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 1, 1\n", .{ result, try self.llvmType(slice_ty), with_ptr });
                return result;
            }
            return error.UnsupportedLlvmEmission;
        }
        if (isAtomicInitCall(call.callee.*)) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload_ty = self.atomicPayloadType(expected_ty) orelse return error.UnsupportedLlvmEmission;
            return try self.emitAtomicValueForStorage(call.args[0], payload_ty);
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "read")) return null;
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const ordering = orderingArg(call.args[0]) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.emitMmioRegisterAddress(info);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}{s}\n", .{ result, try self.llvmType(info.storage_ty), ptr, try self.debugCallSuffix() });
            try self.emitMmioFence(ordering, .after_load);
            if (std.mem.eql(u8, try self.llvmType(info.storage_ty), try self.llvmType(info.value_ty))) return result;
            return try self.castValue(result, info.storage_ty, info.value_ty);
        }
        if (self.maybeUninitCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "assume_init")) return null;
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const ptr = try self.storageBaseAddress(info.base);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.payload_ty), ptr });
            return result;
        }
        if (self.mirCallTargetKindAt(call.callee.*.span) == .raw_load) {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const value_ty = call.type_args[0];
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const ptr = try self.nextTemp();
            const result = try self.nextTemp();
            const llvm_ty = try self.llvmType(value_ty);
            if (rawScalarTypeName(value_ty) == null) {
                // Aggregate (non-scalar) T: whole-object typed load, mirroring how
                // `raw.ptr<T>(addr)` + deref already lowers a struct read. Plain
                // (uninstrumented) typed load, matching the C backend's aggregate path.
                try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}, align {d}{s}\n", .{ result, llvm_ty, ptr, self.llvmAlignOf(value_ty), try self.debugCallSuffix() });
                return result;
            }
            // KASAN (D2.1): consult the shadow before the load — a use-after-free read
            // of poisoned (freed) memory traps in mc_ksan_check before the deref.
            if (self.ksan) try self.out.print(self.allocator, "  call void @mc_ksan_check(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(value_ty) });
            // KCSAN (D2.3): bracket the unsynchronized load with a read watchpoint hook.
            if (self.csan) try self.out.print(self.allocator, "  call void @mc_csan_read(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(value_ty) });
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}{s}\n", .{ result, llvm_ty, ptr, try self.debugCallSuffix() });
            return result;
        }
        if (vaCallMember(call.callee.*)) |va_name| {
            // The cursor argument is either `&ap` for a local va_list or a `*mut va_list`
            // parameter. Normalize both to the ABI cursor pointer that va_arg / va_end want.
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const ap_ptr = try self.emitVaListCursorArg(call.args[0]);
            if (std.mem.eql(u8, va_name, "arg")) {
                if (call.type_args.len != 1) return error.UnsupportedLlvmEmission;
                return try self.emitVaArg(ap_ptr, call.type_args[0]);
            }
            if (std.mem.eql(u8, va_name, "end")) {
                try self.out.print(self.allocator, "  call void @llvm.va_end(ptr {s})\n", .{ap_ptr});
                return ""; // void
            }
            return error.UnsupportedLlvmEmission; // va.start only valid as a let initializer
        }
        if (self.mirCallTargetKindAt(call.callee.*.span) == .raw_ptr) {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (self.enumRawCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(info.base, info.enum_ty);
            return try self.castValue(value, info.enum_ty, info.repr_ty);
        }
        if (byteViewCallKind(call.callee.*)) |kind| {
            const expected_fact = mir.byteViewCallTargetKind(call) orelse return error.UnsupportedLlvmEmission;
            if (self.mirCallTargetKindAt(call.callee.*.span) != expected_fact) return error.UnsupportedLlvmEmission;
            return try self.emitByteViewCall(call, kind);
        }
        if (resultConstructorCallTag(call)) |tag| {
            const kind: mir.TargetTypeKind = if (std.mem.eql(u8, tag, "ok")) .result_ok else .result_err;
            const fact = self.mirTargetTypeFactAt(kind, span) orelse return error.UnsupportedLlvmEmission;
            return try self.emitResultConstructorValue(call, fact.target_ty, tag);
        }
        if (self.domainResidueCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, info.domain_ty);
        }
        if (self.domainOpCallInfo(call)) |info| return try self.emitDomainOpCall(call, info);
        if (self.reduceCallInfo(call)) |info| return try self.emitReduceCall(call, info);
        if (self.conversionCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(call.args[0], info.source_ty);
            if (std.mem.eql(u8, info.op, "trap_from")) return try self.emitTrapConversion(value, info.source_ty, info.target_ty);
            if (std.mem.eql(u8, info.op, "sat_from")) return try self.emitSaturatingConversion(value, info.source_ty, info.target_ty);
            if (std.mem.eql(u8, info.op, "try_from")) return try self.emitTryConversion(value, info.source_ty, info.target_ty);
            if (!std.mem.eql(u8, info.op, "from") and !std.mem.eql(u8, info.op, "wrap_from") and !std.mem.eql(u8, info.op, "from_mod")) return error.UnsupportedLlvmEmission;
            return try self.castValue(value, info.source_ty, info.target_ty);
        }
        if (wrappingBuiltinOp(call.callee.*)) |op| {
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            if (self.integerBitsOf(expected_ty) == null) return error.UnsupportedLlvmEmission;
            const left = try self.emitExpr(call.args[0], expected_ty);
            const right = try self.emitExpr(call.args[1], expected_ty);
            return try self.emitPlainBinaryValues(op, try self.llvmType(expected_ty), left, right);
        }
        if (uncheckedBuiltinOp(call.callee.*)) |op| {
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            if (self.integerBitsOf(expected_ty) == null) return error.UnsupportedLlvmEmission;
            try self.requireMirNoOverflowRangeFact(op, span);
            const left = try self.emitExpr(call.args[0], expected_ty);
            const right = try self.emitExpr(call.args[1], expected_ty);
            return try self.emitPlainBinaryValues(op, try self.llvmType(expected_ty), left, right);
        }
        if (self.atomicCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "load")) {
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                const ordering = atomicOrderingArg(call.args, 0) orelse return error.UnsupportedLlvmEmission;
                const llvm_order = atomicLlvmOrdering(ordering, .load) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.atomicAddress(info);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} {s}, align {d}{s}\n", .{ result, try self.atomicStorageLlvmType(info.payload_ty), ptr, llvm_order, self.llvmAlignOf(info.payload_ty), try self.debugCallSuffix() });
                if (typeNameEql(info.payload_ty, "bool")) {
                    const bool_result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ bool_result, result });
                    return bool_result;
                }
                return result;
            }
            if (std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) {
                if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
                const ordering = atomicOrderingArg(call.args, 1) orelse return error.UnsupportedLlvmEmission;
                const llvm_order = atomicLlvmOrdering(ordering, .rmw) orelse return error.UnsupportedLlvmEmission;
                if (self.integerBitsOf(info.payload_ty) == null) return error.UnsupportedLlvmEmission;
                const ptr = try self.atomicAddress(info);
                const delta = try self.emitExpr(call.args[0], info.payload_ty);
                const result = try self.nextTemp();
                const op: []const u8 = if (std.mem.eql(u8, info.op, "fetch_sub")) "sub" else "add";
                try self.out.print(self.allocator, "  {s} = atomicrmw {s} ptr {s}, {s} {s} {s}{s}\n", .{ result, op, ptr, try self.llvmType(info.payload_ty), delta, llvm_order, try self.debugCallSuffix() });
                return result;
            }
        }
        if (self.rawManyOffsetCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(info.base, info.base_ty);
            const index = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(info.element_ty), base, index });
            return result;
        }
        return null;
    }

    fn emitVoidCall(self: *LlvmEmitter, callee: []const u8, call: anytype) !void {
        const sig = self.fn_sigs.get(callee) orelse return error.UnsupportedLlvmEmission;
        // A `-> never` function lowers to a `void` LLVM declaration, so its call statement is a
        // plain `call void @fn(args)` (no result name) — handled here alongside `-> void`.
        if (!typeNameEql(sig.ret, "void") and !typeNameEql(sig.ret, "never")) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const arg_ty = self.expectedTyForCallArg(callee, i) orelse self.exprType(arg) orelse return error.UnsupportedLlvmEmission;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        try self.out.print(self.allocator, "  call void @{s}(", .{callee});
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitVoidStatementCall(self: *LlvmEmitter, call: anytype, span: ast.Span) !void {
        defer self.applyMirPointerProvenanceInvalidationsAtCall(span);
        defer self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        defer self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        defer self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
        defer self.local_pointer_array_aliases.clearRetainingCapacity();
        if (self.directCallName(call.callee.*)) |callee| {
            try self.emitVoidCall(callee, call);
            return;
        }
        if (self.closureCalleeType(call.callee.*)) |closure_ty| {
            try self.emitClosureVoidCall(call.callee.*, call.args, closure_ty);
            return;
        }
        if (self.fnPointerCalleeType(call.callee.*)) |fn_ty| {
            try self.emitFnPointerVoidCall(call.callee.*, call.args, fn_ty);
            return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (binaryIsComparison(node.op)) return self.emitComparison(node, ty);
        if (node.op == .logical_and or node.op == .logical_or) return self.emitLogicalBinary(node, ty);
        const llvm_ty = try self.llvmType(ty);
        if (self.isFloatTypeOf(ty)) {
            return switch (node.op) {
                .add => try self.emitPlainBinary("fadd", node, ty, llvm_ty),
                .sub => try self.emitPlainBinary("fsub", node, ty, llvm_ty),
                .mul => try self.emitPlainBinary("fmul", node, ty, llvm_ty),
                .div => try self.emitPlainBinary("fdiv", node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        if (self.isWrapDomainType(ty)) {
            return switch (node.op) {
                .add => try self.emitPlainBinary("add", node, ty, llvm_ty),
                .sub => try self.emitPlainBinary("sub", node, ty, llvm_ty),
                .mul => try self.emitPlainBinary("mul", node, ty, llvm_ty),
                .bit_and => try self.emitPlainBinary("and", node, ty, llvm_ty),
                .bit_or => try self.emitPlainBinary("or", node, ty, llvm_ty),
                .bit_xor => try self.emitPlainBinary("xor", node, ty, llvm_ty),
                .shl, .shr => try self.emitWrapShift(node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        if (self.isSatDomainType(ty)) {
            return switch (node.op) {
                .add, .sub, .mul => try self.emitSaturatingArithmetic(node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        return switch (node.op) {
            .add, .sub, .mul => try self.emitCheckedArithmetic(node, ty, llvm_ty),
            .div, .mod => try self.emitCheckedDivRem(node, ty, llvm_ty),
            .bit_and => try self.emitPlainBinary("and", node, ty, llvm_ty),
            .bit_or => try self.emitPlainBinary("or", node, ty, llvm_ty),
            .bit_xor => try self.emitPlainBinary("xor", node, ty, llvm_ty),
            .shl, .shr => try self.emitCheckedShift(node, ty, llvm_ty),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitLogicalBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        const left_ty = self.exprType(node.left.*) orelse return error.UnsupportedLlvmEmission;
        const right_ty = self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(left_ty, "bool") or !typeNameEql(right_ty, "bool")) return error.UnsupportedLlvmEmission;

        const result_ptr = try self.nextTemp();
        try self.emitAlloca(result_ptr, "i1");

        const left = try self.emitExpr(node.left.*, left_ty);
        const rhs_label = try self.nextLabel(if (node.op == .logical_and) "logic_and_rhs" else "logic_or_rhs");
        const short_label = try self.nextLabel(if (node.op == .logical_and) "logic_and_false" else "logic_or_true");
        const end_label = try self.nextLabel("logic_end");
        switch (node.op) {
            .logical_and => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ left, rhs_label, short_label, try self.debugCallSuffix() }),
            .logical_or => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ left, short_label, rhs_label, try self.debugCallSuffix() }),
            else => unreachable,
        }

        try self.out.print(self.allocator, "{s}:\n", .{rhs_label});
        const right = try self.emitExpr(node.right.*, right_ty);
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ right, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ end_label, try self.debugCallSuffix(), short_label });
        const short_value = if (node.op == .logical_and) "0" else "1";
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ short_value, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ end_label, try self.debugCallSuffix(), end_label });
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i1, ptr {s}\n", .{ result, result_ptr });
        return result;
    }

    fn emitUnary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        return switch (node.op) {
            .logical_not => blk: {
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ result, value });
                break :blk result;
            },
            .bit_not => blk: {
                if (self.integerBitsOf(ty) == null) return error.UnsupportedLlvmEmission;
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor {s} {s}, -1\n", .{ result, try self.llvmType(ty), value });
                break :blk result;
            },
            .neg => blk: {
                if (try self.negativeIntegerLiteralValue(node.expr.*)) |literal| break :blk literal;
                const value = try self.emitExpr(node.expr.*, ty);
                if (self.isFloatTypeOf(ty)) {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = fneg {s} {s}\n", .{ result, try self.llvmType(ty), value });
                    break :blk result;
                }
                if (self.integerBitsOf(ty) != null and self.isSignedIntegerType(ty)) {
                    const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
                    const overflow = try self.nextTemp();
                    const trap = try self.nextLabel("trap_neg_overflow");
                    const cont = try self.nextLabel("neg_ok");
                    const result = try self.nextTemp();
                    const llvm_ty = try self.llvmType(ty);
                    try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ overflow, llvm_ty, value, min_literal });
                    try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
                    try self.out.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ result, llvm_ty, value });
                    break :blk result;
                }
                if (self.isWrapDomainType(ty)) {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ result, try self.llvmType(ty), value });
                    break :blk result;
                }
                return error.UnsupportedLlvmEmission;
            },
        };
    }

    fn negativeIntegerLiteralValue(self: *LlvmEmitter, expr: ast.Expr) !?[]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)}),
            .grouped => |inner| try self.negativeIntegerLiteralValue(inner.*),
            else => null,
        };
    }

    fn emitCast(self: *LlvmEmitter, span: ast.Span, value_expr: ast.Expr) ![]const u8 {
        const source_fact = self.mirTargetTypeFactAt(.explicit_cast_source, span) orelse return error.UnsupportedLlvmEmission;
        const target_fact = self.mirTargetTypeFactAt(.explicit_cast_target, span) orelse return error.UnsupportedLlvmEmission;
        const value = try self.emitExprNatural(value_expr, source_fact.target_ty);
        return try self.castValue(value, source_fact.target_ty, target_fact.target_ty);
    }

    fn emitExprNatural(self: *LlvmEmitter, expr: ast.Expr, source_ty: ast.TypeExpr) anyerror![]const u8 {
        return switch (expr.kind) {
            .binary => |node| try self.emitBinary(node, source_ty),
            .grouped => |inner| try self.emitExprNatural(inner.*, source_ty),
            else => try self.emitExpr(expr, source_ty),
        };
    }

    fn castValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (std.mem.eql(u8, source_llvm, target_llvm) and
            self.fixedLayoutBitsOf(source_ty) != null and
            self.fixedLayoutBitsOf(target_ty) != null)
        {
            return value;
        }
        if (std.mem.eql(u8, source_llvm, target_llvm)) {
            const source_name = typeName(self.resolveAliasType(source_ty));
            const target_name = typeName(self.resolveAliasType(target_ty));
            if (source_name != null and target_name != null and std.mem.eql(u8, source_name.?, target_name.?)) {
                return value;
            }
        }
        // A `[]mut T as []const T` const-narrowing cast is a no-op: both slices lower to the
        // identical `{ ptr, i64 }` LLVM type (LLVM pointers carry no constness).
        if (std.mem.eql(u8, source_llvm, target_llvm) and
            self.resolveAliasType(source_ty).kind == .slice and
            self.resolveAliasType(target_ty).kind == .slice)
        {
            return value;
        }
        if (self.pointerAddressCoercion(source_ty, target_ty)) {
            return try self.emitBitcastValue(value, source_ty, target_ty);
        }
        if ((self.integerBitsOf(source_ty) != null or self.enumDeclForType(source_ty) != null) and
            (self.integerBitsOf(target_ty) != null or self.enumDeclForType(target_ty) != null))
        {
            return try self.castIntegerValue(value, source_ty, target_ty);
        }
        if (typeNameEql(self.resolveAliasType(source_ty), "bool") and self.integerBitsOf(target_ty) != null) {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = zext i1 {s} to {s}\n", .{ result, value, target_llvm });
            return result;
        }
        if (self.integerBitsOf(source_ty) != null and typeNameEql(self.resolveAliasType(target_ty), "bool")) {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, 0\n", .{ result, source_llvm, value });
            return result;
        }
        // Float <-> float: widen f32->f64 (fpext) or narrow f64->f32 (fptrunc). Same-width
        // float-to-float is already handled by the identical-llvm-type early return above.
        if (self.isFloatTypeOf(source_ty) and self.isFloatTypeOf(target_ty)) {
            const op = if (self.isF32TypeOf(source_ty)) "fpext" else "fptrunc";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        // Integer -> float: sitofp for signed sources, uitofp for unsigned.
        if (self.integerBitsOf(source_ty) != null and self.isFloatTypeOf(target_ty)) {
            const op = if (self.isSignedIntegerType(source_ty)) "sitofp" else "uitofp";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        // Float -> integer: fptosi for signed targets, fptoui for unsigned (C truncation).
        if (self.isFloatTypeOf(source_ty) and self.integerBitsOf(target_ty) != null) {
            const op = if (self.isSignedIntegerType(target_ty)) "fptosi" else "fptoui";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitBitcastValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_bits = self.fixedLayoutBitsOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const target_bits = self.fixedLayoutBitsOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        if (source_bits != target_bits) return error.UnsupportedLlvmEmission;

        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (std.mem.eql(u8, source_llvm, target_llvm)) return value;

        const op: []const u8 = if (std.mem.eql(u8, source_llvm, "ptr"))
            "ptrtoint"
        else if (std.mem.eql(u8, target_llvm, "ptr"))
            "inttoptr"
        else
            "bitcast";

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
        return result;
    }

    fn castIntegerValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_bits = self.integerBitsOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const target_bits = self.integerBitsOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        if (source_bits == target_bits) return value;

        const result = try self.nextTemp();
        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (source_bits < target_bits) {
            const op: []const u8 = if (self.isSignedIntegerType(source_ty)) "sext" else "zext";
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
        } else {
            try self.out.print(self.allocator, "  {s} = trunc {s} {s} to {s}\n", .{ result, source_llvm, value, target_llvm });
        }
        return result;
    }

    fn emitTrapConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const check = try self.emitConversionOutOfRange(value, source_ty, target_ty);
        if (check) |out_of_range| {
            const trap = try self.nextLabel("trap_conversion");
            const cont = try self.nextLabel("conversion_ok");
            try self.emitTrapBranch(out_of_range, trap, cont, trap, cont, "IntegerOverflow");
        }
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitSaturatingConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const src_range = self.intRangeOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const dst_range = self.intRangeOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        const source_llvm = try self.llvmType(source_ty);
        var current = value;
        if (src_range.min < dst_range.min) {
            const below = try self.nextTemp();
            const selected = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "slt" else "ult";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ below, pred, source_llvm, current, dst_range.min });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, below, source_llvm, dst_range.min, source_llvm, current });
            current = selected;
        }
        if (src_range.max > dst_range.max) {
            const above = try self.nextTemp();
            const selected = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "sgt" else "ugt";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ above, pred, source_llvm, current, dst_range.max });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, above, source_llvm, dst_range.max, source_llvm, current });
            current = selected;
        }
        return try self.castValue(current, source_ty, target_ty);
    }

    fn emitByteViewCall(self: *LlvmEmitter, call: anytype, kind: ByteViewCallKind) ![]const u8 {
        if (call.type_args.len != 0) return error.UnsupportedLlvmEmission;
        return switch (kind) {
            .as_bytes => try self.emitAsBytesCall(call),
            .bytes_equal => try self.emitBytesEqualCall(call),
        };
    }

    fn emitAsBytesCall(self: *LlvmEmitter, call: anytype) ![]const u8 {
        if (call.args.len != 1) return error.UnsupportedLlvmEmission;
        const target = byteViewAddressTarget(call.args[0]) orelse return error.UnsupportedLlvmEmission;
        const source_ty = self.exprType(target) orelse return error.UnsupportedLlvmEmission;
        const size = self.comptimeSizeOf(source_ty, 0) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitExpr(call.args[0], try self.pointerTypeFor(source_ty));
        const slice_ty = try self.constU8SliceType(call.callee.*.span);
        const slice_llvm = try self.llvmType(slice_ty);
        const with_ptr = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, slice_llvm, ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {d}, 1\n", .{ result, slice_llvm, with_ptr, size });
        return result;
    }

    fn emitBytesEqualCall(self: *LlvmEmitter, call: anytype) ![]const u8 {
        if (call.args.len != 2) return error.UnsupportedLlvmEmission;
        const slice_ty = try self.constU8SliceType(call.callee.*.span);
        const slice_llvm = try self.llvmType(slice_ty);
        const left = try self.emitExpr(call.args[0], self.exprType(call.args[0]) orelse slice_ty);
        const right = try self.emitExpr(call.args[1], self.exprType(call.args[1]) orelse slice_ty);
        const left_ptr = try self.nextTemp();
        const left_len = try self.nextTemp();
        const right_ptr = try self.nextTemp();
        const right_len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ left_ptr, slice_llvm, left });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ left_len, slice_llvm, left });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ right_ptr, slice_llvm, right });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ right_len, slice_llvm, right });

        const index_ptr = try self.nextTemp();
        const result_ptr = try self.nextTemp();
        try self.emitAlloca(index_ptr, "i64");
        try self.emitAlloca(result_ptr, "i1");
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store i1 0, ptr {s}\n", .{result_ptr});

        const len_match = try self.nextTemp();
        const cond_label = try self.nextLabel("bytes_equal_cond");
        const body_label = try self.nextLabel("bytes_equal_body");
        const step_label = try self.nextLabel("bytes_equal_step");
        const equal_label = try self.nextLabel("bytes_equal_true");
        const done_label = try self.nextLabel("bytes_equal_done");
        try self.out.print(self.allocator, "  {s} = icmp eq i64 {s}, {s}\n", .{ len_match, left_len, right_len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ len_match, cond_label, done_label, try self.debugCallSuffix(), cond_label });

        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, left_len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, equal_label, try self.debugCallSuffix(), body_label });

        const left_elem_ptr = try self.nextTemp();
        const right_elem_ptr = try self.nextTemp();
        const left_byte = try self.nextTemp();
        const right_byte = try self.nextTemp();
        const same = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ left_elem_ptr, left_ptr, index });
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ right_elem_ptr, right_ptr, index });
        try self.out.print(self.allocator, "  {s} = load i8, ptr {s}\n", .{ left_byte, left_elem_ptr });
        try self.out.print(self.allocator, "  {s} = load i8, ptr {s}\n", .{ right_byte, right_elem_ptr });
        try self.out.print(self.allocator, "  {s} = icmp eq i8 {s}, {s}\n", .{ same, left_byte, right_byte });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ same, step_label, done_label, try self.debugCallSuffix(), step_label });

        const next_index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), equal_label });
        try self.out.print(self.allocator, "  store i1 1, ptr {s}\n", .{result_ptr});
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), done_label });

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i1, ptr {s}\n", .{ result, result_ptr });
        return result;
    }

    fn emitTryConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const result_ty = try self.resultType(target_ty, simpleType(target_ty.span, "ConversionError"), target_ty.span);
        const converted = try self.castValue(value, source_ty, target_ty);
        const out_of_range = try self.emitConversionOutOfRange(value, source_ty, target_ty);
        if (out_of_range) |check| {
            const tag = try self.nextTemp();
            const selected_payload = try self.nextTemp();
            const target_llvm = try self.resultPayloadLlvmType(target_ty);
            try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ tag, check });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} {s}\n", .{ selected_payload, check, target_llvm, try self.resultPayloadZero(target_ty), target_llvm, converted });
            return try self.emitResultValue(result_ty, tag, selected_payload, "0");
        }
        return try self.emitResultValue(result_ty, "true", converted, "0");
    }

    fn emitConversionOutOfRange(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) !?[]const u8 {
        const src_range = self.intRangeOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const dst_range = self.intRangeOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        const source_llvm = try self.llvmType(source_ty);
        var result: ?[]const u8 = null;
        if (src_range.min < dst_range.min) {
            const below = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "slt" else "ult";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ below, pred, source_llvm, value, dst_range.min });
            result = below;
        }
        if (src_range.max > dst_range.max) {
            const above = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "sgt" else "ugt";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ above, pred, source_llvm, value, dst_range.max });
            if (result) |previous| {
                const combined = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ combined, previous, above });
                result = combined;
            } else {
                result = above;
            }
        }
        return result;
    }

    fn intRangeOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?IntRange {
        const bits = self.integerBitsOf(ty) orelse return null;
        if (self.isSignedIntegerType(ty)) {
            const max = (@as(i128, 1) << @intCast(bits - 1)) - 1;
            return .{ .min = -max - 1, .max = max };
        }
        const max = (@as(i128, 1) << @intCast(bits)) - 1;
        return .{ .min = 0, .max = max };
    }

    fn emitComparison(self: *LlvmEmitter, node: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        // `opt == null` / `opt != null` for a value optional `?T` tests its present tag.
        if ((node.op == .eq or node.op == .ne)) {
            if (try self.valueOptionalNullCompare(node)) |result| return result;
        }
        // A comparison yields i1. The expected type is `bool` — or `Secret<bool>`
        // when the verdict stays secret-tainted (constant-time `secret == k`);
        // Secret is transparent, so the inner bool is what we lower against.
        const want = secretInnerType(expected_ty) orelse expected_ty;
        if (!typeNameEql(want, "bool")) return error.UnsupportedLlvmEmission;
        const operand_ty = self.exprType(node.left.*) orelse self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(operand_ty);
        const pred = if (self.isFloatTypeOf(operand_ty))
            floatComparisonPredicate(node.op) orelse return error.UnsupportedLlvmEmission
        else
            comparisonPredicate(node.op, self.isSignedIntegerType(operand_ty)) orelse return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, operand_ty);
        const right = try self.emitExpr(node.right.*, operand_ty);
        const result = try self.nextTemp();
        const cmp_op: []const u8 = if (self.isFloatTypeOf(operand_ty)) "fcmp" else "icmp";
        try self.out.print(self.allocator, "  {s} = {s} {s} {s} {s}, {s}\n", .{ result, cmp_op, pred, llvm_ty, left, right });
        return result;
    }

    fn nullLiteralExpr(expr: ast.Expr) bool {
        return switch (expr.kind) {
            .null_literal => true,
            .grouped => |inner| nullLiteralExpr(inner.*),
            else => false,
        };
    }

    // If `node` compares a value optional `?T` against `null`, emit the present-tag test:
    // `!= null` -> present; `== null` -> `xor present, true`. Returns null when N/A.
    fn valueOptionalNullCompare(self: *LlvmEmitter, node: anytype) !?[]const u8 {
        const left_null = nullLiteralExpr(node.left.*);
        const right_null = nullLiteralExpr(node.right.*);
        if (left_null == right_null) return null; // exactly one null side
        const subject = if (left_null) node.right.* else node.left.*;
        const subject_ty = self.exprType(subject) orelse return null;
        if (!self.targetIsValueOptional(subject_ty)) return null;
        const value = try self.emitExpr(subject, subject_ty);
        const present = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ present, try self.llvmType(subject_ty), value });
        if (node.op == .ne) return present;
        const absent = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ absent, present });
        return absent;
    }

    fn emitCheckedArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const signed = self.isSignedIntegerType(ty);
        const intrinsic = try self.overflowIntrinsic(node.op, signed, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, try self.debugCallSuffix() });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
        return value;
    }

    fn emitSaturatingArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        if (self.isSignedIntegerType(ty)) return error.UnsupportedLlvmEmission;
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const intrinsic = try self.overflowIntrinsic(node.op, false, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, try self.debugCallSuffix() });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const range = self.intRangeOf(ty) orelse return error.UnsupportedLlvmEmission;
        const saturated = if (node.op == .sub) range.min else range.max;
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ result, overflow, llvm_ty, saturated, llvm_ty, value });
        return result;
    }

    fn emitCheckedDivRem(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        if (self.integerBitsOf(ty) == null) return error.UnsupportedLlvmEmission;
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        // OPT (annex E): when the optimizer proved this div/mod's check dead (a non-zero
        // literal divisor, and for a signed dividend a divisor that is also not -1), skip
        // BOTH the zero-check branch and the signed INT_MIN/-1 overflow branch below — the
        // same elision source point covers both, since the proof requires the divisor be
        // neither 0 nor -1.
        const div_elided = self.mirCheckElided((node.right.*).span);
        if (!div_elided) {
            const zero_cmp = try self.nextTemp();
            const zero_trap = try self.nextLabel("trap_div_zero");
            const nonzero = try self.nextLabel("div_nonzero");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, 0\n", .{ zero_cmp, llvm_ty, right });
            try self.emitTrapBranch(zero_cmp, zero_trap, nonzero, zero_trap, nonzero, "DivideByZero");
        }

        if (self.isSignedIntegerType(ty) and !div_elided) {
            const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
            const min_cmp = try self.nextTemp();
            const neg_one_cmp = try self.nextTemp();
            const overflow_cmp = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_div_overflow");
            const safe = try self.nextLabel("div_safe");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ min_cmp, llvm_ty, left, min_literal });
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, -1\n", .{ neg_one_cmp, llvm_ty, right });
            try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ overflow_cmp, min_cmp, neg_one_cmp });
            try self.emitTrapBranch(overflow_cmp, overflow_trap, safe, overflow_trap, safe, "IntegerOverflow");
        }

        const op: []const u8 = switch (node.op) {
            .div => if (self.isSignedIntegerType(ty)) "sdiv" else "udiv",
            .mod => if (self.isSignedIntegerType(ty)) "srem" else "urem",
            else => unreachable,
        };
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitWrapShift(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const shifted_bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const amount_ty = self.exprType(node.right.*) orelse ty;
        const amount_llvm = try self.llvmType(amount_ty);
        const left = try self.emitExpr(node.left.*, ty);
        const raw_amount = try self.emitExpr(node.right.*, amount_ty);

        try self.emitShiftCountCheck(raw_amount, amount_ty, amount_llvm, shifted_bits);
        const amount = try self.castIntegerValue(raw_amount, amount_ty, ty);

        const op: []const u8 = switch (node.op) {
            .shl => "shl",
            .shr => if (self.isSignedIntegerType(ty)) "ashr" else "lshr",
            else => unreachable,
        };
        return try self.emitPlainBinaryValues(op, llvm_ty, left, amount);
    }

    fn emitCheckedShift(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const shifted_bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const amount_ty = self.exprType(node.right.*) orelse ty;
        const amount_llvm = try self.llvmType(amount_ty);
        const left = try self.emitExpr(node.left.*, ty);
        const raw_amount = try self.emitExpr(node.right.*, amount_ty);

        try self.emitShiftCountCheck(raw_amount, amount_ty, amount_llvm, shifted_bits);
        const amount = try self.castIntegerValue(raw_amount, amount_ty, ty);

        const op: []const u8 = switch (node.op) {
            .shl => "shl",
            .shr => if (self.isSignedIntegerType(ty)) "ashr" else "lshr",
            else => unreachable,
        };
        const result = try self.emitPlainBinaryValues(op, llvm_ty, left, amount);
        if (node.op == .shl) {
            try self.emitLeftShiftOverflowCheck(result, left, amount, ty, llvm_ty);
        }
        return result;
    }

    fn emitShiftCountCheck(self: *LlvmEmitter, amount: []const u8, amount_ty: ast.TypeExpr, amount_llvm: []const u8, shifted_bits: u16) !void {
        if (self.integerBitsOf(amount_ty) == null) return error.UnsupportedLlvmEmission;
        if (self.isSignedIntegerType(amount_ty)) {
            const negative = try self.nextTemp();
            const neg_trap = try self.nextLabel("trap_shift_neg");
            const nonnegative = try self.nextLabel("shift_nonnegative");
            try self.out.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ negative, amount_llvm, amount });
            try self.emitTrapBranch(negative, neg_trap, nonnegative, neg_trap, nonnegative, "InvalidShift");
        }

        const too_large = try self.nextTemp();
        const invalid = try self.nextLabel("trap_shift_count");
        const valid = try self.nextLabel("shift_count_ok");
        const pred: []const u8 = if (self.isSignedIntegerType(amount_ty)) "sge" else "uge";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ too_large, pred, amount_llvm, amount, shifted_bits });
        try self.emitTrapBranch(too_large, invalid, valid, invalid, valid, "InvalidShift");
    }

    fn emitLeftShiftOverflowCheck(self: *LlvmEmitter, result: []const u8, left: []const u8, amount: []const u8, ty: ast.TypeExpr, llvm_ty: []const u8) !void {
        const reverse_op: []const u8 = if (self.isSignedIntegerType(ty)) "ashr" else "lshr";
        const reversed = try self.emitPlainBinaryValues(reverse_op, llvm_ty, result, amount);
        const overflow = try self.nextTemp();
        const overflow_trap = try self.nextLabel("trap_shift_overflow");
        const ok = try self.nextLabel("shift_overflow_ok");
        try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}\n", .{ overflow, llvm_ty, reversed, left });
        try self.emitTrapBranch(overflow, overflow_trap, ok, overflow_trap, ok, "IntegerOverflow");
    }

    fn emitPlainBinary(self: *LlvmEmitter, op: []const u8, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitBinaryOperand(self: *LlvmEmitter, expr: ast.Expr, target_ty: ast.TypeExpr) anyerror![]const u8 {
        const source_ty = self.exprType(expr) orelse return self.emitExprWithMirRangeTarget(expr, target_ty, "binary_operand");
        const value = try self.emitExprWithMirRangeTarget(expr, source_ty, "binary_operand");
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitPlainBinaryValues(self: *LlvmEmitter, op: []const u8, llvm_ty: []const u8, left: []const u8, right: []const u8) ![]const u8 {
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, op, llvm_ty, left, right });
        return result;
    }

    fn emitResultConstructorValue(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr, tag: []const u8) ![]const u8 {
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const info = self.resultInfo(expected_ty) orelse return error.UnsupportedLlvmEmission;
        const result_ty = try self.llvmType(expected_ty);
        const ok_ty = try self.resultPayloadLlvmType(info.ok_ty);
        const err_ty = try self.resultPayloadLlvmType(info.err_ty);
        const is_ok = std.mem.eql(u8, tag, "ok");
        const tag_value = if (is_ok) "true" else "false";

        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, tag_value });

        const ok_value = if (is_ok)
            try self.emitResultPayloadExpr(call.args[0], info.ok_ty)
        else
            try self.resultPayloadZero(info.ok_ty);
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_ty, tagged, ok_ty, ok_value });

        const err_value = if (is_ok)
            try self.resultPayloadZero(info.err_ty)
        else
            try self.emitResultPayloadExpr(call.args[0], info.err_ty);
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_ty, with_ok, err_ty, err_value });
        return with_err;
    }

    fn emitResultValue(self: *LlvmEmitter, result_ty: ast.TypeExpr, is_ok: []const u8, ok_value: []const u8, err_value: []const u8) ![]const u8 {
        const info = self.resultInfo(result_ty) orelse return error.UnsupportedLlvmEmission;
        const result_llvm = try self.llvmType(result_ty);
        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_llvm, is_ok });
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_llvm, tagged, try self.resultPayloadLlvmType(info.ok_ty), ok_value });
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_llvm, with_ok, try self.resultPayloadLlvmType(info.err_ty), err_value });
        return with_err;
    }

    fn emitTaggedUnionConstructor(self: *LlvmEmitter, call: anytype, target_ty: ast.TypeExpr) !?[]const u8 {
        const tag = taggedUnionConstructorName(call.callee.*) orelse return null;
        const union_decl = self.taggedUnionForType(target_ty) orelse return null;
        const case_index = self.taggedUnionCaseIndex(union_decl, tag) orelse return null;
        const case = union_decl.cases[case_index];
        const union_llvm = try self.llvmType(target_ty);
        const ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        try self.emitAlloca(ptr, union_llvm);
        try self.out.print(self.allocator, "  store {s} zeroinitializer, ptr {s}{s}\n", .{ union_llvm, ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, ptr });
        try self.out.print(self.allocator, "  store i32 {d}, ptr {s}{s}\n", .{ case_index, tag_ptr, try self.debugCallSuffix() });
        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload = try self.emitExpr(call.args[0], payload_ty);
            const payload_ptr = try self.taggedUnionPayloadPtr(ptr, target_ty, payload_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(payload_ty), payload, payload_ptr, try self.debugCallSuffix() });
        } else if (call.args.len != 0) {
            return error.UnsupportedLlvmEmission;
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, union_llvm, ptr, try self.debugCallSuffix() });
        return result;
    }

    // `Union.variant(...)` — qualified, self-typed tagged-union constructor. The union is
    // the callee owner (not a target type). Returns null when the owner is not a known
    // tagged union (an inherent/associated call, or an intrinsic).
    fn emitQualifiedUnionConstructor(self: *LlvmEmitter, call: anytype) !?[]const u8 {
        const q = ast_query.qualifiedMemberCallee(call.callee.*) orelse return null;
        const union_decl = self.tagged_unions.get(q.owner) orelse return null;
        const case_index = self.taggedUnionCaseIndex(union_decl, q.member.text) orelse return null;
        const case = union_decl.cases[case_index];
        const union_ty = ast.TypeExpr{ .span = call.callee.*.span, .kind = .{ .name = .{ .text = q.owner, .span = call.callee.*.span } } };
        const union_llvm = try self.llvmType(union_ty);
        const ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        try self.emitAlloca(ptr, union_llvm);
        try self.out.print(self.allocator, "  store {s} zeroinitializer, ptr {s}{s}\n", .{ union_llvm, ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, ptr });
        try self.out.print(self.allocator, "  store i32 {d}, ptr {s}{s}\n", .{ case_index, tag_ptr, try self.debugCallSuffix() });
        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload = try self.emitExpr(call.args[0], payload_ty);
            const payload_ptr = try self.taggedUnionPayloadPtr(ptr, union_ty, payload_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(payload_ty), payload, payload_ptr, try self.debugCallSuffix() });
        } else if (call.args.len != 0) {
            return error.UnsupportedLlvmEmission;
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, union_llvm, ptr, try self.debugCallSuffix() });
        return result;
    }

    fn taggedUnionPayloadPtr(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast.TypeExpr, payload_ty: ast.TypeExpr) ![]const u8 {
        const union_decl = self.taggedUnionForType(union_ty) orelse return error.UnsupportedLlvmEmission;
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const union_llvm = try self.llvmType(union_ty);
        const payload_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ payload_ptr, union_llvm, union_ptr, layout.payload_field_index });
        _ = try self.llvmType(payload_ty);
        return payload_ptr;
    }

    fn taggedUnionLoadPayload(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast.TypeExpr, payload_ty: ast.TypeExpr) ![]const u8 {
        const payload_ptr = try self.taggedUnionPayloadPtr(union_ptr, union_ty, payload_ty);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ payload, try self.llvmType(payload_ty), payload_ptr });
        return payload;
    }

    fn emitResultPayloadExpr(self: *LlvmEmitter, expr: ast.Expr, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.emitExpr(expr, ty);
    }

    fn resultPayloadZero(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.zeroInitializer(ty);
    }

    fn resultType(self: *LlvmEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 2);
        args[0] = ok_ty;
        args[1] = err_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "Result", .span = span }, .args = args } } };
    }

    fn emitDomainOpCall(self: *LlvmEmitter, call: anytype, info: DomainOpCallInfo) ![]const u8 {
        if (call.type_args.len != 0) return error.UnsupportedLlvmEmission;
        const expected_args: usize = if (std.mem.eql(u8, info.op, "elapsed_assume_within") or std.mem.eql(u8, info.op, "elapsed_bounded")) 3 else 2;
        if (call.args.len != expected_args) return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(info.payload_ty);
        const left = try self.emitExpr(call.args[0], info.domain_ty);
        const right = try self.emitExpr(call.args[1], info.domain_ty);
        const diff = try self.emitPlainBinaryValues("sub", llvm_ty, left, right);
        if (std.mem.eql(u8, info.op, "before") or std.mem.eql(u8, info.op, "after")) {
            const pred: []const u8 = if (std.mem.eql(u8, info.op, "before")) "slt" else "sgt";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, 0\n", .{ result, pred, llvm_ty, diff });
            return result;
        }
        if (std.mem.eql(u8, info.op, "compare")) {
            const min = try self.signedWindowMinLiteral(info.payload_ty);
            const ambiguous = try self.nextTemp();
            const not_ambiguous = try self.nextTemp();
            const is_lt = try self.nextTemp();
            const is_gt = try self.nextTemp();
            const nonnegative_order = try self.nextTemp();
            const order = try self.nextTemp();
            const selected_order = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ ambiguous, llvm_ty, diff, min });
            try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ not_ambiguous, ambiguous });
            try self.out.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ is_lt, llvm_ty, diff });
            try self.out.print(self.allocator, "  {s} = icmp sgt {s} {s}, 0\n", .{ is_gt, llvm_ty, diff });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 1, i8 0\n", .{ nonnegative_order, is_gt });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 -1, i8 {s}\n", .{ order, is_lt, nonnegative_order });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 0, i8 {s}\n", .{ selected_order, ambiguous, order });
            return try self.emitResultValue(info.return_ty, not_ambiguous, selected_order, "0");
        }
        if (std.mem.eql(u8, info.op, "elapsed_bounded")) {
            const max = try self.emitExpr(call.args[2], try self.durationType(info.payload_ty, call.args[2].span));
            const in_range = try self.nextTemp();
            const selected_delta = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp ule {s} {s}, {s}\n", .{ in_range, llvm_ty, diff, max });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} 0\n", .{ selected_delta, in_range, llvm_ty, diff, llvm_ty });
            return try self.emitResultValue(info.return_ty, in_range, selected_delta, "0");
        }
        return diff;
    }

    fn durationType(self: *LlvmEmitter, payload_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 1);
        args[0] = payload_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = span }, .args = args } } };
    }

    fn emitReduceCall(self: *LlvmEmitter, call: anytype, info: ReduceCallInfo) ![]const u8 {
        if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const slice_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
        const slice = switch (self.resolveAliasType(slice_ty).kind) {
            .slice => |node| node,
            else => return error.UnsupportedLlvmEmission,
        };
        if (!std.mem.eql(u8, try self.llvmType(slice.child.*), try self.llvmType(info.element_ty))) return error.UnsupportedLlvmEmission;

        if (std.mem.eql(u8, info.op, "sum_checked")) return try self.emitReduceSumChecked(call.args[0], slice_ty, info.element_ty, info.return_ty);
        if (std.mem.eql(u8, info.op, "sum_left")) return try self.emitReduceFloat(call.args[0], slice_ty, info.element_ty, false);
        if (std.mem.eql(u8, info.op, "sum_fast")) return try self.emitReduceFloat(call.args[0], slice_ty, info.element_ty, true);
        return error.UnsupportedLlvmEmission;
    }

    fn emitReduceSumChecked(self: *LlvmEmitter, arg: ast.Expr, slice_ty: ast.TypeExpr, element_ty: ast.TypeExpr, return_ty: ast.TypeExpr) ![]const u8 {
        const range = self.intRangeOf(element_ty) orelse return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);
        const element_bits = self.integerBitsOf(element_ty) orelse return error.UnsupportedLlvmEmission;
        const result_llvm = try self.resultPayloadLlvmType(element_ty);

        const slice_value = try self.emitExpr(arg, slice_ty);
        const data = try self.nextTemp();
        const len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(slice_ty), slice_value });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(slice_ty), slice_value });

        const index_ptr = try self.nextTemp();
        const acc_ptr = try self.nextTemp();
        try self.emitAlloca(index_ptr, "i64");
        try self.emitAlloca(acc_ptr, "i128");
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store i128 0, ptr {s}\n", .{acc_ptr});

        const cond_label = try self.nextLabel("reduce_cond");
        const body_label = try self.nextLabel("reduce_body");
        const done_label = try self.nextLabel("reduce_done");
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, done_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.nextTemp();
        const element = try self.nextTemp();
        const widened = try self.nextTemp();
        const acc = try self.nextTemp();
        const next_acc = try self.nextTemp();
        const next_index = try self.nextTemp();
        const extend_op: []const u8 = if (self.isSignedIntegerType(element_ty)) "sext" else "zext";
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ element_ptr, element_llvm, data, index });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element, element_llvm, element_ptr });
        if (element_bits == 128) {
            try self.out.print(self.allocator, "  {s} = add i128 {s}, 0\n", .{ widened, element });
        } else {
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to i128\n", .{ widened, extend_op, element_llvm, element });
        }
        try self.out.print(self.allocator, "  {s} = load i128, ptr {s}\n", .{ acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i128 {s}, {s}\n", .{ next_acc, acc, widened });
        try self.out.print(self.allocator, "  store i128 {s}, ptr {s}\n", .{ next_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), done_label });

        const final_acc = try self.nextTemp();
        const below = try self.nextTemp();
        const above = try self.nextTemp();
        const overflow = try self.nextTemp();
        const ok = try self.nextTemp();
        const narrowed = try self.nextTemp();
        const selected_payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i128, ptr {s}\n", .{ final_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = icmp slt i128 {s}, {d}\n", .{ below, final_acc, range.min });
        try self.out.print(self.allocator, "  {s} = icmp sgt i128 {s}, {d}\n", .{ above, final_acc, range.max });
        try self.out.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ overflow, below, above });
        try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ ok, overflow });
        if (element_bits == 128) {
            try self.out.print(self.allocator, "  {s} = add i128 {s}, 0\n", .{ narrowed, final_acc });
        } else {
            try self.out.print(self.allocator, "  {s} = trunc i128 {s} to {s}\n", .{ narrowed, final_acc, result_llvm });
        }
        try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} 0, {s} {s}\n", .{ selected_payload, overflow, result_llvm, result_llvm, narrowed });
        return try self.emitResultValue(return_ty, ok, selected_payload, "0");
    }

    fn emitReduceFloat(self: *LlvmEmitter, arg: ast.Expr, slice_ty: ast.TypeExpr, element_ty: ast.TypeExpr, fast: bool) ![]const u8 {
        if (!self.isFloatTypeOf(element_ty)) return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);
        const slice_value = try self.emitExpr(arg, slice_ty);
        const data = try self.nextTemp();
        const len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(slice_ty), slice_value });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(slice_ty), slice_value });

        const index_ptr = try self.nextTemp();
        const acc_ptr = try self.nextTemp();
        try self.emitAlloca(index_ptr, "i64");
        try self.emitAlloca(acc_ptr, element_llvm);
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store {s} 0.000000e+00, ptr {s}\n", .{ element_llvm, acc_ptr });

        const cond_label = try self.nextLabel("reduce_cond");
        const body_label = try self.nextLabel("reduce_body");
        const done_label = try self.nextLabel("reduce_done");
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, done_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.nextTemp();
        const element = try self.nextTemp();
        const acc = try self.nextTemp();
        const next_acc = try self.nextTemp();
        const next_index = try self.nextTemp();
        const add_op: []const u8 = if (fast) "fadd reassoc" else "fadd";
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ element_ptr, element_llvm, data, index });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element, element_llvm, element_ptr });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ acc, element_llvm, acc_ptr });
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ next_acc, add_op, element_llvm, acc, element });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ element_llvm, next_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), done_label });

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, element_llvm, acc_ptr });
        return result;
    }

    fn overflowIntrinsic(self: *LlvmEmitter, op: ast.BinaryOp, signed: bool, bits: u16) ![]const u8 {
        const prefix = if (signed) "s" else "u";
        const name = switch (op) {
            .add => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}add.with.overflow.i{d}", .{ prefix, bits }),
            .sub => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}sub.with.overflow.i{d}", .{ prefix, bits }),
            .mul => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}mul.with.overflow.i{d}", .{ prefix, bits }),
            else => unreachable,
        };
        const set = switch (op) {
            .add => if (signed) &self.need_sadd else &self.need_uadd,
            .sub => if (signed) &self.need_ssub else &self.need_usub,
            .mul => if (signed) &self.need_smul else &self.need_umul,
            else => unreachable,
        };
        try set.put(name, {});
        return name;
    }

    fn emitIntrinsicDecls(self: *LlvmEmitter) !void {
        try self.emitIntrinsicSet(self.need_uadd);
        try self.emitIntrinsicSet(self.need_usub);
        try self.emitIntrinsicSet(self.need_umul);
        try self.emitIntrinsicSet(self.need_sadd);
        try self.emitIntrinsicSet(self.need_ssub);
        try self.emitIntrinsicSet(self.need_smul);
        if (self.need_dbg_declare) try self.out.appendSlice(self.allocator, "declare void @llvm.dbg.declare(metadata, metadata, metadata)\n");
        if (self.need_dbg_value) try self.out.appendSlice(self.allocator, "declare void @llvm.dbg.value(metadata, metadata, metadata)\n");
    }

    fn emitIntrinsicSet(self: *LlvmEmitter, set: std.StringHashMap(void)) !void {
        var it = set.keyIterator();
        while (it.next()) |name| {
            const bits = intrinsicBits(name.*) orelse continue;
            try self.out.print(self.allocator, "declare {{ i{d}, i1 }} @{s}(i{d}, i{d})\n", .{ bits, name.*, bits, bits });
        }
    }

    fn emitStringLiteral(self: *LlvmEmitter, literal: []const u8, span: ast.Span) ![]const u8 {
        const fact = self.mirTargetTypeFactAt(.string_literal, span) orelse return error.UnsupportedLlvmEmission;
        const target_ty = fact.target_ty;
        const resolved = self.resolveAliasType(target_ty);
        // A `[]const u8` / `[]u8` slice target: build the fat-pointer slice value
        // `{ ptr = &.str, len = <byte count> }`. The pointer is the static string-literal
        // global (program-lifetime, always valid); the length excludes the trailing NUL that
        // `internStringLiteral` appends.
        if (ast_query.u8SliceMutability(resolved)) |mutability| {
            const global = try self.internStringLiteral(literal);
            const child = resolved.kind.slice.child.*;
            const slice_ty = try self.sliceTypeFor(child, mutability, target_ty.span);
            const slice_llvm = try self.llvmType(slice_ty);
            const ptr = try self.nextTemp();
            const with_ptr = try self.nextTemp();
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{ ptr, global.len, global.name });
            try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, slice_llvm, ptr });
            try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {d}, 1\n", .{ result, slice_llvm, with_ptr, global.len - 1 });
            return result;
        }
        if (!isStringLiteralTarget(resolved)) return error.UnsupportedLlvmEmission;

        const global = try self.internStringLiteral(literal);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{ result, global.len, global.name });
        return result;
    }

    fn internStringLiteral(self: *LlvmEmitter, literal: []const u8) !StringLiteralGlobal {
        const bytes = try llvmStringLiteralBytes(self.scratch.allocator(), literal);
        const name = try std.fmt.allocPrint(self.scratch.allocator(), ".str.{d}", .{self.string_literals.items.len});
        const global: StringLiteralGlobal = .{
            .name = name,
            .escaped_bytes = bytes.escaped,
            .len = bytes.len,
        };
        try self.string_literals.append(self.allocator, global);
        return global;
    }

    fn emitStringLiteralGlobals(self: *LlvmEmitter) !void {
        if (self.string_literals.items.len == 0) return;
        for (self.string_literals.items) |global| {
            try self.out.print(self.allocator, "@{s} = private unnamed_addr constant [{d} x i8] c\"{s}\", align 1\n", .{ global.name, global.len, global.escaped_bytes });
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn emitDebugMetadata(self: *LlvmEmitter) !void {
        if (self.debug_functions.items.len == 0) return;
        const escaped_path = try escapedLlvmString(self.scratch.allocator(), self.source_path);
        try self.out.appendSlice(self.allocator, "\n!llvm.dbg.cu = !{!0}\n");
        try self.out.appendSlice(self.allocator, "!llvm.module.flags = !{!2, !3}\n");
        try self.out.print(self.allocator, "!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: \"mcc emit-llvm\", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)\n", .{});
        try self.out.print(self.allocator, "!1 = !DIFile(filename: \"{s}\", directory: \".\")\n", .{escaped_path});
        try self.out.appendSlice(self.allocator, "!2 = !{i32 2, !\"Debug Info Version\", i32 3}\n");
        try self.out.appendSlice(self.allocator, "!3 = !{i32 1, !\"wchar_size\", i32 4}\n");
        try self.out.appendSlice(self.allocator, "!4 = !DISubroutineType(types: !5)\n");
        try self.out.appendSlice(self.allocator, "!5 = !{null}\n");
        var debug_type_ids = std.StringHashMap(usize).init(self.allocator);
        defer debug_type_ids.deinit();
        var debug_types: std.ArrayList(DebugBasicType) = .empty;
        defer debug_types.deinit(self.allocator);
        for (self.debug_locals.items) |local| {
            const ty = self.debugBasicType(local.ty) orelse continue;
            if (!debug_type_ids.contains(ty.name)) {
                const id = self.debug_next_id;
                self.debug_next_id += 1;
                try debug_type_ids.put(ty.name, id);
                try debug_types.append(self.allocator, ty);
            }
        }
        for (debug_types.items) |ty| {
            const id = debug_type_ids.get(ty.name) orelse continue;
            try self.out.print(
                self.allocator,
                "!{d} = !DIBasicType(name: \"{s}\", size: {d}, encoding: {s})\n",
                .{ id, ty.name, ty.size_bits, ty.encoding },
            );
        }
        for (self.debug_functions.items) |function| {
            const name = try escapedLlvmString(self.scratch.allocator(), function.name);
            try self.out.print(
                self.allocator,
                "!{d} = distinct !DISubprogram(name: \"{s}\", linkageName: \"{s}\", scope: !1, file: !1, line: {d}, type: !4, scopeLine: {d}, spFlags: DISPFlagDefinition, unit: !0)\n",
                .{ function.id, name, name, function.line, function.line },
            );
        }
        for (self.debug_locals.items) |local| {
            const ty = self.debugBasicType(local.ty) orelse continue;
            const type_id = debug_type_ids.get(ty.name) orelse continue;
            const name = try escapedLlvmString(self.scratch.allocator(), local.name);
            switch (local.kind) {
                .parameter => try self.out.print(
                    self.allocator,
                    "!{d} = !DILocalVariable(name: \"{s}\", arg: {d}, scope: !{d}, file: !1, line: {d}, type: !{d})\n",
                    .{ local.id, name, local.arg_index orelse 0, local.scope, local.line, type_id },
                ),
                .variable => try self.out.print(
                    self.allocator,
                    "!{d} = !DILocalVariable(name: \"{s}\", scope: !{d}, file: !1, line: {d}, type: !{d})\n",
                    .{ local.id, name, local.scope, local.line, type_id },
                ),
            }
        }
        for (self.debug_locations.items) |location| {
            try self.out.print(
                self.allocator,
                "!{d} = !DILocation(line: {d}, column: {d}, scope: !{d})\n",
                .{ location.id, location.line, location.column, location.scope },
            );
        }
    }

    fn debugLocation(self: *LlvmEmitter, span: ast.Span) !?usize {
        const scope = self.current_debug_scope orelse return null;
        const id = self.debug_next_id;
        self.debug_next_id += 1;
        try self.debug_locations.append(self.allocator, .{
            .id = id,
            .scope = scope,
            .line = debugLine(span),
            .column = debugColumn(span),
        });
        return id;
    }

    fn debugCallSuffix(self: *LlvmEmitter) ![]const u8 {
        const span = self.current_debug_span orelse return "";
        const location = (try self.debugLocation(span)) orelse return "";
        return try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{location});
    }

    fn emitDebugDeclare(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, ptr: []const u8, span: ast.Span, arg_index: ?usize) !void {
        if (self.current_debug_scope == null or self.debugBasicType(ty) == null) return;
        const local_id = try self.reserveDebugLocal(name, ty, span, if (arg_index == null) .variable else .parameter, arg_index);
        const location = (try self.debugLocation(span)) orelse return;
        self.need_dbg_declare = true;
        try self.out.print(
            self.allocator,
            "  call void @llvm.dbg.declare(metadata ptr {s}, metadata !{d}, metadata !DIExpression()), !dbg !{d}\n",
            .{ ptr, local_id, location },
        );
    }

    fn emitDebugValue(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, value: []const u8, span: ast.Span, arg_index: usize) !void {
        if (self.current_debug_scope == null or self.debugBasicType(ty) == null) return;
        const local_id = try self.reserveDebugLocal(name, ty, span, .parameter, arg_index);
        const location = (try self.debugLocation(span)) orelse return;
        self.need_dbg_value = true;
        try self.out.print(
            self.allocator,
            "  call void @llvm.dbg.value(metadata {s} {s}, metadata !{d}, metadata !DIExpression()), !dbg !{d}\n",
            .{ try self.llvmType(ty), value, local_id, location },
        );
    }

    fn reserveDebugLocal(self: *LlvmEmitter, name: []const u8, ty: ast.TypeExpr, span: ast.Span, kind: DebugLocalKind, arg_index: ?usize) !usize {
        const scope = self.current_debug_scope orelse return error.UnsupportedLlvmEmission;
        const id = self.debug_next_id;
        self.debug_next_id += 1;
        try self.debug_locals.append(self.allocator, .{
            .id = id,
            .name = name,
            .scope = scope,
            .line = debugLine(span),
            .ty = ty,
            .kind = kind,
            .arg_index = arg_index,
        });
        return id;
    }

    fn debugBasicType(self: *LlvmEmitter, ty: ast.TypeExpr) ?DebugBasicType {
        const resolved = self.resolveAliasType(ty);
        if (typeNameEql(resolved, "bool")) return .{ .name = "bool", .size_bits = 1, .encoding = "DW_ATE_boolean" };
        if (typeNameEql(resolved, "f32")) return .{ .name = "f32", .size_bits = 32, .encoding = "DW_ATE_float" };
        if (typeNameEql(resolved, "f64")) return .{ .name = "f64", .size_bits = 64, .encoding = "DW_ATE_float" };
        const bits = integerBits(resolved) orelse return null;
        return switch (resolved.kind) {
            .name => |name| .{
                .name = name.text,
                .size_bits = bits,
                .encoding = if (isSignedInteger(resolved)) "DW_ATE_signed" else "DW_ATE_unsigned",
            },
            else => null,
        };
    }

    fn llvmType(self: *LlvmEmitter, ty: ast.TypeExpr) anyerror![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "void"))
                "void"
            else if (std.mem.eql(u8, name.text, "never"))
                "void"
            else if (isOpaqueAddressTypeName(name.text))
                "i64"
            else if (std.mem.eql(u8, name.text, "c_void"))
                "i8"
            else if (std.mem.eql(u8, name.text, "cstr"))
                "ptr"
            else if (std.mem.eql(u8, name.text, "IrqOff"))
                "i8"
                // C-ABI varargs cursor. On the RISC-V lp64 ABI `va_list` is a single pointer
                // (i8*), so the cursor storage is one `ptr`-sized slot. va.start/arg/end operate
                // on a pointer TO this slot (the generic VAARG legalizer handles the ABI).
            else if (std.mem.eql(u8, name.text, "va_list"))
                "ptr"
            else if (std.mem.eql(u8, name.text, "bool"))
                "i1"
            else if (std.mem.eql(u8, name.text, "f32"))
                "float"
            else if (std.mem.eql(u8, name.text, "f64"))
                "double"
            else if (self.integerBitsOf(resolved_ty)) |bits|
                try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{bits})
            else if (self.enum_types.get(name.text)) |enum_decl|
                try self.llvmType(enumReprType(enum_decl))
            else if (self.packed_bits.get(name.text)) |info|
                try self.llvmType(info.repr)
            else if (self.overlay_unions.get(name.text)) |info|
                try self.overlayLlvmType(info)
            else if (self.tagged_unions.get(name.text)) |union_decl|
                try self.taggedUnionLlvmType(union_decl)
            else if (self.struct_types.get(name.text)) |struct_decl|
                try self.structLlvmType(struct_decl)
            else if (libraryScalarLlvmType(name.text)) |library_ty|
                library_ty
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer => "ptr",
            // A pointer nullable lowers to its inner type's representation — the niche is
            // in-band: `?*T` -> `ptr` (null address), `?*dyn Trait` -> `{ ptr, ptr }` (null
            // data word). A VALUE optional `?T` has no spare sentinel, so it lowers to a
            // tagged aggregate `{ i1, <T> }` (present tag + payload).
            .nullable => |child| if (self.nullablePayloadIsValueType(child.*))
                try std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s} }}", .{try self.llvmType(child.*)})
            else
                try self.llvmType(child.*),
            .array => |node| try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x {s}]", .{ self.arrayLenValue(node.len) orelse return error.UnsupportedLlvmEmission, try self.llvmType(node.child.*) }),
            .slice => "{ ptr, i64 }",
            .fn_pointer => "ptr",
            .closure_type => "{ ptr, ptr }",
            // `*dyn Trait` is the same two-word fat pointer shape as a closure:
            // { data, vtable }. The vtable is a rodata struct of function pointers.
            .dyn_trait => "{ ptr, ptr }",
            .generic => |node| if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2)
                try self.resultLlvmType(node.args[0], node.args[1])
            else if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1)
                try self.atomicStorageLlvmType(node.args[0])
            else if (std.mem.eql(u8, node.base.text, "MaybeUninit") and node.args.len == 1)
                try self.llvmType(node.args[0])
            else if ((std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits")) and node.args.len >= 1)
                try self.llvmType(node.args[0])
            else if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1)
                "ptr"
            else if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2)
                "i64"
            else if (isPayloadDomainGenericName(node.base.text) and node.args.len == 1)
                try self.llvmType(node.args[0])
            else if (isOpaqueAddressGenericName(node.base.text) and node.args.len == 1)
                "i64"
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn resultLlvmType(self: *LlvmEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s}, {s} }}", .{ try self.resultPayloadLlvmType(ok_ty), try self.resultPayloadLlvmType(err_ty) });
    }

    fn resultPayloadLlvmType(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "i8";
        return try self.llvmType(ty);
    }

    fn nextTemp(self: *LlvmEmitter) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%t{d}", .{index});
    }

    fn nextBindingPtr(self: *LlvmEmitter, name: []const u8) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr.{d}", .{ name, index });
    }

    fn nextLabel(self: *LlvmEmitter, prefix: []const u8) ![]const u8 {
        const index = self.trap_index;
        self.trap_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "bb_{s}{d}", .{ prefix, index });
    }

    fn exprType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.local_types.get(ident.text) orelse self.global_types.get(ident.text) orelse self.fnPointerTypeForName(ident.text),
            .bool_literal => simpleType(expr.span, "bool"),
            .unary => |node| if (node.op == .logical_not) simpleType(expr.span, "bool") else self.exprType(node.expr.*),
            .int_literal => null,
            .float_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .call => |call| if (qualifiedTaggedUnionConstructorType(&self.tagged_unions, call)) |ty|
                ty
            else if (isAssumeNoaliasCall(call))
                if (self.mirCallTargetKindAt(call.callee.*.span) == .assume_noalias) self.exprType(call.args[0]) else null
            else if (isDeclassifyCall(call))
                // declassify/reveal yields the Secret<T> argument's inner T.
                if (self.mirCallTargetKindAt(call.callee.*.span) == .declassify and call.args.len == 1) (if (self.exprType(call.args[0])) |ty| secretInnerType(self.resolveAliasType(ty)) orelse ty else null) else null
            else
                self.callReturnType(call),
            .cast => if (self.mirTargetTypeFactAt(.explicit_cast_target, expr.span)) |fact| fact.target_ty else null,
            // `&f` where f is a function is already a code pointer (the fn_pointer type);
            // do NOT wrap it in another pointer. `&x` for a value x is `*x`'s type.
            .address_of => |inner| if (self.exprType(inner.*)) |ty|
                (if (self.resolveAliasType(ty).kind == .fn_pointer) ty else self.pointerTypeFor(ty) catch null)
            else
                null,
            .deref => |inner| self.derefPointeeType(inner.*),
            .index => |node| self.indexElementType(node.base.*),
            .slice => |node| if (self.exprType(node.base.*)) |base_ty| self.sliceTypeForBase(base_ty, node.base.*.span) else null,
            .member => |node| if (enumVariantPathType(&self.enum_types, node, self.memberBaseIsValue(node))) |variant_ty| variant_ty else if (self.exprType(node.base.*)) |base_ty| blk: {
                const resolved_base_ty = self.resolveAliasType(base_ty);
                if (resolved_base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) break :blk simpleType(expr.span, "usize");
                if (self.packedBitsInfoForType(base_ty)) |info| {
                    if (self.packedBitsFieldIndex(info, node.name.text) != null) break :blk simpleType(expr.span, "bool");
                }
                if (self.overlayField(node.base.*, node.name.text)) |field| break :blk field.ty;
                if (self.memberField(node.base.*, node.name.text)) |field| break :blk field.ty;
                break :blk null;
            } else null,
            .binary => |node| if (binaryIsComparison(node.op) or node.op == .logical_and or node.op == .logical_or) simpleType(expr.span, "bool") else self.exprType(node.left.*),
            .try_expr => |node| if (self.exprType(node.operand.*)) |ty|
                if (self.resultInfo(ty)) |info| info.ok_ty else self.nullableInnerType(ty)
            else
                null,
            else => null,
        };
    }

    fn derefPointeeType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        return switch (ty.kind) {
            .pointer => |node| node.child.*,
            .raw_many_pointer => |node| node.child.*,
            else => null,
        };
    }

    fn pointerTypeFor(self: *LlvmEmitter, child: ast.TypeExpr) !ast.TypeExpr {
        const child_ptr = try self.scratch.allocator().create(ast.TypeExpr);
        child_ptr.* = child;
        return .{
            .span = child.span,
            .kind = .{ .pointer = .{ .mutability = .mut, .child = child_ptr } },
        };
    }

    fn nullableInnerType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_llvm_shape.nullableInnerType(&self.type_aliases, ty);
    }

    fn atomicPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_llvm_shape.atomicPayloadType(&self.type_aliases, ty);
    }

    fn maybeUninitPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_llvm_shape.maybeUninitPayloadType(&self.type_aliases, ty);
    }

    fn mmioAccessInfo(self: *LlvmEmitter, call: anytype) ?MmioAccessInfo {
        const member = memberCallee(call) orelse return null;
        const op = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;
        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const base_ty = self.exprType(reg_member.base.*) orelse return null;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return null;
        const struct_decl = self.structDeclForType(struct_ty) orelse return null;
        if (!isMmioStructAbi(struct_decl)) return null;
        const field = self.mmioStructField(struct_decl, reg_member.name.text) orelse return null;
        const field_info = self.mmioFieldInfo(field) orelse return null;
        const offset = self.mmioFieldOffset(struct_decl, reg_member.name.text) orelse return null;
        return .{
            .op = op,
            .base = reg_member.base.*,
            .struct_ty = struct_ty,
            .storage_ty = field_info.storage_ty,
            .value_ty = field_info.value_ty,
            .offset = offset,
        };
    }

    fn emitMmioRegisterAddress(self: *LlvmEmitter, info: MmioAccessInfo) ![]const u8 {
        const base = try self.emitExpr(info.base, try self.mmioPointerType(info.struct_ty, info.base.span));
        if (info.offset == 0) return base;
        const ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {d}\n", .{ ptr, base, info.offset });
        return ptr;
    }

    fn emitMmioFence(self: *LlvmEmitter, ordering: []const u8, placement: MmioFencePlacement) !void {
        const fence: ?[]const u8 = switch (placement) {
            .before_store => if (std.mem.eql(u8, ordering, "release"))
                "release"
            else if (std.mem.eql(u8, ordering, "acq_rel"))
                "release"
            else if (std.mem.eql(u8, ordering, "seq_cst"))
                "seq_cst"
            else
                null,
            .after_load => if (std.mem.eql(u8, ordering, "acquire"))
                "acquire"
            else if (std.mem.eql(u8, ordering, "acq_rel"))
                "acquire"
            else if (std.mem.eql(u8, ordering, "seq_cst"))
                "seq_cst"
            else
                null,
        };
        if (fence) |kind| try self.out.print(self.allocator, "  fence {s}{s}\n", .{ kind, try self.debugCallSuffix() });
    }

    fn mmioPointerType(self: *LlvmEmitter, child_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 1);
        args[0] = child_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "MmioPtr", .span = span }, .args = args } } };
    }

    fn resultInfo(self: *LlvmEmitter, ty: ast.TypeExpr) ?ResultTypeInfo {
        return lower_llvm_shape.resultInfo(&self.type_aliases, ty);
    }

    fn domainPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_llvm_shape.domainPayloadType(&self.type_aliases, ty);
    }

    fn isWrapDomainType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return lower_llvm_shape.isWrapDomainType(&self.type_aliases, ty);
    }

    fn isSatDomainType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return lower_llvm_shape.isSatDomainType(&self.type_aliases, ty);
    }

    fn atomicStorageLlvmType(self: *LlvmEmitter, payload_ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(payload_ty), "bool")) return "i8";
        return self.llvmType(payload_ty);
    }

    fn emitAtomicValueForStorage(self: *LlvmEmitter, expr: ast.Expr, payload_ty: ast.TypeExpr) ![]const u8 {
        const value = try self.emitExpr(expr, payload_ty);
        if (!typeNameEql(self.resolveAliasType(payload_ty), "bool")) return value;
        if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "1")) return value;
        const widened = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ widened, value });
        return widened;
    }

    fn indexElementType(self: *LlvmEmitter, base: ast.Expr) ?ast.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(base) orelse return null);
        return switch (ty.kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn sliceTypeForBase(self: *LlvmEmitter, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .slice => ty,
            .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
            else => null,
        };
    }

    fn sliceTypeFor(self: *LlvmEmitter, child_ty: ast.TypeExpr, mutability: ast.Mutability, span: ast.Span) !ast.TypeExpr {
        const child = try self.scratch.allocator().create(ast.TypeExpr);
        child.* = child_ty;
        return .{ .span = span, .kind = .{ .slice = .{ .mutability = mutability, .child = child } } };
    }

    fn constU8SliceType(self: *LlvmEmitter, span: ast.Span) !ast.TypeExpr {
        const child = try self.scratch.allocator().create(ast.TypeExpr);
        child.* = simpleType(span, "u8");
        return .{ .span = span, .kind = .{ .slice = .{ .mutability = .@"const", .child = child } } };
    }

    fn structDeclForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.StructDecl {
        return lower_llvm_lookup.structDeclForType(&self.type_aliases, &self.struct_types, ty);
    }

    fn packedBitsInfoForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?PackedBitsInfo {
        return lower_llvm_lookup.packedBitsInfoForType(&self.type_aliases, &self.packed_bits, ty);
    }

    fn overlayInfoForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?OverlayUnionInfo {
        return lower_llvm_lookup.overlayInfoForType(&self.type_aliases, &self.overlay_unions, ty);
    }

    fn taggedUnionForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.UnionDecl {
        return lower_llvm_lookup.taggedUnionForType(&self.type_aliases, &self.tagged_unions, ty);
    }

    fn taggedUnionCaseIndex(self: *LlvmEmitter, union_decl: ast.UnionDecl, case_name: []const u8) ?usize {
        _ = self;
        return lower_llvm_lookup.taggedUnionCaseIndex(union_decl, case_name);
    }

    fn taggedUnionLlvmType(self: *LlvmEmitter, union_decl: ast.UnionDecl) ![]const u8 {
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const storage_ty = try self.taggedUnionPayloadStorageType(layout);
        if (layout.padding_size == 0) {
            return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, {s} }}", .{storage_ty});
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, [{d} x i8], {s} }}", .{ layout.padding_size, storage_ty });
    }

    fn taggedUnionLayout(self: *LlvmEmitter, union_decl: ast.UnionDecl, depth: usize) ?TaggedUnionLayout {
        var env = self.reflectEnv();
        return lower_llvm_reflect.taggedUnionLayout(&env, union_decl, depth);
    }

    fn taggedUnionPayloadStorageType(self: *LlvmEmitter, layout: TaggedUnionLayout) ![]const u8 {
        const bits = layout.payload_alignment * 8;
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i{d}]", .{ layout.storage_count, bits });
    }

    fn packedBitsFieldIndex(self: *LlvmEmitter, info: PackedBitsInfo, field_name: []const u8) ?usize {
        _ = self;
        return lower_llvm_lookup.packedBitsFieldIndex(info, field_name);
    }

    fn packedBitsBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| break :blk slot.ptr;
                if (self.global_types.contains(ident.text)) break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                break :blk error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| self.packedBitsBaseAddress(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn enumDeclForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.EnumDecl {
        return lower_llvm_lookup.enumDeclForType(&self.type_aliases, &self.enum_types, ty);
    }

    fn memberBaseIsValue(self: *LlvmEmitter, node: anytype) bool {
        const base_ident = switch (node.base.*.kind) {
            .ident => |id| id,
            else => return false,
        };
        return self.local_types.contains(base_ident.text) or self.global_types.contains(base_ident.text);
    }

    fn memberBaseStructType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_llvm_lookup.memberBaseStructType(&self.type_aliases, ty);
    }

    fn memberBaseStructDecl(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.StructDecl {
        return lower_llvm_lookup.memberBaseStructDecl(&self.type_aliases, &self.struct_types, ty);
    }

    fn enumReprType(enum_decl: ast.EnumDecl) ast.TypeExpr {
        return enum_decl.repr orelse simpleType(enum_decl.name.span, "isize");
    }

    fn enumCaseValueByName(self: *LlvmEmitter, enum_decl: ast.EnumDecl, case_name: []const u8) ![]const u8 {
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, case_name)) return try self.enumCaseValue(enum_decl, case);
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumCaseValue(self: *LlvmEmitter, enum_decl: ast.EnumDecl, case: ast.EnumCase) ![]const u8 {
        if (case.value) |value| return try self.enumLiteralValue(value);
        for (enum_decl.cases, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.name.text, case.name.text)) {
                return try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{i});
            }
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumLiteralValue(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .grouped => |inner| try self.enumLiteralValue(inner.*),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try self.enumLiteralValue(node.expr.*)});
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn packedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ![]const u8 {
        var value: u64 = 0;
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const enabled = switch (field.value.kind) {
                .bool_literal => |enabled| enabled,
                .grouped => |inner| switch ((inner.*).kind) {
                    .bool_literal => |enabled| enabled,
                    else => return error.UnsupportedLlvmEmission,
                },
                else => return error.UnsupportedLlvmEmission,
            };
            if (enabled) value |= packedBitsMask(bit_index);
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn emitPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ![]const u8 {
        if (self.staticPackedBitsLiteralValue(info, fields)) |value| return value;
        const llvm_ty = try self.llvmType(info.repr);
        var current: []const u8 = "0";
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const flag = try self.emitExpr(field.value, simpleType(field.value.span, "bool"));
            const widened = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = zext i1 {s} to {s}\n", .{ widened, flag, llvm_ty });
            const shifted = if (bit_index == 0) widened else blk: {
                const shifted = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = shl {s} {s}, {d}\n", .{ shifted, llvm_ty, widened, bit_index });
                break :blk shifted;
            };
            const next = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = or {s} {s}, {s}\n", .{ next, llvm_ty, current, shifted });
            current = next;
        }
        return current;
    }

    fn staticPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ?[]const u8 {
        return self.packedBitsLiteralValue(info, fields) catch null;
    }

    fn packedBitsComptimeValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const eval.ComptimeStructField) ![]const u8 {
        var value: u64 = 0;
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name) orelse return error.UnsupportedLlvmEmission;
            const enabled = switch (field.value) {
                .boolean => |enabled| enabled,
                else => return error.UnsupportedLlvmEmission,
            };
            if (enabled) value |= packedBitsMask(bit_index);
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn resolveAliasType(self: *LlvmEmitter, ty: ast.TypeExpr) ast.TypeExpr {
        return lower_llvm_alias.resolveAliasType(&self.type_aliases, ty);
    }

    fn structLlvmType(self: *LlvmEmitter, struct_decl: ast.StructDecl) anyerror![]const u8 {
        if (struct_decl.is_c_union) return try self.cUnionLlvmType(struct_decl);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.scratch.allocator(), "{ ");
        for (struct_decl.fields, 0..) |field, i| {
            if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
            const field_ty = if (isMmioStructAbi(struct_decl))
                (self.mmioFieldInfo(field) orelse return error.UnsupportedLlvmEmission).storage_ty
            else
                field.ty;
            try text.appendSlice(self.scratch.allocator(), try self.llvmType(field_ty));
        }
        try text.appendSlice(self.scratch.allocator(), " }");
        return text.toOwnedSlice(self.scratch.allocator());
    }

    fn overlayLlvmType(self: *LlvmEmitter, info: OverlayUnionInfo) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i8]", .{info.size});
    }

    // A `#[c_union]` has no native LLVM union. Represent it as a storage array whose element
    // integer width encodes the max field alignment (`[count x i{align*8}]`) — the same
    // alignment-carrying idiom used for tagged-union payloads — so an alloca/field of this
    // type gets both the largest arm's size AND its alignment. All arms live at offset 0, so
    // member access needs no GEP (see emitMemberAddress); the pointer IS reinterpreted per arm.
    fn cUnionLlvmType(self: *LlvmEmitter, struct_decl: ast.StructDecl) ![]const u8 {
        var max_size: i128 = 0;
        var max_align: i128 = 1;
        for (struct_decl.fields) |field| {
            const size = self.comptimeSizeOf(field.ty, 0) orelse return error.UnsupportedLlvmEmission;
            const alignment = self.comptimeAlignOf(field.ty, 0) orelse return error.UnsupportedLlvmEmission;
            if (alignment <= 0) return error.UnsupportedLlvmEmission;
            if (size > max_size) max_size = size;
            if (alignment > max_align) max_align = alignment;
        }
        if (max_align != 1 and max_align != 2 and max_align != 4 and max_align != 8 and max_align != 16) return error.UnsupportedLlvmEmission;
        const aligned_size = alignForward(max_size, max_align) orelse return error.UnsupportedLlvmEmission;
        const count = @max(@as(i128, 1), @divExact(aligned_size, max_align));
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i{d}]", .{ count, max_align * 8 });
    }

    fn overlayField(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) ?ast.Field {
        const base_ty = self.exprType(base) orelse return null;
        const info = self.overlayInfoForType(base_ty) orelse return null;
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn emitOverlayFieldAddress(self: *LlvmEmitter, base: ast.Expr, field: ast.Field) ![]const u8 {
        _ = field;
        return try self.aggregateBasePointer(base);
    }

    fn memberField(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) ?ast.Field {
        const base_ty = self.exprType(base) orelse return null;
        const struct_decl = self.memberBaseStructDecl(base_ty) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioStructField(self: *LlvmEmitter, struct_decl: ast.StructDecl, field_name: []const u8) ?ast.Field {
        _ = self;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioFieldInfo(self: *LlvmEmitter, field: ast.Field) ?MmioFieldInfo {
        _ = self;
        const generic = switch (field.ty.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (std.mem.eql(u8, generic.base.text, "Reg")) {
            if (generic.args.len != 2) return null;
            return .{ .storage_ty = generic.args[0], .value_ty = generic.args[0] };
        }
        if (std.mem.eql(u8, generic.base.text, "RegBits")) {
            if (generic.args.len != 3) return null;
            return .{ .storage_ty = generic.args[0], .value_ty = generic.args[1] };
        }
        return null;
    }

    fn mmioFieldOffset(self: *LlvmEmitter, struct_decl: ast.StructDecl, field_name: []const u8) ?u64 {
        var offset: i128 = 0;
        for (struct_decl.fields) |field| {
            const info = self.mmioFieldInfo(field) orelse return null;
            const size = self.comptimeSizeOf(info.storage_ty, 0) orelse return null;
            const alignment = self.comptimeAlignOf(info.storage_ty, 0) orelse return null;
            if (field.offset) |explicit| {
                offset = @intCast(explicit);
            } else {
                offset = alignForward(offset, alignment) orelse return null;
            }
            if (std.mem.eql(u8, field.name.text, field_name)) return @intCast(offset);
            offset += size;
        }
        return null;
    }

    fn overlayFieldLayout(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?OverlayLayout {
        if (depth > 32) return null;
        return switch (ty.kind) {
            .array => |node| {
                const child = self.overlayFieldLayout(node.child.*, depth + 1) orelse return null;
                const len = self.arrayLenValue(node.len) orelse return null;
                return .{ .size = child.size * len, .alignment = child.alignment };
            },
            .qualified => |node| self.overlayFieldLayout(node.child.*, depth + 1),
            else => blk: {
                const size = self.comptimeSizeOf(ty, depth + 1) orelse return null;
                const alignment = self.comptimeAlignOf(ty, depth + 1) orelse return null;
                break :blk .{ .size = @intCast(size), .alignment = @intCast(alignment) };
            },
        };
    }

    fn expectedTyForCallArg(self: *LlvmEmitter, callee: []const u8, index: usize) ?ast.TypeExpr {
        const sig = self.fn_sigs.get(callee) orelse return null;
        if (index >= sig.params.len) return null;
        return sig.params[index].ty;
    }

    fn directCallName(self: *LlvmEmitter, callee: ast.Expr) ?[]const u8 {
        const name = calleeIdentName(callee) orelse return null;
        return if (self.fn_sigs.contains(name)) name else null;
    }

    fn fnPointerCalleeType(self: *LlvmEmitter, callee: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(callee) orelse return null;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .fn_pointer => resolved_ty,
            else => null,
        };
    }

    fn closureCalleeType(self: *LlvmEmitter, callee: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(callee) orelse return null;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .closure_type => resolved_ty,
            else => null,
        };
    }

    fn fnPointerTypeForName(self: *LlvmEmitter, name: []const u8) ?ast.TypeExpr {
        const sig = self.fn_sigs.get(name) orelse return null;
        const params = self.scratch.allocator().alloc(ast.TypeExpr, sig.params.len) catch return null;
        for (sig.params, 0..) |param, i| params[i] = param.ty;
        const ret = self.scratch.allocator().create(ast.TypeExpr) catch return null;
        ret.* = sig.ret;
        return .{
            .span = sig.ret.span,
            .kind = .{ .fn_pointer = .{ .params = params, .ret = ret } },
        };
    }

    fn isFnPointerType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return self.resolveAliasType(ty).kind == .fn_pointer;
    }

    fn callReturnType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (reflectionValueCallReturnType(call)) |ty| {
            const expected_fact = mir.reflectionCallTargetKind(call) orelse return null;
            if (self.mirCallTargetKindAt(call.callee.*.span) != expected_fact) return null;
            return ty;
        }
        // Tier 2 dynamic dispatch `d.method(args)` through a `*dyn Trait`: the return type is the
        // trait method's declared return type. Without this, exprType() is null for a dispatch call,
        // so a dispatch used directly as a switch/if subject (`if self.inner.poll() { ... }`) fell
        // through to the unsupported path — the C backend handled it, the LLVM backend did not.
        if (self.dynDispatchTrait(call.callee.*)) |trait| {
            const member = memberCallee(call) orelse return null;
            const slot = traitMethodIndex(trait, member.name.text) orelse return null;
            return trait.methods[slot].return_type orelse simpleType(call.callee.*.span, "void");
        }
        if (self.constGetCallInfo(call)) |info| return info.element_ty;
        if (self.bitcastCallTargetType(call)) |ty| return ty;
        if (self.physCallTargetType(call)) |ty| return ty;
        if (vaCallReturnType(call)) |ty| return ty;
        if (builtinCallReturnType(call)) |ty| return ty;
        if (self.enumRawCallInfo(call)) |info| return info.repr_ty;
        if (self.domainResidueCallInfo(call)) |info| return info.payload_ty;
        if (self.domainOpCallInfo(call)) |info| return info.return_ty;
        if (self.reduceCallInfo(call)) |info| return info.return_ty;
        if (byteViewCallReturnType(call)) |ty| {
            const expected_fact = mir.byteViewCallTargetKind(call) orelse return null;
            if (self.mirCallTargetKindAt(call.callee.*.span) != expected_fact) return null;
            return ty;
        }
        if (mmioMapCallPayloadType(call)) |ty| {
            const child = self.scratch.allocator().create(ast.TypeExpr) catch return null;
            child.* = ty;
            return .{ .span = call.callee.*.span, .kind = .{ .nullable = child } };
        }
        if (self.conversionCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "try_from")) {
                return self.resultType(info.target_ty, simpleType(call.callee.*.span, "ConversionError"), call.callee.*.span) catch null;
            }
            return info.target_ty;
        }
        if (uncheckedBuiltinOp(call.callee.*) != null and call.args.len == 2) return self.exprType(call.args[0]);
        if (self.atomicCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "load") or std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) return info.payload_ty;
            if (std.mem.eql(u8, info.op, "store")) return simpleType(call.callee.*.span, "void");
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "read")) return info.value_ty;
            if (std.mem.eql(u8, info.op, "write")) return simpleType(call.callee.*.span, "void");
        }
        if (self.maybeUninitCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "assume_init")) return info.payload_ty;
            if (std.mem.eql(u8, info.op, "write")) return simpleType(call.callee.*.span, "void");
        }
        if (self.dmaCacheCallInfo(call) != null) return simpleType(call.callee.*.span, "void");
        if (self.dmaBufCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "dma_addr")) return simpleType(call.callee.*.span, "DmaAddr");
            if (std.mem.eql(u8, info.op, "as_slice")) return self.sliceTypeFor(info.payload_ty, .mut, call.callee.*.span) catch null;
        }
        if (self.rawManyOffsetCallInfo(call)) |info| return info.base_ty;
        if (isBindCallNode(call)) return if (self.mirTargetTypeFactAt(.bind, call.callee.*.span)) |fact| fact.target_ty else null;
        if (self.closureCalleeType(call.callee.*)) |closure_ty| return closure_ty.kind.closure_type.ret.*;
        if (self.fnPointerCalleeType(call.callee.*)) |fn_ty| return fn_ty.kind.fn_pointer.ret.*;
        const callee = self.directCallName(call.callee.*) orelse return null;
        return if (self.fn_sigs.get(callee)) |sig| sig.ret else null;
    }

    fn enumRawCallInfo(self: *LlvmEmitter, call: anytype) ?EnumRawCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const enum_ty = self.exprType(member.base.*) orelse return null;
        // `.raw()` is a transparent-repr read; valid on both open and closed enums.
        const enum_decl = self.enumDeclForType(enum_ty) orelse return null;
        return .{ .base = member.base.*, .enum_ty = enum_ty, .repr_ty = enumReprType(enum_decl) };
    }

    fn domainResidueCallInfo(self: *LlvmEmitter, call: anytype) ?DomainResidueCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "residue")) return null;
        const domain_ty = self.exprType(member.base.*) orelse return null;
        const payload_ty = self.domainPayloadType(domain_ty) orelse return null;
        const resolved = self.resolveAliasType(domain_ty);
        const generic = switch (resolved.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (!std.mem.eql(u8, generic.base.text, "wrap")) return null;
        return .{ .base = member.base.*, .domain_ty = domain_ty, .payload_ty = payload_ty };
    }

    fn conversionCallInfo(self: *LlvmEmitter, call: anytype) ?ConversionCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "from") and
            !std.mem.eql(u8, member.name.text, "wrap_from") and
            !std.mem.eql(u8, member.name.text, "from_mod") and
            !std.mem.eql(u8, member.name.text, "trap_from") and
            !std.mem.eql(u8, member.name.text, "sat_from") and
            !std.mem.eql(u8, member.name.text, "try_from"))
        {
            return null;
        }
        switch (member.base.kind) {
            .ident => {},
            else => return null,
        }
        const target_fact = self.mirTargetTypeFactAt(.conversion_target, call.callee.*.span) orelse return null;
        const source_fact = self.mirTargetTypeFactAt(.conversion_source, call.callee.*.span) orelse return null;
        const target_ty = self.resolveAliasType(target_fact.target_ty);
        if (self.integerBitsOf(target_ty) == null) return null;
        const expected_kind = mir.conversionCallTargetKindForName(member.name.text) orelse return null;
        if (self.mirCallTargetKindAt(call.callee.*.span) != expected_kind) return null;
        return .{ .source_ty = source_fact.target_ty, .target_ty = target_ty, .op = member.name.text };
    }

    fn domainOpCallInfo(self: *LlvmEmitter, call: anytype) ?DomainOpCallInfo {
        if (call.type_args.len != 0) return null;
        const member = memberCallee(call) orelse return null;
        const op = member.name.text;
        const is_serial_op = std.mem.eql(u8, op, "before") or
            std.mem.eql(u8, op, "after") or
            std.mem.eql(u8, op, "distance") or
            std.mem.eql(u8, op, "compare");
        const is_counter_op = std.mem.eql(u8, op, "delta_mod") or
            std.mem.eql(u8, op, "elapsed_assume_within") or
            std.mem.eql(u8, op, "elapsed_bounded");
        if (!is_serial_op and !is_counter_op) return null;
        const ident = switch (member.base.kind) {
            .ident => |id| id,
            else => return null,
        };
        if (self.local_types.contains(ident.text)) return null;
        const domain_ty = self.resolveAliasType(simpleType(ident.span, ident.text));
        const generic = switch (domain_ty.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (generic.args.len != 1) return null;
        const is_serial = std.mem.eql(u8, generic.base.text, "serial");
        const is_counter = std.mem.eql(u8, generic.base.text, "counter");
        if ((is_serial_op and !is_serial) or (is_counter_op and !is_counter)) return null;
        const duration_ty: ast.TypeExpr = .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = member.name.span }, .args = generic.args } } };
        const return_ty: ast.TypeExpr = if (std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after"))
            simpleType(member.name.span, "bool")
        else if (std.mem.eql(u8, op, "compare"))
            self.resultType(simpleType(member.name.span, "Order"), simpleType(member.name.span, "AmbiguousSerialOrder"), member.name.span) catch return null
        else if (std.mem.eql(u8, op, "elapsed_assume_within"))
            duration_ty
        else if (std.mem.eql(u8, op, "elapsed_bounded"))
            self.resultType(duration_ty, simpleType(member.name.span, "AmbiguousCounterInterval"), member.name.span) catch return null
        else
            .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "wrap", .span = member.name.span }, .args = generic.args } } };
        return .{ .domain_ty = domain_ty, .payload_ty = generic.args[0], .return_ty = return_ty, .op = op };
    }

    fn reduceCallInfo(self: *LlvmEmitter, call: anytype) ?ReduceCallInfo {
        const kind = self.mirCallTargetKindAt(call.callee.*.span) orelse return null;
        if (kind != .reduce_sum_checked and kind != .reduce_sum_left and kind != .reduce_sum_fast) return null;
        if (call.type_args.len != 1) return null;
        const element_ty = call.type_args[0];
        const return_ty = if (kind == .reduce_sum_checked)
            self.resultType(element_ty, simpleType(call.callee.*.span, "Overflow"), call.callee.*.span) catch return null
        else
            element_ty;
        const op = switch (kind) {
            .reduce_sum_checked => "sum_checked",
            .reduce_sum_left => "sum_left",
            .reduce_sum_fast => "sum_fast",
            else => return null,
        };
        return .{ .element_ty = element_ty, .return_ty = return_ty, .op = op };
    }

    fn constGetCallInfo(self: *LlvmEmitter, call: anytype) ?ConstGetCallInfo {
        if (self.mirCallTargetKindAt(call.callee.*.span) != .const_get) return null;
        const target = constGetCallTarget(call) orelse return null;
        const base_ty = self.exprType(target.base.*) orelse return null;
        const array_ty = self.resolveAliasType(base_ty);
        const array = switch (array_ty.kind) {
            .array => |node| node,
            .qualified => |node| switch (self.resolveAliasType(node.child.*).kind) {
                .array => |array_node| array_node,
                else => return null,
            },
            else => return null,
        };
        const len = self.arrayLenValue(array.len) orelse return null;
        if (target.index >= len) return null;
        return .{
            .base = target.base.*,
            .array_ty = array_ty,
            .element_ty = array.child.*,
            .index = target.index,
        };
    }

    fn atomicCallInfo(self: *LlvmEmitter, call: anytype) ?AtomicCallInfo {
        const kind = self.mirCallTargetKindAt(call.callee.*.span) orelse return null;
        const op = switch (kind) {
            .atomic_load => "load",
            .atomic_store => "store",
            .atomic_fetch_add => "fetch_add",
            .atomic_fetch_sub => "fetch_sub",
            else => return null,
        };
        const member = memberCallee(call) orelse return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        if (self.atomicPayloadType(base_ty)) |payload_ty| {
            return .{ .base = member.base.*, .op = op, .payload_ty = payload_ty };
        }
        // A `*atomic<T>` base: the pointer is the atomic's address.
        const child = switch (self.resolveAliasType(base_ty).kind) {
            .pointer => |p| p.child.*,
            else => return null,
        };
        const payload_ty = self.atomicPayloadType(child) orelse return null;
        return .{ .base = member.base.*, .op = op, .payload_ty = payload_ty, .base_is_pointer = true };
    }

    // The address the atomic lives at: for a `*atomic<T>` base the pointer value already IS the
    // address; otherwise it is the storage address of the by-value atomic (local/global/field).
    fn atomicAddress(self: *LlvmEmitter, info: AtomicCallInfo) ![]const u8 {
        if (info.base_is_pointer) {
            const base_ty = self.exprType(info.base) orelse return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, base_ty);
        }
        return self.atomicBaseAddress(info.base);
    }

    fn maybeUninitCallInfo(self: *LlvmEmitter, call: anytype) ?MaybeUninitCallInfo {
        const kind = self.mirCallTargetKindAt(call.callee.*.span) orelse return null;
        const op = switch (kind) {
            .maybe_uninit_write => "write",
            .maybe_uninit_assume_init => "assume_init",
            else => return null,
        };
        const member = memberCallee(call) orelse return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const payload_ty = self.maybeUninitPayloadType(base_ty) orelse return null;
        return .{ .base = member.base.*, .op = op, .payload_ty = payload_ty };
    }

    fn bitcastCallTargetType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (self.mirCallTargetKindAt(call.callee.*.span) != .bitcast) return null;
        if (call.type_args.len != 1 or call.args.len != 1) return null;
        return call.type_args[0];
    }

    fn physCallTargetType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (self.mirCallTargetKindAt(call.callee.*.span) != .phys) return null;
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        return simpleType(call.callee.*.span, "PAddr");
    }

    fn dmaCacheCallInfo(self: *LlvmEmitter, call: anytype) ?DmaCacheCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!isIdentNamed(member.base.*, "cache")) return null;
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (call.args.len != 1) return null;
        const dma_ty = self.exprType(call.args[0]) orelse return null;
        _ = self.dmaBufInfo(dma_ty) orelse return null;
        return .{ .op = member.name.text, .dma_ty = dma_ty };
    }

    fn dmaBufCallInfo(self: *LlvmEmitter, call: anytype) ?DmaBufCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "dma_addr") and !std.mem.eql(u8, member.name.text, "as_slice")) return null;
        const dma_ty = self.exprType(member.base.*) orelse return null;
        const info = self.dmaBufInfo(dma_ty) orelse return null;
        return .{ .base = member.base.*, .op = member.name.text, .dma_ty = dma_ty, .payload_ty = info.payload_ty };
    }

    fn dmaBufInfo(self: *LlvmEmitter, ty: ast.TypeExpr) ?DmaBufInfo {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "DmaBuf") or node.args.len != 2) return null;
                return .{ .payload_ty = node.args[0] };
            },
            .qualified => |node| self.dmaBufInfo(node.child.*),
            else => null,
        };
    }

    fn atomicBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return self.storageBaseAddress(expr);
    }

    fn storageBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.local_slots.get(ident.text)) |slot|
                slot.ptr
            else if (self.global_types.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .member => |node| try self.emitMemberAddress(node),
            .grouped => |inner| try self.storageBaseAddress(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn llvmAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr) u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.llvmAlignOf(enumReprType(enum_decl));
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (self.domainPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool") or
                std.mem.eql(u8, name.text, "i8") or
                std.mem.eql(u8, name.text, "u8") or
                libraryScalarLlvmType(name.text) != null)
                1
            else if (std.mem.eql(u8, name.text, "i16") or
                std.mem.eql(u8, name.text, "u16"))
                2
            else if (std.mem.eql(u8, name.text, "i32") or
                std.mem.eql(u8, name.text, "u32") or
                std.mem.eql(u8, name.text, "f32"))
                4
            else
                8,
            .pointer, .raw_many_pointer, .nullable, .slice => 8,
            else => 8,
        };
    }

    fn arrayLenValue(self: *LlvmEmitter, expr: ast.Expr) ?u64 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.arrayLenValue(&env, expr);
    }

    fn reflectionCallValue(self: *LlvmEmitter, call: anytype) ?[]const u8 {
        const expected_fact = mir.reflectionCallTargetKind(call) orelse return null;
        if (self.mirCallTargetKindAt(call.callee.*.span) != expected_fact) return null;
        const expr: ast.Expr = .{ .span = call.callee.*.span, .kind = .{ .call = call } };
        var env = self.reflectEnv();
        const value = lower_llvm_reflect.comptimeReflect(&env, expr) orelse return null;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) catch null;
    }

    fn comptimeSizeOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeSizeOf(&env, ty, depth);
    }

    fn comptimeAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeAlignOf(&env, ty, depth);
    }

    fn comptimeFieldOffset(self: *LlvmEmitter, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeFieldOffset(&env, ty, field, depth);
    }

    fn integerBitsOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?u16 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.integerBitsOf(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.integerBitsOf(info.repr);
        if (self.domainPayloadType(ty)) |payload_ty| return self.integerBitsOf(payload_ty);
        return integerBits(self.resolveAliasType(ty));
    }

    fn isSignedIntegerType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        if (self.enumDeclForType(ty)) |enum_decl| return self.isSignedIntegerType(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.isSignedIntegerType(info.repr);
        if (self.domainPayloadType(ty)) |payload_ty| return self.isSignedIntegerType(payload_ty);
        return isSignedInteger(self.resolveAliasType(ty));
    }

    fn isFloatTypeOf(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return isFloatType(self.resolveAliasType(ty));
    }

    fn isF32TypeOf(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |name| std.mem.eql(u8, name.text, "f32"),
            else => false,
        };
    }

    fn fixedLayoutBitsOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?u16 {
        if (self.integerBitsOf(ty)) |bits| return bits;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "f32"))
                32
            else if (std.mem.eql(u8, name.text, "f64") or isOpaqueAddressTypeName(name.text))
                64
            else
                null,
            .pointer, .raw_many_pointer, .nullable, .slice, .fn_pointer => 64,
            .generic => |node| if ((isOpaqueAddressGenericName(node.base.text) or std.mem.eql(u8, node.base.text, "MmioPtr")) and node.args.len == 1) 64 else null,
            .qualified => |node| self.fixedLayoutBitsOf(node.child.*),
            else => null,
        };
    }

    // `MmioPtr<T>` is the typed device-register pointer (lowers to `ptr`). The
    // audited unsafe boundary mints it from a pointer-width integer / opaque address
    // (a probed MMIO base) and extracts it back to an integer; both are pointer
    // <-> address coercions, lowered as inttoptr/ptrtoint by emitBitcastValue.
    fn isMmioPtrType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .generic => |node| std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1,
            else => false,
        };
    }

    fn pointerAddressCoercion(self: *LlvmEmitter, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) bool {
        const source = self.resolveAliasType(source_ty);
        const target = self.resolveAliasType(target_ty);
        // MmioPtr<T> <-> pointer-width integer / opaque address (the device-register
        // mint/extract boundary). MmioPtr lowers to `ptr`, so this is inttoptr/ptrtoint.
        if (self.isMmioPtrType(source)) {
            return switch (target.kind) {
                .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
                .pointer, .raw_many_pointer, .nullable => true,
                else => false,
            };
        }
        if (self.isMmioPtrType(target)) {
            return switch (source.kind) {
                .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
                .pointer, .raw_many_pointer, .nullable, .fn_pointer => true,
                else => false,
            };
        }
        return switch (source.kind) {
            // `.fn_pointer` (a code pointer, e.g. `&trap_vector`) coerces to a pointer-width
            // integer just like a data pointer — needed to install a vector by address.
            .pointer, .raw_many_pointer, .nullable, .fn_pointer => switch (target.kind) {
                .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
                else => false,
            },
            .name => |name| if (isOpaqueAddressTypeName(name.text)) switch (target.kind) {
                .pointer, .raw_many_pointer, .nullable => true,
                else => false,
            } else false,
            else => false,
        };
    }

    fn signedMinLiteralOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?[]const u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.signedMinLiteralOf(enumReprType(enum_decl));
        return signedMinLiteral(self.resolveAliasType(ty));
    }

    fn signedWindowMinLiteral(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const value = -(@as(i128, 1) << @intCast(bits - 1));
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn rawManyOffsetCallInfo(self: *LlvmEmitter, call: anytype) ?RawManyOffsetInfo {
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const element_ty = switch (self.resolveAliasType(base_ty).kind) {
            .raw_many_pointer => |node| node.child.*,
            else => return null,
        };
        return .{ .base = member.base.*, .base_ty = base_ty, .element_ty = element_ty };
    }

    fn isAggregateType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved_ty = self.resolveAliasType(ty);
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.isAggregateType(payload_ty);
        return switch (resolved_ty.kind) {
            .array => true,
            .slice => true,
            .closure_type => true,
            .name => self.structDeclForType(resolved_ty) != null or self.overlayInfoForType(resolved_ty) != null or self.taggedUnionForType(resolved_ty) != null,
            .generic => |node| std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2,
            else => false,
        };
    }
};

// Result/tagged-union arm-pattern shapes are classified by the shared, AST-only `switch_lower`
// module; these aliases keep the existing call sites in this file reading unchanged.
const ResultSwitchPattern = switch_lower.ResultArmPattern;
const TaggedUnionBinding = switch_lower.TaggedUnionArmBinding;

fn isSourceSpan(span: ast.Span) bool {
    return span.line != 0 and span.column != 0;
}

fn restoreLocal(map: anytype, key: []const u8, old: anytype) !void {
    if (old) |entry| {
        try map.put(key, entry.value);
    } else {
        _ = map.remove(key);
    }
}

const resultSwitchPattern = switch_lower.resultArmPattern;

const taggedUnionPatternName = switch_lower.taggedUnionPatternName;
const taggedUnionBindingPattern = switch_lower.taggedUnionArmBinding;
