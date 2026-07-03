const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const error_from = @import("error_from.zig");
const eval = @import("eval.zig");
const mir = @import("mir.zig");
const switch_lower = @import("switch_lower.zig");

const lower_c_type = @import("lower_c_type.zig");
const rawScalarSuffix = lower_c_type.rawScalarSuffix;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;
const intTypeRange = lower_c_type.intTypeRange;
const isCReservedWord = lower_c_type.isCReservedWord;
const floatCTypeName = lower_c_type.floatCTypeName;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const isCVoidType = lower_c_type.isCVoidType;
const isVoidType = lower_c_type.isVoidType;

const lower_c_op = @import("lower_c_op.zig");
const isCheckedBinaryOp = lower_c_op.isCheckedBinaryOp;
const checkedHelperParts = lower_c_op.checkedHelperParts;
const satHelperParts = lower_c_op.satHelperParts;
const trapHelperForCall = lower_c_op.trapHelperForCall;

const lower_c_atomic = @import("lower_c_atomic.zig");
const fenceHelperForCall = lower_c_atomic.fenceHelperForCall;

// C emission model and helper modules used by the emitter implementation.
const lower_c_model = @import("lower_c_model.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_attr = @import("lower_c_attr.zig");
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
const lower_c_builtin = @import("lower_c_builtin.zig");
const lower_c_builtin_emit = @import("lower_c_builtin_emit.zig");
const lower_c_call = @import("lower_c_call.zig");
const lower_c_reflect = @import("lower_c_reflect.zig");
const lower_c_map = @import("lower_c_map.zig");
const lower_c_memory = @import("lower_c_memory.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_switch = @import("lower_c_switch.zig");
const lower_c_try = @import("lower_c_try.zig");
const lower_c_special = @import("lower_c_special.zig");
const lower_c_infer = @import("lower_c_infer.zig");
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
const ReflectEnv = lower_c_reflect.ReflectEnv;
const StructTypeStyle = lower_c_model.StructTypeStyle;
const MmioStruct = lower_c_model.MmioStruct;
const MmioAccess = lower_c_model.MmioAccess;
const GlobalInfo = lower_c_model.GlobalInfo;
const GlobalElementInfo = lower_c_model.GlobalElementInfo;
const GlobalAccess = lower_c_model.GlobalAccess;
const GlobalArrayElementAccess = lower_c_model.GlobalArrayElementAccess;
const hasNakedAttr = lower_c_attr.hasNakedAttr;
const backendNameOverride = lower_c_attr.backendNameOverride;
const bitcastReturnTypeForCall = lower_c_expr.bitcastReturnTypeForCall;
const exprContainsCall = lower_c_expr.exprContainsCall;
const resolvedArrayChildType = lower_c_shape.resolvedArrayChildType;
const overlayFieldLayoutForType = lower_c_shape.overlayFieldLayout;
const resultPayloadTypeForTag = lower_c_shape.resultPayloadTypeForTag;
const structFieldType = lower_c_shape.structFieldType;
const genericChildType = lower_c_shape.genericChildType;
const isVoidLiteralExpr = lower_c_shape.isVoidLiteralExpr;
const emitStaticCInitializer = lower_c_const.emitStaticCInitializer;
const staticCInitializer = lower_c_const.staticCInitializer;
const appendCIntLiteral = lower_c_const.appendCIntLiteral;
const appendCFloatLiteral = lower_c_const.appendCFloatLiteral;
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
const byteViewCallReturnTypeForCall = lower_c_builtin.byteViewCallReturnTypeForCall;
const appendLineDirective = lower_c_map.appendLineDirective;
const emitGlobalDecl = lower_c_global.emitGlobal;
const appendGlobalLoadExpr = lower_c_global.appendGlobalLoadExpr;
const appendGlobalStorePrefix = lower_c_global.appendGlobalStorePrefix;
const appendGlobalStoreSuffix = lower_c_global.appendGlobalStoreSuffix;
const appendGlobalStoreValue = lower_c_global.appendGlobalStoreValue;
const appendGlobalArrayElementStore = lower_c_global.appendGlobalArrayElementStore;
const appendGlobalArrayElementMemberStore = lower_c_global.appendGlobalArrayElementMemberStore;

const isUninitLiteral = ast_query.isUninitLiteral;
const typeName = ast_query.typeName;
const simpleNameType = ast_query.simpleNameType;
const contractName = ast_query.contractName;
const calleeIdentName = ast_query.calleeIdentName;
const callExpr = ast_query.callExpr;
const indexExpr = ast_query.indexExpr;
const memberCallee = ast_query.memberCallee;
const memberExpr = ast_query.memberExpr;
const isCpuPauseCall = ast_query.isCpuPauseCall;
const isRawLoadCall = ast_query.isRawLoadCall;
const isRawStoreCall = ast_query.isRawStoreCall;
const isStringLiteralTarget = ast_query.isStringLiteralTarget;
const isMmioStructAbi = ast_query.isMmioStructAbi;
const dynCalleeMethodName = ast_query.dynCalleeMethodName;

pub fn appendLayoutAsserts(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), struct_names: []const []const u8) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = false });
    defer typed_mir.deinit();

    var emitter = CEmitter.init(allocator, out, &typed_mir, null);
    defer emitter.deinit();
    try emitter.collectModule(module);

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

    var emitter = CEmitter.init(allocator, out, &typed_mir, null);
    defer emitter.deinit();
    try emitter.collectModule(module);

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
) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
    defer typed_mir.deinit();

    var emitter = CEmitter.init(allocator, out, &typed_mir, source_path);
    emitter.ksan = ksan;
    emitter.msan = msan;
    emitter.csan = csan;
    emitter.stub_asm = stub_asm;
    try emitter.emitModule(module);
}

const CEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: std.heap.ArenaAllocator,
    globals: std.StringHashMap(GlobalInfo),
    static_initializers: std.StringHashMap(ast.Expr),
    type_aliases: std.StringHashMap(ast.TypeExpr),
    functions: std.StringHashMap(FnInfo),
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
    structs: std.StringHashMap(ast.StructDecl),
    mmio_structs: std.StringHashMap(MmioStruct),
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
    // Active `defer` expressions for the function currently being emitted, in source
    // order (a function-scoped stack). Every exit edge — `return`, `break`, `continue`,
    // and `?` error propagation — flushes the appropriate suffix of this stack so lexical
    // cleanup runs on all paths, including across nested blocks. `loop_defer_marks` records
    // the stack depth at each enclosing loop's entry, so a `break`/`continue` flushes only
    // the defers declared inside that loop, not the whole function.
    defer_stack: std.ArrayList(ast.Expr) = .empty,
    loop_defer_marks: std.ArrayList(usize) = .empty,

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8), mir_module: *const mir.Module, source_path: ?[]const u8) CEmitter {
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
            .temp_index = 0,
            .indent = 0,
        };
    }

    fn deinit(self: *CEmitter) void {
        self.deinitFunctionCollections();
        self.deinitTypeCollections();
        self.deinitDeclCollections();
        self.deinitControlFlowState();
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
        self.const_fns.deinit();
        eval.deinitConstGlobals(self.allocator, &self.const_globals);
        self.static_initializers.deinit();
        self.globals.deinit();
    }

    fn deinitControlFlowState(self: *CEmitter) void {
        self.loop_ids.deinit(self.allocator);
        self.loop_labels.deinit(self.allocator);
        self.defer_stack.deinit(self.allocator);
        self.loop_defer_marks.deinit(self.allocator);
    }

    fn collectConstGlobalWidths(self: *CEmitter, module: ast.Module) !void {
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

    // Run only the artifact-collection pre-passes (no emission). After this returns, the
    // emitter's `structs`/`type_aliases`/`const_globals`/… maps are populated, so layout
    // queries (`comptimeStructLayout`) resolve exactly as during emission. Shared by
    // `emitModule` (which goes on to emit) and `appendLayoutAsserts` (layouts only).
    fn collectModule(self: *CEmitter, module: ast.Module) anyerror!void {
        try self.collectConstFns(module);
        try self.collectForwardTypeNames(module);
        try self.collectConstGlobals(module);
        try self.collectDeclArtifacts(module);
        try self.collectBindThunks(module);
    }

    fn collectConstFns(self: *CEmitter, module: ast.Module) !void {
        // Pre-pass: collect `const fn` bodies and fold `const` global values up
        // front, so fixed-array lengths that reference them (section 22
        // comptime↔type) resolve during the artifact-collection pass below.
        for (module.decls) |decl| {
            if (decl.kind == .fn_decl) {
                const fn_decl = decl.kind.fn_decl;
                if (fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
            }
        }
    }

    fn collectForwardTypeNames(self: *CEmitter, module: ast.Module) !void {
        // Pre-register every (non-MMIO) struct and type alias name so type-name
        // mangling (`typeSuffix`'s `struct_` prefix) is consistent regardless of
        // declaration/import order — e.g. an array-of-struct field (`[N]S`) whose
        // element struct `S` is declared after the containing struct, or in a
        // later-merged import. Without this the generated-typedef name and the
        // field's type reference can disagree.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .struct_decl => |struct_decl| {
                    if (!isMmioStructAbi(struct_decl)) try self.structs.put(struct_decl.name.text, struct_decl);
                },
                .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.tagged_unions.put(union_decl.name.text, union_decl),
                else => {},
            }
        }
    }

    fn collectConstGlobals(self: *CEmitter, module: ast.Module) !void {
        var reflect_env = self.reflectEnv();
        try eval.collectConstGlobalsWithOptions(self.allocator, module, &self.const_fns, &self.const_globals, .{
            .reflect = lower_c_reflect.comptimeReflectThunk,
            .reflect_ctx = &reflect_env,
        });
        try self.collectConstGlobalWidths(module);
    }

    fn collectDeclArtifacts(self: *CEmitter, module: ast.Module) anyerror!void {
        for (module.decls) |decl| {
            try self.collectDeclArtifact(decl);
        }
    }

    fn collectDeclArtifact(self: *CEmitter, decl: ast.Decl) anyerror!void {
        switch (decl.kind) {
            .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
            .global_decl => |global| try self.collectGlobalDeclArtifact(global),
            .struct_decl => |struct_decl| try self.collectStructDeclArtifact(struct_decl),
            .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
            .union_decl => |union_decl| try self.collectTaggedUnion(union_decl),
            .packed_bits_decl => |packed_bits| try self.collectPackedBits(packed_bits),
            .overlay_union_decl => |overlay_union| try self.collectOverlayUnion(overlay_union),
            .fn_decl => |fn_decl| try self.collectFnDeclArtifact(fn_decl, decl.attrs, false),
            .extern_fn => |fn_decl| try self.collectFnDeclArtifact(fn_decl, decl.attrs, true),
            .trait_decl => |t| try self.trait_decls.put(t.name.text, t),
            .impl_trait => |it| try self.collectImplTraitArtifact(it),
            else => {},
        }
    }

    fn collectGlobalDeclArtifact(self: *CEmitter, global: ast.GlobalDecl) !void {
        if (global.ty) |ty| try self.globals.put(global.name.text, try self.globalInfoFromType(ty));
        if (global.ty) |ty| try self.collectTypeArtifacts(ty);
    }

    fn collectStructDeclArtifact(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        if (isMmioStructAbi(struct_decl)) {
            try self.collectMmioStruct(struct_decl);
            return;
        }
        try self.structs.put(struct_decl.name.text, struct_decl);
        for (struct_decl.fields) |field| try self.collectTypeArtifacts(field.ty);
    }

    fn collectFnDeclArtifact(self: *CEmitter, fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool) !void {
        try self.functions.put(fn_decl.name.text, .{ .params = fn_decl.params, .return_type = fn_decl.return_type, .is_extern = is_extern, .error_from = error_from.hasAttr(attrs) });
        if (!is_extern and fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
        if (!is_extern) if (backendNameOverride(attrs)) |name| try self.backend_names.put(fn_decl.name.text, name);
        try self.collectFunctionSliceTypes(fn_decl);
    }

    fn collectImplTraitArtifact(self: *CEmitter, impl_trait: ast.ImplTrait) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ impl_trait.trait_name.text, impl_trait.type_name.text });
        try self.impl_methods.put(key, impl_trait.methods);
    }

    fn collectBindThunks(self: *CEmitter, module: ast.Module) anyerror!void {
        // Now that every function signature is known, scan all bodies for
        // `bind(scalar, f)` closures that need an env-widening thunk.
        for (module.decls) |decl| {
            if (decl.kind == .fn_decl) {
                if (decl.kind.fn_decl.body) |body| try self.collectBlockBindThunks(body);
            }
        }
    }

    fn emitModule(self: *CEmitter, module: ast.Module) anyerror!void {
        defer self.deinit();
        try self.collectModule(module);
        try self.emitTypePrelude(module);
        try self.emitFunctionDeclarations(module);
        try self.emitGeneratedDispatchArtifacts();
        try self.emitGlobalDefinitions(module);
        try self.emitFunctionDefinitions(module);
    }

    fn emitTypePrelude(self: *CEmitter, module: ast.Module) anyerror!void {
        try self.emitEnums();
        try self.emitPackedBitsTypes();
        try self.emitOverlayUnionTypes();
        try self.emitAggregateForwardDeclarations(module);
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
        try self.emitMmioStructTypes(module);
        // Arrays, structs, Result types, and tagged unions can embed one another
        // by value (`[N]S`, `struct { [N]S }`, `Result<S, E>`), so emit them in
        // dependency order rather than a fixed category order.
        // Value optionals `?T` join the dependency-ordered aggregate emission (a `?T`
        // typedef embeds its payload by value, and a struct/Result may embed a `?T`).
        try self.emitOrderedAggregates(module);
    }

    fn emitMmioStructTypes(self: *CEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            if (decl.kind == .struct_decl and self.mmio_structs.contains(decl.kind.struct_decl.name.text)) {
                try lower_c_mmio.emitStruct(self.mmioStructEmitContext(), decl.kind.struct_decl);
            }
        }
    }

    fn emitFunctionDeclarations(self: *CEmitter, module: ast.Module) anyerror!void {
        // Forward-declare every defined function up front so a call to a function
        // declared later in the (possibly import-merged) source resolves — MC
        // resolves calls module-wide, independent of declaration order.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fn_decl| if (fn_decl.body != null) try self.emitFunctionForwardDecl(fn_decl),
                // Extern prototypes must precede any function body that calls them;
                // an imported `extern fn` can be merged after its caller.
                .extern_fn => |fn_decl| try self.emitExternFunction(fn_decl),
                else => {},
            }
        }
    }

    fn emitGeneratedDispatchArtifacts(self: *CEmitter) !void {
        // Env-widening thunks for scalar-env closures: emit after the function
        // forward declarations (the thunks call those functions) and before any
        // body that might `bind` through one.
        try lower_c_dispatch.emitBindThunks(self.dispatchContext(), &self.bind_thunks);
        // Rodata vtable instances: one `static const VT_Trait __vt_Type_Trait = {…}`
        // per `impl Trait for Type` of an object-safe trait. Emitted after the function
        // forward declarations the initializer references.
        try lower_c_dispatch.emitVtables(self.dispatchContext(), &self.impl_methods, &self.trait_decls);
    }

    fn emitGlobalDefinitions(self: *CEmitter, module: ast.Module) anyerror!void {
        // Emit every global before any function body. MC resolves names
        // module-wide regardless of declaration order, and import-merged sources
        // can place a function ahead of a global it reads (e.g. a `const` defined
        // in an imported module). Globals are simple `static` definitions, so
        // emitting them first satisfies C's declare-before-use without needing
        // forward declarations.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| try self.emitGlobal(global),
                else => {},
            }
        }
    }

    fn emitFunctionDefinitions(self: *CEmitter, module: ast.Module) anyerror!void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fn_decl| if (fn_decl.body) |body| try self.emitFunction(fn_decl, body, decl.attrs) else try self.emitFunctionPrototype(fn_decl),
                // extern prototypes were already emitted in the forward-declaration pass.
                .extern_fn => {},
                // Trait / impl-trait carry no runtime artifact (Tier 1 is direct calls).
                .global_decl, .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn emitGlobal(self: *CEmitter, global: ast.GlobalDecl) !void {
        try emitGlobalDecl(self.globalEmitContext(), global);
    }

    // Fold a `const` global initializer to its C constant text (section 22).
    fn constGlobalCValue(self: *CEmitter, expr: ast.Expr) !?[]const u8 {
        const value = self.foldConstGlobalValue(expr) orelse return null;
        return switch (value) {
            // Values above the signed-64 range need an unsigned suffix, or C
            // reads the decimal literal as implicitly unsigned (a warning).
            .int => |n| if (n > std.math.maxInt(i64))
                try std.fmt.allocPrint(self.scratch.allocator(), "{d}ULL", .{n})
            else
                try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
            .boolean => |b| if (b) "1" else "0",
            .float => |f| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{f}),
            // Aggregate / byte-string const globals are not lowered to a C scalar here.
            .void, .tag, .bytes, .array, .@"struct" => null,
        };
    }

    fn emitConstGlobalInitializer(self: *CEmitter, ty: ast.TypeExpr, expr: ast.Expr) !bool {
        const value = self.foldConstGlobalValue(expr) orelse return false;
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitComptimeValueInitializer(value, ty);
        return true;
    }

    fn foldConstGlobalValue(self: *CEmitter, expr: ast.Expr) ?eval.ComptimeValue {
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
        self.seedConstFoldScope(&scope, &reflect_env);
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| eval.cloneComptimeValue(self.scratch.allocator(), v) catch null,
            else => null,
        };
    }

    fn seedConstFoldScope(self: *CEmitter, scope: *eval.ComptimeScope, reflect_env: *ReflectEnv) void {
        scope.funcs = &self.const_fns;
        scope.globals = &self.const_globals;
        scope.reflect = lower_c_reflect.comptimeReflectThunk;
        scope.reflect_ctx = reflect_env;
        var widths = self.const_global_widths.iterator();
        while (widths.next()) |entry| scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*);
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
            .boolean => |b| try self.out.appendSlice(self.allocator, if (b) "1" else "0"),
            .tag => |tag| {
                const enum_name = self.enumNameForType(resolved) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "{s}_{s}", .{ enum_name, tag });
            },
            .array => |items| try self.emitComptimeArrayInitializer(items, resolved),
            .@"struct" => |fields| try self.emitComptimeStructInitializer(fields, resolved),
            .float => |f| try self.out.print(self.allocator, "{d}", .{f}),
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
        if (n > std.math.maxInt(i64)) {
            try self.out.print(self.allocator, "{d}ULL", .{n});
        } else {
            try self.out.print(self.allocator, "{d}", .{n});
        }
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
    fn emitAggregateForwardDeclarations(self: *CEmitter, module: ast.Module) !void {
        try lower_c_defs.emitAggregateForwardDeclarations(self.defsContext(), module, &self.structs, &self.tagged_unions, &self.array_types, &self.result_types);
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
    fn emitOrderedAggregates(self: *CEmitter, module: ast.Module) !void {
        const arena = self.scratch.allocator();
        var units: std.ArrayList(AggregateEmitUnit) = .empty;
        defer units.deinit(arena);

        for (module.decls) |decl| switch (decl.kind) {
            .struct_decl => |s| if (self.structs.contains(s.name.text)) try units.append(arena, .{ .struct_decl = s }),
            .union_decl => |u| if (self.tagged_unions.contains(u.name.text)) try units.append(arena, .{ .tagged_union = u }),
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
            .emit_unchecked_add_value_temp = emitUncheckedAddValueTempForAggregate,
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
        try lower_c_attr.emitFunctionAttrs(self.allocator, self.out, attrs);
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
        self.current_function = fn_decl.name.text;
        defer self.current_function = previous_function;

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
        const asm_stmt = ast_query.nakedAsmStmt(body) orelse return error.UnsupportedCEmission;
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
    // temporaries; only C reserved words are rewritten (e.g. `int` -> `int_`).
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
        return lower_c_alias.resolveAliasType(&self.type_aliases, ty);
    }

    fn aliasTargetType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return lower_c_alias.aliasTargetType(&self.type_aliases, ty);
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

    fn constGlobalCValueForGlobal(ctx: *anyopaque, expr: ast.Expr) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.constGlobalCValue(expr);
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
            .c_type = cTypeForCall,
            .c_ident = cIdentForMmio,
            .mmio_access = mmioAccessForMmio,
            .value_c_type = valueCTypeForMmio,
            .emit_sequenced_arg_temp = emitSequencedArgTempForCall,
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
            .mmio_structs = &self.mmio_structs,
            .packed_bits = &self.packed_bits,
            .emit_ctx = self,
            .c_ident = cIdentForMmio,
        };
    }

    fn mmioReplacementEmitContext(self: *CEmitter) lower_c_mmio.ReplacementEmitContext {
        return .{
            .allocator = self.allocator,
            .scratch = self.scratch.allocator(),
            .out = self.out,
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
            .c_type = cTypeForCall,
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
        };
    }

    fn sequencedArgContext(self: *CEmitter) lower_c_call.TempContext {
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
            .emit_arg_temp = emitSequencedArgTempForCall,
            .c_type = cTypeForCall,
            .c_ident = cIdentForCall,
            .expr_source_type = exprSourceTypeForCall,
            .local_info_from_type = localInfoFromTypeForArith,
            .global_assignment_target = globalAssignmentTargetForArith,
            .emit_assign_target = emitAssignTargetForArith,
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
            .globals = &self.globals,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .operand_emit_type = operandEmitTypeForAtomic,
            .expr_is_pointer = exprIsPointerForAtomic,
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
            .expr_source_type = exprSourceTypeForCall,
            .numeric_expr_type = numericExprTypeForConvert,
            .underlying_int_type_name = underlyingIntTypeNameForConvert,
            .result_type_name = resultTypeNameForConvert,
        };
    }

    fn domainContext(self: *CEmitter) lower_c_domain.Context {
        return .{
            .allocator = self.allocator,
            .out = self.out,
            .type_aliases = &self.type_aliases,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .result_type_name = resultTypeNameForConvert,
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
            .numeric_expr_type = numericExprTypeForConvert,
            .underlying_int_type_name = underlyingIntTypeNameForConvert,
            .result_type_name = resultTypeNameForConvert,
            .mir_check_elided = mirCheckElidedForArith,
            .has_mir_no_overflow_range_fact = hasMirNoOverflowRangeFactForArith,
            .local_info_from_type = localInfoFromTypeForArith,
            .operand_emit_type = operandEmitTypeForArith,
            .global_assignment_target = globalAssignmentTargetForArith,
            .emit_assign_target = emitAssignTargetForArith,
        };
    }

    fn builtinEmitContext(self: *CEmitter) lower_c_builtin_emit.Context {
        return .{
            .enum_ctx = self,
            .enum_name_for_value_expr = enumNameForValueExprForBuiltin,
            .emit_expr = emitExprForCall,
            .enums = &self.enums,
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
            .type_aliases = &self.type_aliases,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForMemory,
            .c_type = cTypeForCall,
            .slice_type_name = sliceTypeNameForMemory,
            .c_ident = cIdentForMemory,
            .operand_emit_type = operandEmitTypeForMemory,
            .expr_source_type = exprSourceTypeForMemory,
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
            .loop_defer_marks = &self.loop_defer_marks,
            .emit_ctx = self,
            .emit_expr = emitExprForCall,
            .emit_expr_with_target = emitExprWithTargetForArith,
            .emit_block_items = emitBlockItemsForFlow,
            .local_info_from_type = localInfoFromTypeForFlow,
            .array_len_text = arrayLenTextForFlow,
            .array_type_for_expr = arrayTypeForFlow,
            .iterable_type_for_expr = iterableTypeForFlow,
            .slice_return_type_for_expr = sliceReturnTypeForFlow,
            .array_return_type_for_expr = arrayReturnTypeForFlow,
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
            .raw_many_offset_expr_type = rawManyOffsetExprTypeForAccess,
            .slice_return_type_for_call = sliceReturnTypeForAccess,
            .array_return_type_for_expr = arrayReturnTypeForAccess,
            .array_len_text = arrayLenTextForAccess,
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
            .result_type_for_expr = resultTypeForSwitch,
            .tagged_union_type_for_expr = taggedUnionTypeForSwitch,
            .nullable_type_for_expr = nullableTypeForSwitch,
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
            .operand_emit_type = operandEmitTypeForAtomic,
            .expr_resolves_to_float = exprResolvesToFloatForExpr,
            .is_value_optional = isValueOptionalForExpr,
        };
    }

    fn isValueOptionalForExpr(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const ty = self.nullableTypeForExpr(expr, locals) orelse return false;
        const resolved = self.resolveAliasType(ty);
        if (resolved.kind != .nullable) return false;
        return lower_c_type.nullablePayloadIsValueType(&self.type_aliases, resolved.kind.nullable.*);
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
            .result_type_for_expr = resultTypeForTry,
            .nullable_inner_c_type_for_expr = nullableInnerCTypeForTry,
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

    fn enumNameForValueExprForBuiltin(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.enumNameForValueExpr(expr, locals);
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

    fn exprSourceTypeForCall(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprSourceTypeForEmission(expr, locals);
    }

    fn emitBlockItemsForFlow(ctx: *anyopaque, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitBlockItems(block, locals, return_ty);
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

    fn resultTypeForSwitch(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const local_set = locals orelse return null;
        return self.resultTypeForExpr(expr, local_set);
    }

    fn taggedUnionTypeForSwitch(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.taggedUnionTypeForExpr(expr, locals);
    }

    fn nullableTypeForSwitch(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.nullableTypeForExpr(expr, locals);
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

    fn arrayTypeForFlow(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayTypeForExpr(expr, locals);
    }

    fn iterableTypeForFlow(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.iterableTypeForExpr(expr, locals);
    }

    fn sliceReturnTypeForFlow(ctx: *anyopaque, expr: ast.Expr) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        const call = callExpr(expr) orelse return null;
        return self.sliceReturnTypeForCall(call);
    }

    fn arrayReturnTypeForFlow(ctx: *anyopaque, expr: ast.Expr) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayReturnTypeForExpr(expr);
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
        return lower_c_aggregate.emitUncheckedAddAggregateCallArgTemp(self.aggregateEmitContext(), arg, locals, target_ty);
    }

    fn emitUncheckedAddValueTempForAggregate(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.emitUncheckedAddValueTemp(expr, locals, target_ty, range_target);
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

    fn resultTypeForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.resultTypeForExpr(expr, locals);
    }

    fn nullableInnerCTypeForTry(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?[]const u8 {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return try self.nullableInnerCTypeForExpr(expr, locals);
    }

    fn emitDeferredCleanupsForTry(ctx: *anyopaque, locals: *std.StringHashMap(LocalInfo), return_ty: ast.TypeExpr) anyerror!void {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        try self.emitDeferredCleanupsFrom(0, locals, return_ty);
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

    fn sliceReturnTypeForAccess(ctx: *anyopaque, call: ast_query.CallExpr) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.sliceReturnTypeForCall(call);
    }

    fn arrayReturnTypeForAccess(ctx: *anyopaque, expr: ast.Expr) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.arrayReturnTypeForExpr(expr);
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

    fn operandEmitTypeForMemory(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.operandEmitType(expr, locals);
    }

    fn exprSourceTypeForMemory(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprSourceTypeForEmission(expr, locals);
    }

    fn rawManyOffsetExprTypeForAccess(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.rawManyOffsetExprTypeForEmission(expr, locals);
    }

    fn mmioAccessForMmio(ctx: *anyopaque, callee: ast.Expr, args: []ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
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
                    if (!self.opt_types.contains(name)) {
                        try self.opt_types.put(name, .{ .name = name, .payload_ty = payload });
                    }
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

    // The closure type of a callee expression, if it is closure-typed (so its call
    // dispatches through the {code, env} pair). Resolves through aliases.
    fn closureCalleeType(self: *CEmitter, callee: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const ty = self.operandEmitType(callee, locals) orelse return null;
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

    fn collectBlockBindThunks(self: *CEmitter, block: ast.Block) anyerror!void {
        try lower_c_collect.collectBlockBindThunks(.{
            .name_allocator = self.scratch.allocator(),
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .bind_thunks = &self.bind_thunks,
        }, block);
    }

    // Emit `bind(&env, f)` as a closure compound literal. `f` names a function whose
    // first parameter is the (typed) env; the closure drops it to void*.
    fn emitBind(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) !void {
        const plan = try self.bindEmitPlan(node);
        if (!self.bindEnvIsPointerLike(plan.info.params[0].ty)) {
            try lower_c_dispatch.emitScalarEnvBind(self.dispatchContext(), node, locals, plan);
            return;
        }
        try lower_c_dispatch.emitPointerEnvBind(self.dispatchContext(), node, locals, plan);
    }

    fn bindEmitPlan(self: *CEmitter, node: anytype) !lower_c_dispatch.BindEmitPlan {
        const fname = calleeIdentName(node.args[1]) orelse return error.UnsupportedCEmission;
        const info = self.functions.get(fname) orelse return error.UnsupportedCEmission;
        if (info.params.len == 0) return error.UnsupportedCEmission; // need the env param
        const ret_ty: ast.TypeExpr = info.return_type orelse ast.TypeExpr{ .span = node.callee.*.span, .kind = .{ .name = .{ .text = "void", .span = node.callee.*.span } } };
        const cname = try lower_c_names.closureTypeNameForParams(self.typeNameContext(), ret_ty, info.params[1..]);
        return .{
            .fname = fname,
            .info = info,
            .ret_ty = ret_ty,
            .cname = cname,
        };
    }

    // If `callee` is `d.method` where `d` has a `*dyn Trait` type, return the trait name;
    // such a call dispatches through the vtable. Null otherwise.
    fn dynCalleeTrait(self: *CEmitter, callee: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        const member = memberExpr(callee) orelse return null;
        const base_ty = self.operandEmitType(member.base.*, locals) orelse self.exprSourceTypeForEmission(member.base.*, locals) orelse return null;
        return switch (self.resolveAliasType(base_ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            else => null,
        };
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
                try self.emitAssignmentStmt(node, locals, return_ty);
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
            try locals.put(name.text, try self.localDeclInfo(local, is_let, locals));
            if (try self.emitSpecialLocalDecl(name.text, local, locals, return_ty)) continue;
            try self.emitDefaultLocalDecl(name.text, local.ty, local.init, locals);
        }
    }

    fn localDeclInfo(self: *CEmitter, local: ast.LocalDecl, is_let: bool, locals: *std.StringHashMap(LocalInfo)) !LocalInfo {
        var info = if (local.ty) |decl_ty| try self.localInfoFromType(decl_ty) else LocalInfo{};
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
        return try self.emitSpecialInferredLocalInit(name, initializer, locals);
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
        if (try lower_c_aggregate.emitUncheckedAddAggregateLocalInit(self.aggregateEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_flow.emitSequencedComparisonLocalInit(self.flowEmitContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_arith.emitSequencedCheckedBinaryLocalInit(self.sequencedBinaryContext(), name, decl_ty, initializer, locals)) return true;
        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, decl_ty, initializer, locals)) return true;
        return false;
    }

    fn emitSpecialInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
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
        if (try lower_c_arith.emitUncheckedAddInferredLocalInit(self.arithContext(), name, initializer, locals)) return true;
        if (try self.emitLocalCopyInferredLocalInit(name, initializer, locals)) return true;
        if (try lower_c_flow.emitBoolInferredLocalInit(self.flowEmitContext(), name, initializer, locals)) return true;
        if (try self.emitCallInferredLocalInit(name, initializer, locals)) return true;
        if (try self.emitNumericInferredLocalInit(name, initializer, locals)) return true;
        if (try lower_c_mmio.emitDirectReadInferredLocalInitExpr(self.mmioEmitContext(), name, initializer, locals)) return true;
        if (try lower_c_mmio.emitReadExprInferredLocalInit(self.mmioCallEmitContext(), name, initializer, locals)) return true;
        return false;
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
        } else if (maybe_ty != null and maybe_ty.?.kind == .array) {
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

    fn emitAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (try self.emitSpecialAssignmentStmt(assignment, locals, return_ty)) return;
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
        if (try lower_c_aggregate.emitUncheckedAddAggregateAssignmentStmt(self.aggregateEmitContext(), assignment, locals)) return true;
        if (try lower_c_arith.emitUncheckedAddAssignmentStmt(self.arithContext(), assignment, locals)) return true;
        if (try lower_c_flow.emitSequencedComparisonAssignmentStmt(self.flowEmitContext(), assignment, locals)) return true;
        if (try lower_c_arith.emitSequencedCheckedBinaryAssignmentStmt(self.sequencedBinaryContext(), assignment, locals)) return true;
        if (try lower_c_call.emitSequencedCallAssignmentStmt(self.sequencedArgContext(), &self.functions, assignment, locals)) return true;
        return false;
    }

    fn emitDefaultAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try appendGlobalStorePrefix(self.allocator, self.out, target);
            // Pass the global's type as the value target, so a struct-literal value
            // (`g = .{ … }`) lowers to a typed compound literal like the non-global
            // path; scalars/pointers are unaffected by the extra type hint.
            try self.emitExprWithTarget(assignment.value, locals, simpleNameType(target.info.type_name, assignment.value.span));
            try appendGlobalStoreSuffix(self.allocator, self.out, target);
        } else {
            try self.emitAssignTarget(assignment.target, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitExprWithTarget(assignment.value, locals, self.operandEmitType(assignment.target, locals));
            try self.out.appendSlice(self.allocator, ";\n");
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
        if (try lower_c_aggregate.emitUncheckedAddAggregateReturn(self.aggregateEmitContext(), expr, locals, return_ty)) return true;
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
        if (try lower_c_call.emitSequencedCallExprStmt(self.sequencedArgContext(), &self.functions, expr, locals)) return;
        try self.writeIndent();
        try self.emitExpr(expr, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitAssertStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        if (try lower_c_mmio.emitReadAssert(self.mmioCallEmitContext(), expr, locals)) return;
        if (try lower_c_flow.emitSequencedConditionAssert(self.flowEmitContext(), expr, locals)) return;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "if (!(");
        try self.emitExpr(expr, locals);
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
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "{\n");
        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        self.indent += 1;
        try self.emitBlockItems(block, &nested, return_ty);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitLoopStmt(self: *CEmitter, stmt: ast.Stmt, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (loop.kind == .@"while") {
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
        try lower_c_flow.emitPlainWhileLoop(self.flowEmitContext(), loop, locals, return_ty, self.defer_stack.items.len);
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
        const block_start = self.defer_stack.items.len;

        for (block.items) |stmt| {
            switch (try self.emitBlockControlItem(stmt, locals, return_ty, block_start)) {
                .skip_stmt => continue,
                .exit_block => return,
                .emit_stmt => {},
            }
            try self.emitStmt(stmt, locals, return_ty);
        }

        try self.emitDeferredCleanupsFrom(block_start, locals, return_ty);
        self.defer_stack.items.len = block_start;
    }

    const BlockItemAction = enum {
        emit_stmt,
        skip_stmt,
        exit_block,
    };

    fn emitBlockControlItem(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, block_start: usize) anyerror!BlockItemAction {
        switch (stmt.kind) {
            .@"defer" => |expr| {
                try self.emitBlockDeferItem(expr);
                return .skip_stmt;
            },
            .@"return" => {
                try self.emitBlockExitItem(stmt, locals, return_ty, block_start, 0);
                return .exit_block;
            },
            .@"break" => |target| {
                const mark = self.loopDeferMarkFor(target, block_start);
                try self.emitBlockExitItem(stmt, locals, return_ty, block_start, mark);
                return .exit_block;
            },
            .@"continue" => |target| {
                const mark = self.loopDeferMarkFor(target, block_start);
                try self.emitBlockExitItem(stmt, locals, return_ty, block_start, mark);
                return .exit_block;
            },
            else => return .emit_stmt,
        }
    }

    fn emitBlockDeferItem(self: *CEmitter, expr: ast.Expr) !void {
        self.defer_stack.append(self.allocator, expr) catch return error.OutOfMemory;
    }

    // The defer-stack mark from which a `break`/`continue` must run cleanups. A LABELED jump
    // (`break :outer`) unwinds every loop from the innermost up to AND INCLUDING the targeted
    // loop, so cleanup starts at the TARGET loop's mark (running the inner loops' and the target's
    // body defers). A bare jump targets the innermost loop (its mark = the top of the stack). This
    // mirrors `resolveLoopIndex` in lower_c_flow.zig, which emits the matching `goto`; sema rejects
    // unknown labels, so a labeled target always resolves.
    fn loopDeferMarkFor(self: *CEmitter, target: ?ast.Ident, block_start: usize) usize {
        if (target) |t| {
            var i = self.loop_labels.items.len;
            while (i > 0) {
                i -= 1;
                if (self.loop_labels.items[i]) |lbl| {
                    if (std.mem.eql(u8, lbl, t.text)) return self.loop_defer_marks.items[i];
                }
            }
        }
        return self.loop_defer_marks.getLastOrNull() orelse block_start;
    }

    fn emitBlockExitItem(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, block_start: usize, cleanup_start: usize) anyerror!void {
        try self.emitDeferredCleanupsFrom(cleanup_start, locals, return_ty);
        try self.emitStmt(stmt, locals, return_ty);
        self.defer_stack.items.len = block_start;
    }

    // Emit the active defers from index `start` to the top of the stack, in reverse
    // (innermost first). Only reads the stack — callers truncate it when a scope ends — so
    // an exit edge such as `?` that does not pop the scope (the ok path continues) leaves
    // the active defers intact.
    fn emitDeferredCleanupsFrom(self: *CEmitter, start: usize, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        var index = self.defer_stack.items.len;
        while (index > start) {
            index -= 1;
            try self.emitDeferredCleanup(self.defer_stack.items[index], locals, return_ty);
        }
    }

    fn emitDeferredCleanup(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        try self.writeLineDirective(expr.span);
        switch (expr.kind) {
            .block => |block| try self.emitBracedBlockBody(block, locals, return_ty),
            else => try self.emitDeferredExpressionCleanup(expr, locals, return_ty),
        }
    }

    fn emitDeferredExpressionCleanup(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (try self.emitNeverExprStmt(expr, locals)) return;
        if (try lower_c_mmio.emitWriteStmt(self.mmioEmitContext(), expr, locals)) return;
        if (try self.emitRawStoreStmt(expr, locals)) return;
        if (try self.emitCpuPauseStmt(expr)) return;
        if (try self.emitFenceStmt(expr)) return;
        if (try lower_c_try.emitResultTryExprStmt(self.tryStmtEmitContext(), expr, locals, return_ty)) return;
        if (try lower_c_try.emitNullableTryExprStmt(self.tryStmtEmitContext(), expr, locals)) return;
        if (try lower_c_mmio.emitReadExprStmt(self.mmioCallEmitContext(), expr, locals)) return;
        if (try lower_c_call.emitSequencedCallExprStmt(self.sequencedArgContext(), &self.functions, expr, locals)) return;
        try self.writeIndent();
        try self.emitExpr(expr, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn writeIndent(self: *CEmitter) !void {
        for (0..self.indent) |_| try self.out.appendSlice(self.allocator, "    ");
    }

    fn writeLineDirective(self: *CEmitter, span: ast.Span) !void {
        try appendLineDirective(self.allocator, self.out, self.source_path, span);
    }

    fn writeUnsupportedStmt(self: *CEmitter, stmt: ast.Stmt) !void {
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

    fn emitSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (try self.emitResultSwitch(node, locals, return_ty)) return;
        if (try self.emitTaggedUnionSwitch(node, locals, return_ty)) return;
        if (try self.emitNullableSwitch(node, locals, return_ty)) return;
        if (try self.emitEnumCallSwitch(node, locals, return_ty)) return;

        try self.emitGenericSwitchWithMmioSubjectHoists(node, locals, return_ty);
    }

    fn emitEnumCallSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const enum_ty = self.enumReturnTypeForExpr(node.subject) orelse return false;
        const temp = try self.emitSequencedCallArgTemp(node.subject, locals, enum_ty);

        var switch_locals = try cloneLocals(self.allocator, locals.*);
        defer switch_locals.deinit();
        try switch_locals.put(temp.name, try self.localInfoFromType(enum_ty));
        const temp_subject = ast.Expr{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span };
        try self.emitGenericSwitch(.{ .subject = temp_subject, .arms = node.arms }, &switch_locals, return_ty, &[_]MmioReadReplacement{});
        return true;
    }

    fn emitGenericSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_replacements: []const MmioReadReplacement) anyerror!void {
        const subject_enum_name = self.enumNameForExpr(node.subject, locals);
        const subject_is_bool = self.exprIsBoolForEmission(node.subject, locals);
        try lower_c_switch.emitGenericSwitch(self.switchEmitContext(), .{
            .node = node,
            .locals = locals,
            .return_ty = return_ty,
            .subject_enum_name = subject_enum_name,
            .subject_is_bool = subject_is_bool,
            .subject_replacements = subject_replacements,
        });
    }

    fn emitGenericSwitchWithMmioSubjectHoists(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const subject_enum_name = self.enumNameForExpr(node.subject, locals);
        const subject_is_bool = self.exprIsBoolForEmission(node.subject, locals);
        try lower_c_switch.emitGenericSwitchWithMmioSubjectHoists(self.switchEmitContext(), self.mmioEmitContext(), .{
            .node = node,
            .locals = locals,
            .return_ty = return_ty,
            .subject_enum_name = subject_enum_name,
            .subject_is_bool = subject_is_bool,
            .subject_replacements = &[_]MmioReadReplacement{},
        });
    }

    fn emitResultSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = (try lower_c_switch.resultSubjectForValueExpr(self.switchEmitContext(), node.subject, locals)) orelse return false;
        return lower_c_switch.emitResultSwitch(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitNullableSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = if (try lower_c_switch.nullableSubjectForExpr(self.switchEmitContext(), node.subject, locals)) |subject|
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
            .call => self.nullableReturnTypeForExpr(expr),
            .cast => |node| node.ty.*,
            .grouped => |inner| self.nullableTypeForExpr(inner.*, locals),
            else => self.operandEmitType(expr, locals) orelse self.exprSourceTypeForEmission(expr, locals),
        };
    }

    fn taggedUnionReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return lower_c_infer.taggedUnionReturnTypeForExpr(self.inferTypeContext(), expr);
    }

    fn taggedUnionTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.taggedUnionTypeForExpr(self.inferTypeContext(), expr, locals);
    }

    fn emitForLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const header = try lower_c_flow.forLoopHeader(self.flowEmitContext(), loop);
        const binding = header.binding;
        const iterable = header.iterable;
        if (try lower_c_flow.emitForLoopSequencedIterable(self.flowEmitContext(), loop, iterable, locals, return_ty)) return;
        if (try lower_c_flow.emitForLoopCallIterable(self.flowEmitContext(), loop, iterable, locals, return_ty)) return;
        const element = try lower_c_flow.forLoopElementPlan(self.flowEmitContext(), iterable, locals);
        try lower_c_flow.emitForLoopWithElementPlan(self.flowEmitContext(), loop, binding, iterable, locals, return_ty, element, self.defer_stack.items.len);
    }

    fn iterableTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const ty = self.operandEmitType(expr, locals) orelse self.exprSourceTypeForEmission(expr, locals) orelse return null;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .array, .slice => ty,
            else => null,
        };
    }

    fn emitIfLet(self: *CEmitter, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (node.pattern.kind == .tag_bind) {
            const subject = (try lower_c_switch.resultSubjectForValueExpr(self.switchEmitContext(), node.value, locals)) orelse {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported result if-let value: {s} */\n", .{@tagName(node.value.kind)});
                return error.UnsupportedCEmission;
            };
            return lower_c_switch.emitResultIfLet(self.switchEmitContext(), node, locals, return_ty, subject);
        }

        const subject = (try lower_c_switch.nullableSubjectForExpr(self.switchEmitContext(), node.value, locals)) orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let value: {s} */\n", .{@tagName(node.value.kind)});
            return error.UnsupportedCEmission;
        };
        try lower_c_switch.emitNullableIfLet(self.switchEmitContext(), node, locals, return_ty, subject);
    }

    fn emitNeverExprStmt(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "mc_trap_Unreachable();\n");
                return true;
            },
            .call => |node| {
                if (trapHelperForCall(node)) |helper| {
                    try self.writeIndent();
                    try self.out.print(self.allocator, "{s}();\n", .{helper});
                    return true;
                }
                return false;
            },
            .grouped => |inner| return try self.emitNeverExprStmt(inner.*, locals),
            else => return false,
        }
    }

    fn emitRawStoreStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = callExpr(expr) orelse return false;
        if (!isRawStoreCall(call.callee.*)) return false;
        if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedCEmission;

        const addr_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, simpleNameType("PAddr", call.args[0].span));
        const value_temp = try self.emitSequencedCallArgTemp(call.args[1], locals, call.type_args[0]);
        try self.writeIndent();
        if (typeName(call.type_args[0])) |type_name| {
            if (rawScalarSuffix(type_name)) |suffix| {
                try self.out.print(self.allocator, "mc_raw_store_{s}({s}, {s});\n", .{ suffix, addr_temp.name, value_temp.name });
                return true;
            }
        }
        // Aggregate (non-scalar) T: whole-object typed store, mirroring how
        // `raw.ptr<T>(addr)` + deref already lowers a struct assignment.
        try self.out.print(self.allocator, "*({s} *){s} = {s};\n", .{ try self.cTypeFor(call.type_args[0], .typedef_name), addr_temp.name, value_temp.name });
        return true;
    }

    fn emitCpuPauseStmt(self: *CEmitter, expr: ast.Expr) !bool {
        const call = callExpr(expr) orelse return false;
        if (!isCpuPauseCall(call.callee.*)) return false;
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
        const helper = fenceHelperForCall(call.callee.*) orelse return false;
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

    // Emit an assignment LHS (a store target / lvalue). Identical to emitExpr but with the
    // field-LOAD shadow hook suppressed: wrapping an lvalue in a `(hook(...), lv)` comma
    // expression would make it non-assignable. (Pointer/local field STORES are therefore
    // uninstrumented on this path — at parity with the LLVM backend, which hooks only GLOBAL
    // field/array stores.)
    fn emitAssignTarget(self: *CEmitter, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const prev = self.suppress_load_hook;
        self.suppress_load_hook = true;
        defer self.suppress_load_hook = prev;
        try self.emitExpr(target, locals);
    }

    fn emitExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| try self.emitIdentExpr(ident, locals),
            .int_literal, .float_literal, .char_literal, .bool_literal, .null_literal, .void_literal => try self.emitScalarLiteralExpr(expr),
            .array_literal => try self.emitUnsupportedTargetlessAggregateExpr("array"),
            .struct_literal => try self.emitUnsupportedTargetlessAggregateExpr("struct"),
            .grouped => |inner| try self.emitGroupedExpr(inner.*, locals),
            .unreachable_expr => try self.out.appendSlice(self.allocator, "mc_trap_Unreachable()"),
            .unary => try lower_c_expr.emitUnaryExpr(self.exprEmitContext(), expr, locals),
            .binary => try lower_c_expr.emitBinaryExpr(self.exprEmitContext(), expr, locals),
            .call => |node| try self.emitCallExpr(node, locals),
            .index => |node| try self.emitIndexExpr(node, locals),
            .slice => |node| try self.emitSliceExpr(node, expr.span, locals),
            .address_of => |inner| try self.emitAddressOfExpr(inner.*, locals),
            .deref => |inner| try self.emitDerefExpr(inner.*, locals),
            .member => |node| try self.emitMemberExprOrFallback(node, locals),
            .cast => |node| try self.emitCastExpr(node, locals),
            else => try self.emitUnsupportedExpr(expr),
        }
    }

    fn emitUnsupportedTargetlessAggregateExpr(self: *CEmitter, kind: []const u8) !void {
        try self.out.print(self.allocator, "/* unsupported targetless {s} literal */0", .{kind});
        return error.UnsupportedCEmission;
    }

    fn emitCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (try self.emitSpecialCallExpr(node, locals)) return;
        try self.emitDefaultCallExpr(node, locals);
    }

    fn emitMemberExprOrFallback(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (try self.emitMemberExpr(node, locals)) return;
    }

    fn emitUnsupportedExpr(self: *CEmitter, expr: ast.Expr) !void {
        try self.out.print(self.allocator, "/* unsupported expr: {s} */0", .{@tagName(expr.kind)});
        return error.UnsupportedCEmission;
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

    fn emitDerefExpr(self: *CEmitter, inner: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.appendSlice(self.allocator, "*");
        try self.emitExpr(inner, locals);
    }

    fn emitCastExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
        try self.emitExpr(node.value.*, locals);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        if (locals) |local_set| {
            if (try self.emitOverlayIndexReadExpr(node, local_set)) return;
        }
        if (globalArrayElementAccess(node, locals, &self.globals)) |access| {
            try lower_c_global.emitGlobalArrayElementLoadExpr(self.globalArrayAccessEmitContext(), access, locals);
        } else if (self.sliceAccessForBase(node.base.*, locals)) |slice| {
            try self.emitSliceIndexExpr(node, locals, slice);
        } else if (self.arrayTypeForExpr(node.base.*, locals)) |base_arr| {
            try self.emitArrayIndexExpr(node, locals, base_arr);
        } else {
            try self.emitExpr(node.base.*, locals);
            try self.out.appendSlice(self.allocator, "[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
        }
    }

    fn emitSliceIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), slice: SliceAccess) anyerror!void {
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
        try self.emitExpr(node.index.*, locals);
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
    }

    fn emitArrayIndexExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), base_arr: ast.TypeExpr) anyerror!void {
        try self.emitExpr(node.base.*, locals);
        if (self.mirCheckElided(node.index.span)) {
            try self.out.appendSlice(self.allocator, ".elems[");
            try self.emitExpr(node.index.*, locals);
            try self.out.appendSlice(self.allocator, "]");
            return;
        }
        try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
        try self.emitExpr(node.index.*, locals);
        const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
        try self.out.print(self.allocator, ", {s})]", .{len});
    }

    fn emitMemberExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        if (try self.emitEnumVariantPath(node, locals)) return true;
        if (try self.emitPackedBitsMember(node, locals)) return true;
        if (locals) |local_set| {
            if (try self.emitOverlayMemberReadExpr(node, local_set)) return true;
        }
        if (try self.emitGlobalArrayElementMemberLoadExpr(node, locals)) return true;
        if (lower_c_global.globalMemberAccess(self.globalAccessContext(), node, locals)) |access| {
            try appendGlobalLoadExpr(self.allocator, self.out, access.name, access.info);
            return true;
        }
        try self.emitOrdinaryMemberLoadExpr(node, locals);
        return true;
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
        const op: []const u8 = if (self.exprIsPointer(node.base.*, locals)) "->" else ".";
        const field_name = try self.cIdent(node.name.text);
        if (self.ordinaryLoadHookName()) |hook| {
            try self.emitHookedMemberLoadExpr(node, locals, hook, op, field_name);
            return;
        }
        try self.emitExpr(node.base.*, locals);
        try self.out.print(self.allocator, "{s}{s}", .{ op, field_name });
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
        if (try lower_c_aggregate.emitQualifiedUnionConstructor(self.aggregateEmitContext(), node, locals)) return true;
        if (try self.emitNamedSpecialCallExpr(node, locals)) return true;
        // Tier 2 dynamic dispatch: `d.method(args)` through a `*dyn Trait` ->
        // `d.vtable->method(d.data, args)` (a genuine load-through-vtable call).
        if (self.dynCalleeTrait(node.callee.*, locals)) |trait_name| {
            try lower_c_dispatch.emitDynDispatch(self.dispatchContext(), node, trait_name, locals);
            return true;
        }
        // Calling a closure-typed value: `c(args)` -> `c.code(c.env, args)`.
        if (self.closureCalleeType(node.callee.*, locals)) |clos| {
            try lower_c_dispatch.emitClosureCall(self.dispatchContext(), node, clos, locals);
            return true;
        }
        if (try lower_c_call.emitRawAddressCall(self.callContext(), node, locals)) return true;
        if (try lower_c_call.emitVaCall(self.callContext(), node, locals)) return true;
        if (try lower_c_builtin_emit.emitBuiltinCallExpr(self.builtinEmitContext(), node, locals)) return true;
        return false;
    }

    fn emitNamedSpecialCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        const name = calleeIdentName(node.callee.*) orelse return false;
        // `drop(x)` and `forget_unchecked(x)` both evaluate and discard the
        // operand (linearity is a compile-time check). The difference is in the
        // checker: `forget_unchecked` is the only one legal on a resource.
        if (try lower_c_call.emitNamedDiscardCall(self.callContext(), node, locals)) return true;
        // `bind(&env, f)` builds a closure: a {code, env} fat value. The
        // env pointer is type-erased to void* and the function pointer
        // (whose first param is the typed env) is cast to take void* —
        // both casts are ABI-identity, so user code stays typed/cast-free.
        if (std.mem.eql(u8, name, "bind") and node.args.len == 2) {
            try self.emitBind(node, locals);
            return true;
        }
        return false;
    }

    fn emitDefaultCallExpr(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        const fn_info = if (calleeIdentName(node.callee.*)) |name| self.functions.get(name) else null;
        try self.emitExpr(node.callee.*, locals);
        try self.out.appendSlice(self.allocator, "(");
        for (node.args, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
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
        try self.emitAddressOperand(node.base.*, locals);
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

    // Payload type name of an `atomic<T>` local referenced by `expr`, or null
    // if `expr` is not such a local.
    fn atomicLocalPayload(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return lower_c_atomic.atomicLocalPayload(self.atomicEmitContext(), expr, locals);
    }

    fn emitExprWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        if (try self.emitValueOptionalCoercion(expr, locals, target_ty)) return;
        if (try self.emitTargetPreludeExpr(expr, locals, target_ty)) return;
        switch (expr.kind) {
            .array_literal, .struct_literal => try self.emitAggregateLiteralWithTarget(expr, locals, target_ty),
            .binary, .unary => try self.emitArithmeticExprWithTarget(expr, locals, target_ty),
            .call => |node| try self.emitTargetCallExpr(node, locals, target_ty, expr),
            .enum_literal => |literal| try self.emitEnumLiteralWithTarget(literal, target_ty),
            .string_literal => |literal| try self.emitStringLiteralWithTarget(literal, target_ty),
            .grouped => |inner| try self.emitGroupedExprWithTarget(inner.*, locals, target_ty),
            .address_of => try self.emitAddressOfExprWithTarget(expr, locals, target_ty),
            else => try self.emitExpr(expr, locals),
        }
    }

    // Coerce a `null` (absent) or a payload value (present) into a value optional `?T`'s
    // tagged aggregate. A source that already yields `?T` (another optional local / a call
    // returning `?T`) is left to the normal path (pass-through, no double-wrap).
    fn emitValueOptionalCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        const resolved = self.resolveAliasType(ty);
        if (resolved.kind != .nullable) return false;
        const child = resolved.kind.nullable.*;
        if (!lower_c_type.nullablePayloadIsValueType(&self.type_aliases, child)) return false;
        const opt_name = try self.cTypeFor(resolved, .typedef_name);
        if (expr.kind == .null_literal) {
            try self.out.print(self.allocator, "({s}){{ .present = false }}", .{opt_name});
            return true;
        }
        // Pass-through: the source already produces the optional aggregate.
        if (self.nullableTypeForExpr(expr, locals)) |src_ty| {
            if (self.resolveAliasType(src_ty).kind == .nullable) return false;
        }
        try self.out.print(self.allocator, "({s}){{ .present = true, .value = ", .{opt_name});
        try self.emitExprWithTarget(expr, locals, child);
        try self.out.appendSlice(self.allocator, " }");
        return true;
    }

    fn emitAggregateLiteralWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        const target = target_ty orelse return error.UnsupportedCEmission;
        switch (expr.kind) {
            .array_literal => |items| try lower_c_aggregate.emitArrayLiteral(self.aggregateEmitContext(), items, locals, target),
            .struct_literal => |fields| {
                if (try lower_c_aggregate.emitPackedBitsLiteral(self.aggregateEmitContext(), fields, locals, target)) return;
                try lower_c_aggregate.emitStructLiteral(self.aggregateEmitContext(), fields, locals, target);
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
        if (target_ty) |ty| {
            if (try lower_c_aggregate.emitResultConstructor(self.aggregateEmitContext(), node, locals, ty)) return;
            if (try lower_c_aggregate.emitTaggedUnionConstructor(self.aggregateEmitContext(), node, locals, ty)) return;
        }
        try self.emitExpr(expr, locals);
    }

    fn emitTargetPreludeExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool {
        const ty = target_ty orelse return false;
        // f32 target: compute the float expression in `float`, not `double`. A bare C decimal
        // literal is `double`, so `1.7 * 2.3` would multiply in double and round twice when
        // narrowed to f32 — diverging ~1 ULP from the LLVM `fmul`. Suffix f32 literals with `f`.
        if (typeName(self.resolveAliasType(ty))) |tn| {
            if (std.mem.eql(u8, tn, "f32")) {
                try self.emitF32Expr(expr, locals);
                return true;
            }
        }
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
        const resolved_target = self.resolveAliasType(target_ty);
        const target_node = switch (resolved_target.kind) {
            .slice => |node| node,
            else => return false,
        };
        if (target_node.mutability != .@"const") return false;
        // An explicit `m as []const u8` narrow: the cast target is also a slice, so lower the
        // INNER value with the same const reinterpret (the `as` is a no-op reinterpret).
        const value_expr = switch (expr.kind) {
            .cast => |node| if (self.resolveAliasType(node.ty.*).kind == .slice) node.value.* else expr,
            .grouped => |inner| inner.*,
            else => expr,
        };
        const source_ty = self.operandEmitType(value_expr, locals) orelse return false;
        const resolved_source = self.resolveAliasType(source_ty);
        const source_node = switch (resolved_source.kind) {
            .slice => |node| node,
            else => return false,
        };
        if (source_node.mutability != .mut) return false;
        const src_c_type = try self.cTypeFor(source_ty, .typedef_name);
        const slice_name = try self.sliceTypeName(target_node.child.*, .@"const");
        const ptr_type = try self.pointerTypeForSliceElement(target_node.child.*, .@"const");
        const n = self.temp_index;
        self.temp_index += 1;
        try self.out.print(self.allocator, "({{ {s} mc_scv{d} = ", .{ src_c_type, n });
        try self.emitExpr(value_expr, locals);
        try self.out.print(self.allocator, "; ({s}){{ .ptr = ({s})mc_scv{d}.ptr, .len = mc_scv{d}.len }}; }})", .{ slice_name, ptr_type, n, n });
        return true;
    }

    fn emitEnumLiteralWithTarget(self: *CEmitter, literal: ast.Ident, target_ty: ?ast.TypeExpr) anyerror!void {
        const enum_name = if (target_ty) |ty| self.enumNameForType(ty) else null;
        if (enum_name) |name| {
            try self.out.print(self.allocator, "{s}_{s}", .{ name, literal.text });
            return;
        }
        try self.out.print(self.allocator, "/* unsupported enum literal: {s} */0", .{literal.text});
        return error.UnsupportedCEmission;
    }

    fn emitStringLiteralWithTarget(self: *CEmitter, literal: []const u8, target_ty: ?ast.TypeExpr) anyerror!void {
        // String literals require a target type (sema rejects targetless
        // ones). They lower to a C string literal cast to the target
        // pointer type, e.g. `*const u8` -> `(uint8_t const *)"…"`.
        const target = target_ty orelse return error.UnsupportedCEmission;
        const resolved = self.resolveAliasType(target);
        // A `[]const u8` / `[]u8` slice target: build the fat-pointer slice value
        // `(mc_slice_..._u8){ .ptr = (uint8_t const *)"hi", .len = 2 }`. The pointer is
        // the static C string literal (always valid — it is a program-lifetime literal),
        // the length is the decoded byte count (no trailing NUL).
        if (ast_query.u8SliceMutability(resolved)) |mutability| {
            const child = resolved.kind.slice.child.*;
            const slice_name = try self.sliceTypeName(child, mutability);
            const ptr_type = try self.pointerTypeForSliceElement(child, mutability);
            const len = ast_query.stringLiteralByteLen(literal) orelse return error.UnsupportedCEmission;
            try self.out.print(self.allocator, "(({s}){{ .ptr = ({s})", .{ slice_name, ptr_type });
            try self.out.appendSlice(self.allocator, literal);
            try self.out.print(self.allocator, ", .len = {d} }})", .{len});
            return;
        }
        if (!isStringLiteralTarget(resolved)) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(target, .typedef_name)});
        try self.out.appendSlice(self.allocator, literal);
        try self.out.appendSlice(self.allocator, ")");
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
        return switch (self.resolveAliasType(ty).kind) {
            .dyn_trait => true,
            .nullable => |child| self.resolveAliasType(child.*).kind == .dyn_trait,
            else => false,
        };
    }

    fn emitDynCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        // The target is `*dyn Trait` or `?*dyn Trait` (nullable trait object): both build
        // the `mc_dyn_<Trait>` fat pointer; the nullable just adds the `null` niche below.
        const trait_name = self.dynTargetTraitName(target_ty) orelse return false;
        // `?*dyn Trait = null`: `none` is the zero fat pointer (data == NULL).
        if (expr.kind == .null_literal) {
            try self.emitNullDynCoercion(trait_name);
            return true;
        }
        switch (expr.kind) {
            .grouped => |inner| return self.emitDynCoercion(inner.*, locals, target_ty),
            .address_of => |inner| return try self.emitAddressOfDynCoercion(inner.*, locals, trait_name),
            else => return try self.emitPointerValueDynCoercion(expr, locals, trait_name),
        }
    }

    fn dynTargetTraitName(self: *CEmitter, target_ty: ast.TypeExpr) ?[]const u8 {
        return switch (self.resolveAliasType(target_ty).kind) {
            .dyn_trait => |d| d.trait_name.text,
            .nullable => |child| switch (self.resolveAliasType(child.*).kind) {
                .dyn_trait => |d| d.trait_name.text,
                else => null,
            },
            else => null,
        };
    }

    fn emitNullDynCoercion(self: *CEmitter, trait_name: []const u8) !void {
        try self.out.print(self.allocator, "({s}){{0}}", .{try self.dynTypeName(trait_name)});
    }

    fn emitAddressOfDynCoercion(self: *CEmitter, operand: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8) !bool {
        // `&x` -> .data = (void*)&x, vtable keyed on typeof(x).
        const source_ty = self.operandEmitType(operand, locals) orelse self.exprSourceTypeForEmission(operand, locals) orelse return false;
        const type_name = typeName(self.resolveAliasType(source_ty)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)&", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(operand, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn emitPointerValueDynCoercion(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), trait_name: []const u8) !bool {
        // A `*T` value: .data = (void*)<the pointer>, vtable keyed on the pointee T.
        const source_ty = self.operandEmitType(expr, locals) orelse self.exprSourceTypeForEmission(expr, locals) orelse return false;
        const resolved_src = self.resolveAliasType(source_ty);
        // An existing `*dyn Trait` value passes through (no re-wrap).
        if (resolved_src.kind == .dyn_trait) return false;
        const pointee = switch (resolved_src.kind) {
            .pointer => |node| node.child.*,
            else => return false,
        };
        const type_name = typeName(self.resolveAliasType(pointee)) orelse return false;
        try self.out.print(self.allocator, "({s}){{ .data = (void *)", .{try self.dynTypeName(trait_name)});
        try self.emitExpr(expr, locals);
        try self.out.print(self.allocator, ", .vtable = &__vt_{s}_{s} }}", .{ type_name, trait_name });
        return true;
    }

    fn emitF32Expr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        try lower_c_arith.emitF32Expr(self.arithContext(), expr, locals);
    }

    fn structDeclForResolvedTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.StructDecl {
        const struct_name = typeName(target_ty) orelse return null;
        return self.structs.get(struct_name);
    }

    fn enumNameForType(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        return lower_c_infer.enumNameForType(self.inferTypeContext(), ty);
    }

    fn emitPackedBitsMember(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const base_ty = packedBitsNameForExpr(node.base.*, locals, &self.globals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(node.name.text) orelse return false;
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
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s})mc_race_load_{s}(&{s});\n", .{ base_ty, temp_name, base_ty, info.repr_name, global_name });
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} = ({s})(({s} & ({s})~{s}) | (", .{ temp_name, base_ty, temp_name, base_ty, mask });
        try self.emitExpr(value, locals);
        try self.out.print(self.allocator, " ? {s} : ({s})0));\n", .{ mask, base_ty });
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_race_store_{s}(&{s}, ({s}){s});\n", .{ info.repr_name, global_name, info.repr_c_type, temp_name });
    }

    fn emitPackedBitsLocalFieldWrite(self: *CEmitter, base: ast.Expr, base_ty: []const u8, mask: []const u8, value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        try self.writeIndent();
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " = ({s})((", .{base_ty});
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " & ({s})~{s}) | (", .{ base_ty, mask });
        try self.emitExpr(value, locals);
        try self.out.print(self.allocator, " ? {s} : ({s})0));\n", .{ mask, base_ty });
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
        const index_temp = try self.emitSequencedCallArgTemp(access.index, locals, simpleNameType("usize", access.index.span));
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, access.element_info.source_ty);

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
        const index_temp = try self.emitSequencedCallArgTemp(access.index, locals, simpleNameType("usize", access.index.span));
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, field.ty);

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

    fn enumNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return lower_c_infer.enumNameForExpr(self.inferTypeContext(), expr, locals);
    }

    fn exprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return lower_c_infer.exprIsBoolForEmission(self.inferTypeContext(), expr, locals);
    }

    fn enumNameForValueExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return lower_c_infer.enumNameForValueExpr(self.inferTypeContext(), expr, locals);
    }

    fn emitOverlayFieldReadReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        return lower_c_overlay.emitOverlayFieldReadReturn(self.overlayEmitContext(), expr, locals, return_ty);
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
        const base_ty = self.exprSourceTypeForEmission(node.base.*, locals) orelse return error.UnsupportedCEmission;
        const slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedCEmission;
        const slice_name = try self.sliceTypeName(slice_ty.kind.slice.child.*, slice_ty.kind.slice.mutability);
        const resolved = self.resolveAliasType(base_ty);
        const n = self.temp_index;
        self.temp_index += 1;

        try self.emitSliceRangePrelude(node, locals, resolved, n);
        try self.emitSliceBoundsGuard(slice_span, n, slice_name);
        try self.emitSliceBasePtr(node.base.*, locals, resolved);
        try self.out.print(self.allocator, " + mc_start{d}, .len = mc_end{d} - mc_start{d} }}; }})", .{ n, n, n });
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
        const array_ty = self.arrayReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(array_ty));
        try self.emitInferredCallLocalInitValue(name, array_ty, initializer, locals);
        return true;
    }

    fn emitSliceCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const slice_ty = self.sliceReturnTypeForExpr(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(slice_ty));
        try self.emitInferredCallLocalInitValue(name, slice_ty, initializer, locals);
        return true;
    }

    fn emitEnumCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const enum_ty = self.enumReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(enum_ty));
        try self.emitInferredCallLocalInitValue(name, enum_ty, initializer, locals);
        return true;
    }

    fn emitTaggedUnionCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const union_ty = self.taggedUnionReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(union_ty));
        try self.emitInferredCallLocalInitValue(name, union_ty, initializer, locals);
        return true;
    }

    fn emitResultCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const result_ty = self.resultTypeForExpr(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(result_ty));
        try self.emitInferredCallLocalInitValue(name, result_ty, initializer, locals);
        return true;
    }

    fn emitNullableCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const nullable_ty = self.nullableReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(nullable_ty));
        try self.emitInferredCallLocalInitValue(name, nullable_ty, initializer, locals);
        return true;
    }

    fn emitInferredCallLocalInitValue(self: *CEmitter, name: []const u8, inferred_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (try lower_c_call.emitSequencedCallLocalInit(self.sequencedArgContext(), &self.functions, name, inferred_ty, initializer, locals)) return;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalCopyInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inferred_ty = self.operandEmitType(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        if (try lower_c_access.emitDirectCallSliceIndexLocalInit(self.accessEmitContext(), name, inferred_ty, initializer, locals)) return true;
        if (try lower_c_access.emitDirectCallArrayIndexLocalInit(self.accessEmitContext(), name, inferred_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNumericInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inferred_ty = self.numericExprTypeForEmission(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(inferred_ty));

        if (try lower_c_arith.emitSequencedCheckedBinaryLocalInit(self.sequencedBinaryContext(), name, inferred_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn numericExprTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.numericExprTypeForEmission(self.inferTypeContext(), expr, locals);
    }

    fn conditionOperandTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.conditionOperandTypeForEmission(self.inferTypeContext(), expr, locals);
    }

    // Floating-point arithmetic lowers to plain C operators: IEEE semantics
    // never raise a language trap, so no overflow/divide checks are emitted.
    fn exprResolvesToFloat(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .ident, .member => self.operandResolvesToFloat(expr, locals),
            .deref => |inner| self.derefResolvesToFloat(inner.*, locals),
            .cast => |node| floatCTypeName(node.ty.*) != null,
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
        if (isRawLoadCall(node.callee.*) and node.type_args.len == 1) {
            return floatCTypeName(node.type_args[0]) != null;
        }
        const return_ty = self.callReturnTypeForExpr(expr, locals) orelse return false;
        return floatCTypeName(return_ty) != null;
    }

    fn emitCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const return_ty = self.callReturnTypeForExpr(initializer, locals) orelse return false;
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

    fn emitSequencedCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        return lower_c_call.collectSequencedArgTemps(self.scratch.allocator(), self, emitSequencedArgTempForCall, call.args, locals, fn_info);
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
        if (try lower_c_call.emitBitcastValueTempFromCall(self.sequencedArgContext(), call, locals)) |temp| return temp;
        if (try lower_c_call.emitExternNonNullCallValueTemp(self.sequencedArgContext(), &self.functions, arg, locals)) |temp| return temp;
        if (try lower_c_access.emitRawManyOffsetValueTempFromCall(self.accessEmitContext(), call, locals, target_ty)) |temp| return temp;
        if (try self.emitUncheckedAddValueTempFromCall(call, arg.span, locals, target_ty, "call_arg")) |temp| return temp;
        if (try self.emitNestedSequencedCallValueTemp(call, locals)) |temp| return temp;
        return null;
    }

    fn emitNestedSequencedCallValueTemp(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        const callee_name = calleeIdentName(call.callee.*) orelse return null;
        const fn_info = self.functions.get(callee_name) orelse return null;
        const return_ty = fn_info.return_type orelse return null;
        if (isVoidType(return_ty) or fn_info.params.len < call.args.len) return null;

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
        return ctx.emitter.resultTypeForExpr(operand, ctx.locals) != null;
    }

    fn nullableTryOperandIsNullable(ctx_ptr: *anyopaque, operand: ast.Expr) anyerror!bool {
        const ctx: *TryScanContext = @ptrCast(@alignCast(ctx_ptr));
        return (try ctx.emitter.nullableInnerCTypeForExpr(operand, ctx.locals)) != null;
    }

    fn sliceReturnTypeForCall(self: *CEmitter, call: anytype) ?ast.TypeExpr {
        return lower_c_infer.sliceReturnTypeForCall(&self.functions, call);
    }

    fn sliceReturnTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.sliceReturnTypeForExpr(self.inferTypeContext(), expr, locals);
    }

    fn sliceTypeForBase(self: *CEmitter, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
        return lower_c_infer.sliceTypeForBase(self.inferTypeContext(), ty, span);
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
        return lower_c_infer.operandEmitType(self.inferTypeContext(), expr, locals);
    }

    // Slice ptr/len access for a base expression, covering both a local/param base
    // (fast path via LocalInfo) and a struct-field base (`sp.s` where `s: []T`),
    // whose slice-ness is recovered from the field's declared type. The C slice
    // struct always names its fields `ptr`/`len` (see lower_c_info).
    fn sliceAccessForBase(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
        if (sliceAccessForExpr(expr, locals)) |slice| return slice;
        const ty = self.operandEmitType(expr, locals) orelse return null;
        return switch (self.resolveAliasType(ty).kind) {
            .slice => .{ .ptr_field = "ptr", .len_field = "len" },
            else => null,
        };
    }

    // The array type of `expr`, if it is an array — including the element of an
    // outer array access (`m[i]` over `[N][M]T` yields `[M]T`), which enables
    // nested indexing `m[i][j]`. Returns null for non-array expressions.
    fn arrayTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.arrayTypeForExpr(self.inferTypeContext(), expr, locals);
    }

    // Whether an expression has a pointer type, so member access lowers as `->`.
    // MMIO/slice/array accesses take dedicated paths before reaching here, so this
    // covers ordinary `*T` struct pointers (e.g. a borrowed `move` handle).
    fn exprIsPointer(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return lower_c_infer.exprIsPointer(self.inferTypeContext(), expr, locals);
    }

    // The pointee type of a pointer-typed expression (`p` where `p: *T` → `T`).
    fn derefPointeeType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.derefPointeeType(self.inferTypeContext(), expr, locals);
    }

    fn structTypeNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return lower_c_infer.structTypeNameForExpr(self.inferTypeContext(), expr, locals);
    }

    fn inferTypeContext(self: *CEmitter) lower_c_infer.TypeQueryContext {
        return .{
            .type_aliases = &self.type_aliases,
            .functions = &self.functions,
            .globals = &self.globals,
            .structs = &self.structs,
            .enums = &self.enums,
            .tagged_unions = &self.tagged_unions,
            .source_ctx = self,
            .source_type_for_expr = sourceTypeForInfer,
            .call_return_type_for_expr = callReturnTypeForInfer,
        };
    }

    fn sourceTypeForInfer(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.exprSourceTypeForEmission(expr, locals);
    }

    fn callReturnTypeForInfer(ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const self: *CEmitter = @ptrCast(@alignCast(ctx));
        return self.callReturnTypeForExpr(expr, locals);
    }

    fn arrayReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return lower_c_infer.arrayReturnTypeForExpr(&self.functions, expr);
    }

    fn resultTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.resultTypeForExpr(self.inferTypeContext(), expr, locals);
    }

    fn enumReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return lower_c_infer.enumReturnTypeForExpr(&self.functions, &self.enums, expr);
    }

    fn nullableReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return lower_c_infer.nullableReturnTypeForExpr(&self.functions, expr);
    }

    fn callReturnTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| self.callReturnTypeForCall(node, locals),
            .grouped => |inner| self.callReturnTypeForExpr(inner.*, locals),
            else => null,
        };
    }

    fn callReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (bitcastReturnTypeForCall(call)) |ty| return ty;
        if (self.assumeNoaliasReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.rawManyOffsetReturnTypeForCall(call, locals)) |ty| return ty;
        if (byteViewCallReturnTypeForCall(call)) |ty| return ty;
        if (self.atomicLoadReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.rawMethodReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.enumRawReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.dynDispatchReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.closureCalleeType(call.callee.*, locals)) |closure_ty| return closure_ty.kind.closure_type.ret.*;
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        return info.return_type;
    }

    fn dynDispatchReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const trait_name = self.dynCalleeTrait(call.callee.*, locals) orelse return null;
        const trait = self.trait_decls.get(trait_name) orelse return null;
        const method_name = dynCalleeMethodName(call.callee.*) orelse return null;
        for (trait.methods) |method| {
            if (std.mem.eql(u8, method.name.text, method_name)) return method.return_type;
        }
        return null;
    }

    // `<atomic expr>.load(order)` returns the atomic's payload type (`atomic<u32>.load` -> `u32`),
    // so a comparison/return whose operand is an atomic load — `flag.load(.acquire) != x` — can be
    // typed for emission instead of failing UnsupportedCEmission.
    fn atomicLoadReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const member = memberCallee(call.callee.*) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "load")) return null;
        const payload = self.atomicLocalPayload(member.base.*, locals) orelse return null;
        return simpleNameType(payload, member.name.span);
    }

    // `<open-enum expr>.raw()` yields the enum's underlying representation type
    // (`open enum E: u32` -> `u32`), so a comparison/return whose operand is a raw
    // conversion — `e.raw() == 1` — can be typed for emission in a value context
    // (return / let-init) instead of failing UnsupportedCEmission. The `if`-condition
    // path emits this inline and never needs the operand type; the sequenced value path does.
    fn rawMethodReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (call.type_args.len != 0) return null;
        if (call.args.len != 0) return null;
        const member = memberCallee(call.callee.*) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const enum_name = self.enumNameForValueExpr(member.base.*, locals) orelse return null;
        const enum_decl = self.enums.get(enum_name) orelse return null;
        if (!enum_decl.is_open) return null;
        return enum_decl.repr;
    }

    fn assumeNoaliasReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.assumeNoaliasReturnTypeForCall(self.inferTypeContext(), call, locals);
    }

    // `<enum expr>.raw()` extracts the enum's representation integer (emitted as the enum value
    // itself, whose C typedef IS that repr). Recovering this type lets a value-producing compare
    // over a raw operand — `k.raw() == 1` in a typed `let bool` or `return` — type its operands
    // instead of failing UnsupportedCEmission the way an `if`-condition path already avoids.
    fn enumRawReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (call.type_args.len != 0 or call.args.len != 0) return null;
        const member = memberCallee(call.callee.*) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const enum_name = self.enumNameForValueExpr(member.base.*, locals) orelse return null;
        const enum_decl = self.enums.get(enum_name) orelse return null;
        // `.raw()` yields the declared repr integer (`: T`), defaulting to the enum's own
        // storage typedef when unannotated — both are integer C storage.
        return enum_decl.repr orelse simpleNameType(enum_name, member.name.span);
    }

    fn exprSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| return info.source_ty;
                }
                if (self.globals.get(ident.text)) |info| return info.source_ty;
                return null;
            },
            .call => |node| self.callSourceTypeForEmission(node, locals),
            .cast => |node| node.ty.*,
            // A struct-field base (`sp.s` where `s: []T`) has no LocalInfo, so
            // recover its declared type from the struct decl via operandEmitType.
            .member => self.operandEmitType(expr, locals),
            .index => |node| self.operandEmitType(expr, locals) orelse
                (if (locals) |local_set| localIndexElementType(node.base.*, local_set) else null),
            .slice => |node| if (self.exprSourceTypeForEmission(node.base.*, locals)) |base_ty| self.sliceTypeForBase(base_ty, node.base.*.span) else null,
            .grouped => |inner| self.exprSourceTypeForEmission(inner.*, locals),
            .binary => |node| self.binarySourceTypeForEmission(node, locals),
            .unary => |node| if (node.op == .neg) self.exprSourceTypeForEmission(node.expr.*, locals) else null,
            else => null,
        };
    }

    fn callSourceTypeForEmission(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (bitcastReturnTypeForCall(call)) |ty| return ty;
        if (self.assumeNoaliasReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.rawManyOffsetReturnTypeForCall(call, locals)) |ty| return ty;
        if (byteViewCallReturnTypeForCall(call)) |ty| return ty;
        if (self.atomicLoadReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.rawMethodReturnTypeForCall(call, locals)) |ty| return ty;
        if (self.enumRawReturnTypeForCall(call, locals)) |ty| return ty;
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        return info.return_type;
    }

    fn binarySourceTypeForEmission(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (node.op) {
            .shl, .shr => self.exprSourceTypeForEmission(node.left.*, locals),
            .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => null,
            else => self.exprSourceTypeForEmission(node.left.*, locals) orelse self.exprSourceTypeForEmission(node.right.*, locals),
        };
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
    fn mmioAccess(self: *CEmitter, callee: ast.Expr, args: []ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
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

    fn rawManyOffsetReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.rawManyOffsetReturnTypeForCall(self.inferTypeContext(), call, locals);
    }

    fn rawManyOffsetExprTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return lower_c_infer.rawManyOffsetExprTypeForEmission(self.inferTypeContext(), expr, locals);
    }
};
