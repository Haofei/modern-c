const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const backend_cleanup = @import("backend_cleanup.zig");
const diagnostics = @import("diagnostics.zig");
const error_from = @import("error_from.zig");
const eval = @import("eval.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const CodegenDeclArtifacts = declaration_artifacts.CodegenDeclarationArtifacts;
const CodegenFunctionBodyArtifacts = declaration_artifacts.CodegenFunctionBodyArtifacts;
const syntax_bridge = @import("syntax_bridge.zig");
const switch_lower = @import("switch_lower.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");
const mir_source_bridge = @import("mir_source_bridge.zig");
const numeric = @import("numeric.zig");
const type_bridge = @import("type_bridge.zig");

const isIdentNamed = syntax_bridge.isIdentNamed;
const typeName = type_bridge.typeName;
const byteViewAddressTarget = syntax_bridge.byteViewAddressTarget;
const calleeIdentName = syntax_bridge.calleeIdentName;
const memberExpr = syntax_bridge.memberExpr;
const indexExpr = syntax_bridge.indexExpr;
const isSourceSpan = mir_source_bridge.isSourceSpan;
const sourcePointFromOptionalSpan = mir_source_bridge.sourcePointFromOptionalSpan;
const isOpaqueAddressTypeName = type_bridge.isOpaqueAddressTypeName;
const isStringLiteralTarget = type_bridge.isStringLiteralTarget;
const isMmioStructAbi = type_bridge.isMmioStructAbi;
const overlayByteArrayElementType = type_bridge.overlayByteArrayElementType;
const overlayArrayElementType = type_bridge.overlayArrayElementType;
const overlayMemberFromIndexBase = syntax_bridge.overlayMemberFromIndexBase;
const taggedUnionCase = syntax_bridge.taggedUnionCase;

const backend_mod = @import("backend.zig");
const lower_llvm_lookup = @import("lower_llvm_lookup.zig");
const lower_llvm_shape = @import("lower_llvm_shape.zig");

// Phase-2c split: pure type-mapping/classification helpers moved verbatim to
// `lower_llvm_type.zig`. Re-exported here so call sites read unchanged.
const lower_llvm_type = @import("lower_llvm_type.zig");
const simpleType = lower_llvm_type.simpleType;
const isDynTraitLlvmType = lower_llvm_type.isDynTraitLlvmType;
const alignForward = lower_llvm_type.alignForward;
const isOpaqueAddressGenericName = lower_llvm_type.isOpaqueAddressGenericName;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;
const libraryScalarLlvmType = lower_llvm_type.libraryScalarLlvmType;
const typeNameEql = lower_llvm_type.typeNameEql;
const secretInnerType = lower_llvm_type.secretInnerType;
const rawScalarTypeName = lower_llvm_type.rawScalarTypeName;
const parseU64Literal = lower_llvm_type.parseU64Literal;
const integerBits = lower_llvm_type.integerBits;
const isSignedInteger = lower_llvm_type.isSignedInteger;
const signedMinLiteral = lower_llvm_type.signedMinLiteral;
const intrinsicBits = lower_llvm_type.intrinsicBits;

// Phase-2c split: operator/predicate spelling, trap-helper, and literal
// normalization helpers moved verbatim to `lower_llvm_op.zig`. Re-exported
// here so call sites read unchanged.
const lower_llvm_op = @import("lower_llvm_op.zig");
const binaryIsComparison = lower_llvm_op.binaryIsComparison;
const comparisonPredicate = lower_llvm_op.comparisonPredicate;
const floatComparisonPredicate = lower_llvm_op.floatComparisonPredicate;
const normalizedIntLiteral = lower_llvm_op.normalizedIntLiteral;
const normalizedFloatLiteral = lower_llvm_op.normalizedFloatLiteral;
const charLiteralValue = lower_llvm_op.charLiteralValue;

// LLVM module prelude emission and target metadata.
const lower_llvm_prelude = @import("lower_llvm_prelude.zig");
const emitTrapDecl = lower_llvm_prelude.emitTrapDecl;
const emitExternalRuntimeDecls = lower_llvm_prelude.emitExternalRuntimeDecls;
const emitTargetTypeDecls = lower_llvm_prelude.emitTargetTypeDecls;
const isKsanHook = lower_llvm_prelude.isKsanHook;
const llvmTargetDataLayout = lower_llvm_prelude.targetDataLayout;
const llvmTargetTriple = lower_llvm_prelude.targetTriple;

// LLVM textual escaping, inline-asm spelling, debug line normalization, and
// declaration attribute helpers.
const lower_llvm_text = @import("lower_llvm_text.zig");
const codegen_attrs = @import("codegen_attrs.zig");
const debugColumn = lower_llvm_text.debugColumn;
const debugLine = lower_llvm_text.debugLine;
const escapedLlvmString = lower_llvm_text.escapedLlvmString;
const llvmAsmClobbers = lower_llvm_text.llvmAsmClobbers;
const llvmOpaqueAsmTemplate = lower_llvm_text.llvmOpaqueAsmTemplate;
const llvmPreciseAsmConstraints = lower_llvm_text.llvmPreciseAsmConstraints;
const llvmPreciseAsmTemplate = lower_llvm_text.llvmPreciseAsmTemplate;
const llvmStringLiteralBytes = lower_llvm_text.llvmStringLiteralBytes;

const NullableRepresentation = enum {
    pointer,
    dyn_trait,
    value,
};

const MirSubjectType = struct {
    target_ty: ast_bridge.TypeExpr,
    nullable_representation: ?NullableRepresentation = null,
};

// LLVM backend AST/call-shape queries and small pure lowering helpers.
const lower_llvm_query = @import("lower_llvm_query.zig");
const assignmentIdent = lower_llvm_query.assignmentIdent;
const comptimeStructFieldValue = lower_llvm_query.comptimeStructFieldValue;
const derefTarget = lower_llvm_query.derefTarget;
const implMethodMangledLlvm = lower_llvm_query.implMethodMangledLlvm;
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
const atomicOrderingArg = syntax_bridge.atomicOrderingArg;
const atomicOrderingExpr = syntax_bridge.atomicOrderingExpr;
const orderingArg = syntax_bridge.atomicOrderingExpr;
const atomicLlvmOrdering = lower_llvm_atomic.atomicLlvmOrdering;
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
const MmioMapInfo = lower_llvm_model.MmioMapInfo;
const RawCallInfo = lower_llvm_model.RawCallInfo;
const ByteViewCallInfo = lower_llvm_model.ByteViewCallInfo;
const ReflectionCallInfo = lower_llvm_model.ReflectionCallInfo;
const VaCallInfo = lower_llvm_model.VaCallInfo;
const MmioFencePlacement = lower_llvm_model.MmioFencePlacement;
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
const ReduceTypes = struct {
    source_ty: ast_bridge.TypeExpr,
    element_ty: ast_bridge.TypeExpr,
};
const DomainResidueCallInfo = lower_llvm_model.DomainResidueCallInfo;
const DomainOpCallInfo = lower_llvm_model.DomainOpCallInfo;
const ConversionCallInfo = lower_llvm_model.ConversionCallInfo;
const ReduceCallInfo = lower_llvm_model.ReduceCallInfo;
const ConstGetCallInfo = lower_llvm_model.ConstGetCallInfo;
const IntRange = lower_llvm_model.IntRange;
const AtomicCallInfo = lower_llvm_model.AtomicCallInfo;
const MaybeUninitCallInfo = lower_llvm_model.MaybeUninitCallInfo;
const ResultTypeInfo = lower_llvm_model.ResultTypeInfo;
const EnumRawTypes = struct {
    enum_ty: ast_bridge.TypeExpr,
    repr_ty: ast_bridge.TypeExpr,
};
const DomainTypes = struct {
    domain_ty: ast_bridge.TypeExpr,
    payload_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
    interval_ty: ?ast_bridge.TypeExpr = null,
};
const BitcastTypes = struct {
    source_ty: ast_bridge.TypeExpr,
    target_ty: ast_bridge.TypeExpr,
};
const SemanticEscapeTypes = struct {
    source_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

const ArithmeticCallTypes = struct {
    left_ty: ast_bridge.TypeExpr,
    right_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

const UncheckedCallInfo = struct {
    op: []const u8,
    left_ty: ast_bridge.TypeExpr,
    right_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

const WrappingCallInfo = struct {
    op: []const u8,
    left_ty: ast_bridge.TypeExpr,
    right_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

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

fn directCallFactMatchesDeclared(fact_ty: ast_bridge.TypeExpr, declared_ty: ast_bridge.TypeExpr) bool {
    if (std.meta.eql(fact_ty, declared_ty)) return true;
    if (type_bridge.sameTypeSyntax(fact_ty, declared_ty)) return true;
    return (typeNameEql(fact_ty, "void") and typeNameEql(declared_ty, "void")) or
        (typeNameEql(fact_ty, "never") and typeNameEql(declared_ty, "never"));
}

/// Construct the `Backend` registry entry for the LLVM backend. The LLVM
/// backend is profile-agnostic and has no source-map artifact.
pub fn mcBackend() backend_mod.Backend {
    return .{
        .name = "llvm",
        .artifact_ext = ".ll",
        .supports_profiles = false,
        .ctx = null,
        .lowerFn = backendLower,
    };
}

fn backendLower(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: backend_mod.LowerRequest,
) backend_mod.LowerError!void {
    _ = ctx;
    return appendLlvmCheckedMirProfileWithVerifiedProgram(allocator, request.declaration_artifacts, request.function_bodies, request.program, request.out, request.opts.source_path orelse "input.mc", request.opts.checks, request.opts.stub_asm, request.opts.target_arch, request.opts.linux_kernel, request.opts.reporter) catch |err| backend_mod.lowerErrorFromAny(err);
}

pub fn appendLlvmCheckedMirArtifacts(
    allocator: std.mem.Allocator,
    artifacts: CodegenDeclArtifacts,
    function_bodies: CodegenFunctionBodyArtifacts,
    module_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    source_path: []const u8,
    checks: backend_mod.Checks,
    stub_asm: bool,
    target_arch: backend_mod.TargetArch,
    linux_kernel: bool,
    reporter: ?*diagnostics.Reporter,
) !void {
    var local_reporter = diagnostics.Reporter.init(allocator, source_path, "");
    defer local_reporter.deinit();
    const active_reporter = reporter orelse &local_reporter;
    const program = backend_mod.VerifiedProgram.init(module_mir, active_reporter) catch |err| switch (err) {
        error.StaleMirTargetTypeFacts => return error.UnsupportedLlvmEmission,
        else => return err,
    };
    return appendLlvmCheckedMirProfileWithVerifiedProgram(allocator, artifacts, function_bodies, program, out, source_path, checks, stub_asm, target_arch, linux_kernel, reporter);
}

fn appendLlvmCheckedMirProfileWithVerifiedProgram(
    allocator: std.mem.Allocator,
    early_metadata: CodegenDeclArtifacts,
    function_bodies: CodegenFunctionBodyArtifacts,
    program: backend_mod.VerifiedProgram,
    out: *std.ArrayList(u8),
    source_path: []const u8,
    checks: backend_mod.Checks,
    stub_asm: bool,
    target_arch: backend_mod.TargetArch,
    linux_kernel: bool,
    reporter: ?*diagnostics.Reporter,
) !void {
    const comptime_declarations = eval.ComptimeDeclarations.fromDeclarationArtifacts(early_metadata, function_bodies);
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
    if (linux_kernel)
        try emitExternalRuntimeDecls(allocator, out, program.runtime_hooks)
    else
        try emitTrapDecl(allocator, out, program.runtime_hooks);

    var ctx = LlvmEmitter{
        .allocator = allocator,
        .out = out,
        .mir_module = program.typed_mir.*,
        .scratch = std.heap.ArenaAllocator.init(allocator),
        .need_uadd = std.StringHashMap(void).init(allocator),
        .need_usub = std.StringHashMap(void).init(allocator),
        .need_umul = std.StringHashMap(void).init(allocator),
        .need_sadd = std.StringHashMap(void).init(allocator),
        .need_ssub = std.StringHashMap(void).init(allocator),
        .need_smul = std.StringHashMap(void).init(allocator),
        .const_fns = std.StringHashMap(eval.ComptimeFunction).init(allocator),
        .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
        .const_global_widths = std.StringHashMap(u16).init(allocator),
        .const_global_domains = std.StringHashMap(eval.DomainWidth).init(allocator),
        .comptime_declarations = comptime_declarations,
        .type_aliases = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
        .enum_types = std.StringHashMap(ast_bridge.EnumDecl).init(allocator),
        .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
        .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
        .tagged_unions = std.StringHashMap(ast_bridge.UnionDecl).init(allocator),
        .struct_types = std.StringHashMap(ast_bridge.StructDecl).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .trait_decls = std.StringHashMap(declaration_artifacts.TraitDeclArtifact).init(allocator),
        .impl_methods = std.StringHashMap([]const ast_bridge.ImplTraitMethod).init(allocator),
        .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
        .backend_names = std.StringHashMap([]const u8).init(allocator),
        .codegen_artifacts = early_metadata,
        .function_bodies = function_bodies,
        .global_types = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
        .global_is_const = std.StringHashMap(bool).init(allocator),
        .global_initializers = std.StringHashMap(ast_bridge.Expr).init(allocator),
        .local_types = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
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
        .linux_kernel = linux_kernel,
    };
    defer ctx.deinit();
    try ctx.preRegisterTypeDeclsFromArtifacts(early_metadata);
    var reflect_env = ctx.reflectEnv();
    try eval.collectConstGlobalsFromDeclarationsWithOptions(allocator, comptime_declarations, &ctx.const_fns, &ctx.const_globals, .{
        .reflect = lower_llvm_reflect.comptimeReflectThunk,
        .reflect_ctx = &reflect_env,
        .domains = &ctx.const_global_domains,
    });
    try ctx.collectNonStructTypeArtifacts();
    try ctx.collectStructArtifacts();
    try ctx.collectFunctionGlobalAndTraitArtifacts();
    try ctx.collectMirAggregateReturnPointerFieldFacts();
    // Tier 2: one rodata vtable global per `impl Trait for Type` of an object-safe
    // trait. Function pointers may be forward-referenced in LLVM IR, so this can run
    // before the function bodies are emitted.
    try ctx.emitVtables();
    try ctx.emitCollectedGlobals();
    try ctx.emitCollectedCallableDeclarations();
    // Scalar-env closure thunks discovered while emitting bodies. LLVM IR allows
    // forward references to these `@mc_envthunk_*` symbols, so emitting them after
    // the function bodies is fine.
    try ctx.emitBindThunks();
    try ctx.emitBackendNameAliases();
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
    const_fns: std.StringHashMap(eval.ComptimeFunction) = undefined,
    const_globals: std.StringHashMap(eval.ComptimeValue) = undefined,
    const_global_widths: std.StringHashMap(u16) = undefined,
    const_global_domains: std.StringHashMap(eval.DomainWidth) = undefined,
    comptime_declarations: eval.ComptimeDeclarations,
    type_aliases: std.StringHashMap(ast_bridge.TypeExpr) = undefined,
    enum_types: std.StringHashMap(ast_bridge.EnumDecl) = undefined,
    packed_bits: std.StringHashMap(PackedBitsInfo) = undefined,
    overlay_unions: std.StringHashMap(OverlayUnionInfo) = undefined,
    tagged_unions: std.StringHashMap(ast_bridge.UnionDecl) = undefined,
    struct_types: std.StringHashMap(ast_bridge.StructDecl) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    // Tier 2 trait objects (traits-design §8): every `trait` by name (vtable layout +
    // dispatch slot resolution) and each `impl Trait for Type`'s mangled methods (the
    // rodata vtable's function-pointer list).
    trait_decls: std.StringHashMap(declaration_artifacts.TraitDeclArtifact) = undefined,
    impl_methods: std.StringHashMap([]const ast_bridge.ImplTraitMethod) = undefined,
    // `bind(scalar, f)` closures whose env is a non-pointer integer scalar. The
    // closure's env slot is `ptr`, so the scalar is widened via `inttoptr` and the
    // code pointer points at a generated thunk that narrows it back with `ptrtoint`
    // before calling `f`. Keyed by target function name.
    bind_thunks: std.StringHashMap(BindThunk) = undefined,
    // Source function name -> `#[backend_name("Y")]` override; emitted as a module-level
    // alias `@Y = alias <fnty>, ptr @name` so the override symbol is linkable (the C backend
    // achieves the same via an asm label).
    backend_names: std.StringHashMap([]const u8) = undefined,
    codegen_artifacts: CodegenDeclArtifacts = CodegenDeclArtifacts.empty,
    function_bodies: CodegenFunctionBodyArtifacts = CodegenFunctionBodyArtifacts.empty,
    global_types: std.StringHashMap(ast_bridge.TypeExpr) = undefined,
    global_is_const: std.StringHashMap(bool) = undefined,
    global_initializers: std.StringHashMap(ast_bridge.Expr) = undefined,
    local_types: std.StringHashMap(ast_bridge.TypeExpr) = undefined,
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
    string_literals: std.ArrayList(StringLiteralGlobal) = undefined,
    debug_functions: std.ArrayList(DebugFunction) = undefined,
    debug_locations: std.ArrayList(DebugLocation) = undefined,
    debug_locals: std.ArrayList(DebugLocal) = undefined,
    debug_next_id: usize = 6,
    need_dbg_declare: bool = false,
    need_dbg_value: bool = false,
    current_debug_scope: ?usize = null,
    current_debug_span: ?ast_bridge.Span = null,
    current_return_ty: ?ast_bridge.TypeExpr = null,
    current_function: ?[]const u8 = null,
    current_params: ?[]const codegen_attrs.FunctionParamFact = null,
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
    linux_kernel: bool = false,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.const_fns.deinit();
        self.const_global_widths.deinit();
        self.const_global_domains.deinit();
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
        self.global_is_const.deinit();
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
        self.string_literals.deinit(self.allocator);
        self.debug_functions.deinit(self.allocator);
        self.debug_locations.deinit(self.allocator);
        self.debug_locals.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn preRegisterTypeDeclsFromArtifacts(self: *LlvmEmitter, artifacts: CodegenDeclArtifacts) !void {
        try eval.collectConstFunctionsFromDeclarations(eval.ComptimeDeclarations.fromDeclarationArtifacts(artifacts, self.function_bodies), &self.const_fns);
        for (artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
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
                .overlay_union_decl => {},
            },
            else => {},
        };
    }

    fn collectStructArtifacts(self: *LlvmEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .struct_decl => |struct_decl| try self.collectStruct(struct_decl),
                else => {},
            },
            else => {},
        };
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl) !void {
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

    fn collectTypeAlias(self: *LlvmEmitter, alias: ast_bridge.TypeAlias) !void {
        _ = try self.llvmType(alias.ty);
        try self.type_aliases.put(alias.name.text, alias.ty);
    }

    fn collectNonStructTypeArtifacts(self: *LlvmEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .packed_bits_decl => |packed_bits| try self.collectPackedBits(packed_bits),
                .overlay_union_decl => |overlay_union| try self.collectOverlayUnion(overlay_union),
                .union_decl => |union_decl| try self.collectTaggedUnion(union_decl),
                .type_alias => |alias| try self.collectTypeAlias(alias),
                .enum_decl => |enum_decl| try self.collectEnum(enum_decl),
                .struct_decl => {},
            },
            else => {},
        };
    }

    fn collectEnum(self: *LlvmEmitter, enum_decl: ast_bridge.EnumDecl) !void {
        const repr = enumReprType(enum_decl);
        if (self.integerBitsOf(repr) == null) return error.UnsupportedLlvmEmission;
        for (enum_decl.cases) |case| _ = try self.enumCaseValue(enum_decl, case);
        try self.enum_types.put(enum_decl.name.text, enum_decl);
    }

    fn collectPackedBits(self: *LlvmEmitter, packed_bits: ast_bridge.PackedBitsDecl) !void {
        if (self.integerBitsOf(packed_bits.repr) == null) return error.UnsupportedLlvmEmission;
        try self.packed_bits.put(packed_bits.name.text, .{
            .repr = packed_bits.repr,
            .fields = packed_bits.fields,
        });
    }

    fn collectOverlayUnion(self: *LlvmEmitter, overlay_union: ast_bridge.OverlayUnionDecl) !void {
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

    fn collectTaggedUnion(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| _ = try self.llvmType(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
    }

    fn collectFunctionArtifact(self: *LlvmEmitter, function: declaration_artifacts.FunctionArtifact) !void {
        const sig = function.signature;
        const ret_ty = sig.return_type orelse simpleType(function.signature.name.span, "void");
        _ = try self.llvmType(ret_ty);
        for (sig.params) |param| _ = try self.llvmType(param.ty);
        const debug_id: ?usize = if (function.body_facts.has_definition) blk: {
            const id = self.debug_next_id;
            self.debug_next_id += 1;
            try self.debug_functions.append(self.allocator, .{
                .id = id,
                .name = function.signature.name.text,
                .line = debugLine(function.signature.name.span.line),
                .column = debugColumn(function.signature.name.span.column),
            });
            break :blk id;
        } else null;
        try self.fn_sigs.put(function.signature.name.text, .{ .ret = ret_ty, .params = sig.params, .c_abi = sig.c_abi, .is_variadic = sig.is_variadic, .debug_id = debug_id, .error_from = sig.error_from });
        if (function.signature.backend_name) |name| try self.backend_names.put(function.signature.name.text, name);
    }

    fn collectFunctionGlobalAndTraitArtifacts(self: *LlvmEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .function => |function| try self.collectFunctionArtifact(function),
            .global => |global| try self.collectGlobal(global),
            .trait_decl => |trait_decl| try self.trait_decls.put(trait_decl.facts.name.text, trait_decl),
            .impl_trait => |impl_trait| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ impl_trait.facts.trait_name.text, impl_trait.facts.type_name.text });
                try self.impl_methods.put(key, impl_trait.facts.methods);
            },
            .transitional_type_decl => {},
        };
    }

    fn collectGlobal(self: *LlvmEmitter, global: declaration_artifacts.GlobalArtifact) !void {
        const sig = global.signature;
        const ty = sig.ty orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(ty);
        try self.global_types.put(sig.name.text, ty);
        try self.global_is_const.put(sig.name.text, sig.is_const);
        if (sig.is_const) {
            if (eval.comptimeTypeBitWidth(ty)) |bits| try self.const_global_widths.put(sig.name.text, bits);
        }
        if (global.initializer.init) |expr| try self.global_initializers.put(sig.name.text, expr);
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

    fn emitGlobal(self: *LlvmEmitter, global: declaration_artifacts.GlobalArtifact) !void {
        const sig = global.signature;
        const init_facts = global.initializer;
        const previous_function = self.current_function;
        self.current_function = sig.name.text;
        defer self.current_function = previous_function;
        const ty = sig.ty orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        // `extern global NAME: T;` — a declaration only; storage lives in another unit.
        if (sig.is_extern) {
            try self.out.print(self.allocator, "@{s} = external global {s}\n", .{ sig.name.text, llvm_ty });
            return;
        }
        const kind: []const u8 = if (sig.is_const) "constant" else "global";
        // Mirror the C backend's `static` vs external split (lower_c.zig emitGlobal): a plain
        // `global`/`const` stays module-private (LLVM `internal` linkage), so two separately
        // compiled units may each define the same name (e.g. `PAGE`) without a link-time
        // duplicate-symbol error. Only `export global` keeps default (external) linkage.
        const visibility: []const u8 = if (sig.exported) "" else "internal ";
        const init = if (init_facts.init) |expr| try self.emitGlobalInitializer(expr, ty) else try self.zeroInitializer(ty);
        try self.out.print(self.allocator, "@{s} = {s}{s} {s} {s}\n", .{ sig.name.text, visibility, kind, llvm_ty, init });
    }

    fn emitCollectedGlobals(self: *LlvmEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .global => |global| try self.emitGlobal(global),
            else => {},
        };
    }

    fn emitCollectedCallableDeclarations(self: *LlvmEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .function => |function| if (function.signature.is_extern) try self.emitExternFunction(function),
            else => {},
        };

        // Function-definition admission is driven by verified MIR.  The
        // source-shaped body artifact is still the transitional rendering
        // payload, but it no longer decides which functions enter body
        // lowering.
        for (self.mir_module.functions) |fn_mir| {
            if (fn_mir.is_extern) continue;
            const artifact_index = self.functionArtifactIndexByName(fn_mir.name) orelse continue;
            const function = switch (self.codegen_artifacts.decl_artifacts[artifact_index]) {
                .function => |function| function,
                else => unreachable,
            };
            if (function.signature.is_extern) continue;
            const render_attrs = function.render_attrs;
            if (try self.emitSimpleMirFunction(function, fn_mir, render_attrs)) {
                continue;
            } else if (self.function_bodies.legacyFunctionBody(fn_mir.name)) |body| {
                try self.emitFunction(function, body, render_attrs);
            } else {
                return error.UnsupportedLlvmEmission;
            }
        }
    }

    fn functionArtifactIndexByName(self: *const LlvmEmitter, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.codegen_artifacts.decl_artifacts.len) : (i += 1) {
            switch (self.codegen_artifacts.decl_artifacts[i]) {
                .function => |function| if (std.mem.eql(u8, function.signature.name.text, name)) return i,
                else => {},
            }
        }
        return null;
    }

    fn emitGlobalInitializer(self: *LlvmEmitter, expr: ast_bridge.Expr, ty: ast_bridge.TypeExpr) ![]const u8 {
        const view_narrow_target = self.mirTargetTypeFactAt(.view_const_narrow_target, expr.span);
        if (view_narrow_target) |fact| {
            _ = self.mirTargetTypeFactAt(.view_const_narrow_source, expr.span) orelse return error.UnsupportedLlvmEmission;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(ty))) return error.UnsupportedLlvmEmission;
        }
        const semantic_ty = switch (expr.kind) {
            .array_literal => if (self.mirTargetTypeFactAt(.array_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission,
            .struct_literal => (try self.requireMirStructLiteralConstruction(expr.span, ty)).target_ty,
            .null_literal => if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| fact.target_ty else return error.UnsupportedLlvmEmission,
            else => if (view_narrow_target) |fact| fact.target_ty else ty,
        };
        const resolved_ty = self.resolveAliasType(semantic_ty);
        if (self.foldConstGlobalValue(expr, semantic_ty)) |value| {
            return try self.comptimeValueInitializer(value, semantic_ty);
        }
        if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| {
            if (syntax_bridge.callExpr(expr)) |call| {
                if (self.mirHasCallTargetKindAt(.atomic_init, call.callee.*.span)) {
                    const fact_payload_ty = self.atomicInitPayloadTypeAt(call.callee.*.span, semantic_ty) orelse return error.UnsupportedLlvmEmission;
                    if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                    return try self.emitGlobalInitializer(call.args[0], fact_payload_ty);
                }
            }
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
                        return try self.emitGlobalInitializerForOwner(ident.text, initializer, semantic_ty);
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
            .char_literal => |literal| try self.emitCharLiteralWithTarget(literal, expr.span, semantic_ty),
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
                try normalizedFloatLiteral(self.scratch.allocator(), literal, lower_llvm_shape.isF32TypeOf(&self.type_aliases, fact.target_ty))
            else
                error.UnsupportedLlvmEmission,
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, semantic_ty)) {
                    const literal = switch ((node.expr.*).kind) {
                        .float_literal => |literal| literal,
                        .grouped => |inner| switch (inner.kind) {
                            .float_literal => |literal| literal,
                            else => break :blk error.UnsupportedLlvmEmission,
                        },
                        else => break :blk error.UnsupportedLlvmEmission,
                    };
                    const negated = try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{literal});
                    break :blk try normalizedFloatLiteral(self.scratch.allocator(), negated, lower_llvm_shape.isF32TypeOf(&self.type_aliases, semantic_ty));
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

    fn globalAddressInitializer(self: *LlvmEmitter, expr: ast_bridge.Expr) anyerror![]const u8 {
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

    fn emitGlobalInitializerForOwner(self: *LlvmEmitter, owner: []const u8, expr: ast_bridge.Expr, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const previous_function = self.current_function;
        self.current_function = owner;
        defer self.current_function = previous_function;
        return try self.emitGlobalInitializer(expr, ty);
    }

    fn globalConstIndexValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ?u64 {
        if (self.foldConstGlobalValue(expr, null)) |value| {
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

    fn foldConstGlobalValue(self: *LlvmEmitter, expr: ast_bridge.Expr, expected_ty: ?ast_bridge.TypeExpr) ?eval.ComptimeValue {
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
        const folded = if (expected_ty) |ty|
            eval.foldComptimeExprExpected(&scope, expr, ty)
        else
            eval.foldComptimeExpr(&scope, expr);
        return switch (folded) {
            .value => |v| eval.cloneComptimeValue(self.scratch.allocator(), v) catch null,
            else => null,
        };
    }

    fn seedConstFoldScope(self: *LlvmEmitter, scope: *eval.ComptimeScope, reflect_env: *LlvmReflectEnv) bool {
        if (!lower_llvm_reflect.seedConstFoldScope(reflect_env, scope)) return false;
        scope.declarations = self.comptime_declarations;
        return true;
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
            .const_global_domains = &self.const_global_domains,
        };
    }

    fn comptimeValueInitializer(self: *LlvmEmitter, value: eval.ComptimeValue, target_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const resolved = self.resolveAliasType(target_ty);
        return switch (value) {
            .int => |n| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
            .uint => |n| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
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
            // Preserve the exact source-width IEEE representation. Widening an
            // f32 through a host f64 quiets signaling NaNs, so materialize the
            // constant from its raw integer bits instead.
            .float => |f| blk: {
                const tname = switch (resolved.kind) {
                    .name => |n| n.text,
                    else => "",
                };
                if (std.mem.eql(u8, tname, "f32")) {
                    const bits: u32 = @bitCast(f.asF32());
                    break :blk try std.fmt.allocPrint(self.scratch.allocator(), "bitcast (i32 {d} to float)", .{bits});
                }
                const bits: u64 = if (f.width == 64) f.bits else @bitCast(f.asF64());
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "bitcast (i64 {d} to double)", .{bits});
            },
            .void, .bytes => error.UnsupportedLlvmEmission,
        };
    }

    fn zeroInitializer(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        if (lower_llvm_shape.maybeUninitPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool"))
                "0"
            else if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, resolved_ty))
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
            .pointer, .raw_many_pointer => "null",
            .nullable => |child| if (self.nullablePayloadIsValueType(child.*) or self.isAggregateType(child.*))
                "zeroinitializer"
            else
                "null",
            .slice => "zeroinitializer",
            .array => "zeroinitializer",
            .qualified => |node| try self.zeroInitializer(node.child.*),
            .generic => |node| if (lower_llvm_shape.resultInfo(&self.type_aliases, resolved_ty)) |_|
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
    fn emitBackendNameAliases(self: *LlvmEmitter) !void {
        for (self.debug_functions.items) |debug_function| {
            const source_name = debug_function.name;
            const backend = self.backend_names.get(source_name) orelse continue;
            const sig = self.fn_sigs.get(source_name) orelse return error.UnsupportedLlvmEmission;
            try self.out.print(self.allocator, "@{s} = alias {s} (", .{ backend, try self.llvmType(sig.ret) });
            for (sig.params, 0..) |param, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
            }
            try self.out.print(self.allocator, "), ptr @{s}\n", .{source_name});
        }
    }

    fn cAbiExtension(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) []const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "bool")) return if (self.target_arch == .aarch64) "" else "zeroext ";
        const bits = self.integerBitsOf(ty) orelse return "";
        if (bits > 32) return "";
        if (self.target_arch == .aarch64) return "";
        if (bits == 32) return if (self.target_arch == .riscv64) "signext " else "";
        return if (self.isSignedIntegerType(ty)) "signext " else "zeroext ";
    }

    fn promoteCVariadicArgument(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, value: []const u8) !ArgValue {
        const resolved = self.resolveAliasType(ty);
        if (typeNameEql(resolved, "f32")) {
            const promoted = simpleType(ty.span, "f64");
            return .{ .ty = promoted, .value = try self.castValue(value, ty, promoted) };
        }
        if (typeNameEql(resolved, "bool")) {
            const promoted = simpleType(ty.span, "i32");
            return .{ .ty = promoted, .value = try self.castValue(value, ty, promoted) };
        }
        if (self.integerBitsOf(ty)) |bits| {
            if (bits < 32) {
                const promoted = simpleType(ty.span, "i32");
                return .{ .ty = promoted, .value = try self.castValue(value, ty, promoted) };
            }
            return .{ .ty = ty, .value = value };
        }
        if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, ty) or self.fixedLayoutBitsOf(ty) != null or std.mem.eql(u8, try self.llvmType(ty), "ptr")) return .{ .ty = ty, .value = value };
        return error.UnsupportedLlvmEmission;
    }

    const SimpleMirReturn = union(enum) {
        void,
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        checked_integer_literal: []const u8,
        bool_literal: bool,
        enum_literal: SimpleMirEnumLiteral,
        null_literal,
        global_load: []const u8,
        nested_call: SimpleMirNestedCall,
        direct_call: SimpleMirDirectCall,
        result_constructor: SimpleMirResultConstructorReturn,
        explicit_cast_return: SimpleMirExplicitCastReturn,
        conversion_return: SimpleMirConversionReturn,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
        struct_literal: SimpleMirStructLiteralReturn,
        array_literal: SimpleMirArrayLiteralReturn,
    };

    const SimpleMirVoidBody = union(enum) {
        empty,
        statements: SimpleMirVoidStatements,
        conditional_statements: SimpleMirConditionalVoidStatements,
        loop_statements: SimpleMirLoopVoidBody,
        direct_call: SimpleMirDirectCall,
        direct_calls: SimpleMirDirectCalls,
        conditional_direct_calls: SimpleMirConditionalVoidBody,
    };

    const SimpleMirEnumLiteral = struct {
        enum_name: []const u8,
        case_name: []const u8,
    };

    const SimpleMirTrapBody = struct {
        helper: []const u8,
    };

    const max_simple_mir_void_calls = 8;
    const max_simple_mir_void_statements = 8;
    const max_simple_mir_global_stores = 8;

    const SimpleMirDirectCalls = struct {
        calls: [max_simple_mir_void_calls]SimpleMirDirectCall = undefined,
        count: usize = 0,
    };

    const SimpleMirVoidStatementSource = union(enum) {
        direct_call: mir.SourcePoint,
        global_store: struct {
            name: []const u8,
            value_source: mir.SourcePoint,
            source: mir.SourcePoint,
        },
    };

    const SimpleMirVoidStatementSources = struct {
        sources: [max_simple_mir_void_statements]SimpleMirVoidStatementSource = undefined,
        count: usize = 0,
    };

    const SimpleMirConditionalVoidBody = struct {
        prefix_calls: SimpleMirDirectCalls,
        condition: SimpleMirCondition,
        then_calls: SimpleMirDirectCalls,
        else_calls: SimpleMirDirectCalls,
        suffix_statements: SimpleMirVoidStatementSources,
    };

    const SimpleMirConditionalVoidStatements = struct {
        prefix_calls: SimpleMirDirectCalls,
        condition: SimpleMirCondition,
        then_statements: SimpleMirVoidStatements,
        else_statements: SimpleMirVoidStatements,
        suffix_statements: SimpleMirVoidStatementSources,
    };

    const SimpleMirConditionalReturn = struct {
        prefix_calls: SimpleMirDirectCalls,
        condition: SimpleMirCondition,
        then_value: SimpleMirConditionalValue,
        else_value: SimpleMirConditionalValue,
    };

    const SimpleMirConditionalStatementReturnKind = enum {
        after,
        mixed,
        branch,
    };

    const SimpleMirConditionalStatementReturn = struct {
        prefix_calls: SimpleMirDirectCalls,
        condition: SimpleMirCondition,
        then_block_index: usize,
        else_block_index: usize,
        result: SimpleMirConditionalStatementReturnKind,
        suffix_block_index: usize = 0,
    };

    const SimpleMirLoopReturn = struct {
        condition: SimpleMirCondition,
        body_block_index: usize,
        after_block_index: usize,
    };

    const SimpleMirLoopVoidBody = struct {
        condition: SimpleMirCondition,
        body_block_index: usize,
    };

    const SimpleMirCondition = union(enum) {
        param: struct {
            name: []const u8,
            inverted: bool = false,
        },
        param_field: struct {
            field: SimpleMirParamField,
            inverted: bool = false,
        },
        bool_literal: bool,
        direct_call: SimpleMirNestedCall,
        compare_binary: SimpleMirCompareBinary,
    };

    const SimpleMirConditionalValue = union(enum) {
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        bool_literal: bool,
        global_load: []const u8,
        direct_call: SimpleMirDirectCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
        enum_literal: SimpleMirEnumLiteral,
        null_literal,
        struct_literal: SimpleMirStructLiteralReturn,
        array_literal: SimpleMirArrayLiteralReturn,
    };

    const SimpleMirParamField = struct {
        param_name: []const u8,
        field_name: []const u8,
        field_index: usize,
        struct_name: []const u8,
    };

    const max_simple_mir_call_args = 8;
    const max_simple_mir_struct_fields = 8;
    const max_simple_mir_array_items = 8;

    const SimpleMirStructLiteralField = struct {
        llvm_ty: []const u8,
        value: SimpleMirCallArg,
    };

    const SimpleMirStructLiteralReturn = struct {
        llvm_ty: []const u8,
        fields: [max_simple_mir_struct_fields]SimpleMirStructLiteralField = undefined,
        field_count: usize = 0,
    };

    const SimpleMirArrayLiteralReturn = struct {
        llvm_ty: []const u8,
        element_ty: []const u8,
        items: [max_simple_mir_array_items]SimpleMirCallArg = undefined,
        item_count: usize = 0,
    };

    const SimpleMirArg = union(enum) {
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        bool_literal: bool,
    };

    const SimpleMirCallArg = union(enum) {
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        bool_literal: bool,
        global_load: []const u8,
        direct_call: SimpleMirNestedCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        logical_not: SimpleMirArg,
        compare_binary: SimpleMirCompareBinary,
    };

    const SimpleMirNestedCall = struct {
        callee: []const u8,
        args: [max_simple_mir_call_args]SimpleMirArg = undefined,
        arg_facts: [max_simple_mir_call_args]mir.TargetTypeFact = undefined,
        arg_count: usize = 0,
    };

    const SimpleMirDirectCall = struct {
        callee: []const u8,
        args: [max_simple_mir_call_args]SimpleMirCallArg = undefined,
        arg_facts: [max_simple_mir_call_args]mir.TargetTypeFact = undefined,
        arg_count: usize = 0,
    };

    const SimpleMirResultConstructorReturn = struct {
        tag: []const u8,
        result_fact: mir.TargetTypeFact,
        payload: SimpleMirResultConstructorPayload,
    };

    const SimpleMirResultConstructorPayload = union(enum) {
        arg: SimpleMirCallArg,
        enum_literal: SimpleMirEnumLiteral,
    };

    const SimpleMirConversionReturn = struct {
        kind: mir.CallTargetKind,
        source_fact: mir.TargetTypeFact,
        target_fact: mir.TargetTypeFact,
        operand: SimpleMirCallArg,
    };

    const SimpleMirExplicitCastReturn = struct {
        source_fact: mir.TargetTypeFact,
        target_fact: mir.TargetTypeFact,
        operand: SimpleMirCallArg,
    };

    const SimpleMirGlobalStore = struct {
        name: []const u8,
        value: SimpleMirGlobalStoreValue,
        source: mir.SourcePoint,
    };

    const SimpleMirGlobalStores = struct {
        stores: [max_simple_mir_global_stores]SimpleMirGlobalStore = undefined,
        count: usize = 0,
    };

    const SimpleMirVoidStatement = union(enum) {
        direct_call: SimpleMirDirectCall,
        global_store: SimpleMirGlobalStore,
    };

    const SimpleMirVoidStatements = struct {
        statements: [max_simple_mir_void_statements]SimpleMirVoidStatement = undefined,
        count: usize = 0,
    };

    const SimpleMirGlobalStoreValue = union(enum) {
        arg: SimpleMirArg,
        global_load: []const u8,
        direct_call: SimpleMirDirectCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
    };

    const SimpleMirCheckedBinary = struct {
        op: []const u8,
        target_fact: mir.TargetTypeFact,
        left: SimpleMirArg,
        right: SimpleMirArg,
    };

    const SimpleMirCheckedUnary = struct {
        op: []const u8,
        target_fact: mir.TargetTypeFact,
        operand: SimpleMirArg,
    };

    const SimpleMirCompareBinary = struct {
        op: []const u8,
        operand_fact: mir.TargetTypeFact,
        left: SimpleMirArg,
        right: SimpleMirArg,
    };

    fn emitSimpleMirFunction(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, render_attrs: anytype) !bool {
        if (!plainFunctionRenderAttrs(render_attrs) or function.signature.is_variadic) return false;
        const simple_trap = self.simpleMirTrapBody(fn_mir);
        const simple_return = self.simpleMirReturn(function, fn_mir);
        const simple_return_prefix_calls = if (simple_trap == null) blk: {
            if (simple_return) |ret| {
                break :blk self.simpleMirPrefixVoidCallsBeforeReturn(function, fn_mir, self.simpleMirReturnAllowsTrapBlocks(fn_mir, ret)) orelse return false;
            }
            break :blk null;
        } else null;
        const simple_void_body = if (simple_trap == null and simple_return == null) self.simpleMirVoidBody(function, fn_mir) else null;
        const simple_conditional_statement_return = if (simple_trap == null and simple_return == null and simple_void_body == null) self.simpleMirConditionalStatementReturn(function, fn_mir) else null;
        const simple_conditional_return = if (simple_trap == null and simple_return == null and simple_void_body == null and simple_conditional_statement_return == null) self.simpleMirConditionalReturn(function, fn_mir) else null;
        const simple_loop_return = if (simple_trap == null and simple_return == null and simple_void_body == null and simple_conditional_statement_return == null and simple_conditional_return == null) self.simpleMirLoopReturn(function, fn_mir) else null;
        if (simple_trap == null and simple_return == null and simple_void_body == null and simple_conditional_statement_return == null and simple_conditional_return == null and simple_loop_return == null) return false;

        const sig_facts = function.signature;
        const ret_ty = sig_facts.return_type orelse simpleType(sig_facts.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        const fn_sig = self.fn_sigs.get(sig_facts.name.text) orelse return error.UnsupportedLlvmEmission;
        const ret_ext = if (fn_sig.c_abi) self.cAbiExtension(ret_ty) else "";

        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_return_ty = self.current_return_ty;
        const old_function = self.current_function;
        const old_params = self.current_params;
        self.current_debug_scope = if (self.fn_sigs.get(sig_facts.name.text)) |sig| sig.debug_id else null;
        self.current_debug_span = sig_facts.name.span;
        self.current_return_ty = ret_ty;
        self.current_function = sig_facts.name.text;
        self.current_params = sig_facts.params;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_return_ty = old_return_ty;
            self.current_function = old_function;
            self.current_params = old_params;
        }

        const attr_str: []const u8 = if (self.linux_kernel and self.target_arch == .x86_64)
            " nounwind fn_ret_thunk_extern"
        else if (self.linux_kernel and self.target_arch == .aarch64)
            " nounwind \"branch-target-enforcement\""
        else if (self.linux_kernel)
            " nounwind"
        else
            "";
        const weak_str: []const u8 = if (!sig_facts.exported)
            "internal "
        else
            "";

        try self.out.print(self.allocator, "define {s}{s}{s} @{s}(", .{ weak_str, ret_ext, ret_llvm, sig_facts.name.text });
        for (sig_facts.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (fn_sig.c_abi) self.cAbiExtension(param.ty) else "";
            try self.out.print(self.allocator, "{s} {s}%{s}", .{ try self.llvmType(param.ty), param_ext, param.name.text });
        }
        const entry_label = try self.functionEntryLabel();
        if (self.current_debug_scope) |scope| {
            try self.out.print(self.allocator, "){s} !dbg !{d} {{\n{s}:\n", .{ attr_str, scope, entry_label });
        } else {
            try self.out.print(self.allocator, "){s} {{\n{s}:\n", .{ attr_str, entry_label });
        }

        if (simple_trap) |trap| {
            try self.out.print(self.allocator, "  call void @{s}(){s}\n  unreachable\n", .{ trap.helper, try self.debugCallSuffix() });
        } else if (simple_return) |ret| {
            const return_span = self.simpleMirReturnSpan(fn_mir) orelse sig_facts.name.span;
            if (simple_return_prefix_calls) |calls| {
                try self.emitSimpleMirDirectCalls(calls, return_span);
            }
            switch (ret) {
                .void => try self.emitReturnVoid(return_span),
                .param => |name| try self.emitReturnValue(ret_ty, try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{name}), return_span),
                .param_field => |field| {
                    const tmp = try self.emitSimpleMirParamFieldValue(field, return_span);
                    try self.emitReturnValue(ret_ty, tmp, return_span);
                },
                .integer_literal => |literal| try self.emitReturnValue(ret_ty, literal, return_span),
                .checked_integer_literal => |literal| try self.emitReturnValue(ret_ty, literal, return_span),
                .bool_literal => |value| try self.emitReturnValue(ret_ty, if (value) "1" else "0", return_span),
                .enum_literal => |literal| {
                    const enum_decl = self.enum_types.get(literal.enum_name) orelse return error.UnsupportedLlvmEmission;
                    try self.emitReturnValue(ret_ty, try self.enumCaseValueByName(enum_decl, literal.case_name), return_span);
                },
                .null_literal => try self.emitReturnValue(ret_ty, "zeroinitializer", return_span),
                .global_load => |name| {
                    const value = try self.emitSimpleMirGlobalLoad(name, ret_ty);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .nested_call => |call| {
                    const tmp = try self.nextTemp();
                    try self.emitSimpleMirNestedCall(call, tmp, return_span);
                    try self.emitReturnValue(ret_ty, tmp, return_span);
                },
                .checked_binary => |binary| {
                    const value = try self.emitSimpleMirCheckedBinary(binary, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .checked_unary => |unary| {
                    const value = try self.emitSimpleMirCheckedUnary(unary, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .compare_binary => |binary| {
                    const value = try self.emitSimpleMirCompareBinary(binary, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .logical_not => |arg| {
                    const value = try self.emitSimpleMirLogicalNot(arg, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .direct_call => |call| {
                    const tmp = try self.nextTemp();
                    try self.emitSimpleMirDirectCall(call, tmp, return_span);
                    try self.emitReturnValue(ret_ty, tmp, return_span);
                },
                .result_constructor => |constructor| {
                    const value = try self.emitSimpleMirResultConstructorReturn(constructor, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .explicit_cast_return => |cast| {
                    const value = try self.emitSimpleMirExplicitCastReturn(cast, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .conversion_return => |conversion| {
                    const value = try self.emitSimpleMirConversionReturn(conversion, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .struct_literal => |literal| {
                    const value = try self.emitSimpleMirStructLiteralReturn(literal, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
                .array_literal => |literal| {
                    const value = try self.emitSimpleMirArrayLiteralReturn(literal, return_span);
                    try self.emitReturnValue(ret_ty, value, return_span);
                },
            }
        } else if (simple_void_body) |body| {
            switch (body) {
                .empty => try self.emitReturnVoid(sig_facts.name.span),
                .statements => |statements| {
                    const return_span = try self.emitSimpleMirVoidStatements(statements, sig_facts.name.span);
                    try self.emitReturnVoid(return_span);
                },
                .conditional_statements => |conditional| {
                    try self.emitSimpleMirDirectCalls(conditional.prefix_calls, sig_facts.name.span);
                    const then_label = try self.nextLabel("if_then");
                    const else_label = try self.nextLabel("if_else");
                    const done_label = try self.nextLabel("if_done");
                    const condition = try self.emitSimpleMirCondition(conditional.condition, sig_facts.name.span);
                    const inverted = simpleMirConditionInverted(conditional.condition);
                    const true_label = if (inverted) else_label else then_label;
                    const false_label = if (inverted) then_label else else_label;
                    try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, true_label, false_label, try self.debugCallSuffix(), then_label });
                    _ = try self.emitSimpleMirVoidStatements(conditional.then_statements, sig_facts.name.span);
                    try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), else_label });
                    _ = try self.emitSimpleMirVoidStatements(conditional.else_statements, sig_facts.name.span);
                    try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), done_label });
                    _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, conditional.suffix_statements, sig_facts.name.span);
                    try self.emitReturnVoid(sig_facts.name.span);
                },
                .loop_statements => |loop| {
                    const body_label = try self.nextLabel("while_body");
                    const after_label = try self.nextLabel("while_after");
                    const condition = try self.emitSimpleMirCondition(loop.condition, sig_facts.name.span);
                    const inverted = simpleMirConditionInverted(loop.condition);
                    const body_target = if (inverted) after_label else body_label;
                    const after_target = if (inverted) body_label else after_label;
                    try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_target, after_target, try self.debugCallSuffix(), body_label });
                    _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[loop.body_block_index]).?, sig_facts.name.span);
                    try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_target, after_target, try self.debugCallSuffix(), after_label });
                    try self.emitReturnVoid(sig_facts.name.span);
                },
                .direct_call => |call| {
                    const span = if (self.simpleMirCallSource(fn_mir)) |source| spanFromMirSourcePoint(source) else sig_facts.name.span;
                    try self.emitSimpleMirDirectCall(call, null, span);
                    try self.emitReturnVoid(span);
                },
                .direct_calls => |calls| {
                    try self.emitSimpleMirDirectCalls(calls, sig_facts.name.span);
                    try self.emitReturnVoid(sig_facts.name.span);
                },
                .conditional_direct_calls => |conditional| {
                    try self.emitSimpleMirDirectCalls(conditional.prefix_calls, sig_facts.name.span);
                    const then_label = try self.nextLabel("if_then");
                    const else_label = try self.nextLabel("if_else");
                    const done_label = try self.nextLabel("if_done");
                    const condition = try self.emitSimpleMirCondition(conditional.condition, sig_facts.name.span);
                    const inverted = simpleMirConditionInverted(conditional.condition);
                    const true_label = if (inverted) else_label else then_label;
                    const false_label = if (inverted) then_label else else_label;
                    try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, true_label, false_label, try self.debugCallSuffix(), then_label });
                    try self.emitSimpleMirDirectCalls(conditional.then_calls, sig_facts.name.span);
                    try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), else_label });
                    try self.emitSimpleMirDirectCalls(conditional.else_calls, sig_facts.name.span);
                    try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), done_label });
                    _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, conditional.suffix_statements, sig_facts.name.span);
                    try self.emitReturnVoid(sig_facts.name.span);
                },
            }
        } else if (simple_conditional_statement_return) |conditional| {
            const then_label = try self.nextLabel("if_then");
            const else_label = try self.nextLabel("if_else");
            const done_label = try self.nextLabel("if_done");
            try self.emitSimpleMirDirectCalls(conditional.prefix_calls, sig_facts.name.span);
            const condition = try self.emitSimpleMirCondition(conditional.condition, sig_facts.name.span);
            const inverted = simpleMirConditionInverted(conditional.condition);
            const true_label = if (inverted) else_label else then_label;
            const false_label = if (inverted) then_label else else_label;
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, true_label, false_label, try self.debugCallSuffix(), then_label });
            _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[conditional.then_block_index]).?, sig_facts.name.span);
            switch (conditional.result) {
                .branch => try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.then_block_index]).?, sig_facts.name.span),
                .mixed => {
                    if (fn_mir.blocks[conditional.then_block_index].terminator == .return_) {
                        try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.then_block_index]).?, sig_facts.name.span);
                    } else {
                        try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ done_label, try self.debugCallSuffix() });
                    }
                },
                .after => try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ done_label, try self.debugCallSuffix() }),
            }
            try self.out.print(self.allocator, "{s}:\n", .{else_label});
            _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[conditional.else_block_index]).?, sig_facts.name.span);
            switch (conditional.result) {
                .branch => try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.else_block_index]).?, sig_facts.name.span),
                .mixed => {
                    if (fn_mir.blocks[conditional.else_block_index].terminator == .return_) {
                        try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.else_block_index]).?, sig_facts.name.span);
                    } else {
                        try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ done_label, try self.debugCallSuffix() });
                    }
                    try self.out.print(self.allocator, "{s}:\n", .{done_label});
                    _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[conditional.suffix_block_index]).?, sig_facts.name.span);
                    try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.suffix_block_index]).?, sig_facts.name.span);
                },
                .after => {
                    try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), done_label });
                    _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[conditional.suffix_block_index]).?, sig_facts.name.span);
                    try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[conditional.suffix_block_index]).?, sig_facts.name.span);
                },
            }
        } else if (simple_conditional_return) |conditional| {
            const then_label = try self.nextLabel("if_then");
            const else_label = try self.nextLabel("if_else");
            try self.emitSimpleMirDirectCalls(conditional.prefix_calls, sig_facts.name.span);
            const condition = try self.emitSimpleMirCondition(conditional.condition, sig_facts.name.span);
            const inverted = simpleMirConditionInverted(conditional.condition);
            const true_label = if (inverted) else_label else then_label;
            const false_label = if (inverted) then_label else else_label;
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, true_label, false_label, try self.debugCallSuffix(), then_label });
            try self.emitSimpleMirConditionalReturnValue(ret_ty, conditional.then_value, sig_facts.name.span);
            try self.out.print(self.allocator, "{s}:\n", .{else_label});
            try self.emitSimpleMirConditionalReturnValue(ret_ty, conditional.else_value, sig_facts.name.span);
        } else if (simple_loop_return) |loop| {
            const body_label = try self.nextLabel("while_body");
            const after_label = try self.nextLabel("while_after");
            const condition = try self.emitSimpleMirCondition(loop.condition, sig_facts.name.span);
            const inverted = simpleMirConditionInverted(loop.condition);
            const body_target = if (inverted) after_label else body_label;
            const after_target = if (inverted) body_label else after_label;
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_target, after_target, try self.debugCallSuffix(), body_label });
            _ = try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[loop.body_block_index]).?, sig_facts.name.span);
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_target, after_target, try self.debugCallSuffix(), after_label });
            try self.emitSimpleMirConditionalReturnValue(ret_ty, self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[loop.after_block_index]).?, sig_facts.name.span);
        }
        try self.out.appendSlice(self.allocator, "}\n\n");
        return true;
    }

    fn simpleMirTrapBody(self: *LlvmEmitter, fn_mir: mir.Function) ?SimpleMirTrapBody {
        _ = self;
        if (fn_mir.blocks.len != 2 or fn_mir.trap_edges.len != 1) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const edge = fn_mir.trap_edges[0];
        if (edge.from_block != 0 or edge.trap_block != 1) return null;
        const entry = fn_mir.blocks[0];
        const trap_block = fn_mir.blocks[1];
        if (!std.mem.eql(u8, trap_block.kind, "trap") or trap_block.terminator != .trap_) return null;
        switch (entry.terminator) {
            .return_, .unreachable_ => {},
            else => return null,
        }
        if (edge.kind == .Unreachable) return .{ .helper = "mc_trap_Unreachable" };
        if (edge.kind != .ExplicitTrap) return null;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, .{ .line = edge.line, .column = edge.column })) continue;
            if (mir.explicitTrapHelperForTarget(fact.kind)) |helper| return .{ .helper = helper };
        }
        if (fn_mir.call_target_facts.len == 1) {
            if (mir.explicitTrapHelperForTarget(fn_mir.call_target_facts[0].kind)) |helper| return .{ .helper = helper };
        }
        return null;
    }

    fn simpleMirReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirReturn {
        if (fn_mir.blocks.len == 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const block = fn_mir.blocks[0];
        if (block.terminator != .return_) return null;
        if (!self.blockOnlyContainsSimpleMirReturnInstructions(function, fn_mir)) return null;
        const ret = simpleMirReturnInstruction(block) orelse return null;
        if (ret.result_ty == .void or std.mem.eql(u8, ret.detail, "void")) return if (simpleMirNoTrap(fn_mir)) .void else null;
        const value_id = ret.value_id orelse return null;
        for (function.signature.params) |param| {
            if (std.mem.eql(u8, value_id, param.name.text)) return if (simpleMirNoTrap(fn_mir)) .{ .param = param.name.text } else null;
        }
        if (self.simpleMirParamFieldReturn(function, block, ret, value_id)) |field| return if (simpleMirNoTrap(fn_mir)) .{ .param_field = field } else null;
        if (self.global_types.contains(value_id)) return if (simpleMirNoTrap(fn_mir)) .{ .global_load = value_id } else null;
        if (std.mem.eql(u8, value_id, "int")) {
            const source = simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret);
            for (fn_mir.integer_facts) |fact| {
                if (sameMirSourceLocation(fact.source, source)) return if (simpleMirNoTrap(fn_mir)) .{ .integer_literal = fact.literal } else null;
            }
        }
        if (std.mem.eql(u8, value_id, "char")) {
            const source = simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret);
            for (fn_mir.integer_facts) |fact| {
                if (sameMirSourceLocation(fact.source, source)) {
                    const literal = charLiteralValue(self.scratch.allocator(), fact.literal) catch return null;
                    return if (simpleMirNoTrap(fn_mir)) .{ .integer_literal = literal } else null;
                }
            }
        }
        if (std.mem.eql(u8, value_id, "bool")) {
            const source = simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret);
            for (fn_mir.bool_facts) |fact| {
                if (sameMirSourceLocation(fact.source, source)) return if (simpleMirNoTrap(fn_mir)) .{ .bool_literal = fact.value } else null;
            }
        }
        if (self.simpleMirEnumLiteralAtSource(fn_mir, value_id, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) |literal| {
            return if (simpleMirNoTrap(fn_mir)) .{ .enum_literal = literal } else null;
        }
        if (simpleMirNullLiteralAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) {
            return if (simpleMirNoTrap(fn_mir)) .null_literal else null;
        }
        if (self.simpleMirDirectCall(function, fn_mir, value_id)) |call| {
            if (fn_mir.trap_edges.len == simpleMirDirectCallTrapCount(call)) return .{ .direct_call = call };
        }
        if (self.simpleMirResultConstructorReturn(function, fn_mir, block, value_id)) |constructor| {
            if (fn_mir.trap_edges.len == simpleMirResultConstructorPayloadTrapCount(constructor.payload)) return .{ .result_constructor = constructor };
        }
        if (std.mem.eql(u8, value_id, "cast")) {
            if (self.simpleMirExplicitCastReturn(function, fn_mir)) |cast| return .{ .explicit_cast_return = cast };
        }
        if (self.simpleMirConversionReturn(function, fn_mir, value_id)) |conversion| return .{ .conversion_return = conversion };
        if (std.mem.eql(u8, value_id, "struct_literal")) {
            if (self.simpleMirStructLiteralReturn(function, fn_mir, block)) |literal| return .{ .struct_literal = literal };
        }
        if (std.mem.eql(u8, value_id, "array_literal")) {
            if (self.simpleMirArrayLiteralReturn(function, fn_mir, block)) |literal| return .{ .array_literal = literal };
        }
        if (std.mem.eql(u8, value_id, "binary")) {
            if (self.simpleMirCheckedBinaryAtReturn(function, fn_mir)) |binary| return .{ .checked_binary = binary };
            if (self.simpleMirCompareBinaryAtReturn(function, fn_mir)) |binary| return .{ .compare_binary = binary };
        }
        if (std.mem.eql(u8, value_id, "unary")) {
            if (self.simpleMirLogicalNotAtReturn(function, fn_mir)) |arg| return .{ .logical_not = arg };
            if (self.simpleMirCheckedUnaryAtReturn(function, fn_mir)) |unary| {
                if (self.simpleMirFoldedNegatedIntegerLiteral(unary)) |literal| return .{ .checked_integer_literal = literal };
                return .{ .checked_unary = unary };
            }
        }
        if (self.simpleMirAssignmentReturn(function, fn_mir, value_id)) |assigned| return assigned;
        if (self.simpleMirLocalInitReturn(function, fn_mir, value_id)) |local_init| return local_init;
        return null;
    }

    fn simpleMirStructLiteralReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirStructLiteralReturn {
        const ret_ty = function.signature.return_type orelse return null;
        const type_name = type_bridge.typeName(self.resolveAliasType(ret_ty)) orelse return null;
        const struct_decl = self.struct_types.get(type_name) orelse return null;
        if (struct_decl.fields.len > max_simple_mir_struct_fields) return null;

        var literal_source: ?mir.SourcePoint = null;
        var literal_index: usize = 0;
        for (block.instructions, 0..) |instruction, index| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "struct_literal")) {
                literal_source = instructionSourcePoint(instruction);
                literal_index = index;
                break;
            }
        }
        const source = literal_source orelse return null;
        const literal = self.simpleMirStructLiteralFromBlockAtIndex(function, fn_mir, block, literal_index, source) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirStructLiteralTrapCount(literal)) return null;
        return literal;
    }

    fn simpleMirStructLiteralFromBlockAtIndex(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, literal_index: usize, source: mir.SourcePoint) ?SimpleMirStructLiteralReturn {
        const ret_ty = function.signature.return_type orelse return null;
        const type_name = type_bridge.typeName(self.resolveAliasType(ret_ty)) orelse return null;
        const struct_decl = self.struct_types.get(type_name) orelse return null;
        if (struct_decl.fields.len > max_simple_mir_struct_fields) return null;
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .struct_literal, source) orelse return null;
        if (!std.mem.eql(u8, fact.result_ty.name(), type_name)) return null;

        var result: SimpleMirStructLiteralReturn = .{ .llvm_ty = self.llvmType(ret_ty) catch return null };
        var scan_index = literal_index + 1;
        for (struct_decl.fields) |field| {
            while (scan_index < block.instructions.len) : (scan_index += 1) {
                const instruction = block.instructions[scan_index];
                if (instruction.kind == .return_value) return null;
                if (instruction.kind == .target_type or instruction.kind == .integer_literal_conversion) continue;
                if (instruction.kind != .expr and instruction.kind != .call and instruction.kind != .binary and instruction.kind != .unary) return null;
                if ((instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary) and !self.noFunctionBodyFallbacksAvailable()) return null;
                const value_source = instructionSourcePoint(instruction);
                const arg = self.simpleMirCallArgAt(function, fn_mir, value_source) orelse return null;
                result.fields[result.field_count] = .{
                    .llvm_ty = self.llvmType(field.ty) catch return null,
                    .value = arg,
                };
                result.field_count += 1;
                scan_index += 1;
                if (instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary) {
                    while (scan_index < block.instructions.len and !simpleMirLiteralBoundaryInstruction(block.instructions[scan_index])) : (scan_index += 1) {}
                } else {
                    while (scan_index < block.instructions.len and sameMirSourceLocation(instructionSourcePoint(block.instructions[scan_index]), value_source)) : (scan_index += 1) {}
                }
                break;
            } else return null;
        }
        return result;
    }

    fn simpleMirArrayLiteralReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirArrayLiteralReturn {
        var literal_source: ?mir.SourcePoint = null;
        var literal_index: usize = 0;
        for (block.instructions, 0..) |instruction, index| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "array_literal")) {
                literal_source = instructionSourcePoint(instruction);
                literal_index = index;
                break;
            }
        }
        const source = literal_source orelse return null;
        const literal = self.simpleMirArrayLiteralFromBlockAtIndex(function, fn_mir, block, literal_index, source) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirArrayLiteralTrapCount(literal)) return null;
        return literal;
    }

    fn simpleMirArrayLiteralFromBlockAtIndex(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, literal_index: usize, source: mir.SourcePoint) ?SimpleMirArrayLiteralReturn {
        const ret_ty = function.signature.return_type orelse return null;
        const resolved_ret_ty = self.resolveAliasType(ret_ty);
        const array_ty = switch (resolved_ret_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        const item_count_u64 = self.arrayLenValue(array_ty.len) orelse return null;
        if (item_count_u64 > max_simple_mir_array_items) return null;
        const item_count: usize = @intCast(item_count_u64);
        _ = simpleMirTargetTypeFactKindAt(fn_mir, .array_literal, source) orelse return null;

        var result: SimpleMirArrayLiteralReturn = .{
            .llvm_ty = self.llvmType(ret_ty) catch return null,
            .element_ty = self.llvmType(array_ty.child.*) catch return null,
        };
        var scan_index = literal_index + 1;
        while (result.item_count < item_count) {
            while (scan_index < block.instructions.len) : (scan_index += 1) {
                const instruction = block.instructions[scan_index];
                if (instruction.kind == .return_value) return null;
                if (instruction.kind == .target_type or instruction.kind == .integer_literal_conversion) continue;
                if (instruction.kind != .expr and instruction.kind != .call and instruction.kind != .binary and instruction.kind != .unary) return null;
                if ((instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary) and !self.noFunctionBodyFallbacksAvailable()) return null;
                const value_source = instructionSourcePoint(instruction);
                result.items[result.item_count] = self.simpleMirCallArgAt(function, fn_mir, value_source) orelse return null;
                result.item_count += 1;
                scan_index += 1;
                if (instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary) {
                    while (scan_index < block.instructions.len and !simpleMirLiteralBoundaryInstruction(block.instructions[scan_index])) : (scan_index += 1) {}
                } else {
                    while (scan_index < block.instructions.len and sameMirSourceLocation(instructionSourcePoint(block.instructions[scan_index]), value_source)) : (scan_index += 1) {}
                }
                break;
            } else return null;
        }
        return result;
    }

    fn simpleMirParamFieldReturn(self: *LlvmEmitter, function: anytype, block: mir.Block, ret: mir.Instruction, field_name: []const u8) ?SimpleMirParamField {
        var field_source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, field_name)) continue;
            const source = instructionSourcePoint(instruction);
            field_source = source;
        }
        const source = field_source orelse return null;
        return self.simpleMirParamFieldAtSource(function, block, source, field_name, ret.result_ty.name());
    }

    fn simpleMirParamFieldAtSource(self: *LlvmEmitter, function: anytype, block: mir.Block, source: mir.SourcePoint, field_name_filter: ?[]const u8, expected_type_name: ?[]const u8) ?SimpleMirParamField {
        for (function.signature.params) |param| {
            if (!simpleMirBlockHasExprAt(block, param.name.text, source)) continue;
            const struct_name = type_bridge.typeName(self.resolveAliasType(param.ty)) orelse continue;
            const struct_decl = self.struct_types.get(struct_name) orelse continue;
            for (struct_decl.fields, 0..) |field, index| {
                if (field_name_filter) |field_name| {
                    if (!std.mem.eql(u8, field.name.text, field_name)) continue;
                }
                if (!simpleMirBlockHasExprAt(block, field.name.text, source)) continue;
                const field_type_name = type_bridge.typeName(self.resolveAliasType(field.ty)) orelse return null;
                if (expected_type_name) |expected| {
                    if (!std.mem.eql(u8, field_type_name, expected)) continue;
                }
                return .{
                    .param_name = param.name.text,
                    .field_name = field.name.text,
                    .field_index = index,
                    .struct_name = struct_name,
                };
            }
        }
        return null;
    }

    fn simpleMirExprCouldBeParamField(self: *LlvmEmitter, function: anytype, block: mir.Block, field_name: []const u8, source: mir.SourcePoint) bool {
        return self.simpleMirParamFieldAtSource(function, block, source, field_name, null) != null;
    }

    fn simpleMirParamFieldValueAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirParamField {
        const fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        for (fn_mir.blocks) |block| {
            if (self.simpleMirParamFieldAtSource(function, block, source, null, fact.result_ty.name())) |field| return field;
        }
        return null;
    }

    fn simpleMirNoTrap(fn_mir: mir.Function) bool {
        return fn_mir.blocks.len == 1 and fn_mir.trap_edges.len == 0;
    }

    fn simpleMirVoidBody(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirVoidBody {
        if (fn_mir.return_ty != .void) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        if (self.simpleMirConditionalEmptyVoidCalls(function, fn_mir)) |calls| {
            if (calls.count == 1) return .{ .direct_call = calls.calls[0] };
            return .{ .direct_calls = calls };
        }
        if (self.simpleMirConditionalEmptyVoidBody(function, fn_mir)) return .empty;
        if (self.simpleMirConditionalVoidStatements(function, fn_mir)) |conditional| return .{ .conditional_statements = conditional };
        if (self.simpleMirConditionalVoidBody(function, fn_mir)) |conditional| return .{ .conditional_direct_calls = conditional };
        if (self.simpleMirLoopVoidBody(function, fn_mir)) |loop| return .{ .loop_statements = loop };
        const block = fn_mir.blocks[0];
        if (block.terminator != .fallthrough) return null;
        if (!self.blockOnlyContainsSimpleMirReturnInstructions(function, fn_mir)) return null;
        if (self.simpleMirVoidStatements(function, fn_mir, block)) |statements| return .{ .statements = statements };
        if (self.simpleMirDirectVoidCallsInBlock(function, fn_mir, block, false)) |calls| {
            if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(calls)) return null;
            if (calls.count == 1) return .{ .direct_call = calls.calls[0] };
            if (calls.count > 1) return .{ .direct_calls = calls };
        }
        const call_source = self.simpleMirCallSource(fn_mir) orelse return if (simpleMirEmptyVoidBlock(function, fn_mir, block)) .empty else null;
        if (!simpleMirDirectCallResultVoid(fn_mir, call_source)) return null;
        const call = self.simpleMirDirectCallAtSource(function, fn_mir, call_source) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallTrapCount(call)) return null;
        return .{ .direct_call = call };
    }

    fn simpleMirConditionalEmptyVoidBody(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) bool {
        if (fn_mir.blocks.len != 4 or fn_mir.trap_edges.len != 0 or fn_mir.pointer_provenance_facts.len != 0) return false;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return false;
        _ = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return false;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .fallthrough or !simpleMirEmptyVoidBlock(function, fn_mir, after_block)) return false;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return false;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (then_block.terminator != .jump or else_block.terminator != .jump) return false;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return false;
        return self.simpleMirEntrySwitchBlockIsPure(function, entry) and
            simpleMirEmptyVoidBlock(function, fn_mir, then_block) and
            simpleMirEmptyVoidBlock(function, fn_mir, else_block);
    }

    fn simpleMirLoopVoidBody(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirLoopVoidBody {
        if (fn_mir.return_ty != .void) return null;
        if (fn_mir.blocks.len != 3 or fn_mir.pointer_provenance_facts.len != 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .branch or entry.successors.len != 2) return null;
        if (simpleMirBlockHasCall(entry)) return null;
        const condition = self.simpleMirLoopCondition(function, fn_mir, entry) orelse return null;
        const body_index = entry.successors[0];
        const after_index = entry.successors[1];
        if (body_index >= fn_mir.blocks.len or after_index >= fn_mir.blocks.len) return null;
        const body_block = fn_mir.blocks[body_index];
        const after_block = fn_mir.blocks[after_index];
        if (!std.mem.eql(u8, body_block.kind, "loop_body") or !std.mem.eql(u8, after_block.kind, "loop_after")) return null;
        if (body_block.terminator != .jump or body_block.terminator.jump != body_index) return null;
        if (after_block.terminator != .fallthrough or !simpleMirEmptyVoidBlock(function, fn_mir, after_block)) return null;
        const body_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, body_block) orelse return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, body_block)) return null;
        const body_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, body_sources) orelse return null;
        if (fn_mir.trap_edges.len != body_traps) return null;
        return .{ .condition = condition, .body_block_index = body_index };
    }

    fn simpleMirConditionalEmptyVoidCalls(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirDirectCalls {
        if (fn_mir.blocks.len != 4 or fn_mir.pointer_provenance_facts.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return null;
        const prefix_calls = self.simpleMirPrefixVoidCallsBeforeSwitch(function, fn_mir, entry) orelse return null;
        if (prefix_calls.count == 0) return null;
        const condition = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return null;
        switch (condition) {
            .direct_call => return null,
            else => {},
        }
        if (!self.simpleMirEntrySwitchBlockIsPureWithPrefixVoidCalls(function, fn_mir, entry)) return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .fallthrough or !simpleMirEmptyVoidBlock(function, fn_mir, after_block)) return null;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return null;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (then_block.terminator != .jump or else_block.terminator != .jump) return null;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return null;
        if (!simpleMirEmptyVoidBlock(function, fn_mir, then_block) or !simpleMirEmptyVoidBlock(function, fn_mir, else_block)) return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls)) return null;
        return prefix_calls;
    }

    fn simpleMirConditionalVoidStatements(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalVoidStatements {
        if (fn_mir.blocks.len != 4 or fn_mir.pointer_provenance_facts.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return null;
        const prefix_calls = self.simpleMirPrefixVoidCallsBeforeSwitch(function, fn_mir, entry) orelse return null;
        const condition = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .fallthrough) return null;
        const suffix_statements = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, after_block) orelse return null;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return null;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (!std.mem.eql(u8, then_block.kind, "switch_arm") or !std.mem.eql(u8, else_block.kind, "switch_arm")) return null;
        if (then_block.terminator != .jump or else_block.terminator != .jump) return null;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return null;
        const then_statements = self.simpleMirVoidStatementsInBlock(function, fn_mir, then_block, false) orelse return null;
        const else_statements = self.simpleMirVoidStatementsInBlock(function, fn_mir, else_block, false) orelse return null;
        const then_stores = simpleMirVoidStatementsGlobalStores(then_statements);
        const else_stores = simpleMirVoidStatementsGlobalStores(else_statements);
        if (then_stores.count + else_stores.count == 0) return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, then_block)) return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, else_block)) return null;
        const suffix_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, suffix_statements) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls) + simpleMirVoidStatementsDirectCallTrapCount(then_statements) + simpleMirVoidStatementsDirectCallTrapCount(else_statements) + suffix_traps) return null;
        return .{ .prefix_calls = prefix_calls, .condition = condition, .then_statements = then_statements, .else_statements = else_statements, .suffix_statements = suffix_statements };
    }

    fn simpleMirConditionalVoidBody(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalVoidBody {
        if (fn_mir.blocks.len < 4 or fn_mir.pointer_provenance_facts.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return null;
        const prefix_calls = self.simpleMirPrefixVoidCallsBeforeSwitch(function, fn_mir, entry) orelse return null;
        const condition = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .fallthrough) return null;
        const suffix_statements = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, after_block) orelse return null;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return null;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (then_block.terminator != .jump or else_block.terminator != .jump) return null;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return null;
        const then_calls = self.simpleMirDirectVoidCallsInBlock(function, fn_mir, then_block, true) orelse return null;
        const else_calls = self.simpleMirDirectVoidCallsInBlock(function, fn_mir, else_block, true) orelse return null;
        const suffix_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, suffix_statements) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls) + simpleMirDirectCallsTrapCount(then_calls) + simpleMirDirectCallsTrapCount(else_calls) + suffix_traps) return null;
        return .{ .prefix_calls = prefix_calls, .condition = condition, .then_calls = then_calls, .else_calls = else_calls, .suffix_statements = suffix_statements };
    }

    fn simpleMirVoidStatements(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirVoidStatements {
        const result = self.simpleMirVoidStatementsInBlock(function, fn_mir, block, true) orelse return null;
        const stores = simpleMirVoidStatementsGlobalStores(result);
        if (fn_mir.trap_edges.len != simpleMirGlobalStoresTrapCount(stores) + simpleMirVoidStatementsDirectCallTrapCount(result)) return null;
        for (fn_mir.blocks, 0..) |mir_block, index| {
            if (index == 0) continue;
            if (!std.mem.eql(u8, mir_block.kind, "trap") or mir_block.terminator != .trap_) return null;
        }
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, block)) return null;
        return result;
    }

    fn simpleMirVoidStatementsInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, require_global_store: bool) ?SimpleMirVoidStatements {
        var result: SimpleMirVoidStatements = .{};
        var has_global_store = false;
        for (block.instructions) |instruction| {
            if (instruction.kind == .call) {
                const source = instructionSourcePoint(instruction);
                if (!simpleMirDirectCallResultVoid(fn_mir, source)) continue;
                if (result.count >= max_simple_mir_void_statements) return null;
                result.statements[result.count] = .{ .direct_call = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return null };
                result.count += 1;
            } else if (instruction.kind == .assign and !mirFunctionHasLocal(fn_mir, instruction.detail)) {
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) return null;
                }
                if (!self.global_types.contains(instruction.detail)) return null;
                if (result.count >= max_simple_mir_void_statements) return null;
                const name = instruction.detail;
                const value_source = self.simpleMirAssignmentSourceInBlock(block, name) orelse return null;
                result.statements[result.count] = .{ .global_store = .{
                    .name = name,
                    .value = self.simpleMirGlobalStoreValueAtSource(function, fn_mir, value_source) orelse return null,
                    .source = instructionSourcePoint(instruction),
                } };
                result.count += 1;
                has_global_store = true;
            }
        }
        if (require_global_store and !has_global_store) return null;
        return result;
    }

    fn simpleMirVoidStatementsGlobalStores(statements: SimpleMirVoidStatements) SimpleMirGlobalStores {
        var stores: SimpleMirGlobalStores = .{};
        for (statements.statements[0..statements.count]) |statement| switch (statement) {
            .global_store => |store| {
                if (stores.count < max_simple_mir_global_stores) {
                    stores.stores[stores.count] = store;
                    stores.count += 1;
                }
            },
            .direct_call => {},
        };
        return stores;
    }

    fn simpleMirVoidStatementsDirectCallTrapCount(statements: SimpleMirVoidStatements) usize {
        var count: usize = 0;
        for (statements.statements[0..statements.count]) |statement| switch (statement) {
            .direct_call => |call| count += simpleMirDirectCallTrapCount(call),
            .global_store => {},
        };
        return count;
    }

    fn simpleMirGlobalStoreValueAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, value_source: mir.SourcePoint) ?SimpleMirGlobalStoreValue {
        return if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, value_source)) |binary|
            .{ .checked_binary = binary }
        else if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, value_source)) |unary|
            .{ .checked_unary = unary }
        else if (self.simpleMirCompareBinaryAtSource(function, fn_mir, value_source)) |binary|
            .{ .compare_binary = binary }
        else if (self.simpleMirLogicalNotAtSource(function, fn_mir, value_source)) |arg|
            .{ .logical_not = arg }
        else if (self.simpleMirDirectCallAtSource(function, fn_mir, value_source)) |call|
            .{ .direct_call = call }
        else if (self.simpleMirArgAt(function, fn_mir, value_source)) |arg|
            .{ .arg = arg }
        else if (self.simpleMirGlobalAtSource(function, fn_mir, value_source)) |source_name|
            .{ .global_load = source_name }
        else
            return null;
    }

    fn simpleMirGlobalStoreValueTrapCount(value: SimpleMirGlobalStoreValue) usize {
        return switch (value) {
            .checked_binary => |binary| simpleMirCheckedBinaryTrapCount(binary),
            .checked_unary => 1,
            .direct_call => |call| simpleMirDirectCallTrapCount(call),
            else => 0,
        };
    }

    fn simpleMirGlobalStoresTrapCount(stores: SimpleMirGlobalStores) usize {
        var count: usize = 0;
        for (stores.stores[0..stores.count]) |store| count += simpleMirGlobalStoreValueTrapCount(store.value);
        return count;
    }

    fn blockOnlyContainsSimpleMirVoidStatementInstructions(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .target_type, .integer_literal_conversion, .add_overflow, .return_value => {},
            .assign => {
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) {
                    const source = self.simpleMirAssignmentSourceInBlock(block, instruction.detail) orelse return false;
                    if (self.simpleMirArgAt(function, fn_mir, source) == null) return false;
                    continue;
                }
                if (!self.global_types.contains(instruction.detail)) return false;
            },
            .binary => {
                const source = instructionSourcePoint(instruction);
                if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
                    self.simpleMirCompareBinaryAtSource(function, fn_mir, source) == null) return false;
            },
            .unary => {
                const source = instructionSourcePoint(instruction);
                if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source) == null and
                    self.simpleMirLogicalNotAtSource(function, fn_mir, source) == null) return false;
            },
            .call => {
                const source = instructionSourcePoint(instruction);
                if (self.simpleMirDirectCallAtSource(function, fn_mir, source) == null) return false;
            },
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or
                    std.mem.eql(u8, instruction.detail, "bool") or
                    std.mem.eql(u8, instruction.detail, "literal")) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else {
                    if (mirBlockHasLocal(block, instruction.detail)) continue;
                    if (mirBlockHasCall(block, instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.global_types.contains(instruction.detail)) continue;
                    return false;
                }
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirConditionalReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalReturn {
        if (fn_mir.return_ty == .void) return null;
        if (fn_mir.blocks.len < 4 or fn_mir.pointer_provenance_facts.len != 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return null;
        const prefix_calls = self.simpleMirPrefixVoidCallsBeforeSwitch(function, fn_mir, entry) orelse return null;
        const condition = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return null;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return null;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (!std.mem.eql(u8, then_block.kind, "switch_arm") or !std.mem.eql(u8, else_block.kind, "switch_arm")) return null;
        const direct_then_value = self.simpleMirReturnValueInBlock(function, fn_mir, then_block);
        const direct_else_value = self.simpleMirReturnValueInBlock(function, fn_mir, else_block);
        const then_value, const else_value = if (direct_then_value != null and direct_else_value != null)
            .{ direct_then_value.?, direct_else_value.? }
        else if (self.simpleMirConditionalEarlyReturn(function, fn_mir, then_block, else_block)) |early|
            early
        else
            self.simpleMirConditionalAssignedReturn(function, fn_mir, then_block, else_block) orelse return null;
        for (fn_mir.blocks, 0..) |block, index| {
            if (index == 0 or index == 1 or index == then_index or index == else_index) continue;
            if (!std.mem.eql(u8, block.kind, "trap") or block.terminator != .trap_) return null;
        }
        if (fn_mir.trap_edges.len != simpleMirConditionalTrapCount(then_value) + simpleMirConditionalTrapCount(else_value)) return null;
        return .{ .prefix_calls = prefix_calls, .condition = condition, .then_value = then_value, .else_value = else_value };
    }

    fn simpleMirConditionalStatementReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalStatementReturn {
        if (fn_mir.return_ty == .void) return null;
        if (fn_mir.blocks.len < 3 or fn_mir.pointer_provenance_facts.len != 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_ or entry.successors.len != 2) return null;
        const prefix_calls = self.simpleMirPrefixVoidCallsBeforeSwitch(function, fn_mir, entry) orelse return null;
        const condition = self.simpleMirSwitchConditionParam(function, fn_mir, entry) orelse return null;
        const then_index = entry.successors[0];
        const else_index = entry.successors[1];
        if (then_index >= fn_mir.blocks.len or else_index >= fn_mir.blocks.len) return null;
        const then_block = fn_mir.blocks[then_index];
        const else_block = fn_mir.blocks[else_index];
        if (!std.mem.eql(u8, then_block.kind, "switch_arm") or !std.mem.eql(u8, else_block.kind, "switch_arm")) return null;
        const then_statement_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, then_block) orelse return null;
        const else_statement_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, else_block) orelse return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, then_block)) return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, else_block)) return null;
        const then_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, then_statement_sources) orelse return null;
        const else_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, else_statement_sources) orelse return null;

        if (then_block.terminator == .return_ and else_block.terminator == .return_) {
            if (then_statement_sources.count + else_statement_sources.count == 0) return null;
            const then_value = self.simpleMirReturnValueInBlock(function, fn_mir, then_block) orelse return null;
            const else_value = self.simpleMirReturnValueInBlock(function, fn_mir, else_block) orelse return null;
            for (fn_mir.blocks, 0..) |block, index| {
                if (index == 0 or index == then_index or index == else_index) continue;
                if (std.mem.eql(u8, block.kind, "switch_after") and block.terminator == .fallthrough and simpleMirEmptyVoidBlock(function, fn_mir, block)) continue;
                if (!std.mem.eql(u8, block.kind, "trap") or block.terminator != .trap_) return null;
            }
            if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls) + then_traps + else_traps + simpleMirConditionalTrapCount(then_value) + simpleMirConditionalTrapCount(else_value)) return null;
            return .{ .prefix_calls = prefix_calls, .condition = condition, .then_block_index = then_index, .else_block_index = else_index, .result = .branch };
        }

        if (fn_mir.blocks.len != 4) return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .return_) return null;
        const then_jumps_after = switch (then_block.terminator) {
            .jump => |target| target == 1,
            else => false,
        };
        const else_jumps_after = switch (else_block.terminator) {
            .jump => |target| target == 1,
            else => false,
        };
        const suffix_statement_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, after_block) orelse return null;
        if ((then_block.terminator == .return_ and else_jumps_after) or (else_block.terminator == .return_ and then_jumps_after)) {
            const after_value = self.simpleMirReturnValueInBlock(function, fn_mir, after_block) orelse return null;
            const then_value_traps = if (then_block.terminator == .return_) simpleMirConditionalTrapCount(self.simpleMirReturnValueInBlock(function, fn_mir, then_block) orelse return null) else 0;
            const else_value_traps = if (else_block.terminator == .return_) simpleMirConditionalTrapCount(self.simpleMirReturnValueInBlock(function, fn_mir, else_block) orelse return null) else 0;
            const suffix_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, suffix_statement_sources) orelse return null;
            if (then_statement_sources.count + else_statement_sources.count + suffix_statement_sources.count == 0) return null;
            if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls) + then_traps + else_traps + suffix_traps + then_value_traps + else_value_traps + simpleMirConditionalTrapCount(after_value)) return null;
            return .{ .prefix_calls = prefix_calls, .condition = condition, .then_block_index = then_index, .else_block_index = else_index, .result = .mixed, .suffix_block_index = 1 };
        }
        if (then_block.terminator != .jump or else_block.terminator != .jump) return null;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return null;
        const value = self.simpleMirReturnValueInBlock(function, fn_mir, after_block) orelse return null;
        if (!self.blockOnlyContainsSimpleMirReturnInstructions(function, fn_mir)) return null;
        const suffix_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, suffix_statement_sources) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallsTrapCount(prefix_calls) + then_traps + else_traps + suffix_traps + simpleMirConditionalTrapCount(value)) return null;
        return .{ .prefix_calls = prefix_calls, .condition = condition, .then_block_index = then_index, .else_block_index = else_index, .result = .after, .suffix_block_index = 1 };
    }

    fn simpleMirConditionalEarlyReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, then_block: mir.Block, else_block: mir.Block) ?struct { SimpleMirConditionalValue, SimpleMirConditionalValue } {
        if (fn_mir.trap_edges.len != 0) return null;
        if (fn_mir.blocks.len != 4) return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .return_) return null;
        const after_value = self.simpleMirReturnValueInBlock(function, fn_mir, after_block) orelse return null;
        const then_value = self.simpleMirEarlyReturnValueInBlock(function, fn_mir, then_block, after_value) orelse return null;
        const else_value = self.simpleMirEarlyReturnValueInBlock(function, fn_mir, else_block, after_value) orelse return null;
        if (then_block.terminator == .jump and else_block.terminator == .jump) return null;
        return .{ then_value, else_value };
    }

    fn simpleMirEarlyReturnValueInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, after_value: SimpleMirConditionalValue) ?SimpleMirConditionalValue {
        return switch (block.terminator) {
            .return_ => self.simpleMirReturnValueInBlock(function, fn_mir, block),
            .jump => |target| if (target == 1) after_value else null,
            else => null,
        };
    }

    fn simpleMirConditionalAssignedReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, then_block: mir.Block, else_block: mir.Block) ?struct { SimpleMirConditionalValue, SimpleMirConditionalValue } {
        if (fn_mir.trap_edges.len != 0) return null;
        if (fn_mir.blocks.len != 4) return null;
        const after_block = fn_mir.blocks[1];
        if (after_block.terminator != .return_) return null;
        if (then_block.terminator != .jump or else_block.terminator != .jump) return null;
        if (then_block.terminator.jump != 1 or else_block.terminator.jump != 1) return null;
        const ret = simpleMirReturnInstruction(after_block) orelse return null;
        const local_name = ret.value_id orelse return null;
        if (!mirBlockHasLocal(fn_mir.blocks[0], local_name)) return null;
        const initial_source = self.simpleMirLocalInitSource(fn_mir, local_name) orelse return null;
        const initial_value = self.simpleMirConditionalValueAtSource(function, fn_mir, initial_source) orelse return null;
        const then_value = self.simpleMirAssignedValueInBlock(function, fn_mir, then_block, local_name) orelse initial_value;
        const else_value = self.simpleMirAssignedValueInBlock(function, fn_mir, else_block, local_name) orelse initial_value;
        return .{ then_value, else_value };
    }

    fn simpleMirLoopReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirLoopReturn {
        if (fn_mir.return_ty == .void) return null;
        if (fn_mir.blocks.len < 3 or fn_mir.pointer_provenance_facts.len != 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .branch or entry.successors.len != 2) return null;
        if (simpleMirBlockHasCall(entry)) return null;
        const condition = self.simpleMirLoopCondition(function, fn_mir, entry) orelse return null;
        const body_index = entry.successors[0];
        const after_index = entry.successors[1];
        if (body_index >= fn_mir.blocks.len or after_index >= fn_mir.blocks.len) return null;
        for (fn_mir.blocks, 0..) |block, index| {
            if (index == 0 or index == body_index or index == after_index) continue;
            if (!std.mem.eql(u8, block.kind, "trap") or block.terminator != .trap_) return null;
        }
        const body_block = fn_mir.blocks[body_index];
        const after_block = fn_mir.blocks[after_index];
        if (!std.mem.eql(u8, body_block.kind, "loop_body") or !std.mem.eql(u8, after_block.kind, "loop_after")) return null;
        if (body_block.terminator != .jump or body_block.terminator.jump != body_index) return null;
        if (after_block.terminator != .return_) return null;
        const body_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, body_block) orelse return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, body_block)) return null;
        if (!self.blockOnlyContainsSimpleMirReturnInstructionsInBlock(function, fn_mir, after_block)) return null;
        const after_value = self.simpleMirReturnValueInBlock(function, fn_mir, after_block) orelse return null;
        const body_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, body_sources) orelse return null;
        if (fn_mir.trap_edges.len != body_traps + simpleMirConditionalTrapCount(after_value)) return null;
        return .{ .condition = condition, .body_block_index = body_index, .after_block_index = after_index };
    }

    fn simpleMirLoopCondition(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirCondition {
        var saw_loop_marker = false;
        var index: usize = 0;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            if (!saw_loop_marker) {
                saw_loop_marker = instruction.kind == .binary and std.mem.eql(u8, instruction.detail, "while");
                continue;
            }
            switch (instruction.kind) {
                .target_type => continue,
                .unary => {
                    if (!std.mem.eql(u8, instruction.detail, "logical_not")) return null;
                    var operand_index = index + 1;
                    while (operand_index < block.instructions.len) : (operand_index += 1) {
                        const operand = block.instructions[operand_index];
                        if (operand.kind == .target_type) continue;
                        if (operand.kind != .expr or operand.result_ty != .bool) return null;
                        for (function.signature.params) |param| {
                            if (std.mem.eql(u8, operand.detail, param.name.text)) return .{ .param = .{ .name = param.name.text, .inverted = true } };
                        }
                        if (self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(operand))) |arg| {
                            return switch (arg) {
                                .param_field => |field| .{ .param_field = .{ .field = field, .inverted = true } },
                                else => null,
                            };
                        }
                        return null;
                    }
                    return null;
                },
                .binary => {
                    if (self.simpleMirCompareBinaryAtSource(function, fn_mir, instructionSourcePoint(instruction))) |binary| return .{ .compare_binary = binary };
                    return null;
                },
                .call => {
                    if (self.simpleMirNestedCallAtSource(function, fn_mir, instructionSourcePoint(instruction))) |call| {
                        if (self.simpleMirNestedCallReturnsBool(call)) return .{ .direct_call = call };
                    }
                    return null;
                },
                .expr => {
                    if (instruction.result_ty != .bool) return null;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) return .{ .param = .{ .name = param.name.text } };
                    }
                    if (mirBlockHasLocal(block, instruction.detail)) {
                        return self.simpleMirLocalCondition(function, fn_mir, instruction.detail);
                    }
                    if (self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction))) |arg| {
                        return switch (arg) {
                            .param_field => |field| .{ .param_field = .{ .field = field } },
                            .bool_literal => |value| .{ .bool_literal = value },
                            else => null,
                        };
                    }
                    return null;
                },
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirSwitchConditionParam(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirCondition {
        const subject_index = simpleMirSwitchSubjectIndex(block) orelse return null;
        var index: usize = subject_index + 1;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            switch (instruction.kind) {
                .target_type => continue,
                .unary => {
                    if (!std.mem.eql(u8, instruction.detail, "logical_not")) return null;
                    var operand_index = index + 1;
                    while (operand_index < block.instructions.len) : (operand_index += 1) {
                        const operand = block.instructions[operand_index];
                        if (operand.kind == .target_type) continue;
                        if (operand.kind != .expr or operand.result_ty != .bool) return null;
                        for (function.signature.params) |param| {
                            if (std.mem.eql(u8, operand.detail, param.name.text)) return .{ .param = .{ .name = param.name.text, .inverted = true } };
                        }
                        if (self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(operand))) |arg| {
                            return switch (arg) {
                                .param_field => |field| .{ .param_field = .{ .field = field, .inverted = true } },
                                else => null,
                            };
                        }
                        return null;
                    }
                    return null;
                },
                .binary => {
                    if (self.simpleMirCompareBinaryAtSource(function, fn_mir, instructionSourcePoint(instruction))) |binary| return .{ .compare_binary = binary };
                    return null;
                },
                .call => {
                    if (self.simpleMirNestedCallAtSource(function, fn_mir, instructionSourcePoint(instruction))) |call| {
                        if (self.simpleMirNestedCallReturnsBool(call)) return .{ .direct_call = call };
                    }
                    return null;
                },
                .expr => {
                    if (instruction.result_ty != .bool) return null;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) return .{ .param = .{ .name = param.name.text } };
                    }
                    if (mirBlockHasLocal(block, instruction.detail)) {
                        return self.simpleMirLocalCondition(function, fn_mir, instruction.detail);
                    }
                    if (self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction))) |arg| {
                        return switch (arg) {
                            .param_field => |field| .{ .param_field = .{ .field = field } },
                            .bool_literal => |value| .{ .bool_literal = value },
                            else => null,
                        };
                    }
                    return null;
                },
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirLocalCondition(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirCondition {
        const init_source = self.simpleMirAssignmentSource(fn_mir, local_name) orelse
            self.simpleMirLocalInitSource(fn_mir, local_name) orelse return null;
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, init_source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirNestedCallAtSource(function, fn_mir, init_source)) |call| {
            if (self.simpleMirNestedCallReturnsBool(call)) return .{ .direct_call = call };
        }
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, init_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = .{ .name = name, .inverted = true } },
                .param_field => |field| .{ .param_field = .{ .field = field, .inverted = true } },
                else => null,
            };
        }
        if (self.simpleMirArgAt(function, fn_mir, init_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = .{ .name = name } },
                .param_field => |field| .{ .param_field = .{ .field = field } },
                .bool_literal => |value| .{ .bool_literal = value },
                else => null,
            };
        }
        return null;
    }

    fn simpleMirSwitchSubjectIndex(block: mir.Block) ?usize {
        for (block.instructions, 0..) |instruction, index| {
            if (instruction.kind == .binary and std.mem.eql(u8, instruction.detail, "switch_subject")) return index;
        }
        return null;
    }

    fn emitSimpleMirCondition(self: *LlvmEmitter, condition: SimpleMirCondition, span: diagnostics.Span) ![]const u8 {
        return switch (condition) {
            .param => |param| try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{param.name}),
            .param_field => |param_field| try self.emitSimpleMirParamFieldValue(param_field.field, span),
            .bool_literal => |value| if (value) "1" else "0",
            .direct_call => |call| blk: {
                const tmp = try self.nextTemp();
                try self.emitSimpleMirNestedCall(call, tmp, span);
                break :blk tmp;
            },
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary, span),
        };
    }

    fn simpleMirConditionInverted(condition: SimpleMirCondition) bool {
        return switch (condition) {
            .param => |param| param.inverted,
            .param_field => |param_field| param_field.inverted,
            .bool_literal, .direct_call, .compare_binary => false,
        };
    }

    fn simpleMirReturnValueInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirConditionalValue {
        if (block.terminator != .return_) return null;
        const ret = simpleMirReturnInstruction(block) orelse return null;
        const value_id = ret.value_id orelse return null;
        for (function.signature.params) |param| {
            if (std.mem.eql(u8, value_id, param.name.text)) return .{ .param = param.name.text };
        }
        if (self.simpleMirParamFieldReturn(function, block, ret, value_id)) |field| return .{ .param_field = field };
        if (mirBlockHasLocal(block, value_id)) {
            return self.simpleMirLocalValueInBlock(function, fn_mir, block, value_id);
        }
        if (self.global_types.contains(value_id)) return .{ .global_load = value_id };
        var literal_source: ?mir.SourcePoint = null;
        if (std.mem.eql(u8, value_id, "int") or std.mem.eql(u8, value_id, "bool")) {
            for (block.instructions) |instruction| {
                if (instruction.kind == .return_value) break;
                if (instruction.kind == .integer_literal_conversion or
                    (instruction.kind == .expr and (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "bool"))))
                {
                    literal_source = instructionSourcePoint(instruction);
                }
            }
        }
        if (literal_source) |source| {
            return switch (self.simpleMirArgAt(function, fn_mir, source) orelse return null) {
                .param => |name| .{ .param = name },
                .param_field => |field| .{ .param_field = field },
                .integer_literal => |literal| .{ .integer_literal = literal },
                .bool_literal => |value| .{ .bool_literal = value },
            };
        }
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) |literal| return .{ .enum_literal = literal };
        if (simpleMirNullLiteralAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) return .null_literal;
        for (block.instructions) |instruction| {
            if (instruction.kind != .call or !std.mem.eql(u8, instruction.detail, value_id)) continue;
            const call = self.simpleMirDirectCallAtSource(function, fn_mir, instructionSourcePoint(instruction)) orelse return null;
            return .{ .direct_call = call };
        }
        if (std.mem.eql(u8, value_id, "struct_literal")) {
            if (self.simpleMirStructLiteralReturn(function, fn_mir, block)) |literal| return .{ .struct_literal = literal };
            return null;
        }
        if (std.mem.eql(u8, value_id, "array_literal")) {
            if (self.simpleMirArrayLiteralReturn(function, fn_mir, block)) |literal| return .{ .array_literal = literal };
            return null;
        }
        if (std.mem.eql(u8, value_id, "binary")) {
            for (block.instructions) |instruction| {
                if (instruction.kind != .binary) continue;
                if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, instructionSourcePoint(instruction))) |binary| return .{ .checked_binary = binary };
                if (self.simpleMirCompareBinaryAtSource(function, fn_mir, instructionSourcePoint(instruction))) |binary| return .{ .compare_binary = binary };
                return null;
            }
        }
        if (std.mem.eql(u8, value_id, "unary")) {
            for (block.instructions) |instruction| {
                if (instruction.kind != .unary) continue;
                if (self.simpleMirLogicalNotAtSource(function, fn_mir, instructionSourcePoint(instruction))) |arg| return .{ .logical_not = arg };
                if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, instructionSourcePoint(instruction))) |unary| return .{ .checked_unary = unary };
                return null;
            }
        }
        return null;
    }

    fn simpleMirConditionalValueAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirConditionalValue {
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, source)) |call| return .{ .direct_call = call };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirStructLiteralAtSource(function, fn_mir, source)) |literal| return .{ .struct_literal = literal };
        if (self.simpleMirArrayLiteralAtSource(function, fn_mir, source)) |literal| return .{ .array_literal = literal };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, source)) |literal| return .{ .enum_literal = literal };
        if (simpleMirNullLiteralAtSource(fn_mir, source)) return .null_literal;
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, source)) |field| return .{ .param_field = field };
        if (self.simpleMirGlobalAtSource(function, fn_mir, source)) |name| return .{ .global_load = name };
        return switch (self.simpleMirArgAt(function, fn_mir, source) orelse return null) {
            .param => |name| .{ .param = name },
            .param_field => |field| .{ .param_field = field },
            .integer_literal => |literal| .{ .integer_literal = literal },
            .bool_literal => |value| .{ .bool_literal = value },
        };
    }

    fn simpleMirStructLiteralAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirStructLiteralReturn {
        for (fn_mir.blocks) |block| {
            for (block.instructions, 0..) |instruction, index| {
                if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, "struct_literal")) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirStructLiteralFromBlockAtIndex(function, fn_mir, block, index, source);
            }
        }
        return null;
    }

    fn simpleMirArrayLiteralAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArrayLiteralReturn {
        for (fn_mir.blocks) |block| {
            for (block.instructions, 0..) |instruction, index| {
                if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, "array_literal")) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirArrayLiteralFromBlockAtIndex(function, fn_mir, block, index, source);
            }
        }
        return null;
    }

    fn emitSimpleMirConditionalReturnValue(self: *LlvmEmitter, ret_ty: anytype, value: SimpleMirConditionalValue, span: diagnostics.Span) !void {
        switch (value) {
            .param => |name| try self.emitReturnValue(ret_ty, try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{name}), span),
            .param_field => |field| {
                const tmp = try self.emitSimpleMirParamFieldValue(field, span);
                try self.emitReturnValue(ret_ty, tmp, span);
            },
            .integer_literal => |literal| try self.emitReturnValue(ret_ty, literal, span),
            .bool_literal => |bool_value| try self.emitReturnValue(ret_ty, if (bool_value) "1" else "0", span),
            .global_load => |name| {
                const value_name = try self.emitSimpleMirGlobalLoad(name, ret_ty);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .direct_call => |call| {
                const tmp = try self.nextTemp();
                try self.emitSimpleMirDirectCall(call, tmp, span);
                try self.emitReturnValue(ret_ty, tmp, span);
            },
            .checked_binary => |binary| {
                const value_name = try self.emitSimpleMirCheckedBinary(binary, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .checked_unary => |unary| {
                const value_name = try self.emitSimpleMirCheckedUnary(unary, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .compare_binary => |binary| {
                const value_name = try self.emitSimpleMirCompareBinary(binary, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .enum_literal => |literal| {
                const enum_decl = self.enum_types.get(literal.enum_name) orelse return error.UnsupportedLlvmEmission;
                try self.emitReturnValue(ret_ty, try self.enumCaseValueByName(enum_decl, literal.case_name), span);
            },
            .null_literal => try self.emitReturnValue(ret_ty, "zeroinitializer", span),
            .logical_not => |arg| {
                const value_name = try self.emitSimpleMirLogicalNot(arg, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .struct_literal => |literal| {
                const value_name = try self.emitSimpleMirStructLiteralReturn(literal, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
            .array_literal => |literal| {
                const value_name = try self.emitSimpleMirArrayLiteralReturn(literal, span);
                try self.emitReturnValue(ret_ty, value_name, span);
            },
        }
    }

    fn emitSimpleMirDirectCalls(self: *LlvmEmitter, calls: SimpleMirDirectCalls, span: diagnostics.Span) !void {
        for (calls.calls[0..calls.count]) |call| {
            try self.emitSimpleMirDirectCall(call, null, span);
        }
    }

    fn emitSimpleMirVoidStatements(self: *LlvmEmitter, statements: SimpleMirVoidStatements, default_span: diagnostics.Span) !diagnostics.Span {
        var return_span = default_span;
        for (statements.statements[0..statements.count]) |statement| switch (statement) {
            .direct_call => |call| {
                try self.emitSimpleMirDirectCall(call, null, default_span);
            },
            .global_store => |store| {
                const span = spanFromMirSourcePoint(store.source);
                return_span = span;
                const global_ty = self.global_types.get(store.name) orelse return error.UnsupportedLlvmEmission;
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{store.name});
                try self.emitOrdinaryStore(global_ty, try self.llvmType(global_ty), try self.simpleMirGlobalStoreValue(store.value, global_ty, span), ptr, true);
            },
        };
        return return_span;
    }

    fn emitSimpleMirVoidStatementSources(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, statements: SimpleMirVoidStatementSources, default_span: diagnostics.Span) !diagnostics.Span {
        var return_span = default_span;
        for (statements.sources[0..statements.count]) |statement| switch (statement) {
            .direct_call => |source| {
                const call = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return error.UnsupportedLlvmEmission;
                try self.emitSimpleMirDirectCall(call, null, default_span);
            },
            .global_store => |store| {
                const span = spanFromMirSourcePoint(store.source);
                return_span = span;
                const global_ty = self.global_types.get(store.name) orelse return error.UnsupportedLlvmEmission;
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{store.name});
                const value = self.simpleMirGlobalStoreValueAtSource(function, fn_mir, store.value_source) orelse return error.UnsupportedLlvmEmission;
                try self.emitOrdinaryStore(global_ty, try self.llvmType(global_ty), try self.simpleMirGlobalStoreValue(value, global_ty, span), ptr, true);
            },
        };
        return return_span;
    }

    fn simpleMirConditionalTrapCount(value: SimpleMirConditionalValue) usize {
        return switch (value) {
            .checked_binary => |binary| simpleMirCheckedBinaryTrapCount(binary),
            .checked_unary => 1,
            .direct_call => |call| simpleMirDirectCallTrapCount(call),
            else => 0,
        };
    }

    fn simpleMirReturnAllowsTrapBlocks(self: *const LlvmEmitter, fn_mir: mir.Function, ret: SimpleMirReturn) bool {
        return switch (ret) {
            .direct_call => |call| fn_mir.trap_edges.len == simpleMirDirectCallTrapCount(call),
            .checked_integer_literal => fn_mir.trap_edges.len == 1,
            .checked_binary => |binary| fn_mir.trap_edges.len == simpleMirCheckedBinaryTrapCount(binary) and (self.noFunctionBodyFallbacksAvailable() or simpleMirCheckedBinaryUsesParamField(binary)),
            .checked_unary => |unary| fn_mir.trap_edges.len == 1 and (self.noFunctionBodyFallbacksAvailable() or simpleMirArgUsesParamField(unary.operand)),
            .struct_literal => |literal| fn_mir.trap_edges.len == simpleMirStructLiteralTrapCount(literal),
            .array_literal => |literal| fn_mir.trap_edges.len == simpleMirArrayLiteralTrapCount(literal),
            .enum_literal => fn_mir.trap_edges.len >= 1 and self.noFunctionBodyFallbacksAvailable(),
            else => false,
        };
    }

    fn noFunctionBodyFallbacksAvailable(self: *const LlvmEmitter) bool {
        return self.function_bodies.function_body_fallbacks.len == 0;
    }

    fn simpleMirLiteralBoundaryInstruction(instruction: mir.Instruction) bool {
        return instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary or instruction.kind == .return_value;
    }

    fn simpleMirCheckedBinaryUsesParamField(binary: SimpleMirCheckedBinary) bool {
        return simpleMirArgUsesParamField(binary.left) or simpleMirArgUsesParamField(binary.right);
    }

    fn simpleMirArgUsesParamField(arg: SimpleMirArg) bool {
        return switch (arg) {
            .param_field => true,
            else => false,
        };
    }

    fn simpleMirCallArgTrapCount(arg: SimpleMirCallArg) usize {
        return switch (arg) {
            .direct_call => 0,
            .checked_binary => |binary| simpleMirCheckedBinaryTrapCount(binary),
            .checked_unary => 1,
            else => 0,
        };
    }

    fn simpleMirCheckedBinaryTrapCount(binary: SimpleMirCheckedBinary) usize {
        if (std.mem.eql(u8, binary.op, "div") or std.mem.eql(u8, binary.op, "mod")) {
            return if (simpleMirSignedIntegerTypeName(typeName(binary.target_fact.target_ty) orelse "")) 2 else 1;
        }
        if (std.mem.eql(u8, binary.op, "shl")) return 2;
        return 1;
    }

    fn simpleMirStructLiteralTrapCount(literal: SimpleMirStructLiteralReturn) usize {
        var count: usize = 0;
        for (literal.fields[0..literal.field_count]) |field| count += simpleMirCallArgTrapCount(field.value);
        return count;
    }

    fn simpleMirArrayLiteralTrapCount(literal: SimpleMirArrayLiteralReturn) usize {
        var count: usize = 0;
        for (literal.items[0..literal.item_count]) |item| count += simpleMirCallArgTrapCount(item);
        return count;
    }

    fn simpleMirDirectCallTrapCount(call: SimpleMirDirectCall) usize {
        var count: usize = 0;
        for (call.args[0..call.arg_count]) |arg| count += simpleMirCallArgTrapCount(arg);
        return count;
    }

    fn simpleMirDirectCallsTrapCount(calls: SimpleMirDirectCalls) usize {
        var count: usize = 0;
        for (calls.calls[0..calls.count]) |call| count += simpleMirDirectCallTrapCount(call);
        return count;
    }

    fn simpleMirAssignedValueInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8) ?SimpleMirConditionalValue {
        const source = self.simpleMirAssignmentSourceInBlock(block, local_name) orelse return null;
        return self.simpleMirConditionalValueAtSource(function, fn_mir, source);
    }

    fn simpleMirLocalValueInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8) ?SimpleMirConditionalValue {
        if (self.simpleMirAssignmentSourceInBlock(block, local_name)) |assigned_source| {
            return self.simpleMirConditionalValueAtSource(function, fn_mir, assigned_source);
        }
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        return self.simpleMirConditionalValueAtSource(function, fn_mir, init_source);
    }

    fn emitSimpleMirCheckedBinary(self: *LlvmEmitter, binary: SimpleMirCheckedBinary, span: diagnostics.Span) ![]const u8 {
        const ty = binary.target_fact.target_ty;
        const llvm_ty = try self.llvmType(ty);
        if (std.mem.eql(u8, binary.op, "div") or std.mem.eql(u8, binary.op, "mod")) return self.emitSimpleMirCheckedDivRem(binary, llvm_ty, span);
        if (std.mem.eql(u8, binary.op, "shl") or std.mem.eql(u8, binary.op, "shr")) return self.emitSimpleMirCheckedShift(binary, llvm_ty, span);
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const intrinsic = try self.simpleMirOverflowIntrinsic(binary.op, self.isSignedIntegerType(ty), bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.simpleMirArgValue(binary.left, span);
        const right = try self.simpleMirArgValue(binary.right, span);
        const pair = try self.nextTemp();
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, dbg_suffix });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
        return value;
    }

    fn emitSimpleMirCheckedDivRem(self: *LlvmEmitter, binary: SimpleMirCheckedBinary, llvm_ty: []const u8, span: diagnostics.Span) ![]const u8 {
        const ty = binary.target_fact.target_ty;
        _ = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const left = try self.simpleMirArgValue(binary.left, span);
        const right = try self.simpleMirArgValue(binary.right, span);
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";

        const zero_cmp = try self.nextTemp();
        const zero_trap = try self.nextLabel("trap_div_zero");
        const nonzero = try self.nextLabel("div_nonzero");
        try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, 0{s}\n", .{ zero_cmp, llvm_ty, right, dbg_suffix });
        try self.emitTrapBranch(zero_cmp, zero_trap, nonzero, zero_trap, nonzero, "DivideByZero");

        if (self.isSignedIntegerType(ty)) {
            const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
            const min_cmp = try self.nextTemp();
            const neg_one_cmp = try self.nextTemp();
            const overflow_cmp = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_div_overflow");
            const safe = try self.nextLabel("div_safe");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}{s}\n", .{ min_cmp, llvm_ty, left, min_literal, dbg_suffix });
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, -1{s}\n", .{ neg_one_cmp, llvm_ty, right, dbg_suffix });
            try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}{s}\n", .{ overflow_cmp, min_cmp, neg_one_cmp, dbg_suffix });
            try self.emitTrapBranch(overflow_cmp, overflow_trap, safe, overflow_trap, safe, "IntegerOverflow");
        }

        const value = try self.nextTemp();
        const op: []const u8 = if (std.mem.eql(u8, binary.op, "mod"))
            if (self.isSignedIntegerType(ty)) "srem" else "urem"
        else if (self.isSignedIntegerType(ty))
            "sdiv"
        else
            "udiv";
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}{s}\n", .{ value, op, llvm_ty, left, right, dbg_suffix });
        return value;
    }

    fn emitSimpleMirCheckedShift(self: *LlvmEmitter, binary: SimpleMirCheckedBinary, llvm_ty: []const u8, span: diagnostics.Span) ![]const u8 {
        const ty = binary.target_fact.target_ty;
        const shifted_bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const left = try self.simpleMirArgValue(binary.left, span);
        const amount = try self.simpleMirArgValue(binary.right, span);
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";

        const too_large = try self.nextTemp();
        const invalid = try self.nextLabel("trap_shift_count");
        const valid = try self.nextLabel("shift_count_ok");
        const pred: []const u8 = if (self.isSignedIntegerType(ty)) "sge" else "uge";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}{s}\n", .{ too_large, pred, llvm_ty, amount, shifted_bits, dbg_suffix });
        try self.emitTrapBranch(too_large, invalid, valid, invalid, valid, "InvalidShift");

        const op: []const u8 = if (std.mem.eql(u8, binary.op, "shl"))
            "shl"
        else if (self.isSignedIntegerType(ty))
            "ashr"
        else
            "lshr";
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}{s}\n", .{ result, op, llvm_ty, left, amount, dbg_suffix });

        if (std.mem.eql(u8, binary.op, "shl")) {
            const reverse_op: []const u8 = if (self.isSignedIntegerType(ty)) "ashr" else "lshr";
            const reversed = try self.nextTemp();
            const overflow = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_shift_overflow");
            const ok = try self.nextLabel("shift_overflow_ok");
            try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}{s}\n", .{ reversed, reverse_op, llvm_ty, result, amount, dbg_suffix });
            try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}{s}\n", .{ overflow, llvm_ty, reversed, left, dbg_suffix });
            try self.emitTrapBranch(overflow, overflow_trap, ok, overflow_trap, ok, "IntegerOverflow");
        }

        return result;
    }

    fn emitSimpleMirCheckedUnary(self: *LlvmEmitter, unary: SimpleMirCheckedUnary, span: diagnostics.Span) ![]const u8 {
        if (!std.mem.eql(u8, unary.op, "neg")) return error.UnsupportedLlvmEmission;
        const ty = unary.target_fact.target_ty;
        if (!self.isSignedIntegerType(ty)) return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const intrinsic = try self.simpleMirOverflowIntrinsic("sub", true, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const operand = try self.simpleMirArgValue(unary.operand, span);
        const pair = try self.nextTemp();
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} 0, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, llvm_ty, operand, dbg_suffix });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
        return value;
    }

    fn emitSimpleMirCompareBinary(self: *LlvmEmitter, binary: SimpleMirCompareBinary, span: diagnostics.Span) ![]const u8 {
        const ty = binary.operand_fact.target_ty;
        const llvm_ty = try self.llvmType(ty);
        if (!self.isBoolType(ty)) _ = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const predicate = try self.simpleMirComparePredicate(binary.op, self.isSignedIntegerType(ty));
        const left = try self.simpleMirArgValue(binary.left, span);
        const right = try self.simpleMirArgValue(binary.right, span);
        const value = try self.nextTemp();
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {s}{s}\n", .{ value, predicate, llvm_ty, left, right, dbg_suffix });
        return value;
    }

    fn emitSimpleMirLogicalNot(self: *LlvmEmitter, arg: SimpleMirArg, span: diagnostics.Span) ![]const u8 {
        const value = try self.nextTemp();
        const input = try self.simpleMirArgValue(arg, span);
        const dbg_suffix = if (try self.debugLocation(span)) |dbg|
            try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{dbg})
        else
            "";
        try self.out.print(self.allocator, "  {s} = xor i1 {s}, true{s}\n", .{ value, input, dbg_suffix });
        return value;
    }

    fn emitSimpleMirConversionReturn(self: *LlvmEmitter, conversion: SimpleMirConversionReturn, span: diagnostics.Span) ![]const u8 {
        switch (conversion.kind) {
            .conversion_from, .conversion_wrap_from, .conversion_from_mod => {},
            else => return error.UnsupportedLlvmEmission,
        }
        const operand = try self.simpleMirCallArgValue(conversion.operand, span);
        return self.castValue(operand, conversion.source_fact.target_ty, conversion.target_fact.target_ty);
    }

    fn emitSimpleMirExplicitCastReturn(self: *LlvmEmitter, cast: SimpleMirExplicitCastReturn, span: diagnostics.Span) ![]const u8 {
        const operand = try self.simpleMirCallArgValue(cast.operand, span);
        return self.castValue(operand, cast.source_fact.target_ty, cast.target_fact.target_ty);
    }

    fn emitSimpleMirResultConstructorReturn(self: *LlvmEmitter, constructor: SimpleMirResultConstructorReturn, span: diagnostics.Span) ![]const u8 {
        const info = lower_llvm_shape.resultInfo(&self.type_aliases, constructor.result_fact.target_ty) orelse return error.UnsupportedLlvmEmission;
        const result_ty = try self.llvmType(constructor.result_fact.target_ty);
        const is_ok = std.mem.eql(u8, constructor.tag, "ok");

        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, if (is_ok) "true" else "false" });

        const ok_value = if (is_ok)
            try self.simpleMirResultConstructorPayloadValue(constructor.payload, span)
        else
            try self.resultPayloadZero(info.ok_ty);
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_ty, tagged, try self.resultPayloadLlvmType(info.ok_ty), ok_value });

        const err_value = if (is_ok)
            try self.resultPayloadZero(info.err_ty)
        else
            try self.simpleMirResultConstructorPayloadValue(constructor.payload, span);
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_ty, with_ok, try self.resultPayloadLlvmType(info.err_ty), err_value });
        return with_err;
    }

    fn simpleMirResultConstructorPayloadValue(self: *LlvmEmitter, payload: SimpleMirResultConstructorPayload, span: diagnostics.Span) ![]const u8 {
        return switch (payload) {
            .arg => |arg| try self.simpleMirCallArgValue(arg, span),
            .enum_literal => |literal| blk: {
                const enum_decl = self.enum_types.get(literal.enum_name) orelse return error.UnsupportedLlvmEmission;
                break :blk try self.enumCaseValueByName(enum_decl, literal.case_name);
            },
        };
    }

    fn simpleMirArgValue(self: *LlvmEmitter, arg: SimpleMirArg, span: diagnostics.Span) ![]const u8 {
        return switch (arg) {
            .param => |name| try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{name}),
            .param_field => |field| try self.emitSimpleMirParamFieldValue(field, span),
            .integer_literal => |literal| literal,
            .bool_literal => |value| if (value) "1" else "0",
        };
    }

    fn emitSimpleMirStructLiteralReturn(self: *LlvmEmitter, literal: SimpleMirStructLiteralReturn, span: diagnostics.Span) ![]const u8 {
        const aggregate_ty = literal.llvm_ty;
        var result: []const u8 = "zeroinitializer";
        for (literal.fields[0..literal.field_count], 0..) |field, index| {
            const next = try self.nextTemp();
            const field_ty = field.llvm_ty;
            const field_value = try self.simpleMirCallArgValue(field.value, span);
            try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}{s}\n", .{ next, aggregate_ty, result, field_ty, field_value, index, try self.debugCallSuffix() });
            result = next;
        }
        return result;
    }

    fn emitSimpleMirArrayLiteralReturn(self: *LlvmEmitter, literal: SimpleMirArrayLiteralReturn, span: diagnostics.Span) ![]const u8 {
        const aggregate_ty = literal.llvm_ty;
        var result: []const u8 = "zeroinitializer";
        for (literal.items[0..literal.item_count], 0..) |item, index| {
            const next = try self.nextTemp();
            const value = try self.simpleMirCallArgValue(item, span);
            try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}{s}\n", .{ next, aggregate_ty, result, literal.element_ty, value, index, try self.debugCallSuffix() });
            result = next;
        }
        return result;
    }

    fn simpleMirGlobalStoreValue(self: *LlvmEmitter, value: SimpleMirGlobalStoreValue, expected_ty: anytype, span: diagnostics.Span) ![]const u8 {
        return switch (value) {
            .arg => |arg| try self.simpleMirArgValue(arg, span),
            .global_load => |name| try self.emitSimpleMirGlobalLoad(name, expected_ty),
            .direct_call => |call| blk: {
                const tmp = try self.nextTemp();
                try self.emitSimpleMirDirectCall(call, tmp, span);
                break :blk tmp;
            },
            .checked_binary => |binary| try self.emitSimpleMirCheckedBinary(binary, span),
            .checked_unary => |unary| try self.emitSimpleMirCheckedUnary(unary, span),
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary, spanFromMirSourcePoint(binary.operand_fact.source)),
            .logical_not => |arg| try self.emitSimpleMirLogicalNot(arg, span),
        };
    }

    fn simpleMirCallArgValue(self: *LlvmEmitter, arg: SimpleMirCallArg, span: diagnostics.Span) ![]const u8 {
        return switch (arg) {
            .param => |name| try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{name}),
            .param_field => |field| try self.emitSimpleMirParamFieldValue(field, span),
            .integer_literal => |literal| literal,
            .bool_literal => |value| if (value) "1" else "0",
            .global_load => |name| try self.emitSimpleMirGlobalLoad(name, self.global_types.get(name) orelse return error.UnsupportedLlvmEmission),
            .direct_call => |call| blk: {
                const tmp = try self.nextTemp();
                try self.emitSimpleMirNestedCall(call, tmp, span);
                break :blk tmp;
            },
            .checked_binary => |binary| try self.emitSimpleMirCheckedBinary(binary, span),
            .checked_unary => |unary| try self.emitSimpleMirCheckedUnary(unary, span),
            .logical_not => |operand| try self.emitSimpleMirLogicalNot(operand, span),
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary, span),
        };
    }

    fn emitSimpleMirParamFieldValue(self: *LlvmEmitter, field: SimpleMirParamField, span: diagnostics.Span) ![]const u8 {
        const tmp = try self.nextTemp();
        const param_ty = type_bridge.simpleNameType(field.struct_name, span);
        try self.out.print(self.allocator, "  {s} = extractvalue {s} %{s}, {d}{s}\n", .{ tmp, try self.llvmType(param_ty), field.param_name, field.field_index, try self.debugCallSuffix() });
        return tmp;
    }

    fn emitSimpleMirDirectCall(self: *LlvmEmitter, call: SimpleMirDirectCall, result: ?[]const u8, span: diagnostics.Span) !void {
        const callee_sig = self.fn_sigs.get(call.callee) orelse return error.UnsupportedLlvmEmission;
        const call_ret_ext = if (callee_sig.c_abi) self.cAbiExtension(callee_sig.ret) else "";
        var arg_values: [max_simple_mir_call_args][]const u8 = undefined;
        for (call.args[0..call.arg_count], 0..) |arg, i| {
            arg_values[i] = try self.simpleMirCallArgValue(arg, span);
        }
        if (result) |tmp| {
            try self.out.print(self.allocator, "  {s} = call {s}{s} @{s}(", .{ tmp, call_ret_ext, try self.llvmType(callee_sig.ret), call.callee });
        } else {
            try self.out.print(self.allocator, "  call {s}{s} @{s}(", .{ call_ret_ext, try self.llvmType(callee_sig.ret), call.callee });
        }
        for (call.args[0..call.arg_count], 0..) |_, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ty = call.arg_facts[i].target_ty;
            const param_ext = if (callee_sig.c_abi) self.cAbiExtension(arg_ty) else "";
            const value = arg_values[i];
            try self.out.print(self.allocator, "{s} {s}{s}", .{ try self.llvmType(arg_ty), param_ext, value });
        }
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "), !dbg !{d}\n", .{dbg});
        } else {
            try self.out.appendSlice(self.allocator, ")\n");
        }
    }

    fn emitSimpleMirNestedCall(self: *LlvmEmitter, call: SimpleMirNestedCall, result: []const u8, span: diagnostics.Span) !void {
        const callee_sig = self.fn_sigs.get(call.callee) orelse return error.UnsupportedLlvmEmission;
        const call_ret_ext = if (callee_sig.c_abi) self.cAbiExtension(callee_sig.ret) else "";
        var arg_values: [max_simple_mir_call_args][]const u8 = undefined;
        for (call.args[0..call.arg_count], 0..) |arg, i| {
            arg_values[i] = try self.simpleMirArgValue(arg, span);
        }
        try self.out.print(self.allocator, "  {s} = call {s}{s} @{s}(", .{ result, call_ret_ext, try self.llvmType(callee_sig.ret), call.callee });
        for (call.args[0..call.arg_count], 0..) |_, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ty = call.arg_facts[i].target_ty;
            const param_ext = if (callee_sig.c_abi) self.cAbiExtension(arg_ty) else "";
            try self.out.print(self.allocator, "{s} {s}{s}", .{ try self.llvmType(arg_ty), param_ext, arg_values[i] });
        }
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "), !dbg !{d}\n", .{dbg});
        } else {
            try self.out.appendSlice(self.allocator, ")\n");
        }
    }

    fn simpleMirCheckedBinaryAtReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCheckedBinary {
        return self.simpleMirCheckedBinaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .binary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCheckedBinaryAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCheckedBinary {
        const block, const binary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        if (!simpleMirBinaryOpSupported(binary_instr.detail)) return null;
        if (!mirHasCheckedBinaryTrapsAt(fn_mir, source, binary_instr.detail, target_fact.target_ty)) return null;
        var operands: [2]SimpleMirArg = undefined;
        var count: usize = 0;
        var after_binary = false;
        var last_operand_source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (!after_binary) {
                after_binary = instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr) continue;
            const arg_source = instructionSourcePoint(instruction);
            if (last_operand_source) |last| {
                if (sameMirSourceLocation(last, arg_source)) continue;
            }
            const arg = self.simpleMirArgAt(function, fn_mir, arg_source) orelse return null;
            if (count >= operands.len) return null;
            operands[count] = arg;
            last_operand_source = arg_source;
            count += 1;
            if (count == operands.len) break;
        }
        if (count != 2) return null;
        return .{ .op = binary_instr.detail, .target_fact = target_fact, .left = operands[0], .right = operands[1] };
    }

    fn simpleMirCompareBinaryAtReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCompareBinary {
        return self.simpleMirCompareBinaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .binary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCompareBinaryAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCompareBinary {
        const block, const binary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!simpleMirCompareOpSupported(binary_instr.detail)) return null;
        var operands: [2]SimpleMirArg = undefined;
        var operand_fact: ?mir.TargetTypeFact = null;
        var count: usize = 0;
        var after_binary = false;
        var last_operand_source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (!after_binary) {
                after_binary = instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const arg_source = instructionSourcePoint(instruction);
            if (last_operand_source) |last| {
                if (sameMirSourceLocation(last, arg_source)) continue;
            }
            const arg = self.simpleMirArgAt(function, fn_mir, arg_source) orelse return null;
            if (count >= operands.len) return null;
            operands[count] = arg;
            operand_fact = operand_fact orelse self.simpleMirOperandTargetTypeFactAt(fn_mir, arg_source);
            last_operand_source = arg_source;
            count += 1;
            if (count == operands.len) break;
        }
        if (count != 2) return null;
        return .{ .op = binary_instr.detail, .operand_fact = operand_fact orelse return null, .left = operands[0], .right = operands[1] };
    }

    fn simpleMirLogicalNotAtReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirArg {
        return self.simpleMirLogicalNotAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .unary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirLogicalNotAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArg {
        const block, const unary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!std.mem.eql(u8, unary_instr.detail, "logical_not")) return null;
        var after_unary = false;
        for (block.instructions) |instruction| {
            if (!after_unary) {
                after_unary = instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr) continue;
            return self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction));
        }
        return null;
    }

    fn simpleMirCheckedUnaryAtReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCheckedUnary {
        return self.simpleMirCheckedUnaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .unary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCheckedUnaryAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCheckedUnary {
        const block, const unary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!std.mem.eql(u8, unary_instr.detail, "neg")) return null;
        if (!mirHasIntegerOverflowTrapAt(fn_mir, source)) return null;
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        if (!self.isSignedIntegerType(target_fact.target_ty)) return null;
        var after_unary = false;
        for (block.instructions) |instruction| {
            if (!after_unary) {
                after_unary = instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const operand = self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse return null;
            return .{ .op = unary_instr.detail, .target_fact = target_fact, .operand = operand };
        }
        return null;
    }

    fn simpleMirFoldedNegatedIntegerLiteral(self: *LlvmEmitter, unary: SimpleMirCheckedUnary) ?[]const u8 {
        if (!std.mem.eql(u8, unary.op, "neg")) return null;
        const literal = switch (unary.operand) {
            .integer_literal => |value| value,
            else => return null,
        };
        if (literal.len == 0 or literal[0] == '-') return null;
        return std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{literal}) catch null;
    }

    fn simpleMirDirectCall(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, callee: []const u8) ?SimpleMirDirectCall {
        return self.simpleMirDirectCallAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, callee)) break :blk instructionSourcePoint(instruction);
                }
            }
            return null;
        });
    }

    fn simpleMirDirectCallAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirDirectCall {
        const call_block, const callee = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) break :blk .{ block, instruction.detail };
                }
            }
            return null;
        };
        var arg_count: usize = 0;
        var call: SimpleMirDirectCall = .{ .callee = callee };
        var seen_args = [_]bool{false} ** max_simple_mir_call_args;
        var saw_result = false;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .direct_call_result and std.mem.eql(u8, fact.target_owner orelse "", callee) and sameMirSourceLocation(fact.source, call_source)) {
                saw_result = true;
            }
        }
        if (!saw_result) return null;
        var after_call = false;
        for (call_block.instructions) |instruction| {
            if (!after_call) {
                after_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source);
                continue;
            }
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .call) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const arg_source = instructionSourcePoint(instruction);
            const fact = self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, arg_source) orelse continue;
            const arg_index = fact.target_index orelse return null;
            if (arg_index >= max_simple_mir_call_args) return null;
            call.args[arg_index] = self.simpleMirCallArgAt(function, fn_mir, arg_source) orelse return null;
            call.arg_facts[arg_index] = fact;
            seen_args[arg_index] = true;
            arg_count = @max(arg_count, arg_index + 1);
        }
        const fn_sig = self.fn_sigs.get(callee) orelse return null;
        if (fn_sig.is_variadic) {
            if (arg_count < fn_sig.params.len) return null;
        } else if (arg_count != fn_sig.params.len) return null;
        for (seen_args[0..arg_count]) |seen| if (!seen) return null;
        call.arg_count = arg_count;
        if (arg_count > 1) {
            for (call.args[0..arg_count]) |arg| if (simpleMirCallArgHasDirectCall(arg)) return null;
        }
        return call;
    }

    fn simpleMirResultConstructorReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirResultConstructorReturn {
        const call_source, const kind = blk: {
            for (block.instructions) |instruction| {
                if (instruction.kind != .call or !std.mem.eql(u8, instruction.detail, value_id)) continue;
                const source = instructionSourcePoint(instruction);
                for (fn_mir.call_target_facts) |fact| {
                    if (!sameMirSourceLocation(fact.source, source)) continue;
                    switch (fact.kind) {
                        .result_ok, .result_err => break :blk .{ source, fact.kind },
                        else => {},
                    }
                }
            }
            return null;
        };
        const constructor = mir.resultConstructorFactInfo(kind) orelse return null;
        const target_fact = simpleMirTargetTypeFactKindAt(fn_mir, constructor.target_kind, call_source) orelse return null;
        const return_ty = function.signature.return_type orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(target_fact.target_ty))) return null;

        var payload: ?SimpleMirResultConstructorPayload = null;
        var after_call = false;
        for (block.instructions) |instruction| {
            if (!after_call) {
                after_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source);
                continue;
            }
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .target_type or instruction.kind == .call_target or instruction.kind == .integer_literal_conversion) continue;
            if (instruction.kind != .expr and instruction.kind != .call and instruction.kind != .binary and instruction.kind != .unary) continue;
            const source = instructionSourcePoint(instruction);
            if (sameMirSourceLocation(source, call_source)) continue;
            const arg: SimpleMirResultConstructorPayload = if (self.simpleMirCallArgAt(function, fn_mir, source)) |call_arg|
                .{ .arg = call_arg }
            else if (self.simpleMirEnumLiteralValueAtSource(fn_mir, source)) |literal|
                .{ .enum_literal = literal }
            else
                continue;
            if (payload != null) return null;
            payload = arg;
        }
        return .{
            .tag = constructor.tag,
            .result_fact = target_fact,
            .payload = payload orelse return null,
        };
    }

    fn simpleMirResultConstructorPayloadTrapCount(payload: SimpleMirResultConstructorPayload) usize {
        return switch (payload) {
            .arg => |arg| simpleMirCallArgTrapCount(arg),
            .enum_literal => 0,
        };
    }

    fn simpleMirConversionReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, value_id: []const u8) ?SimpleMirConversionReturn {
        const block, const call_source = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, value_id)) break :blk .{ block, instructionSourcePoint(instruction) };
                }
            }
            return null;
        };
        const kind = self.simpleMirConversionCallTargetKindAt(fn_mir, call_source) orelse return null;
        const source_fact = simpleMirTargetTypeFactKindAt(fn_mir, .conversion_source, call_source) orelse return null;
        const target_fact = simpleMirTargetTypeFactKindAt(fn_mir, .conversion_target, call_source) orelse return null;
        var after_call = false;
        for (block.instructions) |instruction| {
            if (!after_call) {
                after_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .call) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const operand = self.simpleMirCallArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse continue;
            return .{ .kind = kind, .source_fact = source_fact, .target_fact = target_fact, .operand = operand };
        }
        return null;
    }

    fn simpleMirExplicitCastReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirExplicitCastReturn {
        const block, const cast_source = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "cast")) break :blk .{ block, instructionSourcePoint(instruction) };
                }
            }
            return null;
        };
        const source_fact = simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_source, cast_source) orelse return null;
        const target_fact = simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_target, cast_source) orelse return null;
        var after_cast = false;
        for (block.instructions) |instruction| {
            if (!after_cast) {
                after_cast = instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "cast") and sameMirSourceLocation(instructionSourcePoint(instruction), cast_source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .call) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const operand = self.simpleMirCallArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse continue;
            if (fn_mir.trap_edges.len != simpleMirCallArgTrapCount(operand)) return null;
            return .{ .source_fact = source_fact, .target_fact = target_fact, .operand = operand };
        }
        return null;
    }

    fn simpleMirConversionCallTargetKindAt(self: *LlvmEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
        _ = self;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source)) continue;
            switch (fact.kind) {
                .conversion_from, .conversion_wrap_from, .conversion_from_mod => return fact.kind,
                else => {},
            }
        }
        return null;
    }

    fn simpleMirCallArgAt(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCallArg {
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirLocalCallArgAt(function, fn_mir, source)) |arg| return arg;
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, source)) |field| return .{ .param_field = field };
        if (self.simpleMirGlobalAtSource(function, fn_mir, source)) |name| return .{ .global_load = name };
        if (self.simpleMirNestedCallAtSource(function, fn_mir, source)) |call| {
            if (self.simpleMirNestedCallReturnsValue(call)) return .{ .direct_call = call };
        }
        return switch (self.simpleMirArgAt(function, fn_mir, source) orelse return null) {
            .param => |name| .{ .param = name },
            .param_field => |field| .{ .param_field = field },
            .integer_literal => |literal| .{ .integer_literal = literal },
            .bool_literal => |value| .{ .bool_literal = value },
        };
    }

    fn simpleMirCallArgHasDirectCall(arg: SimpleMirCallArg) bool {
        return switch (arg) {
            .direct_call => true,
            else => false,
        };
    }

    fn simpleMirNestedCallReturnsValue(self: *LlvmEmitter, call: SimpleMirNestedCall) bool {
        const fn_sig = self.fn_sigs.get(call.callee) orelse return false;
        return !typeNameEql(fn_sig.ret, "void") and !typeNameEql(fn_sig.ret, "never");
    }

    fn simpleMirNestedCallReturnsBool(self: *LlvmEmitter, call: SimpleMirNestedCall) bool {
        const fn_sig = self.fn_sigs.get(call.callee) orelse return false;
        return typeNameEql(fn_sig.ret, "bool");
    }

    fn simpleMirNestedCallAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirNestedCall {
        const call_block, const callee = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) break :blk .{ block, instruction.detail };
                }
            }
            return null;
        };
        var arg_count: usize = 0;
        var call: SimpleMirNestedCall = .{ .callee = callee };
        var seen_args = [_]bool{false} ** max_simple_mir_call_args;
        var saw_result = false;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .direct_call_result and std.mem.eql(u8, fact.target_owner orelse "", callee) and sameMirSourceLocation(fact.source, call_source)) {
                saw_result = true;
            }
        }
        if (!saw_result) return null;
        var after_call = false;
        for (call_block.instructions) |instruction| {
            if (!after_call) {
                after_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source);
                continue;
            }
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .call) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion) continue;
            const arg_source = instructionSourcePoint(instruction);
            const fact = self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, arg_source) orelse continue;
            const arg_index = fact.target_index orelse return null;
            if (arg_index >= max_simple_mir_call_args) return null;
            call.args[arg_index] = self.simpleMirArgAt(function, fn_mir, arg_source) orelse return null;
            call.arg_facts[arg_index] = fact;
            seen_args[arg_index] = true;
            arg_count = @max(arg_count, arg_index + 1);
        }
        const fn_sig = self.fn_sigs.get(callee) orelse return null;
        if (fn_sig.is_variadic) {
            if (arg_count < fn_sig.params.len) return null;
        } else if (arg_count != fn_sig.params.len) return null;
        for (seen_args[0..arg_count]) |seen| if (!seen) return null;
        call.arg_count = arg_count;
        return call;
    }

    fn simpleMirLocalCallArgAt(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCallArg {
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr or !sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                if (!mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
                const local_source = self.simpleMirAssignmentSourceInBlock(block, instruction.detail) orelse
                    self.simpleMirLocalInitSourceInBlock(block, instruction.detail) orelse return null;
                if (sameMirSourceLocation(local_source, source)) return null;
                return self.simpleMirCallArgAt(function, fn_mir, local_source);
            }
        }
        return null;
    }

    fn simpleMirDirectCallArgumentFactAt(self: *LlvmEmitter, fn_mir: mir.Function, callee: []const u8, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .direct_call_argument) continue;
            if (!std.mem.eql(u8, fact.target_owner orelse "", callee)) continue;
            if (sameMirSourceLocation(fact.source, source)) return fact;
        }
        return null;
    }

    fn simpleMirPrefixVoidCallsBeforeReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, allow_trap_blocks: bool) ?SimpleMirDirectCalls {
        if (fn_mir.blocks.len == 0) return null;
        if (!allow_trap_blocks and fn_mir.blocks.len != 1) return null;
        var calls: SimpleMirDirectCalls = .{};
        const block = fn_mir.blocks[0];
        const ret = simpleMirReturnInstruction(block) orelse return null;
        const return_value_id = ret.value_id;
        var saw_return_value_call = false;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) return calls;
            if (instruction.kind != .call) continue;
            const source = instructionSourcePoint(instruction);
            if (!simpleMirDirectCallResultVoid(fn_mir, source)) {
                if (return_value_id) |value_id| {
                    if (self.simpleMirCallFeedsReturnValue(fn_mir, block, source, value_id)) {
                        saw_return_value_call = true;
                        continue;
                    }
                }
                return null;
            }
            if (saw_return_value_call) return null;
            if (calls.count >= max_simple_mir_void_calls) return null;
            calls.calls[calls.count] = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return null;
            calls.count += 1;
        }
        return null;
    }

    fn simpleMirPrefixVoidCallsBeforeSwitch(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirDirectCalls {
        var calls: SimpleMirDirectCalls = .{};
        for (block.instructions) |instruction| {
            if (instruction.kind == .binary and std.mem.eql(u8, instruction.detail, "switch_subject")) return calls;
            if (instruction.kind != .call) continue;
            const source = instructionSourcePoint(instruction);
            if (!simpleMirDirectCallResultVoid(fn_mir, source)) {
                if (self.simpleMirCallFeedsSwitchCondition(function, fn_mir, block, source)) continue;
                return null;
            }
            if (calls.count >= max_simple_mir_void_calls) return null;
            calls.calls[calls.count] = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return null;
            calls.count += 1;
        }
        return null;
    }

    fn simpleMirCallFeedsSwitchCondition(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint) bool {
        _ = function;
        _ = fn_mir;
        const subject_index = simpleMirSwitchSubjectIndex(block) orelse return false;
        var index: usize = subject_index + 1;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            if (instruction.kind == .target_type) continue;
            if (instruction.kind == .call) return sameMirSourceLocation(instructionSourcePoint(instruction), source);
            if (instruction.kind != .expr) return false;
            if (sameMirSourceLocation(instructionSourcePoint(instruction), source)) return true;
            if (!mirBlockHasLocal(block, instruction.detail)) return false;
            const local_source = self.simpleMirAssignmentSourceInBlock(block, instruction.detail) orelse
                self.simpleMirLocalInitSourceInBlock(block, instruction.detail) orelse return false;
            return sameMirSourceLocation(local_source, source);
        }
        return false;
    }

    fn simpleMirCallFeedsReturnValue(self: *LlvmEmitter, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint, value_id: []const u8) bool {
        if (std.mem.eql(u8, value_id, "struct_literal") or std.mem.eql(u8, value_id, "array_literal")) {
            var after_literal = false;
            for (block.instructions) |instruction| {
                if (instruction.kind == .return_value) break;
                if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, value_id)) {
                    after_literal = true;
                    continue;
                }
                if (after_literal and instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), source)) return true;
            }
        }
        if (mirBlockHasCall(block, value_id)) {
            for (block.instructions) |instruction| {
                if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, value_id)) {
                    return sameMirSourceLocation(instructionSourcePoint(instruction), source);
                }
            }
        }
        if (!mirFunctionHasLocal(fn_mir, value_id)) return false;
        const local_source = self.simpleMirAssignmentSourceInBlock(block, value_id) orelse
            self.simpleMirLocalInitSourceInBlock(block, value_id) orelse return false;
        if (sameMirSourceLocation(local_source, source)) return true;
        return simpleMirCallFeedsAggregateLiteralAtSource(block, source, local_source);
    }

    fn simpleMirCallFeedsAggregateLiteralAtSource(block: mir.Block, call_source: mir.SourcePoint, literal_source: mir.SourcePoint) bool {
        var after_literal = false;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .expr and
                (std.mem.eql(u8, instruction.detail, "struct_literal") or std.mem.eql(u8, instruction.detail, "array_literal")) and
                sameMirSourceLocation(instructionSourcePoint(instruction), literal_source))
            {
                after_literal = true;
                continue;
            }
            if (after_literal and instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) return true;
        }
        return false;
    }

    fn simpleMirDirectVoidCallsInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, allow_empty: bool) ?SimpleMirDirectCalls {
        var calls: SimpleMirDirectCalls = .{};
        for (block.instructions) |instruction| {
            switch (instruction.kind) {
                .param, .local, .target_type, .integer_literal_conversion, .add_overflow => {},
                .assign => if (!mirFunctionHasLocal(fn_mir, instruction.detail)) return null,
                .binary => {
                    if (std.mem.eql(u8, instruction.detail, "switch_subject")) continue;
                    const source = instructionSourcePoint(instruction);
                    if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirCompareBinaryAtSource(function, fn_mir, source) == null) return null;
                },
                .unary => {
                    const source = instructionSourcePoint(instruction);
                    if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirLogicalNotAtSource(function, fn_mir, source) == null) return null;
                },
                .expr => {
                    if (std.mem.eql(u8, instruction.detail, "int") or
                        std.mem.eql(u8, instruction.detail, "bool") or
                        std.mem.eql(u8, instruction.detail, "literal")) continue;
                    if (self.global_types.contains(instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                    } else {
                        if (mirBlockHasCall(block, instruction.detail)) continue;
                        return null;
                    }
                },
                .call => {
                    const source = instructionSourcePoint(instruction);
                    if (!simpleMirDirectCallResultVoid(fn_mir, source)) {
                        if (simpleMirReturnInstruction(block)) |ret| {
                            if (ret.value_id) |value_id| {
                                if (self.simpleMirCallFeedsReturnValue(fn_mir, block, source, value_id)) continue;
                            }
                        }
                        if (self.simpleMirCallFeedsLaterDirectCallArg(function, fn_mir, block, source)) continue;
                        return null;
                    }
                    if (calls.count >= max_simple_mir_void_calls) return null;
                    calls.calls[calls.count] = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return null;
                    calls.count += 1;
                },
                else => return null,
            }
        }
        if (!allow_empty and calls.count == 0) return null;
        return calls;
    }

    fn simpleMirVoidStatementSourcesInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirVoidStatementSources {
        var result: SimpleMirVoidStatementSources = .{};
        for (block.instructions) |instruction| {
            switch (instruction.kind) {
                .param, .local, .target_type, .integer_literal_conversion, .add_overflow => {},
                .return_value => {},
                .assign => {
                    if (mirFunctionHasLocal(fn_mir, instruction.detail)) return null;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) return null;
                    }
                    if (!self.global_types.contains(instruction.detail)) return null;
                    if (result.count >= max_simple_mir_void_statements) return null;
                    const name = instruction.detail;
                    result.sources[result.count] = .{ .global_store = .{
                        .name = name,
                        .value_source = self.simpleMirAssignmentSourceInBlock(block, name) orelse return null,
                        .source = instructionSourcePoint(instruction),
                    } };
                    result.count += 1;
                },
                .binary => {
                    if (std.mem.eql(u8, instruction.detail, "switch_subject")) continue;
                    const source = instructionSourcePoint(instruction);
                    if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirCompareBinaryAtSource(function, fn_mir, source) == null) return null;
                },
                .unary => {
                    const source = instructionSourcePoint(instruction);
                    if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirLogicalNotAtSource(function, fn_mir, source) == null) return null;
                },
                .expr => {
                    if (std.mem.eql(u8, instruction.detail, "int") or
                        std.mem.eql(u8, instruction.detail, "bool") or
                        std.mem.eql(u8, instruction.detail, "literal")) continue;
                    if (self.global_types.contains(instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                    } else {
                        if (mirBlockHasCall(block, instruction.detail)) continue;
                        return null;
                    }
                },
                .call => {
                    const source = instructionSourcePoint(instruction);
                    if (!simpleMirDirectCallResultVoid(fn_mir, source)) {
                        if (simpleMirReturnInstruction(block)) |ret| {
                            if (ret.value_id) |value_id| {
                                if (self.simpleMirCallFeedsReturnValue(fn_mir, block, source, value_id)) continue;
                            }
                        }
                        if (self.simpleMirCallFeedsLaterDirectCallArg(function, fn_mir, block, source)) continue;
                        return null;
                    }
                    if (result.count >= max_simple_mir_void_statements) return null;
                    result.sources[result.count] = .{ .direct_call = source };
                    result.count += 1;
                },
                else => return null,
            }
        }
        return result;
    }

    fn simpleMirVoidStatementSourcesTrapCount(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, sources: SimpleMirVoidStatementSources) ?usize {
        var count: usize = 0;
        for (sources.sources[0..sources.count]) |source| {
            count += switch (source) {
                .direct_call => |call_source| simpleMirDirectCallTrapCount(self.simpleMirDirectCallAtSource(function, fn_mir, call_source) orelse return null),
                .global_store => |store| simpleMirGlobalStoreValueTrapCount(self.simpleMirGlobalStoreValueAtSource(function, fn_mir, store.value_source) orelse return null),
            };
        }
        return count;
    }

    fn simpleMirCallFeedsLaterDirectCallArg(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint) bool {
        _ = function;
        var after_source_call = false;
        var active_callee: ?[]const u8 = null;
        for (block.instructions) |instruction| {
            if (!after_source_call) {
                after_source_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .call) {
                active_callee = instruction.detail;
                continue;
            }
            if (instruction.kind != .expr) continue;
            const callee = active_callee orelse continue;
            const arg_source = instructionSourcePoint(instruction);
            if (self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, arg_source) == null) continue;
            if (sameMirSourceLocation(arg_source, source)) return true;
            if (!mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
            const local_source = self.simpleMirAssignmentSourceInBlock(block, instruction.detail) orelse
                self.simpleMirLocalInitSourceInBlock(block, instruction.detail) orelse continue;
            if (sameMirSourceLocation(local_source, source)) return true;
        }
        return false;
    }

    fn simpleMirLocalInitReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirReturn {
        if (!mirBlockHasLocal(fn_mir.blocks[0], local_name)) return null;
        const init_source = self.simpleMirLocalInitSource(fn_mir, local_name) orelse return null;
        if (simpleMirLocalHasInferredTypeFact(fn_mir, local_name)) {
            if (self.simpleMirEnumLiteralValueAtSource(fn_mir, init_source)) |literal| return .{ .enum_literal = literal };
            return null;
        }
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, init_source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, init_source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, init_source)) |call| return .{ .direct_call = call };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, init_source)) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirStructLiteralAtSource(function, fn_mir, init_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirStructLiteralTrapCount(literal)) return .{ .struct_literal = literal };
        }
        if (self.simpleMirArrayLiteralAtSource(function, fn_mir, init_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirArrayLiteralTrapCount(literal)) return .{ .array_literal = literal };
        }
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (self.simpleMirNestedCallAtSource(function, fn_mir, init_source)) |call| return .{ .nested_call = call };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, init_source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, init_source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirGlobalAtSource(function, fn_mir, init_source)) |name| return .{ .global_load = name };
        if (simpleMirNullLiteralAtSource(fn_mir, init_source)) return .null_literal;
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, init_source)) |field| return .{ .param_field = field };
        if (self.simpleMirArgAt(function, fn_mir, init_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = name },
                .param_field => |field| .{ .param_field = field },
                .integer_literal => |literal| .{ .integer_literal = literal },
                .bool_literal => |value| .{ .bool_literal = value },
            };
        }
        return null;
    }

    fn simpleMirLocalHasInferredTypeFact(fn_mir: mir.Function, local_name: []const u8) bool {
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .inferred_local and std.mem.eql(u8, fact.target_owner orelse "", local_name)) return true;
        }
        return false;
    }

    fn simpleMirAssignmentReturn(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirReturn {
        if (fn_mir.pointer_provenance_facts.len != 0) return null;
        const assigned_source = self.simpleMirAssignmentSource(fn_mir, local_name) orelse return null;
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, assigned_source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, assigned_source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, assigned_source)) |call| return .{ .direct_call = call };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, assigned_source)) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirStructLiteralAtSource(function, fn_mir, assigned_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirStructLiteralTrapCount(literal)) return .{ .struct_literal = literal };
        }
        if (self.simpleMirArrayLiteralAtSource(function, fn_mir, assigned_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirArrayLiteralTrapCount(literal)) return .{ .array_literal = literal };
        }
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (self.simpleMirNestedCallAtSource(function, fn_mir, assigned_source)) |call| return .{ .nested_call = call };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, assigned_source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, assigned_source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirGlobalAtSource(function, fn_mir, assigned_source)) |name| return .{ .global_load = name };
        if (simpleMirNullLiteralAtSource(fn_mir, assigned_source)) return .null_literal;
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, assigned_source)) |field| return .{ .param_field = field };
        if (self.simpleMirArgAt(function, fn_mir, assigned_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = name },
                .param_field => |field| .{ .param_field = field },
                .integer_literal => |literal| .{ .integer_literal = literal },
                .bool_literal => |value| .{ .bool_literal = value },
            };
        }
        return null;
    }

    fn simpleMirAssignmentSource(self: *LlvmEmitter, fn_mir: mir.Function, local_name: []const u8) ?mir.SourcePoint {
        const block = fn_mir.blocks[0];
        return self.simpleMirAssignmentSourceInBlock(block, local_name);
    }

    fn simpleMirAssignmentSourceInBlock(_: *LlvmEmitter, block: mir.Block, local_name: []const u8) ?mir.SourcePoint {
        var source: ?mir.SourcePoint = null;
        var index: usize = 0;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            if (instruction.kind != .assign or !std.mem.eql(u8, instruction.detail, local_name)) continue;
            if (source != null) return null;
            index += 1;
            while (index < block.instructions.len) : (index += 1) {
                const next = block.instructions[index];
                switch (next.kind) {
                    .target_type, .typed_load, .representation_check, .representation_use => continue,
                    .expr => {
                        if (std.mem.eql(u8, next.detail, local_name)) continue;
                        source = instructionSourcePoint(next);
                        break;
                    },
                    .integer_literal_conversion, .binary, .unary, .call => {
                        source = instructionSourcePoint(next);
                        break;
                    },
                    else => return null,
                }
            }
        }
        return source;
    }

    fn simpleMirGlobalAtSource(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?[]const u8 {
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr or !sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) return null;
                }
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) return null;
                if (self.global_types.contains(instruction.detail)) return instruction.detail;
            }
        }
        return null;
    }

    fn emitSimpleMirGlobalLoad(self: *LlvmEmitter, name: []const u8, expected_ty: anytype) ![]const u8 {
        const global_ty = self.global_types.get(name) orelse return error.UnsupportedLlvmEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(global_ty), self.resolveAliasType(expected_ty))) return error.UnsupportedLlvmEmission;
        const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{name});
        return self.emitOrdinaryLoad(global_ty, ptr, !(self.global_is_const.get(name) orelse false));
    }

    fn simpleMirLocalInitSource(self: *LlvmEmitter, fn_mir: mir.Function, local_name: []const u8) ?mir.SourcePoint {
        return self.simpleMirLocalInitSourceInBlock(fn_mir.blocks[0], local_name);
    }

    fn simpleMirLocalInitSourceInBlock(_: *LlvmEmitter, block: mir.Block, local_name: []const u8) ?mir.SourcePoint {
        var after_local = false;
        for (block.instructions) |instruction| {
            if (!after_local) {
                after_local = instruction.kind == .local and std.mem.eql(u8, instruction.detail, local_name);
                continue;
            }
            switch (instruction.kind) {
                .target_type, .representation_check, .representation_use => continue,
                .integer_literal_conversion, .binary, .unary, .call => return instructionSourcePoint(instruction),
                .expr => if (!std.mem.eql(u8, instruction.detail, local_name)) return instructionSourcePoint(instruction),
                .return_value => return null,
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirArgAt(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArg {
        for (fn_mir.integer_facts) |fact| {
            if (sameMirSourceLocation(fact.source, source)) return .{ .integer_literal = fact.literal };
        }
        for (fn_mir.bool_facts) |fact| {
            if (sameMirSourceLocation(fact.source, source)) return .{ .bool_literal = fact.value };
        }
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr or !sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                if (self.simpleMirParamFieldAtSource(function, block, source, instruction.detail, instruction.result_ty.name())) |field| return .{ .param_field = field };
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) return .{ .param = param.name.text };
                }
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) {
                    if (self.simpleMirLocalValueArg(function, fn_mir, block, instruction.detail, source)) |arg| return arg;
                }
            }
        }
        return null;
    }

    fn simpleMirLocalValueArg(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8, use_source: mir.SourcePoint) ?SimpleMirArg {
        if (self.simpleMirAssignmentSourceInBlock(block, local_name)) |assigned_source| {
            if (sameMirSourceLocation(assigned_source, use_source)) return null;
            return self.simpleMirArgAt(function, fn_mir, assigned_source);
        }
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        if (sameMirSourceLocation(init_source, use_source)) return null;
        return self.simpleMirArgAt(function, fn_mir, init_source);
    }

    fn simpleMirEnumLiteralAtSource(self: *LlvmEmitter, fn_mir: mir.Function, case_name: []const u8, source: mir.SourcePoint) ?SimpleMirEnumLiteral {
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .enum_literal, source) orelse return null;
        const enum_decl = self.enumDeclForType(fact.target_ty) orelse return null;
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, case_name)) return .{ .enum_name = enum_decl.name.text, .case_name = case_name };
        }
        return null;
    }

    fn simpleMirEnumLiteralValueAtSource(self: *LlvmEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirEnumLiteral {
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, source);
            }
        }
        return null;
    }

    fn simpleMirNullLiteralAtSource(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        return simpleMirTargetTypeFactKindAt(fn_mir, .null_literal, source) != null;
    }

    fn blockOnlyContainsSimpleMirReturnInstructions(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function) bool {
        return self.blockOnlyContainsSimpleMirReturnInstructionsInBlock(function, fn_mir, fn_mir.blocks[0]);
    }

    fn blockOnlyContainsSimpleMirReturnInstructionsInBlock(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .assign, .target_type, .integer_literal_conversion, .representation_check, .representation_use, .typed_load, .binary, .unary, .add_overflow, .return_value => {},
            .call, .call_target => {},
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "char") or std.mem.eql(u8, instruction.detail, "bool") or std.mem.eql(u8, instruction.detail, "struct_literal") or std.mem.eql(u8, instruction.detail, "array_literal")) continue;
                if (self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "null") and simpleMirNullLiteralAtSource(fn_mir, instructionSourcePoint(instruction))) continue;
                if (self.simpleMirConversionCallTargetKindAt(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "cast") and simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_source, instructionSourcePoint(instruction)) != null) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else {
                    if (mirBlockHasLocal(block, instruction.detail)) continue;
                    if (mirBlockHasCall(block, instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.global_types.contains(instruction.detail)) continue;
                    return false;
                }
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirCallSource(self: *LlvmEmitter, fn_mir: mir.Function) ?mir.SourcePoint {
        _ = self;
        var source: ?mir.SourcePoint = null;
        for (fn_mir.blocks[0].instructions) |instruction| {
            if (instruction.kind != .call) continue;
            if (source != null) return null;
            source = instructionSourcePoint(instruction);
        }
        return source;
    }

    fn simpleMirEmptyVoidBlock(function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .target_type, .integer_literal_conversion => {},
            .assign => if (!mirFunctionHasLocal(fn_mir, instruction.detail)) return false,
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or
                    std.mem.eql(u8, instruction.detail, "bool") or
                    std.mem.eql(u8, instruction.detail, "literal")) continue;
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else return false;
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirBlockHasCall(block: mir.Block) bool {
        for (block.instructions) |instruction| {
            if (instruction.kind == .call) return true;
        }
        return false;
    }

    fn simpleMirEntrySwitchBlockIsPure(self: *LlvmEmitter, function: anytype, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .target_type, .integer_literal_conversion => {},
            .assign => if (!mirBlockHasLocal(block, instruction.detail)) return false,
            .binary => if (!std.mem.eql(u8, instruction.detail, "switch_subject")) return false,
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "bool")) continue;
                if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                if (mirBlockHasLocal(block, instruction.detail)) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else return false;
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirEntrySwitchBlockIsPureWithPrefixVoidCalls(self: *LlvmEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        const subject_index = simpleMirSwitchSubjectIndex(block) orelse return false;
        for (block.instructions, 0..) |instruction, index| switch (instruction.kind) {
            .param, .local, .target_type, .integer_literal_conversion => {},
            .assign => if (!mirBlockHasLocal(block, instruction.detail)) return false,
            .binary => if (!std.mem.eql(u8, instruction.detail, "switch_subject")) return false,
            .call => {
                if (index > subject_index) return false;
                const source = instructionSourcePoint(instruction);
                if (!simpleMirDirectCallResultVoid(fn_mir, source)) return false;
                if (self.simpleMirDirectCallAtSource(function, fn_mir, source) == null) return false;
            },
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "bool")) continue;
                if (index < subject_index and mirBlockHasCall(block, instruction.detail)) continue;
                if (mirBlockHasLocal(block, instruction.detail)) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else return false;
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirDirectCallResultVoid(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .direct_call_result and sameMirSourceLocation(fact.source, source)) return fact.result_ty == .void;
        }
        return false;
    }

    fn simpleMirBinaryOpSupported(op: []const u8) bool {
        return std.mem.eql(u8, op, "add") or
            std.mem.eql(u8, op, "sub") or
            std.mem.eql(u8, op, "mul") or
            std.mem.eql(u8, op, "div") or
            std.mem.eql(u8, op, "mod") or
            std.mem.eql(u8, op, "shl") or
            std.mem.eql(u8, op, "shr");
    }

    fn simpleMirSignedIntegerTypeName(type_name: []const u8) bool {
        return std.mem.eql(u8, type_name, "i8") or
            std.mem.eql(u8, type_name, "i16") or
            std.mem.eql(u8, type_name, "i32") or
            std.mem.eql(u8, type_name, "i64") or
            std.mem.eql(u8, type_name, "i128") or
            std.mem.eql(u8, type_name, "isize");
    }

    fn simpleMirCompareOpSupported(op: []const u8) bool {
        return std.mem.eql(u8, op, "eq") or std.mem.eql(u8, op, "ne") or std.mem.eql(u8, op, "lt") or std.mem.eql(u8, op, "le") or std.mem.eql(u8, op, "gt") or std.mem.eql(u8, op, "ge");
    }

    fn simpleMirComparePredicate(self: *LlvmEmitter, op: []const u8, signed: bool) ![]const u8 {
        _ = self;
        if (std.mem.eql(u8, op, "eq")) return "eq";
        if (std.mem.eql(u8, op, "ne")) return "ne";
        if (std.mem.eql(u8, op, "lt")) return if (signed) "slt" else "ult";
        if (std.mem.eql(u8, op, "le")) return if (signed) "sle" else "ule";
        if (std.mem.eql(u8, op, "gt")) return if (signed) "sgt" else "ugt";
        if (std.mem.eql(u8, op, "ge")) return if (signed) "sge" else "uge";
        return error.UnsupportedLlvmEmission;
    }

    fn mirHasIntegerOverflowTrapAt(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.trap_edges) |edge| {
            if (edge.kind == .IntegerOverflow and edge.source == .checked_arithmetic and edge.line == source.line and edge.column == source.column) return true;
        }
        return false;
    }

    fn mirHasDivideByZeroTrapAt(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.trap_edges) |edge| {
            if (edge.kind == .DivideByZero and edge.source == .checked_arithmetic and edge.line == source.line and edge.column == source.column) return true;
        }
        return false;
    }

    fn mirHasInvalidShiftTrapAt(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.trap_edges) |edge| {
            if (edge.kind == .InvalidShift and edge.source == .checked_shift and edge.line == source.line and edge.column == source.column) return true;
        }
        return false;
    }

    fn mirHasCheckedBinaryTrapsAt(fn_mir: mir.Function, source: mir.SourcePoint, op: []const u8, target_ty: anytype) bool {
        const type_name = typeName(target_ty) orelse return false;
        if (std.mem.eql(u8, op, "div") or std.mem.eql(u8, op, "mod")) {
            if (!mirHasDivideByZeroTrapAt(fn_mir, source)) return false;
            return !simpleMirSignedIntegerTypeName(type_name) or mirHasIntegerOverflowTrapAt(fn_mir, source);
        }
        if (std.mem.eql(u8, op, "shl")) {
            return mirHasInvalidShiftTrapAt(fn_mir, source) and mirHasIntegerOverflowTrapAt(fn_mir, source);
        }
        if (std.mem.eql(u8, op, "shr")) {
            return mirHasInvalidShiftTrapAt(fn_mir, source);
        }
        return mirHasIntegerOverflowTrapAt(fn_mir, source);
    }

    fn simpleMirOverflowIntrinsic(self: *LlvmEmitter, op: []const u8, signed: bool, bits: u16) ![]const u8 {
        const prefix = if (signed) "s" else "u";
        const middle: []const u8 = if (std.mem.eql(u8, op, "add"))
            "add"
        else if (std.mem.eql(u8, op, "sub"))
            "sub"
        else if (std.mem.eql(u8, op, "mul"))
            "mul"
        else
            return error.UnsupportedLlvmEmission;
        const name = try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}{s}.with.overflow.i{d}", .{ prefix, middle, bits });
        if (std.mem.eql(u8, op, "add")) {
            if (signed) try self.need_sadd.put(name, {}) else try self.need_uadd.put(name, {});
        } else if (std.mem.eql(u8, op, "sub")) {
            if (signed) try self.need_ssub.put(name, {}) else try self.need_usub.put(name, {});
        } else if (std.mem.eql(u8, op, "mul")) {
            if (signed) try self.need_smul.put(name, {}) else try self.need_umul.put(name, {});
        }
        return name;
    }

    fn simpleMirTargetTypeFactAt(self: *LlvmEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .expression_result and sameMirSourceLocation(fact.source, source)) return fact;
        }
        return null;
    }

    fn simpleMirTargetTypeFactKindAt(fn_mir: mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint) ?mir.TargetTypeFact {
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == kind and sameMirSourceLocation(fact.source, source)) return fact;
        }
        return null;
    }

    fn simpleMirOperandTargetTypeFactAt(self: *LlvmEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        var bool_fact: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .expression_result or !sameMirSourceLocation(fact.source, source)) continue;
            if (fact.result_ty != .bool) return fact;
            bool_fact = bool_fact orelse fact;
        }
        return bool_fact;
    }

    fn mirBlockHasLocal(block: mir.Block, name: []const u8) bool {
        for (block.instructions) |instruction| {
            if (instruction.kind == .local and std.mem.eql(u8, instruction.detail, name)) return true;
        }
        return false;
    }

    fn mirFunctionHasLocal(fn_mir: mir.Function, name: []const u8) bool {
        for (fn_mir.blocks) |block| {
            if (mirBlockHasLocal(block, name)) return true;
        }
        return false;
    }

    fn simpleMirBlockAssignsLocal(block: mir.Block, name: []const u8) bool {
        for (block.instructions) |instruction| {
            if (instruction.kind == .assign and std.mem.eql(u8, instruction.detail, name)) return true;
        }
        return false;
    }

    fn simpleMirBlockHasExprAt(block: mir.Block, detail: []const u8, source: mir.SourcePoint) bool {
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) return false;
            if (instruction.kind != .expr) continue;
            if (std.mem.eql(u8, instruction.detail, detail) and sameMirSourceLocation(instructionSourcePoint(instruction), source)) return true;
        }
        return false;
    }

    fn mirBlockHasCall(block: mir.Block, name: []const u8) bool {
        for (block.instructions) |instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, name)) return true;
        }
        return false;
    }

    fn simpleMirReturnInstruction(block: mir.Block) ?mir.Instruction {
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) return instruction;
        }
        return null;
    }

    fn simpleMirReturnValueSource(block: mir.Block, value_id: []const u8) ?mir.SourcePoint {
        var source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind != .expr) continue;
            if (!std.mem.eql(u8, instruction.detail, value_id)) continue;
            source = instructionSourcePoint(instruction);
        }
        return source;
    }

    fn plainFunctionRenderAttrs(render: anytype) bool {
        return !render.naked and !render.weak and !render.noinline_attr and render.section == null and render.effective_align == null;
    }

    fn simpleMirReturnSpan(self: *LlvmEmitter, fn_mir: mir.Function) ?diagnostics.Span {
        _ = self;
        if (fn_mir.blocks.len != 1) return null;
        const ret = simpleMirReturnInstruction(fn_mir.blocks[0]) orelse return null;
        return spanFromMirSourcePoint(instructionSourcePoint(ret));
    }

    fn instructionSourcePoint(instruction: mir.Instruction) mir.SourcePoint {
        return .{
            .line = instruction.line,
            .column = instruction.column,
            .offset = instruction.source_offset,
            .len = instruction.source_len,
        };
    }

    fn sameMirSourcePoint(a: mir.SourcePoint, b: mir.SourcePoint) bool {
        return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len;
    }

    fn sameMirSourceLocation(a: mir.SourcePoint, b: mir.SourcePoint) bool {
        return a.line == b.line and a.column == b.column;
    }

    fn spanFromMirSourcePoint(source: mir.SourcePoint) diagnostics.Span {
        return .{ .line = source.line, .column = source.column, .offset = source.offset, .len = source.len };
    }

    fn emitFunction(self: *LlvmEmitter, function: anytype, body: ast_bridge.Block, attrs: codegen_attrs.FunctionRenderAttrs) !void {
        const sig_facts = function.signature;
        const ret_ty = sig_facts.return_type orelse simpleType(sig_facts.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        const fn_sig = self.fn_sigs.get(sig_facts.name.text) orelse return error.UnsupportedLlvmEmission;
        const ret_ext = if (fn_sig.c_abi) self.cAbiExtension(ret_ty) else "";
        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_return_ty = self.current_return_ty;
        const old_function = self.current_function;
        const old_params = self.current_params;
        self.current_debug_scope = if (self.fn_sigs.get(sig_facts.name.text)) |sig| sig.debug_id else null;
        self.current_debug_span = sig_facts.name.span;
        self.current_return_ty = ret_ty;
        self.current_function = sig_facts.name.text;
        self.current_params = sig_facts.params;
        const entry_label = try self.functionEntryLabel();
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_return_ty = old_return_ty;
            self.current_function = old_function;
            self.current_params = old_params;
        }
        try self.validateFunctionCleanupAuthority();
        // `#[naked]`: the `naked` function attribute tells LLVM to emit no prologue or
        // epilogue. The body is a single inline-asm statement that performs the
        // ABI-correct jump/return itself; we terminate the entry block with
        // `unreachable` because the asm — not a synthesized `ret` — transfers control.
        const naked = attrs.naked;
        // `#[noinline]`: the LLVM `noinline` function attribute keeps a distinct physical call
        // frame (e.g. a frame-pointer backtrace must walk nested frames). Composes with naked.
        const base_attr_str: []const u8 = if (naked and attrs.noinline_attr)
            " naked noinline"
        else if (naked)
            " naked"
        else if (attrs.noinline_attr)
            " noinline"
        else
            "";
        const attr_str: []const u8 = if (self.linux_kernel and self.target_arch == .x86_64)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind fn_ret_thunk_extern", .{base_attr_str})
        else if (self.linux_kernel and self.target_arch == .aarch64)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind \"branch-target-enforcement\"", .{base_attr_str})
        else if (self.linux_kernel)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind", .{base_attr_str})
        else
            base_attr_str;
        // `#[section("...")]`: emit an LLVM `section "..."` clause so the symbol lands in the
        // named linker section (bare-metal entry points pinned by the linker script, e.g.
        // OpenSBI's `_start` at 0x80200000 via `KEEP(*(.text.boot))`).
        var section_buf: std.ArrayList(u8) = .empty;
        defer section_buf.deinit(self.allocator);
        if (attrs.section) |sec| {
            try section_buf.print(self.allocator, " section \"{s}\"", .{sec});
        }
        const section_str: []const u8 = section_buf.items;
        // `#[align(N)]`: emit an LLVM `align N` function attribute. `#[naked]` functions default
        // to 4-byte alignment — they are trap/entry code whose address is loaded into an
        // alignment-sensitive register (a RISC-V `stvec`/`mtvec` base must be 4-byte aligned;
        // its low two bits are the MODE field, so a 2-byte-aligned vector traps to a bad PC).
        var align_buf: [32]u8 = undefined;
        const align_str: []const u8 = if (attrs.effective_align) |al|
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
        const weak_str: []const u8 = if (attrs.weak)
            "weak "
        else if (!sig_facts.exported)
            "internal "
        else
            "";
        try self.out.print(self.allocator, "define {s}{s}{s} @{s}(", .{ weak_str, ret_ext, ret_llvm, sig_facts.name.text });
        for (sig_facts.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (fn_sig.c_abi) self.cAbiExtension(param.ty) else "";
            try self.out.print(self.allocator, "{s} {s}%{s}", .{ try self.llvmType(param.ty), param_ext, param.name.text });
        }
        // C-ABI variadic tail: `define T @f(named..., ...)`. The body's `va.*` intrinsics
        // (llvm.va_start / the va_arg instruction / llvm.va_end) read the extra args.
        if (sig_facts.is_variadic) {
            if (sig_facts.params.len != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "...");
        }
        // The naked path needs no entry-alloca buffering: its body is a single asm stmt.
        if (naked) {
            if (self.current_debug_scope) |scope| {
                try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\n{s}:\n", .{ attr_str, section_str, align_str, scope, entry_label });
            } else {
                try self.out.print(self.allocator, "){s}{s}{s} {{\n{s}:\n", .{ attr_str, section_str, align_str, entry_label });
            }
            self.temp_index = 0;
            try self.emitAsmStmt(syntax_bridge.nakedAsmStmt(body) orelse return error.UnsupportedLlvmEmission);
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
        for (sig_facts.params, 0..) |param, i| {
            try self.local_types.put(param.name.text, param.ty);
            if (self.isVaListType(param.ty)) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.emitAlloca(ptr, "ptr");
                try self.out.print(self.allocator, "  store ptr %{s}, ptr {s}\n", .{ param.name.text, ptr });
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr, .kind = .va_list_param });
            } else if (self.isAggregateType(param.ty) or lower_llvm_shape.atomicPayloadType(&self.type_aliases, param.ty) != null) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.emitAlloca(ptr, try self.llvmType(param.ty));
                if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, param.ty) != null) {
                    try self.out.print(self.allocator, "  store {s} %{s}, ptr {s}\n", .{ try self.llvmType(param.ty), param.name.text, ptr });
                } else {
                    const value = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{param.name.text});
                    try self.emitConcreteObjectStore(ptr, param.ty, value);
                }
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr });
            } else {
                const value = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{param.name.text});
                try self.emitDebugValue(param.name.text, param.ty, value, param.name.span, i + 1);
            }
        }

        if (!try self.emitBlock(body, ret_ty)) {
            if (typeNameEql(ret_ty, "void")) {
                try self.emitReturnVoid(sig_facts.name.span);
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
            try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\n{s}:\n", .{ attr_str, section_str, align_str, scope, entry_label });
        } else {
            try self.out.print(self.allocator, "){s}{s}{s} {{\n{s}:\n", .{ attr_str, section_str, align_str, entry_label });
        }
        try self.out.appendSlice(self.allocator, alloca_buf.items);
        try self.out.appendSlice(self.allocator, body_buf.items);
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitExternFunction(self: *LlvmEmitter, function: anytype) !void {
        const sig_facts = function.signature;
        // The KASAN shadow hooks (D2.1) get weak no-op `define`s in emitTrapDecl so every
        // build links; skip the `declare` here to avoid an LLVM declare-vs-define clash.
        if (isKsanHook(sig_facts.name.text)) return;
        const ret_ty = sig_facts.return_type orelse simpleType(sig_facts.name.span, "void");
        const sig = self.fn_sigs.get(sig_facts.name.text) orelse return error.UnsupportedLlvmEmission;
        const ret_ext = if (sig.c_abi) self.cAbiExtension(ret_ty) else "";
        try self.out.print(self.allocator, "declare {s}{s} @{s}(", .{ ret_ext, try self.llvmType(ret_ty), sig_facts.name.text });
        for (sig_facts.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (sig.c_abi) self.cAbiExtension(param.ty) else "";
            try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
            if (param_ext.len != 0) try self.out.print(self.allocator, " {s}", .{std.mem.trimEnd(u8, param_ext, " ")});
        }
        if (sig_facts.is_variadic) {
            if (sig_facts.params.len != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "...");
        }
        try self.out.appendSlice(self.allocator, ")\n\n");
    }

    fn reportUnsupported(self: *LlvmEmitter, span: ast_bridge.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            reporter.err(self.diagnosticSpan(span), "E_BACKEND_UNSUPPORTED: LLVM backend does not yet support {s}", .{construct});
        }
    }

    fn reportUnsupportedIfNone(self: *LlvmEmitter, span: ast_bridge.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            if (!reporter.has_errors) {
                reporter.err(self.diagnosticSpan(span), "E_BACKEND_UNSUPPORTED: LLVM backend does not yet support {s}", .{construct});
            }
        }
    }

    fn diagnosticSpan(self: *LlvmEmitter, span: ast_bridge.Span) ast_bridge.Span {
        if (isSourceSpan(span)) return span;
        if (self.current_debug_span) |current| {
            if (isSourceSpan(current)) return current;
        }
        return span;
    }

    fn unsupportedExprValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
        self.reportUnsupported(expr.span, @tagName(expr.kind));
        return error.UnsupportedLlvmEmission;
    }

    fn emitExpr(self: *LlvmEmitter, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        return self.emitExprInner(expr, expected_ty) catch |err| switch (err) {
            error.UnsupportedLlvmEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprWithMirRangeTarget(self: *LlvmEmitter, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr, target: []const u8) anyerror![]const u8 {
        const previous = self.current_mir_range_target;
        self.current_mir_range_target = target;
        defer self.current_mir_range_target = previous;
        return self.emitExpr(expr, expected_ty);
    }

    fn emitExprInner(self: *LlvmEmitter, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const semantic_expected_ty = if (expr.kind == .null_literal)
            if (!isSourceSpan(expr.span))
                expected_ty
            else if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact|
                fact.target_ty
            else
                return error.UnsupportedLlvmEmission
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
            .char_literal => |literal| try self.emitCharLiteralWithTarget(literal, expr.span, semantic_expected_ty),
            .string_literal => |literal| try self.emitStringLiteral(literal, expr.span),
            .float_literal => |literal| if (self.contextualTargetTypeAt(.float_literal, expr.span, semantic_expected_ty)) |target_ty|
                try normalizedFloatLiteral(self.scratch.allocator(), literal, lower_llvm_shape.isF32TypeOf(&self.type_aliases, target_ty))
            else
                error.UnsupportedLlvmEmission,
            .bool_literal => |value| if (value) "1" else "0",
            .null_literal => "null",
            .enum_literal => |literal| if (self.contextualTargetTypeAt(.enum_literal, expr.span, semantic_expected_ty)) |target_ty|
                if (self.enumDeclForType(target_ty)) |enum_decl|
                    try self.enumCaseValueByName(enum_decl, literal.text)
                else
                    error.UnsupportedLlvmEmission
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| self.emitExpr(inner.*, expected_ty),
            .move_expr => |inner| try self.emitExpr(inner.*, expected_ty),
            .call => |call| try self.emitCall(call, expected_ty, expr.span),
            .array_literal => |items| if (self.contextualTargetTypeAt(.array_literal, expr.span, semantic_expected_ty)) |target_ty|
                try self.emitArrayLiteralValue(target_ty, items)
            else
                error.UnsupportedLlvmEmission,
            .struct_literal => |fields| blk: {
                const aggregate = try self.requireMirStructLiteralConstruction(expr.span, semantic_expected_ty);
                break :blk switch (aggregate.construction) {
                    .packed_bits => try self.emitPackedBitsLiteralValue(self.packedBitsInfoForType(aggregate.target_ty) orelse return error.UnsupportedLlvmEmission, fields),
                    .declared_struct, .c_union => try self.emitStructLiteralValue(aggregate.target_ty, fields),
                };
            },
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expr.span),
            .cast => |node| try self.emitCast(expr.span, node.value.*),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .borrow_expr => |node| try self.emitAddressOf(node.value.*),
            .deref => |inner| try self.emitDeref(inner.*, expr.span),
            .index => |node| try self.emitIndexLoad(node, expr.span),
            .slice => |node| try self.emitSlice(node, expr.span),
            .member => |node| if (self.mirTargetTypeFactAt(.enum_variant_path_result, expr.span)) |fact|
                (if (self.enumDeclForType(fact.target_ty)) |enum_decl|
                    try self.enumCaseValueByName(enum_decl, node.name.text)
                else
                    error.UnsupportedLlvmEmission)
            else
                try self.emitMemberLoad(node, expr.span),
            .try_expr => |node| try self.emitTryExpr(node.operand.*, node.mapped, expected_ty),
            .block => |block| try self.emitBlockExprValue(block, expected_ty),
            else => self.unsupportedExprValue(expr),
        };
        // An unsuffixed integer literal is context-typed. `value` is an LLVM
        // constant spelling and already has the caller's `expected_ty`; do not
        // reinterpret the MIR's default literal classification (commonly u32)
        // as a source width and truncate a wide literal before extending it.
        if (expr.kind == .int_literal) {
            const parts = numeric.parseIntegerLiteralParts(expr.kind.int_literal) orelse return error.UnsupportedLlvmEmission;
            if (parts.suffix == null) return value;
        }
        return try self.coerceExprValue(value, expr, expected_ty);
    }

    fn emitBlockExprValue(self: *LlvmEmitter, block: ast_bridge.Block, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (block.items.len == 0) return error.UnsupportedLlvmEmission;
        for (block.items[0 .. block.items.len - 1]) |stmt| {
            switch (stmt.kind) {
                .let_decl, .var_decl, .@"defer", .@"return", .@"break", .@"continue" => return error.UnsupportedLlvmEmission,
                else => {},
            }
            if (try self.emitStmt(stmt, expected_ty)) return error.UnsupportedLlvmEmission;
        }
        const value = switch (block.items[block.items.len - 1].kind) {
            .expr => |expr| expr,
            else => return error.UnsupportedLlvmEmission,
        };
        return self.emitExpr(value, expected_ty);
    }

    fn coerceExprValue(self: *LlvmEmitter, value: []const u8, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (self.mirTargetTypeFactAt(.view_const_narrow_target, expr.span)) |target_fact| {
            const source_fact = self.mirTargetTypeFactAt(.view_const_narrow_source, expr.span) orelse return error.UnsupportedLlvmEmission;
            if (type_bridge.sameTypeSyntax(self.resolveAliasType(target_fact.target_ty), self.resolveAliasType(expected_ty))) {
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
        if (lower_llvm_shape.pointerAddressCoercion(&self.type_aliases, source_ty, expected_ty)) {
            return try self.emitBitcastValue(value, source_ty, expected_ty);
        }
        return value;
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast_bridge.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            if (self.isVaListType(slot.ty)) return try self.emitVaListValueFromSlot(slot);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr, try self.debugCallSuffix() });
            return result;
        }
        if (self.local_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
        if (self.global_types.get(ident.text)) |ty| {
            // Immutable `const` storage cannot participate in a data race.
            // Loading it through the mutable-global race path emits an
            // unnecessary unordered atomic, which also prevents LLVM from
            // folding state-machine constants and inlining their users. Keep
            // the emitted global initializer authoritative and use an ordinary
            // load; LLVM can fold it without backend-side value rediscovery.
            if (self.global_is_const.get(ident.text) orelse false) {
                const const_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                return try self.emitOrdinaryLoad(ty, const_ptr, false);
            }
            const global_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
            try self.emitOrdinaryShadowHook(global_ptr, ty, .load_pre);
            return try self.emitOrdinaryLoad(ty, global_ptr, true);
        }
        if (self.fn_sigs.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
        return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
    }

    fn isVaListType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
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

    fn emitVaListCursorForCopySource(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
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

    fn emitVaListCursorArg(self: *LlvmEmitter, expr: ast_bridge.Expr, cursor_ty: ast_bridge.TypeExpr) ![]const u8 {
        return switch (expr.kind) {
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .borrow_expr => |node| try self.emitAddressOf(node.value.*),
            .grouped => |inner| try self.emitVaListCursorArg(inner.*, cursor_ty),
            else => try self.emitExpr(expr, cursor_ty),
        };
    }

    fn emitVaArg(self: *LlvmEmitter, ap_ptr: []const u8, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (self.target_arch == .aarch64) return try self.emitAarch64VaArg(ap_ptr, ty);

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = va_arg ptr {s}, {s}{s}\n", .{ result, ap_ptr, try self.llvmType(ty), try self.debugCallSuffix() });
        return result;
    }

    fn emitAarch64VaArg(self: *LlvmEmitter, ap_ptr: []const u8, ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitBlock(self: *LlvmEmitter, block: ast_bridge.Block, ret_ty: ast_bridge.TypeExpr) anyerror!bool {
        return try self.emitBlockWithScopeCleanup(block, ret_ty, true);
    }

    fn emitBlockWithScopeCleanup(self: *LlvmEmitter, block: ast_bridge.Block, ret_ty: ast_bridge.TypeExpr, emit_scope_cleanup: bool) anyerror!bool {
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
        if (emit_scope_cleanup) try self.emitCleanupEdge(.scope_exit, ret_ty, block.span, null);
        return false;
    }

    fn emitStmt(self: *LlvmEmitter, stmt: ast_bridge.Stmt, ret_ty: ast_bridge.TypeExpr) anyerror!bool {
        switch (stmt.kind) {
            .let_decl => |local| try self.emitLocalDecl(local, false),
            .var_decl => |local| try self.emitLocalDecl(local, true),
            .assignment => |node| try self.emitAssignment(node.target, node.value, stmt.span),
            .@"defer" => |expr| {
                const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
                const deferred_drop = backend_cleanup.registerDeferredExplicitDropCleanup(&self.mir_module, function, self.currentOwnershipCleanupPlan(), expr.span);
                switch (deferred_drop) {
                    .ignored => {},
                    .applied => {
                        try self.validateCleanupCfg();
                    },
                    .rejected => return error.UnsupportedLlvmEmission,
                }
                const defer_ref = mir_source_bridge.deferCleanupRefAtSpan(function.*, stmt.span) orelse return error.UnsupportedLlvmEmission;
                const cleanup_cfg = self.currentCleanupCfg() orelse return error.UnsupportedLlvmEmission;
                if (try self.ordinaryDeferDirectCallCleanup(function, expr, defer_ref)) |cleanup| {
                    switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, cleanup.defer_ref)) {
                        .applied => {},
                        .ignored, .rejected => return error.UnsupportedLlvmEmission,
                    }
                    return false;
                }
                if (try self.ordinaryDeferCallTargetCleanup(function, expr, defer_ref)) |cleanup| {
                    switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, cleanup.defer_ref)) {
                        .applied => {},
                        .ignored, .rejected => return error.UnsupportedLlvmEmission,
                    }
                    return false;
                }
                switch (expr.kind) {
                    .block => {
                        switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, defer_ref)) {
                            .applied => {},
                            .ignored, .rejected => return error.UnsupportedLlvmEmission,
                        }
                    },
                    else => return error.UnsupportedLlvmEmission,
                }
            },
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
                    try self.emitCleanupEdge(.return_exit, ret_ty, null, stmt.span);
                    try self.emitReturnVoid(stmt.span);
                } else if (typeNameEql(ret_ty, "never")) {
                    return error.UnsupportedLlvmEmission;
                } else {
                    const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                    const value = try self.emitExprWithMirRangeTarget(expr, ret_ty, "value");
                    try self.emitCleanupEdge(.return_exit, ret_ty, null, stmt.span);
                    try self.emitReturnValue(ret_ty, value, stmt.span);
                }
                return true;
            },
            .@"switch" => |node| {
                const subject_info = try self.requireMirSwitchSubjectType(node.subject);
                const subject_ty = subject_info.target_ty;
                if (try self.emitNullableSwitch(node, ret_ty, subject_ty, subject_info.nullable_representation)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitResultSwitch(node, ret_ty, subject_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitTaggedUnionSwitch(node, ret_ty, subject_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                if (try self.emitScalarSwitch(node, ret_ty, subject_ty)) |terminated| {
                    if (terminated) return true;
                    return false;
                }
                self.reportUnsupported(stmt.span, "switch statement");
                return error.UnsupportedLlvmEmission;
            },
            .if_let => |node| {
                const subject_info = try self.requireMirIfLetSubjectType(node.value);
                const subject_ty = subject_info.target_ty;
                if (try self.emitResultIfLet(node, ret_ty, subject_ty)) return true;
                if (try self.emitNullableIfLet(node, ret_ty, subject_ty, subject_info.nullable_representation)) return true;
            },
            .@"break" => |target| {
                const labels = self.resolveLoopLabels(target) orelse return error.UnsupportedLlvmEmission;
                try self.emitCleanupEdge(.break_exit, ret_ty, null, stmt.span);
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ labels.break_label, try self.debugCallSuffix() });
                return true;
            },
            .@"continue" => |target| {
                const labels = self.resolveLoopLabels(target) orelse return error.UnsupportedLlvmEmission;
                try self.emitCleanupEdge(.continue_exit, ret_ty, null, stmt.span);
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
    fn resolveLoopLabels(self: *LlvmEmitter, target: ?ast_bridge.Ident) ?LoopLabels {
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

    fn emitCleanupEdge(self: *LlvmEmitter, kind: backend_cleanup.CleanupEdgeKind, ret_ty: ast_bridge.TypeExpr, scope_span: ?ast_bridge.Span, before_span: ?ast_bridge.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        var plan = (try backend_cleanup.buildCleanupEdgePlan(self.allocator, &self.mir_module, function.*, self.currentOwnershipCleanupPlan(), self.currentCleanupCfg(), kind, sourcePointFromOptionalSpan(scope_span), sourcePointFromOptionalSpan(before_span))) orelse return error.UnsupportedLlvmEmission;
        defer plan.deinit(self.allocator);
        for (plan.refs) |ref| {
            try self.emitCleanupRef(ref, ret_ty);
        }
    }

    fn validateCleanupCfg(self: *LlvmEmitter) !void {
        if (self.currentMirFunction() == null or self.currentCleanupCfg() == null) return error.UnsupportedLlvmEmission;
    }

    fn validateFunctionCleanupAuthority(self: *LlvmEmitter) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        const cleanup_plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedLlvmEmission;
        const cleanup_cfg = self.currentCleanupCfg() orelse return error.UnsupportedLlvmEmission;
        if (!backend_cleanup.validateFunctionCleanupAuthority(&self.mir_module, function, cleanup_plan, cleanup_cfg)) return error.UnsupportedLlvmEmission;
    }

    fn emitCleanupRef(self: *LlvmEmitter, ref: backend_cleanup.CleanupRef, ret_ty: ast_bridge.TypeExpr) !void {
        switch (ref) {
            .defer_ref => |defer_ref| {
                const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
                const expr = self.deferExprForRef(defer_ref) orelse return error.UnsupportedLlvmEmission;
                if (try self.ordinaryDeferDirectCallCleanup(function, expr, defer_ref)) |cleanup| {
                    try self.emitOrdinaryDeferDirectCallCleanup(cleanup);
                    return;
                }
                if (try self.ordinaryDeferCallTargetCleanup(function, expr, defer_ref)) |cleanup| {
                    try self.emitCallTargetDeferCleanup(cleanup);
                    return;
                }
                switch (expr.kind) {
                    .block => |block| if (try self.emitScopedBlockWithCleanup(block, ret_ty, false)) return error.UnsupportedLlvmEmission,
                    else => return error.UnsupportedLlvmEmission,
                }
            },
            .ownership_action => |action_ref| {
                const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedLlvmEmission;
                if (action_ref.cleanup_action_index >= plan.actions.len) return error.UnsupportedLlvmEmission;
                switch (plan.actions[action_ref.cleanup_action_index].kind) {
                    .auto_drop => try self.emitAutoDropPointerCleanup(action_ref),
                    .explicit_drop => try self.emitExplicitDropPointerCleanup(action_ref),
                }
            },
        }
    }

    fn deferExprForRef(self: *LlvmEmitter, ref: mir.DeferCleanupRef) ?ast_bridge.Expr {
        const function = self.currentMirFunction() orelse return null;
        if (!mir.deferCleanupRefValid(function.*, ref)) return null;
        return mir.deferCleanupExprForRef(function.*, ref);
    }

    fn ordinaryDeferDirectCallCleanup(self: *LlvmEmitter, function: *const mir.Function, expr: ast_bridge.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedLlvmEmission}!?backend_cleanup.OrdinaryDeferCallCleanup {
        const call = syntax_bridge.callExpr(expr) orelse return null;
        if (call.type_args.len != 0) return null;
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const sig = self.fn_sigs.get(fn_name) orelse return null;
        if (sig.is_variadic or call.args.len != sig.params.len) return error.UnsupportedLlvmEmission;
        if (!mir_source_bridge.directDeferCallCleanupForSpans(function.*, defer_ref, expr.span, call.callee.*.span, fn_name, call.args)) return error.UnsupportedLlvmEmission;
        return .{ .defer_ref = defer_ref, .fn_name = fn_name, .span = expr.span, .callee_span = call.callee.*.span, .args = call.args };
    }

    fn ordinaryDeferCallTargetCleanup(self: *LlvmEmitter, function: *const mir.Function, expr: ast_bridge.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedLlvmEmission}!?backend_cleanup.CallTargetDeferCleanup {
        const call = syntax_bridge.callExpr(expr) orelse return null;
        const kind = self.mirCallTargetKindAt(call.callee.*.span) orelse return null;
        switch (kind) {
            .cpu_pause, .fence_full, .fence_release, .fence_acquire => {
                if (call.type_args.len != 0 or call.args.len != 0) return null;
            },
            .raw_store => {
                if (!syntax_bridge.isRawStoreCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 2) return null;
            },
            .mmio_write => {
                if (call.type_args.len != 0 or call.args.len != 2) return null;
            },
            .mmio_read => {
                if (call.type_args.len != 0 or call.args.len != 1) return null;
            },
            .dma_cache_clean, .dma_cache_invalidate => {
                if (call.type_args.len != 0 or call.args.len != 1) return null;
            },
            .maybe_uninit_write => {
                if (call.type_args.len != 0 or call.args.len != 1) return null;
            },
            .atomic_store => {
                if (call.type_args.len != 0 or call.args.len != 2) return null;
            },
            .va_end => {
                if (call.type_args.len != 0 or call.args.len != 1) return null;
            },
            else => return null,
        }
        if (!mir_source_bridge.callTargetDeferCleanupForSpans(function.*, defer_ref, expr.span, call.callee.*.span, kind)) return error.UnsupportedLlvmEmission;
        return .{ .defer_ref = defer_ref, .kind = kind, .span = expr.span, .callee = call.callee.*, .callee_span = call.callee.*.span, .type_args = call.type_args, .args = call.args };
    }

    fn emitCallTargetDeferCleanup(self: *LlvmEmitter, cleanup: backend_cleanup.CallTargetDeferCleanup) !void {
        if (!mir_source_bridge.callTargetDeferCleanupForSpans((self.currentMirFunction() orelse return error.UnsupportedLlvmEmission).*, cleanup.defer_ref, cleanup.span, cleanup.callee_span, cleanup.kind)) return error.UnsupportedLlvmEmission;
        switch (cleanup.kind) {
            .cpu_pause => try self.out.print(self.allocator, "  call void asm sideeffect \"pause\", \"~{{memory}}\"(){s}\n", .{try self.debugCallSuffix()}),
            .fence_full => try self.out.print(self.allocator, "  fence seq_cst{s}\n", .{try self.debugCallSuffix()}),
            .fence_release => try self.out.print(self.allocator, "  fence release{s}\n", .{try self.debugCallSuffix()}),
            .fence_acquire => try self.out.print(self.allocator, "  fence acquire{s}\n", .{try self.debugCallSuffix()}),
            .raw_store => try self.emitRawStorePayload(cleanup.callee_span, cleanup.type_args, cleanup.args),
            .mmio_write => try self.emitMmioWritePayload(cleanup.callee, cleanup.args),
            .mmio_read => _ = try self.emitMmioReadPayload(cleanup.callee, cleanup.args),
            .dma_cache_clean, .dma_cache_invalidate => try self.emitDmaCachePayload(cleanup.callee, cleanup.args, cleanup.kind),
            .maybe_uninit_write => try self.emitMaybeUninitWritePayload(cleanup.callee, cleanup.args),
            .atomic_store => try self.emitAtomicStorePayload(cleanup.callee, cleanup.args),
            .va_end => try self.emitVaEndPayload(cleanup.callee, cleanup.args),
            else => return error.UnsupportedLlvmEmission,
        }
    }

    fn emitOrdinaryDeferDirectCallCleanup(self: *LlvmEmitter, cleanup: backend_cleanup.OrdinaryDeferCallCleanup) !void {
        defer self.applyMirPointerProvenanceInvalidationsAtCall(cleanup.span);
        defer self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        defer self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        defer self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
        defer self.local_pointer_array_aliases.clearRetainingCapacity();
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        if (!mir_source_bridge.directDeferCallCleanupForSpans(function.*, cleanup.defer_ref, cleanup.span, cleanup.callee_span, cleanup.fn_name, cleanup.args)) return error.UnsupportedLlvmEmission;
        const sig = self.fn_sigs.get(cleanup.fn_name) orelse return error.UnsupportedLlvmEmission;
        if (sig.is_variadic or cleanup.args.len != sig.params.len) return error.UnsupportedLlvmEmission;
        if (typeNameEql(sig.ret, "void") or typeNameEql(sig.ret, "never")) {
            try self.emitVoidDirectCall(cleanup.fn_name, cleanup.args, cleanup.callee_span);
            return;
        }
        var callee_expr: ast_bridge.Expr = .{
            .span = cleanup.callee_span,
            .kind = .{ .ident = .{ .text = cleanup.fn_name, .span = cleanup.callee_span } },
        };
        const call = struct {
            callee: *ast_bridge.Expr,
            args: []const ast_bridge.Expr,
        }{ .callee = &callee_expr, .args = cleanup.args };
        _ = try self.emitDirectCall(cleanup.fn_name, call, sig.ret);
    }

    fn emitAutoDropPointerCleanup(self: *LlvmEmitter, ref: mir_ownership_authority.OwnershipCleanupActionRef) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedLlvmEmission;
        const cleanup = mir_ownership_authority.autoDropLocalCleanupFromActionRef(&self.mir_module, function, plan, ref) orelse return error.UnsupportedLlvmEmission;
        const slot = self.local_slots.get(cleanup.local_name) orelse return error.UnsupportedLlvmEmission;
        try self.out.print(self.allocator, "  call void @{s}(ptr {s})\n", .{ cleanup.fn_name, slot.ptr });
    }

    fn emitExplicitDropPointerCleanup(self: *LlvmEmitter, ref: mir_ownership_authority.OwnershipCleanupActionRef) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedLlvmEmission;
        const cleanup = mir_ownership_authority.explicitDropLocalCleanupFromActionRef(&self.mir_module, function, plan, ref) orelse return error.UnsupportedLlvmEmission;
        const slot = self.local_slots.get(cleanup.local_name) orelse return error.UnsupportedLlvmEmission;
        try self.out.print(self.allocator, "  call void @{s}(ptr {s})\n", .{ cleanup.fn_name, slot.ptr });
    }

    fn emitScopedBlock(self: *LlvmEmitter, block: ast_bridge.Block, ret_ty: ast_bridge.TypeExpr) !bool {
        return try self.emitScopedBlockWithCleanup(block, ret_ty, true);
    }

    fn emitScopedBlockWithCleanup(self: *LlvmEmitter, block: ast_bridge.Block, ret_ty: ast_bridge.TypeExpr, emit_scope_cleanup: bool) !bool {
        var saved_types = std.StringHashMap(ast_bridge.TypeExpr).init(self.allocator);
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

        const terminated = try self.emitBlockWithScopeCleanup(block, ret_ty, emit_scope_cleanup);
        try self.preserveOuterPointerLocalProvenanceAfterScope(&saved_types, &saved_pointer_local_provenance);
        try self.preserveOuterAggregatePointerFieldProvenanceAfterScope(&saved_types, &saved_aggregate_global_pointer_fields);
        try self.preserveOuterLocalArrayPointerElementProvenanceAfterScope(&saved_types, &saved_local_array_global_pointer_elements);
        return terminated;
    }

    fn preserveOuterPointerLocalProvenanceAfterScope(
        self: *LlvmEmitter,
        saved_types: *const std.StringHashMap(ast_bridge.TypeExpr),
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
        saved_types: *const std.StringHashMap(ast_bridge.TypeExpr),
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
        saved_types: *const std.StringHashMap(ast_bridge.TypeExpr),
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

    fn emitAsmStmt(self: *LlvmEmitter, asm_stmt: ast_bridge.AsmStmt) !void {
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

    fn emitPreciseAsmStmt(self: *LlvmEmitter, asm_stmt: ast_bridge.AsmStmt) !void {
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
        const constraints = try llvmPreciseAsmConstraints(self.scratch.allocator(), asm_stmt.outputs.len, asm_stmt.inputs.len, asm_stmt.clobbers);
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

    fn preciseAsmReturnType(self: *LlvmEmitter, outputs: []const ast_bridge.AsmOutput) ![]const u8 {
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

    fn emitExprStatement(self: *LlvmEmitter, expr: ast_bridge.Expr) anyerror!void {
        self.emitExprStatementInner(expr) catch |err| switch (err) {
            error.UnsupportedLlvmEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprStatementInner(self: *LlvmEmitter, expr: ast_bridge.Expr) anyerror!void {
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
                const call_span = call.callee.*.span;
                const call_kind = self.mirCallTargetKindAt(call_span);
                if (call_kind) |kind| {
                    switch (kind) {
                        .drop, .forget_unchecked => {
                            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                            const argument_ty = try self.requireMirDiscardArgumentTypeForEmission(call.args[0]);
                            _ = try self.emitExpr(call.args[0], argument_ty);
                            return;
                        },
                        else => {},
                    }
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
                if (call_kind) |kind| {
                    switch (kind) {
                        .va_start, .va_arg, .va_end => {
                            _ = try self.emitCall(call, simpleType(expr.span, "void"), expr.span);
                            return;
                        },
                        else => {},
                    }
                }
                if (self.callResultTypeForEmission(call)) |ret_ty| {
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
            .move_expr => |inner| {
                try self.emitExprStatement(inner.*);
            },
            else => {
                const ty = self.exprStatementTypeForEmission(expr) orelse {
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

    fn emitAllocaConcreteStore(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr, value: []const u8) !void {
        try self.emitAlloca(ptr, try self.llvmType(ty));
        try self.emitConcreteObjectStore(ptr, ty, value);
    }

    fn emitZeroObjectBytes(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr) !void {
        const size = std.math.cast(u64, self.comptimeSizeOf(ty, 0) orelse return error.UnsupportedLlvmEmission) orelse return error.UnsupportedLlvmEmission;
        const alignment = std.math.cast(u64, self.comptimeAlignOf(ty, 0) orelse return error.UnsupportedLlvmEmission) orelse return error.UnsupportedLlvmEmission;
        if (alignment == 0) return error.UnsupportedLlvmEmission;
        if (size == 0) return;
        try self.out.print(self.allocator, "  call void @llvm.memset.p0.i64(ptr align {d} {s}, i8 0, i64 {d}, i1 false){s}\n", .{ alignment, ptr, size, try self.debugCallSuffix() });
    }

    fn emitPaddingPreservingStore(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr, value: []const u8) !void {
        const resolved = self.resolveAliasType(ty);
        if (lower_llvm_shape.maybeUninitPayloadType(&self.type_aliases, resolved)) |payload_ty| {
            try self.emitPaddingPreservingStore(ptr, payload_ty, value);
            return;
        }
        switch (resolved.kind) {
            .nullable => |child| {
                if (self.nullablePayloadIsValueType(child.*)) {
                    const optional_llvm = try self.llvmType(resolved);
                    const present = try self.nextTemp();
                    const present_ptr = try self.nextTemp();
                    const payload = try self.nextTemp();
                    const payload_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ present, optional_llvm, value });
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ present_ptr, optional_llvm, ptr });
                    try self.out.print(self.allocator, "  store i1 {s}, ptr {s}{s}\n", .{ present, present_ptr, try self.debugCallSuffix() });
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, optional_llvm, value });
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 1\n", .{ payload_ptr, optional_llvm, ptr });
                    try self.emitPaddingPreservingStore(payload_ptr, child.*, payload);
                    return;
                }
            },
            .array => |array| {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const array_llvm = try self.llvmType(resolved);
                for (0..len) |i| {
                    const element = try self.nextTemp();
                    const element_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ element, array_llvm, value, i });
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ element_ptr, array_llvm, ptr, i });
                    try self.emitPaddingPreservingStore(element_ptr, array.child.*, element);
                }
                return;
            },
            .name, .qualified => {
                const struct_decl = self.structDeclForType(resolved) orelse {
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(resolved), value, ptr, try self.debugCallSuffix() });
                    return;
                };
                if (struct_decl.is_c_union) {
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(resolved), value, ptr, try self.debugCallSuffix() });
                    return;
                }
                const struct_llvm = try self.llvmType(resolved);
                for (struct_decl.fields, 0..) |field, i| {
                    const field_value = try self.nextTemp();
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, struct_llvm, value, i });
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, struct_llvm, ptr, i });
                    try self.emitPaddingPreservingStore(field_ptr, field.ty, field_value);
                }
                return;
            },
            .generic => |node| {
                if (lower_llvm_shape.resultInfo(&self.type_aliases, resolved)) |info| {
                    const result_llvm = try self.llvmType(resolved);
                    const tag = try self.nextTemp();
                    const tag_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ tag, result_llvm, value });
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, result_llvm, ptr });
                    try self.out.print(self.allocator, "  store i1 {s}, ptr {s}{s}\n", .{ tag, tag_ptr, try self.debugCallSuffix() });
                    const payloads = [_]struct { ty: ast_bridge.TypeExpr, index: u8 }{
                        .{ .ty = info.ok_ty, .index = 1 },
                        .{ .ty = info.err_ty, .index = 2 },
                    };
                    for (payloads) |payload_info| {
                        const payload = try self.nextTemp();
                        const payload_ptr = try self.nextTemp();
                        const payload_llvm = try self.resultPayloadLlvmType(payload_info.ty);
                        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, result_llvm, value, payload_info.index });
                        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ payload_ptr, result_llvm, ptr, payload_info.index });
                        if (typeNameEql(self.resolveAliasType(payload_info.ty), "void")) {
                            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ payload_llvm, payload, payload_ptr, try self.debugCallSuffix() });
                        } else {
                            try self.emitPaddingPreservingStore(payload_ptr, payload_info.ty, payload);
                        }
                    }
                    return;
                }
                if ((std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits") or isPayloadDomainGenericName(node.base.text)) and node.args.len >= 1) {
                    try self.emitPaddingPreservingStore(ptr, node.args[0], value);
                    return;
                }
            },
            else => {},
        }
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(resolved), value, ptr, try self.debugCallSuffix() });
    }

    fn emitConcreteObjectStore(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr, value: []const u8) !void {
        if (!self.isAggregateType(ty)) {
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(ty), value, ptr, try self.debugCallSuffix() });
            return;
        }
        try self.emitZeroObjectBytes(ptr, ty);
        try self.emitPaddingPreservingStore(ptr, ty, value);
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

    fn emitAssert(self: *LlvmEmitter, expr: ast_bridge.Expr) !void {
        const ty = try self.requireMirBoolTargetTypeForEmission(.assert_condition, expr);
        const condition = try self.emitExpr(expr, ty);
        const cont = try self.nextLabel("assert_ok");
        const trap = try self.nextLabel("trap_assert");
        try self.emitTrapBranch(condition, cont, trap, trap, cont, "Assert");
    }

    fn emitTryExpr(self: *LlvmEmitter, operand: ast_bridge.Expr, mapped: ?*ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        const operand_ty = try self.requireMirTryOperandType(operand);
        _ = try self.llvmType(expected_ty);
        if (lower_llvm_shape.resultInfo(&self.type_aliases, operand_ty)) |info| {
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
        const inner_ty = lower_llvm_shape.nullableInnerType(&self.type_aliases, operand_ty) orelse return error.UnsupportedLlvmEmission;
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

    fn emitResultPropagationCheck(self: *LlvmEmitter, value: []const u8, operand_ty: ast_bridge.TypeExpr, info: ResultTypeInfo, mapped: ?*ast_bridge.Expr, span: ast_bridge.Span) !bool {
        const return_ty = self.current_return_ty orelse return false;
        const return_info = lower_llvm_shape.resultInfo(&self.type_aliases, return_ty) orelse return false;
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
                const convert_sig = self.fn_sigs.get(cf) orelse return error.UnsupportedLlvmEmission;
                const converted = try self.nextTemp();
                const ret_ext = if (convert_sig.c_abi) self.cAbiExtension(return_info.err_ty) else "";
                const arg_ext = if (convert_sig.c_abi) self.cAbiExtension(info.err_ty) else "";
                try self.out.print(self.allocator, "  {s} = call {s}{s} @{s}({s} {s}{s}){s}\n", .{ converted, ret_ext, try self.llvmType(return_info.err_ty), cf, try self.llvmType(info.err_ty), arg_ext, err_value, try self.debugCallSuffix() });
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
        try self.emitCleanupEdge(.error_exit, return_ty, null, null);
        try self.emitReturnValue(return_ty, propagated_value, span);
        try self.out.print(self.allocator, "{s}:\n", .{ok_label});
        return true;
    }

    fn emitResultUnwrapCheck(self: *LlvmEmitter, value: []const u8, result_ty: ast_bridge.TypeExpr) !void {
        const is_ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_result");
        const cont = try self.nextLabel("result_ok");
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(result_ty), value });
        try self.emitTrapBranch(is_ok, cont, trap, trap, cont, "InvalidRepresentation");
    }

    // The pointer word a nullable niche-tests against: a thin `?*T` value IS the pointer;
    // a `?*dyn Trait` fat pointer's niche is its data word (`extractvalue … , 0`).
    fn nullableDataWord(self: *LlvmEmitter, value: []const u8, inner_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (!isDynTraitLlvmType(self.resolveAliasType(inner_ty))) return value;
        const data = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {{ ptr, ptr }} {s}, 0\n", .{ data, value });
        return data;
    }

    fn emitNullableSomeTest(self: *LlvmEmitter, dest: []const u8, value: []const u8, inner_ty: ast_bridge.TypeExpr) !void {
        const word = try self.nullableDataWord(value, inner_ty);
        try self.out.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ dest, word });
    }

    fn emitNullUnwrapCheck(self: *LlvmEmitter, value: []const u8, inner_ty: ast_bridge.TypeExpr) !void {
        const word = try self.nullableDataWord(value, inner_ty);
        const is_null = try self.nextTemp();
        const trap = try self.nextLabel("trap_null");
        const cont = try self.nextLabel("nonnull");
        try self.out.print(self.allocator, "  {s} = icmp eq ptr {s}, null\n", .{ is_null, word });
        try self.emitTrapBranch(is_null, trap, cont, trap, cont, "NullUnwrap");
    }

    fn emitNullableIfLet(self: *LlvmEmitter, node: ast_bridge.IfLet, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr, representation: ?NullableRepresentation) !bool {
        const binding = switch (node.pattern.kind) {
            .bind => |ident| ident,
            else => return false,
        };
        const inner_ty = lower_llvm_shape.nullableInnerType(&self.type_aliases, subject_ty) orelse return false;
        const nullable_representation = representation orelse return error.UnsupportedLlvmEmission;
        const subject = try self.emitExpr(node.value, subject_ty);
        const then_label = try self.nextLabel("nullable_some");
        const else_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        if (nullable_representation == .value) {
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
        defer restoreLocal(&self.local_types, binding.text, old_type);
        defer restoreLocal(&self.local_slots, binding.text, old_slot);
        defer restoreLocal(&self.pointer_local_provenance, binding.text, old_global_pointer);
        defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.text, old_aggregate_pointer_alias);
        defer restoreLocal(&self.local_pointer_array_aliases, binding.text, old_pointer_array_alias);
        defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.text, old_slice_global_pointer_array);
        defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.text, old_slice_pointer_array_range);
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.text, old_slice_aggregate_pointer_array_field);
        defer self.restoreAggregatePointerFieldsForLocal(binding.text, &old_aggregate_pointer_fields);
        defer self.restoreLocalArrayPointerElementsForLocal(binding.text, &old_local_array_pointer_elements);

        const binding_ptr = try self.nextBindingPtr(binding.text);
        const binding_value = if (nullable_representation == .value) blk: {
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, try self.llvmType(subject_ty), subject });
            break :blk payload;
        } else subject;
        try self.emitAllocaConcreteStore(binding_ptr, inner_ty, binding_value);
        try self.local_types.put(binding.text, inner_ty);
        try self.local_slots.put(binding.text, .{ .ty = inner_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlockWithDeferStackSnapshot(node.then_block, ret_ty);
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
        const else_terminated = if (node.else_block) |else_block| try self.emitBlockWithDeferStackSnapshot(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultIfLet(self: *LlvmEmitter, node: ast_bridge.IfLet, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) !bool {
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
        const info = lower_llvm_shape.resultInfo(&self.type_aliases, subject_ty) orelse return false;
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
        defer restoreLocal(&self.local_types, tag_bind.binding.text, old_type);
        defer restoreLocal(&self.local_slots, tag_bind.binding.text, old_slot);
        defer restoreLocal(&self.pointer_local_provenance, tag_bind.binding.text, old_global_pointer);
        defer restoreLocal(&self.local_aggregate_pointer_aliases, tag_bind.binding.text, old_aggregate_pointer_alias);
        defer restoreLocal(&self.local_pointer_array_aliases, tag_bind.binding.text, old_pointer_array_alias);
        defer restoreLocal(&self.local_slice_global_pointer_arrays, tag_bind.binding.text, old_slice_global_pointer_array);
        defer restoreLocal(&self.local_slice_pointer_array_ranges, tag_bind.binding.text, old_slice_pointer_array_range);
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, tag_bind.binding.text, old_slice_aggregate_pointer_array_field);
        defer self.restoreAggregatePointerFieldsForLocal(tag_bind.binding.text, &old_aggregate_pointer_fields);
        defer self.restoreLocalArrayPointerElementsForLocal(tag_bind.binding.text, &old_local_array_pointer_elements);

        const binding_ptr = try self.nextBindingPtr(tag_bind.binding.text);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
        try self.emitAllocaConcreteStore(binding_ptr, binding_ty, payload);
        try self.local_types.put(tag_bind.binding.text, binding_ty);
        try self.local_slots.put(tag_bind.binding.text, .{ .ty = binding_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlockWithDeferStackSnapshot(node.then_block, ret_ty);
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
        const else_terminated = if (node.else_block) |else_block| try self.emitBlockWithDeferStackSnapshot(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitNeverExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) !bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.out.print(self.allocator, "  call void @mc_trap_Unreachable(){s}\n  unreachable\n", .{try self.debugCallSuffix()});
                return true;
            },
            .call => |call| {
                const helper = self.trapHelperForCall(call) orelse return false;
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "  call void @{s}(){s}\n  unreachable\n", .{ helper, try self.debugCallSuffix() });
                return true;
            },
            .grouped, .move_expr => |inner| return try self.emitNeverExpr(inner.*),
            else => return false,
        }
        return false;
    }

    // True when an expression *statement* emits its own `unreachable` terminator: `unreachable`
    // or a `trap(...)`. Such a statement terminates its block, so even in a value-returning
    // function the block ends there with no fall-through. (A `-> never` call is NOT included: it
    // lowers as an ordinary call and the enclosing block falls through to its normal terminator.)
    fn exprStatementDiverges(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .unreachable_expr => true,
            .call => |call| blk: {
                break :blk self.trapHelperForCall(call) != null;
            },
            .grouped, .move_expr => |inner| self.exprStatementDiverges(inner.*),
            else => false,
        };
    }

    fn trapHelperForCall(self: *LlvmEmitter, call: anytype) ?[]const u8 {
        const call_span = call.callee.*.span;
        const kind = self.mirCallTargetKindAt(call_span) orelse return null;
        return mir.explicitTrapHelperForTarget(kind);
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast_bridge.LocalDecl, is_mutable: bool) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const ty = if (local.ty) |decl_ty|
            decl_ty
        else if (self.mirTargetTypeFactAtOwned(.inferred_local, init.span, local.names[0].text, null) != null)
            try self.requireMirInferredLocalType(local.names[0].text, init)
        else
            self.exprType(init) orelse return error.UnsupportedLlvmEmission;
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
            try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr, .kind = .va_list_local, .is_mutable = is_mutable });
            const dst = try self.vaListCursorPtrFromStorage(ptr);
            if (init.kind == .call) {
                const call = init.kind.call;
                const call_span = call.callee.*.span;
                const call_kind = self.mirCallTargetKindAt(call_span);
                if (call_kind) |kind| {
                    if (kind == .va_start) {
                        const info = self.vaCallInfo(call, kind) orelse return error.UnsupportedLlvmEmission;
                        if (info.kind != .va_start) return error.UnsupportedLlvmEmission;
                        try self.out.print(self.allocator, "  call void @llvm.va_start(ptr {s})\n", .{dst});
                        return;
                    }
                }
            }
            const src = try self.emitVaListCursorForCopySource(init);
            try self.out.print(self.allocator, "  call void @llvm.va_copy(ptr {s}, ptr {s})\n", .{ dst, src });
            return;
        }
        const llvm_ty = try self.llvmType(ty);
        try self.emitAlloca(ptr, llvm_ty);
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr, .is_mutable = is_mutable });
        try self.updatePointerProvenanceFromMirOrLocalProof(name, ty, init, .emit_comment);
        try self.updateAggregatePointerAliasProvenance(name, ty, init);
        try self.updateLocalPointerArrayAliasProvenanceFromInit(name, ty, init);
        try self.updateAggregatePointerFieldProvenanceFromInit(name, ty, init);
        try self.updateLocalArrayPointerElementProvenanceFromInit(name, ty, init);
        try self.updateLocalSlicePointerElementProvenanceFromInit(name, ty, init);
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty)) try self.applyMirPointerProvenanceForLocalInitializer(name, ty, init);
        try self.emitDebugDeclare(name, ty, ptr, local.names[0].span, null);
        // `var ap: va_list = va.start();` — the slot IS the va_list cursor storage; initialize
        // it in place with llvm.va_start (it has no value to store).
        if (init.kind == .call) {
            const call = init.kind.call;
            const call_span = call.callee.*.span;
            const call_kind = self.mirCallTargetKindAt(call_span);
            if (call_kind) |kind| {
                if (kind == .va_start) {
                    const info = self.vaCallInfo(call, kind) orelse return error.UnsupportedLlvmEmission;
                    if (info.kind != .va_start) return error.UnsupportedLlvmEmission;
                    try self.out.print(self.allocator, "  call void @llvm.va_start(ptr {s})\n", .{ptr});
                    return;
                }
            }
        }
        if (isUninitExpr(init)) {
            if (self.isAggregateType(ty)) {
                try self.emitZeroObjectBytes(ptr, ty);
            } else {
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, try self.zeroInitializer(ty), ptr, try self.debugCallSuffix() });
            }
            return;
        }
        if (resolved_ty.kind == .array) {
            if (init.kind == .array_literal) {
                try self.emitArrayLiteralStores(ptr, resolved_ty, init.kind.array_literal);
            } else {
                const value = try self.emitExprWithMirRangeTarget(init, ty, name);
                try self.emitConcreteObjectStore(ptr, ty, value);
            }
            return;
        }
        if (self.structDeclForType(resolved_ty)) |_| {
            if (init.kind == .struct_literal) {
                _ = try self.requireMirStructLiteralConstruction(init.span, resolved_ty);
                try self.emitStructLiteralStores(ptr, resolved_ty, init.kind.struct_literal);
            } else {
                const value = try self.emitExprWithMirRangeTarget(init, ty, name);
                try self.emitConcreteObjectStore(ptr, ty, value);
            }
            return;
        }
        const value = try self.emitExprWithMirRangeTarget(init, ty, name);
        try self.emitConcreteObjectStore(ptr, ty, value);
    }

    fn requireMirInferredLocalType(self: *LlvmEmitter, name: []const u8, initializer: ast_bridge.Expr) !ast_bridge.TypeExpr {
        const fact_ty = (self.mirTargetTypeFactAtOwned(.inferred_local, initializer.span, name, null) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (self.directAddressOfLocalPlace(initializer)) |place| {
            const pointer = switch (self.resolveAliasType(fact_ty).kind) {
                .pointer => |node| node,
                else => return error.UnsupportedLlvmEmission,
            };
            if (pointer.mutability != place.mutability) return error.UnsupportedLlvmEmission;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointer.child.*), self.resolveAliasType(place.ty))) return error.UnsupportedLlvmEmission;
            return fact_ty;
        }
        if (try self.requireMirTryExpressionResultType(initializer)) |known_ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(known_ty))) return error.UnsupportedLlvmEmission;
            return fact_ty;
        }
        if (try self.requireMirBinaryExpressionResultType(initializer)) |known_ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(known_ty))) return error.UnsupportedLlvmEmission;
            return fact_ty;
        }
        if (self.exprType(initializer)) |known_ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(known_ty))) return error.UnsupportedLlvmEmission;
        }
        return fact_ty;
    }

    fn requireMirTryExpressionResultType(self: *LlvmEmitter, initializer: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (initializer.kind) {
            .grouped => |inner| try self.requireMirTryExpressionResultType(inner.*),
            .try_expr => |node| blk: {
                const result_ty = (self.mirTargetTypeFactAt(.expression_result, initializer.span) orelse return error.UnsupportedLlvmEmission).target_ty;
                const operand_ty = try self.requireMirTryOperandType(node.operand.*);
                const expected_ty = if (lower_llvm_shape.resultInfo(&self.type_aliases, operand_ty)) |info|
                    info.ok_ty
                else
                    lower_llvm_shape.nullableInnerType(&self.type_aliases, operand_ty) orelse return error.UnsupportedLlvmEmission;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result_ty), self.resolveAliasType(expected_ty))) return error.UnsupportedLlvmEmission;
                break :blk result_ty;
            },
            else => null,
        };
    }

    fn requireMirBinaryExpressionResultType(self: *LlvmEmitter, initializer: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (initializer.kind) {
            .grouped => |inner| try self.requireMirBinaryExpressionResultType(inner.*),
            .binary => |node| blk: {
                const result_ty = (self.mirTargetTypeFactAt(.expression_result, initializer.span) orelse return error.UnsupportedLlvmEmission).target_ty;
                const expected_ty = if (binaryIsComparison(node.op) or node.op == .logical_and or node.op == .logical_or)
                    simpleType(initializer.span, "bool")
                else
                    self.exprType(node.left.*) orelse return error.UnsupportedLlvmEmission;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result_ty), self.resolveAliasType(expected_ty))) return error.UnsupportedLlvmEmission;
                break :blk result_ty;
            },
            else => null,
        };
    }

    const DirectAddressPlace = struct {
        ty: ast_bridge.TypeExpr,
        mutability: ast_bridge.Mutability,
    };

    // The MIR fact owns the address result. The backend checks the direct source
    // place only to reject stale pointee or pointer-qualification facts.
    fn directAddressOfLocalPlace(self: *LlvmEmitter, initializer: ast_bridge.Expr) ?DirectAddressPlace {
        return switch (initializer.kind) {
            .address_of => |inner| self.directAddressOfLocalPlaceInfo(inner.*),
            .grouped => |inner| self.directAddressOfLocalPlace(inner.*),
            else => null,
        };
    }

    fn directAddressOfLocalPlaceInfo(self: *LlvmEmitter, operand: ast_bridge.Expr) ?DirectAddressPlace {
        return switch (operand.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| {
                    const ty = self.identifierExpressionType(operand, ident.text) orelse break :blk null;
                    break :blk .{ .ty = ty, .mutability = if (slot.is_mutable) .mut else .@"const" };
                }
                if (self.local_types.contains(ident.text)) {
                    const ty = self.identifierExpressionType(operand, ident.text) orelse break :blk null;
                    break :blk .{ .ty = ty, .mutability = .@"const" };
                }
                if (self.global_types.contains(ident.text)) {
                    const ty = self.identifierExpressionType(operand, ident.text) orelse break :blk null;
                    break :blk .{ .ty = ty, .mutability = if (self.global_is_const.get(ident.text) orelse true) .@"const" else .mut };
                }
                break :blk null;
            },
            .member => |node| if (self.directAddressOfLocalPlaceInfo(node.base.*)) |base| .{ .ty = self.exprType(operand) orelse return null, .mutability = base.mutability } else null,
            .index => |node| blk: {
                const base = self.directAddressOfLocalPlaceInfo(node.base.*) orelse break :blk null;
                if (self.resolveAliasType(base.ty).kind != .array) break :blk null;
                break :blk .{ .ty = self.exprType(operand) orelse break :blk null, .mutability = base.mutability };
            },
            .deref => |inner| blk: {
                const pointer_ty = self.directAddressOfLocalPointerType(inner.*) orelse break :blk null;
                const view = type_bridge.viewType(self.resolveAliasType(pointer_ty)) orelse break :blk null;
                switch (view.kind) {
                    .pointer, .raw_many_pointer => {},
                    .slice => break :blk null,
                }
                break :blk .{ .ty = self.exprType(operand) orelse break :blk null, .mutability = view.mutability };
            },
            .grouped => |inner| self.directAddressOfLocalPlaceInfo(inner.*),
            else => null,
        };
    }

    fn directAddressOfLocalPointerType(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.identifierExpressionType(expr, ident.text),
            .grouped => |inner| self.directAddressOfLocalPointerType(inner.*),
            else => null,
        };
    }

    fn emitAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, value_expr: ast_bridge.Expr, span: ast_bridge.Span) !void {
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
                if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, slot.ty) != null) {
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, slot.ptr, try self.debugCallSuffix() });
                } else {
                    try self.emitConcreteObjectStore(slot.ptr, slot.ty, value);
                }
                try self.updatePointerProvenanceAssignmentFromMirOrLocalProof(ident.text, slot.ty, value_expr, span);
                _ = self.local_aggregate_pointer_aliases.remove(ident.text);
                _ = self.local_pointer_array_aliases.remove(ident.text);
                self.clearLocalSlicesBackedByArray(ident.text);
                self.clearLocalPointerArrayAliasesBackedByArray(ident.text);
                try self.updateAggregatePointerFieldProvenanceFromInit(ident.text, slot.ty, value_expr);
                try self.updateLocalArrayPointerElementProvenanceFromInit(ident.text, slot.ty, value_expr);
                try self.updateLocalSlicePointerElementProvenanceFromInit(ident.text, slot.ty, value_expr);
                if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, slot.ty)) try self.applyMirPointerProvenanceForAssignment(ident.text, slot.ty, value_expr, span);
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

    fn emitIndexAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, value_expr: ast_bridge.Expr, span: ast_bridge.Span) !bool {
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
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind) |kind| {
            if (self.maybeUninitCallInfo(call, kind)) |info| {
                if (!std.mem.eql(u8, info.op, "write")) return false;
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                try self.emitMaybeUninitWriteInfo(info, call.args);
                return true;
            }
        }
        if (call_kind == .raw_store) {
            _ = self.rawCallInfo(call, .raw_store) orelse return error.UnsupportedLlvmEmission;
            try self.emitRawStorePayload(call.callee.*.span, call.type_args, call.args);
            return true;
        }
        if (call_kind) |kind| {
            if (self.mmioAccessInfo(call, kind)) |info| {
                if (!std.mem.eql(u8, info.op, "write")) return false;
                if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
                try self.emitMmioWriteInfo(info, call.args);
                return true;
            }
        }
        if (call_kind) |kind| {
            if (self.dmaCacheCallInfo(call, kind)) |info| {
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                try self.emitDmaCacheInfo(info, call.args);
                return true;
            }
        }
        if (call_kind == .cpu_pause) {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            try self.out.print(self.allocator, "  call void asm sideeffect \"pause\", \"~{{memory}}\"(){s}\n", .{try self.debugCallSuffix()});
            return true;
        }
        if (call_kind) |fence_kind| {
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
        if (call_kind) |kind| {
            if (self.atomicCallInfo(call, kind)) |info| {
                if (!std.mem.eql(u8, info.op, "store")) return false;
                if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
                try self.emitAtomicStoreInfo(info, call.args);
                return true;
            }
        }
        return false;
    }

    fn emitRawStorePayload(self: *LlvmEmitter, callee_span: ast_bridge.Span, type_args: []const ast_bridge.TypeExpr, args: []const ast_bridge.Expr) !void {
        if (type_args.len != 1 or args.len != 2) return error.UnsupportedLlvmEmission;
        const info = RawCallInfo{
            .kind = .raw_store,
            .address_ty = (self.mirTargetTypeFactAt(.raw_address, callee_span) orelse return error.UnsupportedLlvmEmission).target_ty,
            .payload_ty = (self.mirTargetTypeFactAt(.raw_payload, callee_span) orelse return error.UnsupportedLlvmEmission).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.raw_result, callee_span) orelse return error.UnsupportedLlvmEmission).target_ty,
        };
        const addr = try self.emitExpr(args[0], info.address_ty);
        const value = try self.emitExpr(args[1], info.payload_ty);
        const ptr = try self.nextTemp();
        const llvm_ty = try self.llvmType(info.payload_ty);
        if (rawScalarTypeName(info.payload_ty) == null) {
            // Aggregate (non-scalar) T: whole-object typed store, mirroring how
            // `raw.ptr<T>(addr)` + deref already lowers a struct assignment. The
            // sanitizer hooks below key off scalar-sized accesses, so aggregate
            // stores lower to a plain (uninstrumented) typed store, matching the C
            // backend where aggregate stores bypass the mc_raw_store_* helpers.
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.emitConcreteObjectStore(ptr, info.payload_ty, value);
            return;
        }
        // KASAN (D2.1): consult the shadow before the store — a poisoned (freed/
        // redzone) target traps in mc_ksan_check. Scalar size == llvmAlignOf here.
        // KMSAN (D2.2): call mc_ksan_store before the write. The hook must not reject
        // UNINIT bytes because first writes initialize them, but it does reject POISON.
        if (self.msan) {
            try self.out.print(self.allocator, "  call void @mc_ksan_store(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(info.payload_ty) });
        } else if (self.ksan) {
            try self.out.print(self.allocator, "  call void @mc_ksan_check(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(info.payload_ty) });
        }
        // KCSAN (D2.3): bracket the unsynchronized store with a write watchpoint hook so a
        // concurrent access lands inside the watch window. Mirrors the C backend's csan path.
        if (self.csan) try self.out.print(self.allocator, "  call void @mc_csan_write(i64 {s}, i64 {d})\n", .{ addr, self.llvmAlignOf(info.payload_ty) });
        try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
        try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
    }

    fn emitMmioWritePayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr) !void {
        if (args.len != 2) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.mmioAccessInfo(call, .mmio_write) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, info.op, "write")) return error.UnsupportedLlvmEmission;
        try self.emitMmioWriteInfo(info, args);
    }

    fn emitMmioWriteInfo(self: *LlvmEmitter, info: MmioAccessInfo, args: []const ast_bridge.Expr) !void {
        if (args.len != 2) return error.UnsupportedLlvmEmission;
        const ordering = orderingArg(args[1]) orelse return error.UnsupportedLlvmEmission;
        const raw_value = try self.emitExpr(args[0], info.value_ty);
        const value = if (std.mem.eql(u8, try self.llvmType(info.value_ty), try self.llvmType(info.storage_ty)))
            raw_value
        else
            try self.castValue(raw_value, info.value_ty, info.storage_ty);
        try self.emitMmioFence(ordering, .before_store);
        const ptr = try self.emitMmioRegisterAddress(info);
        try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(info.storage_ty), value, ptr, try self.debugCallSuffix() });
    }

    fn emitMmioReadPayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr) ![]const u8 {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.mmioAccessInfo(call, .mmio_read) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, info.op, "read")) return error.UnsupportedLlvmEmission;
        return try self.emitMmioReadInfo(info, args);
    }

    fn emitMmioReadInfo(self: *LlvmEmitter, info: MmioAccessInfo, args: []const ast_bridge.Expr) ![]const u8 {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        const ordering = orderingArg(args[0]) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMmioRegisterAddress(info);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}{s}\n", .{ result, try self.llvmType(info.storage_ty), ptr, try self.debugCallSuffix() });
        try self.emitMmioFence(ordering, .after_load);
        if (std.mem.eql(u8, try self.llvmType(info.storage_ty), try self.llvmType(info.value_ty))) return result;
        return try self.castValue(result, info.storage_ty, info.value_ty);
    }

    fn emitDmaCachePayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, kind: mir.CallTargetKind) !void {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.dmaCacheCallInfo(call, kind) orelse return error.UnsupportedLlvmEmission;
        try self.emitDmaCacheInfo(info, args);
    }

    fn emitDmaCacheInfo(self: *LlvmEmitter, info: DmaCacheCallInfo, args: []const ast_bridge.Expr) !void {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        _ = try self.emitExpr(args[0], info.dma_ty);
        if (std.mem.eql(u8, info.op, "clean")) {
            try self.out.print(self.allocator, "  fence release{s}\n", .{try self.debugCallSuffix()});
        } else if (std.mem.eql(u8, info.op, "invalidate")) {
            try self.out.print(self.allocator, "  fence acquire{s}\n", .{try self.debugCallSuffix()});
        } else {
            return error.UnsupportedLlvmEmission;
        }
    }

    fn emitMaybeUninitWritePayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr) !void {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.maybeUninitCallInfo(call, .maybe_uninit_write) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, info.op, "write")) return error.UnsupportedLlvmEmission;
        try self.emitMaybeUninitWriteInfo(info, args);
    }

    fn emitMaybeUninitWriteInfo(self: *LlvmEmitter, info: MaybeUninitCallInfo, args: []const ast_bridge.Expr) !void {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        const ptr = try self.storageBaseAddress(info.base);
        const value = try self.emitExpr(args[0], info.payload_ty);
        try self.emitConcreteObjectStore(ptr, info.payload_ty, value);
    }

    fn emitAtomicStorePayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr) !void {
        if (args.len != 2) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.atomicCallInfo(call, .atomic_store) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, info.op, "store")) return error.UnsupportedLlvmEmission;
        try self.emitAtomicStoreInfo(info, args);
    }

    fn emitAtomicStoreInfo(self: *LlvmEmitter, info: AtomicCallInfo, args: []const ast_bridge.Expr) !void {
        if (args.len != 2) return error.UnsupportedLlvmEmission;
        const ordering = atomicOrderingArg(args, 1) orelse return error.UnsupportedLlvmEmission;
        const llvm_order = atomicLlvmOrdering(ordering, .store) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.atomicAddress(info);
        const value = try self.emitAtomicValueForStorage(args[0], info.payload_ty);
        try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} {s}, align {d}{s}\n", .{ try self.atomicStorageLlvmType(info.payload_ty), value, ptr, llvm_order, self.llvmAlignOf(info.payload_ty), try self.debugCallSuffix() });
    }

    fn emitVaEndPayload(self: *LlvmEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr) !void {
        if (args.len != 1) return error.UnsupportedLlvmEmission;
        var callee_storage = callee;
        const empty_type_args: []const ast_bridge.TypeExpr = &.{};
        const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = args };
        const info = self.vaCallInfo(call, .va_end) orelse return error.UnsupportedLlvmEmission;
        const cursor_ty = info.cursor_ty orelse return error.UnsupportedLlvmEmission;
        const ap_ptr = try self.emitVaListCursorArg(args[0], cursor_ty);
        try self.out.print(self.allocator, "  call void @llvm.va_end(ptr {s})\n", .{ap_ptr});
    }

    fn emitMemberAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, value_expr: ast_bridge.Expr) !bool {
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

    fn emitLoop(self: *LlvmEmitter, loop: ast_bridge.Loop, ret_ty: ast_bridge.TypeExpr) !bool {
        return switch (loop.kind) {
            .@"while" => try self.emitWhile(loop, ret_ty),
            .@"for" => try self.emitFor(loop, ret_ty),
        };
    }

    fn emitWhile(self: *LlvmEmitter, loop: ast_bridge.Loop, ret_ty: ast_bridge.TypeExpr) !bool {
        if (loop.kind != .@"while") return error.UnsupportedLlvmEmission;
        const condition_expr = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const condition_ty = try self.requireMirBoolTargetTypeForEmission(.loop_condition, condition_expr);

        const cond_label = try self.nextLabel("while_cond");
        const body_label = try self.nextLabel("while_body");
        const end_label = try self.nextLabel("while_end");

        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const condition = try self.emitExpr(condition_expr, condition_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_label, end_label, try self.debugCallSuffix(), body_label });
        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = cond_label, .label = if (loop.loop_label) |l| l.text else null });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlockWithDeferStackSnapshot(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ cond_label, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn requireMirSwitchSubjectType(self: *LlvmEmitter, subject: ast_bridge.Expr) !MirSubjectType {
        return self.requireMirSubjectType(.switch_subject, subject);
    }

    fn requireMirIfLetSubjectType(self: *LlvmEmitter, value: ast_bridge.Expr) !MirSubjectType {
        return self.requireMirSubjectType(.if_let_subject, value);
    }

    fn requireMirSubjectType(self: *LlvmEmitter, kind: mir.TargetTypeKind, subject: ast_bridge.Expr) !MirSubjectType {
        if (!isSourceSpan(subject.span)) return .{ .target_ty = self.exprType(subject) orelse return error.UnsupportedLlvmEmission };
        const fact = self.mirTargetTypeFactAt(kind, subject.span) orelse return error.UnsupportedLlvmEmission;
        const fact_ty = fact.target_ty;
        if (self.exprType(subject)) |known_ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(known_ty))) return error.UnsupportedLlvmEmission;
        }
        const resolved_fact_ty = self.resolveAliasType(fact_ty);
        return .{
            .target_ty = fact_ty,
            .nullable_representation = if (resolved_fact_ty.kind == .nullable) try self.nullableRepresentationFromTargetFact(fact) else null,
        };
    }

    fn mirTargetTypeForEmission(self: *LlvmEmitter, kind: mir.TargetTypeKind, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.exprType(expr);
        const fact_ty = (self.mirTargetTypeFactAt(kind, expr.span) orelse return null).target_ty;
        if (self.exprType(expr)) |known_ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(known_ty))) return null;
        }
        return fact_ty;
    }

    fn requireMirTargetTypeForEmission(self: *LlvmEmitter, kind: mir.TargetTypeKind, expr: ast_bridge.Expr) !ast_bridge.TypeExpr {
        return self.mirTargetTypeForEmission(kind, expr) orelse error.UnsupportedLlvmEmission;
    }

    fn requireMirTargetTypeAtForEmission(self: *LlvmEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span) !ast_bridge.TypeExpr {
        return (self.mirTargetTypeFactAt(kind, span) orelse return error.UnsupportedLlvmEmission).target_ty;
    }

    fn requireMirBoolTargetTypeForEmission(self: *LlvmEmitter, kind: mir.TargetTypeKind, expr: ast_bridge.Expr) !ast_bridge.TypeExpr {
        const ty = try self.requireMirTargetTypeForEmission(kind, expr);
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        return ty;
    }

    fn nullableRepresentationFromTargetFact(self: *LlvmEmitter, fact: mir.TargetTypeFact) !NullableRepresentation {
        const from_fact: NullableRepresentation = switch (fact.result_ty) {
            .nullable_value => .value,
            .nullable_dyn_trait => .dyn_trait,
            .nullable_pointer => .pointer,
            else => return error.UnsupportedLlvmEmission,
        };
        const expected = self.nullableRepresentationForTargetType(fact.target_ty) orelse return error.UnsupportedLlvmEmission;
        if (from_fact != expected) return error.UnsupportedLlvmEmission;
        return from_fact;
    }

    fn nullableRepresentationForTargetType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?NullableRepresentation {
        const resolved = self.resolveAliasType(ty);
        if (resolved.kind != .nullable) return null;
        const child = resolved.kind.nullable.*;
        const resolved_child = self.resolveAliasType(child);
        if (resolved_child.kind == .dyn_trait) return .dyn_trait;
        if (self.nullablePayloadIsValueType(child)) return .value;
        return .pointer;
    }

    fn requireMirTryOperandType(self: *LlvmEmitter, operand: ast_bridge.Expr) !ast_bridge.TypeExpr {
        return self.requireMirTargetTypeForEmission(.try_operand, operand);
    }

    fn mirTryOperandTypeForQuery(self: *LlvmEmitter, operand: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return self.requireMirTryOperandType(operand) catch null;
    }

    fn requireMirDiscardArgumentTypeForEmission(self: *LlvmEmitter, argument: ast_bridge.Expr) !ast_bridge.TypeExpr {
        return self.requireMirTargetTypeForEmission(.discard_argument, argument);
    }

    fn requireMirForLoopTypes(self: *LlvmEmitter, iterable: ast_bridge.Expr) !struct { iterable: ast_bridge.TypeExpr, element: ast_bridge.TypeExpr } {
        const iterable_ty = try self.requireMirTargetTypeForEmission(.for_iterable, iterable);
        const element_ty = try self.requireMirForElementTypeForEmission(iterable);
        const expected_element = switch (self.resolveAliasType(iterable_ty).kind) {
            .array => |node| node.child.*,
            .slice => |node| node.child.*,
            else => return error.UnsupportedLlvmEmission,
        };
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(expected_element))) return error.UnsupportedLlvmEmission;
        return .{ .iterable = iterable_ty, .element = element_ty };
    }

    fn requireMirForElementTypeForEmission(self: *LlvmEmitter, iterable: ast_bridge.Expr) !ast_bridge.TypeExpr {
        return self.requireMirTargetTypeAtForEmission(.for_element, iterable.span);
    }

    fn emitFor(self: *LlvmEmitter, loop: ast_bridge.Loop, ret_ty: ast_bridge.TypeExpr) !bool {
        const binding = loop.label orelse return error.UnsupportedLlvmEmission;
        const iterable = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const types = try self.requireMirForLoopTypes(iterable);
        const iterable_ty = types.iterable;
        const element_ty = types.element;
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
                try self.emitConcreteObjectStore(ptr, iterable_ty, value);
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
        defer restoreLocal(&self.local_types, binding.text, old_type);
        defer restoreLocal(&self.local_slots, binding.text, old_slot);
        defer restoreLocal(&self.pointer_local_provenance, binding.text, old_global_pointer);
        defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.text, old_aggregate_pointer_alias);
        defer restoreLocal(&self.local_pointer_array_aliases, binding.text, old_pointer_array_alias);
        defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.text, old_slice_global_pointer_array);
        defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.text, old_slice_pointer_array_range);
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.text, old_slice_aggregate_pointer_array_field);
        defer self.restoreAggregatePointerFieldsForLocal(binding.text, &old_aggregate_pointer_fields);
        defer self.restoreLocalArrayPointerElementsForLocal(binding.text, &old_local_array_pointer_elements);
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
        try self.emitConcreteObjectStore(binding_ptr, element_ty, element_value);

        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = step_label, .label = if (loop.loop_label) |l| l.text else null });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlockWithDeferStackSnapshot(loop.body, ret_ty);
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

    fn emitIterableLen(self: *LlvmEmitter, iterable: ast_bridge.Expr, iterable_ty: ast_bridge.TypeExpr, iterable_slot: ?LocalSlot) ![]const u8 {
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

    fn emitForElementPtr(self: *LlvmEmitter, iterable: ast_bridge.Expr, iterable_ty: ast_bridge.TypeExpr, iterable_ptr: ?[]const u8, index: []const u8) ![]const u8 {
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

    fn emitNullableSwitch(self: *LlvmEmitter, node: ast_bridge.Switch, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr, representation: ?NullableRepresentation) !?bool {
        const inner_ty = lower_llvm_shape.nullableInnerType(&self.type_aliases, subject_ty) orelse return null;
        const nullable_representation = representation orelse return error.UnsupportedLlvmEmission;
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
        if (nullable_representation == .value) {
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_some, try self.llvmType(subject_ty), subject });
        } else {
            try self.emitNullableSomeTest(is_some, subject, inner_ty);
        }
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
        defer restoreLocal(&self.local_types, bind.text, old_type);
        defer restoreLocal(&self.local_slots, bind.text, old_slot);
        defer restoreLocal(&self.pointer_local_provenance, bind.text, old_global_pointer);
        defer restoreLocal(&self.local_aggregate_pointer_aliases, bind.text, old_aggregate_pointer_alias);
        defer restoreLocal(&self.local_pointer_array_aliases, bind.text, old_pointer_array_alias);
        defer restoreLocal(&self.local_slice_global_pointer_arrays, bind.text, old_slice_global_pointer_array);
        defer restoreLocal(&self.local_slice_pointer_array_ranges, bind.text, old_slice_pointer_array_range);
        defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, bind.text, old_slice_aggregate_pointer_array_field);
        defer self.restoreAggregatePointerFieldsForLocal(bind.text, &old_aggregate_pointer_fields);
        defer self.restoreLocalArrayPointerElementsForLocal(bind.text, &old_local_array_pointer_elements);

        const binding_ptr = try self.nextBindingPtr(bind.text);
        const binding_value = if (nullable_representation == .value) blk: {
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, try self.llvmType(subject_ty), subject });
            break :blk payload;
        } else subject;
        try self.emitAllocaConcreteStore(binding_ptr, inner_ty, binding_value);
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

    fn emitResultSwitch(self: *LlvmEmitter, node: ast_bridge.Switch, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) !?bool {
        const info = lower_llvm_shape.resultInfo(&self.type_aliases, subject_ty) orelse return null;
        if (node.arms.len != 2) return error.UnsupportedLlvmEmission;

        var ok_index: ?usize = null;
        var ok_binding: ?ast_bridge.Ident = null;
        var err_index: ?usize = null;
        var err_binding: ?ast_bridge.Ident = null;
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

    fn emitResultSwitchArm(self: *LlvmEmitter, arm: ast_bridge.SwitchArm, ret_ty: ast_bridge.TypeExpr, subject: []const u8, subject_ty: ast_bridge.TypeExpr, payload_ty: ast_bridge.TypeExpr, payload_index: u8, binding: ?ast_bridge.Ident) !bool {
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
            defer restoreLocal(&self.local_types, bind.text, old_type);
            defer restoreLocal(&self.local_slots, bind.text, old_slot);
            defer restoreLocal(&self.pointer_local_provenance, bind.text, old_global_pointer);
            defer restoreLocal(&self.local_aggregate_pointer_aliases, bind.text, old_aggregate_pointer_alias);
            defer restoreLocal(&self.local_pointer_array_aliases, bind.text, old_pointer_array_alias);
            defer restoreLocal(&self.local_slice_global_pointer_arrays, bind.text, old_slice_global_pointer_array);
            defer restoreLocal(&self.local_slice_pointer_array_ranges, bind.text, old_slice_pointer_array_range);
            defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, bind.text, old_slice_aggregate_pointer_array_field);
            defer self.restoreAggregatePointerFieldsForLocal(bind.text, &old_aggregate_pointer_fields);
            defer self.restoreLocalArrayPointerElementsForLocal(bind.text, &old_local_array_pointer_elements);

            const binding_ptr = try self.nextBindingPtr(bind.text);
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
            try self.emitAllocaConcreteStore(binding_ptr, payload_ty, payload);
            try self.local_types.put(bind.text, payload_ty);
            try self.local_slots.put(bind.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitTaggedUnionSwitch(self: *LlvmEmitter, node: ast_bridge.Switch, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) !?bool {
        const union_decl = self.taggedUnionForType(subject_ty) orelse return null;
        const subject = try self.emitExpr(node.subject, subject_ty);
        const subject_ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        const tag = try self.nextTemp();
        const union_llvm = try self.llvmType(subject_ty);
        try self.emitAllocaConcreteStore(subject_ptr, subject_ty, subject);
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

    fn emitTaggedUnionSwitchArm(self: *LlvmEmitter, arm: ast_bridge.SwitchArm, ret_ty: ast_bridge.TypeExpr, subject_ptr: []const u8, subject_ty: ast_bridge.TypeExpr, union_decl: ast_bridge.UnionDecl) !bool {
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
            defer restoreLocal(&self.local_types, binding.binding.text, old_type);
            defer restoreLocal(&self.local_slots, binding.binding.text, old_slot);
            defer restoreLocal(&self.pointer_local_provenance, binding.binding.text, old_global_pointer);
            defer restoreLocal(&self.local_aggregate_pointer_aliases, binding.binding.text, old_aggregate_pointer_alias);
            defer restoreLocal(&self.local_pointer_array_aliases, binding.binding.text, old_pointer_array_alias);
            defer restoreLocal(&self.local_slice_global_pointer_arrays, binding.binding.text, old_slice_global_pointer_array);
            defer restoreLocal(&self.local_slice_pointer_array_ranges, binding.binding.text, old_slice_pointer_array_range);
            defer self.restoreLocalOwnedStringValue(&self.local_slice_aggregate_pointer_array_fields, binding.binding.text, old_slice_aggregate_pointer_array_field);
            defer self.restoreAggregatePointerFieldsForLocal(binding.binding.text, &old_aggregate_pointer_fields);
            defer self.restoreLocalArrayPointerElementsForLocal(binding.binding.text, &old_local_array_pointer_elements);

            const binding_ptr = try self.nextBindingPtr(binding.binding.text);
            const payload = try self.taggedUnionLoadPayload(subject_ptr, subject_ty, payload_ty);
            try self.emitAllocaConcreteStore(binding_ptr, payload_ty, payload);
            try self.local_types.put(binding.binding.text, payload_ty);
            try self.local_slots.put(binding.binding.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitScalarSwitch(self: *LlvmEmitter, node: ast_bridge.Switch, ret_ty: ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) !?bool {
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

    fn switchPatternValue(self: *LlvmEmitter, pattern: ast_bridge.Pattern, subject_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn switchLiteralValue(self: *LlvmEmitter, expr: ast_bridge.Expr, subject_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitSwitchBody(self: *LlvmEmitter, body: ast_bridge.SwitchBody, ret_ty: ast_bridge.TypeExpr) !bool {
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

    fn emitBlockWithDeferStackSnapshot(self: *LlvmEmitter, block: ast_bridge.Block, ret_ty: ast_bridge.TypeExpr) !bool {
        return self.emitBlock(block, ret_ty);
    }

    fn emitReturnVoid(self: *LlvmEmitter, span: ast_bridge.Span) !void {
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "  ret void, !dbg !{d}\n", .{dbg});
        } else {
            try self.out.appendSlice(self.allocator, "  ret void\n");
        }
    }

    fn emitReturnValue(self: *LlvmEmitter, ret_ty: ast_bridge.TypeExpr, value: []const u8, span: ast_bridge.Span) !void {
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
    fn targetIsDynOrNullableDyn(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => true,
            .nullable => |child| self.resolveAliasType(child.*).kind == .dyn_trait,
            else => false,
        };
    }

    // A `?T` payload T uses the tagged `{ i1, T }` repr iff T is a sized VALUE type (named
    // scalar/struct/enum/address, not a pointer, slice, fn-pointer, or `*dyn`).
    fn nullablePayloadIsValueType(self: *LlvmEmitter, child: ast_bridge.TypeExpr) bool {
        const resolved = self.resolveAliasType(child);
        return switch (resolved.kind) {
            .name => |n| !std.mem.eql(u8, n.text, "c_void"),
            .qualified => |node| self.nullablePayloadIsValueType(node.child.*),
            else => false,
        };
    }

    fn targetIsValueOptional(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return resolved.kind == .nullable and self.nullablePayloadIsValueType(resolved.kind.nullable.*);
    }

    // Coerce a `null` (absent) or a payload value (present) into a value optional `?T`'s
    // tagged `{ i1, T }` aggregate. A source already yielding `?T` returns null (pass-through).
    fn emitValueOptionalCoercion(self: *LlvmEmitter, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) !?[]const u8 {
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

    fn emitDynCoercion(self: *LlvmEmitter, expr: ast_bridge.Expr, _: ast_bridge.TypeExpr) !?[]const u8 {
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
                const source_ty = (self.mirTargetTypeFactAt(.dyn_coercion_source, expr.span) orelse return error.UnsupportedLlvmEmission).target_ty;
                type_name = typeName(self.resolveAliasType(source_ty)) orelse return null;
                data_ptr = try self.emitAddressOf(inner.*);
            },
            else => {
                // A `*T` value: data = the pointer itself, vtable keyed on the pointee T.
                const source_ty = self.resolveAliasType((self.mirTargetTypeFactAt(.dyn_coercion_source, expr.span) orelse return error.UnsupportedLlvmEmission).target_ty);
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

    fn emitAddressOf(self: *LlvmEmitter, target: ast_bridge.Expr) ![]const u8 {
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

    fn emitDeref(self: *LlvmEmitter, ptr_expr: ast_bridge.Expr, deref_span: ast_bridge.Span) ![]const u8 {
        const inferred_pointee_ty = self.derefPointeeType(ptr_expr) orelse return error.UnsupportedLlvmEmission;
        const pointee_ty = self.expressionResultTypeAt(deref_span, inferred_pointee_ty) orelse return error.UnsupportedLlvmEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointee_ty), self.resolveAliasType(inferred_pointee_ty))) return error.UnsupportedLlvmEmission;
        const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
        if (self.isAggregateType(pointee_ty) and !self.pointerExprHasProvenLocalStorage(ptr_expr)) {
            return try self.emitRaceTolerantAggregateDerefLoad(ptr, pointee_ty);
        }
        const use_atomic = self.derefUsesRaceTolerantLowering(ptr_expr, pointee_ty);
        if (use_atomic) try self.emitOrdinaryShadowHook(ptr, pointee_ty, .load_pre);
        return try self.emitOrdinaryLoad(pointee_ty, ptr, use_atomic);
    }

    fn emitMemberLoad(self: *LlvmEmitter, node: anytype, member_span: ast_bridge.Span) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        if (base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) {
            const usize_ty = simpleType(member_span, "usize");
            const field_ty = self.requireExpressionResultType(.{ .kind = .{ .member = node }, .span = member_span }, usize_ty) orelse return error.UnsupportedLlvmEmission;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(usize_ty))) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(node.base.*, base_ty);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ result, try self.llvmType(base_ty), base });
            return result;
        }
        if (self.packedBitsInfoForType(base_ty)) |info| {
            const bit_index = self.packedBitsFieldIndex(info, node.name.text) orelse return error.UnsupportedLlvmEmission;
            const field_ty = self.requireExpressionResultType(.{ .kind = .{ .member = node }, .span = member_span }, simpleType(member_span, "bool")) orelse return error.UnsupportedLlvmEmission;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(simpleType(member_span, "bool")))) return error.UnsupportedLlvmEmission;
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
            const field_ty = self.expressionResultTypeAt(member_span, field.ty) orelse return error.UnsupportedLlvmEmission;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(field.ty))) return error.UnsupportedLlvmEmission;
            const ptr = try self.emitOverlayFieldAddress(node.base.*, field);
            try self.emitOrdinaryShadowHook(ptr, field.ty, .load_pre);
            return try self.emitOrdinaryLoad(field.ty, ptr, self.memberBaseIsGlobal(node));
        }
        const inferred_field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const field_ty = self.expressionResultTypeAt(member_span, inferred_field.ty) orelse return error.UnsupportedLlvmEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field.ty))) return error.UnsupportedLlvmEmission;
        const field = inferred_field;
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
    fn emitOrdinaryShadowHook(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr, phase: enum { load_pre, store_pre, store_post }) !void {
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

    fn emitOrdinaryLoad(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, ptr: []const u8, use_atomic: bool) ![]const u8 {
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

    fn emitOrdinaryStore(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, llvm_ty: []const u8, value: []const u8, ptr: []const u8, use_atomic: bool) !void {
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
            if (self.isAggregateType(ty)) {
                try self.emitConcreteObjectStore(ptr, ty, value);
            } else {
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            }
        }
    }

    fn canUseOrdinaryAtomicAccess(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        return !self.isAggregateType(ty);
    }

    // Race-tolerant lowering (`load/store atomic ... unordered`) is only sound for
    // scalars up to the native 8-byte word: a 128-bit atomic would lower to an
    // `__atomic_load_16`/`__atomic_store_16` libcall that the freestanding kernel
    // image cannot link. Spec §I.13: with no sound race-tolerant lowering, the
    // backend must fail emission rather than guess.
    fn ordinaryAtomicScalarTooWide(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
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

    fn restoreLocalOwnedStringValue(self: *LlvmEmitter, map: *std.StringHashMap([]const u8), key: []const u8, old: anytype) void {
        if (map.fetchRemove(key)) |entry| self.allocator.free(entry.value);
        // `fetchRemove` retains the map capacity, so this restores a previously-held
        // entry without allocating while a scope is unwound.
        if (old) |entry| map.putAssumeCapacity(key, entry.value);
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

    fn directLocalSliceBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn provenLocalSliceBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn restoreLocalArrayPointerElementsForLocal(self: *LlvmEmitter, local_name: []const u8, saved: *std.StringHashMap(mir.PointerProvenance)) void {
        self.clearLocalArrayPointerElementsForLocal(local_name);
        defer saved.deinit();

        var it = saved.iterator();
        while (it.next()) |entry| {
            self.local_array_global_pointer_elements.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
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

    fn restoreAggregatePointerFieldsForLocal(self: *LlvmEmitter, local_name: []const u8, saved: *std.StringHashMap(mir.PointerProvenance)) void {
        self.clearAggregatePointerFieldsForLocal(local_name);
        defer saved.deinit();

        var it = saved.iterator();
        while (it.next()) |entry| {
            self.aggregate_global_pointer_fields.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
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

    fn directLocalAggregateBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.local_slots.contains(ident.text)) ident.text else null,
            .grouped => |inner| self.directLocalAggregateBaseName(inner.*),
            .cast => |node| self.directLocalAggregateBaseName(node.value.*),
            .call => |call| if (self.isMirAssumeNoaliasCall(call))
                self.directLocalAggregateBaseName(call.args[0])
            else
                null,
            else => null,
        };
    }

    fn directStructTypeName(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        const name = typeName(self.resolveAliasType(ty)) orelse return null;
        if (!self.struct_types.contains(name)) return null;
        return name;
    }

    fn directAggregateCopySourceExpr(self: *LlvmEmitter, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) bool {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return false;
        return self.directAggregateCopySourceExprForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) ?[]const u8 {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return null;
        return self.directAggregateCopySourceBaseNameForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceExprForStruct(self: *LlvmEmitter, expr: ast_bridge.Expr, target_struct_name: []const u8) bool {
        return self.directAggregateCopySourceBaseNameForStruct(expr, target_struct_name) != null or
            self.directAggregateCopySourceMemberForStruct(expr, target_struct_name);
    }

    fn directAggregateCopySourceBaseNameForStruct(self: *LlvmEmitter, expr: ast_bridge.Expr, target_struct_name: []const u8) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.directAggregateCopySourceBaseNameForStruct(inner.*, target_struct_name),
            .cast => |node| self.directAggregateCopySourceBaseNameForStruct(node.value.*, target_struct_name),
            .call => |call| if (self.isMirAssumeNoaliasCall(call))
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

    fn directAggregateCopySourceMemberForStruct(self: *LlvmEmitter, expr: ast_bridge.Expr, target_struct_name: []const u8) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directAggregateCopySourceMemberForStruct(inner.*, target_struct_name),
            .cast => |node| self.directAggregateCopySourceMemberForStruct(node.value.*, target_struct_name),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directAggregateCopySourceMemberForStruct(call.args[0], target_struct_name),
            .member => blk: {
                _ = self.directLocalAggregateMemberPath(expr) orelse break :blk false;
                const source_ty = self.aggregateCopyMemberSourceTypeForEmission(expr) orelse break :blk false;
                const source_struct_name = self.directStructTypeName(source_ty) orelse break :blk false;
                break :blk std.mem.eql(u8, source_struct_name, target_struct_name);
            },
            else => false,
        };
    }

    fn aggregateCopyMemberSourceTypeForEmission(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| return fact.target_ty;
        if (isSourceSpan(expr.span)) return null;
        return self.exprType(expr);
    }

    fn localAggregatePointerAliasBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn directLocalAggregateMemberPath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
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

    fn directLocalAggregateArrayElementPath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
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
                if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, child_ty) and self.directStructTypeName(child_ty) == null and child_ty.kind != .array) break :blk null;
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

    fn directLocalAggregateArrayBasePath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
        const path = self.directLocalAggregateMemberPath(expr) orelse return null;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return null;
        return path;
    }

    fn directLocalAggregateArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAnyElementHasGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.directLocalAggregateArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveLocalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasMemberPath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
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

    fn aggregatePointerAliasArrayElementPath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.aggregatePointerAliasArrayElementPath(inner.*),
            .index => |node| blk: {
                const base_path = self.aggregatePointerAliasMemberPath(node.base.*) orelse break :blk null;
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                const array = switch (base_ty.kind) {
                    .array => |array| array,
                    else => break :blk null,
                };
                if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) break :blk null;
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

    fn aggregatePointerAliasArrayBasePath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?AggregatePointerFieldPath {
        const path = self.aggregatePointerAliasMemberPath(expr) orelse return null;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return null;
        return path;
    }

    fn aggregatePointerAliasArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAnyElementHasGlobalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn aggregatePointerAliasArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const path = self.aggregatePointerAliasArrayBasePath(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localAggregateArrayAllElementsHaveLocalPointerProvenance(path.local_name, path.field_path, len);
    }

    fn directLocalAggregateAssignmentPath(self: *LlvmEmitter, base: ast_bridge.Expr, field_name: []const u8) !?AggregatePointerFieldPath {
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

    fn aggregatePointerAliasAssignmentPath(self: *LlvmEmitter, base: ast_bridge.Expr, field_name: []const u8) !?AggregatePointerFieldPath {
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

    fn localArrayConstIndexValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ?u64 {
        if (self.globalConstIndexValue(expr)) |index| return index;
        return switch (expr.kind) {
            .int_literal => |literal| parseU64Literal(literal),
            .grouped => |inner| self.localArrayConstIndexValue(inner.*),
            else => null,
        };
    }

    fn directLocalArrayBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn directLocalArrayElementPath(self: *LlvmEmitter, expr: ast_bridge.Expr) ?LocalArrayPointerElementPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalArrayElementPath(inner.*),
            .index => |node| blk: {
                const local_name = self.directLocalArrayBaseName(node.base.*) orelse break :blk null;
                const base_ty = self.resolveAliasType(self.exprType(node.base.*) orelse break :blk null);
                const array = switch (base_ty.kind) {
                    .array => |array| array,
                    else => break :blk null,
                };
                if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) break :blk null;
                const index = self.localArrayConstIndexValue(node.index.*) orelse break :blk null;
                const len = self.arrayLenValue(array.len) orelse break :blk null;
                if (index >= len) break :blk null;
                break :blk .{ .local_name = local_name, .index = index };
            },
            else => null,
        };
    }

    fn directLocalArrayBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveGlobalPointerProvenance(local_name, len);
    }

    fn directLocalArrayBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAnyElementHasGlobalPointerProvenance(local_name, len);
    }

    fn directLocalArrayBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const local_name = self.directLocalArrayBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveLocalPointerProvenance(local_name, len);
    }

    fn directLocalPointerArrayAddressBaseName(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) ?[]const u8 {
        const pointee_ty = switch (self.resolveAliasType(ty).kind) {
            .pointer => |pointer| self.resolveAliasType(pointer.child.*),
            else => return null,
        };
        const pointee_array = switch (pointee_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, pointee_array.child.*)) return null;

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
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, source_array.child.*)) return null;
        const pointee_len = self.arrayLenValue(pointee_array.len) orelse return null;
        const source_len = self.arrayLenValue(source_array.len) orelse return null;
        if (pointee_len != source_len) return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointee_array.child.*), self.resolveAliasType(source_array.child.*))) return null;
        return array_name;
    }

    fn updateLocalPointerArrayAliasProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
        _ = self.local_pointer_array_aliases.remove(local_name);
        const array_name = self.directLocalPointerArrayAddressBaseName(ty, init) orelse return;
        if (std.mem.eql(u8, array_name, local_name)) return;
        try self.local_pointer_array_aliases.put(local_name, array_name);
    }

    fn localPointerArrayAliasPointerName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| self.localPointerArrayAliasPointerName(inner.*),
            else => null,
        };
    }

    fn localPointerArrayAliasBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.localPointerArrayAliasBaseName(inner.*),
            .deref => |inner| if (self.localPointerArrayAliasPointerName(inner.*)) |name|
                self.local_pointer_array_aliases.get(name)
            else
                null,
            else => null,
        };
    }

    fn localPointerArrayAliasBaseHasCompleteGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAllElementsHaveGlobalPointerProvenance(array_name, len);
    }

    fn localPointerArrayAliasBaseHasAnyGlobalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
        const len = self.arrayLenValue(array.len) orelse return false;
        return self.localArrayAnyElementHasGlobalPointerProvenance(array_name, len);
    }

    fn localPointerArrayAliasBaseHasAllLocalPointerProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        const array_name = self.localPointerArrayAliasBaseName(expr) orelse return false;
        const base_ty = self.resolveAliasType(self.exprType(expr) orelse return false);
        const array = switch (base_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;
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

    fn directLocalArraySliceBase(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) ?LocalSlicePointerArrayBase {
        const resolved_ty = self.resolveAliasType(ty);
        const slice_ty = switch (resolved_ty.kind) {
            .slice => |slice| slice,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, slice_ty.child.*)) return null;

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
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return null;
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

    fn directLocalAggregateArraySliceBase(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) ?LocalSliceAggregatePointerArrayBase {
        const resolved_ty = self.resolveAliasType(ty);
        const slice_ty = switch (resolved_ty.kind) {
            .slice => |slice| slice,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, slice_ty.child.*)) return null;

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
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return null;
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

    fn updateLocalSlicePointerElementProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
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
        dest_struct_decl: ast_bridge.StructDecl,
        init: ast_bridge.Expr,
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

    fn pointerExprStorageProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) mir.PointerProvenance {
        if (self.pointerExprHasGlobalStorageProvenance(expr)) return .global_storage;
        if (self.pointerExprHasProvenLocalStorage(expr)) return .local_storage;
        return .unknown;
    }

    fn updateAggregatePointerFieldProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
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

    fn structLiteralFields(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const ast_bridge.StructLiteralField {
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
        struct_decl: ast_bridge.StructDecl,
        fields: []const ast_bridge.StructLiteralField,
        path_prefix: ?[]const u8,
    ) !void {
        for (struct_decl.fields) |field| {
            const value_expr = structLiteralField(fields, field.name.text) orelse continue;
            const field_path = if (path_prefix) |prefix|
                try self.joinAggregatePointerFieldPath(prefix, field.name.text)
            else
                field.name.text;
            if (lower_llvm_shape.isPointerLikeType(&self.type_aliases, field.ty)) {
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
        array_ty: ast_bridge.TypeExpr,
        init: ast_bridge.Expr,
    ) !bool {
        const resolved_ty = self.resolveAliasType(array_ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => return false,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return false;

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
        base: ast_bridge.Expr,
        field_name: []const u8,
        field_ty: ast_bridge.TypeExpr,
        value_expr: ast_bridge.Expr,
    ) !void {
        const direct_target_path = try self.directLocalAggregateAssignmentPath(base, field_name);
        const target_path = direct_target_path orelse
            (try self.aggregatePointerAliasAssignmentPath(base, field_name)) orelse return;
        if (lower_llvm_shape.isPointerLikeType(&self.type_aliases, field_ty)) {
            if (direct_target_path != null) {
                if (try self.applyMirAggregatePointerFieldFactsAtSource(target_path.local_name, target_path.field_path, null, value_expr.span)) return;
                if (self.directMirPointerContainerValueExpr(value_expr)) {
                    try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, .unknown);
                    return;
                }
                try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, self.pointerExprStorageProvenance(value_expr));
                return;
            }

            // MIR records an alias write under the alias subject and explicitly
            // invalidates the backing aggregate field. Do not turn the alias's
            // syntactic RHS into a backing-local proof here.
            if (try self.applyMirAggregatePointerFieldFactsAtSource(target_path.local_name, target_path.field_path, null, value_expr.span)) return;
            if (self.directMirPointerContainerValueExpr(value_expr)) {
                try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, .unknown);
                return;
            }
            try self.setAggregatePointerFieldProvenance(target_path.local_name, target_path.field_path, .unknown);
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

    fn arrayLiteralItems(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const ast_bridge.Expr {
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

    fn updateLocalArrayPointerElementProvenanceFromInit(self: *LlvmEmitter, local_name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
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
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) {
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

    fn updateLocalArrayPointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, element_ty: ast_bridge.TypeExpr, value_expr: ast_bridge.Expr) !void {
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
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, element_ty)) return;
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

    fn invalidateLocalSlicePointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast_bridge.Expr) void {
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

    fn updateAggregateArrayPointerElementProvenanceFromAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, element_ty: ast_bridge.TypeExpr, value_expr: ast_bridge.Expr) !void {
        const node = switch (target.kind) {
            .index => |node| node,
            .grouped => |inner| return self.updateAggregateArrayPointerElementProvenanceFromAssignment(inner.*, element_ty, value_expr),
            else => return,
        };
        const direct_array_path = self.directLocalAggregateArrayBasePath(node.base.*);
        const array_path = direct_array_path orelse
            self.aggregatePointerAliasArrayBasePath(node.base.*) orelse return;
        self.clearLocalSlicesBackedByArray(array_path.local_name);
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, element_ty)) return;
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

    fn currentOwnershipCleanupPlan(self: *const LlvmEmitter) ?*const mir.OwnershipCleanupPlan {
        const function_name = self.current_function orelse return null;
        for (self.mir_module.functions) |*function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            if (!mir.cleanupCfgValid(self.mir_module, function.*, function.ownership_cleanup_plan, function.cleanup_cfg)) return null;
            var rebuilt_plan = mir.buildOwnershipCleanupPlan(self.allocator, self.mir_module, function.*) catch return null;
            defer rebuilt_plan.deinit(self.allocator);
            if (!mir.ownershipCleanupPlanEquivalent(function.ownership_cleanup_plan, rebuilt_plan)) return null;
            return &function.ownership_cleanup_plan;
        }
        return null;
    }

    fn currentCleanupCfg(self: *const LlvmEmitter) ?*const mir.CleanupCfg {
        const function_name = self.current_function orelse return null;
        for (self.mir_module.functions) |*function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            if (!mir.cleanupCfgValid(self.mir_module, function.*, function.ownership_cleanup_plan, function.cleanup_cfg)) return null;
            var rebuilt_plan = mir.buildOwnershipCleanupPlan(self.allocator, self.mir_module, function.*) catch return null;
            defer rebuilt_plan.deinit(self.allocator);
            if (!mir.ownershipCleanupPlanEquivalent(function.ownership_cleanup_plan, rebuilt_plan)) return null;
            var rebuilt_cfg = mir.buildCleanupCfg(self.allocator, self.mir_module, function.*, rebuilt_plan) catch return null;
            defer rebuilt_cfg.deinit(self.allocator);
            if (!mir.cleanupCfgEquivalent(function.cleanup_cfg, rebuilt_cfg)) return null;
            return &function.cleanup_cfg;
        }
        return null;
    }

    fn mirCallTargetKindAt(self: *LlvmEmitter, span: ast_bridge.Span) ?mir.CallTargetKind {
        return mir_source_bridge.uniqueCallTargetKindAt(self.currentMirFunction(), span);
    }

    fn mirHasCallTargetKindAt(self: *LlvmEmitter, kind: mir.CallTargetKind, span: ast_bridge.Span) bool {
        return mir_source_bridge.hasCallTargetKindAt(self.currentMirFunction(), kind, span, true);
    }

    fn atomicInitPayloadTypeAt(self: *LlvmEmitter, span: ast_bridge.Span, expected_result_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const expected_payload_ty = lower_llvm_shape.atomicPayloadType(&self.type_aliases, self.resolveAliasType(expected_result_ty)) orelse return null;
        return mir_source_bridge.atomicInitPayloadTypeAt(self.currentMirFunction(), &self.type_aliases, span, expected_result_ty, expected_payload_ty);
    }

    fn mirTargetTypeFactAt(self: *LlvmEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?mir.TargetTypeFact {
        return mir_source_bridge.targetTypeFactAtCurrentSpan(self.currentMirFunction(), kind, span);
    }

    fn contextualTargetTypeAt(self: *LlvmEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span, generated_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(span)) return generated_ty;
        return if (self.mirTargetTypeFactAt(kind, span)) |fact| fact.target_ty else null;
    }

    const MirStructLiteralConstruction = struct {
        target_ty: ast_bridge.TypeExpr,
        construction: mir.AggregateConstructionKind,
    };

    fn requireMirStructLiteralConstruction(self: *LlvmEmitter, span: ast_bridge.Span, generated_ty: ast_bridge.TypeExpr) !MirStructLiteralConstruction {
        // Async lowering may create compiler-owned zero-span aggregate nodes.
        // They have no source-keyed fact; their generated declaration is the
        // only admitted fallback. Real source literals must carry the fact.
        const result: MirStructLiteralConstruction = if (!isSourceSpan(span)) blk: {
            if (self.packedBitsInfoForType(generated_ty) != null) break :blk .{ .target_ty = generated_ty, .construction = .packed_bits };
            const decl = self.structDeclForType(generated_ty) orelse return error.UnsupportedLlvmEmission;
            break :blk .{ .target_ty = generated_ty, .construction = if (decl.is_c_union) .c_union else .declared_struct };
        } else blk: {
            const fact = self.mirTargetTypeFactAt(.struct_literal, span) orelse return error.UnsupportedLlvmEmission;
            break :blk .{ .target_ty = fact.target_ty, .construction = fact.aggregate_construction orelse return error.UnsupportedLlvmEmission };
        };
        switch (result.construction) {
            .packed_bits => if (self.packedBitsInfoForType(result.target_ty) == null) return error.UnsupportedLlvmEmission,
            .declared_struct, .c_union => {
                const decl = self.structDeclForType(result.target_ty) orelse return error.UnsupportedLlvmEmission;
                if (decl.is_c_union != (result.construction == .c_union)) return error.UnsupportedLlvmEmission;
            },
        }
        return result;
    }

    fn mirTargetTypeFactAtOwned(self: *LlvmEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span, target_owner: []const u8, target_index: ?usize) ?mir.TargetTypeFact {
        return mir_source_bridge.targetTypeFactAtOwnedCurrentSpan(self.currentMirFunction(), kind, span, target_owner, target_index);
    }

    fn mirConstGetIndexAt(self: *LlvmEmitter, span: ast_bridge.Span) ?usize {
        return mir_source_bridge.uniqueConstGetIndexAt(self.currentMirFunction(), span);
    }

    fn mirFactSubjectSupportedNow(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) bool {
        const ty = self.local_types.get(fact.subject) orelse return false;
        if (fact.element_index != null) return self.fixedLocalPointerArrayElementType(ty) != null;
        return lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty) or self.fixedLocalPointerArrayElementType(ty) != null;
    }

    fn fixedLocalPointerArrayElementType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, array.child.*)) return null;
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

    fn applyMirPointerProvenanceFact(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) !void {
        if (!self.mirFactSubjectSupportedNow(fact)) return;
        try self.emitMirPointerProvenanceConsumedComment(fact);
        try self.applyMirPointerProvenanceFactState(fact);
    }

    fn applyMirPointerProvenanceFactState(self: *LlvmEmitter, fact: mir.PointerProvenanceFact) !void {
        if (fact.field_path) |field_path| {
            if (fact.element_index) |index| {
                const element_path = try self.aggregatePointerArrayElementPath(field_path, @intCast(index));
                try self.setAggregatePointerFieldProvenance(fact.subject, element_path, mir_source_bridge.pointerFactLiveState(fact));
            } else {
                try self.setAggregatePointerFieldProvenance(fact.subject, field_path, mir_source_bridge.pointerFactLiveState(fact));
            }
            return;
        }
        if (fact.element_index) |index| {
            try self.setLocalArrayPointerElementProvenance(fact.subject, @intCast(index), mir_source_bridge.pointerFactLiveState(fact));
            return;
        }
        const live_global = mir_source_bridge.pointerFactIsLiveGlobal(fact);
        if (self.fixedLocalPointerArrayElementType(self.local_types.get(fact.subject) orelse return) != null) {
            self.clearLocalArrayPointerElementsForLocal(fact.subject);
            return;
        }
        if (live_global) {
            try self.pointer_local_provenance.put(fact.subject, .global_storage);
        } else if (mir_source_bridge.pointerFactIsLiveLocal(fact)) {
            try self.pointer_local_provenance.put(fact.subject, .local_storage);
        } else {
            _ = self.pointer_local_provenance.remove(fact.subject);
        }
    }

    fn applyMirPointerProvenanceFactsAtSourceWithMode(self: *LlvmEmitter, subject: []const u8, element_index: ?usize, span: ast_bridge.Span, comment_mode: MirFactCommentMode) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactMatchesAt(fact, subject, element_index, span)) continue;
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

    fn applyMirPointerProvenanceInvalidationsAtCall(self: *LlvmEmitter, span: ast_bridge.Span) void {
        const function = self.currentMirFunction() orelse return;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactIsCallInvalidationAt(fact, span)) continue;
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

    fn applyMirPointerProvenanceFactsAtSource(self: *LlvmEmitter, subject: []const u8, element_index: ?usize, span: ast_bridge.Span) !bool {
        return self.applyMirPointerProvenanceFactsAtSourceWithMode(subject, element_index, span, .emit_comment);
    }

    fn applyMirAggregatePointerFieldFactsAtSource(self: *LlvmEmitter, subject: []const u8, field_path: []const u8, element_index: ?usize, span: ast_bridge.Span) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.aggregatePointerFieldFactMatchesAt(fact, subject, field_path, element_index, span)) continue;
            matched = true;
            try self.emitMirPointerProvenanceConsumedComment(fact);
            try self.applyMirPointerProvenanceFactState(fact);
        }
        return matched;
    }

    fn applyMirAggregatePointerFieldFactsForSubjectAtSource(self: *LlvmEmitter, subject: []const u8, span: ast_bridge.Span) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactMatchesSubjectFieldAt(fact, subject, span)) continue;
            matched = true;
            try self.emitMirPointerProvenanceConsumedComment(fact);
            try self.applyMirPointerProvenanceFactState(fact);
        }
        return matched;
    }

    fn directMirAddressProvenanceExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceExpr(inner.*),
            .cast => |node| self.directMirAddressProvenanceExpr(node.value.*),
            .address_of => |inner| self.directMirAddressProvenanceTarget(inner.*),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directMirAddressProvenanceExpr(call.args[0]),
            else => false,
        };
    }

    fn directMirAddressProvenanceTarget(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceTarget(inner.*),
            .ident => |ident| self.global_types.contains(ident.text) or self.local_types.contains(ident.text),
            else => false,
        };
    }

    fn isMirAssumeNoaliasCall(self: *LlvmEmitter, call: anytype) bool {
        return call.type_args.len == 0 and
            call.args.len == 2 and
            self.mirHasCallTargetKindAt(.assume_noalias, call.callee.*.span);
    }

    fn mirPointerProvenanceCoversDirectLocalUpdate(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, expr: ast_bridge.Expr) bool {
        return lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty) and self.directMirPointerContainerValueExpr(expr);
    }

    fn directMirRawManyZeroOffsetExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirRawManyZeroOffsetExpr(inner.*),
            .cast => |node| self.directMirRawManyZeroOffsetExpr(node.value.*),
            .call => |call| blk: {
                if (self.isMirAssumeNoaliasCall(call)) {
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

    fn directRawManyLocalName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn directMirPointerLocalCopyExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirPointerLocalCopyExpr(inner.*),
            .cast => |node| self.directMirPointerLocalCopyExpr(node.value.*),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directMirPointerLocalCopyExpr(call.args[0]),
            .ident => |ident| blk: {
                const ty = self.local_types.get(ident.text) orelse break :blk false;
                break :blk lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty);
            },
            else => false,
        };
    }

    fn directMirFixedPointerArrayElementExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirFixedPointerArrayElementExpr(inner.*),
            .cast => |node| self.directMirFixedPointerArrayElementExpr(node.value.*),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directMirFixedPointerArrayElementExpr(call.args[0]),
            .index => |node| self.directLocalArrayElementPath(expr) != null or
                self.localPointerArrayAliasBaseName(node.base.*) != null,
            else => false,
        };
    }

    fn directMirAggregatePointerFieldExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerFieldExpr(inner.*),
            .cast => |node| self.directMirAggregatePointerFieldExpr(node.value.*),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directMirAggregatePointerFieldExpr(call.args[0]),
            else => self.directLocalAggregateMemberPath(expr) != null or
                self.aggregatePointerAliasMemberPath(expr) != null,
        };
    }

    fn directMirAggregatePointerArrayElementExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerArrayElementExpr(inner.*),
            .cast => |node| self.directMirAggregatePointerArrayElementExpr(node.value.*),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directMirAggregatePointerArrayElementExpr(call.args[0]),
            else => self.directLocalAggregateArrayElementPath(expr) != null or
                self.aggregatePointerAliasArrayElementPath(expr) != null,
        };
    }

    fn directMirPointerContainerValueExpr(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        switch (expr.kind) {
            .call => |call| {
                if (self.isMirAssumeNoaliasCall(call)) {
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

    fn applyMirPointerProvenanceForLocalInitializer(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
        if (lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty)) {
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

    fn applyMirPointerProvenanceForAssignment(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, value_expr: ast_bridge.Expr, span: ast_bridge.Span) !void {
        if (lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty)) {
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

    fn applyMirPointerProvenanceForIndexAssignment(self: *LlvmEmitter, target: ast_bridge.Expr, value_expr: ast_bridge.Expr, span: ast_bridge.Span) !void {
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

    fn directGlobalStorageRoot(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| !self.local_slots.contains(ident.text) and !self.local_types.contains(ident.text) and self.global_types.contains(ident.text),
            .grouped => |inner| self.directGlobalStorageRoot(inner.*),
            .index => |node| self.directGlobalStorageRoot(node.base.*),
            .member => |node| self.directGlobalStorageRoot(node.base.*),
            else => false,
        };
    }

    const MirFactCommentMode = enum {
        silent,
        emit_comment,
    };

    fn updatePointerProvenanceFromMirOrLocalProof(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr, comment_mode: MirFactCommentMode) !void {
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty)) {
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

    fn updatePointerProvenanceAssignmentFromMirOrLocalProof(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, value_expr: ast_bridge.Expr, span: ast_bridge.Span) !void {
        if (!lower_llvm_shape.isPointerLikeType(&self.type_aliases, ty)) {
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

    fn localAggregateAddressBaseName(self: *LlvmEmitter, expr: ast_bridge.Expr) ?[]const u8 {
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

    fn updateAggregatePointerAliasProvenance(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, init: ast_bridge.Expr) !void {
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

    fn invalidateAggregatePointerDerefAssignment(self: *LlvmEmitter, ptr_expr: ast_bridge.Expr) void {
        const local_name = self.localAggregatePointerAliasBaseName(ptr_expr) orelse return;
        self.clearAggregatePointerFieldsForLocal(local_name);
        self.clearLocalSlicesBackedByArray(local_name);
    }

    fn pointerExprHasGlobalStorageProvenance(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
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
            .call => |call| if (self.isMirAssumeNoaliasCall(call))
                self.pointerExprHasGlobalStorageProvenance(call.args[0])
            else if (self.mirHasCallTargetKindAt(.raw_many_offset, call.callee.*.span)) blk: {
                const info = self.rawManyOffsetCallInfo(call, .raw_many_offset) orelse break :blk false;
                break :blk call.args.len == 1 and
                    self.localArrayConstIndexValue(call.args[0]) == 0 and
                    self.pointerExprHasGlobalStorageProvenance(info.base);
            } else false,
            else => false,
        };
    }

    // Positive locality proof for the bare pointer-deref access class (spec I.13):
    // PLAIN deref lowering is allowed only when the pointer provably names the
    // current function's own storage — a live MIR local_storage fact for the
    // pointer local, or a syntactic address-of a named local (through grouped/
    // cast). Everything else (params, unknown calls, invalidated facts, member/
    // element-derived pointers without a fact) lowers race-tolerantly.
    fn pointerExprHasProvenLocalStorage(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
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
    fn directLocalStorageRoot(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
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
    fn derefUsesRaceTolerantLowering(self: *LlvmEmitter, ptr_expr: ast_bridge.Expr, pointee_ty: ast_bridge.TypeExpr) bool {
        if (self.isAggregateType(pointee_ty)) return false;
        return !self.pointerExprHasProvenLocalStorage(ptr_expr);
    }

    fn emitRaceTolerantAggregateDerefLoad(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr) ![]const u8 {
        const aggregate_ty = try self.llvmType(ty);
        var result: []const u8 = "zeroinitializer";
        const resolved_ty = self.resolveAliasType(ty);
        switch (resolved_ty.kind) {
            .nullable => |child| {
                if (!self.nullablePayloadIsValueType(child.*)) {
                    if (!self.isAggregateType(child.*)) return error.UnsupportedLlvmEmission;
                    return self.emitRaceTolerantAggregateDerefLoad(ptr, child.*);
                }
                const tag_ty = simpleType(ty.span, "bool");
                const tag_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, aggregate_ty, ptr });
                const tag = try self.emitOrdinaryLoad(tag_ty, tag_ptr, true);
                const with_tag = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i1 {s}, 0\n", .{ with_tag, aggregate_ty, result, tag });
                const payload_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 1\n", .{ payload_ptr, aggregate_ty, ptr });
                const payload = if (self.isAggregateType(child.*))
                    try self.emitRaceTolerantAggregateDerefLoad(payload_ptr, child.*)
                else
                    try self.emitOrdinaryLoad(child.*, payload_ptr, true);
                const with_payload = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_payload, aggregate_ty, with_tag, try self.llvmType(child.*), payload });
                return with_payload;
            },
            .closure_type, .dyn_trait => {
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
            .slice => {
                for (0..2) |i| {
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    const field_ty = if (i == 0) "ptr" else "i64";
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} unordered, align 8{s}\n", .{ field_value, field_ty, field_ptr, try self.debugCallSuffix() });
                    const next = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ next, aggregate_ty, result, field_ty, field_value, i });
                    result = next;
                }
            },
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return error.UnsupportedLlvmEmission;
                for (0..3) |i| {
                    const semantic_ty = if (i == 0)
                        simpleType(ty.span, "bool")
                    else if (typeNameEql(self.resolveAliasType(node.args[i - 1]), "void"))
                        simpleType(ty.span, "u8")
                    else
                        node.args[i - 1];
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    const field_value = if (self.isAggregateType(semantic_ty))
                        try self.emitRaceTolerantAggregateDerefLoad(field_ptr, semantic_ty)
                    else blk: {
                        try self.emitOrdinaryShadowHook(field_ptr, semantic_ty, .load_pre);
                        break :blk try self.emitOrdinaryLoad(semantic_ty, field_ptr, true);
                    };
                    const next = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ next, aggregate_ty, result, try self.llvmType(semantic_ty), field_value, i });
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
                if (self.overlayInfoForType(ty)) |overlay| {
                    return try self.emitRaceTolerantLlvmArrayLoad(ptr, aggregate_ty, "i8", std.math.cast(usize, overlay.size) orelse return error.UnsupportedLlvmEmission, 1);
                }
                if (self.taggedUnionForType(ty)) |union_decl| {
                    const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
                    const tag_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, aggregate_ty, ptr });
                    const tag = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = load atomic i32, ptr {s} unordered, align 4{s}\n", .{ tag, tag_ptr, try self.debugCallSuffix() });
                    const with_tag = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i32 {s}, 0\n", .{ with_tag, aggregate_ty, result, tag });
                    result = with_tag;
                    if (layout.padding_size != 0) {
                        const padding_ty = try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i8]", .{layout.padding_size});
                        const padding = try self.emitRaceTolerantLlvmArrayFieldLoad(ptr, aggregate_ty, 1, padding_ty, "i8", layout.padding_size, 1);
                        const with_padding = try self.nextTemp();
                        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_padding, aggregate_ty, result, padding_ty, padding });
                        result = with_padding;
                    }
                    const storage_ty = try self.taggedUnionPayloadStorageType(layout);
                    const element_ty = try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{layout.payload_alignment * 8});
                    const storage = try self.emitRaceTolerantLlvmArrayFieldLoad(ptr, aggregate_ty, layout.payload_field_index, storage_ty, element_ty, layout.storage_count, layout.payload_alignment);
                    const with_storage = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ with_storage, aggregate_ty, result, storage_ty, storage, layout.payload_field_index });
                    result = with_storage;
                    return result;
                }
                const struct_decl = self.structDeclForType(ty) orelse return error.UnsupportedLlvmEmission;
                if (struct_decl.is_c_union) {
                    const layout = self.cUnionStorageLayout(struct_decl) orelse return error.UnsupportedLlvmEmission;
                    if (layout.alignment > 8) return error.UnsupportedLlvmEmission;
                    const element_ty = try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{layout.alignment * 8});
                    return try self.emitRaceTolerantLlvmArrayLoad(ptr, aggregate_ty, element_ty, layout.count, layout.alignment);
                }
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

    fn emitRaceTolerantAggregateDerefStore(self: *LlvmEmitter, ptr: []const u8, ty: ast_bridge.TypeExpr, value: []const u8) !void {
        const aggregate_ty = try self.llvmType(ty);
        const resolved_ty = self.resolveAliasType(ty);
        switch (resolved_ty.kind) {
            .nullable => |child| {
                if (!self.nullablePayloadIsValueType(child.*)) {
                    if (!self.isAggregateType(child.*)) return error.UnsupportedLlvmEmission;
                    return self.emitRaceTolerantAggregateDerefStore(ptr, child.*, value);
                }
                const payload = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, aggregate_ty, value });
                const payload_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 1\n", .{ payload_ptr, aggregate_ty, ptr });
                if (self.isAggregateType(child.*)) {
                    try self.emitRaceTolerantAggregateDerefStore(payload_ptr, child.*, payload);
                } else {
                    try self.emitOrdinaryStore(child.*, try self.llvmType(child.*), payload, payload_ptr, true);
                }
                const tag = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ tag, aggregate_ty, value });
                const tag_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, aggregate_ty, ptr });
                try self.emitOrdinaryStore(simpleType(ty.span, "bool"), "i1", tag, tag_ptr, true);
                return;
            },
            .closure_type, .dyn_trait => {
                for (0..2) |i| {
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, aggregate_ty, value, i });
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    try self.out.print(self.allocator, "  store atomic ptr {s}, ptr {s} unordered, align 8{s}\n", .{ field_value, field_ptr, try self.debugCallSuffix() });
                }
            },
            .slice => {
                for (0..2) |i| {
                    const field_ty = if (i == 0) "ptr" else "i64";
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, aggregate_ty, value, i });
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} unordered, align 8{s}\n", .{ field_ty, field_value, field_ptr, try self.debugCallSuffix() });
                }
            },
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return error.UnsupportedLlvmEmission;
                for (0..3) |i| {
                    const semantic_ty = if (i == 0)
                        simpleType(ty.span, "bool")
                    else if (typeNameEql(self.resolveAliasType(node.args[i - 1]), "void"))
                        simpleType(ty.span, "u8")
                    else
                        node.args[i - 1];
                    const field_value = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ field_value, aggregate_ty, value, i });
                    const field_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ field_ptr, aggregate_ty, ptr, i });
                    if (self.isAggregateType(semantic_ty)) {
                        try self.emitRaceTolerantAggregateDerefStore(field_ptr, semantic_ty, field_value);
                    } else {
                        try self.emitOrdinaryShadowHook(field_ptr, semantic_ty, .store_pre);
                        try self.emitOrdinaryStore(semantic_ty, try self.llvmType(semantic_ty), field_value, field_ptr, true);
                        try self.emitOrdinaryShadowHook(field_ptr, semantic_ty, .store_post);
                    }
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
                if (self.overlayInfoForType(ty)) |overlay| {
                    try self.emitRaceTolerantLlvmArrayStore(ptr, aggregate_ty, "i8", std.math.cast(usize, overlay.size) orelse return error.UnsupportedLlvmEmission, 1, value);
                    return;
                }
                if (self.taggedUnionForType(ty)) |union_decl| {
                    const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
                    const tag = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ tag, aggregate_ty, value });
                    const tag_ptr = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, aggregate_ty, ptr });
                    try self.out.print(self.allocator, "  store atomic i32 {s}, ptr {s} unordered, align 4{s}\n", .{ tag, tag_ptr, try self.debugCallSuffix() });
                    if (layout.padding_size != 0) {
                        const padding_ty = try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i8]", .{layout.padding_size});
                        const padding = try self.nextTemp();
                        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ padding, aggregate_ty, value });
                        try self.emitRaceTolerantLlvmArrayFieldStore(ptr, aggregate_ty, 1, padding_ty, "i8", layout.padding_size, 1, padding);
                    }
                    const storage_ty = try self.taggedUnionPayloadStorageType(layout);
                    const storage = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ storage, aggregate_ty, value, layout.payload_field_index });
                    const element_ty = try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{layout.payload_alignment * 8});
                    try self.emitRaceTolerantLlvmArrayFieldStore(ptr, aggregate_ty, layout.payload_field_index, storage_ty, element_ty, layout.storage_count, layout.payload_alignment, storage);
                    return;
                }
                const struct_decl = self.structDeclForType(ty) orelse return error.UnsupportedLlvmEmission;
                if (struct_decl.is_c_union) {
                    const layout = self.cUnionStorageLayout(struct_decl) orelse return error.UnsupportedLlvmEmission;
                    if (layout.alignment > 8) return error.UnsupportedLlvmEmission;
                    const element_ty = try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{layout.alignment * 8});
                    try self.emitRaceTolerantLlvmArrayStore(ptr, aggregate_ty, element_ty, layout.count, layout.alignment, value);
                    return;
                }
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

    fn emitRaceTolerantLlvmArrayFieldLoad(self: *LlvmEmitter, ptr: []const u8, aggregate_ty: []const u8, field_index: usize, array_ty: []const u8, element_ty: []const u8, count: usize, alignment: usize) ![]const u8 {
        const array_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ array_ptr, aggregate_ty, ptr, field_index });
        return self.emitRaceTolerantLlvmArrayLoad(array_ptr, array_ty, element_ty, count, alignment);
    }

    fn emitRaceTolerantLlvmArrayLoad(self: *LlvmEmitter, ptr: []const u8, array_ty: []const u8, element_ty: []const u8, count: usize, alignment: usize) ![]const u8 {
        var result: []const u8 = "zeroinitializer";
        for (0..count) |i| {
            const element_ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ element_ptr, array_ty, ptr, i });
            const element = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} unordered, align {d}{s}\n", .{ element, element_ty, element_ptr, alignment, try self.debugCallSuffix() });
            const next = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{ next, array_ty, result, element_ty, element, i });
            result = next;
        }
        return result;
    }

    fn emitRaceTolerantLlvmArrayFieldStore(self: *LlvmEmitter, ptr: []const u8, aggregate_ty: []const u8, field_index: usize, array_ty: []const u8, element_ty: []const u8, count: usize, alignment: usize, value: []const u8) !void {
        const array_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ array_ptr, aggregate_ty, ptr, field_index });
        return self.emitRaceTolerantLlvmArrayStore(array_ptr, array_ty, element_ty, count, alignment, value);
    }

    fn emitRaceTolerantLlvmArrayStore(self: *LlvmEmitter, ptr: []const u8, array_ty: []const u8, element_ty: []const u8, count: usize, alignment: usize, value: []const u8) !void {
        for (0..count) |i| {
            const element = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ element, array_ty, value, i });
            const element_ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ element_ptr, array_ty, ptr, i });
            try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} unordered, align {d}{s}\n", .{ element_ty, element, element_ptr, alignment, try self.debugCallSuffix() });
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

    fn scalarPointerMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr, field_ty: ast_bridge.TypeExpr) bool {
        if (self.isAggregateType(field_ty)) return false;
        return self.pointerMemberBaseUsesRaceTolerantLowering(base_expr);
    }

    fn pointerMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr) bool {
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        const root = if (base_ty.kind == .pointer) base_expr else self.pointerMemberRoot(base_expr) orelse return false;
        return !self.pointerExprHasProvenLocalStorage(root);
    }

    fn pointerMemberRoot(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.Expr {
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

    fn scalarIndexedMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr, field_ty: ast_bridge.TypeExpr) bool {
        if (self.isAggregateType(field_ty)) return false;
        const indexed = self.indexedMemberRoot(base_expr) orelse return false;
        const element_ty = self.indexElementType(indexed.base.*) orelse return false;
        return self.aggregateIndexUsesRaceTolerantLowering(indexed.base.*, element_ty);
    }

    fn aggregateIndexedMemberBaseUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr, field_ty: ast_bridge.TypeExpr) bool {
        if (!self.isAggregateType(field_ty)) return false;
        const indexed = self.indexedMemberRoot(base_expr) orelse return false;
        const element_ty = self.indexElementType(indexed.base.*) orelse return false;
        return self.aggregateIndexUsesRaceTolerantLowering(indexed.base.*, element_ty);
    }

    fn indexedMemberRoot(self: *LlvmEmitter, expr: ast_bridge.Expr) ?syntax_bridge.IndexExpr {
        if (indexExpr(expr)) |indexed| return indexed;
        return switch (expr.kind) {
            .grouped => |inner| self.indexedMemberRoot(inner.*),
            .member => |node| self.indexedMemberRoot(node.base.*),
            else => null,
        };
    }

    fn scalarIndexUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr, element_ty: ast_bridge.TypeExpr) bool {
        if (self.isAggregateType(element_ty)) return false;
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        if (base_ty.kind == .slice) return true;
        return switch (base_expr.kind) {
            .grouped => |inner| self.scalarIndexUsesRaceTolerantLowering(inner.*, element_ty),
            .deref => |ptr_expr| !self.pointerExprHasProvenLocalStorage(ptr_expr.*),
            else => false,
        };
    }

    fn aggregateIndexUsesRaceTolerantLowering(self: *LlvmEmitter, base_expr: ast_bridge.Expr, element_ty: ast_bridge.TypeExpr) bool {
        if (!self.isAggregateType(element_ty)) return false;
        const base_ty = self.resolveAliasType(self.exprType(base_expr) orelse return false);
        if (base_ty.kind == .slice) return true;
        return switch (base_expr.kind) {
            .grouped => |inner| self.aggregateIndexUsesRaceTolerantLowering(inner.*, element_ty),
            .deref => |ptr_expr| !self.pointerExprHasProvenLocalStorage(ptr_expr.*),
            else => false,
        };
    }

    fn emitIndexLoad(self: *LlvmEmitter, node: anytype, index_span: ast_bridge.Span) ![]const u8 {
        if (overlayMemberFromIndexBase(node.base.*)) |member| {
            if (self.overlayField(member.base.*, member.name.text)) |field| {
                // Any array-view element (byte or non-byte): the byte offset is
                // `index * sizeof(elem)`, computed by `emitIndexAddress` via a typed GEP
                // over the storage base, so the load just uses the element type.
                const element_ty = overlayArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                const result_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedLlvmEmission).target_ty;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result_ty), self.resolveAliasType(element_ty))) return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(element_ty), ptr, try self.debugCallSuffix() });
                return result;
            }
        }
        const inferred_element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const element_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedLlvmEmission;
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

    fn arrayBasePointer(self: *LlvmEmitter, expr: ast_bridge.Expr) anyerror![]const u8 {
        return self.aggregateBasePointer(expr);
    }

    fn aggregateBasePointer(self: *LlvmEmitter, expr: ast_bridge.Expr) anyerror![]const u8 {
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

    fn materializeAggregateRvalue(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!self.isAggregateType(ty)) return error.UnsupportedLlvmEmission;
        const value = try self.emitExpr(expr, ty);
        const ptr = try self.nextTemp();
        try self.emitAllocaConcreteStore(ptr, ty, value);
        return ptr;
    }

    fn isStableAggregateAddress(self: *LlvmEmitter, expr: ast_bridge.Expr) bool {
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
    fn mirCheckElided(self: *LlvmEmitter, span: ast_bridge.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.elided_bounds) |pt| {
                if (pt.line == span.line and pt.column == span.column) return true;
            }
        }
        return false;
    }

    fn requireMirBoundsFact(self: *LlvmEmitter, kind: mir.BoundsFactKind, span: ast_bridge.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedLlvmEmission;
        for (function.bounds_facts) |fact| {
            if (fact.kind == kind and fact.source.line == span.line and fact.source.column == span.column) return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn requireMirNoOverflowRangeFact(self: *LlvmEmitter, op: []const u8, span: ast_bridge.Span) !void {
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

    fn emitSlice(self: *LlvmEmitter, node: anytype, slice_span: ast_bridge.Span) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const inferred_slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedLlvmEmission;
        const slice_ty = (self.mirTargetTypeFactAt(.expression_result, slice_span) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(slice_ty), self.resolveAliasType(inferred_slice_ty))) return error.UnsupportedLlvmEmission;
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

    fn emitArrayLiteralStores(self: *LlvmEmitter, array_ptr: []const u8, array_ty: ast_bridge.TypeExpr, items: []const ast_bridge.Expr) !void {
        const resolved_array_ty = self.resolveAliasType(array_ty);
        const array = switch (resolved_array_ty.kind) {
            .array => |array| array,
            else => return error.UnsupportedLlvmEmission,
        };
        const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
        if (items.len != len) return error.UnsupportedLlvmEmission;
        const element_ty = array.child.*;
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(self.allocator);
        for (items) |item| {
            try values.append(self.allocator, if (isUninitExpr(item))
                try self.zeroInitializer(element_ty)
            else
                try self.emitExprWithMirRangeTarget(item, element_ty, "aggregate_element"));
        }
        try self.emitZeroObjectBytes(array_ptr, resolved_array_ty);
        for (values.items, 0..) |value, i| {
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(resolved_array_ty), array_ptr, i });
            try self.emitPaddingPreservingStore(ptr, element_ty, value);
        }
    }

    fn emitExprOrTargetTypedUninit(self: *LlvmEmitter, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (isUninitExpr(expr)) return try self.zeroInitializer(target_ty);
        return self.emitExpr(expr, target_ty);
    }

    fn cUnionLiteralActiveField(self: *LlvmEmitter, fields: []const ast_bridge.StructLiteralField) ?ast_bridge.StructLiteralField {
        _ = self;
        var active: ?ast_bridge.StructLiteralField = null;
        for (fields) |field| {
            if (!isUninitExpr(field.value)) active = field;
        }
        return active orelse if (fields.len > 0) fields[0] else null;
    }

    fn structDeclField(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl, name: []const u8) ?ast_bridge.Field {
        _ = self;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, name)) return field;
        }
        return null;
    }

    fn structDeclFieldIndex(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl, name: []const u8) ?usize {
        _ = self;
        for (struct_decl.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name.text, name)) return index;
        }
        return null;
    }

    fn emitStructLiteralStores(self: *LlvmEmitter, struct_ptr: []const u8, struct_ty: ast_bridge.TypeExpr, fields: []const ast_bridge.StructLiteralField) !void {
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_llvm = try self.llvmType(struct_ty);
        if (struct_decl.is_c_union) {
            const active = self.cUnionLiteralActiveField(fields) orelse return error.UnsupportedLlvmEmission;
            const field = self.structDeclField(struct_decl, active.name.text) orelse return error.UnsupportedLlvmEmission;
            const value = if (isUninitExpr(active.value))
                try self.zeroInitializer(field.ty)
            else
                try self.emitExprWithMirRangeTarget(active.value, field.ty, field.name.text);
            try self.emitZeroObjectBytes(struct_ptr, struct_ty);
            try self.emitPaddingPreservingStore(struct_ptr, field.ty, value);
            return;
        }
        const values = try self.scratch.allocator().alloc(?[]const u8, struct_decl.fields.len);
        @memset(values, null);
        // Evaluate named fields in lexical source order. Layout order is applied only
        // when the already-computed SSA values are stored below.
        for (fields) |source_field| {
            const index = self.structDeclFieldIndex(struct_decl, source_field.name.text) orelse return error.UnsupportedLlvmEmission;
            const field = struct_decl.fields[index];
            values[index] = if (isUninitExpr(source_field.value))
                try self.zeroInitializer(field.ty)
            else
                try self.emitExprWithMirRangeTarget(source_field.value, field.ty, field.name.text);
        }
        try self.emitZeroObjectBytes(struct_ptr, struct_ty);
        for (struct_decl.fields, values, 0..) |field, maybe_value, i| {
            const value = maybe_value orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ ptr, struct_llvm, struct_ptr, i });
            try self.emitPaddingPreservingStore(ptr, field.ty, value);
        }
    }

    fn emitArrayLiteralValue(self: *LlvmEmitter, array_ty: ast_bridge.TypeExpr, items: []const ast_bridge.Expr) ![]const u8 {
        const resolved_array_ty = self.resolveAliasType(array_ty);
        if (resolved_array_ty.kind != .array) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.emitAlloca(ptr, try self.llvmType(resolved_array_ty));
        try self.emitArrayLiteralStores(ptr, resolved_array_ty, items);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(resolved_array_ty), ptr });
        return value;
    }

    fn emitStructLiteralValue(self: *LlvmEmitter, struct_ty: ast_bridge.TypeExpr, fields: []const ast_bridge.StructLiteralField) ![]const u8 {
        if (self.structDeclForType(struct_ty) == null) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.emitAlloca(ptr, try self.llvmType(struct_ty));
        try self.emitStructLiteralStores(ptr, struct_ty, fields);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(struct_ty), ptr });
        return value;
    }

    fn emitCall(self: *LlvmEmitter, call: anytype, expected_ty: ast_bridge.TypeExpr, span: ast_bridge.Span) ![]const u8 {
        defer self.applyMirPointerProvenanceInvalidationsAtCall(span);
        defer self.local_slice_global_pointer_arrays.clearRetainingCapacity();
        defer self.local_slice_pointer_array_ranges.clearRetainingCapacity();
        defer self.clearOwnedStringValueMapRetainingCapacity(&self.local_slice_aggregate_pointer_array_fields);
        defer self.local_pointer_array_aliases.clearRetainingCapacity();
        const call_kind = self.mirCallTargetKindAt(span);
        if (call_kind) |kind| switch (kind) {
            .drop, .forget_unchecked => return error.UnsupportedLlvmEmission,
            else => {},
        };
        if (call_kind == .bind) {
            const fact = self.mirTargetTypeFactAt(.bind, span) orelse return error.UnsupportedLlvmEmission;
            return try self.emitBindValue(call, fact.target_ty);
        }
        if (self.mirTargetTypeFactAt(.bind, span) != null) return error.UnsupportedLlvmEmission;
        // `Union.variant(...)` qualified constructor — self-typed from the owner (no target).
        if (self.mirTargetTypeFactAt(.qualified_union_result, span)) |fact| {
            return (try self.emitQualifiedUnionConstructor(call, fact.target_ty)) orelse error.UnsupportedLlvmEmission;
        }
        if (self.mirTargetTypeFactAt(.tagged_union, span)) |fact| {
            return (try self.emitTaggedUnionConstructor(call, fact.target_ty)) orelse error.UnsupportedLlvmEmission;
        }
        // Async lowering creates direct calls without source locations. Such calls
        // cannot safely query location-keyed builtin facts shared by other generated
        // nodes, so resolve declared functions before builtin dispatch.
        if (!isSourceSpan(span)) {
            if (self.directCallName(call.callee.*)) |callee| {
                if (self.fn_sigs.contains(callee)) return try self.emitDirectCall(callee, call, expected_ty);
            }
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

    fn emitBindValue(self: *LlvmEmitter, call: anytype, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
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
    fn dynVtableLlvmType(self: *LlvmEmitter, trait: declaration_artifacts.TraitDeclArtifact) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.scratch.allocator(), "{ ");
        for (trait.facts.methods, 0..) |_, i| {
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
            for (trait.facts.methods, 0..) |m, i| {
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
            if (self.linux_kernel and self.target_arch == .x86_64)
                try self.out.appendSlice(self.allocator, ") nounwind fn_ret_thunk_extern {\nbb_entry:\n")
            else if (self.linux_kernel and self.target_arch == .aarch64)
                try self.out.appendSlice(self.allocator, ") nounwind \"branch-target-enforcement\" {\nbb_entry:\n")
            else if (self.linux_kernel)
                try self.out.appendSlice(self.allocator, ") nounwind {\nbb_entry:\n")
            else
                try self.out.appendSlice(self.allocator, ") {\nbb_entry:\n");
            const narrowed = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = ptrtoint ptr %env to {s}\n", .{ narrowed, env_llvm });
            const returns_void = typeNameEql(sig.ret, "void");
            const result = if (returns_void) "" else try self.nextTemp();
            const ret_ext = if (sig.c_abi) self.cAbiExtension(sig.ret) else "";
            const env_ext = if (sig.c_abi) self.cAbiExtension(sig.params[0].ty) else "";
            if (returns_void) {
                try self.out.print(self.allocator, "  call void @{s}({s} {s}{s}", .{ thunk.fname, env_llvm, env_ext, narrowed });
            } else {
                try self.out.print(self.allocator, "  {s} = call {s}{s} @{s}({s} {s}{s}", .{ result, ret_ext, ret_llvm, thunk.fname, env_llvm, env_ext, narrowed });
            }
            for (sig.params[1..], 0..) |param, i| {
                const param_ext = if (sig.c_abi) self.cAbiExtension(param.ty) else "";
                try self.out.print(self.allocator, ", {s} {s}%a{d}", .{ try self.llvmType(param.ty), param_ext, i });
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

    fn emitDirectCall(self: *LlvmEmitter, callee: []const u8, call: anytype, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        _ = expected_ty;
        const sig = self.fn_sigs.get(callee) orelse return error.UnsupportedLlvmEmission;
        const ret_ast_ty = (self.mirTargetTypeFactAtOwned(.direct_call_result, call.callee.*.span, callee, null) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (!directCallFactMatchesDeclared(ret_ast_ty, sig.ret)) return error.UnsupportedLlvmEmission;
        const ret_ty = try self.llvmType(ret_ast_ty);
        if (typeNameEql(ret_ast_ty, "void")) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const fact_ty = (self.mirTargetTypeFactAtOwned(.direct_call_argument, arg.span, callee, i) orelse return error.UnsupportedLlvmEmission).target_ty;
            const arg_ty = if (i < sig.params.len) blk: {
                if (!directCallFactMatchesDeclared(fact_ty, sig.params[i].ty)) return error.UnsupportedLlvmEmission;
                break :blk fact_ty;
            } else blk: {
                if (!sig.is_variadic) return error.UnsupportedLlvmEmission;
                break :blk fact_ty;
            };
            const arg_value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg");
            const lowered_arg = if (i >= sig.params.len and sig.is_variadic and sig.c_abi)
                try self.promoteCVariadicArgument(arg_ty, arg_value)
            else
                ArgValue{ .ty = arg_ty, .value = arg_value };
            try args.append(self.allocator, lowered_arg);
        }
        const result = try self.nextTemp();
        const ret_ext = if (sig.c_abi) self.cAbiExtension(ret_ast_ty) else "";
        try self.out.print(self.allocator, "  {s} = call {s}{s} @{s}(", .{ result, ret_ext, ret_ty, callee });
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ext = if (sig.c_abi) self.cAbiExtension(arg.ty) else "";
            try self.out.print(self.allocator, "{s} {s}{s}", .{ try self.llvmType(arg.ty), arg_ext, arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitFnPointerCall(self: *LlvmEmitter, callee_expr: ast_bridge.Expr, args_expr: []const ast_bridge.Expr, fn_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitFnPointerVoidCall(self: *LlvmEmitter, callee_expr: ast_bridge.Expr, args_expr: []const ast_bridge.Expr, fn_ty: ast_bridge.TypeExpr) !void {
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
    fn dynDispatchTrait(self: *LlvmEmitter, callee: ast_bridge.Expr) ?declaration_artifacts.TraitDeclArtifact {
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
    fn emitDynDispatch(self: *LlvmEmitter, call: anytype, trait: declaration_artifacts.TraitDeclArtifact) ![]const u8 {
        const member = memberCallee(call) orelse return error.UnsupportedLlvmEmission;
        const slot = traitMethodIndex(trait, member.name.text) orelse return error.UnsupportedLlvmEmission;
        const msig = trait.facts.methods[slot];
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
            if (i + 1 >= msig.params.len) return error.UnsupportedLlvmEmission;
            const declared_ty = msig.params[i + 1].ty;
            const arg_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_argument, arg.span, trait.facts.name.text, mir.dynDispatchArgumentFactIndex(slot, i)) orelse return error.UnsupportedLlvmEmission).target_ty;
            if (!std.meta.eql(arg_ty, declared_ty)) return error.UnsupportedLlvmEmission;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg") });
        }
        const ret_ty: ast_bridge.TypeExpr = msig.return_type orelse simpleType(member.name.span, "void");
        if (typeNameEql(ret_ty, "void")) {
            try self.out.print(self.allocator, "  call void {s}(ptr {s}", .{ code, data });
            for (args.items) |arg| try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
            try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
            return "0";
        }
        const result_fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, call.callee.*.span, trait.facts.name.text, slot) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (!std.meta.eql(result_fact_ty, ret_ty)) return error.UnsupportedLlvmEmission;
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(ptr {s}", .{ result, try self.llvmType(ret_ty), code, data });
        for (args.items) |arg| try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitClosureCall(self: *LlvmEmitter, callee_expr: ast_bridge.Expr, args_expr: []const ast_bridge.Expr, closure_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitClosureVoidCall(self: *LlvmEmitter, callee_expr: ast_bridge.Expr, args_expr: []const ast_bridge.Expr, closure_ty: ast_bridge.TypeExpr) !void {
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

    fn emitBuiltinValueCall(self: *LlvmEmitter, call: anytype, expected_ty: ast_bridge.TypeExpr, span: ast_bridge.Span) !?[]const u8 {
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind) |kind| {
            if (self.reflectionCallInfo(call, kind)) |info| return self.reflectionCallValue(call, info) orelse error.UnsupportedLlvmEmission;
        }
        // `declassify(x)` / `reveal(x)` strip the constant-time `Secret<T>` tag.
        // Secret shares T's representation, so this is a value-identity pass-through.
        if (call_kind == .declassify) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const types = try self.declassifyTypesForEmission(call);
            const value = try self.emitExpr(call.args[0], types.source_ty);
            return try self.coerceExprValue(value, call.args[0], expected_ty);
        }
        if (call_kind == .assume_noalias) {
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const types = try self.assumeNoaliasTypesForEmission(call);
            const value = try self.emitExpr(call.args[0], types.source_ty);
            _ = try self.emitExpr(call.args[1], simpleType(call.args[1].span, "usize"));
            return try self.coerceExprValue(value, call.args[0], expected_ty);
        }
        if (call_kind == .const_get) {
            const info = self.constGetCallInfo(call, .const_get) orelse return error.UnsupportedLlvmEmission;
            if (call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base_ptr = try self.arrayBasePointer(info.base);
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(info.array_ty), base_ptr, info.index });
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.element_ty), ptr });
            return result;
        }
        if (call_kind == .bitcast) {
            const types = try self.bitcastTypesForEmission(call, .bitcast);
            const value = try self.emitExpr(call.args[0], types.source_ty);
            return try self.emitBitcastValue(value, types.source_ty, types.target_ty);
        }
        if (call_kind == .phys) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            _ = try self.physResultTypeForEmission(call, .phys);
            return try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
        }
        if (call_kind == .mmio_map) {
            const info = self.mmioMapCallInfo(call, .mmio_map) orelse return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], info.source_ty);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (call_kind) |kind| {
            if (self.dmaBufCallInfo(call, kind)) |info| {
                if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
                const base = try self.emitExpr(info.base, info.dma_ty);
                if (std.mem.eql(u8, info.op, "dma_addr")) return base;
                if (std.mem.eql(u8, info.op, "as_slice")) {
                    const ptr = try self.nextTemp();
                    const with_ptr = try self.nextTemp();
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, base });
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, try self.llvmType(info.result_ty), ptr });
                    try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 1, 1\n", .{ result, try self.llvmType(info.result_ty), with_ptr });
                    return result;
                }
                return error.UnsupportedLlvmEmission;
            }
        }
        if (self.mirHasCallTargetKindAt(.atomic_init, call.callee.*.span)) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload_ty = self.atomicInitPayloadTypeAt(call.callee.*.span, expected_ty) orelse return error.UnsupportedLlvmEmission;
            return try self.emitAtomicValueForStorage(call.args[0], payload_ty);
        }
        if (call_kind) |kind| {
            if (self.mmioAccessInfo(call, kind)) |info| {
                if (!std.mem.eql(u8, info.op, "read")) return null;
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                return try self.emitMmioReadInfo(info, call.args);
            }
        }
        if (call_kind) |kind| {
            if (self.maybeUninitCallInfo(call, kind)) |info| {
                if (!std.mem.eql(u8, info.op, "assume_init")) return null;
                if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
                const ptr = try self.storageBaseAddress(info.base);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.payload_ty), ptr });
                return result;
            }
        }
        if (call_kind == .raw_load) {
            const info = self.rawCallInfo(call, .raw_load) orelse return error.UnsupportedLlvmEmission;
            const value_ty = info.payload_ty;
            const addr = try self.emitExpr(call.args[0], info.address_ty);
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
        if (call_kind) |kind| switch (kind) {
            .va_start, .va_arg, .va_end => {
                // The cursor argument is either `&ap` for a local va_list or a `*mut va_list`
                // parameter. Normalize both to the ABI cursor pointer that va_arg / va_end want.
                const info = self.vaCallInfo(call, kind) orelse return error.UnsupportedLlvmEmission;
                const cursor_ty = info.cursor_ty orelse return error.UnsupportedLlvmEmission;
                const ap_ptr = try self.emitVaListCursorArg(call.args[0], cursor_ty);
                switch (info.kind) {
                    .va_arg => return try self.emitVaArg(ap_ptr, info.payload_ty orelse return error.UnsupportedLlvmEmission),
                    .va_end => {
                        try self.out.print(self.allocator, "  call void @llvm.va_end(ptr {s})\n", .{ap_ptr});
                        return ""; // void
                    },
                    .va_start => return error.UnsupportedLlvmEmission, // va.start only valid as a let initializer
                    else => unreachable,
                }
            },
            else => {},
        };
        if (call_kind == .raw_ptr) {
            const info = self.rawCallInfo(call, .raw_ptr) orelse return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], info.address_ty);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (call_kind == .enum_raw) {
            const info = self.enumRawCallInfo(call, .enum_raw) orelse return error.UnsupportedLlvmEmission;
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(info.base, info.enum_ty);
            return try self.castValue(value, info.enum_ty, info.repr_ty);
        }
        if (call_kind) |kind| {
            if (self.byteViewCallInfo(call, kind)) |info| return try self.emitByteViewCall(call, info);
        }
        const generated_result_constructor: ?mir.ResultConstructorFactInfo = if (!isSourceSpan(span))
            if (calleeIdentName(call.callee.*)) |name|
                if (std.mem.eql(u8, name, "ok"))
                    .{ .target_kind = .result_ok, .tag = "ok" }
                else if (std.mem.eql(u8, name, "err"))
                    .{ .target_kind = .result_err, .tag = "err" }
                else
                    null
            else
                null
        else
            null;
        const constructor_kind = self.mirCallTargetKindAt(span);
        const result_constructor = generated_result_constructor orelse
            if (constructor_kind) |kind| mir.resultConstructorFactInfo(kind) else null;
        if (result_constructor) |constructor| {
            const result_ty = if (!isSourceSpan(span))
                expected_ty
            else if (self.mirTargetTypeFactAt(constructor.target_kind, span)) |fact|
                fact.target_ty
            else
                return error.UnsupportedLlvmEmission;
            return try self.emitResultConstructorValue(call, result_ty, constructor.tag);
        }
        if (self.mirTargetTypeFactAt(.result_ok, span) != null or self.mirTargetTypeFactAt(.result_err, span) != null) return error.UnsupportedLlvmEmission;
        if (call_kind == .wrap_residue) {
            const info = self.domainResidueCallInfo(call, .wrap_residue) orelse return error.UnsupportedLlvmEmission;
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, info.domain_ty);
        }
        if (call_kind) |kind| {
            if (self.domainOpCallInfo(call, kind)) |info| return try self.emitDomainOpCall(call, info);
        }
        if (call_kind) |kind| {
            if (self.reduceCallInfo(call, kind)) |info| return try self.emitReduceCall(call, info);
        }
        if (call_kind) |kind| {
            if (self.conversionCallInfo(call, kind)) |info| {
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                const value = try self.emitExpr(call.args[0], info.source_ty);
                if (std.mem.eql(u8, info.op, "trap_from")) return try self.emitTrapConversion(value, info.source_ty, info.target_ty);
                if (std.mem.eql(u8, info.op, "sat_from")) return try self.emitSaturatingConversion(value, info.source_ty, info.target_ty);
                if (std.mem.eql(u8, info.op, "try_from")) return try self.emitTryConversion(value, info.source_ty, info.target_ty);
                if (!std.mem.eql(u8, info.op, "from") and !std.mem.eql(u8, info.op, "wrap_from") and !std.mem.eql(u8, info.op, "from_mod")) return error.UnsupportedLlvmEmission;
                return try self.castValue(value, info.source_ty, info.target_ty);
            }
        }
        if (call_kind) |kind| {
            if (self.wrappingCallInfo(call, kind)) |info| {
                if (self.integerBitsOf(info.result_ty) == null) return error.UnsupportedLlvmEmission;
                const left = try self.emitExpr(call.args[0], info.left_ty);
                const right = try self.emitExpr(call.args[1], info.right_ty);
                return try self.emitPlainBinaryValues(info.op, try self.llvmType(info.result_ty), left, right);
            }
        }
        if (call_kind) |kind| {
            if (self.uncheckedCallInfo(call, kind)) |info| {
                if (self.integerBitsOf(info.result_ty) == null) return error.UnsupportedLlvmEmission;
                try self.requireMirNoOverflowRangeFact(info.op, span);
                const left = try self.emitExpr(call.args[0], info.left_ty);
                const right = try self.emitExpr(call.args[1], info.right_ty);
                return try self.emitPlainBinaryValues(info.op, try self.llvmType(info.result_ty), left, right);
            }
        }
        if (call_kind) |kind| {
            if (self.atomicCallInfo(call, kind)) |info| {
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
        }
        if (call_kind == .raw_many_offset) {
            if (self.rawManyOffsetCallInfo(call, .raw_many_offset)) |info| {
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                const base = try self.emitExpr(info.base, info.base_ty);
                const index = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(info.element_ty), base, index });
                return result;
            }
        }
        return null;
    }

    fn emitVoidCall(self: *LlvmEmitter, callee: []const u8, call: anytype) !void {
        try self.emitVoidDirectCall(callee, call.args, call.callee.*.span);
    }

    fn emitVoidDirectCall(self: *LlvmEmitter, callee: []const u8, args_source: []const ast_bridge.Expr, callee_span: ast_bridge.Span) !void {
        const sig = self.fn_sigs.get(callee) orelse return error.UnsupportedLlvmEmission;
        // A `-> never` function lowers to a `void` LLVM declaration, so its call statement is a
        // plain `call void @fn(args)` (no result name) — handled here alongside `-> void`.
        if (!typeNameEql(sig.ret, "void") and !typeNameEql(sig.ret, "never")) return error.UnsupportedLlvmEmission;
        const fact_ret_ty = (self.mirTargetTypeFactAtOwned(.direct_call_result, callee_span, callee, null) orelse return error.UnsupportedLlvmEmission).target_ty;
        if (!directCallFactMatchesDeclared(fact_ret_ty, sig.ret)) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_source, 0..) |arg, i| {
            const fact_ty = (self.mirTargetTypeFactAtOwned(.direct_call_argument, arg.span, callee, i) orelse return error.UnsupportedLlvmEmission).target_ty;
            const arg_ty = if (i < sig.params.len) blk: {
                if (!std.meta.eql(fact_ty, sig.params[i].ty)) return error.UnsupportedLlvmEmission;
                break :blk fact_ty;
            } else blk: {
                if (!sig.is_variadic) return error.UnsupportedLlvmEmission;
                break :blk fact_ty;
            };
            const arg_value = try self.emitExprWithMirRangeTarget(arg, arg_ty, "call_arg");
            const lowered_arg = if (i >= sig.params.len and sig.is_variadic and sig.c_abi)
                try self.promoteCVariadicArgument(arg_ty, arg_value)
            else
                ArgValue{ .ty = arg_ty, .value = arg_value };
            try args.append(self.allocator, lowered_arg);
        }
        try self.out.print(self.allocator, "  call void @{s}(", .{callee});
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ext = if (sig.c_abi) self.cAbiExtension(arg.ty) else "";
            try self.out.print(self.allocator, "{s} {s}{s}", .{ try self.llvmType(arg.ty), arg_ext, arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitVoidStatementCall(self: *LlvmEmitter, call: anytype, span: ast_bridge.Span) !void {
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

    fn emitBinary(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (binaryIsComparison(node.op)) return self.emitComparison(node, ty);
        if (node.op == .logical_and or node.op == .logical_or) return self.emitLogicalBinary(node, ty);
        const llvm_ty = try self.llvmType(ty);
        if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, ty)) {
            return switch (node.op) {
                .add => try self.emitPlainBinary("fadd", node, ty, llvm_ty),
                .sub => try self.emitPlainBinary("fsub", node, ty, llvm_ty),
                .mul => try self.emitPlainBinary("fmul", node, ty, llvm_ty),
                .div => try self.emitPlainBinary("fdiv", node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        if (lower_llvm_shape.isWrapDomainType(&self.type_aliases, ty)) {
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
        if (lower_llvm_shape.isSatDomainType(&self.type_aliases, ty)) {
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

    fn emitLogicalBinary(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitUnary(self: *LlvmEmitter, node: anytype, unary_span: ast_bridge.Span) ![]const u8 {
        const inferred_ty = if (node.op == .logical_not)
            simpleType(unary_span, "bool")
        else if (node.op == .neg and node.expr.kind == .int_literal)
            null
        else
            self.exprType(node.expr.*);
        const ty = self.requireExpressionResultType(.{ .kind = .{ .unary = node }, .span = unary_span }, inferred_ty) orelse return error.UnsupportedLlvmEmission;
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
                if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, ty)) {
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
                if (lower_llvm_shape.isWrapDomainType(&self.type_aliases, ty)) {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ result, try self.llvmType(ty), value });
                    break :blk result;
                }
                return error.UnsupportedLlvmEmission;
            },
        };
    }

    fn negativeIntegerLiteralValue(self: *LlvmEmitter, expr: ast_bridge.Expr) !?[]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)}),
            .grouped => |inner| try self.negativeIntegerLiteralValue(inner.*),
            else => null,
        };
    }

    fn emitCast(self: *LlvmEmitter, span: ast_bridge.Span, value_expr: ast_bridge.Expr) ![]const u8 {
        const source_fact = self.mirTargetTypeFactAt(.explicit_cast_source, span) orelse return error.UnsupportedLlvmEmission;
        const target_fact = self.mirTargetTypeFactAt(.explicit_cast_target, span) orelse return error.UnsupportedLlvmEmission;
        const value = try self.emitExprNatural(value_expr, source_fact.target_ty);
        return try self.castValue(value, source_fact.target_ty, target_fact.target_ty);
    }

    fn emitExprNatural(self: *LlvmEmitter, expr: ast_bridge.Expr, source_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        return switch (expr.kind) {
            .binary => |node| try self.emitBinary(node, source_ty),
            .grouped => |inner| try self.emitExprNatural(inner.*, source_ty),
            else => try self.emitExpr(expr, source_ty),
        };
    }

    fn castValue(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
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
        if (lower_llvm_shape.pointerAddressCoercion(&self.type_aliases, source_ty, target_ty)) {
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
        if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, source_ty) and lower_llvm_shape.isFloatTypeOf(&self.type_aliases, target_ty)) {
            const op = if (lower_llvm_shape.isF32TypeOf(&self.type_aliases, source_ty)) "fpext" else "fptrunc";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        // Integer -> float: sitofp for signed sources, uitofp for unsigned.
        if (self.integerBitsOf(source_ty) != null and lower_llvm_shape.isFloatTypeOf(&self.type_aliases, target_ty)) {
            const op = if (self.isSignedIntegerType(source_ty)) "sitofp" else "uitofp";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        // Float -> integer: fptosi for signed targets, fptoui for unsigned (C truncation).
        if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, source_ty) and self.integerBitsOf(target_ty) != null) {
            const op = if (self.isSignedIntegerType(target_ty)) "fptosi" else "fptoui";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
            return result;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitBitcastValue(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn castIntegerValue(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitTrapConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
        const check = try self.emitConversionOutOfRange(value, source_ty, target_ty);
        if (check) |out_of_range| {
            const trap = try self.nextLabel("trap_conversion");
            const cont = try self.nextLabel("conversion_ok");
            try self.emitTrapBranch(out_of_range, trap, cont, trap, cont, "IntegerOverflow");
        }
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitSaturatingConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitByteViewCall(self: *LlvmEmitter, call: anytype, info: ByteViewCallInfo) ![]const u8 {
        if (call.type_args.len != 0) return error.UnsupportedLlvmEmission;
        return switch (info.kind) {
            .byte_view_as_bytes => try self.emitAsBytesCall(call, info),
            .byte_view_equal => try self.emitBytesEqualCall(call, info),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitAsBytesCall(self: *LlvmEmitter, call: anytype, info: ByteViewCallInfo) ![]const u8 {
        if (call.args.len != 1) return error.UnsupportedLlvmEmission;
        _ = byteViewAddressTarget(call.args[0]) orelse return error.UnsupportedLlvmEmission;
        const size = self.comptimeSizeOf(info.source_ty, 0) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitExpr(call.args[0], try self.pointerTypeFor(info.source_ty));
        const slice_llvm = try self.llvmType(info.result_ty);
        const with_ptr = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, slice_llvm, ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {d}, 1\n", .{ result, slice_llvm, with_ptr, size });
        return result;
    }

    fn emitBytesEqualCall(self: *LlvmEmitter, call: anytype, info: ByteViewCallInfo) ![]const u8 {
        if (call.args.len != 2) return error.UnsupportedLlvmEmission;
        const slice_llvm = try self.llvmType(info.source_ty);
        const left = try self.emitExpr(call.args[0], info.source_ty);
        const right = try self.emitExpr(call.args[1], info.source_ty);
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

    fn emitTryConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitConversionOutOfRange(self: *LlvmEmitter, value: []const u8, source_ty: ast_bridge.TypeExpr, target_ty: ast_bridge.TypeExpr) !?[]const u8 {
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

    fn intRangeOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?IntRange {
        const bits = self.integerBitsOf(ty) orelse return null;
        if (self.isSignedIntegerType(ty)) {
            const max = (@as(i128, 1) << @intCast(bits - 1)) - 1;
            return .{ .min = -max - 1, .max = max };
        }
        const max = (@as(i128, 1) << @intCast(bits)) - 1;
        return .{ .min = 0, .max = max };
    }

    fn emitComparison(self: *LlvmEmitter, node: anytype, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        // `opt == null` / `opt != null` for a value optional `?T` tests its present tag.
        if ((node.op == .eq or node.op == .ne)) {
            if (try self.valueOptionalNullCompare(node)) |result| return result;
        }
        // A comparison yields i1. The expected type is `bool` — or `Secret<bool>`
        // when the verdict stays secret-tainted (constant-time `secret == k`);
        // Secret is transparent, so the inner bool is what we lower against.
        const want = secretInnerType(expected_ty) orelse expected_ty;
        if (!typeNameEql(want, "bool")) return error.UnsupportedLlvmEmission;
        const operand_ty = self.comparisonOperandType(node) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(operand_ty);
        const pred = if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, operand_ty))
            floatComparisonPredicate(node.op) orelse return error.UnsupportedLlvmEmission
        else
            comparisonPredicate(node.op, self.isSignedIntegerType(operand_ty)) orelse return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, operand_ty);
        const right = try self.emitExpr(node.right.*, operand_ty);
        const result = try self.nextTemp();
        const cmp_op: []const u8 = if (lower_llvm_shape.isFloatTypeOf(&self.type_aliases, operand_ty)) "fcmp" else "icmp";
        try self.out.print(self.allocator, "  {s} = {s} {s} {s} {s}, {s}\n", .{ result, cmp_op, pred, llvm_ty, left, right });
        return result;
    }

    fn comparisonOperandType(self: *LlvmEmitter, node: anytype) ?ast_bridge.TypeExpr {
        const left_ty = self.comparisonOperandExprType(node.left.*);
        const right_ty = self.comparisonOperandExprType(node.right.*);
        const left_contextual = contextualIntegerLiteralExpr(node.left.*);
        const right_contextual = contextualIntegerLiteralExpr(node.right.*);

        if (left_contextual and !right_contextual) return right_ty orelse left_ty;
        if (right_contextual and !left_contextual) return left_ty orelse right_ty;
        return left_ty orelse right_ty;
    }

    fn comparisonOperandExprType(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .member, .index => if (!isSourceSpan(expr.span))
                self.exprType(expr)
            else if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact|
                fact.target_ty
            else
                null,
            else => self.exprType(expr),
        };
    }

    fn contextualIntegerLiteralExpr(expr: ast_bridge.Expr) bool {
        return switch (expr.kind) {
            .int_literal => |literal| blk: {
                const parts = numeric.parseIntegerLiteralParts(literal) orelse break :blk false;
                break :blk parts.suffix == null;
            },
            .grouped => |inner| contextualIntegerLiteralExpr(inner.*),
            .unary => |node| node.op == .neg and contextualIntegerLiteralExpr(node.expr.*),
            else => false,
        };
    }

    fn nullLiteralExpr(expr: ast_bridge.Expr) bool {
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

    fn emitCheckedArithmetic(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
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

    fn emitSaturatingArithmetic(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
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

    fn emitCheckedDivRem(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
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

    fn emitWrapShift(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
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

    fn emitCheckedShift(self: *LlvmEmitter, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
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

    fn emitShiftCountCheck(self: *LlvmEmitter, amount: []const u8, amount_ty: ast_bridge.TypeExpr, amount_llvm: []const u8, shifted_bits: u16) !void {
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

    fn emitLeftShiftOverflowCheck(self: *LlvmEmitter, result: []const u8, left: []const u8, amount: []const u8, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) !void {
        const reverse_op: []const u8 = if (self.isSignedIntegerType(ty)) "ashr" else "lshr";
        const reversed = try self.emitPlainBinaryValues(reverse_op, llvm_ty, result, amount);
        const overflow = try self.nextTemp();
        const overflow_trap = try self.nextLabel("trap_shift_overflow");
        const ok = try self.nextLabel("shift_overflow_ok");
        try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}\n", .{ overflow, llvm_ty, reversed, left });
        try self.emitTrapBranch(overflow, overflow_trap, ok, overflow_trap, ok, "IntegerOverflow");
    }

    fn emitPlainBinary(self: *LlvmEmitter, op: []const u8, node: anytype, ty: ast_bridge.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitBinaryOperand(self: *LlvmEmitter, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        if (expr.kind == .int_literal) {
            const parts = numeric.parseIntegerLiteralParts(expr.kind.int_literal) orelse return error.UnsupportedLlvmEmission;
            if (parts.suffix == null) {
                return self.emitExprWithMirRangeTarget(expr, target_ty, "binary_operand");
            }
        }
        const source_ty = self.exprType(expr) orelse return self.emitExprWithMirRangeTarget(expr, target_ty, "binary_operand");
        const value = try self.emitExprWithMirRangeTarget(expr, source_ty, "binary_operand");
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitPlainBinaryValues(self: *LlvmEmitter, op: []const u8, llvm_ty: []const u8, left: []const u8, right: []const u8) ![]const u8 {
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, op, llvm_ty, left, right });
        return result;
    }

    fn emitResultConstructorValue(self: *LlvmEmitter, call: anytype, expected_ty: ast_bridge.TypeExpr, tag: []const u8) ![]const u8 {
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const info = lower_llvm_shape.resultInfo(&self.type_aliases, expected_ty) orelse return error.UnsupportedLlvmEmission;
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

    fn emitResultValue(self: *LlvmEmitter, result_ty: ast_bridge.TypeExpr, is_ok: []const u8, ok_value: []const u8, err_value: []const u8) ![]const u8 {
        const info = lower_llvm_shape.resultInfo(&self.type_aliases, result_ty) orelse return error.UnsupportedLlvmEmission;
        const result_llvm = try self.llvmType(result_ty);
        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_llvm, is_ok });
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_llvm, tagged, try self.resultPayloadLlvmType(info.ok_ty), ok_value });
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_llvm, with_ok, try self.resultPayloadLlvmType(info.err_ty), err_value });
        return with_err;
    }

    fn emitTaggedUnionConstructor(self: *LlvmEmitter, call: anytype, target_ty: ast_bridge.TypeExpr) !?[]const u8 {
        const tag = taggedUnionConstructorName(call.callee.*) orelse return null;
        const union_decl = self.taggedUnionForType(target_ty) orelse return null;
        const case_index = self.taggedUnionCaseIndex(union_decl, tag) orelse return null;
        const case = union_decl.cases[case_index];
        const union_llvm = try self.llvmType(target_ty);
        const ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        try self.emitAlloca(ptr, union_llvm);
        try self.emitZeroObjectBytes(ptr, target_ty);
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, ptr });
        try self.out.print(self.allocator, "  store i32 {d}, ptr {s}{s}\n", .{ case_index, tag_ptr, try self.debugCallSuffix() });
        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload = try self.emitExpr(call.args[0], payload_ty);
            const payload_ptr = try self.taggedUnionPayloadPtr(ptr, target_ty, payload_ty);
            try self.emitPaddingPreservingStore(payload_ptr, payload_ty, payload);
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
    fn emitQualifiedUnionConstructor(self: *LlvmEmitter, call: anytype, union_ty: ast_bridge.TypeExpr) !?[]const u8 {
        const q = syntax_bridge.qualifiedMemberCallee(call.callee.*) orelse return null;
        const union_name = typeName(self.resolveAliasType(union_ty)) orelse return null;
        if (!std.mem.eql(u8, union_name, q.owner)) return error.UnsupportedLlvmEmission;
        const union_decl = self.tagged_unions.get(union_name) orelse return null;
        const case_index = self.taggedUnionCaseIndex(union_decl, q.member.text) orelse return null;
        const case = union_decl.cases[case_index];
        const union_llvm = try self.llvmType(union_ty);
        const ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        try self.emitAlloca(ptr, union_llvm);
        try self.emitZeroObjectBytes(ptr, union_ty);
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, ptr });
        try self.out.print(self.allocator, "  store i32 {d}, ptr {s}{s}\n", .{ case_index, tag_ptr, try self.debugCallSuffix() });
        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload = try self.emitExpr(call.args[0], payload_ty);
            const payload_ptr = try self.taggedUnionPayloadPtr(ptr, union_ty, payload_ty);
            try self.emitPaddingPreservingStore(payload_ptr, payload_ty, payload);
        } else if (call.args.len != 0) {
            return error.UnsupportedLlvmEmission;
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, union_llvm, ptr, try self.debugCallSuffix() });
        return result;
    }

    fn taggedUnionPayloadPtr(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast_bridge.TypeExpr, payload_ty: ast_bridge.TypeExpr) ![]const u8 {
        const union_decl = self.taggedUnionForType(union_ty) orelse return error.UnsupportedLlvmEmission;
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const union_llvm = try self.llvmType(union_ty);
        const payload_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ payload_ptr, union_llvm, union_ptr, layout.payload_field_index });
        _ = try self.llvmType(payload_ty);
        return payload_ptr;
    }

    fn taggedUnionLoadPayload(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast_bridge.TypeExpr, payload_ty: ast_bridge.TypeExpr) ![]const u8 {
        const payload_ptr = try self.taggedUnionPayloadPtr(union_ptr, union_ty, payload_ty);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ payload, try self.llvmType(payload_ty), payload_ptr });
        return payload;
    }

    fn emitResultPayloadExpr(self: *LlvmEmitter, expr: ast_bridge.Expr, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.emitExpr(expr, ty);
    }

    fn resultPayloadZero(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.zeroInitializer(ty);
    }

    fn resultType(self: *LlvmEmitter, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr, span: ast_bridge.Span) !ast_bridge.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast_bridge.TypeExpr, 2);
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
            const max = try self.emitExpr(call.args[2], info.interval_ty orelse return error.UnsupportedLlvmEmission);
            const in_range = try self.nextTemp();
            const selected_delta = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp ule {s} {s}, {s}\n", .{ in_range, llvm_ty, diff, max });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} 0\n", .{ selected_delta, in_range, llvm_ty, diff, llvm_ty });
            return try self.emitResultValue(info.return_ty, in_range, selected_delta, "0");
        }
        return diff;
    }

    fn emitReduceCall(self: *LlvmEmitter, call: anytype, info: ReduceCallInfo) ![]const u8 {
        if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const slice = switch (self.resolveAliasType(info.source_ty).kind) {
            .slice => |node| node,
            else => return error.UnsupportedLlvmEmission,
        };
        if (!std.mem.eql(u8, try self.llvmType(slice.child.*), try self.llvmType(info.element_ty))) return error.UnsupportedLlvmEmission;

        if (std.mem.eql(u8, info.op, "sum_checked")) return try self.emitReduceSumChecked(call.args[0], info.source_ty, info.element_ty, info.return_ty);
        if (std.mem.eql(u8, info.op, "sum_left")) return try self.emitReduceFloat(call.args[0], info.source_ty, info.element_ty, false);
        if (std.mem.eql(u8, info.op, "sum_fast")) return try self.emitReduceFloat(call.args[0], info.source_ty, info.element_ty, true);
        return error.UnsupportedLlvmEmission;
    }

    fn emitReduceSumChecked(self: *LlvmEmitter, arg: ast_bridge.Expr, slice_ty: ast_bridge.TypeExpr, element_ty: ast_bridge.TypeExpr, return_ty: ast_bridge.TypeExpr) ![]const u8 {
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

    fn emitReduceFloat(self: *LlvmEmitter, arg: ast_bridge.Expr, slice_ty: ast_bridge.TypeExpr, element_ty: ast_bridge.TypeExpr, fast: bool) ![]const u8 {
        if (!lower_llvm_shape.isFloatTypeOf(&self.type_aliases, element_ty)) return error.UnsupportedLlvmEmission;
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

    fn overflowIntrinsic(self: *LlvmEmitter, op: ast_bridge.BinaryOp, signed: bool, bits: u16) ![]const u8 {
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

    fn emitStringLiteral(self: *LlvmEmitter, literal: []const u8, span: ast_bridge.Span) ![]const u8 {
        const fact = self.mirTargetTypeFactAt(.string_literal, span) orelse return error.UnsupportedLlvmEmission;
        const target_ty = fact.target_ty;
        const resolved = self.resolveAliasType(target_ty);
        // A `[]const u8` / `[]u8` slice target: build the fat-pointer slice value
        // `{ ptr = &.str, len = <byte count> }`. The pointer is the static string-literal
        // global (program-lifetime, always valid); the length excludes the trailing NUL that
        // `internStringLiteral` appends.
        if (type_bridge.u8SliceMutability(resolved)) |mutability| {
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
        if (self.linux_kernel and self.target_arch == .x86_64) {
            const ibt_id = self.debug_next_id;
            const rethunk_id = ibt_id + 1;
            self.debug_next_id += 2;
            try self.out.print(self.allocator, "!llvm.module.flags = !{{!2, !3, !{d}, !{d}}}\n", .{ ibt_id, rethunk_id });
            try self.out.print(self.allocator, "!{d} = !{{i32 8, !\"cf-protection-branch\", i32 1}}\n", .{ibt_id});
            try self.out.print(self.allocator, "!{d} = !{{i32 4, !\"function_return_thunk_extern\", i32 1}}\n", .{rethunk_id});
        } else if (self.linux_kernel and self.target_arch == .aarch64) {
            const bti_id = self.debug_next_id;
            self.debug_next_id += 1;
            try self.out.print(self.allocator, "!llvm.module.flags = !{{!2, !3, !{d}}}\n", .{bti_id});
            try self.out.print(self.allocator, "!{d} = !{{i32 8, !\"branch-target-enforcement\", i32 2}}\n", .{bti_id});
        } else {
            try self.out.appendSlice(self.allocator, "!llvm.module.flags = !{!2, !3}\n");
        }
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

    fn debugLocation(self: *LlvmEmitter, span: ast_bridge.Span) !?usize {
        const scope = self.current_debug_scope orelse return null;
        const id = self.debug_next_id;
        self.debug_next_id += 1;
        try self.debug_locations.append(self.allocator, .{
            .id = id,
            .scope = scope,
            .line = debugLine(span.line),
            .column = debugColumn(span.column),
        });
        return id;
    }

    fn debugCallSuffix(self: *LlvmEmitter) ![]const u8 {
        const span = self.current_debug_span orelse return "";
        const location = (try self.debugLocation(span)) orelse return "";
        return try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{location});
    }

    fn emitDebugDeclare(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, ptr: []const u8, span: ast_bridge.Span, arg_index: ?usize) !void {
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

    fn emitDebugValue(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, value: []const u8, span: ast_bridge.Span, arg_index: usize) !void {
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

    fn reserveDebugLocal(self: *LlvmEmitter, name: []const u8, ty: ast_bridge.TypeExpr, span: ast_bridge.Span, kind: DebugLocalKind, arg_index: ?usize) !usize {
        const scope = self.current_debug_scope orelse return error.UnsupportedLlvmEmission;
        const id = self.debug_next_id;
        self.debug_next_id += 1;
        try self.debug_locals.append(self.allocator, .{
            .id = id,
            .name = name,
            .scope = scope,
            .line = debugLine(span.line),
            .ty = ty,
            .kind = kind,
            .arg_index = arg_index,
        });
        return id;
    }

    fn debugBasicType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?DebugBasicType {
        const resolved = self.resolveAliasType(ty);
        if (typeNameEql(resolved, "bool")) return .{ .name = "bool", .size_bits = 1, .encoding = "DW_ATE_boolean" };
        if (typeNameEql(resolved, "f32")) return .{ .name = "f32", .size_bits = 32, .encoding = "DW_ATE_float" };
        if (typeNameEql(resolved, "f64")) return .{ .name = "f64", .size_bits = 64, .encoding = "DW_ATE_float" };
        const bits = self.integerBitsOf(resolved) orelse return null;
        return switch (resolved.kind) {
            .name => |name| .{
                .name = name.text,
                .size_bits = bits,
                .encoding = if (isSignedInteger(resolved)) "DW_ATE_signed" else "DW_ATE_unsigned",
            },
            else => null,
        };
    }

    fn llvmType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
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

    fn resultLlvmType(self: *LlvmEmitter, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s}, {s} }}", .{ try self.resultPayloadLlvmType(ok_ty), try self.resultPayloadLlvmType(err_ty) });
    }

    fn resultPayloadLlvmType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "i8";
        return try self.llvmType(ty);
    }

    fn nextTemp(self: *LlvmEmitter) ![]const u8 {
        while (true) {
            const index = self.temp_index;
            self.temp_index += 1;
            const bare = try std.fmt.allocPrint(self.scratch.allocator(), "t{d}", .{index});
            if (self.currentSourceParamUsesLlvmName(bare)) continue;
            return std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{bare});
        }
    }

    fn nextBindingPtr(self: *LlvmEmitter, name: []const u8) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr.{d}", .{ name, index });
    }

    fn nextLabel(self: *LlvmEmitter, prefix: []const u8) ![]const u8 {
        while (true) {
            const index = self.trap_index;
            self.trap_index += 1;
            const label = try std.fmt.allocPrint(self.scratch.allocator(), "bb_{s}{d}", .{ prefix, index });
            if (self.currentSourceParamUsesLlvmName(label)) continue;
            return label;
        }
    }

    fn currentSourceParamUsesLlvmName(self: *LlvmEmitter, name: []const u8) bool {
        const params = self.current_params orelse return false;
        for (params) |param| if (std.mem.eql(u8, param.name.text, name)) return true;
        return false;
    }

    fn functionEntryLabel(self: *LlvmEmitter) ![]const u8 {
        if (!self.currentSourceParamUsesLlvmName("bb_entry")) return "bb_entry";
        var index: usize = 0;
        while (true) : (index += 1) {
            const label = try std.fmt.allocPrint(self.scratch.allocator(), "bb_entry_generated_{d}", .{index});
            if (!self.currentSourceParamUsesLlvmName(label)) return label;
        }
    }

    fn exprType(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.identifierExpressionType(expr, ident.text),
            .bool_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                simpleType(expr.span, "bool"),
            .void_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                simpleType(expr.span, "void"),
            // Source unary expressions have their own MIR-owned result type.
            // Generated zero-span nodes retain the operand-derived fallback.
            .unary => |node| if (!isSourceSpan(expr.span))
                self.requireExpressionResultType(expr, if (node.op == .logical_not) simpleType(expr.span, "bool") else self.exprType(node.expr.*))
            else if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact|
                fact.target_ty
            else
                null,
            .int_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .char_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.char_literal, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .string_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.string_literal, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .enum_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.enum_literal, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .null_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .float_literal => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.float_literal, expr.span)) |fact| fact.target_ty else null
            else
                null,
            .array_literal => if (self.mirTargetTypeFactAt(.array_literal, expr.span)) |fact| fact.target_ty else null,
            .struct_literal => if (self.mirTargetTypeFactAt(.struct_literal, expr.span)) |fact| fact.target_ty else null,
            .block => if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null,
            // Source groupings have their own MIR-owned result type. The
            // inner query is a stale-fact check only; generated zero-span
            // groupings retain the construction-derived fallback.
            .grouped => |inner| if (!isSourceSpan(expr.span))
                self.exprType(inner.*)
            else
                self.requireExpressionResultType(expr, self.exprType(inner.*)),
            .call => |call| self.callExpressionType(expr, call),
            .cast => self.castResultType(expr),
            // Source addresses have exact MIR expression-result facts. Only
            // compiler-generated zero-span nodes retain the declaration-based
            // fallback because they cannot be keyed to a source fact.
            .address_of => |inner| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else if (self.exprType(inner.*)) |ty|
                (if (self.resolveAliasType(ty).kind == .fn_pointer) ty else self.pointerTypeFor(ty) catch null)
            else
                null,
            // Real source dereferences have an exact MIR result type. Only
            // generated zero-span nodes need the legacy operand-derived
            // fallback because no source-keyed fact can identify them.
            .deref => |inner| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.requireExpressionResultType(expr, self.derefPointeeType(inner.*)),
            // Real source indexes have an exact MIR result type. The fallback
            // remains only for generated zero-span nodes; index-address
            // emission still derives storage mechanics from the base.
            .index => |node| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.requireExpressionResultType(expr, self.indexElementType(node.base.*)),
            // Real source slices have an exact MIR result type. Slice
            // emission still derives base storage mechanics separately.
            .slice => |node| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.requireExpressionResultType(expr, if (self.exprType(node.base.*)) |base_ty| self.sliceTypeForBase(base_ty, node.base.*.span) else null),
            .member => |node| if (self.mirTargetTypeFactAt(.enum_variant_path_result, expr.span)) |fact| fact.target_ty else if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.requireExpressionResultType(expr, if (self.exprType(node.base.*)) |base_ty| blk: {
                    const resolved_base_ty = self.resolveAliasType(base_ty);
                    if (resolved_base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) break :blk simpleType(expr.span, "usize");
                    if (self.packedBitsInfoForType(base_ty)) |info| {
                        if (self.packedBitsFieldIndex(info, node.name.text) != null) break :blk simpleType(expr.span, "bool");
                    }
                    if (self.overlayField(node.base.*, node.name.text)) |field| break :blk self.requireExpressionResultType(expr, field.ty);
                    if (self.memberField(node.base.*, node.name.text)) |field| break :blk field.ty;
                    break :blk null;
                } else null),
            // Source binary expressions have their own MIR-owned result type.
            // Keep operand-derived inference only for generated zero-span nodes
            // that cannot be keyed to a source expression-result fact.
            .binary => |node| if (!isSourceSpan(expr.span))
                self.requireExpressionResultType(expr, if (binaryIsComparison(node.op) or node.op == .logical_and or node.op == .logical_or) simpleType(expr.span, "bool") else self.exprType(node.left.*))
            else if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact|
                fact.target_ty
            else
                null,
            .try_expr => |node| self.tryExpressionResultType(expr, node.operand.*),
            else => null,
        };
    }

    fn exprStatementTypeForEmission(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.exprType(expr);
        const fact = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        const known = self.exprType(expr) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact), self.resolveAliasType(known))) return null;
        return fact;
    }

    fn identifierExpressionType(self: *LlvmEmitter, expr: ast_bridge.Expr, name: []const u8) ?ast_bridge.TypeExpr {
        const inferred = self.local_types.get(name) orelse self.global_types.get(name) orelse self.fnPointerTypeForName(name) orelse return null;
        if (!isSourceSpan(expr.span)) return inferred;
        return self.expressionResultTypeAt(expr.span, inferred);
    }

    fn requireExpressionResultType(self: *LlvmEmitter, expr: ast_bridge.Expr, inferred: ?ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const expected = inferred orelse if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| return fact.target_ty else return null;
        return self.expressionResultTypeAt(expr.span, expected);
    }

    fn castResultType(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const target_ty = (self.mirTargetTypeFactAt(.explicit_cast_target, expr.span) orelse return null).target_ty;
        return self.expressionResultTypeAt(expr.span, target_ty);
    }

    fn callExpressionType(self: *LlvmEmitter, expr: ast_bridge.Expr, call: anytype) ?ast_bridge.TypeExpr {
        // Source call expressions have complete MIR result facts. The
        // call-specific fact identifies the callee/ABI or builtin path; the
        // expression_result row authorizes the value type at this source span.
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        const inferred = if (self.mirTargetTypeFactAt(.qualified_union_result, expr.span)) |fact|
            fact.target_ty
        else if (call_kind == .assume_noalias)
            if (self.assumeNoaliasTypesForQuery(call)) |types| types.result_ty else return null
        else if (call_kind == .declassify)
            if (self.declassifyTypesForQuery(call)) |types| types.result_ty else return null
        else
            self.callResultTypeForEmission(call) orelse return null;
        return self.expressionResultTypeAt(expr.span, inferred);
    }

    fn expressionResultTypeAt(self: *LlvmEmitter, span: ast_bridge.Span, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        // Async lowering creates zero-span expressions whose construction site
        // already determines their type. Multiple generated nodes share that
        // sentinel span, so a span-keyed MIR lookup cannot identify one fact.
        if (!isSourceSpan(span)) return inferred;
        const fact = self.mirTargetTypeFactAt(.expression_result, span) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) return null;
        return fact.target_ty;
    }

    fn emitCharLiteralWithTarget(self: *LlvmEmitter, literal: []const u8, span: ast_bridge.Span, expected_ty: ast_bridge.TypeExpr) ![]const u8 {
        const fact = self.mirTargetTypeFactAt(.char_literal, span) orelse return error.UnsupportedLlvmEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(expected_ty))) return error.UnsupportedLlvmEmission;
        return charLiteralValue(self.scratch.allocator(), literal);
    }

    fn derefPointeeType(self: *LlvmEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        return switch (ty.kind) {
            .pointer => |node| node.child.*,
            .raw_many_pointer => |node| node.child.*,
            else => null,
        };
    }

    fn tryExpressionResultType(self: *LlvmEmitter, expr: ast_bridge.Expr, operand: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const result_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        const operand_ty = self.mirTryOperandTypeForQuery(operand) orelse return null;
        const expected_ty = if (lower_llvm_shape.resultInfo(&self.type_aliases, operand_ty)) |info|
            info.ok_ty
        else
            lower_llvm_shape.nullableInnerType(&self.type_aliases, operand_ty) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result_ty), self.resolveAliasType(expected_ty))) return null;
        return result_ty;
    }

    fn pointerTypeFor(self: *LlvmEmitter, child: ast_bridge.TypeExpr) !ast_bridge.TypeExpr {
        const child_ptr = try self.scratch.allocator().create(ast_bridge.TypeExpr);
        child_ptr.* = child;
        return .{
            .span = child.span,
            .kind = .{ .pointer = .{ .mutability = .mut, .child = child_ptr } },
        };
    }

    fn mmioAccessInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?MmioAccessInfo {
        if (call.type_args.len != 0) return null;
        const member = memberCallee(call) orelse return null;
        const op: []const u8 = switch (kind) {
            .mmio_read => blk: {
                if (!std.mem.eql(u8, member.name.text, "read") or call.args.len != 1) return null;
                break :blk "read";
            },
            .mmio_write => blk: {
                if (!std.mem.eql(u8, member.name.text, "write") or call.args.len != 2) return null;
                break :blk "write";
            },
            else => return null,
        };
        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const struct_ty = (self.mirTargetTypeFactAt(.mmio_struct, call.callee.*.span) orelse return null).target_ty;
        const storage_ty = (self.mirTargetTypeFactAt(.mmio_storage, call.callee.*.span) orelse return null).target_ty;
        const value_ty = (self.mirTargetTypeFactAt(.mmio_value, call.callee.*.span) orelse return null).target_ty;
        const result_ty = (self.mirTargetTypeFactAt(.mmio_result, call.callee.*.span) orelse return null).target_ty;
        const struct_decl = self.structDeclForType(struct_ty) orelse return null;
        if (!isMmioStructAbi(struct_decl)) return null;
        _ = self.mmioStructField(struct_decl, reg_member.name.text) orelse return null;
        const offset = self.mmioFieldOffset(struct_decl, reg_member.name.text) orelse return null;
        return .{
            .op = op,
            .base = reg_member.base.*,
            .struct_ty = struct_ty,
            .storage_ty = storage_ty,
            .value_ty = value_ty,
            .result_ty = result_ty,
            .offset = offset,
        };
    }

    fn mmioMapCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?MmioMapInfo {
        if (kind != .mmio_map) return null;
        if (call.type_args.len != 1 or call.args.len != 1) return null;
        return .{
            .source_ty = (self.mirTargetTypeFactAt(.mmio_map_source, call.callee.*.span) orelse return null).target_ty,
            .payload_ty = (self.mirTargetTypeFactAt(.mmio_map_payload, call.callee.*.span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.mmio_map_result, call.callee.*.span) orelse return null).target_ty,
        };
    }

    fn rawCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?RawCallInfo {
        const valid_shape = switch (kind) {
            .raw_load => syntax_bridge.isRawLoadCall(call.callee.*) and call.type_args.len == 1 and call.args.len == 1,
            .raw_ptr => syntax_bridge.isRawPtrCall(call.callee.*) and call.type_args.len == 1 and call.args.len == 1,
            .raw_store => syntax_bridge.isRawStoreCall(call.callee.*) and call.type_args.len == 1 and call.args.len == 2,
            else => false,
        };
        if (!valid_shape) return null;
        const types = self.rawAddressTypesForEmission(call) orelse return null;
        return .{
            .kind = kind,
            .address_ty = types.address_ty,
            .payload_ty = types.payload_ty,
            .result_ty = types.result_ty,
        };
    }

    fn rawAddressTypesForEmission(self: *LlvmEmitter, call: anytype) ?struct {
        address_ty: ast_bridge.TypeExpr,
        payload_ty: ast_bridge.TypeExpr,
        result_ty: ast_bridge.TypeExpr,
    } {
        const span = call.callee.*.span;
        return .{
            .address_ty = (self.mirTargetTypeFactAt(.raw_address, span) orelse return null).target_ty,
            .payload_ty = (self.mirTargetTypeFactAt(.raw_payload, span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.raw_result, span) orelse return null).target_ty,
        };
    }

    fn byteViewCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ByteViewCallInfo {
        const expected_args: usize = switch (kind) {
            .byte_view_as_bytes => 1,
            .byte_view_equal => 2,
            else => return null,
        };
        if (call.type_args.len != 0 or call.args.len != expected_args) return null;
        return .{
            .kind = kind,
            .source_ty = (self.mirTargetTypeFactAt(.byte_view_source, call.callee.*.span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.byte_view_result, call.callee.*.span) orelse return null).target_ty,
        };
    }

    fn reflectionCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ReflectionCallInfo {
        const expected_args: usize = switch (kind) {
            .reflection_size, .reflection_alignment, .reflection_repr => 0,
            .reflection_field_offset, .reflection_bit_offset => 1,
            else => return null,
        };
        if (call.type_args.len != 1 or call.args.len != expected_args) return null;
        return .{
            .kind = kind,
            .target_ty = (self.mirTargetTypeFactAt(.reflection_target, call.callee.*.span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.reflection_result, call.callee.*.span) orelse return null).target_ty,
        };
    }

    fn vaCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?VaCallInfo {
        const valid_shape = switch (kind) {
            .va_start => call.type_args.len == 0 and call.args.len == 0,
            .va_arg => call.type_args.len == 1 and call.args.len == 1,
            .va_end => call.type_args.len == 0 and call.args.len == 1,
            else => false,
        };
        if (!valid_shape) return null;
        const types = self.vaCallTypesForEmission(call, kind) orelse return null;
        return .{
            .kind = kind,
            .cursor_ty = types.cursor_ty,
            .payload_ty = types.payload_ty,
            .result_ty = types.result_ty,
        };
    }

    fn vaCallTypesForEmission(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?struct {
        cursor_ty: ?ast_bridge.TypeExpr,
        payload_ty: ?ast_bridge.TypeExpr,
        result_ty: ast_bridge.TypeExpr,
    } {
        const span = call.callee.*.span;
        return .{
            .cursor_ty = if (kind == .va_start) null else (self.mirTargetTypeFactAt(.va_cursor, span) orelse return null).target_ty,
            .payload_ty = if (kind == .va_arg) (self.mirTargetTypeFactAt(.va_payload, span) orelse return null).target_ty else null,
            .result_ty = (self.mirTargetTypeFactAt(.va_result, span) orelse return null).target_ty,
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

    fn mmioPointerType(self: *LlvmEmitter, child_ty: ast_bridge.TypeExpr, span: ast_bridge.Span) !ast_bridge.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast_bridge.TypeExpr, 1);
        args[0] = child_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "MmioPtr", .span = span }, .args = args } } };
    }

    fn atomicStorageLlvmType(self: *LlvmEmitter, payload_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(payload_ty), "bool")) return "i8";
        return self.llvmType(payload_ty);
    }

    fn emitAtomicValueForStorage(self: *LlvmEmitter, expr: ast_bridge.Expr, payload_ty: ast_bridge.TypeExpr) ![]const u8 {
        const value = try self.emitExpr(expr, payload_ty);
        if (!typeNameEql(self.resolveAliasType(payload_ty), "bool")) return value;
        if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "1")) return value;
        const widened = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ widened, value });
        return widened;
    }

    fn indexElementType(self: *LlvmEmitter, base: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(base) orelse return null);
        return switch (ty.kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn sliceTypeForBase(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, span: ast_bridge.Span) ?ast_bridge.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .slice => ty,
            .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
            else => null,
        };
    }

    fn sliceTypeFor(self: *LlvmEmitter, child_ty: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability, span: ast_bridge.Span) !ast_bridge.TypeExpr {
        const child = try self.scratch.allocator().create(ast_bridge.TypeExpr);
        child.* = child_ty;
        return .{ .span = span, .kind = .{ .slice = .{ .mutability = mutability, .child = child } } };
    }

    fn structDeclForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.StructDecl {
        return lower_llvm_lookup.structDeclForType(&self.type_aliases, &self.struct_types, ty);
    }

    fn packedBitsInfoForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?PackedBitsInfo {
        return lower_llvm_lookup.packedBitsInfoForType(&self.type_aliases, &self.packed_bits, ty);
    }

    fn overlayInfoForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?OverlayUnionInfo {
        return lower_llvm_lookup.overlayInfoForType(&self.type_aliases, &self.overlay_unions, ty);
    }

    fn taggedUnionForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.UnionDecl {
        return lower_llvm_lookup.taggedUnionForType(&self.type_aliases, &self.tagged_unions, ty);
    }

    fn taggedUnionCaseIndex(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl, case_name: []const u8) ?usize {
        _ = self;
        return lower_llvm_lookup.taggedUnionCaseIndex(union_decl, case_name);
    }

    fn taggedUnionLlvmType(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl) ![]const u8 {
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const storage_ty = try self.taggedUnionPayloadStorageType(layout);
        if (layout.padding_size == 0) {
            return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, {s} }}", .{storage_ty});
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, [{d} x i8], {s} }}", .{ layout.padding_size, storage_ty });
    }

    fn taggedUnionLayout(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl, depth: usize) ?TaggedUnionLayout {
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

    fn packedBitsBaseAddress(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
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

    fn enumDeclForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.EnumDecl {
        return lower_llvm_lookup.enumDeclForType(&self.type_aliases, &self.enum_types, ty);
    }

    fn memberBaseIsValue(self: *LlvmEmitter, node: anytype) bool {
        const base_ident = switch (node.base.*.kind) {
            .ident => |id| id,
            else => return false,
        };
        return self.local_types.contains(base_ident.text) or self.global_types.contains(base_ident.text);
    }

    fn memberBaseStructType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return lower_llvm_lookup.memberBaseStructType(&self.type_aliases, ty);
    }

    fn memberBaseStructDecl(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.StructDecl {
        return lower_llvm_lookup.memberBaseStructDecl(&self.type_aliases, &self.struct_types, ty);
    }

    fn enumReprType(enum_decl: ast_bridge.EnumDecl) ast_bridge.TypeExpr {
        return enum_decl.repr orelse simpleType(enum_decl.name.span, "isize");
    }

    fn enumCaseValueByName(self: *LlvmEmitter, enum_decl: ast_bridge.EnumDecl, case_name: []const u8) ![]const u8 {
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, case_name)) return try self.enumCaseValue(enum_decl, case);
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumCaseValue(self: *LlvmEmitter, enum_decl: ast_bridge.EnumDecl, case: ast_bridge.EnumCase) ![]const u8 {
        if (case.value) |value| return try self.enumLiteralValue(value);
        for (enum_decl.cases, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.name.text, case.name.text)) {
                return try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{i});
            }
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumLiteralValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
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

    fn packedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast_bridge.StructLiteralField) ![]const u8 {
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

    fn emitPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast_bridge.StructLiteralField) ![]const u8 {
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

    fn staticPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast_bridge.StructLiteralField) ?[]const u8 {
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

    fn resolveAliasType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ast_bridge.TypeExpr {
        return type_bridge.resolveAliasType(&self.type_aliases, ty);
    }

    fn structLlvmType(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl) anyerror![]const u8 {
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
    fn cUnionLlvmType(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl) ![]const u8 {
        const layout = self.cUnionStorageLayout(struct_decl) orelse return error.UnsupportedLlvmEmission;
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i{d}]", .{ layout.count, layout.alignment * 8 });
    }

    const CUnionStorageLayout = struct { count: usize, alignment: usize };

    fn cUnionStorageLayout(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl) ?CUnionStorageLayout {
        var max_size: i128 = 0;
        var max_align: i128 = 1;
        for (struct_decl.fields) |field| {
            const size = self.comptimeSizeOf(field.ty, 0) orelse return null;
            const alignment = self.comptimeAlignOf(field.ty, 0) orelse return null;
            if (alignment <= 0) return null;
            if (size > max_size) max_size = size;
            if (alignment > max_align) max_align = alignment;
        }
        if (max_align != 1 and max_align != 2 and max_align != 4 and max_align != 8 and max_align != 16) return null;
        const aligned_size = alignForward(max_size, max_align) orelse return null;
        const count = @max(@as(i128, 1), @divExact(aligned_size, max_align));
        return .{
            .count = std.math.cast(usize, count) orelse return null,
            .alignment = std.math.cast(usize, max_align) orelse return null,
        };
    }

    fn overlayField(self: *LlvmEmitter, base: ast_bridge.Expr, field_name: []const u8) ?ast_bridge.Field {
        const base_ty = self.exprType(base) orelse return null;
        const info = self.overlayInfoForType(base_ty) orelse return null;
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn emitOverlayFieldAddress(self: *LlvmEmitter, base: ast_bridge.Expr, field: ast_bridge.Field) ![]const u8 {
        _ = field;
        return try self.aggregateBasePointer(base);
    }

    fn memberField(self: *LlvmEmitter, base: ast_bridge.Expr, field_name: []const u8) ?ast_bridge.Field {
        const base_ty = self.exprType(base) orelse return null;
        const struct_decl = self.memberBaseStructDecl(base_ty) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioStructField(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl, field_name: []const u8) ?ast_bridge.Field {
        _ = self;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioFieldInfo(self: *LlvmEmitter, field: ast_bridge.Field) ?MmioFieldInfo {
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

    fn mmioFieldOffset(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl, field_name: []const u8) ?u64 {
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

    fn overlayFieldLayout(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, depth: usize) ?OverlayLayout {
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

    fn directCallName(self: *LlvmEmitter, callee: ast_bridge.Expr) ?[]const u8 {
        const name = calleeIdentName(callee) orelse return null;
        return if (self.fn_sigs.contains(name)) name else null;
    }

    fn fnPointerCalleeType(self: *LlvmEmitter, callee: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const ty = (self.mirTargetTypeFactAt(.indirect_call_callee, callee.span) orelse return null).target_ty;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .fn_pointer => resolved_ty,
            else => null,
        };
    }

    fn closureCalleeType(self: *LlvmEmitter, callee: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const ty = (self.mirTargetTypeFactAt(.indirect_call_callee, callee.span) orelse return null).target_ty;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .closure_type => resolved_ty,
            else => null,
        };
    }

    fn fnPointerTypeForName(self: *LlvmEmitter, name: []const u8) ?ast_bridge.TypeExpr {
        const sig = self.fn_sigs.get(name) orelse return null;
        const params = self.scratch.allocator().alloc(ast_bridge.TypeExpr, sig.params.len) catch return null;
        for (sig.params, 0..) |param, i| params[i] = param.ty;
        const ret = self.scratch.allocator().create(ast_bridge.TypeExpr) catch return null;
        ret.* = sig.ret;
        return .{
            .span = sig.ret.span,
            .kind = .{ .fn_pointer = .{ .params = params, .ret = ret } },
        };
    }

    fn isFnPointerType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.resolveAliasType(ty).kind == .fn_pointer;
    }

    fn callResultTypeForEmission(self: *LlvmEmitter, call: anytype) ?ast_bridge.TypeExpr {
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind) |kind| {
            if (self.reflectionCallInfo(call, kind)) |info| return info.result_ty;
        }
        // Tier 2 dynamic dispatch `d.method(args)` through a `*dyn Trait`: the return type is the
        // trait method's declared return type. Without this, exprType() is null for a dispatch call,
        // so a dispatch used directly as a switch/if subject (`if self.inner.poll() { ... }`) fell
        // through to the unsupported path — the C backend handled it, the LLVM backend did not.
        if (self.dynDispatchTrait(call.callee.*)) |trait| {
            const member = memberCallee(call) orelse return null;
            const slot = traitMethodIndex(trait, member.name.text) orelse return null;
            const declared_ty = trait.facts.methods[slot].return_type orelse return simpleType(call.callee.*.span, "void");
            const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, call.callee.*.span, trait.facts.name.text, slot) orelse return null).target_ty;
            if (!std.meta.eql(fact_ty, declared_ty)) return null;
            return fact_ty;
        }
        if (call_kind == .const_get) return if (self.constGetCallInfo(call, .const_get)) |info| info.element_ty else null;
        if (call_kind == .bitcast) return if (self.bitcastTypesForQuery(call, .bitcast)) |types| types.target_ty else null;
        if (call_kind == .phys) return self.physResultTypeForQuery(call, .phys);
        if (call_kind == .raw_load) return if (self.rawCallInfo(call, .raw_load)) |info| info.result_ty else null;
        if (call_kind == .raw_ptr) return if (self.rawCallInfo(call, .raw_ptr)) |info| info.result_ty else null;
        if (call_kind) |kind| {
            if (self.vaCallInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind == .enum_raw) return if (self.enumRawCallInfo(call, .enum_raw)) |info| info.repr_ty else null;
        if (call_kind == .wrap_residue) return if (self.domainResidueCallInfo(call, .wrap_residue)) |info| info.payload_ty else null;
        if (call_kind) |kind| {
            if (self.domainOpCallInfo(call, kind)) |info| return info.return_ty;
        }
        if (call_kind) |kind| {
            if (self.reduceCallInfo(call, kind)) |info| return info.return_ty;
        }
        if (call_kind) |kind| {
            if (self.byteViewCallInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind == .mmio_map) return if (self.mmioMapCallInfo(call, .mmio_map)) |info| info.result_ty else null;
        if (call_kind) |kind| {
            if (self.conversionCallInfo(call, kind)) |info| {
                if (std.mem.eql(u8, info.op, "try_from")) {
                    return self.resultType(info.target_ty, simpleType(call.callee.*.span, "ConversionError"), call.callee.*.span) catch null;
                }
                return info.target_ty;
            }
        }
        if (call_kind) |kind| {
            if (self.wrappingCallInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind) |kind| {
            if (self.uncheckedCallInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind) |kind| {
            if (self.atomicCallInfo(call, kind)) |info| {
                if (std.mem.eql(u8, info.op, "load") or std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) return info.payload_ty;
                if (std.mem.eql(u8, info.op, "store")) return simpleType(call.callee.*.span, "void");
            }
        }
        if (call_kind) |kind| {
            if (self.mmioAccessInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind) |kind| {
            if (self.maybeUninitCallInfo(call, kind)) |info| {
                if (std.mem.eql(u8, info.op, "assume_init")) return info.payload_ty;
                if (std.mem.eql(u8, info.op, "write")) return simpleType(call.callee.*.span, "void");
            }
        }
        if (call_kind) |kind| {
            if (self.dmaCacheCallInfo(call, kind)) |info| return info.result_ty;
            if (self.dmaBufCallInfo(call, kind)) |info| return info.result_ty;
        }
        if (call_kind == .raw_many_offset) return if (self.rawManyOffsetCallInfo(call, .raw_many_offset)) |info| info.result_ty else null;
        if (call_kind == .bind) return if (self.mirTargetTypeFactAt(.bind, call_span)) |fact| fact.target_ty else null;
        if (self.closureCalleeType(call.callee.*)) |closure_ty| return closure_ty.kind.closure_type.ret.*;
        if (self.fnPointerCalleeType(call.callee.*)) |fn_ty| return fn_ty.kind.fn_pointer.ret.*;
        const callee = self.directCallName(call.callee.*) orelse return null;
        const sig = self.fn_sigs.get(callee) orelse return null;
        const fact_ty = if (self.mirTargetTypeFactAtOwned(.direct_call_result, call.callee.*.span, callee, null)) |fact| fact.target_ty else return null;
        if (!directCallFactMatchesDeclared(fact_ty, sig.ret)) return null;
        return fact_ty;
    }

    fn enumRawCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?EnumRawCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        if (kind != .enum_raw) return null;
        const types = self.enumRawTypesForEmission(call) orelse return null;
        return .{ .base = member.base.*, .enum_ty = types.enum_ty, .repr_ty = types.repr_ty };
    }

    fn enumRawTypesForEmission(self: *LlvmEmitter, call: anytype) ?EnumRawTypes {
        const span = call.callee.*.span;
        return .{
            .enum_ty = (self.mirTargetTypeFactAt(.enum_raw_source, span) orelse return null).target_ty,
            .repr_ty = (self.mirTargetTypeFactAt(.enum_raw_result, span) orelse return null).target_ty,
        };
    }

    fn domainResidueCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?DomainResidueCallInfo {
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "residue")) return null;
        if (kind != .wrap_residue) return null;
        const types = self.domainTypesForEmission(call, false) orelse return null;
        return .{ .base = member.base.*, .domain_ty = types.domain_ty, .payload_ty = types.result_ty };
    }

    fn conversionCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ConversionCallInfo {
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
        if (kind != expected_kind) return null;
        return .{ .source_ty = source_fact.target_ty, .target_ty = target_ty, .op = member.name.text };
    }

    fn uncheckedCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?UncheckedCallInfo {
        if (call.type_args.len != 0 or call.args.len != 2) return null;
        const op = mir.uncheckedCallFactInfo(kind) orelse return null;
        const types = self.uncheckedTypesForEmission(call) orelse return null;
        return .{ .op = op, .left_ty = types.left_ty, .right_ty = types.right_ty, .result_ty = types.result_ty };
    }

    fn wrappingCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?WrappingCallInfo {
        if (call.type_args.len != 0 or call.args.len != 2) return null;
        const op = mir.wrappingCallFactInfo(kind) orelse return null;
        const types = self.wrappingTypesForEmission(call) orelse return null;
        return .{ .op = op, .left_ty = types.left_ty, .right_ty = types.right_ty, .result_ty = types.result_ty };
    }

    fn uncheckedTypesForEmission(self: *LlvmEmitter, call: anytype) ?ArithmeticCallTypes {
        return self.arithmeticCallTypesForEmission(call, .unchecked_left, .unchecked_right, .unchecked_result);
    }

    fn wrappingTypesForEmission(self: *LlvmEmitter, call: anytype) ?ArithmeticCallTypes {
        return self.arithmeticCallTypesForEmission(call, .wrapping_left, .wrapping_right, .wrapping_result);
    }

    fn arithmeticCallTypesForEmission(self: *LlvmEmitter, call: anytype, left_kind: mir.TargetTypeKind, right_kind: mir.TargetTypeKind, result_kind: mir.TargetTypeKind) ?ArithmeticCallTypes {
        return .{
            .left_ty = (self.mirTargetTypeFactAt(left_kind, call.args[0].span) orelse return null).target_ty,
            .right_ty = (self.mirTargetTypeFactAt(right_kind, call.args[1].span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(result_kind, call.callee.*.span) orelse return null).target_ty,
        };
    }

    fn domainOpCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?DomainOpCallInfo {
        if (call.type_args.len != 0) return null;
        const member = memberCallee(call) orelse return null;
        const fact_info = mir.domainCallFactInfo(kind) orelse return null;
        if (kind == .wrap_residue or !std.mem.eql(u8, member.name.text, fact_info.op)) return null;
        const types = self.domainTypesForEmission(call, fact_info.has_interval) orelse return null;
        return .{ .domain_ty = types.domain_ty, .payload_ty = types.payload_ty, .return_ty = types.result_ty, .interval_ty = types.interval_ty, .op = fact_info.op };
    }

    fn domainTypesForEmission(self: *LlvmEmitter, call: anytype, needs_interval: bool) ?DomainTypes {
        const span = call.callee.*.span;
        return .{
            .domain_ty = (self.mirTargetTypeFactAt(.domain_type, span) orelse return null).target_ty,
            .payload_ty = (self.mirTargetTypeFactAt(.domain_payload, span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(.domain_result, span) orelse return null).target_ty,
            .interval_ty = if (needs_interval)
                (self.mirTargetTypeFactAt(.domain_interval, span) orelse return null).target_ty
            else
                null,
        };
    }

    fn reduceCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ReduceCallInfo {
        if (kind != .reduce_sum_checked and kind != .reduce_sum_left and kind != .reduce_sum_fast) return null;
        if (call.type_args.len != 1) return null;
        const types = self.reduceTypesForEmission(call) orelse return null;
        const return_ty = if (kind == .reduce_sum_checked)
            self.resultType(types.element_ty, simpleType(call.callee.*.span, "Overflow"), call.callee.*.span) catch return null
        else
            types.element_ty;
        const op = switch (kind) {
            .reduce_sum_checked => "sum_checked",
            .reduce_sum_left => "sum_left",
            .reduce_sum_fast => "sum_fast",
            else => return null,
        };
        return .{ .source_ty = types.source_ty, .element_ty = types.element_ty, .return_ty = return_ty, .op = op };
    }

    fn reduceTypesForEmission(self: *LlvmEmitter, call: anytype) ?ReduceTypes {
        return .{
            .source_ty = (self.mirTargetTypeFactAt(.reduce_source, call.args[0].span) orelse return null).target_ty,
            .element_ty = (self.mirTargetTypeFactAt(.reduce_element, call.callee.*.span) orelse return null).target_ty,
        };
    }

    fn constGetCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ConstGetCallInfo {
        if (kind != .const_get) return null;
        if (call.args.len != 0 or call.type_args.len != 1) return null;
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
        const array_ty = (self.mirTargetTypeFactAt(.const_get_base, call.callee.*.span) orelse return null).target_ty;
        const element_ty = (self.mirTargetTypeFactAt(.const_get_result, call.callee.*.span) orelse return null).target_ty;
        const index = self.mirConstGetIndexAt(call.callee.*.span) orelse return null;
        return .{
            .base = member.base.*,
            .array_ty = array_ty,
            .element_ty = element_ty,
            .index = index,
        };
    }

    fn atomicCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?AtomicCallInfo {
        const op = switch (kind) {
            .atomic_load => "load",
            .atomic_store => "store",
            .atomic_fetch_add => "fetch_add",
            .atomic_fetch_sub => "fetch_sub",
            else => return null,
        };
        const member = memberCallee(call) orelse return null;
        const payload_ty = (self.mirTargetTypeFactAt(.atomic_payload, call.callee.*.span) orelse return null).target_ty;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const base_is_pointer = if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, base_ty) != null)
            false
        else switch (self.resolveAliasType(base_ty).kind) {
            .pointer => |pointer| if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, pointer.child.*) != null) true else return null,
            else => return null,
        };
        return .{
            .base = member.base.*,
            .op = op,
            .payload_ty = payload_ty,
            .base_is_pointer = base_is_pointer,
        };
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

    fn maybeUninitCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?MaybeUninitCallInfo {
        const op = switch (kind) {
            .maybe_uninit_write => "write",
            .maybe_uninit_assume_init => "assume_init",
            else => return null,
        };
        const member = memberCallee(call) orelse return null;
        const payload_ty = (self.mirTargetTypeFactAt(.maybe_uninit_payload, call.callee.*.span) orelse return null).target_ty;
        return .{ .base = member.base.*, .op = op, .payload_ty = payload_ty };
    }

    fn bitcastTypesForEmission(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) !BitcastTypes {
        return self.bitcastTypesForQuery(call, kind) orelse error.UnsupportedLlvmEmission;
    }

    fn bitcastTypesForQuery(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?BitcastTypes {
        if (kind != .bitcast) return null;
        if (call.type_args.len != 1 or call.args.len != 1) return null;
        const span = call.callee.*.span;
        return .{
            .source_ty = (self.mirTargetTypeFactAt(.bitcast_source, span) orelse return null).target_ty,
            .target_ty = (self.mirTargetTypeFactAt(.bitcast_target, span) orelse return null).target_ty,
        };
    }

    fn physResultTypeForEmission(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) !ast_bridge.TypeExpr {
        return self.physResultTypeForQuery(call, kind) orelse error.UnsupportedLlvmEmission;
    }

    fn physResultTypeForQuery(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .phys) return null;
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        return if (self.mirTargetTypeFactAt(.phys_result, call.callee.*.span)) |fact| fact.target_ty else null;
    }

    fn semanticEscapeTypesForEmission(self: *LlvmEmitter, call: anytype, source_kind: mir.TargetTypeKind, result_kind: mir.TargetTypeKind) !SemanticEscapeTypes {
        return self.semanticEscapeTypesForQuery(call, source_kind, result_kind) orelse error.UnsupportedLlvmEmission;
    }

    fn semanticEscapeTypesForQuery(self: *LlvmEmitter, call: anytype, source_kind: mir.TargetTypeKind, result_kind: mir.TargetTypeKind) ?SemanticEscapeTypes {
        const span = call.callee.*.span;
        return .{
            .source_ty = (self.mirTargetTypeFactAt(source_kind, span) orelse return null).target_ty,
            .result_ty = (self.mirTargetTypeFactAt(result_kind, span) orelse return null).target_ty,
        };
    }

    fn declassifyTypesForEmission(self: *LlvmEmitter, call: anytype) !SemanticEscapeTypes {
        return self.semanticEscapeTypesForEmission(call, .declassify_source, .declassify_result);
    }

    fn declassifyTypesForQuery(self: *LlvmEmitter, call: anytype) ?SemanticEscapeTypes {
        return self.semanticEscapeTypesForQuery(call, .declassify_source, .declassify_result);
    }

    fn assumeNoaliasTypesForEmission(self: *LlvmEmitter, call: anytype) !SemanticEscapeTypes {
        return self.semanticEscapeTypesForEmission(call, .assume_noalias_source, .assume_noalias_result);
    }

    fn assumeNoaliasTypesForQuery(self: *LlvmEmitter, call: anytype) ?SemanticEscapeTypes {
        return self.semanticEscapeTypesForQuery(call, .assume_noalias_source, .assume_noalias_result);
    }

    fn dmaCacheCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?DmaCacheCallInfo {
        const fact_info = mir.dmaCallFactInfo(kind) orelse return null;
        if (!fact_info.cache) return null;
        const member = memberCallee(call) orelse return null;
        if (!isIdentNamed(member.base.*, "cache")) return null;
        if (!std.mem.eql(u8, member.name.text, fact_info.op)) return null;
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        const dma_ty = (self.mirTargetTypeFactAt(.dma_buffer, call.callee.*.span) orelse return null).target_ty;
        _ = self.mirTargetTypeFactAt(.dma_payload, call.callee.*.span) orelse return null;
        const result_ty = (self.mirTargetTypeFactAt(.dma_result, call.callee.*.span) orelse return null).target_ty;
        return .{ .op = fact_info.op, .dma_ty = dma_ty, .result_ty = result_ty };
    }

    fn dmaBufCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?DmaBufCallInfo {
        const fact_info = mir.dmaCallFactInfo(kind) orelse return null;
        if (fact_info.cache) return null;
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, fact_info.op)) return null;
        if (call.type_args.len != 0 or call.args.len != 0) return null;
        const dma_ty = (self.mirTargetTypeFactAt(.dma_buffer, call.callee.*.span) orelse return null).target_ty;
        _ = self.mirTargetTypeFactAt(.dma_payload, call.callee.*.span) orelse return null;
        const result_ty = (self.mirTargetTypeFactAt(.dma_result, call.callee.*.span) orelse return null).target_ty;
        return .{ .base = member.base.*, .op = fact_info.op, .dma_ty = dma_ty, .result_ty = result_ty };
    }

    fn atomicBaseAddress(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
        return self.storageBaseAddress(expr);
    }

    fn storageBaseAddress(self: *LlvmEmitter, expr: ast_bridge.Expr) ![]const u8 {
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

    fn llvmAlignOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.llvmAlignOf(enumReprType(enum_decl));
        const resolved_ty = self.resolveAliasType(ty);
        if (lower_llvm_shape.atomicPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (lower_llvm_shape.maybeUninitPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (lower_llvm_shape.domainPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
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

    fn arrayLenValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ?u64 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.arrayLenValue(&env, expr);
    }

    fn reflectionCallValue(self: *LlvmEmitter, call: anytype, info: ReflectionCallInfo) ?[]const u8 {
        var env = self.reflectEnv();
        const value = switch (info.kind) {
            .reflection_size => lower_llvm_reflect.comptimeSizeOf(&env, info.target_ty, 0),
            .reflection_alignment => lower_llvm_reflect.comptimeAlignOf(&env, info.target_ty, 0),
            .reflection_field_offset => lower_llvm_reflect.comptimeFieldOffset(&env, info.target_ty, syntax_bridge.reflectionFieldName(call.args[0]) orelse return null, 0),
            .reflection_bit_offset => lower_llvm_reflect.comptimeBitOffset(&env, info.target_ty, syntax_bridge.reflectionFieldName(call.args[0]) orelse return null),
            .reflection_repr => lower_llvm_reflect.comptimeReprOf(&env, info.target_ty, 0),
            else => null,
        } orelse return null;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) catch null;
    }

    fn comptimeSizeOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeSizeOf(&env, ty, depth);
    }

    fn comptimeAlignOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeAlignOf(&env, ty, depth);
    }

    fn comptimeFieldOffset(self: *LlvmEmitter, ty: ast_bridge.TypeExpr, field: []const u8, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.comptimeFieldOffset(&env, ty, field, depth);
    }

    fn integerBitsOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?u16 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.integerBitsOf(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.integerBitsOf(info.repr);
        if (self.structDeclForType(ty) != null or self.taggedUnionForType(ty) != null or self.overlayInfoForType(ty) != null) return null;
        if (lower_llvm_shape.domainPayloadType(&self.type_aliases, ty)) |payload_ty| return self.integerBitsOf(payload_ty);
        return integerBits(self.resolveAliasType(ty));
    }

    fn isSignedIntegerType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        if (self.enumDeclForType(ty)) |enum_decl| return self.isSignedIntegerType(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.isSignedIntegerType(info.repr);
        if (lower_llvm_shape.domainPayloadType(&self.type_aliases, ty)) |payload_ty| return self.isSignedIntegerType(payload_ty);
        return isSignedInteger(self.resolveAliasType(ty));
    }

    fn isBoolType(self: *LlvmEmitter, ty: anytype) bool {
        return switch (self.resolveAliasType(ty).kind) {
            .name => |name| std.mem.eql(u8, name.text, "bool"),
            else => false,
        };
    }

    fn fixedLayoutBitsOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?u16 {
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

    fn signedMinLiteralOf(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.signedMinLiteralOf(enumReprType(enum_decl));
        return signedMinLiteral(self.resolveAliasType(ty));
    }

    fn signedWindowMinLiteral(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const value = -(@as(i128, 1) << @intCast(bits - 1));
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn rawManyOffsetCallInfo(self: *LlvmEmitter, call: anytype, kind: mir.CallTargetKind) ?RawManyOffsetInfo {
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        const member = memberCallee(call) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        if (kind != .raw_many_offset) return null;
        const base_ty = (self.mirTargetTypeFactAt(.raw_many_offset_base, call.callee.*.span) orelse return null).target_ty;
        const element_ty = (self.mirTargetTypeFactAt(.raw_many_offset_element, call.callee.*.span) orelse return null).target_ty;
        const result_ty = (self.mirTargetTypeFactAt(.raw_many_offset_result, call.callee.*.span) orelse return null).target_ty;
        return .{ .base = member.base.*, .base_ty = base_ty, .element_ty = element_ty, .result_ty = result_ty };
    }

    fn isAggregateType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) bool {
        const resolved_ty = self.resolveAliasType(ty);
        if (lower_llvm_shape.maybeUninitPayloadType(&self.type_aliases, resolved_ty)) |payload_ty| return self.isAggregateType(payload_ty);
        return switch (resolved_ty.kind) {
            .array => true,
            .slice => true,
            .closure_type => true,
            .dyn_trait => true,
            .nullable => |child| self.nullablePayloadIsValueType(child.*) or self.isAggregateType(child.*),
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

fn restoreLocal(map: anytype, key: []const u8, old: anytype) void {
    if (old) |entry| {
        // Each scope removes this key before installing its shadow binding. Restoring
        // the old binding therefore fits in the capacity already retained by the map.
        map.putAssumeCapacity(key, entry.value);
    } else {
        _ = map.remove(key);
    }
}

const resultSwitchPattern = switch_lower.resultArmPattern;

const taggedUnionPatternName = switch_lower.taggedUnionPatternName;
const taggedUnionBindingPattern = switch_lower.taggedUnionArmBinding;
