const std = @import("std");

const ast = @import("ast.zig");
const backend_cleanup = @import("backend_cleanup.zig");
const backend_mod = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const error_from = @import("error_from.zig");
const eval = @import("eval.zig");
const early_declaration_metadata = @import("early_declaration_metadata.zig");
const expr_syntax = @import("expr_syntax.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");
const mir_facts_view = @import("mir_facts_view.zig");
const type_syntax = @import("type_syntax.zig");
const switch_lower = @import("switch_lower.zig");

const lower_c_type = @import("lower_c_type.zig");
const numeric = @import("numeric.zig");
const rawScalarSuffix = lower_c_type.rawScalarSuffix;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;
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
const attr_syntax = @import("attr_syntax.zig");
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
const lower_c_module = @import("lower_c_module.zig");
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
const hasNakedAttr = attr_syntax.hasNakedAttr;
const backendNameOverride = attr_syntax.backendNameOverride;
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

const isUninitLiteral = expr_syntax.isUninitLiteral;
const typeName = type_syntax.typeName;
const simpleNameType = type_syntax.simpleNameType;
const contractName = expr_syntax.contractName;
const calleeIdentName = expr_syntax.calleeIdentName;
const callExpr = expr_syntax.callExpr;

fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| {
        switch (attr.kind) {
            .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
            else => {},
        }
    }
    return false;
}

const MirSubjectType = struct {
    target_ty: ast.TypeExpr,
    nullable_representation: ?NullableRepresentation = null,
};
const indexExpr = expr_syntax.indexExpr;
const memberCallee = expr_syntax.memberCallee;
const memberExpr = expr_syntax.memberExpr;
const isStringLiteralTarget = type_syntax.isStringLiteralTarget;
const isMmioStructAbi = type_syntax.isMmioStructAbi;
const dynCalleeMethodName = expr_syntax.dynCalleeMethodName;

const FunctionDeclArtifact = mir_ownership_authority.FunctionDeclArtifact;

const AggregateDeclArtifact = union(enum) {
    struct_decl: ast.StructDecl,
    tagged_union: ast.UnionDecl,
};

pub fn appendLayoutAsserts(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), struct_names: []const []const u8) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = false });
    defer typed_mir.deinit();

    var emitter = CEmitter.init(allocator, out, &typed_mir, null, null);
    defer emitter.deinit();
    var early_metadata = try early_declaration_metadata.EarlyDeclarationArtifacts.collectFromDecls(allocator, module.decls);
    defer early_metadata.deinit(allocator);
    try emitter.collectModule(early_metadata);

    try out.appendSlice(allocator,
        \\/* GENERATED by `mcc emit-layout` — DO NOT EDIT. */
        \\/* MC's authoritative struct layouts (sizeof/offsetof). A C runtime that hand-mirrors */
        \\/* one of these structs includes this header; any layout drift is a compile error.    */
        \\#include <stddef.h>
        \\
    );

    try emitter.appendLayoutAssertsFor(struct_names);
}

pub fn appendStructDecls(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), struct_names: []const []const u8) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = false });
    defer typed_mir.deinit();

    var emitter = CEmitter.init(allocator, out, &typed_mir, null, null);
    defer emitter.deinit();
    var early_metadata = try early_declaration_metadata.EarlyDeclarationArtifacts.collectFromDecls(allocator, module.decls);
    defer early_metadata.deinit(allocator);
    try emitter.collectModule(early_metadata);

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

pub fn appendModule(
    allocator: std.mem.Allocator,
    module: ast.Module,
    out: *std.ArrayList(u8),
    optimize: bool,
    source_path: ?[]const u8,
    ksan: bool,
    msan: bool,
    csan: bool,
    stub_asm: bool,
    reporter: ?*diagnostics.Reporter,
) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
    defer typed_mir.deinit();

    var early_metadata = try early_declaration_metadata.EarlyDeclarationArtifacts.collectFromDecls(allocator, module.decls);
    defer early_metadata.deinit(allocator);
    try appendModuleMir(allocator, early_metadata, &typed_mir, out, source_path, ksan, msan, csan, stub_asm, reporter);
}

pub fn appendModuleMir(
    allocator: std.mem.Allocator,
    early_metadata: early_declaration_metadata.EarlyDeclarationArtifacts,
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
    try emitter.emitModule(early_metadata);
}

pub const CEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: std.heap.ArenaAllocator,
    globals: std.StringHashMap(GlobalInfo),
    global_decl_artifacts: std.ArrayList(ast.GlobalDecl) = .empty,
    static_initializers: std.StringHashMap(ast.Expr),
    type_aliases: std.StringHashMap(ast.TypeExpr),
    functions: std.StringHashMap(FnInfo),
    function_decl_artifacts: std.ArrayList(FunctionDeclArtifact) = .empty,
    // Source function name -> overridden object/backend symbol (`#[backend_name("Y")]`).
    // Emitted as a C `__asm__("Y")` label so the object symbol is renamed without touching
    // any C-level call site.
    backend_names: std.StringHashMap([]const u8),
    // `const fn` bodies and folded `const` global values, for folding comptime
    // const-fn calls / named constants in fixed-array lengths (section 22
    // comptime↔type feedback).
    const_fns: std.StringHashMap(ast.FnDecl),
    const_globals: std.StringHashMap(eval.ComptimeValue),
    const_global_widths: std.StringHashMap(u16),
    const_global_domains: std.StringHashMap(eval.DomainWidth),
    owned_comptime_declarations: early_declaration_metadata.ComptimeDeclarationArtifacts = .empty,
    comptime_declarations: ?eval.ComptimeDeclarations = null,
    structs: std.StringHashMap(ast.StructDecl),
    aggregate_decl_artifacts: std.ArrayList(AggregateDeclArtifact) = .empty,
    mmio_structs: std.StringHashMap(MmioStruct),
    mmio_struct_decl_artifacts: std.ArrayList(ast.StructDecl) = .empty,
    packed_bits: std.StringHashMap(PackedBitsInfo),
    overlay_unions: std.StringHashMap(OverlayUnionInfo),
    tagged_unions: std.StringHashMap(ast.UnionDecl),
    enums: std.StringHashMap(ast.EnumDecl),
    array_types: std.StringHashMap(ArrayInfo),
    slice_types: std.StringHashMap(SliceInfo),
    result_types: std.StringHashMap(ResultInfo),
    // Value optionals `?T` (tagged repr), one typedef per payload type.
    opt_types: std.StringHashMap(lower_c_model.OptInfo),
    // Function-pointer signatures encountered, each emitted as a `typedef RET
    // (*name)(params);` so the name-in-the-middle C declarator works anywhere a
    // plain type name does.
    fn_ptr_types: std.StringHashMap(ast.TypeExpr),
    closure_types: std.StringHashMap(ast.TypeExpr),
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
    trait_decls: std.StringHashMap(ast.TraitDecl),
    impl_methods: std.StringHashMap([]const ast.ImplTraitMethod),
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
    current_function_body: ?ast.Block = null,
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
            .static_initializers = std.StringHashMap(ast.Expr).init(allocator),
            .type_aliases = std.StringHashMap(ast.TypeExpr).init(allocator),
            .functions = std.StringHashMap(FnInfo).init(allocator),
            .backend_names = std.StringHashMap([]const u8).init(allocator),
            .const_fns = std.StringHashMap(ast.FnDecl).init(allocator),
            .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
            .const_global_widths = std.StringHashMap(u16).init(allocator),
            .const_global_domains = std.StringHashMap(eval.DomainWidth).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
            .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
            .tagged_unions = std.StringHashMap(ast.UnionDecl).init(allocator),
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .array_types = std.StringHashMap(ArrayInfo).init(allocator),
            .slice_types = std.StringHashMap(SliceInfo).init(allocator),
            .result_types = std.StringHashMap(ResultInfo).init(allocator),
            .opt_types = std.StringHashMap(lower_c_model.OptInfo).init(allocator),
            .fn_ptr_types = std.StringHashMap(ast.TypeExpr).init(allocator),
            .closure_types = std.StringHashMap(ast.TypeExpr).init(allocator),
            .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
            .trait_decls = std.StringHashMap(ast.TraitDecl).init(allocator),
            .impl_methods = std.StringHashMap([]const ast.ImplTraitMethod).init(allocator),
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
        self.function_decl_artifacts.deinit(self.allocator);
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
        self.mmio_struct_decl_artifacts.deinit(self.allocator);
        self.aggregate_decl_artifacts.deinit(self.allocator);
        self.structs.deinit();
        self.type_aliases.deinit();
    }

    fn deinitDeclCollections(self: *CEmitter) void {
        self.const_global_widths.deinit();
        self.const_global_domains.deinit();
        self.const_fns.deinit();
        self.owned_comptime_declarations.deinit(self.allocator);
        eval.deinitConstGlobals(self.allocator, &self.const_globals);
        self.static_initializers.deinit();
        self.global_decl_artifacts.deinit(self.allocator);
        self.globals.deinit();
    }

    fn deinitControlFlowState(self: *CEmitter) void {
        self.loop_ids.deinit(self.allocator);
        self.loop_labels.deinit(self.allocator);
    }

    fn collectModule(self: *CEmitter, early_metadata: early_declaration_metadata.EarlyDeclarationArtifacts) anyerror!void {
        try lower_c_module.collect(self, early_metadata);
    }

    pub fn setComptimeDeclarationsFromArtifacts(self: *CEmitter, artifacts: early_declaration_metadata.EarlyDeclarationArtifacts) !void {
        self.owned_comptime_declarations.deinit(self.allocator);
        self.owned_comptime_declarations = try early_declaration_metadata.ComptimeDeclarationArtifacts.collectFromArtifacts(self.allocator, artifacts);
        self.comptime_declarations = self.owned_comptime_declarations.view();
    }

    pub fn collectEarlyDeclarationMetadata(self: *CEmitter, artifacts: early_declaration_metadata.EarlyDeclarationArtifacts) !void {
        // Pre-pass: collect const/comptime metadata and pre-register nominal type
        // names up front, so fixed-array lengths, reflection queries, and type-name
        // mangling resolve during the artifact-collection pass below. Const global
        // widths stay in this early pass because later type artifact collection can
        // consult the reflection environment.
        for (artifacts.callable_value_artifacts) |artifact| switch (artifact) {
            .function => |function| {
                const fn_decl = function.fn_decl;
                if (fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
            },
            else => {},
        };
        const declarations = self.comptime_declarations orelse return error.UnsupportedCEmission;
        for (declarations.globals) |global| {
            if (!global.is_const) continue;
            const ty = global.ty orelse continue;
            const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
            try self.const_global_widths.put(global.name.text, bits);
        }
        for (artifacts.type_artifacts) |artifact| switch (artifact) {
            .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
            .struct_decl => |struct_decl| if (!isMmioStructAbi(struct_decl)) try self.structs.put(struct_decl.name.text, struct_decl),
            .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
            .union_decl => |union_decl| try self.tagged_unions.put(union_decl.name.text, union_decl),
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

    pub fn collectDeclArtifacts(self: *CEmitter, artifacts: early_declaration_metadata.EarlyDeclarationArtifacts) anyerror!void {
        try self.collectCallableValueArtifacts(artifacts.callable_value_artifacts);
        try self.collectTypeArtifactsFromArtifacts(artifacts.type_artifacts);
    }

    fn collectCallableValueArtifacts(self: *CEmitter, artifacts: []const early_declaration_metadata.CallableValueArtifact) anyerror!void {
        for (artifacts) |artifact| switch (artifact) {
            .global => |global| try self.collectGlobalDeclArtifact(global),
            .function => |function| try self.collectFnDeclArtifact(function.fn_decl, function.attrs, false),
            .extern_function => |function| try self.collectFnDeclArtifact(function.fn_decl, function.attrs, true),
            .trait_decl => |trait_decl| try self.trait_decls.put(trait_decl.name.text, trait_decl),
            .impl_trait => |impl_trait| try self.collectImplTraitArtifact(impl_trait),
        };
    }

    fn collectTypeArtifactsFromArtifacts(self: *CEmitter, artifacts: []const early_declaration_metadata.TypeArtifact) anyerror!void {
        for (artifacts) |artifact| switch (artifact) {
            .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
            .struct_decl => |struct_decl| try self.collectStructDeclArtifact(struct_decl),
            .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
            .union_decl => |union_decl| try self.collectTaggedUnion(union_decl),
            .packed_bits => |packed_bits| try self.collectPackedBits(packed_bits),
            .overlay_union => |overlay_union| try self.collectOverlayUnion(overlay_union),
            .opaque_decl => {},
        };
    }

    fn collectGlobalDeclArtifact(self: *CEmitter, global: ast.GlobalDecl) !void {
        try self.global_decl_artifacts.append(self.allocator, global);
        if (global.ty) |ty| {
            var info = try self.globalInfoFromType(ty);
            info.is_const = global.is_const;
            try self.globals.put(global.name.text, info);
        }
        if (global.ty) |ty| try self.collectTypeArtifacts(ty);
    }

    fn collectStructDeclArtifact(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        if (isMmioStructAbi(struct_decl)) {
            try self.mmio_struct_decl_artifacts.append(self.allocator, struct_decl);
            try self.collectMmioStruct(struct_decl);
            return;
        }
        try self.structs.put(struct_decl.name.text, struct_decl);
        for (struct_decl.fields) |field| try self.collectTypeArtifacts(field.ty);
        try self.aggregate_decl_artifacts.append(self.allocator, .{ .struct_decl = struct_decl });
    }

    fn collectFnDeclArtifact(self: *CEmitter, fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool) !void {
        try self.functions.put(fn_decl.name.text, .{ .params = fn_decl.params, .return_type = fn_decl.return_type, .is_extern = is_extern, .is_variadic = fn_decl.is_variadic, .error_from = error_from.hasAttr(attrs) });
        if (!is_extern and hasNamedAttr(attrs, "drop")) {
            if (type_syntax.dropPointerReleaseParamTypeName(fn_decl)) |type_name| {
                if (!mir_ownership_authority.dropGlueDeclMatches(self.mir_module, type_name, fn_decl.name.text)) return error.UnsupportedCEmission;
            }
        }
        try self.function_decl_artifacts.append(self.allocator, .{ .fn_decl = fn_decl, .attrs = attrs, .is_extern = is_extern });
        if (!is_extern and fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
        if (!is_extern) if (backendNameOverride(attrs)) |name| try self.backend_names.put(fn_decl.name.text, name);
        try self.collectFunctionSliceTypes(fn_decl);
    }

    pub fn validateDropGlueFactsAgainstDecls(self: *CEmitter) !void {
        if (!mir_ownership_authority.dropGlueFactsMatchDeclArtifacts(self.mir_module, self.function_decl_artifacts.items)) return error.UnsupportedCEmission;
    }

    fn collectImplTraitArtifact(self: *CEmitter, impl_trait: ast.ImplTrait) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ impl_trait.trait_name.text, impl_trait.type_name.text });
        try self.impl_methods.put(key, impl_trait.methods);
    }

    pub fn collectBindThunks(self: *CEmitter) anyerror!void {
        // Now that every function signature is known, scan all bodies for
        // `bind(scalar, f)` closures that need an env-widening thunk.
        for (self.function_decl_artifacts.items) |artifact| {
            if (artifact.is_extern) continue;
            if (artifact.fn_decl.body) |body| {
                const mir_function = self.mirFunctionNamed(artifact.fn_decl.name.text) orelse return error.UnsupportedCEmission;
                try self.collectBlockBindThunks(body, mir_function);
            }
        }
    }

    fn emitModule(self: *CEmitter, early_metadata: early_declaration_metadata.EarlyDeclarationArtifacts) anyerror!void {
        try lower_c_module.emit(self, early_metadata);
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
        for (self.mmio_struct_decl_artifacts.items) |struct_decl| {
            if (self.mmio_structs.contains(struct_decl.name.text)) {
                try lower_c_mmio.emitStruct(self.mmioStructEmitContext(), struct_decl);
            }
        }
    }

    pub fn emitFunctionDeclarations(self: *CEmitter) anyerror!void {
        // Forward-declare every defined function up front so a call to a function
        // declared later in the (possibly import-merged) source resolves — MC
        // resolves calls module-wide, independent of declaration order.
        for (self.function_decl_artifacts.items) |artifact| {
            if (artifact.is_extern) {
                // Extern prototypes must precede any function body that calls them;
                // an imported `extern fn` can be merged after its caller.
                try self.emitExternFunction(artifact.fn_decl);
            } else if (artifact.fn_decl.body != null) {
                try self.emitFunctionForwardDecl(artifact.fn_decl);
            }
        }
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
        for (self.global_decl_artifacts.items) |global| try self.emitGlobal(global);
    }

    pub fn emitFunctionDefinitions(self: *CEmitter) anyerror!void {
        for (self.function_decl_artifacts.items) |artifact| {
            if (artifact.is_extern) {
                // Extern prototypes were already emitted in the forward-declaration pass.
                continue;
            }
            if (artifact.fn_decl.body) |body| {
                try self.emitFunction(artifact.fn_decl, body, artifact.attrs);
            } else {
                try self.emitFunctionPrototype(artifact.fn_decl);
            }
        }
    }

    fn emitGlobal(self: *CEmitter, global: ast.GlobalDecl) !void {
        const previous_function = self.current_function;
        self.current_function = global.name.text;
        defer self.current_function = previous_function;
        try emitGlobalDecl(self.globalEmitContext(), global);
    }

    // Fold a `const` global initializer to its C constant text (section 22).
    fn constGlobalCValue(self: *CEmitter, expr: ast.Expr, ty: ?ast.TypeExpr) !?[]const u8 {
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

    fn emitConstGlobalInitializer(self: *CEmitter, ty: ast.TypeExpr, expr: ast.Expr) !bool {
        if (expr_syntax.callExpr(expr)) |call| {
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

    fn foldConstGlobalValue(self: *CEmitter, expr: ast.Expr, expected_ty: ?ast.TypeExpr) ?eval.ComptimeValue {
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

    fn cTypeForReflect(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn comptimeSizeOf(self: *CEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        var env = self.reflectEnv();
        return lower_c_reflect.comptimeSizeOf(&env, ty, depth);
    }

    fn emitComptimeValueInitializer(self: *CEmitter, value: eval.ComptimeValue, target_ty: ast.TypeExpr) anyerror!void {
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

    fn emitComptimeArrayInitializer(self: *CEmitter, items: []const eval.ComptimeValue, resolved: ast.TypeExpr) anyerror!void {
        const child_ty = resolvedArrayChildType(resolved) orelse return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, "{ .elems = { ");
        for (items, 0..) |item, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitComptimeValueInitializer(item, child_ty);
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitComptimeStructInitializer(self: *CEmitter, fields: []const eval.ComptimeStructField, resolved: ast.TypeExpr) anyerror!void {
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

    fn isAggregateGlobalType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return lower_c_info.isAggregateGlobalType(self.infoContext(), ty);
    }

    fn emitEnums(self: *CEmitter) !void {
        try lower_c_defs.emitEnums(self.defsContext(), &self.enums);
    }

    fn emitEnumType(self: *CEmitter, enum_decl: ast.EnumDecl) !void {
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

    fn emitTaggedUnionType(self: *CEmitter, union_decl: ast.UnionDecl) !void {
        try lower_c_defs.emitTaggedUnionType(self.defsContext(), union_decl);
    }

    fn emitEnumCaseValue(self: *CEmitter, value: ast.Expr) !void {
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

    fn unsupportedEnumValue(self: *CEmitter, value: ast.Expr) !void {
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
        for (self.aggregate_decl_artifacts.items) |artifact| {
            var keyword: []const u8 = "struct";
            const name = switch (artifact) {
                .struct_decl => |struct_decl| blk: {
                    if (!self.structs.contains(struct_decl.name.text)) continue;
                    // A `#[c_union]` is a real C `union`; its forward tag must
                    // match its definition tag (`typedef union U U;`), not the
                    // default `struct`.
                    if (struct_decl.is_c_union) keyword = "union";
                    break :blk struct_decl.name.text;
                },
                .tagged_union => |union_decl| if (self.tagged_unions.contains(union_decl.name.text)) union_decl.name.text else continue,
            };
            try self.out.print(self.allocator, "typedef {s} {s} {s};\n", .{ keyword, name, name });
            emitted = true;
        }
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
    /// genuine drift on resolvable (e.g. virtqueue) structs is still a hard error.
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

        for (self.aggregate_decl_artifacts.items) |artifact| switch (artifact) {
            .struct_decl => |s| if (self.structs.contains(s.name.text)) try units.append(arena, .{ .struct_decl = s }),
            .tagged_union => |u| if (self.tagged_unions.contains(u.name.text)) try units.append(arena, .{ .tagged_union = u }),
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

    fn aggregateDepNameForType(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        try lower_c_defs.emitStruct(self.defsContext(), struct_decl);
    }

    fn emitSliceTypes(self: *CEmitter) !void {
        try lower_c_defs.emitSliceTypes(self.defsContext(), &self.slice_types);
    }

    // C has no `void` struct member, so a `Result<void, E>` (or `Result<T, void>`)
    // payload uses a 1-byte placeholder. The unit value `()` lowers to `0`, so
    // `.payload.ok = 0` stays well-formed.
    fn resultPayloadCType(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (isVoidType(self.resolveAliasType(ty))) return "unsigned char";
        return try self.cTypeFor(ty, .typedef_name);
    }

    fn emitResultType(self: *CEmitter, result: ResultInfo) !void {
        try lower_c_defs.emitResultType(self.defsContext(), result);
    }

    fn emitArrayType(self: *CEmitter, array: ArrayInfo) !void {
        try lower_c_defs.emitArrayType(self.defsContext(), array);
    }

    fn emitFunctionPrototype(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionSignature(fn_decl, false, true);
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    // Forward declaration for a *defined* function, matching the definition's
    // storage class (non-exported functions are `static`) so the prototype and
    // body agree.
    fn emitFunctionForwardDecl(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionSignature(fn_decl, !fn_decl.exported, true);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitExternFunction(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionPrototype(fn_decl);
    }

    fn emitFunction(self: *CEmitter, fn_decl: ast.FnDecl, body: ast.Block, attrs: []const ast.Attr) anyerror!void {
        try self.writeLineDirective(fn_decl.name.span);
        try attr_syntax.emitCFunctionAttrs(self.allocator, self.out, attrs);
        if (hasNakedAttr(attrs)) {
            try self.emitNakedFunction(fn_decl, body);
            return;
        }
        try self.emitFunctionBody(fn_decl, body);
    }

    fn emitNakedFunction(self: *CEmitter, fn_decl: ast.FnDecl, body: ast.Block) !void {
        try self.emitFunctionSignature(fn_decl, !fn_decl.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");
        try self.emitNakedAsmBody(body);
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitFunctionBody(self: *CEmitter, fn_decl: ast.FnDecl, body: ast.Block) anyerror!void {
        try self.emitFunctionSignature(fn_decl, !fn_decl.exported, false);
        try self.out.appendSlice(self.allocator, " {\n");

        const previous_function = self.current_function;
        const previous_function_body = self.current_function_body;
        self.current_function = fn_decl.name.text;
        self.current_function_body = body;
        defer self.current_function = previous_function;
        defer self.current_function_body = previous_function_body;
        try self.validateFunctionCleanupAuthority();
        self.mir_pointer_local_provenance.clearRetainingCapacity();
        self.clearOwnedStringProvenanceMapRetainingCapacity(&self.mir_pointer_array_elements);
        self.clearOwnedStringProvenanceMapRetainingCapacity(&self.mir_aggregate_pointer_fields);

        const previous_variadic_last = self.current_variadic_last;
        self.current_variadic_last = functionVariadicLastParam(fn_decl);
        defer self.current_variadic_last = previous_variadic_last;

        var locals = try self.functionParamLocals(fn_decl.params);
        defer locals.deinit();
        try self.emitIndentedFunctionBlock(body, &locals, fn_decl.return_type);
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn functionVariadicLastParam(fn_decl: ast.FnDecl) ?[]const u8 {
        if (!fn_decl.is_variadic or fn_decl.params.len == 0) return null;
        return fn_decl.params[fn_decl.params.len - 1].name.text;
    }

    fn functionParamLocals(self: *CEmitter, params: []const ast.Param) !std.StringHashMap(LocalInfo) {
        var locals = std.StringHashMap(LocalInfo).init(self.allocator);
        errdefer locals.deinit();
        for (params) |param| try locals.put(param.name.text, try self.localInfoFromType(param.ty));
        return locals;
    }

    fn emitIndentedFunctionBlock(self: *CEmitter, body: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        self.indent += 1;
        defer self.indent -= 1;
        try self.emitBlockItems(body, locals, return_ty);
    }

    // The single asm block of a `#[naked]` function, emitted as *basic* asm (no
    // operands or clobber list — those are ill-formed inside a naked function). The
    // template strings carry the hand-written machine code that does the ABI-correct
    // jump/return itself.
    fn emitNakedAsmBody(self: *CEmitter, body: ast.Block) !void {
        const asm_stmt = expr_syntax.nakedAsmStmt(body) orelse return error.UnsupportedCEmission;
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

    fn emitFunctionSignature(self: *CEmitter, fn_decl: ast.FnDecl, is_static: bool, with_asm_label: bool) !void {
        try lower_c_defs.emitFunctionSignature(self.defsContext(), fn_decl, is_static, with_asm_label);
    }

    fn emitParamDecl(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try lower_c_defs.emitParamDecl(self.defsContext(), ty, name);
    }

    fn emitDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .typedef_name);
    }

    fn emitIgnoredLocalPrefix(self: *CEmitter, name: []const u8) !void {
        if (name.len > 0 and name[0] == '_') {
            try self.out.appendSlice(self.allocator, "MC_UNUSED ");
        }
    }

    fn emitStructFieldDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .struct_tag);
    }

    fn emitDeclaratorWithStyle(self: *CEmitter, ty: ast.TypeExpr, name: []const u8, style: StructTypeStyle) !void {
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

    fn cTypeFor(self: *CEmitter, ty: ast.TypeExpr, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendType(&out, ty, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn emitVaStartLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr) !bool {
        return lower_c_call.emitVaStartLocalInit(self.callLocalInitContext(), name, decl_ty, initializer);
    }

    fn emitVaListCopyLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr) !bool {
        return lower_c_call.emitVaListCopyLocalInit(self.callLocalInitContext(), name, decl_ty, initializer);
    }

    fn appendType(self: *CEmitter, out: *std.ArrayList(u8), ty: ast.TypeExpr, style: StructTypeStyle) anyerror!void {
        try lower_c_type.appendType(self.typeEmitContext(), out, ty, style);
    }

    fn resolveAliasType(self: *CEmitter, ty: ast.TypeExpr) ast.TypeExpr {
        return type_syntax.resolveAliasType(&self.type_aliases, ty);
    }

    fn aliasTargetType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return type_syntax.aliasTargetType(&self.type_aliases, ty);
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

    fn globalInfoFromTypeForGlobal(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!GlobalInfo {
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

    fn arrayLenTextForNames(ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }

    fn writeLineDirectiveForGlobal(ctx: *anyopaque, span: ast.Span) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.writeLineDirective(span);
    }

    fn emitDeclaratorForGlobal(ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitDeclarator(ty, name);
    }

    fn constGlobalCValueForGlobal(ctx: *anyopaque, expr: ast.Expr, ty: ?ast.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.constGlobalCValue(expr, ty);
    }

    fn emitExprForGlobal(ctx: *anyopaque, expr: ast.Expr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, null);
    }

    fn emitExprWithTargetForGlobal(ctx: *anyopaque, expr: ast.Expr, target_ty: ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, null, target_ty);
    }

    fn emitConstGlobalInitializerForGlobal(ctx: *anyopaque, ty: ast.TypeExpr, expr: ast.Expr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitConstGlobalInitializer(ty, expr);
    }

    fn isAggregateGlobalTypeForGlobal(ctx: *anyopaque, ty: ast.TypeExpr) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.isAggregateGlobalType(ty);
    }

    fn writeIndentForOverlay(ctx: *anyopaque) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.writeIndent();
    }

    fn cTypeForOverlay(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitExprForOverlay(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, locals);
    }

    fn emitExprWithTargetForOverlay(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn overlayFieldLayoutSizeForOverlay(ctx: *anyopaque, ty: ast.TypeExpr) usize {
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

    fn emitExprWithTargetForAsm(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
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

    fn isValueOptionalForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn numericExprTypeForConvert(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.numericExprTypeForEmission(expr, locals);
    }

    fn unaryResultTypeForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.unaryResultTypeForEmission(expr, locals);
    }

    fn unaryResultTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const node = switch (expr.kind) {
            .unary => |node| node,
            else => return null,
        };
        const inferred = if (node.op == .logical_not)
            type_syntax.simpleNameType("bool", expr.span)
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
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return null;
        };
        return fact_ty;
    }

    fn underlyingIntTypeNameForConvert(ctx: *anyopaque, ty: ast.TypeExpr) ?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.underlyingIntTypeName(ty);
    }

    fn resultTypeNameForConvert(ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultTypeName(ok_ty, err_ty);
    }

    fn optTypeNameForType(ctx: *anyopaque, payload_ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_names.optTypeName(self.typeNameContext(), self.resolveAliasType(payload_ty));
    }

    fn sliceTypeNameForType(ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn arrayTypeNameForType(ctx: *anyopaque, child: ast.TypeExpr, len_expr: ast.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayTypeName(child, len_expr);
    }

    fn fnPtrTypeNameForType(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.fnPtrTypeName(ty.kind.fn_pointer);
    }

    fn closureTypeNameForType(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.closureTypeName(ty.kind.closure_type);
    }

    fn dynTypeNameForType(ctx: *anyopaque, trait_name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.dynTypeName(trait_name);
    }

    fn operandEmitTypeForAtomic(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn exprIsPointerForAtomic(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprIsPointer(expr, locals);
    }

    fn emitExprForCall(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExpr(expr, locals);
    }

    fn emitExprWithTargetForArith(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn emitCheckedUnaryExprForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const node = switch (expr.kind) {
            .unary => |node| node,
            else => return false,
        };
        return lower_c_arith.emitCheckedUnaryWithTarget(self.arithContext(), node, locals, target_ty);
    }

    fn emitCheckedBinaryExprForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const node = switch (expr.kind) {
            .binary => |node| node,
            else => return false,
        };
        return lower_c_arith.emitCheckedBinaryWithTarget(self.arithContext(), node, locals, target_ty);
    }

    fn countMmioReadsForExpr(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) usize {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_mmio.countReads(self.mmioEmitContext(), expr, locals);
    }

    fn exprResolvesToFloatForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprResolvesToFloat(expr, locals);
    }

    fn emitBlockItemsForFlow(ctx: *anyopaque, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitBlockItemsWithDeferStackSnapshot(block, locals, return_ty);
    }

    fn emitBlockItemsForMmio(ctx: *anyopaque, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitBlockItems(block, locals, return_ty);
    }

    fn emitSwitchBodyForSwitch(ctx: *anyopaque, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitSwitchBody(body, locals, return_ty);
    }

    fn emitMmioReadExprWithReplacementsForSwitch(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const MmioReadReplacement) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try lower_c_mmio.emitReadExprWithReplacements(self.mmioReplacementEmitContext(), expr, locals, target_ty, replacements);
    }

    fn localInfoFromTypeForSwitch(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn taggedUnionTypeForSwitch(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.taggedUnionTypeForExpr(expr, locals);
    }

    fn nullableInnerCTypeForSwitch(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.nullableInnerCTypeForType(ty);
    }

    fn localInfoFromTypeForFlow(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn arrayLenTextForFlow(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenText(ty);
    }

    fn conditionOperandTypeForFlow(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.conditionOperandTypeForEmission(expr, locals);
    }

    fn emitLoopForFlow(ctx: *anyopaque, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitForLoop(loop, locals, return_ty);
    }

    fn emitSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitAddressSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitAddressSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitIndexSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitIndexSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitBinarySequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitBinarySequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitDerefSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return lower_c_access.emitRawManyOffsetDerefValueTemp(self.accessEmitContext(), arg, locals, target_ty);
    }

    fn emitAggregateSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const mir_target_ty = (try self.mirAggregateTargetTypeForExpr(arg)) orelse target_ty;
        return lower_c_aggregate.emitUncheckedAddAggregateCallArgTemp(self.aggregateEmitContext(), arg, locals, mir_target_ty);
    }

    fn emitSequencedValueTempForAggregate(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (expr.kind == .uninit_literal) return null;
        if (try self.emitUncheckedAddValueTemp(expr, locals, target_ty, range_target)) |temp| return temp;
        return try self.emitSequencedCallArgTemp(expr, locals, target_ty);
    }

    fn operandEmitTypeForAggregate(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForAggregate(ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForAggregate(ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitCastSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (try self.emitAtomicCastSequencedCallArgTemp(arg, locals, target_ty)) |temp| return temp;
        return self.emitUncheckedAddValueTemp(arg, locals, target_ty, "call_arg");
    }

    fn emitCallSequencedArgTempForCall(ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitCallSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn cTypeForCall(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn emitDeclaratorForCall(ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitDeclarator(ty, name);
    }

    fn cIdentForCall(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn mirCheckElidedForArith(ctx: *anyopaque, span: ast.Span) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirCheckElided(span);
    }

    fn hasMirNoOverflowRangeFactForArith(ctx: *anyopaque, target: []const u8, op: []const u8, span: ast.Span) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.hasMirNoOverflowRangeFact(target, op, span);
    }

    fn mirCallTargetKindForLowering(ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirCallTargetKindAt(span);
    }

    fn mirTargetTypeForLowering(ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return if (self.mirTargetTypeFactAt(kind, span)) |fact| fact.target_ty else null;
    }

    fn mirOwnedTargetTypeForLowering(ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return if (self.mirTargetTypeFactAtOwned(kind, span, target_owner, target_index)) |fact| fact.target_ty else null;
    }

    fn mirConstGetIndexForLowering(ctx: *anyopaque, span: ast.Span) ?usize {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mirConstGetIndexAt(span);
    }

    fn localInfoFromTypeForArith(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn operandEmitTypeForArith(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForArith(ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForArith(ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitSequencedBinaryOperandTempForArith(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        if (try self.emitUncheckedAddValueTemp(expr, locals, target_ty, "binary_operand")) |temp| return temp;
        return try self.emitSequencedCallArgTemp(expr, locals, target_ty);
    }

    fn operandEmitTypeForTry(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForTry(ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForTry(ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitResultTrySequencedBinaryValueTempForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.emitResultTrySequencedBinaryValueTemp(self.tryDirectEmitContext(), expr, locals, target_ty, return_ty, mode);
    }

    fn emitNullableTrySequencedBinaryValueTempForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.emitNullableTrySequencedBinaryValueTemp(self.tryDirectEmitContext(), expr, locals, target_ty);
    }

    fn exprContainsResultTryForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprContainsResultTry(expr, locals);
    }

    fn callArgsContainResultTryForTry(ctx: *anyopaque, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.callArgsContainResultTry(args, locals);
    }

    fn callArgsContainNullableTryForTry(ctx: *anyopaque, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try self.callArgsContainNullableTry(args, locals);
    }

    fn collectResultTryHoistsForStmtForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectResultTryHoistsForStmt(self.tryDirectEmitContext(), expr, locals, return_ty, replacements);
    }

    fn collectResultTryHoistsForLocalInitForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr, replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectResultTryHoistsForLocalInit(self.tryDirectEmitContext(), expr, locals, enclosing_return_ty, replacements);
    }

    fn collectNullableTryHoistsForReturnForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(TryReplacement)) anyerror!bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_try.collectNullableTryHoistsForReturn(self.tryDirectEmitContext(), expr, locals, replacements);
    }

    fn emitDeferredCleanupsForTry(ctx: *anyopaque, locals: *std.StringHashMap(LocalInfo), return_ty: ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitCleanupEdge(.error_exit, locals, return_ty, null, null);
    }

    fn operandEmitTypeForAccess(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForAccess(ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForAccess(ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn localInfoFromTypeForAccess(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.localInfoFromType(ty);
    }

    fn arrayLenTextForAccess(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try self.arrayLenText(ty);
    }

    fn sliceTypeNameForMemory(ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn cIdentForMemory(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn emitExprWithTargetForMemory(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitExprWithTarget(expr, locals, target_ty);
    }

    fn mmioAccessForMmio(ctx: *anyopaque, callee: ast.Expr, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.mmioAccess(callee, args, locals);
    }

    fn valueCTypeForMmio(ctx: *anyopaque, value_type: []const u8) []const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeForMmioValue(value_type);
    }

    fn operandEmitTypeForMmio(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn globalAssignmentTargetForMmio(ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.globalAssignmentTarget(target, locals);
    }

    fn emitAssignTargetForMmio(ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitAssignTarget(target, locals);
    }

    fn emitMmioReadSequencedBinaryValueTempForMmio(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try lower_c_mmio.emitReadSequencedBinaryValueTemp(self.mmioCallEmitContext(), expr, locals, target_ty);
    }

    fn cTypeForDefs(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, .typedef_name);
    }

    fn cIdentForDefs(ctx: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cIdent(name);
    }

    fn declaratorForDefs(ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitDeclarator(ty, name);
    }

    fn fieldDeclaratorForDefs(ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitStructFieldDeclarator(ty, name);
    }

    fn enumCaseValueForDefs(ctx: *anyopaque, value: ast.Expr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitEnumCaseValue(value);
    }

    fn resultPayloadCTypeForDefs(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultPayloadCType(ty);
    }

    fn isVoidTypeForDispatch(ctx: *anyopaque, ty: ast.TypeExpr) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return isVoidType(self.resolveAliasType(ty));
    }

    fn collectPackedBits(self: *CEmitter, packed_bits: ast.PackedBitsDecl) !void {
        try lower_c_collect.collectPackedBits(self.allocator, &self.packed_bits, packed_bits, try self.cTypeFor(packed_bits.repr, .typedef_name));
    }

    fn collectOverlayUnion(self: *CEmitter, overlay_union: ast.OverlayUnionDecl) !void {
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

    fn collectTaggedUnion(self: *CEmitter, union_decl: ast.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| try self.collectTypeArtifacts(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
        try self.aggregate_decl_artifacts.append(self.allocator, .{ .tagged_union = union_decl });
    }

    fn overlayFieldLayout(self: *CEmitter, ty: ast.TypeExpr) ?OverlayLayout {
        var reflect_env = self.reflectEnv();
        return overlayFieldLayoutForType(ty, &self.const_fns, &self.const_globals, &reflect_env);
    }

    fn overlayByteArrayLen(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
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

    fn collectMmioStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        try lower_c_collect.collectMmioStruct(self.allocator, &self.mmio_structs, struct_decl);
    }

    fn appendPointerType(self: *CEmitter, out: *std.ArrayList(u8), child: ast.TypeExpr, mutability: ast.Mutability, style: StructTypeStyle) anyerror!void {
        try lower_c_type.appendPointerType(self.typeEmitContext(), out, child, mutability, style);
    }

    fn collectFunctionSliceTypes(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        const previous_function = self.current_function;
        self.current_function = fn_decl.name.text;
        defer self.current_function = previous_function;
        try lower_c_collect.collectFunctionTypeArtifacts(self.typeArtifactContext(), fn_decl);
    }

    fn collectBlockSliceTypes(self: *CEmitter, block: ast.Block) anyerror!void {
        try lower_c_collect.collectBlockTypeArtifacts(self.typeArtifactContext(), block);
    }

    fn collectTypeArtifacts(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        const resolved_ty = self.resolveAliasType(ty);
        try lower_c_collect.collectArrayType(self.arrayArtifactContext(), resolved_ty);
        try lower_c_collect.collectSliceType(self.sliceArtifactContext(), resolved_ty);
        try lower_c_collect.collectResultType(self.resultArtifactContext(), resolved_ty);
        try lower_c_collect.collectFnPtrType(self.fnPtrArtifactContext(), resolved_ty);
        try self.collectOptTypes(ty);
    }

    // Register any value optional `?T` (tagged repr) reachable through `ty` so its
    // `mc_opt_<T>` typedef is emitted. Mirrors collectSliceType's per-type dedup.
    fn collectOptTypes(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
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
                        if (!type_syntax.sameTypeSyntax(existing.payload_ty, payload)) return error.GeneratedTypeNameCollision;
                    } else try self.opt_types.put(name, .{ .name = name, .payload_ty = payload });
                }
            },
            else => {},
        }
    }

    // A `?T` payload uses the tagged repr iff T is a sized VALUE type (not a pointer,
    // slice, fn-pointer, or `*dyn` — those keep the null-sentinel repr).
    fn nullablePayloadIsValueOptional(self: *CEmitter, child: ast.TypeExpr) bool {
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

    fn typeArtifactContext(self: *CEmitter) lower_c_collect.TypeArtifactContext {
        return .{
            .emit_ctx = self,
            .collect_type_artifacts = collectTypeArtifactsForCollect,
            .mir_call_target_kind = mirCallTargetKindForLowering,
            .mir_target_type = mirTargetTypeForLowering,
        };
    }

    fn collectTypeArtifactsForCollect(ctx: *anyopaque, ty: ast.TypeExpr) anyerror!void {
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

    fn arrayTypeNameForCollect(ctx: *anyopaque, child: ast.TypeExpr, len_expr: ast.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayTypeName(child, len_expr);
    }

    fn arrayLenTextForCollect(ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }

    fn cTypeForTypedefForCollect(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
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

    fn resultTypeNameForCollect(ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8 {
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

    fn sliceTypeNameForCollect(ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceTypeName(child, mutability);
    }

    fn pointerTypeForSliceElementForCollect(ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8 {
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

    fn fnPtrTypeNameForCollect(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.fnPtrTypeName(ty.kind.fn_pointer);
    }

    fn closureTypeNameForCollect(ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8 {
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
    fn closureCalleeType(self: *CEmitter, callee: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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
    fn bindEnvIsPointerLike(self: *CEmitter, ty: ast.TypeExpr) bool {
        return lower_c_collect.bindEnvIsPointerLike(&self.type_aliases, ty);
    }

    fn collectBlockBindThunks(self: *CEmitter, block: ast.Block, mir_function: *const mir.Function) anyerror!void {
        try lower_c_collect.collectBlockBindThunks(.{
            .name_allocator = self.scratch.allocator(),
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .bind_thunks = &self.bind_thunks,
            .mir_function = mir_function,
        }, block);
    }

    // Emit `bind(&env, f)` as a closure compound literal. `f` names a function whose
    // first parameter is the (typed) env; the closure drops it to void*.
    fn emitBind(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !void {
        const plan = try self.bindEmitPlan(node, target_ty);
        if (!self.bindEnvIsPointerLike(plan.info.params[0].ty)) {
            try lower_c_dispatch.emitScalarEnvBind(self.dispatchContext(), node, locals, plan);
            return;
        }
        try lower_c_dispatch.emitPointerEnvBind(self.dispatchContext(), node, locals, plan);
    }

    fn bindEmitPlan(self: *CEmitter, node: anytype, target_ty: ast.TypeExpr) !lower_c_dispatch.BindEmitPlan {
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
        params: []ast.TypeExpr,
        ret: *ast.TypeExpr,
    };

    fn closureNodeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ClosureTypeNode {
        return switch (self.resolveAliasType(ty).kind) {
            .closure_type => |node| .{ .params = node.params, .ret = node.ret },
            else => null,
        };
    }

    // If `callee` is `d.method` where `d` has a `*dyn Trait` type, return the trait name;
    // such a call dispatches through the vtable. Null otherwise.
    fn dynCalleeTrait(self: *CEmitter, callee: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        const member = memberExpr(callee) orelse return null;
        const base_ty = self.memberBaseTypeForEmission(member.base.*, locals) orelse return null;
        return self.dynDispatchTraitNameFromCandidate(base_ty);
    }

    // `d.method(args)` -> `({ mc_dyn_T t = d; t.vtable->method(t.data, args); })`.
    // The `d` value is spilled to a temp so its `.data`/`.vtable` are read once.
    fn sliceTypeName(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        return lower_c_names.sliceTypeName(self.typeNameContext(), child, mutability);
    }

    fn pointerTypeForSliceElement(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, if (mutability == .mut) .mut else .@"const", .typedef_name);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn pointerTypeFor(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, mutability, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn arrayTypeName(self: *CEmitter, child: ast.TypeExpr, len_expr: ast.Expr) ![]const u8 {
        return lower_c_names.arrayTypeName(self.typeNameContext(), child, len_expr);
    }

    fn typeSuffix(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        return lower_c_names.typeSuffix(self.typeNameContext(), ty);
    }

    fn resultTypeName(self: *CEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) ![]const u8 {
        return lower_c_names.resultTypeName(self.typeNameContext(), ok_ty, err_ty);
    }

    fn emitStmt(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitLocalDeclStmt(self: *CEmitter, local: ast.LocalDecl, is_let: bool, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn localDeclInfo(self: *CEmitter, local: ast.LocalDecl, is_let: bool, locals: *std.StringHashMap(LocalInfo)) !LocalInfo {
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

    fn emitSpecialLocalDecl(self: *CEmitter, name: []const u8, local: ast.LocalDecl, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
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
        decl_ty: ast.TypeExpr,
        initializer: ast.Expr,
        locals: *std.StringHashMap(LocalInfo),
        return_ty: ?ast.TypeExpr,
    ) anyerror!bool {
        if (try self.emitVarargsTypedLocalInit(name, decl_ty, initializer)) return true;
        if (try lower_c_special.emitTypedLocalInit(self.tryMmioContext(), name, decl_ty, initializer, locals, return_ty)) return true;
        if (try self.emitAccessTypedLocalInit(name, decl_ty, initializer, locals)) return true;
        if (try self.emitConversionTypedLocalInit(name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitVarargsTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr) anyerror!bool {
        if (try self.emitVaStartLocalInit(name, decl_ty, initializer)) return true;
        if (try self.emitVaListCopyLocalInit(name, decl_ty, initializer)) return true;
        return false;
    }

    fn emitAccessTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try lower_c_access.emitDirectCallSliceIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAddressLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitLocalIndexAddressLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_access.emitLocalIndexLocalInit(self.accessEmitContext(), name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitConversionTypedLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
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

    fn emitSpecialInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
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

    fn emitAddressOfInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const operand = switch (initializer.kind) {
            .address_of => |inner| inner.*,
            .grouped => |inner| return try self.emitAddressOfInferredLocalInit(name, inner.*, locals),
            else => return false,
        };
        const place = self.directAddressPlaceInfo(operand, locals) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, null)) orelse return error.UnsupportedCEmission;
        const pointer = self.pointerNodeFromCandidate(inferred_ty) orelse return error.UnsupportedCEmission;
        if (pointer.mutability != place.mutability) return error.UnsupportedCEmission;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(pointer.child.*), self.resolveAliasType(place.ty))) return error.UnsupportedCEmission;
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
        ty: ast.TypeExpr,
        mutability: ast.Mutability,
    };

    fn directAddressPlaceInfo(self: *CEmitter, operand: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?DirectAddressPlace {
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
                const view = type_syntax.viewType(self.resolveAliasType(pointer_ty)) orelse break :blk null;
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

    fn directAddressOfLocalPointerType(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => self.operandEmitType(expr, locals),
            .grouped => |inner| self.directAddressOfLocalPointerType(inner.*, locals),
            else => null,
        };
    }

    // A direct `source?` initializer is already typed by the MIR-owned operand
    // fact. Use that payload only to validate the owned inferred-local fact;
    // the typed try emitter still owns control-flow lowering.
    fn tryPayloadTypeForInferredLocal(self: *CEmitter, initializer: ast.Expr) !?ast.TypeExpr {
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
                    if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(expected))) return error.UnsupportedCEmission;
                }
                break :blk fact_ty;
            },
            else => null,
        };
    }

    fn emitCastInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitLiteralInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const expected_ty = (try self.literalExpressionResultType(initializer)) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, expected_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitDefaultLocalDecl(self: *CEmitter, name: []const u8, maybe_ty: ?ast.TypeExpr, maybe_init: ?ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        try self.writeIndent();
        try self.emitIgnoredLocalPrefix(name);
        try self.emitLocalDeclarator(name, maybe_ty);
        try self.emitDefaultLocalInitializer(maybe_ty, maybe_init, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalDeclarator(self: *CEmitter, name: []const u8, maybe_ty: ?ast.TypeExpr) anyerror!void {
        if (maybe_ty) |decl_ty| {
            try self.emitDeclarator(decl_ty, name);
        } else {
            try self.out.print(self.allocator, "uint32_t {s}", .{name});
        }
    }

    fn emitDefaultLocalInitializer(self: *CEmitter, maybe_ty: ?ast.TypeExpr, maybe_init: ?ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        if (maybe_init) |initializer| {
            try self.emitExplicitLocalInitializer(maybe_ty, initializer, locals);
        } else if (maybe_ty != null and self.arrayTypeFromType(maybe_ty.?) != null) {
            try self.out.appendSlice(self.allocator, " = {0}");
        } else {
            try self.out.appendSlice(self.allocator, " = 0");
        }
    }

    fn emitExplicitLocalInitializer(self: *CEmitter, maybe_ty: ?ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitAssignmentStmt(self: *CEmitter, assignment: anytype, span: ast.Span, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitSpecialAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
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

    fn emitReturnStmt(self: *CEmitter, maybe: ?ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (maybe) |expr| {
            if (try self.emitSpecialReturnStmt(expr, locals, return_ty)) return;
            try self.emitDefaultValueReturnStmt(expr, locals, return_ty);
        } else {
            try self.emitVoidReturnStmt();
        }
    }

    fn emitSpecialReturnStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        if (try self.emitSimpleSpecialReturn(expr, locals, return_ty)) return true;
        if (try self.emitAccessSpecialReturn(expr, locals, return_ty)) return true;
        if (try lower_c_special.emitReturn(self.tryMmioContext(), expr, locals, return_ty)) return true;
        return try self.emitConversionSpecialReturn(expr, locals, return_ty);
    }

    fn emitSimpleSpecialReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        if (try self.emitNeverExprStmt(expr, locals)) return true;
        if (return_ty) |target_ty| {
            if (isVoidType(target_ty) and isVoidLiteralExpr(expr)) {
                try self.emitVoidReturnStmt();
                return true;
            }
        }
        return false;
    }

    fn emitAccessSpecialReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        if (try lower_c_access.emitDirectCallSliceIndexReturn(self.accessEmitContext(), expr, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexReturn(self.accessEmitContext(), expr, locals)) return true;
        if (try lower_c_access.emitRawManyOffsetDerefAddressReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_access.emitLocalIndexAddressReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_access.emitLocalIndexReturn(self.accessEmitContext(), expr, locals, return_ty)) return true;
        if (try lower_c_mmio.emitDirectReadReturnExpr(self.mmioEmitContext(), expr, locals)) return true;
        if (try self.emitOverlayFieldReadReturn(expr, locals, return_ty)) return true;
        return false;
    }

    fn emitConversionSpecialReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
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

    fn emitDefaultValueReturnStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitExpressionStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitAssertStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        const condition_ty = try self.requireMirBoolTargetTypeForEmission(.assert_condition, expr);
        if (try lower_c_mmio.emitReadAssert(self.mmioCallEmitContext(), expr, locals)) return;
        if (try lower_c_flow.emitSequencedConditionAssert(self.flowEmitContext(), expr, locals)) return;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "if (!(");
        try self.emitExprWithTarget(expr, locals, condition_ty);
        try self.out.appendSlice(self.allocator, ")) mc_trap_Assert();\n");
    }

    fn emitBreakStmt(self: *CEmitter, target: ?ast.Ident) anyerror!void {
        try lower_c_flow.emitBreakStmt(self.flowEmitContext(), target);
    }

    fn emitContinueStmt(self: *CEmitter, target: ?ast.Ident) anyerror!void {
        try lower_c_flow.emitContinueStmt(self.flowEmitContext(), target);
    }

    fn emitScopedBlockStmt(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.emitBracedBlockBody(block, locals, return_ty);
    }

    fn emitContractBlockStmt(self: *CEmitter, contract: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.writeIndent();
        try self.out.print(self.allocator, "/* MC_CONTRACT_BEGIN {s} */\n", .{contractName(contract.attr)});
        try self.emitBracedBlockBody(contract.block, locals, return_ty);
        try self.writeIndent();
        try self.out.print(self.allocator, "/* MC_CONTRACT_END {s} */\n", .{contractName(contract.attr)});
    }

    fn emitBracedBlockBody(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.emitBracedBlockBodyWithCleanup(block, locals, return_ty, true);
    }

    fn emitBracedBlockBodyWithCleanup(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, emit_scope_cleanup: bool) anyerror!void {
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

    fn emitLoopStmt(self: *CEmitter, stmt: ast.Stmt, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitPlainWhileLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try lower_c_flow.emitPlainWhileLoop(self.flowEmitContext(), loop, locals, return_ty);
    }

    fn requireMirBoolTargetTypeForEmission(self: *CEmitter, kind: mir.TargetTypeKind, expr: ast.Expr) !ast.TypeExpr {
        const ty = try self.requireMirTargetTypeForEmission(kind, expr, null);
        if (!isBoolType(ty)) return error.UnsupportedCEmission;
        return ty;
    }

    fn requireMirTargetTypeForEmission(self: *CEmitter, kind: mir.TargetTypeKind, expr: ast.Expr, known_ty: ?ast.TypeExpr) !ast.TypeExpr {
        const fact_ty = (self.mirTargetTypeFactAt(kind, expr.span) orelse return error.UnsupportedCEmission).target_ty;
        if (known_ty) |ty| {
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return fact_ty;
    }

    fn mirTryOperandTypeForQuery(self: *CEmitter, operand: ast.Expr) ?ast.TypeExpr {
        return self.requireMirTargetTypeForEmission(.try_operand, operand, null) catch null;
    }

    fn emitAsmStmt(self: *CEmitter, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        try lower_c_asm.emitAsmStmt(self.asmEmitContext(), asm_stmt, locals);
    }

    fn emitAsmTemplate(self: *CEmitter, templates: []const []const u8) !void {
        try lower_c_asm.emitAsmTemplate(self.allocator, self.out, templates);
    }

    fn emitPreciseAsmStmt(self: *CEmitter, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        try lower_c_asm.emitPreciseAsmStmt(self.asmEmitContext(), asm_stmt, locals);
    }

    fn emitBlockItems(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.emitBlockItemsWithScopeCleanup(block, locals, return_ty, true);
    }

    fn emitBlockItemsWithScopeCleanup(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, emit_scope_cleanup: bool) anyerror!void {
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

    fn emitBlockItemsWithDeferStackSnapshot(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.emitBlockItems(block, locals, return_ty);
    }

    const BlockItemAction = enum {
        emit_stmt,
        skip_stmt,
        exit_block,
    };

    fn emitBlockControlItem(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!BlockItemAction {
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

    fn emitBlockDeferItem(self: *CEmitter, expr: ast.Expr, stmt_span: ast.Span) !void {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        const deferred_drop = backend_cleanup.registerDeferredExplicitDropCleanup(self.mir_module, function, self.currentOwnershipCleanupPlan(), expr);
        switch (deferred_drop) {
            .ignored => {},
            .applied => {
                try self.validateCleanupCfg();
            },
            .rejected => return error.UnsupportedCEmission,
        }
        const defer_ref = mir.deferCleanupRefAtSource(function.*, mir.sourcePointFromSpan(stmt_span)) orelse return error.UnsupportedCEmission;
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

    fn emitBlockExitItem(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitReturnExitItem(self: *CEmitter, maybe_expr: ?ast.Expr, stmt_span: ast.Span, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn cleanupEdgeIsEmpty(self: *CEmitter, kind: backend_cleanup.CleanupEdgeKind, scope_span: ?ast.Span, before_span: ?ast.Span) !bool {
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        var plan = (try backend_cleanup.buildCleanupEdgePlan(self.allocator, self.mir_module, function.*, self.currentOwnershipCleanupPlan(), self.currentCleanupCfg(), kind, sourcePointFromOptionalSpan(scope_span), sourcePointFromOptionalSpan(before_span))) orelse return error.UnsupportedCEmission;
        defer plan.deinit(self.allocator);
        return plan.refs.len == 0;
    }

    // Emit the MIR-admitted active cleanup range from `start`, in reverse
    // (innermost first). Exit edges such as `?` that do not pop the scope leave
    // the active cleanup state intact.
    fn emitCleanupEdge(self: *CEmitter, kind: backend_cleanup.CleanupEdgeKind, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, scope_span: ?ast.Span, before_span: ?ast.Span) anyerror!void {
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

    fn emitCleanupRef(self: *CEmitter, ref: backend_cleanup.CleanupRef, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn deferExprForRef(self: *CEmitter, ref: mir.DeferCleanupRef) ?ast.Expr {
        const function = self.currentMirFunction() orelse return null;
        if (!mir.deferCleanupRefValid(function.*, ref)) return null;
        const body = self.current_function_body orelse return null;
        return deferExprForRefInBlock(body, ref);
    }

    fn ordinaryDeferDirectCallCleanup(self: *CEmitter, function: *const mir.Function, expr: ast.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedCEmission}!?backend_cleanup.OrdinaryDeferCallCleanup {
        const call = callExpr(expr) orelse return null;
        if (call.type_args.len != 0) return null;
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        if (info.is_variadic or call.args.len != info.params.len) return error.UnsupportedCEmission;
        if (!mir.directDeferCallCleanupForRef(function.*, defer_ref, mir.sourcePointFromSpan(expr.span), mir.sourcePointFromSpan(call.callee.*.span), fn_name, call.args)) return error.UnsupportedCEmission;
        return .{ .defer_ref = defer_ref, .fn_name = fn_name, .span = expr.span, .callee_span = call.callee.*.span, .args = call.args };
    }

    fn ordinaryDeferCallTargetCleanup(self: *CEmitter, function: *const mir.Function, expr: ast.Expr, defer_ref: mir.DeferCleanupRef) error{UnsupportedCEmission}!?backend_cleanup.CallTargetDeferCleanup {
        const call = callExpr(expr) orelse return null;
        const kind = self.mirCallTargetKindAt(call.callee.*.span) orelse return null;
        switch (kind) {
            .cpu_pause, .fence_full, .fence_release, .fence_acquire => {
                if (call.type_args.len != 0 or call.args.len != 0) return null;
            },
            .raw_store => {
                if (!expr_syntax.isRawStoreCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 2) return null;
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
        if (!mir.callTargetDeferCleanupForRef(function.*, defer_ref, mir.sourcePointFromSpan(expr.span), mir.sourcePointFromSpan(call.callee.*.span), kind)) return error.UnsupportedCEmission;
        return .{ .defer_ref = defer_ref, .kind = kind, .span = expr.span, .callee = call.callee.*, .callee_span = call.callee.*.span, .type_args = call.type_args, .args = call.args };
    }

    fn emitCallTargetDeferCleanup(self: *CEmitter, cleanup: backend_cleanup.CallTargetDeferCleanup, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!mir.callTargetDeferCleanupForRef((self.currentMirFunction() orelse return error.UnsupportedCEmission).*, cleanup.defer_ref, mir.sourcePointFromSpan(cleanup.span), mir.sourcePointFromSpan(cleanup.callee_span), cleanup.kind)) return error.UnsupportedCEmission;
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
            const empty_type_args: []const ast.TypeExpr = &.{};
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
            const empty_type_args: []const ast.TypeExpr = &.{};
            const call = .{ .callee = &callee_storage, .type_args = empty_type_args, .args = cleanup.args };
            try self.writeIndent();
            if (!try lower_c_atomic.emitAtomicCall(self.atomicEmitContext(), call, locals)) return error.UnsupportedCEmission;
            try self.out.appendSlice(self.allocator, ";\n");
            return;
        }
        if (cleanup.kind == .va_end) {
            var callee_storage = cleanup.callee;
            const empty_type_args: []const ast.TypeExpr = &.{};
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

    fn emitOrdinaryDeferDirectCallCleanup(self: *CEmitter, cleanup: backend_cleanup.OrdinaryDeferCallCleanup, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !void {
        _ = return_ty;
        const function = self.currentMirFunction() orelse return error.UnsupportedCEmission;
        if (!mir.directDeferCallCleanupForRef(function.*, cleanup.defer_ref, mir.sourcePointFromSpan(cleanup.span), mir.sourcePointFromSpan(cleanup.callee_span), cleanup.fn_name, cleanup.args)) return error.UnsupportedCEmission;
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

    fn writeLineDirective(self: *CEmitter, span: ast.Span) !void {
        try appendLineDirective(self.allocator, self.out, self.source_path, span);
    }

    fn reportUnsupported(self: *CEmitter, span: ast.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            reporter.err(span, "E_BACKEND_UNSUPPORTED: C backend does not yet support {s}", .{construct});
        }
    }

    fn writeUnsupportedStmt(self: *CEmitter, stmt: ast.Stmt) !void {
        self.reportUnsupported(stmt.span, @tagName(stmt.kind));
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "/* unsupported statement for C emission: {s} */\n",
            .{@tagName(stmt.kind)},
        );
        return error.UnsupportedCEmission;
    }

    fn emitMaterializedUninitInitializer(self: *CEmitter, ty: ast.TypeExpr) !void {
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
    fn clearMirPointerProvenanceForPattern(self: *CEmitter, pattern: ast.Pattern) void {
        switch (pattern.kind) {
            .bind => |ident| _ = self.mir_pointer_local_provenance.remove(ident.text),
            .tag_bind => |tag_bind| _ = self.mir_pointer_local_provenance.remove(tag_bind.binding.text),
            else => {},
        }
    }

    fn emitSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitEnumCallSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, enum_ty: ast.TypeExpr) anyerror!bool {
        _ = callExpr(node.subject) orelse return false;
        const temp = try self.emitSequencedCallArgTemp(node.subject, locals, enum_ty);

        var switch_locals = try cloneLocals(self.allocator, locals.*);
        defer switch_locals.deinit();
        try switch_locals.put(temp.name, try self.localInfoFromType(enum_ty));
        const temp_subject = ast.Expr{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span };
        try self.emitGenericSwitch(.{ .subject = temp_subject, .arms = node.arms }, &switch_locals, return_ty, enum_ty, &[_]MmioReadReplacement{});
        return true;
    }

    fn emitGenericSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_ty: ast.TypeExpr, subject_replacements: []const MmioReadReplacement) anyerror!void {
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

    fn emitGenericSwitchWithMmioSubjectHoists(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_ty: ast.TypeExpr) anyerror!void {
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

    fn requireMirSwitchSubjectType(self: *CEmitter, subject: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !MirSubjectType {
        const known_ty = self.operandEmitType(subject, locals) orelse self.taggedUnionTypeForExpr(subject, locals);
        const fact = if (known_ty) |ty|
            self.mirTargetTypeFactMatchingType(.switch_subject, subject.span, ty)
        else
            self.mirTargetTypeFactAt(.switch_subject, subject.span);
        const subject_fact = fact orelse return error.UnsupportedCEmission;
        const fact_ty = subject_fact.target_ty;
        if (known_ty) |ty| {
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return .{
            .target_ty = fact_ty,
            .nullable_representation = if (self.nullableTypeFromCandidate(fact_ty) != null) try self.nullableRepresentationFromTargetFact(subject_fact) else null,
        };
    }

    fn emitResultSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_ty: ast.TypeExpr) anyerror!bool {
        const subject = (try lower_c_switch.resultSubjectForValueExprWithType(self.switchEmitContext(), node.subject, locals, subject_ty)) orelse return false;
        return lower_c_switch.emitResultSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitNullableSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_ty: ast.TypeExpr, representation: NullableRepresentation) anyerror!bool {
        const subject = if (try lower_c_switch.nullableSubjectForExprWithType(self.switchEmitContext(), node.subject, locals, subject_ty, representation)) |subject|
            subject
        else
            return false;

        return lower_c_switch.emitNullableSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitTaggedUnionSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = (try lower_c_switch.taggedUnionSubjectForValueExpr(self.switchEmitContext(), node.subject, locals)) orelse return false;
        return lower_c_switch.emitTaggedUnionSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitSwitchBody(self: *CEmitter, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        switch (body) {
            .block => |block| try self.emitBlockItems(block, locals, return_ty),
            .expr => |expr| try self.emitExpressionStmt(expr, locals, return_ty),
        }
    }

    fn nullableTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn nullableExpressionResultTypeOrGenerated(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| {
            return self.nullableTypeFromCandidate(fact.target_ty);
        }
        return self.generatedNullableExpressionTypeForEmission(expr, locals);
    }

    fn generatedNullableExpressionTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn nullableTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .nullable) ty else null;
    }

    fn nullablePayloadFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .nullable => |child| child.*,
            else => null,
        };
    }

    fn valueOptionalPayloadFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const child = self.nullablePayloadFromCandidate(ty) orelse return null;
        return if (lower_c_type.nullablePayloadIsValueType(&self.type_aliases, child)) child else null;
    }

    fn generatedNullableLocalTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        const local_set = locals orelse return null;
        const name = directLocalName(expr) orelse return null;
        const info = local_set.get(name) orelse return null;
        const ty = info.source_ty orelse return null;
        return self.nullableTypeFromCandidate(ty);
    }

    fn taggedUnionTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn taggedUnionCallCandidateTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        // A qualified constructor `Union.variant(...)` is self-typed to its
        // owner, so an untyped `let t = Token.number(9)` infers `Token`.
        if (self.mirTargetTypeFactAt(.qualified_union_result, expr.span)) |fact| return fact.target_ty;
        const ret_ty = self.callResultTypeForEmission(expr, locals) orelse return null;
        return self.taggedUnionTypeFromType(ret_ty);
    }

    fn taggedUnionTypeFromType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const type_name = typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.tagged_unions.contains(type_name)) ty else null;
    }

    fn emitForLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const header = try lower_c_flow.forLoopHeader(self.flowEmitContext(), loop);
        const binding = header.binding;
        const iterable = header.iterable;
        const types = try self.requireMirForLoopTypes(iterable, locals);
        if (try lower_c_flow.emitForLoopSequencedIterable(self.flowEmitContext(), loop, iterable, types.iterable, locals, return_ty)) return;
        const iterable_array_ty = self.arrayTypeFromType(types.iterable);
        const element = try lower_c_flow.forLoopElementPlan(self.flowEmitContext(), iterable_array_ty, types.element);
        try lower_c_flow.emitForLoopWithElementPlan(self.flowEmitContext(), loop, binding, iterable, locals, return_ty, element);
    }

    fn requireMirForLoopTypes(self: *CEmitter, iterable: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !struct { iterable: ast.TypeExpr, element: ast.TypeExpr } {
        const iterable_ty = try self.requireMirForIterableTypeForEmission(iterable, locals);
        const element_ty = try self.requireMirForElementTypeForEmission(iterable);
        const expected_element = self.arrayOrSliceElementTypeFromCandidate(iterable_ty) orelse return error.UnsupportedCEmission;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(expected_element))) return error.UnsupportedCEmission;
        return .{ .iterable = iterable_ty, .element = element_ty };
    }

    fn requireMirForIterableTypeForEmission(self: *CEmitter, iterable: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !ast.TypeExpr {
        return self.requireMirTargetTypeForEmission(.for_iterable, iterable, self.iterableTypeForExpr(iterable, locals));
    }

    fn requireMirForElementTypeForEmission(self: *CEmitter, iterable: ast.Expr) !ast.TypeExpr {
        return self.requireMirTargetTypeForEmission(.for_element, iterable, null);
    }

    fn iterableTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const ty = self.arrayOrSliceBaseTypeForEmission(expr, locals) orelse return null;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .array, .slice => ty,
            else => null,
        };
    }

    fn emitIfLet(self: *CEmitter, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
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

    fn requireMirIfLetSubjectType(self: *CEmitter, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !MirSubjectType {
        const fact = self.mirTargetTypeFactAt(.if_let_subject, value.span) orelse return error.UnsupportedCEmission;
        const fact_ty = fact.target_ty;
        const known_ty = self.operandEmitType(value, locals);
        if (known_ty) |ty| {
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
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

    fn nullableRepresentationForTargetType(self: *CEmitter, ty: ast.TypeExpr) ?NullableRepresentation {
        const child = self.nullablePayloadFromCandidate(ty) orelse return null;
        if (self.dynTraitNameFromCandidate(child) != null) return .dyn_trait;
        if (self.valueOptionalPayloadFromCandidate(ty) != null) return .value;
        return .pointer;
    }

    fn emitNeverExprStmt(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
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

    fn emitRawStoreStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = callExpr(expr) orelse return false;
        const call_span = call.callee.*.span;
        const call_kind = self.mirCallTargetKindAt(call_span);
        if (call_kind != .raw_store) return false;
        if (!expr_syntax.isRawStoreCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedCEmission;
        try self.emitRawStorePayload(call_span, call.type_args, call.args, locals);
        return true;
    }

    fn emitRawStorePayload(self: *CEmitter, call_span: ast.Span, type_args: []const ast.TypeExpr, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
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

    fn emitCpuPauseStmt(self: *CEmitter, expr: ast.Expr) !bool {
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
    fn emitFenceStmt(self: *CEmitter, expr: ast.Expr) !bool {
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

    fn emitOrdinaryHookedAssignmentStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
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

    fn ordinaryStoreHookTarget(target: ast.Expr) bool {
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
    fn emitAssignTarget(self: *CEmitter, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const prev = self.suppress_load_hook;
        self.suppress_load_hook = true;
        defer self.suppress_load_hook = prev;
        try self.emitExpr(target, locals);
    }

    fn emitExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        self.emitExprInner(expr, locals) catch |err| switch (err) {
            error.UnsupportedCEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprInner(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitUnsupportedTargetlessAggregateExpr(self: *CEmitter, expr: ast.Expr, kind: []const u8) !void {
        self.reportUnsupported(expr.span, kind);
        try self.out.print(self.allocator, "/* unsupported targetless {s} literal */0", .{kind});
        return error.UnsupportedCEmission;
    }

    fn emitCallExpr(self: *CEmitter, expr: ast.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        self.applyMirPointerProvenanceInvalidationsAtCall(expr.span, locals);
        if (try self.emitSpecialCallExpr(node, locals)) return;
        try self.emitDefaultCallExpr(node, locals);
    }

    fn emitMemberExprOrFallback(self: *CEmitter, node: anytype, member_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (try self.emitMemberExpr(node, member_span, locals)) return;
    }

    fn emitUnsupportedExpr(self: *CEmitter, expr: ast.Expr) !void {
        self.reportUnsupported(expr.span, @tagName(expr.kind));
        try self.out.print(self.allocator, "/* unsupported expr: {s} */0", .{@tagName(expr.kind)});
        return error.UnsupportedCEmission;
    }

    fn reportUnsupportedIfNone(self: *CEmitter, span: ast.Span, construct: []const u8) void {
        if (self.reporter) |reporter| {
            if (!reporter.has_errors) {
                reporter.err(span, "E_BACKEND_UNSUPPORTED: C backend does not yet support {s}", .{construct});
            }
        }
    }

    fn emitIdentExpr(self: *CEmitter, ident: ast.Ident, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitScalarLiteralExpr(self: *CEmitter, expr: ast.Expr) !void {
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

    fn emitGroupedExpr(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(inner, locals);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitAddressOfExpr(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.appendSlice(self.allocator, "&");
        try self.emitAddressOperand(inner, locals);
    }

    fn emitDerefExpr(self: *CEmitter, inner: ast.Expr, deref_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const inferred_pointee_ty = self.derefPointeeType(inner, locals) orelse return error.UnsupportedCEmission;
        const pointee_ty = (self.mirTargetTypeFactAt(.expression_result, deref_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(pointee_ty), self.resolveAliasType(inferred_pointee_ty))) return error.UnsupportedCEmission;
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

    fn emitRaceLoadTempForAccess(ctx: *anyopaque, ptr_name: []const u8, target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitRaceLoadTempFromPointerTemp(ptr_name, target_ty);
    }

    fn emitRaceLoadTempFromPointerTemp(self: *CEmitter, ptr_name: []const u8, target_ty: ast.TypeExpr) !?SequencedArgTemp {
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

    fn emitCastExpr(self: *CEmitter, span: ast.Span, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const source_fact = self.mirTargetTypeFactAt(.explicit_cast_source, span) orelse return error.UnsupportedCEmission;
        const target_fact = self.mirTargetTypeFactAt(.explicit_cast_target, span) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(target_fact.target_ty, .typedef_name)});
        try self.emitExprWithTarget(node.value.*, locals, source_fact.target_ty);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitIndexExpr(self: *CEmitter, node: anytype, index_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (locals) |local_set| {
            if (self.overlayIndexResultType(node, local_set)) |inferred_element_ty| {
                const element_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
                if (try self.emitOverlayIndexReadExpr(node, local_set)) return;
                return error.UnsupportedCEmission;
            }
        }
        const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
        const inferred_element_ty = self.arrayOrSliceElementTypeFromCandidate(base_ty) orelse return error.UnsupportedCEmission;
        const element_ty = (self.mirTargetTypeFactAt(.expression_result, index_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
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

    fn emitArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast.TypeExpr) anyerror!void {
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
    fn emitArrayIndexBase(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (base.kind == .deref) {
            try self.out.appendSlice(self.allocator, "(");
            try self.emitExpr(base, locals);
            try self.out.appendSlice(self.allocator, ")");
            return;
        }
        try self.emitExpr(base, locals);
    }

    fn emitMemberExpr(self: *CEmitter, node: anytype, member_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try self.emitEnumVariantPath(node, locals)) return true;
        if (self.sliceAccessForBase(node.base.*, locals)) |slice| {
            const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
            if (self.sliceTypeFromCandidate(base_ty) != null and std.mem.eql(u8, node.name.text, "len")) {
                const usize_ty = simpleNameType("usize", member_span);
                const field_ty = self.memberResultTypeOrGenerated(member_span, usize_ty) orelse return error.UnsupportedCEmission;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(usize_ty))) return error.UnsupportedCEmission;
                try self.emitExpr(node.base.*, locals);
                try self.out.print(self.allocator, ".{s}", .{slice.len_field});
                return true;
            }
        }
        if (try self.emitPackedBitsMember(node, member_span, locals)) return true;
        if (locals) |local_set| {
            if (self.overlayMemberResultType(node, local_set)) |inferred_field_ty| {
                const field_ty = self.memberResultTypeOrGenerated(member_span, inferred_field_ty) orelse return error.UnsupportedCEmission;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
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
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
        try self.emitOrdinaryMemberLoadExpr(node, locals);
        return true;
    }

    fn memberResultTypeOrGenerated(self: *CEmitter, member_span: ast.Span, inferred: ast.TypeExpr) ?ast.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, member_span)) |fact| return fact.target_ty;
        return generatedMemberResultTypeForEmission(member_span, inferred);
    }

    fn generatedMemberResultTypeForEmission(member_span: ast.Span, inferred: ast.TypeExpr) ?ast.TypeExpr {
        if (isSourceSpan(member_span)) return null;
        return inferred;
    }

    fn overlayMemberResultType(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const overlay_name = lower_c_access.overlayUnionNameForExpr(node.base.*, locals) orelse return null;
        const info = self.overlay_unions.get(overlay_name) orelse return null;
        const field = info.fields.get(node.name.text) orelse return null;
        if (field.byte_array_len != null or type_syntax.overlayArrayElementType(field.ty) != null) return null;
        return field.ty;
    }

    fn overlayIndexResultType(self: *CEmitter, node: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const member = expr_syntax.overlayMemberFromIndexBase(node.base.*) orelse return null;
        const overlay_name = lower_c_access.overlayUnionNameForExpr(member.base.*, locals) orelse return null;
        const info = self.overlay_unions.get(overlay_name) orelse return null;
        const field = info.fields.get(member.name.text) orelse return null;
        return type_syntax.overlayArrayElementType(field.ty);
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
        root: ast.Expr,
        fields: []const []const u8,
    };

    fn collectPointerMemberPath(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?ast.Expr {
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

    fn pointerMemberPath(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?PointerMemberPath {
        const root = try self.collectPointerMemberPath(expr, locals, fields) orelse return null;
        if (fields.items.len <= 1) return null;
        return .{ .root = root, .fields = fields.items };
    }

    fn pointerMemberPathFinalType(self: *CEmitter, root: ast.Expr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        var current = self.memberBaseTypeForEmission(root, locals) orelse return null;
        for (fields) |field_name| current = self.memberFieldTypeFromAggregate(current, field_name) orelse return null;
        return current;
    }

    fn emitPointerMemberPathAddressExpr(self: *CEmitter, root: ast.Expr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitIndexedMemberAddressExpr(self: *CEmitter, index: expr_syntax.IndexExpr, field_name: []const u8, locals: ?*std.StringHashMap(LocalInfo), index_temp: ?[]const u8) anyerror!bool {
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

    fn collectIndexedMemberPath(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), fields: *std.ArrayList([]const u8)) !?expr_syntax.IndexExpr {
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

    fn indexedElementType(self: *CEmitter, index: expr_syntax.IndexExpr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const base_ty = self.arrayOrSliceBaseTypeForEmission(index.base.*, locals) orelse return null;
        return self.arrayOrSliceElementTypeFromCandidate(base_ty);
    }

    fn indexedMemberPathFinalType(self: *CEmitter, index: expr_syntax.IndexExpr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        var current = self.indexedElementType(index, locals) orelse return null;
        for (fields) |field_name| current = self.memberFieldTypeFromAggregate(current, field_name) orelse return null;
        return current;
    }

    fn emitIndexedMemberPathAddressExpr(self: *CEmitter, index: expr_syntax.IndexExpr, fields: []const []const u8, locals: ?*std.StringHashMap(LocalInfo), index_temp: ?[]const u8) anyerror!bool {
        if (fields.len == 0) return false;
        if (!try self.emitIndexedMemberAddressExpr(index, try self.cIdent(fields[0]), locals, index_temp)) return false;
        for (fields[1..]) |field_name| try self.out.print(self.allocator, ".{s}", .{try self.cIdent(field_name)});
        return true;
    }

    fn indexedMemberHasRaceTolerantStorage(self: *CEmitter, index: expr_syntax.IndexExpr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (self.sliceAccessForBase(index.base.*, locals) != null) return true;
        if (self.arrayTypeForExpr(index.base.*, locals) != null and self.pointerArrayDerefInner(index.base.*, locals) != null) return true;
        return false;
    }

    fn memberChainHasRaceTolerantIndexedBase(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn emitAddressOperand(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitArrayIndexAddressOperand(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast.TypeExpr) anyerror!void {
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

    fn underlyingIntTypeName(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return lower_c_info.underlyingIntTypeName(self.infoContext(), ty);
    }

    fn emitExprWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        self.emitExprWithTargetInner(expr, locals, target_ty) catch |err| switch (err) {
            error.UnsupportedCEmission => {
                self.reportUnsupportedIfNone(expr.span, @tagName(expr.kind));
                return err;
            },
            else => return err,
        };
    }

    fn emitExprWithTargetInner(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
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

    fn nullLiteralTargetTypeForEmission(self: *CEmitter, expr: ast.Expr, target_ty: ?ast.TypeExpr) ?ast.TypeExpr {
        if (self.mirTargetTypeFactAt(.null_literal, expr.span)) |fact| return fact.target_ty;
        const ty = target_ty orelse return null;
        return self.nullableTypeFromCandidate(ty);
    }

    // Coerce a `null` (absent) or a payload value (present) into a value optional `?T`'s
    // tagged aggregate. A source that already yields `?T` (another optional local / a call
    // returning `?T`) is left to the normal path (pass-through, no double-wrap).
    fn emitValueOptionalCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
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

    fn emitPointerToPAddrTargetCast(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        if (!lower_c_type.isPAddrType(ty)) return false;
        const source_ty = self.paddrCoercionSourceTypeForEmission(expr, locals) orelse return false;
        if (!lower_c_type.isPointerLikeAddressType(source_ty)) return false;
        try self.out.appendSlice(self.allocator, "((uintptr_t)(");
        try self.emitExpr(expr, locals);
        try self.out.appendSlice(self.allocator, "))");
        return true;
    }

    fn paddrCoercionSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.mirTargetTypeFactAt(.paddr_coercion_source, expr.span)) |fact| return fact.target_ty;
        if (expr.kind == .cast) return (self.mirTargetTypeFactAt(.explicit_cast_source, expr.span) orelse return null).target_ty;
        return self.generatedPaddrCoercionSourceTypeForEmission(expr, locals);
    }

    fn generatedPaddrCoercionSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn emitAggregateLiteralWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

    fn emitArithmeticExprWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
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

    fn emitGroupedExprWithTarget(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        try self.out.appendSlice(self.allocator, "(");
        try self.emitExprWithTarget(inner, locals, target_ty);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitAddressOfExprWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        // `&x` / `&mut x` coerced to `*dyn Trait`: build the fat pointer
        // `(mc_dyn_Trait){ .data = (void*)&x, .vtable = &__vt_Type_Trait }`.
        if (target_ty) |ty| {
            if (try self.emitDynCoercion(expr, locals, ty)) return;
        }
        try self.emitExpr(expr, locals);
    }

    fn emitTargetCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, expr: ast.Expr) anyerror!void {
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

    fn emitTargetPreludeExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
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

    fn emitSliceConstNarrowCoercion(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!bool {
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
        if (expr.kind != .cast and !type_syntax.sameTypeSyntax(self.resolveAliasType(fact_target_ty), self.resolveAliasType(target_ty))) return false;
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

    fn emitEnumLiteralWithTarget(self: *CEmitter, literal: ast.Ident, span: ast.Span) anyerror!void {
        const fact = self.mirTargetTypeFactAt(.enum_literal, span) orelse return error.UnsupportedCEmission;
        const enum_name = self.enumNameForType(fact.target_ty);
        if (enum_name) |name| {
            try self.out.print(self.allocator, "{s}_{s}", .{ name, literal.text });
            return;
        }
        try self.out.print(self.allocator, "/* unsupported enum literal: {s} */0", .{literal.text});
        return error.UnsupportedCEmission;
    }

    fn emitFloatLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast.Span) anyerror!void {
        const fact = self.mirTargetTypeFactAt(.float_literal, span) orelse return error.UnsupportedCEmission;
        const name = typeName(self.resolveAliasType(fact.target_ty)) orelse return error.UnsupportedCEmission;
        if (!std.mem.eql(u8, name, "f32") and !std.mem.eql(u8, name, "f64")) return error.UnsupportedCEmission;
        try appendCFloatLiteral(self.allocator, self.out, literal, std.mem.eql(u8, name, "f32"));
    }

    fn emitCharLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast.Span, expected_ty: ?ast.TypeExpr) !void {
        const fact = self.mirTargetTypeFactAt(.char_literal, span) orelse return error.UnsupportedCEmission;
        const expected = expected_ty orelse return error.UnsupportedCEmission;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(expected))) return error.UnsupportedCEmission;
        const value = numeric.parseCharLiteral(literal) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s}){d})", .{ try self.cTypeFor(fact.target_ty, .typedef_name), value });
    }

    fn emitStringLiteralWithTarget(self: *CEmitter, literal: []const u8, span: ast.Span) anyerror!void {
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
        if (type_syntax.u8SliceMutability(resolved)) |mutability| {
            const child = resolved.kind.slice.child.*;
            const slice_name = try self.sliceTypeName(child, mutability);
            const ptr_type = try self.pointerTypeForSliceElement(child, mutability);
            const len = type_syntax.stringLiteralByteLen(literal) orelse return error.UnsupportedCEmission;
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
    fn targetIsDynOrNullableDyn(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.dynTraitNameFromCandidate(ty) != null;
    }

    fn emitDynCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
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

    fn dynSourceIsPassThrough(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.dynSourceIsPassThrough(inner.*, locals),
            else => if (self.dynPassThroughTypeForEmission(expr, locals)) |source_ty|
                self.targetIsDynOrNullableDyn(source_ty)
            else
                false,
        };
    }

    fn dynTargetTraitName(self: *CEmitter, target_ty: ast.TypeExpr) ?[]const u8 {
        return self.dynTraitNameFromCandidate(target_ty);
    }

    fn dynTraitNameFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            .nullable => |child| switch (self.resolveAliasType(child.*).kind) {
                .dyn_trait => |d| d.trait_name.text,
                else => null,
            },
            else => null,
        };
    }

    fn dynDispatchTraitNameFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
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

    fn emitDynCoercionWithSource(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast.TypeExpr) !bool {
        return switch (expr.kind) {
            .grouped => |inner| try self.emitDynCoercionWithSource(inner.*, locals, trait_name, source_ty),
            .address_of => |inner| try self.emitAddressOfDynCoercion(inner.*, locals, trait_name, source_ty),
            else => try self.emitPointerValueDynCoercion(expr, locals, trait_name, source_ty),
        };
    }

    fn emitAddressOfDynCoercion(self: *CEmitter, operand: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast.TypeExpr) !bool {
        // `&x` -> .data = (void*)&x, vtable keyed on typeof(x).
        const type_name = typeName(self.resolveAliasType(source_ty)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)&", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(operand, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn emitPointerValueDynCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8, source_ty: ast.TypeExpr) !bool {
        // A `*T` value: .data = (void*)<the pointer>, vtable keyed on the pointee T.
        const pointee = self.dynPointerSourcePointeeFromCandidate(source_ty) orelse return false;
        const type_name = typeName(self.resolveAliasType(pointee)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(expr, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn dynPointerSourcePointeeFromCandidate(self: *CEmitter, source_ty: ast.TypeExpr) ?ast.TypeExpr {
        // An existing `*dyn Trait` value passes through (no re-wrap).
        if (self.dynTraitNameFromCandidate(source_ty) != null) return null;
        const pointer = self.pointerNodeFromCandidate(source_ty) orelse return null;
        return pointer.child.*;
    }

    fn dynPassThroughTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn emitF32Expr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try lower_c_arith.emitF32Expr(self.arithContext(), expr, locals);
    }

    fn structDeclForResolvedTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.StructDecl {
        const struct_name = typeName(target_ty) orelse return null;
        return self.structs.get(struct_name);
    }

    fn enumNameForType(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return self.enumNameFromCandidate(ty);
    }

    fn emitPackedBitsMember(self: *CEmitter, node: anytype, member_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const base_ty = packedBitsNameForExpr(node.base.*, locals, &self.globals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(node.name.text) orelse return false;
        const field_ty = (self.mirTargetTypeFactAt(.expression_result, member_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(type_syntax.simpleNameType("bool", member_span)))) return error.UnsupportedCEmission;
        try self.emitPackedBitsMaskTest(node.base.*, locals, info, field.bit_index);
        return true;
    }

    fn emitPackedBitsMaskTest(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), info: PackedBitsInfo, bit_index: usize) !void {
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

    fn emitPackedBitsGlobalFieldWrite(self: *CEmitter, base_ty: []const u8, info: PackedBitsInfo, global_name: []const u8, mask: []const u8, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
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

    fn emitPackedBitsLocalFieldWrite(self: *CEmitter, base: ast.Expr, base_ty: []const u8, mask: []const u8, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        const value_temp = try self.emitSequencedCallArgTemp(value, locals, simpleNameType("bool", value.span));
        try self.writeIndent();
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " = ({s})((", .{base_ty});
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " & ({s})~{s}) | ({s} ? {s} : ({s})0));\n", .{ base_ty, mask, value_temp.name, mask, base_ty });
    }

    fn globalAssignmentTarget(self: *CEmitter, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
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

    fn globalArrayElementMemberField(self: *CEmitter, access: GlobalArrayElementAccess, member_name: []const u8) ?ast.Field {
        const element_ty = self.resolveAliasType(access.element_info.source_ty);
        const element_name = typeName(element_ty) orelse return null;
        const struct_decl = self.structs.get(element_name) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, member_name)) return field;
        }
        return null;
    }

    fn exprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn boolLiteralIsBoolForEmission(self: *CEmitter, expr: ast.Expr) bool {
        if (!isSourceSpan(expr.span)) return true;
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn storageExprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse return false;
        return isBoolType(self.resolveAliasType(ty));
    }

    fn groupedExprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (!isSourceSpan(expr.span)) return self.exprIsBoolForEmission(inner, locals);
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn binaryExprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, node: anytype) bool {
        if (!isSourceSpan(expr.span)) {
            return switch (node.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => true,
                else => false,
            };
        }
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn unaryExprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, node: anytype) bool {
        if (!isSourceSpan(expr.span)) return node.op == .logical_not;
        return self.expressionResultIsBoolForEmission(expr);
    }

    fn expressionResultIsBoolForEmission(self: *CEmitter, expr: ast.Expr) bool {
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return false).target_ty;
        return isBoolType(self.resolveAliasType(ty));
    }

    fn enumNameForValueExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
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

    fn groupedEnumNameForValueExpr(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        if (!isSourceSpan(expr.span)) return self.enumNameForValueExpr(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.enumNameForType(ty);
    }

    fn emitOverlayFieldReadReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        try self.requireOverlayReturnExpressionResult(expr, locals);
        return lower_c_overlay.emitOverlayFieldReadReturn(self.overlayEmitContext(), expr, locals, return_ty);
    }

    fn requireOverlayReturnExpressionResult(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        switch (expr.kind) {
            .grouped => |inner| return self.requireOverlayReturnExpressionResult(inner.*, locals),
            .member => |node| if (self.overlayMemberResultType(node, locals)) |inferred_field_ty| {
                const field_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(field_ty), self.resolveAliasType(inferred_field_ty))) return error.UnsupportedCEmission;
            },
            .index => |node| if (self.overlayIndexResultType(node, locals)) |inferred_element_ty| {
                const element_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return error.UnsupportedCEmission).target_ty;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(element_ty), self.resolveAliasType(inferred_element_ty))) return error.UnsupportedCEmission;
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

    fn overlayFieldLayoutSize(self: *CEmitter, ty: ast.TypeExpr) usize {
        return (self.overlayFieldLayout(ty) orelse OverlayLayout{ .size = 1, .alignment = 1 }).size;
    }

    fn emitSliceExpr(self: *CEmitter, node: anytype, slice_span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) !void {
        const base_ty = self.arrayOrSliceBaseTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
        const inferred_slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedCEmission;
        const slice_ty = (self.mirTargetTypeFactAt(.expression_result, slice_span) orelse return error.UnsupportedCEmission).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(slice_ty), self.resolveAliasType(inferred_slice_ty))) return error.UnsupportedCEmission;
        const slice_name = try self.sliceTypeName(slice_ty.kind.slice.child.*, slice_ty.kind.slice.mutability);
        const resolved = self.resolveAliasType(base_ty);
        const n = self.temp_index;
        self.temp_index += 1;

        try self.emitSliceRangePrelude(node, locals, resolved, n);
        try self.emitSliceBoundsGuard(slice_span, n, slice_name);
        try self.emitSliceBasePtr(node.base.*, locals, resolved);
        try self.out.print(self.allocator, " + mc_start{d}, .len = mc_end{d} - mc_start{d} }}; }})", .{ n, n, n });
    }

    fn arrayOrSliceBaseTypeForEmission(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn arrayOrSliceBaseTypeForEmissionRecovered(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.arrayTypeForExpr(base, locals)) |ty| return ty;
        if (self.sliceReturnTypeForExpr(base, locals)) |ty| return ty;
        if (self.operandEmitType(base, locals)) |ty| return ty;
        return null;
    }

    fn emitSliceRangePrelude(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast.TypeExpr, temp_id: usize) !void {
        try self.out.print(self.allocator, "({{ uintptr_t mc_start{d} = (", .{temp_id});
        try self.emitExpr(node.start.*, locals);
        try self.out.print(self.allocator, "); uintptr_t mc_end{d} = (", .{temp_id});
        try self.emitExpr(node.end.*, locals);
        try self.out.print(self.allocator, "); uintptr_t mc_len{d} = ", .{temp_id});
        try self.emitSliceBaseLen(node.base.*, locals, resolved_base_ty);
    }

    fn emitSliceBaseLen(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast.TypeExpr) !void {
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

    fn emitSliceBoundsGuard(self: *CEmitter, slice_span: ast.Span, temp_id: usize, slice_name: []const u8) !void {
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

    fn emitSliceBasePtr(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), resolved_base_ty: ast.TypeExpr) !void {
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

    fn emitArrayCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const array_ty = self.callReturnTypeForInferredLocal(initializer, locals, isArrayCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, array_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isArrayCallReturnType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.arrayTypeFromType(ty) != null;
    }

    fn emitSliceCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const slice_ty = self.callReturnTypeForInferredLocal(initializer, locals, isSliceCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, slice_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isSliceCallReturnType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.sliceTypeFromCandidate(ty) != null;
    }

    fn emitEnumCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const enum_ty = self.callReturnTypeForInferredLocal(initializer, locals, isEnumCallReturnType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, enum_ty)) orelse return error.UnsupportedCEmission;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isEnumCallReturnType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.enumTypeFromCandidate(ty) != null;
    }

    fn sliceTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .slice) ty else null;
    }

    fn enumTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return if (self.enumNameFromCandidate(ty) != null) ty else null;
    }

    fn enumNameFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        const enum_name = type_syntax.typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.enums.contains(enum_name)) enum_name else null;
    }

    fn emitTaggedUnionCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const union_ty = self.qualifiedUnionResultTypeForInferredLocal(initializer) orelse
            self.callReturnTypeForInferredLocal(initializer, locals, isTaggedUnionCallReturnType) orelse
            return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, union_ty)) orelse union_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn qualifiedUnionResultTypeForInferredLocal(self: *CEmitter, initializer: ast.Expr) ?ast.TypeExpr {
        return switch (initializer.kind) {
            .grouped => |inner| self.qualifiedUnionResultTypeForInferredLocal(inner.*),
            .call => if (self.mirTargetTypeFactAt(.qualified_union_result, initializer.span)) |fact| fact.target_ty else null,
            else => null,
        };
    }

    fn isTaggedUnionCallReturnType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.taggedUnionTypeFromType(ty) != null;
    }

    fn emitResultCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const result_ty = self.callReturnTypeForInferredLocal(initializer, locals, isResultMirCallResultType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, result_ty)) orelse result_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isResultMirCallResultType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.resultTypeFromCandidate(ty) != null;
    }

    fn resultTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .generic => |generic| if (std.mem.eql(u8, generic.base.text, "Result")) ty else null,
            else => null,
        };
    }

    fn emitNullableCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const nullable_ty = self.callReturnTypeForInferredLocal(initializer, locals, isNullableMirCallResultType) orelse return false;
        const inferred_ty = (try self.mirInferredLocalType(name, initializer, nullable_ty)) orelse nullable_ty;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.emitInferredCallLocalInitValue(name, inferred_ty, initializer, locals);
        return true;
    }

    fn isNullableMirCallResultType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.nullableTypeFromCandidate(ty) != null;
    }

    fn callReturnTypeForInferredLocal(self: *CEmitter, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), comptime matches: fn (*CEmitter, ast.TypeExpr) bool) ?ast.TypeExpr {
        const ty = self.callResultTypeForEmission(initializer, locals) orelse return null;
        return if (matches(self, ty)) ty else null;
    }

    fn emitInferredCallLocalInitValue(self: *CEmitter, name: []const u8, inferred_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, inferred_ty, initializer, locals)) return;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalCopyInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitBooleanInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (!inferredLocalBooleanInitializer(initializer)) return false;
        const bool_ty = type_syntax.simpleNameType("bool", initializer.span);
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

    fn inferredLocalBooleanInitializer(initializer: ast.Expr) bool {
        return switch (initializer.kind) {
            .unary => |node| node.op == .logical_not,
            .binary => |node| node.op == .logical_and or node.op == .logical_or or lower_c_expr.comparisonExpr(initializer),
            .grouped => |inner| inferredLocalBooleanInitializer(inner.*),
            else => false,
        };
    }

    fn inferredLocalCastInitializer(initializer: ast.Expr) bool {
        return switch (initializer.kind) {
            .cast => true,
            .grouped => |inner| inferredLocalCastInitializer(inner.*),
            else => false,
        };
    }

    fn literalExpressionResultType(self: *CEmitter, initializer: ast.Expr) !?ast.TypeExpr {
        return switch (initializer.kind) {
            .int_literal, .bool_literal => (self.mirTargetTypeFactAt(.expression_result, initializer.span) orelse return error.UnsupportedCEmission).target_ty,
            .grouped => |inner| try self.literalExpressionResultType(inner.*),
            else => null,
        };
    }

    fn emitNumericInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn numericExprTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn numericExprTypeForEmissionInferred(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn numericExpressionResultType(self: *CEmitter, expr: ast.Expr, inferred: ast.TypeExpr) ?ast.TypeExpr {
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

    fn conditionOperandTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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
    fn exprResolvesToFloat(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn operandResolvesToFloat(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.operandEmitType(expr, locals) orelse return false;
        return floatCTypeName(ty) != null;
    }

    fn derefResolvesToFloat(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.derefPointeeType(inner, locals) orelse return false;
        return floatCTypeName(ty) != null;
    }

    fn indexResolvesToFloat(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
        _ = self;
        const local_set = locals orelse return false;
        const elem = localIndexElementType(node.base.*, local_set) orelse return false;
        return floatCTypeName(elem) != null;
    }

    fn callResolvesToFloat(self: *CEmitter, expr: ast.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (self.mirHasCallTargetKindAt(.raw_load, node.callee.*.span) and node.type_args.len == 1) {
            const result_ty = (self.mirTargetTypeFactAt(.raw_result, node.callee.*.span) orelse return false).target_ty;
            return floatCTypeName(result_ty) != null;
        }
        const return_ty = self.callResultTypeForEmission(expr, locals) orelse return false;
        return floatCTypeName(return_ty) != null;
    }

    fn emitCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn mirInferredLocalType(self: *CEmitter, name: []const u8, initializer: ast.Expr, known_ty: ?ast.TypeExpr) !?ast.TypeExpr {
        const fact_ty = (self.mirTargetTypeFactAtOwned(.inferred_local, initializer.span, name, null) orelse return null).target_ty;
        if (known_ty) |ty| {
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(ty))) return error.UnsupportedCEmission;
        }
        return fact_ty;
    }

    fn emitSequencedCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        return lower_c_call.collectSequencedArgTemps(self.sequencedArgContext(), call, locals, fn_info);
    }

    fn emitSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        if (arg.kind == .grouped) return try self.emitSequencedCallArgTemp(arg.kind.grouped.*, locals, target_ty);
        if (try self.emitSpecialSequencedCallArgTemp(arg, locals, target_ty)) |temp| return temp;
        return lower_c_call.emitPlainSequencedArgTemp(self.sequencedArgContext(), arg, locals, target_ty);
    }

    fn emitSpecialSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        return lower_c_call.emitSpecialSequencedArgTemp(self.specialSequencedArgContext(), arg, locals, target_ty);
    }

    fn emitAddressSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_access.emitRawManyOffsetDerefAddressValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitLocalIndexAddressValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitIndexSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_access.emitDirectCallSliceIndexExprValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitDirectCallArrayIndexExprValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        if (try lower_c_access.emitLocalIndexValueTemp(self.accessEmitContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitBinarySequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        if (try lower_c_flow.emitSequencedConditionValueTemp(self.flowEmitContext(), arg, locals)) |temp| return temp;
        if (try lower_c_arith.emitSequencedBinaryValueTemp(self.sequencedBinaryContext(), arg, locals, target_ty)) |temp| return temp;
        return null;
    }

    fn emitCallSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const call = callExpr(arg) orelse return null;
        if (try self.emitAtomicResultValueTempFromCall(call, locals)) |temp| return temp;
        if (try lower_c_call.emitBitcastValueTempFromCall(self.sequencedArgContext(), call, locals)) |temp| return temp;
        if (try lower_c_call.emitExternNonNullCallValueTemp(self.sequencedArgContext(), &self.functions, arg, locals)) |temp| return temp;
        if (try lower_c_access.emitRawManyOffsetValueTempFromCall(self.accessEmitContext(), call, locals, target_ty)) |temp| return temp;
        if (try self.emitUncheckedAddValueTempFromCall(call, arg.span, locals, target_ty, "call_arg")) |temp| return temp;
        if (try self.emitNestedSequencedCallValueTemp(call, locals)) |temp| return temp;
        return null;
    }

    fn emitAtomicCastSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
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

    fn emitAtomicResultValueTempFromCall(self: *CEmitter, call: expr_syntax.CallExpr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
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

    fn emitUncheckedAddValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        return lower_c_arith.emitUncheckedAddValueTemp(self.arithContext(), expr, locals, target_ty, range_target);
    }

    fn emitUncheckedAddValueTempFromCall(self: *CEmitter, call: anytype, call_span: ast.Span, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        return lower_c_arith.emitUncheckedAddValueTempFromCall(self.arithContext(), call, call_span, locals, target_ty, range_target);
    }

    fn hasMirNoOverflowRangeFact(self: *CEmitter, target: []const u8, op: []const u8, span: ast.Span) bool {
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
    fn mirCheckElided(self: *CEmitter, span: ast.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.elided_bounds) |pt| {
                if (pt.line == span.line and pt.column == span.column) return true;
            }
        }
        return false;
    }

    fn requireMirBoundsFact(self: *CEmitter, kind: mir.BoundsFactKind, span: ast.Span) !void {
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

    fn mirCallTargetKindAt(self: *CEmitter, span: ast.Span) ?mir.CallTargetKind {
        const function = self.currentMirFunction() orelse return null;
        for (function.call_target_facts) |fact| {
            if (mirSourceMatches(span, fact.source)) return fact.kind;
        }
        return null;
    }

    fn mirHasCallTargetKindAt(self: *CEmitter, kind: mir.CallTargetKind, span: ast.Span) bool {
        const function = self.currentMirFunction() orelse return false;
        for (function.call_target_facts) |fact| {
            if (fact.kind == kind and mirSourceMatches(span, fact.source)) return true;
        }
        return false;
    }

    fn atomicInitPayloadTypeAt(self: *CEmitter, span: ast.Span, expected_result_ty: ast.TypeExpr) ?ast.TypeExpr {
        const function = self.currentMirFunction() orelse return null;
        const expected_payload_ty = lower_c_shape.atomicPayloadOfType(self.resolveAliasType(expected_result_ty)) orelse return null;
        var matched_payload_ty: ?ast.TypeExpr = null;
        var found_result = false;
        for (function.target_type_facts) |result_fact| {
            if (result_fact.kind != .atomic_init_result or result_fact.target_owner == null or result_fact.target_index == null or !mirSourceMatches(span, result_fact.source)) continue;
            if (!std.mem.eql(u8, result_fact.target_owner.?, "atomic.init")) continue;
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(result_fact.target_ty), self.resolveAliasType(expected_result_ty))) continue;
            found_result = true;

            var group_payload_ty: ?ast.TypeExpr = null;
            for (function.target_type_facts) |payload_fact| {
                if (payload_fact.kind != .atomic_init_payload or payload_fact.target_index != result_fact.target_index or payload_fact.target_owner == null or !mirSourceMatches(span, payload_fact.source)) continue;
                if (!std.mem.eql(u8, payload_fact.target_owner.?, "atomic.init")) continue;
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(payload_fact.target_ty), self.resolveAliasType(expected_payload_ty))) return null;
                if (group_payload_ty) |known| {
                    if (!type_syntax.sameTypeSyntax(self.resolveAliasType(known), self.resolveAliasType(payload_fact.target_ty))) return null;
                }
                group_payload_ty = payload_fact.target_ty;
            }
            const payload_ty = group_payload_ty orelse return null;
            if (matched_payload_ty) |known| {
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(known), self.resolveAliasType(payload_ty))) return null;
            }
            matched_payload_ty = payload_ty;
        }
        if (!found_result) return null;
        return matched_payload_ty;
    }

    fn mirTargetTypeFactAt(self: *CEmitter, kind: mir.TargetTypeKind, span: ast.Span) ?mir.TargetTypeFact {
        return mir_facts_view.MirFactsView.init(self.mir_module).targetTypeFactAtWithModuleFallback(self.currentMirFunction(), kind, mir.sourcePointFromSpan(span));
    }

    fn mirTargetTypeFactMatchingType(self: *CEmitter, kind: mir.TargetTypeKind, span: ast.Span, expected_ty: ast.TypeExpr) ?mir.TargetTypeFact {
        const function = self.currentMirFunction() orelse return null;
        for (function.target_type_facts) |fact| {
            if (fact.kind != kind or fact.target_index != null or fact.target_owner != null) continue;
            if (!mirTargetTypeSourceMatches(kind, span, fact.source)) continue;
            if (type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(expected_ty))) return fact;
        }
        return null;
    }

    fn mirTargetTypeFactAtOwned(self: *CEmitter, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?mir.TargetTypeFact {
        return mir_facts_view.MirFactsView.init(self.mir_module).targetTypeFactAtOwnedWithModuleFallback(self.currentMirFunction(), kind, mir.sourcePointFromSpan(span), target_owner, target_index);
    }

    fn mirConstGetIndexAt(self: *CEmitter, span: ast.Span) ?usize {
        const function = self.currentMirFunction() orelse return null;
        var matched: ?usize = null;
        for (function.const_get_facts) |fact| {
            if (!mirSourceMatches(span, fact.source)) continue;
            if (matched) |index| {
                if (index != fact.index) return null;
            } else {
                matched = fact.index;
            }
        }
        return matched;
    }

    fn mirAggregateTargetTypeForExpr(self: *CEmitter, expr: ast.Expr) !?ast.TypeExpr {
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

    fn mirFloatLiteralTargetForExpr(self: *CEmitter, expr: ast.Expr) !?ast.TypeExpr {
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
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(left.?), self.resolveAliasType(right.?))) return error.UnsupportedCEmission;
                break :blk left;
            },
            else => null,
        };
    }

    fn mirSourceMatches(span: ast.Span, source: mir.SourcePoint) bool {
        return mir_facts_view.sourcePointLineColumnMatches(mir.sourcePointFromSpan(span), source);
    }

    fn mirTargetTypeSourceMatches(kind: mir.TargetTypeKind, span: ast.Span, source: mir.SourcePoint) bool {
        return mir_facts_view.targetTypeSourceMatches(kind, mir.sourcePointFromSpan(span), source);
    }

    fn mirPointerFactIsLiveGlobal(fact: mir.PointerProvenanceFact) bool {
        if (fact.provenance != .global_storage) return false;
        return mirPointerFactReasonIsLive(fact);
    }

    // A live local_storage fact is the positive locality proof that keeps a deref
    // PLAIN under the spec I.13 conservative default. Liveness is symmetric with
    // the global side: any call/indirect-call/address-escape/dynamic-index
    // invalidation drops the proof back to unknown (-> race-tolerant lowering).
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

    fn fixedLocalPointerArrayElementType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
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

    fn arrayLiteralItems(expr: ast.Expr) ?[]const ast.Expr {
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

    fn directLocalAggregateMemberPath(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?AggregatePointerFieldPath {
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

    fn directLocalAggregateArrayElementPath(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?AggregatePointerFieldPath {
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

    fn directLocalPointerArrayBaseName(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
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

    fn localArrayConstIndexValue(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?u64 {
        const value = constIntValue(expr, locals) orelse return null;
        if (value < 0) return null;
        return std.math.cast(u64, value);
    }

    fn directLocalArrayElementPath(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?LocalArrayElementPath {
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

    fn isKnownStructType(self: *CEmitter, ty: ast.TypeExpr) bool {
        return self.structNameFromCandidate(ty) != null;
    }

    fn mirPointerFactSubjectRecoveredType(fact: mir.PointerProvenanceFact, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn mirPointerFactState(fact: mir.PointerProvenanceFact) mir.PointerProvenance {
        if (mirPointerFactIsLiveGlobal(fact)) return .global_storage;
        if (mirPointerFactIsLiveLocal(fact)) return .local_storage;
        return .unknown;
    }

    fn applyMirPointerProvenanceFact(self: *CEmitter, fact: mir.PointerProvenanceFact, locals: ?*std.StringHashMap(LocalInfo)) !void {
        if (!self.mirPointerFactSubjectSupportedNow(fact, locals)) return;
        try self.emitMirPointerProvenanceConsumedComment(fact);
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
        const ty = mirPointerFactSubjectRecoveredType(fact, locals) orelse return;
        if (self.fixedLocalPointerArrayElementType(ty) != null) {
            self.clearLocalArrayPointerElementsForLocal(fact.subject);
            return;
        }
        if (live_global) {
            try self.mir_pointer_local_provenance.put(fact.subject, .global_storage);
        } else if (mirPointerFactIsLiveLocal(fact)) {
            try self.mir_pointer_local_provenance.put(fact.subject, .local_storage);
        } else {
            _ = self.mir_pointer_local_provenance.remove(fact.subject);
        }
    }

    fn applyMirPointerProvenanceFactsAtSource(self: *CEmitter, subject: []const u8, element_index: ?usize, span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
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
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn applyMirPointerProvenanceInvalidationsAtCall(self: *CEmitter, span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) void {
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

    fn applyMirAggregatePointerFieldFactsAtSource(self: *CEmitter, subject: []const u8, field_path: []const u8, element_index: ?usize, span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
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
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn applyMirAggregatePointerFieldFactsForSubjectAtSource(self: *CEmitter, subject: []const u8, span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const function = self.currentMirFunction() orelse return false;
        var matched = false;
        for (function.pointer_provenance_facts) |fact| {
            if (!std.mem.eql(u8, fact.subject, subject)) continue;
            if (fact.field_path == null) continue;
            if (!mirSourceMatches(span, fact.source)) continue;
            matched = true;
            try self.applyMirPointerProvenanceFact(fact, locals);
        }
        return matched;
    }

    fn structLiteralFields(expr: ast.Expr) ?[]const ast.StructLiteralField {
        return switch (expr.kind) {
            .struct_literal => |fields| fields,
            .grouped => |inner| structLiteralFields(inner.*),
            else => null,
        };
    }

    fn applyMirAggregatePointerFieldFactsFromStructLiteral(self: *CEmitter, subject: []const u8, aggregate_ty: ast.TypeExpr, literal: ast.Expr, path_prefix: ?[]const u8, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn directMirAddressProvenanceExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAddressProvenanceExpr(inner.*, locals),
            .cast => |node| self.directMirAddressProvenanceExpr(node.value.*, locals),
            .address_of => |inner| self.directMirAddressProvenanceTarget(inner.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAddressProvenanceExpr(call.args[0], locals),
            else => false,
        };
    }

    fn directMirAddressProvenanceTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn directMirRawManyZeroOffsetExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
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

    fn directRawManyLocalName(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
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

    fn rawManyPointerTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .raw_many_pointer) ty else null;
    }

    fn directMirPointerLocalCopyExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
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

    fn directMirFixedPointerArrayElementExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirFixedPointerArrayElementExpr(inner.*, locals),
            .cast => |node| self.directMirFixedPointerArrayElementExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirFixedPointerArrayElementExpr(call.args[0], locals),
            else => self.directLocalArrayElementPath(expr, locals) != null,
        };
    }

    fn directMirAggregatePointerFieldExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerFieldExpr(inner.*, locals),
            .cast => |node| self.directMirAggregatePointerFieldExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAggregatePointerFieldExpr(call.args[0], locals),
            else => self.directLocalAggregateMemberPath(expr, locals) != null,
        };
    }

    fn directMirAggregatePointerArrayElementExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .grouped => |inner| self.directMirAggregatePointerArrayElementExpr(inner.*, locals),
            .cast => |node| self.directMirAggregatePointerArrayElementExpr(node.value.*, locals),
            .call => |call| self.isMirAssumeNoaliasCall(call) and
                self.directMirAggregatePointerArrayElementExpr(call.args[0], locals),
            else => self.directLocalAggregateArrayElementPath(expr, locals) != null,
        };
    }

    fn directMirPointerContainerValueExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
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

    fn updatePointerProvenanceFromMir(self: *CEmitter, name: []const u8, ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!isPointerLikeGlobalType(self.resolveAliasType(ty))) {
            _ = self.mir_pointer_local_provenance.remove(name);
            return;
        }

        _ = self.mir_pointer_local_provenance.remove(name);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, initializer.span, locals);
    }

    fn updatePointerProvenanceAssignmentFromMir(self: *CEmitter, name: []const u8, ty: ast.TypeExpr, value: ast.Expr, span: ast.Span, locals: *std.StringHashMap(LocalInfo)) !void {
        if (!isPointerLikeGlobalType(self.resolveAliasType(ty))) {
            _ = self.mir_pointer_local_provenance.remove(name);
            return;
        }

        _ = self.mir_pointer_local_provenance.remove(name);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, value.span, locals);
        _ = try self.applyMirPointerProvenanceFactsAtSource(name, null, span, locals);
    }

    fn applyMirAggregateReturnPointerFacts(self: *CEmitter, dest_name: []const u8, dest_ty: ast.TypeExpr, initializer: ast.Expr) !bool {
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

    fn applyMirPointerProvenanceForLocalInitializer(self: *CEmitter, name: []const u8, ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
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

    fn directLocalName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| directLocalName(inner.*),
            else => null,
        };
    }

    fn directStructTypeName(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return self.structNameFromCandidate(ty);
    }

    fn structNameFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        const name = typeName(self.resolveAliasType(ty)) orelse return null;
        return if (self.structs.contains(name)) name else null;
    }

    fn directAggregateCopySourceExpr(self: *CEmitter, expr: ast.Expr, target_ty: ast.TypeExpr, locals: *std.StringHashMap(LocalInfo)) bool {
        const target_struct_name = self.directStructTypeName(target_ty) orelse return false;
        return self.directAggregateCopySourceExprForStruct(expr, target_struct_name, locals);
    }

    fn directAggregateCopySourceExprForStruct(self: *CEmitter, expr: ast.Expr, target_struct_name: []const u8, locals: *std.StringHashMap(LocalInfo)) bool {
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

    fn generatedAggregateMemberCopySourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.mirTargetTypeFactAt(.expression_result, expr.span)) |fact| return fact.target_ty;
        return self.generatedAggregateMemberCopyFallbackTypeForEmission(expr, locals);
    }

    fn generatedAggregateMemberCopyFallbackTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        return self.generatedAggregateMemberCopyStorageOrSourceType(expr, locals);
    }

    fn generatedAggregateMemberCopyStorageOrSourceType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.operandEmitType(expr, locals)) |ty| return ty;
        return self.generatedExprSourceTypeForEmission(expr, locals);
    }

    fn applyMirPointerProvenanceForAssignment(self: *CEmitter, target: ast.Expr, value: ast.Expr, span: ast.Span, locals: *std.StringHashMap(LocalInfo)) !void {
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

    fn applyMirPointerProvenanceForIndexAssignment(self: *CEmitter, target: ast.Expr, value: ast.Expr, span: ast.Span, locals: *std.StringHashMap(LocalInfo)) !void {
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
        slice: ast.TypeExpr,
        @"struct": ast.StructDecl,
        array: ast.TypeExpr,
        dyn_trait: []const u8,
        closure: []const u8,
        value_optional: ast.TypeExpr,
        result: struct { ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr },
        tagged_union: ast.UnionDecl,
    };

    // Positive locality proof for the bare pointer-deref access class (spec I.13):
    // PLAIN deref lowering is allowed only when the pointer provably names the
    // current function's own storage — a live MIR local_storage fact for the
    // pointer local, or a syntactic address-of a named local (through grouped/
    // cast). Everything else lowers race-tolerantly.
    fn derefPointerHasProvenLocalStorage(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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
    fn directLocalStorageTarget(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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
    fn derefAccessLowering(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !DerefAccessLowering {
        const pointee_ty = self.derefPointeeType(inner, locals) orelse return .plain;
        return self.derefAccessLoweringForPointee(inner, pointee_ty, locals);
    }

    fn derefAccessLoweringForPointee(self: *CEmitter, inner: ast.Expr, pointee_ty: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !DerefAccessLowering {
        if (self.derefPointerHasProvenLocalStorage(inner, locals)) return .plain;
        const info = self.globalInfoFromType(pointee_ty) catch return .plain;
        if (info.aggregate) return .plain;
        if (info.pointer_like) return .{ .race_pointer = info };
        if (!lower_c_shape.raceScalarHelperExists(info.race_type_name)) return error.UnsupportedCEmission;
        return .{ .race_scalar = info };
    }

    fn emitRaceTolerantDerefStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantAggregateDerefExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
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

    fn raceAggregateKind(self: *CEmitter, ty: ast.TypeExpr) !RaceAggregateKind {
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

    fn emitRaceTolerantAggregateLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast.TypeExpr) anyerror!void {
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

    fn emitRaceTolerantAggregateStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast.TypeExpr, value_expr: []const u8) anyerror!void {
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

    fn emitRaceTolerantValueOptionalLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast.TypeExpr, child: ast.TypeExpr) anyerror!void {
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

    fn emitRaceTolerantValueOptionalStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8, child: ast.TypeExpr) anyerror!void {
        const payload_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "&(({s})->value)", .{ptr_expr});
        const payload_value = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.value", .{value_expr});
        try self.emitRaceTolerantAggregateStoreFromPtr(payload_ptr, child, payload_value);
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_bool(&(({s})->present), (bool){s}.present);\n", .{ ptr_expr, value_expr });
    }

    fn emitRaceTolerantResultLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast.TypeExpr, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror!void {
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

    fn emitRaceTolerantResultStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, value_expr: []const u8, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror!void {
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

    fn emitRaceTolerantTaggedUnionLoadFromPtr(self: *CEmitter, ptr_expr: []const u8, ty: ast.TypeExpr, union_decl: ast.UnionDecl) anyerror!void {
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

    fn emitRaceTolerantTaggedUnionStoreFromPtr(self: *CEmitter, ptr_expr: []const u8, union_decl: ast.UnionDecl, value_expr: []const u8) anyerror!void {
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

    fn constArrayLen(self: *CEmitter, expr: ast.Expr) ?usize {
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

    fn emitRaceTolerantPointerMemberStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantPointerMemberAggregateExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
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

    fn emitRaceTolerantNestedPointerMemberAggregateExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
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

    fn emitRaceTolerantIndexedMemberAggregateExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
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

    fn ambiguousPointerMemberAggregateValueCopy(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
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

    fn ambiguousIndexedMemberAggregateValueCopy(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
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

    fn ambiguousAggregateDerefValueCopy(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantSliceIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), slice: SliceAccess, element_ty: ast.TypeExpr) anyerror!bool {
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

    fn emitRaceTolerantSliceIndexStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn pointerArrayDerefInner(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.Expr {
        return switch (base.kind) {
            .deref => |inner| if (self.derefPointerHasProvenLocalStorage(inner.*, locals)) null else inner.*,
            .grouped => |inner| self.pointerArrayDerefInner(inner.*, locals),
            else => null,
        };
    }

    fn emitPointerArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast.TypeExpr, index_temp: ?[]const u8) anyerror!void {
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

    fn emitRaceTolerantPointerArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast.TypeExpr) anyerror!bool {
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

    fn emitRaceTolerantPointerArrayIndexStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantIndexedMemberStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantNestedIndexedMemberStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

    fn emitRaceTolerantNestedPointerMemberStoreStmt(self: *CEmitter, target: ast.Expr, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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
    fn constLocalValue(self: *CEmitter, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?i128 {
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

    fn resultTryOperandIsResult(ctx_ptr: *anyopaque, operand: ast.Expr) bool {
        const ctx: *TryScanContext = @ptrCast(@alignCast(ctx_ptr));
        _ = ctx.locals;
        const operand_ty = ctx.emitter.mirTryOperandTypeForQuery(operand) orelse return false;
        return lower_c_shape.resultPayloadTypeForTag(operand_ty, "ok") != null and lower_c_shape.resultPayloadTypeForTag(operand_ty, "err") != null;
    }

    fn nullableTryOperandIsNullable(ctx_ptr: *anyopaque, operand: ast.Expr) anyerror!bool {
        const ctx: *TryScanContext = @ptrCast(@alignCast(ctx_ptr));
        _ = ctx.locals;
        const operand_ty = ctx.emitter.mirTryOperandTypeForQuery(operand) orelse return false;
        return ctx.emitter.nullableTypeFromCandidate(operand_ty) != null;
    }

    fn sliceReturnTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn sliceBaseTypeForZeroSpanSlice(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => self.callResultTypeForEmission(expr, locals),
            .grouped => |inner| blk: {
                const inferred = self.sliceBaseTypeForZeroSpanSlice(inner.*, locals) orelse break :blk null;
                break :blk self.checkedStorageExpressionResultTypeForEmission(expr, inferred) orelse break :blk null;
            },
            else => self.operandEmitType(expr, locals),
        };
    }

    fn requireExpressionResultTypeForInference(self: *CEmitter, expr: ast.Expr, inferred: ast.TypeExpr) ?ast.TypeExpr {
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!lower_c_type.sameCStorageType(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) return null;
        return fact.target_ty;
    }

    fn checkedStorageExpressionResultTypeForEmission(self: *CEmitter, expr: ast.Expr, inferred: ast.TypeExpr) ?ast.TypeExpr {
        if (!isSourceSpan(expr.span)) return inferred;
        return self.requireExpressionResultTypeForInference(expr, inferred);
    }

    fn storageOrExpressionResultTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.operandEmitType(expr, locals);
        return (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
    }

    fn castResultTypeForEmission(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        const node = switch (expr.kind) {
            .cast => |node| node,
            else => return null,
        };
        return self.checkedCastResultTypeForEmission(expr, node.ty.*);
    }

    fn checkedCastResultTypeForEmission(self: *CEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) ?ast.TypeExpr {
        if (!isSourceSpan(expr.span)) return expected_ty;
        const target_ty = (self.mirTargetTypeFactAt(.explicit_cast_target, expr.span) orelse return null).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(target_ty), self.resolveAliasType(expected_ty))) return null;
        const fact_ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact_ty), self.resolveAliasType(target_ty))) return null;
        return fact_ty;
    }

    fn sliceTypeForBase(self: *CEmitter, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .slice => resolved,
            .array => |array| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = array.child } } },
            else => null,
        };
    }

    fn arrayLenText(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .array => |node| try self.arrayLenTextForExpr(node.len),
            .qualified => |node| try self.arrayLenText(node.child.*),
            else => null,
        };
    }

    fn arrayLenTextForExpr(self: *CEmitter, expr: ast.Expr) ![]const u8 {
        var reflect_env = self.reflectEnv();
        const value = constArrayLenValue(expr, &self.const_fns, &self.const_globals, lower_c_reflect.comptimeReflectThunk, &reflect_env) orelse return error.UnsupportedCEmission;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    // The declared type of a value expression (a local, global, call result,
    // struct field, or array/slice element) — enough to keep inferred locals and
    // enum-literal comparison operands typed.
    fn operandEmitType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn identTypeForEmissionRecovered(self: *CEmitter, name: []const u8, span: ast.Span, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const declared_ty: ast.TypeExpr = blk: {
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

    fn exprHasPointerType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const ty = self.memberBaseTypeForEmission(expr, locals) orelse return false;
        return self.pointerTypeFromCandidate(ty) != null;
    }

    fn memberFieldType(self: *CEmitter, base: ast.Expr, field_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (indexExpr(base)) |index| {
            const base_ty = self.arrayOrSliceBaseTypeForEmission(index.base.*, locals) orelse return null;
            const element_ty = self.arrayOrSliceElementTypeFromCandidate(base_ty) orelse return null;
            return self.memberFieldTypeFromAggregate(element_ty, field_name);
        }
        const base_ty = self.memberBaseTypeForEmission(base, locals) orelse return null;
        return self.memberFieldTypeFromAggregate(base_ty, field_name);
    }

    fn memberBaseTypeForEmission(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn memberBaseTypeForEmissionRecovered(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (self.operandEmitType(base, locals)) |ty| return ty;
        if (self.callResultTypeForEmission(base, locals)) |ty| return ty;
        return null;
    }

    fn syntheticDestructureBase(base: ast.Expr) bool {
        return switch (base.kind) {
            .ident => |ident| std.mem.startsWith(u8, ident.text, "__destr"),
            .grouped => |inner| syntheticDestructureBase(inner.*),
            else => false,
        };
    }

    fn memberFieldTypeFromAggregate(self: *CEmitter, aggregate_ty: ast.TypeExpr, field_name: []const u8) ?ast.TypeExpr {
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
    fn sliceAccessForBase(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
        if (sliceAccessForExpr(expr, locals)) |slice| return slice;
        const ty = self.operandEmitType(expr, locals) orelse return null;
        return if (self.sliceTypeFromCandidate(ty) != null) .{ .ptr_field = "ptr", .len_field = "len" } else null;
    }

    // The array type of `expr`, if it is an array — including the element of an
    // outer array access (`m[i]` over `[N][M]T` yields `[M]T`), which enables
    // nested indexing `m[i][j]`. Returns null for non-array expressions.
    fn arrayTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn arrayTypeFromType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved = self.resolveAliasType(ty);
        return if (resolved.kind == .array) resolved else null;
    }

    fn arrayOrSliceElementTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn arrayDerefResultTypeForEmission(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const pointee = self.derefPointeeType(inner, locals) orelse return null;
        if (!isSourceSpan(expr.span)) return pointee;
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(pointee))) return null;
        return fact.target_ty;
    }

    // Whether an expression has a pointer type, so member access lowers as `->`.
    // MMIO/slice/array accesses take dedicated paths before reaching here, so this
    // covers ordinary `*T` struct pointers (e.g. a borrowed `move` handle).
    fn exprIsPointer(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
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

    fn groupedExprIsPointer(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        if (!isSourceSpan(expr.span)) return self.exprIsPointer(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return false).target_ty;
        return self.pointerTypeFromCandidate(ty) != null;
    }

    fn pointerTypeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return if (self.resolveAliasType(ty).kind == .pointer) ty else null;
    }

    const PointerTypeNode = struct {
        mutability: ast.Mutability,
        child: *ast.TypeExpr,
    };

    fn pointerNodeFromCandidate(self: *CEmitter, ty: ast.TypeExpr) ?PointerTypeNode {
        return switch (self.resolveAliasType(ty).kind) {
            .pointer => |node| .{ .mutability = node.mutability, .child = node.child },
            else => null,
        };
    }

    // The pointee type of a pointer-typed expression (`p` where `p: *T` → `T`).
    fn derefPointeeType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn groupedDerefPointeeType(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (!isSourceSpan(expr.span)) return self.derefPointeeType(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.pointerPointeeTypeFromType(ty);
    }

    fn pointerPointeeTypeFromType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (self.resolveAliasType(ty).kind) {
            .pointer => |p| p.child.*,
            .raw_many_pointer => |p| p.child.*,
            else => null,
        };
    }

    fn structTypeNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                break :blk self.structTypeNameFromType(ty);
            },
            .member => blk: {
                // A source member result is already represented by a complete
                // MIR expression_result row. Do not rediscover its struct type
                // by walking the member declaration here.
                const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.structTypeNameFromType(ty);
            },
            .index => blk: {
                const ty = self.storageOrExpressionResultTypeForEmission(expr, locals) orelse break :blk null;
                break :blk self.structTypeNameFromType(ty);
            },
            .grouped => |inner| self.groupedStructTypeNameForExpr(expr, inner.*, locals),
            else => null,
        };
    }

    fn groupedStructTypeNameForExpr(self: *CEmitter, expr: ast.Expr, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        if (!isSourceSpan(expr.span)) return self.structTypeNameForExpr(inner, locals);
        const ty = (self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null).target_ty;
        return self.structTypeNameFromType(ty);
    }

    fn structTypeNameFromType(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(ty).kind) {
            .name => |n| n.text,
            .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                .name => |n| n.text,
                else => null,
            },
            else => null,
        };
    }

    fn callResultTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn callExpressionResultTypeForEmission(self: *CEmitter, expr: ast.Expr, inferred: ast.TypeExpr) ?ast.TypeExpr {
        return self.checkedExpressionResultTypeForEmission(expr, inferred);
    }

    fn checkedExpressionResultTypeForEmission(self: *CEmitter, expr: ast.Expr, inferred: ast.TypeExpr) ?ast.TypeExpr {
        if (!isSourceSpan(expr.span)) return inferred;
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) return null;
        return fact.target_ty;
    }

    fn callReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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

    fn indirectCallCalleeType(self: *CEmitter, callee: ast.Expr) ?ast.TypeExpr {
        const ty = (self.mirTargetTypeFactAt(.indirect_call_callee, callee.span) orelse return null).target_ty;
        return self.resolveAliasType(ty);
    }

    fn closureCallReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const closure_ty = self.closureCalleeType(call.callee.*, locals) orelse return null;
        return closure_ty.kind.closure_type.ret.*;
    }

    fn indirectCallReturnTypeForCall(self: *CEmitter, call: anytype) ?ast.TypeExpr {
        const callee_ty = self.indirectCallCalleeType(call.callee.*) orelse return null;
        return switch (callee_ty.kind) {
            .fn_pointer => |signature| signature.ret.*,
            .closure_type => |signature| signature.ret.*,
            else => null,
        };
    }

    // Ordinary direct calls require the MIR-owned result row to match the
    // declared function return type before inferred-local typing can consume it.
    fn directCallReturnTypeForCall(self: *CEmitter, call: anytype) ?ast.TypeExpr {
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
    fn simpleMirResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.TargetTypeKind) ?ast.TypeExpr {
        return (self.mirTargetTypeFactAt(kind, call.callee.*.span) orelse return null).target_ty;
    }

    fn dynDispatchReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const trait_name = self.dynCalleeTrait(call.callee.*, locals) orelse return null;
        const trait = self.trait_decls.get(trait_name) orelse return null;
        const method_name = dynCalleeMethodName(call.callee.*) orelse return null;
        for (trait.methods, 0..) |method, index| {
            if (!std.mem.eql(u8, method.name.text, method_name)) continue;
            const declared_ty = method.return_type orelse return null;
            const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, call.callee.*.span, trait_name, index) orelse return null).target_ty;
            if (!std.meta.eql(fact_ty, declared_ty)) return null;
            return fact_ty;
        }
        return null;
    }

    fn dynDispatchMethodIndex(self: *CEmitter, callee: ast.Expr, trait_name: []const u8) ?usize {
        const trait = self.trait_decls.get(trait_name) orelse return null;
        const method_name = dynCalleeMethodName(callee) orelse return null;
        for (trait.methods, 0..) |method, index| {
            if (std.mem.eql(u8, method.name.text, method_name)) return index;
        }
        return null;
    }

    fn requireDynDispatchArgument(self: *CEmitter, span: ast.Span, trait_name: []const u8, method_index: usize, argument_index: usize) !void {
        const trait = self.trait_decls.get(trait_name) orelse return error.UnsupportedCEmission;
        if (method_index >= trait.methods.len) return error.UnsupportedCEmission;
        const method = trait.methods[method_index];
        if (argument_index + 1 >= method.params.len) return error.UnsupportedCEmission;
        const declared_ty = method.params[argument_index + 1].ty;
        const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_argument, span, trait_name, mir.dynDispatchArgumentFactIndex(method_index, argument_index)) orelse return error.UnsupportedCEmission).target_ty;
        if (!std.meta.eql(fact_ty, declared_ty)) return error.UnsupportedCEmission;
    }

    fn requireDynDispatchArgumentForDispatch(ctx: *anyopaque, span: ast.Span, trait_name: []const u8, method_index: usize, argument_index: usize) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.requireDynDispatchArgument(span, trait_name, method_index, argument_index);
    }

    fn requireDynDispatchResult(self: *CEmitter, span: ast.Span, trait_name: []const u8, method_index: usize) !void {
        const trait = self.trait_decls.get(trait_name) orelse return error.UnsupportedCEmission;
        if (method_index >= trait.methods.len) return error.UnsupportedCEmission;
        const declared_ty = trait.methods[method_index].return_type orelse return;
        if (isVoidType(self.resolveAliasType(declared_ty))) return;
        const fact_ty = (self.mirTargetTypeFactAtOwned(.dyn_dispatch_result, span, trait_name, method_index) orelse return error.UnsupportedCEmission).target_ty;
        if (!std.meta.eql(fact_ty, declared_ty)) return error.UnsupportedCEmission;
    }

    fn requireDynDispatchResultForDispatch(ctx: *anyopaque, span: ast.Span, trait_name: []const u8, method_index: usize) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.requireDynDispatchResult(span, trait_name, method_index);
    }

    // Atomic value-producing calls return the atomic payload type
    // (`atomic<u64>.fetch_add` -> `u64`), so inferred locals and compound
    // operands do not fall back to the C emitter's default `uint32_t`.
    fn atomicResultReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        _ = locals;
        return lower_c_atomic.atomicResultPayload(self.atomicEmitContext(), call);
    }

    // MaybeUninit extraction returns its MIR-owned payload type. The emitted
    // value is the backing storage itself, so an inferred local must use this
    // type before it is added to the C local environment.
    fn maybeUninitResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .maybe_uninit_assume_init) return null;
        return (self.mirTargetTypeFactAt(.maybe_uninit_payload, call.callee.*.span) orelse return null).target_ty;
    }

    // Raw loads and raw pointer construction have a distinct `raw_result`
    // fact. Do not recover their type from the call's type argument while
    // allocating an inferred local.
    fn rawResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .raw_load and kind != .raw_ptr) return null;
        return (self.mirTargetTypeFactAt(.raw_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Arithmetic-domain call results are admitted by the MIR domain identity
    // and its `domain_result` row. Do not rebuild wrap/Duration/Result shapes
    // from the AST while allocating inferred locals.
    fn domainResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        _ = mir.domainCallFactInfo(kind) orelse return null;
        return (self.mirTargetTypeFactAt(.domain_result, call.callee.*.span) orelse return null).target_ty;
    }

    // DMA helper calls return their MIR-owned result row. Keep inferred-local
    // result typing tied to the call identity instead of deriving DMA address
    // or slice results from the receiver/type spelling.
    fn dmaResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        _ = mir.dmaCallFactInfo(kind) orelse return null;
        return (self.mirTargetTypeFactAt(.dma_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Enum raw reads expose the MIR-owned representation result type. Keep
    // inferred locals from deriving the representation through enum lookup.
    fn enumRawResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .enum_raw) return null;
        return (self.mirTargetTypeFactAt(.enum_raw_result, call.callee.*.span) orelse return null).target_ty;
    }

    // const_get result typing is admitted by the MIR call identity plus the
    // fixed-index result row; array shape checks stay in const_get validation.
    fn constGetResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .const_get) return null;
        return (self.mirTargetTypeFactAt(.const_get_result, call.callee.*.span) orelse return null).target_ty;
    }

    // Semantic escapes are admitted by explicit MIR call identities and result
    // rows. Keep inferred locals from accepting these capability-sensitive
    // results through ordinary call or pointer spelling inference.
    fn declassifyResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .declassify) return null;
        return (self.mirTargetTypeFactAt(.declassify_result, call.callee.*.span) orelse return null).target_ty;
    }

    fn assumeNoaliasResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .assume_noalias) return null;
        return (self.mirTargetTypeFactAt(.assume_noalias_result, call.callee.*.span) orelse return null).target_ty;
    }

    // raw-many offsets return the MIR-owned pointer result. Inferred locals
    // must not recover this type from receiver spelling or alias resolution.
    fn rawManyOffsetResultReturnTypeForCall(self: *CEmitter, call: anytype, kind: mir.CallTargetKind) ?ast.TypeExpr {
        if (kind != .raw_many_offset) return null;
        return (self.mirTargetTypeFactAt(.raw_many_offset_result, call.callee.*.span) orelse return null).target_ty;
    }

    fn exprSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
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
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) break :blk null;
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
                if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(inferred))) break :blk null;
                break :blk fact.target_ty;
            },
            else => null,
        };
    }

    fn generatedExprSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (isSourceSpan(expr.span)) return null;
        return self.exprSourceTypeForEmission(expr, locals);
    }

    fn binarySourceTypeForEmission(self: *CEmitter, expr: ast.Expr, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const fact = self.mirTargetTypeFactAt(.expression_result, expr.span) orelse return null;
        const inferred = switch (node.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => type_syntax.simpleNameType("bool", expr.span),
            .shl, .shr => self.exprSourceTypeForEmission(node.left.*, locals),
            else => self.exprSourceTypeForEmission(node.left.*, locals) orelse self.exprSourceTypeForEmission(node.right.*, locals),
        };
        if (inferred) |ty| {
            if (!type_syntax.sameTypeSyntax(self.resolveAliasType(fact.target_ty), self.resolveAliasType(ty))) return null;
        }
        return fact.target_ty;
    }

    fn nullableInnerCTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?[]const u8 {
        return lower_c_info.nullableInnerCTypeForExpr(self.infoContext(), expr, locals);
    }

    fn nullableInnerCTypeForType(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return lower_c_info.nullableInnerCTypeForType(self.infoContext(), ty);
    }

    fn exprContainsResultTry(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.exprContainsTry(&ctx, expr, resultTryOperandIsResult);
    }

    fn callArgsContainResultTry(self: *CEmitter, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.argsContainTry(&ctx, args, resultTryOperandIsResult);
    }

    fn exprContainsNullableTry(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.exprContainsTryError(&ctx, expr, nullableTryOperandIsNullable);
    }

    fn callArgsContainNullableTry(self: *CEmitter, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var ctx = TryScanContext{ .emitter = self, .locals = locals };
        return lower_c_try.argsContainTryError(&ctx, args, nullableTryOperandIsNullable);
    }

    // Count the MMIO register reads in an expression. Used to detect a sequencing hazard in a
    // short-circuiting `&&` / `||` operand: a single read renders inline safely, but two or
    // more reads in one operand would be combined by non-sequencing C operators (function-call
    // arguments, arithmetic, comparison) whose evaluation order is unspecified — which would
    // silently reorder device reads.
    fn mmioAccess(self: *CEmitter, callee: ast.Expr, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
        return lower_c_mmio.classifyAccess(self.mmioAccessContext(), callee, args, locals);
    }

    fn cTypeForMmioValue(self: *CEmitter, value_type: []const u8) []const u8 {
        return lower_c_mmio.valueCType(self.mmioAccessContext(), value_type);
    }

    fn localInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !LocalInfo {
        return lower_c_info.localInfoFromType(self.infoContext(), ty);
    }

    fn globalInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !GlobalInfo {
        return lower_c_info.globalInfoFromType(self.infoContext(), ty);
    }

    fn globalElementInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !GlobalElementInfo {
        return lower_c_info.globalElementInfoFromType(self.infoContext(), ty);
    }

    fn nullableInnerCType(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
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

    fn cTypeForInfo(ctx: *anyopaque, ty: ast.TypeExpr, style: StructTypeStyle) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.cTypeFor(ty, style);
    }

    fn arrayLenTextForInfo(ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayLenTextForExpr(expr);
    }
};

fn deferExprForRefInBlock(block: ast.Block, ref: mir.DeferCleanupRef) ?ast.Expr {
    for (block.items) |stmt| {
        if (stmt.kind == .@"defer" and sourcePointMatchesSpan(ref.source, stmt.span)) return stmt.kind.@"defer";
        switch (stmt.kind) {
            .block, .comptime_block, .unsafe_block => |nested| {
                if (deferExprForRefInBlock(nested, ref)) |expr| return expr;
            },
            .contract_block => |contract| {
                if (deferExprForRefInBlock(contract.block, ref)) |expr| return expr;
            },
            .if_let => |node| {
                if (deferExprForRefInBlock(node.then_block, ref)) |expr| return expr;
                if (node.else_block) |else_block| {
                    if (deferExprForRefInBlock(else_block, ref)) |expr| return expr;
                }
            },
            .@"switch" => |node| {
                for (node.arms) |arm| switch (arm.body) {
                    .block => |nested| if (deferExprForRefInBlock(nested, ref)) |expr| return expr,
                    .expr => {},
                };
            },
            .loop => |node| {
                if (deferExprForRefInBlock(node.body, ref)) |expr| return expr;
            },
            else => {},
        }
    }
    return null;
}

fn sourcePointMatchesSpan(source: mir.SourcePoint, span: ast.Span) bool {
    return mir_facts_view.sourcePointExactMatches(source, mir.sourcePointFromSpan(span));
}

fn spanFromSourcePoint(source: mir.SourcePoint) ast.Span {
    return .{
        .offset = source.offset,
        .len = source.len,
        .line = source.line,
        .column = source.column,
    };
}

fn sourcePointFromOptionalSpan(span: ?ast.Span) ?mir.SourcePoint {
    return if (span) |value| mir.sourcePointFromSpan(value) else null;
}

fn isSourceSpan(span: ast.Span) bool {
    return mir_facts_view.sourcePointHasLineColumn(mir.sourcePointFromSpan(span));
}
