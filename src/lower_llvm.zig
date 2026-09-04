const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const diagnostics = @import("diagnostics.zig");
const codegen_request = @import("codegen_request.zig");
const error_from = @import("error_from.zig");
const mir = @import("mir.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_executable_llvm = @import("mir_executable_llvm.zig");
const mir_source_bridge = @import("mir_source_bridge.zig");
const numeric = @import("numeric.zig");
const scalar_repr = @import("scalar_repr.zig");
const signature_type_mechanics = @import("signature_type_mechanics.zig");
const signature_type_materializer = @import("signature_type_materializer.zig");
const type_bridge = @import("type_bridge.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const TransitionalTypeExpr = @TypeOf(@as(lower_llvm_model.ReflectionCallInfo, undefined).target_ty);

/// Ephemeral syntax view for legacy LLVM rendering.  The canonical
/// target-type fact stores only `SignatureTypeId`; this is materialized from
/// the verified module table at the final syntax boundary.
const MaterializedTargetTypeFact = struct {
    kind: mir.TargetTypeKind,
    target_ty: TransitionalTypeExpr,
    result_ty: mir.ValueType,
    typed_result_ty: mir.TypeId,
    typed_span_id: mir.SpanId,
    typed_callee_span_id: mir.SpanId,
    typed_operand_value_id: mir.ValueId,
    aggregate_construction: ?mir.AggregateConstructionKind,
    target_index: ?usize,
    typed_target_owner_id: mir.SymbolId,
};

const typeName = type_bridge.typeName;
const isSourceSpan = mir_source_bridge.isSourceSpan;
const isOpaqueAddressTypeName = type_bridge.isOpaqueAddressTypeName;
const isStringLiteralTarget = type_bridge.isStringLiteralTarget;
const isMmioStructAbi = type_bridge.isMmioStructAbi;

const backend_mod = @import("backend.zig");
const lower_llvm_lookup = @import("lower_llvm_lookup.zig");
const lower_llvm_shape = @import("lower_llvm_shape.zig");

// Phase-2c split: pure type-mapping/classification helpers moved verbatim to
// `lower_llvm_type.zig`. Re-exported here so call sites read unchanged.
const lower_llvm_type = @import("lower_llvm_type.zig");
const simpleType = lower_llvm_type.simpleType;
const isOpaqueAddressGenericName = lower_llvm_type.isOpaqueAddressGenericName;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;
const libraryScalarLlvmType = lower_llvm_type.libraryScalarLlvmType;
const typeNameEql = lower_llvm_type.typeNameEql;
const integerBits = lower_llvm_type.integerBits;
const isSignedInteger = lower_llvm_type.isSignedInteger;
const intrinsicBits = lower_llvm_type.intrinsicBits;

// Phase-2c split: operator/predicate spelling, trap-helper, and literal
// normalization helpers moved verbatim to `lower_llvm_op.zig`. Re-exported
// here so call sites read unchanged.
const lower_llvm_op = @import("lower_llvm_op.zig");
const normalizedIntLiteral = lower_llvm_op.normalizedIntLiteral;
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
const llvmCanonicalStringBytes = lower_llvm_text.llvmCanonicalStringBytes;

// LLVM backend model records used by the emitter implementation.
const lower_llvm_reflect = @import("lower_llvm_reflect.zig");
const LlvmReflectEnv = lower_llvm_reflect.ReflectEnv;

const FnSig = lower_llvm_model.FnSig;
const BindThunk = lower_llvm_model.BindThunk;
const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const OverlayUnionInfo = lower_llvm_model.OverlayUnionInfo;
const TaggedUnionLayout = lower_llvm_model.TaggedUnionLayout;
const TaggedUnionInfo = lower_llvm_model.TaggedUnionInfo;
const StructInfo = lower_llvm_model.StructInfo;
const MmioFieldInfo = lower_llvm_model.MmioFieldInfo;
const ReflectionCallInfo = lower_llvm_model.ReflectionCallInfo;
const ArgValue = lower_llvm_model.ArgValue;
const StringLiteralGlobal = lower_llvm_model.StringLiteralGlobal;
const DebugFunction = lower_llvm_model.DebugFunction;
const DebugLocation = lower_llvm_model.DebugLocation;
const DebugLocal = lower_llvm_model.DebugLocal;
const DebugBasicType = struct {
    name: []const u8,
    size_bits: u16,
    encoding: []const u8,
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
    return appendLlvmCheckedMirProfileWithVerifiedProgram(allocator, request.program, request.out, request.opts.source_path orelse "input.mc", request.opts.checks, request.opts.stub_asm, request.opts.target_arch, request.opts.linux_kernel, request.opts.reporter) catch |err| backend_mod.lowerErrorFromAny(err);
}

pub fn appendLlvmCheckedMirArtifacts(
    allocator: std.mem.Allocator,
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
    return appendLlvmCheckedMirProfileWithVerifiedProgram(allocator, program, out, source_path, checks, stub_asm, target_arch, linux_kernel, reporter);
}

fn appendLlvmCheckedMirProfileWithVerifiedProgram(
    allocator: std.mem.Allocator,
    program: backend_mod.VerifiedProgram,
    out: *std.ArrayList(u8),
    source_path: []const u8,
    checks: backend_mod.Checks,
    stub_asm: bool,
    target_arch: backend_mod.TargetArch,
    linux_kernel: bool,
    reporter: ?*diagnostics.Reporter,
) !void {
    codegen_request.rejectExperimentalDynamicTraits(program, reporter) catch |err| switch (err) {
        error.ExperimentalDynamicTraitCodegen => return error.UnsupportedLlvmEmission,
    };
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
        .type_aliases = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
        .enum_types = std.StringHashMap(ast_bridge.EnumDecl).init(allocator),
        .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
        .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
        .tagged_unions = std.StringHashMap(TaggedUnionInfo).init(allocator),
        .struct_types = std.StringHashMap(StructInfo).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
        .backend_names = std.StringHashMap([]const u8).init(allocator),
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
    try ctx.collectTypeAliasFacts();
    try ctx.collectEnumFacts();
    try ctx.collectPackedBitsFacts();
    try ctx.collectOverlayUnionFacts();
    try ctx.collectTaggedUnionFacts();
    try ctx.collectStructFacts();
    try ctx.collectCallableEmissionFacts();
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
    type_aliases: std.StringHashMap(ast_bridge.TypeExpr) = undefined,
    enum_types: std.StringHashMap(ast_bridge.EnumDecl) = undefined,
    packed_bits: std.StringHashMap(PackedBitsInfo) = undefined,
    overlay_unions: std.StringHashMap(OverlayUnionInfo) = undefined,
    tagged_unions: std.StringHashMap(TaggedUnionInfo) = undefined,
    struct_types: std.StringHashMap(StructInfo) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    // `bind(scalar, f)` closures whose env is a non-pointer integer scalar. The
    // closure's env slot is `ptr`, so the scalar is widened via `inttoptr` and the
    // code pointer points at a generated thunk that narrows it back with `ptrtoint`
    // before calling `f`. Keyed by target function name.
    bind_thunks: std.StringHashMap(BindThunk) = undefined,
    // Source function name -> `#[backend_name("Y")]` override; emitted as a module-level
    // alias `@Y = alias <fnty>, ptr @name` so the override symbol is linkable (the C backend
    // achieves the same via an asm label).
    backend_names: std.StringHashMap([]const u8) = undefined,
    string_literals: std.ArrayList(StringLiteralGlobal) = undefined,
    debug_functions: std.ArrayList(DebugFunction) = undefined,
    debug_locations: std.ArrayList(DebugLocation) = undefined,
    debug_locals: std.ArrayList(DebugLocal) = undefined,
    debug_next_id: usize = 6,
    need_dbg_declare: bool = false,
    need_dbg_value: bool = false,
    current_debug_scope: ?usize = null,
    current_debug_span: ?ast_bridge.Span = null,
    current_return_ty: ?TransitionalTypeExpr = null,
    current_function: ?[]const u8 = null,
    current_params: ?[]const lower_llvm_model.FnParam = null,
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
        self.type_aliases.deinit();
        self.enum_types.deinit();
        self.packed_bits.deinit();
        self.overlay_unions.deinit();
        self.tagged_unions.deinit();
        self.struct_types.deinit();
        self.fn_sigs.deinit();
        self.bind_thunks.deinit();
        self.backend_names.deinit();
        self.string_literals.deinit(self.allocator);
        self.debug_functions.deinit(self.allocator);
        self.debug_locations.deinit(self.allocator);
        self.debug_locals.deinit(self.allocator);
        self.scratch.deinit();
    }

    /// This AST-shaped cache is derived only from the module-owned alias
    /// fact table for legacy aggregate/body helpers.
    fn collectTypeAliasFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.type_aliases) |fact| {
            const identity = self.typeAliasIdentity(fact) orelse return error.UnsupportedLlvmEmission;
            const target = try signature_type_materializer.typeExpr(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                fact.target_type_id,
                .{ .offset = 0, .len = 0, .line = 0, .column = 0 },
            );
            if (self.type_aliases.contains(identity.spelling)) return error.UnsupportedLlvmEmission;
            try self.type_aliases.put(identity.spelling, target);
        }
    }

    /// Enum AST views are derived solely from checked module facts for the
    /// remaining legacy expression helpers. No declaration artifact carries
    /// an enum AST ingress.
    fn collectEnumFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.enums) |fact| {
            const enum_decl = try signature_type_materializer.enumDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            try self.collectEnum(enum_decl);
        }
    }

    /// Packed-bits rendering views are derived from module-owned checked
    /// facts. No declaration artifact carries a packed-bits AST payload.
    fn collectPackedBitsFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.packed_bits) |fact| {
            const packed_bits = try signature_type_materializer.packedBitsDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            try self.collectPackedBits(packed_bits);
        }
    }

    /// Overlay storage and field layouts are admitted module facts. The
    /// temporary AST view is only for legacy expression rendering.
    fn collectOverlayUnionFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.overlay_unions) |fact| {
            const overlay_union = try signature_type_materializer.overlayUnionDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            try self.collectOverlayUnionFact(overlay_union, fact);
        }
    }

    /// Tagged-union rendering views are derived from checked module facts;
    /// the stored layout is the frontend's canonical aggregate-layout result.
    fn collectTaggedUnionFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.tagged_unions) |fact| {
            const tagged_union = try signature_type_materializer.taggedUnionDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            try self.collectTaggedUnionFact(tagged_union, fact);
        }
    }

    fn collectStructFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.structs) |fact| {
            const struct_decl = try signature_type_materializer.structDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            if (struct_decl.type_params.len != 0) continue;
            try self.struct_types.put(struct_decl.name.text, .{
                .decl = struct_decl,
                .storage_size = fact.storage_size,
                .storage_alignment = fact.storage_alignment,
            });
        }
        for (self.mir_module.structs) |fact| {
            const struct_decl = try signature_type_materializer.structDecl(
                self.scratch.allocator(),
                self.mir_module.signature_types,
                self.mir_module.symbol_identities,
                fact,
            );
            try self.collectStructFact(struct_decl, fact);
        }
    }

    fn collectStructFact(self: *LlvmEmitter, struct_decl: ast_bridge.StructDecl, fact: mir.StructFact) !void {
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
        try self.struct_types.put(struct_decl.name.text, .{ .decl = struct_decl, .storage_size = fact.storage_size, .storage_alignment = fact.storage_alignment });
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

    fn collectOverlayUnionFact(self: *LlvmEmitter, overlay_union: ast_bridge.OverlayUnionDecl, fact: mir.OverlayUnionFact) !void {
        if (overlay_union.fields.len != fact.fields.len) return error.UnsupportedLlvmEmission;
        try self.overlay_unions.put(overlay_union.name.text, .{
            .fields = overlay_union.fields,
            .size = fact.storage_size,
            .alignment = fact.storage_alignment,
        });
    }

    fn collectTaggedUnionFact(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl, fact: mir.TaggedUnionFact) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| _ = try self.llvmType(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, .{ .decl = union_decl, .layout = fact.layout });
    }

    fn collectCallableEmissionFacts(self: *LlvmEmitter) !void {
        for (self.mir_module.callable_emission_facts) |fact| try self.collectCallableEmissionFact(fact);
    }

    fn collectCallableEmissionFact(self: *LlvmEmitter, fact: mir.CallableEmissionFact) !void {
        const checked = self.checkedCallableFact(fact.def_id) orelse return error.UnsupportedLlvmEmission;
        const name = self.callableSymbol(fact) orelse return error.UnsupportedLlvmEmission;
        const fn_mir = self.mirFunctionByDefId(fact.def_id) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, name, fn_mir.name) or !mir.ValueType.eql(checked.return_ty, fn_mir.return_ty) or
            fact.params.len != fn_mir.param_types.len or fact.params.len != checked.signature_param_type_ids.len or
            checked.kind == .global_initializer)
            return error.UnsupportedLlvmEmission;
        const declaration_span = spanFromSourcePoint(fact.declaration_source);
        const ret_ty = try self.signatureTypeExpr(checked.signature_return_type_id, declaration_span);
        _ = try self.llvmType(ret_ty);
        const signature_ret = try self.llvmSignatureType(checked.signature_return_type_id);
        if (!std.mem.eql(u8, signature_ret, try self.llvmType(ret_ty))) return error.UnsupportedLlvmEmission;
        const params = try self.scratch.allocator().alloc(lower_llvm_model.FnParam, fact.params.len);
        for (fact.params, fn_mir.param_types, checked.param_types, checked.signature_param_type_ids, 0..) |param, mir_param_ty, checked_param_ty, signature_type_id, index| {
            if (!mir.ValueType.eql(checked_param_ty, mir_param_ty)) return error.UnsupportedLlvmEmission;
            const param_ty = try self.signatureTypeExpr(signature_type_id, declaration_span);
            const signature_param = try self.llvmSignatureType(signature_type_id);
            if (!std.mem.eql(u8, signature_param, try self.llvmType(param_ty))) return error.UnsupportedLlvmEmission;
            params[index] = .{
                .name = param.spelling,
                .value_ty = checked_param_ty,
                .type_id = signature_type_id,
                .ty = param_ty,
            };
        }
        const debug_id: ?usize = if (checked.kind == .function) blk: {
            const id = self.debug_next_id;
            self.debug_next_id += 1;
            try self.debug_functions.append(self.allocator, .{
                .id = id,
                .name = name,
                .source_path = self.sourcePathForSpan(declaration_span),
                .line = debugLine(fact.declaration_source.line),
                .column = debugColumn(fact.declaration_source.column),
            });
            break :blk id;
        } else null;
        try self.fn_sigs.put(name, .{
            .return_ty = checked.return_ty,
            .return_type_id = checked.signature_return_type_id,
            .ret = ret_ty,
            .params = params,
            .c_abi = checked.c_abi,
            .is_variadic = checked.is_variadic,
            .debug_id = debug_id,
            .error_from = fact.error_from,
        });
        if (checked.kind != .extern_function) if (fact.backend_name) |backend_name| try self.backend_names.put(name, backend_name);
    }

    fn emitCollectedGlobals(self: *LlvmEmitter) !void {
        for (self.mir_module.checked_globals) |global| {
            const fact = self.mir_module.checkedGlobalInitializer(global) orelse continue;
            switch (fact.plan) {
                .scalar => try self.emitCheckedScalarGlobal(global, fact),
                .zero => try self.emitCheckedZeroGlobal(global),
                .atomic_init => |plan| try self.emitCheckedAtomicInitGlobal(global, plan),
                .aggregate => |plan| try self.emitCheckedAggregateGlobal(global, plan),
                .enum_case => |plan| try self.emitCheckedEnumGlobal(global, plan),
                .nullable_null => try self.emitCheckedNullableNullGlobal(global),
                .string_bytes => |plan| try self.emitCheckedStringBytesGlobal(global, plan),
                .global_address => |plan| try self.emitCheckedGlobalAddressGlobal(global, plan),
                .function_symbol => |plan| try self.emitCheckedFunctionSymbolGlobal(global, plan),
            }
        }
        for (self.mir_module.checked_globals) |global| {
            if (!global.is_extern) continue;
            try self.emitCheckedExternGlobal(global);
        }
    }

    fn emitCheckedExternGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        try self.out.print(self.allocator, "@{s} = external global {s}\n", .{ name, try self.llvmSignatureType(global.signature_type_id) });
    }

    fn emitCheckedScalarGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, fact: mir.GlobalInitializerFact) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try mir_executable_llvm.renderType(self.scratch.allocator(), &mir.ExecutableBody{}, global.ty, null);
        const init = try self.scalarConstGlobalInitializer(fact);
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(self.allocator, "@{s} = {s}{s} {s} {s}\n", .{ name, visibility, kind, llvm_ty, init });
    }

    fn emitCheckedAtomicInitGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.AtomicInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmSignatureType(global.signature_type_id);
        const init = try self.llvmScalarGlobalInitializer(plan.value);
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(self.allocator, "@{s} = {s}{s} {s} {s}\n", .{ name, visibility, kind, llvm_ty, init });
    }

    fn emitCheckedZeroGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const ty = try self.signatureTypeExpr(global.signature_type_id, spanFromSourcePoint(global.declaration_source));
        const llvm_ty = try self.llvmSignatureType(global.signature_type_id);
        if (global.ty != .value) {
            const executable_type = mir_executable_llvm.renderType(self.scratch.allocator(), &mir.ExecutableBody{}, global.ty, null) catch |err| switch (err) {
                error.Unsupported, error.InvalidBody => null,
                else => return err,
            };
            if (executable_type) |value| if (!std.mem.eql(u8, llvm_ty, value)) return error.UnsupportedLlvmEmission;
        }
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(self.allocator, "@{s} = {s}{s} {s} {s}\n", .{ name, visibility, kind, llvm_ty, try self.zeroInitializer(ty) });
    }

    fn emitCheckedAggregateGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.AggregateInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmSignatureType(global.signature_type_id);
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} {s}\n",
            .{ name, visibility, kind, llvm_ty, try self.llvmAggregateGlobalInitializer(plan, global.signature_type_id) },
        );
    }

    fn emitCheckedEnumGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.EnumInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const enum_fact = self.enumFact(plan.enum_symbol_id) orelse return error.UnsupportedLlvmEmission;
        if (!enum_fact.repr_type_id.eql(plan.repr_type_id) or plan.case_index >= enum_fact.cases.len) return error.UnsupportedLlvmEmission;
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} {s}\n",
            .{ name, visibility, kind, try self.llvmSignatureType(global.signature_type_id), try self.llvmEnumCaseInitializer(enum_fact.cases[plan.case_index]) },
        );
    }

    fn emitCheckedNullableNullGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} null\n",
            .{ name, visibility, kind, try self.llvmSignatureType(global.signature_type_id) },
        );
    }

    fn emitCheckedStringBytesGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.StringBytesInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const string = try self.internPlannedStringBacking(plan);
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} getelementptr ([{d} x i8], ptr @{s}, i64 0, i64 0)\n",
            .{ name, visibility, kind, try self.llvmSignatureType(global.signature_type_id), string.len, string.name },
        );
    }

    fn emitCheckedGlobalAddressGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.GlobalAddressInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const target = self.checkedGlobalSymbolId(plan.target_symbol_id) orelse return error.UnsupportedLlvmEmission;
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} @{s}\n",
            .{ name, visibility, kind, try self.llvmSignatureType(global.signature_type_id), target },
        );
    }

    fn emitCheckedFunctionSymbolGlobal(self: *LlvmEmitter, global: mir.CheckedGlobalFact, plan: mir.FunctionSymbolInitializerPlan) !void {
        const name = self.checkedGlobalSymbol(global) orelse return error.UnsupportedLlvmEmission;
        const target = self.checkedFunctionSymbolId(plan.target_symbol_id) orelse return error.UnsupportedLlvmEmission;
        const visibility: []const u8 = if (global.exported) "" else "internal ";
        const kind: []const u8 = if (global.is_const) "constant" else "global";
        try self.out.print(
            self.allocator,
            "@{s} = {s}{s} {s} @{s}\n",
            .{ name, visibility, kind, try self.llvmSignatureType(global.signature_type_id), target },
        );
    }

    fn enumFact(self: *const LlvmEmitter, symbol_id: mir.SymbolId) ?mir.EnumFact {
        for (self.mir_module.enums) |fact| if (fact.symbol_id.eql(symbol_id)) return fact;
        return null;
    }

    fn llvmEnumCaseInitializer(self: *LlvmEmitter, value: mir.EnumCaseFact) ![]const u8 {
        return if (value.negative)
            std.fmt.allocPrint(self.scratch.allocator(), "-{d}", .{value.magnitude})
        else
            std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value.magnitude});
    }

    fn llvmAggregateGlobalInitializer(self: *LlvmEmitter, plan: mir.AggregateInitializerPlan, id: mir.SignatureTypeId) ![]const u8 {
        return switch (plan) {
            .scalar => |value| self.llvmScalarGlobalInitializer(value),
            .function_symbol => |value| blk: {
                const target = self.checkedFunctionSymbolId(value.target_symbol_id) orelse return error.UnsupportedLlvmEmission;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{target});
            },
            .array => |items| blk: {
                const shape = signature_type_mechanics.shape(self.mir_module.signature_types, id) catch return error.UnsupportedLlvmEmission;
                const array = switch (shape) {
                    .array => |value| value,
                    else => return error.UnsupportedLlvmEmission,
                };
                const length = array.length orelse return error.UnsupportedLlvmEmission;
                if (items.len != length) return error.UnsupportedLlvmEmission;
                const child_ty = try self.llvmSignatureType(array.child);
                var text: std.ArrayList(u8) = .empty;
                try text.append(self.scratch.allocator(), '[');
                for (items, 0..) |item, index| {
                    if (index != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ child_ty, try self.llvmAggregateGlobalInitializer(item, array.child) });
                }
                try text.append(self.scratch.allocator(), ']');
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .struct_ => |struct_plan| blk: {
                const struct_fact = self.structFact(struct_plan.struct_symbol_id) orelse return error.UnsupportedLlvmEmission;
                if (struct_plan.fields.len != struct_fact.fields.len) return error.UnsupportedLlvmEmission;
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(self.scratch.allocator(), "{ ");
                for (struct_plan.fields, 0..) |field, index| {
                    if (field.field_index != index or index >= struct_fact.fields.len) return error.UnsupportedLlvmEmission;
                    const struct_field = struct_fact.fields[index];
                    if (index != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmSignatureType(struct_field.type_id), try self.llvmAggregateGlobalInitializer(field.value, struct_field.type_id) });
                }
                try text.appendSlice(self.scratch.allocator(), " }");
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .zero => "zeroinitializer",
            .enum_case => |value| blk: {
                const enum_fact = self.enumFact(value.enum_symbol_id) orelse return error.UnsupportedLlvmEmission;
                if (!enum_fact.repr_type_id.eql(value.repr_type_id) or value.case_index >= enum_fact.cases.len) return error.UnsupportedLlvmEmission;
                break :blk try self.llvmEnumCaseInitializer(enum_fact.cases[value.case_index]);
            },
            .string_bytes => |value| blk: {
                const string = try self.internPlannedStringBacking(value);
                break :blk try std.fmt.allocPrint(
                    self.scratch.allocator(),
                    "getelementptr ([{d} x i8], ptr @{s}, i64 0, i64 0)",
                    .{ string.len, string.name },
                );
            },
            .global_address => |value| blk: {
                const target = self.checkedGlobalSymbolId(value.target_symbol_id) orelse return error.UnsupportedLlvmEmission;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{target});
            },
        };
    }

    fn structFact(self: *const LlvmEmitter, symbol_id: mir.SymbolId) ?mir.StructFact {
        for (self.mir_module.structs) |fact| if (fact.symbol_id.eql(symbol_id)) return fact;
        return null;
    }

    fn checkedGlobalSymbol(self: *const LlvmEmitter, global: mir.CheckedGlobalFact) ?[]const u8 {
        return self.checkedGlobalSymbolId(global.symbol_id);
    }

    fn checkedGlobalSymbolId(self: *const LlvmEmitter, symbol_id: mir.SymbolId) ?[]const u8 {
        if (!symbol_id.isValid() or symbol_id.index() >= self.mir_module.symbol_identities.len) return null;
        const identity = self.mir_module.symbol_identities[symbol_id.index()];
        return if (identity.id.eql(symbol_id) and identity.kind == .global) identity.spelling else null;
    }

    fn checkedFunctionSymbolId(self: *const LlvmEmitter, symbol_id: mir.SymbolId) ?[]const u8 {
        if (!symbol_id.isValid() or symbol_id.index() >= self.mir_module.symbol_identities.len) return null;
        const identity = self.mir_module.symbol_identities[symbol_id.index()];
        return if (identity.id.eql(symbol_id) and identity.kind == .function) identity.spelling else null;
    }

    fn typeAliasIdentity(self: *const LlvmEmitter, fact: mir.TypeAliasFact) ?mir.SymbolIdentity {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= self.mir_module.symbol_identities.len) return null;
        const identity = self.mir_module.symbol_identities[fact.symbol_id.index()];
        return if (identity.id.eql(fact.symbol_id) and identity.kind == .type_) identity else null;
    }

    fn emitCollectedCallableDeclarations(self: *LlvmEmitter) !void {
        for (self.mir_module.callable_emission_facts) |fact| {
            const checked = self.checkedCallableFact(fact.def_id) orelse return error.UnsupportedLlvmEmission;
            if (checked.kind == .extern_function) try self.emitExternFunction(fact);
        }

        // Function-definition admission is driven by verified MIR.  The
        // Callable emission facts are mandatory render metadata, while MIR
        // remains the sole body authority.
        for (self.mir_module.functions) |fn_mir| {
            if (fn_mir.is_extern) continue;
            // Global initializer bodies are compiler-internal checked MIR, not
            // callable source entries. They deliberately have no callable emission fact
            // and are identified by the absence of a declaration DefId, rather
            // than by positional coupling to the checked-callable table.
            if (!fn_mir.typed_def_id.isValid()) continue;
            // Declaration facts are mandatory for every executable body.  Do
            // not silently omit a verified MIR function when its matching
            // fact is absent: ordinary codegen has no AST body fallback
            // that could make such an ingress failure acceptable.
            const fact = self.mir_module.callableEmissionFact(fn_mir.typed_def_id) orelse return error.UnsupportedLlvmEmission;
            const checked = self.checkedCallableFact(fact.def_id) orelse return error.UnsupportedLlvmEmission;
            const name = self.callableSymbol(fact) orelse return error.UnsupportedLlvmEmission;
            if (!std.mem.eql(u8, name, fn_mir.name) or checked.kind != .function) return error.UnsupportedLlvmEmission;
            const render_attrs = fact.render_attrs;
            const previous_source_path = self.source_path;
            self.source_path = self.sourcePathForSpan(spanFromMirSourcePoint(fact.declaration_source));
            defer self.source_path = previous_source_path;
            if (try self.emitExecutableMirFunction(fact, fn_mir, render_attrs)) {
                continue;
            } else if (mir_executable_body.explicitUnsupported(&fn_mir)) |unsupported| {
                self.reportUnsupported(spanFromMirSourcePoint(unsupported.source), unsupported.construct());
                return error.UnsupportedLlvmEmission;
            } else {
                return error.UnsupportedLlvmEmission;
            }
        }
    }

    fn checkedCallableFact(self: *const LlvmEmitter, def_id: mir.DefId) ?mir.CheckedCallableFact {
        if (!def_id.isValid()) return null;
        var found: ?mir.CheckedCallableFact = null;
        for (self.mir_module.checked_callables) |fact| {
            if (!fact.def_id.eql(def_id)) continue;
            if (found != null) return null;
            found = fact;
        }
        return found;
    }

    fn callableSymbol(self: *const LlvmEmitter, fact: mir.CallableEmissionFact) ?[]const u8 {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= self.mir_module.symbol_identities.len) return null;
        const identity = self.mir_module.symbol_identities[fact.symbol_id.index()];
        return if (identity.id.eql(fact.symbol_id) and identity.kind == .function) identity.spelling else null;
    }

    fn sourcePathForSpan(self: *const LlvmEmitter, span: diagnostics.Span) []const u8 {
        if (span.file_id != diagnostics.invalid_file_id) {
            if (self.reporter) |reporter| if (reporter.pathForFileId(span.file_id)) |path| return path;
        }
        return self.source_path;
    }

    fn globalConstIndexValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ?u64 {
        return switch (expr.kind) {
            .int_literal => |literal| numeric.parseUsizeLiteral(literal),
            .char_literal => |literal| numeric.parseCharLiteral(literal),
            .grouped => |inner| self.globalConstIndexValue(inner.*),
            else => null,
        };
    }

    fn reflectEnv(self: *LlvmEmitter) LlvmReflectEnv {
        return .{
            .type_aliases = &self.type_aliases,
            .enum_types = &self.enum_types,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .struct_types = &self.struct_types,
        };
    }

    fn scalarConstGlobalInitializer(self: *LlvmEmitter, fact: mir.GlobalInitializerFact) ![]const u8 {
        if (!fact.scalarValue().isCompatibleWith(fact.value_ty)) return error.UnsupportedLlvmEmission;
        return self.llvmScalarGlobalInitializer(fact.scalarValue());
    }

    fn llvmScalarGlobalInitializer(self: *LlvmEmitter, scalar: mir.ConstScalarValue) ![]const u8 {
        return switch (scalar) {
            .int => |number| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{number}),
            .uint => |number| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{number}),
            .boolean => |value| if (value) "1" else "0",
            .float => |value| switch (value.width) {
                32 => try std.fmt.allocPrint(self.scratch.allocator(), "bitcast (i32 {d} to float)", .{@as(u32, @truncate(value.bits))}),
                64 => try std.fmt.allocPrint(self.scratch.allocator(), "bitcast (i64 {d} to double)", .{value.bits}),
                else => error.UnsupportedLlvmEmission,
            },
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
            try self.out.print(self.allocator, "@{s} = alias {s} (", .{ backend, try self.llvmSignatureType(sig.return_type_id) });
            for (sig.params, 0..) |param, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, try self.llvmSignatureType(param.type_id));
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

    fn cAbiExtensionForSignature(self: *LlvmEmitter, id: mir.SignatureTypeId) []const u8 {
        const shape = signature_type_mechanics.shape(self.mir_module.signature_types, id) catch return "";
        return switch (shape) {
            .qualified => |node| self.cAbiExtensionForSignature(node.child),
            .generic => |node| if (isPayloadDomainGenericName(node.base) and node.args.len == 1)
                self.cAbiExtensionForSignature(node.args[0])
            else
                "",
            .name => |name| self.cAbiExtensionForSignatureName(name),
            else => "",
        };
    }

    fn cAbiExtensionForSignatureName(self: *LlvmEmitter, name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "bool")) return if (self.target_arch == .aarch64) "" else "zeroext ";
        if (scalar_repr.integer(name)) |integer| {
            if (integer.bits > 32 or self.target_arch == .aarch64) return "";
            if (integer.bits == 32) return if (self.target_arch == .riscv64) "signext " else "";
            return if (integer.signed) "signext " else "zeroext ";
        }
        // A nominal alias is a type-declaration lookup, never callable
        // signature syntax.  Keep its established ABI classification intact.
        if (self.type_aliases.get(name)) |target| return self.cAbiExtension(target);
        if (self.enum_types.get(name)) |decl| return self.cAbiExtension(enumReprType(decl));
        if (self.packed_bits.get(name)) |info| return self.cAbiExtension(info.repr);
        return "";
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

    fn emitExecutableMirFunction(self: *LlvmEmitter, fact: mir.CallableEmissionFact, fn_mir: mir.Function, render_attrs: codegen_attrs.FunctionRenderAttrs) !bool {
        if (render_attrs.naked) return self.emitExecutableMirNakedFunction(fact, fn_mir, render_attrs);
        const cleanup_free = fn_mir.ownership_cleanup_plan.actions.len == 0 and
            fn_mir.ownership_cleanup_plan.cancellations.len == 0;
        if (fn_mir.executable_body.cleanup_actions.len == 0) {
            for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return false;
        }
        if (!cleanup_free or !mir_executable_body.isComplete(&fn_mir) or !self.mirExecutableBodySupported(fn_mir)) return false;

        const call_abi_plan = (try self.buildExecutableDirectCallAbiPlan(fn_mir)) orelse return false;
        var string_symbols: std.ArrayList(mir_executable_llvm.StringLiteralSymbol) = .empty;
        defer string_symbols.deinit(self.allocator);
        for (fn_mir.executable_body.expressions) |expression| switch (expression.operation) {
            .literal => |literal| switch (literal) {
                .string => |bytes| {
                    const global = try self.internCanonicalStringLiteral(bytes);
                    try string_symbols.append(self.allocator, .{ .expression = expression.id, .spelling = global.name });
                },
                else => {},
            },
            else => {},
        };
        const rendered = mir_executable_llvm.renderWithCallAbiAndOptions(self.scratch.allocator(), &fn_mir.executable_body, fn_mir.return_ty, call_abi_plan, .{
            .stub_asm = self.stub_asm,
            .string_literals = string_symbols.items,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported, error.InvalidBody => return false,
        };
        const checked = self.checkedCallableFact(fact.def_id) orelse return error.UnsupportedLlvmEmission;
        const name = self.callableSymbol(fact) orelse return error.UnsupportedLlvmEmission;
        if (!mir.ValueType.eql(checked.return_ty, fn_mir.return_ty)) return false;
        const fn_sig = self.fn_sigs.get(name) orelse return error.UnsupportedLlvmEmission;
        const ret_ty = fn_sig.ret;
        const ret_llvm = if (checked.return_ty == .value and fn_mir.return_callable_signature == null and !fn_mir.executable_body.return_dyn_trait_symbol_id.isValid())
            try self.llvmSignatureType(checked.signature_return_type_id)
        else
            mir_executable_llvm.renderType(self.scratch.allocator(), &fn_mir.executable_body, checked.return_ty, fn_mir.return_callable_signature) catch |err| switch (err) {
                error.Unsupported, error.InvalidBody => try self.llvmType(ret_ty),
                else => return err,
            };
        const ret_ext = if (fn_sig.c_abi) self.cAbiExtensionForSignature(checked.signature_return_type_id) else "";

        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_return_ty = self.current_return_ty;
        const old_function = self.current_function;
        const old_params = self.current_params;
        self.current_debug_scope = if (self.fn_sigs.get(name)) |sig| sig.debug_id else null;
        self.current_debug_span = spanFromMirSourcePoint(fact.declaration_source);
        self.current_return_ty = ret_ty;
        self.current_function = name;
        self.current_params = fn_sig.params;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_return_ty = old_return_ty;
            self.current_function = old_function;
            self.current_params = old_params;
        }

        const mechanics = try self.llvmFunctionRenderMechanics(render_attrs, fact.exported);

        try self.out.print(self.allocator, "define {s}{s}{s} @{s}(", .{ mechanics.linkage, ret_ext, ret_llvm, name });
        for (fn_sig.params, fn_mir.executable_body.parameters, 0..) |param, executable_parameter, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (fn_sig.c_abi) self.cAbiExtensionForSignature(param.type_id) else "";
            try self.out.print(self.allocator, "{s} {s}%mc_arg_{d}", .{ try self.executableFunctionParamType(fn_mir, param, i), param_ext, executable_parameter.local.raw });
        }
        if (fn_mir.executable_body.is_variadic) {
            if (fn_sig.params.len != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "...");
        }
        const entry_label = try self.functionEntryLabel();
        if (self.current_debug_scope) |scope| {
            try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\n{s}:\n", .{ mechanics.attributes, mechanics.section, mechanics.alignment, scope, entry_label });
        } else {
            try self.out.print(self.allocator, "){s}{s}{s} {{\n{s}:\n", .{ mechanics.attributes, mechanics.section, mechanics.alignment, entry_label });
        }
        for (fn_mir.pointer_provenance_facts) |provenance_fact| {
            try self.emitMirPointerProvenanceConsumedComment(provenance_fact);
        }
        try self.emitExecutableAggregateReturnPointerFacts(&fn_mir.executable_body);
        try self.out.appendSlice(self.allocator, rendered);
        try self.out.appendSlice(self.allocator, "}\n\n");
        return true;
    }

    fn emitExecutableMirNakedFunction(self: *LlvmEmitter, fact: mir.CallableEmissionFact, fn_mir: mir.Function, render_attrs: codegen_attrs.FunctionRenderAttrs) !bool {
        const cleanup_free = fn_mir.ownership_cleanup_plan.actions.len == 0 and
            fn_mir.ownership_cleanup_plan.cancellations.len == 0 and cleanup_edges: {
            for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) break :cleanup_edges false;
            break :cleanup_edges true;
        };
        if (!cleanup_free or !mir_executable_body.isComplete(&fn_mir) or
            !mir_executable_llvm.canRenderNaked(&fn_mir.executable_body) or
            fn_mir.executable_body.parameters.len != fn_mir.param_types.len or
            fn_mir.executable_body.parameters.len != fn_mir.param_count) return false;
        for (fn_mir.executable_body.parameters, fn_mir.param_types) |parameter, parameter_ty|
            if (!mir.ValueType.eql(parameter.ty, parameter_ty)) return false;

        const rendered = mir_executable_llvm.renderNaked(self.scratch.allocator(), &fn_mir.executable_body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported, error.InvalidBody => return false,
        };
        const checked = self.checkedCallableFact(fact.def_id) orelse return false;
        const name = self.callableSymbol(fact) orelse return false;
        if (!mir.ValueType.eql(checked.return_ty, fn_mir.return_ty)) return false;
        const fn_sig = self.fn_sigs.get(name) orelse return false;
        const ret_ty = fn_sig.ret;
        const ret_llvm = if (checked.return_ty == .value and fn_mir.return_callable_signature == null and !fn_mir.executable_body.return_dyn_trait_symbol_id.isValid())
            try self.llvmSignatureType(checked.signature_return_type_id)
        else
            mir_executable_llvm.renderType(self.scratch.allocator(), &fn_mir.executable_body, checked.return_ty, fn_mir.return_callable_signature) catch |err| switch (err) {
                error.Unsupported, error.InvalidBody => try self.llvmType(ret_ty),
                else => return err,
            };
        const ret_ext = if (fn_sig.c_abi) self.cAbiExtensionForSignature(checked.signature_return_type_id) else "";
        const mechanics = try self.llvmFunctionRenderMechanics(render_attrs, fact.exported);

        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_function = self.current_function;
        self.current_debug_scope = if (self.fn_sigs.get(name)) |sig| sig.debug_id else null;
        self.current_debug_span = spanFromMirSourcePoint(fact.declaration_source);
        self.current_function = name;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_function = old_function;
        }

        try self.out.print(self.allocator, "define {s}{s}{s} @{s}(", .{ mechanics.linkage, ret_ext, ret_llvm, name });
        for (fn_sig.params, fn_mir.executable_body.parameters, 0..) |param, executable_parameter, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (fn_sig.c_abi) self.cAbiExtensionForSignature(param.type_id) else "";
            try self.out.print(self.allocator, "{s} {s}%mc_arg_{d}", .{ try self.executableFunctionParamType(fn_mir, param, index), param_ext, executable_parameter.local.raw });
        }
        const entry_label = try self.functionEntryLabel();
        if (self.current_debug_scope) |scope|
            try self.out.print(self.allocator, "){s}{s}{s} !dbg !{d} {{\n{s}:\n", .{ mechanics.attributes, mechanics.section, mechanics.alignment, scope, entry_label })
        else
            try self.out.print(self.allocator, "){s}{s}{s} {{\n{s}:\n", .{ mechanics.attributes, mechanics.section, mechanics.alignment, entry_label });
        try self.out.appendSlice(self.allocator, rendered);
        try self.out.appendSlice(self.allocator, "}\n\n");
        return true;
    }

    fn emitExecutableAggregateReturnPointerFacts(
        self: *LlvmEmitter,
        body: *const mir.ExecutableBody,
    ) !void {
        for (body.places) |place| {
            const deref = mir.executableAggregatePointerFieldDerefPlace(body, place, false) orelse continue;
            const local_id = switch (place.root) {
                .local => |id| id,
                .symbol, .value => continue,
            };
            var initializer: ?mir.ExprId = null;
            for (body.statements) |statement| switch (statement.operation) {
                .local_init => |init| if (init.local.eql(local_id)) {
                    if (initializer != null or init.value == null) {
                        initializer = null;
                        break;
                    }
                    initializer = init.value;
                },
                else => {},
            };
            const value_id = initializer orelse continue;
            if (!value_id.isValid() or value_id.index() >= body.expressions.len) continue;
            const value = body.expressions[value_id.index()];
            const call = switch (value.operation) {
                .direct_call => |operation| operation,
                else => continue,
            };
            if (!call.callee.isValid() or call.callee.index() >= body.symbols.len) continue;
            const callee = body.symbols[call.callee.index()];
            var aggregate_index: ?usize = null;
            for (body.aggregate_types, 0..) |candidate, index| if (candidate.type_id.eql(place.root_type_id)) {
                aggregate_index = index;
                break;
            };
            const shape = body.aggregate_types[aggregate_index orelse continue];
            if (deref.field_index >= shape.field_count) continue;
            const field_path = shape.field_spellings[deref.field_index];
            for (self.mir_module.aggregate_return_pointer_facts) |fact| {
                if (!std.mem.eql(u8, fact.callee, callee.spelling) or
                    !std.mem.eql(u8, fact.field_path, field_path)) continue;
                try self.emitMirAggregateReturnPointerFactConsumedComment(fact);
            }
        }
    }

    fn mirStructuralType(self: *LlvmEmitter, value_ty: mir.ValueType) ?[]const u8 {
        return switch (value_ty) {
            .void => "void",
            .bool => "i1",
            .integer => |name| if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8"))
                "i8"
            else if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16"))
                "i16"
            else if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32"))
                "i32"
            else if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize"))
                "i64"
            else
                null,
            .domain_integer => |shape| self.mirStructuralType(.{ .integer = shape.child }),
            .float => |name| if (std.mem.eql(u8, name, "f32")) "float" else if (std.mem.eql(u8, name, "f64")) "double" else null,
            .pointer => |shape| if (shape.kind == .slice) "{ ptr, i64 }" else "ptr",
            .nullable_pointer => |shape| if (shape.kind == .slice) null else "ptr",
            .cstr => "ptr",
            .slice => "{ ptr, i64 }",
            .address => "i64",
            .struct_, .closed_enum, .open_enum => |name| self.llvmType(simpleType(.{ .offset = 0, .len = 0, .line = 0, .column = 0 }, name)) catch null,
            else => null,
        };
    }

    fn mirExecutableBodySupported(self: *LlvmEmitter, fn_mir: mir.Function) bool {
        if (!mir_executable_body.isComplete(&fn_mir)) return false;
        const maybe_call_abi_plan = self.buildExecutableDirectCallAbiPlan(fn_mir) catch return false;
        const call_abi_plan = maybe_call_abi_plan orelse return false;
        if (!mir_executable_llvm.supportsWithCallAbi(&fn_mir.executable_body, fn_mir.return_ty, call_abi_plan)) return false;
        if (fn_mir.executable_body.parameters.len != fn_mir.param_types.len or
            fn_mir.executable_body.parameters.len != fn_mir.param_count) return false;
        for (fn_mir.executable_body.parameters, fn_mir.param_types) |parameter, parameter_ty| {
            if (!mir.ValueType.eql(parameter.ty, parameter_ty)) return false;
        }
        for (fn_mir.executable_body.expressions) |expression| switch (expression.operation) {
            // Generic executable MIR does not yet carry the ordinary/atomic/
            // volatile/MMIO access mode.  Keep every memory read on the
            // specialized path until that semantic fact is explicit.
            .symbol => |symbol_id| {
                const symbol = mir_executable_body.symbol(&fn_mir.executable_body, symbol_id) orelse return false;
                // Functions are SSA pointer values. Aggregate globals may
                // appear only as storage bases for a renderer-admitted typed
                // index; supportsWithCallAbi above proves that use. All other
                // global reads still require an explicit access operation.
                if (symbol.kind == .function) {
                    if (expression.result_ty != .value) return false;
                } else if (symbol.kind != .global or expression.result_ty != .array) return false;
            },
            .deref => return false,
            .direct_call => |call| {
                const symbol = mir_executable_body.symbol(&fn_mir.executable_body, call.callee) orelse return false;
                const signature = self.mirFunctionByName(symbol.spelling) orelse return false;
                if (signature.is_variadic or signature.param_count != call.argument_count or signature.param_types.len != call.argument_count) return false;
                if (signature.c_abi) {
                    if (!mir.ValueType.eql(signature.return_ty, expression.result_ty)) return false;
                } else if (!self.executableMirTypeMatches(signature.return_ty, expression.result_ty)) return false;
                for (call.arguments[0..call.argument_count], signature.param_types) |argument_id, parameter_ty| {
                    const argument = mir_executable_body.expression(&fn_mir.executable_body, argument_id) orelse return false;
                    if (signature.c_abi) {
                        if (!mir.ValueType.eql(argument.result_ty, parameter_ty)) return false;
                    } else if (!self.executableMirTypeMatches(argument.result_ty, parameter_ty)) return false;
                }
            },
            // The syntax-free renderer performs the closed, typed admission
            // for builtin operations.  Re-rejecting the whole union here kept
            // even fully modelled pure builtins on the AST fallback path.
            .builtin_call => |call| {
                // The standalone renderer deliberately has no profile state.
                // Raw scalar accesses are therefore admitted here only when
                // no sanitizer instrumentation would be required; the legacy
                // path remains authoritative for instrumented builds.
                if ((call.kind == .raw_load or call.kind == .raw_store) and (self.ksan or self.msan or self.csan)) return false;
            },
            // The executable body carries and verifies the complete indirect
            // callable signature; no backend-side syntax recovery is needed.
            .indirect_call => {},
            .address_of => {
                switch (expression.result_ty) {
                    .pointer => {},
                    else => return false,
                }
            },
            else => {},
        };
        for (fn_mir.executable_body.places) |place| {
            switch (place.root) {
                .local, .value => {},
                .symbol => |id| {
                    const identity = mir_executable_body.symbol(&fn_mir.executable_body, id) orelse return false;
                    // Executable MIR global places are admitted against the
                    // checked global table.  In particular, const scalar
                    // Global declarations are admitted through checked facts.
                    if (identity.kind != .global or self.checkedGlobalType(identity.spelling) == null) return false;
                },
            }
            // The syntax-free executable-MIR renderer owns projection
            // admission.  Keep this integration check limited to roots that
            // the LLVM declaration registry can resolve instead of rebuilding
            // typed place semantics here.
        }
        return true;
    }

    fn checkedGlobalType(self: *const LlvmEmitter, spelling: []const u8) ?mir.ValueType {
        for (self.mir_module.checked_globals) |global| {
            const symbol = self.checkedGlobalSymbol(global) orelse continue;
            if (std.mem.eql(u8, symbol, spelling)) return global.ty;
        }
        return null;
    }

    fn mirFunctionByName(self: *const LlvmEmitter, name: []const u8) ?mir.Function {
        for (self.mir_module.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }

    fn mirFunctionByDefId(self: *const LlvmEmitter, def_id: mir.DefId) ?mir.Function {
        if (!def_id.isValid()) return null;
        for (self.mir_module.functions) |function| if (function.typed_def_id.eql(def_id)) return function;
        return null;
    }

    fn executableTargetAbi(self: *const LlvmEmitter) mir_executable_llvm.TargetAbi {
        return switch (self.target_arch) {
            .riscv64 => .riscv64,
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }

    fn executableMirTypeMatches(self: *LlvmEmitter, left: mir.ValueType, right: mir.ValueType) bool {
        if (mir.ValueType.eql(left, right)) return true;
        const left_type = self.mirStructuralType(left) orelse return false;
        const right_type = self.mirStructuralType(right) orelse return false;
        return std.mem.eql(u8, left_type, right_type);
    }

    fn executableFunctionParamType(self: *LlvmEmitter, function: mir.Function, param: lower_llvm_model.FnParam, index: usize) ![]const u8 {
        if (index >= function.param_types.len or !mir.ValueType.eql(param.value_ty, function.param_types[index]))
            return error.UnsupportedLlvmEmission;
        const executable_parameter = if (index < function.executable_body.parameters.len) function.executable_body.parameters[index] else null;
        if (executable_parameter) |value| {
            if (value.dyn_trait_symbol_id.isValid()) return "{ ptr, ptr }";
            return mir_executable_llvm.renderType(self.scratch.allocator(), &function.executable_body, param.value_ty, value.callable_signature) catch |err| switch (err) {
                error.Unsupported, error.InvalidBody => try self.llvmSignatureType(param.type_id),
                else => return err,
            };
        }
        if (param.value_ty == .value) return self.llvmSignatureType(param.type_id);
        return mir_executable_llvm.renderType(self.scratch.allocator(), &function.executable_body, param.value_ty, null) catch |err| switch (err) {
            error.Unsupported, error.InvalidBody => try self.llvmSignatureType(param.type_id),
            else => return err,
        };
    }

    fn buildExecutableDirectCallAbiPlan(self: *LlvmEmitter, fn_mir: mir.Function) !?mir_executable_llvm.CallAbiPlan {
        var direct_call_count: usize = 0;
        for (fn_mir.executable_body.expressions) |expression| switch (expression.operation) {
            .direct_call => direct_call_count += 1,
            else => {},
        };
        const entries = try self.scratch.allocator().alloc(mir_executable_llvm.DirectCallAbi, direct_call_count);
        var next: usize = 0;
        const target = self.executableTargetAbi();
        for (fn_mir.executable_body.expressions) |expression| switch (expression.operation) {
            .direct_call => |call| {
                const symbol = mir_executable_body.symbol(&fn_mir.executable_body, call.callee) orelse return null;
                const signature = self.mirFunctionByName(symbol.spelling) orelse return null;
                // Variadic calls still require default argument promotions and
                // remain on the qualified legacy path.  Do not weaken this
                // admission until those promotions are canonical MIR facts.
                if (signature.is_variadic or signature.param_count != call.argument_count or signature.param_types.len != call.argument_count) return null;
                if (signature.c_abi) {
                    if (!mir.ValueType.eql(signature.return_ty, expression.result_ty)) return null;
                } else if (!self.executableMirTypeMatches(signature.return_ty, expression.result_ty)) return null;
                var entry: mir_executable_llvm.DirectCallAbi = .{
                    .expression = expression.id,
                    .callee = call.callee,
                    .fixed_arity = call.argument_count,
                    .c_abi = signature.c_abi,
                    .result_callable_signature = signature.return_callable_signature,
                    .result_extension = if (signature.c_abi) mir_executable_llvm.abiExtension(target, expression.result_ty) else .none,
                };
                for (call.arguments[0..call.argument_count], signature.param_types, 0..) |argument_id, parameter_ty, index| {
                    const argument = mir_executable_body.expression(&fn_mir.executable_body, argument_id) orelse return null;
                    if (signature.c_abi) {
                        if (!mir.ValueType.eql(argument.result_ty, parameter_ty)) return null;
                    } else if (!self.executableMirTypeMatches(argument.result_ty, parameter_ty)) return null;
                    entry.parameter_extensions[index] = if (signature.c_abi) mir_executable_llvm.abiExtension(target, parameter_ty) else .none;
                }
                entries[next] = entry;
                next += 1;
            },
            else => {},
        };
        return .{
            .target = target,
            .function_return_callable_signature = fn_mir.return_callable_signature,
            .direct_calls = entries,
        };
    }

    const LlvmFunctionRenderMechanics = struct {
        attributes: []const u8,
        section: []const u8,
        alignment: []const u8,
        linkage: []const u8,
    };

    fn llvmFunctionRenderMechanics(self: *LlvmEmitter, attrs: codegen_attrs.FunctionRenderAttrs, exported: bool) !LlvmFunctionRenderMechanics {
        const base_attributes: []const u8 = if (attrs.naked and attrs.noinline_attr)
            " naked noinline"
        else if (attrs.naked)
            " naked"
        else if (attrs.noinline_attr)
            " noinline"
        else
            "";
        const attributes: []const u8 = if (self.linux_kernel and self.target_arch == .x86_64)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind fn_ret_thunk_extern", .{base_attributes})
        else if (self.linux_kernel and self.target_arch == .aarch64)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind \"branch-target-enforcement\"", .{base_attributes})
        else if (self.linux_kernel)
            try std.fmt.allocPrint(self.scratch.allocator(), "{s} nounwind", .{base_attributes})
        else
            base_attributes;
        return .{
            .attributes = attributes,
            .section = if (attrs.section) |section|
                try std.fmt.allocPrint(self.scratch.allocator(), " section \"{s}\"", .{section})
            else
                "",
            .alignment = if (attrs.effective_align) |alignment|
                try std.fmt.allocPrint(self.scratch.allocator(), " align {d}", .{alignment})
            else
                "",
            .linkage = if (attrs.weak) "weak " else if (!exported) "internal " else "",
        };
    }

    fn sameMirSourcePoint(a: mir.SourcePoint, b: mir.SourcePoint) bool {
        return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len;
    }

    fn sameMirSourceLocation(a: mir.SourcePoint, b: mir.SourcePoint) bool {
        return a.line == b.line and a.column == b.column;
    }

    fn spanFromMirSourcePoint(source: mir.SourcePoint) diagnostics.Span {
        return .{ .line = source.line, .column = @intCast(source.column), .offset = source.offset, .len = source.len, .file_id = source.file_id };
    }

    fn emitExternFunction(self: *LlvmEmitter, fact: mir.CallableEmissionFact) !void {
        const checked = self.checkedCallableFact(fact.def_id) orelse return error.UnsupportedLlvmEmission;
        const name = self.callableSymbol(fact) orelse return error.UnsupportedLlvmEmission;
        // The KASAN shadow hooks (D2.1) get weak no-op `define`s in emitTrapDecl so every
        // build links; skip the `declare` here to avoid an LLVM declare-vs-define clash.
        if (isKsanHook(name)) return;
        const fn_mir = self.mirFunctionByDefId(fact.def_id) orelse return error.UnsupportedLlvmEmission;
        if (!std.mem.eql(u8, name, fn_mir.name) or checked.kind != .extern_function) return error.UnsupportedLlvmEmission;
        if (!mir.ValueType.eql(checked.return_ty, fn_mir.return_ty)) return error.UnsupportedLlvmEmission;
        const ret_llvm = if (checked.return_ty == .value and fn_mir.return_callable_signature == null and !fn_mir.executable_body.return_dyn_trait_symbol_id.isValid())
            try self.llvmSignatureType(checked.signature_return_type_id)
        else
            mir_executable_llvm.renderType(self.scratch.allocator(), &fn_mir.executable_body, checked.return_ty, fn_mir.return_callable_signature) catch |err| switch (err) {
                error.Unsupported, error.InvalidBody => try self.llvmSignatureType(checked.signature_return_type_id),
                else => return err,
            };
        const sig = self.fn_sigs.get(name) orelse return error.UnsupportedLlvmEmission;
        const ret_ext = if (sig.c_abi) self.cAbiExtensionForSignature(checked.signature_return_type_id) else "";
        try self.out.print(self.allocator, "declare {s}{s} @{s}(", .{ ret_ext, ret_llvm, name });
        for (sig.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const param_ext = if (sig.c_abi) self.cAbiExtensionForSignature(param.type_id) else "";
            try self.out.appendSlice(self.allocator, try self.executableFunctionParamType(fn_mir, param, i));
            if (param_ext.len != 0) try self.out.print(self.allocator, " {s}", .{std.mem.trimEnd(u8, param_ext, " ")});
        }
        if (sig.is_variadic) {
            if (sig.params.len != 0) try self.out.appendSlice(self.allocator, ", ");
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

    fn nullablePayloadIsValueType(self: *LlvmEmitter, child: ast_bridge.TypeExpr) bool {
        const resolved = self.resolveAliasType(child);
        return switch (resolved.kind) {
            .name => |n| !std.mem.eql(u8, n.text, "c_void"),
            .qualified => |node| self.nullablePayloadIsValueType(node.child.*),
            else => false,
        };
    }

    fn emitMirAggregateReturnPointerFactConsumedComment(self: *LlvmEmitter, fact: mir.AggregateReturnPointerFact) !void {
        const caller = self.current_function orelse return;
        try self.out.print(
            self.allocator,
            "  ; mir aggregate_return_pointer consumed caller={s} callee={s} field={s} provenance={s} source={d}:{d}\n",
            .{ caller, fact.callee, fact.field_path, @tagName(fact.provenance), fact.source.line, fact.source.column },
        );
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

    fn emitBindThunks(self: *LlvmEmitter) !void {
        // Canonical executable MIR names the generated scalar-env thunk in the
        // closure-bind operation. Collect those module-scope definitions
        // mechanically before rendering the inventory; legacy body lowering
        // may already have registered additional entries in the same map.
        for (self.mir_module.functions) |function| {
            if (!function.executable_body.complete or function.executable_body.expressions.len == 0) continue;
            for (function.executable_body.expressions) |expression| switch (expression.operation) {
                .closure_bind => |bind| if (bind.capture_encoding == .integer) {
                    const target = executableClosureSymbol(&function.executable_body, bind.target) orelse
                        return error.UnsupportedLlvmEmission;
                    const code = executableClosureSymbol(&function.executable_body, bind.code) orelse
                        return error.UnsupportedLlvmEmission;
                    const sig = self.fn_sigs.get(target) orelse return error.UnsupportedLlvmEmission;
                    if (sig.params.len == 0 or sig.is_variadic) return error.UnsupportedLlvmEmission;
                    if (!self.bind_thunks.contains(code)) try self.bind_thunks.put(code, .{ .fname = target, .sig = sig });
                },
                else => {},
            };
        }
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

    fn executableClosureSymbol(body: *const mir.ExecutableBody, id: mir.SymbolId) ?[]const u8 {
        if (!id.isValid() or id.index() >= body.symbols.len) return null;
        const identity = body.symbols[id.index()];
        return if (identity.id.eql(id) and identity.kind == .function) identity.spelling else null;
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

    fn internCanonicalStringLiteral(self: *LlvmEmitter, bytes_value: []const u8) !StringLiteralGlobal {
        const bytes = try llvmCanonicalStringBytes(self.scratch.allocator(), bytes_value);
        const name = try std.fmt.allocPrint(self.scratch.allocator(), ".str.{d}", .{self.string_literals.items.len});
        const global: StringLiteralGlobal = .{
            .name = name,
            .escaped_bytes = bytes.escaped,
            .len = bytes.len,
        };
        try self.string_literals.append(self.allocator, global);
        return global;
    }

    fn internPlannedStringBacking(self: *LlvmEmitter, plan: mir.StringBytesInitializerPlan) !StringLiteralGlobal {
        for (self.string_literals.items) |global| {
            const backing_id = global.backing_id orelse continue;
            if (backing_id.eql(plan.backing_id)) return global;
        }
        const bytes = try llvmCanonicalStringBytes(self.scratch.allocator(), plan.bytes);
        const name = try std.fmt.allocPrint(self.scratch.allocator(), ".str.{d}", .{self.string_literals.items.len});
        const global: StringLiteralGlobal = .{
            .name = name,
            .escaped_bytes = bytes.escaped,
            .len = bytes.len,
            .backing_id = plan.backing_id,
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
        var debug_file_ids = std.StringHashMap(usize).init(self.allocator);
        defer debug_file_ids.deinit();
        try debug_file_ids.put(self.source_path, 1);
        for (self.debug_functions.items) |function| {
            if (debug_file_ids.contains(function.source_path)) continue;
            const id = self.debug_next_id;
            self.debug_next_id += 1;
            try debug_file_ids.put(function.source_path, id);
            const escaped_function_path = try escapedLlvmString(self.scratch.allocator(), function.source_path);
            try self.out.print(self.allocator, "!{d} = !DIFile(filename: \"{s}\", directory: \".\")\n", .{ id, escaped_function_path });
        }
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
            const file_id = debug_file_ids.get(function.source_path) orelse 1;
            try self.out.print(
                self.allocator,
                "!{d} = distinct !DISubprogram(name: \"{s}\", linkageName: \"{s}\", scope: !{d}, file: !{d}, line: {d}, type: !4, scopeLine: {d}, spFlags: DISPFlagDefinition, unit: !0)\n",
                .{ function.id, name, name, file_id, file_id, function.line, function.line },
            );
        }
        for (self.debug_locals.items) |local| {
            const ty = self.debugBasicType(local.ty) orelse continue;
            const type_id = debug_type_ids.get(ty.name) orelse continue;
            const name = try escapedLlvmString(self.scratch.allocator(), local.name);
            var local_file_id: usize = 1;
            for (self.debug_functions.items) |function| {
                if (function.id != local.scope) continue;
                local_file_id = debug_file_ids.get(function.source_path) orelse 1;
                break;
            }
            switch (local.kind) {
                .parameter => try self.out.print(
                    self.allocator,
                    "!{d} = !DILocalVariable(name: \"{s}\", arg: {d}, scope: !{d}, file: !{d}, line: {d}, type: !{d})\n",
                    .{ local.id, name, local.arg_index orelse 0, local.scope, local_file_id, local.line, type_id },
                ),
                .variable => try self.out.print(
                    self.allocator,
                    "!{d} = !DILocalVariable(name: \"{s}\", scope: !{d}, file: !{d}, line: {d}, type: !{d})\n",
                    .{ local.id, name, local.scope, local_file_id, local.line, type_id },
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
            else if (self.tagged_unions.get(name.text)) |union_info|
                try self.taggedUnionLlvmType(union_info.decl)
            else if (self.struct_types.get(name.text)) |struct_info|
                try self.structLlvmType(struct_info.decl)
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

    // Callable signatures are materialized from the module-owned
    // `SignatureTypeTable`, never by rebuilding an AST type.  Nominal names
    // may still consult the transitional type-declaration registry for their
    // representation; that is a type-declaration dependency, not a callable
    // syntax ingress.
    fn llvmSignatureType(self: *LlvmEmitter, id: mir.SignatureTypeId) ![]const u8 {
        const shape = signature_type_mechanics.shape(self.mir_module.signature_types, id) catch return error.UnsupportedLlvmEmission;
        return switch (shape) {
            .name => |name| self.llvmSignatureNameType(name),
            .enum_literal => error.UnsupportedLlvmEmission,
            .qualified => |node| self.llvmSignatureType(node.child),
            .pointer, .raw_many_pointer => "ptr",
            .slice => "{ ptr, i64 }",
            .array => |node| std.fmt.allocPrint(self.scratch.allocator(), "[{d} x {s}]", .{ node.length orelse return error.UnsupportedLlvmEmission, try self.llvmSignatureType(node.child) }),
            .nullable => |child| if (self.signatureTypeIsPointerLike(child))
                self.llvmSignatureType(child)
            else
                std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s} }}", .{try self.llvmSignatureType(child)}),
            .generic => |node| self.llvmSignatureGenericType(node.base, node.args),
            .fn_pointer => "ptr",
            .closure_type => "{ ptr, ptr }",
            // Dynamic dispatch is rejected by backend admission.  Do not
            // retain a second representation route here.
            .dyn_trait, .member => error.UnsupportedLlvmEmission,
        };
    }

    /// Shared one-way bridge for remaining legacy body mechanics.
    fn signatureTypeExpr(self: *LlvmEmitter, id: mir.SignatureTypeId, span: diagnostics.Span) anyerror!TransitionalTypeExpr {
        return signature_type_materializer.typeExpr(self.scratch.allocator(), self.mir_module.signature_types, id, span) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsupportedLlvmEmission,
        };
    }

    fn llvmSignatureNameType(self: *LlvmEmitter, name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never")) return "void";
        if (isOpaqueAddressTypeName(name)) return "i64";
        if (std.mem.eql(u8, name, "c_void") or std.mem.eql(u8, name, "IrqOff")) return "i8";
        if (std.mem.eql(u8, name, "cstr") or std.mem.eql(u8, name, "va_list")) return "ptr";
        if (std.mem.eql(u8, name, "bool")) return "i1";
        if (std.mem.eql(u8, name, "f32")) return "float";
        if (std.mem.eql(u8, name, "f64")) return "double";
        // Aliases and aggregates are module-level transitional
        // type artifacts.  They are intentionally not carried by FnSig.
        if (self.type_aliases.get(name)) |target| return self.llvmType(target);
        if (self.enum_types.get(name)) |decl| return self.llvmType(enumReprType(decl));
        if (self.packed_bits.get(name)) |info| return self.llvmType(info.repr);
        if (self.overlay_unions.get(name)) |info| return self.overlayLlvmType(info);
        if (self.tagged_unions.get(name)) |info| return self.taggedUnionLlvmType(info.decl);
        if (self.struct_types.get(name)) |info| return self.structLlvmType(info.decl);
        if (scalar_repr.integer(name)) |integer| return std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{integer.bits});
        if (libraryScalarLlvmType(name)) |ty| return ty;
        return error.UnsupportedLlvmEmission;
    }

    fn llvmSignatureGenericType(self: *LlvmEmitter, base: []const u8, args: []const mir.SignatureTypeId) ![]const u8 {
        if (std.mem.eql(u8, base, "Result") and args.len == 2) {
            const ok = if (try signature_type_mechanics.isVoid(self.mir_module.signature_types, args[0])) "i8" else try self.llvmSignatureType(args[0]);
            const err = if (try signature_type_mechanics.isVoid(self.mir_module.signature_types, args[1])) "i8" else try self.llvmSignatureType(args[1]);
            return std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s}, {s} }}", .{ ok, err });
        }
        if (std.mem.eql(u8, base, "atomic") and args.len == 1) return self.llvmSignatureType(args[0]);
        if (std.mem.eql(u8, base, "MaybeUninit") and args.len == 1) return self.llvmSignatureType(args[0]);
        if ((std.mem.eql(u8, base, "Reg") or std.mem.eql(u8, base, "RegBits")) and args.len >= 1) return self.llvmSignatureType(args[0]);
        if (std.mem.eql(u8, base, "MmioPtr") and args.len == 1) return "ptr";
        if (std.mem.eql(u8, base, "DmaBuf") and args.len == 2) return "i64";
        if (isPayloadDomainGenericName(base) and args.len == 1) return self.llvmSignatureType(args[0]);
        if (isOpaqueAddressGenericName(base) and args.len >= 1) return "i64";
        return error.UnsupportedLlvmEmission;
    }

    fn signatureTypeIsPointerLike(self: *LlvmEmitter, id: mir.SignatureTypeId) bool {
        const shape = signature_type_mechanics.shape(self.mir_module.signature_types, id) catch return false;
        return switch (shape) {
            .pointer, .raw_many_pointer, .fn_pointer => true,
            .qualified => |node| self.signatureTypeIsPointerLike(node.child),
            .name => |name| std.mem.eql(u8, name, "cstr"),
            .generic => |node| std.mem.eql(u8, node.base, "MmioPtr") or std.mem.eql(u8, node.base, "UserPtr") or std.mem.eql(u8, node.base, "PhysPtr"),
            else => false,
        };
    }

    fn resultLlvmType(self: *LlvmEmitter, ok_ty: TransitionalTypeExpr, err_ty: TransitionalTypeExpr) ![]const u8 {
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

    fn currentSourceParamUsesLlvmName(self: *LlvmEmitter, name: []const u8) bool {
        const params = self.current_params orelse return false;
        for (params) |param| if (std.mem.eql(u8, param.name, name)) return true;
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

    fn atomicStorageLlvmType(self: *LlvmEmitter, payload_ty: ast_bridge.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(payload_ty), "bool")) return "i8";
        return self.llvmType(payload_ty);
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

    fn taggedUnionLlvmType(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl) ![]const u8 {
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const storage_ty = try self.taggedUnionPayloadStorageType(layout);
        if (layout.padding_size == 0) {
            return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, {s} }}", .{storage_ty});
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, [{d} x i8], {s} }}", .{ layout.padding_size, storage_ty });
    }

    fn taggedUnionLayout(self: *LlvmEmitter, union_decl: ast_bridge.UnionDecl, depth: usize) ?TaggedUnionLayout {
        _ = depth;
        return if (self.tagged_unions.get(union_decl.name.text)) |info| info.layout else null;
    }

    fn taggedUnionPayloadStorageType(self: *LlvmEmitter, layout: TaggedUnionLayout) ![]const u8 {
        const bits = layout.payload_alignment * 8;
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i{d}]", .{ layout.storage_count, bits });
    }

    fn enumDeclForType(self: *LlvmEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.EnumDecl {
        return lower_llvm_lookup.enumDeclForType(&self.type_aliases, &self.enum_types, ty);
    }

    fn enumReprType(enum_decl: ast_bridge.EnumDecl) ast_bridge.TypeExpr {
        return enum_decl.repr orelse simpleType(enum_decl.name.span, "isize");
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
        const info = self.struct_types.get(struct_decl.name.text) orelse return null;
        const storage_alignment = info.storage_alignment orelse return null;
        const storage_size = info.storage_size orelse return null;
        if (!struct_decl.is_c_union or storage_alignment == 0 or storage_size == 0) return null;
        if (storage_alignment != 1 and storage_alignment != 2 and storage_alignment != 4 and storage_alignment != 8 and storage_alignment != 16) return null;
        if (storage_size % storage_alignment != 0) return null;
        return .{
            .count = @max(@as(usize, 1), storage_size / storage_alignment),
            .alignment = storage_alignment,
        };
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

    fn arrayLenValue(self: *LlvmEmitter, expr: ast_bridge.Expr) ?u64 {
        var env = self.reflectEnv();
        return lower_llvm_reflect.arrayLenValue(&env, expr);
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

fn spanFromSourcePoint(source: mir.SourcePoint) diagnostics.Span {
    return .{
        .offset = source.offset,
        .len = source.len,
        .line = source.line,
        .column = @intCast(source.column),
    };
}
