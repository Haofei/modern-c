const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const backend_cleanup = @import("backend_cleanup.zig");
const backend_mod = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const CodegenDeclArtifacts = declaration_artifacts.CodegenDeclarationArtifacts;
const CodegenFunctionBodyArtifacts = declaration_artifacts.CodegenFunctionBodyArtifacts;
const syntax_bridge = @import("syntax_bridge.zig");
const mir = @import("mir.zig");
const mir_nullable_control_plan = @import("mir_nullable_control_plan.zig");
const mir_nested_conditional_return_plan = @import("mir_nested_conditional_return_plan.zig");
const mir_aggregate_sequence_plan = @import("mir_aggregate_sequence_plan.zig");
const mir_workflow_plan = @import("mir_workflow_plan.zig");
const mir_alloca_hoist_plan = @import("mir_alloca_hoist_plan.zig");
const mir_access_plan = @import("mir_access_plan.zig");
const mir_statement_plan = @import("mir_statement_plan.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");
const mir_executable_c = @import("mir_executable_c.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_source_bridge = @import("mir_source_bridge.zig");
const type_bridge = @import("type_bridge.zig");
const switch_lower = @import("switch_lower.zig");
const fallback_census = @import("fallback_census.zig");
const TransitionalTypeExpr = @TypeOf(@as(mir.TargetTypeFact, undefined).target_ty);

const lower_c_type = @import("lower_c_type.zig");
const numeric = @import("numeric.zig");
const rawScalarSuffix = lower_c_type.rawScalarSuffix;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;
const signedCTypeForInner = lower_c_type.signedCTypeForInner;
const intTypeRange = lower_c_type.intTypeRange;
const isCReservedWord = lower_c_type.isCReservedWord;
const cPayloadFieldName = lower_c_type.cPayloadFieldName;
const floatCTypeName = lower_c_type.floatCTypeName;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const isCVoidType = lower_c_type.isCVoidType;
const isVoidType = lower_c_type.isVoidType;
const isBoolType = lower_c_type.isBoolType;

const lower_c_op = @import("lower_c_op.zig");
const isCheckedBinaryOp = lower_c_op.isCheckedBinaryOp;
const checkedHelperParts = lower_c_op.checkedHelperParts;
const satHelperParts = lower_c_op.satHelperParts;

const lower_c_atomic = @import("lower_c_atomic.zig");

// C emission model and helper modules used by the emitter implementation.
const lower_c_model = @import("lower_c_model.zig");
const codegen_attrs = @import("codegen_attrs.zig");
const lower_c_flow = @import("lower_c_flow.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_arith = @import("lower_c_arith.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_collect = @import("lower_c_collect.zig");
const lower_c_convert = @import("lower_c_convert.zig");
const lower_c_defs = @import("lower_c_defs.zig");
const lower_c_domain = @import("lower_c_domain.zig");
const lower_c_names = @import("lower_c_names.zig");
const lower_c_aggregate = @import("lower_c_aggregate.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_builtin_emit = @import("lower_c_builtin_emit.zig");
const lower_c_call = @import("lower_c_call.zig");
const lower_c_reflect = @import("lower_c_reflect.zig");
const lower_c_map = @import("lower_c_map.zig");
const lower_c_memory = @import("lower_c_memory.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_switch = @import("lower_c_switch.zig");
const lower_c_try = @import("lower_c_try.zig");
const lower_c_special = @import("lower_c_special.zig");
const lower_c_info = @import("lower_c_info.zig");
const lower_c_mmio = @import("lower_c_mmio.zig");
const lower_c_overlay = @import("lower_c_overlay.zig");
const lower_c_asm = @import("lower_c_asm.zig");
const lower_c_layout = @import("lower_c_layout.zig");
const lower_c_dispatch = @import("lower_c_dispatch.zig");
const LocalInfo = lower_c_model.LocalInfo;
const ArrayInfo = lower_c_model.ArrayInfo;
const AggregateEmitUnit = lower_c_model.AggregateEmitUnit;
const FnInfo = lower_c_model.FnInfo;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const ResultTrySequenceMode = lower_c_model.ResultTrySequenceMode;
const BindThunk = lower_c_model.BindThunk;
const TryReplacement = lower_c_model.TryReplacement;
const MmioReadReplacement = lower_c_model.MmioReadReplacement;
const SliceInfo = lower_c_model.SliceInfo;
const SliceAccess = lower_c_model.SliceAccess;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const OverlayFieldInfo = lower_c_model.OverlayFieldInfo;
const OverlayLayout = lower_c_model.OverlayLayout;
const ResultInfo = lower_c_model.ResultInfo;
const NullableRepresentation = lower_c_model.NullableRepresentation;
const ReflectEnv = lower_c_reflect.ReflectEnv;
const StructTypeStyle = lower_c_model.StructTypeStyle;
const MmioStruct = lower_c_model.MmioStruct;
const MmioAccess = lower_c_model.MmioAccess;
const GlobalInfo = lower_c_model.GlobalInfo;
const GlobalElementInfo = lower_c_model.GlobalElementInfo;
const GlobalAccess = lower_c_model.GlobalAccess;
const GlobalArrayElementAccess = lower_c_model.GlobalArrayElementAccess;
const isSourceSpan = mir_source_bridge.isSourceSpan;
const sourcePointFromOptionalSpan = mir_source_bridge.sourcePointFromOptionalSpan;

const exprContainsCall = lower_c_expr.exprContainsCall;
const resolvedArrayChildType = lower_c_shape.resolvedArrayChildType;
const overlayFieldLayoutForType = lower_c_shape.overlayFieldLayout;
const resultPayloadTypeForTag = lower_c_shape.resultPayloadTypeForTag;
const structFieldType = lower_c_shape.structFieldType;
const genericChildType = lower_c_shape.genericChildType;
const isVoidLiteralExpr = lower_c_shape.isVoidLiteralExpr;
const isPointerLikeGlobalType = lower_c_shape.isPointerLikeGlobalType;
const emitStaticCInitializer = lower_c_const.emitStaticCInitializer;
const staticCInitializer = lower_c_const.staticCInitializer;
const appendCIntLiteral = lower_c_const.appendCIntLiteral;
const appendCFloatLiteral = lower_c_const.appendCFloatLiteral;
const appendCComptimeFloat = lower_c_const.appendCComptimeFloat;
const appendCSignedIntValue = lower_c_const.appendCSignedIntValue;
const constIntValue = lower_c_const.constIntValue;
const constBinaryProvenNoOverflow = lower_c_const.constBinaryProvenNoOverflow;
const constArrayLenValue = lower_c_const.constArrayLenValue;
const cloneLocals = lower_c_access.cloneLocals;
const arrayElemsFieldForExpr = lower_c_access.arrayElemsFieldForExpr;
const localIndexElementType = lower_c_access.localIndexElementType;
const sliceAccessForExpr = lower_c_access.sliceAccessForExpr;
const packedBitsNameForExpr = lower_c_access.packedBitsNameForExpr;
const packedBitsGlobalBase = lower_c_access.packedBitsGlobalBase;
const packedBitsMaskLiteral = lower_c_access.packedBitsMaskLiteral;
const globalArrayElementAccess = lower_c_access.globalArrayElementAccess;
const appendLineDirective = lower_c_map.appendLineDirective;
const emitGlobalDecl = lower_c_global.emitGlobal;
const appendGlobalLoadExpr = lower_c_global.appendGlobalLoadExpr;
const appendGlobalStorePrefix = lower_c_global.appendGlobalStorePrefix;
const appendGlobalStoreSuffix = lower_c_global.appendGlobalStoreSuffix;
const appendGlobalStoreValue = lower_c_global.appendGlobalStoreValue;
const appendGlobalArrayElementStore = lower_c_global.appendGlobalArrayElementStore;
const appendGlobalArrayElementMemberStore = lower_c_global.appendGlobalArrayElementMemberStore;

const isUninitLiteral = syntax_bridge.isUninitLiteral;
const typeName = type_bridge.typeName;
const simpleNameType = type_bridge.simpleNameType;
const contractName = syntax_bridge.contractName;
const calleeIdentName = syntax_bridge.calleeIdentName;
const callExpr = syntax_bridge.callExpr;

const MirSubjectType = struct {
    target_ty: ast_bridge.TypeExpr,
    nullable_representation: ?NullableRepresentation = null,
};
const indexExpr = syntax_bridge.indexExpr;
const memberCallee = syntax_bridge.memberCallee;
const memberExpr = syntax_bridge.memberExpr;
const isStringLiteralTarget = type_bridge.isStringLiteralTarget;
const isMmioStructAbi = type_bridge.isMmioStructAbi;
const dynCalleeMethodName = syntax_bridge.dynCalleeMethodName;

pub fn appendLayoutAsserts(
    allocator: std.mem.Allocator,
    artifacts: CodegenDeclArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    struct_names: []const []const u8,
) anyerror!void {
    var emitter = CEmitter.init(allocator, out, typed_mir, null, null);
    defer emitter.deinit();
    try emitter.collectModule(artifacts, .empty);

    try out.appendSlice(allocator,
        \\/* GENERATED by `mcc emit-layout` — DO NOT EDIT. */
        \\/* MC's authoritative struct layouts (sizeof/offsetof). A C runtime that hand-mirrors */
        \\/* one of these structs includes this header; any layout drift is a compile error.    */
        \\#include <stddef.h>
        \\
    );

    try emitter.appendLayoutAssertsFor(struct_names);
}

pub fn appendStructDecls(
    allocator: std.mem.Allocator,
    artifacts: CodegenDeclArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    struct_names: []const []const u8,
) anyerror!void {
    var emitter = CEmitter.init(allocator, out, typed_mir, null, null);
    defer emitter.deinit();
    try emitter.collectModule(artifacts, .empty);

    try out.appendSlice(allocator,
        \\/* GENERATED by `mcc emit-c-struct` — DO NOT EDIT. */
        \\/* Full C definitions of MC's authoritative shared structs (single source of truth). */
        \\/* The MC struct is the ONLY declaration; this header is regenerated from it, so a C   */
        \\/* runtime that includes it can never drift from MC's layout (there is no hand copy).  */
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdalign.h>
        \\
        \\
    );

    try emitter.emitNamedStructDecls(struct_names);

    // Belt-and-suspenders: also assert the generated definitions against MC's computed layout.
    try out.appendSlice(allocator, "\n/* Layout cross-check (sizeof/offsetof) against MC's authoritative layout. */\n");
    // Non-fatal: a struct with a tagged-union/nullable/overlay field whose lowered
    // layout MC does not compute at comptime is skipped (with a comment) rather than
    // aborting the whole header — the struct *definition* above is always emitted.
    try emitter.appendLayoutAssertsForImpl(struct_names, false);
}

pub fn appendModuleMir(
    allocator: std.mem.Allocator,
    early_metadata: CodegenDeclArtifacts,
    function_bodies: CodegenFunctionBodyArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    source_path: ?[]const u8,
    ksan: bool,
    msan: bool,
    csan: bool,
    stub_asm: bool,
    reporter: ?*diagnostics.Reporter,
) anyerror!void {
    var emitter = CEmitter.init(allocator, out, typed_mir, source_path, reporter);
    emitter.ksan = ksan;
    emitter.msan = msan;
    emitter.csan = csan;
    emitter.stub_asm = stub_asm;
    try emitter.emitModule(early_metadata, function_bodies);
}

pub const CEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: std.heap.ArenaAllocator,
    globals: std.StringHashMap(GlobalInfo),
    codegen_artifacts: CodegenDeclArtifacts = CodegenDeclArtifacts.empty,
    function_bodies: CodegenFunctionBodyArtifacts = CodegenFunctionBodyArtifacts.empty,
    static_initializers: std.StringHashMap(ast_bridge.Expr),
    type_aliases: std.StringHashMap(ast_bridge.TypeExpr),
    functions: std.StringHashMap(FnInfo),
    // Source function name -> overridden object/backend symbol (`#[backend_name("Y")]`).
    // Emitted as a C `__asm__("Y")` label so the object symbol is renamed without touching
    // any C-level call site.
    backend_names: std.StringHashMap([]const u8),
    // `const fn` bodies and folded `const` global values, for folding comptime
    // const-fn calls / named constants in fixed-array lengths (section 22
    // comptime↔type feedback).
    const_fns: std.StringHashMap(eval.ComptimeFunction),
    const_globals: std.StringHashMap(eval.ComptimeValue),
    const_global_widths: std.StringHashMap(u16),
    const_global_domains: std.StringHashMap(eval.DomainWidth),
    comptime_declarations: ?eval.ComptimeDeclarations = null,
    structs: std.StringHashMap(ast_bridge.StructDecl),
    mmio_structs: std.StringHashMap(MmioStruct),
    packed_bits: std.StringHashMap(PackedBitsInfo),
    overlay_unions: std.StringHashMap(OverlayUnionInfo),
    tagged_unions: std.StringHashMap(ast_bridge.UnionDecl),
    enums: std.StringHashMap(ast_bridge.EnumDecl),
    array_types: std.StringHashMap(ArrayInfo),
    slice_types: std.StringHashMap(SliceInfo),
    result_types: std.StringHashMap(ResultInfo),
    // Value optionals `?T` (tagged repr), one typedef per payload type.
    opt_types: std.StringHashMap(lower_c_model.OptInfo),
    // Function-pointer signatures encountered, each emitted as a `typedef RET
    // (*name)(params);` so the name-in-the-middle C declarator works anywhere a
    // plain type name does.
    fn_ptr_types: std.StringHashMap(ast_bridge.TypeExpr),
    closure_types: std.StringHashMap(ast_bridge.TypeExpr),
    // `bind(scalar, f)` closures: the env is a non-pointer scalar that must be
    // widened through `uintptr_t` to fit the closure's `void *` env slot. Calling
    // `f` directly through the `(void *, ...)` code-pointer cast would be an ABI
    // mismatch (and a narrowing int-to-pointer warning), so each such `f` gets a
    // generated thunk `RET f__envthunk(void *env, P...){ return f((T)(uintptr_t)env, P...); }`
    // whose signature genuinely matches the slot. Keyed by thunk name.
    bind_thunks: std.StringHashMap(BindThunk),
    // Tier 2 trait objects. `trait_decls`: every `trait` by name (method sigs), so a
    // `*dyn Trait` knows its vtable layout and a dispatch resolves the slot. `impl_methods`:
    // (Trait,Type) → the mangled `Type__m` function names, in trait-method order, so the
    // rodata vtable initializer lists the right function pointers.
    trait_decls: std.StringHashMap(declaration_artifacts.TraitDeclArtifact),
    impl_methods: std.StringHashMap([]const ast_bridge.ImplTraitMethod),
    mir_module: *const mir.Module,
    source_path: ?[]const u8,
    reporter: ?*diagnostics.Reporter = null,
    // Sanitizer profile (D2.1/2.2/2.3). When set, ordinary (non-raw, non-global) scalar LOADS
    // through a struct field / array element are wrapped with the shadow hook via a comma
    // expression, so a UAF/OOB reached through a field or element is caught — matching the LLVM
    // backend. Global loads/stores are already instrumented inside the `mc_race_*` macro. All
    // false by default (no hook emitted).
    ksan: bool = false,
    msan: bool = false,
    csan: bool = false,
    // `--stub-asm` (test-only): replace each inline-asm block with a host-neutral stub so an
    // arch module's portable logic can be compiled/run host-natively. Default false → asm is
    // emitted verbatim (kernel/bare-metal builds unchanged).
    stub_asm: bool = false,
    // Set while emitting an assignment LHS (a store target / lvalue), so the field-LOAD shadow
    // hook is not spliced into a context where the result must remain assignable.
    suppress_load_hook: bool = false,
    current_function: ?[]const u8 = null,
    // Proven storage class per pointer-typed local, sourced from live MIR
    // pointer-provenance facts: .global_storage routes derefs through the
    // mc_race helpers; .local_storage is the positive locality proof that keeps
    // a deref PLAIN under the spec I.13 conservative default (absent/unknown
    // pointers lower race-tolerantly).
    mir_pointer_local_provenance: std.StringHashMap(mir.PointerProvenance),
    mir_pointer_array_elements: std.StringHashMap(mir.PointerProvenance),
    mir_aggregate_pointer_fields: std.StringHashMap(mir.PointerProvenance),
    // For a variadic function body: the name of the last NAMED parameter, which C's
    // `va_start(ap, last)` anchors on. Null outside a variadic function.
    current_variadic_last: ?[]const u8 = null,
    temp_index: usize,
    indent: usize,
    // Stack of enclosing loop ids and a counter, for lowering `break`/`continue`
    // as labeled `goto`s so they target the loop even through an intervening
    // `switch` (a C `break` inside a `switch` would otherwise break the switch).
    loop_ids: std.ArrayList(u32) = .empty,
    // G7: parallel to `loop_ids`; source label naming each enclosing loop (or
    // null), used to resolve labeled `break :outer` / `continue :outer`.
    loop_labels: std.ArrayList(?[]const u8) = .empty,
    next_loop_id: u32 = 0,
    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8), mir_module: *const mir.Module, source_path: ?[]const u8, reporter: ?*diagnostics.Reporter) CEmitter {
        return .{
            .allocator = allocator,
            .out = out,
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .globals = std.StringHashMap(GlobalInfo).init(allocator),
            .static_initializers = std.StringHashMap(ast_bridge.Expr).init(allocator),
            .type_aliases = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
            .functions = std.StringHashMap(FnInfo).init(allocator),
            .backend_names = std.StringHashMap([]const u8).init(allocator),
            .const_fns = std.StringHashMap(eval.ComptimeFunction).init(allocator),
            .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
            .const_global_widths = std.StringHashMap(u16).init(allocator),
            .const_global_domains = std.StringHashMap(eval.DomainWidth).init(allocator),
            .structs = std.StringHashMap(ast_bridge.StructDecl).init(allocator),
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
            .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
            .tagged_unions = std.StringHashMap(ast_bridge.UnionDecl).init(allocator),
            .enums = std.StringHashMap(ast_bridge.EnumDecl).init(allocator),
            .array_types = std.StringHashMap(ArrayInfo).init(allocator),
            .slice_types = std.StringHashMap(SliceInfo).init(allocator),
            .result_types = std.StringHashMap(ResultInfo).init(allocator),
            .opt_types = std.StringHashMap(lower_c_model.OptInfo).init(allocator),
            .fn_ptr_types = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
            .closure_types = std.StringHashMap(ast_bridge.TypeExpr).init(allocator),
            .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
            .trait_decls = std.StringHashMap(declaration_artifacts.TraitDeclArtifact).init(allocator),
            .impl_methods = std.StringHashMap([]const ast_bridge.ImplTraitMethod).init(allocator),
            .mir_module = mir_module,
            .source_path = source_path,
            .reporter = reporter,
            .mir_pointer_local_provenance = std.StringHashMap(mir.PointerProvenance).init(allocator),
            .mir_pointer_array_elements = std.StringHashMap(mir.PointerProvenance).init(allocator),
            .mir_aggregate_pointer_fields = std.StringHashMap(mir.PointerProvenance).init(allocator),
            .temp_index = 0,
            .indent = 0,
        };
    }

    pub fn deinit(self: *CEmitter) void {
        self.deinitFunctionCollections();
        self.deinitTypeCollections();
        self.deinitDeclCollections();
        self.deinitControlFlowState();
        self.deinitOwnedStringProvenanceMap(&self.mir_pointer_array_elements);
        self.deinitOwnedStringProvenanceMap(&self.mir_aggregate_pointer_fields);
        self.mir_pointer_local_provenance.deinit();
        self.scratch.deinit();
    }

    fn deinitFunctionCollections(self: *CEmitter) void {
        self.fn_ptr_types.deinit();
        self.closure_types.deinit();
        self.bind_thunks.deinit();
        self.trait_decls.deinit();
        {
            var it = self.impl_methods.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
        }
        self.impl_methods.deinit();
        self.functions.deinit();
        self.backend_names.deinit();
    }

    fn deinitTypeCollections(self: *CEmitter) void {
        self.opt_types.deinit();
        self.result_types.deinit();
        self.slice_types.deinit();
        self.array_types.deinit();
        self.enums.deinit();
        var packed_bits = self.packed_bits.valueIterator();
        while (packed_bits.next()) |bits| bits.fields.deinit();
        self.packed_bits.deinit();
        var overlay_unions = self.overlay_unions.valueIterator();
        while (overlay_unions.next()) |overlay_union| overlay_union.fields.deinit();
        self.overlay_unions.deinit();
        self.tagged_unions.deinit();
        var mmio_structs = self.mmio_structs.valueIterator();
        while (mmio_structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
        self.structs.deinit();
        self.type_aliases.deinit();
    }

    fn deinitDeclCollections(self: *CEmitter) void {
        self.const_global_widths.deinit();
        self.const_global_domains.deinit();
        self.const_fns.deinit();
        eval.deinitConstGlobals(self.allocator, &self.const_globals);
        self.static_initializers.deinit();
        self.globals.deinit();
    }

    fn deinitControlFlowState(self: *CEmitter) void {
        self.loop_ids.deinit(self.allocator);
        self.loop_labels.deinit(self.allocator);
    }

    fn collectModule(self: *CEmitter, early_metadata: CodegenDeclArtifacts, function_bodies: CodegenFunctionBodyArtifacts) anyerror!void {
        self.codegen_artifacts = early_metadata;
        self.function_bodies = function_bodies;
        self.setComptimeDeclarationsFromArtifacts(early_metadata);
        try self.collectEarlyDeclarationMetadata(early_metadata);
        try self.collectConstGlobals();
        try self.collectDeclArtifacts(early_metadata);
        try self.collectBindThunks();
    }

    pub fn setComptimeDeclarationsFromArtifacts(self: *CEmitter, artifacts: CodegenDeclArtifacts) void {
        self.comptime_declarations = eval.ComptimeDeclarations.fromCodegenArtifacts(artifacts);
    }

    pub fn collectEarlyDeclarationMetadata(self: *CEmitter, artifacts: CodegenDeclArtifacts) !void {
        // Pre-pass: collect const/comptime metadata and pre-register nominal type
        // names up front, so fixed-array lengths, reflection queries, and type-name
        // mangling resolve during the artifact-collection pass below. Const global
        // widths stay in this early pass because later type artifact collection can
        // consult the reflection environment.
        try eval.collectConstFunctionsFromDeclarations(eval.ComptimeDeclarations.fromCodegenArtifacts(artifacts), &self.const_fns);
        for (artifacts.decl_artifacts) |artifact| switch (artifact) {
            .global => |global| {
                const sig = global.signature;
                if (!sig.is_const) continue;
                const ty = sig.ty orelse continue;
                const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
                try self.const_global_widths.put(sig.name.text, bits);
            },
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .struct_decl => |struct_decl| if (!isMmioStructAbi(struct_decl)) try self.structs.put(struct_decl.name.text, struct_decl),
                .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.tagged_unions.put(union_decl.name.text, union_decl),
                else => {},
            },
            else => {},
        };
    }

    pub fn collectConstGlobals(self: *CEmitter) !void {
        var reflect_env = self.reflectEnv();
        const declarations = self.comptime_declarations orelse return error.UnsupportedCEmission;
        try eval.collectConstGlobalsFromDeclarationsWithOptions(self.allocator, declarations, &self.const_fns, &self.const_globals, .{
            .reflect = lower_c_reflect.comptimeReflectThunk,
            .reflect_ctx = &reflect_env,
            .domains = &self.const_global_domains,
        });
    }

    pub fn collectDeclArtifacts(self: *CEmitter, artifacts: CodegenDeclArtifacts) anyerror!void {
        for (artifacts.decl_artifacts) |artifact| switch (artifact) {
            .function => |function| try self.collectFunctionArtifact(function),
            .global => |global| try self.collectGlobalDeclArtifact(global),
            .trait_decl => |trait_decl| try self.trait_decls.put(trait_decl.facts.name.text, trait_decl),
            .impl_trait => |impl_trait| try self.collectImplTraitArtifact(impl_trait),
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .struct_decl => |struct_decl| try self.collectStructDeclArtifact(struct_decl),
                .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.collectTaggedUnion(union_decl),
                .packed_bits_decl => |packed_bits| try self.collectPackedBits(packed_bits),
                .overlay_union_decl => |overlay_union| try self.collectOverlayUnion(overlay_union),
            },
        };
    }

    fn collectGlobalDeclArtifact(self: *CEmitter, global: declaration_artifacts.GlobalArtifact) !void {
        const sig = global.signature;
        if (sig.ty) |ty| {
            var info = try self.globalInfoFromType(ty);
            info.is_const = sig.is_const;
            try self.globals.put(sig.name.text, info);
        }
        if (sig.ty) |ty| try self.collectTypeArtifacts(ty);
    }

    fn collectStructDeclArtifact(self: *CEmitter, struct_decl: ast_bridge.StructDecl) !void {
        if (isMmioStructAbi(struct_decl)) {
            try self.collectMmioStruct(struct_decl);
            return;
        }
        try self.structs.put(struct_decl.name.text, struct_decl);
        for (struct_decl.fields) |field| try self.collectTypeArtifacts(field.ty);
    }

    fn collectFunctionArtifact(self: *CEmitter, function: declaration_artifacts.FunctionArtifact) !void {
        const sig = function.signature;
        try self.functions.put(function.signature.name.text, .{ .params = sig.params, .return_type = sig.transitionalReturnType(), .is_extern = sig.is_extern, .is_variadic = sig.is_variadic, .error_from = sig.error_from });
        if (!function.signature.is_extern) if (function.signature.backend_name) |name| try self.backend_names.put(function.signature.name.text, name);
        try self.collectFunctionArtifactSliceTypes(function);
    }

    fn collectImplTraitArtifact(self: *CEmitter, impl_trait: declaration_artifacts.ImplTraitArtifact) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ impl_trait.facts.trait_name.text, impl_trait.facts.type_name.text });
        try self.impl_methods.put(key, impl_trait.facts.methods);
    }

    pub fn collectBindThunks(self: *CEmitter) anyerror!void {
        // MIR owns the `bind(env, f)` call inventory. The C backend only uses it
        // to predeclare scalar-env thunks before function bodies are emitted.
        for (self.mir_module.functions) |fn_mir| {
            if (fn_mir.is_extern) continue;
            for (fn_mir.bind_thunk_facts) |fact| try self.collectBindThunkFact(fact);
        }
    }

    fn emitModule(self: *CEmitter, early_metadata: CodegenDeclArtifacts, function_bodies: CodegenFunctionBodyArtifacts) anyerror!void {
        defer self.deinit();
        try self.collectModule(early_metadata, function_bodies);
        try self.emitTypePrelude();
        try self.emitFunctionDeclarations();
        try self.emitGeneratedDispatchArtifacts();
        try self.emitGlobalDefinitions();
        try self.emitFunctionDefinitions();
    }

    pub fn emitTypePrelude(self: *CEmitter) anyerror!void {
        try self.emitEnums();
        try self.emitPackedBitsTypes();
        try self.emitOverlayUnionTypes();
        try self.emitAggregateForwardDeclarations();
        // Slices lower to a struct with a pointer field, so the forward
        // declarations above suffice; emit them before the by-value aggregates
        // (a struct may embed a slice by value).
        try self.emitSliceTypes();
        // Function-pointer typedefs depend only on already-declared scalar/struct
        // types, and structs/params may reference them by name.
        try self.emitFnPtrTypes();
        try self.emitClosureTypes();
        // Tier 2 trait-object types: per object-safe trait, a `VT_Trait` vtable-struct
        // typedef and the `mc_dyn_Trait` fat-pointer typedef. The rodata vtable
        // INSTANCES are emitted later (after function forward declarations).
        try self.emitDynTraitTypes();
        try self.emitMmioStructTypes();
        // Arrays, structs, Result types, and tagged unions can embed one another
        // by value (`[N]S`, `struct { [N]S }`, `Result<S, E>`), so emit them in
        // dependency order rather than a fixed category order.
        // Value optionals `?T` join the dependency-ordered aggregate emission (a `?T`
        // typedef embeds its payload by value, and a struct/Result may embed a `?T`).
        try self.emitOrderedAggregates();
    }

    fn emitMmioStructTypes(self: *CEmitter) !void {
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .struct_decl => |struct_decl| {
                    if (self.mmio_structs.contains(struct_decl.name.text)) {
                        try lower_c_mmio.emitStruct(self.mmioStructEmitContext(), struct_decl);
                    }
                },
                else => {},
            },
            else => {},
        };
    }

    pub fn emitFunctionDeclarations(self: *CEmitter) anyerror!void {
        // Forward-declare every defined function up front so a call to a function
        // declared later in the (possibly import-merged) source resolves — MC
        // resolves calls module-wide, independent of declaration order.
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .function => |function| if (function.signature.is_extern) {
                // Extern prototypes must precede any function body that calls them;
                // an imported `extern fn` can be merged after its caller.
                try self.emitExternFunction(function);
            } else if (function.body_facts.has_definition) {
                try self.emitFunctionForwardDecl(function);
            },
            else => {},
        };
    }

    pub fn emitGeneratedDispatchArtifacts(self: *CEmitter) !void {
        // Env-widening thunks for scalar-env closures: emit after the function
        // forward declarations (the thunks call those functions) and before any
        // body that might `bind` through one.
        try lower_c_dispatch.emitBindThunks(self.dispatchContext(), &self.bind_thunks);
        // Rodata vtable instances: one `static const VT_Trait __vt_Type_Trait = {…}`
        // per `impl Trait for Type` of an object-safe trait. Emitted after the function
        // forward declarations the initializer references.
        try lower_c_dispatch.emitVtables(self.dispatchContext(), &self.impl_methods, &self.trait_decls);
    }

    pub fn emitGlobalDefinitions(self: *CEmitter) anyerror!void {
        // Emit every global before any function body. MC resolves names
        // module-wide regardless of declaration order, and import-merged sources
        // can place a function ahead of a global it reads (e.g. a `const` defined
        // in an imported module). Globals are simple `static` definitions, so
        // emitting them first satisfies C's declare-before-use without needing
        // forward declarations.
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .global => |global| try self.emitGlobal(global),
            else => {},
        };
    }

    pub fn emitFunctionDefinitions(self: *CEmitter) anyerror!void {
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
            const previous_source_path = self.source_path;
            self.source_path = self.sourcePathForSpan(function.signature.name.span);
            defer self.source_path = previous_source_path;
            const canonical_status = self.canonicalCensusStatus(&fn_mir);
            const canonical_detail = if (canonical_status == .producer_incomplete) mir_executable_body.incompleteReason(&fn_mir) else "";
            var selected_path: fallback_census.SelectedPath = .unsupported;
            if (try self.emitSimpleMirFunction(function, fn_mir, render_attrs, &selected_path)) {
                fallback_census.record(.c, .admitted, selected_path, canonical_status, canonical_detail, self.source_path, fn_mir);
                continue;
            } else if (self.function_bodies.legacyFunctionBody(fn_mir.name)) |body| {
                fallback_census.record(.c, .fallback, .ast_fallback, canonical_status, canonical_detail, self.source_path, fn_mir);
                try self.emitFunction(function, body, render_attrs);
            } else {
                fallback_census.record(.c, .unsupported, .unsupported, canonical_status, canonical_detail, self.source_path, fn_mir);
                return error.UnsupportedCEmission;
            }
        }
    }

    fn canonicalCensusStatus(self: *CEmitter, fn_mir: *const mir.Function) fallback_census.CanonicalStatus {
        if (!fallback_census.isEnabled()) return .producer_incomplete;
        if (!mir_executable_body.isComplete(fn_mir)) return .producer_incomplete;
        if (!mir_executable_c.canEmitBody(&fn_mir.executable_body)) return .renderer_unsupported;
        if (!self.mirExecutableBodySupported(fn_mir)) return .ingress_mismatch;
        return .ready;
    }

    fn functionArtifactIndexByName(self: *const CEmitter, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.codegen_artifacts.decl_artifacts.len) : (i += 1) {
            switch (self.codegen_artifacts.decl_artifacts[i]) {
                .function => |function| if (std.mem.eql(u8, function.signature.name.text, name)) return i,
                else => {},
            }
        }
        return null;
    }

    fn emitGlobal(self: *CEmitter, global: declaration_artifacts.GlobalArtifact) !void {
        const previous_function = self.current_function;
        const previous_source_path = self.source_path;
        self.current_function = global.signature.name.text;
        self.source_path = self.sourcePathForSpan(global.signature.name.span);
        defer {
            self.current_function = previous_function;
            self.source_path = previous_source_path;
        }
        try emitGlobalDecl(self.globalEmitContext(), global);
    }

    fn sourcePathForSpan(self: *const CEmitter, span: diagnostics.Span) ?[]const u8 {
        if (span.file_id != diagnostics.invalid_file_id) {
            if (self.reporter) |reporter| if (reporter.pathForFileId(span.file_id)) |path| return path;
        }
        return self.source_path;
    }

    // Fold a `const` global initializer to its C constant text (section 22).
    fn constGlobalCValue(self: *CEmitter, expr: ast_bridge.Expr, ty: ?ast_bridge.TypeExpr) !?[]const u8 {
        const value = self.foldConstGlobalValue(expr, ty) orelse return null;
        return switch (value) {
            // Values above the signed-64 range need an unsigned suffix, or C
            // reads the decimal literal as implicitly unsigned (a warning).
            .int => |n| blk: {
                var text: std.ArrayList(u8) = .empty;
                try appendCSignedIntValue(self.scratch.allocator(), &text, n);
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .uint => |n| blk: {
                var text: std.ArrayList(u8) = .empty;
                try lower_c_const.appendCIntValue(self.scratch.allocator(), &text, n);
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .boolean => |b| if (b) "1" else "0",
            .float => |f| blk: {
                var text: std.ArrayList(u8) = .empty;
                try appendCComptimeFloat(self.scratch.allocator(), &text, f, f.width == 32);
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            // Aggregate / byte-string const globals are not lowered to a C scalar here.
            .void, .tag, .bytes, .array, .@"struct" => null,
        };
    }

    fn emitConstGlobalInitializer(self: *CEmitter, ty: ast_bridge.TypeExpr, expr: ast_bridge.Expr) !bool {
        if (syntax_bridge.callExpr(expr)) |call| {
            if (self.mirHasCallTargetKindAt(.atomic_init, call.callee.*.span)) {
                try self.out.appendSlice(self.allocator, " = ");
                try self.emitExprWithTarget(expr, null, ty);
                return true;
            }
        }
        const value = self.foldConstGlobalValue(expr, ty) orelse return false;
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitComptimeValueInitializer(value, ty);
        return true;
    }

    fn foldConstGlobalValue(self: *CEmitter, expr: ast_bridge.Expr, expected_ty: ?ast_bridge.TypeExpr) ?eval.ComptimeValue {
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

    fn seedConstFoldScope(self: *CEmitter, scope: *eval.ComptimeScope, reflect_env: *ReflectEnv) bool {
        scope.funcs = &self.const_fns;
        scope.declarations = self.comptime_declarations;
        scope.globals = &self.const_globals;
        scope.global_domains = &self.const_global_domains;
        scope.reflect = lower_c_reflect.comptimeReflectThunk;
        scope.reflect_ctx = reflect_env;
        var widths = self.const_global_widths.iterator();
        while (widths.next()) |entry| scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*) catch return false;
        return true;
    }

    fn reflectEnv(self: *CEmitter) ReflectEnv {
        return .{
            .type_aliases = &self.type_aliases,
            .structs = &self.structs,
            .enums = &self.enums,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .const_fns = &self.const_fns,
            .const_globals = &self.const_globals,
        };
    }

    fn reflectEmitContext(self: *CEmitter) lower_c_reflect.EmitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .enums = &self.enums,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .mmio_structs = &self.mmio_structs,
            .type_ctx = self,
            .c_type = cTypeForReflect,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn cTypeForReflect(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn comptimeSizeOf(self: *CEmitter, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_c_reflect.comptimeSizeOf(&env, ty, depth);
    }

    fn emitComptimeValueInitializer(self: *CEmitter, value: eval.ComptimeValue, target_ty: ast_bridge.TypeExpr) anyerror!void {
        const resolved = self.resolveAliasType(target_ty);
        switch (value) {
            .int => |n| try self.emitComptimeIntInitializer(n),
            .uint => |n| try lower_c_const.appendCIntValue(self.allocator, self.out, n),
            .boolean => |b| try self.out.appendSlice(self.allocator, if (b) "1" else "0"),
            .tag => |tag| {
                const enum_name = self.enumNameForType(resolved) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "{s}_{s}", .{ enum_name, tag });
            },
            .array => |items| try self.emitComptimeArrayInitializer(items, resolved),
            .@"struct" => |fields| try self.emitComptimeStructInitializer(fields, resolved),
            .float => |f| try appendCComptimeFloat(self.allocator, self.out, f, switch (resolved.kind) {
                .name => |name| std.mem.eql(u8, name.text, "f32"),
                else => false,
            }),
            // A byte-string ComptimeValue baked as a C initializer is not yet supported.
            .void, .bytes => return error.UnsupportedCEmission,
        }
    }

    fn emitComptimeArrayInitializer(self: *CEmitter, items: []const eval.ComptimeValue, resolved: ast_bridge.TypeExpr) anyerror!void {
        const child_ty = resolvedArrayChildType(resolved) orelse return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, "{ .elems = { ");
        for (items, 0..) |item, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitComptimeValueInitializer(item, child_ty);
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitComptimeStructInitializer(self: *CEmitter, fields: []const eval.ComptimeStructField, resolved: ast_bridge.TypeExpr) anyerror!void {
        const struct_decl = self.structDeclForResolvedTarget(resolved) orelse return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, "{ ");
        for (fields, 0..) |field, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const field_ty = structFieldType(struct_decl, field.name) orelse return error.UnsupportedCEmission;
            try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(field.name)});
            try self.emitComptimeValueInitializer(field.value, field_ty);
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn emitComptimeIntInitializer(self: *CEmitter, n: i128) !void {
        try appendCSignedIntValue(self.allocator, self.out, n);
    }

    fn nextTempName(self: *CEmitter) ![]const u8 {
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        return temp_name;
    }

    fn isAggregateGlobalType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return lower_c_info.isAggregateGlobalType(self.infoContext(), ty);
    }

    fn emitEnums(self: *CEmitter) !void {
        try lower_c_defs.emitEnums(self.defsContext(), &self.enums);
    }

    fn emitEnumType(self: *CEmitter, enum_decl: ast_bridge.EnumDecl) !void {
        try lower_c_defs.emitEnumType(self.defsContext(), enum_decl);
    }

    fn emitPackedBitsTypes(self: *CEmitter) !void {
        try lower_c_defs.emitPackedBitsTypes(self.defsContext(), &self.packed_bits);
    }

    fn emitOverlayUnionTypes(self: *CEmitter) !void {
        try lower_c_defs.emitOverlayUnionTypes(self.defsContext(), &self.overlay_unions);
    }

    fn emitOverlayUnionType(self: *CEmitter, name: []const u8, info: OverlayUnionInfo) !void {
        try lower_c_defs.emitOverlayUnionType(self.defsContext(), name, info);
    }

    fn emitTaggedUnionType(self: *CEmitter, union_decl: ast_bridge.UnionDecl) !void {
        try lower_c_defs.emitTaggedUnionType(self.defsContext(), union_decl);
    }

    fn emitEnumCaseValue(self: *CEmitter, value: ast_bridge.Expr) !void {
        switch (value.kind) {
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .char_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .grouped => |inner| try self.emitEnumCaseValue(inner.*),
            // Negative discriminants for signed-repr enums (`negative = -1`).
            .unary => |node| {
                if (node.op != .neg) return self.unsupportedEnumValue(value);
                try self.out.appendSlice(self.allocator, "-");
                try self.emitEnumCaseValue(node.expr.*);
            },
            else => return self.unsupportedEnumValue(value),
        }
    }

    fn unsupportedEnumValue(self: *CEmitter, value: ast_bridge.Expr) !void {
        try self.out.print(self.allocator, "/* unsupported enum value: {s} */0", .{@tagName(value.kind)});
        return error.UnsupportedCEmission;
    }

    // Forward-declare every user struct and tagged-union as an incomplete
    // typedef so that container types emitted earlier (e.g. a slice
    // `[]const T` lowering to a struct with a `T *` field) can name `T` before
    // its full definition appears. C11 permits the later redundant
    // `typedef struct T { ... } T;`. Pointer references only need this forward
    // declaration; by-value embedding still relies on definition ordering.
    fn emitAggregateForwardDeclarations(self: *CEmitter) !void {
        var emitted = false;
        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .struct_decl => |struct_decl| {
                    if (!self.structs.contains(struct_decl.name.text)) continue;
                    // A `#[c_union]` is a real C `union`; its forward tag must
                    // match its definition tag (`typedef union U U;`), not the
                    // default `struct`.
                    const keyword: []const u8 = if (struct_decl.is_c_union) "union" else "struct";
                    try self.out.print(self.allocator, "typedef {s} {s} {s};\n", .{ keyword, struct_decl.name.text, struct_decl.name.text });
                    emitted = true;
                },
                .union_decl => |union_decl| {
                    if (!self.tagged_unions.contains(union_decl.name.text)) continue;
                    try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ union_decl.name.text, union_decl.name.text });
                    emitted = true;
                },
                else => {},
            },
            else => {},
        };
        {
            var it = self.array_types.valueIterator();
            while (it.next()) |array| {
                try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ array.name, array.name });
                emitted = true;
            }
        }
        {
            var it = self.result_types.valueIterator();
            while (it.next()) |result| {
                try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ result.name, result.name });
                emitted = true;
            }
        }
        if (emitted) try self.out.appendSlice(self.allocator, "\n");
    }

    // Emit `_Static_assert(sizeof/offsetof == ...)` lines for every named struct against MC's
    // authoritative computed layout. Shared by `appendLayoutAsserts` (A1: assert a hand-written C
    // mirror) and `appendStructDecls` (A2: belt-and-suspenders check of the generated definitions),
    // which previously duplicated this loop verbatim. `collectModule` must have run first.
    fn appendLayoutAssertsFor(self: *CEmitter, struct_names: []const []const u8) !void {
        return self.appendLayoutAssertsForImpl(struct_names, true);
    }

    /// Same as `appendLayoutAssertsFor` but, when `fatal` is false, a struct whose
    /// comptime layout cannot be resolved (e.g. it has a tagged-union, nullable `?T`,
    /// or overlay-union field whose lowered layout MC does not compute at comptime) is
    /// SKIPPED with an explanatory comment instead of aborting. The struct *definition*
    /// is emitted regardless by `emitNamedStructDecls`; skipping only the belt-and-
    /// suspenders `_Static_assert` keeps the header compiling rather than emitting no
    /// header at all. The authoritative A1 `emit-layout` path keeps `fatal = true`, so
    /// genuine drift on resolvable structs is still a hard error.
    fn appendLayoutAssertsForImpl(self: *CEmitter, struct_names: []const []const u8, fatal: bool) !void {
        try lower_c_layout.appendLayoutAsserts(self.layoutAssertContext(), struct_names, fatal);
    }

    // A2: emit the full C definitions of just the named structs and the by-value aggregates they
    // transitively embed (nested structs + the `mc_array_*` wrappers MC arrays lower to), in
    // dependency order. Used by the standalone `emit-c-struct` header so a runtime can include the
    // generated definitions instead of hand-mirroring them. `collectModule` must have run first
    // (it populates `self.structs` and `self.array_types`). Pointer references between the named
    // structs (e.g. `Virtq.desc: *mut DescTable`) are covered by forward declarations; every named
    // pointee here is itself a requested struct, so its definition is emitted too.
    fn emitNamedStructDecls(self: *CEmitter, struct_names: []const []const u8) !void {
        const arena = self.scratch.allocator();
        var units: std.ArrayList(AggregateEmitUnit) = .empty;
        defer units.deinit(arena);
        var scalar_deps: std.ArrayList([]const u8) = .empty;
        defer scalar_deps.deinit(arena);

        try self.collectNamedStructClosure(struct_names, &units, &scalar_deps);
        try self.emitNamedStructScalarDeps(scalar_deps.items);
        try self.emitNamedAggregateForwardDecls(units.items);
        try self.emitAggregateUnitsInDependencyOrder(units.items);
    }

    fn collectNamedStructClosure(self: *CEmitter, struct_names: []const []const u8, units: *std.ArrayList(AggregateEmitUnit), scalar_deps: *std.ArrayList([]const u8)) !void {
        const arena = self.scratch.allocator();
        var seen = std.StringHashMap(void).init(arena);
        defer seen.deinit();

        // Build the transitive closure of by-value aggregate units reachable from the named
        // structs. A struct's `mc_array_*` field wrappers were registered in `self.array_types`
        // during `collectModule`; nested structs are looked up by name in `self.structs`.
        for (struct_names) |name| {
            const struct_decl = self.structs.get(name) orelse return error.LayoutStructNotFound;
            try lower_c_aggregate.collectStructClosure(self.aggregateDepContext(), arena, struct_decl, units, &seen, scalar_deps);
        }
    }

    fn emitNamedStructScalarDeps(self: *CEmitter, scalar_deps: []const []const u8) !void {
        // Emit the referenced scalar named-type definitions (enum / packed-bits / overlay union)
        // up front: structs in the closure reference them by name. `cTypeFor` emits these by
        // NAME, so their typedef must precede the generated structs.
        for (scalar_deps) |name| {
            if (self.enums.get(name)) |enum_decl| {
                try self.emitEnumType(enum_decl);
            } else if (self.packed_bits.getEntry(name)) |entry| {
                try self.out.print(self.allocator, "typedef {s} {s};\n\n", .{ entry.value_ptr.repr_c_type, entry.key_ptr.* });
            } else if (self.overlay_unions.getEntry(name)) |entry| {
                try self.emitOverlayUnionType(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    fn emitNamedAggregateForwardDecls(self: *CEmitter, units: []const AggregateEmitUnit) !void {
        // Forward-declare every struct AND tagged union in the closure so pointer fields (and
        // recursive references) resolve regardless of definition order.
        for (units) |unit| {
            switch (unit) {
                .struct_decl => |s| try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ s.name.text, s.name.text }),
                .tagged_union => |u| try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ u.name.text, u.name.text }),
                else => {},
            }
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    // Emit arrays, structs, Result types, and tagged unions in dependency
    // order: a unit is emitted once every aggregate it embeds *by value* has
    // been emitted. Pointer/slice references are covered by the forward
    // declarations and need no ordering. For valid (acyclic) programs this
    // terminates; a defensive fallback emits any stragglers to stay complete.
    fn emitOrderedAggregates(self: *CEmitter) !void {
        const arena = self.scratch.allocator();
        var units: std.ArrayList(AggregateEmitUnit) = .empty;
        defer units.deinit(arena);

        for (self.codegen_artifacts.decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .struct_decl => |s| if (self.structs.contains(s.name.text)) try units.append(arena, .{ .struct_decl = s }),
                .union_decl => |u| if (self.tagged_unions.contains(u.name.text)) try units.append(arena, .{ .tagged_union = u }),
                else => {},
            },
            else => {},
        };
        {
            var it = self.array_types.valueIterator();
            while (it.next()) |a| try units.append(arena, .{ .array = a.* });
        }
        {
            var it = self.result_types.valueIterator();
            while (it.next()) |r| try units.append(arena, .{ .result = r.* });
        }
        {
            var it = self.opt_types.valueIterator();
            while (it.next()) |o| try units.append(arena, .{ .opt = o.* });
        }

        try self.emitAggregateUnitsInDependencyOrder(units.items);
    }

    fn emitAggregateUnitsInDependencyOrder(self: *CEmitter, units: []const AggregateEmitUnit) !void {
        try lower_c_aggregate.emitUnitsInDependencyOrder(
            self.aggregateDepContext(),
            self.scratch.allocator(),
            units,
            self,
            emitAggregateUnitFromContext,
        );
    }

    fn emitAggregateUnit(self: *CEmitter, unit: AggregateEmitUnit) !void {
        switch (unit) {
            .struct_decl => |s| try self.emitStruct(s),
            .array => |a| try self.emitArrayType(a),
            .result => |r| try self.emitResultType(r),
            .tagged_union => |u| try self.emitTaggedUnionType(u),
            .opt => |o| try lower_c_defs.emitOptType(self.defsContext(), o),
        }
    }

    fn emitAggregateUnitFromContext(ctx: *anyopaque, unit: AggregateEmitUnit) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAggregateUnit(unit);
    }

    fn aggregateDepContext(self: *CEmitter) lower_c_aggregate.DepContext {
        return .{
            .type_aliases = &self.type_aliases,
            .structs = &self.structs,
            .tagged_unions = &self.tagged_unions,
            .enums = &self.enums,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .array_types = &self.array_types,
            .name_ctx = self,
            .name_for_type = aggregateDepNameForType,
        };
    }

    fn aggregateEmitContext(self: *CEmitter) lower_c_aggregate.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .type_aliases = &self.type_aliases,
            .structs = &self.structs,
            .tagged_unions = &self.tagged_unions,
            .packed_bits = &self.packed_bits,
            .emit_ctx = self,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_unchecked_add_value_temp = emitSequencedValueTempForAggregate,
            .operand_emit_type = operandEmitTypeForAggregate,
            .global_assignment_target = globalAssignmentTargetForAggregate,
            .emit_assign_target = emitAssignTargetForAggregate,
            .c_type = cTypeForCall,
            .c_ident = cIdentForMemory,
        };
    }

    fn aggregateDepNameForType(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitStruct(self: *CEmitter, struct_decl: ast_bridge.StructDecl) !void {
        try lower_c_defs.emitStruct(self.defsContext(), struct_decl);
    }

    fn emitSliceTypes(self: *CEmitter) !void {
        try lower_c_defs.emitSliceTypes(self.defsContext(), &self.slice_types);
    }

    // C has no `void` struct member, so a `Result<void, E>` (or `Result<T, void>`)
    // payload uses a 1-byte placeholder. The unit value `()` lowers to `0`, so
    // `.payload.ok = 0` stays well-formed.
    fn resultPayloadCType(self: *CEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        if (isVoidType(self.resolveAliasType(ty))) return "unsigned char";
        return try self.cTypeFor(ty, .typedef_name);
    }

    fn emitResultType(self: *CEmitter, result: ResultInfo) !void {
        try lower_c_defs.emitResultType(self.defsContext(), result);
    }

    fn emitArrayType(self: *CEmitter, array: ArrayInfo) !void {
        try lower_c_defs.emitArrayType(self.defsContext(), array);
    }

    fn emitFunctionPrototype(self: *CEmitter, function: anytype) !void {
        try self.emitFunctionSignature(function.signature, false, true);
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    // Forward declaration for a *defined* function, matching the definition's
    // storage class (non-exported functions are `static`) so the prototype and
    // body agree.
    fn emitFunctionForwardDecl(self: *CEmitter, function: anytype) !void {
        try self.emitFunctionSignature(function.signature, !function.signature.exported, true);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitExternFunction(self: *CEmitter, function: anytype) !void {
        try self.emitFunctionPrototype(function);
    }

    fn emitFunction(self: *CEmitter, function: anytype, body: ast_bridge.Block, attrs: codegen_attrs.FunctionRenderAttrs) anyerror!void {
        try self.writeLineDirective(function.signature.name.span);
        try self.emitFunctionRenderAttrs(attrs);
        if (attrs.naked) {
            try self.emitNakedFunction(function, body);
            return;
        }
        try self.emitFunctionBody(function, body);
    }

    fn emitNakedFunction(self: *CEmitter, function: anytype, body: ast_bridge.Block) !void {
        try self.emitFunctionSignature(function.signature, !function.signature.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");
        try self.emitNakedAsmBody(body);
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitFunctionBody(self: *CEmitter, function: anytype, body: ast_bridge.Block) anyerror!void {
        const sig = function.signature;
        try self.emitFunctionSignature(sig, !sig.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");

        const previous_function = self.current_function;
        self.current_function = sig.name.text;
        defer self.current_function = previous_function;
        try self.validateFunctionCleanupAuthority();
        self.mir_pointer_local_provenance.clearRetainingCapacity();
        self.clearOwnedStringProvenanceMapRetainingCapacity(&self.mir_pointer_array_elements);
        self.clearOwnedStringProvenanceMapRetainingCapacity(&self.mir_aggregate_pointer_fields);

        const previous_variadic_last = self.current_variadic_last;
        self.current_variadic_last = functionVariadicLastParam(sig);
        defer self.current_variadic_last = previous_variadic_last;

        var locals = try self.functionParamLocals(sig.params);
        defer locals.deinit();
        try self.emitIndentedFunctionBlock(body, &locals, sig.transitionalReturnType());
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn functionVariadicLastParam(fn_decl: anytype) ?[]const u8 {
        if (!fn_decl.is_variadic or fn_decl.params.len == 0) return null;
        return fn_decl.params[fn_decl.params.len - 1].name.text;
    }

    fn functionParamLocals(self: *CEmitter, params: []const codegen_attrs.FunctionParamFact) !std.StringHashMap(LocalInfo) {
        var locals = std.StringHashMap(LocalInfo).init(self.allocator);
        errdefer locals.deinit();
        for (params) |param| try locals.put(param.name.text, try self.localInfoFromType(param.ty));
        return locals;
    }

    const SimpleMirReturn = union(enum) {
        void,
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        checked_integer_literal: []const u8,
        float_literal: SimpleMirFloatLiteral,
        bool_literal: bool,
        enum_literal: SimpleMirEnumLiteral,
        null_literal: SimpleMirNullLiteral,
        global_load: []const u8,
        global_address: []const u8,
        nested_call: SimpleMirNestedCall,
        direct_call: SimpleMirDirectCall,
        local_init_call_return: SimpleMirLocalInitCallReturn,
        result_constructor: SimpleMirResultConstructorReturn,
        explicit_cast_return: SimpleMirExplicitCastReturn,
        conversion_return: SimpleMirConversionReturn,
        wrapping_binary: SimpleMirWrappingBinary,
        plain_float_binary: SimpleMirPlainFloatBinary,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
        struct_literal: SimpleMirStructLiteralReturn,
        array_literal: SimpleMirArrayLiteralReturn,
        aggregate_return_pointer_load: SimpleMirAggregateReturnPointerLoad,
        scalar_deref_load: SimpleMirScalarDerefLoad,
        scalar_field_load: SimpleMirScalarFieldLoad,
        plain_unary: SimpleMirPlainUnary,
    };

    // `return r.a` for a scalar field `a` of the struct a bare param pointer `r`
    // points at, lowered through the race-tolerant load of `&(r->a)`.
    const SimpleMirScalarFieldLoad = struct {
        param_name: []const u8,
        field_name: []const u8,
        field_ty: mir.ValueType,
    };

    // `return ~a` / `return -a` for a non-trapping unary op (bitwise not; wrapping
    // negate). `op_c` is the C/LLVM-independent spelling ("~" or "-").
    const SimpleMirPlainUnary = struct {
        op_c: []const u8,
        operand: SimpleMirArg,
    };

    // `return p.*` for a scalar pointee of a bare param pointer `p`, lowered
    // through the race-tolerant load helper (matching the fallback's default,
    // conservative-provenance rendering).
    const SimpleMirScalarDerefLoad = struct {
        param_name: []const u8,
        pointee_ty: mir.ValueType,
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

    const SimpleMirNullLiteral = struct {
        fact: mir.TargetTypeFact,
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

    const SimpleMirLoopReturn = struct {
        condition: SimpleMirCondition,
        body_block_index: usize,
        after_block_index: usize,
    };

    const max_simple_mir_switch_arms = 8;

    const SimpleMirEnumSwitchArmReturn = struct {
        case_name: []const u8,
        value: SimpleMirConditionalValue,
        span: diagnostics.Span,
    };

    const SimpleMirEnumSwitchReturn = struct {
        subject_name: []const u8,
        enum_name: []const u8,
        arms: [max_simple_mir_switch_arms]SimpleMirEnumSwitchArmReturn = undefined,
        arm_count: usize = 0,
    };

    const SimpleMirLoopVoidBody = struct {
        condition: SimpleMirCondition,
        body_block_index: usize,
        body_returns: bool = false,
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
        float_literal: SimpleMirFloatLiteral,
        bool_literal: bool,
        enum_literal: SimpleMirEnumLiteral,
        global_load: []const u8,
        global_address: []const u8,
        direct_call: SimpleMirDirectCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
        null_literal: SimpleMirNullLiteral,
        struct_literal: SimpleMirStructLiteralReturn,
        array_literal: SimpleMirArrayLiteralReturn,
    };

    const SimpleMirParamField = struct {
        param_name: []const u8,
        field_name: []const u8,
        field_index: usize,
    };

    const SimpleMirAggregateReturnPointerLoad = struct {
        call: SimpleMirDirectCall,
        fact: mir.AggregateReturnPointerFact,
        pointee_ty: mir.ValueType,
    };

    const max_simple_mir_call_args = 8;
    const max_simple_mir_struct_fields = 8;
    const max_simple_mir_array_items = 8;

    const SimpleMirStructLiteralField = struct {
        name: []const u8,
        value: SimpleMirCallArg,
    };

    const SimpleMirStructLiteralReturn = struct {
        type_name: []const u8,
        fields: [max_simple_mir_struct_fields]SimpleMirStructLiteralField = undefined,
        field_count: usize = 0,
    };

    const SimpleMirArrayLiteralReturn = struct {
        c_type: []const u8,
        items: [max_simple_mir_array_items]SimpleMirCallArg = undefined,
        item_count: usize = 0,
    };

    const SimpleMirArg = union(enum) {
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        float_literal: SimpleMirFloatLiteral,
        bool_literal: bool,
        enum_literal: SimpleMirEnumLiteral,
    };

    const SimpleMirCallArg = union(enum) {
        local: []const u8,
        param: []const u8,
        param_field: SimpleMirParamField,
        integer_literal: []const u8,
        float_literal: SimpleMirFloatLiteral,
        bool_literal: bool,
        enum_literal: SimpleMirEnumLiteral,
        global_load: []const u8,
        global_address: []const u8,
        direct_call: SimpleMirNestedCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        logical_not: SimpleMirArg,
        compare_binary: SimpleMirCompareBinary,
    };

    const SimpleMirLocalInitCallReturn = struct {
        local_name: []const u8,
        local_ty: ast_bridge.TypeExpr,
        local_source: mir.SourcePoint,
        init_call: SimpleMirDirectCall,
        return_call: SimpleMirDirectCall,
    };

    const SimpleMirNestedCall = struct {
        callee: []const u8,
        args: [max_simple_mir_call_args]SimpleMirArg = undefined,
        arg_count: usize = 0,
    };

    const SimpleMirDirectCall = struct {
        callee: []const u8,
        source: mir.SourcePoint,
        args: [max_simple_mir_call_args]SimpleMirCallArg = undefined,
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
        param_field_store: SimpleMirParamFieldStore,
    };

    const SimpleMirVoidStatements = struct {
        statements: [max_simple_mir_void_statements]SimpleMirVoidStatement = undefined,
        count: usize = 0,
    };

    const SimpleMirGlobalStoreValue = union(enum) {
        arg: SimpleMirArg,
        float_literal: SimpleMirFloatLiteral,
        global_load: []const u8,
        direct_call: SimpleMirDirectCall,
        checked_binary: SimpleMirCheckedBinary,
        checked_unary: SimpleMirCheckedUnary,
        wrapping_binary: SimpleMirWrappingBinary,
        explicit_cast: SimpleMirExplicitCastReturn,
        conversion: SimpleMirConversionReturn,
        compare_binary: SimpleMirCompareBinary,
        logical_not: SimpleMirArg,
        enum_literal: SimpleMirEnumLiteral,
        null_literal: SimpleMirNullLiteral,
        struct_literal: SimpleMirStructLiteralReturn,
        result_constructor: SimpleMirResultConstructorReturn,
    };

    const SimpleMirParamFieldStore = struct {
        param_name: []const u8,
        field_name: []const u8,
        field_index: usize,
        value: SimpleMirArg,
        source: mir.SourcePoint,
    };

    const SimpleMirCheckedBinary = struct {
        op: []const u8,
        type_name: []const u8,
        left: SimpleMirArg,
        right: SimpleMirArg,
    };

    const SimpleMirPlainFloatBinary = struct {
        op: []const u8,
        target_fact: mir.TargetTypeFact,
        left: SimpleMirArg,
        right: SimpleMirArg,
    };

    const SimpleMirFloatLiteral = struct {
        literal: []const u8,
        target_type_name: []const u8,
    };

    const SimpleMirCheckedUnary = struct {
        op: []const u8,
        type_name: []const u8,
        operand: SimpleMirArg,
    };

    const SimpleMirCompareBinary = struct {
        op: []const u8,
        left: SimpleMirArg,
        right: SimpleMirArg,
        representation_check: ?SimpleMirEnumRepresentationCheck = null,
    };

    const SimpleMirEnumRepresentationCheck = struct {
        enum_name: []const u8,
        subject: SimpleMirArg,
    };

    const SimpleMirWrappingBinary = struct {
        kind: enum { wrapping_add, unchecked, serial_before, serial_after, serial_distance, counter_delta_mod },
        op: []const u8,
        operation_fact: mir.TargetTypeFact,
        result_fact: mir.TargetTypeFact,
        range_fact: ?mir.RangeFact = null,
        left: SimpleMirCallArg,
        right: SimpleMirCallArg,
    };

    fn emitSimpleMirFunction(self: *CEmitter, function: anytype, fn_mir: mir.Function, render_attrs: anytype, selected_path: *fallback_census.SelectedPath) !bool {
        if (function.signature.is_variadic) return false;
        // Prefer the canonical, syntax-free executable body whenever it is
        // complete and within this backend's capability set.  In particular,
        // do this before constructing any of the transitional specialized
        // plans below: once the canonical body is admitted, AST-shaped plans
        // must not get another opportunity to decide the function semantics.
        const executable_body = if (self.mirExecutableBodySupported(&fn_mir)) body: {
            mir_executable_body.verify(&fn_mir) catch break :body null;
            break :body &fn_mir.executable_body;
        } else null;
        if (!render_attrs.naked) if (executable_body) |body| {
            try self.emitExecutableMirFunction(function, body, render_attrs);
            selected_path.* = .canonical;
            return true;
        };

        // Transitional specialized plans do not own function declaration
        // mechanics.  Keep them restricted to plain definitions; attributed
        // functions either use the canonical wrapper above or fall through to
        // the legacy definition emitter, which still renders every attribute.
        if (!plainFunctionRenderAttrs(render_attrs)) return false;

        const nullable_control_plan = if (mir_nullable_control_plan.build(&fn_mir)) |plan|
            if (self.mirNullableControlPlanSupported(function, plan)) plan else null
        else
            null;
        const nested_conditional_return_plan = if (nullable_control_plan == null)
            if (mir_nested_conditional_return_plan.build(fn_mir)) |plan|
                if (self.mirNestedConditionalReturnPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const aggregate_sequence_plan = if (nullable_control_plan == null and nested_conditional_return_plan == null)
            if (mir_aggregate_sequence_plan.build(&fn_mir)) |plan|
                if (self.mirAggregateSequencePlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const workflow_plan = if (nullable_control_plan == null and nested_conditional_return_plan == null and aggregate_sequence_plan == null)
            if (mir_workflow_plan.build(&fn_mir)) |plan|
                if (self.mirWorkflowPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const alloca_hoist_plan = if (nullable_control_plan == null and nested_conditional_return_plan == null and aggregate_sequence_plan == null and workflow_plan == null)
            if (mir_alloca_hoist_plan.build(&fn_mir)) |plan|
                if (self.mirAllocaHoistPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        var access_body_plan: ?mir_access_plan.AccessBodyPlan = null;
        defer if (access_body_plan) |*plan| plan.deinit(self.scratch.allocator());
        const access_slice_plan = if (nullable_control_plan == null and nested_conditional_return_plan == null and aggregate_sequence_plan == null and workflow_plan == null and alloca_hoist_plan == null) blk: {
            access_body_plan = try mir_access_plan.buildAccessBody(self.scratch.allocator(), &fn_mir);
            const plan = access_body_plan orelse break :blk null;
            break :blk if (self.mirAccessSlicePlanSupported(function, plan)) plan else null;
        } else null;
        const access_structural_operation = if (access_slice_plan == null and access_body_plan != null)
            if (mir_access_plan.buildStructuralOperation(access_body_plan.?)) |operation|
                if (self.mirAccessStructuralPlanSupported(function, access_body_plan.?, operation)) operation else null
            else
                null
        else
            null;
        const access_structural_priority = access_structural_operation != null and
            mirAccessStructuralRequiresPriority(access_body_plan.?, access_structural_operation.?);
        const sequence_foreach_update_plan = if (mir_statement_plan.buildSequenceForEachUpdate(fn_mir)) |plan|
            if (self.mirSequenceForEachUpdatePlanSupported(function, plan)) plan else null
        else
            null;
        const sequence_foreach_return_plan = if (sequence_foreach_update_plan == null)
            if (mir_statement_plan.buildSequenceForEachReturn(fn_mir)) |plan|
                if (self.mirSequenceForEachReturnPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const direct_call_projected_return_plan = if (sequence_foreach_return_plan == null)
            if (mir_statement_plan.buildDirectCallProjectedReturn(fn_mir)) |plan|
                if (self.mirDirectCallProjectedReturnPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const local_aggregate_place_update_return_plan = if (direct_call_projected_return_plan == null)
            if (mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(fn_mir)) |plan|
                if (self.mirLocalAggregatePlaceUpdateReturnPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const local_aggregate_assignment_return_plan = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null)
            if (mir_statement_plan.buildLocalAggregateAssignmentReturn(fn_mir)) |plan|
                if (self.mirLocalAggregateAssignmentReturnPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const place_return_plan = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null)
            if (mir_statement_plan.buildSingleBlockPlaceReturn(fn_mir)) |plan|
                if (self.mirPlacePlanSupported(plan, function.signature.name.span)) plan else null
            else
                null
        else
            null;
        const scalar_switch_return_plan = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and place_return_plan == null)
            if (mir_statement_plan.buildScalarSwitchReturn(fn_mir)) |plan|
                if (self.mirScalarSwitchPlanSupported(function, plan)) plan else null
            else
                null
        else
            null;
        const nullable_try_plan = if (mir_statement_plan.buildNullableTry(fn_mir)) |plan|
            if (self.mirNullableTryPlanSupported(plan)) plan else null
        else
            null;
        const simple_return = if (nested_conditional_return_plan == null and aggregate_sequence_plan == null and workflow_plan == null and alloca_hoist_plan == null and access_slice_plan == null and sequence_foreach_return_plan == null and direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and place_return_plan == null and scalar_switch_return_plan == null and nullable_try_plan == null) self.simpleMirReturn(function, fn_mir) else null;
        const simple_return_prefix_calls = blk: {
            if (simple_return) |ret| {
                switch (ret) {
                    .aggregate_return_pointer_load => break :blk SimpleMirDirectCalls{},
                    .local_init_call_return => break :blk SimpleMirDirectCalls{},
                    else => {},
                }
                break :blk self.simpleMirPrefixVoidCallsBeforeReturn(function, fn_mir, self.simpleMirReturnAllowsTrapBlocks(fn_mir, ret)) orelse return false;
            }
            break :blk null;
        };
        const simple_void_body = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and simple_return == null and nullable_try_plan == null) self.simpleMirVoidBody(function, fn_mir) else null;
        const simple_conditional_return = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and simple_return == null and simple_void_body == null) self.simpleMirConditionalReturn(function, fn_mir) else null;
        const simple_enum_switch_return = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and simple_return == null and simple_void_body == null and simple_conditional_return == null) self.simpleMirEnumSwitchReturn(function, fn_mir) else null;
        const simple_loop_return = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and simple_return == null and simple_void_body == null and simple_conditional_return == null and simple_enum_switch_return == null) self.simpleMirLoopReturn(function, fn_mir) else null;
        const indirect_call_return_plan = if (direct_call_projected_return_plan == null and local_aggregate_place_update_return_plan == null and local_aggregate_assignment_return_plan == null and simple_return == null and simple_void_body == null and simple_conditional_return == null and simple_enum_switch_return == null and simple_loop_return == null and place_return_plan == null)
            if (mir_statement_plan.buildSingleBlockIndirectCallReturn(fn_mir)) |plan|
                if (self.mirIndirectCallReturnPlanSupported(plan)) plan else null
            else
                null
        else
            null;
        const specialized_plans = [_]bool{
            nullable_control_plan != null,
            nested_conditional_return_plan != null,
            aggregate_sequence_plan != null,
            workflow_plan != null,
            alloca_hoist_plan != null,
            access_slice_plan != null,
            access_structural_operation != null,
            sequence_foreach_update_plan != null,
            sequence_foreach_return_plan != null,
            direct_call_projected_return_plan != null,
            local_aggregate_place_update_return_plan != null,
            local_aggregate_assignment_return_plan != null,
            nullable_try_plan != null,
            simple_return != null,
            simple_void_body != null,
            simple_conditional_return != null,
            simple_enum_switch_return != null,
            simple_loop_return != null,
            place_return_plan != null,
            scalar_switch_return_plan != null,
            indirect_call_return_plan != null,
        };
        if (std.mem.indexOfScalar(bool, &specialized_plans, true) == null) return false;

        try self.writeLineDirective(function.signature.name.span);
        try self.emitFunctionSignature(function.signature, !function.signature.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");

        const previous_function = self.current_function;
        self.current_function = function.signature.name.text;
        defer self.current_function = previous_function;
        self.indent += 1;
        defer self.indent -= 1;

        if (nullable_control_plan) |plan| {
            selected_path.* = .nullable_control;
            try self.emitMirNullableControlPlan(plan);
        } else if (nested_conditional_return_plan) |plan| {
            selected_path.* = .nested_conditional_return;
            try self.emitMirNestedConditionalReturnPlan(plan);
        } else if (aggregate_sequence_plan) |plan| {
            selected_path.* = .aggregate_sequence;
            try self.emitMirAggregateSequencePlan(plan);
        } else if (workflow_plan) |plan| {
            selected_path.* = .workflow;
            try self.emitMirWorkflowPlan(plan);
        } else if (alloca_hoist_plan) |plan| {
            selected_path.* = .alloca_hoist;
            try self.emitMirAllocaHoistPlan(plan);
        } else if (access_slice_plan) |plan| {
            selected_path.* = .access_slice;
            try self.emitMirAccessSlicePlan(plan);
        } else if (access_structural_priority) {
            selected_path.* = .access_structural;
            try self.emitMirAccessStructuralPlan(access_body_plan.?, access_structural_operation.?);
        } else if (sequence_foreach_update_plan) |plan| {
            selected_path.* = .sequence_foreach_update;
            try self.emitMirSequenceForEachUpdatePlan(plan);
        } else if (sequence_foreach_return_plan) |plan| {
            selected_path.* = .sequence_foreach_return;
            try self.emitMirSequenceForEachReturnPlan(plan);
        } else if (direct_call_projected_return_plan) |plan| {
            selected_path.* = .direct_call_projected_return;
            try self.emitMirDirectCallProjectedReturnPlan(plan);
        } else if (local_aggregate_place_update_return_plan) |plan| {
            selected_path.* = .local_aggregate_place_update_return;
            try self.emitMirLocalAggregatePlaceUpdateReturnPlan(plan);
        } else if (local_aggregate_assignment_return_plan) |plan| {
            selected_path.* = .local_aggregate_assignment_return;
            try self.emitMirLocalAggregateAssignmentReturnPlan(plan);
        } else if (place_return_plan) |plan| {
            selected_path.* = .place_return;
            try self.emitMirPlaceReturnPlan(plan);
        } else if (scalar_switch_return_plan) |plan| {
            selected_path.* = .scalar_switch_return;
            try self.emitMirScalarSwitchReturnPlan(plan);
        } else if (nullable_try_plan) |plan| {
            selected_path.* = .nullable_try;
            try self.emitMirNullableTryPlan(plan);
        } else if (indirect_call_return_plan) |plan| {
            selected_path.* = .indirect_call_return;
            try self.emitMirIndirectCallReturnPlan(plan);
        } else if (simple_return) |ret| {
            selected_path.* = .simple_return;
            if (simple_return_prefix_calls) |calls| {
                try self.emitSimpleMirDirectCallStatements(calls);
            }
            const return_span: ?diagnostics.Span = switch (ret) {
                .local_init_call_return => |local_return| spanFromMirSourcePoint(local_return.local_source),
                else => self.simpleMirReturnSpan(fn_mir),
            };
            if (return_span) |span| try self.writeLineDirective(span);
            try self.writeIndent();
            switch (ret) {
                .void => try self.out.appendSlice(self.allocator, "return;\n"),
                .param => |name| try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(name)}),
                .param_field => |field| try self.out.print(self.allocator, "return {s}.{s};\n", .{ try self.cIdent(field.param_name), try self.cIdent(field.field_name) }),
                .integer_literal => |literal| try self.out.print(self.allocator, "return {s};\n", .{literal}),
                .checked_integer_literal => |literal| try self.out.print(self.allocator, "return {s};\n", .{literal}),
                .float_literal => |literal| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirFloatLiteral(literal);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .bool_literal => |value| try self.out.print(self.allocator, "return {s};\n", .{if (value) "true" else "false"}),
                .enum_literal => |literal| try self.out.print(self.allocator, "return {s}_{s};\n", .{ literal.enum_name, literal.case_name }),
                .null_literal => |literal| try self.emitSimpleMirNullReturn(literal),
                .global_load => |name| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try appendGlobalLoadExpr(self.allocator, self.out, name, self.globals.get(name) orelse return error.UnsupportedCEmission);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .global_address => |name| try self.out.print(self.allocator, "return &{s};\n", .{try self.cIdent(name)}),
                .nested_call => |call| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirNestedCall(call);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .checked_binary => |binary| {
                    const helper = try self.checkedHelperName(binary.op, binary.type_name);
                    try self.out.print(self.allocator, "return {s}(", .{helper});
                    try self.emitSimpleMirArg(binary.left);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitSimpleMirArg(binary.right);
                    try self.out.appendSlice(self.allocator, ");\n");
                },
                .checked_unary => |unary| {
                    const helper = try self.checkedUnaryHelperName(unary.op, unary.type_name);
                    try self.out.print(self.allocator, "return {s}(", .{helper});
                    try self.emitSimpleMirArg(unary.operand);
                    try self.out.appendSlice(self.allocator, ");\n");
                },
                .compare_binary => |binary| {
                    try self.emitSimpleMirCompareRepresentationCheck(binary);
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirCompareBinary(binary);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .logical_not => |arg| {
                    try self.out.appendSlice(self.allocator, "return !");
                    try self.emitSimpleMirArg(arg);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .direct_call => |call| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirDirectCall(call);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .local_init_call_return => |local_return| {
                    try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(local_return.local_ty, .typedef_name), try self.cIdent(local_return.local_name) });
                    try self.emitSimpleMirDirectCall(local_return.init_call);
                    try self.out.appendSlice(self.allocator, ";\n");
                    if (self.simpleMirReturnSpan(fn_mir)) |span| try self.writeLineDirective(span);
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirDirectCall(local_return.return_call);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .result_constructor => |constructor| {
                    try self.out.print(self.allocator, "return (({s}){{ .is_ok = ", .{try self.cTypeFor(constructor.result_fact.target_ty, .typedef_name)});
                    try self.out.appendSlice(self.allocator, if (std.mem.eql(u8, constructor.tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
                    try self.emitSimpleMirResultConstructorPayload(constructor.payload);
                    try self.out.appendSlice(self.allocator, " });\n");
                },
                .explicit_cast_return => |cast| {
                    _ = cast.source_fact;
                    try self.out.print(self.allocator, "return (({s})(", .{try self.cTypeFor(cast.target_fact.target_ty, .typedef_name)});
                    try self.emitSimpleMirCallArg(cast.operand);
                    try self.out.appendSlice(self.allocator, "));\n");
                },
                .conversion_return => |conversion| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirConversionExpr(conversion);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .wrapping_binary => |binary| {
                    switch (binary.kind) {
                        .wrapping_add, .serial_before, .serial_after, .serial_distance, .counter_delta_mod => {},
                        .unchecked => {
                            const fact = binary.range_fact orelse return error.UnsupportedCEmission;
                            try self.out.print(self.allocator, "/* MC_MIR_RANGE no_overflow target={s} op={s} */\n", .{ fact.target, fact.op });
                            try self.writeIndent();
                        },
                    }
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirWrappingBinaryExpr(binary);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .plain_float_binary => |binary| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirPlainFloatBinaryExpr(binary);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .struct_literal => |literal| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirStructLiteral(literal);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .array_literal => |literal| {
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirArrayLiteral(literal);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .aggregate_return_pointer_load => |load| {
                    try self.emitMirAggregateReturnPointerFactConsumedComment(load.fact);
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitSimpleMirAggregateReturnPointerLoad(load);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .scalar_deref_load => |load| {
                    const scalar = simpleMirScalarLikeCInfo(load.pointee_ty) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "return (({s})mc_race_load_{s}({s}));\n", .{ scalar.c_type, scalar.race_type_name, try self.cIdent(load.param_name) });
                },
                .scalar_field_load => |load| {
                    const scalar = simpleMirScalarLikeCInfo(load.field_ty) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "return (({s})mc_race_load_{s}(&({s}->{s})));\n", .{ scalar.c_type, scalar.race_type_name, try self.cIdent(load.param_name), try self.cIdent(load.field_name) });
                },
                .plain_unary => |unary| {
                    try self.out.print(self.allocator, "return {s}(", .{unary.op_c});
                    try self.emitSimpleMirArg(unary.operand);
                    try self.out.appendSlice(self.allocator, ");\n");
                },
            }
        } else if (simple_void_body) |body| {
            selected_path.* = .simple_void_body;
            switch (body) {
                .empty => {},
                .statements => |statements| {
                    try self.emitSimpleMirVoidStatements(statements);
                },
                .conditional_statements => |conditional| {
                    try self.emitSimpleMirDirectCallStatements(conditional.prefix_calls);
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "if (");
                    try self.emitSimpleMirCondition(conditional.condition);
                    try self.out.appendSlice(self.allocator, ") {\n");
                    self.indent += 1;
                    try self.emitSimpleMirVoidStatements(conditional.then_statements);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "} else {\n");
                    self.indent += 1;
                    try self.emitSimpleMirVoidStatements(conditional.else_statements);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "}\n");
                    try self.emitSimpleMirVoidStatementSources(function, fn_mir, conditional.suffix_statements);
                },
                .loop_statements => |loop| {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "while (");
                    try self.emitSimpleMirCondition(loop.condition);
                    try self.out.appendSlice(self.allocator, ") {\n");
                    self.indent += 1;
                    if (loop.body_returns) {
                        try self.writeIndent();
                        try self.out.appendSlice(self.allocator, "return;\n");
                    } else {
                        try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[loop.body_block_index]).?);
                    }
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "}\n");
                },
                .direct_call => |call| {
                    if (self.simpleMirCallSource(fn_mir)) |source| try self.writeLineDirective(spanFromMirSourcePoint(source));
                    try self.writeIndent();
                    try self.emitSimpleMirDirectCall(call);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .direct_calls => |calls| {
                    try self.emitSimpleMirDirectCallStatements(calls);
                },
                .conditional_direct_calls => |conditional| {
                    try self.emitSimpleMirDirectCallStatements(conditional.prefix_calls);
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "if (");
                    try self.emitSimpleMirCondition(conditional.condition);
                    try self.out.appendSlice(self.allocator, ") {\n");
                    self.indent += 1;
                    try self.emitSimpleMirDirectCallStatements(conditional.then_calls);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "} else {\n");
                    self.indent += 1;
                    try self.emitSimpleMirDirectCallStatements(conditional.else_calls);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "}\n");
                    try self.emitSimpleMirVoidStatementSources(function, fn_mir, conditional.suffix_statements);
                },
            }
        } else if (simple_conditional_return) |conditional| {
            selected_path.* = .simple_conditional_return;
            try self.emitSimpleMirDirectCallStatements(conditional.prefix_calls);
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "if (");
            try self.emitSimpleMirCondition(conditional.condition);
            try self.out.appendSlice(self.allocator, ") {\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "return ");
            try self.emitSimpleMirConditionalValue(conditional.then_value);
            try self.out.appendSlice(self.allocator, ";\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "} else {\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "return ");
            try self.emitSimpleMirConditionalValue(conditional.else_value);
            try self.out.appendSlice(self.allocator, ";\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        } else if (simple_enum_switch_return) |switch_return| {
            selected_path.* = .simple_enum_switch_return;
            try self.writeIndent();
            try self.out.print(self.allocator, "switch ({s}) {{\n", .{try self.cIdent(switch_return.subject_name)});
            self.indent += 1;
            for (switch_return.arms[0..switch_return.arm_count]) |arm| {
                try self.writeIndent();
                try self.out.print(self.allocator, "case {s}_{s}:\n", .{ switch_return.enum_name, arm.case_name });
                self.indent += 1;
                try self.writeLineDirective(arm.span);
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return ");
                try self.emitSimpleMirConditionalValue(arm.value);
                try self.out.appendSlice(self.allocator, ";\n");
                self.indent -= 1;
            }
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "default:\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_trap_InvalidRepresentation();\n");
            self.indent -= 1;
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        } else if (simple_loop_return) |loop| {
            selected_path.* = .simple_loop_return;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "while (");
            try self.emitSimpleMirCondition(loop.condition);
            try self.out.appendSlice(self.allocator, ") {\n");
            self.indent += 1;
            try self.emitSimpleMirVoidStatementSources(function, fn_mir, self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, fn_mir.blocks[loop.body_block_index]).?);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "return ");
            try self.emitSimpleMirConditionalValue(self.simpleMirReturnValueInBlock(function, fn_mir, fn_mir.blocks[loop.after_block_index]).?);
            try self.out.appendSlice(self.allocator, ";\n");
        } else if (access_structural_operation) |operation| {
            selected_path.* = .access_structural;
            try self.emitMirAccessStructuralPlan(access_body_plan.?, operation);
        }
        try self.out.appendSlice(self.allocator, "}\n\n");
        return true;
    }

    fn emitExecutableMirFunction(self: *CEmitter, function: anytype, body: *const mir.ExecutableBody, render_attrs: codegen_attrs.FunctionRenderAttrs) !void {
        try self.writeLineDirective(function.signature.name.span);
        try self.emitFunctionRenderAttrs(render_attrs);
        try self.emitFunctionSignature(function.signature, !function.signature.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");

        const previous_function = self.current_function;
        self.current_function = function.signature.name.text;
        defer self.current_function = previous_function;

        {
            self.indent += 1;
            defer self.indent -= 1;
            try mir_executable_c.emitBodyWithSourcePath(self.allocator, self.out, body, self.indent, self.source_path);
        }
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn mirExecutableBodySupported(self: *CEmitter, function: *const mir.Function) bool {
        // The generic renderer does not schedule cleanup edges.  Admission is
        // fail-closed until ownership cleanup is itself represented by
        // executable-body statements/blocks.
        if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return false;
        for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return false;
        const body = &function.executable_body;
        if (!mir_executable_c.canEmitBody(body)) return false;
        if (mir_executable_body.hasOnlyWriteOnlyLocals(body)) return false;
        if (body.parameters.len != function.param_types.len or body.parameters.len != function.param_count) return false;
        for (body.parameters, function.param_types) |parameter, parameter_ty| {
            if (!mir.ValueType.eql(parameter.ty, parameter_ty)) return false;
        }
        for (body.expressions) |expression| switch (expression.operation) {
            .direct_call => |call| {
                if (!call.callee.isValid() or call.callee.index() >= body.symbols.len) return false;
                const symbol = body.symbols[call.callee.index()];
                if (!symbol.id.eql(call.callee)) return false;
                const signature = self.mirFunctionByName(symbol.spelling) orelse return false;
                if (signature.is_variadic or signature.param_types.len != call.argument_count or
                    !mir.ValueType.eql(expression.result_ty, signature.return_ty)) return false;
                for (call.arguments[0..call.argument_count], signature.param_types) |argument_id, parameter_ty| {
                    if (!argument_id.isValid() or argument_id.index() >= body.expressions.len) return false;
                    const argument_ty = body.expressions[argument_id.index()].result_ty;
                    if (!mir.ValueType.eql(argument_ty, parameter_ty) and
                        (signature.c_abi or mir.ExecutableCastKind.classify(argument_ty, parameter_ty) != .pointer_to_nullable)) return false;
                }
            },
            else => {},
        };
        return true;
    }

    fn mirFunctionByName(self: *const CEmitter, name: []const u8) ?mir.Function {
        for (self.mir_module.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }

    fn mirNullableControlPlanSupported(self: *CEmitter, function: anytype, plan: mir_nullable_control_plan.Plan) bool {
        if (!plan.binding.value_id.isValid()) return false;
        const declared_return = function.signature.transitionalReturnType() orelse return false;
        const binding_ty = switch (plan.then_return.operand) {
            .direct_call => |call| blk: {
                const signature = self.functions.get(call.call.callee_name) orelse return false;
                const arm_return = signature.return_type orelse return false;
                if (!call.call.callee_value_id.isValid() or signature.is_variadic or signature.params.len != 1 or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(arm_return)) or
                    !self.mirNullableControlValueTypeMatches(call.call.result.value_ty, arm_return) or
                    !self.mirNullableControlValueTypeMatches(plan.binding.pointer_ty, signature.params[0].ty)) return false;
                break :blk signature.params[0].ty;
            },
            .binding => |binding| blk: {
                if (!binding.value_id.isValid() or !self.mirNullableControlValueTypeMatches(binding.pointer_ty, declared_return)) return false;
                break :blk declared_return;
            },
            else => return false,
        };

        switch (plan.else_return.operand) {
            .integer_zero => if (!self.mirNullableControlIntegerReturn(declared_return)) return false,
            .parameter => |parameter| {
                const fallback_ty = self.mirNullableControlParameterType(function, parameter.name) orelse return false;
                if (!parameter.value_id.isValid() or !self.mirNullableControlValueTypeMatches(parameter.pointer_ty, fallback_ty) or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(fallback_ty), self.resolveAliasType(declared_return))) return false;
            },
            else => return false,
        }

        const subject_ty = self.mirNullableControlSubjectType(function, plan.subject) orelse return false;
        if (!self.mirNullableControlValueTypeMatches(plan.subject_type.value_ty, subject_ty)) return false;
        const subject_c = self.cTypeFor(subject_ty, .typedef_name) catch return false;
        const binding_c = self.cTypeFor(binding_ty, .typedef_name) catch return false;
        if (!std.mem.eql(u8, subject_c, binding_c)) return false;

        return switch (plan.subject) {
            .parameter, .global, .field => true,
            .direct_call => |subject| blk: {
                const outer = self.functions.get(subject.call.callee_name) orelse break :blk false;
                const outer_return = outer.return_type orelse break :blk false;
                if (outer.is_variadic or !self.mirNullableControlValueTypeMatches(subject.call.result.value_ty, outer_return) or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(subject_ty), self.resolveAliasType(outer_return))) break :blk false;
                if (subject.seed) |seed| {
                    const seed_signature = self.functions.get(seed.callee_name) orelse break :blk false;
                    const seed_return = seed_signature.return_type orelse break :blk false;
                    break :blk !seed_signature.is_variadic and seed_signature.params.len == 0 and outer.params.len == 1 and
                        self.mirNullableControlValueTypeMatches(seed.result.value_ty, seed_return) and
                        type_bridge.sameTypeSyntax(self.resolveAliasType(seed_return), self.resolveAliasType(outer.params[0].ty));
                }
                break :blk outer.params.len == 0;
            },
        };
    }

    fn mirNullableControlParameterType(self: *CEmitter, function: anytype, name: []const u8) ?TransitionalTypeExpr {
        _ = self;
        for (function.signature.params) |param| if (std.mem.eql(u8, param.name.text, name)) return param.ty;
        return null;
    }

    fn mirNullableControlIntegerReturn(self: *CEmitter, ty: TransitionalTypeExpr) bool {
        const name = typeName(self.resolveAliasType(ty)) orelse return false;
        return std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize") or
            std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "i32") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize");
    }

    fn mirNullableControlSubjectType(self: *CEmitter, function: anytype, subject: mir_nullable_control_plan.Subject) ?TransitionalTypeExpr {
        return switch (subject) {
            .parameter => |parameter| blk: {
                if (!parameter.value_id.isValid()) break :blk null;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, param.name.text, parameter.name)) break :blk param.ty;
                }
                break :blk null;
            },
            .global => |global| blk: {
                if (!global.value_id.isValid()) break :blk null;
                break :blk (self.globals.get(global.name) orelse break :blk null).source_ty;
            },
            .field => |field| blk: {
                if (!field.base_value_id.isValid()) break :blk null;
                for (function.signature.params) |param| {
                    if (!std.mem.eql(u8, param.name.text, field.base_name)) continue;
                    const struct_name = self.structTypeNameFromType(param.ty) orelse break :blk null;
                    const struct_decl = self.structs.get(struct_name) orelse break :blk null;
                    if (field.field_index >= struct_decl.fields.len) break :blk null;
                    const declared_field = struct_decl.fields[field.field_index];
                    if (!std.mem.eql(u8, declared_field.name.text, field.field_name)) break :blk null;
                    break :blk declared_field.ty;
                }
                break :blk null;
            },
            .direct_call => |call| (self.functions.get(call.call.callee_name) orelse return null).return_type,
        };
    }

    fn mirNullableControlValueTypeMatches(self: *CEmitter, value_ty: mir.ValueType, source_ty: TransitionalTypeExpr) bool {
        const resolved = self.resolveAliasType(source_ty);
        return switch (value_ty) {
            .integer => |name| typeName(resolved) != null and std.mem.eql(u8, typeName(resolved).?, name),
            .pointer => |shape| self.mirNullableControlPointerShapeMatches(shape, resolved, false),
            .nullable_pointer => |shape| self.mirNullableControlPointerShapeMatches(shape, resolved, true),
            else => false,
        };
    }

    fn mirNullableControlPointerShapeMatches(self: *CEmitter, shape: mir.PointerShape, source_ty: TransitionalTypeExpr, nullable: bool) bool {
        const pointer_ty = if (nullable) switch (source_ty.kind) {
            .nullable => |child| self.resolveAliasType(child.*),
            else => return false,
        } else source_ty;
        const pointer = switch (pointer_ty.kind) {
            .pointer => |pointer| pointer,
            else => return false,
        };
        const child_name = typeName(self.resolveAliasType(pointer.child.*)) orelse return false;
        return pointer.mutability == shape.mutability and std.mem.eql(u8, child_name, shape.child);
    }

    fn emitMirNullableControlPlan(self: *CEmitter, plan: mir_nullable_control_plan.Plan) !void {
        const subject = try self.emitMirNullableControlSubject(plan);
        const binding_ty = try self.mirNullableControlBindingType(plan);
        try self.writeLineDirective(spanFromMirSourcePoint(plan.subject_type.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} != NULL) {{\n", .{subject});
        self.indent += 1;

        try self.writeLineDirective(spanFromMirSourcePoint(plan.binding.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{
            try self.cTypeFor(binding_ty, .typedef_name),
            try self.cIdent(plan.binding.name),
            subject,
        });
        try self.emitMirNullableControlArmReturn(plan.then_return, plan.binding.name);

        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "} else {\n");
        self.indent += 1;
        try self.emitMirNullableControlArmReturn(plan.else_return, plan.binding.name);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitMirNullableControlSubject(self: *CEmitter, plan: mir_nullable_control_plan.Plan) ![]const u8 {
        const binding_ty = try self.mirNullableControlBindingType(plan);
        // A parameter subject needs no cross-function temporary allocation.
        // Its function-local spelling is stable and cannot collide because a
        // nullable-control plan owns the complete function body.
        const subject_name: []const u8 = if (std.meta.activeTag(plan.subject) == .parameter) "mc_tmp0" else try self.nextTempName();
        if (std.meta.activeTag(plan.subject) == .direct_call) {
            const call_subject = plan.subject.direct_call;
            if (call_subject.seed) |seed| {
                const seed_signature = self.functions.get(seed.callee_name) orelse return error.UnsupportedCEmission;
                const seed_name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(seed.call_location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}();\n", .{
                    try self.cTypeFor(seed_signature.return_type orelse return error.UnsupportedCEmission, .typedef_name),
                    seed_name,
                    try self.cIdent(seed.callee_name),
                });
                try self.writeLineDirective(spanFromMirSourcePoint(call_subject.call.call_location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}({s});\n", .{
                    try self.cTypeFor(binding_ty, .typedef_name),
                    subject_name,
                    try self.cIdent(call_subject.call.callee_name),
                    seed_name,
                });
                return subject_name;
            }
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.subject_type.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(binding_ty, .typedef_name), subject_name });
        switch (plan.subject) {
            .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
            .global => |global| try appendGlobalLoadExpr(self.allocator, self.out, global.name, self.globals.get(global.name) orelse return error.UnsupportedCEmission),
            .field => |field| try self.out.print(self.allocator, "{s}.{s}", .{ try self.cIdent(field.base_name), try self.cIdent(field.field_name) }),
            .direct_call => |call_subject| try self.out.print(self.allocator, "{s}()", .{try self.cIdent(call_subject.call.callee_name)}),
        }
        try self.out.appendSlice(self.allocator, ";\n");
        return subject_name;
    }

    fn mirNullableControlBindingType(self: *CEmitter, plan: mir_nullable_control_plan.Plan) !TransitionalTypeExpr {
        return switch (plan.then_return.operand) {
            .direct_call => |call| (self.functions.get(call.call.callee_name) orelse return error.UnsupportedCEmission).params[0].ty,
            .binding => self.currentFunctionReturnType() orelse return error.UnsupportedCEmission,
            else => error.UnsupportedCEmission,
        };
    }

    fn currentFunctionReturnType(self: *CEmitter) ?TransitionalTypeExpr {
        const current = self.current_function orelse return null;
        return (self.functions.get(current) orelse return null).return_type;
    }

    fn emitMirNullableControlArmReturn(self: *CEmitter, arm: mir_nullable_control_plan.ArmReturn, binding_name: []const u8) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(arm.return_location.source));
        switch (arm.operand) {
            .direct_call => |call| {
                try self.writeIndent();
                try self.out.print(self.allocator, "return {s}({s});\n", .{ try self.cIdent(call.call.callee_name), try self.cIdent(binding_name) });
            },
            .binding => {
                try self.writeIndent();
                try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(binding_name)});
            },
            .integer_zero => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return 0;\n");
            },
            .parameter => |parameter| {
                if (parameter.requires_nonnull_check) {
                    try self.writeLineDirective(spanFromMirSourcePoint(parameter.location.source));
                    try self.writeIndent();
                    try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_InvalidRepresentation();\n", .{try self.cIdent(parameter.name)});
                }
                try self.writeIndent();
                try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(parameter.name)});
            },
        }
    }

    fn mirNestedConditionalReturnPlanSupported(self: *CEmitter, function: anytype, plan: mir_nested_conditional_return_plan.Plan) bool {
        if (!plan.dispatch_block.isValid() or !plan.nested_dispatch_block.isValid() or !plan.flag.id.isValid() or !plan.x.id.isValid()) return false;
        if (!self.mirNestedConditionalParameterTypeIs(function, plan.flag, "bool") or !self.mirNestedConditionalParameterTypeIs(function, plan.x, "u32")) return false;
        if (!mirNestedConditionalIntegerIs(plan.comparison_limit, "u32", 10) or !mirNestedConditionalIntegerIs(plan.first_return, "u32", 5) or
            !mirNestedConditionalIntegerIs(plan.second_return, "u32", 6) or !mirNestedConditionalIntegerIs(plan.final_return, "u32", 7)) return false;
        return self.mirScalarExpressionSourceTypeIs(function.signature.transitionalReturnType() orelse return false, "u32");
    }

    fn mirNestedConditionalParameterTypeIs(self: *CEmitter, function: anytype, value: mir_nested_conditional_return_plan.Value, expected: []const u8) bool {
        if (!std.mem.eql(u8, value.ty.value_ty.name(), expected)) return false;
        var matches: usize = 0;
        for (function.signature.params) |parameter| {
            if (!std.mem.eql(u8, parameter.name.text, value.name)) continue;
            if (!self.mirNestedConditionalSourceTypeMatches(value.ty, parameter.ty)) return false;
            matches += 1;
        }
        return matches == 1;
    }

    fn mirNestedConditionalIntegerIs(value: mir_nested_conditional_return_plan.Integer, type_name: []const u8, expected: usize) bool {
        return value.value == expected and std.mem.eql(u8, value.ty.value_ty.name(), type_name) and value.ty.id.isValid() and value.location.span_id.isValid();
    }

    fn mirNestedConditionalSourceTypeMatches(self: *CEmitter, value_ty: mir_nested_conditional_return_plan.TypeRef, source_ty: TransitionalTypeExpr) bool {
        return self.mirScalarExpressionSourceTypeIs(source_ty, value_ty.value_ty.name());
    }

    fn emitMirNestedConditionalReturnPlan(self: *CEmitter, plan: mir_nested_conditional_return_plan.Plan) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(plan.flag_not_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "if (!{s}) {{\n", .{try self.cIdent(plan.flag.name)});
        self.indent += 1;
        try self.emitMirNestedConditionalReturn(plan.first_return, plan.first_return_location);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "} else if (");
        try self.out.print(self.allocator, "{s} > {d}) {{\n", .{ try self.cIdent(plan.x.name), plan.comparison_limit.value });
        self.indent += 1;
        try self.emitMirNestedConditionalReturn(plan.second_return, plan.second_return_location);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "} else {\n");
        self.indent += 1;
        try self.emitMirNestedConditionalReturn(plan.final_return, plan.final_return_location);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitMirNestedConditionalReturn(self: *CEmitter, value: mir_nested_conditional_return_plan.Integer, return_location: mir_nested_conditional_return_plan.Location) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {d};\n", .{value.value});
    }

    fn mirAggregateSequencePlanSupported(self: *CEmitter, function: anytype, plan: mir_aggregate_sequence_plan.Plan) bool {
        return switch (plan) {
            .aggregate_call_after_assignment => |sequence| self.mirAggregateCallAfterAssignmentPlanSupported(function, sequence),
            .struct_literal_direct_calls => |literal| self.mirStructLiteralDirectCallsPlanSupported(function, literal),
        };
    }

    fn mirAggregateCallAfterAssignmentPlanSupported(self: *CEmitter, function: anytype, sequence: mir_aggregate_sequence_plan.AggregateCallAfterAssignment) bool {
        if (sequence.count != 7 or !self.mirScalarExpressionSourceTypeIs(function.signature.transitionalReturnType() orelse return false, "u32")) return false;
        const row = switch (sequence.steps[0]) {
            .local_uninit => |value| value,
            else => return false,
        };
        const copy = switch (sequence.steps[1]) {
            .copy_index_assignment => |value| value,
            else => return false,
        };
        const pair = switch (sequence.steps[2]) {
            .local_uninit => |value| value,
            else => return false,
        };
        const aggregate = switch (sequence.steps[3]) {
            .aggregate_assignment => |value| value,
            else => return false,
        };
        const left = switch (sequence.steps[4]) {
            .direct_call => |value| value,
            else => return false,
        };
        const right = switch (sequence.steps[5]) {
            .direct_call => |value| value,
            else => return false,
        };
        const returned = switch (sequence.steps[6]) {
            .binary_return => |value| value,
            else => return false,
        };
        if (!row.local.id.isValid() or !pair.local.id.isValid() or !copy.target.id.eql(row.local.id) or !aggregate.target.id.eql(pair.local.id) or
            !copy.source_root.id.isValid() or copy.index != 0 or copy.bound != 2 or copy.bounds_trap.kind != .Bounds or returned.overflow_trap.kind != .IntegerOverflow or
            !std.mem.eql(u8, returned.operation, "add") or returned.left_call_step != 4 or returned.right_call_step != 5) return false;
        const matrix = self.globals.get(copy.source_root.name) orelse return false;
        const row_c = matrix.array_element_info orelse return false;
        if (matrix.array_len == null or !std.mem.eql(u8, matrix.array_len.?, "2") or std.meta.activeTag(row.type_ref.value_ty) != .array or std.meta.activeTag(copy.source_type.value_ty) != .array) return false;
        const pair_name = switch (pair.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return false,
        };
        const pair_decl = self.structs.get(pair_name) orelse return false;
        if (pair_decl.fields.len != 2 or std.meta.activeTag(aggregate.type_ref.value_ty) != std.meta.activeTag(pair.type_ref.value_ty) or !std.mem.eql(u8, aggregate.type_ref.value_ty.name(), pair.type_ref.value_ty.name()) or aggregate.field_indices[0] != 0 or aggregate.field_indices[1] != 1 or aggregate.literal_values[0] != 71 or aggregate.literal_values[1] != 72) return false;
        for (pair_decl.fields) |field| if (!self.mirScalarExpressionSourceTypeIs(field.ty, "u32")) return false;
        return self.mirAggregateSequenceCallSupported(left, row.local, row_c.c_type, "u32") and self.mirAggregateSequenceCallSupported(right, pair.local, pair_name, "u32");
    }

    fn mirAggregateSequenceCallSupported(self: *CEmitter, call: mir_aggregate_sequence_plan.DirectCall, argument: mir_aggregate_sequence_plan.ValueRef, argument_c: []const u8, result_name: []const u8) bool {
        if (!call.callee.id.isValid() or !call.argument.id.eql(argument.id) or !std.mem.eql(u8, call.argument.name, argument.name) or !std.mem.eql(u8, call.result.value_ty.name(), result_name)) return false;
        const signature = self.functions.get(call.callee.name) orelse return false;
        const return_ty = signature.return_type orelse return false;
        if (signature.is_variadic or signature.params.len != 1 or !self.mirScalarExpressionSourceTypeIs(return_ty, result_name)) return false;
        const parameter_c = self.cTypeFor(signature.params[0].ty, .typedef_name) catch return false;
        return std.mem.eql(u8, parameter_c, argument_c);
    }

    fn mirStructLiteralDirectCallsPlanSupported(self: *CEmitter, function: anytype, literal: mir_aggregate_sequence_plan.StructLiteralDirectCalls) bool {
        const result_name = switch (literal.result.value_ty) {
            .struct_ => |name| name,
            else => return false,
        };
        const result_decl = self.structs.get(result_name) orelse return false;
        if (result_decl.fields.len != 2 or !self.mirScalarExpressionSourceTypeIs(function.signature.transitionalReturnType() orelse return false, result_name)) return false;
        for (literal.fields, 0..) |field, index| {
            if (field.field_index != index or !field.call.argument.id.isValid() or !self.mirAggregateSequenceFieldCallSupported(function, field.call, result_decl.fields[index].ty)) return false;
            if (index == 1) {
                const trap = field.representation_trap orelse return false;
                if (trap.kind != .InvalidRepresentation) return false;
            } else if (field.representation_trap != null) return false;
        }
        return true;
    }

    fn mirAggregateSequenceFieldCallSupported(self: *CEmitter, function: anytype, call: mir_aggregate_sequence_plan.DirectCall, field_ty: TransitionalTypeExpr) bool {
        const signature = self.functions.get(call.callee.name) orelse return false;
        const return_ty = signature.return_type orelse return false;
        if (!call.callee.id.isValid() or signature.is_variadic or signature.params.len != 1 or !type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(field_ty))) return false;
        for (function.signature.params) |parameter| {
            if (!std.mem.eql(u8, parameter.name.text, call.argument.name)) continue;
            return type_bridge.sameTypeSyntax(self.resolveAliasType(parameter.ty), self.resolveAliasType(signature.params[0].ty));
        }
        return false;
    }

    fn emitMirAggregateSequencePlan(self: *CEmitter, plan: mir_aggregate_sequence_plan.Plan) !void {
        switch (plan) {
            .aggregate_call_after_assignment => |sequence| try self.emitMirAggregateCallAfterAssignmentPlan(sequence),
            .struct_literal_direct_calls => |literal| try self.emitMirStructLiteralDirectCallsPlan(literal),
        }
    }

    fn emitMirAggregateCallAfterAssignmentPlan(self: *CEmitter, sequence: mir_aggregate_sequence_plan.AggregateCallAfterAssignment) !void {
        const row = sequence.steps[0].local_uninit;
        const copy = sequence.steps[1].copy_index_assignment;
        const pair = sequence.steps[2].local_uninit;
        const aggregate = sequence.steps[3].aggregate_assignment;
        const left = sequence.steps[4].direct_call;
        const right = sequence.steps[5].direct_call;
        const returned = sequence.steps[6].binary_return;
        const matrix = self.globals.get(copy.source_root.name) orelse return error.UnsupportedCEmission;
        const row_c = matrix.array_element_info orelse return error.UnsupportedCEmission;
        const pair_name = switch (pair.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return error.UnsupportedCEmission,
        };
        const pair_decl = self.structs.get(pair_name) orelse return error.UnsupportedCEmission;
        try self.writeLineDirective(spanFromMirSourcePoint(row.local.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s};\n", .{ row_c.c_type, try self.cIdent(row.local.name) });
        try self.writeLineDirective(spanFromMirSourcePoint(copy.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = {s}.elems[mc_check_index_usize({d}, {d})];\n", .{ try self.cIdent(row.local.name), try self.cIdent(copy.source_root.name), copy.index, copy.bound });
        try self.writeLineDirective(spanFromMirSourcePoint(pair.local.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s};\n", .{ pair_name, try self.cIdent(pair.local.name) });
        try self.writeLineDirective(spanFromMirSourcePoint(aggregate.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = ({s}){{ .{s} = {d}, .{s} = {d} }};\n", .{ try self.cIdent(pair.local.name), pair_name, try self.cIdent(pair_decl.fields[0].name.text), aggregate.literal_values[0], try self.cIdent(pair_decl.fields[1].name.text), aggregate.literal_values[1] });
        const left_ty = try self.cTypeFor((self.functions.get(left.callee.name) orelse return error.UnsupportedCEmission).return_type orelse return error.UnsupportedCEmission, .typedef_name);
        const left_name = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(left.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}({s});\n", .{ left_ty, left_name, try self.cIdent(left.callee.name), try self.cIdent(left.argument.name) });
        const right_ty = try self.cTypeFor((self.functions.get(right.callee.name) orelse return error.UnsupportedCEmission).return_type orelse return error.UnsupportedCEmission, .typedef_name);
        const right_name = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(right.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}({s});\n", .{ right_ty, right_name, try self.cIdent(right.callee.name), try self.cIdent(right.argument.name) });
        try self.writeLineDirective(spanFromMirSourcePoint(returned.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s}({s}, {s});\n", .{ try self.checkedHelperName(returned.operation, left.result.value_ty.name()), left_name, right_name });
    }

    fn emitMirStructLiteralDirectCallsPlan(self: *CEmitter, literal: mir_aggregate_sequence_plan.StructLiteralDirectCalls) !void {
        const result_name = switch (literal.result.value_ty) {
            .struct_ => |name| name,
            else => return error.UnsupportedCEmission,
        };
        const result_decl = self.structs.get(result_name) orelse return error.UnsupportedCEmission;
        const first = literal.fields[0];
        const second = literal.fields[1];
        const first_ty = try self.cTypeFor((self.functions.get(first.call.callee.name) orelse return error.UnsupportedCEmission).return_type orelse return error.UnsupportedCEmission, .typedef_name);
        const first_name = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(first.call.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}({s});\n", .{ first_ty, first_name, try self.cIdent(first.call.callee.name), try self.cIdent(first.call.argument.name) });
        const second_ty = try self.cTypeFor((self.functions.get(second.call.callee.name) orelse return error.UnsupportedCEmission).return_type orelse return error.UnsupportedCEmission, .typedef_name);
        const second_name = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(second.call.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}({s});\n", .{ second_ty, second_name, try self.cIdent(second.call.callee.name), try self.cIdent(second.call.argument.name) });
        if (second.representation_trap != null) {
            try self.writeIndent();
            try self.out.print(self.allocator, "if ({s}.ptr == NULL && {s}.len != 0) mc_trap_InvalidRepresentation();\n", .{ second_name, second_name });
        }
        try self.writeLineDirective(spanFromMirSourcePoint(literal.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return ({s}){{ .{s} = {s}, .{s} = {s} }};\n", .{ result_name, try self.cIdent(result_decl.fields[first.field_index].name.text), first_name, try self.cIdent(result_decl.fields[second.field_index].name.text), second_name });
    }

    // These workflows are deliberately rendered from MIR identities plus declaration
    // artifacts.  In particular, no fallback body artifact is consulted here.
    fn mirWorkflowPlanSupported(self: *CEmitter, function: anytype, plan: mir_workflow_plan.Plan) bool {
        return switch (plan) {
            .local_vtable_call => |workflow| self.mirLocalVtableCallPlanSupported(function, workflow),
            .scoped_block => |workflow| self.mirScopedBlockPlanSupported(function, workflow),
            .call_closure => |workflow| self.mirClosureCallPlanSupported(function, workflow),
        };
    }

    fn mirWorkflowValueTypeMatchesSource(self: *CEmitter, value_ty: mir.ValueType, source_ty: TransitionalTypeExpr) bool {
        const resolved = self.resolveAliasType(source_ty);
        return switch (value_ty) {
            .void => isCVoidType(resolved),
            .bool, .integer, .float, .address, .struct_ => self.mirScalarExpressionSourceTypeIs(resolved, value_ty.name()),
            .domain_integer => |shape| switch (resolved.kind) {
                .generic => |generic| generic.args.len == 1 and
                    std.mem.eql(u8, generic.base.text, @tagName(shape.kind)) and
                    self.mirScalarExpressionSourceTypeIs(generic.args[0], shape.child),
                else => false,
            },
            .pointer => |pointer| switch (resolved.kind) {
                .pointer => |source_pointer| pointer.kind == .single and pointer.mutability == source_pointer.mutability and
                    std.mem.eql(u8, pointer.child, typeName(self.resolveAliasType(source_pointer.child.*)) orelse return false),
                .raw_many_pointer => |source_pointer| pointer.kind == .raw_many and pointer.mutability == source_pointer.mutability and
                    std.mem.eql(u8, pointer.child, typeName(self.resolveAliasType(source_pointer.child.*)) orelse return false),
                .slice => |source_slice| pointer.kind == .slice and pointer.mutability == source_slice.mutability and
                    std.mem.eql(u8, pointer.child, typeName(self.resolveAliasType(source_slice.child.*)) orelse return false),
                else => false,
            },
            .nullable_pointer => |pointer| self.mirNullableControlPointerShapeMatches(pointer, resolved, true),
            else => false,
        };
    }

    fn mirWorkflowFunctionMatches(self: *CEmitter, name: []const u8, result: mir_workflow_plan.TypeRef, args: []const mir_workflow_plan.CallArgument) bool {
        const signature = self.functions.get(name) orelse return false;
        const return_ty = signature.return_type orelse return false;
        if (signature.is_variadic or signature.params.len != args.len or !self.mirWorkflowValueTypeMatchesSource(result.value_ty, return_ty)) return false;
        for (args, 0..) |arg, index| {
            if (arg.index != index or !arg.type_ref.id.isValid() or !self.mirWorkflowValueTypeMatchesSource(arg.type_ref.value_ty, signature.params[index].ty)) return false;
        }
        return true;
    }

    fn mirLocalVtableCallPlanSupported(self: *CEmitter, function: anytype, workflow: mir_workflow_plan.LocalVtableCall) bool {
        if (workflow.function_field_index != 0 or !workflow.local.value.id.isValid() or !workflow.function_symbol.id.isValid()) return false;
        const local_name = switch (workflow.local.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return false,
        };
        const local_decl = self.structs.get(local_name) orelse return false;
        if (local_decl.fields.len != 1 or function.signature.params.len != 2 or !self.mirWorkflowValueTypeMatchesSource(workflow.dispatch.result.value_ty, function.signature.transitionalReturnType() orelse return false)) return false;
        if (workflow.dispatch.arg_count != 3 or !workflow.dispatch.args[0].type_ref.id.isValid()) return false;
        const address = switch (workflow.dispatch.args[0].value) {
            .address_of => |value| value,
            else => return false,
        };
        const x = switch (workflow.dispatch.args[1].value) {
            .value => |value| value,
            else => return false,
        };
        const y = switch (workflow.dispatch.args[2].value) {
            .value => |value| value,
            else => return false,
        };
        if (!address.operand.id.eql(workflow.local.value.id) or !x.id.isValid() or !y.id.isValid() or !std.mem.eql(u8, x.name, function.signature.params[0].name.text) or !std.mem.eql(u8, y.name, function.signature.params[1].name.text)) return false;
        return self.mirWorkflowFunctionMatches(workflow.dispatch.callee.name, workflow.dispatch.result, workflow.dispatch.args[0..workflow.dispatch.arg_count]);
    }

    fn mirScopedBlockPlanSupported(self: *CEmitter, function: anytype, workflow: mir_workflow_plan.ScopedBlock) bool {
        if (function.signature.params.len != 1 or !workflow.outer.value.id.isValid() or !workflow.inner.value.id.isValid() or !workflow.outer_initializer.id.isValid()) return false;
        if (!self.mirWorkflowValueTypeMatchesSource(workflow.outer.type_ref.value_ty, function.signature.transitionalReturnType() orelse return false) or !self.mirWorkflowValueTypeMatchesSource(workflow.outer.type_ref.value_ty, function.signature.params[0].ty) or !std.mem.eql(u8, workflow.inner.type_ref.value_ty.name(), workflow.inner_call.result.value_ty.name())) return false;
        if (workflow.inner_call.arg_count != 2 or workflow.consume_call.arg_count != 1) return false;
        const inner_arg = switch (workflow.inner_call.args[0].value) {
            .value => |value| value,
            else => return false,
        };
        const one = switch (workflow.inner_call.args[1].value) {
            .integer_literal => |value| value,
            else => return false,
        };
        const consumed = switch (workflow.consume_call.args[0].value) {
            .value => |value| value,
            else => return false,
        };
        if (!inner_arg.id.eql(workflow.outer_initializer.id) or one.value != 1 or !consumed.id.eql(workflow.inner.value.id)) return false;
        return self.mirWorkflowFunctionMatches(workflow.inner_call.callee.name, workflow.inner_call.result, workflow.inner_call.args[0..workflow.inner_call.arg_count]) and self.mirWorkflowFunctionMatches(workflow.consume_call.callee.name, workflow.consume_call.result, workflow.consume_call.args[0..workflow.consume_call.arg_count]);
    }

    fn mirWorkflowClosureTypeName(self: *CEmitter, bind: mir_workflow_plan.ClosureBind) ?[]const u8 {
        if (bind.closure_param_count != 1 or bind.closure_return.value_ty != .void) return null;
        var types = self.closure_types.iterator();
        while (types.next()) |entry| {
            const closure = entry.value_ptr.kind.closure_type;
            if (closure.params.len == bind.closure_param_count and isCVoidType(self.resolveAliasType(closure.ret.*)) and self.mirWorkflowValueTypeMatchesSource(bind.closure_type.value_ty, entry.value_ptr.*)) return entry.key_ptr.*;
            // The closure type itself is represented as `.value` in MIR; its
            // declaration is therefore checked by the recorded signature.
            if (closure.params.len == bind.closure_param_count and isCVoidType(self.resolveAliasType(closure.ret.*)) and self.mirScalarExpressionSourceTypeIs(closure.params[0], "u32")) return entry.key_ptr.*;
        }
        return null;
    }

    fn mirWorkflowCType(value_ty: mir.ValueType) ![]const u8 {
        return primitiveCTypeName(value_ty.name()) orelse switch (value_ty) {
            .struct_ => |name| name,
            else => error.UnsupportedCEmission,
        };
    }

    fn mirClosureCallPlanSupported(self: *CEmitter, function: anytype, workflow: mir_workflow_plan.ClosureCall) bool {
        if (function.signature.params.len != 1 or !isCVoidType(function.signature.transitionalReturnType() orelse return false) or !workflow.environment.value.id.isValid() or !workflow.bind.capture.operand.id.eql(workflow.environment.value.id) or workflow.bind.target_param_count != 2 or workflow.bind.closure_param_count != 1 or workflow.bind.target_return.value_ty != .void or workflow.bind.closure_return.value_ty != .void or !workflow.call.closure.id.eql(workflow.bind.closure.id)) return false;
        const environment_name = switch (workflow.environment.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return false,
        };
        const environment = self.structs.get(environment_name) orelse return false;
        if (environment.fields.len != 1 or self.mirWorkflowClosureTypeName(workflow.bind) == null) return false;
        const target = self.functions.get(workflow.bind.target.name) orelse return false;
        if (target.is_variadic or target.params.len != workflow.bind.target_param_count or !isCVoidType(target.return_type orelse return false) or !self.mirWorkflowValueTypeMatchesSource(workflow.bind.capture.type_ref.value_ty, target.params[0].ty) or !type_bridge.sameTypeSyntax(self.resolveAliasType(function.signature.params[0].ty), self.resolveAliasType(target.params[1].ty))) return false;
        return workflow.call.result.value_ty == .void;
    }

    fn emitMirWorkflowPlan(self: *CEmitter, plan: mir_workflow_plan.Plan) !void {
        switch (plan) {
            .local_vtable_call => |workflow| try self.emitMirLocalVtableCallPlan(workflow),
            .scoped_block => |workflow| try self.emitMirScopedBlockPlan(workflow),
            .call_closure => |workflow| try self.emitMirClosureCallPlan(workflow),
        }
    }

    fn emitMirLocalVtableCallPlan(self: *CEmitter, workflow: mir_workflow_plan.LocalVtableCall) !void {
        const struct_name = workflow.local.type_ref.value_ty.name();
        const field_name = (self.structs.get(struct_name) orelse return error.UnsupportedCEmission).fields[workflow.function_field_index].name.text;
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.local.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s}){{ .{s} = {s} }};\n", .{ struct_name, try self.cIdent(workflow.local.value.name), struct_name, try self.cIdent(field_name), try self.cIdent(workflow.function_symbol.name) });
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s}(&{s}, {s}, {s});\n", .{ try self.cIdent(workflow.dispatch.callee.name), try self.cIdent(workflow.local.value.name), try self.cIdent(workflow.dispatch.args[1].value.value.name), try self.cIdent(workflow.dispatch.args[2].value.value.name) });
    }

    fn emitMirScopedBlockPlan(self: *CEmitter, workflow: mir_workflow_plan.ScopedBlock) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.outer.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try mirWorkflowCType(workflow.outer.type_ref.value_ty), try self.cIdent(workflow.outer.value.name), try self.cIdent(workflow.outer_initializer.name) });
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "{\n");
        self.indent += 1;
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.inner.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}({s}, {d});\n", .{ try mirWorkflowCType(workflow.inner.type_ref.value_ty), try self.cIdent(workflow.inner.value.name), try self.cIdent(workflow.inner_call.callee.name), try self.cIdent(workflow.inner_call.args[0].value.value.name), workflow.inner_call.args[1].value.integer_literal.value });
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.inner_scope_last_use.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}({s});\n", .{ try self.cIdent(workflow.consume_call.callee.name), try self.cIdent(workflow.consume_call.args[0].value.value.name) });
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(workflow.outer.value.name)});
    }

    fn emitMirClosureCallPlan(self: *CEmitter, workflow: mir_workflow_plan.ClosureCall) !void {
        const environment_name = workflow.environment.type_ref.value_ty.name();
        const closure_name = self.mirWorkflowClosureTypeName(workflow.bind) orelse return error.UnsupportedCEmission;
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.environment.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s}){{ .value = 0 }};\n", .{ environment_name, try self.cIdent(workflow.environment.value.name), environment_name });
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.bind.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s}){{ .code = (void (*)(void *, uint32_t)){s}, .env = (void *)(&{s}) }};\n", .{ closure_name, try self.cIdent(workflow.bind.closure.name), closure_name, try self.cIdent(workflow.bind.target.name), try self.cIdent(workflow.bind.capture.operand.name) });
        const temporary = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(workflow.call.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ closure_name, temporary, try self.cIdent(workflow.call.closure.name) });
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}.code({s}.env, {s});\n", .{ temporary, temporary, try self.cIdent(workflow.call.argument.name) });
    }

    fn mirAllocaHoistTypeIs(value: mir_alloca_hoist_plan.TypeRef, expected: []const u8) bool {
        return value.id.isValid() and std.mem.eql(u8, value.value_ty.name(), expected);
    }

    fn mirAllocaHoistPlanSupported(self: *CEmitter, function: anytype, plan: mir_alloca_hoist_plan.Plan) bool {
        if (function.signature.params.len != 0 or !self.mirScalarExpressionSourceTypeIs(function.signature.transitionalReturnType() orelse return false, "u32")) return false;
        if (!plan.entry_block.isValid() or !plan.loop_block.isValid() or !plan.return_block.isValid() or !plan.sum.value.id.isValid() or !plan.index.value.id.isValid() or !plan.iteration_limit.id.isValid() or !plan.buffer_limit.id.isValid() or !plan.scratch.local.value.id.isValid() or !plan.slot.value.id.isValid()) return false;
        if (plan.initial_sum.value != 0 or plan.initial_index.value != 0 or plan.bit_mask.value != 255 or plan.increment_by.value != 1 or !plan.scratch.static_function_storage or plan.scratch.array_len != 256 or !plan.scratch.loop_block.eql(plan.loop_block) or plan.store.bound != plan.scratch.array_len or plan.load.bound != plan.scratch.array_len) return false;
        if (!mirAllocaHoistTypeIs(plan.sum.type_ref, "u32") or !mirAllocaHoistTypeIs(plan.index.type_ref, "u32") or !mirAllocaHoistTypeIs(plan.slot.type_ref, "usize") or !mirAllocaHoistTypeIs(plan.store.element, "u8") or !mirAllocaHoistTypeIs(plan.load.element, "u8") or !mirAllocaHoistTypeIs(plan.index_cast.source, "u32") or !mirAllocaHoistTypeIs(plan.index_cast.target, "usize") or !mirAllocaHoistTypeIs(plan.store_cast.target, "u8") or !mirAllocaHoistTypeIs(plan.load_cast.target, "u32")) return false;
        if (plan.slot_modulo.trap.kind != .DivideByZero or plan.store.trap.kind != .Bounds or plan.load.trap.kind != .Bounds or plan.sum_add.trap.kind != .IntegerOverflow or plan.increment.trap.kind != .IntegerOverflow or !std.mem.eql(u8, plan.slot_modulo.operation, "mod") or !std.mem.eql(u8, plan.sum_add.operation, "add") or !std.mem.eql(u8, plan.increment.operation, "add")) return false;
        return self.globals.contains(plan.iteration_limit.name) and self.globals.contains(plan.buffer_limit.name);
    }

    fn emitMirAllocaHoistPlan(self: *CEmitter, plan: mir_alloca_hoist_plan.Plan) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(plan.sum.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "uint32_t {s} = {d};\n", .{ try self.cIdent(plan.sum.value.name), plan.initial_sum.value });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.index.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "uint32_t {s} = {d};\n", .{ try self.cIdent(plan.index.value.name), plan.initial_index.value });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.iteration_limit.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "while ({s} < {s}) {{\n", .{ try self.cIdent(plan.index.value.name), try self.cIdent(plan.iteration_limit.name) });
        self.indent += 1;
        try self.writeLineDirective(spanFromMirSourcePoint(plan.scratch.local.declaration.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "uint8_t {s}[{d}];\n", .{ try self.cIdent(plan.scratch.local.value.name), plan.scratch.array_len });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.slot_modulo.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "uintptr_t {s} = {s}((uintptr_t){s}, {s});\n", .{ try self.cIdent(plan.slot.value.name), try self.checkedHelperName(plan.slot_modulo.operation, plan.slot.type_ref.value_ty.name()), try self.cIdent(plan.index.value.name), try self.cIdent(plan.buffer_limit.name) });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.store.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}[mc_check_index_usize({s}, {d})] = (uint8_t)({s} & {d});\n", .{ try self.cIdent(plan.scratch.local.value.name), try self.cIdent(plan.slot.value.name), plan.store.bound, try self.cIdent(plan.index.value.name), plan.bit_mask.value });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.load.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = {s}({s}, (uint32_t){s}[mc_check_index_usize({s}, {d})]);\n", .{ try self.cIdent(plan.sum.value.name), try self.checkedHelperName(plan.sum_add.operation, plan.sum.type_ref.value_ty.name()), try self.cIdent(plan.sum.value.name), try self.cIdent(plan.scratch.local.value.name), try self.cIdent(plan.slot.value.name), plan.load.bound });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.increment.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = {s}({s}, {d});\n", .{ try self.cIdent(plan.index.value.name), try self.checkedHelperName(plan.increment.operation, plan.index.type_ref.value_ty.name()), try self.cIdent(plan.index.value.name), plan.increment_by.value });
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        try self.writeLineDirective(spanFromMirSourcePoint(plan.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(plan.sum.value.name)});
    }

    fn mirAccessSlicePlanSupported(self: *CEmitter, function: anytype, body: mir_access_plan.AccessBodyPlan) bool {
        _ = self;
        if (!std.mem.eql(u8, body.function_name, function.signature.name.text) or !body.function_symbol_id.isValid()) return false;
        var indexes: usize = 0;
        var returned: usize = 0;
        var calls: usize = 0;
        var stores: usize = 0;
        var index_access: ?usize = null;
        var returned_value: ?mir_access_plan.Operand = null;
        var store_value: ?mir_access_plan.Operand = null;
        for (body.statements) |statement| switch (statement) {
            .index => |event| {
                if (event.access_index >= body.accesses.len) return false;
                const index = switch (body.accesses[event.access_index]) {
                    .index => |value| value,
                    else => return false,
                };
                const slice_base = switch (index.base.type_ref.value_ty) {
                    .slice => true,
                    .pointer => |shape| shape.kind == .slice,
                    else => false,
                };
                if (index.static_bound != null or !index.block_id.isValid() or !slice_base or simpleMirScalarCInfo(index.result.value_ty) == null) return false;
                index_access = event.access_index;
                indexes += 1;
            },
            .return_value => |value| {
                if (returned != 0) return false;
                returned_value = value.value;
                returned += 1;
            },
            .direct_call => |call| {
                if (calls != 0 or call.argument_count != 0) return false;
                calls += 1;
            },
            .index_store => |store| {
                if (stores != 0 or index_access == null or store.target_access_index != index_access.?) return false;
                const value = switch (store.value) {
                    .operand => |operand| operand,
                    else => return false,
                };
                if (value.name == null or value.value_id == null or !value.value_id.?.isValid()) return false;
                store_value = value;
                stores += 1;
            },
            else => return false,
        };
        if (indexes != 1 or returned != 1 or calls > 1 or stores > 1) return false;
        if (stores == 1) return returned_value == null and store_value != null;
        const operand = returned_value orelse return false;
        return operand.location.span_id.eql(switch (body.accesses[index_access.?]) {
            .index => |index| index.location.span_id,
            else => return false,
        });
    }

    fn emitMirAccessSlicePlan(self: *CEmitter, body: mir_access_plan.AccessBodyPlan) !void {
        var indexed: ?mir_access_plan.Index = null;
        var call: ?mir_access_plan.DirectCall = null;
        for (body.statements) |statement| switch (statement) {
            .index => |event| indexed = switch (body.accesses[event.access_index]) {
                .index => |value| value,
                else => return error.UnsupportedCEmission,
            },
            .direct_call => |value| call = value,
            else => {},
        };
        const index = indexed orelse return error.UnsupportedCEmission;
        const index_text = if (index.constant_index) |value| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) else try self.cIdent(index.index.name orelse return error.UnsupportedCEmission);
        const base = if (call) |direct| blk: {
            const signature = self.functions.get(direct.callee_name) orelse return error.UnsupportedCEmission;
            const ty = try self.cTypeFor(signature.return_type orelse return error.UnsupportedCEmission, .typedef_name);
            const temporary = try self.nextTempName();
            try self.writeLineDirective(spanFromMirSourcePoint(direct.location.source));
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = {s}();\n", .{ ty, temporary, try self.cIdent(direct.callee_name) });
            break :blk temporary;
        } else try self.cIdent(index.base.name orelse return error.UnsupportedCEmission);
        try self.writeLineDirective(spanFromMirSourcePoint(index.location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s}.ptr == NULL && {s}.len != 0) mc_trap_InvalidRepresentation();\n", .{ base, base });
        const scalar = simpleMirScalarCInfo(index.result.value_ty) orelse return error.UnsupportedCEmission;
        var element: ?[]const u8 = null;
        for (body.statements) |statement| switch (statement) {
            .index_store => |store| element = switch (store.value) {
                .operand => |operand| operand.name orelse return error.UnsupportedCEmission,
                else => return error.UnsupportedCEmission,
            },
            else => {},
        };
        try self.writeIndent();
        if (element) |value| {
            try self.out.print(self.allocator, "mc_race_store_{s}(&({s}.ptr[mc_check_index_usize({s}, {s}.len)]), ({s}){s});\n", .{ scalar.race_type_name, base, index_text, base, scalar.c_type, value });
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "return;\n");
        } else {
            try self.out.print(self.allocator, "return (({s})mc_race_load_{s}(&({s}.ptr[mc_check_index_usize({s}, {s}.len)])));\n", .{ scalar.c_type, scalar.race_type_name, base, index_text, base });
        }
    }

    fn mirAccessStructuralPlanSupported(self: *CEmitter, function: anytype, body: mir_access_plan.AccessBodyPlan, operation: mir_access_plan.StructuralOperation) bool {
        if (!std.mem.eql(u8, body.function_name, function.signature.name.text) or !body.function_symbol_id.isValid() or !body.entry_block.isValid()) return false;
        // Do not steal ordinary scalar/aggregate reads from the established
        // MIR statement plans. This path is intentionally bounded to bodies
        // whose semantics require a structural address/range/store witness,
        // or a materialized call result used as an indexed base.
        var has_structural_witness = false;
        for (body.statements) |statement| switch (statement) {
            .address_of, .range_slice, .deref_store, .index_store => has_structural_witness = true,
            .local_init => |local| switch (local.value) {
                .direct_call => {
                    const local_tag = std.meta.activeTag(local.type_ref.value_ty);
                    const aggregate_base = local_tag == .array or mirAccessIsSlice(local.type_ref.value_ty);
                    if (aggregate_base) for (body.accesses) |access| switch (access) {
                        .index => |index| if (index.base.name != null and std.mem.eql(u8, index.base.name.?, local.name)) {
                            has_structural_witness = true;
                            break;
                        },
                        else => {},
                    };
                },
                else => {},
            },
            else => {},
        };
        if (!has_structural_witness) return false;
        switch (operation) {
            .return_access => |returned| {
                if (returned.access_index >= body.accesses.len) return false;
                if (std.meta.activeTag(body.accesses[returned.access_index]) == .deref and !mirAccessHasProjectedAddress(body)) return false;
            },
            .store_access_then_return => |stored| if (stored.store.target_access_index >= body.accesses.len or mirAccessStoreNeedsLegacyProvenance(body, stored.store)) return false,
            .store_access_then_return_access => |stored| {
                if (stored.store.target_access_index >= body.accesses.len or mirAccessStoreNeedsLegacyProvenance(body, stored.store)) return false;
                switch (stored.value) {
                    .access_result => |index| if (index >= body.accesses.len or !self.mirAccessValueSupported(body, body.accesses[index])) return false,
                    .field => |field| if (!self.mirAccessFieldProjectionSupported(body, field)) return false,
                }
            },
            .store_access_then_return_operand => |stored| {
                if (stored.store.target_access_index >= body.accesses.len or mirAccessStoreNeedsLegacyProvenance(body, stored.store) or !self.mirAccessOperandSupported(body, stored.value)) return false;
            },
            .range_slice_local_then_return_builtin => |returned| {
                if (returned.range_access_index >= body.accesses.len or
                    !returned.local.value_id.isValid() or
                    !returned.member.result.id.isValid() or
                    returned.member.member != .slice_length or
                    !mirAccessIsSlice(returned.member.base.type_ref.value_ty) or
                    returned.member.base.value_id == null or
                    !returned.member.base.value_id.?.eql(returned.local.value_id)) return false;
                const initialized_access = switch (returned.local.value) {
                    .access_result => |index| index,
                    else => return false,
                };
                if (initialized_access != returned.range_access_index) return false;
                switch (body.accesses[returned.range_access_index]) {
                    .range_slice => {},
                    else => return false,
                }
            },
        }
        if (mirAccessStructuralMaterializedCallBase(body, operation) and !mirAccessStructuralRequiresPriority(body, operation)) return false;
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| {
                if (mirAccessStructuralElidesLocal(operation, local.value_id)) continue;
                _ = self.mirAccessLocalCType(body, local) catch return false;
                if (!self.mirAccessInitializerSupported(body, local.value)) return false;
            },
            .direct_call => |call| if (!self.mirAccessDirectCallSupported(body, call) or mirAccessCallReferenceCount(body, call.location) != 1) return false,
            .address_of, .deref_load, .index => |event| if (event.access_index >= body.accesses.len or !self.mirAccessValueSupported(body, body.accesses[event.access_index])) return false,
            .range_slice => |event| {
                if (event.access_index >= body.accesses.len) return false;
                if (mirAccessStructuralElidesRange(operation, event.access_index)) {
                    const range = switch (body.accesses[event.access_index]) {
                        .range_slice => |range| range,
                        else => return false,
                    };
                    if (!self.mirAccessOperandSupported(body, range.base) or
                        !self.mirAccessOperandSupported(body, range.start) or
                        !self.mirAccessOperandSupported(body, range.end) or
                        (!mirAccessIsSlice(range.base.type_ref.value_ty) and self.mirAccessArrayBound(body, range.base) == null)) return false;
                } else if (!self.mirAccessValueSupported(body, body.accesses[event.access_index])) return false;
            },
            .deref_store, .index_store => |store| if (store.target_access_index >= body.accesses.len or !self.mirAccessStoreValueSupported(body, store.value)) return false,
            .return_value => {},
        };
        return true;
    }

    fn mirAccessStructuralElidesLocal(operation: mir_access_plan.StructuralOperation, value_id: mir.ValueId) bool {
        return switch (operation) {
            .range_slice_local_then_return_builtin => |returned| returned.local.value_id.eql(value_id),
            else => false,
        };
    }

    fn mirAccessHasProjectedAddress(body: mir_access_plan.AccessBodyPlan) bool {
        for (body.accesses) |access| switch (access) {
            .address_of => |address| if (address.place.projection_count != 0) return true,
            else => {},
        };
        return false;
    }

    fn mirAccessStoreNeedsLegacyProvenance(body: mir_access_plan.AccessBodyPlan, store: mir_access_plan.Store) bool {
        if (store.target_access_index >= body.accesses.len or std.meta.activeTag(body.accesses[store.target_access_index]) != .deref) return false;
        var has_unprojected = false;
        for (body.accesses) |access| switch (access) {
            .address_of => |address| if (address.place.projection_count == 0) {
                has_unprojected = true;
            },
            else => {},
        };
        return has_unprojected and !mirAccessHasProjectedAddress(body);
    }

    fn mirAccessStructuralElidesRange(operation: mir_access_plan.StructuralOperation, access_index: usize) bool {
        return switch (operation) {
            .range_slice_local_then_return_builtin => |returned| returned.range_access_index == access_index,
            else => false,
        };
    }

    fn mirAccessStructuralRequiresPriority(body: mir_access_plan.AccessBodyPlan, operation: mir_access_plan.StructuralOperation) bool {
        switch (operation) {
            .range_slice_local_then_return_builtin => return true,
            .return_access => |returned| {
                if (returned.access_index >= body.accesses.len) return false;
                const base_id = switch (body.accesses[returned.access_index]) {
                    .index => |index| index.base.value_id orelse return false,
                    else => return false,
                };
                for (body.statements) |statement| switch (statement) {
                    .local_init => |local| {
                        if (!local.value_id.eql(base_id)) continue;
                        return switch (local.value) {
                            .access_result => |index| index < body.accesses.len and std.meta.activeTag(body.accesses[index]) == .range_slice,
                            .direct_call => |call| blk: {
                                const result_tag = std.meta.activeTag(call.result.value_ty);
                                if (!mirAccessIsSlice(call.result.value_ty) and result_tag != .array) break :blk false;
                                const indexed = switch (body.accesses[returned.access_index]) {
                                    .index => |index| index,
                                    else => break :blk false,
                                };
                                const computed_index = indexed.index.name == null and indexed.index.integer_value == null;
                                break :blk call.argument_count != 0 or computed_index;
                            },
                            else => false,
                        };
                    },
                    else => {},
                };
            },
            else => {},
        }
        return false;
    }

    fn mirAccessStructuralMaterializedCallBase(body: mir_access_plan.AccessBodyPlan, operation: mir_access_plan.StructuralOperation) bool {
        const returned = switch (operation) {
            .return_access => |returned| returned,
            else => return false,
        };
        if (returned.access_index >= body.accesses.len) return false;
        const base_id = switch (body.accesses[returned.access_index]) {
            .index => |index| index.base.value_id orelse return false,
            else => return false,
        };
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| if (local.value_id.eql(base_id)) return std.meta.activeTag(local.value) == .direct_call,
            else => {},
        };
        return false;
    }

    fn mirAccessIsSlice(value_ty: mir.ValueType) bool {
        return switch (value_ty) {
            .slice => true,
            .pointer => |shape| shape.kind == .slice,
            else => false,
        };
    }

    fn mirAccessInitializerSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, initializer: mir_access_plan.Initializer) bool {
        return switch (initializer) {
            .named => |operand| self.mirAccessOperandSupported(body, operand),
            .direct_call => |call| self.mirAccessDirectCallSupported(body, call),
            .access_result => |index| index < body.accesses.len and self.mirAccessValueSupported(body, body.accesses[index]),
            .graph => |graph| graph.count != 0 and graph.root < graph.count and self.mirAccessInitializerNodeSupported(body, graph, graph.root, 0),
        };
    }

    fn mirAccessInitializerNodeSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, graph: mir_access_plan.InitializerGraph, node_index: usize, depth: usize) bool {
        if (node_index >= graph.count or depth >= mir_access_plan.max_initializer_nodes) return false;
        return switch (graph.nodes[node_index].operation) {
            .named => |operand| self.mirAccessOperandSupported(body, operand),
            .integer_literal => true,
            .array_literal, .struct_literal => |aggregate| blk: {
                if (aggregate.count == 0) break :blk false;
                for (aggregate.children[0..aggregate.count]) |child| if (!self.mirAccessInitializerNodeSupported(body, graph, child, depth + 1)) break :blk false;
                break :blk true;
            },
        };
    }

    fn mirAccessDirectCallSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, call: mir_access_plan.DirectCall) bool {
        const signature = self.functions.get(call.callee_name) orelse return false;
        if (!call.callee_value_id.isValid() or signature.params.len != call.argument_count) return false;
        for (call.arguments[0..call.argument_count]) |argument| if (!self.mirAccessOperandSupported(body, argument)) return false;
        return true;
    }

    fn mirAccessOperandSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, operand: mir_access_plan.Operand) bool {
        if (!operand.location.span_id.isValid() or !operand.type_ref.id.isValid()) return false;
        if (operand.integer_value != null) return operand.name == null and operand.value_id == null;
        if (operand.name != null) return operand.value_id != null and operand.value_id.?.isValid();
        return self.mirAccessDirectCallAt(body, operand.location) != null;
    }

    fn mirAccessStoreValueSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, value: mir_access_plan.StoreValue) bool {
        return switch (value) {
            .operand => |operand| self.mirAccessOperandSupported(body, operand),
            .access_result => |index| index < body.accesses.len and self.mirAccessValueSupported(body, body.accesses[index]),
            .checked_binary => |binary| simpleMirScalarCInfo(binary.type_ref.value_ty) != null and self.mirAccessOperandSupported(body, binary.left) and self.mirAccessOperandSupported(body, binary.right),
            .conversion => |conversion| self.mirAccessCType(conversion.type_ref.value_ty) != null and self.mirAccessOperandSupported(body, conversion.operand),
        };
    }

    fn mirAccessValueSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access) bool {
        return switch (access) {
            .index => |index| blk: {
                if (simpleMirScalarCInfo(index.result.value_ty) == null or !self.mirAccessOperandSupported(body, index.base) or !self.mirAccessOperandSupported(body, index.index)) break :blk false;
                break :blk switch (index.base.type_ref.value_ty) {
                    .slice => index.static_bound == null,
                    .pointer => |shape| shape.kind == .slice and index.static_bound == null,
                    .array => index.static_bound != null,
                    else => false,
                };
            },
            .range_slice => |range| self.mirAccessRangeElement(body, range) != null and self.mirAccessOperandSupported(body, range.base) and self.mirAccessOperandSupported(body, range.start) and self.mirAccessOperandSupported(body, range.end) and (mirAccessIsSlice(range.base.type_ref.value_ty) or self.mirAccessArrayBound(body, range.base) != null),
            .address_of => |address| blk: {
                _ = self.mirAccessPointerCType(address.result.value_ty) catch break :blk false;
                break :blk self.mirAccessPlaceSupported(body, address.place);
            },
            .deref => |deref| simpleMirScalarCInfo(deref.result.value_ty) != null and self.mirAccessOperandSupported(body, deref.operand),
        };
    }

    fn mirAccessFieldProjectionSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, field: mir_access_plan.FieldProjection) bool {
        if (!self.mirAccessOperandSupported(body, field.base) or
            field.base.name == null or
            field.base.value_id == null or
            !field.base.value_id.?.isValid() or
            !field.result.id.isValid()) return false;
        const struct_name = switch (field.base.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return false,
        };
        const decl = self.structs.get(struct_name) orelse return false;
        if (field.field_index >= decl.fields.len) return false;
        return simpleMirScalarCInfo(field.result.value_ty) != null;
    }

    fn mirAccessBuiltinProjectionSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, member: mir_access_plan.BuiltinMemberProjection) bool {
        if (!self.mirAccessOperandSupported(body, member.base) or !member.result.id.isValid()) return false;
        return member.member == .slice_length and mirAccessIsSlice(member.base.type_ref.value_ty);
    }

    fn mirAccessPlaceSupported(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, place: mir_access_plan.AddressPlace) bool {
        if (!self.mirAccessOperandSupported(body, place.root)) return false;
        var current = place.root.type_ref.value_ty;
        if (place.root_kind == .access_result) {
            const index = place.access_index orelse return false;
            if (index >= body.accesses.len or !self.mirAccessValueSupported(body, body.accesses[index])) return false;
        }
        for (place.projections[0..place.projection_count]) |projection| switch (projection) {
            .field => |field| {
                const name = switch (current) {
                    .struct_ => |name| name,
                    else => return false,
                };
                const decl = self.structs.get(name) orelse return false;
                if (field.index >= decl.fields.len) return false;
                current = field.result.value_ty;
            },
            .constant_index => |index| {
                if (std.meta.activeTag(current) != .array or index.index >= index.bound) return false;
                current = index.result.value_ty;
            },
            .deref => |deref| {
                // A postfix `.*` source projection needs a prefix C lvalue
                // renderer with explicit parenthesization. Keep it outside
                // this bounded structural path until that renderer exists.
                _ = deref;
                return false;
            },
        };
        return true;
    }

    fn mirAccessCType(_: *CEmitter, value_ty: mir.ValueType) ?[]const u8 {
        if (primitiveCTypeName(value_ty.name())) |name| return name;
        return switch (value_ty) {
            .struct_ => |name| name,
            .address => "uintptr_t",
            else => null,
        };
    }

    fn mirAccessPointerCType(self: *CEmitter, value_ty: mir.ValueType) ![]const u8 {
        const shape = switch (value_ty) {
            .pointer => |shape| shape,
            else => return error.UnsupportedCEmission,
        };
        const child = primitiveCTypeName(shape.child) orelse if (self.structs.contains(shape.child)) shape.child else return error.UnsupportedCEmission;
        return if (shape.mutability == .mut)
            std.fmt.allocPrint(self.scratch.allocator(), "{s} *", .{child})
        else
            std.fmt.allocPrint(self.scratch.allocator(), "{s} const *", .{child});
    }

    fn mirAccessLocalCType(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, local: mir_access_plan.LocalInit) ![]const u8 {
        if (self.mirAccessCType(local.type_ref.value_ty)) |name| return name;
        return switch (local.type_ref.value_ty) {
            .pointer => |shape| if (shape.kind == .slice) blk: {
                const element = self.mirAccessElementForValueId(body, local.value_id) orelse return error.UnsupportedCEmission;
                const mutability: []const u8 = if (shape.mutability == .mut) "mut" else if (shape.mutability == .@"const") "const" else return error.UnsupportedCEmission;
                break :blk std.fmt.allocPrint(self.scratch.allocator(), "mc_slice_{s}_{s}", .{ mutability, element.race_type_name });
            } else self.mirAccessPointerCType(local.type_ref.value_ty),
            .array => blk: {
                const shape = self.mirAccessArrayShapeForLocal(body, local) orelse return error.UnsupportedCEmission;
                break :blk std.fmt.allocPrint(self.scratch.allocator(), "mc_array_{s}_{d}", .{ shape.element.race_type_name, shape.bound });
            },
            .slice => blk: {
                const element = switch (local.value) {
                    .access_result => |index| if (index < body.accesses.len) switch (body.accesses[index]) {
                        .range_slice => |range| self.mirAccessRangeElement(body, range),
                        else => null,
                    } else null,
                    else => self.mirAccessElementForValueId(body, local.value_id),
                } orelse return error.UnsupportedCEmission;
                const mutability: []const u8 = if (std.mem.eql(u8, local.type_ref.value_ty.name(), "[]mut")) "mut" else if (std.mem.eql(u8, local.type_ref.value_ty.name(), "[]const")) "const" else return error.UnsupportedCEmission;
                break :blk std.fmt.allocPrint(self.scratch.allocator(), "mc_slice_{s}_{s}", .{ mutability, element.race_type_name });
            },
            else => error.UnsupportedCEmission,
        };
    }

    const MirAccessArrayShape = struct { element: SimpleMirScalarCInfo, bound: usize };

    fn mirAccessArrayShapeForLocal(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, local: mir_access_plan.LocalInit) ?MirAccessArrayShape {
        _ = self;
        switch (local.value) {
            .graph => |graph| {
                const root = graph.nodes[graph.root];
                const aggregate = switch (root.operation) {
                    .array_literal => |aggregate| aggregate,
                    else => return null,
                };
                if (aggregate.count == 0) return null;
                const element = simpleMirScalarCInfo(graph.nodes[aggregate.children[0]].type_ref.value_ty) orelse return null;
                return .{ .element = element, .bound = aggregate.count };
            },
            else => {},
        }
        for (body.accesses) |access| switch (access) {
            .index => |index| if (index.base.name != null and std.mem.eql(u8, index.base.name.?, local.name)) return .{
                .element = simpleMirScalarCInfo(index.result.value_ty) orelse return null,
                .bound = index.static_bound orelse return null,
            },
            else => {},
        };
        return null;
    }

    fn mirAccessElementForValueId(_: *CEmitter, body: mir_access_plan.AccessBodyPlan, value_id: mir.ValueId) ?SimpleMirScalarCInfo {
        if (!value_id.isValid()) return null;
        var found: ?SimpleMirScalarCInfo = null;
        for (body.accesses) |access| switch (access) {
            .index => |index| if (index.base.value_id != null and index.base.value_id.?.eql(value_id)) {
                const candidate = simpleMirScalarCInfo(index.result.value_ty) orelse return null;
                if (found) |previous| if (!std.mem.eql(u8, previous.c_type, candidate.c_type)) return null;
                found = candidate;
            },
            else => {},
        };
        return found;
    }

    fn mirAccessRangeElement(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, range: mir_access_plan.RangeSlice) ?SimpleMirScalarCInfo {
        // Prefer the typed scalar result of an index that consumes this exact
        // materialized range. This keeps element representation independent
        // of source type spelling (TypeIdentity intentionally records only
        // the slice class/mutability today).
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| switch (local.value) {
                .access_result => |access_index| if (access_index < body.accesses.len) switch (body.accesses[access_index]) {
                    .range_slice => |candidate| if (candidate.location.span_id.eql(range.location.span_id)) {
                        if (self.mirAccessElementForValueId(body, local.value_id)) |element| return element;
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        };
        if (!range.result.id.isValid() or !body.function_symbol_id.isValid()) return null;
        const function = blk: {
            for (self.mir_module.functions) |*candidate| if (candidate.typed_symbol_id.eql(body.function_symbol_id)) break :blk candidate;
            return null;
        };
        var spelling: ?[]const u8 = null;
        for (function.type_identities) |identity| if (identity.id.eql(range.result.id)) {
            if (spelling != null) return null;
            spelling = identity.spelling;
        };
        const slice_spelling = spelling orelse return null;
        const child = if (std.mem.startsWith(u8, slice_spelling, "[]const "))
            slice_spelling["[]const ".len..]
        else if (std.mem.startsWith(u8, slice_spelling, "[]mut "))
            slice_spelling["[]mut ".len..]
        else
            return null;
        for (lower_c_shape.race_scalar_helpers) |helper| if (std.mem.eql(u8, helper.name, child)) return .{
            .c_type = helper.c_type,
            .race_type_name = helper.name,
        };
        return null;
    }

    fn mirAccessArrayBound(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, operand: mir_access_plan.Operand) ?usize {
        const name = operand.name orelse return null;
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| if (std.mem.eql(u8, local.name, name)) return (self.mirAccessArrayShapeForLocal(body, local) orelse return null).bound,
            else => {},
        };
        return null;
    }

    fn mirAccessDirectCallAt(_: *CEmitter, body: mir_access_plan.AccessBodyPlan, location: mir_access_plan.Location) ?mir_access_plan.DirectCall {
        var found: ?mir_access_plan.DirectCall = null;
        for (body.statements) |statement| switch (statement) {
            .direct_call => |call| if (call.location.span_id.eql(location.span_id)) {
                if (found != null) return null;
                found = call;
            },
            else => {},
        };
        return found;
    }

    fn mirAccessCallReferenceCount(body: mir_access_plan.AccessBodyPlan, location: mir_access_plan.Location) usize {
        var count: usize = 0;
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| count += mirAccessInitializerCallReferenceCount(local.value, location),
            .direct_call => |call| {
                for (call.arguments[0..call.argument_count]) |argument| count += mirAccessOperandCallReferenceCount(argument, location);
            },
            .deref_store, .index_store => |store| count += mirAccessStoreCallReferenceCount(store.value, location),
            .return_value => |returned| if (returned.value) |value| {
                count += mirAccessOperandCallReferenceCount(value, location);
            },
            else => {},
        };
        for (body.accesses) |access| switch (access) {
            .index => |index| {
                count += mirAccessOperandCallReferenceCount(index.base, location);
                count += mirAccessOperandCallReferenceCount(index.index, location);
            },
            .range_slice => |range| {
                count += mirAccessOperandCallReferenceCount(range.base, location);
                count += mirAccessOperandCallReferenceCount(range.start, location);
                count += mirAccessOperandCallReferenceCount(range.end, location);
            },
            .address_of => |address| count += mirAccessOperandCallReferenceCount(address.operand, location),
            .deref => |deref| count += mirAccessOperandCallReferenceCount(deref.operand, location),
        };
        return count;
    }

    fn mirAccessInitializerCallReferenceCount(initializer: mir_access_plan.Initializer, location: mir_access_plan.Location) usize {
        return switch (initializer) {
            .direct_call => |call| @intFromBool(call.location.span_id.eql(location.span_id)),
            .named, .access_result, .graph => 0,
        };
    }

    fn mirAccessOperandCallReferenceCount(operand: mir_access_plan.Operand, location: mir_access_plan.Location) usize {
        return @intFromBool(operand.name == null and operand.integer_value == null and operand.location.span_id.eql(location.span_id));
    }

    fn mirAccessStoreCallReferenceCount(value: mir_access_plan.StoreValue, location: mir_access_plan.Location) usize {
        return switch (value) {
            .operand => |operand| mirAccessOperandCallReferenceCount(operand, location),
            .checked_binary => |binary| mirAccessOperandCallReferenceCount(binary.left, location) + mirAccessOperandCallReferenceCount(binary.right, location),
            .conversion => |conversion| mirAccessOperandCallReferenceCount(conversion.operand, location),
            .access_result => 0,
        };
    }

    fn emitMirAccessStructuralPlan(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, operation: mir_access_plan.StructuralOperation) !void {
        for (body.statements) |statement| switch (statement) {
            .local_init => |local| {
                if (mirAccessStructuralElidesLocal(operation, local.value_id)) continue;
                try self.emitMirAccessPrecheckForInitializer(body, local.value);
                try self.writeLineDirective(spanFromMirSourcePoint(local.declaration.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.mirAccessLocalCType(body, local), try self.cIdent(local.name) });
                try self.emitMirAccessInitializer(body, local.value);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            else => {},
        };
        switch (operation) {
            .return_access => |returned| {
                try self.emitMirAccessPrecheck(body, body.accesses[returned.access_index]);
                try self.writeLineDirective(spanFromMirSourcePoint(returned.location.source));
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return ");
                try self.emitMirAccessLoadValue(body, body.accesses[returned.access_index]);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .store_access_then_return => |stored| {
                const access = body.accesses[stored.store.target_access_index];
                try self.emitMirAccessPrecheck(body, access);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.store.location.source));
                try self.emitMirAccessStore(body, access, stored.store.value);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.return_location.source));
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return;\n");
            },
            .store_access_then_return_access => |stored| {
                const target = body.accesses[stored.store.target_access_index];
                try self.emitMirAccessPrecheck(body, target);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.store.location.source));
                try self.emitMirAccessStore(body, target, stored.store.value);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.return_location.source));
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return ");
                switch (stored.value) {
                    .access_result => |index| {
                        try self.emitMirAccessPrecheck(body, body.accesses[index]);
                        try self.emitMirAccessLoadValue(body, body.accesses[index]);
                    },
                    .field => |field| try self.emitMirAccessFieldLoad(body, field),
                }
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .store_access_then_return_operand => |stored| {
                const target = body.accesses[stored.store.target_access_index];
                try self.emitMirAccessPrecheck(body, target);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.store.location.source));
                try self.emitMirAccessStore(body, target, stored.store.value);
                try self.writeLineDirective(spanFromMirSourcePoint(stored.return_location.source));
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return ");
                try self.emitMirAccessLoadedOperand(body, stored.value);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .range_slice_local_then_return_builtin => |returned| {
                const range = switch (body.accesses[returned.range_access_index]) {
                    .range_slice => |range| range,
                    else => return error.UnsupportedCEmission,
                };
                try self.emitMirAccessRangeLengthReturn(body, range, returned.return_location);
            },
        }
    }

    fn emitMirAccessRangeLengthReturn(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, range: mir_access_plan.RangeSlice, return_location: mir_access_plan.Location) !void {
        try self.emitMirAccessPrecheck(body, .{ .range_slice = range });
        const start = try self.nextTempName();
        const end = try self.nextTempName();
        const length = try self.nextTempName();
        try self.writeIndent();
        try self.out.print(self.allocator, "uintptr_t {s} = ", .{start});
        try self.emitMirAccessOperand(body, range.start);
        try self.out.appendSlice(self.allocator, ";\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "uintptr_t {s} = ", .{end});
        try self.emitMirAccessOperand(body, range.end);
        try self.out.appendSlice(self.allocator, ";\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "uintptr_t {s} = ", .{length});
        switch (range.base.type_ref.value_ty) {
            .slice => {
                try self.emitMirAccessOperand(body, range.base);
                try self.out.appendSlice(self.allocator, ".len");
            },
            .pointer => |shape| if (shape.kind == .slice) {
                try self.emitMirAccessOperand(body, range.base);
                try self.out.appendSlice(self.allocator, ".len");
            } else return error.UnsupportedCEmission,
            .array => try self.out.print(self.allocator, "{d}", .{self.mirAccessArrayBound(body, range.base) orelse return error.UnsupportedCEmission}),
            else => return error.UnsupportedCEmission,
        }
        try self.out.appendSlice(self.allocator, ";\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} > {s} || {s} > {s}) mc_trap_Bounds();\n", .{ start, end, end, length });
        try self.writeLineDirective(spanFromMirSourcePoint(return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s} - {s};\n", .{ end, start });
    }

    fn emitMirAccessPrecheckForInitializer(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, initializer: mir_access_plan.Initializer) !void {
        switch (initializer) {
            .access_result => |index| try self.emitMirAccessPrecheck(body, body.accesses[index]),
            else => {},
        }
    }

    fn emitMirAccessPrecheck(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access) !void {
        const base = switch (access) {
            .index => |index| if (mirAccessIsSlice(index.base.type_ref.value_ty)) index.base else return,
            .range_slice => |range| if (mirAccessIsSlice(range.base.type_ref.value_ty)) range.base else return,
            else => return,
        };
        const name = base.name orelse return;
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s}.ptr == NULL && {s}.len != 0) mc_trap_InvalidRepresentation();\n", .{ try self.cIdent(name), try self.cIdent(name) });
        _ = body;
    }

    fn emitMirAccessInitializer(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, initializer: mir_access_plan.Initializer) !void {
        switch (initializer) {
            .named => |operand| try self.emitMirAccessOperand(body, operand),
            .direct_call => |call| try self.emitMirAccessCall(body, call),
            .access_result => |index| try self.emitMirAccessValue(body, body.accesses[index]),
            .graph => |graph| try self.emitMirAccessInitializerNode(body, graph, graph.root),
        }
    }

    fn emitMirAccessInitializerNode(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, graph: mir_access_plan.InitializerGraph, node_index: usize) anyerror!void {
        const node = graph.nodes[node_index];
        switch (node.operation) {
            .named => |operand| try self.emitMirAccessOperand(body, operand),
            .integer_literal => |literal| try self.out.print(self.allocator, "{d}", .{literal.value}),
            .array_literal => |aggregate| {
                const element = simpleMirScalarCInfo(graph.nodes[aggregate.children[0]].type_ref.value_ty) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "(mc_array_{s}_{d}){{ .elems = {{ ", .{ element.race_type_name, aggregate.count });
                for (aggregate.children[0..aggregate.count], 0..) |child, index| {
                    if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitMirAccessInitializerNode(body, graph, child);
                }
                try self.out.appendSlice(self.allocator, " } }");
            },
            .struct_literal => |aggregate| {
                const name = switch (node.type_ref.value_ty) {
                    .struct_ => |name| name,
                    else => return error.UnsupportedCEmission,
                };
                const decl = self.structs.get(name) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "({s}){{ ", .{name});
                for (aggregate.children[0..aggregate.count], 0..) |child, index| {
                    if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                    const field_index = aggregate.field_indices[index];
                    if (field_index >= decl.fields.len) return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(decl.fields[field_index].name.text)});
                    try self.emitMirAccessInitializerNode(body, graph, child);
                }
                try self.out.appendSlice(self.allocator, " }");
            },
        }
    }

    fn emitMirAccessOperand(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, operand: mir_access_plan.Operand) anyerror!void {
        if (operand.integer_value) |value| return self.out.print(self.allocator, "{d}", .{value});
        if (operand.name) |name| return self.out.appendSlice(self.allocator, try self.cIdent(name));
        const call = self.mirAccessDirectCallAt(body, operand.location) orelse return error.UnsupportedCEmission;
        try self.emitMirAccessCall(body, call);
    }

    fn emitMirAccessLoadedOperand(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, operand: mir_access_plan.Operand) anyerror!void {
        if (operand.name) |name| {
            if (self.globals.get(name)) |global| return appendGlobalLoadExpr(self.allocator, self.out, name, global);
        }
        try self.emitMirAccessOperand(body, operand);
    }

    fn emitMirAccessFieldLoad(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, field: mir_access_plan.FieldProjection) anyerror!void {
        const struct_name = switch (field.base.type_ref.value_ty) {
            .struct_ => |name| name,
            else => return error.UnsupportedCEmission,
        };
        const decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
        if (field.field_index >= decl.fields.len) return error.UnsupportedCEmission;
        const scalar = simpleMirScalarCInfo(field.result.value_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ scalar.c_type, scalar.race_type_name });
        try self.emitMirAccessOperand(body, field.base);
        try self.out.print(self.allocator, ".{s})))", .{try self.cIdent(decl.fields[field.field_index].name.text)});
    }

    fn emitMirAccessCall(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, call: mir_access_plan.DirectCall) anyerror!void {
        try self.out.print(self.allocator, "{s}(", .{try self.cIdent(call.callee_name)});
        for (call.arguments[0..call.argument_count], 0..) |argument, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitMirAccessOperand(body, argument);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitMirAccessLoadValue(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access) anyerror!void {
        switch (access) {
            .index, .deref => {
                const result = switch (access) {
                    .index => |index| index.result.value_ty,
                    .deref => |deref| deref.result.value_ty,
                    else => unreachable,
                };
                const scalar = simpleMirScalarCInfo(result) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "(({s})mc_race_load_{s}(", .{ scalar.c_type, scalar.race_type_name });
                try self.emitMirAccessAddress(body, access);
                try self.out.appendSlice(self.allocator, "))");
            },
            .address_of, .range_slice => try self.emitMirAccessValue(body, access),
        }
    }

    fn emitMirAccessValue(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access) anyerror!void {
        switch (access) {
            .index, .deref => try self.emitMirAccessLoadValue(body, access),
            .address_of => |address| {
                try self.out.appendSlice(self.allocator, "&");
                try self.emitMirAccessPlace(body, address.place);
            },
            .range_slice => |range| try self.emitMirAccessRange(body, range),
        }
    }

    fn emitMirAccessAddress(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access) !void {
        switch (access) {
            .index => |index| {
                try self.out.appendSlice(self.allocator, "&(");
                try self.emitMirAccessOperand(body, index.base);
                switch (index.base.type_ref.value_ty) {
                    .slice => {
                        try self.out.appendSlice(self.allocator, ".ptr[mc_check_index_usize(");
                        try self.emitMirAccessOperand(body, index.index);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitMirAccessOperand(body, index.base);
                        try self.out.appendSlice(self.allocator, ".len)]");
                    },
                    .pointer => |shape| if (shape.kind == .slice) {
                        try self.out.appendSlice(self.allocator, ".ptr[mc_check_index_usize(");
                        try self.emitMirAccessOperand(body, index.index);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitMirAccessOperand(body, index.base);
                        try self.out.appendSlice(self.allocator, ".len)]");
                    } else return error.UnsupportedCEmission,
                    .array => {
                        try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
                        try self.emitMirAccessOperand(body, index.index);
                        try self.out.print(self.allocator, ", {d})]", .{index.static_bound orelse return error.UnsupportedCEmission});
                    },
                    else => return error.UnsupportedCEmission,
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .deref => |deref| try self.emitMirAccessOperand(body, deref.operand),
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitMirAccessPlace(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, place: mir_access_plan.AddressPlace) anyerror!void {
        if (place.root_kind == .access_result) {
            try self.emitMirAccessValue(body, body.accesses[place.access_index orelse return error.UnsupportedCEmission]);
        } else {
            try self.emitMirAccessOperand(body, place.root);
        }
        var current = place.root.type_ref.value_ty;
        for (place.projections[0..place.projection_count]) |projection| switch (projection) {
            .field => |field| {
                const name = switch (current) {
                    .struct_ => |name| name,
                    else => return error.UnsupportedCEmission,
                };
                const decl = self.structs.get(name) orelse return error.UnsupportedCEmission;
                if (field.index >= decl.fields.len) return error.UnsupportedCEmission;
                try self.out.print(self.allocator, ".{s}", .{try self.cIdent(decl.fields[field.index].name.text)});
                current = field.result.value_ty;
            },
            .constant_index => |index| {
                try self.out.print(self.allocator, ".elems[{d}]", .{index.index});
                current = index.result.value_ty;
            },
            .deref => |deref| {
                try self.out.appendSlice(self.allocator, ".*");
                current = deref.result.value_ty;
            },
        };
    }

    fn emitMirAccessRange(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, range: mir_access_plan.RangeSlice) !void {
        const element = self.mirAccessRangeElement(body, range) orelse return error.UnsupportedCEmission;
        const mutability: []const u8 = if (std.mem.eql(u8, range.result.value_ty.name(), "[]mut")) "mut" else if (std.mem.eql(u8, range.result.value_ty.name(), "[]const")) "const" else return error.UnsupportedCEmission;
        const temp = self.temp_index;
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ uintptr_t mc_start{d} = ", .{temp});
        try self.emitMirAccessOperand(body, range.start);
        try self.out.print(self.allocator, "; uintptr_t mc_end{d} = ", .{temp});
        try self.emitMirAccessOperand(body, range.end);
        try self.out.print(self.allocator, "; uintptr_t mc_len{d} = ", .{temp});
        switch (range.base.type_ref.value_ty) {
            .slice => {
                try self.emitMirAccessOperand(body, range.base);
                try self.out.appendSlice(self.allocator, ".len");
            },
            .pointer => |shape| if (shape.kind == .slice) {
                try self.emitMirAccessOperand(body, range.base);
                try self.out.appendSlice(self.allocator, ".len");
            } else return error.UnsupportedCEmission,
            .array => try self.out.print(self.allocator, "{d}", .{self.mirAccessArrayBound(body, range.base) orelse return error.UnsupportedCEmission}),
            else => return error.UnsupportedCEmission,
        }
        try self.out.print(self.allocator, "; if (mc_start{d} > mc_end{d} || mc_end{d} > mc_len{d}) mc_trap_Bounds(); (mc_slice_{s}_{s}){{ .ptr = ", .{ temp, temp, temp, temp, mutability, element.race_type_name });
        try self.emitMirAccessOperand(body, range.base);
        try self.out.appendSlice(self.allocator, if (mirAccessIsSlice(range.base.type_ref.value_ty)) ".ptr" else ".elems");
        try self.out.print(self.allocator, " + mc_start{d}, .len = mc_end{d} - mc_start{d} }}; }})", .{ temp, temp, temp });
    }

    fn emitMirAccessStore(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, access: mir_access_plan.Access, value: mir_access_plan.StoreValue) !void {
        const result_ty = switch (access) {
            .index => |index| index.result.value_ty,
            .deref => |deref| deref.result.value_ty,
            else => return error.UnsupportedCEmission,
        };
        const scalar = simpleMirScalarCInfo(result_ty) orelse return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_{s}(", .{scalar.race_type_name});
        try self.emitMirAccessAddress(body, access);
        try self.out.print(self.allocator, ", ({s})", .{scalar.c_type});
        try self.emitMirAccessStoreValue(body, value);
        try self.out.appendSlice(self.allocator, ");\n");
    }

    fn emitMirAccessStoreValue(self: *CEmitter, body: mir_access_plan.AccessBodyPlan, value: mir_access_plan.StoreValue) !void {
        switch (value) {
            .operand => |operand| try self.emitMirAccessOperand(body, operand),
            .access_result => |index| try self.emitMirAccessLoadValue(body, body.accesses[index]),
            .checked_binary => |binary| {
                try self.out.print(self.allocator, "{s}(", .{try self.checkedHelperName(binary.op, binary.type_ref.value_ty.name())});
                try self.emitMirAccessOperand(body, binary.left);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitMirAccessOperand(body, binary.right);
                try self.out.appendSlice(self.allocator, ")");
            },
            .conversion => |conversion| {
                try self.out.print(self.allocator, "({s})", .{self.mirAccessCType(conversion.type_ref.value_ty) orelse return error.UnsupportedCEmission});
                try self.emitMirAccessOperand(body, conversion.operand);
            },
        }
    }

    fn mirScalarExpressionSourceTypeIs(self: *CEmitter, source_ty: TransitionalTypeExpr, expected: []const u8) bool {
        const name = typeName(self.resolveAliasType(source_ty)) orelse return false;
        return std.mem.eql(u8, name, expected);
    }

    fn simpleMirReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirReturn {
        if (fn_mir.blocks.len == 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const block = fn_mir.blocks[0];
        if (block.terminator != .return_) return null;
        const ret = simpleMirReturnInstruction(block) orelse return null;
        if (self.simpleMirAggregateReturnPointerLoad(function, fn_mir, block, ret)) |load| {
            return .{ .aggregate_return_pointer_load = load };
        }
        if (!self.blockOnlyContainsSimpleMirReturnInstructions(function, fn_mir)) return null;
        if (self.simpleMirScalarDerefLoadReturn(function, fn_mir, block, ret)) |load| {
            return .{ .scalar_deref_load = load };
        }
        if (self.simpleMirScalarFieldLoadReturn(function, fn_mir, block, ret)) |load| {
            return .{ .scalar_field_load = load };
        }
        if (ret.result_ty == .void or std.mem.eql(u8, ret.detail, "void")) return if (simpleMirNoTrap(fn_mir)) .void else null;
        const value_id = ret.value_id orelse return null;
        for (function.signature.params) |param| {
            // A bare `return p` renders `return p;` regardless of trap edges: the
            // only trap a bare param return can carry is a `nonnull_pointer`
            // representation check, which the fallback statically elides (a bare
            // param return never narrows — nullable and non-null both emit
            // `return p;`). So admit it even with such an (elided) trap edge.
            if (std.mem.eql(u8, value_id, param.name.text)) {
                if (simpleMirNoTrap(fn_mir) or simpleMirAllTrapEdgesRepresentationChecks(fn_mir)) return .{ .param = param.name.text };
                return null;
            }
        }
        if (self.simpleMirParamFieldReturn(function, block, ret, value_id)) |field| return if (simpleMirNoTrap(fn_mir)) .{ .param_field = field } else null;
        if (self.globals.contains(value_id)) return if (simpleMirNoTrap(fn_mir)) .{ .global_load = value_id } else null;
        if (simpleMirReturnValueSource(block, value_id)) |source| {
            if (self.simpleMirGlobalAddressAtValueSource(fn_mir, source)) |name| return if (simpleMirNoTrap(fn_mir)) .{ .global_address = name } else null;
        }
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
                    const value = numeric.parseCharLiteral(fact.literal) orelse return null;
                    const literal = std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) catch return null;
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
        if (std.mem.eql(u8, value_id, "float")) {
            const source = simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret);
            if (self.simpleMirFloatLiteralAtSource(fn_mir, source)) |literal| return if (simpleMirNoTrap(fn_mir)) .{ .float_literal = literal } else null;
        }
        if (mirFunctionHasLocal(fn_mir, value_id)) {
            const source = simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret);
            if (self.simpleMirLocalFloatLiteral(function, fn_mir, block, value_id, source)) |literal| return if (simpleMirNoTrap(fn_mir)) .{ .float_literal = literal } else null;
        }
        if (self.simpleMirNullLiteralAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) |literal| {
            return if (simpleMirNoTrap(fn_mir)) .{ .null_literal = literal } else null;
        }
        if (self.simpleMirWrappingBinaryReturn(function, fn_mir, block, value_id)) |binary| return .{ .wrapping_binary = binary };
        if (self.simpleMirDomainBinaryReturn(function, fn_mir, block, value_id)) |binary| return .{ .wrapping_binary = binary };
        if (self.simpleMirUncheckedBinaryReturn(function, fn_mir, block, value_id)) |binary| return .{ .wrapping_binary = binary };
        if (self.simpleMirLocalInitCallReturn(function, fn_mir, block, value_id)) |local_return| return .{ .local_init_call_return = local_return };
        if (self.simpleMirDirectCall(function, fn_mir, value_id)) |call| {
            if (fn_mir.trap_edges.len == simpleMirDirectCallReturnTrapCount(fn_mir, call)) return .{ .direct_call = call };
        }
        if (self.simpleMirResultConstructorReturn(function, fn_mir, block, value_id)) |constructor| {
            if (fn_mir.trap_edges.len == simpleMirResultConstructorPayloadTrapCount(constructor.payload)) return .{ .result_constructor = constructor };
        }
        if (std.mem.eql(u8, value_id, "cast")) {
            if (self.simpleMirExplicitCastReturn(function, fn_mir)) |cast| return .{ .explicit_cast_return = cast };
        }
        if (self.simpleMirTypedUnaryCallTargetReturn(function, fn_mir, value_id)) |conversion| return .{ .conversion_return = conversion };
        if (std.mem.eql(u8, value_id, "struct_literal")) {
            if (self.simpleMirStructLiteralReturn(function, fn_mir, block)) |literal| return .{ .struct_literal = literal };
        }
        if (std.mem.eql(u8, value_id, "array_literal")) {
            if (self.simpleMirArrayLiteralReturn(function, fn_mir, block)) |literal| return .{ .array_literal = literal };
        }
        if (std.mem.eql(u8, value_id, "binary")) {
            if (self.simpleMirPlainFloatBinaryAtReturn(function, fn_mir)) |binary| return .{ .plain_float_binary = binary };
            if (self.simpleMirPlainUnsignedBinaryReturn(function, fn_mir)) |binary| return .{ .plain_float_binary = binary };
            if (self.simpleMirCheckedBinaryAtReturn(function, fn_mir)) |binary| return .{ .checked_binary = binary };
            if (self.simpleMirCompareBinaryAtReturn(function, fn_mir)) |binary| return .{ .compare_binary = binary };
        }
        if (std.mem.eql(u8, value_id, "unary")) {
            if (self.simpleMirLogicalNotAtReturn(function, fn_mir)) |arg| return .{ .logical_not = arg };
            if (self.simpleMirCheckedUnaryAtReturn(function, fn_mir)) |unary| {
                if (self.simpleMirFoldedNegatedIntegerLiteral(unary)) |literal| return .{ .checked_integer_literal = literal };
                return .{ .checked_unary = unary };
            }
            if (self.simpleMirPlainUnaryReturn(function, fn_mir)) |unary| return .{ .plain_unary = unary };
        }
        if (self.simpleMirAssignmentReturn(function, fn_mir, value_id)) |assigned| return assigned;
        if (self.simpleMirLocalInitReturn(function, fn_mir, value_id)) |local_init| return local_init;
        return null;
    }

    fn simpleMirWrappingBinaryReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirWrappingBinary {
        const call_source = simpleMirReturnValueSource(block, value_id) orelse return null;
        const return_ty = function.signature.transitionalReturnType() orelse return null;
        const expected_type_name = type_bridge.typeName(self.resolveAliasType(return_ty)) orelse
            (self.cTypeFor(return_ty, .typedef_name) catch return null);
        return self.simpleMirWrappingBinaryAtSource(function, fn_mir, call_source, expected_type_name);
    }

    fn simpleMirDomainBinaryReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirWrappingBinary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        const call_source = simpleMirReturnedCallSource(block, value_id) orelse return null;
        var call_target: ?mir.CallTargetFact = null;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, call_source)) continue;
            switch (fact.kind) {
                .serial_before, .serial_after, .serial_distance, .counter_delta_mod => {},
                else => continue,
            }
            if (call_target != null) return null;
            call_target = fact;
        }
        const call_target_fact = call_target orelse return null;
        const domain_kind = call_target_fact.kind;
        const info = mir.domainCallFactInfo(domain_kind) orelse return null;
        var canonical_call_source: mir.SourcePoint = undefined;
        var call_count: usize = 0;
        for (block.instructions) |instruction| {
            if (instruction.kind != .call or !sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) continue;
            if (!std.mem.eql(u8, instruction.detail, info.op)) return null;
            canonical_call_source = instructionSourcePoint(instruction);
            call_count += 1;
        }
        if (call_count != 1) return null;

        const domain_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .domain_type, canonical_call_source) orelse return null;
        const payload_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .domain_payload, canonical_call_source) orelse return null;
        const result_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .domain_result, canonical_call_source) orelse return null;
        if (!sameSimpleMirValueType(call_target_fact.result_ty, result_fact.result_ty)) return null;
        const domain = switch (self.resolveAliasType(domain_fact.target_ty).kind) {
            .generic => |node| node,
            else => return null,
        };
        const expected_domain_name: []const u8 = switch (domain_kind) {
            .serial_before, .serial_after, .serial_distance => "serial",
            .counter_delta_mod => "counter",
            else => return null,
        };
        if (!std.mem.eql(u8, domain.base.text, expected_domain_name) or domain.args.len != 1) return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(domain.args[0]), self.resolveAliasType(payload_fact.target_ty))) return null;
        const inner_name = self.underlyingIntTypeName(payload_fact.target_ty) orelse return null;
        if (unsignedTypeSuffix(inner_name) == null or signedCTypeForInner(inner_name) == null) return null;
        if (!std.mem.eql(u8, self.cTypeFor(domain_fact.target_ty, .typedef_name) catch return null, self.cTypeFor(payload_fact.target_ty, .typedef_name) catch return null)) return null;

        switch (domain_kind) {
            .serial_before, .serial_after => if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result_fact.target_ty), type_bridge.simpleNameType("bool", result_fact.target_ty.span))) return null,
            .serial_distance, .counter_delta_mod => {
                const result = switch (self.resolveAliasType(result_fact.target_ty).kind) {
                    .generic => |node| node,
                    else => return null,
                };
                if (!std.mem.eql(u8, result.base.text, "wrap") or result.args.len != 1 or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(result.args[0]), self.resolveAliasType(payload_fact.target_ty))) return null;
            },
            else => return null,
        }
        const declared_return = function.signature.transitionalReturnType() orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(result_fact.target_ty))) return null;

        const left_fact = simpleMirUniqueTypedCallOperandFactAt(fn_mir, canonical_call_source, domain_kind, 0) orelse return null;
        const right_fact = simpleMirUniqueTypedCallOperandFactAt(fn_mir, canonical_call_source, domain_kind, 1) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(left_fact.target_ty), self.resolveAliasType(domain_fact.target_ty)) or
            !type_bridge.sameTypeSyntax(self.resolveAliasType(right_fact.target_ty), self.resolveAliasType(domain_fact.target_ty))) return null;
        const left_instruction = simpleMirTypedLeafOperandInstruction(block, left_fact.source) orelse return null;
        const right_instruction = simpleMirTypedLeafOperandInstruction(block, right_fact.source) orelse return null;
        const left = self.simpleMirTypedLeafOperandAtInstruction(function, fn_mir, left_instruction) orelse return null;
        const right = self.simpleMirTypedLeafOperandAtInstruction(function, fn_mir, right_instruction) orelse return null;
        const render_kind: @TypeOf(@as(SimpleMirWrappingBinary, undefined).kind) = switch (domain_kind) {
            .serial_before => .serial_before,
            .serial_after => .serial_after,
            .serial_distance => .serial_distance,
            .counter_delta_mod => .counter_delta_mod,
            else => return null,
        };
        return .{ .kind = render_kind, .op = "sub", .operation_fact = payload_fact, .result_fact = result_fact, .left = left, .right = right };
    }

    fn simpleMirPlainFloatBinaryAtReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirPlainFloatBinary {
        return self.simpleMirPlainFloatBinaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .binary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirAggregateReturnPointerLoad(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, ret: mir.Instruction) ?SimpleMirAggregateReturnPointerLoad {
        if (!std.mem.eql(u8, ret.value_id orelse return null, "deref")) return null;
        const load_instruction = self.simpleMirReturnedPointerFieldLoad(block) orelse return null;
        if (!simpleMirCFieldPath(load_instruction.detail)) return null;
        const source = instructionSourcePoint(load_instruction);
        const local_name = self.simpleMirAggregateBaseLocalAtSource(block, source) orelse return null;
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        const call = self.simpleMirDirectCallAtSource(function, fn_mir, init_source) orelse return null;
        if (!self.mirOwnsAggregateReturnSummary(call.callee)) return null;
        const fact = self.simpleMirAggregateReturnPointerFact(call.callee, load_instruction.detail) orelse return null;
        if (fact.provenance != .global_storage) return null;
        return .{
            .call = call,
            .fact = fact,
            .pointee_ty = ret.result_ty,
        };
    }

    fn simpleMirReturnedPointerFieldLoad(self: *CEmitter, block: mir.Block) ?mir.Instruction {
        _ = self;
        var candidate: ?mir.Instruction = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .typed_load) {
                candidate = instruction;
                continue;
            }
            if (instruction.kind == .representation_use and std.mem.eql(u8, instruction.detail, "deref_base")) {
                if (candidate) |load| {
                    if (std.mem.eql(u8, load.value_id orelse "", instruction.value_id orelse "") and
                        sameMirSourceLocation(instructionSourcePoint(load), instructionSourcePoint(instruction)))
                    {
                        return load;
                    }
                }
            }
        }
        return null;
    }

    // `return p.*` where `p` is a bare param pointer and the pointee is a scalar.
    // Rendered through the race-tolerant load helper, matching the fallback's
    // default (conservative-provenance) form. Gated narrowly for soundness:
    //   - no sanitizer profile (those wrap the load differently),
    //   - `p` has no recorded pointer provenance (so the conservative race-load
    //     is exactly what the fallback emits — a proven-local pointer would use a
    //     plain deref, so defer to the fallback),
    //   - the pointer is a bare param (not a field path — aggregates handle those),
    //   - no folded local (keeps source-map fidelity).
    // Its only trap edge is the elided nonnull representation check (see .param).
    fn simpleMirScalarDerefLoadReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, ret: mir.Instruction) ?SimpleMirScalarDerefLoad {
        if (self.ksan or self.msan or self.csan) return null;
        if (!std.mem.eql(u8, ret.value_id orelse return null, "deref")) return null;
        // Gate on the DECLARED return type, not ret.result_ty: the MIR return
        // instruction records the payload representation (u32) for an optional
        // `?u32` too, so result_ty cannot tell a plain scalar from an optional
        // (which needs a tag+value load, not a single scalar load).
        const return_ty = function.signature.transitionalReturnType() orelse return null;
        const return_ty_name = type_bridge.typeName(self.resolveAliasType(return_ty)) orelse return null;
        var is_plain_scalar = type_bridge.isOpaqueAddressTypeName(return_ty_name);
        for (lower_c_shape.race_scalar_helpers) |helper| {
            if (std.mem.eql(u8, helper.name, return_ty_name)) {
                is_plain_scalar = true;
                break;
            }
        }
        if (!is_plain_scalar) return null;
        if (simpleMirScalarLikeCInfo(ret.result_ty) == null) return null;
        if (simpleMirEntryBlockFoldsLocal(fn_mir)) return null;
        const load = self.simpleMirReturnedPointerFieldLoad(block) orelse return null;
        const ptr_id = load.value_id orelse return null;
        var is_param = false;
        for (function.signature.params) |param| {
            if (std.mem.eql(u8, param.name.text, ptr_id)) {
                is_param = true;
                break;
            }
        }
        if (!is_param) return null;
        if (self.mir_pointer_local_provenance.get(ptr_id) != null) return null;
        return .{ .param_name = ptr_id, .pointee_ty = ret.result_ty };
    }

    // `return r.a` for a scalar field of the struct a bare param pointer `r`
    // points at. Same narrow gating as the scalar deref: no sanitizer, no
    // provenance, no folded local; and the DECLARED field type must equal the
    // MIR result_ty name so an optional field (whose result_ty records only the
    // payload) is excluded — it needs a tag+value load, not a single scalar load.
    fn simpleMirScalarFieldLoadReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, ret: mir.Instruction) ?SimpleMirScalarFieldLoad {
        if (self.ksan or self.msan or self.csan) return null;
        if (simpleMirEntryBlockFoldsLocal(fn_mir)) return null;
        const field_name = ret.value_id orelse return null;
        if (simpleMirScalarLikeCInfo(ret.result_ty) == null) return null;
        var ptr_param: ?[]const u8 = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .typed_load) ptr_param = instruction.value_id;
        }
        const param_name = ptr_param orelse return null;
        if (self.mir_pointer_local_provenance.get(param_name) != null) return null;
        for (function.signature.params) |param| {
            if (!std.mem.eql(u8, param.name.text, param_name)) continue;
            const pointer = switch (self.resolveAliasType(param.ty).kind) {
                .pointer => |pointer| pointer,
                else => return null,
            };
            const struct_name = type_bridge.typeName(self.resolveAliasType(pointer.child.*)) orelse return null;
            const struct_decl = self.structs.get(struct_name) orelse return null;
            for (struct_decl.fields) |field| {
                if (!std.mem.eql(u8, field.name.text, field_name)) continue;
                const field_type_name = type_bridge.typeName(self.resolveAliasType(field.ty)) orelse return null;
                if (!std.mem.eql(u8, field_type_name, ret.result_ty.name())) return null;
                return .{ .param_name = param_name, .field_name = field_name, .field_ty = ret.result_ty };
            }
            return null;
        }
        return null;
    }

    fn simpleMirAggregateBaseLocalAtSource(self: *CEmitter, block: mir.Block, source: mir.SourcePoint) ?[]const u8 {
        _ = self;
        var candidate: ?[]const u8 = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) break;
            if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
            if (instruction.kind != .expr) continue;
            if (!mirBlockHasLocal(block, instruction.detail)) continue;
            candidate = instruction.detail;
        }
        return candidate;
    }

    fn simpleMirAggregateReturnPointerFact(self: *CEmitter, callee: []const u8, field_path: []const u8) ?mir.AggregateReturnPointerFact {
        for (self.mir_module.aggregate_return_pointer_facts) |fact| {
            if (!std.mem.eql(u8, fact.callee, callee)) continue;
            if (!std.mem.eql(u8, fact.field_path, field_path)) continue;
            return fact;
        }
        return null;
    }

    fn simpleMirCFieldPath(field_path: []const u8) bool {
        var index: usize = 0;
        var expect_field_start = true;
        while (index < field_path.len) {
            const ch = field_path[index];
            if (expect_field_start) {
                if (!isSimpleMirFieldPathIdentStart(ch)) return false;
                expect_field_start = false;
                index += 1;
                continue;
            }
            if (isSimpleMirFieldPathIdentContinue(ch)) {
                index += 1;
                continue;
            }
            if (ch == '.') {
                expect_field_start = true;
                index += 1;
                continue;
            }
            if (ch == '[') {
                index += 1;
                const start = index;
                while (index < field_path.len and std.ascii.isDigit(field_path[index])) : (index += 1) {}
                if (index == start or index >= field_path.len or field_path[index] != ']') return false;
                index += 1;
                continue;
            }
            return false;
        }
        return !expect_field_start;
    }

    fn isSimpleMirFieldPathIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isSimpleMirFieldPathIdentContinue(ch: u8) bool {
        return isSimpleMirFieldPathIdentStart(ch) or std.ascii.isDigit(ch);
    }

    fn simpleMirWrappingBinaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint, expected_type_name: []const u8) ?SimpleMirWrappingBinary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        var call_target_count: usize = 0;
        for (fn_mir.call_target_facts) |fact| {
            if (fact.kind == .wrapping_add and sameMirSourceLocation(fact.source, call_source)) {
                call_target_count += 1;
            }
        }
        if (call_target_count != 1) return null;
        var call_block: ?mir.Block = null;
        var canonical_call_source: mir.SourcePoint = undefined;
        var call_count: usize = 0;
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) {
                    if (!std.mem.eql(u8, instruction.detail, "wrapping.add")) return null;
                    call_block = block;
                    canonical_call_source = instructionSourcePoint(instruction);
                    call_count += 1;
                }
            }
        }
        if (call_count != 1) return null;
        const block = call_block orelse return null;

        const result_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .wrapping_result, canonical_call_source) orelse return null;
        const result_name = type_bridge.typeName(self.resolveAliasType(result_fact.target_ty)) orelse
            (self.cTypeFor(result_fact.target_ty, .typedef_name) catch return null);
        if (!std.mem.eql(u8, expected_type_name, result_name) and !std.mem.eql(u8, expected_type_name, self.cTypeFor(result_fact.target_ty, .typedef_name) catch return null)) return null;
        const inner_name = self.underlyingIntTypeName(result_fact.target_ty) orelse return null;
        if (unsignedTypeSuffix(inner_name) == null) return null;
        const left_operand_fact = simpleMirUniqueTypedCallOperandFactAt(fn_mir, canonical_call_source, .wrapping_add, 0) orelse return null;
        const right_operand_fact = simpleMirUniqueTypedCallOperandFactAt(fn_mir, canonical_call_source, .wrapping_add, 1) orelse return null;
        const left_type_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .wrapping_left, left_operand_fact.source) orelse return null;
        const right_type_fact = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .wrapping_right, right_operand_fact.source) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(left_operand_fact.target_ty), self.resolveAliasType(left_type_fact.target_ty)) or
            !type_bridge.sameTypeSyntax(self.resolveAliasType(right_operand_fact.target_ty), self.resolveAliasType(right_type_fact.target_ty)) or
            !type_bridge.sameTypeSyntax(self.resolveAliasType(left_type_fact.target_ty), self.resolveAliasType(result_fact.target_ty)) or
            !type_bridge.sameTypeSyntax(self.resolveAliasType(right_type_fact.target_ty), self.resolveAliasType(result_fact.target_ty))) return null;
        const left_instruction = simpleMirTypedLeafOperandInstruction(block, left_operand_fact.source) orelse return null;
        const right_instruction = simpleMirTypedLeafOperandInstruction(block, right_operand_fact.source) orelse return null;
        const left = self.simpleMirTypedLeafOperandAtInstruction(function, fn_mir, left_instruction) orelse return null;
        const right = self.simpleMirTypedLeafOperandAtInstruction(function, fn_mir, right_instruction) orelse return null;
        return .{ .kind = .wrapping_add, .op = "add", .operation_fact = result_fact, .result_fact = result_fact, .left = left, .right = right };
    }

    fn simpleMirUncheckedBinaryReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirWrappingBinary {
        const call_source = simpleMirReturnValueSource(block, value_id) orelse return null;
        const return_ty = function.signature.transitionalReturnType() orelse return null;
        const expected_type_name = type_bridge.typeName(self.resolveAliasType(return_ty)) orelse return null;
        return self.simpleMirUncheckedBinaryAtSource(function, fn_mir, call_source, expected_type_name, "value");
    }

    fn simpleMirUncheckedBinaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint, expected_type_name: []const u8, range_target: []const u8) ?SimpleMirWrappingBinary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        var unchecked_op: ?[]const u8 = null;
        for (fn_mir.call_target_facts) |fact| {
            if (mir.uncheckedCallFactInfo(fact.kind)) |op| {
                if (!sameMirSourceLocation(fact.source, call_source)) continue;
                if (unchecked_op != null) return null;
                unchecked_op = op;
            }
        }
        const op = unchecked_op orelse return null;
        const expected_detail = if (std.mem.eql(u8, op, "add"))
            "unchecked.add"
        else if (std.mem.eql(u8, op, "sub"))
            "unchecked.sub"
        else if (std.mem.eql(u8, op, "mul"))
            "unchecked.mul"
        else
            return null;
        var saw_call = false;
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind == .unchecked_assume and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) {
                    if (!std.mem.eql(u8, instruction.detail, expected_detail)) return null;
                    saw_call = true;
                    break;
                }
            }
        }
        if (!saw_call) return null;

        const result_fact = simpleMirTargetTypeFactKindAt(fn_mir, .unchecked_result, call_source) orelse return null;
        const result_name = type_bridge.typeName(self.resolveAliasType(result_fact.target_ty)) orelse return null;
        if (!std.mem.eql(u8, expected_type_name, result_name) and !std.mem.eql(u8, expected_type_name, self.cTypeFor(result_fact.target_ty, .typedef_name) catch return null)) return null;
        if (unsignedTypeSuffix(result_name) == null) return null;
        var left_fact: ?mir.TargetTypeFact = null;
        var right_fact: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            switch (fact.kind) {
                .unchecked_left => {
                    if (left_fact != null) return null;
                    left_fact = fact;
                },
                .unchecked_right => {
                    if (right_fact != null) return null;
                    right_fact = fact;
                },
                else => {},
            }
        }
        const range_fact = simpleMirNoOverflowRangeFactAt(fn_mir, range_target, op, call_source);
        const left_fact_value = left_fact orelse return null;
        const right_fact_value = right_fact orelse return null;
        const left = self.simpleMirCallArgAt(function, fn_mir, left_fact_value.source) orelse return null;
        const right = self.simpleMirCallArgAt(function, fn_mir, right_fact_value.source) orelse return null;
        if (simpleMirCallArgHasDirectCall(left) or simpleMirCallArgHasDirectCall(right)) return null;
        return .{ .kind = .unchecked, .op = op, .operation_fact = result_fact, .result_fact = result_fact, .range_fact = range_fact, .left = left, .right = right };
    }

    fn simpleMirStructLiteralReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirStructLiteralReturn {
        const ret_ty = function.signature.transitionalReturnType() orelse return null;
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
        const literal = self.simpleMirStructLiteralFromBlockAtIndex(function, fn_mir, block, literal_index, source, ret_ty) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirStructLiteralTrapCount(literal)) return null;
        return literal;
    }

    fn simpleMirStructLiteralFromBlockAtIndex(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, literal_index: usize, source: mir.SourcePoint, target_ty: anytype) ?SimpleMirStructLiteralReturn {
        const type_name = type_bridge.typeName(self.resolveAliasType(target_ty)) orelse return null;
        const struct_decl = self.structs.get(type_name) orelse return null;
        if (struct_decl.fields.len > max_simple_mir_struct_fields) return null;
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .struct_literal, source) orelse return null;
        if (!std.mem.eql(u8, fact.result_ty.name(), type_name)) return null;

        var result: SimpleMirStructLiteralReturn = .{ .type_name = type_name };
        var scan_index = literal_index + 1;
        for (struct_decl.fields) |field| {
            while (scan_index < block.instructions.len) : (scan_index += 1) {
                const instruction = block.instructions[scan_index];
                if (instruction.kind == .return_value) return null;
                if (instruction.kind == .target_type or instruction.kind == .integer_literal_conversion or instruction.kind == .representation_check or instruction.kind == .representation_use) continue;
                if (instruction.kind != .expr and instruction.kind != .call and instruction.kind != .binary and instruction.kind != .unary) return null;
                if ((instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary) and !self.noFunctionBodyFallbacksAvailable()) return null;
                const value_source = instructionSourcePoint(instruction);
                const arg = self.simpleMirCallArgAt(function, fn_mir, value_source) orelse return null;
                result.fields[result.field_count] = .{
                    .name = field.name.text,
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

    fn simpleMirArrayLiteralReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirArrayLiteralReturn {
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

    fn simpleMirArrayLiteralFromBlockAtIndex(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, literal_index: usize, source: mir.SourcePoint) ?SimpleMirArrayLiteralReturn {
        const ret_ty = function.signature.transitionalReturnType() orelse return null;
        const resolved_ret_ty = self.resolveAliasType(ret_ty);
        const array_ty = switch (resolved_ret_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        const len_text = self.arrayLenTextForExpr(array_ty.len) catch return null;
        const item_count = std.fmt.parseUnsigned(usize, len_text, 10) catch return null;
        if (item_count > max_simple_mir_array_items) return null;
        _ = simpleMirTargetTypeFactKindAt(fn_mir, .array_literal, source) orelse return null;

        var result: SimpleMirArrayLiteralReturn = .{ .c_type = self.cTypeFor(ret_ty, .typedef_name) catch return null };
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

    fn simpleMirParamFieldReturn(self: *CEmitter, function: anytype, block: mir.Block, ret: mir.Instruction, field_name: []const u8) ?SimpleMirParamField {
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

    fn simpleMirParamFieldAtSource(self: *CEmitter, function: anytype, block: mir.Block, source: mir.SourcePoint, field_name_filter: ?[]const u8, expected_type_name: ?[]const u8) ?SimpleMirParamField {
        for (function.signature.params) |param| {
            if (!simpleMirBlockHasExprAt(block, param.name.text, source)) continue;
            const struct_name = type_bridge.typeName(self.resolveAliasType(param.ty)) orelse continue;
            const struct_decl = self.structs.get(struct_name) orelse continue;
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
                };
            }
        }
        return null;
    }

    fn simpleMirExprCouldBeParamField(self: *CEmitter, function: anytype, block: mir.Block, field_name: []const u8, source: mir.SourcePoint) bool {
        return self.simpleMirParamFieldAtSource(function, block, source, field_name, null) != null;
    }

    fn simpleMirExprCouldBePointerParamField(self: *CEmitter, function: anytype, block: mir.Block, field_name: []const u8, source: mir.SourcePoint) bool {
        for (function.signature.params) |param| {
            if (!simpleMirBlockHasExprAt(block, param.name.text, source)) continue;
            const pointer = switch (self.resolveAliasType(param.ty).kind) {
                .pointer => |pointer| pointer,
                else => continue,
            };
            const struct_name = type_bridge.typeName(self.resolveAliasType(pointer.child.*)) orelse continue;
            const struct_decl = self.structs.get(struct_name) orelse continue;
            for (struct_decl.fields) |field| {
                if (std.mem.eql(u8, field.name.text, field_name)) return true;
            }
        }
        return false;
    }

    fn simpleMirParamFieldValueAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirParamField {
        const fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        for (fn_mir.blocks) |block| {
            if (self.simpleMirParamFieldAtSource(function, block, source, null, fact.result_ty.name())) |field| return field;
        }
        return null;
    }

    fn simpleMirNoTrap(fn_mir: mir.Function) bool {
        return fn_mir.blocks.len == 1 and fn_mir.trap_edges.len == 0;
    }

    // True when the function has trap edges and every one is a representation
    // check (e.g. `nonnull_pointer`). Such checks on a value that already holds
    // the right representation — as a bare `return p` does — are statically
    // satisfied and elided by codegen, so a shape rendered without emitting them
    // stays byte-identical to the fallback.
    fn simpleMirAllTrapEdgesRepresentationChecks(fn_mir: mir.Function) bool {
        if (fn_mir.trap_edges.len == 0) return false;
        for (fn_mir.trap_edges) |edge| {
            if (edge.source != .representation_check) return false;
        }
        return true;
    }

    fn simpleMirVoidBody(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirVoidBody {
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

    fn simpleMirConditionalEmptyVoidBody(self: *CEmitter, function: anytype, fn_mir: mir.Function) bool {
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

    fn simpleMirLoopVoidBody(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirLoopVoidBody {
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
        if (after_block.terminator != .fallthrough or !simpleMirEmptyVoidBlock(function, fn_mir, after_block)) return null;
        if (body_block.terminator == .return_) {
            if (!self.blockOnlyContainsSimpleMirReturnInstructionsInBlock(function, fn_mir, body_block)) return null;
            const ret = simpleMirReturnInstruction(body_block) orelse return null;
            if (ret.result_ty != .void or !std.mem.eql(u8, ret.detail, "void")) return null;
            if (fn_mir.trap_edges.len != 0) return null;
            return .{ .condition = condition, .body_block_index = body_index, .body_returns = true };
        }
        if (body_block.terminator != .jump or body_block.terminator.jump != body_index) return null;
        const body_sources = self.simpleMirVoidStatementSourcesInBlock(function, fn_mir, body_block) orelse return null;
        if (!self.blockOnlyContainsSimpleMirVoidStatementInstructions(function, fn_mir, body_block)) return null;
        const body_traps = self.simpleMirVoidStatementSourcesTrapCount(function, fn_mir, body_sources) orelse return null;
        if (fn_mir.trap_edges.len != body_traps) return null;
        return .{ .condition = condition, .body_block_index = body_index };
    }

    fn simpleMirConditionalEmptyVoidCalls(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirDirectCalls {
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

    fn simpleMirConditionalVoidStatements(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalVoidStatements {
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

    fn simpleMirConditionalVoidBody(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalVoidBody {
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

    fn simpleMirEnumSwitchReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirEnumSwitchReturn {
        if (fn_mir.return_ty == .void) return null;
        if (fn_mir.blocks.len < 4 or fn_mir.pointer_provenance_facts.len != 0) return null;
        if (fn_mir.ownership_cleanup_plan.actions.len != 0 or fn_mir.ownership_cleanup_plan.cancellations.len != 0) return null;
        for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;
        const entry = fn_mir.blocks[0];
        if (entry.terminator != .switch_) return null;
        const subject_index = simpleMirSwitchSubjectIndex(entry) orelse return null;
        const subject_source = simpleMirSwitchSubjectExprSource(entry, subject_index) orelse return null;
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .switch_subject, subject_source) orelse return null;
        const enum_name = self.enumNameForType(fact.target_ty) orelse return null;
        const enum_decl = self.enums.get(enum_name) orelse return null;
        const subject_name = simpleMirSwitchSubjectParam(function, entry, subject_index, enum_name) orelse return null;
        var result: SimpleMirEnumSwitchReturn = .{ .subject_name = subject_name, .enum_name = enum_name };
        var trap_successors: usize = 0;
        for (entry.successors) |successor| {
            if (successor >= fn_mir.blocks.len) return null;
            const arm_block = fn_mir.blocks[successor];
            if (std.mem.eql(u8, arm_block.kind, "trap")) {
                if (arm_block.terminator != .trap_) return null;
                trap_successors += 1;
                continue;
            }
            if (std.mem.eql(u8, arm_block.kind, "switch_after")) {
                if (arm_block.terminator != .fallthrough or !simpleMirEmptyVoidBlock(function, fn_mir, arm_block)) return null;
                continue;
            }
            if (!std.mem.eql(u8, arm_block.kind, "switch_arm") or arm_block.terminator != .return_) return null;
            if (result.arm_count >= max_simple_mir_switch_arms) return null;
            const case_name = simpleMirSwitchArmCaseName(arm_block) orelse return null;
            var known_case = false;
            for (enum_decl.cases) |case| {
                if (std.mem.eql(u8, case.name.text, case_name)) {
                    known_case = true;
                    break;
                }
            }
            if (!known_case) return null;
            const value = self.simpleMirReturnValueInBlock(function, fn_mir, arm_block) orelse return null;
            result.arms[result.arm_count] = .{
                .case_name = case_name,
                .value = value,
                .span = spanFromMirSourcePoint(instructionSourcePoint(simpleMirReturnInstruction(arm_block) orelse return null)),
            };
            result.arm_count += 1;
        }
        if (result.arm_count < 2) return null;
        var expected_traps = trap_successors;
        for (result.arms[0..result.arm_count]) |arm| expected_traps += simpleMirConditionalTrapCount(arm.value);
        if (fn_mir.trap_edges.len != expected_traps) return null;
        return result;
    }

    fn simpleMirSwitchSubjectExprSource(block: mir.Block, subject_index: usize) ?mir.SourcePoint {
        var index = subject_index + 1;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            switch (instruction.kind) {
                .target_type, .typed_load, .representation_check, .representation_use => continue,
                .expr => return instructionSourcePoint(instruction),
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirSwitchSubjectParam(function: anytype, block: mir.Block, subject_index: usize, enum_name: []const u8) ?[]const u8 {
        var index = subject_index + 1;
        while (index < block.instructions.len) : (index += 1) {
            const instruction = block.instructions[index];
            switch (instruction.kind) {
                .target_type, .typed_load, .representation_check, .representation_use => continue,
                .expr => {
                    if (!std.mem.eql(u8, instruction.result_ty.name(), enum_name)) return null;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) return param.name.text;
                    }
                    return null;
                },
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirSwitchArmCaseName(block: mir.Block) ?[]const u8 {
        for (block.instructions) |instruction| {
            if (instruction.kind == .expr and instruction.result_ty == .branch) return instruction.detail;
        }
        return null;
    }

    fn simpleMirVoidStatements(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirVoidStatements {
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

    fn simpleMirVoidStatementsInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, require_global_store: bool) ?SimpleMirVoidStatements {
        var result: SimpleMirVoidStatements = .{};
        var has_global_store = false;
        var has_emitted_store = false;
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
                if (self.simpleMirPointerParamFieldStore(function, fn_mir, block, instruction)) |store| {
                    if (result.count >= max_simple_mir_void_statements) return null;
                    result.statements[result.count] = .{ .param_field_store = store };
                    result.count += 1;
                    has_emitted_store = true;
                    continue;
                }
                if (!self.globals.contains(instruction.detail)) return null;
                if (result.count >= max_simple_mir_void_statements) return null;
                const name = instruction.detail;
                const value_source = self.simpleMirAssignmentSourceInBlock(block, name) orelse return null;
                result.statements[result.count] = .{ .global_store = .{
                    .name = name,
                    .value = self.simpleMirGlobalStoreValue(function, fn_mir, name, value_source) orelse return null,
                    .source = instructionSourcePoint(instruction),
                } };
                result.count += 1;
                has_global_store = true;
                has_emitted_store = true;
            }
        }
        if (require_global_store and !has_global_store and !has_emitted_store) return null;
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
            .direct_call, .param_field_store => {},
        };
        return stores;
    }

    fn simpleMirVoidStatementsDirectCallTrapCount(statements: SimpleMirVoidStatements) usize {
        var count: usize = 0;
        for (statements.statements[0..statements.count]) |statement| switch (statement) {
            .direct_call => |call| count += simpleMirDirectCallTrapCount(call),
            .global_store => {},
            .param_field_store => count += 1,
        };
        return count;
    }

    fn simpleMirPointerParamFieldStore(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, assign: mir.Instruction) ?SimpleMirParamFieldStore {
        if (!self.noFunctionBodyFallbacksAvailable()) return null;
        const source = instructionSourcePoint(assign);
        const value_source = simpleMirPointerFieldAssignmentValueSource(block, assign) orelse return null;
        const value = self.simpleMirArgAt(function, fn_mir, value_source) orelse return null;
        for (function.signature.params) |param| {
            if (!simpleMirBlockHasExprAt(block, param.name.text, source)) continue;
            const pointer = switch (self.resolveAliasType(param.ty).kind) {
                .pointer => |pointer| pointer,
                else => continue,
            };
            if (pointer.mutability != .mut) continue;
            const struct_name = typeName(self.resolveAliasType(pointer.child.*)) orelse continue;
            const struct_decl = self.structs.get(struct_name) orelse continue;
            for (struct_decl.fields, 0..) |field, field_index| {
                if (!std.mem.eql(u8, field.name.text, assign.detail)) continue;
                const field_type_name = typeName(self.resolveAliasType(field.ty)) orelse return null;
                if (!std.mem.eql(u8, field_type_name, assign.result_ty.name())) return null;
                return .{
                    .param_name = param.name.text,
                    .field_name = field.name.text,
                    .field_index = field_index,
                    .value = value,
                    .source = source,
                };
            }
        }
        return null;
    }

    fn simpleMirPointerFieldAssignmentValueSource(block: mir.Block, assign: mir.Instruction) ?mir.SourcePoint {
        const assign_source = instructionSourcePoint(assign);
        var after_assign = false;
        for (block.instructions) |instruction| {
            if (!after_assign) {
                after_assign = instruction.kind == .assign and sameMirSourceLocation(instructionSourcePoint(instruction), assign_source) and std.mem.eql(u8, instruction.detail, assign.detail);
                continue;
            }
            switch (instruction.kind) {
                .target_type, .typed_load, .representation_check, .representation_use => continue,
                .expr, .integer_literal_conversion, .binary, .unary, .call => {
                    const source = instructionSourcePoint(instruction);
                    if (sameMirSourceLocation(source, assign_source)) continue;
                    return source;
                },
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirGlobalStoreValue(self: *CEmitter, function: anytype, fn_mir: mir.Function, store_name: []const u8, value_source: mir.SourcePoint) ?SimpleMirGlobalStoreValue {
        const global_info = self.globals.get(store_name) orelse return null;
        return if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, value_source)) |binary|
            .{ .checked_binary = binary }
        else if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, value_source)) |unary|
            .{ .checked_unary = unary }
        else if (self.simpleMirWrappingBinaryAtSource(function, fn_mir, value_source, global_info.type_name)) |binary|
            .{ .wrapping_binary = binary }
        else if (self.simpleMirUncheckedBinaryAtSource(function, fn_mir, value_source, global_info.type_name, store_name)) |binary|
            .{ .wrapping_binary = binary }
        else if (self.simpleMirExplicitCastAtSource(function, fn_mir, value_source)) |cast|
            .{ .explicit_cast = cast }
        else if (self.simpleMirConversionAtSource(function, fn_mir, value_source)) |conversion|
            .{ .conversion = conversion }
        else if (self.simpleMirCompareBinaryAtSource(function, fn_mir, value_source)) |binary|
            .{ .compare_binary = binary }
        else if (self.simpleMirLogicalNotAtSource(function, fn_mir, value_source)) |arg|
            .{ .logical_not = arg }
        else if (self.simpleMirLocalFloatLiteralValueAtSource(function, fn_mir, value_source)) |literal|
            .{ .float_literal = literal }
        else if (self.simpleMirFloatLiteralAtSource(fn_mir, value_source)) |literal|
            .{ .float_literal = literal }
        else if (self.simpleMirEnumLiteralValueAtSource(fn_mir, value_source)) |literal|
            .{ .enum_literal = literal }
        else if (self.simpleMirNullLiteralAtSource(fn_mir, value_source)) |literal|
            .{ .null_literal = literal }
        else if (if (global_info.source_ty) |target_ty| self.simpleMirStructLiteralAtSourceWithType(function, fn_mir, value_source, target_ty) else null) |literal|
            .{ .struct_literal = literal }
        else if (if (global_info.source_ty) |target_ty| self.simpleMirResultConstructorAtSourceWithType(function, fn_mir, value_source, target_ty) else null) |constructor|
            .{ .result_constructor = constructor }
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
            .enum_literal => 1,
            .struct_literal => |literal| simpleMirStructLiteralTrapCount(literal),
            .result_constructor => |constructor| simpleMirResultConstructorPayloadTrapCount(constructor.payload),
            else => 0,
        };
    }

    fn simpleMirGlobalStoresTrapCount(stores: SimpleMirGlobalStores) usize {
        var count: usize = 0;
        for (stores.stores[0..stores.count]) |store| count += simpleMirGlobalStoreValueTrapCount(store.value);
        return count;
    }

    fn blockOnlyContainsSimpleMirVoidStatementInstructions(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .target_type, .integer_literal_conversion, .add_overflow, .contract_begin, .contract_end, .unchecked_assume, .call_target, .typed_load, .representation_check, .representation_use, .return_value => {},
            .assign => {
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) {
                    const source = self.simpleMirAssignmentSourceInBlock(block, instruction.detail) orelse return false;
                    if (self.simpleMirArgAt(function, fn_mir, source) == null and
                        self.simpleMirFloatLiteralAtSource(fn_mir, source) == null) return false;
                    continue;
                }
                if (self.simpleMirPointerParamFieldStore(function, fn_mir, block, instruction) != null) continue;
                if (!self.globals.contains(instruction.detail)) return false;
            },
            .binary => {
                const source = instructionSourcePoint(instruction);
                if (self.simpleMirPlainFloatBinaryAtSource(function, fn_mir, source) == null and
                    self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
                    self.simpleMirCompareBinaryAtSource(function, fn_mir, source) == null) return false;
            },
            .unary => {
                const source = instructionSourcePoint(instruction);
                if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source) == null and
                    self.simpleMirLogicalNotAtSource(function, fn_mir, source) == null) return false;
            },
            .call => {
                const source = instructionSourcePoint(instruction);
                if (simpleMirArithmeticCallAtSource(fn_mir, source)) continue;
                if (self.simpleMirConversionCallTargetKindAt(fn_mir, source) != null) continue;
                if (simpleMirResultConstructorKindAtSource(fn_mir, source) != null) continue;
                if (self.simpleMirDirectCallAtSource(function, fn_mir, source) == null) return false;
            },
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or
                    std.mem.eql(u8, instruction.detail, "bool") or
                    std.mem.eql(u8, instruction.detail, "char") or
                    std.mem.eql(u8, instruction.detail, "float") or
                    std.mem.eql(u8, instruction.detail, "literal")) continue;
                if ((std.mem.eql(u8, instruction.detail, "add") or
                    std.mem.eql(u8, instruction.detail, "sub") or
                    std.mem.eql(u8, instruction.detail, "mul") or
                    std.mem.eql(u8, instruction.detail, "wrapping") or
                    std.mem.eql(u8, instruction.detail, "unchecked")) and
                    simpleMirArithmeticCallAtSource(fn_mir, instructionSourcePoint(instruction))) continue;
                if (std.mem.eql(u8, instruction.detail, "cast") and simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_source, instructionSourcePoint(instruction)) != null) continue;
                if (self.simpleMirConversionCallTargetKindAt(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "null") and self.simpleMirNullLiteralAtSource(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "struct_literal") and simpleMirTargetTypeFactKindAt(fn_mir, .struct_literal, instructionSourcePoint(instruction)) != null) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else {
                    if (mirBlockHasLocal(block, instruction.detail)) continue;
                    if (mirBlockHasCall(block, instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.noFunctionBodyFallbacksAvailable() and self.simpleMirExprCouldBePointerParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.globals.contains(instruction.detail)) continue;
                    return false;
                }
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirConditionalReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirConditionalReturn {
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

    fn simpleMirConditionalEarlyReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, then_block: mir.Block, else_block: mir.Block) ?struct { SimpleMirConditionalValue, SimpleMirConditionalValue } {
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

    fn simpleMirEarlyReturnValueInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, after_value: SimpleMirConditionalValue) ?SimpleMirConditionalValue {
        return switch (block.terminator) {
            .return_ => self.simpleMirReturnValueInBlock(function, fn_mir, block),
            .jump => |target| if (target == 1) after_value else null,
            else => null,
        };
    }

    fn simpleMirConditionalAssignedReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, then_block: mir.Block, else_block: mir.Block) ?struct { SimpleMirConditionalValue, SimpleMirConditionalValue } {
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

    fn simpleMirLoopReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirLoopReturn {
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

    fn simpleMirLoopCondition(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirCondition {
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

    fn simpleMirSwitchConditionParam(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirCondition {
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

    fn simpleMirLocalCondition(self: *CEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirCondition {
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

    fn emitSimpleMirCondition(self: *CEmitter, condition: SimpleMirCondition) !void {
        switch (condition) {
            .param => |param| {
                if (param.inverted) try self.out.appendSlice(self.allocator, "!");
                try self.out.appendSlice(self.allocator, try self.cIdent(param.name));
            },
            .param_field => |param_field| {
                if (param_field.inverted) try self.out.appendSlice(self.allocator, "!");
                try self.emitSimpleMirArg(.{ .param_field = param_field.field });
            },
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .direct_call => |call| try self.emitSimpleMirNestedCall(call),
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary),
        }
    }

    fn simpleMirReturnValueInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirConditionalValue {
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
        if (self.globals.contains(value_id)) return .{ .global_load = value_id };
        if (simpleMirReturnValueSource(block, value_id)) |source| {
            if (self.simpleMirGlobalAddressAtValueSource(fn_mir, source)) |name| return .{ .global_address = name };
        }
        var literal_source: ?mir.SourcePoint = null;
        if (std.mem.eql(u8, value_id, "int") or std.mem.eql(u8, value_id, "bool") or std.mem.eql(u8, value_id, "char") or std.mem.eql(u8, value_id, "float")) {
            for (block.instructions) |instruction| {
                if (instruction.kind == .return_value) break;
                if (instruction.kind == .integer_literal_conversion or
                    (instruction.kind == .expr and (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "bool") or std.mem.eql(u8, instruction.detail, "char") or std.mem.eql(u8, instruction.detail, "float"))))
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
                .float_literal => |literal| .{ .float_literal = literal },
                .enum_literal => |literal| .{ .enum_literal = literal },
            };
        }
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirNullLiteralAtSource(fn_mir, simpleMirReturnValueSource(block, value_id) orelse instructionSourcePoint(ret))) |literal| return .{ .null_literal = literal };
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

    fn simpleMirConditionalValueAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirConditionalValue {
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, source)) |call| return .{ .direct_call = call };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirStructLiteralAtSource(function, fn_mir, source)) |literal| return .{ .struct_literal = literal };
        if (self.simpleMirArrayLiteralAtSource(function, fn_mir, source)) |literal| return .{ .array_literal = literal };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, source)) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirNullLiteralAtSource(fn_mir, source)) |literal| return .{ .null_literal = literal };
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, source)) |field| return .{ .param_field = field };
        if (self.simpleMirGlobalAddressAtValueSource(fn_mir, source)) |name| return .{ .global_address = name };
        if (self.simpleMirGlobalAtSource(function, fn_mir, source)) |name| return .{ .global_load = name };
        return switch (self.simpleMirArgAt(function, fn_mir, source) orelse return null) {
            .param => |name| .{ .param = name },
            .param_field => |field| .{ .param_field = field },
            .integer_literal => |literal| .{ .integer_literal = literal },
            .bool_literal => |value| .{ .bool_literal = value },
            .float_literal => |literal| .{ .float_literal = literal },
            .enum_literal => |literal| .{ .enum_literal = literal },
        };
    }

    fn simpleMirStructLiteralAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirStructLiteralReturn {
        for (fn_mir.blocks) |block| {
            for (block.instructions, 0..) |instruction, index| {
                if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, "struct_literal")) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirStructLiteralFromBlockAtIndex(function, fn_mir, block, index, source, function.signature.transitionalReturnType() orelse return null);
            }
        }
        return null;
    }

    fn simpleMirStructLiteralAtSourceWithType(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint, target_ty: anytype) ?SimpleMirStructLiteralReturn {
        for (fn_mir.blocks) |block| {
            for (block.instructions, 0..) |instruction, index| {
                if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, "struct_literal")) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirStructLiteralFromBlockAtIndex(function, fn_mir, block, index, source, target_ty);
            }
        }
        return null;
    }

    fn simpleMirArrayLiteralAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArrayLiteralReturn {
        for (fn_mir.blocks) |block| {
            for (block.instructions, 0..) |instruction, index| {
                if (instruction.kind != .expr or !std.mem.eql(u8, instruction.detail, "array_literal")) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirArrayLiteralFromBlockAtIndex(function, fn_mir, block, index, source);
            }
        }
        return null;
    }

    fn emitSimpleMirConditionalValue(self: *CEmitter, value: SimpleMirConditionalValue) !void {
        switch (value) {
            .param => |name| try self.out.appendSlice(self.allocator, try self.cIdent(name)),
            .param_field => |field| try self.out.print(self.allocator, "{s}.{s}", .{ try self.cIdent(field.param_name), try self.cIdent(field.field_name) }),
            .integer_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .float_literal => |literal| try self.emitSimpleMirFloatLiteral(literal),
            .bool_literal => |bool_value| try self.out.appendSlice(self.allocator, if (bool_value) "true" else "false"),
            .global_load => |name| try appendGlobalLoadExpr(self.allocator, self.out, name, self.globals.get(name) orelse return error.UnsupportedCEmission),
            .global_address => |name| try self.out.print(self.allocator, "&{s}", .{try self.cIdent(name)}),
            .direct_call => |call| try self.emitSimpleMirDirectCall(call),
            .checked_binary => |binary| {
                const helper = try self.checkedHelperName(binary.op, binary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(binary.left);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitSimpleMirArg(binary.right);
                try self.out.appendSlice(self.allocator, ")");
            },
            .checked_unary => |unary| {
                const helper = try self.checkedUnaryHelperName(unary.op, unary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(unary.operand);
                try self.out.appendSlice(self.allocator, ")");
            },
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary),
            .enum_literal => |literal| try self.out.print(self.allocator, "{s}_{s}", .{ literal.enum_name, literal.case_name }),
            .null_literal => |literal| try self.emitSimpleMirNullExpr(literal),
            .logical_not => |operand| {
                try self.out.appendSlice(self.allocator, "!");
                try self.emitSimpleMirArg(operand);
            },
            .struct_literal => |literal| try self.emitSimpleMirStructLiteral(literal),
            .array_literal => |literal| try self.emitSimpleMirArrayLiteral(literal),
        }
    }

    fn emitSimpleMirStructLiteral(self: *CEmitter, literal: SimpleMirStructLiteralReturn) !void {
        try self.out.print(self.allocator, "({s}){{ ", .{try self.cIdent(literal.type_name)});
        for (literal.fields[0..literal.field_count], 0..) |field, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(field.name)});
            try self.emitSimpleMirCallArg(field.value);
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn emitSimpleMirArrayLiteral(self: *CEmitter, literal: SimpleMirArrayLiteralReturn) !void {
        try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{literal.c_type});
        for (literal.items[0..literal.item_count], 0..) |item, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitSimpleMirCallArg(item);
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitSimpleMirNullReturn(self: *CEmitter, literal: SimpleMirNullLiteral) !void {
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitSimpleMirNullExpr(literal);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitSimpleMirNullExpr(self: *CEmitter, literal: SimpleMirNullLiteral) !void {
        switch (literal.fact.result_ty) {
            .nullable_pointer => try self.out.appendSlice(self.allocator, "NULL"),
            else => try self.out.print(self.allocator, "({s}){{ .present = false }}", .{try self.cTypeFor(literal.fact.target_ty, .typedef_name)}),
        }
    }

    fn emitSimpleMirDirectCallStatements(self: *CEmitter, calls: SimpleMirDirectCalls) !void {
        for (calls.calls[0..calls.count]) |call| {
            try self.writeIndent();
            try self.emitSimpleMirDirectCall(call);
            try self.out.appendSlice(self.allocator, ";\n");
        }
    }

    fn emitMirIndirectCallReturnPlan(self: *CEmitter, plan: mir_statement_plan.IndirectCallReturnPlan) !void {
        switch (plan.callee) {
            .local_function => |local| {
                try self.writeLineDirective(spanFromMirSourcePoint(local.local_location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s};\n", .{
                    try self.cTypeFor(plan.callee_fact.target_ty, .typedef_name),
                    try self.cIdent(local.local_name),
                    try self.cIdent(local.function_name),
                });
            },
            else => {},
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.location.source));
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitMirIndirectCallee(plan.callee);
        try self.out.append(self.allocator, '(');
        for (plan.arguments[0..plan.argument_count], 0..) |argument, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, try self.cIdent(argument.name));
        }
        try self.out.appendSlice(self.allocator, ");\n");
    }

    fn mirIndirectCallReturnPlanSupported(self: *CEmitter, plan: mir_statement_plan.IndirectCallReturnPlan) bool {
        return switch (plan.callee) {
            .local_function => |local| blk: {
                if (!local.local_id.isValid() or !local.function_id.isValid()) break :blk false;
                const target = self.functions.get(local.function_name) orelse break :blk false;
                const signature = switch (plan.callee_fact.target_ty.kind) {
                    .fn_pointer => |signature| signature,
                    else => break :blk false,
                };
                const return_ty = target.return_type orelse break :blk false;
                if (target.is_variadic or target.params.len != signature.params.len or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(signature.ret.*))) break :blk false;
                for (target.params, signature.params) |actual, expected| {
                    if (!type_bridge.sameTypeSyntax(self.resolveAliasType(actual.ty), self.resolveAliasType(expected))) break :blk false;
                }
                break :blk true;
            },
            .projected_place => |place| blk: {
                const place_ty = self.mirPlaceType(place, spanFromMirSourcePoint(plan.location.source)) catch break :blk false;
                break :blk type_bridge.sameTypeSyntax(self.resolveAliasType(place_ty), self.resolveAliasType(plan.callee_fact.target_ty));
            },
            else => true,
        };
    }

    fn mirScalarSwitchPlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.ScalarSwitchReturnPlan) bool {
        const return_ty = function.signature.transitionalReturnType() orelse return false;
        var matched_subject = false;
        for (function.signature.params) |param| {
            if (!std.mem.eql(u8, param.name.text, plan.subject_name)) continue;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(param.ty), self.resolveAliasType(plan.subject_fact.target_ty))) return false;
            matched_subject = true;
        }
        if (!matched_subject) return false;
        for (plan.arms[0..plan.arm_count]) |arm| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(arm.result.type_fact.target_ty))) return false;
        }
        return true;
    }

    fn emitMirScalarSwitchReturnPlan(self: *CEmitter, plan: mir_statement_plan.ScalarSwitchReturnPlan) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(plan.subject_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "switch ({s}) {{\n", .{try self.cIdent(plan.subject_name)});
        self.indent += 1;
        defer self.indent -= 1;
        for (plan.arms[0..plan.arm_count]) |arm| {
            const is_default = for (arm.patterns[0..arm.pattern_count]) |pattern| {
                switch (pattern) {
                    .wildcard => break true,
                    else => {},
                }
            } else false;
            if (is_default) {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "default:\n");
            } else {
                for (arm.patterns[0..arm.pattern_count]) |pattern| {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "case ");
                    try self.emitMirScalarSwitchPattern(pattern);
                    try self.out.appendSlice(self.allocator, ":\n");
                }
            }
            self.indent += 1;
            try self.writeLineDirective(spanFromMirSourcePoint(arm.location.source));
            try self.writeIndent();
            try self.out.print(self.allocator, "return {d};\n", .{arm.result.value});
            self.indent -= 1;
        }
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitMirScalarSwitchPattern(self: *CEmitter, pattern: mir.Instruction.SwitchPattern) !void {
        switch (pattern) {
            .unused, .wildcard => return error.UnsupportedCEmission,
            .scalar => |scalar| {
                if (scalar.negative) try self.out.append(self.allocator, '-');
                try self.out.print(self.allocator, "{d}", .{scalar.magnitude});
            },
        }
    }

    fn mirDirectCallArgumentSupported(self: *CEmitter, function: anytype, argument: mir_statement_plan.DirectCallArgument) bool {
        return switch (argument.value) {
            .parameter => |parameter| parameter.value_id.isValid() and
                self.mirAggregateParameterMatchesSignature(function, parameter.name, argument.type_fact.target_ty),
            .zero_arg_call => |call| blk: {
                if (!call.callee_value_id.isValid()) break :blk false;
                const signature = self.functions.get(call.callee_name) orelse break :blk false;
                const return_ty = signature.return_type orelse break :blk false;
                break :blk !signature.is_variadic and signature.params.len == 0 and
                    type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(call.callee_fact.target_ty)) and
                    type_bridge.sameTypeSyntax(self.resolveAliasType(return_ty), self.resolveAliasType(argument.type_fact.target_ty));
            },
        };
    }

    fn emitMirDirectCallArgument(self: *CEmitter, argument: mir_statement_plan.DirectCallArgument) ![]const u8 {
        return switch (argument.value) {
            .parameter => |parameter| try self.cIdent(parameter.name),
            .zero_arg_call => |call| blk: {
                const name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(call.location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}();\n", .{
                    try self.cTypeFor(argument.type_fact.target_ty, .typedef_name),
                    name,
                    try self.cIdent(call.callee_name),
                });
                break :blk name;
            },
        };
    }

    fn mirSequenceForEachReturnPlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.SequenceForEachReturnPlan) bool {
        if (!plan.binding_id.isValid()) return false;
        const iterable_ty = switch (plan.iterable) {
            .parameter => |parameter| blk: {
                if (!parameter.value_id.isValid() or
                    !self.mirAggregateParameterMatchesSignature(function, parameter.name, parameter.type_fact.target_ty)) return false;
                break :blk parameter.type_fact.target_ty;
            },
            .direct_call => |call| blk: {
                if (!call.callee_value_id.isValid()) return false;
                const callee = self.functions.get(call.callee_name) orelse return false;
                if (callee.is_variadic or call.argument_count != callee.params.len) return false;
                const call_ty = callee.return_type orelse return false;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(call_ty), self.resolveAliasType(call.result_fact.target_ty))) return false;
                for (call.arguments[0..call.argument_count], 0..) |argument, index| {
                    if (argument.index != index or
                        !type_bridge.sameTypeSyntax(self.resolveAliasType(argument.type_fact.target_ty), self.resolveAliasType(callee.params[index].ty)) or
                        !self.mirDirectCallArgumentSupported(function, argument)) return false;
                }
                var projected_ty = call_ty;
                for (call.projections[0..call.projection_count]) |projection| switch (projection) {
                    .field => |field| {
                        const struct_name = self.mirDirectCallStructName(projected_ty) orelse return false;
                        const struct_decl = self.structs.get(struct_name) orelse return false;
                        if (field.field_index >= struct_decl.fields.len) return false;
                        const declared_field = struct_decl.fields[field.field_index];
                        if (!std.mem.eql(u8, field.field_name, declared_field.name.text) or
                            !type_bridge.sameTypeSyntax(self.resolveAliasType(field.type_fact.target_ty), self.resolveAliasType(declared_field.ty))) return false;
                        projected_ty = declared_field.ty;
                    },
                    .index => return false,
                };
                break :blk projected_ty;
            },
        };
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(iterable_ty), self.resolveAliasType(plan.iterable_fact.target_ty))) return false;
        const child_ty = switch (self.resolveAliasType(iterable_ty).kind) {
            .array => |array| blk: {
                _ = self.arrayLenTextForExpr(array.len) catch return false;
                if (plan.representation_check != null) return false;
                break :blk array.child.*;
            },
            .slice => |slice| blk: {
                const check = plan.representation_check orelse return false;
                if (!check.value_id.isValid() or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(check.type_fact.target_ty), self.resolveAliasType(iterable_ty))) return false;
                break :blk slice.child.*;
            },
            else => return false,
        };
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(child_ty), self.resolveAliasType(plan.element_fact.target_ty))) return false;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(plan.fallback.type_fact.target_ty), self.resolveAliasType(child_ty))) return false;
        const declared_return = function.signature.transitionalReturnType() orelse return false;
        return type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(child_ty));
    }

    fn mirNullableTryPlanSupported(self: *CEmitter, plan: mir_statement_plan.NullableTryPlan) bool {
        const nullable_c = self.cTypeFor(plan.nullable_fact.target_ty, .typedef_name) catch return false;
        const unwrapped_c = self.cTypeFor(plan.unwrapped_fact.target_ty, .typedef_name) catch return false;
        if (!std.mem.eql(u8, nullable_c, unwrapped_c)) return false;
        switch (plan.source) {
            .parameter => {},
            .zero_arg_call => |call| {
                const signature = self.functions.get(call.callee_name) orelse return false;
                if (!signature.acceptsArgCount(0) or signature.params.len != 0 or signature.return_type == null or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(signature.return_type.?), self.resolveAliasType(call.result_fact.target_ty))) return false;
            },
        }
        return switch (plan.consumer) {
            .return_unwrapped => true,
            .direct_call => |call| blk: {
                const signature = self.functions.get(call.callee_name) orelse break :blk false;
                if (!signature.acceptsArgCount(1) or signature.params.len != 1 or signature.return_type == null or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(signature.params[0].ty), self.resolveAliasType(call.argument_fact.target_ty)) or
                    !type_bridge.sameTypeSyntax(self.resolveAliasType(signature.return_type.?), self.resolveAliasType(call.result_fact.target_ty))) break :blk false;
                break :blk true;
            },
        };
    }

    fn emitMirNullableTryPlan(self: *CEmitter, plan: mir_statement_plan.NullableTryPlan) !void {
        const temp = try self.nextTempName();
        const source_location = switch (plan.source) {
            .parameter => |parameter| parameter.location,
            .zero_arg_call => |call| call.location,
        };
        try self.writeLineDirective(spanFromMirSourcePoint(source_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{
            try self.cTypeFor(plan.unwrapped_fact.target_ty, .typedef_name),
            temp,
        });
        switch (plan.source) {
            .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
            .zero_arg_call => |call| try self.out.print(self.allocator, "{s}()", .{try self.cIdent(call.callee_name)}),
        }
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeLineDirective(spanFromMirSourcePoint(plan.try_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_NullUnwrap();\n", .{temp});

        switch (plan.consumer) {
            .return_unwrapped => {
                const location = plan.return_location orelse plan.try_location;
                try self.writeLineDirective(spanFromMirSourcePoint(location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "return {s};\n", .{temp});
            },
            .direct_call => |call| {
                try self.writeLineDirective(spanFromMirSourcePoint(call.location.source));
                try self.writeIndent();
                if (call.returns_value) try self.out.appendSlice(self.allocator, "return ");
                try self.out.print(self.allocator, "{s}({s});\n", .{ try self.cIdent(call.callee_name), temp });
            },
        }
    }

    fn emitMirScalarLocalCheckedBinaryOperand(
        self: *CEmitter,
        operand: mir_statement_plan.ScalarCheckedBinaryOperand,
    ) !void {
        switch (operand) {
            .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
            .integer_literal => |literal| try self.out.print(self.allocator, "{d}", .{literal.value}),
        }
    }

    fn mirSequenceForEachUpdatePlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.SequenceForEachUpdatePlan) bool {
        const parameter = switch (plan.iterable) {
            .parameter => |parameter| parameter,
            else => return false,
        };
        const declared_iterable = blk: {
            for (function.signature.params) |param| {
                if (std.mem.eql(u8, param.name.text, parameter.name)) break :blk param.ty;
            }
            return false;
        };
        const child_ty = switch (self.resolveAliasType(declared_iterable).kind) {
            .slice => |slice| slice.child.*,
            else => return false,
        };
        const declared_return = function.signature.transitionalReturnType() orelse return false;
        return type_bridge.sameTypeSyntax(self.resolveAliasType(declared_iterable), self.resolveAliasType(plan.iterable_fact.target_ty)) and
            type_bridge.sameTypeSyntax(self.resolveAliasType(child_ty), self.resolveAliasType(plan.element_fact.target_ty)) and
            type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(plan.local_fact.target_ty)) and
            typeName(plan.local_fact.target_ty) != null;
    }

    fn emitMirSequenceForEachUpdatePlan(self: *CEmitter, plan: mir_statement_plan.SequenceForEachUpdatePlan) !void {
        const parameter = switch (plan.iterable) {
            .parameter => |parameter| parameter,
            else => return error.UnsupportedCEmission,
        };
        const iterable_name = try self.cIdent(parameter.name);
        const local_name = try self.cIdent(plan.local_name);
        const binding_name = try self.cIdent(plan.binding_name);
        const slice = switch (self.resolveAliasType(plan.iterable_fact.target_ty).kind) {
            .slice => |slice| slice,
            else => return error.UnsupportedCEmission,
        };
        try self.writeLineDirective(spanFromMirSourcePoint(plan.declaration_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {d};\n", .{ try self.cTypeFor(plan.local_fact.target_ty, .typedef_name), local_name, plan.initializer.value });
        try self.emitMirDirectCallRepresentationCheck(.{
            .projection_index = 0,
            .type_fact = plan.representation_check.type_fact,
            .location = plan.representation_check.location,
            .value_id = plan.representation_check.value_id,
            .result_ty = plan.representation_check.type_fact.result_ty,
        }, iterable_name, plan.iterable_fact.target_ty);
        const index_name = try self.nextTempName();
        try self.writeLineDirective(spanFromMirSourcePoint(plan.element_fact.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "for (uintptr_t {s} = 0; {s} < {s}.len; {s} += 1) {{\n", .{ index_name, index_name, iterable_name, index_name });
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}.ptr[{s}];\n", .{ try self.cTypeFor(slice.child.*, .typedef_name), binding_name, iterable_name, index_name });
        try self.writeLineDirective(spanFromMirSourcePoint(plan.assignment_location.source));
        try self.writeIndent();
        switch (plan.update) {
            .replace_with_element => try self.out.print(self.allocator, "{s} = {s};\n", .{ local_name, binding_name }),
            .checked_add_element => {
                const type_name = typeName(plan.local_fact.target_ty) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "{s} = mc_checked_add_{s}({s}, {s});\n", .{ local_name, type_name, local_name, binding_name });
            },
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.control_location.source));
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, switch (plan.control) {
            .break_ => "break;\n",
            .continue_ => "continue;\n",
        });
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        try self.writeLineDirective(spanFromMirSourcePoint(plan.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{local_name});
    }

    fn emitMirSequenceForEachReturnPlan(self: *CEmitter, plan: mir_statement_plan.SequenceForEachReturnPlan) !void {
        var current_ty = plan.iterable_fact.target_ty;
        var current_name: []const u8 = undefined;
        var projections: []const mir_statement_plan.DirectCallProjection = &.{};
        switch (plan.iterable) {
            .parameter => |parameter| {
                current_ty = parameter.type_fact.target_ty;
                current_name = try self.cIdent(parameter.name);
            },
            .direct_call => |call| {
                var argument_names: [mir_statement_plan.max_arguments][]const u8 = undefined;
                for (call.arguments[0..call.argument_count], 0..) |argument, index| {
                    argument_names[index] = try self.emitMirDirectCallArgument(argument);
                }
                current_ty = call.result_fact.target_ty;
                current_name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(call.call_location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}(", .{ try self.cTypeFor(current_ty, .typedef_name), current_name, try self.cIdent(call.callee_name) });
                for (argument_names[0..call.argument_count], 0..) |argument_name, index| {
                    if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.appendSlice(self.allocator, argument_name);
                }
                try self.out.appendSlice(self.allocator, ");\n");
                projections = call.projections[0..call.projection_count];
            },
        }

        for (projections) |projection| switch (projection) {
            .field => |field| {
                const struct_name = self.mirDirectCallStructName(current_ty) orelse return error.UnsupportedCEmission;
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                if (field.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                const declared_field = struct_decl.fields[field.field_index];
                const next_name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(field.location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}.{s};\n", .{ try self.cTypeFor(declared_field.ty, .typedef_name), next_name, current_name, try self.cIdent(declared_field.name.text) });
                current_ty = declared_field.ty;
                current_name = next_name;
            },
            .index => return error.UnsupportedCEmission,
        };

        if (plan.representation_check) |check| {
            try self.emitMirDirectCallRepresentationCheck(.{
                .projection_index = 0,
                .type_fact = check.type_fact,
                .location = check.location,
                .value_id = check.value_id,
                .result_ty = check.type_fact.result_ty,
            }, current_name, current_ty);
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.element_fact.source));
        try self.writeIndent();
        const child_ty = switch (self.resolveAliasType(current_ty).kind) {
            .array => |array| blk: {
                const bound = try self.arrayLenTextForExpr(array.len);
                try self.out.print(self.allocator, "if ({s} != 0) {{\n", .{bound});
                break :blk array.child.*;
            },
            .slice => |slice| blk: {
                try self.out.print(self.allocator, "if ({s}.len != 0) {{\n", .{current_name});
                break :blk slice.child.*;
            },
            else => return error.UnsupportedCEmission,
        };
        self.indent += 1;
        try self.writeIndent();
        switch (self.resolveAliasType(current_ty).kind) {
            .array => try self.out.print(self.allocator, "{s} {s} = {s}.elems[0];\n", .{ try self.cTypeFor(child_ty, .typedef_name), try self.cIdent(plan.binding_name), current_name }),
            .slice => try self.out.print(self.allocator, "{s} {s} = {s}.ptr[0];\n", .{ try self.cTypeFor(child_ty, .typedef_name), try self.cIdent(plan.binding_name), current_name }),
            else => unreachable,
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.body_return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(plan.binding_name)});
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        try self.writeLineDirective(spanFromMirSourcePoint(plan.fallback_return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {d};\n", .{plan.fallback.value});
    }

    fn mirDirectCallProjectedReturnPlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.DirectCallProjectedReturnPlan) bool {
        if (!plan.callee_value_id.isValid() or plan.projection_count == 0) return false;
        const callee = self.functions.get(plan.callee_name) orelse return false;
        if (callee.is_variadic or plan.argument_count != callee.params.len) return false;
        const call_ty = callee.return_type orelse return false;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(call_ty), self.resolveAliasType(plan.result_fact.target_ty))) return false;

        for (plan.arguments[0..plan.argument_count], 0..) |argument, index| {
            if (argument.index != index) return false;
            const parameter = callee.params[index];
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(argument.type_fact.target_ty), self.resolveAliasType(parameter.ty))) return false;
            if (!self.mirDirectCallArgumentSupported(function, argument)) return false;
        }

        var projected_ty = call_ty;
        for (plan.projections[0..plan.projection_count]) |projection| switch (projection) {
            .field => |field| {
                const struct_name = self.mirDirectCallStructName(projected_ty) orelse return false;
                const struct_decl = self.structs.get(struct_name) orelse return false;
                if (field.field_index >= struct_decl.fields.len) return false;
                const declared_field = struct_decl.fields[field.field_index];
                if (!std.mem.eql(u8, field.field_name, declared_field.name.text) or !type_bridge.sameTypeSyntax(self.resolveAliasType(field.type_fact.target_ty), self.resolveAliasType(declared_field.ty))) return false;
                projected_ty = declared_field.ty;
            },
            .index => |index| {
                if (!index.operand_id.isValid() or !self.mirAggregateParameterMatchesSignature(function, index.operand_name, index.operand_fact.target_ty)) return false;
                switch (self.resolveAliasType(projected_ty).kind) {
                    .array => |array| {
                        const bound_text = self.arrayLenTextForExpr(array.len) catch return false;
                        const bound = std.fmt.parseUnsigned(usize, bound_text, 10) catch return false;
                        if (index.static_bound) |static_bound| if (static_bound != bound) return false;
                        if (index.constant_value) |constant| if (constant >= bound) return false;
                        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(index.type_fact.target_ty), self.resolveAliasType(array.child.*))) return false;
                        projected_ty = array.child.*;
                    },
                    .slice => |slice| {
                        if (index.static_bound != null or !type_bridge.sameTypeSyntax(self.resolveAliasType(index.type_fact.target_ty), self.resolveAliasType(slice.child.*))) return false;
                        projected_ty = slice.child.*;
                    },
                    else => return false,
                }
            },
        };
        const declared_return = function.signature.transitionalReturnType() orelse return false;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(projected_ty))) return false;

        if (plan.representation_check) |check| {
            if (!check.value_id.isValid() or check.projection_index >= plan.projection_count) return false;
            const projection_fact = switch (plan.projections[check.projection_index]) {
                .field => |field| field.type_fact,
                .index => |index| index.type_fact,
            };
            if (!projection_fact.typed_span_id.eql(check.type_fact.typed_span_id) or !type_bridge.sameTypeSyntax(self.resolveAliasType(projection_fact.target_ty), self.resolveAliasType(check.type_fact.target_ty)) or std.meta.activeTag(check.result_ty) != std.meta.activeTag(projection_fact.result_ty) or !std.mem.eql(u8, check.result_ty.name(), projection_fact.result_ty.name())) return false;
            if (check.type_fact.typed_operand_value_id.isValid() and !check.value_id.eql(check.type_fact.typed_operand_value_id)) return false;
            switch (check.result_ty) {
                .pointer, .cstr, .slice, .closed_enum => {},
                else => return false,
            }
        }
        return true;
    }

    fn emitMirDirectCallProjectedReturnPlan(self: *CEmitter, plan: mir_statement_plan.DirectCallProjectedReturnPlan) !void {
        var current_ty = plan.result_fact.target_ty;
        var current_name = try self.nextTempName();
        var argument_names: [mir_statement_plan.max_arguments][]const u8 = undefined;
        for (plan.arguments[0..plan.argument_count], 0..) |argument, index| {
            argument_names[index] = try self.emitMirDirectCallArgument(argument);
        }
        try self.writeLineDirective(spanFromMirSourcePoint(plan.call_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}(", .{ try self.cTypeFor(current_ty, .typedef_name), current_name, try self.cIdent(plan.callee_name) });
        for (argument_names[0..plan.argument_count], 0..) |argument_name, index| {
            if (index != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, argument_name);
        }
        try self.out.appendSlice(self.allocator, ");\n");

        for (plan.projections[0..plan.projection_count], 0..) |projection, projection_index| switch (projection) {
            .field => |field| {
                const struct_name = self.mirDirectCallStructName(current_ty) orelse return error.UnsupportedCEmission;
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                if (field.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                const declared_field = struct_decl.fields[field.field_index];
                const next_name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(field.location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}.{s};\n", .{ try self.cTypeFor(declared_field.ty, .typedef_name), next_name, current_name, try self.cIdent(declared_field.name.text) });
                current_ty = declared_field.ty;
                current_name = next_name;
                if (plan.representation_check) |check| {
                    if (check.projection_index == projection_index) try self.emitMirDirectCallRepresentationCheck(check, current_name, current_ty);
                }
            },
            .index => |index| {
                const index_name = try self.nextTempName();
                try self.writeLineDirective(spanFromMirSourcePoint(index.location.source));
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(index.operand_fact.target_ty, .typedef_name), index_name });
                if (index.constant_value) |constant| {
                    try self.out.print(self.allocator, "{d}", .{constant});
                } else {
                    try self.out.appendSlice(self.allocator, try self.cIdent(index.operand_name));
                }
                try self.out.appendSlice(self.allocator, ";\n");

                const next_name = try self.nextTempName();
                const element_ty = index.type_fact.target_ty;
                try self.writeIndent();
                switch (self.resolveAliasType(current_ty).kind) {
                    .array => |array| {
                        const bound = try self.arrayLenTextForExpr(array.len);
                        if (index.checked) {
                            try self.out.print(self.allocator, "{s} {s} = {s}.elems[mc_check_index_usize({s}, {s})];\n", .{ try self.cTypeFor(element_ty, .typedef_name), next_name, current_name, index_name, bound });
                        } else {
                            try self.out.print(self.allocator, "{s} {s} = {s}.elems[{s}];\n", .{ try self.cTypeFor(element_ty, .typedef_name), next_name, current_name, index_name });
                        }
                    },
                    .slice => {
                        if (index.checked) {
                            try self.out.print(self.allocator, "{s} {s} = {s}.ptr[mc_check_index_usize({s}, {s}.len)];\n", .{ try self.cTypeFor(element_ty, .typedef_name), next_name, current_name, index_name, current_name });
                        } else {
                            try self.out.print(self.allocator, "{s} {s} = {s}.ptr[{s}];\n", .{ try self.cTypeFor(element_ty, .typedef_name), next_name, current_name, index_name });
                        }
                    },
                    else => return error.UnsupportedCEmission,
                }
                current_ty = element_ty;
                current_name = next_name;
                if (plan.representation_check) |check| {
                    if (check.projection_index == projection_index) try self.emitMirDirectCallRepresentationCheck(check, current_name, current_ty);
                }
            },
        };

        try self.writeLineDirective(spanFromMirSourcePoint(plan.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{current_name});
    }

    fn emitMirDirectCallRepresentationCheck(self: *CEmitter, check: mir_statement_plan.DirectCallRepresentationCheck, value_name: []const u8, value_ty: anytype) !void {
        try self.writeLineDirective(spanFromMirSourcePoint(check.location.source));
        switch (self.resolveAliasType(value_ty).kind) {
            .slice => {
                try self.writeIndent();
                try self.out.print(self.allocator, "if ({s}.ptr == NULL && {s}.len != 0) mc_trap_InvalidRepresentation();\n", .{ value_name, value_name });
                return;
            },
            else => {},
        }
        switch (check.result_ty) {
            .pointer, .cstr => {
                try self.writeIndent();
                try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_InvalidRepresentation();\n", .{value_name});
            },
            .slice => return error.UnsupportedCEmission,
            .closed_enum => |enum_name| {
                const enum_decl = self.enums.get(enum_name) orelse return error.UnsupportedCEmission;
                try self.writeIndent();
                try self.out.print(self.allocator, "switch ({s}) {{\n", .{value_name});
                self.indent += 1;
                for (enum_decl.cases) |case| {
                    try self.writeIndent();
                    try self.out.print(self.allocator, "case {s}_{s}: break;\n", .{ enum_name, try self.cIdent(case.name.text) });
                }
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "default: mc_trap_InvalidRepresentation();\n");
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
            },
            else => return error.UnsupportedCEmission,
        }
    }

    fn mirDirectCallStructName(self: *CEmitter, ty: anytype) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .name => |name| name.text,
            else => null,
        };
    }

    fn mirLocalAggregatePlaceUpdateReturnPlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.LocalAggregatePlaceUpdateReturnPlan) bool {
        const local_ty = plan.local_type_fact.target_ty;
        if (!self.mirAggregateValuePlanSupported(function, plan.initializer, local_ty)) return false;
        if (!std.mem.eql(u8, plan.local_name, plan.returned.root_name) or !plan.returned.root_id.eql(plan.local_id)) return false;

        const declared_return = function.signature.transitionalReturnType() orelse return false;
        const returned_ty = self.mirPlaceType(plan.returned, spanFromMirSourcePoint(plan.return_location.source)) catch return false;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(returned_ty))) return false;

        if (plan.update) |update| {
            if (update.target.root_kind != .local or !update.target.root_id.eql(plan.local_id) or !std.mem.eql(u8, update.target.root_name, plan.local_name)) return false;
            const target_ty = self.mirPlaceType(update.target, spanFromMirSourcePoint(update.location.source)) catch return false;
            switch (update.value) {
                .parameter => |parameter| {
                    if (!parameter.value_id.isValid() or !self.mirAggregateParameterMatchesSignature(function, parameter.name, target_ty)) return false;
                },
                .integer_literal => |literal| {
                    if (literal.type_fact.result_ty != .integer or !type_bridge.sameTypeSyntax(self.resolveAliasType(literal.type_fact.target_ty), self.resolveAliasType(target_ty))) return false;
                },
                else => return false,
            }
        }
        return true;
    }

    fn mirAggregateValuePlanSupported(self: *CEmitter, function: anytype, value: mir_statement_plan.AggregateValuePlan, expected_ty: anytype) bool {
        if (value.count == 0 or value.count > value.nodes.len or value.root >= value.count) return false;
        var seen = [_]bool{false} ** mir_statement_plan.max_aggregate_value_nodes;
        if (!self.mirAggregateValueNodeSupported(function, value, value.root, expected_ty, &seen)) return false;
        for (seen[0..value.count]) |used| if (!used) return false;
        return true;
    }

    fn mirAggregateValueNodeSupported(self: *CEmitter, function: anytype, value: mir_statement_plan.AggregateValuePlan, index: usize, expected_ty: anytype, seen: *[mir_statement_plan.max_aggregate_value_nodes]bool) bool {
        if (index >= value.count or seen[index]) return false;
        const node = value.nodes[index];
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(node.type_fact.target_ty), self.resolveAliasType(expected_ty))) return false;
        seen[index] = true;
        switch (node.operation) {
            .parameter => |parameter| {
                if (!parameter.value_id.isValid() or !self.mirAggregateParameterMatchesSignature(function, parameter.name, expected_ty)) return false;
            },
            .integer_literal => {
                if (node.type_fact.result_ty != .integer) return false;
            },
            .array_literal => |array_value| {
                if (node.type_fact.result_ty != .array or array_value.child_count > array_value.children.len) return false;
                const array = switch (self.resolveAliasType(expected_ty).kind) {
                    .array => |array| array,
                    else => return false,
                };
                const bound_text = self.arrayLenTextForExpr(array.len) catch return false;
                const bound = std.fmt.parseUnsigned(usize, bound_text, 10) catch return false;
                if (array_value.child_count != bound) return false;
                for (array_value.children[0..array_value.child_count]) |child| {
                    if (child.field_index != std.math.maxInt(usize) or !self.mirAggregateValueNodeSupported(function, value, child.node, array.child.*, seen)) return false;
                }
            },
            .struct_literal => |struct_value| {
                if (node.type_fact.result_ty != .struct_ or struct_value.child_count > struct_value.children.len) return false;
                const struct_name = switch (self.resolveAliasType(expected_ty).kind) {
                    .name => |name| name.text,
                    else => return false,
                };
                const struct_decl = self.structs.get(struct_name) orelse return false;
                if (struct_value.child_count != struct_decl.fields.len) return false;
                for (struct_value.children[0..struct_value.child_count], 0..) |child, child_index| {
                    if (child.field_index >= struct_decl.fields.len) return false;
                    for (struct_value.children[0..child_index]) |earlier| if (earlier.field_index == child.field_index) return false;
                    if (!self.mirAggregateValueNodeSupported(function, value, child.node, struct_decl.fields[child.field_index].ty, seen)) return false;
                }
            },
        }
        return true;
    }

    fn mirAggregateParameterMatchesSignature(self: *CEmitter, function: anytype, name: []const u8, expected_ty: anytype) bool {
        var found = false;
        for (function.signature.params) |parameter| {
            if (!std.mem.eql(u8, parameter.name.text, name)) continue;
            if (found or !type_bridge.sameTypeSyntax(self.resolveAliasType(parameter.ty), self.resolveAliasType(expected_ty))) return false;
            found = true;
        }
        return found;
    }

    fn emitMirLocalAggregatePlaceUpdateReturnPlan(self: *CEmitter, plan: mir_statement_plan.LocalAggregatePlaceUpdateReturnPlan) !void {
        const local_ty = plan.local_type_fact.target_ty;
        try self.writeLineDirective(spanFromMirSourcePoint(plan.declaration_location.source));
        try self.writeIndent();
        try self.emitDeclarator(local_ty, plan.local_name);
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitMirAggregateValuePlan(plan.initializer, plan.initializer.root, local_ty);
        try self.out.appendSlice(self.allocator, ";\n");

        if (plan.update) |update| {
            const target = try self.mirPlaceAccess(update.target);
            try self.writeLineDirective(spanFromMirSourcePoint(update.location.source));
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} = ", .{target});
            switch (update.value) {
                .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
                .integer_literal => |literal| try self.out.print(self.allocator, "{d}", .{literal.value}),
                else => return error.UnsupportedCEmission,
            }
            try self.out.appendSlice(self.allocator, ";\n");
        }

        const returned = try self.mirPlaceAccess(plan.returned);
        try self.writeLineDirective(spanFromMirSourcePoint(plan.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{returned});
    }

    fn emitMirAggregateValuePlan(self: *CEmitter, value: mir_statement_plan.AggregateValuePlan, index: usize, expected_ty: anytype) !void {
        if (index >= value.count) return error.UnsupportedCEmission;
        const node = value.nodes[index];
        switch (node.operation) {
            .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
            .integer_literal => |literal| try self.out.print(self.allocator, "{d}", .{literal}),
            .array_literal => |array_value| {
                const array = switch (self.resolveAliasType(expected_ty).kind) {
                    .array => |array| array,
                    else => return error.UnsupportedCEmission,
                };
                try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(expected_ty, .typedef_name)});
                for (array_value.children[0..array_value.child_count], 0..) |child, child_index| {
                    if (child_index != 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitMirAggregateValuePlan(value, child.node, array.child.*);
                }
                try self.out.appendSlice(self.allocator, " } }");
            },
            .struct_literal => |struct_value| {
                const struct_name = switch (self.resolveAliasType(expected_ty).kind) {
                    .name => |name| name.text,
                    else => return error.UnsupportedCEmission,
                };
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "({s}){{ ", .{try self.cTypeFor(expected_ty, .typedef_name)});
                for (struct_value.children[0..struct_value.child_count], 0..) |child, child_index| {
                    if (child.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                    if (child_index != 0) try self.out.appendSlice(self.allocator, ", ");
                    const field = struct_decl.fields[child.field_index];
                    try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(field.name.text)});
                    try self.emitMirAggregateValuePlan(value, child.node, field.ty);
                }
                try self.out.appendSlice(self.allocator, " }");
            },
        }
    }

    /// The shared MIR plan retains this source-shaped storage sequence on
    /// purpose: an explicit `uninit` declaration and its subsequent aggregate
    /// assignment can be observable in source maps and debugging output.  The
    /// C backend only validates types and materializes the plan; it never
    /// consults the legacy function-body artifact.
    fn mirLocalAggregateAssignmentReturnPlanSupported(self: *CEmitter, function: anytype, plan: mir_statement_plan.LocalAggregateAssignmentReturnPlan) bool {
        const declared_return = function.signature.transitionalReturnType() orelse return false;
        const local_ty = plan.local_type_fact.target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(declared_return), self.resolveAliasType(local_ty))) return false;

        switch (plan.value) {
            .array_literal => |literal| {
                if (plan.local_type_fact.result_ty != .array or literal.type_fact.result_ty != .array or !type_bridge.sameTypeSyntax(self.resolveAliasType(literal.type_fact.target_ty), self.resolveAliasType(local_ty))) return false;
                const array = switch (self.resolveAliasType(local_ty).kind) {
                    .array => |array| array,
                    else => return false,
                };
                const declared_bound = self.arrayLenTextForExpr(array.len) catch return false;
                const element_count = std.fmt.parseUnsigned(usize, declared_bound, 10) catch return false;
                if (element_count != literal.element_count) return false;
                for (literal.elements[0..literal.element_count]) |element| {
                    if (element.type_fact.result_ty != .integer or !type_bridge.sameTypeSyntax(self.resolveAliasType(element.type_fact.target_ty), self.resolveAliasType(array.child.*))) return false;
                }
            },
            .struct_literal => |literal| {
                if (plan.local_type_fact.result_ty != .struct_ or literal.type_fact.result_ty != .struct_ or !type_bridge.sameTypeSyntax(self.resolveAliasType(literal.type_fact.target_ty), self.resolveAliasType(local_ty))) return false;
                const struct_name = switch (literal.type_fact.result_ty) {
                    .struct_ => |name| name,
                    else => return false,
                };
                const struct_decl = self.structs.get(struct_name) orelse return false;
                if (literal.field_count != struct_decl.fields.len) return false;
                for (literal.fields[0..literal.field_count], 0..) |field, index| {
                    if (field.field_index >= struct_decl.fields.len) return false;
                    for (literal.fields[0..index]) |previous| {
                        if (previous.field_index == field.field_index) return false;
                    }
                    if (field.value.type_fact.result_ty != .integer or !type_bridge.sameTypeSyntax(self.resolveAliasType(field.value.type_fact.target_ty), self.resolveAliasType(struct_decl.fields[field.field_index].ty))) return false;
                }
            },
            else => return false,
        }
        return true;
    }

    fn emitMirLocalAggregateAssignmentReturnPlan(self: *CEmitter, plan: mir_statement_plan.LocalAggregateAssignmentReturnPlan) !void {
        const local_ty = plan.local_type_fact.target_ty;

        try self.writeLineDirective(spanFromMirSourcePoint(plan.declaration_location.source));
        try self.writeIndent();
        try self.emitDeclarator(local_ty, plan.local_name);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeLineDirective(spanFromMirSourcePoint(plan.assignment_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = ", .{try self.cIdent(plan.local_name)});
        try self.emitMirLocalAggregateAssignmentValue(local_ty, plan.value);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeLineDirective(spanFromMirSourcePoint(plan.return_location.source));
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{try self.cIdent(plan.local_name)});
    }

    fn emitMirLocalAggregateAssignmentValue(self: *CEmitter, local_ty: anytype, value: mir_statement_plan.PlaceStoreValue) !void {
        switch (value) {
            .array_literal => |literal| {
                try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(local_ty, .typedef_name)});
                for (literal.elements[0..literal.element_count], 0..) |element, index| {
                    if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, "{d}", .{element.value});
                }
                try self.out.appendSlice(self.allocator, " } }");
            },
            .struct_literal => |literal| {
                const struct_name = switch (literal.type_fact.result_ty) {
                    .struct_ => |name| name,
                    else => return error.UnsupportedCEmission,
                };
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "({s}){{ ", .{try self.cTypeFor(local_ty, .typedef_name)});
                for (literal.fields[0..literal.field_count], 0..) |field, index| {
                    if (field.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                    if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                    const declared_field = struct_decl.fields[field.field_index];
                    try self.out.print(self.allocator, ".{s} = {d}", .{ try self.cIdent(declared_field.name.text), field.value.value });
                }
                try self.out.appendSlice(self.allocator, " }");
            },
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitMirPlaceReturnPlan(self: *CEmitter, plan: mir_statement_plan.PlaceReturnPlan) !void {
        if (plan.local_init) |local| {
            const span = spanFromMirSourcePoint(local.location.source);
            const local_ty = try self.mirPlaceType(local.value, span);
            const initializer = try self.mirPlaceAccess(local.value);
            try self.writeLineDirective(span);
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(local_ty, .typedef_name), try self.cIdent(local.name), initializer });
        }
        if (plan.store) |store| {
            const span = spanFromMirSourcePoint(store.location.source);
            const target_ty = try self.mirPlaceType(store.target, span);
            const access = try self.mirPlaceAccess(store.target);
            try self.writeLineDirective(span);
            try self.writeIndent();
            const temp = try self.nextTempName();
            try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp });
            switch (store.value) {
                .parameter => |parameter| try self.out.appendSlice(self.allocator, try self.cIdent(parameter.name)),
                .integer_literal => |literal| try self.out.print(self.allocator, "{d}", .{literal.value}),
                .array_literal => |literal| {
                    const array = switch (self.resolveAliasType(target_ty).kind) {
                        .array => |array| array,
                        else => return error.UnsupportedCEmission,
                    };
                    const declared_bound = self.arrayLenTextForExpr(array.len) catch return error.UnsupportedCEmission;
                    const element_count = std.fmt.parseUnsigned(usize, declared_bound, 10) catch return error.UnsupportedCEmission;
                    if (element_count != literal.element_count) return error.UnsupportedCEmission;
                    for (literal.elements[0..literal.element_count]) |element| {
                        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element.type_fact.target_ty), self.resolveAliasType(array.child.*))) return error.UnsupportedCEmission;
                    }
                    try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(target_ty, .typedef_name)});
                    for (literal.elements[0..literal.element_count], 0..) |element, index| {
                        if (index != 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "{d}", .{element.value});
                    }
                    try self.out.appendSlice(self.allocator, " } }");
                },
                .struct_literal => |literal| try self.emitMirLocalAggregateAssignmentValue(target_ty, .{ .struct_literal = literal }),
            }
            try self.out.appendSlice(self.allocator, ";\n");
            try self.writeIndent();
            try appendGlobalStorePrefix(self.allocator, self.out, .{ .name = access, .info = try self.globalInfoFromType(target_ty) });
            try self.out.appendSlice(self.allocator, temp);
            try appendGlobalStoreSuffix(self.allocator, self.out, .{ .name = access, .info = try self.globalInfoFromType(target_ty) });
        }

        const return_span = spanFromMirSourcePoint(plan.return_location.source);
        const return_ty = try self.mirPlaceType(plan.returned, return_span);
        const access = try self.mirPlaceAccess(plan.returned);
        try self.writeLineDirective(return_span);
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        switch (plan.returned.root_kind) {
            .parameter, .local => try self.out.appendSlice(self.allocator, access),
            .global => try appendGlobalLoadExpr(self.allocator, self.out, access, try self.globalInfoFromType(return_ty)),
        }
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn mirPlaceAccess(self: *CEmitter, place: mir_statement_plan.Place) ![]const u8 {
        var access = try std.fmt.allocPrint(self.scratch.allocator(), "{s}", .{try self.cIdent(place.root_name)});
        for (place.projections[0..place.projection_count], 0..) |projection, projection_index| switch (projection) {
            .field => |field| access = if (place.root_indirect and projection_index == 0)
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}->{s}", .{ access, try self.cIdent(field.field_name) })
            else
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{ access, try self.cIdent(field.field_name) }),
            .constant_index => |index| access = if (index.checked)
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}.elems[mc_check_index_usize({d}, {d})]", .{ access, index.index, index.bound })
            else
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}.elems[{d}]", .{ access, index.index }),
        };
        return access;
    }

    fn mirPlaceType(self: *CEmitter, place: mir_statement_plan.Place, span: diagnostics.Span) !ast_bridge.TypeExpr {
        var ty = if (place.root_kind == .global)
            (self.globals.get(place.root_name) orelse return error.UnsupportedCEmission).source_ty orelse return error.UnsupportedCEmission
        else
            place.root_type_fact.target_ty;
        if (place.root_indirect) {
            ty = switch (self.resolveAliasType(ty).kind) {
                .pointer => |pointer| pointer.child.*,
                else => return error.UnsupportedCEmission,
            };
        }
        for (place.projections[0..place.projection_count]) |projection| switch (projection) {
            .field => |field_projection| {
                const struct_name = self.structTypeNameFromType(ty) orelse return error.UnsupportedCEmission;
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                if (field_projection.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                const field = struct_decl.fields[field_projection.field_index];
                if (!std.mem.eql(u8, field.name.text, field_projection.field_name)) return error.UnsupportedCEmission;
                ty = field.ty;
            },
            .constant_index => |index| {
                const array = switch (self.resolveAliasType(ty).kind) {
                    .array => |array| array,
                    else => return error.UnsupportedCEmission,
                };
                const declared_bound = self.arrayLenTextForExpr(array.len) catch return error.UnsupportedCEmission;
                const parsed_bound = std.fmt.parseUnsigned(usize, declared_bound, 10) catch return error.UnsupportedCEmission;
                if (parsed_bound != index.bound or index.index >= index.bound) return error.UnsupportedCEmission;
                ty = array.child.*;
            },
        };
        _ = span;
        return ty;
    }

    fn mirPlacePlanSupported(self: *CEmitter, plan: mir_statement_plan.PlaceReturnPlan, span: diagnostics.Span) bool {
        _ = self.mirPlaceType(plan.returned, span) catch return false;
        if (plan.local_init) |local| _ = self.mirPlaceType(local.value, span) catch return false;
        if (plan.store) |store| _ = self.mirPlaceType(store.target, span) catch return false;
        return true;
    }

    fn emitMirIndirectCallee(self: *CEmitter, callee: mir_statement_plan.IndirectCallee) !void {
        switch (callee) {
            .parameter => |name| try self.out.appendSlice(self.allocator, try self.cIdent(name)),
            .global => |name| try appendGlobalLoadExpr(self.allocator, self.out, name, self.globals.get(name) orelse return error.UnsupportedCEmission),
            .local_function => |local| try self.out.appendSlice(self.allocator, try self.cIdent(local.local_name)),
            .projected_place => |place| {
                const access = try self.mirPlaceAccess(place);
                const ty = try self.mirPlaceType(place, spanFromMirSourcePoint(place.root_location.source));
                try appendGlobalLoadExpr(self.allocator, self.out, access, try self.globalInfoFromType(ty));
            },
            .global_field => |field| {
                const struct_name = self.structTypeNameFromType(field.root_type_fact.target_ty) orelse return error.UnsupportedCEmission;
                const struct_decl = self.structs.get(struct_name) orelse return error.UnsupportedCEmission;
                if (field.field_index >= struct_decl.fields.len) return error.UnsupportedCEmission;
                const declared_field = struct_decl.fields[field.field_index];
                if (!std.mem.eql(u8, declared_field.name.text, field.field_name)) return error.UnsupportedCEmission;
                const access_name = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{
                    try self.cIdent(field.root_name),
                    try self.cIdent(field.field_name),
                });
                try appendGlobalLoadExpr(self.allocator, self.out, access_name, try self.globalInfoFromType(declared_field.ty));
            },
        }
    }

    fn emitSimpleMirVoidStatements(self: *CEmitter, statements: SimpleMirVoidStatements) !void {
        for (statements.statements[0..statements.count]) |statement| {
            switch (statement) {
                .direct_call => |call| {
                    try self.writeIndent();
                    try self.emitSimpleMirDirectCall(call);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
                .global_store => |store| {
                    try self.writeLineDirective(spanFromMirSourcePoint(store.source));
                    try self.writeIndent();
                    const target: GlobalAccess = .{
                        .name = store.name,
                        .info = self.globals.get(store.name) orelse return error.UnsupportedCEmission,
                    };
                    try self.emitSimpleMirUncheckedRangeCommentForGlobalStoreValue(store.value);
                    try appendGlobalStorePrefix(self.allocator, self.out, target);
                    try self.emitSimpleMirGlobalStoreValue(store.value);
                    try appendGlobalStoreSuffix(self.allocator, self.out, target);
                },
                .param_field_store => |store| {
                    try self.writeLineDirective(spanFromMirSourcePoint(store.source));
                    try self.writeIndent();
                    try self.out.print(self.allocator, "{s}->{s} = ", .{ try self.cIdent(store.param_name), try self.cIdent(store.field_name) });
                    try self.emitSimpleMirArg(store.value);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
            }
        }
    }

    fn emitSimpleMirVoidStatementSources(self: *CEmitter, function: anytype, fn_mir: mir.Function, statements: SimpleMirVoidStatementSources) !void {
        for (statements.sources[0..statements.count]) |statement| switch (statement) {
            .direct_call => |source| {
                const call = self.simpleMirDirectCallAtSource(function, fn_mir, source) orelse return error.UnsupportedCEmission;
                try self.writeIndent();
                try self.emitSimpleMirDirectCall(call);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .global_store => |store| {
                try self.writeLineDirective(spanFromMirSourcePoint(store.source));
                try self.writeIndent();
                const target: GlobalAccess = .{
                    .name = store.name,
                    .info = self.globals.get(store.name) orelse return error.UnsupportedCEmission,
                };
                const value = self.simpleMirGlobalStoreValue(function, fn_mir, store.name, store.value_source) orelse return error.UnsupportedCEmission;
                try self.emitSimpleMirUncheckedRangeCommentForGlobalStoreValue(value);
                try appendGlobalStorePrefix(self.allocator, self.out, target);
                try self.emitSimpleMirGlobalStoreValue(value);
                try appendGlobalStoreSuffix(self.allocator, self.out, target);
            },
        };
    }

    fn simpleMirAssignedValueInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8) ?SimpleMirConditionalValue {
        const source = self.simpleMirAssignmentSourceInBlock(block, local_name) orelse return null;
        return self.simpleMirConditionalValueAtSource(function, fn_mir, source);
    }

    fn simpleMirLocalValueInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8) ?SimpleMirConditionalValue {
        if (self.simpleMirAssignmentSourceInBlock(block, local_name)) |assigned_source| {
            return self.simpleMirConditionalValueAtSource(function, fn_mir, assigned_source);
        }
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        return self.simpleMirConditionalValueAtSource(function, fn_mir, init_source);
    }

    fn simpleMirConditionalTrapCount(value: SimpleMirConditionalValue) usize {
        return switch (value) {
            .checked_binary => |binary| simpleMirCheckedBinaryTrapCount(binary),
            .checked_unary => 1,
            .direct_call => |call| simpleMirDirectCallTrapCount(call),
            .compare_binary => |binary| simpleMirCompareBinaryTrapCount(binary),
            else => 0,
        };
    }

    fn simpleMirReturnAllowsTrapBlocks(self: *const CEmitter, fn_mir: mir.Function, ret: SimpleMirReturn) bool {
        return switch (ret) {
            // A bare param return emits `return p;` and never emits a trap; its
            // only trap edge is the elided nonnull representation check. Exclude
            // folded-local returns (`let x = p; return x;`, which reach `.param`
            // via simpleMirLocalInitReturn): those must stay on the fallback that
            // keeps the `let`'s source map and the inferred-local fail-closed check.
            .param => simpleMirAllTrapEdgesRepresentationChecks(fn_mir) and !simpleMirEntryBlockFoldsLocal(fn_mir),
            // The scalar deref's only trap is the elided nonnull representation
            // check; the recognizer already excluded folded locals and sanitizers.
            .scalar_deref_load => simpleMirAllTrapEdgesRepresentationChecks(fn_mir),
            .scalar_field_load => simpleMirAllTrapEdgesRepresentationChecks(fn_mir),
            .plain_unary => fn_mir.trap_edges.len == 0,
            .direct_call => |call| fn_mir.trap_edges.len == simpleMirDirectCallReturnTrapCount(fn_mir, call),
            .checked_integer_literal => fn_mir.trap_edges.len == 1,
            .checked_binary => |binary| fn_mir.trap_edges.len == simpleMirCheckedBinaryTrapCount(binary) and (self.noFunctionBodyFallbacksAvailable() or (simpleMirCheckedBinaryOperandsSimple(binary) and !simpleMirEntryBlockFoldsLocal(fn_mir))),
            .checked_unary => |unary| fn_mir.trap_edges.len == 1 and (self.noFunctionBodyFallbacksAvailable() or (simpleMirArgIsSimpleReturnOperand(unary.operand) and !simpleMirEntryBlockFoldsLocal(fn_mir))),
            // A comparison whose only extra trap edges are elided nonnull
            // representation checks (e.g. `a == b` on two pointer params) renders
            // as `(a == b)` with no trap, like a bare param return. Admit it past
            // those checks; exclude folded locals for source-map fidelity.
            .compare_binary => |binary| fn_mir.trap_edges.len == simpleMirCompareBinaryTrapCount(binary) or
                (simpleMirAllTrapEdgesRepresentationChecks(fn_mir) and !simpleMirEntryBlockFoldsLocal(fn_mir)),
            .plain_float_binary => fn_mir.trap_edges.len == 0,
            .explicit_cast_return => |cast| fn_mir.trap_edges.len == simpleMirCallArgTrapCount(cast.operand),
            .conversion_return => |conversion| fn_mir.trap_edges.len == simpleMirCallArgTrapCount(conversion.operand),
            .wrapping_binary => fn_mir.trap_edges.len == 0,
            .struct_literal => |literal| fn_mir.trap_edges.len == simpleMirStructLiteralTrapCount(literal),
            .array_literal => |literal| fn_mir.trap_edges.len == simpleMirArrayLiteralTrapCount(literal),
            .aggregate_return_pointer_load => fn_mir.trap_edges.len == 1,
            .global_address => fn_mir.trap_edges.len <= 1,
            .enum_literal => fn_mir.trap_edges.len >= 1 and self.noFunctionBodyFallbacksAvailable(),
            else => false,
        };
    }

    fn noFunctionBodyFallbacksAvailable(self: *const CEmitter) bool {
        return self.function_bodies.function_body_fallbacks.len == 0;
    }

    fn simpleMirLiteralBoundaryInstruction(instruction: mir.Instruction) bool {
        return instruction.kind == .call or instruction.kind == .binary or instruction.kind == .unary or instruction.kind == .return_value;
    }

    fn simpleMirCheckedBinaryOperandsSimple(binary: SimpleMirCheckedBinary) bool {
        return simpleMirArgIsSimpleReturnOperand(binary.left) and simpleMirArgIsSimpleReturnOperand(binary.right);
    }

    // A checked-arith operand the MIR fast path renders the same as the AST
    // fallback. Every SimpleMirArg is such a resolved simple operand (param /
    // param field / literal); the exhaustive switch forces a decision if a
    // non-trivial variant is added.
    fn simpleMirArgIsSimpleReturnOperand(arg: SimpleMirArg) bool {
        return switch (arg) {
            .param, .param_field, .integer_literal, .float_literal, .bool_literal, .enum_literal => true,
        };
    }

    // A `.local` in the entry block means the fast path folded a `let` into the
    // returned expression (e.g. `let y = a + b; return y` -> `return a + b`),
    // which drops that construct's source-map / `#line` entry. Direct-return
    // shapes (no folded local) lose no source-map fidelity, so only those are
    // admitted in normal emit; let-folding functions stay on the fallback that
    // still emits their per-construct source map.
    fn simpleMirEntryBlockFoldsLocal(fn_mir: mir.Function) bool {
        if (fn_mir.blocks.len == 0) return false;
        for (fn_mir.blocks[0].instructions) |instruction| {
            if (instruction.kind == .local) return true;
        }
        return false;
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
            return if (simpleMirSignedIntegerTypeName(binary.type_name)) 2 else 1;
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

    fn simpleMirDirectCallReturnTrapCount(fn_mir: mir.Function, call: SimpleMirDirectCall) usize {
        return simpleMirDirectCallTrapCount(call) + simpleMirRepresentationTrapCountAt(fn_mir, call.source);
    }

    fn simpleMirDirectCallsTrapCount(calls: SimpleMirDirectCalls) usize {
        var count: usize = 0;
        for (calls.calls[0..calls.count]) |call| count += simpleMirDirectCallTrapCount(call);
        return count;
    }

    fn simpleMirCompareBinaryTrapCount(binary: SimpleMirCompareBinary) usize {
        return if (binary.representation_check != null) 1 else 0;
    }

    fn emitSimpleMirCompareRepresentationCheck(self: *CEmitter, binary: SimpleMirCompareBinary) !void {
        const check = binary.representation_check orelse return;
        const enum_decl = self.enums.get(check.enum_name) orelse return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, "switch ((int)(");
        try self.emitSimpleMirArg(check.subject);
        try self.out.appendSlice(self.allocator, ")) {\n");
        self.indent += 1;
        for (enum_decl.cases) |case| {
            try self.writeIndent();
            try self.out.print(self.allocator, "case {s}_{s}: break;\n", .{ check.enum_name, case.name.text });
        }
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "default: mc_trap_InvalidRepresentation();\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitSimpleMirCompareBinary(self: *CEmitter, binary: SimpleMirCompareBinary) !void {
        try self.out.appendSlice(self.allocator, "(");
        try self.emitSimpleMirArg(binary.left);
        try self.out.print(self.allocator, " {s} ", .{try simpleMirCCompareOp(binary.op)});
        try self.emitSimpleMirArg(binary.right);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitSimpleMirArg(self: *CEmitter, arg: SimpleMirArg) !void {
        switch (arg) {
            .param => |name| try self.out.appendSlice(self.allocator, try self.cIdent(name)),
            .param_field => |field| try self.out.print(self.allocator, "{s}.{s}", .{ try self.cIdent(field.param_name), try self.cIdent(field.field_name) }),
            .integer_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .float_literal => |literal| try self.emitSimpleMirFloatLiteral(literal),
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .enum_literal => |literal| try self.out.print(self.allocator, "{s}_{s}", .{ literal.enum_name, literal.case_name }),
        }
    }

    fn emitSimpleMirGlobalStoreValue(self: *CEmitter, value: SimpleMirGlobalStoreValue) !void {
        switch (value) {
            .arg => |arg| try self.emitSimpleMirArg(arg),
            .float_literal => |literal| try self.emitSimpleMirFloatLiteral(literal),
            .global_load => |name| try appendGlobalLoadExpr(self.allocator, self.out, name, self.globals.get(name) orelse return error.UnsupportedCEmission),
            .direct_call => |call| try self.emitSimpleMirDirectCall(call),
            .checked_binary => |binary| {
                const helper = try self.checkedHelperName(binary.op, binary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(binary.left);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitSimpleMirArg(binary.right);
                try self.out.appendSlice(self.allocator, ")");
            },
            .checked_unary => |unary| {
                const helper = try self.checkedUnaryHelperName(unary.op, unary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(unary.operand);
                try self.out.appendSlice(self.allocator, ")");
            },
            .wrapping_binary => |binary| try self.emitSimpleMirWrappingBinaryExpr(binary),
            .explicit_cast => |cast| try self.emitSimpleMirExplicitCastExpr(cast),
            .conversion => |conversion| try self.emitSimpleMirConversionExpr(conversion),
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary),
            .logical_not => |arg| {
                try self.out.appendSlice(self.allocator, "!");
                try self.emitSimpleMirArg(arg);
            },
            .enum_literal => |literal| try self.out.print(self.allocator, "{s}_{s}", .{ literal.enum_name, literal.case_name }),
            .null_literal => |literal| try self.emitSimpleMirNullExpr(literal),
            .struct_literal => |literal| try self.emitSimpleMirStructLiteral(literal),
            .result_constructor => |constructor| try self.emitSimpleMirResultConstructorExpr(constructor),
        }
    }

    fn emitSimpleMirFloatLiteral(self: *CEmitter, literal: SimpleMirFloatLiteral) !void {
        try appendCFloatLiteral(self.allocator, self.out, literal.literal, std.mem.eql(u8, literal.target_type_name, "f32"));
    }

    fn emitSimpleMirResultConstructorExpr(self: *CEmitter, constructor: SimpleMirResultConstructorReturn) !void {
        try self.out.print(self.allocator, "(({s}){{ .is_ok = ", .{try self.cTypeFor(constructor.result_fact.target_ty, .typedef_name)});
        try self.out.appendSlice(self.allocator, if (std.mem.eql(u8, constructor.tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
        try self.emitSimpleMirResultConstructorPayload(constructor.payload);
        try self.out.appendSlice(self.allocator, " })");
    }

    fn emitSimpleMirUncheckedRangeCommentForGlobalStoreValue(self: *CEmitter, value: SimpleMirGlobalStoreValue) !void {
        switch (value) {
            .wrapping_binary => |binary| switch (binary.kind) {
                .wrapping_add, .serial_before, .serial_after, .serial_distance, .counter_delta_mod => {},
                .unchecked => {
                    const fact = binary.range_fact orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "/* MC_MIR_RANGE no_overflow target={s} op={s} */\n", .{ fact.target, fact.op });
                    try self.writeIndent();
                },
            },
            else => {},
        }
    }

    fn emitSimpleMirExplicitCastExpr(self: *CEmitter, cast: SimpleMirExplicitCastReturn) !void {
        _ = cast.source_fact;
        try self.out.print(self.allocator, "(({s})(", .{try self.cTypeFor(cast.target_fact.target_ty, .typedef_name)});
        try self.emitSimpleMirCallArg(cast.operand);
        try self.out.appendSlice(self.allocator, "))");
    }

    fn emitSimpleMirConversionExpr(self: *CEmitter, conversion: SimpleMirConversionReturn) !void {
        switch (conversion.kind) {
            .bitcast => return self.emitSimpleMirBitcastExpr(conversion),
            .enum_raw => return self.emitSimpleMirCallArg(conversion.operand),
            .conversion_from, .conversion_wrap_from, .conversion_from_mod, .phys => {},
            else => return error.UnsupportedCEmission,
        }
        try self.out.print(self.allocator, "(({s})(", .{try self.cTypeFor(conversion.target_fact.target_ty, .typedef_name)});
        try self.emitSimpleMirCallArg(conversion.operand);
        try self.out.appendSlice(self.allocator, "))");
    }

    fn emitSimpleMirBitcastExpr(self: *CEmitter, conversion: SimpleMirConversionReturn) !void {
        const source_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_bc_src{d}", .{self.temp_index});
        self.temp_index += 1;
        const target_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_bc_dst{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ {s} {s} = ", .{ try self.cTypeFor(conversion.source_fact.target_ty, .typedef_name), source_name });
        try self.emitSimpleMirCallArg(conversion.operand);
        try self.out.print(self.allocator, "; {s} {s}; _Static_assert(sizeof({s}) == sizeof({s}), \"MC bitcast width mismatch\"); __builtin_memcpy(&{s}, &{s}, sizeof({s})); {s}; }})", .{
            try self.cTypeFor(conversion.target_fact.target_ty, .typedef_name),
            target_name,
            source_name,
            target_name,
            target_name,
            source_name,
            source_name,
            target_name,
        });
    }

    fn emitSimpleMirWrappingBinaryExpr(self: *CEmitter, binary: SimpleMirWrappingBinary) !void {
        if (binary.kind == .serial_before or binary.kind == .serial_after) {
            const inner_name = self.underlyingIntTypeName(binary.operation_fact.target_ty) orelse return error.UnsupportedCEmission;
            const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
            const unsigned_c = try self.cTypeFor(binary.operation_fact.target_ty, .typedef_name);
            try self.out.print(self.allocator, "(({s})(({s})(", .{ signed_c, unsigned_c });
            try self.emitSimpleMirCallArg(binary.left);
            try self.out.appendSlice(self.allocator, " - ");
            try self.emitSimpleMirCallArg(binary.right);
            try self.out.print(self.allocator, ")) {s} 0)", .{if (binary.kind == .serial_before) "<" else ">"});
            return;
        }
        const op = if (std.mem.eql(u8, binary.op, "add"))
            "+"
        else if (std.mem.eql(u8, binary.op, "sub"))
            "-"
        else if (std.mem.eql(u8, binary.op, "mul"))
            "*"
        else
            return error.UnsupportedCEmission;
        if (binary.kind == .serial_distance or binary.kind == .counter_delta_mod) {
            try self.out.print(self.allocator, "(({s})(", .{try self.cTypeFor(binary.operation_fact.target_ty, .typedef_name)});
        } else {
            try self.out.appendSlice(self.allocator, "(");
        }
        try self.emitSimpleMirCallArg(binary.left);
        try self.out.print(self.allocator, " {s} ", .{op});
        try self.emitSimpleMirCallArg(binary.right);
        try self.out.appendSlice(self.allocator, if (binary.kind == .serial_distance or binary.kind == .counter_delta_mod) "))" else ")");
    }

    fn emitSimpleMirPlainFloatBinaryExpr(self: *CEmitter, binary: SimpleMirPlainFloatBinary) !void {
        _ = binary.target_fact;
        const op = try simpleMirCFloatBinaryOp(binary.op);
        try self.out.appendSlice(self.allocator, "(");
        try self.emitSimpleMirArg(binary.left);
        try self.out.print(self.allocator, " {s} ", .{op});
        try self.emitSimpleMirArg(binary.right);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitSimpleMirCallArg(self: *CEmitter, arg: SimpleMirCallArg) !void {
        switch (arg) {
            .local => |name| try self.out.appendSlice(self.allocator, try self.cIdent(name)),
            .param => |name| try self.out.appendSlice(self.allocator, try self.cIdent(name)),
            .param_field => |field| try self.out.print(self.allocator, "{s}.{s}", .{ try self.cIdent(field.param_name), try self.cIdent(field.field_name) }),
            .integer_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .float_literal => |literal| try self.emitSimpleMirFloatLiteral(literal),
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .enum_literal => |literal| try self.out.print(self.allocator, "{s}_{s}", .{ literal.enum_name, literal.case_name }),
            .global_load => |name| try appendGlobalLoadExpr(self.allocator, self.out, name, self.globals.get(name) orelse return error.UnsupportedCEmission),
            .global_address => |name| try self.out.print(self.allocator, "&{s}", .{try self.cIdent(name)}),
            .direct_call => |call| try self.emitSimpleMirNestedCall(call),
            .checked_binary => |binary| {
                const helper = try self.checkedHelperName(binary.op, binary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(binary.left);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitSimpleMirArg(binary.right);
                try self.out.appendSlice(self.allocator, ")");
            },
            .checked_unary => |unary| {
                const helper = try self.checkedUnaryHelperName(unary.op, unary.type_name);
                try self.out.print(self.allocator, "{s}(", .{helper});
                try self.emitSimpleMirArg(unary.operand);
                try self.out.appendSlice(self.allocator, ")");
            },
            .logical_not => |operand| {
                try self.out.appendSlice(self.allocator, "!");
                try self.emitSimpleMirArg(operand);
            },
            .compare_binary => |binary| try self.emitSimpleMirCompareBinary(binary),
        }
    }

    fn emitSimpleMirAggregateReturnPointerLoad(self: *CEmitter, load: SimpleMirAggregateReturnPointerLoad) !void {
        const scalar = simpleMirScalarCInfo(load.pointee_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(", .{ scalar.c_type, scalar.race_type_name });
        try self.out.appendSlice(self.allocator, "(");
        try self.emitSimpleMirDirectCall(load.call);
        try self.out.print(self.allocator, ").{s}))", .{load.fact.field_path});
    }

    const SimpleMirScalarCInfo = struct {
        c_type: []const u8,
        race_type_name: []const u8,
    };

    fn simpleMirScalarCInfo(ty: mir.ValueType) ?SimpleMirScalarCInfo {
        const name = ty.name();
        for (lower_c_shape.race_scalar_helpers) |helper| {
            if (std.mem.eql(u8, helper.name, name)) {
                return .{
                    .c_type = helper.c_type,
                    .race_type_name = helper.name,
                };
            }
        }
        return null;
    }

    // Like simpleMirScalarCInfo but also resolves the opaque address types
    // (PAddr/VAddr/DmaAddr): C type uintptr_t, loaded as their usize
    // representation. Used only by the pointer-field/deref load path.
    fn simpleMirScalarLikeCInfo(ty: mir.ValueType) ?SimpleMirScalarCInfo {
        if (simpleMirScalarCInfo(ty)) |info| return info;
        if (type_bridge.isOpaqueAddressTypeName(ty.name())) return .{ .c_type = "uintptr_t", .race_type_name = "usize" };
        return null;
    }

    fn emitSimpleMirDirectCall(self: *CEmitter, call: SimpleMirDirectCall) !void {
        try self.out.print(self.allocator, "{s}(", .{try self.cIdent(call.callee)});
        for (call.args[0..call.arg_count], 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitSimpleMirCallArg(arg);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitSimpleMirNestedCall(self: *CEmitter, call: SimpleMirNestedCall) !void {
        try self.out.print(self.allocator, "{s}(", .{try self.cIdent(call.callee)});
        for (call.args[0..call.arg_count], 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitSimpleMirArg(arg);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn simpleMirCheckedBinaryAtReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCheckedBinary {
        return self.simpleMirCheckedBinaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .binary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCheckedBinaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCheckedBinary {
        const block, const binary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        const target_name = typeName(self.resolveAliasType(target_fact.target_ty)) orelse return null;
        if (!simpleMirBinaryOpSupported(binary_instr.detail)) return null;
        if (!mirHasCheckedBinaryTrapsAt(fn_mir, source, binary_instr.detail, target_name)) return null;
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
        return .{ .op = binary_instr.detail, .type_name = target_name, .left = operands[0], .right = operands[1] };
    }

    fn simpleMirPlainFloatBinaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirPlainFloatBinary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        const block, const binary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!simpleMirFloatBinaryOpSupported(binary_instr.detail)) return null;
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        const target_name = typeName(self.resolveAliasType(target_fact.target_ty)) orelse return null;
        if (!std.mem.eql(u8, target_name, "f32") and !std.mem.eql(u8, target_name, "f64")) return null;
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

    // `return a + b` (also `-`, `*`) for unsigned integer wrap arithmetic. `wrap<T>`
    // is always unsigned, and for a u32/u64/usize result the C rendering is a plain
    // `(a op b)` with no integer-promotion casts (unlike u8/u16), so it matches the
    // fallback. No trap (wrapping add/sub/mul never trap → simpleMirNoTrap holds),
    // no folded local. Reuses SimpleMirPlainFloatBinary — the render is identical.
    fn simpleMirPlainUnsignedBinaryReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirPlainFloatBinary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (simpleMirEntryBlockFoldsLocal(fn_mir)) return null;
        const block = fn_mir.blocks[0];
        var binary_instr: ?mir.Instruction = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .binary) {
                binary_instr = instruction;
                break;
            }
        }
        const bi = binary_instr orelse return null;
        const op = bi.detail;
        if (!simpleMirPlainUnsignedBinaryOp(op)) return null;
        const source = instructionSourcePoint(bi);
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        // `wrap<T>` records its domain type ("wrap") in the fact, so gate on the
        // lowered C type: uint32_t/uint64_t undergo no C integer promotion, so a
        // plain `(a op b)` matches the fallback. u8/u16 (which promote to int and
        // get `(unsigned int)` casts) are excluded and stay on the fallback.
        const c_type = self.cTypeFor(target_fact.target_ty, .typedef_name) catch return null;
        if (!(std.mem.eql(u8, c_type, "uint32_t") or std.mem.eql(u8, c_type, "uint64_t"))) return null;
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
        return .{ .op = op, .target_fact = target_fact, .left = operands[0], .right = operands[1] };
    }

    fn simpleMirCompareBinaryAtReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCompareBinary {
        return self.simpleMirCompareBinaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .binary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCompareBinaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCompareBinary {
        const block, const binary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!simpleMirCompareOpSupported(binary_instr.detail)) return null;
        var operands: [2]SimpleMirArg = undefined;
        var representation_check: ?SimpleMirEnumRepresentationCheck = null;
        var count: usize = 0;
        var after_binary = false;
        var last_operand_source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (!after_binary) {
                after_binary = instruction.kind == .binary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr and
                instruction.kind != .integer_literal_conversion and
                instruction.kind != .binary and
                instruction.kind != .unary and
                instruction.kind != .representation_check and
                instruction.kind != .representation_use) continue;
            const arg_source = instructionSourcePoint(instruction);
            if (last_operand_source) |last| {
                if (sameMirSourceLocation(last, arg_source)) continue;
            }
            const arg = self.simpleMirArgAt(function, fn_mir, arg_source) orelse return null;
            if (count >= operands.len) return null;
            operands[count] = arg;
            if (representation_check == null and simpleMirRepresentationTrapCountAt(fn_mir, arg_source) == 1) {
                const fact = self.simpleMirOperandTargetTypeFactAt(fn_mir, arg_source) orelse return null;
                if (self.enumNameForType(fact.target_ty)) |enum_name| {
                    representation_check = .{ .enum_name = enum_name, .subject = arg };
                } else switch (self.resolveAliasType(fact.target_ty).kind) {
                    // A pointer operand's nonnull check is elided in a comparison
                    // (no deref), so skip it — the render is a plain `(a == b)`.
                    .pointer => {},
                    else => return null,
                }
            }
            last_operand_source = arg_source;
            count += 1;
            if (count == operands.len) break;
        }
        if (count != 2) return null;
        return .{ .op = binary_instr.detail, .left = operands[0], .right = operands[1], .representation_check = representation_check };
    }

    fn simpleMirLogicalNotAtReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirArg {
        return self.simpleMirLogicalNotAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .unary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirLogicalNotAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArg {
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

    // `return ~a` (bitwise not) / `return -a` (wrapping negate) — non-trapping
    // unary ops rendered as `op(operand)`. Signed negate is checked (traps on
    // INT_MIN) so it never reaches here (simpleMirNoTrap); wrapping negate and
    // bitwise-not never trap. No folded local.
    fn simpleMirPlainUnaryReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirPlainUnary {
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (simpleMirEntryBlockFoldsLocal(fn_mir)) return null;
        const block = fn_mir.blocks[0];
        var unary_instr: ?mir.Instruction = null;
        for (block.instructions) |instruction| {
            if (instruction.kind == .unary) {
                unary_instr = instruction;
                break;
            }
        }
        const ui = unary_instr orelse return null;
        const op_c: []const u8 = if (std.mem.eql(u8, ui.detail, "bit_not"))
            "~"
        else if (std.mem.eql(u8, ui.detail, "neg"))
            "-"
        else
            return null;
        const source = instructionSourcePoint(ui);
        var after_unary = false;
        for (block.instructions) |instruction| {
            if (!after_unary) {
                after_unary = instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr) continue;
            const operand = self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse return null;
            return .{ .op_c = op_c, .operand = operand };
        }
        return null;
    }

    fn simpleMirCheckedUnaryAtReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirCheckedUnary {
        return self.simpleMirCheckedUnaryAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks[0].instructions) |instruction| {
                if (instruction.kind == .unary) break :blk instructionSourcePoint(instruction);
            }
            return null;
        });
    }

    fn simpleMirCheckedUnaryAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCheckedUnary {
        const block, const unary_instr = blk: {
            for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source)) break :blk .{ block, instruction };
            };
            return null;
        };
        if (!std.mem.eql(u8, unary_instr.detail, "neg")) return null;
        if (!mirHasIntegerOverflowTrapAt(fn_mir, source)) return null;
        const target_fact = self.simpleMirTargetTypeFactAt(fn_mir, source) orelse return null;
        const target_name = typeName(self.resolveAliasType(target_fact.target_ty)) orelse return null;
        if (!simpleMirSignedIntegerTypeName(target_name)) return null;
        var after_unary = false;
        for (block.instructions) |instruction| {
            if (!after_unary) {
                after_unary = instruction.kind == .unary and sameMirSourceLocation(instructionSourcePoint(instruction), source);
                continue;
            }
            if (instruction.kind == .return_value or instruction.kind == .local) break;
            if (instruction.kind != .expr and instruction.kind != .integer_literal_conversion and instruction.kind != .binary and instruction.kind != .unary) continue;
            const operand = self.simpleMirArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse return null;
            return .{ .op = unary_instr.detail, .type_name = target_name, .operand = operand };
        }
        return null;
    }

    fn simpleMirFoldedNegatedIntegerLiteral(self: *CEmitter, unary: SimpleMirCheckedUnary) ?[]const u8 {
        if (!std.mem.eql(u8, unary.op, "neg")) return null;
        const literal = switch (unary.operand) {
            .integer_literal => |value| value,
            else => return null,
        };
        if (literal.len == 0 or literal[0] == '-') return null;
        return std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{literal}) catch null;
    }

    fn simpleMirDirectCall(self: *CEmitter, function: anytype, fn_mir: mir.Function, callee: []const u8) ?SimpleMirDirectCall {
        return self.simpleMirDirectCallAtSource(function, fn_mir, blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, callee)) break :blk instructionSourcePoint(instruction);
                }
            }
            return null;
        });
    }

    fn simpleMirDirectCallAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirDirectCall {
        const call_block, const callee = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) break :blk .{ block, instruction.detail };
                }
            }
            return null;
        };
        var arg_count: usize = 0;
        var call: SimpleMirDirectCall = .{ .callee = callee, .source = call_source };
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
            if (instruction.kind == .call) {
                // A nested-call argument (e.g. `g(f())`) appears as its own call
                // at the argument's source; it is the outer call's arg, inlined,
                // not a separate statement — skip it and let the arg expr below
                // pick it up via simpleMirCallArgAt.
                if (self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, instructionSourcePoint(instruction)) != null) continue;
                break;
            }
            if (instruction.kind != .expr and
                instruction.kind != .integer_literal_conversion and
                instruction.kind != .binary and
                instruction.kind != .unary and
                instruction.kind != .representation_check and
                instruction.kind != .representation_use) continue;
            const arg_source = instructionSourcePoint(instruction);
            const fact = self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, arg_source) orelse continue;
            const arg_index = fact.target_index orelse return null;
            if (arg_index >= max_simple_mir_call_args) return null;
            call.args[arg_index] = self.simpleMirCallArgAt(function, fn_mir, arg_source) orelse return null;
            seen_args[arg_index] = true;
            arg_count = @max(arg_count, arg_index + 1);
        }
        const fn_info = self.functions.get(callee) orelse return null;
        if (!fn_info.acceptsArgCount(arg_count)) return null;
        for (seen_args[0..arg_count]) |seen| if (!seen) return null;
        call.arg_count = arg_count;
        if (arg_count > 1) {
            // Argument evaluation order is unspecified in C, so a call whose args
            // contain more than one side-effecting sub-call could observe a
            // different order than MC's left-to-right semantics — decline it (the
            // fallback sequences those through temps). A single nested call is
            // safe iff every *other* arg is a pure leaf (param/literal): only one
            // call is sequenced, and pure leaves have no observable order.
            var nested_calls: usize = 0;
            for (call.args[0..arg_count]) |arg| {
                if (simpleMirCallArgHasDirectCall(arg)) nested_calls += 1;
            }
            if (nested_calls > 1) return null;
            if (nested_calls == 1) {
                for (call.args[0..arg_count]) |arg| {
                    if (simpleMirCallArgHasDirectCall(arg)) continue;
                    if (!simpleMirCallArgIsPureLeaf(arg)) return null;
                }
            }
        }
        return call;
    }

    fn simpleMirDirectCallAtSourceWithLocalArg(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint, local_name: []const u8, local_value_id: mir.ValueId) ?SimpleMirDirectCall {
        const call_block, const callee = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) break :blk .{ block, instruction.detail };
                }
            }
            return null;
        };
        var arg_count: usize = 0;
        var call: SimpleMirDirectCall = .{ .callee = callee, .source = call_source };
        var seen_args = [_]bool{false} ** max_simple_mir_call_args;
        var saw_result = false;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .direct_call_result and std.mem.eql(u8, fact.target_owner orelse "", callee) and sameMirSourceLocation(fact.source, call_source)) {
                saw_result = true;
            }
        }
        if (!saw_result) return null;
        var saw_local_arg = false;
        var after_call = false;
        for (call_block.instructions) |instruction| {
            if (!after_call) {
                after_call = instruction.kind == .call and sameMirSourceLocation(instructionSourcePoint(instruction), call_source);
                continue;
            }
            if (instruction.kind == .return_value) break;
            if (instruction.kind == .call) {
                if (self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, instructionSourcePoint(instruction)) != null) continue;
                break;
            }
            if (instruction.kind != .expr and
                instruction.kind != .integer_literal_conversion and
                instruction.kind != .binary and
                instruction.kind != .unary and
                instruction.kind != .representation_check and
                instruction.kind != .representation_use) continue;
            const arg_source = instructionSourcePoint(instruction);
            const fact = self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, arg_source) orelse continue;
            const arg_index = fact.target_index orelse return null;
            if (arg_index >= max_simple_mir_call_args) return null;
            if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, local_name)) {
                const arg_value_id = instruction.typed_value_id orelse return null;
                if (!arg_value_id.isValid() or !arg_value_id.eql(local_value_id)) return null;
                call.args[arg_index] = .{ .local = local_name };
                saw_local_arg = true;
            } else {
                call.args[arg_index] = self.simpleMirCallArgAt(function, fn_mir, arg_source) orelse return null;
                if (simpleMirCallArgHasDirectCall(call.args[arg_index])) return null;
            }
            seen_args[arg_index] = true;
            arg_count = @max(arg_count, arg_index + 1);
        }
        if (!saw_local_arg) return null;
        const fn_info = self.functions.get(callee) orelse return null;
        if (!fn_info.acceptsArgCount(arg_count)) return null;
        for (seen_args[0..arg_count]) |seen| if (!seen) return null;
        call.arg_count = arg_count;
        return call;
    }

    // A call argument with no observable evaluation-order dependence on a
    // sibling call: params and compile-time literals only. Deliberately
    // conservative — excludes field/global reads (a sibling call could mutate
    // them) and any trap-bearing sub-expression.
    fn simpleMirCallArgIsPureLeaf(arg: SimpleMirCallArg) bool {
        return switch (arg) {
            .local, .param, .integer_literal, .float_literal, .bool_literal, .enum_literal => true,
            else => false,
        };
    }

    fn simpleMirResultConstructorReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirResultConstructorReturn {
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
        const return_ty = function.signature.transitionalReturnType() orelse return null;
        return self.simpleMirResultConstructorFromBlockAtSourceWithType(function, fn_mir, block, call_source, kind, return_ty);
    }

    fn simpleMirResultConstructorAtSourceWithType(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint, target_ty: anytype) ?SimpleMirResultConstructorReturn {
        const kind = simpleMirResultConstructorKindAtSource(fn_mir, source) orelse return null;
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .call) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                return self.simpleMirResultConstructorFromBlockAtSourceWithType(function, fn_mir, block, source, kind, target_ty);
            }
        }
        return null;
    }

    fn simpleMirResultConstructorFromBlockAtSourceWithType(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, call_source: mir.SourcePoint, kind: mir.CallTargetKind, target_ty: anytype) ?SimpleMirResultConstructorReturn {
        const constructor = mir.resultConstructorFactInfo(kind) orelse return null;
        const target_fact = simpleMirTargetTypeFactKindAt(fn_mir, constructor.target_kind, call_source) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(target_ty), self.resolveAliasType(target_fact.target_ty))) return null;

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

    fn emitSimpleMirResultConstructorPayload(self: *CEmitter, payload: SimpleMirResultConstructorPayload) !void {
        switch (payload) {
            .arg => |arg| try self.emitSimpleMirCallArg(arg),
            .enum_literal => |literal| try self.out.print(self.allocator, "{s}_{s}", .{ literal.enum_name, literal.case_name }),
        }
    }

    fn simpleMirDirectCallArgumentFactAt(self: *CEmitter, fn_mir: mir.Function, callee: []const u8, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .direct_call_argument) continue;
            if (!std.mem.eql(u8, fact.target_owner orelse "", callee)) continue;
            if (sameMirSourceLocation(fact.source, source)) return fact;
        }
        return null;
    }

    fn simpleMirTypedUnaryCallTargetReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, value_id: []const u8) ?SimpleMirConversionReturn {
        const block = fn_mir.blocks[0];
        const call_source = simpleMirReturnValueSource(block, value_id) orelse return null;
        var matching_calls: usize = 0;
        for (block.instructions) |instruction| {
            if (instruction.kind != .call or !std.mem.eql(u8, instruction.detail, value_id)) continue;
            if (!sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) continue;
            matching_calls += 1;
        }
        if (matching_calls != 1) return null;
        const result = self.simpleMirTypedUnaryCallTargetAtSource(function, fn_mir, call_source) orelse return null;
        const declared_return = function.signature.transitionalReturnType() orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(result.target_fact.target_ty), self.resolveAliasType(declared_return))) return null;
        return result;
    }

    fn simpleMirConversionAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirConversionReturn {
        const conversion = self.simpleMirTypedUnaryCallTargetAtSource(function, fn_mir, call_source) orelse return null;
        return switch (conversion.kind) {
            .conversion_from, .conversion_wrap_from, .conversion_from_mod => conversion,
            else => null,
        };
    }

    fn simpleMirTypedUnaryCallTargetAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirConversionReturn {
        var call_block: ?mir.Block = null;
        var canonical_call_source: mir.SourcePoint = undefined;
        var call_count: usize = 0;
        for (fn_mir.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.kind != .call or !sameMirSourceLocation(instructionSourcePoint(instruction), call_source)) continue;
            call_block = block;
            canonical_call_source = instructionSourcePoint(instruction);
            call_count += 1;
        };
        if (call_count != 1) return null;
        const block = call_block orelse return null;
        const call_target_fact = simpleMirTypedUnaryCallTargetFactAt(fn_mir, canonical_call_source) orelse return null;
        const kind = call_target_fact.kind;
        const initial_source_fact, const target_fact = switch (kind) {
            .conversion_from, .conversion_wrap_from, .conversion_from_mod => .{
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .conversion_source, canonical_call_source) orelse return null,
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .conversion_target, canonical_call_source) orelse return null,
            },
            .bitcast => .{
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .bitcast_source, canonical_call_source) orelse return null,
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .bitcast_target, canonical_call_source) orelse return null,
            },
            .enum_raw => .{
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .enum_raw_source, canonical_call_source) orelse return null,
                simpleMirUniqueTargetTypeFactKindAt(fn_mir, .enum_raw_result, canonical_call_source) orelse return null,
            },
            .phys => blk: {
                const target = simpleMirUniqueTargetTypeFactKindAt(fn_mir, .phys_result, canonical_call_source) orelse return null;
                const c_type = self.cTypeFor(target.target_ty, .typedef_name) catch return null;
                if (!std.mem.eql(u8, c_type, "uintptr_t")) return null;
                break :blk .{ target, target };
            },
            else => return null,
        };
        var source_fact = initial_source_fact;
        if (!sameSimpleMirValueType(call_target_fact.result_ty, target_fact.result_ty)) return null;
        switch (kind) {
            .bitcast => {
                const source_size = self.comptimeSizeOf(source_fact.target_ty, 0) orelse return null;
                const target_size = self.comptimeSizeOf(target_fact.target_ty, 0) orelse return null;
                if (source_size <= 0 or source_size != target_size) return null;
            },
            .enum_raw => {
                const enum_name = self.enumNameForType(source_fact.target_ty) orelse return null;
                const enum_decl = self.enums.get(enum_name) orelse return null;
                const repr_ty = enum_decl.repr orelse type_bridge.simpleNameType("isize", enum_decl.name.span);
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(repr_ty), self.resolveAliasType(target_fact.target_ty))) return null;
            },
            else => {},
        }
        const operand_fact = simpleMirUniqueTypedUnaryOperandFactAt(fn_mir, canonical_call_source) orelse return null;
        const operand_instruction = simpleMirTypedLeafOperandInstruction(block, operand_fact.source) orelse return null;
        const operand = self.simpleMirTypedLeafOperandAtInstruction(function, fn_mir, operand_instruction) orelse return null;
        if (kind == .phys) {
            const source_size = self.comptimeSizeOf(operand_fact.target_ty, 0) orelse return null;
            const target_size = self.comptimeSizeOf(target_fact.target_ty, 0) orelse return null;
            if (source_size <= 0 or source_size != target_size) return null;
            source_fact = operand_fact;
        } else if (!sameSimpleMirValueType(operand_fact.result_ty, source_fact.result_ty) or
            !type_bridge.sameTypeSyntax(self.resolveAliasType(operand_fact.target_ty), self.resolveAliasType(source_fact.target_ty))) return null;
        return .{ .kind = kind, .source_fact = source_fact, .target_fact = target_fact, .operand = operand };
    }

    fn simpleMirTypedLeafOperandAtInstruction(self: *CEmitter, function: anytype, fn_mir: mir.Function, instruction: mir.Instruction) ?SimpleMirCallArg {
        const operand = self.simpleMirCallArgAt(function, fn_mir, instructionSourcePoint(instruction)) orelse return null;
        return switch (operand) {
            .param => |name| if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, name)) operand else null,
            .integer_literal => |literal| if (instruction.kind == .integer_literal_conversion and std.mem.eql(u8, instruction.detail, literal)) operand else null,
            else => null,
        };
    }

    fn simpleMirUniqueTypedUnaryOperandFactAt(fn_mir: mir.Function, call_source: mir.SourcePoint) ?mir.TargetTypeFact {
        var result: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .typed_unary_operand or !mirSourceContains(call_source, fact.source)) continue;
            if (result != null) return null;
            result = fact;
        }
        return result;
    }

    fn simpleMirUniqueTypedCallOperandFactAt(fn_mir: mir.Function, call_source: mir.SourcePoint, kind: mir.CallTargetKind, operand_index: usize) ?mir.TargetTypeFact {
        var result: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .typed_call_operand or fact.target_index != operand_index or !mirSourceContains(call_source, fact.source)) continue;
            const owner = fact.target_owner orelse continue;
            if (!std.mem.eql(u8, owner, @tagName(kind))) continue;
            if (result != null) return null;
            result = fact;
        }
        return result;
    }

    fn simpleMirTypedLeafOperandInstruction(block: mir.Block, source: mir.SourcePoint) ?mir.Instruction {
        var expr: ?mir.Instruction = null;
        var integer: ?mir.Instruction = null;
        for (block.instructions) |instruction| {
            if (!sameMirSourcePoint(instructionSourcePoint(instruction), source)) continue;
            switch (instruction.kind) {
                .expr => if (expr == null) {
                    expr = instruction;
                } else return null,
                .integer_literal_conversion => if (integer == null) {
                    integer = instruction;
                } else return null,
                else => {},
            }
        }
        return integer orelse expr;
    }

    fn mirSourceContains(outer: mir.SourcePoint, inner: mir.SourcePoint) bool {
        if (outer.len == 0 or inner.len == 0) return false;
        const outer_end = std.math.add(usize, outer.offset, outer.len) catch return false;
        const inner_end = std.math.add(usize, inner.offset, inner.len) catch return false;
        return outer.offset <= inner.offset and inner_end <= outer_end;
    }

    fn simpleMirTypedUnaryCallTargetFactAt(fn_mir: mir.Function, source: mir.SourcePoint) ?mir.CallTargetFact {
        var result: ?mir.CallTargetFact = null;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source)) continue;
            switch (fact.kind) {
                .conversion_from, .conversion_wrap_from, .conversion_from_mod, .bitcast, .enum_raw, .phys => {},
                else => continue,
            }
            if (result != null) return null;
            result = fact;
        }
        return result;
    }

    fn simpleMirUniqueTargetTypeFactKindAt(fn_mir: mir.Function, kind: mir.TargetTypeKind, source: mir.SourcePoint) ?mir.TargetTypeFact {
        var result: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != kind or !sameMirSourcePoint(fact.source, source)) continue;
            if (result != null) return null;
            result = fact;
        }
        return result;
    }

    fn sameSimpleMirValueType(left: mir.ValueType, right: mir.ValueType) bool {
        return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
    }

    fn simpleMirExplicitCastReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function) ?SimpleMirExplicitCastReturn {
        const cast_source = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "cast")) break :blk instructionSourcePoint(instruction);
                }
            }
            return null;
        };
        return self.simpleMirExplicitCastAtSource(function, fn_mir, cast_source);
    }

    fn simpleMirExplicitCastAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, cast_source: mir.SourcePoint) ?SimpleMirExplicitCastReturn {
        const block = blk: {
            for (fn_mir.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "cast") and sameMirSourceLocation(instructionSourcePoint(instruction), cast_source)) break :blk block;
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

    fn simpleMirConversionCallTargetKindAt(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
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

    fn simpleMirCallArgAt(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCallArg {
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirLocalCallArgAt(function, fn_mir, source)) |arg| return arg;
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, source)) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, source)) |field| return .{ .param_field = field };
        if (self.simpleMirGlobalAddressAtValueSource(fn_mir, source)) |name| return .{ .global_address = name };
        if (self.simpleMirGlobalAtSource(function, fn_mir, source)) |name| return .{ .global_load = name };
        if (self.simpleMirNestedCallAtSource(function, fn_mir, source)) |call| {
            if (self.simpleMirNestedCallReturnsValue(call)) return .{ .direct_call = call };
        }
        return switch (self.simpleMirArgAt(function, fn_mir, source) orelse return null) {
            .param => |name| .{ .param = name },
            .param_field => |field| .{ .param_field = field },
            .integer_literal => |literal| .{ .integer_literal = literal },
            .float_literal => |literal| .{ .float_literal = literal },
            .bool_literal => |value| .{ .bool_literal = value },
            .enum_literal => |literal| .{ .enum_literal = literal },
        };
    }

    fn simpleMirCallArgHasDirectCall(arg: SimpleMirCallArg) bool {
        return switch (arg) {
            .direct_call => true,
            else => false,
        };
    }

    fn simpleMirNestedCallReturnsValue(self: *CEmitter, call: SimpleMirNestedCall) bool {
        const fn_info = self.functions.get(call.callee) orelse return false;
        const return_ty = fn_info.return_type orelse return false;
        return !isVoidType(return_ty);
    }

    fn simpleMirNestedCallReturnsBool(self: *CEmitter, call: SimpleMirNestedCall) bool {
        const fn_info = self.functions.get(call.callee) orelse return false;
        const return_ty = fn_info.return_type orelse return false;
        return isBoolType(return_ty);
    }

    fn simpleMirNestedCallAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, call_source: mir.SourcePoint) ?SimpleMirNestedCall {
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
            seen_args[arg_index] = true;
            arg_count = @max(arg_count, arg_index + 1);
        }
        const fn_info = self.functions.get(callee) orelse return null;
        if (!fn_info.acceptsArgCount(arg_count)) return null;
        for (seen_args[0..arg_count]) |seen| if (!seen) return null;
        call.arg_count = arg_count;
        return call;
    }

    fn simpleMirLocalCallArgAt(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirCallArg {
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

    fn simpleMirPrefixVoidCallsBeforeReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, allow_trap_blocks: bool) ?SimpleMirDirectCalls {
        if (fn_mir.blocks.len == 0) return null;
        if (!allow_trap_blocks and fn_mir.blocks.len != 1) return null;
        var calls: SimpleMirDirectCalls = .{};
        const block = fn_mir.blocks[0];
        const ret = simpleMirReturnInstruction(block) orelse return null;
        const return_value_id = ret.value_id;
        var saw_return_value_call = false;
        // Callee of the call that directly produces the return value (the `g` in
        // `return g(f())`), captured when we walk past it below. Only a nested
        // call that is *this* callee's own argument may be skipped as inlined.
        var return_call_callee: ?[]const u8 = null;
        const folds_local = simpleMirEntryBlockFoldsLocal(fn_mir);
        for (block.instructions) |instruction| {
            if (instruction.kind == .return_value) return calls;
            if (instruction.kind != .call) continue;
            const source = instructionSourcePoint(instruction);
            if (!simpleMirDirectCallResultVoid(fn_mir, source)) {
                if (return_value_id) |value_id| {
                    if (self.simpleMirCallFeedsReturnValue(fn_mir, block, source, value_id)) {
                        saw_return_value_call = true;
                        return_call_callee = instruction.detail;
                        continue;
                    }
                }
                // A non-void call at an argument slot of the return call (`f` in
                // `return g(f())`) is inlined into that argument, not a prefix
                // statement — skip it. Gated to the return call's own callee and
                // to functions with no folded local, so it cannot admit
                // ordering-sensitive or reassigned-local shapes.
                if (!folds_local) {
                    if (return_call_callee) |callee| {
                        if (self.simpleMirDirectCallArgumentFactAt(fn_mir, callee, source) != null) continue;
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

    fn simpleMirPrefixVoidCallsBeforeSwitch(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirDirectCalls {
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

    fn simpleMirCallFeedsSwitchCondition(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint) bool {
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

    fn simpleMirCallFeedsReturnValue(self: *CEmitter, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint, value_id: []const u8) bool {
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
        if (std.mem.eql(u8, value_id, "add") or std.mem.eql(u8, value_id, "sub") or std.mem.eql(u8, value_id, "mul")) {
            for (fn_mir.call_target_facts) |fact| {
                if ((fact.kind != .wrapping_add and mir.uncheckedCallFactInfo(fact.kind) == null) or !sameMirSourceLocation(fact.source, source)) continue;
                if (fact.kind == .wrapping_add and !std.mem.eql(u8, value_id, "add")) continue;
                if (mir.uncheckedCallFactInfo(fact.kind)) |op| {
                    if (!std.mem.eql(u8, value_id, op)) continue;
                }
                for (block.instructions) |instruction| {
                    if (instruction.kind == .expr and
                        std.mem.eql(u8, instruction.detail, value_id) and
                        sameMirSourceLocation(instructionSourcePoint(instruction), source))
                    {
                        return true;
                    }
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

    fn simpleMirDirectVoidCallsInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, allow_empty: bool) ?SimpleMirDirectCalls {
        var calls: SimpleMirDirectCalls = .{};
        for (block.instructions) |instruction| {
            switch (instruction.kind) {
                .param, .local, .target_type, .integer_literal_conversion, .add_overflow, .contract_begin, .contract_end, .unchecked_assume, .call_target, .typed_load, .representation_check, .representation_use => {},
                .assign => if (!mirFunctionHasLocal(fn_mir, instruction.detail)) return null,
                .binary => {
                    if (std.mem.eql(u8, instruction.detail, "switch_subject")) continue;
                    const source = instructionSourcePoint(instruction);
                    if (self.simpleMirPlainFloatBinaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
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
                        std.mem.eql(u8, instruction.detail, "char") or
                        std.mem.eql(u8, instruction.detail, "float") or
                        std.mem.eql(u8, instruction.detail, "literal")) continue;
                    if ((std.mem.eql(u8, instruction.detail, "add") or
                        std.mem.eql(u8, instruction.detail, "sub") or
                        std.mem.eql(u8, instruction.detail, "mul") or
                        std.mem.eql(u8, instruction.detail, "wrapping") or
                        std.mem.eql(u8, instruction.detail, "unchecked")) and
                        simpleMirArithmeticCallAtSource(fn_mir, instructionSourcePoint(instruction))) continue;
                    if (self.globals.contains(instruction.detail)) continue;
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
                    if (simpleMirArithmeticCallAtSource(fn_mir, source)) continue;
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

    fn simpleMirVoidStatementSourcesInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) ?SimpleMirVoidStatementSources {
        var result: SimpleMirVoidStatementSources = .{};
        for (block.instructions) |instruction| {
            switch (instruction.kind) {
                .param, .local, .target_type, .integer_literal_conversion, .add_overflow, .contract_begin, .contract_end, .unchecked_assume, .call_target, .typed_load, .representation_check, .representation_use => {},
                .return_value => {},
                .assign => {
                    if (mirFunctionHasLocal(fn_mir, instruction.detail)) return null;
                    for (function.signature.params) |param| {
                        if (std.mem.eql(u8, instruction.detail, param.name.text)) return null;
                    }
                    if (!self.globals.contains(instruction.detail)) return null;
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
                    if (self.simpleMirPlainFloatBinaryAtSource(function, fn_mir, source) == null and
                        self.simpleMirCheckedBinaryAtSource(function, fn_mir, source) == null and
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
                        std.mem.eql(u8, instruction.detail, "char") or
                        std.mem.eql(u8, instruction.detail, "float") or
                        std.mem.eql(u8, instruction.detail, "literal")) continue;
                    if ((std.mem.eql(u8, instruction.detail, "add") or
                        std.mem.eql(u8, instruction.detail, "sub") or
                        std.mem.eql(u8, instruction.detail, "mul") or
                        std.mem.eql(u8, instruction.detail, "wrapping") or
                        std.mem.eql(u8, instruction.detail, "unchecked")) and
                        simpleMirArithmeticCallAtSource(fn_mir, instructionSourcePoint(instruction))) continue;
                    if (std.mem.eql(u8, instruction.detail, "cast") and simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_source, instructionSourcePoint(instruction)) != null) continue;
                    if (self.simpleMirConversionCallTargetKindAt(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                    if (self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, instructionSourcePoint(instruction)) != null) continue;
                    if (std.mem.eql(u8, instruction.detail, "null") and self.simpleMirNullLiteralAtSource(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                    if (std.mem.eql(u8, instruction.detail, "struct_literal") and simpleMirTargetTypeFactKindAt(fn_mir, .struct_literal, instructionSourcePoint(instruction)) != null) continue;
                    if (self.globals.contains(instruction.detail)) continue;
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
                    if (simpleMirArithmeticCallAtSource(fn_mir, source)) continue;
                    if (self.simpleMirConversionCallTargetKindAt(fn_mir, source) != null) continue;
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

    fn simpleMirVoidStatementSourcesTrapCount(self: *CEmitter, function: anytype, fn_mir: mir.Function, sources: SimpleMirVoidStatementSources) ?usize {
        var count: usize = 0;
        for (sources.sources[0..sources.count]) |source| {
            count += switch (source) {
                .direct_call => |call_source| simpleMirDirectCallTrapCount(self.simpleMirDirectCallAtSource(function, fn_mir, call_source) orelse return null),
                .global_store => |store| simpleMirGlobalStoreValueTrapCount(self.simpleMirGlobalStoreValue(function, fn_mir, store.name, store.value_source) orelse return null),
            };
        }
        return count;
    }

    fn simpleMirCallFeedsLaterDirectCallArg(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, source: mir.SourcePoint) bool {
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

    fn simpleMirLocalInitCallReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, value_id: []const u8) ?SimpleMirLocalInitCallReturn {
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (fn_mir.blocks.len != 1) return null;
        if (fn_mir.pointer_provenance_facts.len != 0) return null;
        const return_source = simpleMirReturnValueSource(block, value_id) orelse return null;
        var local_instruction: ?mir.Instruction = null;
        for (block.instructions) |instruction| {
            if (instruction.kind != .local) continue;
            if (local_instruction != null) return null;
            local_instruction = instruction;
        }
        const local = local_instruction orelse return null;
        const local_name = local.detail;
        const local_value_id = local.typed_value_id orelse return null;
        if (!local_value_id.isValid()) return null;
        if (simpleMirBlockAssignsLocal(block, local_name)) return null;
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        if (sameMirSourceLocation(init_source, return_source)) return null;
        const init_call = self.simpleMirDirectCallAtSource(function, fn_mir, init_source) orelse return null;
        const return_call = self.simpleMirDirectCallAtSourceWithLocalArg(function, fn_mir, return_source, local_name, local_value_id) orelse return null;

        var top_level_call_count: usize = 0;
        for (block.instructions) |instruction| {
            if (instruction.kind != .call) continue;
            const source = instructionSourcePoint(instruction);
            if (sameMirSourceLocation(source, init_source) or sameMirSourceLocation(source, return_source)) {
                top_level_call_count += 1;
                continue;
            }
            if (self.simpleMirDirectCallArgumentFactAt(fn_mir, init_call.callee, source) != null) continue;
            if (self.simpleMirDirectCallArgumentFactAt(fn_mir, return_call.callee, source) != null) continue;
            if (self.simpleMirCallFeedsLaterDirectCallArg(function, fn_mir, block, source)) continue;
            return null;
        }
        if (top_level_call_count != 2) return null;

        const init_result = simpleMirTargetTypeFactKindAt(fn_mir, .direct_call_result, init_source) orelse return null;
        if (fn_mir.trap_edges.len != simpleMirDirectCallTrapCount(init_call) + simpleMirDirectCallTrapCount(return_call)) return null;
        return .{
            .local_name = local_name,
            .local_ty = init_result.target_ty,
            .local_source = instructionSourcePoint(local),
            .init_call = init_call,
            .return_call = return_call,
        };
    }

    fn simpleMirLocalInitReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirReturn {
        if (!mirBlockHasLocal(fn_mir.blocks[0], local_name)) return null;
        const init_source = self.simpleMirLocalInitSource(fn_mir, local_name) orelse return null;
        if (simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) != null) {
            if (self.simpleMirEnumLiteralValueAtSource(fn_mir, init_source)) |literal| return .{ .enum_literal = literal };
            if (self.simpleMirNullLiteralAtSource(fn_mir, init_source)) |literal| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(literal.fact.target_ty))) return null;
                return .{ .null_literal = literal };
            }
            if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, init_source)) |binary| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .checked_binary = binary };
            }
            if (self.simpleMirCompareBinaryAtSource(function, fn_mir, init_source)) |binary| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .compare_binary = binary };
            }
            if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, init_source)) |unary| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .checked_unary = unary };
            }
            if (self.simpleMirLogicalNotAtSource(function, fn_mir, init_source)) |arg| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .logical_not = arg };
            }
            if (self.simpleMirDirectCallAtSource(function, fn_mir, init_source)) |call| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .direct_call_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .direct_call = call };
            }
            if (simpleMirArithmeticCallAtSource(fn_mir, init_source)) {
                if (simpleMirInferredLocalFactAt(fn_mir, local_name, init_source)) |inferred| {
                    const expected_type_name = type_bridge.typeName(self.resolveAliasType(inferred.target_ty)) orelse return null;
                    if (self.simpleMirWrappingBinaryAtSource(function, fn_mir, init_source, expected_type_name)) |binary| return .{ .wrapping_binary = binary };
                    if (self.simpleMirUncheckedBinaryAtSource(function, fn_mir, init_source, expected_type_name, local_name)) |binary| return .{ .wrapping_binary = binary };
                }
            }
            if (self.simpleMirExplicitCastAtSource(function, fn_mir, init_source)) |cast| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(cast.target_fact.target_ty))) return null;
                return .{ .explicit_cast_return = cast };
            }
            if (self.simpleMirConversionAtSource(function, fn_mir, init_source)) |conversion| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(conversion.target_fact.target_ty))) return null;
                return .{ .conversion_return = conversion };
            }
            if (self.simpleMirGlobalAtSource(function, fn_mir, init_source)) |name| {
                const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
                const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
                return .{ .global_load = name };
            }
            if (self.simpleMirLocalInitAddressOfSource(fn_mir, local_name)) |address_source| {
                if (self.simpleMirGlobalAddressAtValueSource(fn_mir, address_source)) |name| return .{ .global_address = name };
            }
            const inferred = simpleMirInferredLocalFactAt(fn_mir, local_name, init_source) orelse return null;
            const result = simpleMirTargetTypeFactKindAt(fn_mir, .expression_result, init_source) orelse return null;
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(inferred.target_ty), self.resolveAliasType(result.target_ty))) return null;
            if (self.simpleMirArgAt(function, fn_mir, init_source)) |arg| {
                return switch (arg) {
                    .param => |name| if (simpleMirPlainExprAtSource(fn_mir, init_source)) .{ .param = name } else null,
                    .param_field => |field| if (simpleMirPlainExprAtSource(fn_mir, init_source)) .{ .param_field = field } else null,
                    .integer_literal => |literal| .{ .integer_literal = literal },
                    .float_literal => |literal| .{ .float_literal = literal },
                    .bool_literal => |value| .{ .bool_literal = value },
                    .enum_literal => |literal| .{ .enum_literal = literal },
                };
            }
            return null;
        }
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, init_source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, init_source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, init_source)) |call| return .{ .direct_call = call };
        if (simpleMirArithmeticCallAtSource(fn_mir, init_source)) {
            if (function.signature.transitionalReturnType()) |return_ty| {
                const expected_type_name = type_bridge.typeName(self.resolveAliasType(return_ty)) orelse return null;
                if (self.simpleMirWrappingBinaryAtSource(function, fn_mir, init_source, expected_type_name)) |binary| return .{ .wrapping_binary = binary };
                if (self.simpleMirUncheckedBinaryAtSource(function, fn_mir, init_source, expected_type_name, local_name)) |binary| return .{ .wrapping_binary = binary };
            }
        }
        if (self.simpleMirExplicitCastAtSource(function, fn_mir, init_source)) |cast| return .{ .explicit_cast_return = cast };
        if (self.simpleMirConversionAtSource(function, fn_mir, init_source)) |conversion| return .{ .conversion_return = conversion };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, init_source)) |literal| return .{ .enum_literal = literal };
        if (self.simpleMirStructLiteralAtSource(function, fn_mir, init_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirStructLiteralTrapCount(literal)) return .{ .struct_literal = literal };
        }
        if (self.simpleMirArrayLiteralAtSource(function, fn_mir, init_source)) |literal| {
            if (fn_mir.trap_edges.len == simpleMirArrayLiteralTrapCount(literal)) return .{ .array_literal = literal };
        }
        if (self.simpleMirLocalInitAddressOfSource(fn_mir, local_name)) |address_source| {
            if (self.simpleMirGlobalAddressAtValueSource(fn_mir, address_source)) |name| return .{ .global_address = name };
        }
        if (!simpleMirNoTrap(fn_mir)) return null;
        if (self.simpleMirNestedCallAtSource(function, fn_mir, init_source)) |call| return .{ .nested_call = call };
        if (self.simpleMirCompareBinaryAtSource(function, fn_mir, init_source)) |binary| return .{ .compare_binary = binary };
        if (self.simpleMirLogicalNotAtSource(function, fn_mir, init_source)) |arg| return .{ .logical_not = arg };
        if (self.simpleMirGlobalAtSource(function, fn_mir, init_source)) |name| return .{ .global_load = name };
        if (self.simpleMirNullLiteralAtSource(fn_mir, init_source)) |literal| return .{ .null_literal = literal };
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, init_source)) |field| return .{ .param_field = field };
        if (self.simpleMirArgAt(function, fn_mir, init_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = name },
                .param_field => |field| .{ .param_field = field },
                .integer_literal => |literal| .{ .integer_literal = literal },
                .float_literal => |literal| .{ .float_literal = literal },
                .bool_literal => |value| .{ .bool_literal = value },
                .enum_literal => |literal| .{ .enum_literal = literal },
            };
        }
        return null;
    }

    fn simpleMirInferredLocalFactAt(fn_mir: mir.Function, local_name: []const u8, source: mir.SourcePoint) ?mir.TargetTypeFact {
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind == .inferred_local and
                std.mem.eql(u8, fact.target_owner orelse "", local_name) and
                sameMirSourceLocation(fact.source, source)) return fact;
        }
        return null;
    }

    fn simpleMirPlainExprAtSource(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        var saw_expr = false;
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                switch (instruction.kind) {
                    .call, .binary, .unary => return false,
                    .expr => saw_expr = true,
                    else => {},
                }
            }
        }
        return saw_expr;
    }

    fn simpleMirAssignmentReturn(self: *CEmitter, function: anytype, fn_mir: mir.Function, local_name: []const u8) ?SimpleMirReturn {
        if (fn_mir.pointer_provenance_facts.len != 0) return null;
        const assigned_source = self.simpleMirAssignmentSource(fn_mir, local_name) orelse return null;
        if (self.simpleMirCheckedBinaryAtSource(function, fn_mir, assigned_source)) |binary| return .{ .checked_binary = binary };
        if (self.simpleMirCheckedUnaryAtSource(function, fn_mir, assigned_source)) |unary| return .{ .checked_unary = unary };
        if (self.simpleMirDirectCallAtSource(function, fn_mir, assigned_source)) |call| return .{ .direct_call = call };
        if (simpleMirArithmeticCallAtSource(fn_mir, assigned_source)) {
            if (function.signature.transitionalReturnType()) |return_ty| {
                const expected_type_name = type_bridge.typeName(self.resolveAliasType(return_ty)) orelse return null;
                if (self.simpleMirWrappingBinaryAtSource(function, fn_mir, assigned_source, expected_type_name)) |binary| return .{ .wrapping_binary = binary };
                if (self.simpleMirUncheckedBinaryAtSource(function, fn_mir, assigned_source, expected_type_name, local_name)) |binary| return .{ .wrapping_binary = binary };
            }
        }
        if (self.simpleMirExplicitCastAtSource(function, fn_mir, assigned_source)) |cast| return .{ .explicit_cast_return = cast };
        if (self.simpleMirConversionAtSource(function, fn_mir, assigned_source)) |conversion| return .{ .conversion_return = conversion };
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
        if (self.simpleMirNullLiteralAtSource(fn_mir, assigned_source)) |literal| return .{ .null_literal = literal };
        if (self.simpleMirParamFieldValueAtSource(function, fn_mir, assigned_source)) |field| return .{ .param_field = field };
        if (self.simpleMirArgAt(function, fn_mir, assigned_source)) |arg| {
            return switch (arg) {
                .param => |name| .{ .param = name },
                .param_field => |field| .{ .param_field = field },
                .integer_literal => |literal| .{ .integer_literal = literal },
                .float_literal => |literal| .{ .float_literal = literal },
                .bool_literal => |value| .{ .bool_literal = value },
                .enum_literal => |literal| .{ .enum_literal = literal },
            };
        }
        return null;
    }

    fn simpleMirAssignmentSource(self: *CEmitter, fn_mir: mir.Function, local_name: []const u8) ?mir.SourcePoint {
        const block = fn_mir.blocks[0];
        return self.simpleMirAssignmentSourceInBlock(block, local_name);
    }

    fn simpleMirAssignmentSourceInBlock(_: *CEmitter, block: mir.Block, local_name: []const u8) ?mir.SourcePoint {
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
                    .target_type, .integer_literal_conversion, .call_target, .typed_load, .representation_check, .representation_use => continue,
                    .expr => {
                        if (std.mem.eql(u8, next.detail, local_name)) continue;
                        source = instructionSourcePoint(next);
                        break;
                    },
                    .binary, .unary, .call, .unchecked_assume => {
                        source = instructionSourcePoint(next);
                        break;
                    },
                    else => return null,
                }
            }
        }
        return source;
    }

    fn simpleMirGlobalAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?[]const u8 {
        const typed_span_id = mir.spanIdAtSource(fn_mir, source) orelse return null;
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr or !mir.instructionMatchesSpanId(fn_mir, instruction, typed_span_id)) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) return null;
                }
                if (mirFunctionHasLocal(fn_mir, instruction.detail)) return null;
                if (self.globals.contains(instruction.detail)) return instruction.detail;
            }
        }
        return null;
    }

    fn simpleMirGlobalAddressAtValueSource(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?[]const u8 {
        const typed_span_id = mir.spanIdAtSource(fn_mir, source) orelse return null;
        var pointer_fact: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .expression_result) continue;
            if (!mir.targetTypeFactMatchesSpanId(fn_mir, fact, typed_span_id)) continue;
            switch (self.resolveAliasType(fact.target_ty).kind) {
                .pointer => {},
                else => return null,
            }
            pointer_fact = fact;
            break;
        }
        const fact = pointer_fact orelse return null;
        const pointer = switch (self.resolveAliasType(fact.target_ty).kind) {
            .pointer => |pointer| pointer,
            else => return null,
        };
        const name = fact.target_owner orelse return null;
        if (!fact.typed_target_owner_id.isValid() or !self.globals.contains(name)) return null;
        const global_info = self.globals.get(name) orelse return null;
        const global_ty = global_info.source_ty orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointer.child.*), self.resolveAliasType(global_ty))) {
            return null;
        }
        return name;
    }

    fn simpleMirLocalInitSource(self: *CEmitter, fn_mir: mir.Function, local_name: []const u8) ?mir.SourcePoint {
        return self.simpleMirLocalInitSourceInBlock(fn_mir.blocks[0], local_name);
    }

    fn simpleMirLocalInitAddressOfSource(self: *CEmitter, fn_mir: mir.Function, local_name: []const u8) ?mir.SourcePoint {
        return self.simpleMirLocalInitAddressOfSourceInBlock(fn_mir.blocks[0], local_name);
    }

    fn simpleMirLocalInitAddressOfSourceInBlock(_: *CEmitter, block: mir.Block, local_name: []const u8) ?mir.SourcePoint {
        var after_local = false;
        for (block.instructions) |instruction| {
            if (!after_local) {
                after_local = instruction.kind == .local and std.mem.eql(u8, instruction.detail, local_name);
                continue;
            }
            switch (instruction.kind) {
                .target_type => continue,
                .representation_check => {
                    if (instruction.value_id) |value_id| {
                        if (std.mem.eql(u8, value_id, "address_of")) return instructionSourcePoint(instruction);
                    }
                    return null;
                },
                .expr, .return_value => return null,
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirLocalInitSourceInBlock(_: *CEmitter, block: mir.Block, local_name: []const u8) ?mir.SourcePoint {
        var after_local = false;
        for (block.instructions) |instruction| {
            if (!after_local) {
                after_local = instruction.kind == .local and std.mem.eql(u8, instruction.detail, local_name);
                continue;
            }
            switch (instruction.kind) {
                .target_type, .representation_check, .representation_use => continue,
                .integer_literal_conversion, .binary, .unary, .call, .unchecked_assume => return instructionSourcePoint(instruction),
                .expr => if (!std.mem.eql(u8, instruction.detail, local_name)) return instructionSourcePoint(instruction),
                .return_value => return null,
                else => return null,
            }
        }
        return null;
    }

    fn simpleMirArgAt(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirArg {
        if (self.simpleMirCharIntegerLiteralAtSource(fn_mir, source)) |literal| return .{ .integer_literal = literal };
        if (self.simpleMirFloatLiteralAtSource(fn_mir, source)) |literal| return .{ .float_literal = literal };
        if (self.simpleMirEnumLiteralValueAtSource(fn_mir, source)) |literal| return .{ .enum_literal = literal };
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

    fn simpleMirFloatLiteralAtSource(_: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirFloatLiteral {
        for (fn_mir.float_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source)) continue;
            const target_type_name = fact.target_ty.name();
            if (!std.mem.eql(u8, target_type_name, "f32") and !std.mem.eql(u8, target_type_name, "f64")) return null;
            return .{ .literal = fact.literal, .target_type_name = target_type_name };
        }
        return null;
    }

    fn simpleMirLocalFloatLiteralValueAtSource(self: *CEmitter, function: anytype, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirFloatLiteral {
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr or !sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                if (!mirFunctionHasLocal(fn_mir, instruction.detail)) continue;
                return self.simpleMirLocalFloatLiteral(function, fn_mir, block, instruction.detail, source);
            }
        }
        return null;
    }

    fn simpleMirLocalFloatLiteral(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8, use_source: mir.SourcePoint) ?SimpleMirFloatLiteral {
        _ = function;
        if (self.simpleMirAssignmentSourceInBlock(block, local_name)) |assigned_source| {
            if (sameMirSourceLocation(assigned_source, use_source)) return null;
            return self.simpleMirFloatLiteralAtSource(fn_mir, assigned_source);
        }
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        if (sameMirSourceLocation(init_source, use_source)) return null;
        return self.simpleMirFloatLiteralAtSource(fn_mir, init_source);
    }

    fn simpleMirCharIntegerLiteralAtSource(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?[]const u8 {
        _ = simpleMirTargetTypeFactKindAt(fn_mir, .char_literal, source) orelse return null;
        for (fn_mir.integer_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source)) continue;
            const value = numeric.parseCharLiteral(fact.literal) orelse return null;
            return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) catch null;
        }
        return null;
    }

    fn simpleMirLocalValueArg(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block, local_name: []const u8, use_source: mir.SourcePoint) ?SimpleMirArg {
        if (self.simpleMirAssignmentSourceInBlock(block, local_name)) |assigned_source| {
            if (sameMirSourceLocation(assigned_source, use_source)) return null;
            return self.simpleMirArgAt(function, fn_mir, assigned_source);
        }
        const init_source = self.simpleMirLocalInitSourceInBlock(block, local_name) orelse return null;
        if (sameMirSourceLocation(init_source, use_source)) return null;
        return self.simpleMirArgAt(function, fn_mir, init_source);
    }

    fn simpleMirEnumLiteralAtSource(self: *CEmitter, fn_mir: mir.Function, case_name: []const u8, source: mir.SourcePoint) ?SimpleMirEnumLiteral {
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .enum_literal, source) orelse return null;
        const enum_name = self.enumNameForType(fact.target_ty) orelse return null;
        const enum_decl = self.enums.get(enum_name) orelse return null;
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, case_name)) return .{ .enum_name = enum_name, .case_name = case_name };
        }
        return null;
    }

    fn simpleMirEnumLiteralValueAtSource(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirEnumLiteral {
        for (fn_mir.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.kind != .expr) continue;
                if (!sameMirSourceLocation(instructionSourcePoint(instruction), source)) continue;
                if (self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, source)) |literal| return literal;
            }
        }
        return null;
    }

    fn simpleMirNullLiteralAtSource(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?SimpleMirNullLiteral {
        const fact = simpleMirTargetTypeFactKindAt(fn_mir, .null_literal, source) orelse return null;
        _ = self;
        return .{ .fact = fact };
    }

    fn blockOnlyContainsSimpleMirReturnInstructions(self: *CEmitter, function: anytype, fn_mir: mir.Function) bool {
        return self.blockOnlyContainsSimpleMirReturnInstructionsInBlock(function, fn_mir, fn_mir.blocks[0]);
    }

    fn blockOnlyContainsSimpleMirReturnInstructionsInBlock(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
        for (block.instructions) |instruction| switch (instruction.kind) {
            .param, .local, .assign, .target_type, .integer_literal_conversion, .representation_check, .representation_use, .typed_load, .binary, .unary, .add_overflow, .contract_begin, .unchecked_assume, .return_value => {},
            .call, .call_target => {},
            .expr => {
                if (std.mem.eql(u8, instruction.detail, "int") or std.mem.eql(u8, instruction.detail, "char") or std.mem.eql(u8, instruction.detail, "bool") or std.mem.eql(u8, instruction.detail, "float") or std.mem.eql(u8, instruction.detail, "struct_literal") or std.mem.eql(u8, instruction.detail, "array_literal")) continue;
                if ((std.mem.eql(u8, instruction.detail, "add") or std.mem.eql(u8, instruction.detail, "sub") or std.mem.eql(u8, instruction.detail, "mul") or std.mem.eql(u8, instruction.detail, "wrapping") or std.mem.eql(u8, instruction.detail, "unchecked")) and simpleMirArithmeticCallAtSource(fn_mir, instructionSourcePoint(instruction))) continue;
                if (self.simpleMirEnumLiteralAtSource(fn_mir, instruction.detail, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "null") and self.simpleMirNullLiteralAtSource(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (self.simpleMirConversionCallTargetKindAt(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (simpleMirDomainCallTargetKindAt(fn_mir, instructionSourcePoint(instruction)) != null) continue;
                if (std.mem.eql(u8, instruction.detail, "cast") and simpleMirTargetTypeFactKindAt(fn_mir, .explicit_cast_source, instructionSourcePoint(instruction)) != null) continue;
                for (function.signature.params) |param| {
                    if (std.mem.eql(u8, instruction.detail, param.name.text)) break;
                } else {
                    if (mirBlockHasLocal(block, instruction.detail)) continue;
                    if (mirBlockHasCall(block, instruction.detail)) continue;
                    if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.simpleMirExprCouldBePointerParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
                    if (self.globals.contains(instruction.detail)) continue;
                    return false;
                }
            },
            else => return false,
        };
        return true;
    }

    fn simpleMirCallSource(self: *CEmitter, fn_mir: mir.Function) ?mir.SourcePoint {
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
                    std.mem.eql(u8, instruction.detail, "char") or
                    std.mem.eql(u8, instruction.detail, "float") or
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

    fn simpleMirEntrySwitchBlockIsPure(self: *CEmitter, function: anytype, block: mir.Block) bool {
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

    fn simpleMirEntrySwitchBlockIsPureWithPrefixVoidCalls(self: *CEmitter, function: anytype, fn_mir: mir.Function, block: mir.Block) bool {
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
                if (self.simpleMirExprCouldBeParamField(function, block, instruction.detail, instructionSourcePoint(instruction))) continue;
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

    fn simpleMirResultConstructorKindAtSource(fn_mir: mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
        var found: ?mir.CallTargetKind = null;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source)) continue;
            switch (fact.kind) {
                .result_ok, .result_err => {
                    if (found != null) return null;
                    found = fact.kind;
                },
                else => {},
            }
        }
        return found;
    }

    fn simpleMirArithmeticCallAtSource(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.call_target_facts) |fact| {
            if ((fact.kind == .wrapping_add or mir.uncheckedCallFactInfo(fact.kind) != null) and sameMirSourceLocation(fact.source, source)) return true;
        }
        return false;
    }

    fn simpleMirNoOverflowRangeFactAt(fn_mir: mir.Function, target: []const u8, op: []const u8, source: mir.SourcePoint) ?mir.RangeFact {
        var found: ?mir.RangeFact = null;
        for (fn_mir.range_facts) |fact| {
            if (!std.mem.eql(u8, fact.target, target)) continue;
            if (!std.mem.eql(u8, fact.op, op)) continue;
            if (fact.line != source.line or fact.column != source.column) continue;
            if (found != null) return null;
            found = fact;
        }
        return found;
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

    fn simpleMirCompareOpSupported(op: []const u8) bool {
        return std.mem.eql(u8, op, "eq") or std.mem.eql(u8, op, "ne") or std.mem.eql(u8, op, "lt") or std.mem.eql(u8, op, "le") or std.mem.eql(u8, op, "gt") or std.mem.eql(u8, op, "ge");
    }

    fn simpleMirFloatBinaryOpSupported(op: []const u8) bool {
        return std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "mul") or std.mem.eql(u8, op, "div");
    }

    fn simpleMirCFloatBinaryOp(op: []const u8) ![]const u8 {
        if (std.mem.eql(u8, op, "add")) return "+";
        if (std.mem.eql(u8, op, "sub")) return "-";
        if (std.mem.eql(u8, op, "mul")) return "*";
        if (std.mem.eql(u8, op, "div")) return "/";
        if (std.mem.eql(u8, op, "bit_and")) return "&";
        if (std.mem.eql(u8, op, "bit_or")) return "|";
        if (std.mem.eql(u8, op, "bit_xor")) return "^";
        return error.UnsupportedCEmission;
    }

    // Plain (non-trapping) unsigned integer binary ops that render as `(a op b)`
    // for a u32/u64 result: arithmetic add/sub/mul (wrapping) and bitwise
    // and/or/xor. Division/shift/etc. are excluded (they trap or promote).
    fn simpleMirPlainUnsignedBinaryOp(op: []const u8) bool {
        return std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "mul") or
            std.mem.eql(u8, op, "bit_and") or std.mem.eql(u8, op, "bit_or") or std.mem.eql(u8, op, "bit_xor");
    }

    fn simpleMirCCompareOp(op: []const u8) ![]const u8 {
        if (std.mem.eql(u8, op, "eq")) return "==";
        if (std.mem.eql(u8, op, "ne")) return "!=";
        if (std.mem.eql(u8, op, "lt")) return "<";
        if (std.mem.eql(u8, op, "le")) return "<=";
        if (std.mem.eql(u8, op, "gt")) return ">";
        if (std.mem.eql(u8, op, "ge")) return ">=";
        return error.UnsupportedCEmission;
    }

    fn mirHasIntegerOverflowTrapAt(fn_mir: mir.Function, source: mir.SourcePoint) bool {
        for (fn_mir.trap_edges) |edge| {
            if (edge.kind == .IntegerOverflow and edge.source == .checked_arithmetic and edge.line == source.line and edge.column == source.column) return true;
        }
        return false;
    }

    fn simpleMirRepresentationTrapCountAt(fn_mir: mir.Function, source: mir.SourcePoint) usize {
        var count: usize = 0;
        for (fn_mir.trap_edges) |edge| {
            if (edge.kind == .InvalidRepresentation and edge.source == .representation_check and edge.line == source.line and edge.column == source.column) {
                count += 1;
            }
        }
        return count;
    }

    fn simpleMirOperandTargetTypeFactAt(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.TargetTypeFact {
        _ = self;
        var bool_fact: ?mir.TargetTypeFact = null;
        for (fn_mir.target_type_facts) |fact| {
            if (fact.kind != .expression_result or !sameMirSourceLocation(fact.source, source)) continue;
            if (fact.result_ty != .bool) return fact;
            bool_fact = bool_fact orelse fact;
        }
        return bool_fact;
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

    fn mirHasCheckedBinaryTrapsAt(fn_mir: mir.Function, source: mir.SourcePoint, op: []const u8, type_name: []const u8) bool {
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

    fn checkedHelperName(self: *CEmitter, op: []const u8, type_name: []const u8) ![]const u8 {
        const suffix = lower_c_type.checkedTypeSuffix(type_name) orelse return error.UnsupportedCEmission;
        const prefix: []const u8 = if (std.mem.eql(u8, op, "add"))
            "mc_checked_add_"
        else if (std.mem.eql(u8, op, "sub"))
            "mc_checked_sub_"
        else if (std.mem.eql(u8, op, "mul"))
            "mc_checked_mul_"
        else if (std.mem.eql(u8, op, "div"))
            "mc_checked_div_"
        else if (std.mem.eql(u8, op, "mod"))
            "mc_checked_mod_"
        else if (std.mem.eql(u8, op, "shl"))
            "mc_checked_shl_"
        else if (std.mem.eql(u8, op, "shr"))
            "mc_checked_shr_"
        else
            return error.UnsupportedCEmission;
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}{s}", .{ prefix, suffix });
    }

    fn checkedUnaryHelperName(self: *CEmitter, op: []const u8, type_name: []const u8) ![]const u8 {
        const suffix = lower_c_type.checkedTypeSuffix(type_name) orelse return error.UnsupportedCEmission;
        if (!simpleMirSignedIntegerTypeName(type_name)) return error.UnsupportedCEmission;
        const prefix: []const u8 = if (std.mem.eql(u8, op, "neg"))
            "mc_checked_neg_"
        else
            return error.UnsupportedCEmission;
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}{s}", .{ prefix, suffix });
    }

    fn simpleMirSignedIntegerTypeName(type_name: []const u8) bool {
        return std.mem.eql(u8, type_name, "i8") or
            std.mem.eql(u8, type_name, "i16") or
            std.mem.eql(u8, type_name, "i32") or
            std.mem.eql(u8, type_name, "i64") or
            std.mem.eql(u8, type_name, "i128") or
            std.mem.eql(u8, type_name, "isize");
    }

    fn simpleMirTargetTypeFactAt(self: *CEmitter, fn_mir: mir.Function, source: mir.SourcePoint) ?mir.TargetTypeFact {
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
            if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, value_id)) {
                source = instructionSourcePoint(instruction);
                continue;
            }
            if (instruction.value_id) |instruction_value| {
                if (std.mem.eql(u8, instruction_value, value_id)) source = instructionSourcePoint(instruction);
            }
        }
        return source;
    }

    fn simpleMirReturnedCallSource(block: mir.Block, value_id: []const u8) ?mir.SourcePoint {
        var source: ?mir.SourcePoint = null;
        for (block.instructions) |instruction| {
            if (instruction.kind != .call) continue;
            if (!std.mem.eql(u8, instruction.value_id orelse continue, value_id)) continue;
            if (source != null) return null;
            source = instructionSourcePoint(instruction);
        }
        return source;
    }

    fn simpleMirDomainCallTargetKindAt(fn_mir: mir.Function, source: mir.SourcePoint) ?mir.CallTargetKind {
        var kind: ?mir.CallTargetKind = null;
        for (fn_mir.call_target_facts) |fact| {
            if (!sameMirSourceLocation(fact.source, source) or mir.domainCallFactInfo(fact.kind) == null) continue;
            if (kind != null) return null;
            kind = fact.kind;
        }
        return kind;
    }

    fn plainFunctionRenderAttrs(render: anytype) bool {
        return !render.naked and !render.weak and !render.noinline_attr and render.section == null and render.effective_align == null;
    }

    fn simpleMirReturnSpan(self: *CEmitter, fn_mir: mir.Function) ?diagnostics.Span {
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
        return .{ .line = source.line, .column = @intCast(source.column), .offset = source.offset, .len = source.len };
    }

    fn emitIndentedFunctionBlock(self: *CEmitter, body: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        self.indent += 1;
        defer self.indent -= 1;
        try self.emitBlockItems(body, locals, return_ty);
    }

    // The single asm block of a `#[naked]` function, emitted as *basic* asm (no
    // operands or clobber list — those are ill-formed inside a naked function). The
    // template strings carry the hand-written machine code that does the ABI-correct
    // jump/return itself.
    fn emitNakedAsmBody(self: *CEmitter, body: ast_bridge.Block) !void {
        const asm_stmt = syntax_bridge.nakedAsmStmt(body) orelse return error.UnsupportedCEmission;
        self.indent += 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "__asm__(");
        try self.emitAsmTemplate(asm_stmt.templates);
        try self.out.appendSlice(self.allocator, ");\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#else\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#error \"#[naked] requires GCC/Clang inline-asm support\"\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#endif\n");
        self.indent -= 1;
    }

    fn emitFunctionSignature(self: *CEmitter, sig: codegen_attrs.FunctionSignatureFacts, is_static: bool, with_asm_label: bool) !void {
        try lower_c_defs.emitFunctionSignature(self.defsContext(), sig, is_static, with_asm_label);
    }

    fn emitFunctionRenderAttrs(self: *CEmitter, attrs: codegen_attrs.FunctionRenderAttrs) !void {
        try codegen_attrs.emitCFunctionRenderAttrs(self.allocator, self.out, attrs);
    }

    fn emitParamDecl(self: *CEmitter, ty: ast_bridge.TypeExpr, name: []const u8) !void {
        try lower_c_defs.emitParamDecl(self.defsContext(), ty, name);
    }

    fn emitDeclarator(self: *CEmitter, ty: ast_bridge.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .typedef_name);
    }

    fn emitIgnoredLocalPrefix(self: *CEmitter, name: []const u8) !void {
        if (name.len > 0 and name[0] == '_') {
            try self.out.appendSlice(self.allocator, "MC_UNUSED ");
        }
    }

    fn emitStructFieldDeclarator(self: *CEmitter, ty: ast_bridge.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .struct_tag);
    }

    fn emitDeclaratorWithStyle(self: *CEmitter, ty: ast_bridge.TypeExpr, name: []const u8, style: StructTypeStyle) !void {
        try self.out.print(self.allocator, "{s} {s}", .{ try self.cTypeFor(ty, style), try self.cIdent(name) });
    }

    // Maps an MC value identifier to a safe C identifier. Identity for ordinary
    // names (so generated C is stable) and for the emitter's own `mc_`-prefixed
    // temporaries; C/header-reserved words are rewritten (e.g. `int` -> `int_`).
    // The mapping is deterministic, so declarations and uses stay consistent.
    fn cIdent(self: *CEmitter, name: []const u8) ![]const u8 {
        if (isCReservedWord(name)) return std.fmt.allocPrint(self.scratch.allocator(), "{s}_", .{name});
        return name;
    }

    fn cTypeFor(self: *CEmitter, ty: ast_bridge.TypeExpr, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendType(&out, ty, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn emitVaStartLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr) !bool {
        return lower_c_call.emitVaStartLocalInit(self.callLocalInitContext(), name, decl_ty, initializer);
    }

    fn emitVaListCopyLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr) !bool {
        return lower_c_call.emitVaListCopyLocalInit(self.callLocalInitContext(), name, decl_ty, initializer);
    }

    fn appendType(self: *CEmitter, out: *std.ArrayList(u8), ty: ast_bridge.TypeExpr, style: StructTypeStyle) anyerror!void {
        try lower_c_type.appendType(self.typeEmitContext(), out, ty, style);
    }

    fn resolveAliasType(self: *CEmitter, ty: ast_bridge.TypeExpr) ast_bridge.TypeExpr {
        return type_bridge.resolveAliasType(&self.type_aliases, ty);
    }

    fn aliasTargetType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return type_bridge.aliasTargetType(&self.type_aliases, ty);
    }

    fn typeNameContext(self: *CEmitter) lower_c_names.Context {
        return .{
            .allocator = self.scratch.allocator(),
            .type_aliases = &self.type_aliases,
            .structs = &self.structs,
            .len_ctx = self,
            .array_len_text = arrayLenTextForNames,
        };
    }

    fn typeEmitContext(self: *CEmitter) lower_c_type.TypeEmitContext {
        return .{
            .scratch = self.scratch.allocator(),
            .type_aliases = &self.type_aliases,
            .enums = &self.enums,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .structs = &self.structs,
            .mmio_structs = &self.mmio_structs,
            .fn_ptr_types = &self.fn_ptr_types,
            .closure_types = &self.closure_types,
            .emit_ctx = self,
            .slice_type_name = sliceTypeNameForType,
            .array_type_name = arrayTypeNameForType,
            .result_type_name = resultTypeNameForConvert,
            .fn_ptr_type_name = fnPtrTypeNameForType,
            .closure_type_name = closureTypeNameForType,
            .dyn_type_name = dynTypeNameForType,
            .opt_type_name = optTypeNameForType,
        };
    }

    fn globalEmitContext(self: *CEmitter) lower_c_global.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .static_initializers = &self.static_initializers,
            .functions = &self.functions,
            .emit_ctx = self,
            .write_line_directive = writeLineDirectiveForGlobal,
            .emit_declarator = emitDeclaratorForGlobal,
            .const_global_c_value = constGlobalCValueForGlobal,
            .emit_expr = emitExprForGlobal,
            .emit_expr_with_target = emitExprWithTargetForGlobal,
            .emit_expr_with_target_for_owner = emitExprWithTargetForGlobalOwner,
            .emit_const_global_initializer = emitConstGlobalInitializerForGlobal,
            .is_aggregate_global_type = isAggregateGlobalTypeForGlobal,
        };
    }

    fn globalArrayAccessEmitContext(self: *CEmitter) lower_c_global.ArrayAccessEmitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
        };
    }

    fn globalAccessContext(self: *CEmitter) lower_c_global.AccessContext {
        return .{
            .scratch = self.scratch.allocator(),
            .globals = &self.globals,
            .structs = &self.structs,
            .emit_ctx = self,
            .global_info_from_type = globalInfoFromTypeForGlobal,
        };
    }

    fn globalInfoFromTypeForGlobal(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!GlobalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalInfoFromType(ty);
    }

    fn overlayEmitContext(self: *CEmitter) lower_c_overlay.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .temp_index = &self.temp_index,
            .overlay_unions = &self.overlay_unions,
            .emit_ctx = self,
            .write_indent = writeIndentForOverlay,
            .c_type = cTypeForOverlay,
            .emit_expr = emitExprForOverlay,
            .emit_expr_with_target = emitExprWithTargetForOverlay,
            .overlay_field_layout_size = overlayFieldLayoutSizeForOverlay,
        };
    }

    fn asmEmitContext(self: *CEmitter) lower_c_asm.EmitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .stub_asm = self.stub_asm,
            .emit_ctx = self,
            .write_indent = writeIndentForAsm,
            .c_ident = cIdentForAsm,
            .emit_expr_with_target = emitExprWithTargetForAsm,
        };
    }

    fn layoutAssertContext(self: *CEmitter) lower_c_layout.AssertContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .structs = &self.structs,
            .reflect_env = self.reflectEnv(),
        };
    }

    fn arrayLenTextForNames(ctx: *anyopaque, expr: ast_bridge.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }

    fn writeLineDirectiveForGlobal(ctx: *anyopaque, span: ast_bridge.Span) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.writeLineDirective(span);
    }

    fn emitDeclaratorForGlobal(ctx: *anyopaque, ty: ast_bridge.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitDeclarator(ty, name);
    }

    fn constGlobalCValueForGlobal(ctx: *anyopaque, expr: ast_bridge.Expr, ty: ?ast_bridge.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.constGlobalCValue(expr, ty);
    }

    fn emitExprForGlobal(ctx: *anyopaque, expr: ast_bridge.Expr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, null);
    }

    fn emitExprWithTargetForGlobal(ctx: *anyopaque, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, null, target_ty);
    }

    fn emitExprWithTargetForGlobalOwner(ctx: *anyopaque, owner: ?[]const u8, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const previous_function = self.current_function;
        if (owner) |name| self.current_function = name;
        defer self.current_function = previous_function;
        try self.emitExprWithTarget(expr, null, target_ty);
    }

    fn emitConstGlobalInitializerForGlobal(ctx: *anyopaque, ty: ast_bridge.TypeExpr, expr: ast_bridge.Expr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitConstGlobalInitializer(ty, expr);
    }

    fn isAggregateGlobalTypeForGlobal(ctx: *anyopaque, ty: ast_bridge.TypeExpr) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.isAggregateGlobalType(ty);
    }

    fn writeIndentForOverlay(ctx: *anyopaque) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.writeIndent();
    }

    fn cTypeForOverlay(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitExprForOverlay(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, locals);
    }

    fn emitExprWithTargetForOverlay(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn overlayFieldLayoutSizeForOverlay(ctx: *anyopaque, ty: ast_bridge.TypeExpr) usize {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.overlayFieldLayoutSize(ty);
    }

    fn writeIndentForAsm(ctx: *anyopaque) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.writeIndent();
    }

    fn cIdentForAsm(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn cIdentForMmio(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn emitExprWithTargetForAsm(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn defsContext(self: *CEmitter) lower_c_defs.Context {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .backend_names = &self.backend_names,
            .emit_ctx = self,
            .c_type = cTypeForDefs,
            .c_ident = cIdentForDefs,
            .declarator = declaratorForDefs,
            .field_declarator = fieldDeclaratorForDefs,
            .enum_case_value = enumCaseValueForDefs,
            .result_payload_c_type = resultPayloadCTypeForDefs,
        };
    }

    fn dispatchContext(self: *CEmitter) lower_c_dispatch.Context {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .temp_index = &self.temp_index,
            .emit_ctx = self,
            .c_type = cTypeForDefs,
            .dyn_type_name = dynTypeNameForType,
            .emit_expr = emitExprForCall,
            .is_void_type = isVoidTypeForDispatch,
            .require_dyn_dispatch_argument = requireDynDispatchArgumentForDispatch,
            .require_dyn_dispatch_result = requireDynDispatchResultForDispatch,
        };
    }

    fn mmioContext(self: *CEmitter) lower_c_mmio.Context {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .indent = &self.indent,
        };
    }

    fn mmioEmitContext(self: *CEmitter) lower_c_mmio.EmitContext {
        return .{
            .context = self.mmioContext(),
            .scratch = self.scratch.allocator(),
            .temp_index = &self.temp_index,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .c_type = cTypeForCall,
            .c_ident = cIdentForMmio,
            .mmio_access = mmioAccessForMmio,
            .value_c_type = valueCTypeForMmio,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
            .mir_owned_target_type = mirOwnedTargetTypeForLowering,
        };
    }

    fn mmioStructEmitContext(self: *CEmitter) lower_c_mmio.StructEmitContext {
        return .{
            .context = self.mmioContext(),
            .emit_ctx = self,
            .c_ident = cIdentForMmio,
        };
    }

    fn mmioAccessContext(self: *CEmitter) lower_c_mmio.AccessContext {
        return .{
            .packed_bits = &self.packed_bits,
            .emit_ctx = self,
            .c_ident = cIdentForMmio,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn mmioReplacementEmitContext(self: *CEmitter) lower_c_mmio.ReplacementEmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .temp_index = &self.temp_index,
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .packed_bits = &self.packed_bits,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .c_type = cTypeForCall,
            .emit_declarator = emitDeclaratorForCall,
            .operand_emit_type = operandEmitTypeForMmio,
            .global_assignment_target = globalAssignmentTargetForMmio,
            .emit_assign_target = emitAssignTargetForMmio,
            .emit_read_sequenced_binary_value_temp = emitMmioReadSequencedBinaryValueTempForMmio,
        };
    }

    fn mmioCallEmitContext(self: *CEmitter) lower_c_mmio.CallEmitContext {
        return .{
            .emit = self.mmioEmitContext(),
            .replacement = self.mmioReplacementEmitContext(),
            .call_ctx = self.sequencedArgContext(),
            .arith = self.arithContext(),
        };
    }

    fn mmioWhileEmitContext(self: *CEmitter) lower_c_mmio.WhileEmitContext {
        return .{
            .emit = self.mmioEmitContext(),
            .replacement = self.mmioReplacementEmitContext(),
            .emit_ctx = self,
            .emit_block_items = emitBlockItemsForMmio,
        };
    }

    fn callContext(self: *CEmitter) lower_c_call.Context {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .c_type = cTypeForCall,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn callLocalInitContext(self: *CEmitter) lower_c_call.LocalInitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .indent = &self.indent,
            .current_variadic_last = self.current_variadic_last,
            .emit_ctx = self,
            .emit_declarator = emitDeclaratorForCall,
            .c_ident = cIdentForCall,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn sequencedArgContext(self: *CEmitter) lower_c_call.TempContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_arg_temp = emitSequencedArgTempForCall,
            .c_type = cTypeForCall,
            .c_ident = cIdentForCall,
            .local_info_from_type = localInfoFromTypeForArith,
            .global_assignment_target = globalAssignmentTargetForArith,
            .emit_assign_target = emitAssignTargetForArith,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
            .mir_owned_target_type = mirOwnedTargetTypeForLowering,
        };
    }

    fn specialSequencedArgContext(self: *CEmitter) lower_c_call.SpecialTempContext {
        return .{
            .emit_ctx = self,
            .address = emitAddressSequencedArgTempForCall,
            .index = emitIndexSequencedArgTempForCall,
            .binary = emitBinarySequencedArgTempForCall,
            .deref = emitDerefSequencedArgTempForCall,
            .aggregate = emitAggregateSequencedArgTempForCall,
            .cast = emitCastSequencedArgTempForCall,
            .call = emitCallSequencedArgTempForCall,
        };
    }

    fn atomicEmitContext(self: *CEmitter) lower_c_atomic.EmitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .expr_is_pointer = exprIsPointerForAtomic,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn convertContext(self: *CEmitter) lower_c_convert.Context {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .temp_index = &self.temp_index,
            .type_aliases = &self.type_aliases,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .c_type = cTypeForCall,
            .underlying_int_type_name = underlyingIntTypeNameForConvert,
            .result_type_name = resultTypeNameForConvert,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn domainContext(self: *CEmitter) lower_c_domain.Context {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .c_type = cTypeForCall,
            .underlying_int_type_name = underlyingIntTypeNameForConvert,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn arithContext(self: *CEmitter) lower_c_arith.Context {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .type_aliases = &self.type_aliases,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .c_type = cTypeForCall,
            .c_ident = cIdentForCall,
            .underlying_int_type_name = underlyingIntTypeNameForConvert,
            .result_type_name = resultTypeNameForConvert,
            .mir_check_elided = mirCheckElidedForArith,
            .has_mir_no_overflow_range_fact = hasMirNoOverflowRangeFactForArith,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
            .local_info_from_type = localInfoFromTypeForArith,
            .operand_emit_type = operandEmitTypeForArith,
            .global_assignment_target = globalAssignmentTargetForArith,
            .emit_assign_target = emitAssignTargetForArith,
        };
    }

    fn builtinEmitContext(self: *CEmitter) lower_c_builtin_emit.Context {
        return .{
            .enum_ctx = self,
            .emit_expr = emitExprForCall,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
            .atomic = self.atomicEmitContext(),
            .call = self.callContext(),
            .convert = self.convertContext(),
            .memory = self.memoryContext(),
            .mmio = self.mmioEmitContext(),
            .arith = self.arithContext(),
            .domain = self.domainContext(),
            .reflect = self.reflectEmitContext(),
            .access = self.accessEmitContext(),
        };
    }

    fn sequencedBinaryContext(self: *CEmitter) lower_c_arith.SequencedBinaryContext {
        return .{
            .arith = self.arithContext(),
            .emit_ctx = self,
            .expr_needs_sequenced_binary = lower_c_arith.exprNeedsDefaultSequencedBinary,
            .emit_operand_temp = emitSequencedBinaryOperandTempForArith,
        };
    }

    fn memoryContext(self: *CEmitter) lower_c_memory.Context {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForMemory,
            .c_type = cTypeForCall,
            .slice_type_name = sliceTypeNameForMemory,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn flowEmitContext(self: *CEmitter) lower_c_flow.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .next_loop_id = &self.next_loop_id,
            .loop_ids = &self.loop_ids,
            .loop_labels = &self.loop_labels,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_block_items = emitBlockItemsForFlow,
            .local_info_from_type = localInfoFromTypeForFlow,
            .array_len_text = arrayLenTextForFlow,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .emit_loop = emitLoopForFlow,
            .condition_operand_type = conditionOperandTypeForFlow,
            .operand_emit_type = operandEmitTypeForArith,
            .global_assignment_target = globalAssignmentTargetForArith,
            .emit_assign_target = emitAssignTargetForArith,
            .c_type = cTypeForCall,
        };
    }

    fn accessEmitContext(self: *CEmitter) lower_c_access.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .c_type = cTypeForCall,
            .emit_declarator = emitDeclaratorForCall,
            .local_info_from_type = localInfoFromTypeForAccess,
            .operand_emit_type = operandEmitTypeForAccess,
            .global_assignment_target = globalAssignmentTargetForAccess,
            .emit_assign_target = emitAssignTargetForAccess,
            .emit_race_load_temp = emitRaceLoadTempForAccess,
            .array_len_text = arrayLenTextForAccess,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
            .mir_owned_target_type = mirOwnedTargetTypeForLowering,
            .mir_const_get_index = mirConstGetIndexForLowering,
        };
    }

    fn switchEmitContext(self: *CEmitter) lower_c_switch.EmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_read_expr_with_replacements = emitMmioReadExprWithReplacementsForSwitch,
            .emit_switch_body = emitSwitchBodyForSwitch,
            .local_info_from_type = localInfoFromTypeForSwitch,
            .c_type = cTypeForCall,
            .c_ident = cIdentForCall,
            .tagged_union_type_for_expr = taggedUnionTypeForSwitch,
            .nullable_inner_c_type_for_type = nullableInnerCTypeForSwitch,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .tagged_unions = &self.tagged_unions,
        };
    }

    fn exprEmitContext(self: *CEmitter) lower_c_expr.EmitContext {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .type_aliases = &self.type_aliases,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_checked_unary = emitCheckedUnaryExprForExpr,
            .emit_checked_binary = emitCheckedBinaryExprForExpr,
            .count_mmio_reads = countMmioReadsForExpr,
            .numeric_expr_type = numericExprTypeForConvert,
            .unary_result_type = unaryResultTypeForExpr,
            .operand_emit_type = operandEmitTypeForAtomic,
            .expr_resolves_to_float = exprResolvesToFloatForExpr,
            .is_value_optional = isValueOptionalForExpr,
        };
    }

    fn isValueOptionalForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const ty = self.nullableTypeForExpr(expr, locals) orelse return false;
        return self.valueOptionalPayloadFromCandidate(ty) != null;
    }

    fn tryReplacementEmitContext(self: *CEmitter) lower_c_try.TryReplacementEmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
            .indent = &self.indent,
            .temp_index = &self.temp_index,
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .c_type = cTypeForCall,
            .emit_declarator = emitDeclaratorForCall,
            .operand_emit_type = operandEmitTypeForTry,
            .global_assignment_target = globalAssignmentTargetForTry,
            .emit_assign_target = emitAssignTargetForTry,
            .emit_result_try_sequenced_binary_value_temp = emitResultTrySequencedBinaryValueTempForTry,
            .emit_nullable_try_sequenced_binary_value_temp = emitNullableTrySequencedBinaryValueTempForTry,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn tryCallEmitContext(self: *CEmitter) lower_c_try.TryCallEmitContext {
        return .{
            .replacement = self.tryReplacementEmitContext(),
            .call_ctx = self.sequencedArgContext(),
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
            .expr_contains_result_try = exprContainsResultTryForTry,
            .call_args_contain_result_try = callArgsContainResultTryForTry,
            .call_args_contain_nullable_try = callArgsContainNullableTryForTry,
            .collect_result_try_hoists_for_stmt = collectResultTryHoistsForStmtForTry,
            .collect_result_try_hoists_for_local_init = collectResultTryHoistsForLocalInitForTry,
            .collect_nullable_try_hoists_for_return = collectNullableTryHoistsForReturnForTry,
        };
    }

    fn tryDirectEmitContext(self: *CEmitter) lower_c_try.TryDirectEmitContext {
        return .{
            .arith = self.arithContext(),
            .replacement = self.tryReplacementEmitContext(),
            .emit_deferred_cleanups = emitDeferredCleanupsForTry,
        };
    }

    fn tryStmtEmitContext(self: *CEmitter) lower_c_try.TryStmtEmitContext {
        return .{
            .direct = self.tryDirectEmitContext(),
            .call = self.tryCallEmitContext(),
        };
    }

    fn tryMmioContext(self: *CEmitter) lower_c_special.TryMmioContext {
        return .{
            .try_stmt = self.tryStmtEmitContext(),
            .try_direct = self.tryDirectEmitContext(),
            .try_replacement = self.tryReplacementEmitContext(),
            .try_call = self.tryCallEmitContext(),
            .mmio_emit = self.mmioEmitContext(),
            .mmio_replacement = self.mmioReplacementEmitContext(),
            .mmio_call = self.mmioCallEmitContext(),
        };
    }

    fn numericExprTypeForConvert(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.numericExprTypeForEmission(expr, locals);
    }

    fn unaryResultTypeForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.unaryResultTypeForEmission(expr, locals);
    }

    fn unaryResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const node = switch (expr.kind) {
            .unary => |node| node,
            else => return null,
        };
        const inferred = if (node.op == .logical_not)
            type_bridge.simpleNameType("bool", expr.span)
        else
            self.numericExprTypeForEmission(node.expr.*, locals);
        const fact_ty = if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact|
            fact.target_ty
        else if (!isSourceSpan(expr.span))
            // Generated async state-machine expressions are absent from the
            // source-keyed MIR map; preserve their resolved operand type.
            inferred orelse return null
        else
            return null;
        // A negated integer literal is context-typed as one expression. The
        // positive magnitude may independently default to u32, including for
        // `-2147483648`, so it must not override the MIR-owned unary result.
        if (inferred) |ty| if (!(node.op == .neg and lower_c_const.isIntegerLiteralExpr(node.expr.*))) {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return null;
        };
        return fact_ty;
    }

    fn underlyingIntTypeNameForConvert(ctx: *anyopaque, ty: ast_bridge.TypeExpr) ?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.underlyingIntTypeName(ty);
    }

    fn resultTypeNameForConvert(ctx: *anyopaque, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultTypeName(ok_ty, err_ty);
    }

    fn optTypeNameForType(ctx: *anyopaque, payload_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_names.optTypeName(self.typeNameContext(), self.resolveAliasType(payload_ty));
    }

    fn sliceTypeNameForType(ctx: *anyopaque, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn arrayTypeNameForType(ctx: *anyopaque, child: ast_bridge.TypeExpr, len_expr: ast_bridge.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayTypeName(child, len_expr);
    }

    fn fnPtrTypeNameForType(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.fnPtrTypeName(ty.kind.fn_pointer);
    }

    fn closureTypeNameForType(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.closureTypeName(ty.kind.closure_type);
    }

    fn dynTypeNameForType(ctx: *anyopaque, trait_name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.dynTypeName(trait_name);
    }

    fn operandEmitTypeForAtomic(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn exprIsPointerForAtomic(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprIsPointer(expr, locals);
    }

    fn emitExprForCall(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, locals);
    }

    fn emitExprWithTargetForArith(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn emitCheckedUnaryExprForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const node = switch (expr.kind) {
            .unary => |node| node,
            else => return false,
        };
        return lower_c_arith.emitCheckedUnaryWithTarget(self.arithContext(), node, locals, target_ty);
    }

    fn emitCheckedBinaryExprForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const node = switch (expr.kind) {
            .binary => |node| node,
            else => return false,
        };
        return lower_c_arith.emitCheckedBinaryWithTarget(self.arithContext(), node, locals, target_ty);
    }

    fn countMmioReadsForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) usize {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_mmio.countReads(self.mmioEmitContext(), expr, locals);
    }

    fn exprResolvesToFloatForExpr(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprResolvesToFloat(expr, locals);
    }

    fn emitBlockItemsForFlow(ctx: *anyopaque, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitBlockItemsWithDeferStackSnapshot(block, locals, return_ty);
    }

    fn emitBlockItemsForMmio(ctx: *anyopaque, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitBlockItems(block, locals, return_ty);
    }

    fn emitSwitchBodyForSwitch(ctx: *anyopaque, body: ast_bridge.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitSwitchBody(body, locals, return_ty);
    }

    fn emitMmioReadExprWithReplacementsForSwitch(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr, replacements: []const MmioReadReplacement) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try lower_c_mmio.emitReadExprWithReplacements(self.mmioReplacementEmitContext(), expr, locals, target_ty, replacements);
    }

    fn localInfoFromTypeForSwitch(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn taggedUnionTypeForSwitch(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.taggedUnionTypeForExpr(expr, locals);
    }

    fn nullableInnerCTypeForSwitch(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.nullableInnerCTypeForType(ty);
    }

    fn localInfoFromTypeForFlow(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn arrayLenTextForFlow(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenText(ty);
    }

    fn conditionOperandTypeForFlow(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.conditionOperandTypeForEmission(expr, locals);
    }

    fn emitLoopForFlow(ctx: *anyopaque, loop: ast_bridge.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitForLoop(loop, locals, return_ty);
    }

    fn emitSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitAddressSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitAddressSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitIndexSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitIndexSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitBinarySequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitBinarySequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitDerefSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_access.emitRawManyOffsetDerefValueTemp(self.accessEmitContext(), arg, locals, target_ty);
    }

    fn emitAggregateSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const mir_target_ty = (try self.mirAggregateTargetTypeForExpr(arg)) orelse target_ty;
        return lower_c_aggregate.emitUncheckedAddAggregateCallArgTemp(self.aggregateEmitContext(), arg, locals, mir_target_ty);
    }

    fn emitSequencedValueTempForAggregate(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (expr.kind == .uninit_literal) return null;
        if (try self.emitUncheckedAddValueTemp(expr, locals, target_ty, range_target)) |temp| return temp;
        return try self.emitSequencedCallArgTemp(expr, locals, target_ty);
    }

    fn operandEmitTypeForAggregate(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForAggregate(ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForAggregate(ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitCastSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (try self.emitAtomicCastSequencedCallArgTemp(arg, locals, target_ty)) |temp| return temp;
        return self.emitUncheckedAddValueTemp(arg, locals, target_ty, "call_arg");
    }

    fn emitCallSequencedArgTempForCall(ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitCallSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn cTypeForCall(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitDeclaratorForCall(ctx: *anyopaque, ty: ast_bridge.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitDeclarator(ty, name);
    }

    fn cIdentForCall(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn mirCheckElidedForArith(ctx: *anyopaque, span: ast_bridge.Span) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirCheckElided(span);
    }

    fn hasMirNoOverflowRangeFactForArith(ctx: *anyopaque, target: []const u8, op: []const u8, span: ast_bridge.Span) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.hasMirNoOverflowRangeFact(target, op, span);
    }

    fn mirCallTargetKindForLowering(ctx: *anyopaque, span: ast_bridge.Span) ?mir.CallTargetKind {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirCallTargetKindAt(span);
    }

    fn mirTargetTypeForLowering(ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return if (self.mirTargetTypeFactAt(kind, span)) |fact| fact.target_ty else null;
    }

    fn mirOwnedTargetTypeForLowering(ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast_bridge.Span, target_owner: []const u8, target_index: ?usize) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return if (self.mirTargetTypeFactAtOwned(kind, span, target_owner, target_index)) |fact| fact.target_ty else null;
    }

    fn mirConstGetIndexForLowering(ctx: *anyopaque, span: ast_bridge.Span) ?usize {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirConstGetIndexAt(span);
    }

    fn localInfoFromTypeForArith(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn operandEmitTypeForArith(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForArith(ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForArith(ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitSequencedBinaryOperandTempForArith(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (try self.emitUncheckedAddValueTemp(expr, locals, target_ty, "binary_operand")) |temp| return temp;
        return try self.emitSequencedCallArgTemp(expr, locals, target_ty);
    }

    fn operandEmitTypeForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForTry(ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForTry(ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitResultTrySequencedBinaryValueTempForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, return_ty: ?ast_bridge.TypeExpr, mode: ResultTrySequenceMode) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.emitResultTrySequencedBinaryValueTemp(self.tryDirectEmitContext(), expr, locals, target_ty, return_ty, mode);
    }

    fn emitNullableTrySequencedBinaryValueTempForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.emitNullableTrySequencedBinaryValueTemp(self.tryDirectEmitContext(), expr, locals, target_ty);
    }

    fn exprContainsResultTryForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprContainsResultTry(expr, locals);
    }

    fn callArgsContainResultTryForTry(ctx: *anyopaque, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.callArgsContainResultTry(args, locals);
    }

    fn callArgsContainNullableTryForTry(ctx: *anyopaque, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try self.callArgsContainNullableTry(args, locals);
    }

    fn collectResultTryHoistsForStmtForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectResultTryHoistsForStmt(self.tryDirectEmitContext(), expr, locals, return_ty, replacements);
    }

    fn collectResultTryHoistsForLocalInitForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast_bridge.TypeExpr, replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectResultTryHoistsForLocalInit(self.tryDirectEmitContext(), expr, locals, enclosing_return_ty, replacements);
    }

    fn collectNullableTryHoistsForReturnForTry(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectNullableTryHoistsForReturn(self.tryDirectEmitContext(), expr, locals, replacements);
    }

    fn emitDeferredCleanupsForTry(ctx: *anyopaque, locals: *std.StringHashMap(LocalInfo), return_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitCleanupEdge(.error_exit, locals, return_ty, null, null);
    }

    fn operandEmitTypeForAccess(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForAccess(ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForAccess(ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn localInfoFromTypeForAccess(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn arrayLenTextForAccess(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try self.arrayLenText(ty);
    }

    fn sliceTypeNameForMemory(ctx: *anyopaque, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn cIdentForMemory(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn emitExprWithTargetForMemory(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn mmioAccessForMmio(ctx: *anyopaque, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mmioAccess(callee, args, locals);
    }

    fn valueCTypeForMmio(ctx: *anyopaque, value_type: []const u8) []const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeForMmioValue(value_type);
    }

    fn operandEmitTypeForMmio(ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForMmio(ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForMmio(ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitMmioReadSequencedBinaryValueTempForMmio(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_mmio.emitReadSequencedBinaryValueTemp(self.mmioCallEmitContext(), expr, locals, target_ty);
    }

    fn cTypeForDefs(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn cIdentForDefs(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn declaratorForDefs(ctx: *anyopaque, ty: ast_bridge.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitDeclarator(ty, name);
    }

    fn fieldDeclaratorForDefs(ctx: *anyopaque, ty: ast_bridge.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitStructFieldDeclarator(ty, name);
    }

    fn enumCaseValueForDefs(ctx: *anyopaque, value: ast_bridge.Expr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitEnumCaseValue(value);
    }

    fn resultPayloadCTypeForDefs(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultPayloadCType(ty);
    }

    fn isVoidTypeForDispatch(ctx: *anyopaque, ty: ast_bridge.TypeExpr) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return isVoidType(self.resolveAliasType(ty));
    }

    fn collectPackedBits(self: *CEmitter, packed_bits: ast_bridge.PackedBitsDecl) !void {
        try lower_c_collect.collectPackedBits(self.allocator, &self.packed_bits, packed_bits, try self.cTypeFor(packed_bits.repr, .typedef_name));
    }

    fn collectOverlayUnion(self: *CEmitter, overlay_union: ast_bridge.OverlayUnionDecl) !void {
        var size: usize = 1;
        var alignment: usize = 1;
        var fields = std.StringHashMap(OverlayFieldInfo).init(self.allocator);
        errdefer fields.deinit();
        for (overlay_union.fields) |field| {
            const layout = self.overlayFieldLayout(field.ty) orelse return error.UnsupportedCEmission;
            size = @max(size, layout.size);
            alignment = @max(alignment, layout.alignment);
            try self.collectTypeArtifacts(field.ty);
            try fields.put(field.name.text, .{
                .ty = field.ty,
                .layout = layout,
                .byte_array_len = try self.overlayByteArrayLen(field.ty),
            });
        }
        try self.overlay_unions.put(overlay_union.name.text, .{ .size = size, .alignment = alignment, .fields = fields });
    }

    fn collectTaggedUnion(self: *CEmitter, union_decl: ast_bridge.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| try self.collectTypeArtifacts(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
    }

    fn overlayFieldLayout(self: *CEmitter, ty: ast_bridge.TypeExpr) ?OverlayLayout {
        var reflect_env = self.reflectEnv();
        return overlayFieldLayoutForType(ty, &self.const_fns, &self.const_globals, &reflect_env);
    }

    fn overlayByteArrayLen(self: *CEmitter, ty: ast_bridge.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .array => |node| {
                const child_name = typeName(node.child.*) orelse return null;
                if (!std.mem.eql(u8, child_name, "u8")) return null;
                return try self.arrayLenTextForExpr(node.len);
            },
            .qualified => |node| try self.overlayByteArrayLen(node.child.*),
            else => null,
        };
    }

    fn collectMmioStruct(self: *CEmitter, struct_decl: ast_bridge.StructDecl) !void {
        try lower_c_collect.collectMmioStruct(self.allocator, &self.mmio_structs, struct_decl);
    }

    fn appendPointerType(self: *CEmitter, out: *std.ArrayList(u8), child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability, style: StructTypeStyle) anyerror!void {
        try lower_c_type.appendPointerType(self.typeEmitContext(), out, child, mutability, style);
    }

    fn collectFunctionArtifactSliceTypes(self: *CEmitter, function: declaration_artifacts.FunctionArtifact) !void {
        const previous_function = self.current_function;
        self.current_function = function.signature.name.text;
        defer self.current_function = previous_function;
        for (function.signature.params) |param| try self.collectTypeArtifacts(param.ty);
        if (function.signature.transitionalReturnType()) |ret| try self.collectTypeArtifacts(ret);
        if (self.mirFunctionNamed(function.signature.name.text)) |fn_mir| try self.collectMirFunctionBodyTypeArtifacts(fn_mir);
    }

    fn collectMirFunctionBodyTypeArtifacts(self: *CEmitter, fn_mir: *const mir.Function) !void {
        for (fn_mir.body_type_artifact_facts) |fact| try self.collectTypeArtifacts(fact.ty);
        for (fn_mir.target_type_facts) |fact| try self.collectTypeArtifacts(fact.target_ty);
    }

    fn collectTypeArtifacts(self: *CEmitter, ty: ast_bridge.TypeExpr) anyerror!void {
        const resolved_ty = self.resolveAliasType(ty);
        try lower_c_collect.collectArrayType(self.arrayArtifactContext(), resolved_ty);
        try lower_c_collect.collectSliceType(self.sliceArtifactContext(), resolved_ty);
        try lower_c_collect.collectResultType(self.resultArtifactContext(), resolved_ty);
        try lower_c_collect.collectFnPtrType(self.fnPtrArtifactContext(), resolved_ty);
        try self.collectOptTypes(ty);
    }

    // Register any value optional `?T` (tagged repr) reachable through `ty` so its
    // `mc_opt_<T>` typedef is emitted. Mirrors collectSliceType's per-type dedup.
    fn collectOptTypes(self: *CEmitter, ty: ast_bridge.TypeExpr) anyerror!void {
        const resolved = self.resolveAliasType(ty);
        switch (resolved.kind) {
            .pointer => |node| try self.collectOptTypes(node.child.*),
            .raw_many_pointer => |node| try self.collectOptTypes(node.child.*),
            .slice => |node| try self.collectOptTypes(node.child.*),
            .array => |node| try self.collectOptTypes(node.child.*),
            .qualified => |node| try self.collectOptTypes(node.child.*),
            .generic => |node| for (node.args) |arg| try self.collectOptTypes(arg),
            .member => |node| try self.collectOptTypes(node.base.*),
            .nullable => |child| {
                try self.collectOptTypes(child.*);
                if (self.nullablePayloadIsValueOptional(child.*)) {
                    const payload = self.resolveAliasType(child.*);
                    const name = try lower_c_names.optTypeName(self.typeNameContext(), payload);
                    if (self.opt_types.get(name)) |existing| {
                        if (!type_bridge.sameTypeSyntax(existing.payload_ty, payload)) return error.GeneratedTypeNameCollision;
                    } else try self.opt_types.put(name, .{ .name = name, .payload_ty = payload });
                }
            },
            else => {},
        }
    }

    // A `?T` payload uses the tagged repr iff T is a sized VALUE type (not a pointer,
    // slice, fn-pointer, or `*dyn` — those keep the null-sentinel repr).
    fn nullablePayloadIsValueOptional(self: *CEmitter, child: ast_bridge.TypeExpr) bool {
        const resolved = self.resolveAliasType(child);
        return switch (resolved.kind) {
            // A named payload — a scalar (u32/…), address class (PAddr), struct, enum,
            // or packed-bits — uses the tagged repr. Pointers/slices/dyn keep the
            // sentinel repr; arrays/generics are deferred.
            .name => |n| !std.mem.eql(u8, n.text, "c_void"),
            .qualified => |node| self.nullablePayloadIsValueOptional(node.child.*),
            else => false,
        };
    }

    fn collectTypeArtifactsForCollect(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.collectTypeArtifacts(ty);
    }

    fn arrayArtifactContext(self: *CEmitter) lower_c_collect.ArrayArtifactContext {
        return .{
            .emit_ctx = self,
            .collect_type_artifacts = collectTypeArtifactsForCollect,
            .array_type_name = arrayTypeNameForCollect,
            .array_len_text_for_expr = arrayLenTextForCollect,
            .c_type_for_typedef = cTypeForTypedefForCollect,
            .array_types = &self.array_types,
        };
    }

    fn arrayTypeNameForCollect(ctx: *anyopaque, child: ast_bridge.TypeExpr, len_expr: ast_bridge.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayTypeName(child, len_expr);
    }

    fn arrayLenTextForCollect(ctx: *anyopaque, expr: ast_bridge.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }

    fn cTypeForTypedefForCollect(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn resultArtifactContext(self: *CEmitter) lower_c_collect.ResultArtifactContext {
        return .{
            .emit_ctx = self,
            .collect_type_artifacts = collectTypeArtifactsForCollect,
            .result_type_name = resultTypeNameForCollect,
            .result_types = &self.result_types,
        };
    }

    fn resultTypeNameForCollect(ctx: *anyopaque, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultTypeName(ok_ty, err_ty);
    }

    fn sliceArtifactContext(self: *CEmitter) lower_c_collect.SliceArtifactContext {
        return .{
            .emit_ctx = self,
            .slice_type_name = sliceTypeNameForCollect,
            .pointer_type_for_slice_element = pointerTypeForSliceElementForCollect,
            .slice_types = &self.slice_types,
        };
    }

    fn sliceTypeNameForCollect(ctx: *anyopaque, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn pointerTypeForSliceElementForCollect(ctx: *anyopaque, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.pointerTypeForSliceElement(child, mutability);
    }

    fn fnPtrArtifactContext(self: *CEmitter) lower_c_collect.FnPtrArtifactContext {
        return .{
            .emit_ctx = self,
            .fn_ptr_type_name = fnPtrTypeNameForCollect,
            .closure_type_name = closureTypeNameForCollect,
            .fn_ptr_types = &self.fn_ptr_types,
            .closure_types = &self.closure_types,
        };
    }

    fn fnPtrTypeNameForCollect(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.fnPtrTypeName(ty.kind.fn_pointer);
    }

    fn closureTypeNameForCollect(ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.closureTypeName(ty.kind.closure_type);
    }

    // A stable typedef name for a function-pointer signature: `mc_fnptr_<ret>` then
    // each parameter suffix, so identical signatures share one typedef.
    fn fnPtrTypeName(self: *CEmitter, node: anytype) ![]const u8 {
        return lower_c_names.fnPtrTypeName(self.typeNameContext(), node);
    }

    fn closureTypeName(self: *CEmitter, node: anytype) ![]const u8 {
        return lower_c_names.closureTypeName(self.typeNameContext(), node);
    }

    fn emitFnPtrTypes(self: *CEmitter) !void {
        try lower_c_defs.emitFnPtrTypes(self.defsContext(), &self.fn_ptr_types);
    }

    // A closure is a fat value: a code pointer taking the type-erased env first,
    // plus the env pointer. `bind`/calls cast at the boundary (compiler-generated),
    // so user code stays typed and cast-free.
    fn emitClosureTypes(self: *CEmitter) !void {
        try lower_c_defs.emitClosureTypes(self.defsContext(), &self.closure_types);
    }

    // ----- Tier 2 trait objects (traits-design §4,§8) ---------------------------
    // The fat-pointer typedef name for `*dyn Trait`.
    fn dynTypeName(self: *CEmitter, trait_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "mc_dyn_{s}", .{trait_name});
    }

    // For every object-safe trait, emit `struct VT_Trait { … };` and the fat-pointer
    // typedef `mc_dyn_Trait`. Only traits that are actually formed as `*dyn` need this,
    // but emitting for every declared trait is harmless (unused typedefs cost nothing).
    fn emitDynTraitTypes(self: *CEmitter) !void {
        try lower_c_defs.emitDynTraitTypes(self.defsContext(), &self.trait_decls);
    }

    // Checked MIR owns the complete indirect callee signature. The legacy
    // parser-only C entry point still accepts modules that have no such fact.
    fn closureCalleeType(self: *CEmitter, callee: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const ty = if (self.mirTargetTypeFactAt(.indirect_call_callee, callee.span)) |fact|
            fact.target_ty
        else
            self.operandEmitType(callee, locals) orelse return null;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .closure_type => resolved,
            else => null,
        };
    }

    // Whether a bind env of this (resolved) type passes through the closure's
    // `void *` env slot without conversion. Pointer-shaped envs (the common
    // `bind(&obj, f)` form) are ABI-identical to `void *`; everything else (a
    // `u32`, an enum, …) is a scalar that must be widened through `uintptr_t`
    // and routed via a generated thunk.
    fn bindEnvIsPointerLike(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return lower_c_collect.bindEnvIsPointerLike(&self.type_aliases, ty);
    }

    fn collectBindThunkFact(self: *CEmitter, fact: mir.BindThunkFact) !void {
        const info = self.functions.get(fact.target_fn) orelse return;
        if (info.params.len == 0 or info.is_extern) return;
        if (self.bindEnvIsPointerLike(info.params[0].ty)) return;
        const name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_envthunk_{s}", .{fact.target_fn});
        if (!self.bind_thunks.contains(name)) try self.bind_thunks.put(name, .{ .fname = fact.target_fn, .info = info });
    }

    // Emit `bind(&env, f)` as a closure compound literal. `f` names a function whose
    // first parameter is the (typed) env; the closure drops it to void*.
    fn emitBind(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) !void {
        const plan = try self.bindEmitPlan(node, target_ty);
        if (!self.bindEnvIsPointerLike(plan.info.params[0].ty)) {
            try lower_c_dispatch.emitScalarEnvBind(self.dispatchContext(), node, locals, plan);
            return;
        }
        try lower_c_dispatch.emitPointerEnvBind(self.dispatchContext(), node, locals, plan);
    }

    fn bindEmitPlan(self: *CEmitter, node: anytype, target_ty: ast_bridge.TypeExpr) !lower_c_dispatch.BindEmitPlan {
        const fname = calleeIdentName(node.args[1]) orelse return error.UnsupportedCEmission;
        const info = self.functions.get(fname) orelse return error.UnsupportedCEmission;
        if (info.params.len == 0) return error.UnsupportedCEmission; // need the env param
        const closure_ty = self.closureNodeFromCandidate(target_ty) orelse return error.UnsupportedCEmission;
        const ret_ty = closure_ty.ret.*;
        const cname = try self.closureTypeName(closure_ty);
        return .{
            .fname = fname,
            .info = info,
            .ret_ty = ret_ty,
            .cname = cname,
        };
    }

    const ClosureTypeNode = struct {
        params: []ast_bridge.TypeExpr,
        ret: *ast_bridge.TypeExpr,
    };

    fn closureNodeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ClosureTypeNode {
        return switch (self.resolveAliasType(ty).kind) {
            .closure_type => |node| .{ .params = node.params, .ret = node.ret },
            else => null,
        };
    }

    // If `callee` is `d.method` where `d` has a `*dyn Trait` type, return the trait name;
    // such a call dispatches through the vtable. Null otherwise.
    fn dynCalleeTrait(self: *CEmitter, callee: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        const member = memberExpr(callee) orelse return null;
        const base_ty = self.memberBaseTypeForEmission(member.base.*, locals) orelse return null;
        return self.dynDispatchTraitNameFromCandidate(base_ty);
    }

    // `d.method(args)` -> `({ mc_dyn_T t = d; t.vtable->method(t.data, args); })`.
    // The `d` value is spilled to a temp so its `.data`/`.vtable` are read once.
    fn sliceTypeName(self: *CEmitter, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) ![]const u8 {
        return lower_c_names.sliceTypeName(self.typeNameContext(), child, mutability);
    }

    fn pointerTypeForSliceElement(self: *CEmitter, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, if (mutability == .mut) .mut else .@"const", .typedef_name);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn pointerTypeFor(self: *CEmitter, child: ast_bridge.TypeExpr, mutability: ast_bridge.Mutability, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, mutability, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn arrayTypeName(self: *CEmitter, child: ast_bridge.TypeExpr, len_expr: ast_bridge.Expr) ![]const u8 {
        return lower_c_names.arrayTypeName(self.typeNameContext(), child, len_expr);
    }

    fn typeSuffix(self: *CEmitter, ty: ast_bridge.TypeExpr) ![]const u8 {
        return lower_c_names.typeSuffix(self.typeNameContext(), ty);
    }

    fn resultTypeName(self: *CEmitter, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) ![]const u8 {
        return lower_c_names.resultTypeName(self.typeNameContext(), ok_ty, err_ty);
    }

    fn emitStmt(self: *CEmitter, stmt: ast_bridge.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.writeLineDirective(stmt.span);
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                const is_let = std.meta.activeTag(stmt.kind) == .let_decl;
                try self.emitLocalDeclStmt(local, is_let, locals, return_ty);
            },
            .assignment => |node| {
                try self.emitAssignmentStmt(node, stmt.span, locals, return_ty);
            },
            .@"return" => |maybe| {
                try self.emitReturnStmt(maybe, locals, return_ty);
            },
            .@"break" => |target| {
                try self.emitBreakStmt(target);
            },
            .@"continue" => |target| {
                try self.emitContinueStmt(target);
            },
            .expr => |expr| {
                try self.emitExpressionStmt(expr, locals, return_ty);
            },
            .assert => |expr| {
                try self.emitAssertStmt(expr, locals);
            },
            .block, .unsafe_block => |block| {
                try self.emitScopedBlockStmt(block, locals, return_ty);
            },
            .contract_block => |contract| {
                try self.emitContractBlockStmt(contract, locals, return_ty);
            },
            .comptime_block => {},
            .asm_stmt => |asm_stmt| try self.emitAsmStmt(asm_stmt, locals),
            .loop => |loop| {
                try self.emitLoopStmt(stmt, loop, locals, return_ty);
            },
            .@"switch" => |node| try self.emitSwitch(node, locals, return_ty),
            .if_let => |node| try self.emitIfLet(node, locals, return_ty),
            else => try self.writeUnsupportedStmt(stmt),
        }
    }

    fn emitLocalDeclStmt(self: *CEmitter, local: ast_bridge.LocalDecl, is_let: bool, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        for (local.names) |name| {
            // A declaration (re)binds the name: a stale provenance entry from a
            // disjoint sibling scope must never leak into the new binding (a
            // leaked .local_storage proof would be an unsound plain lowering).
            _ = self.mir_pointer_local_provenance.remove(name.text);
            try locals.put(name.text, try self.localDeclInfo(local, is_let, locals));
            if (local.ty) |decl_ty| {
                if (local.init) |initializer| try self.applyMirPointerProvenanceForLocalInitializer(name.text, decl_ty, initializer, locals);
            }
            if (try self.emitSpecialLocalDecl(name.text, local, locals, return_ty)) {
                continue;
            }
            try self.emitDefaultLocalDecl(name.text, local.ty, local.init, locals);
        }
    }

    fn localDeclInfo(self: *CEmitter, local: ast_bridge.LocalDecl, is_let: bool, locals: *std.StringHashMap(LocalInfo)) !LocalInfo {
        var info = if (local.ty) |decl_ty| try self.localInfoFromType(decl_ty) else LocalInfo{};
        info.is_mutable = !is_let;
        if (is_let and local.names.len == 1) {
            if (local.ty) |decl_ty| {
                if (local.init) |initializer| {
                    info.const_int = self.constLocalValue(decl_ty, initializer, locals);
                }
            }
        }
        return info;
    }

    fn emitSpecialLocalDecl(self: *CEmitter, name: []const u8, local: ast_bridge.LocalDecl, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (local.names.len != 1) return false;
        if (local.ty) |decl_ty| {
            const initializer = local.init orelse return false;
            return try self.emitSpecialTypedLocalInit(name, decl_ty, initializer, locals, return_ty);
        }
        const initializer = local.init orelse return false;
        return try self.emitSpecialInferredLocalInit(name, initializer, locals, return_ty);
    }

    fn emitSpecialTypedLocalInit(
        self: *CEmitter,
        name: []const u8,
        decl_ty: ast_bridge.TypeExpr,
        initializer: ast_bridge.Expr,
        locals: *std.StringHashMap(LocalInfo),
        return_ty: ?ast_bridge.TypeExpr,
    ) anyerror!bool {
        if (try self.emitVarargsTypedLocalInit(name, decl_ty, initializer)) return true;
        if (try lower_c_special.emitTypedLocalInit(self.tryMmioContext(), name, decl_ty, initializer, locals, return_ty)) return true;
        if (try self.emitAccessTypedLocalInit(name, decl_ty, initializer, locals)) return true;
        if (try self.emitConversionTypedLocalInit(name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitVarargsTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr) anyerror!bool {
        if (try self.emitVaStartLocalInit(name, decl_ty, initializer)) return true;
        if (try self.emitVaListCopyLocalInit(name, decl_ty, initializer)) return true;
        return false;
    }

    fn emitAccessTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_access.emitDirectCallSliceIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAddressLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitLocalIndexAddressLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitLocalIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitConversionTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_access.emitRawManyOffsetDerefLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_call.emitBitcastLocalInit(self.sequencedArgContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_call.emitExternNonNullCallLocalInit(self.sequencedArgContext(), &self.functions, name, decl_ty, initializer, locals)) return true;
        if (try lower_c_arith.emitUncheckedAddLocalInit(self.arithContext(), name, decl_ty, initializer, locals)) return true;
        const aggregate_target_ty = (try self.mirAggregateTargetTypeForExpr(initializer)) orelse decl_ty;
        if (try lower_c_aggregate.emitUncheckedAddAggregateLocalInit(self.aggregateEmitContext(), name, aggregate_target_ty, initializer, locals)) return true;
        if (try lower_c_flow.emitSequencedComparisonLocalInit(self.flowEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_arith.emitSequencedCheckedBinaryLocalInit(self.sequencedBinaryContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitSpecialInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try self.emitAddressOfInferredLocalInit(name, initializer, locals)) return true;
        if (try self.tryPayloadTypeForInferredLocal(initializer)) |known_ty| {
            const inferred_ty = (try self.mirInferredLocalType(name, initializer, known_ty)) orelse return error.UnsupportedCEmission;
            try locals.put(name, try self.localInfoFromType(inferred_ty));
            return try self.emitSpecialTypedLocalInit(name, inferred_ty, initializer, locals, return_ty);
        }
        // A cast can wrap `unchecked.add/sub/mul`; give the MIR range-fact
        // lowering first claim so it does not fall through to targetless call
        // emission inside the generic cast path.
        if (try lower_c_arith.emitUncheckedAddInferredLocalInit(self.arithContext(), name, initializer, locals)) return true;
        if (try self.emitCastInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitLiteralInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitArrayCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitSliceCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitEnumCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitTaggedUnionCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitResultCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitNullableCallInferredLocalInit(name, initializer, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefInferredLocalInit(self.accessEmitContext(), name, initializer, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetInferredLocalInit(self.accessEmitContext(), name, initializer, locals)) return true;
        if (try lower_c_call.emitBitcastInferredLocalInit(self.sequencedArgContext(), name, initializer, locals)) return true;
        if (try lower_c_call.emitExternNonNullCallInferredLocalInit(self.sequencedArgContext(), &self.functions, name, initializer, locals)) return true;
        if (try self.emitLocalCopyInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitBooleanInferredLocalInit(name, initializer, locals)) return true;
        if (try lower_c_mmio.emitDirectReadInferredLocalInitExpr(self.mmioEmitContext(), name, initializer, locals)) return true;
        if (try lower_c_mmio.emitReadExprInferredLocalInit(self.mmioCallEmitContext(), name, initializer, locals)) return true;
        if (try self.emitCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitNumericInferredLocalInit(name, initializer, locals)) return true;
        return false;
    }

    fn emitAddressOfInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const operand = switch (initializer.kind) {
            .address_of => |inner| inner.*,
            .grouped => |inner| return try self.emitAddressOfInferredLocalInit(name, inner.*, locals),
            else => return false,
        };
        const place = self.directAddressPlaceInfo(operand, locals) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, null)) orelse return error.UnsupportedCEmission;
        const pointer = self.pointerNodeFromCandidate(inferred_ty) orelse return error.UnsupportedCEmission;
        if (pointer.mutability != place.mutability) return error.UnsupportedCEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointer.child.*), self.resolveAliasType(place.ty))) return error.UnsupportedCEmission;
        var info = try self.localInfoFromType(inferred_ty);
        if (locals.get(name)) |existing| info.is_mutable = existing.is_mutable;
        try locals.put(name, info);
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    const DirectAddressPlace = struct {
        ty: ast_bridge.TypeExpr,
        mutability: ast_bridge.Mutability,
    };

    fn directAddressPlaceInfo(self: *CEmitter, operand: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?DirectAddressPlace {
        return switch (operand.kind) {
            .ident => |ident| blk: {
                if (locals.get(ident.text)) |info| {
                    const place_ty = self.identTypeForEmissionRecovered(ident.text, operand.span, locals) orelse break :blk null;
                    break :blk .{ .ty = place_ty, .mutability = if (info.is_mutable) .mut else .@"const" };
                }
                if (self.globals.get(ident.text)) |info| {
                    const place_ty = self.identTypeForEmissionRecovered(ident.text, operand.span, locals) orelse break :blk null;
                    break :blk .{ .ty = place_ty, .mutability = if (info.is_const) .@"const" else .mut };
                }
                break :blk null;
            },
            .member => |node| if (self.directAddressPlaceInfo(node.base.*, locals)) |base| .{ .ty = self.operandEmitType(operand, locals) orelse return null, .mutability = base.mutability } else null,
            .index => |node| blk: {
                const base = self.directAddressPlaceInfo(node.base.*, locals) orelse break :blk null;
                if (self.arrayTypeFromType(base.ty) == null) break :blk null;
                break :blk .{ .ty = self.operandEmitType(operand, locals) orelse break :blk null, .mutability = base.mutability };
            },
            .deref => |inner| blk: {
                const pointer_ty = self.directAddressOfLocalPointerType(inner.*, locals) orelse break :blk null;
                const view = type_bridge.viewType(self.resolveAliasType(pointer_ty)) orelse break :blk null;
                const mutability = switch (view.kind) {
                    .pointer, .raw_many_pointer => view.mutability,
                    else => break :blk null,
                };
                break :blk .{ .ty = self.operandEmitType(operand, locals) orelse break :blk null, .mutability = mutability };
            },
            .grouped => |inner| self.directAddressPlaceInfo(inner.*, locals),
            else => null,
        };
    }

    fn directAddressOfLocalPointerType(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => self.operandEmitType(expr, locals),
            .grouped => |inner| self.directAddressOfLocalPointerType(inner.*, locals),
            else => null,
        };
    }

    // A direct `source?` initializer is already typed by the MIR-owned operand
    // fact. Use that payload only to validate the owned inferred-local fact;
    // the typed try emitter still owns control-flow lowering.
    fn tryPayloadTypeForInferredLocal(self: *CEmitter, initializer: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (initializer.kind) {
            .grouped => |inner| try self.tryPayloadTypeForInferredLocal(inner.*),
            .try_expr => |node| blk: {
                const operand_ty = self.mirTryOperandTypeForQuery(node.operand.*) orelse break :blk null;
                const resolved = self.resolveAliasType(operand_ty);
                const expected_ty = if (resultPayloadTypeForTag(resolved, "ok")) |payload_ty|
                    payload_ty
                else switch (resolved.kind) {
                    .nullable => |child| child.*,
                    else => null,
                };
                const fact_ty = (self.mirTargetTypeFactAt(.expression_result, initializer.span) orelse break :blk null).target_ty;
                if (expected_ty) |expected| {
                    if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(expected))) return error.UnsupportedCEmission;
                }
                break :blk fact_ty;
            },
            else => null,
        };
    }

    fn emitCastInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (!inferredLocalCastInitializer(initializer)) return false;
        const known_ty = self.operandEmitType(initializer, locals);
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, known_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitLiteralInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const expected_ty = (try self.literalExpressionResultType(initializer)) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, expected_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitDefaultLocalDecl(self: *CEmitter, name: []const u8, maybe_ty: ?ast_bridge.TypeExpr, maybe_init: ?ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        try self.writeIndent();
        try self.emitIgnoredLocalPrefix(name);
        try self.emitLocalDeclarator(name, maybe_ty);
        try self.emitDefaultLocalInitializer(maybe_ty, maybe_init, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalDeclarator(self: *CEmitter, name: []const u8, maybe_ty: ?ast_bridge.TypeExpr) anyerror!void {
        if (maybe_ty) |decl_ty| {
            try self.emitDeclarator(decl_ty, name);
        } else {
            try self.out.print(self.allocator, "uint32_t {s}", .{name});
        }
    }

    fn emitDefaultLocalInitializer(self: *CEmitter, maybe_ty: ?ast_bridge.TypeExpr, maybe_init: ?ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        if (maybe_init) |initializer| {
            try self.emitExplicitLocalInitializer(maybe_ty, initializer, locals);
        } else if (maybe_ty != null and self.arrayTypeFromType(maybe_ty.?) != null) {
            try self.out.appendSlice(self.allocator, " = {0}");
        } else {
            try self.out.appendSlice(self.allocator, " = 0");
        }
    }

    fn emitExplicitLocalInitializer(self: *CEmitter, maybe_ty: ?ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        if (isUninitLiteral(initializer)) {
            if (maybe_ty) |decl_ty| try self.emitMaterializedUninitInitializer(decl_ty);
            return;
        }
        try self.out.appendSlice(self.allocator, " = ");
        if (maybe_ty) |decl_ty| {
            try self.emitExprWithTarget(initializer, locals, decl_ty);
        } else {
            try self.emitExpr(initializer, locals);
        }
    }

    fn emitAssignmentStmt(self: *CEmitter, assignment: anytype, span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.applyMirPointerProvenanceForAssignment(assignment.target, assignment.value, span, locals);
        try self.applyMirPointerProvenanceForIndexAssignment(assignment.target, assignment.value, span, locals);
        if (try self.emitRaceTolerantDerefStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitRaceTolerantPointerMemberStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitRaceTolerantSliceIndexStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitRaceTolerantPointerArrayIndexStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitSpecialAssignmentStmt(assignment, locals, return_ty)) return;
        if (try self.emitRaceTolerantIndexedMemberStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitRaceTolerantNestedIndexedMemberStoreStmt(assignment.target, assignment.value, locals)) return;
        if (try self.emitRaceTolerantNestedPointerMemberStoreStmt(assignment.target, assignment.value, locals)) return;
        if (self.memberChainHasRaceTolerantIndexedBase(assignment.target, locals)) return error.UnsupportedCEmission;
        try self.emitDefaultAssignmentStmt(assignment, locals);
    }

    fn emitSpecialAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try self.emitAggregateSpecialAssignmentStmt(assignment, locals)) return true;
        if (try lower_c_special.emitAssignmentStmt(self.tryMmioContext(), assignment, locals, return_ty)) return true;
        if (try self.emitAccessSpecialAssignmentStmt(assignment, locals)) return true;
        if (try self.emitConversionSpecialAssignmentStmt(assignment, locals)) return true;
        return false;
    }

    fn emitAggregateSpecialAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try self.emitPackedBitsFieldWriteStmt(assignment, locals)) return true;
        if (try self.emitOverlayFieldWriteStmt(assignment, locals)) return true;
        if (try self.emitGlobalArrayElementMemberAssignmentStmt(assignment, locals)) return true;
        if (try self.emitGlobalArrayIndexAssignmentStmt(assignment, locals)) return true;
        return false;
    }

    fn emitAccessSpecialAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_access.emitDirectCallSliceIndexAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitLocalIndexTargetAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAddressAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitLocalIndexAddressAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitLocalIndexAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        return false;
    }

    fn emitConversionSpecialAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_access.emitRawManyOffsetDerefTargetAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetAssignmentStmt(self.accessEmitContext(), assignment, locals)) return true;
        if (try lower_c_call.emitBitcastAssignmentStmt(self.sequencedArgContext(), assignment, locals)) return true;
        if (try lower_c_call.emitExternNonNullCallAssignmentStmt(self.sequencedArgContext(), &self.functions, assignment, locals)) return true;
        if (try lower_c_aggregate.emitUncheckedAddAggregateAssignmentStmt(self.aggregateEmitContext(), assignment, locals, try self.mirAggregateTargetTypeForExpr(assignment.value))) return true;
        if (try lower_c_arith.emitUncheckedAddAssignmentStmt(self.arithContext(), assignment, locals)) return true;
        if (try lower_c_flow.emitSequencedComparisonAssignmentStmt(self.flowEmitContext(), assignment, locals)) return true;
        if (try lower_c_arith.emitSequencedCheckedBinaryAssignmentStmt(self.sequencedBinaryContext(), assignment, locals)) return true;
        if (try lower_c_call.emitSequencedCallAssignmentStmt(self.sequencedArgContext(), &self.functions, assignment, locals)) return true;
        return false;
    }

    fn emitDefaultAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            const target_ty = simpleNameType(target.info.type_name, assignment.value.span);
            const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, target_ty);
            try self.writeIndent();
            try appendGlobalStorePrefix(self.allocator, self.out, target);
            try self.out.appendSlice(self.allocator, value_temp.name);
            try appendGlobalStoreSuffix(self.allocator, self.out, target);
        } else if (try self.emitOrdinaryHookedAssignmentStmt(assignment.target, assignment.value, locals)) {
            return;
        } else {
            const target_ty = self.operandEmitType(assignment.target, locals) orelse return error.UnsupportedCEmission;
            const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, target_ty);
            try self.writeIndent();
            try self.emitAssignTarget(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        }
    }

    fn emitReturnStmt(self: *CEmitter, maybe: ?ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        if (maybe) |expr| {
            if (try self.emitSpecialReturnStmt(expr, locals, return_ty)) return;
            try self.emitDefaultValueReturnStmt(expr, locals, return_ty);
        } else {
            try self.emitVoidReturnStmt();
        }
    }

    fn emitSpecialReturnStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try self.emitSimpleSpecialReturn(expr, locals, return_ty)) return true;
        if (try self.emitAccessSpecialReturn(expr, locals, return_ty)) return true;
        if (try lower_c_special.emitReturn(self.tryMmioContext(), expr, locals, return_ty)) return true;
        return try self.emitConversionSpecialReturn(expr, locals, return_ty);
    }

    fn emitSimpleSpecialReturn(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try self.emitNeverExprStmt(expr, locals)) return true;
        if (return_ty) |target_ty| {
            if (isVoidType(target_ty) and isVoidLiteralExpr(expr)) {
                try self.emitVoidReturnStmt();
                return true;
            }
        }
        return false;
    }

    fn emitAccessSpecialReturn(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try lower_c_access.emitDirectCallSliceIndexReturn(self.accessEmitContext(), expr, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexReturn(self.accessEmitContext(), expr, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAddressReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_access.emitLocalIndexAddressReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_access.emitLocalIndexReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_mmio.emitDirectReadReturnExpr(self.mmioEmitContext(), expr, locals)) return true;
        if (try self.emitOverlayFieldReadReturn(expr, locals, return_ty)) return true;
        return false;
    }

    fn emitConversionSpecialReturn(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        if (try lower_c_access.emitRawManyOffsetDerefReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_access.emitRawManyOffsetReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_call.emitBitcastReturn(self.sequencedArgContext(), expr, locals, return_ty)) return true;
        if (try lower_c_call.emitExternNonNullCallReturn(self.sequencedArgContext(), &self.functions, expr, locals)) return true;
        if (try lower_c_arith.emitUncheckedAddReturn(self.arithContext(), expr, locals, return_ty)) return true;
        const aggregate_target_ty = (try self.mirAggregateTargetTypeForExpr(expr)) orelse return_ty;
        if (try lower_c_aggregate.emitUncheckedAddAggregateReturn(self.aggregateEmitContext(), expr, locals, aggregate_target_ty)) return true;
        if (try lower_c_flow.emitSequencedComparisonReturn(self.flowEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_arith.emitSequencedCheckedBinaryReturn(self.sequencedBinaryContext(), expr, locals, return_ty)) return true;
        if (try lower_c_call.emitSequencedCallReturn(self.sequencedArgContext(), &self.functions, expr, locals)) return true;
        return false;
    }

    fn emitDefaultValueReturnStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        if (return_ty) |target_ty| {
            try self.emitExprWithTarget(expr, locals, target_ty);
        } else {
            try self.emitExpr(expr, locals);
        }
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitVoidReturnStmt(self: *CEmitter) anyerror!void {
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return;\n");
    }

    fn emitExpressionStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        if (try self.emitNeverExprStmt(expr, locals)) return;
        if (try lower_c_memory.emitMaybeUninitWriteStmt(self.memoryContext(), expr, locals)) return;
        if (try lower_c_mmio.emitWriteStmt(self.mmioEmitContext(), expr, locals)) return;
        if (try self.emitRawStoreStmt(expr, locals)) return;
        if (try self.emitCpuPauseStmt(expr)) return;
        if (try self.emitFenceStmt(expr)) return;
        if (try lower_c_try.emitResultTryExprStmt(self.tryStmtEmitContext(), expr, locals, return_ty)) return;
        if (try lower_c_try.emitNullableTryExprStmt(self.tryStmtEmitContext(), expr, locals)) return;
        if (try lower_c_mmio.emitReadExprStmt(self.mmioCallEmitContext(), expr, locals)) return;
        if (try lower_c_call.emitSequencedCallExprStmt(self.sequencedArgContext(), &self.functions, expr, locals)) {
            self.applyMirPointerProvenanceInvalidationsAtCall(expr.span, locals);
            return;
        }
        try self.writeIndent();
        try self.emitExpr(expr, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitAssertStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        const condition_ty = try self.requireMirBoolTargetTypeForEmission(.assert_condition, expr);
        if (try lower_c_mmio.emitReadAssert(self.mmioCallEmitContext(), expr, locals)) return;
        if (try lower_c_flow.emitSequencedConditionAssert(self.flowEmitContext(), expr, locals)) return;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "if (!(");
        try self.emitExprWithTarget(expr, locals, condition_ty);
        try self.out.appendSlice(self.allocator, ")) mc_trap_Assert();\n");
    }

    fn emitBreakStmt(self: *CEmitter, target: ?ast_bridge.Ident) anyerror!void {
        try lower_c_flow.emitBreakStmt(self.flowEmitContext(), target);
    }

    fn emitContinueStmt(self: *CEmitter, target: ?ast_bridge.Ident) anyerror!void {
        try lower_c_flow.emitContinueStmt(self.flowEmitContext(), target);
    }

    fn emitScopedBlockStmt(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.emitBracedBlockBody(block, locals, return_ty);
    }

    fn emitContractBlockStmt(self: *CEmitter, contract: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.writeIndent();
        try self.out.print(self.allocator, "/* MC_CONTRACT_BEGIN {s} */\n", .{contractName(contract.attr)});
        try self.emitBracedBlockBody(contract.block, locals, return_ty);
        try self.writeIndent();
        try self.out.print(self.allocator, "/* MC_CONTRACT_END {s} */\n", .{contractName(contract.attr)});
    }

    fn emitBracedBlockBody(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.emitBracedBlockBodyWithCleanup(block, locals, return_ty, true);
    }

    fn emitBracedBlockBodyWithCleanup(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, emit_scope_cleanup: bool) anyerror!void {
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "{\n");
        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        self.indent += 1;
        try self.emitBlockItemsWithScopeCleanup(block, &nested, return_ty, emit_scope_cleanup);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitLoopStmt(self: *CEmitter, stmt: ast_bridge.Stmt, loop: ast_bridge.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        // The for-binding (re)binds its name; see clearMirPointerProvenanceForPattern.
        if (loop.label) |binding| _ = self.mir_pointer_local_provenance.remove(binding.text);
        if (loop.kind == .@"while") {
            const condition = loop.iterable orelse return error.UnsupportedCEmission;
            _ = try self.requireMirBoolTargetTypeForEmission(.loop_condition, condition);
            if (try lower_c_mmio.emitReadWhileLoop(self.mmioWhileEmitContext(), loop, locals, return_ty)) return;
            if (try lower_c_flow.emitSequencedConditionWhileLoop(self.flowEmitContext(), loop, locals, return_ty)) return;
            try self.emitPlainWhileLoop(loop, locals, return_ty);
        } else if (loop.kind == .@"for") {
            try self.emitForLoop(loop, locals, return_ty);
        } else {
            try self.writeUnsupportedStmt(stmt);
        }
    }

    fn emitPlainWhileLoop(self: *CEmitter, loop: ast_bridge.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try lower_c_flow.emitPlainWhileLoop(self.flowEmitContext(), loop, locals, return_ty);
    }

    fn requireMirBoolTargetTypeForEmission(self: *CEmitter, kind: mir.TargetTypeKind, expr: ast_bridge.Expr) !ast_bridge.TypeExpr {
        const ty = try self.requireMirTargetTypeForEmission(kind, expr, null);
        if (!isBoolType(ty)) return error.UnsupportedCEmission;
        return ty;
    }

    fn requireMirTargetTypeForEmission(self: *CEmitter, kind: mir.TargetTypeKind, expr: ast_bridge.Expr, known_ty: ?ast_bridge.TypeExpr) !ast_bridge.TypeExpr {
        const fact_ty = (self.mirTargetTypeFactAt(kind, expr.span) orelse return error.UnsupportedCEmission).target_ty;
        if (known_ty) |ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return fact_ty;
    }

    fn mirTryOperandTypeForQuery(self: *CEmitter, operand: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return self.requireMirTargetTypeForEmission(.try_operand, operand, null) catch null;
    }

    fn emitAsmStmt(self: *CEmitter, asm_stmt: ast_bridge.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        try lower_c_asm.emitAsmStmt(self.asmEmitContext(), asm_stmt, locals);
    }

    fn emitAsmTemplate(self: *CEmitter, templates: []const []const u8) !void {
        try lower_c_asm.emitAsmTemplate(self.allocator, self.out, templates);
    }

    fn emitPreciseAsmStmt(self: *CEmitter, asm_stmt: ast_bridge.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        try lower_c_asm.emitPreciseAsmStmt(self.asmEmitContext(), asm_stmt, locals);
    }

    fn emitBlockItems(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.emitBlockItemsWithScopeCleanup(block, locals, return_ty, true);
    }

    fn emitBlockItemsWithScopeCleanup(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, emit_scope_cleanup: bool) anyerror!void {
        for (block.items) |stmt| {
            switch (try self.emitBlockControlItem(stmt, locals, return_ty)) {
                .skip_stmt => continue,
                .exit_block => return,
                .emit_stmt => {},
            }
            try self.emitStmt(stmt, locals, return_ty);
        }

        if (emit_scope_cleanup) try self.emitCleanupEdge(.scope_exit, locals, return_ty, block.span, null);
    }

    fn emitBlockItemsWithDeferStackSnapshot(self: *CEmitter, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.emitBlockItems(block, locals, return_ty);
    }

    const BlockItemAction = enum {
        emit_stmt,
        skip_stmt,
        exit_block,
    };

    fn emitBlockControlItem(self: *CEmitter, stmt: ast_bridge.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!BlockItemAction {
        switch (stmt.kind) {
            .@"defer" => |expr| {
                try self.emitBlockDeferItem(expr, stmt.span);
                return .skip_stmt;
            },
            .@"return" => {
                try self.emitBlockExitItem(stmt, locals, return_ty);
                return .exit_block;
            },
            .@"break", .@"continue" => {
                try self.emitBlockExitItem(stmt, locals, return_ty);
                return .exit_block;
            },
            else => return .emit_stmt,
        }
    }

    fn emitBlockDeferItem(self: *CEmitter, expr: ast_bridge.Expr, stmt_span: ast_bridge.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        const deferred_drop = backend_cleanup.registerDeferredExplicitDropCleanup(self.mir_module, function, self.currentOwnershipCleanupPlan(), expr.span);
        switch (deferred_drop) {
            .ignored => {},
            .applied => {
                try self.validateCleanupCfg();
            },
            .rejected => return error.UnsupportedCEmission,
        }
        const defer_ref = mir_source_bridge.deferCleanupRefAtSpan(function.*, stmt_span) orelse return error.UnsupportedCEmission;
        const cleanup_cfg = self.currentCleanupCfg() orelse return error.UnsupportedCEmission;
        if (try self.ordinaryDeferDirectCallCleanup(function, expr, defer_ref)) |cleanup| {
            switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, cleanup.defer_ref)) {
                .applied => {},
                .ignored, .rejected => return error.UnsupportedCEmission,
            }
            return;
        }
        if (try self.ordinaryDeferCallTargetCleanup(function, expr, defer_ref)) |cleanup| {
            switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, cleanup.defer_ref)) {
                .applied => {},
                .ignored, .rejected => return error.UnsupportedCEmission,
            }
            return;
        }
        switch (expr.kind) {
            .block => {
                switch (backend_cleanup.registerOrdinaryDeferCleanup(function, cleanup_cfg, defer_ref)) {
                    .applied => {},
                    .ignored, .rejected => return error.UnsupportedCEmission,
                }
            },
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitBlockExitItem(self: *CEmitter, stmt: ast_bridge.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        if (stmt.kind == .@"return") {
            try self.emitReturnExitItem(stmt.kind.@"return", stmt.span, locals, return_ty);
            return;
        }
        const edge_kind: backend_cleanup.CleanupEdgeKind = switch (stmt.kind) {
            .@"break" => .break_exit,
            .@"continue" => .continue_exit,
            else => return error.UnsupportedCEmission,
        };
        try self.emitCleanupEdge(edge_kind, locals, return_ty, null, stmt.span);
        try self.emitStmt(stmt, locals, return_ty);
    }

    fn emitReturnExitItem(self: *CEmitter, maybe_expr: ?ast_bridge.Expr, stmt_span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const expr = maybe_expr orelse {
            try self.emitCleanupEdge(.return_exit, locals, return_ty, null, stmt_span);
            try self.writeLineDirective(stmt_span);
            try self.emitVoidReturnStmt();
            return;
        };
        if (try self.cleanupEdgeIsEmpty(.return_exit, null, stmt_span)) {
            try self.writeLineDirective(stmt_span);
            try self.emitReturnStmt(maybe_expr, locals, return_ty);
            return;
        }
        const target_ty = return_ty orelse {
            try self.emitCleanupEdge(.return_exit, locals, return_ty, null, stmt_span);
            try self.emitReturnStmt(maybe_expr, locals, return_ty);
            return;
        };
        if (isVoidType(target_ty) and isVoidLiteralExpr(expr)) {
            try self.emitCleanupEdge(.return_exit, locals, return_ty, null, stmt_span);
            try self.emitVoidReturnStmt();
            return;
        }

        try self.writeLineDirective(expr.span);
        const tmp_name = try self.nextTempName();
        try self.writeIndent();
        try self.emitDeclarator(target_ty, tmp_name);
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitExprWithTarget(expr, locals, target_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        try self.emitCleanupEdge(.return_exit, locals, return_ty, null, stmt_span);
        try self.writeLineDirective(stmt_span);
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{tmp_name});
    }

    fn cleanupEdgeIsEmpty(self: *CEmitter, kind: backend_cleanup.CleanupEdgeKind, scope_span: ?ast_bridge.Span, before_span: ?ast_bridge.Span) !bool {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        var plan = (try backend_cleanup.buildCleanupEdgePlan(self.allocator, self.mir_module, function.*, self.currentOwnershipCleanupPlan(), self.currentCleanupCfg(), kind, sourcePointFromOptionalSpan(scope_span), sourcePointFromOptionalSpan(before_span))) orelse return error.UnsupportedCEmission;
        defer plan.deinit(self.allocator);
        return plan.refs.len == 0;
    }

    // Emit the MIR-admitted active cleanup range from `start`, in reverse
    // (innermost first). Exit edges such as `?` that do not pop the scope leave
    // the active cleanup state intact.
    fn emitCleanupEdge(self: *CEmitter, kind: backend_cleanup.CleanupEdgeKind, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, scope_span: ?ast_bridge.Span, before_span: ?ast_bridge.Span) anyerror!void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        var plan = (try backend_cleanup.buildCleanupEdgePlan(self.allocator, self.mir_module, function.*, self.currentOwnershipCleanupPlan(), self.currentCleanupCfg(), kind, sourcePointFromOptionalSpan(scope_span), sourcePointFromOptionalSpan(before_span))) orelse return error.UnsupportedCEmission;
        defer plan.deinit(self.allocator);
        for (plan.refs) |ref| {
            try self.emitCleanupRef(ref, locals, return_ty);
        }
    }

    fn validateCleanupCfg(self: *CEmitter) !void {
        if (self.currentMirFunction() == null or self.currentCleanupCfg() == null) return error.UnsupportedCEmission;
    }

    fn validateFunctionCleanupAuthority(self: *CEmitter) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        const cleanup_plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedCEmission;
        const cleanup_cfg = self.currentCleanupCfg() orelse return error.UnsupportedCEmission;
        if (!backend_cleanup.validateFunctionCleanupAuthority(self.mir_module, function, cleanup_plan, cleanup_cfg)) return error.UnsupportedCEmission;
    }

    fn emitCleanupRef(self: *CEmitter, ref: backend_cleanup.CleanupRef, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        switch (ref) {
            .defer_ref => |defer_ref| {
                const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
                const expr = self.deferExprForRef(defer_ref) orelse return error.UnsupportedCEmission;
                try self.writeLineDirective(expr.span);
                if (try self.ordinaryDeferDirectCallCleanup(function, expr, defer_ref)) |cleanup| {
                    try self.emitOrdinaryDeferDirectCallCleanup(cleanup, locals, return_ty);
                    return;
                }
                if (try self.ordinaryDeferCallTargetCleanup(function, expr, defer_ref)) |cleanup| {
                    try self.emitCallTargetDeferCleanup(cleanup, locals);
                    return;
                }
                switch (expr.kind) {
                    .block => |block| try self.emitBracedBlockBodyWithCleanup(block, locals, return_ty, false),
                    else => return error.UnsupportedCEmission,
                }
            },
            .ownership_action => |action_ref| {
                const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedCEmission;
                if (action_ref.cleanup_action_index >= plan.actions.len) return error.UnsupportedCEmission;
                switch (plan.actions[action_ref.cleanup_action_index].kind) {
                    .auto_drop => {
                        try self.writeLineDirective(spanFromSourcePoint(action_ref.source));
                        try self.emitAutoDropPointerCleanup(action_ref);
                    },
                    .explicit_drop => {
                        try self.writeLineDirective(spanFromSourcePoint(action_ref.source));
                        try self.emitExplicitDropPointerCleanup(action_ref);
                    },
                }
            },
        }
    }

    fn deferExprForRef(self: *CEmitter, ref: mir.DeferCleanupRef) ?ast_bridge.Expr {
        const function = self.currentMirFunction() orelse return null;
        if (!mir.deferCleanupRefValid(function.*, ref)) return null;
        return mir.deferCleanupExprForRef(function.*, ref);
    }

    fn ordinaryDeferDirectCallCleanup(self: *CEmitter, function: *const mir.Function, expr: ast_bridge.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedCEmission}!?backend_cleanup.OrdinaryDeferCallCleanup {
        const call = callExpr(expr) orelse return null;
        if (call.type_args.len != 0) return null;
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        if (info.is_variadic or call.args.len != info.params.len) return error.UnsupportedCEmission;
        if (!mir_source_bridge.directDeferCallCleanupForSpans(function.*, defer_ref, expr.span, call.callee.*.span, fn_name, call.args)) return error.UnsupportedCEmission;
        return .{ .defer_ref = defer_ref, .fn_name = fn_name, .span = expr.span, .callee_span = call.callee.*.span, .args = call.args };
    }

    fn ordinaryDeferCallTargetCleanup(self: *CEmitter, function: *const mir.Function, expr: ast_bridge.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedCEmission}!?backend_cleanup.CallTargetDeferCleanup {
        const call = callExpr(expr) orelse return null;
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
        if (!mir_source_bridge.callTargetDeferCleanupForSpans(function.*, defer_ref, expr.span, call.callee.*.span, kind)) return error.UnsupportedCEmission;
        return .{ .defer_ref = defer_ref, .kind = kind, .span = expr.span, .callee = call.callee.*, .callee_span = call.callee.*.span, .type_args = call.type_args, .args = call.args };
    }

    fn emitCallTargetDeferCleanup(self: *CEmitter, cleanup: backend_cleanup.CallTargetDeferCleanup, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!mir_source_bridge.callTargetDeferCleanupForSpans((self.currentMirFunction() orelse return error.UnsupportedCEmission).*, cleanup.defer_ref, cleanup.span, cleanup.callee_span, cleanup.kind)) return error.UnsupportedCEmission;
        if (cleanup.kind == .raw_store) {
            try self.emitRawStorePayload(cleanup.callee_span, cleanup.type_args, cleanup.args, locals);
            return;
        }
        if (cleanup.kind == .mmio_write) {
            if (!try lower_c_mmio.emitWriteCall(self.mmioEmitContext(), cleanup.callee, cleanup.args, locals)) return error.UnsupportedCEmission;
            return;
        }
        if (cleanup.kind == .mmio_read) {
            if (!try lower_c_mmio.emitReadCallStmt(self.mmioEmitContext(), cleanup.callee, cleanup.args, locals)) return error.UnsupportedCEmission;
            return;
        }
        if (cleanup.kind == .dma_cache_clean or cleanup.kind == .dma_cache_invalidate) {
            var callee_storage = cleanup.callee;
            const empty_type_args: []const ast_bridge.TypeExpr = &.{};
            const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = cleanup.args };
            try self.writeIndent();
            if (!try lower_c_memory.emitDmaCall(self.memoryContext(), call, locals)) return error.UnsupportedCEmission;
            try self.out.appendSlice(self.allocator, ";\n");
            return;
        }
        if (cleanup.kind == .maybe_uninit_write) {
            if (!try lower_c_memory.emitMaybeUninitWriteCall(self.memoryContext(), cleanup.callee, cleanup.args, locals)) return error.UnsupportedCEmission;
            return;
        }
        if (cleanup.kind == .atomic_store) {
            var callee_storage = cleanup.callee;
            const empty_type_args: []const ast_bridge.TypeExpr = &.{};
            const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = cleanup.args };
            try self.writeIndent();
            if (!try lower_c_atomic.emitAtomicCall(self.atomicEmitContext(), call, locals)) return error.UnsupportedCEmission;
            try self.out.appendSlice(self.allocator, ";\n");
            return;
        }
        if (cleanup.kind == .va_end) {
            var callee_storage = cleanup.callee;
            const empty_type_args: []const ast_bridge.TypeExpr = &.{};
            const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = cleanup.args };
            try self.writeIndent();
            if (!try lower_c_call.emitVaCall(self.callContext(), call, locals)) return error.UnsupportedCEmission;
            try self.out.appendSlice(self.allocator, ";\n");
            return;
        }
        const statement = switch (cleanup.kind) {
            .cpu_pause => "mc_cpu_pause",
            .fence_full => "mc_barrier_full",
            .fence_release => "mc_barrier_release_before",
            .fence_acquire => "mc_barrier_acquire_after",
            else => return error.UnsupportedCEmission,
        };
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}();\n", .{statement});
    }

    fn emitOrdinaryDeferDirectCallCleanup(self: *CEmitter, cleanup: backend_cleanup.OrdinaryDeferCallCleanup, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !void {
        _ = return_ty;
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        if (!mir_source_bridge.directDeferCallCleanupForSpans(function.*, cleanup.defer_ref, cleanup.span, cleanup.callee_span, cleanup.fn_name, cleanup.args)) return error.UnsupportedCEmission;
        const info = self.functions.get(cleanup.fn_name) orelse return error.UnsupportedCEmission;
        if (info.is_variadic or cleanup.args.len != info.params.len) return error.UnsupportedCEmission;
        if (cleanup.args.len == 0) {
            try self.writeIndent();
            try self.out.print(self.allocator, "{s}();\n", .{try self.cIdent(cleanup.fn_name)});
            self.applyMirPointerProvenanceInvalidationsAtCall(cleanup.span, locals);
            return;
        }
        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        for (cleanup.args, info.params) |arg, param| {
            try temps.append(self.scratch.allocator(), try self.emitSequencedCallArgTemp(arg, locals, param.ty));
        }
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}", .{try self.cIdent(cleanup.fn_name)});
        try lower_c_call.emitSequencedArgList(self.allocator, self.out, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        self.applyMirPointerProvenanceInvalidationsAtCall(cleanup.span, locals);
    }

    fn emitAutoDropPointerCleanup(self: *CEmitter, ref: mir_ownership_authority.OwnershipCleanupActionRef) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedCEmission;
        const cleanup = mir_ownership_authority.autoDropLocalCleanupFromActionRef(self.mir_module, function, plan, ref) orelse return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}(&{s});\n", .{ cleanup.fn_name, cleanup.local_name });
    }

    fn emitExplicitDropPointerCleanup(self: *CEmitter, ref: mir_ownership_authority.OwnershipCleanupActionRef) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        const plan = self.currentOwnershipCleanupPlan() orelse return error.UnsupportedCEmission;
        const cleanup = mir_ownership_authority.explicitDropLocalCleanupFromActionRef(self.mir_module, function, plan, ref) orelse return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}(&{s});\n", .{ cleanup.fn_name, cleanup.local_name });
    }

    fn writeIndent(self: *CEmitter) !void {
        for (0..self.indent) |_| try self.out.appendSlice(self.allocator, "    ");
    }

    fn writeLineDirective(self: *CEmitter, span: ast_bridge.Span) !void {
        try appendLineDirective(self.allocator, self.out, self.source_path, span);
    }

    fn reportUnsupported(self: *CEmitter, span: ast_bridge.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            reporter.err(span, "E_BACKEND_UNSUPPORTED: C backend does not yet support {s}", .{construct});
        }
    }

    fn writeUnsupportedStmt(self: *CEmitter, stmt: ast_bridge.Stmt) !void {
        self.reportUnsupported(stmt.span, @tagName(stmt.kind));
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "/* unsupported statement for C emission: {s} */\n",
            .{@tagName(stmt.kind)},
        );
        return error.UnsupportedCEmission;
    }

    fn emitMaterializedUninitInitializer(self: *CEmitter, ty: ast_bridge.TypeExpr) !void {
        try self.out.appendSlice(self.allocator, " = ");
        if (self.isAggregateGlobalType(ty)) {
            try self.out.appendSlice(self.allocator, "{0}");
        } else {
            try self.out.appendSlice(self.allocator, "0");
        }
    }

    // A pattern binding (re)binds its name in a nested scope the shared MIR
    // pointer-provenance map does not model. Drop any entry a disjoint sibling
    // scope may have left for the same name: a leaked .local_storage proof would
    // let the binding's derefs lower PLAIN unsoundly (the leaked .global analog
    // was merely conservative). Removal-only — after the arm the name stays
    // unknown, which is the conservative default.
    fn clearMirPointerProvenanceForPattern(self: *CEmitter, pattern: ast_bridge.Pattern) void {
        switch (pattern.kind) {
            .bind => |ident| _ = self.mir_pointer_local_provenance.remove(ident.text),
            .tag_bind => |tag_bind| _ = self.mir_pointer_local_provenance.remove(tag_bind.binding.text),
            else => {},
        }
    }

    fn emitSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const subject_info = try self.requireMirSwitchSubjectType(node.subject, locals);
        const subject_ty = subject_info.target_ty;
        for (node.arms) |arm| {
            for (arm.patterns) |pattern| self.clearMirPointerProvenanceForPattern(pattern);
        }
        if (self.resultTypeFromCandidate(subject_ty) != null) {
            if (try self.emitResultSwitch(node, locals, return_ty, subject_ty)) return;
            return error.UnsupportedCEmission;
        }
        if (self.nullableTypeFromCandidate(subject_ty) != null) {
            const representation = subject_info.nullable_representation orelse return error.UnsupportedCEmission;
            if (try self.emitNullableSwitch(node, locals, return_ty, subject_ty, representation)) return;
            return error.UnsupportedCEmission;
        }
        if (self.taggedUnionTypeFromType(subject_ty) != null) {
            if (try self.emitTaggedUnionSwitch(node, locals, return_ty)) return;
            return error.UnsupportedCEmission;
        }
        if (self.enumTypeFromCandidate(subject_ty) != null) {
            if (try self.emitEnumCallSwitch(node, locals, return_ty, subject_ty)) return;
        }

        try self.emitGenericSwitchWithMmioSubjectHoists(node, locals, return_ty, subject_ty);
    }

    fn emitEnumCallSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, enum_ty: ast_bridge.TypeExpr) anyerror!bool {
        _ = callExpr(node.subject) orelse return false;
        const temp = try self.emitSequencedCallArgTemp(node.subject, locals, enum_ty);

        var switch_locals = try cloneLocals(self.allocator, locals.*);
        defer switch_locals.deinit();
        try switch_locals.put(temp.name, try self.localInfoFromType(enum_ty));
        const temp_subject = ast_bridge.Expr{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span };
        try self.emitGenericSwitch(.{ .subject = temp_subject, .arms = node.arms }, &switch_locals, return_ty, enum_ty, &[_]MmioReadReplacement{});
        return true;
    }

    fn emitGenericSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr, subject_replacements: []const MmioReadReplacement) anyerror!void {
        const resolved_subject_ty = self.resolveAliasType(subject_ty);
        const subject_enum_name = self.enumNameFromCandidate(subject_ty);
        const subject_is_bool = isBoolType(resolved_subject_ty);
        try lower_c_switch.emitGenericSwitch(self.switchEmitContext(), .{
            .node = node,
            .locals = locals,
            .return_ty = return_ty,
            .subject_enum_name = subject_enum_name,
            .subject_is_bool = subject_is_bool,
            .subject_replacements = subject_replacements,
        });
    }

    fn emitGenericSwitchWithMmioSubjectHoists(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) anyerror!void {
        const resolved_subject_ty = self.resolveAliasType(subject_ty);
        const subject_enum_name = self.enumNameFromCandidate(subject_ty);
        const subject_is_bool = isBoolType(resolved_subject_ty);
        try lower_c_switch.emitGenericSwitchWithMmioSubjectHoists(self.switchEmitContext(), self.mmioEmitContext(), .{
            .node = node,
            .locals = locals,
            .return_ty = return_ty,
            .subject_enum_name = subject_enum_name,
            .subject_is_bool = subject_is_bool,
            .subject_replacements = &[_]MmioReadReplacement{},
        });
    }

    fn requireMirSwitchSubjectType(self: *CEmitter, subject: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !MirSubjectType {
        const known_ty = self.operandEmitType(subject, locals) orelse self.taggedUnionTypeForExpr(subject, locals);
        const fact = if (known_ty) |ty|
            self.mirTargetTypeFactMatchingType(.switch_subject, subject.span, ty)
        else
            self.mirTargetTypeFactAt(.switch_subject, subject.span);
        const subject_fact = fact orelse return error.UnsupportedCEmission;
        const fact_ty = subject_fact.target_ty;
        if (known_ty) |ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return .{
            .target_ty = fact_ty,
            .nullable_representation = if (self.nullableTypeFromCandidate(fact_ty) != null) try self.nullableRepresentationFromTargetFact(subject_fact) else null,
        };
    }

    fn emitResultSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr) anyerror!bool {
        const subject = (try lower_c_switch.resultSubjectForValueExprWithType(self.switchEmitContext(), node.subject, locals, subject_ty)) orelse return false;
        return lower_c_switch.emitResultSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitNullableSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, subject_ty: ast_bridge.TypeExpr, representation: NullableRepresentation) anyerror!bool {
        const subject = if (try lower_c_switch.nullableSubjectForExprWithType(self.switchEmitContext(), node.subject, locals, subject_ty, representation)) |subject|
            subject
        else
            return false;

        return lower_c_switch.emitNullableSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitTaggedUnionSwitch(self: *CEmitter, node: ast_bridge.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const subject = (try lower_c_switch.taggedUnionSubjectForValueExpr(self.switchEmitContext(), node.subject, locals)) orelse return false;
        return lower_c_switch.emitTaggedUnionSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitSwitchBody(self: *CEmitter, body: ast_bridge.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        switch (body) {
            .block => |block| try self.emitBlockItems(block, locals, return_ty),
            .expr => |expr| try self.emitExpressionStmt(expr, locals, return_ty),
        }
    }

    fn nullableTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .call => blk: {
                const ty = self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.nullableTypeFromCandidate(ty);
            },
            .cast => blk: {
                const ty = self.castResultTypeForEmission(expr) orelse break :blk null;
                break :blk self.nullableTypeFromCandidate(ty);
            },
            .grouped => |inner| blk: {
                const inferred = self.nullableTypeForExpr(inner.*, locals) orelse break :blk null;
                break :blk self.checkedExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            else => self.nullableExpressionResultTypeOrGenerated(expr, locals),
        };
    }

    fn nullableExpressionResultTypeOrGenerated(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| {
            return self.nullableTypeFromCandidate(fact.target_ty);
        }
        return self.generatedNullableExpressionTypeForEmission(expr, locals);
    }

    fn generatedNullableExpressionTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        // Source nullable expressions have MIR expression_result rows. The
        // declaration/local fallback is generated-only.
        if (isSourceSpan(expr.span)) return null;
        if (self.generatedNullableLocalTypeForEmission(expr, locals)) |ty| return ty;
        const inferred = self.operandEmitType(expr, locals) orelse blk: {
            if (self.exprSourceTypeForEmission(expr, locals)) |ty| break :blk ty;
            return null;
        };
        return self.nullableTypeFromCandidate(inferred);
    }

    fn nullableTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .nullable) ty else null;
    }

    fn nullablePayloadFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .nullable => |child| child.*,
            else => null,
        };
    }

    fn valueOptionalPayloadFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const child = self.nullablePayloadFromCandidate(ty) orelse return null;
        return if (lower_c_type.nullablePayloadIsValueType(&self.type_aliases, child)) child else null;
    }

    fn generatedNullableLocalTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        const local_set = locals orelse return null;
        const name = directLocalName(expr) orelse return null;
        const info = local_set.get(name) orelse return null;
        const ty = info.source_ty orelse return null;
        return self.nullableTypeFromCandidate(ty);
    }

    fn taggedUnionTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const ty = switch (expr.kind) {
            .call => self.taggedUnionCallCandidateTypeForEmission(expr, locals) orelse return null,
            .cast => self.castResultTypeForEmission(expr) orelse return null,
            .grouped => |inner| blk: {
                const inferred = self.taggedUnionTypeForExpr(inner.*, locals) orelse return null;
                break :blk self.checkedExpressionResultTypeForEmission(expr, inferred) orelse return null;
            },
            else => self.operandEmitType(expr, locals) orelse return null,
        };
        return self.taggedUnionTypeFromType(ty);
    }

    fn taggedUnionCallCandidateTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        // A qualified constructor `Union.variant(...)` is self-typed to its
        // owner, so an untyped `let t = Token.number(9)` infers `Token`.
        if (self.mirTargetTypeFactAt(.qualified_union_result, expr.span)) |fact| return fact.target_ty;
        const ret_ty = self.callResultTypeForEmission(expr, locals) orelse return null;
        return self.taggedUnionTypeFromType(ret_ty);
    }

    fn taggedUnionTypeFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const type_name = typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.tagged_unions.contains(type_name)) ty else null;
    }

    fn emitForLoop(self: *CEmitter, loop: ast_bridge.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const header = try lower_c_flow.forLoopHeader(self.flowEmitContext(), loop);
        const binding = header.binding;
        const iterable = header.iterable;
        const types = try self.requireMirForLoopTypes(iterable, locals);
        if (try lower_c_flow.emitForLoopSequencedIterable(self.flowEmitContext(), loop, iterable, types.iterable, locals, return_ty)) return;
        const iterable_array_ty = self.arrayTypeFromType(types.iterable);
        const element = try lower_c_flow.forLoopElementPlan(self.flowEmitContext(), iterable_array_ty, types.element);
        try lower_c_flow.emitForLoopWithElementPlan(self.flowEmitContext(), loop, binding, iterable, locals, return_ty, element);
    }

    fn requireMirForLoopTypes(self: *CEmitter, iterable: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !struct { iterable: ast_bridge.TypeExpr, element: ast_bridge.TypeExpr } {
        const iterable_ty = try self.requireMirForIterableTypeForEmission(iterable, locals);
        const element_ty = try self.requireMirForElementTypeForEmission(iterable);
        const expected_element = self.arrayOrSliceElementTypeFromCandidate(iterable_ty) orelse return error.UnsupportedCEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(expected_element))) return error.UnsupportedCEmission;
        return .{ .iterable = iterable_ty, .element = element_ty };
    }

    fn requireMirForIterableTypeForEmission(self: *CEmitter, iterable: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !ast_bridge.TypeExpr {
        return self.requireMirTargetTypeForEmission(.for_iterable, iterable, self.iterableTypeForExpr(iterable, locals));
    }

    fn requireMirForElementTypeForEmission(self: *CEmitter, iterable: ast_bridge.Expr) !ast_bridge.TypeExpr {
        return self.requireMirTargetTypeForEmission(.for_element, iterable, null);
    }

    fn iterableTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const ty = self.arrayOrSliceBaseTypeForEmission(expr, locals) orelse return null;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .array, .slice => ty,
            else => null,
        };
    }

    fn emitIfLet(self: *CEmitter, node: ast_bridge.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void {
        self.clearMirPointerProvenanceForPattern(node.pattern);
        const subject_info = try self.requireMirIfLetSubjectType(node.value, locals);
        const subject_ty = subject_info.target_ty;
        if (node.pattern.kind == .tag_bind) {
            _ = self.resultTypeFromCandidate(subject_ty) orelse return error.UnsupportedCEmission;
            const subject = (try lower_c_switch.resultSubjectForValueExprWithType(self.switchEmitContext(), node.value, locals, subject_ty)) orelse {
                self.reportUnsupported(node.value.span, "result if-let value");
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported result if-let value: {s} */\n", .{@tagName(node.value.kind)});
                return error.UnsupportedCEmission;
            };
            return lower_c_switch.emitResultIfLet(self.switchEmitContext(), node, locals, return_ty, subject);
        }

        if (self.nullableTypeFromCandidate(subject_ty) == null) return error.UnsupportedCEmission;
        const representation = subject_info.nullable_representation orelse return error.UnsupportedCEmission;
        const subject = (try lower_c_switch.nullableSubjectForExprWithType(self.switchEmitContext(), node.value, locals, subject_ty, representation)) orelse {
            self.reportUnsupported(node.value.span, "if-let value");
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let value: {s} */\n", .{@tagName(node.value.kind)});
            return error.UnsupportedCEmission;
        };
        try lower_c_switch.emitNullableIfLet(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn requireMirIfLetSubjectType(self: *CEmitter, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !MirSubjectType {
        const fact = self.mirTargetTypeFactAt(.if_let_subject, value.span) orelse return error.UnsupportedCEmission;
        const fact_ty = fact.target_ty;
        const known_ty = self.operandEmitType(value, locals);
        if (known_ty) |ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return .{
            .target_ty = fact_ty,
            .nullable_representation = if (self.nullableTypeFromCandidate(fact_ty) != null) try self.nullableRepresentationFromTargetFact(fact) else null,
        };
    }

    fn nullableRepresentationFromTargetFact(self: *CEmitter, fact: mir.TargetTypeFact) !NullableRepresentation {
        const from_fact: NullableRepresentation = switch (fact.result_ty) {
            .nullable_value => .value,
            .nullable_dyn_trait => .dyn_trait,
            .nullable_pointer => .pointer,
            else => return error.UnsupportedCEmission,
        };
        const expected = self.nullableRepresentationForTargetType(fact.target_ty) orelse return error.UnsupportedCEmission;
        if (from_fact != expected) return error.UnsupportedCEmission;
        return from_fact;
    }

    fn nullableRepresentationForTargetType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?NullableRepresentation {
        const child = self.nullablePayloadFromCandidate(ty) orelse return null;
        if (self.dynTraitNameFromCandidate(child) != null) return .dyn_trait;
        if (self.valueOptionalPayloadFromCandidate(ty) != null) return .value;
        return .pointer;
    }

    fn emitNeverExprStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "mc_trap_Unreachable();\n");
                return true;
            },
            .call => |node| {
                _ = self.trapHelperForCall(node) orelse return false;
                try self.writeIndent();
                if (!try lower_c_call.emitTrapCall(self.callContext(), node)) return error.UnsupportedCEmission;
                try self.out.appendSlice(self.allocator, ";\n");
                return true;
            },
            .grouped => |inner| return try self.emitNeverExprStmt(inner.*, locals),
            else => return false,
        }
    }

    fn trapHelperForCall(self: *CEmitter, call: anytype) ?[]const u8 {
        const call_span = call.callee.*.span;
        const kind = self.mirCallTargetKindAt(call_span) orelse return null;
        return mir.explicitTrapHelperForTarget(kind);
    }

    fn emitRawStoreStmt(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = callExpr(expr) orelse return false;
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind != .raw_store) return false;
        if (!syntax_bridge.isRawStoreCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedCEmission;
        try self.emitRawStorePayload(call_span, call.type_args, call.args, locals);
        return true;
    }

    fn emitRawStorePayload(self: *CEmitter, call_span: ast_bridge.Span, type_args: []const ast_bridge.TypeExpr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (type_args.len != 1 or args.len != 2) return error.UnsupportedCEmission;
        const address_ty = (self.mirTargetTypeFactAt(.raw_address, call_span) orelse return error.UnsupportedCEmission).target_ty;
        const payload_ty = (self.mirTargetTypeFactAt(.raw_payload, call_span) orelse return error.UnsupportedCEmission).target_ty;
        _ = self.mirTargetTypeFactAt(.raw_result, call_span) orelse return error.UnsupportedCEmission;
        const addr_temp = try self.emitSequencedCallArgTemp(args[0], locals, address_ty);
        const value_temp = try self.emitSequencedCallArgTemp(args[1], locals, payload_ty);
        try self.writeIndent();
        if (typeName(payload_ty)) |type_name| {
            if (rawScalarSuffix(type_name)) |suffix| {
                try self.out.print(self.allocator, "mc_raw_store_{s}({s}, {s});\n", .{ suffix, addr_temp.name, value_temp.name });
                return;
            }
        }
        // Aggregate (non-scalar) T: whole-object typed store, mirroring how
        // `raw.ptr<T>(addr)` + deref already lowers a struct assignment.
        try self.out.print(self.allocator, "*({s} *){s} = {s};\n", .{ try self.cTypeFor(payload_ty, .typedef_name), addr_temp.name, value_temp.name });
    }

    fn emitCpuPauseStmt(self: *CEmitter, expr: ast_bridge.Expr) !bool {
        const call = callExpr(expr) orelse return false;
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind != .cpu_pause) return false;
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "mc_cpu_pause();\n");
        return true;
    }

    // `fence.full()` / `fence.release()` / `fence.acquire()` lower to the
    // target-aware `__atomic_thread_fence` helpers (riscv `fence`, x86 `mfence`,
    // arm `dmb`), so explicit memory barriers are real CPU fences, not just
    // compiler barriers.
    fn emitFenceStmt(self: *CEmitter, expr: ast_bridge.Expr) !bool {
        const call = callExpr(expr) orelse return false;
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        const helper = switch (call_kind orelse return false) {
            .fence_full => "mc_barrier_full",
            .fence_release => "mc_barrier_release_before",
            .fence_acquire => "mc_barrier_acquire_after",
            else => return false,
        };
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}();\n", .{helper});
        return true;
    }

    // The read shadow hook for an ordinary (non-raw, non-global) scalar field/array load, or
    // null when no sanitizer profile selects one. Globals are instrumented in the `mc_race_*`
    // macro instead; raw.load on the raw macro. This covers the pointer/aggregate field & array
    // LOAD path so a UAF/OOB reached through a field or element traps — matching lower_llvm.zig.
    fn ordinaryLoadHookName(self: *const CEmitter) ?[]const u8 {
        if (self.suppress_load_hook) return null;
        if (self.csan) return "mc_csan_read";
        if (self.ksan) return "mc_ksan_check"; // msan implies ksan
        return null;
    }

    fn ordinaryStorePreHookName(self: *const CEmitter) ?[]const u8 {
        if (self.msan) return "mc_ksan_store";
        if (self.ksan) return "mc_ksan_check";
        return null;
    }

    fn emitOrdinaryHookedAssignmentStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        const hook = self.ordinaryStorePreHookName() orelse return false;
        if (!ordinaryStoreHookTarget(target)) return false;
        const target_ty = self.operandEmitType(target, locals) orelse return false;
        const target_c_ty = try self.cTypeFor(target_ty, .typedef_name);
        const value_temp = try self.emitSequencedCallArgTemp(value, locals.?, target_ty);
        const ptr_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_storep{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} *{s} = &(", .{ target_c_ty, ptr_temp });
        try self.emitAddressOperand(target, locals);
        try self.out.appendSlice(self.allocator, ");\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}((uintptr_t){s}, (uintptr_t)sizeof(*{s}));\n", .{ hook, ptr_temp, ptr_temp });
        try self.writeIndent();
        try self.out.print(self.allocator, "*{s} = {s};\n", .{ ptr_temp, value_temp.name });
        return true;
    }

    fn ordinaryStoreHookTarget(target: ast_bridge.Expr) bool {
        return switch (target.kind) {
            .member, .index => true,
            .grouped => |inner| ordinaryStoreHookTarget(inner.*),
            else => false,
        };
    }

    // Emit an assignment LHS (a store target / lvalue). Identical to emitExpr but with the
    // field-LOAD shadow hook suppressed: wrapping an lvalue in a `(hook(...), lv)` comma
    // expression would make it non-assignable. Store hooks for member/index lvalues are emitted
    // through a temporary pointer by emitOrdinaryHookedAssignmentStmt.
    fn emitAssignTarget(self: *CEmitter, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const prev = self.suppress_load_hook;
        self.suppress_load_hook = true;
        defer self.suppress_load_hook = prev;
        try self.emitExpr(target, locals);
    }

    fn emitExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        self.emitExprInner(expr, locals) catch |err| switch (err) {
            error.UnsupportedCEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprInner(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| try self.emitIdentExpr(ident, locals),
            .int_literal, .float_literal, .char_literal, .bool_literal, .null_literal, .void_literal => try self.emitScalarLiteralExpr(expr),
            .array_literal => try self.emitUnsupportedTargetlessAggregateExpr(expr, "array"),
            .struct_literal => try self.emitUnsupportedTargetlessAggregateExpr(expr, "struct"),
            .grouped => |inner| try self.emitGroupedExpr(inner.*, locals),
            .move_expr => |inner| {
                try self.emitExpr(inner.*, locals);
            },
            .unreachable_expr => try self.out.appendSlice(self.allocator, "mc_trap_Unreachable()"),
            .unary => try lower_c_expr.emitUnaryExpr(self.exprEmitContext(), expr, locals),
            .binary => try lower_c_expr.emitBinaryExpr(self.exprEmitContext(), expr, locals),
            .call => |node| try self.emitCallExpr(expr, node, locals),
            .index => |node| try self.emitIndexExpr(node, expr.span, locals),
            .slice => |node| try self.emitSliceExpr(node, expr.span, locals),
            .address_of => |inner| try self.emitAddressOfExpr(inner.*, locals),
            .borrow_expr => |node| try self.emitAddressOfExpr(node.value.*, locals),
            .deref => |inner| try self.emitDerefExpr(inner.*, expr.span, locals),
            .member => |node| try self.emitMemberExprOrFallback(node, expr.span, locals),
            .cast => |node| try self.emitCastExpr(expr.span, node, locals),
            else => try self.emitUnsupportedExpr(expr),
        }
    }

    fn emitUnsupportedTargetlessAggregateExpr(self: *CEmitter, expr: ast_bridge.Expr, kind: []const u8) !void {
        self.reportUnsupported(expr.span, kind);
        try self.out.print(self.allocator, "/* unsupported targetless {s} literal */0", .{kind});
        return error.UnsupportedCEmission;
    }

    fn emitCallExpr(self: *CEmitter, expr: ast_bridge.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        self.applyMirPointerProvenanceInvalidationsAtCall(expr.span, locals);
        if (try self.emitSpecialCallExpr(node, locals)) return;
        try self.emitDefaultCallExpr(node, locals);
    }

    fn emitMemberExprOrFallback(self: *CEmitter, node: anytype, member_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (try self.emitMemberExpr(node, member_span, locals)) return;
    }

    fn emitUnsupportedExpr(self: *CEmitter, expr: ast_bridge.Expr) !void {
        self.reportUnsupported(expr.span, @tagName(expr.kind));
        try self.out.print(self.allocator, "/* unsupported expr: {s} */0", .{@tagName(expr.kind)});
        return error.UnsupportedCEmission;
    }

    fn reportUnsupportedIfNone(self: *CEmitter, span: ast_bridge.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            if (!reporter.has_errors) {
                reporter.err(span, "E_BACKEND_UNSUPPORTED: C backend does not yet support {s}", .{construct});
            }
        }
    }

    fn emitIdentExpr(self: *CEmitter, ident: ast_bridge.Ident, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (locals) |local_set| {
            if (!local_set.contains(ident.text)) {
                if (self.globals.get(ident.text)) |global| {
                    try appendGlobalLoadExpr(self.allocator, self.out, ident.text, global);
                    return;
                }
            }
        }
        try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
    }

    fn emitScalarLiteralExpr(self: *CEmitter, expr: ast_bridge.Expr) !void {
        switch (expr.kind) {
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .float_literal => |literal| try appendCFloatLiteral(self.allocator, self.out, literal, false),
            .char_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .null_literal => try self.out.appendSlice(self.allocator, "NULL"),
            .void_literal => try self.out.appendSlice(self.allocator, "0"),
            else => unreachable,
        }
    }

    fn emitGroupedExpr(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(inner, locals);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitAddressOfExpr(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.appendSlice(self.allocator, "&");
        try self.emitAddressOperand(inner, locals);
    }

    fn emitDerefExpr(self: *CEmitter, inner: ast_bridge.Expr, deref_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const inferred_pointee_ty = self.derefPointeeType(inner, locals) orelse return error.UnsupportedCEmission;
        const pointee_ty = (self.mirTargetTypeFactAt(.expression_result, deref_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(pointee_ty), self.resolveAliasType(inferred_pointee_ty))) return error.UnsupportedCEmission;
        switch (try self.derefAccessLoweringForPointee(inner, pointee_ty, locals)) {
            .plain => {
                try self.out.appendSlice(self.allocator, "*");
                try self.emitExpr(inner, locals);
            },
            .race_scalar => |info| {
                try self.out.print(self.allocator, "(({s})mc_race_load_{s}(", .{ info.c_type, info.race_type_name });
                try self.emitExpr(inner, locals);
                try self.out.appendSlice(self.allocator, "))");
            },
            .race_pointer => |info| {
                try self.out.print(self.allocator, "(({s})__atomic_load_n(", .{info.c_type});
                try self.emitExpr(inner, locals);
                try self.out.appendSlice(self.allocator, ", __ATOMIC_RELAXED))");
            },
        }
    }

    fn emitRaceLoadTempForAccess(ctx: *anyopaque, ptr_name: []const u8, target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitRaceLoadTempFromPointerTemp(ptr_name, target_ty);
    }

    fn emitRaceLoadTempFromPointerTemp(self: *CEmitter, ptr_name: []const u8, target_ty: ast_bridge.TypeExpr) !?SequencedArgTemp {
        const info = self.globalInfoFromType(target_ty) catch return null;
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        if (info.aggregate) {
            try self.out.print(self.allocator, "{s} {s} = ", .{ info.c_type, temp_name });
            try self.emitRaceTolerantAggregateLoadFromPtr(ptr_name, target_ty);
            try self.out.appendSlice(self.allocator, ";\n");
        } else if (info.pointer_like) {
            try self.out.print(self.allocator, "{s} {s} = ({s})__atomic_load_n({s}, __ATOMIC_RELAXED);\n", .{
                info.c_type,
                temp_name,
                info.c_type,
                ptr_name,
            });
        } else {
            if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
            try self.out.print(self.allocator, "{s} {s} = ({s})mc_race_load_{s}({s});\n", .{
                info.c_type,
                temp_name,
                info.c_type,
                info.race_type_name,
                ptr_name,
            });
        }
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitCastExpr(self: *CEmitter, span: ast_bridge.Span, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const source_fact = self.mirTargetTypeFactAt(.explicit_cast_source, span) orelse return error.UnsupportedCEmission;
        const target_fact = self.mirTargetTypeFactAt(.explicit_cast_target, span) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(target_fact.target_ty, .typedef_name)});
        try self.emitExprWithTarget(node.value.*, locals, source_fact.target_ty);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitIndexExpr(self: *CEmitter, node: anytype, index_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (locals) |local_set| {
            if (self.overlayIndexResultType(node, local_set)) |inferred_element_ty| {
                const element_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
                if (try self.emitOverlayIndexReadExpr(node, local_set)) return;
                return error.UnsupportedCEmission;
            }
        }
        const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
        const inferred_element_ty = self.arrayOrSliceElementTypeFromCandidate(base_ty) orelse return error.UnsupportedCEmission;
        const element_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
        if (locals) |local_set| {
            if (try self.emitOverlayIndexReadExpr(node, local_set)) return;
        }
        if (globalArrayElementAccess(node, locals, &self.globals)) |access| {
            try lower_c_global.emitGlobalArrayElementLoadExpr(self.globalArrayAccessEmitContext(), access, locals);
        } else if (self.sliceAccessForBase(node.base.*, locals)) |slice| {
            if (!try self.emitRaceTolerantSliceIndexExpr(node, locals, slice, element_ty)) {
                try self.emitSliceIndexExpr(node, locals, slice);
            }
        } else if (self.arrayTypeForExpr(node.base.*, locals)) |base_arr| {
            if (!try self.emitRaceTolerantPointerArrayIndexExpr(node, locals, base_arr)) {
                try self.emitArrayIndexExpr(node, locals, base_arr);
            }
        } else {
            try self.emitExpr(node.base.*, locals);
            try self.out.appendSlice(self.allocator, "[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
        }
    }

    fn emitSliceIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), slice: SliceAccess) anyerror!void {
        try self.requireMirBoundsFact(.index, node.index.span);
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
        try self.emitExpr(node.index.*, locals);
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
    }

    fn emitArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast_bridge.TypeExpr) anyerror!void {
        try self.emitArrayIndexBase(node.base.*, locals);
        if (self.mirCheckElided(node.index.span)) {
            try self.out.appendSlice(self.allocator, ".elems[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
            return;
        }
        try self.requireMirBoundsFact(.index, node.index.span);
        try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
        try self.emitExpr(node.index.*, locals);
        const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
        try self.out.print(self.allocator, ", {s})]", .{len});
    }

    // A deref base (`pa.*[i]`) must parenthesize so `.elems` binds to the deref
    // result: `(*pa).elems[...]`, not `*pa.elems[...]`.
    fn emitArrayIndexBase(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (base.kind == .deref) {
            try self.out.appendSlice(self.allocator, "(");
            try self.emitExpr(base, locals);
            try self.out.appendSlice(self.allocator, ")");
            return;
        }
        try self.emitExpr(base, locals);
    }

    fn emitMemberExpr(self: *CEmitter, node: anytype, member_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try self.emitEnumVariantPath(node, locals)) return true;
        if (self.sliceAccessForBase(node.base.*, locals)) |slice| {
            const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
            if (self.sliceTypeFromCandidate(base_ty) != null and std.mem.eql(u8, node.name.text, "len")) {
                const usize_ty = simpleNameType("usize", member_span);
                const field_ty = self.memberResultTypeOrGenerated(member_span, usize_ty) orelse return error.UnsupportedCEmission;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(usize_ty))) return error.UnsupportedCEmission;
                try self.emitExpr(node.base.*, locals);
                try self.out.print(self.allocator, ".{s}", .{slice.len_field});
                return true;
            }
        }
        if (try self.emitPackedBitsMember(node, member_span, locals)) return true;
        if (locals) |local_set| {
            if (self.overlayMemberResultType(node, local_set)) |inferred_field_ty| {
                const field_ty = self.memberResultTypeOrGenerated(member_span, inferred_field_ty) orelse return error.UnsupportedCEmission;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
            }
            if (try self.emitOverlayMemberReadExpr(node, local_set)) return true;
        }
        if (try self.emitGlobalArrayElementMemberLoadExpr(node, locals)) return true;
        if (lower_c_global.globalMemberAccess(self.globalAccessContext(), node, locals)) |access| {
            try appendGlobalLoadExpr(self.allocator, self.out, access.name, access.info);
            return true;
        }
        if (try self.emitRaceTolerantIndexedMemberLoadExpr(node, locals)) return true;
        if (try self.emitRaceTolerantNestedIndexedMemberLoadExpr(node, locals)) return true;
        if (try self.emitRaceTolerantPointerMemberLoadExpr(node, locals)) return true;
        if (!self.suppress_load_hook and try self.emitRaceTolerantNestedPointerMemberLoadExpr(node, locals)) return true;
        if (self.memberChainHasRaceTolerantIndexedBase(node.base.*, locals)) return error.UnsupportedCEmission;
        const inferred_field_ty = self.memberFieldType(node.base.*, node.name.text, locals) orelse return error.UnsupportedCEmission;
        // Async lowering synthesizes state-machine member expressions after source
        // parsing. They deliberately carry the zero span and have no source-keyed
        // MIR fact; the generated struct declaration remains the typed authority.
        // User-source members still require the exact expression-result fact.
        const field_ty = self.memberResultTypeOrGenerated(member_span, inferred_field_ty) orelse return error.UnsupportedCEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
        try self.emitOrdinaryMemberLoadExpr(node, locals);
        return true;
    }

    fn memberResultTypeOrGenerated(self: *CEmitter, member_span: ast_bridge.Span, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, member_span)) |fact| return fact.target_ty;
        return generatedMemberResultTypeForEmission(member_span, inferred);
    }

    fn generatedMemberResultTypeForEmission(member_span: ast_bridge.Span, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (isSourceSpan(member_span)) return null;
        return inferred;
    }

    fn overlayMemberResultType(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const overlay_name = lower_c_access.overlayUnionNameForExpr(node.base.*, locals) orelse return null;
        const info = self.overlay_unions.get(overlay_name) orelse return null;
        const field = info.fields.get(node.name.text) orelse return null;
        if (field.byte_array_len != null or type_bridge.overlayArrayElementType(field.ty) != null) return null;
        return field.ty;
    }

    fn overlayIndexResultType(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const member = syntax_bridge.overlayMemberFromIndexBase(node.base.*) orelse return null;
        const overlay_name = lower_c_access.overlayUnionNameForExpr(member.base.*, locals) orelse return null;
        const info = self.overlay_unions.get(overlay_name) orelse return null;
        const field = info.fields.get(member.name.text) orelse return null;
        return type_bridge.overlayArrayElementType(field.ty);
    }

    // A variant-path literal `Enum.variant` used as a value emits the enum's case
    // constant (`Enum_variant`), exactly like the `.variant` enum literal does. The
    // base must name an enum TYPE (not a local/global value shadowing it), and the
    // member must be one of its cases.
    fn emitEnumVariantPath(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        const base_ident = switch (node.base.*.kind) {
            .ident => |id| id,
            else => return false,
        };
        if (locals) |local_set| {
            if (local_set.contains(base_ident.text)) return false;
        }
        if (self.globals.contains(base_ident.text)) return false;
        const enum_decl = self.enums.get(base_ident.text) orelse return false;
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, node.name.text)) {
                try self.out.print(self.allocator, "{s}_{s}", .{ base_ident.text, node.name.text });
                return true;
            }
        }
        return false;
    }

    fn emitOrdinaryMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const op: []const u8 = if (self.exprHasPointerType(node.base.*, locals)) "->" else ".";
        const field_name = try self.cIdent(node.name.text);
        if (self.ordinaryLoadHookName()) |hook| {
            try self.emitHookedMemberLoadExpr(node, locals, hook, op, field_name);
            return;
        }
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s}", .{ op, field_name });
    }

    fn emitRaceTolerantPointerMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        if (!self.exprHasPointerType(node.base.*, locals)) return false;
        const field_ty = self.memberFieldType(node.base.*, node.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (info.aggregate) return false;
        const field_name = try self.cIdent(node.name.text);
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            try self.emitExpr(node.base.*, locals);
            try self.out.print(self.allocator, "->{s}), __ATOMIC_RELAXED))", .{field_name});
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "->{s})))", .{field_name});
        return true;
    }

    const PointerMemberPath = struct {
        root: ast_bridge.Expr,
        fields: []const []const u8,
    };

    fn collectPointerMemberPath(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?ast_bridge.Expr {
        switch (expr.kind) {
            .member => |node| {
                const root = try self.collectPointerMemberPath(node.base.*, locals, fields) orelse return null;
                try fields.append(self.allocator, node.name.text);
                return root;
            },
            .grouped => |wrapped| return try self.collectPointerMemberPath(wrapped.*, locals, fields),
            else => return if (self.exprHasPointerType(expr, locals)) expr else null,
        }
    }

    fn pointerMemberPath(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?PointerMemberPath {
        const root = try self.collectPointerMemberPath(expr, locals, fields) orelse return null;
        if (fields.items.len <= 1) return null;
        return .{ .root = root, .fields = fields.items };
    }

    fn pointerMemberPathFinalType(self: *CEmitter, root: ast_bridge.Expr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        var current = self.memberBaseTypeForEmission(root, locals) orelse return null;
        for (fields) |field_name| current = self.memberFieldTypeFromAggregate(current, field_name) orelse return null;
        return current;
    }

    fn emitPointerMemberPathAddressExpr(self: *CEmitter, root: ast_bridge.Expr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.emitExpr(root, locals);
        if (fields.len == 0) return;
        try self.out.print(self.allocator, "->{s}", .{try self.cIdent(fields[0])});
        for (fields[1..]) |field_name| try self.out.print(self.allocator, ".{s}", .{try self.cIdent(field_name)});
    }

    fn pointerMemberPathPtrExpr(self: *CEmitter, root_name: []const u8, fields: []const []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.scratch.allocator(), "&(");
        try out.appendSlice(self.scratch.allocator(), root_name);
        if (fields.len != 0) {
            try out.print(self.scratch.allocator(), "->{s}", .{try self.cIdent(fields[0])});
            for (fields[1..]) |field_name| try out.print(self.scratch.allocator(), ".{s}", .{try self.cIdent(field_name)});
        }
        try out.appendSlice(self.scratch.allocator(), ")");
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn emitRaceTolerantNestedPointerMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const path = try self.pointerMemberPath(.{ .span = node.name.span, .kind = .{ .member = node } }, locals, &fields) orelse return false;
        const field_ty = self.pointerMemberPathFinalType(path.root, path.fields, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (info.aggregate) {
            if (self.derefPointerHasProvenLocalStorage(path.root, locals)) return false;
            return error.UnsupportedCEmission;
        }
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            try self.emitPointerMemberPathAddressExpr(path.root, path.fields, locals);
            try self.out.appendSlice(self.allocator, "), __ATOMIC_RELAXED))");
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        try self.emitPointerMemberPathAddressExpr(path.root, path.fields, locals);
        try self.out.appendSlice(self.allocator, ")))");
        return true;
    }

    fn emitIndexedMemberAddressExpr(self: *CEmitter, index: syntax_bridge.IndexExpr, field_name: []const u8, locals: ?*std.StringHashMap(LocalInfo), index_temp: ?[]const u8) anyerror!bool {
        if (self.sliceAccessForBase(index.base.*, locals)) |slice| {
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
            if (index_temp) |temp| {
                try self.out.appendSlice(self.allocator, temp);
            } else {
                try self.emitExpr(index.index.*, locals);
            }
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})].{s}", .{ slice.len_field, field_name });
            return true;
        }
        const base_arr = self.arrayTypeForExpr(index.base.*, locals) orelse return false;
        _ = self.pointerArrayDerefInner(index.base.*, locals) orelse return false;
        try self.emitPointerArrayIndexExpr(index, locals, base_arr, index_temp);
        try self.out.print(self.allocator, ".{s}", .{field_name});
        return true;
    }

    fn collectIndexedMemberPath(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?syntax_bridge.IndexExpr {
        switch (expr.kind) {
            .member => |node| {
                const index = try self.collectIndexedMemberPath(node.base.*, locals, fields) orelse return null;
                try fields.append(self.allocator, node.name.text);
                return index;
            },
            .grouped => |wrapped| return try self.collectIndexedMemberPath(wrapped.*, locals, fields),
            else => return indexExpr(expr),
        }
    }

    fn indexedElementType(self: *CEmitter, index: syntax_bridge.IndexExpr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const base_ty = self.arrayOrSliceBaseTypeForEmission(index.base.*, locals) orelse return null;
        return self.arrayOrSliceElementTypeFromCandidate(base_ty);
    }

    fn indexedMemberPathFinalType(self: *CEmitter, index: syntax_bridge.IndexExpr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        var current = self.indexedElementType(index, locals) orelse return null;
        for (fields) |field_name| current = self.memberFieldTypeFromAggregate(current, field_name) orelse return null;
        return current;
    }

    fn emitIndexedMemberPathAddressExpr(self: *CEmitter, index: syntax_bridge.IndexExpr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo), index_temp: ?[]const u8) anyerror!bool {
        if (fields.len == 0) return false;
        if (!try self.emitIndexedMemberAddressExpr(index, try self.cIdent(fields[0]), locals, index_temp)) return false;
        for (fields[1..]) |field_name| try self.out.print(self.allocator, ".{s}", .{try self.cIdent(field_name)});
        return true;
    }

    fn indexedMemberHasRaceTolerantStorage(self: *CEmitter, index: syntax_bridge.IndexExpr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (self.sliceAccessForBase(index.base.*, locals) != null) return true;
        if (self.arrayTypeForExpr(index.base.*, locals) != null and self.pointerArrayDerefInner(index.base.*, locals) != null) return true;
        return false;
    }

    fn memberChainHasRaceTolerantIndexedBase(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        switch (expr.kind) {
            .member => |node| return self.memberChainHasRaceTolerantIndexedBase(node.base.*, locals),
            .grouped => |wrapped| return self.memberChainHasRaceTolerantIndexedBase(wrapped.*, locals),
            else => {},
        }
        const index = indexExpr(expr) orelse return false;
        return self.indexedMemberHasRaceTolerantStorage(index, locals);
    }

    fn emitRaceTolerantIndexedMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        const index = indexExpr(node.base.*) orelse return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.memberFieldType(node.base.*, node.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (info.aggregate) return false;
        const field_name = try self.cIdent(node.name.text);
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            if (!try self.emitIndexedMemberAddressExpr(index, field_name, locals, null)) return false;
            try self.out.appendSlice(self.allocator, "), __ATOMIC_RELAXED))");
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        if (!try self.emitIndexedMemberAddressExpr(index, field_name, locals, null)) return false;
        try self.out.appendSlice(self.allocator, ")))");
        return true;
    }

    fn emitRaceTolerantNestedIndexedMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const index = try self.collectIndexedMemberPath(.{ .span = node.name.span, .kind = .{ .member = node } }, locals, &fields) orelse return false;
        if (fields.items.len <= 1) return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.indexedMemberPathFinalType(index, fields.items, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (info.aggregate) return error.UnsupportedCEmission;
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, null)) return false;
            try self.out.appendSlice(self.allocator, "), __ATOMIC_RELAXED))");
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, null)) return false;
        try self.out.appendSlice(self.allocator, ")))");
        return true;
    }

    fn emitHookedMemberLoadExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), hook: []const u8, op: []const u8, field_name: []const u8) anyerror!void {
        try self.out.print(self.allocator, "({s}((uintptr_t)&(", .{hook});
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s}), (uintptr_t)sizeof(", .{ op, field_name });
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s})), ", .{ op, field_name });
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s})", .{ op, field_name });
    }

    fn emitSpecialCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_call.emitTrapCall(self.callContext(), node)) return true;
        // `Union.variant(...)` qualified constructor — self-typed from the owner.
        if (self.mirTargetTypeFactAt(.qualified_union_result, node.callee.*.span)) |fact| {
            if (try lower_c_aggregate.emitQualifiedUnionConstructor(self.aggregateEmitContext(), node, locals, fact.target_ty)) return true;
            return error.UnsupportedCEmission;
        }
        if (self.mirHasCallTargetKindAt(.atomic_init, node.callee.*.span)) return error.UnsupportedCEmission;
        if (try self.emitNamedSpecialCallExpr(node, locals)) return true;
        // Tier 2 dynamic dispatch: `d.method(args)` through a `*dyn Trait` ->
        // `d.vtable->method(d.data, args)` (a genuine load-through-vtable call).
        if (self.dynCalleeTrait(node.callee.*, locals)) |trait_name| {
            const method_index = self.dynDispatchMethodIndex(node.callee.*, trait_name) orelse return error.UnsupportedCEmission;
            try lower_c_dispatch.emitDynDispatch(self.dispatchContext(), node, trait_name, method_index, locals);
            return true;
        }
        // Calling a closure-typed value: `c(args)` -> `c.code(c.env, args)`.
        if (self.closureCalleeType(node.callee.*, locals)) |clos| {
            try lower_c_dispatch.emitClosureCall(self.dispatchContext(), node, clos, locals);
            return true;
        }
        if (self.indirectCallCalleeType(node.callee.*)) |callee_ty| switch (callee_ty.kind) {
            .fn_pointer => {},
            .closure_type => unreachable,
            else => return error.UnsupportedCEmission,
        };
        if (try lower_c_call.emitRawAddressCall(self.callContext(), node, locals)) return true;
        if (try lower_c_call.emitVaCall(self.callContext(), node, locals)) return true;
        if (try lower_c_builtin_emit.emitBuiltinCallExpr(self.builtinEmitContext(), node, locals)) return true;
        return false;
    }

    fn emitNamedSpecialCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        // `drop(x)` and `forget_unchecked(x)` both evaluate and discard the
        // operand (linearity is a compile-time check). The difference is in the
        // checker: `forget_unchecked` is the only one legal on a resource.
        if (try lower_c_call.emitNamedDiscardCall(self.callContext(), node, locals)) return true;
        // `bind(&env, f)` builds a closure: a {code, env} fat value. The
        // env pointer is type-erased to void* and the function pointer
        // (whose first param is the typed env) is cast to take void* —
        // both casts are ABI-identity, so user code stays typed/cast-free.
        if (self.mirHasCallTargetKindAt(.bind, node.callee.*.span)) {
            const fact = self.mirTargetTypeFactAt(.bind, node.callee.*.span) orelse return error.UnsupportedCEmission;
            try self.emitBind(node, locals, fact.target_ty);
            return true;
        }
        if (self.mirTargetTypeFactAt(.bind, node.callee.*.span) != null) return error.UnsupportedCEmission;
        return false;
    }

    fn emitDefaultCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const fn_name = calleeIdentName(node.callee.*);
        const fn_info = if (fn_name) |name| self.functions.get(name) else null;
        try self.emitExpr(node.callee.*, locals);
        try self.out.appendSlice(self.allocator, "(");
        for (node.args, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const target_ty = if (fn_info) |info|
                if (i < info.params.len) blk: {
                    const fact_ty = (self.mirTargetTypeFactAtOwned(.direct_call_argument, arg.span, fn_name.?, i) orelse return error.UnsupportedCEmission).target_ty;
                    if (!std.meta.eql(fact_ty, info.params[i].ty)) return error.UnsupportedCEmission;
                    break :blk fact_ty;
                } else null
            else
                null;
            try self.emitExprWithTarget(arg, locals, target_ty);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitAddressOperand(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (!local_set.contains(ident.text) and self.globals.contains(ident.text)) {
                        try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
            },
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitAddressOperand(inner.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .index => |node| try self.emitIndexAddressOperand(node, locals),
            .member => |node| try self.emitMemberAddressOperand(node, locals),
            else => try self.emitExpr(expr, locals),
        }
    }

    fn emitIndexAddressOperand(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (self.sliceAccessForBase(node.base.*, locals)) |slice| {
            try self.emitSliceIndexAddressOperand(node, locals, slice);
        } else if (self.arrayTypeForExpr(node.base.*, locals)) |base_arr| {
            try self.emitArrayIndexAddressOperand(node, locals, base_arr);
        } else {
            try self.emitAddressOperand(node.base.*, locals);
            try self.out.appendSlice(self.allocator, "[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
        }
    }

    fn emitSliceIndexAddressOperand(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), slice: SliceAccess) anyerror!void {
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
        try self.emitExpr(node.index.*, locals);
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
    }

    fn emitArrayIndexAddressOperand(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast_bridge.TypeExpr) anyerror!void {
        // Mirrors the value-read path so `&arr[i]` and `arr[i]` agree.
        if (node.base.*.kind == .deref) {
            // `&pa.*[i]` — parenthesize the deref so `.elems` binds to its result.
            try self.emitArrayIndexBase(node.base.*, locals);
        } else try self.emitAddressOperand(node.base.*, locals);
        if (locals == null) {
            try self.emitStaticArrayIndexAddress(node);
            return;
        }
        const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
        try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
        try self.emitExpr(node.index.*, locals);
        try self.out.print(self.allocator, ", {s})]", .{len});
    }

    fn emitStaticArrayIndexAddress(self: *CEmitter, node: anytype) anyerror!void {
        try self.out.appendSlice(self.allocator, ".elems[");
        const static_index = staticCInitializer(node.index.*, &self.static_initializers, &self.functions, self.scratch.allocator()) orelse node.index.*;
        if (!try emitStaticCInitializer(self.allocator, self.out, static_index)) try self.emitExpr(static_index, null);
        try self.out.appendSlice(self.allocator, "]");
    }

    fn emitMemberAddressOperand(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const op: []const u8 = if (self.exprIsPointer(node.base.*, locals)) "->" else ".";
        try self.emitAddressOperand(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s}", .{ op, try self.cIdent(node.name.text) });
    }

    fn underlyingIntTypeName(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return lower_c_info.underlyingIntTypeName(self.infoContext(), ty);
    }

    fn emitExprWithTarget(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        self.emitExprWithTargetInner(expr, locals, target_ty) catch |err| switch (err) {
            error.UnsupportedCEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprWithTargetInner(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        const semantic_target_ty = if (expr.kind == .null_literal)
            self.nullLiteralTargetTypeForEmission(expr, target_ty) orelse return error.UnsupportedCEmission
        else
            target_ty;
        if (try self.emitRaceTolerantAggregateDerefExpr(expr, locals, semantic_target_ty)) return;
        if (try self.emitRaceTolerantPointerMemberAggregateExpr(expr, locals, semantic_target_ty)) return;
        if (try self.emitRaceTolerantNestedPointerMemberAggregateExpr(expr, locals, semantic_target_ty)) return;
        if (try self.emitRaceTolerantIndexedMemberAggregateExpr(expr, locals, semantic_target_ty)) return;
        if (try self.ambiguousAggregateDerefValueCopy(expr, locals)) return error.UnsupportedCEmission;
        if (try self.ambiguousPointerMemberAggregateValueCopy(expr, locals)) return error.UnsupportedCEmission;
        if (try self.ambiguousIndexedMemberAggregateValueCopy(expr, locals)) return error.UnsupportedCEmission;
        if (try self.emitValueOptionalCoercion(expr, locals, semantic_target_ty)) return;
        if (try self.emitPointerToPAddrTargetCast(expr, locals, semantic_target_ty)) return;
        if (try self.emitTargetPreludeExpr(expr, locals, semantic_target_ty)) return;
        switch (expr.kind) {
            .array_literal, .struct_literal => try self.emitAggregateLiteralWithTarget(expr, locals),
            .binary, .unary => try self.emitArithmeticExprWithTarget(expr, locals, semantic_target_ty),
            .call => |node| try self.emitTargetCallExpr(node, locals, semantic_target_ty, expr),
            .enum_literal => |literal| try self.emitEnumLiteralWithTarget(literal, expr.span),
            .string_literal => |literal| try self.emitStringLiteralWithTarget(literal, expr.span),
            .float_literal => |literal| try self.emitFloatLiteralWithTarget(literal, expr.span),
            .char_literal => |literal| try self.emitCharLiteralWithTarget(literal, expr.span, semantic_target_ty),
            .grouped => |inner| try self.emitGroupedExprWithTarget(inner.*, locals, semantic_target_ty),
            .move_expr => |inner| {
                try self.emitExprWithTarget(inner.*, locals, semantic_target_ty);
            },
            .address_of => try self.emitAddressOfExprWithTarget(expr, locals, semantic_target_ty),
            else => try self.emitExpr(expr, locals),
        }
    }

    fn nullLiteralTargetTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, target_ty: ?ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| return fact.target_ty;
        const ty = target_ty orelse return null;
        return self.nullableTypeFromCandidate(ty);
    }

    // Coerce a `null` (absent) or a payload value (present) into a value optional `?T`'s
    // tagged aggregate. A source that already yields `?T` (another optional local / a call
    // returning `?T`) is left to the normal path (pass-through, no double-wrap).
    fn emitValueOptionalCoercion(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        var resolved = self.resolveAliasType(ty);
        _ = self.valueOptionalPayloadFromCandidate(ty) orelse return false;
        if (expr.kind == .null_literal) {
            const opt_name = try self.cTypeFor(resolved, .typedef_name);
            try self.out.print(self.allocator, "({s}){{ .present = false }}", .{opt_name});
            return true;
        }
        // Pass-through: the source already produces the optional aggregate.
        if (self.nullableTypeForExpr(expr, locals)) |src_ty| {
            if (self.nullableTypeFromCandidate(src_ty) != null) return false;
        }
        const fact = self.mirTargetTypeFactAt(.value_optional_coercion, expr.span) orelse return error.UnsupportedCEmission;
        resolved = self.resolveAliasType(fact.target_ty);
        const child = self.valueOptionalPayloadFromCandidate(fact.target_ty) orelse return error.UnsupportedCEmission;
        const opt_name = try self.cTypeFor(resolved, .typedef_name);
        try self.out.print(self.allocator, "({s}){{ .present = true, .value = ", .{opt_name});
        try self.emitExprWithTarget(expr, locals, child);
        try self.out.appendSlice(self.allocator, " }");
        return true;
    }

    fn emitPointerToPAddrTargetCast(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        if (!lower_c_type.isPAddrType(ty)) return false;
        const source_ty = self.paddrCoercionSourceTypeForEmission(expr, locals) orelse return false;
        if (!lower_c_type.isPointerLikeAddressType(source_ty)) return false;
        try self.out.appendSlice(self.allocator, "((uintptr_t)(");
        try self.emitExpr(expr, locals);
        try self.out.appendSlice(self.allocator, "))");
        return true;
    }

    fn paddrCoercionSourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.paddr_coercion_source, expr.span)) |fact| return fact.target_ty;
        if (expr.kind == .cast) return (self.mirTargetTypeFactAt(.explicit_cast_source, expr.span) orelse return null).target_ty;
        return self.generatedPaddrCoercionSourceTypeForEmission(expr, locals);
    }

    fn generatedPaddrCoercionSourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn emitAggregateLiteralWithTarget(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const kind: mir.TargetTypeKind = if (expr.kind == .array_literal) .array_literal else .struct_literal;
        const fact = self.mirTargetTypeFactAt(kind, expr.span) orelse return error.UnsupportedCEmission;
        const target = fact.target_ty;
        switch (expr.kind) {
            .array_literal => |items| try lower_c_aggregate.emitArrayLiteral(self.aggregateEmitContext(), items, locals, target),
            .struct_literal => |fields| {
                const construction = try self.validateMirStructLiteralConstruction(fact);
                switch (construction) {
                    .packed_bits => if (!try lower_c_aggregate.emitPackedBitsLiteral(self.aggregateEmitContext(), fields, locals, target)) return error.UnsupportedCEmission,
                    .declared_struct, .c_union => try lower_c_aggregate.emitStructLiteral(self.aggregateEmitContext(), fields, locals, target),
                }
            },
            else => unreachable,
        }
    }

    fn emitArithmeticExprWithTarget(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        switch (expr.kind) {
            .binary => |node| {
                if (try lower_c_arith.emitWrapBinaryWithTarget(self.arithContext(), node, locals, target_ty)) return;
                if (try lower_c_arith.emitSatBinaryWithTarget(self.arithContext(), node, locals, target_ty)) return;
                if (try lower_c_arith.emitCheckedBinaryWithTarget(self.arithContext(), node, locals, target_ty)) return;
            },
            .unary => |node| {
                _ = self.unaryResultTypeForEmission(expr, locals) orelse return error.UnsupportedCEmission;
                if (try lower_c_arith.emitCheckedUnaryWithTarget(self.arithContext(), node, locals, target_ty)) return;
            },
            else => unreachable,
        }
        try self.emitExpr(expr, locals);
    }

    fn emitGroupedExprWithTarget(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        try self.out.appendSlice(self.allocator, "(");
        try self.emitExprWithTarget(inner, locals, target_ty);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitAddressOfExprWithTarget(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void {
        // `&x` / `&mut x` coerced to `*dyn Trait`: build the fat pointer
        // `(mc_dyn_Trait){ .data = (void*)&x, .vtable = &__vt_Type_Trait }`.
        if (target_ty) |ty| {
            if (try self.emitDynCoercion(expr, locals, ty)) return;
        }
        try self.emitExpr(expr, locals);
    }

    fn emitTargetCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr, expr: ast_bridge.Expr) anyerror!void {
        if (self.mirHasCallTargetKindAt(.atomic_init, expr.span)) {
            const expected_result_ty = target_ty orelse return error.UnsupportedCEmission;
            const payload_ty = self.atomicInitPayloadTypeAt(expr.span, expected_result_ty) orelse return error.UnsupportedCEmission;
            if (try lower_c_atomic.emitAtomicInitCall(self.atomicEmitContext(), node, locals, payload_ty)) return;
            return error.UnsupportedCEmission;
        }
        const result_constructor = if (self.mirCallTargetKindAt(expr.span)) |kind| mir.resultConstructorFactInfo(kind) else null;
        if (result_constructor) |constructor| {
            if (self.mirTargetTypeFactAt(constructor.target_kind, expr.span)) |fact| {
                if (try lower_c_aggregate.emitResultConstructor(self.aggregateEmitContext(), node, locals, fact.target_ty, constructor.tag)) return;
                return error.UnsupportedCEmission;
            }
            return error.UnsupportedCEmission;
        }
        if (self.mirTargetTypeFactAt(.result_ok, expr.span) != null or self.mirTargetTypeFactAt(.result_err, expr.span) != null) return error.UnsupportedCEmission;
        if (self.mirTargetTypeFactAt(.tagged_union, expr.span)) |fact| {
            if (try lower_c_aggregate.emitTaggedUnionConstructor(self.aggregateEmitContext(), node, locals, fact.target_ty)) return;
            return error.UnsupportedCEmission;
        }
        try self.emitExpr(expr, locals);
    }

    fn emitTargetPreludeExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        // f32 target: compute the float expression in `float`, not `double`. A bare C decimal
        // literal is `double`, so `1.7 * 2.3` would multiply in double and round twice when
        // narrowed to f32 — diverging ~1 ULP from the LLVM `fmul`. Suffix f32 literals with `f`.
        if (expr.kind != .float_literal) if (try self.mirFloatLiteralTargetForExpr(expr)) |mir_float_ty| if (typeName(self.resolveAliasType(mir_float_ty))) |tn| {
            if (std.mem.eql(u8, tn, "f32")) {
                try self.emitF32Expr(expr, locals);
                return true;
            }
        };
        // The uniform `*T -> *dyn Trait` coercion: fires at EVERY assignment context
        // that threads a target type (let-init, return, assignment RHS, struct field,
        // array element, call arg), from any `*T` source — not just `&x`. A `*dyn`
        // pass-through returns false and emits normally.
        if (self.targetIsDynOrNullableDyn(ty)) {
            if (try self.emitDynCoercion(expr, locals, ty)) return true;
        }
        // A `[]mut T` value coerced to a `[]const T` target (safe const-narrowing). The two
        // slice structs are layout-identical but distinct C types (const vs mut pointee), so a
        // plain assignment won't compile — reinterpret via a fresh slice literal that const-casts
        // the pointer.
        if (locals) |local_set| {
            if (try self.emitSliceConstNarrowCoercion(expr, local_set, ty)) return true;
        }
        return false;
    }

    fn emitSliceConstNarrowCoercion(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!bool {
        const fact_source_ty = if (expr.kind == .cast)
            (self.mirTargetTypeFactAt(.explicit_cast_source, expr.span) orelse return error.UnsupportedCEmission).target_ty
        else blk: {
            const fact = self.mirTargetTypeFactAt(.view_const_narrow_source, expr.span) orelse return false;
            break :blk fact.target_ty;
        };
        const fact_target_ty = if (expr.kind == .cast)
            (self.mirTargetTypeFactAt(.explicit_cast_target, expr.span) orelse return error.UnsupportedCEmission).target_ty
        else blk: {
            break :blk (self.mirTargetTypeFactAt(.view_const_narrow_target, expr.span) orelse return error.UnsupportedCEmission).target_ty;
        };
        if (expr.kind != .cast and !type_bridge.sameTypeSyntax(self.resolveAliasType(fact_target_ty), self.resolveAliasType(target_ty))) return false;
        const resolved_target = self.resolveAliasType(fact_target_ty);
        const target_node = switch (resolved_target.kind) {
            .slice => |node| node,
            else => return false,
        };
        if (target_node.mutability != .@"const") return false;
        // An explicit `m as []const u8` narrow: the cast target is also a slice, so lower the
        // INNER value with the same const reinterpret (the `as` is a no-op reinterpret).
        const value_expr = switch (expr.kind) {
            .cast => |node| node.value.*,
            .grouped => |inner| inner.*,
            else => expr,
        };
        const resolved_source = self.resolveAliasType(fact_source_ty);
        const source_node = switch (resolved_source.kind) {
            .slice => |node| node,
            else => return false,
        };
        if (source_node.mutability != .mut) return false;
        const src_c_type = try self.cTypeFor(fact_source_ty, .typedef_name);
        const slice_name = try self.sliceTypeName(target_node.child.*, .@"const");
        const ptr_type = try self.pointerTypeForSliceElement(target_node.child.*, .@"const");
        const n = self.temp_index;
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ {s} mc_scv{d} = ", .{ src_c_type, n });
        try self.emitExpr(value_expr, locals);
        try self.out.print(self.allocator, "; ({s}){{ .ptr = ({s})mc_scv{d}.ptr, .len = mc_scv{d}.len }}; }})", .{ slice_name, ptr_type, n, n });
        return true;
    }

    fn emitEnumLiteralWithTarget(self: *CEmitter, literal: ast_bridge.Ident, span: ast_bridge.Span) anyerror!void {
        const fact = self.mirTargetTypeFactAt(.enum_literal, span) orelse return error.UnsupportedCEmission;
        const enum_name = self.enumNameForType(fact.target_ty);
        if (enum_name) |name| {
            try self.out.print(self.allocator, "{s}_{s}", .{ name, literal.text });
            return;
        }
        try self.out.print(self.allocator, "/* unsupported enum literal: {s} */0", .{literal.text});
        return error.UnsupportedCEmission;
    }

    fn emitFloatLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast_bridge.Span) anyerror!void {
        const fact = self.mirTargetTypeFactAt(.float_literal, span) orelse return error.UnsupportedCEmission;
        const name = typeName(self.resolveAliasType(fact.target_ty)) orelse return error.UnsupportedCEmission;
        if (!std.mem.eql(u8, name, "f32") and !std.mem.eql(u8, name, "f64")) return error.UnsupportedCEmission;
        try appendCFloatLiteral(self.allocator, self.out, literal, std.mem.eql(u8, name, "f32"));
    }

    fn emitCharLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast_bridge.Span, expected_ty: ?ast_bridge.TypeExpr) !void {
        const fact = self.mirTargetTypeFactAt(.char_literal, span) orelse return error.UnsupportedCEmission;
        const expected = expected_ty orelse return error.UnsupportedCEmission;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(expected))) return error.UnsupportedCEmission;
        const value = numeric.parseCharLiteral(literal) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s}){d})", .{ try self.cTypeFor(fact.target_ty, .typedef_name), value });
    }

    fn emitStringLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast_bridge.Span) anyerror!void {
        // String literals require a target type (sema rejects targetless
        // ones). They lower to a C string literal cast to the target
        // pointer type, e.g. `*const u8` -> `(uint8_t const *)"…"`.
        const fact = self.mirTargetTypeFactAt(.string_literal, span) orelse return error.UnsupportedCEmission;
        const target = fact.target_ty;
        const resolved = self.resolveAliasType(target);
        // A `[]const u8` / `[]u8` slice target: build the fat-pointer slice value
        // `(mc_slice_..._u8){ .ptr = (uint8_t const *)"hi", .len = 2 }`. The pointer is
        // the static C string literal (always valid — it is a program-lifetime literal),
        // the length is the decoded byte count (no trailing NUL).
        if (type_bridge.u8SliceMutability(resolved)) |mutability| {
            const child = resolved.kind.slice.child.*;
            const slice_name = try self.sliceTypeName(child, mutability);
            const ptr_type = try self.pointerTypeForSliceElement(child, mutability);
            const len = type_bridge.stringLiteralByteLen(literal) orelse return error.UnsupportedCEmission;
            try self.out.print(self.allocator, "(({s}){{ .ptr = ({s})", .{ slice_name, ptr_type });
            try self.emitCStringLiteral(literal);
            try self.out.print(self.allocator, ", .len = {d} }})", .{len});
            return;
        }
        if (!isStringLiteralTarget(resolved)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(target, .typedef_name)});
        try self.emitCStringLiteral(literal);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitCStringLiteral(self: *CEmitter, literal: []const u8) !void {
        if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return error.UnsupportedCEmission;
        try self.out.append(self.allocator, '"');
        var i: usize = 1;
        while (i + 1 < literal.len) : (i += 1) {
            const byte = if (literal[i] == '\\') blk: {
                i += 1;
                if (i + 1 >= literal.len) return error.UnsupportedCEmission;
                break :blk switch (literal[i]) {
                    '\\' => @as(u8, '\\'),
                    '\'' => @as(u8, '\''),
                    '"' => @as(u8, '"'),
                    '0' => @as(u8, 0),
                    'n' => @as(u8, '\n'),
                    'r' => @as(u8, '\r'),
                    't' => @as(u8, '\t'),
                    else => return error.UnsupportedCEmission,
                };
            } else literal[i];
            try self.emitCStringByte(byte);
        }
        try self.out.append(self.allocator, '"');
    }

    fn emitCStringByte(self: *CEmitter, byte: u8) !void {
        switch (byte) {
            '\\' => try self.out.appendSlice(self.allocator, "\\\\"),
            '"' => try self.out.appendSlice(self.allocator, "\\\""),
            '\'' => try self.out.appendSlice(self.allocator, "\\'"),
            '?' => try self.out.appendSlice(self.allocator, "\\?"),
            0 => try self.out.appendSlice(self.allocator, "\\000"),
            '\n' => try self.out.appendSlice(self.allocator, "\\n"),
            '\r' => try self.out.appendSlice(self.allocator, "\\r"),
            '\t' => try self.out.appendSlice(self.allocator, "\\t"),
            32...33, 35...38, 40...62, 64...91, 93...126 => try self.out.append(self.allocator, byte),
            else => {
                try self.out.append(self.allocator, '\\');
                try self.out.append(self.allocator, '0' + ((byte >> 6) & 0x07));
                try self.out.append(self.allocator, '0' + ((byte >> 3) & 0x07));
                try self.out.append(self.allocator, '0' + (byte & 0x07));
            },
        }
    }

    // If `target_ty` is `*dyn Trait`, emit the checked fat-pointer coercion from a `*T`
    // source and return true. The STATIC pointee type T selects the rodata vtable,
    // UNIFORMLY for:
    //   - `&x` / `&mut x`     : .data = (void*)&x,   T = typeof(x)
    //   - a `*T` value (param, field, returned `*T`, …): .data = (void*)<ptr>, T = pointee
    // An existing `*dyn Trait` value passes through (returns false → normal emit). Sema
    // verified conformance + forge-safety. Returns false when not applicable.
    // True when `ty` is `*dyn Trait` or `?*dyn Trait` — both route through emitDynCoercion.
    fn targetIsDynOrNullableDyn(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.dynTraitNameFromCandidate(ty) != null;
    }

    fn emitDynCoercion(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) !bool {
        if (self.dynTargetTraitName(target_ty) == null) return false;
        // `?*dyn Trait = null`: `none` is the zero fat pointer (data == NULL).
        if (expr.kind == .null_literal) {
            const trait_name = self.dynTargetTraitName(target_ty) orelse return false;
            try self.emitNullDynCoercion(trait_name);
            return true;
        }
        if (self.dynSourceIsPassThrough(expr, locals)) return false;
        const fact = self.mirTargetTypeFactAt(.dyn_coercion, expr.span) orelse return error.UnsupportedCEmission;
        const source_fact = self.mirTargetTypeFactAt(.dyn_coercion_source, expr.span) orelse return error.UnsupportedCEmission;
        const trait_name = self.dynTargetTraitName(fact.target_ty) orelse return error.UnsupportedCEmission;
        const source_ty = source_fact.target_ty;
        switch (expr.kind) {
            .grouped => |inner| return try self.emitDynCoercionWithSource(inner.*, locals, trait_name, source_ty),
            else => return try self.emitDynCoercionWithSource(expr, locals, trait_name, source_ty),
        }
    }

    fn dynSourceIsPassThrough(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.dynSourceIsPassThrough(inner.*, locals),
            else => if (self.dynPassThroughTypeForEmission(expr, locals)) |source_ty|
                self.targetIsDynOrNullableDyn(source_ty)
            else
                false,
        };
    }

    fn dynTargetTraitName(self: *CEmitter, target_ty: ast_bridge.TypeExpr) ?[]const u8 {
        return self.dynTraitNameFromCandidate(target_ty);
    }

    fn dynTraitNameFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            .nullable => |child| switch (self.resolveAliasType(child.*).kind) {
                .dyn_trait => |d| d.trait_name.text,
                else => null,
            },
            else => null,
        };
    }

    fn dynDispatchTraitNameFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                .dyn_trait => |d| d.trait_name.text,
                else => null,
            },
            else => null,
        };
    }

    fn emitNullDynCoercion(self: *CEmitter, trait_name: []const u8) !void {
        try self.out.print(self.allocator, "({s}){{0}}", .{try self.dynTypeName(trait_name)});
    }

    fn emitDynCoercionWithSource(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast_bridge.TypeExpr) !bool {
        return switch (expr.kind) {
            .grouped => |inner| try self.emitDynCoercionWithSource(inner.*, locals, trait_name, source_ty),
            .address_of => |inner| try self.emitAddressOfDynCoercion(inner.*, locals, trait_name, source_ty),
            else => try self.emitPointerValueDynCoercion(expr, locals, trait_name, source_ty),
        };
    }

    fn emitAddressOfDynCoercion(self: *CEmitter, operand: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast_bridge.TypeExpr) !bool {
        // `&x` -> .data = (void*)&x, vtable keyed on typeof(x).
        const type_name = typeName(self.resolveAliasType(source_ty)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)&", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(operand, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn emitPointerValueDynCoercion(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast_bridge.TypeExpr) !bool {
        // A `*T` value: .data = (void*)<the pointer>, vtable keyed on the pointee T.
        const pointee = self.dynPointerSourcePointeeFromCandidate(source_ty) orelse return false;
        const type_name = typeName(self.resolveAliasType(pointee)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(expr, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn dynPointerSourcePointeeFromCandidate(self: *CEmitter, source_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        // An existing `*dyn Trait` value passes through (no re-wrap).
        if (self.dynTraitNameFromCandidate(source_ty) != null) return null;
        const pointer = self.pointerNodeFromCandidate(source_ty) orelse return null;
        return pointer.child.*;
    }

    fn dynPassThroughTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn emitF32Expr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try lower_c_arith.emitF32Expr(self.arithContext(), expr, locals);
    }

    fn structDeclForResolvedTarget(self: *CEmitter, target_ty: ast_bridge.TypeExpr) ?ast_bridge.StructDecl {
        const struct_name = typeName(target_ty) orelse return null;
        return self.structs.get(struct_name);
    }

    fn enumNameForType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return self.enumNameFromCandidate(ty);
    }

    fn emitPackedBitsMember(self: *CEmitter, node: anytype, member_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const base_ty = packedBitsNameForExpr(node.base.*, locals, &self.globals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(node.name.text) orelse return false;
        const field_ty = (self.mirTargetTypeFactAt(.expression_result, member_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(type_bridge.simpleNameType("bool", member_span)))) return error.UnsupportedCEmission;
        try self.emitPackedBitsMaskTest(node.base.*, locals, info, field.bit_index);
        return true;
    }

    fn emitPackedBitsMaskTest(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), info: PackedBitsInfo, bit_index: usize) !void {
        try self.out.appendSlice(self.allocator, "((");
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " & {s}) != 0)", .{try packedBitsMaskLiteral(self.scratch.allocator(), info, bit_index)});
    }

    fn emitPackedBitsFieldWriteStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const member = memberExpr(assignment.target) orelse return false;
        const base_ty = packedBitsNameForExpr(member.base.*, locals, &self.globals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(member.name.text) orelse return false;
        const mask = try packedBitsMaskLiteral(self.scratch.allocator(), info, field.bit_index);
        if (packedBitsGlobalBase(member.base.*, locals, &self.globals, base_ty)) |global_name| {
            try self.emitPackedBitsGlobalFieldWrite(base_ty, info, global_name, mask, assignment.value, locals);
            return true;
        }

        try self.emitPackedBitsLocalFieldWrite(member.base.*, base_ty, mask, assignment.value, locals);
        return true;
    }

    fn emitPackedBitsGlobalFieldWrite(self: *CEmitter, base_ty: []const u8, info: PackedBitsInfo, global_name: []const u8, mask: []const u8, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        const value_temp = try self.emitSequencedCallArgTemp(value, locals, simpleNameType("bool", value.span));
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s})mc_race_load_{s}(&{s});\n", .{ base_ty, temp_name, base_ty, info.repr_name, global_name });
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = ({s})(({s} & ({s})~{s}) | ({s} ? {s} : ({s})0));\n", .{ temp_name, base_ty, temp_name, base_ty, mask, value_temp.name, mask, base_ty });
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_{s}(&{s}, ({s}){s});\n", .{ info.repr_name, global_name, info.repr_c_type, temp_name });
    }

    fn emitPackedBitsLocalFieldWrite(self: *CEmitter, base: ast_bridge.Expr, base_ty: []const u8, mask: []const u8, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        const value_temp = try self.emitSequencedCallArgTemp(value, locals, simpleNameType("bool", value.span));
        try self.writeIndent();
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " = ({s})((", .{base_ty});
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " & ({s})~{s}) | ({s} ? {s} : ({s})0));\n", .{ base_ty, mask, value_temp.name, mask, base_ty });
    }

    fn globalAssignmentTarget(self: *CEmitter, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        return lower_c_global.globalAssignmentTarget(self.globalAccessContext(), target, locals);
    }

    fn emitGlobalArrayElementMemberLoadExpr(self: *CEmitter, member: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const index = indexExpr(member.base.*) orelse return false;
        const access = globalArrayElementAccess(index, locals, &self.globals) orelse return false;
        const field = self.globalArrayElementMemberField(access, member.name.text) orelse return false;
        const field_info = try self.globalElementInfoFromType(field.ty);
        const field_name = try self.cIdent(member.name.text);
        try lower_c_global.emitGlobalArrayElementMemberLoadExpr(self.globalArrayAccessEmitContext(), access, locals, field_info, field_name);
        return true;
    }

    fn emitGlobalArrayIndexAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const index = indexExpr(assignment.target) orelse return false;
        const access = globalArrayElementAccess(index, locals, &self.globals) orelse return false;
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, access.element_info.source_ty);
        const index_temp = try self.emitSequencedCallArgTemp(access.index, locals, simpleNameType("usize", access.index.span));

        try self.writeIndent();
        try appendGlobalArrayElementStore(self.allocator, self.out, access, index_temp.name, value_temp.name);
        return true;
    }

    fn emitGlobalArrayElementMemberAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const member = memberExpr(assignment.target) orelse return false;
        const index = indexExpr(member.base.*) orelse return false;
        const access = globalArrayElementAccess(index, locals, &self.globals) orelse return false;
        const field = self.globalArrayElementMemberField(access, member.name.text) orelse return false;
        const field_info = try self.globalElementInfoFromType(field.ty);
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, field.ty);
        const index_temp = try self.emitSequencedCallArgTemp(access.index, locals, simpleNameType("usize", access.index.span));

        try self.writeIndent();
        try appendGlobalArrayElementMemberStore(self.allocator, self.out, access, field_info, try self.cIdent(member.name.text), index_temp.name, value_temp.name);
        return true;
    }

    fn globalArrayElementMemberField(self: *CEmitter, access: GlobalArrayElementAccess, member_name: []const u8) ?ast_bridge.Field {
        const element_ty = self.resolveAliasType(access.element_info.source_ty);
        const element_name = typeName(element_ty) orelse return null;
        const struct_decl = self.structs.get(element_name) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, member_name)) return field;
        }
        return null;
    }

    fn exprIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            // User-source boolean-producing expressions have complete MIR
            // result facts. Syntax identifies the operation, but it must not
            // independently authorize boolean lowering when that fact is
            // absent.
            .bool_literal => self.boolLiteralIsBoolForEmission(expr),
            .ident => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk false;
                break :blk isBoolType(self.resolveAliasType(ty));
            },
            .index, .member => self.storageExprIsBoolForEmission(expr, locals),
            .call => if (self.callResultTypeForEmission(expr, locals)) |ty| isBoolType(self.resolveAliasType(ty)) else false,
            .grouped => |inner| self.groupedExprIsBoolForEmission(expr, inner.*, locals),
            .binary => |node| self.binaryExprIsBoolForEmission(expr, node),
            .unary => |node| self.unaryExprIsBoolForEmission(expr, node),
            else => false,
        };
    }

    fn boolLiteralIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr) bool {
        if (!isSourceSpan(expr.span)) return true;
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn storageExprIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse return false;
        return isBoolType(self.resolveAliasType(ty));
    }

    fn groupedExprIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (!isSourceSpan(expr.span)) return self.exprIsBoolForEmission(inner, locals);
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn binaryExprIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr, node: anytype) bool {
        if (!isSourceSpan(expr.span)) {
            return switch (node.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => true,
                else => false,
            };
        }
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn unaryExprIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr, node: anytype) bool {
        if (!isSourceSpan(expr.span)) return node.op == .logical_not;
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn expressionResultIsBoolForEmission(self: *CEmitter, expr: ast_bridge.Expr) bool {
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return false).target_ty;
        return isBoolType(self.resolveAliasType(ty));
    }

    fn enumNameForValueExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        if (self.operandEmitType(expr, locals)) |ty| return self.enumNameForType(ty);
        return switch (expr.kind) {
            .call => blk: {
                const ret_ty = self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.enumNameForType(ret_ty);
            },
            .cast => blk: {
                const ty = self.castResultTypeForEmission(expr) orelse break :blk null;
                break :blk self.enumNameForType(ty);
            },
            .member => |node| blk: {
                // A variant-path literal `Enum.variant` has the enum's own
                // type; its MIR fact, not declaration scanning, authorizes enum
                // identity.
                const ty = (self.mirTargetTypeFactAt(.enum_variant_path_result, node.base.*.span) orelse break :blk null).target_ty;
                break :blk self.enumNameForType(ty);
            },
            .grouped => |inner| self.groupedEnumNameForValueExpr(expr, inner.*, locals),
            else => null,
        };
    }

    fn groupedEnumNameForValueExpr(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        if (!isSourceSpan(expr.span)) return self.enumNameForValueExpr(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.enumNameForType(ty);
    }

    fn emitOverlayFieldReadReturn(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !bool {
        try self.requireOverlayReturnExpressionResult(expr, locals);
        return lower_c_overlay.emitOverlayFieldReadReturn(self.overlayEmitContext(), expr, locals, return_ty);
    }

    fn requireOverlayReturnExpressionResult(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        switch (expr.kind) {
            .grouped => |inner| return self.requireOverlayReturnExpressionResult(inner.*, locals),
            .member => |node| if (self.overlayMemberResultType(node, locals)) |inferred_field_ty| {
                const field_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
            },
            .index => |node| if (self.overlayIndexResultType(node, locals)) |inferred_element_ty| {
                const element_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
            },
            else => {},
        }
    }

    fn emitOverlayFieldWriteStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        return lower_c_overlay.emitOverlayFieldWriteStmt(self.overlayEmitContext(), assignment, locals);
    }

    fn emitOverlayMemberReadExpr(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        return lower_c_overlay.emitOverlayMemberReadExpr(self.overlayEmitContext(), node, locals);
    }

    fn emitOverlayIndexReadExpr(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        return lower_c_overlay.emitOverlayIndexReadExpr(self.overlayEmitContext(), node, locals);
    }

    fn overlayFieldLayoutSize(self: *CEmitter, ty: ast_bridge.TypeExpr) usize {
        return (self.overlayFieldLayout(ty) orelse OverlayLayout{ .size = 1, .alignment = 1 }).size;
    }

    fn emitSliceExpr(self: *CEmitter, node: anytype, slice_span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) !void {
        const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
        const inferred_slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedCEmission;
        const slice_ty = (self.mirTargetTypeFactAt(.expression_result, slice_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(slice_ty), self.resolveAliasType(inferred_slice_ty))) return error.UnsupportedCEmission;
        const slice_name = try self.sliceTypeName(slice_ty.kind.slice.child.*, slice_ty.kind.slice.mutability);
        const resolved = self.resolveAliasType(base_ty);
        const n = self.temp_index;
        self.temp_index += 1;

        try self.emitSliceRangePrelude(node, locals, resolved, n);
        try self.emitSliceBoundsGuard(slice_span, n, slice_name);
        try self.emitSliceBasePtr(node.base.*, locals, resolved);
        try self.out.print(self.allocator, " + mc_start{d}, .len = mc_end{d} - mc_start{d} }}; }})", .{ n, n, n });
    }

    fn arrayOrSliceBaseTypeForEmission(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (syntheticDestructureBase(base)) return self.arrayOrSliceBaseTypeForEmissionRecovered(base, locals);
        if (isSourceSpan(base.span)) {
            const base_fact_ty = (self.mirTargetTypeFactAt(.expression_result, base.span) orelse return null).target_ty;
            const inferred = self.arrayOrSliceBaseTypeForEmissionRecovered(base, locals) orelse return null;
            if (!lower_c_type.sameCStorageType(self.resolveAliasType(base_fact_ty), self.resolveAliasType(inferred))) return null;
            return base_fact_ty;
        }
        return self.arrayOrSliceBaseTypeForEmissionRecovered(base, locals) orelse
            self.generatedExprSourceTypeForEmission(base, locals);
    }

    fn arrayOrSliceBaseTypeForEmissionRecovered(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.arrayTypeForExpr(base, locals)) |ty| return ty;
        if (self.sliceReturnTypeForExpr(base, locals)) |ty| return ty;
        if (self.operandEmitType(base, locals)) |ty| return ty;
        return null;
    }

    fn emitSliceRangePrelude(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast_bridge.TypeExpr, temp_id: usize) !void {
        try self.out.print(self.allocator, "({{ uintptr_t mc_start{d} = (", .{temp_id});
        try self.emitExpr(node.start.*, locals);
        try self.out.print(self.allocator, "); uintptr_t mc_end{d} = (", .{temp_id});
        try self.emitExpr(node.end.*, locals);
        try self.out.print(self.allocator, "); uintptr_t mc_len{d} = ", .{temp_id});
        try self.emitSliceBaseLen(node.base.*, locals, resolved_base_ty);
    }

    fn emitSliceBaseLen(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast_bridge.TypeExpr) !void {
        switch (resolved_base_ty.kind) {
            .slice => {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(base, locals);
                try self.out.appendSlice(self.allocator, ").len");
            },
            .array => |array| try self.out.appendSlice(self.allocator, try self.arrayLenTextForExpr(array.len)),
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitSliceBoundsGuard(self: *CEmitter, slice_span: ast_bridge.Span, temp_id: usize, slice_name: []const u8) !void {
        // OPT (annex E): when the optimized MIR proved this constant range in bounds, the
        // `start <= end <= len` guard is elided (the `mc_len` binding above is still emitted but
        // unused, which is harmless).
        if (self.mirCheckElided(slice_span)) {
            try self.out.print(self.allocator, "; (void)mc_len{d}; ({s}){{ .ptr = ", .{ temp_id, slice_name });
        } else {
            try self.requireMirBoundsFact(.slice, slice_span);
            try self.out.print(self.allocator, "; if (mc_start{d} > mc_end{d} || mc_end{d} > mc_len{d}) mc_trap_Bounds(); ({s}){{ .ptr = ", .{ temp_id, temp_id, temp_id, temp_id, slice_name });
        }
    }

    fn emitSliceBasePtr(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast_bridge.TypeExpr) !void {
        switch (resolved_base_ty.kind) {
            .slice => {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(base, locals);
                try self.out.appendSlice(self.allocator, ").ptr");
            },
            .array => {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(base, locals);
                try self.out.appendSlice(self.allocator, ").elems");
            },
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitArrayCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const array_ty = self.callReturnTypeForInferredLocal(initializer, locals, isArrayCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, array_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isArrayCallReturnType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.arrayTypeFromType(ty) != null;
    }

    fn emitSliceCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const slice_ty = self.callReturnTypeForInferredLocal(initializer, locals, isSliceCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, slice_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isSliceCallReturnType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.sliceTypeFromCandidate(ty) != null;
    }

    fn emitEnumCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const enum_ty = self.callReturnTypeForInferredLocal(initializer, locals, isEnumCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, enum_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isEnumCallReturnType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.enumTypeFromCandidate(ty) != null;
    }

    fn sliceTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .slice) ty else null;
    }

    fn enumTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return if (self.enumNameFromCandidate(ty) != null) ty else null;
    }

    fn enumNameFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        const enum_name = type_bridge.typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.enums.contains(enum_name)) enum_name else null;
    }

    fn emitTaggedUnionCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const union_ty = self.qualifiedUnionResultTypeForInferredLocal(initializer) orelse
            self.callReturnTypeForInferredLocal(initializer, locals, isTaggedUnionCallReturnType) orelse
            return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, union_ty)) orelse union_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn qualifiedUnionResultTypeForInferredLocal(self: *CEmitter, initializer: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        return switch (initializer.kind) {
            .grouped => |inner| self.qualifiedUnionResultTypeForInferredLocal(inner.*),
            .call => if (self.mirTargetTypeFactAt(.qualified_union_result, initializer.span)) |fact| fact.target_ty else null,
            else => null,
        };
    }

    fn isTaggedUnionCallReturnType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.taggedUnionTypeFromType(ty) != null;
    }

    fn emitResultCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const result_ty = self.callReturnTypeForInferredLocal(initializer, locals, isResultMirCallResultType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, result_ty)) orelse result_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isResultMirCallResultType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.resultTypeFromCandidate(ty) != null;
    }

    fn resultTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .generic => |generic| if (std.mem.eql(u8, generic.base.text, "Result")) ty else null,
            else => null,
        };
    }

    fn emitNullableCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const nullable_ty = self.callReturnTypeForInferredLocal(initializer, locals, isNullableMirCallResultType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, nullable_ty)) orelse nullable_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isNullableMirCallResultType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.nullableTypeFromCandidate(ty) != null;
    }

    fn callReturnTypeForInferredLocal(self: *CEmitter, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), comptime matches: fn (*CEmitter, ast_bridge.TypeExpr) bool) ?ast_bridge.TypeExpr {
        const ty = self.callResultTypeForEmission(initializer, locals) orelse return null;
        return if (matches(self, ty)) ty else null;
    }

    fn emitInferredCallLocalInitValue(self: *CEmitter, name: []const u8, inferred_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, inferred_ty, initializer, locals)) return;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalCopyInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const known_ty = self.operandEmitType(initializer, locals) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, known_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        if (try lower_c_access.emitDirectCallSliceIndexLocalInit(self.accessEmitContext(), name, inferred_ty, initializer, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexLocalInit(self.accessEmitContext(), name, inferred_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitBooleanInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (!inferredLocalBooleanInitializer(initializer)) return false;
        const bool_ty = type_bridge.simpleNameType("bool", initializer.span);
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, bool_ty)) orelse return error.UnsupportedCEmission;
        if (!isBoolType(self.resolveAliasType(inferred_ty))) return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        if (lower_c_expr.comparisonExpr(initializer)) {
            if (try lower_c_flow.emitSequencedComparisonLocalInit(self.flowEmitContext(), name, inferred_ty, initializer, locals)) return true;
        }
        try self.writeIndent();
        try self.out.print(self.allocator, "bool {s} = ", .{name});
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn inferredLocalBooleanInitializer(initializer: ast_bridge.Expr) bool {
        return switch (initializer.kind) {
            .unary => |node| node.op == .logical_not,
            .binary => |node| node.op == .logical_and or node.op == .logical_or or lower_c_expr.comparisonExpr(initializer),
            .grouped => |inner| inferredLocalBooleanInitializer(inner.*),
            else => false,
        };
    }

    fn inferredLocalCastInitializer(initializer: ast_bridge.Expr) bool {
        return switch (initializer.kind) {
            .cast => true,
            .grouped => |inner| inferredLocalCastInitializer(inner.*),
            else => false,
        };
    }

    fn literalExpressionResultType(self: *CEmitter, initializer: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (initializer.kind) {
            .int_literal, .bool_literal => (self.mirTargetTypeFactAt(.expression_result, initializer.span) orelse return error.UnsupportedCEmission).target_ty,
            .grouped => |inner| try self.literalExpressionResultType(inner.*),
            else => null,
        };
    }

    fn emitNumericInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const known_ty = self.numericExprTypeForEmission(initializer, locals) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, known_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));

        if (try lower_c_arith.emitSequencedCheckedBinaryLocalInit(self.sequencedBinaryContext(), name, inferred_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn numericExprTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (expr.kind == .binary) {
            const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
            const resolved_fact = self.resolveAliasType(fact.target_ty);
            if (!lower_c_type.isNumericStorageType(resolved_fact)) return null;
            const inferred = self.numericExprTypeForEmissionInferred(expr, locals);
            if (inferred) |ty| {
                if (!lower_c_type.sameCStorageType(resolved_fact, self.resolveAliasType(ty))) return null;
            }
            return fact.target_ty;
        }
        const inferred = self.numericExprTypeForEmissionInferred(expr, locals);
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse {
            // Source compound numeric expressions have MIR-owned result types.
            // Direct names, calls, and casts still carry their own source facts;
            // generated zero-span expressions have no unique source fact key.
            if (isSourceSpan(expr.span)) {
                switch (expr.kind) {
                    .grouped, .unary, .member, .index, .deref => return null,
                    else => {},
                }
            }
            return inferred;
        };
        const expected = inferred orelse return fact.target_ty;
        if (!lower_c_type.sameCStorageType(self.resolveAliasType(fact.target_ty), self.resolveAliasType(expected))) return null;
        return fact.target_ty;
    }

    fn numericExprTypeForEmissionInferred(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => blk: {
                const source_ty = self.operandEmitType(expr, locals) orelse break :blk null;
                break :blk if (lower_c_type.isNumericStorageType(source_ty)) source_ty else null;
            },
            .call => blk: {
                const return_ty = self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk if (lower_c_type.isNumericStorageType(return_ty)) return_ty else null;
            },
            // A numeric member result is MIR-owned. The generic operand helper
            // checks the row against the declaration where that stale-fact guard
            // is still needed, so this numeric classifier does not repeat the
            // declaration scan.
            .member, .index => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk if (lower_c_type.isNumericStorageType(resolved))
                    self.numericExpressionResultType(expr, resolved)
                else
                    null;
            },
            // `p.*` over `p: *T` recovers `T`, so `p.* + 1` lowers checked.
            .deref => blk: {
                const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk if (lower_c_type.isNumericStorageType(resolved))
                    self.numericExpressionResultType(expr, resolved)
                else
                    null;
            },
            // A cast's result type is its target type, so `(x as u32) << 8` and
            // similar recover their width.
            .cast => blk: {
                const ty = self.castResultTypeForEmission(expr) orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk if (lower_c_type.isNumericStorageType(resolved))
                    self.numericExpressionResultType(expr, resolved)
                else
                    null;
            },
            .grouped => |inner| self.numericExprTypeForEmission(inner.*, locals),
            .unary => |node| self.numericExprTypeForEmission(node.expr.*, locals),
            .binary => |node| blk: {
                if (!lower_c_expr.isNumericValueBinaryOp(node.op)) break :blk null;
                const left_ty = self.numericExprTypeForEmission(node.left.*, locals);
                // A shift's result type is the left (shifted) operand's type;
                // the shift amount may be a different width (`u64 >> u32`), so
                // it does not have to match.
                if (node.op == .shl or node.op == .shr) break :blk left_ty;
                const right_ty = self.numericExprTypeForEmission(node.right.*, locals);
                if (left_ty != null and right_ty != null) {
                    break :blk if (lower_c_type.sameCStorageType(left_ty.?, right_ty.?)) left_ty else null;
                }
                // A bare numeric literal adopts its sibling operand's storage
                // type, so `i + 1` resolves to `i`'s type (e.g. as a comparison
                // or loop-condition operand: `while (i + 1) < n`).
                if (left_ty) |lt| break :blk if (lower_c_expr.exprIsNumericLiteral(node.right.*)) lt else null;
                if (right_ty) |rt| break :blk if (lower_c_expr.exprIsNumericLiteral(node.left.*)) rt else null;
                break :blk null;
            },
            else => null,
        };
    }

    fn numericExpressionResultType(self: *CEmitter, expr: ast_bridge.Expr, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse {
            // Source numeric value expressions have MIR-owned result types.
            // Generated zero-span nodes can still use their syntactic operand
            // type because no source-keyed fact can identify them.
            if (isSourceSpan(expr.span)) return null;
            return inferred;
        };
        const resolved_fact = self.resolveAliasType(fact.target_ty);
        if (!lower_c_type.isNumericStorageType(resolved_fact) or !lower_c_type.sameCStorageType(resolved_fact, inferred)) return null;
        return fact.target_ty;
    }

    fn conditionOperandTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => self.operandEmitType(expr, locals),
            // Source literal result types are MIR-owned. In particular, a
            // numeric comparison literal may be contextually widened to its
            // sibling's storage type; C must not recreate a default u32
            // decision here.
            .bool_literal, .int_literal => if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null,
            .call => self.callResultTypeForEmission(expr, locals),
            .grouped => |inner| blk: {
                const inferred = self.conditionOperandTypeForEmission(inner.*, locals) orelse break :blk null;
                break :blk self.checkedExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            .unary => |node| blk: {
                const inferred = self.conditionOperandTypeForEmission(node.expr.*, locals) orelse break :blk null;
                break :blk self.checkedExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            .binary => self.numericExprTypeForEmission(expr, locals),
            .index, .member => self.storageOrExpressionResultTypeForEmission(expr, locals),
            else => null,
        };
    }

    // Floating-point arithmetic lowers to plain C operators: IEEE semantics
    // never raise a language trap, so no overflow/divide checks are emitted.
    fn exprResolvesToFloat(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .ident, .member => self.operandResolvesToFloat(expr, locals),
            .deref => |inner| self.derefResolvesToFloat(inner.*, locals),
            .cast => if (self.castResultTypeForEmission(expr)) |ty| floatCTypeName(ty) != null else false,
            .grouped => |inner| self.exprResolvesToFloat(inner.*, locals),
            .unary => |node| self.exprResolvesToFloat(node.expr.*, locals),
            .binary => |node| self.exprResolvesToFloat(node.left.*, locals) or self.exprResolvesToFloat(node.right.*, locals),
            .index => |node| self.indexResolvesToFloat(node, locals),
            .float_literal => true,
            .call => |node| self.callResolvesToFloat(expr, node, locals),
            else => false,
        };
    }

    fn operandResolvesToFloat(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.operandEmitType(expr, locals) orelse return false;
        return floatCTypeName(ty) != null;
    }

    fn derefResolvesToFloat(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.derefPointeeType(inner, locals) orelse return false;
        return floatCTypeName(ty) != null;
    }

    fn indexResolvesToFloat(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
        _ = self;
        const local_set = locals orelse return false;
        const elem = localIndexElementType(node.base.*, local_set) orelse return false;
        return floatCTypeName(elem) != null;
    }

    fn callResolvesToFloat(self: *CEmitter, expr: ast_bridge.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (self.mirHasCallTargetKindAt(.raw_load, node.callee.*.span) and node.type_args.len == 1) {
            const result_ty = (self.mirTargetTypeFactAt(.raw_result, node.callee.*.span) orelse return false).target_ty;
            return floatCTypeName(result_ty) != null;
        }
        const return_ty = self.callResultTypeForEmission(expr, locals) orelse return false;
        return floatCTypeName(return_ty) != null;
    }

    fn emitCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const known_return_ty = self.callResultTypeForEmission(initializer, locals) orelse return false;
        const return_ty = (try self.mirInferredLocalType(name, initializer, known_return_ty)) orelse return error.UnsupportedCEmission;
        if (isCVoidType(return_ty)) return false;
        try locals.put(name, try self.localInfoFromType(return_ty));

        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, return_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.emitIgnoredLocalPrefix(name);
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn mirInferredLocalType(self: *CEmitter, name: []const u8, initializer: ast_bridge.Expr, known_ty: ?ast_bridge.TypeExpr) !?ast_bridge.TypeExpr {
        const fact_ty = (self.mirTargetTypeFactAtOwned(.inferred_local, initializer.span, name, null) orelse return null).target_ty;
        if (known_ty) |ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return fact_ty;
    }

    fn emitSequencedCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        return lower_c_call.collectSequencedArgTemps(self.sequencedArgContext(), call, locals, fn_info);
    }

    fn emitSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
        if (arg.kind == .grouped) return try self.emitSequencedCallArgTemp(arg.kind.grouped.*, locals, target_ty);
        if (try self.emitSpecialSequencedCallArgTemp(arg, locals, target_ty)) |temp| return temp;
        return lower_c_call.emitPlainSequencedArgTemp(self.sequencedArgContext(), arg, locals, target_ty);
    }

    fn emitSpecialSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        return lower_c_call.emitSpecialSequencedArgTemp(self.specialSequencedArgContext(), arg, locals, target_ty);
    }

    fn emitAddressSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_access.emitRawManyOffsetDerefAddressValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitLocalIndexAddressValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitIndexSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_access.emitDirectCallSliceIndexExprValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitDirectCallArrayIndexExprValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitLocalIndexValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitBinarySequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_flow.emitSequencedConditionValueTemp(self.flowEmitContext(), arg, locals)) |temp| return temp;
        if (try lower_c_arith.emitSequencedBinaryValueTemp(self.sequencedBinaryContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitCallSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const call = callExpr(arg) orelse return null;
        if (try self.emitAtomicResultValueTempFromCall(call, locals)) |temp| return temp;
        if (try lower_c_call.emitBitcastValueTempFromCall(self.sequencedArgContext(), call, locals)) |temp| return temp;
        if (try lower_c_call.emitExternNonNullCallValueTemp(self.sequencedArgContext(), &self.functions, arg, locals)) |temp| return temp;
        if (try lower_c_access.emitRawManyOffsetValueTempFromCall(self.accessEmitContext(), call, locals, target_ty)) |temp| return temp;
        if (try self.emitUncheckedAddValueTempFromCall(call, arg.span, locals, target_ty, "call_arg")) |temp| return temp;
        if (try self.emitNestedSequencedCallValueTemp(call, locals)) |temp| return temp;
        return null;
    }

    fn emitAtomicCastSequencedCallArgTemp(self: *CEmitter, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
        const cast = switch (arg.kind) {
            .cast => |node| node,
            .grouped => |inner| return try self.emitAtomicCastSequencedCallArgTemp(inner.*, locals, target_ty),
            else => return null,
        };
        const call = callExpr(cast.value.*) orelse return null;
        const source_temp = (try self.emitAtomicResultValueTempFromCall(call, locals)) orelse return null;

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = (({s}){s});\n", .{
            try self.cTypeFor(target_ty, .typedef_name),
            temp_name,
            try self.cTypeFor(cast.ty.*, .typedef_name),
            source_temp.name,
        });
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitAtomicResultValueTempFromCall(self: *CEmitter, call: syntax_bridge.CallExpr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        const return_ty = self.atomicResultReturnTypeForCall(call, locals) orelse return null;
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), temp_name });
        if (!try lower_c_atomic.emitAtomicCall(self.atomicEmitContext(), call, locals)) return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = return_ty };
    }

    fn emitNestedSequencedCallValueTemp(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        const callee_name = calleeIdentName(call.callee.*) orelse return null;
        const fn_info = self.functions.get(callee_name) orelse return null;
        const return_ty = fn_info.return_type orelse return null;
        if (isVoidType(return_ty) or !fn_info.acceptsArgCount(call.args.len)) return null;

        var nested_temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer nested_temps.deinit(self.scratch.allocator());

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), temp_name });
        try self.emitExpr(call.callee.*, locals);
        try lower_c_call.emitSequencedArgList(self.allocator, self.out, nested_temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = return_ty };
    }

    fn emitUncheckedAddValueTemp(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        return lower_c_arith.emitUncheckedAddValueTemp(self.arithContext(), expr, locals, target_ty, range_target);
    }

    fn emitUncheckedAddValueTempFromCall(self: *CEmitter, call: anytype, call_span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        return lower_c_arith.emitUncheckedAddValueTempFromCall(self.arithContext(), call, call_span, locals, target_ty, range_target);
    }

    fn hasMirNoOverflowRangeFact(self: *CEmitter, target: []const u8, op: []const u8, span: ast_bridge.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.range_facts) |fact| {
                if (!std.mem.eql(u8, fact.target, target)) continue;
                if (!std.mem.eql(u8, fact.op, op)) continue;
                if (fact.line != span.line or fact.column != span.column) continue;
                return true;
            }
        }
        return false;
    }

    // OPT (annex E): true when the optimizer proved the check at this operand source point
    // dead (a constant in-range index's Bounds check, or an unsigned div-by-literal's
    // DivideByZero check) and recorded it in the optimized MIR's `elided_bounds`. Without
    // `--optimize` the list is empty, so this is always false and the check is emitted — the
    // backend consumes the optimized MIR rather than re-deriving the proof.
    fn mirCheckElided(self: *CEmitter, span: ast_bridge.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.elided_bounds) |pt| {
                if (pt.line == span.line and pt.column == span.column) return true;
            }
        }
        return false;
    }

    fn requireMirBoundsFact(self: *CEmitter, kind: mir.BoundsFactKind, span: ast_bridge.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        for (function.bounds_facts) |fact| {
            if (fact.kind == kind and fact.source.line == span.line and fact.source.column == span.column) return;
        }
        return error.UnsupportedCEmission;
    }

    fn currentMirFunction(self: *CEmitter) ?*const mir.Function {
        const function_name = self.current_function orelse return null;
        return self.mirFunctionNamed(function_name);
    }

    fn currentOwnershipCleanupPlan(self: *const CEmitter) ?*const mir.OwnershipCleanupPlan {
        const function_name = self.current_function orelse return null;
        for (self.mir_module.functions) |*function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            if (!mir.cleanupCfgValid(self.mir_module.*, function.*, function.ownership_cleanup_plan, function.cleanup_cfg)) return null;
            var rebuilt_plan = mir.buildOwnershipCleanupPlan(self.allocator, self.mir_module.*, function.*) catch return null;
            defer rebuilt_plan.deinit(self.allocator);
            if (!mir.ownershipCleanupPlanEquivalent(function.ownership_cleanup_plan, rebuilt_plan)) return null;
            return &function.ownership_cleanup_plan;
        }
        return null;
    }

    fn currentCleanupCfg(self: *const CEmitter) ?*const mir.CleanupCfg {
        const function_name = self.current_function orelse return null;
        for (self.mir_module.functions) |*function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            if (!mir.cleanupCfgValid(self.mir_module.*, function.*, function.ownership_cleanup_plan, function.cleanup_cfg)) return null;
            var rebuilt_plan = mir.buildOwnershipCleanupPlan(self.allocator, self.mir_module.*, function.*) catch return null;
            defer rebuilt_plan.deinit(self.allocator);
            if (!mir.ownershipCleanupPlanEquivalent(function.ownership_cleanup_plan, rebuilt_plan)) return null;
            var rebuilt_cfg = mir.buildCleanupCfg(self.allocator, self.mir_module.*, function.*, rebuilt_plan) catch return null;
            defer rebuilt_cfg.deinit(self.allocator);
            if (!mir.cleanupCfgEquivalent(function.cleanup_cfg, rebuilt_cfg)) return null;
            return &function.cleanup_cfg;
        }
        return null;
    }

    fn mirFunctionNamed(self: *CEmitter, function_name: []const u8) ?*const mir.Function {
        for (self.mir_module.functions) |*function| {
            if (std.mem.eql(u8, function.name, function_name)) return function;
        }
        return null;
    }

    fn mirCallTargetKindAt(self: *CEmitter, span: ast_bridge.Span) ?mir.CallTargetKind {
        return mir_source_bridge.firstCallTargetKindAt(self.currentMirFunction(), span);
    }

    fn mirHasCallTargetKindAt(self: *CEmitter, kind: mir.CallTargetKind, span: ast_bridge.Span) bool {
        return mir_source_bridge.hasCallTargetKindAt(self.currentMirFunction(), kind, span, false);
    }

    fn atomicInitPayloadTypeAt(self: *CEmitter, span: ast_bridge.Span, expected_result_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const expected_payload_ty = lower_c_shape.atomicPayloadOfType(self.resolveAliasType(expected_result_ty)) orelse return null;
        return mir_source_bridge.atomicInitPayloadTypeAt(self.currentMirFunction(), &self.type_aliases, span, expected_result_ty, expected_payload_ty);
    }

    fn mirTargetTypeFactAt(self: *CEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?mir.TargetTypeFact {
        return mir_source_bridge.targetTypeFactAtCurrentSpan(self.currentMirFunction(), kind, span);
    }

    fn mirTargetTypeFactMatchingType(self: *CEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span, expected_ty: ast_bridge.TypeExpr) ?mir.TargetTypeFact {
        return mir_source_bridge.targetTypeFactMatchingType(self.currentMirFunction(), &self.type_aliases, kind, span, expected_ty);
    }

    fn mirTargetTypeFactAtOwned(self: *CEmitter, kind: mir.TargetTypeKind, span: ast_bridge.Span, target_owner: []const u8, target_index: ?usize) ?mir.TargetTypeFact {
        return mir_source_bridge.targetTypeFactAtOwnedCurrentSpan(self.currentMirFunction(), kind, span, target_owner, target_index);
    }

    fn mirConstGetIndexAt(self: *CEmitter, span: ast_bridge.Span) ?usize {
        return mir_source_bridge.uniqueConstGetIndexAt(self.currentMirFunction(), span);
    }

    fn mirAggregateTargetTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .grouped => |inner| self.mirAggregateTargetTypeForExpr(inner.*),
            .array_literal => if (self.mirTargetTypeFactAt(.array_literal, expr.span)) |fact| fact.target_ty else error.UnsupportedCEmission,
            .struct_literal => if (self.mirTargetTypeFactAt(.struct_literal, expr.span)) |fact| blk: {
                _ = try self.validateMirStructLiteralConstruction(fact);
                break :blk fact.target_ty;
            } else error.UnsupportedCEmission,
            else => null,
        };
    }

    fn validateMirStructLiteralConstruction(self: *CEmitter, fact: mir.TargetTypeFact) !mir.AggregateConstructionKind {
        const construction = fact.aggregate_construction orelse return error.UnsupportedCEmission;
        const resolved = self.resolveAliasType(fact.target_ty);
        const name = typeName(resolved) orelse return error.UnsupportedCEmission;
        switch (construction) {
            .packed_bits => if (!self.packed_bits.contains(name)) return error.UnsupportedCEmission,
            .declared_struct, .c_union => {
                const decl = self.structs.get(name) orelse return error.UnsupportedCEmission;
                if (decl.is_c_union != (construction == .c_union)) return error.UnsupportedCEmission;
            },
        }
        return construction;
    }

    fn mirFloatLiteralTargetForExpr(self: *CEmitter, expr: ast_bridge.Expr) !?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .float_literal => if (self.mirTargetTypeFactAt(.float_literal, expr.span)) |fact| fact.target_ty else error.UnsupportedCEmission,
            .grouped => |inner| self.mirFloatLiteralTargetForExpr(inner.*),
            .unary => |node| self.mirFloatLiteralTargetForExpr(node.expr.*),
            .binary => |node| blk: {
                const left = try self.mirFloatLiteralTargetForExpr(node.left.*);
                const right = try self.mirFloatLiteralTargetForExpr(node.right.*);
                if (left == null) break :blk right;
                if (right == null) break :blk left;
                // TypeExpr carries source spans. Two f32 facts at different
                // literals are semantically equal even though their AST values
                // are not byte-for-byte equal.
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(left.?), self.resolveAliasType(right.?))) return error.UnsupportedCEmission;
                break :blk left;
            },
            else => null,
        };
    }

    fn deinitOwnedStringVoidMap(self: *CEmitter, map: *std.StringHashMap(void)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.deinit();
    }

    fn deinitOwnedStringProvenanceMap(self: *CEmitter, map: *std.StringHashMap(mir.PointerProvenance)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.deinit();
    }

    fn clearOwnedStringVoidMapRetainingCapacity(self: *CEmitter, map: *std.StringHashMap(void)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.clearRetainingCapacity();
    }

    fn clearOwnedStringProvenanceMapRetainingCapacity(self: *CEmitter, map: *std.StringHashMap(mir.PointerProvenance)) void {
        var it = map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        map.clearRetainingCapacity();
    }

    fn localArrayPointerElementKey(self: *CEmitter, local_name: []const u8, index: u64) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ local_name, index });
    }

    fn localArrayPointerElementKeyMatchesLocal(key: []const u8, local_name: []const u8) bool {
        return key.len > local_name.len and std.mem.eql(u8, key[0..local_name.len], local_name) and key[local_name.len] == 0;
    }

    fn clearLocalArrayPointerElementsForLocal(self: *CEmitter, local_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.mir_pointer_array_elements.keyIterator();
            while (it.next()) |key| {
                if (localArrayPointerElementKeyMatchesLocal(key.*, local_name)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (self.mir_pointer_array_elements.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    fn setLocalArrayPointerElementProvenance(self: *CEmitter, local_name: []const u8, index: u64, provenance: mir.PointerProvenance) !void {
        const lookup_key = try self.localArrayPointerElementKey(local_name, index);
        defer self.allocator.free(lookup_key);

        if (provenance == .unknown) {
            if (self.mir_pointer_array_elements.fetchRemove(lookup_key)) |entry| {
                self.allocator.free(entry.key);
            }
            return;
        }

        if (self.mir_pointer_array_elements.getPtr(lookup_key)) |existing| {
            existing.* = provenance;
            return;
        }
        const owned_key = try self.localArrayPointerElementKey(local_name, index);
        errdefer self.allocator.free(owned_key);
        try self.mir_pointer_array_elements.put(owned_key, provenance);
    }

    fn localArrayElementPointerProvenance(self: *CEmitter, local_name: []const u8, index: u64) ?mir.PointerProvenance {
        const lookup_key = self.localArrayPointerElementKey(local_name, index) catch return null;
        defer self.allocator.free(lookup_key);
        return self.mir_pointer_array_elements.get(lookup_key);
    }

    fn fixedLocalPointerArrayElementType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        const array = switch (resolved_ty.kind) {
            .array => |array| array,
            else => return null,
        };
        if (!isPointerLikeGlobalType(self.resolveAliasType(array.child.*))) return null;
        var reflect_env = self.reflectEnv();
        _ = constArrayLenValue(array.len, &self.const_fns, &self.const_globals, lower_c_reflect.comptimeReflectThunk, &reflect_env) orelse return null;
        return array.child.*;
    }

    fn arrayLiteralItems(expr: ast_bridge.Expr) ?[]const ast_bridge.Expr {
        return switch (expr.kind) {
            .array_literal => |items| items,
            .grouped => |inner| arrayLiteralItems(inner.*),
            .cast => |node| arrayLiteralItems(node.value.*),
            else => null,
        };
    }

    const LocalArrayElementPath = struct {
        local_name: []const u8,
        index: u64,
    };

    const AggregatePointerFieldPath = struct {
        local_name: []const u8,
        field_path: []const u8,
    };

    fn aggregatePointerFieldKey(self: *CEmitter, local_name: []const u8, field_path: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ local_name, field_path });
    }

    fn aggregatePointerFieldKeyMatchesLocalPath(key: []const u8, local_name: []const u8, field_path: []const u8) bool {
        if (key.len <= local_name.len or !std.mem.eql(u8, key[0..local_name.len], local_name) or key[local_name.len] != 0) return false;
        if (field_path.len == 0) return true;
        const existing_path = key[local_name.len + 1 ..];
        if (std.mem.eql(u8, existing_path, field_path)) return true;
        return existing_path.len > field_path.len and
            std.mem.eql(u8, existing_path[0..field_path.len], field_path) and
            (existing_path[field_path.len] == '.' or existing_path[field_path.len] == '[');
    }

    fn setAggregatePointerFieldProvenance(self: *CEmitter, local_name: []const u8, field_path: []const u8, provenance: mir.PointerProvenance) !void {
        const lookup_key = try self.aggregatePointerFieldKey(local_name, field_path);
        defer self.allocator.free(lookup_key);

        if (provenance == .unknown) {
            if (self.mir_aggregate_pointer_fields.fetchRemove(lookup_key)) |entry| self.allocator.free(entry.key);
            return;
        }

        if (self.mir_aggregate_pointer_fields.getPtr(lookup_key)) |existing| {
            existing.* = provenance;
            return;
        }
        const owned_key = try self.aggregatePointerFieldKey(local_name, field_path);
        errdefer self.allocator.free(owned_key);
        try self.mir_aggregate_pointer_fields.put(owned_key, provenance);
    }

    fn clearAggregatePointerFieldsForLocalPath(self: *CEmitter, local_name: []const u8, field_path: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var it = self.mir_aggregate_pointer_fields.keyIterator();
            while (it.next()) |key| {
                if (aggregatePointerFieldKeyMatchesLocalPath(key.*, local_name, field_path)) {
                    found_key = key.*;
                    break;
                }
            }

            const key = found_key orelse return;
            if (self.mir_aggregate_pointer_fields.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        }
    }

    fn aggregateFieldPointerProvenance(self: *CEmitter, local_name: []const u8, field_path: []const u8) ?mir.PointerProvenance {
        const lookup_key = self.aggregatePointerFieldKey(local_name, field_path) catch return null;
        defer self.allocator.free(lookup_key);
        return self.mir_aggregate_pointer_fields.get(lookup_key);
    }

    fn joinAggregatePointerFieldPath(self: *CEmitter, prefix: []const u8, field_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{ prefix, field_name });
    }

    fn aggregatePointerArrayElementPath(self: *CEmitter, array_path: []const u8, index: u64) ![]const u8 {
        return try std.fmt.allocPrint(self.scratch.allocator(), "{s}[{d}]", .{ array_path, index });
    }

    fn directLocalAggregateMemberPath(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalAggregateMemberPath(inner.*, locals),
            .member => |node| blk: {
                if (directLocalName(node.base.*)) |local_name| {
                    const base_ty = switch (node.base.*.kind) {
                        .ident => |ident| self.identTypeForEmissionRecovered(ident.text, node.base.*.span, locals) orelse break :blk null,
                        else => break :blk null,
                    };
                    _ = self.memberFieldTypeFromAggregate(base_ty, node.name.text) orelse break :blk null;
                    break :blk .{ .local_name = local_name, .field_path = node.name.text };
                }
                const base_path = self.directLocalAggregateMemberPath(node.base.*, locals) orelse
                    self.directLocalAggregateArrayElementPath(node.base.*, locals) orelse
                    break :blk null;
                _ = self.memberFieldType(node.base.*, node.name.text, locals) orelse break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.joinAggregatePointerFieldPath(base_path.field_path, node.name.text) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn directLocalAggregateArrayElementPath(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?AggregatePointerFieldPath {
        return switch (expr.kind) {
            .grouped => |inner| self.directLocalAggregateArrayElementPath(inner.*, locals),
            .index => |node| blk: {
                const base_path = self.directLocalAggregateMemberPath(node.base.*, locals) orelse
                    self.directLocalAggregateArrayElementPath(node.base.*, locals) orelse
                    break :blk null;
                const index = localArrayConstIndexValue(node.index.*, locals orelse break :blk null) orelse break :blk null;
                break :blk .{
                    .local_name = base_path.local_name,
                    .field_path = self.aggregatePointerArrayElementPath(base_path.field_path, index) catch break :blk null,
                };
            },
            else => null,
        };
    }

    fn directLocalPointerArrayBaseName(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const ty = self.identTypeForEmissionRecovered(ident.text, expr.span, locals) orelse break :blk null;
                if (self.fixedLocalPointerArrayElementType(ty) == null) break :blk null;
                break :blk ident.text;
            },
            .grouped => |inner| self.directLocalPointerArrayBaseName(inner.*, locals),
            else => null,
        };
    }

    fn localArrayConstIndexValue(expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?u64 {
        const value = constIntValue(expr, locals) orelse return null;
        if (value < 0) return null;
        return std.math.cast(u64, value);
    }

    fn directLocalArrayElementPath(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?LocalArrayElementPath {
        return switch (expr.kind) {
            .index => |node| blk: {
                const local_name = self.directLocalPointerArrayBaseName(node.base.*, locals) orelse break :blk null;
                const index = localArrayConstIndexValue(node.index.*, locals) orelse break :blk null;
                break :blk .{ .local_name = local_name, .index = index };
            },
            .grouped => |inner| self.directLocalArrayElementPath(inner.*, locals),
            else => null,
        };
    }

    fn isKnownStructType(self: *CEmitter, ty: ast_bridge.TypeExpr) bool {
        return self.structNameFromCandidate(ty) != null;
    }

    fn mirPointerFactSubjectRecoveredType(fact: mir.PointerProvenanceFact, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const local_set = locals orelse return null;
        const info = local_set.get(fact.subject) orelse return null;
        return info.source_ty;
    }

    fn mirPointerFactSubjectSupportedNow(self: *CEmitter, fact: mir.PointerProvenanceFact, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = mirPointerFactSubjectRecoveredType(fact, locals) orelse return false;
        if (fact.field_path != null) return self.isKnownStructType(ty);
        if (fact.element_index != null) return self.fixedLocalPointerArrayElementType(ty) != null;
        return isPointerLikeGlobalType(self.resolveAliasType(ty)) or self.fixedLocalPointerArrayElementType(ty) != null;
    }

    fn emitMirPointerProvenanceConsumedComment(self: *CEmitter, fact: mir.PointerProvenanceFact) !void {
        const fn_name = self.current_function orelse return;
        try self.writeIndent();
        if (fact.field_path) |field_path| {
            if (fact.element_index) |index| {
                try self.out.print(self.allocator, "/* mir pointer_provenance consumed fn={s} subject={s} field={s} element={d} provenance={s} reason={s} source={d}:{d} */\n", .{
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
                try self.out.print(self.allocator, "/* mir pointer_provenance consumed fn={s} subject={s} field={s} provenance={s} reason={s} source={d}:{d} */\n", .{
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
            try self.out.print(self.allocator, "/* mir pointer_provenance consumed fn={s} subject={s} element={d} provenance={s} reason={s} source={d}:{d} */\n", .{
                fn_name,
                fact.subject,
                index,
                @tagName(fact.provenance),
                @tagName(fact.invalidation_reason),
                fact.source.line,
                fact.source.column,
            });
        } else {
            try self.out.print(self.allocator, "/* mir pointer_provenance consumed fn={s} subject={s} provenance={s} reason={s} source={d}:{d} */\n", .{
                fn_name,
                fact.subject,
                @tagName(fact.provenance),
                @tagName(fact.invalidation_reason),
                fact.source.line,
                fact.source.column,
            });
        }
    }

    fn applyMirPointerProvenanceFact(self: *CEmitter, fact: mir.PointerProvenanceFact, locals: ?*std.StringHashMap(LocalInfo)) !void {
        if (!self.mirPointerFactSubjectSupportedNow(fact, locals)) return;
        try self.emitMirPointerProvenanceConsumedComment(fact);
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
        const ty = mirPointerFactSubjectRecoveredType(fact, locals) orelse return;
        if (self.fixedLocalPointerArrayElementType(ty) != null) {
            self.clearLocalArrayPointerElementsForLocal(fact.subject);
            return;
        }
        if (live_global) {
            try self.mir_pointer_local_provenance.put(fact.subject, .global_storage);
        } else if (mir_source_bridge.pointerFactIsLiveLocal(fact)) {
            try self.mir_pointer_local_provenance.put(fact.subject, .local_storage);
        } else {
            _ = self.mir_pointer_local_provenance.remove(fact.subject);
        }
    }

    fn applyMirPointerProvenanceFactsAtSource(self: *CEmitter, subject: []const u8, element_index: ?usize, span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactMatchesAt(fact, subject, element_index, span)) continue;
            matched = true;
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn applyMirPointerProvenanceInvalidationsAtCall(self: *CEmitter, span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) void {
        const function = self.currentMirFunction() orelse return;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactIsCallInvalidationAt(fact, span)) continue;
            if (fact.field_path) |field_path| {
                self.clearAggregatePointerFieldsForLocalPath(fact.subject, field_path);
                continue;
            }
            if (!self.mirPointerFactSubjectSupportedNow(fact, locals)) continue;
            if (fact.element_index != null) {
                self.clearLocalArrayPointerElementsForLocal(fact.subject);
            } else {
                if (mirPointerFactSubjectRecoveredType(fact, locals)) |ty| {
                    if (self.fixedLocalPointerArrayElementType(ty) != null) {
                        self.clearLocalArrayPointerElementsForLocal(fact.subject);
                        continue;
                    }
                }
                _ = self.mir_pointer_local_provenance.remove(fact.subject);
            }
        }
    }

    fn applyMirAggregatePointerFieldFactsAtSource(self: *CEmitter, subject: []const u8, field_path: []const u8, element_index: ?usize, span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.aggregatePointerFieldFactMatchesAt(fact, subject, field_path, element_index, span)) continue;
            matched = true;
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn applyMirAggregatePointerFieldFactsForSubjectAtSource(self: *CEmitter, subject: []const u8, span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!mir_source_bridge.pointerFactMatchesSubjectFieldAt(fact, subject, span)) continue;
            matched = true;
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn structLiteralFields(expr: ast_bridge.Expr) ?[]const ast_bridge.StructLiteralField {
        return switch (expr.kind) {
            .struct_literal => |fields| fields,
            .grouped => |inner| structLiteralFields(inner.*),
            else => null,
        };
    }

    fn applyMirAggregatePointerFieldFactsFromStructLiteral(self: *CEmitter, subject: []const u8, aggregate_ty: ast_bridge.TypeExpr, literal: ast_bridge.Expr, path_prefix: ?[]const u8, locals: *std.StringHashMap(LocalInfo)) !bool {
        const fields = structLiteralFields(literal) orelse return false;
        var matched = false;
        for (fields) |field| {
            const field_ty = self.memberFieldTypeFromAggregate(aggregate_ty, field.name.text) orelse continue;
            const field_path = if (path_prefix) |prefix|
                try self.joinAggregatePointerFieldPath(prefix, field.name.text)
            else
                field.name.text;
            if (isPointerLikeGlobalType(self.resolveAliasType(field_ty))) {
                const field_matched = try self.applyMirAggregatePointerFieldFactsAtSource(subject, field_path, null, field.value.span, locals);
                matched = matched or field_matched;
                if (!field_matched and self.directMirPointerContainerValueExpr(field.value, locals)) {
                    try self.setAggregatePointerFieldProvenance(subject, field_path, .unknown);
                    matched = true;
                }
                continue;
            }
            if (self.fixedLocalPointerArrayElementType(field_ty) != null) {
                self.clearAggregatePointerFieldsForLocalPath(subject, field_path);
                const items = arrayLiteralItems(field.value) orelse continue;
                for (items, 0..) |item, index| {
                    const element_matched = try self.applyMirAggregatePointerFieldFactsAtSource(subject, field_path, index, item.span, locals);
                    matched = matched or element_matched;
                    if (!element_matched and self.directMirPointerContainerValueExpr(item, locals)) {
                        const element_path = try self.aggregatePointerArrayElementPath(field_path, @intCast(index));
                        try self.setAggregatePointerFieldProvenance(subject, element_path, .unknown);
                        matched = true;
                    }
                }
                continue;
            }
            matched = (try self.applyMirAggregatePointerFieldFactsFromStructLiteral(subject, field_ty, field.value, field_path, locals)) or matched;
        }
        return matched;
    }

    fn directMirAddressProvenanceExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceExpr(inner.*, locals),
            .cast => |node| self.directMirAddressProvenanceExpr(node.value.*, locals),
            .address_of => |inner| self.directMirAddressProvenanceTarget(inner.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAddressProvenanceExpr(call.args[0], locals),
            else => false,
        };
    }

    fn directMirAddressProvenanceTarget(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceTarget(inner.*, locals),
            .ident => |ident| blk: {
                if (locals) |local_set| {
                    if (local_set.contains(ident.text)) break :blk true;
                }
                break :blk self.globals.contains(ident.text);
            },
            else => false,
        };
    }

    fn isMirAssumeNoaliasCall(self: *CEmitter, call: anytype) bool {
        return call.type_args.len == 0 and
            call.args.len == 2 and
            self.mirHasCallTargetKindAt(.assume_noalias, call.callee.*.span);
    }

    fn directMirRawManyZeroOffsetExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirRawManyZeroOffsetExpr(inner.*, locals),
            .cast => |node| self.directMirRawManyZeroOffsetExpr(node.value.*, locals),
            .call => |call| blk: {
                if (self.isMirAssumeNoaliasCall(call)) {
                    break :blk self.directMirRawManyZeroOffsetExpr(call.args[0], locals);
                }
                if (call.type_args.len != 0 or call.args.len != 1) break :blk false;
                const member = memberExpr(call.callee.*) orelse break :blk false;
                if (!std.mem.eql(u8, member.name.text, "offset")) break :blk false;
                if (localArrayConstIndexValue(call.args[0], locals) != 0) break :blk false;
                _ = self.directRawManyLocalName(member.base.*, locals) orelse break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn directRawManyLocalName(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .grouped => |inner| self.directRawManyLocalName(inner.*, locals),
            .ident => |ident| blk: {
                const ty = self.identTypeForEmissionRecovered(ident.text, expr.span, locals) orelse break :blk null;
                _ = self.rawManyPointerTypeFromCandidate(ty) orelse break :blk null;
                break :blk ident.text;
            },
            else => null,
        };
    }

    fn rawManyPointerTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .raw_many_pointer) ty else null;
    }

    fn directMirPointerLocalCopyExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirPointerLocalCopyExpr(inner.*, locals),
            .cast => |node| self.directMirPointerLocalCopyExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirPointerLocalCopyExpr(call.args[0], locals),
            .ident => |ident| blk: {
                const ty = self.identTypeForEmissionRecovered(ident.text, expr.span, locals) orelse break :blk false;
                break :blk isPointerLikeGlobalType(self.resolveAliasType(ty));
            },
            else => false,
        };
    }

    fn directMirFixedPointerArrayElementExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirFixedPointerArrayElementExpr(inner.*, locals),
            .cast => |node| self.directMirFixedPointerArrayElementExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirFixedPointerArrayElementExpr(call.args[0], locals),
            else => self.directLocalArrayElementPath(expr, locals) != null,
        };
    }

    fn directMirAggregatePointerFieldExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerFieldExpr(inner.*, locals),
            .cast => |node| self.directMirAggregatePointerFieldExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAggregatePointerFieldExpr(call.args[0], locals),
            else => self.directLocalAggregateMemberPath(expr, locals) != null,
        };
    }

    fn directMirAggregatePointerArrayElementExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerArrayElementExpr(inner.*, locals),
            .cast => |node| self.directMirAggregatePointerArrayElementExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAggregatePointerArrayElementExpr(call.args[0], locals),
            else => self.directLocalAggregateArrayElementPath(expr, locals) != null,
        };
    }

    fn directMirPointerContainerValueExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        switch (expr.kind) {
            .call => |call| {
                if (self.isMirAssumeNoaliasCall(call)) {
                    return self.directMirPointerContainerValueExpr(call.args[0], locals);
                }
            },
            else => {},
        }
        return self.directMirAddressProvenanceExpr(expr, locals) or
            self.directMirRawManyZeroOffsetExpr(expr, locals) or
            self.directMirPointerLocalCopyExpr(expr, locals) or
            self.directMirFixedPointerArrayElementExpr(expr, locals) or
            self.directMirAggregatePointerFieldExpr(expr, locals) or
            self.directMirAggregatePointerArrayElementExpr(expr, locals);
    }

    fn updatePointerProvenanceFromMir(self: *CEmitter, name: []const u8, ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!isPointerLikeGlobalType(self.resolveAliasType(ty))) {
            _ = self.mir_pointer_local_provenance.remove(name);
            return;
        }

        _ = self.mir_pointer_local_provenance.remove(name);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, initializer.span, locals);
    }

    fn updatePointerProvenanceAssignmentFromMir(self: *CEmitter, name: []const u8, ty: ast_bridge.TypeExpr, value: ast_bridge.Expr, span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!isPointerLikeGlobalType(self.resolveAliasType(ty))) {
            _ = self.mir_pointer_local_provenance.remove(name);
            return;
        }

        _ = self.mir_pointer_local_provenance.remove(name);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, value.span, locals);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, span, locals);
    }

    fn applyMirAggregateReturnPointerFacts(self: *CEmitter, dest_name: []const u8, dest_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr) !bool {
        const call = switch (initializer.kind) {
            .call => |call| call,
            .grouped => |inner| return self.applyMirAggregateReturnPointerFacts(dest_name, dest_ty, inner.*),
            else => return false,
        };
        const callee = calleeIdentName(call.callee.*) orelse return false;
        const fn_info = self.functions.get(callee) orelse return false;
        const return_ty = fn_info.return_type orelse return false;
        const source_struct = self.directStructTypeName(return_ty) orelse return false;
        const dest_struct = self.directStructTypeName(dest_ty) orelse return false;
        if (!std.mem.eql(u8, source_struct, dest_struct)) return false;
        if (!self.mirOwnsAggregateReturnSummary(callee)) return false;

        for (self.mir_module.aggregate_return_pointer_facts) |fact| {
            if (!std.mem.eql(u8, fact.callee, callee)) continue;
            if (fact.provenance != .global_storage) continue;
            try self.setAggregatePointerFieldProvenance(dest_name, fact.field_path, fact.provenance);
            try self.emitMirAggregateReturnPointerFactConsumedComment(fact);
        }
        // The summary marker owns this call shape even when it has no matching
        // field fact, so a stale or removed fact stays unknown.
        return true;
    }

    fn mirOwnsAggregateReturnSummary(self: *CEmitter, callee: []const u8) bool {
        for (self.mir_module.aggregate_return_summaries) |summary| {
            if (std.mem.eql(u8, summary.callee, callee)) return true;
        }
        return false;
    }

    fn emitMirAggregateReturnPointerFactConsumedComment(self: *CEmitter, fact: mir.AggregateReturnPointerFact) !void {
        const caller = self.current_function orelse return;
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "/* mir aggregate_return_pointer consumed caller={s} callee={s} field={s} provenance={s} source={d}:{d} */\n",
            .{ caller, fact.callee, fact.field_path, @tagName(fact.provenance), fact.source.line, fact.source.column },
        );
    }

    fn applyMirPointerProvenanceForLocalInitializer(self: *CEmitter, name: []const u8, ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (isPointerLikeGlobalType(self.resolveAliasType(ty))) {
            try self.updatePointerProvenanceFromMir(name, ty, initializer, locals);
            return;
        }
        if (self.isKnownStructType(ty)) {
            self.clearAggregatePointerFieldsForLocalPath(name, "");
            if (try self.applyMirAggregateReturnPointerFacts(name, ty, initializer)) return;
            if (self.directAggregateCopySourceExpr(initializer, ty, locals)) {
                _ = try self.applyMirAggregatePointerFieldFactsForSubjectAtSource(name, initializer.span, locals);
                return;
            }
            _ = try self.applyMirAggregatePointerFieldFactsFromStructLiteral(name, ty, initializer, null, locals);
            return;
        }
        if (self.fixedLocalPointerArrayElementType(ty) == null) return;
        const items = arrayLiteralItems(initializer) orelse return;
        for (items, 0..) |item, index| {
            const matched = try self.applyMirPointerProvenanceFactsAtSource(name, index, item.span, locals);
            if (!matched and self.directMirPointerContainerValueExpr(item, locals)) {
                try self.setLocalArrayPointerElementProvenance(name, @intCast(index), .unknown);
            }
        }
    }

    fn directLocalName(expr: ast_bridge.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| directLocalName(inner.*),
            else => null,
        };
    }

    fn directStructTypeName(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return self.structNameFromCandidate(ty);
    }

    fn structNameFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        const name = typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.structs.contains(name)) name else null;
    }

    fn directAggregateCopySourceExpr(self: *CEmitter, expr: ast_bridge.Expr, target_ty: ast_bridge.TypeExpr, locals: *std.StringHashMap(LocalInfo)) bool {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return false;
        return self.directAggregateCopySourceExprForStruct(expr, target_struct_name, locals);
    }

    fn directAggregateCopySourceExprForStruct(self: *CEmitter, expr: ast_bridge.Expr, target_struct_name: []const u8, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directAggregateCopySourceExprForStruct(inner.*, target_struct_name, locals),
            .cast => |node| self.directAggregateCopySourceExprForStruct(node.value.*, target_struct_name, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and self.directAggregateCopySourceExprForStruct(call.args[0], target_struct_name, locals),
            .ident => |ident| blk: {
                const source_ty = self.identTypeForEmissionRecovered(ident.text, expr.span, locals) orelse break :blk false;
                const source_struct_name = self.directStructTypeName(source_ty) orelse break :blk false;
                break :blk std.mem.eql(u8, source_struct_name, target_struct_name);
            },
            .member => blk: {
                _ = self.directLocalAggregateMemberPath(expr, locals) orelse break :blk false;
                const source_ty = self.generatedAggregateMemberCopySourceTypeForEmission(expr, locals) orelse break :blk false;
                const source_struct_name = self.directStructTypeName(source_ty) orelse break :blk false;
                break :blk std.mem.eql(u8, source_struct_name, target_struct_name);
            },
            else => false,
        };
    }

    fn generatedAggregateMemberCopySourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| return fact.target_ty;
        return self.generatedAggregateMemberCopyFallbackTypeForEmission(expr, locals);
    }

    fn generatedAggregateMemberCopyFallbackTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        return self.generatedAggregateMemberCopyStorageOrSourceType(expr, locals);
    }

    fn generatedAggregateMemberCopyStorageOrSourceType(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn applyMirPointerProvenanceForAssignment(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo)) !void {
        switch (target.kind) {
            .grouped => |inner| return self.applyMirPointerProvenanceForAssignment(inner.*, value, span, locals),
            .member => |member| {
                const path = self.directLocalAggregateMemberPath(target, locals) orelse return;
                const field_ty = self.memberFieldType(member.base.*, member.name.text, locals) orelse return;
                if (isPointerLikeGlobalType(self.resolveAliasType(field_ty))) {
                    if (try self.applyMirAggregatePointerFieldFactsAtSource(path.local_name, path.field_path, null, value.span, locals)) return;
                    if (self.directMirPointerContainerValueExpr(value, locals)) {
                        try self.setAggregatePointerFieldProvenance(path.local_name, path.field_path, .unknown);
                        return;
                    }
                }
                if (self.isKnownStructType(field_ty)) {
                    self.clearAggregatePointerFieldsForLocalPath(path.local_name, path.field_path);
                    if (self.directAggregateCopySourceExpr(value, field_ty, locals)) {
                        _ = try self.applyMirAggregatePointerFieldFactsForSubjectAtSource(path.local_name, value.span, locals);
                        return;
                    }
                    _ = try self.applyMirAggregatePointerFieldFactsFromStructLiteral(path.local_name, field_ty, value, path.field_path, locals);
                }
                return;
            },
            .ident => |ident| {
                const name = ident.text;
                const ty = self.identTypeForEmissionRecovered(name, target.span, locals) orelse return;
                if (isPointerLikeGlobalType(self.resolveAliasType(ty))) {
                    try self.updatePointerProvenanceAssignmentFromMir(name, ty, value, span, locals);
                    return;
                }
                if (self.isKnownStructType(ty)) {
                    self.clearAggregatePointerFieldsForLocalPath(name, "");
                    if (try self.applyMirAggregateReturnPointerFacts(name, ty, value)) return;
                    if (self.directAggregateCopySourceExpr(value, ty, locals)) {
                        _ = try self.applyMirAggregatePointerFieldFactsForSubjectAtSource(name, value.span, locals);
                        return;
                    }
                    _ = try self.applyMirAggregatePointerFieldFactsFromStructLiteral(name, ty, value, null, locals);
                    return;
                }
                if (self.fixedLocalPointerArrayElementType(ty) == null) return;
                _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, span, locals);
                const items = arrayLiteralItems(value) orelse return;
                for (items, 0..) |item, index| {
                    const matched = try self.applyMirPointerProvenanceFactsAtSource(name, index, item.span, locals);
                    if (!matched and self.directMirPointerContainerValueExpr(item, locals)) {
                        try self.setLocalArrayPointerElementProvenance(name, @intCast(index), .unknown);
                    }
                }
                return;
            },
            else => return,
        }
    }

    fn applyMirPointerProvenanceForIndexAssignment(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo)) !void {
        if (self.directLocalAggregateArrayElementPath(target, locals)) |aggregate_path| {
            const index_node = switch (target.kind) {
                .index => |node| node,
                .grouped => |inner| switch (inner.kind) {
                    .index => |node| node,
                    else => return,
                },
                else => return,
            };
            const field_path = self.directLocalAggregateMemberPath(index_node.base.*, locals) orelse return;
            const index = localArrayConstIndexValue(index_node.index.*, locals) orelse return;
            if (try self.applyMirAggregatePointerFieldFactsAtSource(field_path.local_name, field_path.field_path, index, value.span, locals)) return;
            if (self.directMirPointerContainerValueExpr(value, locals)) {
                try self.setAggregatePointerFieldProvenance(aggregate_path.local_name, aggregate_path.field_path, .unknown);
                return;
            }
        }
        const path = self.directLocalArrayElementPath(target, locals) orelse {
            const node = switch (target.kind) {
                .index => |node| node,
                .grouped => |inner| return self.applyMirPointerProvenanceForIndexAssignment(inner.*, value, span, locals),
                else => return,
            };
            if (self.directLocalPointerArrayBaseName(node.base.*, locals)) |local_name| {
                _ = try self.applyMirPointerProvenanceFactsAtSource(local_name, null, span, locals);
            }
            return;
        };
        const matched_value = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, path.index, value.span, locals);
        _ = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, path.index, span, locals);
        _ = try self.applyMirPointerProvenanceFactsAtSource(path.local_name, null, span, locals);
        if (!matched_value and self.directMirPointerContainerValueExpr(value, locals)) {
            try self.setLocalArrayPointerElementProvenance(path.local_name, path.index, .unknown);
        }
    }

    const DerefAccessLowering = union(enum) {
        plain,
        race_scalar: GlobalInfo,
        race_pointer: GlobalInfo,
    };

    const RaceAggregateKind = union(enum) {
        scalar: GlobalInfo,
        pointer: GlobalInfo,
        slice: ast_bridge.TypeExpr,
        @"struct": ast_bridge.StructDecl,
        array: ast_bridge.TypeExpr,
        dyn_trait: []const u8,
        closure: []const u8,
        value_optional: ast_bridge.TypeExpr,
        result: struct { ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr },
        tagged_union: ast_bridge.UnionDecl,
    };

    // Positive locality proof for the bare pointer-deref access class (spec I.13):
    // PLAIN deref lowering is allowed only when the pointer provably names the
    // current function's own storage — a live MIR local_storage fact for the
    // pointer local, or a syntactic address-of a named local (through grouped/
    // cast). Everything else lowers race-tolerantly.
    fn derefPointerHasProvenLocalStorage(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (locals) |local_set| {
            if (self.directLocalArrayElementPath(inner, local_set)) |path| {
                if (self.localArrayElementPointerProvenance(path.local_name, path.index)) |provenance| return provenance == .local_storage;
            }
        }
        if (self.directLocalAggregateArrayElementPath(inner, locals)) |path| {
            if (self.aggregateFieldPointerProvenance(path.local_name, path.field_path)) |provenance| return provenance == .local_storage;
        }
        if (self.directLocalAggregateMemberPath(inner, locals)) |path| {
            if (self.aggregateFieldPointerProvenance(path.local_name, path.field_path)) |provenance| return provenance == .local_storage;
        }
        return switch (inner.kind) {
            .ident => |ident| blk: {
                const local_set = locals orelse break :blk false;
                if (!local_set.contains(ident.text)) break :blk false;
                if (self.mir_pointer_local_provenance.get(ident.text)) |provenance| break :blk provenance == .local_storage;
                break :blk false;
            },
            .address_of => |target| directLocalStorageTarget(target.*, locals),
            .grouped => |wrapped| self.derefPointerHasProvenLocalStorage(wrapped.*, locals),
            .cast => |node| self.derefPointerHasProvenLocalStorage(node.value.*, locals),
            else => false,
        };
    }

    // Only a bare named local counts: member/index roots may reach through a
    // pointer-typed base (auto-deref), which does NOT prove the storage is local.
    fn directLocalStorageTarget(expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |wrapped| directLocalStorageTarget(wrapped.*, locals),
            .ident => |ident| if (locals) |local_set| local_set.contains(ident.text) else false,
            else => false,
        };
    }

    // Spec I.13 conservative default for the bare pointer-deref class: an
    // ordinary scalar deref lowers race-tolerantly (mc_race helpers for helper
    // scalars, relaxed __atomic_*_n for pointer-shaped pointees) unless the
    // pointer is positively proven local. Aggregate pointees stay on the plain
    // structural path here so pointer-to-array/member-base forms can use their
    // dedicated access-class handling; aggregate value-copy/store contexts fail
    // closed before they reach plain C aggregate copying. Scalars with no sound
    // race-tolerant lowering (u128/i128) fail emission closed.
    fn derefAccessLowering(self: *CEmitter, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) !DerefAccessLowering {
        const pointee_ty = self.derefPointeeType(inner, locals) orelse return .plain;
        return self.derefAccessLoweringForPointee(inner, pointee_ty, locals);
    }

    fn derefAccessLoweringForPointee(self: *CEmitter, inner: ast_bridge.Expr, pointee_ty: ast_bridge.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !DerefAccessLowering {
        if (self.derefPointerHasProvenLocalStorage(inner, locals)) return .plain;
        const info = self.globalInfoFromType(pointee_ty) catch return .plain;
        if (info.aggregate) return .plain;
        if (info.pointer_like) return .{ .race_pointer = info };
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        return .{ .race_scalar = info };
    }

    fn emitRaceTolerantDerefStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inner = switch (target.kind) {
            .deref => |ptr| ptr.*,
            .grouped => |wrapped| return try self.emitRaceTolerantDerefStoreStmt(wrapped.*, value, locals),
            else => return false,
        };
        if (!self.derefPointerHasProvenLocalStorage(inner, locals)) {
            if (self.derefPointeeType(inner, locals)) |pointee_ty| {
                const info = self.globalInfoFromType(pointee_ty) catch null;
                if (info) |global_info| {
                    if (global_info.aggregate) {
                        const value_temp = try self.emitSequencedCallArgTemp(value, locals, pointee_ty);
                        const ptr_ty = try self.pointerTypeFor(pointee_ty, .mut, .typedef_name);
                        const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
                        self.temp_index += 1;
                        try self.writeIndent();
                        try self.out.print(self.allocator, "{s} {s} = ", .{ ptr_ty, ptr_name });
                        try self.emitExpr(inner, locals);
                        try self.out.appendSlice(self.allocator, ";\n");
                        try self.emitRaceTolerantAggregateStoreFromPtr(ptr_name, pointee_ty, value_temp.name);
                        return true;
                    }
                }
            }
        }
        switch (try self.derefAccessLowering(inner, locals)) {
            .plain => return false,
            .race_scalar => |info| {
                const pointee_ty = self.derefPointeeType(inner, locals) orelse return false;
                const value_temp = try self.emitSequencedCallArgTemp(value, locals, pointee_ty);
                try self.writeIndent();
                try self.out.print(self.allocator, "mc_race_store_{s}(", .{info.race_type_name});
                try self.emitExpr(inner, locals);
                try self.out.print(self.allocator, ", ({s}){s});\n", .{ info.race_c_type, value_temp.name });
                return true;
            },
            .race_pointer => |info| {
                const pointee_ty = self.derefPointeeType(inner, locals) orelse return false;
                const value_temp = try self.emitSequencedCallArgTemp(value, locals, pointee_ty);
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "__atomic_store_n(");
                try self.emitExpr(inner, locals);
                try self.out.print(self.allocator, ", ({s}){s}, __ATOMIC_RELAXED);\n", .{ info.c_type, value_temp.name });
                return true;
            },
        }
    }

    fn emitRaceTolerantAggregateDerefExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
        const inner = switch (expr.kind) {
            .deref => |ptr| ptr.*,
            .grouped => |wrapped| return try self.emitRaceTolerantAggregateDerefExpr(wrapped.*, locals, target_ty),
            else => return false,
        };
        if (self.derefPointerHasProvenLocalStorage(inner, locals)) return false;
        const pointee_ty = self.derefPointeeType(inner, locals) orelse return false;
        const info = self.globalInfoFromType(pointee_ty) catch return false;
        if (!info.aggregate) return false;
        _ = target_ty orelse return false;
        const ptr_ty = try self.pointerTypeFor(pointee_ty, .mut, .typedef_name);
        const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ {s} {s} = ", .{ ptr_ty, ptr_name });
        try self.emitExpr(inner, locals);
        try self.out.appendSlice(self.allocator, "; ");
        try self.emitRaceTolerantAggregateLoadFromPtr(ptr_name, pointee_ty);
        try self.out.appendSlice(self.allocator, "; })");
        return true;
    }

    fn raceAggregateKind(self: *CEmitter, ty: ast_bridge.TypeExpr) !RaceAggregateKind {
        const info = try self.globalInfoFromType(ty);
        if (!info.aggregate) {
            if (info.pointer_like) return .{ .pointer = info };
            if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
            return .{ .scalar = info };
        }
        const resolved = self.resolveAliasType(ty);
        if (self.nullablePayloadFromCandidate(resolved)) |child| {
            if (self.valueOptionalPayloadFromCandidate(ty)) |value_child| return .{ .value_optional = value_child };
            return self.raceAggregateKind(child);
        }
        if (self.dynTraitNameFromCandidate(resolved) != null) return .{ .dyn_trait = try self.cTypeFor(resolved, .typedef_name) };
        if (self.closureNodeFromCandidate(resolved) != null) return .{ .closure = try self.cTypeFor(resolved, .typedef_name) };
        if (typeName(resolved)) |name| {
            if (self.tagged_unions.get(name)) |union_decl| return .{ .tagged_union = union_decl };
        }
        switch (resolved.kind) {
            .slice => return .{ .slice = resolved },
            .array => return .{ .array = resolved },
            .generic => |node| {
                if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                    return .{ .result = .{ .ok_ty = node.args[0], .err_ty = node.args[1] } };
                }
                return error.UnsupportedCEmission;
            },
            .name => |name| {
                const decl = self.structs.get(name.text) orelse return error.UnsupportedCEmission;
                if (decl.is_c_union) return error.UnsupportedCEmission;
                return .{ .@"struct" = decl };
            },
            else => return error.UnsupportedCEmission,
        }
    }

    fn emitRaceTolerantAggregateLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast_bridge.TypeExpr) anyerror!void {
        switch (try self.raceAggregateKind(ty)) {
            .scalar => |info| try self.out.print(self.allocator, "(({s})mc_race_load_{s}({s}))", .{ info.c_type, info.race_type_name, ptr_expr }),
            .pointer => |info| try self.out.print(self.allocator, "(({s})__atomic_load_n({s}, __ATOMIC_RELAXED))", .{ info.c_type, ptr_expr }),
            .slice => |slice_ty| try self.out.print(self.allocator, "({s}){{ .ptr = __atomic_load_n(&(({s})->ptr), __ATOMIC_RELAXED), .len = (size_t)mc_race_load_usize(&(({s})->len)) }}", .{
                try self.cTypeFor(slice_ty, .typedef_name),
                ptr_expr,
                ptr_expr,
            }),
            .@"struct" => |decl| {
                try self.out.print(self.allocator, "({s}){{ ", .{try self.cTypeFor(ty, .typedef_name)});
                for (decl.fields, 0..) |field, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const field_name = try self.cIdent(field.name.text);
                    try self.out.print(self.allocator, ".{s} = ", .{field_name});
                    const field_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->{s})", .{ ptr_expr, field_name });
                    try self.emitRaceTolerantAggregateLoadFromPtr(field_ptr, field.ty);
                }
                try self.out.appendSlice(self.allocator, " }");
            },
            .array => |array_ty| {
                const array = array_ty.kind.array;
                const len = self.constArrayLen(array.len) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(array_ty, .typedef_name)});
                for (0..len) |i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const elem_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->elems[{d}])", .{ ptr_expr, i });
                    try self.emitRaceTolerantAggregateLoadFromPtr(elem_ptr, array.child.*);
                }
                try self.out.appendSlice(self.allocator, " } }");
            },
            .dyn_trait => |dyn_ty| try self.out.print(self.allocator, "(({s}){{ .data = __atomic_load_n(&(({s})->data), __ATOMIC_RELAXED), .vtable = __atomic_load_n(&(({s})->vtable), __ATOMIC_RELAXED) }})", .{
                dyn_ty,
                ptr_expr,
                ptr_expr,
            }),
            .closure => |closure_ty| try self.out.print(self.allocator, "(({s}){{ .code = __atomic_load_n(&(({s})->code), __ATOMIC_RELAXED), .env = __atomic_load_n(&(({s})->env), __ATOMIC_RELAXED) }})", .{
                closure_ty,
                ptr_expr,
                ptr_expr,
            }),
            .value_optional => |child| try self.emitRaceTolerantValueOptionalLoadFromPtr(ptr_expr, ty, child),
            .result => |result| try self.emitRaceTolerantResultLoadFromPtr(ptr_expr, ty, result.ok_ty, result.err_ty),
            .tagged_union => |decl| try self.emitRaceTolerantTaggedUnionLoadFromPtr(ptr_expr, ty, decl),
        }
    }

    fn emitRaceTolerantAggregateStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast_bridge.TypeExpr, value_expr: []const u8) anyerror!void {
        switch (try self.raceAggregateKind(ty)) {
            .scalar => |info| {
                try self.writeIndent();
                try self.out.print(self.allocator, "mc_race_store_{s}({s}, ({s}){s});\n", .{ info.race_type_name, ptr_expr, info.race_c_type, value_expr });
            },
            .pointer => |info| {
                try self.writeIndent();
                try self.out.print(self.allocator, "__atomic_store_n({s}, ({s}){s}, __ATOMIC_RELAXED);\n", .{ ptr_expr, info.c_type, value_expr });
            },
            .slice => {
                try self.writeIndent();
                try self.out.print(self.allocator, "__atomic_store_n(&(({s})->ptr), {s}.ptr, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
                try self.writeIndent();
                try self.out.print(self.allocator, "mc_race_store_usize(&(({s})->len), (uintptr_t){s}.len);\n", .{ ptr_expr, value_expr });
            },
            .@"struct" => |decl| {
                for (decl.fields) |field| {
                    const field_name = try self.cIdent(field.name.text);
                    const field_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->{s})", .{ ptr_expr, field_name });
                    const field_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{ value_expr, field_name });
                    try self.emitRaceTolerantAggregateStoreFromPtr(field_ptr, field.ty, field_value);
                }
            },
            .array => |array_ty| {
                const array = array_ty.kind.array;
                const len = self.constArrayLen(array.len) orelse return error.UnsupportedCEmission;
                for (0..len) |i| {
                    const elem_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->elems[{d}])", .{ ptr_expr, i });
                    const elem_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.elems[{d}]", .{ value_expr, i });
                    try self.emitRaceTolerantAggregateStoreFromPtr(elem_ptr, array.child.*, elem_value);
                }
            },
            .dyn_trait => try self.emitRaceTolerantDynTraitStoreFromPtr(ptr_expr, value_expr),
            .closure => try self.emitRaceTolerantClosureStoreFromPtr(ptr_expr, value_expr),
            .value_optional => |child| try self.emitRaceTolerantValueOptionalStoreFromPtr(ptr_expr, value_expr, child),
            .result => |result| try self.emitRaceTolerantResultStoreFromPtr(ptr_expr, value_expr, result.ok_ty, result.err_ty),
            .tagged_union => |decl| try self.emitRaceTolerantTaggedUnionStoreFromPtr(ptr_expr, decl, value_expr),
        }
    }

    fn emitRaceTolerantDynTraitStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8) !void {
        try self.writeIndent();
        try self.out.print(self.allocator, "__atomic_store_n(&(({s})->data), {s}.data, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
        try self.writeIndent();
        try self.out.print(self.allocator, "__atomic_store_n(&(({s})->vtable), {s}.vtable, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
    }

    fn emitRaceTolerantClosureStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8) !void {
        try self.writeIndent();
        try self.out.print(self.allocator, "__atomic_store_n(&(({s})->env), {s}.env, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
        try self.writeIndent();
        try self.out.print(self.allocator, "__atomic_store_n(&(({s})->code), {s}.code, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
    }

    fn emitRaceTolerantValueOptionalLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast_bridge.TypeExpr, child: ast_bridge.TypeExpr) anyerror!void {
        const optional_ty = try self.cTypeFor(ty, .typedef_name);
        const value_name = try self.nextTempName();
        const tag_name = try self.nextTempName();
        try self.out.print(self.allocator, "({{ {s} {s} = ({s}){{0}}; bool {s} = mc_race_load_bool(&(({s})->present)); {s}.present = {s}; if ({s}) {{ {s}.value = ", .{
            optional_ty,
            value_name,
            optional_ty,
            tag_name,
            ptr_expr,
            value_name,
            tag_name,
            tag_name,
            value_name,
        });
        const payload_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->value)", .{ptr_expr});
        try self.emitRaceTolerantAggregateLoadFromPtr(payload_ptr, child);
        try self.out.print(self.allocator, "; }} {s}; }})", .{value_name});
    }

    fn emitRaceTolerantValueOptionalStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8, child: ast_bridge.TypeExpr) anyerror!void {
        const payload_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->value)", .{ptr_expr});
        const payload_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.value", .{value_expr});
        try self.emitRaceTolerantAggregateStoreFromPtr(payload_ptr, child, payload_value);
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_bool(&(({s})->present), (bool){s}.present);\n", .{ ptr_expr, value_expr });
    }

    fn emitRaceTolerantResultLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast_bridge.TypeExpr, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) anyerror!void {
        const result_ty = try self.cTypeFor(ty, .typedef_name);
        const value_name = try self.nextTempName();
        const tag_name = try self.nextTempName();
        try self.out.print(self.allocator, "({{ {s} {s} = ({s}){{0}}; bool {s} = mc_race_load_bool(&(({s})->is_ok)); {s}.is_ok = {s}; if ({s}) {{ {s}.payload.ok = ", .{
            result_ty,
            value_name,
            result_ty,
            tag_name,
            ptr_expr,
            value_name,
            tag_name,
            tag_name,
            value_name,
        });
        const ok_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.ok)", .{ptr_expr});
        try self.emitRaceTolerantAggregateLoadFromPtr(ok_ptr, ok_ty);
        try self.out.print(self.allocator, "; }} else {{ {s}.payload.err = ", .{value_name});
        const err_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.err)", .{ptr_expr});
        try self.emitRaceTolerantAggregateLoadFromPtr(err_ptr, err_ty);
        try self.out.print(self.allocator, "; }} {s}; }})", .{value_name});
    }

    fn emitRaceTolerantResultStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) anyerror!void {
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s}.is_ok) {{\n", .{value_expr});
        self.indent += 1;
        const ok_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.ok)", .{ptr_expr});
        const ok_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.payload.ok", .{value_expr});
        try self.emitRaceTolerantAggregateStoreFromPtr(ok_ptr, ok_ty, ok_value);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "} else {\n");
        self.indent += 1;
        const err_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.err)", .{ptr_expr});
        const err_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.payload.err", .{value_expr});
        try self.emitRaceTolerantAggregateStoreFromPtr(err_ptr, err_ty, err_value);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_bool(&(({s})->is_ok), (bool){s}.is_ok);\n", .{ ptr_expr, value_expr });
    }

    fn emitRaceTolerantTaggedUnionLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast_bridge.TypeExpr, union_decl: ast_bridge.UnionDecl) anyerror!void {
        const union_ty = try self.cTypeFor(ty, .typedef_name);
        const union_name = union_decl.name.text;
        const value_name = try self.nextTempName();
        const tag_name = try self.nextTempName();

        try self.out.print(self.allocator, "({{ {s} {s} = ({s}){{0}}; {s}Tag {s} = __atomic_load_n(&(({s})->tag), __ATOMIC_RELAXED); {s}.tag = {s}; switch ({s}) {{ ", .{
            union_ty,
            value_name,
            union_ty,
            union_name,
            tag_name,
            ptr_expr,
            value_name,
            tag_name,
            tag_name,
        });
        for (union_decl.cases) |case| {
            try self.out.print(self.allocator, "case {s}Tag_{s}: ", .{ union_name, case.name.text });
            if (case.ty) |payload_ty| {
                const payload_name = try cPayloadFieldName(self.scratch.allocator(), case.name.text);
                const payload_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.{s})", .{ ptr_expr, payload_name });
                try self.out.print(self.allocator, "{s}.payload.{s} = ", .{ value_name, payload_name });
                try self.emitRaceTolerantAggregateLoadFromPtr(payload_ptr, payload_ty);
                try self.out.appendSlice(self.allocator, "; ");
            }
            try self.out.appendSlice(self.allocator, "break; ");
        }
        try self.out.print(self.allocator, "default: break; }} {s}; }})", .{value_name});
    }

    fn emitRaceTolerantTaggedUnionStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, union_decl: ast_bridge.UnionDecl, value_expr: []const u8) anyerror!void {
        const union_name = union_decl.name.text;
        for (union_decl.cases) |case| {
            const payload_ty = case.ty orelse continue;
            const payload_name = try cPayloadFieldName(self.scratch.allocator(), case.name.text);
            try self.writeIndent();
            try self.out.print(self.allocator, "if ({s}.tag == {s}Tag_{s}) {{\n", .{ value_expr, union_name, case.name.text });
            self.indent += 1;
            const payload_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->payload.{s})", .{ ptr_expr, payload_name });
            const payload_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.payload.{s}", .{ value_expr, payload_name });
            try self.emitRaceTolerantAggregateStoreFromPtr(payload_ptr, payload_ty, payload_value);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        try self.writeIndent();
        try self.out.print(self.allocator, "__atomic_store_n(&(({s})->tag), {s}.tag, __ATOMIC_RELAXED);\n", .{ ptr_expr, value_expr });
    }

    fn constArrayLen(self: *CEmitter, expr: ast_bridge.Expr) ?usize {
        var reflect_env = lower_c_reflect.ReflectEnv{
            .structs = &self.structs,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .enums = &self.enums,
            .type_aliases = &self.type_aliases,
            .const_fns = &self.const_fns,
            .const_globals = &self.const_globals,
        };
        const len = constArrayLenValue(expr, &self.const_fns, &self.const_globals, lower_c_reflect.comptimeReflectThunk, &reflect_env) orelse return null;
        return std.math.cast(usize, len);
    }

    fn emitRaceTolerantPointerMemberStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const member = switch (target.kind) {
            .member => |node| node,
            .grouped => |wrapped| return try self.emitRaceTolerantPointerMemberStoreStmt(wrapped.*, value, locals),
            else => return false,
        };
        if (!self.exprHasPointerType(member.base.*, locals)) return false;
        const field_ty = self.operandEmitType(target, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (info.aggregate) {
            if (self.derefPointerHasProvenLocalStorage(member.base.*, locals)) return false;
            const value_temp = try self.emitSequencedCallArgTemp(value, locals, field_ty);
            const base_ty = self.memberBaseTypeForEmission(member.base.*, locals) orelse return false;
            const base_c_ty = try self.cTypeFor(base_ty, .typedef_name);
            const base_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            const field_name = try self.cIdent(member.name.text);
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ", .{ base_c_ty, base_name });
            try self.emitExpr(member.base.*, locals);
            try self.out.appendSlice(self.allocator, ";\n");
            const field_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&({s}->{s})", .{ base_name, field_name });
            try self.emitRaceTolerantAggregateStoreFromPtr(field_ptr, field_ty, value_temp.name);
            return true;
        }
        const field_name = try self.cIdent(member.name.text);
        const value_temp = try self.emitSequencedCallArgTemp(value, locals, field_ty);
        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            try self.emitExpr(member.base.*, locals);
            try self.out.print(self.allocator, "->{s}), ({s}){s}, __ATOMIC_RELAXED);\n", .{ field_name, info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        try self.emitExpr(member.base.*, locals);
        try self.out.print(self.allocator, "->{s}), ({s}){s});\n", .{ field_name, info.race_c_type, value_temp.name });
        return true;
    }

    fn emitRaceTolerantPointerMemberAggregateExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
        const member = switch (expr.kind) {
            .member => |node| node,
            .grouped => |wrapped| return try self.emitRaceTolerantPointerMemberAggregateExpr(wrapped.*, locals, target_ty),
            else => return false,
        };
        if (!self.exprHasPointerType(member.base.*, locals)) return false;
        if (self.derefPointerHasProvenLocalStorage(member.base.*, locals)) return false;
        const field_ty = self.memberFieldType(member.base.*, member.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (!info.aggregate) return false;
        _ = target_ty orelse return false;
        const base_ty = self.memberBaseTypeForEmission(member.base.*, locals) orelse return false;
        const base_c_ty = try self.cTypeFor(base_ty, .typedef_name);
        const base_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
        self.temp_index += 1;
        const field_name = try self.cIdent(member.name.text);
        try self.out.print(self.allocator, "({{ {s} {s} = ", .{ base_c_ty, base_name });
        try self.emitExpr(member.base.*, locals);
        try self.out.appendSlice(self.allocator, "; ");
        const field_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&({s}->{s})", .{ base_name, field_name });
        try self.emitRaceTolerantAggregateLoadFromPtr(field_ptr, field_ty);
        try self.out.appendSlice(self.allocator, "; })");
        return true;
    }

    fn emitRaceTolerantNestedPointerMemberAggregateExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const path = try self.pointerMemberPath(expr, locals, &fields) orelse return false;
        if (self.derefPointerHasProvenLocalStorage(path.root, locals)) return false;
        const field_ty = self.pointerMemberPathFinalType(path.root, path.fields, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (!info.aggregate) return false;
        _ = target_ty orelse return false;
        const root_ty = self.memberBaseTypeForEmission(path.root, locals) orelse return false;
        const root_c_ty = try self.cTypeFor(root_ty, .typedef_name);
        const root_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ {s} {s} = ", .{ root_c_ty, root_name });
        try self.emitExpr(path.root, locals);
        try self.out.appendSlice(self.allocator, "; ");
        const field_ptr = try self.pointerMemberPathPtrExpr(root_name, path.fields);
        try self.emitRaceTolerantAggregateLoadFromPtr(field_ptr, field_ty);
        try self.out.appendSlice(self.allocator, "; })");
        return true;
    }

    fn emitRaceTolerantIndexedMemberAggregateExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const index = try self.collectIndexedMemberPath(expr, locals, &fields) orelse return false;
        if (fields.items.len == 0) return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.indexedMemberPathFinalType(index, fields.items, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        if (!info.aggregate) return false;
        _ = target_ty orelse return false;
        const usize_ty = simpleNameType("usize", index.index.*.span);
        const usize_c_ty = try self.cTypeFor(usize_ty, .typedef_name);
        const index_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_idx{d}", .{self.temp_index});
        self.temp_index += 1;
        const ptr_ty = try self.pointerTypeFor(field_ty, .mut, .typedef_name);
        const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.out.print(self.allocator, "({{ {s} {s} = ", .{ usize_c_ty, index_name });
        try self.emitExpr(index.index.*, locals);
        try self.out.print(self.allocator, "; {s} {s} = &(", .{ ptr_ty, ptr_name });
        if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, index_name)) return false;
        try self.out.appendSlice(self.allocator, "); ");
        try self.emitRaceTolerantAggregateLoadFromPtr(ptr_name, field_ty);
        try self.out.appendSlice(self.allocator, "; })");
        return true;
    }

    fn ambiguousPointerMemberAggregateValueCopy(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (expr.kind) {
            .member => |node| node,
            .grouped => |wrapped| return try self.ambiguousPointerMemberAggregateValueCopy(wrapped.*, locals),
            else => return false,
        };
        if (!self.exprHasPointerType(member.base.*, locals)) return false;
        if (self.derefPointerHasProvenLocalStorage(member.base.*, locals)) return false;
        const field_ty = self.memberFieldType(member.base.*, member.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        return info.aggregate;
    }

    fn ambiguousIndexedMemberAggregateValueCopy(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (expr.kind) {
            .member => |node| node,
            .grouped => |wrapped| return try self.ambiguousIndexedMemberAggregateValueCopy(wrapped.*, locals),
            else => return false,
        };
        const index = indexExpr(member.base.*) orelse return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.memberFieldType(member.base.*, member.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        return info.aggregate;
    }

    fn ambiguousAggregateDerefValueCopy(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const inner = switch (expr.kind) {
            .deref => |ptr| ptr.*,
            .grouped => |wrapped| return try self.ambiguousAggregateDerefValueCopy(wrapped.*, locals),
            else => return false,
        };
        if (self.derefPointerHasProvenLocalStorage(inner, locals)) return false;
        const pointee_ty = self.derefPointeeType(inner, locals) orelse return false;
        const info = self.globalInfoFromType(pointee_ty) catch return false;
        return info.aggregate;
    }

    fn emitRaceTolerantSliceIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), slice: SliceAccess, element_ty: ast_bridge.TypeExpr) anyerror!bool {
        const info = self.globalInfoFromType(element_ty) catch return false;
        if (info.aggregate) {
            const usize_ty = simpleNameType("usize", node.index.*.span);
            const usize_c_ty = try self.cTypeFor(usize_ty, .typedef_name);
            const index_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_idx{d}", .{self.temp_index});
            self.temp_index += 1;
            const ptr_ty = try self.pointerTypeFor(element_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.out.print(self.allocator, "({{ {s} {s} = ", .{ usize_c_ty, index_name });
            try self.emitExpr(node.index.*, locals);
            try self.out.print(self.allocator, "; {s} {s} = &(", .{ ptr_ty, ptr_name });
            try self.emitExpr(node.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_name });
            try self.emitExpr(node.base.*, locals);
            try self.out.print(self.allocator, ".{s})]); ", .{slice.len_field});
            try self.emitRaceTolerantAggregateLoadFromPtr(ptr_name, element_ty);
            try self.out.appendSlice(self.allocator, "; })");
            return true;
        }
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            try self.emitSliceIndexExpr(node, locals, slice);
            try self.out.appendSlice(self.allocator, "), __ATOMIC_RELAXED))");
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        try self.emitSliceIndexExpr(node, locals, slice);
        try self.out.appendSlice(self.allocator, ")))");
        return true;
    }

    fn emitRaceTolerantSliceIndexStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const index = switch (target.kind) {
            .index => |node| node,
            .grouped => |wrapped| return try self.emitRaceTolerantSliceIndexStoreStmt(wrapped.*, value, locals),
            else => return false,
        };
        const slice = self.sliceAccessForBase(index.base.*, locals) orelse return false;
        const element_ty = self.operandEmitType(target, locals) orelse return false;
        const info = self.globalInfoFromType(element_ty) catch return false;

        const value_temp = try self.emitSequencedCallArgTemp(value, locals, element_ty);
        const usize_ty = simpleNameType("usize", index.index.*.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        if (info.aggregate) {
            const ptr_ty = try self.pointerTypeFor(element_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = &(", .{ ptr_ty, ptr_name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})]);\n", .{slice.len_field});
            try self.emitRaceTolerantAggregateStoreFromPtr(ptr_name, element_ty, value_temp.name);
            return true;
        }

        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})]), ({s}){s}, __ATOMIC_RELAXED);\n", .{ slice.len_field, info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        try self.emitExpr(index.base.*, locals);
        try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
        try self.emitExpr(index.base.*, locals);
        try self.out.print(self.allocator, ".{s})]), ({s}){s});\n", .{ slice.len_field, info.race_c_type, value_temp.name });
        return true;
    }

    fn pointerArrayDerefInner(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.Expr {
        return switch (base.kind) {
            .deref => |inner| if (self.derefPointerHasProvenLocalStorage(inner.*, locals)) null else inner.*,
            .grouped => |inner| self.pointerArrayDerefInner(inner.*, locals),
            else => null,
        };
    }

    fn emitPointerArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast_bridge.TypeExpr, index_temp: ?[]const u8) anyerror!void {
        try self.emitArrayIndexBase(node.base.*, locals);
        if (index_temp == null and self.mirCheckElided(node.index.span)) {
            try self.out.appendSlice(self.allocator, ".elems[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
            return;
        }
        try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
        if (index_temp) |temp| {
            try self.out.appendSlice(self.allocator, temp);
        } else {
            try self.emitExpr(node.index.*, locals);
        }
        const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
        try self.out.print(self.allocator, ", {s})]", .{len});
    }

    fn emitRaceTolerantPointerArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast_bridge.TypeExpr) anyerror!bool {
        _ = self.pointerArrayDerefInner(node.base.*, locals) orelse return false;
        const element_ty = base_arr.kind.array.child.*;
        const info = self.globalInfoFromType(element_ty) catch return false;
        if (info.aggregate) {
            const usize_ty = simpleNameType("usize", node.index.*.span);
            const usize_c_ty = try self.cTypeFor(usize_ty, .typedef_name);
            const index_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_idx{d}", .{self.temp_index});
            self.temp_index += 1;
            const ptr_ty = try self.pointerTypeFor(element_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.out.print(self.allocator, "({{ {s} {s} = ", .{ usize_c_ty, index_name });
            try self.emitExpr(node.index.*, locals);
            try self.out.print(self.allocator, "; {s} {s} = &(", .{ ptr_ty, ptr_name });
            try self.emitPointerArrayIndexExpr(node, locals, base_arr, index_name);
            try self.out.appendSlice(self.allocator, "); ");
            try self.emitRaceTolerantAggregateLoadFromPtr(ptr_name, element_ty);
            try self.out.appendSlice(self.allocator, "; })");
            return true;
        }
        if (info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&(", .{info.c_type});
            try self.emitPointerArrayIndexExpr(node, locals, base_arr, null);
            try self.out.appendSlice(self.allocator, "), __ATOMIC_RELAXED))");
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&(", .{ info.c_type, info.race_type_name });
        try self.emitPointerArrayIndexExpr(node, locals, base_arr, null);
        try self.out.appendSlice(self.allocator, ")))");
        return true;
    }

    fn emitRaceTolerantPointerArrayIndexStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const index = switch (target.kind) {
            .index => |node| node,
            .grouped => |wrapped| return try self.emitRaceTolerantPointerArrayIndexStoreStmt(wrapped.*, value, locals),
            else => return false,
        };
        const base_arr = self.arrayTypeForExpr(index.base.*, locals) orelse return false;
        _ = self.pointerArrayDerefInner(index.base.*, locals) orelse return false;
        const element_ty = base_arr.kind.array.child.*;
        const info = self.globalInfoFromType(element_ty) catch return false;

        const value_temp = try self.emitSequencedCallArgTemp(value, locals, element_ty);
        const usize_ty = simpleNameType("usize", index.index.*.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        if (info.aggregate) {
            const ptr_ty = try self.pointerTypeFor(element_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = &(", .{ ptr_ty, ptr_name });
            try self.emitPointerArrayIndexExpr(index, locals, base_arr, index_temp.name);
            try self.out.appendSlice(self.allocator, ");\n");
            try self.emitRaceTolerantAggregateStoreFromPtr(ptr_name, element_ty, value_temp.name);
            return true;
        }

        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            try self.emitPointerArrayIndexExpr(index, locals, base_arr, index_temp.name);
            try self.out.print(self.allocator, "), ({s}){s}, __ATOMIC_RELAXED);\n", .{ info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        try self.emitPointerArrayIndexExpr(index, locals, base_arr, index_temp.name);
        try self.out.print(self.allocator, "), ({s}){s});\n", .{ info.race_c_type, value_temp.name });
        return true;
    }

    fn emitRaceTolerantIndexedMemberStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const member = switch (target.kind) {
            .member => |node| node,
            .grouped => |wrapped| return try self.emitRaceTolerantIndexedMemberStoreStmt(wrapped.*, value, locals),
            else => return false,
        };
        const index = indexExpr(member.base.*) orelse return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.memberFieldType(member.base.*, member.name.text, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        const field_name = try self.cIdent(member.name.text);

        const value_temp = try self.emitSequencedCallArgTemp(value, locals, field_ty);
        const usize_ty = simpleNameType("usize", index.index.*.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        if (info.aggregate) {
            const ptr_ty = try self.pointerTypeFor(field_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = &(", .{ ptr_ty, ptr_name });
            if (!try self.emitIndexedMemberAddressExpr(index, field_name, locals, index_temp.name)) return false;
            try self.out.appendSlice(self.allocator, ");\n");
            try self.emitRaceTolerantAggregateStoreFromPtr(ptr_name, field_ty, value_temp.name);
            return true;
        }

        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            if (!try self.emitIndexedMemberAddressExpr(index, field_name, locals, index_temp.name)) return false;
            try self.out.print(self.allocator, "), ({s}){s}, __ATOMIC_RELAXED);\n", .{ info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        if (!try self.emitIndexedMemberAddressExpr(index, field_name, locals, index_temp.name)) return false;
        try self.out.print(self.allocator, "), ({s}){s});\n", .{ info.race_c_type, value_temp.name });
        return true;
    }

    fn emitRaceTolerantNestedIndexedMemberStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const index = try self.collectIndexedMemberPath(target, locals, &fields) orelse return false;
        if (fields.items.len <= 1) return false;
        if (!self.indexedMemberHasRaceTolerantStorage(index, locals)) return false;
        const field_ty = self.indexedMemberPathFinalType(index, fields.items, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;

        const value_temp = try self.emitSequencedCallArgTemp(value, locals, field_ty);
        const usize_ty = simpleNameType("usize", index.index.*.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        if (info.aggregate) {
            const ptr_ty = try self.pointerTypeFor(field_ty, .mut, .typedef_name);
            const ptr_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = &(", .{ ptr_ty, ptr_name });
            if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, index_temp.name)) return false;
            try self.out.appendSlice(self.allocator, ");\n");
            try self.emitRaceTolerantAggregateStoreFromPtr(ptr_name, field_ty, value_temp.name);
            return true;
        }

        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, index_temp.name)) return false;
            try self.out.print(self.allocator, "), ({s}){s}, __ATOMIC_RELAXED);\n", .{ info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        if (!try self.emitIndexedMemberPathAddressExpr(index, fields.items, locals, index_temp.name)) return false;
        try self.out.print(self.allocator, "), ({s}){s});\n", .{ info.race_c_type, value_temp.name });
        return true;
    }

    fn emitRaceTolerantNestedPointerMemberStoreStmt(self: *CEmitter, target: ast_bridge.Expr, value: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        const path = try self.pointerMemberPath(target, locals, &fields) orelse return false;
        if (self.derefPointerHasProvenLocalStorage(path.root, locals)) return false;
        const field_ty = self.pointerMemberPathFinalType(path.root, path.fields, locals) orelse return false;
        const info = self.globalInfoFromType(field_ty) catch return false;
        const value_temp = try self.emitSequencedCallArgTemp(value, locals, field_ty);
        if (info.aggregate) {
            const root_ty = self.memberBaseTypeForEmission(path.root, locals) orelse return false;
            const root_c_ty = try self.cTypeFor(root_ty, .typedef_name);
            const root_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_ptr{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ", .{ root_c_ty, root_name });
            try self.emitExpr(path.root, locals);
            try self.out.appendSlice(self.allocator, ";\n");
            const field_ptr = try self.pointerMemberPathPtrExpr(root_name, path.fields);
            try self.emitRaceTolerantAggregateStoreFromPtr(field_ptr, field_ty, value_temp.name);
            return true;
        }

        try self.writeIndent();
        if (info.pointer_like) {
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&(");
            try self.emitPointerMemberPathAddressExpr(path.root, path.fields, locals);
            try self.out.print(self.allocator, "), ({s}){s}, __ATOMIC_RELAXED);\n", .{ info.c_type, value_temp.name });
            return true;
        }
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "mc_race_store_{s}(&(", .{info.race_type_name});
        try self.emitPointerMemberPathAddressExpr(path.root, path.fields, locals);
        try self.out.print(self.allocator, "), ({s}){s});\n", .{ info.race_c_type, value_temp.name });
        return true;
    }

    // The constant value of an integer local initializer, but only when it fits
    // the declared type (so the local genuinely holds that constant at runtime).
    fn constLocalValue(self: *CEmitter, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?i128 {
        const resolved = self.resolveAliasType(decl_ty);
        const tn = typeName(resolved) orelse return null;
        const range = intTypeRange(tn) orelse return null;
        const v = constIntValue(initializer, locals) orelse return null;
        if (@as(i256, v) >= @as(i256, range.min) and @as(i256, v) <= @as(i256, range.max)) return v;
        return null;
    }

    const TryScanContext = struct {
        emitter: *CEmitter,
        locals: *std.StringHashMap(LocalInfo),
    };

    fn resultTryOperandIsResult(ctx_ptr: *anyopaque, operand: ast_bridge.Expr) bool {
        const ctx: *TryScanContext = @ptrCast(@alignCast(ctx_ptr));
        _ = ctx.locals;
        const operand_ty = ctx.emitter.mirTryOperandTypeForQuery(operand) orelse return false;
        return lower_c_shape.resultPayloadTypeForTag(operand_ty, "ok") != null and lower_c_shape.resultPayloadTypeForTag(operand_ty, "err") != null;
    }

    fn nullableTryOperandIsNullable(ctx_ptr: *anyopaque, operand: ast_bridge.Expr) anyerror!bool {
        const ctx: *TryScanContext = @ptrCast(@alignCast(ctx_ptr));
        _ = ctx.locals;
        const operand_ty = ctx.emitter.mirTryOperandTypeForQuery(operand) orelse return false;
        return ctx.emitter.nullableTypeFromCandidate(operand_ty) != null;
    }

    fn sliceReturnTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .call => blk: {
                const return_ty = self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.sliceTypeFromCandidate(return_ty);
            },
            // Real source slices have an exact MIR result type. Generated
            // zero-span nodes retain only a narrow base-derived path for values
            // already described by call return facts or operand emission facts.
            .slice => |node| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else blk: {
                const base_ty = self.sliceBaseTypeForZeroSpanSlice(node.base.*, locals) orelse break :blk null;
                const inferred = self.sliceTypeForBase(base_ty, node.base.*.span) orelse break :blk null;
                break :blk self.requireExpressionResultTypeForInference(expr, inferred);
            },
            .grouped => |inner| blk: {
                const inferred = self.sliceReturnTypeForExpr(inner.*, locals) orelse break :blk null;
                break :blk self.checkedStorageExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            else => null,
        };
    }

    fn sliceBaseTypeForZeroSpanSlice(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .call => self.callResultTypeForEmission(expr, locals),
            .grouped => |inner| blk: {
                const inferred = self.sliceBaseTypeForZeroSpanSlice(inner.*, locals) orelse break :blk null;
                break :blk self.checkedStorageExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            else => self.operandEmitType(expr, locals),
        };
    }

    fn requireExpressionResultTypeForInference(self: *CEmitter, expr: ast_bridge.Expr, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!lower_c_type.sameCStorageType(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) return null;
        return fact.target_ty;
    }

    fn checkedStorageExpressionResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return inferred;
        return self.requireExpressionResultTypeForInference(expr, inferred);
    }

    fn storageOrExpressionResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.operandEmitType(expr, locals);
        return (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
    }

    fn castResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const node = switch (expr.kind) {
            .cast => |node| node,
            else => return null,
        };
        return self.checkedCastResultTypeForEmission(expr, node.ty.*);
    }

    fn checkedCastResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, expected_ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return expected_ty;
        const target_ty = (self.mirTargetTypeFactAt(.explicit_cast_target, expr.span) orelse return null).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(target_ty), self.resolveAliasType(expected_ty))) return null;
        const fact_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(target_ty))) return null;
        return fact_ty;
    }

    fn sliceTypeForBase(self: *CEmitter, ty: ast_bridge.TypeExpr, span: ast_bridge.Span) ?ast_bridge.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .slice => resolved,
            .array => |array| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = array.child } } },
            else => null,
        };
    }

    fn arrayLenText(self: *CEmitter, ty: ast_bridge.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .array => |node| try self.arrayLenTextForExpr(node.len),
            .qualified => |node| try self.arrayLenText(node.child.*),
            else => null,
        };
    }

    fn arrayLenTextForExpr(self: *CEmitter, expr: ast_bridge.Expr) ![]const u8 {
        var reflect_env = self.reflectEnv();
        const value = constArrayLenValue(expr, &self.const_fns, &self.const_globals, lower_c_reflect.comptimeReflectThunk, &reflect_env) orelse return error.UnsupportedCEmission;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    // The declared type of a value expression (a local, global, call result,
    // struct field, or array/slice element) — enough to keep inferred locals and
    // enum-literal comparison operands typed.
    fn operandEmitType(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .cast => self.castResultTypeForEmission(expr),
            .ident => |ident| self.identTypeForEmissionRecovered(ident.text, expr.span, locals),
            .grouped => |inner| blk: {
                // A user-source grouping has its own complete MIR result fact.
                // Recover the inner type only to reject a stale fact; it must
                // not remain the semantic authority for the grouped expression.
                const inferred = self.operandEmitType(inner.*, locals) orelse break :blk null;
                break :blk self.checkedStorageExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            .member => |node| blk: {
                // Source members have an exact, validated MIR result fact. Do
                // not reconstruct their type by walking the base declaration in
                // C.
                if (isSourceSpan(expr.span)) {
                    break :blk if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null;
                }
                // Async lowering creates zero-span state-machine members after
                // source facts are built; their resolved declaration is
                // authority.
                const base_ty = self.operandEmitType(node.base.*, locals) orelse break :blk null;
                const struct_name = self.structTypeNameFromType(base_ty) orelse break :blk null;
                const struct_decl = self.structs.get(struct_name) orelse break :blk null;
                for (struct_decl.fields) |field| {
                    if (std.mem.eql(u8, field.name.text, node.name.text)) break :blk field.ty;
                }
                break :blk null;
            },
            .index => |node| blk: {
                if (isSourceSpan(expr.span)) {
                    break :blk if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null;
                }
                const base_ty = self.operandEmitType(node.base.*, locals) orelse break :blk null;
                const resolved = self.resolveAliasType(base_ty);
                break :blk switch (resolved.kind) {
                    .array => resolved.kind.array.child.*,
                    .slice => resolved.kind.slice.child.*,
                    else => null,
                };
            },
            // MIR records an exact result for direct function addresses and the
            // bounded data-address place family. Other address expressions
            // remain unsupported here rather than rediscovered from
            // backend-local state.
            .address_of, .deref => if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null,
            else => null,
        };
    }

    fn identTypeForEmissionRecovered(self: *CEmitter, name: []const u8, span: ast_bridge.Span, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const declared_ty: ast_bridge.TypeExpr = blk: {
            if (locals) |local_set| {
                if (local_set.get(name)) |info| {
                    if (info.source_ty) |ty| break :blk ty;
                }
            }
            if (self.globals.get(name)) |global| {
                if (global.source_ty) |ty| break :blk ty;
            }
            return null;
        };
        // A source identifier now has an exact MIR expression_result fact. The
        // declaration table is only the fallback for generated nodes that have
        // no stable source-keyed fact. Tuple-destructure temps are
        // parser-synthesized locals with real binding spans but no user-written
        // identifier occurrence.
        if (!isSourceSpan(span) or std.mem.startsWith(u8, name, "__destr")) return declared_ty;
        const fact_ty = if (self.mirTargetTypeFactAt(.expression_result, span)) |fact| fact.target_ty else return null;
        if (!lower_c_type.sameCStorageType(self.resolveAliasType(fact_ty), self.resolveAliasType(declared_ty))) return null;
        return fact_ty;
    }

    fn exprHasPointerType(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.memberBaseTypeForEmission(expr, locals) orelse return false;
        return self.pointerTypeFromCandidate(ty) != null;
    }

    fn memberFieldType(self: *CEmitter, base: ast_bridge.Expr, field_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (indexExpr(base)) |index| {
            const base_ty = self.arrayOrSliceBaseTypeForEmission(index.base.*, locals) orelse return null;
            const element_ty = self.arrayOrSliceElementTypeFromCandidate(base_ty) orelse return null;
            return self.memberFieldTypeFromAggregate(element_ty, field_name);
        }
        const base_ty = self.memberBaseTypeForEmission(base, locals) orelse return null;
        return self.memberFieldTypeFromAggregate(base_ty, field_name);
    }

    fn memberBaseTypeForEmission(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (syntheticDestructureBase(base)) return self.memberBaseTypeForEmissionRecovered(base, locals);
        if (isSourceSpan(base.span)) {
            const fact_ty = (self.mirTargetTypeFactAt(.expression_result, base.span) orelse return null).target_ty;
            const inferred = self.memberBaseTypeForEmissionRecovered(base, locals) orelse return null;
            if (!lower_c_type.sameCStorageType(self.resolveAliasType(fact_ty), self.resolveAliasType(inferred))) return null;
            return fact_ty;
        }
        return self.memberBaseTypeForEmissionRecovered(base, locals) orelse
            self.generatedExprSourceTypeForEmission(base, locals);
    }

    fn memberBaseTypeForEmissionRecovered(self: *CEmitter, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (self.operandEmitType(base, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(base, locals)) |ty| return ty;
        return null;
    }

    fn syntheticDestructureBase(base: ast_bridge.Expr) bool {
        return switch (base.kind) {
            .ident => |ident| std.mem.startsWith(u8, ident.text, "__destr"),
            .grouped => |inner| syntheticDestructureBase(inner.*),
            else => false,
        };
    }

    fn memberFieldTypeFromAggregate(self: *CEmitter, aggregate_ty: ast_bridge.TypeExpr, field_name: []const u8) ?ast_bridge.TypeExpr {
        const struct_name = self.structTypeNameFromType(aggregate_ty) orelse return null;
        const struct_decl = self.structs.get(struct_name) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
        }
        return null;
    }

    // Slice ptr/len access for a base expression, covering both a local/param base
    // (fast path via LocalInfo) and a struct-field base (`sp.s` where `s: []T`),
    // whose slice-ness is recovered from the field's declared type. The C slice
    // struct always names its fields `ptr`/`len` (see lower_c_info).
    fn sliceAccessForBase(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
        if (sliceAccessForExpr(expr, locals)) |slice| return slice;
        const ty = self.operandEmitType(expr, locals) orelse return null;
        return if (self.sliceTypeFromCandidate(ty) != null) .{ .ptr_field = "ptr", .len_field = "len" } else null;
    }

    // The array type of `expr`, if it is an array — including the element of an
    // outer array access (`m[i]` over `[N][M]T` yields `[M]T`), which enables
    // nested indexing `m[i][j]`. Returns null for non-array expressions.
    fn arrayTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .call => blk: {
                const return_ty = self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.arrayTypeFromType(return_ty);
            },
            .ident => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                break :blk self.arrayTypeFromType(ty);
            },
            .grouped => |inner| blk: {
                const inferred = self.arrayTypeForExpr(inner.*, locals) orelse break :blk null;
                const result_ty = self.checkedExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
                break :blk self.arrayTypeFromType(result_ty);
            },
            // Source member/index results are MIR-owned. In particular, a
            // nested array result must not be reconstructed by walking the
            // struct declaration or the previous array expression.
            .index, .member => blk: {
                const result_ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.arrayTypeFromType(result_ty);
            },
            // `pa.*[i]` — deref of a pointer-to-array indexes the pointee
            // array.
            .deref => |inner| blk: {
                const ty = self.arrayDerefResultTypeForEmission(expr, inner.*, locals) orelse break :blk null;
                break :blk self.arrayTypeFromType(ty);
            },
            else => null,
        };
    }

    fn arrayTypeFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return if (resolved.kind == .array) resolved else null;
    }

    fn arrayOrSliceElementTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn arrayDerefResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const pointee = self.derefPointeeType(inner, locals) orelse return null;
        if (!isSourceSpan(expr.span)) return pointee;
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(pointee))) return null;
        return fact.target_ty;
    }

    // Whether an expression has a pointer type, so member access lowers as `->`.
    // MMIO/slice/array accesses take dedicated paths before reaching here, so this
    // covers ordinary `*T` struct pointers (e.g. a borrowed `move` handle).
    fn exprIsPointer(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .ident => |id| blk: {
                const ty = self.identTypeForEmissionRecovered(id.text, expr.span, locals) orelse break :blk false;
                break :blk self.pointerTypeFromCandidate(ty) != null;
            },
            .member => blk: {
                const result_ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk false;
                break :blk self.pointerTypeFromCandidate(result_ty) != null;
            },
            .grouped => |inner| self.groupedExprIsPointer(expr, inner.*, locals),
            else => false,
        };
    }

    fn groupedExprIsPointer(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (!isSourceSpan(expr.span)) return self.exprIsPointer(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return false).target_ty;
        return self.pointerTypeFromCandidate(ty) != null;
    }

    fn pointerTypeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .pointer) ty else null;
    }

    const PointerTypeNode = struct {
        mutability: ast_bridge.Mutability,
        child: *ast_bridge.TypeExpr,
    };

    fn pointerNodeFromCandidate(self: *CEmitter, ty: ast_bridge.TypeExpr) ?PointerTypeNode {
        return switch (self.resolveAliasType(ty).kind) {
            .pointer => |node| .{ .mutability = node.mutability, .child = node.child },
            else => null,
        };
    }

    // The pointee type of a pointer-typed expression (`p` where `p: *T` → `T`).
    fn derefPointeeType(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                break :blk self.pointerPointeeTypeFromType(ty);
            },
            .address_of => |inner| if (isSourceSpan(expr.span)) blk: {
                const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse break :blk null).target_ty;
                break :blk self.pointerPointeeTypeFromType(ty);
            } else self.operandEmitType(inner.*, locals),
            .call => |node| blk: {
                const ty = if (self.mirTargetTypeFactAt(.raw_many_offset_result, node.callee.*.span)) |fact|
                    fact.target_ty
                else
                    self.callResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.pointerPointeeTypeFromType(ty);
            },
            .cast => blk: {
                const ty = self.castResultTypeForEmission(expr) orelse break :blk null;
                break :blk self.pointerPointeeTypeFromType(ty);
            },
            .member, .index => blk: {
                const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.pointerPointeeTypeFromType(ty);
            },
            .grouped => |inner| self.groupedDerefPointeeType(expr, inner.*, locals),
            else => null,
        };
    }

    fn groupedDerefPointeeType(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.derefPointeeType(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.pointerPointeeTypeFromType(ty);
    }

    fn pointerPointeeTypeFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .pointer => |p| p.child.*,
            .raw_many_pointer => |p| p.child.*,
            else => null,
        };
    }

    fn structTypeNameForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                break :blk self.structTypeNameFromType(ty);
            },
            .member, .index => blk: {
                // A source projection result is already represented by a
                // complete MIR expression_result row. Do not rediscover its
                // struct type by walking the declaration here.
                const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.structTypeNameFromType(ty);
            },
            .grouped => |inner| self.groupedStructTypeNameForExpr(expr, inner.*, locals),
            else => null,
        };
    }

    fn groupedStructTypeNameForExpr(self: *CEmitter, expr: ast_bridge.Expr, inner: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        if (!isSourceSpan(expr.span)) return self.structTypeNameForExpr(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.structTypeNameFromType(ty);
    }

    fn structTypeNameFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .name => |n| n.text,
            .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                .name => |n| n.text,
                else => null,
            },
            else => null,
        };
    }

    fn callResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                // Source call expressions have complete MIR result facts. The
                // call-specific fact identifies the callee/ABI path; the
                // expression_result row authorizes the value type at this
                // source expression span.
                const inferred = self.callReturnTypeForCall(node, locals) orelse break :blk null;
                break :blk self.callExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            .grouped => |inner| blk: {
                const inferred = self.callResultTypeForEmission(inner.*, locals) orelse break :blk null;
                break :blk self.callExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            else => null,
        };
    }

    fn callExpressionResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        return self.checkedExpressionResultTypeForEmission(expr, inferred);
    }

    fn checkedExpressionResultTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, inferred: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
        if (!isSourceSpan(expr.span)) return inferred;
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) return null;
        return fact.target_ty;
    }

    fn callReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (self.simpleMirResultReturnTypeForCall(call, .reflection_result)) |ty| return ty;
        if (self.simpleMirResultReturnTypeForCall(call, .byte_view_result)) |ty| return ty;
        if (self.simpleMirResultReturnTypeForCall(call, .bitcast_target)) |ty| return ty;
        if (self.simpleMirResultReturnTypeForCall(call, .conversion_target)) |ty| return ty;
        if (self.simpleMirResultReturnTypeForCall(call, .phys_result)) |ty| return ty;
        if (call_kind) |kind| {
            if (self.enumRawResultReturnTypeForCall(call, kind)) |ty| return ty;
            if (self.constGetResultReturnTypeForCall(call, kind)) |ty| return ty;
        }
        if (call_kind) |kind| if (self.dmaResultReturnTypeForCall(call, kind)) |ty| return ty;
        if (call_kind) |kind| if (self.domainResultReturnTypeForCall(call, kind)) |ty| return ty;
        if (call_kind) |kind| {
            if (self.declassifyResultReturnTypeForCall(call, kind)) |ty| return ty;
            if (self.assumeNoaliasResultReturnTypeForCall(call, kind)) |ty| return ty;
        }
        if (call_kind) |kind| {
            if (self.rawManyOffsetResultReturnTypeForCall(call, kind)) |ty| return ty;
            if (self.rawResultReturnTypeForCall(call, kind)) |ty| return ty;
            if (self.maybeUninitResultReturnTypeForCall(call, kind)) |ty| return ty;
        }
        if (self.atomicResultReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.dynDispatchReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.closureCallReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.indirectCallReturnTypeForCall(call)) |ty| return ty;
        return self.directCallReturnTypeForCall(call);
    }

    fn indirectCallCalleeType(self: *CEmitter, callee: ast_bridge.Expr) ?ast_bridge.TypeExpr {
        const ty = (self.mirTargetTypeFactAt(.indirect_call_callee, callee.span) orelse return null).target_ty;
        return self.resolveAliasType(ty);
    }

    fn closureCallReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const closure_ty = self.closureCalleeType(call.callee.*, locals) orelse return null;
        return closure_ty.kind.closure_type.ret.*;
    }

    fn indirectCallReturnTypeForCall(self: *CEmitter, call: anytype) ?ast_bridge.TypeExpr {
        const callee_ty = self.indirectCallCalleeType(call.callee.*) orelse return null;
        return switch (callee_ty.kind) {
            .fn_pointer => |signature| signature.ret.*,
            .closure_type => |signature| signature.ret.*,
            else => null,
        };
    }

    // Ordinary direct calls require the MIR-owned result row to match the
    // declared function return type before inferred-local typing can consume it.
    fn directCallReturnTypeForCall(self: *CEmitter, call: anytype) ?ast_bridge.TypeExpr {
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        const fact_ty = if (self.mirTargetTypeFactAtOwned(.direct_call_result, call.callee.*.span, fn_name, null)) |fact| fact.target_ty else return null;
        if (info.return_type) |declared_ty| {
            if (!std.meta.eql(fact_ty, declared_ty)) return null;
        } else if (!isVoidType(fact_ty)) return null;
        return fact_ty;
    }

    // Simple builtin call-result queries consume an already-produced MIR
    // target row at the callee span. The helper names this as result admission
    // instead of leaving each fact as an inline inferred-local type shortcut.
    fn simpleMirResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.TargetTypeKind) ?ast_bridge.TypeExpr {
        return (self.mirTargetTypeFactAt(kind, call.callee.*.span) orelse return null).target_ty;
    }

    fn dynDispatchReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const trait_name = self.dynCalleeTrait(call.callee.*, locals) orelse return null;
        const trait = self.trait_decls.get(trait_name) orelse return null;
        const method_name = dynCalleeMethodName(call.callee.*) orelse return null;
        for (trait.facts.methods, 0..) |method, index| {
            if (!std.mem.eql(u8, method.name.text, method_name)) continue;
            const declared_ty = method.return_type orelse return null;
            const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, call.callee.*.span, trait_name, index) orelse return null).target_ty;
            if (!std.meta.eql(fact_ty, declared_ty)) return null;
            return fact_ty;
        }
        return null;
    }

    fn dynDispatchMethodIndex(self: *CEmitter, callee: ast_bridge.Expr, trait_name: []const u8) ?usize {
        const trait = self.trait_decls.get(trait_name) orelse return null;
        const method_name = dynCalleeMethodName(callee) orelse return null;
        for (trait.facts.methods, 0..) |method, index| {
            if (std.mem.eql(u8, method.name.text, method_name)) return index;
        }
        return null;
    }

    fn requireDynDispatchArgument(self: *CEmitter, span: ast_bridge.Span, trait_name: []const u8, method_index: usize, argument_index: usize) !void {
        const trait = self.trait_decls.get(trait_name) orelse return error.UnsupportedCEmission;
        if (method_index >= trait.facts.methods.len) return error.UnsupportedCEmission;
        const method = trait.facts.methods[method_index];
        if (argument_index + 1 >= method.params.len) return error.UnsupportedCEmission;
        const declared_ty = method.params[argument_index + 1].ty;
        const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_argument, span, trait_name, mir.dynDispatchArgumentFactIndex(method_index, argument_index)) orelse return error.UnsupportedCEmission).target_ty;
        if (!std.meta.eql(fact_ty, declared_ty)) return error.UnsupportedCEmission;
    }

    fn requireDynDispatchArgumentForDispatch(ctx: *anyopaque, span: ast_bridge.Span, trait_name: []const u8, method_index: usize, argument_index: usize) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.requireDynDispatchArgument(span, trait_name, method_index, argument_index);
    }

    fn requireDynDispatchResult(self: *CEmitter, span: ast_bridge.Span, trait_name: []const u8, method_index: usize) !void {
        const trait = self.trait_decls.get(trait_name) orelse return error.UnsupportedCEmission;
        if (method_index >= trait.facts.methods.len) return error.UnsupportedCEmission;
        const declared_ty = trait.facts.methods[method_index].return_type orelse return;
        if (isVoidType(self.resolveAliasType(declared_ty))) return;
        const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, span, trait_name, method_index) orelse return error.UnsupportedCEmission).target_ty;
        if (!std.meta.eql(fact_ty, declared_ty)) return error.UnsupportedCEmission;
    }

    fn requireDynDispatchResultForDispatch(ctx: *anyopaque, span: ast_bridge.Span, trait_name: []const u8, method_index: usize) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.requireDynDispatchResult(span, trait_name, method_index);
    }

    // Atomic value-producing calls return the atomic payload type
    // (`atomic<u64>.fetch_add` -> `u64`), so inferred locals and compound
    // operands do not fall back to the C emitter's default `uint32_t`.
    fn atomicResultReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        _ = locals;
        return lower_c_atomic.atomicResultPayload(self.atomicEmitContext(), call);
    }

    // MaybeUninit extraction returns its MIR-owned payload type. The emitted
    // value is the backing storage itself, so an inferred local must use this
    // type before it is added to the C local environment.
    fn maybeUninitResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .maybe_uninit_assume_init) return null;
        return (self.mirTargetTypeFactAt(.maybe_uninit_payload, call.callee.*.span) orelse return null).target_ty;
    }

    // Raw loads and raw pointer construction have a distinct `raw_result`
    // fact. Do not recover their type from the call's type argument while
    // allocating an inferred local.
    fn rawResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .raw_load and kind != .raw_ptr) return null;
        return (self.mirTargetTypeFactAt(.raw_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Arithmetic-domain call results are admitted by the MIR domain identity
    // and its `domain_result` row. Do not rebuild wrap/Duration/Result shapes
    // from the AST while allocating inferred locals.
    fn domainResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        _ = mir.domainCallFactInfo(kind) orelse return null;
        return (self.mirTargetTypeFactAt(.domain_result, call.callee.*.span) orelse return null).target_ty;
    }

    // DMA helper calls return their MIR-owned result row. Keep inferred-local
    // result typing tied to the call identity instead of deriving DMA address
    // or slice results from the receiver/type spelling.
    fn dmaResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        _ = mir.dmaCallFactInfo(kind) orelse return null;
        return (self.mirTargetTypeFactAt(.dma_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Enum raw reads expose the MIR-owned representation result type. Keep
    // inferred locals from deriving the representation through enum lookup.
    fn enumRawResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .enum_raw) return null;
        return (self.mirTargetTypeFactAt(.enum_raw_result, call.callee.*.span) orelse return null).target_ty;
    }

    // const_get result typing is admitted by the MIR call identity plus the
    // fixed-index result row; array shape checks stay in const_get validation.
    fn constGetResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .const_get) return null;
        return (self.mirTargetTypeFactAt(.const_get_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Semantic escapes are admitted by explicit MIR call identities and result
    // rows. Keep inferred locals from accepting these capability-sensitive
    // results through ordinary call or pointer spelling inference.
    fn declassifyResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .declassify) return null;
        return (self.mirTargetTypeFactAt(.declassify_result, call.callee.*.span) orelse return null).target_ty;
    }

    fn assumeNoaliasResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .assume_noalias) return null;
        return (self.mirTargetTypeFactAt(.assume_noalias_result, call.callee.*.span) orelse return null).target_ty;
    }

    // raw-many offsets return the MIR-owned pointer result. Inferred locals
    // must not recover this type from receiver spelling or alias resolution.
    fn rawManyOffsetResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast_bridge.TypeExpr {
        if (kind != .raw_many_offset) return null;
        return (self.mirTargetTypeFactAt(.raw_many_offset_result, call.callee.*.span) orelse return null).target_ty;
    }

    fn exprSourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.identTypeForEmissionRecovered(ident.text, expr.span, locals),
            .call => self.callResultTypeForEmission(expr, locals),
            .cast => self.castResultTypeForEmission(expr),
            // Real source members are typed by MIR. Only compiler-generated
            // zero-span nodes may use the layout-derived fallback because no
            // source-keyed fact can exist for them.
            .member => if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.operandEmitType(expr, locals),
            .index => |node| blk: {
                const inferred = self.operandEmitType(expr, locals) orelse fallback: {
                    // Real source indexes are typed by MIR. Only compiler-generated
                    // zero-span indexes may recover an element type from the local
                    // base, because there is no source-keyed expression_result row
                    // for those synthetic nodes.
                    if (isSourceSpan(expr.span)) break :fallback null;
                    break :fallback if (locals) |local_set| localIndexElementType(node.base.*, local_set) else null;
                } orelse break :blk null;
                const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse break :blk null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) break :blk null;
                break :blk fact.target_ty;
            },
            // A real source slice has a complete MIR-owned result type. The
            // slice emitter still queries its base for address/length mechanics,
            // but that query must not select the result type used by callers.
            .slice => |node| if (isSourceSpan(expr.span))
                if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| fact.target_ty else null
            else
                self.sliceTypeForBase(self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return null, node.base.*.span),
            .grouped => |inner| blk: {
                const inferred = self.exprSourceTypeForEmission(inner.*, locals) orelse break :blk null;
                break :blk self.checkedExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            .binary => |node| self.binarySourceTypeForEmission(expr, node, locals),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk null;
                const inferred = self.exprSourceTypeForEmission(node.expr.*, locals) orelse break :blk null;
                const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse break :blk null;
                if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) break :blk null;
                break :blk fact.target_ty;
            },
            else => null,
        };
    }

    fn generatedExprSourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        return self.exprSourceTypeForEmission(expr, locals);
    }

    fn binarySourceTypeForEmission(self: *CEmitter, expr: ast_bridge.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        const inferred = switch (node.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => type_bridge.simpleNameType("bool", expr.span),
            .shl, .shr => self.exprSourceTypeForEmission(node.left.*, locals),
            else => self.exprSourceTypeForEmission(node.left.*, locals) orelse self.exprSourceTypeForEmission(node.right.*, locals),
        };
        if (inferred) |ty| {
            if (!type_bridge.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(ty))) return null;
        }
        return fact.target_ty;
    }

    fn nullableInnerCTypeForExpr(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !?[]const u8 {
        return lower_c_info.nullableInnerCTypeForExpr(self.infoContext(), expr, locals);
    }

    fn nullableInnerCTypeForType(self: *CEmitter, ty: ast_bridge.TypeExpr) !?[]const u8 {
        return lower_c_info.nullableInnerCTypeForType(self.infoContext(), ty);
    }

    fn exprContainsResultTry(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.exprContainsTry(&ctx, expr, resultTryOperandIsResult);
    }

    fn callArgsContainResultTry(self: *CEmitter, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.argsContainTry(&ctx, args, resultTryOperandIsResult);
    }

    fn exprContainsNullableTry(self: *CEmitter, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.exprContainsTryError(&ctx, expr, nullableTryOperandIsNullable);
    }

    fn callArgsContainNullableTry(self: *CEmitter, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.argsContainTryError(&ctx, args, nullableTryOperandIsNullable);
    }

    // Count the MMIO register reads in an expression. Used to detect a sequencing hazard in a
    // short-circuiting `&&` / `||` operand: a single read renders inline safely, but two or
    // more reads in one operand would be combined by non-sequencing C operators (function-call
    // arguments, arithmetic, comparison) whose evaluation order is unspecified — which would
    // silently reorder device reads.
    fn mmioAccess(self: *CEmitter, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
        return lower_c_mmio.classifyAccess(self.mmioAccessContext(), callee, args, locals);
    }

    fn cTypeForMmioValue(self: *CEmitter, value_type: []const u8) []const u8 {
        return lower_c_mmio.valueCType(self.mmioAccessContext(), value_type);
    }

    fn localInfoFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) !LocalInfo {
        return lower_c_info.localInfoFromType(self.infoContext(), ty);
    }

    fn globalInfoFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) !GlobalInfo {
        return lower_c_info.globalInfoFromType(self.infoContext(), ty);
    }

    fn globalElementInfoFromType(self: *CEmitter, ty: ast_bridge.TypeExpr) !GlobalElementInfo {
        return lower_c_info.globalElementInfoFromType(self.infoContext(), ty);
    }

    fn nullableInnerCType(self: *CEmitter, ty: ast_bridge.TypeExpr) !?[]const u8 {
        return lower_c_info.nullableInnerCType(self.infoContext(), ty);
    }

    fn infoContext(self: *CEmitter) lower_c_info.Context {
        return .{
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .structs = &self.structs,
            .packed_bits = &self.packed_bits,
            .overlay_unions = &self.overlay_unions,
            .tagged_unions = &self.tagged_unions,
            .enums = &self.enums,
            .emit_ctx = self,
            .c_type_for = cTypeForInfo,
            .array_len_text_for_expr = arrayLenTextForInfo,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn cTypeForInfo(ctx: *anyopaque, ty: ast_bridge.TypeExpr, style: StructTypeStyle) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, style);
    }

    fn arrayLenTextForInfo(ctx: *anyopaque, expr: ast_bridge.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }
};

fn spanFromSourcePoint(source: mir.SourcePoint) ast_bridge.Span {
    return .{
        .offset = source.offset,
        .len = source.len,
        .line = source.line,
        .column = @intCast(source.column),
    };
}
