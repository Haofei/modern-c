const std = @import("std");

const array_len = @import("array_len.zig");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const diagnostics = @import("diagnostics.zig");
const error_from = @import("error_from.zig");
const numeric = @import("numeric.zig");
const eval = @import("eval.zig");
const loader = @import("loader.zig");
const sema_move = @import("sema_move.zig");

const sema_model = @import("sema_model.zig");
const sema_builtin = @import("sema_builtin.zig");
const sema_call = @import("sema_call.zig");
const sema_decl = @import("sema_decl.zig");
const sema_expr = @import("sema_expr.zig");
const sema_flow = @import("sema_flow.zig");
const sema_lookup = @import("sema_lookup.zig");
const sema_reflect = @import("sema_reflect.zig");
const sema_type = @import("sema_type.zig");

pub const Context = sema_model.Context;
pub const MoveSlot = sema_model.MoveSlot;
pub const TypeClass = sema_model.TypeClass;
const LoopLabelNode = sema_model.LoopLabelNode;
const MmioStruct = sema_model.MmioStruct;
const MmioFieldInfo = sema_model.MmioFieldInfo;
const StructInfo = sema_model.StructInfo;
const LayoutFieldInfo = sema_model.LayoutFieldInfo;
const EnumInfo = sema_model.EnumInfo;
const UnionInfo = sema_model.UnionInfo;
const FunctionInfo = sema_model.FunctionInfo;
const GlobalInfo = sema_model.GlobalInfo;
const UnsafeContracts = sema_model.UnsafeContracts;
const LocalInfo = sema_model.LocalInfo;
const BindingOrigin = sema_model.BindingOrigin;
const AddressOrigin = sema_model.AddressOrigin;
const Scope = sema_model.Scope;
const TypeMode = sema_model.TypeMode;
const ReflectEnv = sema_reflect.ReflectEnv;

const arithmeticDomainsImplicitlyMix = sema_type.arithmeticDomainsImplicitlyMix;
const addressOfOperand = sema_expr.addressOfOperand;
const arrayLiteralItems = sema_expr.arrayLiteralItems;
const backendNameAttr = sema_decl.backendNameAttr;
const byteViewCallReturnClass = sema_call.byteViewCallReturnClass;
const classifyType = sema_type.classifyType;
pub const classifyTypeCtx = sema_type.classifyTypeCtx;
const comptimeErrorMessage = sema_builtin.comptimeErrorMessage;
const comptimeUsizeValue = array_len.comptimeUsizeValue;
const constGetIndexArg = array_len.constGetIndexArg;
const constIndexLiteral = array_len.constIndexLiteral;
const declHasTrivialDrop = sema_decl.declHasTrivialDrop;
const declIsPublic = sema_decl.declIsPublic;
const declName = sema_decl.declName;
const divModProvablySafe = sema_type.divModProvablySafe;
const domainOperationArgCount = sema_type.domainOperationArgCount;
const equalityOperandsCompatible = sema_type.equalityOperandsCompatible;
const enumLiteralName = sema_builtin.enumLiteralName;
const findImplMethod = sema_decl.findImplMethod;
const findTraitMethod = sema_decl.findTraitMethod;
const fixedArrayType = array_len.fixedArrayType;
const genericHasStoragePayload = sema_builtin.genericHasStoragePayload;
const genericHoldsArgsByValue = sema_builtin.genericHoldsArgsByValue;
const genericTypeExpectedArgs = sema_builtin.genericTypeExpectedArgs;
const hasBoundedContext = sema_decl.hasBoundedContext;
const hasIrqContext = sema_decl.hasIrqContext;
const hasMaySleep = sema_decl.hasMaySleep;
const hasNaked = sema_decl.hasNaked;
const hasNoLangTrap = sema_decl.hasNoLangTrap;
const isArithmeticBinary = sema_type.isArithmeticBinary;
const isArithmeticDomain = sema_type.isArithmeticDomain;
const isArithmeticDomainTypeName = sema_builtin.isArithmeticDomainTypeName;
const isArithmeticOperand = sema_type.isArithmeticOperand;
const isArrayLiteral = sema_expr.isArrayLiteral;
const isBitwiseBinary = sema_type.isBitwiseBinary;
const isBitwiseOperand = sema_type.isBitwiseOperand;
const isBitcastCallName = sema_builtin.isBitcastCallName;
const isBuiltinFunctionName = sema_builtin.isBuiltinFunctionName;
const isBuiltinNamespaceMember = sema_builtin.isBuiltinNamespaceMember;
const isCAbiOpaqueBoundary = sema_builtin.isCAbiOpaqueBoundary;
const isCheckedInt = sema_type.isCheckedInt;
const isCheckedSigned = sema_type.isCheckedSigned;
const isCheckedUnsigned = sema_type.isCheckedUnsigned;
const isComparisonBinary = sema_type.isComparisonBinary;
const isComptimeForbiddenCall = sema_builtin.isComptimeForbiddenCall;
const isConstStorageType = sema_type.isConstStorageType;
const isCVoidPointerClass = sema_type.isCVoidPointerClass;
const isDeclassifyCallName = sema_builtin.isDeclassifyCallName;
const isDerefablePointerClass = sema_type.isDerefablePointerClass;
const isDiagnosticNeutralOperand = sema_type.isDiagnosticNeutralOperand;
const isDmaBufMode = sema_builtin.isDmaBufMode;
const isFixedUnsignedMmioWidth = sema_type.isFixedUnsignedMmioWidth;
const isFloat = sema_type.isFloat;
const isFloatish = sema_type.isFloatish;
pub const isForgetUncheckedCall = sema_builtin.isForgetUncheckedCall;
const isForbiddenBitwisePolicy = sema_type.isForbiddenBitwisePolicy;
const isForbiddenOrderingDomain = sema_type.isForbiddenOrderingDomain;
pub const isIntegerLike = sema_type.isIntegerLike;
const isNullableValue = sema_type.isNullableValue;
const isIndexType = sema_type.isIndexType;
const isIndexableBase = sema_type.isIndexableBase;
const isForIterableBase = sema_type.isForIterableBase;
const isConditionType = sema_type.isConditionType;
const isConversionName = sema_type.isConversionName;
const isCounterOperationName = sema_type.isCounterOperationName;
const isTryOperand = sema_type.isTryOperand;
const tryResultType = sema_type.tryResultType;
const isTypeStaticMember = sema_call.isTypeStaticMember;
const isFloatScalarName = sema_type.isFloatScalarName;
const isIntegerScalarName = sema_type.isIntegerScalarName;
const isNarrowingConversionName = sema_type.isNarrowingConversionName;
const isOpaqueAddressClass = sema_type.isOpaqueAddressClass;
const isAddressClass = sema_type.isAddressClass;
const isBitcastLayoutClass = sema_type.isBitcastLayoutClass;
const isSerialOperationName = sema_type.isSerialOperationName;
const isKnownGenericTypeName = sema_builtin.isKnownGenericTypeName;
const isKnownLayoutType = sema_lookup.isKnownLayoutType;
const isKnownTypeName = sema_lookup.isKnownTypeName;
const isLanguageTrapKind = sema_builtin.isLanguageTrapKind;
const isLogicalBinary = sema_type.isLogicalBinary;
const isMmioAccessMode = sema_builtin.isMmioAccessMode;
const isNoTrapArithmeticDomainOp = sema_type.isNoTrapArithmeticDomainOp;
const isNonNullPointerLike = sema_type.isNonNullPointerLike;
const isNullLiteral = sema_expr.isNullLiteral;
const isNonTrappingFloatOp = sema_type.isNonTrappingFloatOp;
const isNullablePointerLike = sema_type.isNullablePointerLike;
const isOrderedComparisonOperand = sema_type.isOrderedComparisonOperand;
const isPointerLikeClass = sema_type.isPointerLikeClass;
pub const isPointerLike = sema_type.isPointerLike;
const isPointerArithmeticBinary = sema_type.isPointerArithmeticBinary;
const isPackedBitsTypeName = sema_lookup.isPackedBitsTypeName;
const isRuntimePointerDerefClass = sema_type.isRuntimePointerDerefClass;
const isSingleObjectPointerLike = sema_type.isSingleObjectPointerLike;
const isStaticGlobalInitializer = sema_expr.isStaticGlobalInitializer;
const isStructLiteral = sema_expr.isStructLiteral;
const maybeUninitPayloadType = sema_type.maybeUninitPayloadType;
pub const nullableInnerType = sema_type.nullableInnerType;
const isTrapCall = sema_builtin.isTrapCall;
const isTrapBinary = sema_type.isTrapBinary;
const isTrappingConversionCall = sema_builtin.isTrappingConversionCall;
const isTypeName = sema_builtin.isTypeName;
const isUnsafeOperationCall = sema_builtin.isUnsafeOperationCall;
const isUnwrapCall = sema_builtin.isUnwrapCall;
const isValueLevelDecl = sema_decl.isValueLevelDecl;
const mathBuiltinCallReturnClass = sema_builtin.mathBuiltinCallReturnClass;
const mathBuiltinFloatClass = sema_builtin.mathBuiltinFloatClass;
const mergeArithmetic = sema_type.mergeArithmetic;
const knownMmioStructName = sema_lookup.knownMmioStructName;
const knownPackedBitsName = sema_lookup.knownPackedBitsName;
const layoutFieldInfo = sema_lookup.layoutFieldInfo;
const parseArrayLen = array_len.parseArrayLen;
const sameTypeSyntax = sema_type.sameTypeSyntax;
const viewElementType = sema_type.viewElementType;
const viewType = sema_type.viewType;
const ReflectionKind = sema_builtin.ReflectionKind;
const ReflectionTarget = sema_builtin.ReflectionTarget;
const reflectionGenericHasWrongArity = sema_builtin.reflectionGenericHasWrongArity;
const reflectionKind = sema_builtin.reflectionKind;
const reflectionRequiresField = sema_builtin.reflectionRequiresField;
const reflectionReturnClass = sema_builtin.reflectionReturnClass;
const reflectionTypeExprFromArg = sema_builtin.reflectionTypeExprFromArg;
const reduceCallReturnClass = sema_call.reduceCallReturnClass;
const resolveAliasType = sema_type.resolveAliasType;
pub const resultPayloadType = sema_type.resultPayloadType;
const resultLocalHandledLater = sema_flow.resultLocalHandledLater;
const structLiteralFields = sema_expr.structLiteralFields;
const stmtHandlesResultLocal = sema_flow.stmtHandlesResultLocal;
const switchBoolLiteralValue = sema_flow.switchBoolLiteralValue;
const switchCoversAllEnumCases = sema_flow.switchCoversAllEnumCases;
const switchCoversAllUnionCases = sema_flow.switchCoversAllUnionCases;
const staticTypeBaseClass = sema_call.staticTypeBaseClass;
const traitIsObjectSafe = sema_decl.traitIsObjectSafe;
const typeStaticCallReturnClass = sema_call.typeStaticCallReturnClass;
const secretPayloadType = sema_builtin.secretPayloadType;
const uncheckedRequirement = sema_builtin.uncheckedRequirement;
pub const isDropCall = sema_builtin.isDropCall;

// Pure AST-shape queries shared with `mir.zig`/`lower_c.zig` (see `ast_query.zig`). The shared
// `isIdentNamed` is grouping-transparent (was not, here, before consolidation).
const isIdentNamed = ast_query.isIdentNamed;
const MmioRegisterAccess = ast_query.MmioRegisterAccess;
const mmioRegisterAccessFromModeType = ast_query.mmioRegisterAccessFromModeType;
const simpleNameType = ast_query.simpleNameType;
const isMmioMapCallName = ast_query.isMmioMapCallName;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const isResultNarrowingTag = ast_query.isResultNarrowingTag;
const localDeclaresName = ast_query.localDeclaresName;
const isUninitLiteral = ast_query.isUninitLiteral;
const typeName = ast_query.typeName;
const isRawManyPointerType = ast_query.isRawManyPointerType;
const isPointerLikeGeneric = ast_query.isPointerLikeGeneric;
const mmioPointee = ast_query.mmioPointee;
const reduceCallKind = ast_query.reduceCallKind;
const constU8SliceType = ast_query.constU8SliceType;
const callExpr = ast_query.callExpr;
const calleeIdentName = ast_query.calleeIdentName;
const memberCallee = ast_query.memberCallee;
const memberExpr = ast_query.memberExpr;
const byteViewCallKind = ast_query.byteViewCallKind;
const DmaBufInfo = ast_query.DmaBufInfo;
const dmaBufInfo = ast_query.dmaBufInfo;

// Numeric-literal and integer-bounds primitives shared with `mir.zig` and `lower_c.zig`
// (see `numeric.zig`); aliased here so the existing call sites read unchanged.
const LiteralValue = numeric.LiteralValue;
const IntBounds = numeric.IntBounds;
const maxUnsigned = numeric.maxUnsigned;
const signedBounds = numeric.signedBounds;
const integerLiteralValue = numeric.integerLiteralValue;
const atomicPayloadType = sema_type.atomicPayloadType;

fn isCBackendReservedTopLevelName(kind: ast.Decl.Kind, name: []const u8) bool {
    if (isCBackendRuntimeHelperName(name) or isCBackendGeneratedTopLevelValueName(name)) return true;
    // Value-level C keywords are sanitized by C emission, but C prelude/header names
    // and nominal declarations still share generated C namespaces.
    if (isValueLevelDecl(kind)) return isCBackendReservedHeaderName(name);
    return isCBackendReservedExactName(name);
}

fn isCBackendReservedLocalName(name: []const u8) bool {
    return isCBackendRuntimeHelperName(name) or
        std.mem.startsWith(u8, name, "mc_tmp") or
        std.mem.startsWith(u8, name, "mc_acc") or
        std.mem.startsWith(u8, name, "mc_xs") or
        std.mem.startsWith(u8, name, "mc_i") or
        std.mem.startsWith(u8, name, "mc_a");
}

fn isCBackendReservedExactName(name: []const u8) bool {
    const reserved = [_][]const u8{
        // C keywords and contextual/builtin names the C emitter may put in scope.
        "auto",              "break",              "case",              "char",             "const",
        "continue",          "default",            "do",                "double",           "else",
        "enum",              "extern",             "float",             "for",              "goto",
        "if",                "inline",             "int",               "long",             "register",
        "restrict",          "return",             "short",             "signed",           "sizeof",
        "static",            "struct",             "switch",            "typedef",          "union",
        "unsigned",          "void",               "volatile",          "while",            "_Bool",
        "_Complex",          "_Imaginary",         "_Alignas",          "_Alignof",         "_Atomic",
        "_Generic",          "_Noreturn",          "_Static_assert",    "_Thread_local",    "__auto_type",
        "__asm__",           "__attribute__",      "__builtin_trap",    "__builtin_memcpy", "__builtin_memcmp",
        "__builtin_va_list", "__builtin_va_start", "__builtin_va_copy", "__builtin_va_arg", "__builtin_va_end",
        // Macros and typedefs from the headers emitted by the C prelude.
        "bool",              "true",               "false",             "NULL",             "offsetof",
        "size_t",            "ptrdiff_t",          "uintptr_t",         "intptr_t",         "uint8_t",
        "uint16_t",          "uint32_t",           "uint64_t",          "int8_t",           "int16_t",
        "int32_t",           "int64_t",            "UINT8_MAX",         "UINT16_MAX",       "UINT32_MAX",
        "UINT64_MAX",        "UINTPTR_MAX",        "INT8_MIN",          "INT16_MIN",        "INT32_MIN",
        "INT64_MIN",         "INTPTR_MIN",         "INT8_MAX",          "INT16_MAX",        "INT32_MAX",
        "INT64_MAX",         "INTPTR_MAX",         "CHAR_BIT",          "MC_UNUSED",        "MC_NORETURN",
        "MC_WEAK",
    };
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn isCBackendRuntimeHelperName(name: []const u8) bool {
    const exact = [_][]const u8{
        "mc_check_index_usize",
        "mc_cpu_pause",
        "mc_barrier_release_before",
        "mc_barrier_acquire_after",
        "mc_barrier_full",
    };
    for (exact) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return std.mem.startsWith(u8, name, "mc_trap_") or
        std.mem.startsWith(u8, name, "mc_checked_") or
        std.mem.startsWith(u8, name, "mc_wrap_") or
        std.mem.startsWith(u8, name, "mc_sat_") or
        std.mem.startsWith(u8, name, "mc_race_") or
        std.mem.startsWith(u8, name, "mc_raw_") or
        std.mem.startsWith(u8, name, "mc_mmio_") or
        std.mem.startsWith(u8, name, "mc_envthunk_") or
        std.mem.startsWith(u8, name, "mc_dyn_") or
        std.mem.startsWith(u8, name, "__vt_") or
        std.mem.startsWith(u8, name, "VT_");
}

pub const Checker = struct {
    reporter: *diagnostics.Reporter,
    // Set when building a symbol table runs out of memory. Surfaced as a fatal
    // diagnostic so an incomplete table never silently passes checking.
    oom: bool = false,
    // Names that own a qualified namespace (`module`/`impl`); a local binding may not shadow
    // one, or `Owner.member` access would silently bind to the qualified symbol instead of the
    // local. Set for the duration of checkModule.
    qualified_owners: [][]const u8 = &.{},
    // The (possibly mangled) name of the function currently being checked, used to
    // decide whether code may name an `opaque struct`'s private fields: only the
    // struct's own associated functions (`Struct__member`, from `impl Struct`) may.
    // Null at module scope (globals/initializers), where no private field is in reach.
    current_fn_name: ?[]const u8 = null,
    // Fact-gated MIR optimizer toggle (annex E), set by the caller for `verify --optimize`.
    // When on, a provably-in-range constant index is treated as non-trapping so it is
    // allowed inside `#[no_lang_trap]` (mirrors the MIR-level bounds-check elision). Off by
    // default, so `check` and the standard pipeline are unchanged.
    optimize: bool = false,
    // Registry of `const fn` declarations, populated for the duration of
    // checkModule so comptime folding can evaluate const-fn calls (section 22).
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Folded values of `const NAME: T = …` globals (section 22), so comptime
    // folding can resolve named compile-time constants.
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
    // Declared integer widths of named const globals, used by width-sensitive
    // comptime folds such as `~CONST_U32`.
    const_global_widths: ?*const std.StringHashMap(u16) = null,
    // Functions that declare at least one `comptime` parameter (section 22),
    // keyed by name, so call sites can re-check their comptime assertions with
    // the parameters bound to the call's constant arguments.
    comptime_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Type registries for comptime reflection (`sizeof`/`alignof`), set for the
    // duration of checkModule.
    reflect_env: ?*const ReflectEnv = null,
    // Names of `move struct` linear resource types (section 18.1), set for the
    // duration of checkModule so the move/liveness pass (D.7) can classify
    // bindings. Empty for the common case (no move types → the pass is a no-op).
    move_types: ?*const std.StringHashMap(void) = null,
    // Names of `move struct` types marked `#[trivial_drop]` (section 18.1): the author
    // asserts, once at the declaration, that completing the resource needs no release, so
    // `drop(x)` is a SAFE final use (no `unsafe { forget_unchecked }` at every call site).
    // A resource's release obligation is not visible in its field types, so this cannot be
    // inferred — it is an explicit author assertion, like `unsafe`, moved to the boundary.
    trivial_drop_types: ?*const std.StringHashMap(void) = null,
    // A module-level Context used during the move pass to infer a switch subject's Result
    // type, so an arm binding (`ok(p)`) can be recognized as a linear `move` value.
    move_ctx: ?*const Context = null,
    // A stack of "names live at loop entry", one frame per enclosing loop, maintained
    // during the move pass. A `break`/`continue` exits the current iteration, so any
    // loop-body-local `move` value live at that edge (a name not in the top frame) is a
    // leak — the same check `return` does at function exit, but scoped to the loop body.
    move_loop_stack: std.ArrayListUnmanaged(std.StringHashMap(void)) = .empty,
    // Owns the synthetic place-key strings (`binding.field`) the move pass inserts into
    // its state to track a `move` field that has been moved out of its aggregate. Freed at
    // the end of each function's analysis.
    move_place_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    // Block-scoping (G20): the innermost-last stack of local names that are CURRENTLY LIVE
    // across all open lexical scopes (params + every enclosing block's locals). A `let`/`var`
    // may reuse a name that belongs to an already-exited SIBLING block (popped from here), but
    // re-declaring a name still live in an enclosing scope stays E_DUPLICATE_LOCAL (MC forbids
    // live-shadowing). This mirrors the async path's `DupScope.liveInAnyFrame` frame stack so
    // both paths agree. The backing `scope` map is NEVER popped (keep-all), so post-body passes
    // (fall-through / switch-exhaustiveness) still resolve a block-local subject's type; only the
    // liveness set here is scoped. Reset per function; markers via `enterScope`/`leaveScope`.
    live_locals: std.ArrayListUnmanaged([]const u8) = .empty,
    // (bug #3) Definite-init: defer bodies do NOT run at their lexical position — they
    // run at scope EXIT, after later assignments. Reading them eagerly mid-block produced
    // a false E_USE_BEFORE_INIT (`var x=uninit; defer sink(x); x=5;`). Instead we COLLECT
    // each defer expression here, paired with the count of defers already live when it was
    // declared (its index), and evaluate its reads against the MEET (union of still-pending /
    // uninit names) over EVERY exit edge — return / `?` (try) propagation / fall-through —
    // that is reachable while the defer is live. (Regression fix: a defer ALSO runs on
    // early-return / `?` edges where a var may still be uninit; checking only fall-through
    // let those slip.) Non-null only during a DI pass.
    di_defers: ?*std.ArrayListUnmanaged(DiDefer) = null,
    // Exit-edge snapshots taken while inside a DI pass: each records the set of still-pending
    // (uninit) names at an exit edge and how many defers were live there (so a defer at index
    // i is only checked against snapshots whose live_defers > i).
    di_exits: ?*std.ArrayListUnmanaged(DiExitSnapshot) = null,
    // Definite-init owns synthetic place keys used for proven initialized array elements
    // while a surrounding `var arr: [N]T = uninit` aggregate is still pending.
    di_place_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    // Origin-file boundaries of the import-flattened source (loader.FileBoundary), in append
    // order by start offset. Maps a decl's span offset back to the file it came from, which the
    // orphan rule (`checkOrphanImpls`) uses to require that an `impl` of an `opaque struct`
    // live in the SAME file as the type's definition. Null for single-file/standalone checks
    // (no imports, nothing cross-file to forge), where the orphan rule is a no-op.
    file_boundaries: ?[]const loader.FileBoundary = null,
    // Opt-in module visibility (§30): names that are file-private — a non-`pub` top-level
    // declaration in a "strict" file (one that has at least one `pub` declaration). Maps the
    // name to its defining file; a reference from a DIFFERENT file is E_PRIVATE_IMPORT. Empty
    // when no file is strict (every existing module stays fully visible) or single-file.
    private_items: ?*const std.StringHashMap([]const u8) = null,
    // Tier 2 trait-object tables, populated by checkTraits and read while checking
    // bodies (object-safety of `*dyn Trait`, dispatch type-checking). Set for the
    // duration of checkModule.
    known_traits: std.StringHashMap(void) = undefined,
    object_safe_traits: std.StringHashMap(void) = undefined,
    // `(Trait, Type)` conformance pairs (key = "Trait\x00Type"), so a `&x -> *dyn Trait`
    // coercion can verify `impl Trait for typeof(x)` exists. Owns its key strings.
    trait_conformances: std.StringHashMap(void) = undefined,
    // Trait declarations by name, so a `d.method(args)` dispatch through a
    // `*dyn Trait` can resolve the method signature.
    trait_decls: ?*const std.StringHashMap(ast.TraitDecl) = null,
    // Template precheck mode is used before monomorphization drops generic
    // templates. It collects the full symbol/type context, then checks only
    // declarations that can disappear before normal sema sees them.
    generic_template_precheck: bool = false,
    generic_template_fns: ?*const std.StringHashMap(void) = null,

    pub fn init(reporter: *diagnostics.Reporter) Checker {
        return .{ .reporter = reporter };
    }

    pub fn checkModule(self: *Checker, module: ast.Module) void {
        defer self.live_locals.deinit(self.reporter.allocator); // free the block-scoping liveness stack
        var mmio_structs = std.StringHashMap(MmioStruct).init(self.reporter.allocator);
        defer deinitMmioStructs(&mmio_structs);
        var structs = std.StringHashMap(StructInfo).init(self.reporter.allocator);
        defer deinitStructs(&structs);
        var packed_bits = std.StringHashMap(LayoutFieldInfo).init(self.reporter.allocator);
        defer deinitLayoutFieldInfos(&packed_bits);
        var overlay_unions = std.StringHashMap(LayoutFieldInfo).init(self.reporter.allocator);
        defer deinitLayoutFieldInfos(&overlay_unions);
        var tagged_unions = std.StringHashMap(UnionInfo).init(self.reporter.allocator);
        defer deinitTaggedUnions(&tagged_unions);
        var enums = std.StringHashMap(EnumInfo).init(self.reporter.allocator);
        defer deinitEnums(&enums);
        var functions = std.StringHashMap(FunctionInfo).init(self.reporter.allocator);
        defer functions.deinit();
        var globals = std.StringHashMap(GlobalInfo).init(self.reporter.allocator);
        defer globals.deinit();
        var type_aliases = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        defer type_aliases.deinit();
        self.qualified_owners = module.qualified_owners;
        self.known_traits = std.StringHashMap(void).init(self.reporter.allocator);
        defer self.known_traits.deinit();
        self.object_safe_traits = std.StringHashMap(void).init(self.reporter.allocator);
        defer self.object_safe_traits.deinit();
        self.trait_conformances = std.StringHashMap(void).init(self.reporter.allocator);
        defer {
            var cit = self.trait_conformances.keyIterator();
            while (cit.next()) |k| self.reporter.allocator.free(k.*);
            self.trait_conformances.deinit();
        }
        var trait_decls = std.StringHashMap(ast.TraitDecl).init(self.reporter.allocator);
        defer trait_decls.deinit();
        self.trait_decls = &trait_decls;
        defer self.trait_decls = null;
        if (!self.generic_template_precheck) {
            self.checkTopLevelNames(module);
            self.checkBackendNameUniqueness(module);
        }
        self.collectTypeAliases(module, &type_aliases);
        if (!self.generic_template_precheck) self.checkTypeAliasCycles(module, &type_aliases);
        self.collectMmioStructs(module, &mmio_structs);
        self.collectStructs(module, &structs);
        self.collectPackedBits(module, &packed_bits);
        self.collectOverlayUnions(module, &overlay_unions);
        self.collectTaggedUnions(module, &tagged_unions);
        self.collectEnums(module, &enums);
        self.collectFunctions(module, &functions);
        if (!self.generic_template_precheck) self.checkErrorFromDecls(module);
        self.collectGlobals(module, &globals);

        // Orphan rule: an `impl` of an `opaque struct` must live in the type's defining file,
        // so the name-keyed private-field gate (`opaqueAccessAllowed`) cannot be forged by a
        // peer `impl <OpaqueType>` written in another file. Trait impls follow the spec's
        // wider coherence boundary: `impl Trait for Type` must be in `Type`'s declaring file.
        // No-op without file boundaries.
        if (!self.generic_template_precheck) self.checkOrphanImpls(module);

        // Tier 1 traits: conformance (every trait method present, matching self-mode +
        // effect annotations) and coherence (<=1 impl per (Trait, Type)). Bound
        // satisfaction is checked at the instantiation site during monomorphization;
        // the orphan rule for `impl Trait for <opaque>` is covered by checkOrphanImpls
        // above (the impl methods are `Type__m` functions keyed on the opaque owner).
        self.checkTraits(module);

        var const_fns = std.StringHashMap(ast.FnDecl).init(self.reporter.allocator);
        defer const_fns.deinit();
        for (module.decls) |decl| {
            const fn_decl = switch (decl.kind) {
                .fn_decl => |node| node,
                else => continue,
            };
            if (fn_decl.is_const and !const_fns.contains(fn_decl.name.text)) {
                const_fns.put(fn_decl.name.text, fn_decl) catch {
                    self.oom = true;
                };
            }
        }
        self.const_fns = &const_fns;
        defer self.const_fns = null;

        var reflect_env = ReflectEnv{
            .structs = &structs,
            .packed_bits = &packed_bits,
            .overlay_unions = &overlay_unions,
            .tagged_unions = &tagged_unions,
            .enums = &enums,
            .aliases = &type_aliases,
            .const_fns = &const_fns,
        };
        self.reflect_env = &reflect_env;
        defer self.reflect_env = null;

        var const_globals = std.StringHashMap(eval.ComptimeValue).init(self.reporter.allocator);
        defer eval.deinitConstGlobals(self.reporter.allocator, &const_globals);
        eval.collectConstGlobalsWithOptions(self.reporter.allocator, module, &const_fns, &const_globals, .{
            .reflect = sema_reflect.comptimeReflectThunk,
            .reflect_ctx = &reflect_env,
        }) catch {
            self.oom = true;
        };
        self.const_globals = &const_globals;
        reflect_env.const_globals = &const_globals;
        defer self.const_globals = null;

        var const_global_widths = std.StringHashMap(u16).init(self.reporter.allocator);
        defer const_global_widths.deinit();
        self.collectConstGlobalWidths(module, &const_global_widths);
        self.const_global_widths = &const_global_widths;
        defer self.const_global_widths = null;

        var comptime_fns = std.StringHashMap(ast.FnDecl).init(self.reporter.allocator);
        defer comptime_fns.deinit();
        for (module.decls) |decl| {
            const fn_decl = switch (decl.kind) {
                .fn_decl => |node| node,
                else => continue,
            };
            if (fn_decl.body == null or comptime_fns.contains(fn_decl.name.text)) continue;
            for (fn_decl.params) |param| {
                if (param.is_comptime) {
                    comptime_fns.put(fn_decl.name.text, fn_decl) catch {
                        self.oom = true;
                    };
                    break;
                }
            }
        }
        self.comptime_fns = &comptime_fns;
        defer self.comptime_fns = null;

        var move_types = std.StringHashMap(void).init(self.reporter.allocator);
        defer move_types.deinit();
        var trivial_drop_types = std.StringHashMap(void).init(self.reporter.allocator);
        defer trivial_drop_types.deinit();
        for (module.decls) |decl| {
            if (decl.kind == .struct_decl and decl.kind.struct_decl.is_move) {
                move_types.put(decl.kind.struct_decl.name.text, {}) catch {
                    self.oom = true;
                };
            }
            if (declHasTrivialDrop(decl)) {
                if (decl.kind == .struct_decl and decl.kind.struct_decl.is_move) {
                    trivial_drop_types.put(decl.kind.struct_decl.name.text, {}) catch {
                        self.oom = true;
                    };
                } else {
                    // `#[trivial_drop]` asserts a linear resource's completion is a no-op; it
                    // is meaningless on anything but a `move struct`.
                    self.errorCode(decl.span, "E_TRIVIAL_DROP_NOT_MOVE", "#[trivial_drop] applies only to a `move struct` (it asserts the resource's completion needs no release)");
                }
            }
        }
        self.move_types = &move_types;
        defer self.move_types = null;
        self.trivial_drop_types = &trivial_drop_types;
        defer self.trivial_drop_types = null;

        // Opt-in module visibility: a file with >= 1 `pub` declaration is "strict"; its
        // non-`pub`/non-`export` top-level items are private to it (E_PRIVATE_IMPORT when
        // referenced from another file). No strict file -> the map stays empty and every
        // module is fully visible, so existing code is unaffected.
        var private_items = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer private_items.deinit();
        if (self.file_boundaries != null) {
            var strict_files = std.StringHashMap(void).init(self.reporter.allocator);
            defer strict_files.deinit();
            for (module.decls) |decl| {
                if (decl.is_pub) {
                    if (self.originFile(decl.span.offset)) |f| strict_files.put(f, {}) catch {
                        self.oom = true;
                    };
                }
            }
            if (strict_files.count() > 0) {
                for (module.decls) |decl| {
                    if (decl.kind == .impl_trait) continue; // no own importable name
                    if (declIsPublic(decl)) continue;
                    const file = self.originFile(decl.span.offset) orelse continue;
                    if (!strict_files.contains(file)) continue;
                    private_items.put(declName(decl).text, file) catch {
                        self.oom = true;
                    };
                }
            }
        }
        self.private_items = &private_items;
        defer self.private_items = null;

        for (module.decls) |decl| {
            if (self.generic_template_precheck and !self.shouldCheckGenericTemplateDecl(decl)) continue;
            self.checkDecl(decl, &mmio_structs, &structs, &packed_bits, &overlay_unions, &tagged_unions, &enums, &functions, &globals, &type_aliases);
        }

        // Definite-initialization pass (S0.1). A scalar `var x: T = uninit;`
        // must be definitely assigned on every control-flow path before it is
        // read; a read-before-assign is E_USE_BEFORE_INIT. Runs over every
        // function body (the `uninit` idiom is pervasive, but the analysis is
        // precise enough to accept it — see checkDefiniteInit).
        if (!self.generic_template_precheck) {
            const di_ctx = Context{
                .functions = &functions,
                .globals = &globals,
                .type_aliases = &type_aliases,
                .structs = &structs,
                .packed_bits = &packed_bits,
                .overlay_unions = &overlay_unions,
                .enums = &enums,
                .tagged_unions = &tagged_unions,
            };
            for (module.decls) |decl| {
                if (decl.kind == .fn_decl) self.checkDefiniteInit(decl.kind.fn_decl, di_ctx);
            }
        }

        // Linear `move`/liveness pass (section 18.1, annex D.7). No-op unless the
        // module declares `move` types.
        if (!self.generic_template_precheck and move_types.count() > 0) {
            var move_ctx = Context{
                .functions = &functions,
                .globals = &globals,
                .type_aliases = &type_aliases,
                .structs = &structs,
                .enums = &enums,
                .tagged_unions = &tagged_unions,
            };
            self.move_ctx = &move_ctx;
            defer self.move_ctx = null;
            defer self.move_loop_stack.deinit(self.reporter.allocator); // free the loop-entry snapshot stack
            defer self.move_place_keys.deinit(self.reporter.allocator); // free the field-move place-key list
            for (module.decls) |decl| {
                if (decl.kind == .fn_decl) sema_move.checkMoveLinearity(self, decl.kind.fn_decl, &type_aliases);
            }
        }

        if (self.oom) {
            self.errorCode(.{ .offset = 0, .len = 0, .line = 1, .column = 1 }, "E_INTERNAL_OOM", "compiler ran out of memory while building symbol tables; results are incomplete");
        }
    }

    fn shouldCheckGenericTemplateDecl(self: *Checker, decl: ast.Decl) bool {
        return switch (decl.kind) {
            .fn_decl => |fn_decl| if (self.generic_template_fns) |names| names.contains(fn_decl.name.text) else false,
            .struct_decl => |struct_decl| struct_decl.type_params.len > 0,
            .union_decl => |union_decl| union_decl.type_params.len > 0,
            else => false,
        };
    }

    fn collectTypeAliases(self: *Checker, module: ast.Module, type_aliases: *std.StringHashMap(ast.TypeExpr)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| if (!type_aliases.contains(alias.name.text)) type_aliases.put(alias.name.text, alias.ty) catch {
                    self.oom = true;
                },
                .opaque_decl => |name| if (!type_aliases.contains(name.text)) type_aliases.put(name.text, simpleNameType(name.text, name.span)) catch {
                    self.oom = true;
                },
                .fn_decl, .extern_fn, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn checkTypeAliasCycles(self: *Checker, module: ast.Module, type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        for (module.decls) |decl| {
            const alias = switch (decl.kind) {
                .type_alias => |alias| alias,
                else => continue,
            };
            var visiting = std.StringHashMap(void).init(self.reporter.allocator);
            defer visiting.deinit();
            if (self.typeExprHasAliasCycle(alias.name.text, alias.ty, type_aliases, &visiting)) {
                self.errorCode(alias.name.span, "E_TYPE_ALIAS_CYCLE", "type aliases must not form recursive cycles");
            }
        }
    }

    fn typeExprHasAliasCycle(self: *Checker, root_name: []const u8, ty: ast.TypeExpr, type_aliases: *const std.StringHashMap(ast.TypeExpr), visiting: *std.StringHashMap(void)) bool {
        switch (ty.kind) {
            .name => |name| {
                if (std.mem.eql(u8, name.text, root_name)) return true;
                const target = type_aliases.get(name.text) orelse return false;
                if (visiting.contains(name.text)) return true;
                visiting.put(name.text, {}) catch {
                    self.oom = true;
                    return false;
                };
                defer _ = visiting.remove(name.text);
                return self.typeExprHasAliasCycle(root_name, target, type_aliases, visiting);
            },
            .member => |node| return self.typeExprHasAliasCycle(root_name, node.base.*, type_aliases, visiting),
            .nullable => |child| return self.typeExprHasAliasCycle(root_name, child.*, type_aliases, visiting),
            .qualified => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .pointer => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .raw_many_pointer => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .slice => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .array => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .generic => |node| {
                for (node.args) |arg| {
                    if (self.typeExprHasAliasCycle(root_name, arg, type_aliases, visiting)) return true;
                }
                return false;
            },
            .fn_pointer => |node| {
                for (node.params) |param| {
                    if (self.typeExprHasAliasCycle(root_name, param, type_aliases, visiting)) return true;
                }
                return self.typeExprHasAliasCycle(root_name, node.ret.*, type_aliases, visiting);
            },
            .closure_type => |node| {
                for (node.params) |param| {
                    if (self.typeExprHasAliasCycle(root_name, param, type_aliases, visiting)) return true;
                }
                return self.typeExprHasAliasCycle(root_name, node.ret.*, type_aliases, visiting);
            },
            .enum_literal => return false,
            // A `*dyn Trait` names a trait, not a type alias — it cannot start a cycle.
            .dyn_trait => return false,
        }
    }

    fn collectMmioStructs(self: *Checker, module: ast.Module, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) self.collectMmioStruct(struct_decl, mmio_structs);
                    }
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectMmioStruct(self: *Checker, struct_decl: ast.StructDecl, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        if (mmio_structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(MmioFieldInfo).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (mmioFieldInfoFromType(field.ty)) |info| {
                if (!fields.contains(field.name.text)) fields.put(field.name.text, info) catch {
                    self.oom = true;
                };
            }
        }
        mmio_structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectStructs(self: *Checker, module: ast.Module, structs: *std.StringHashMap(StructInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| self.collectStruct(struct_decl, structs),
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectStruct(self: *Checker, struct_decl: ast.StructDecl, structs: *std.StringHashMap(StructInfo)) void {
        if (structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {
                self.oom = true;
            };
        }
        structs.put(struct_decl.name.text, .{ .fields = fields, .ordered = struct_decl.fields, .abi = struct_decl.abi, .type_param_count = struct_decl.type_params.len, .is_opaque = struct_decl.is_opaque, .is_c_union = struct_decl.is_c_union }) catch {
            fields.deinit();
        };
    }

    fn collectPackedBits(self: *Checker, module: ast.Module, packed_bits: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .packed_bits_decl => |packed_bits_decl| self.collectLayoutFields(packed_bits_decl.name.text, packed_bits_decl.fields, packed_bits_decl.repr, packed_bits),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .union_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectOverlayUnions(self: *Checker, module: ast.Module, overlay_unions: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .overlay_union_decl => |overlay_union_decl| self.collectLayoutFields(overlay_union_decl.name.text, overlay_union_decl.fields, null, overlay_unions),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectTaggedUnions(self: *Checker, module: ast.Module, tagged_unions: *std.StringHashMap(UnionInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .union_decl => |union_decl| self.collectTaggedUnion(union_decl, tagged_unions),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectTaggedUnion(self: *Checker, union_decl: ast.UnionDecl, tagged_unions: *std.StringHashMap(UnionInfo)) void {
        if (tagged_unions.contains(union_decl.name.text)) return;
        var cases = std.StringHashMap(?ast.TypeExpr).init(self.reporter.allocator);
        for (union_decl.cases) |case| {
            if (!cases.contains(case.name.text)) cases.put(case.name.text, case.ty) catch {
                self.oom = true;
            };
        }
        tagged_unions.put(union_decl.name.text, .{ .cases = cases, .type_param_count = union_decl.type_params.len }) catch {
            cases.deinit();
        };
    }

    fn collectLayoutFields(self: *Checker, name: []const u8, fields_in: []const ast.Field, repr: ?ast.TypeExpr, infos: *std.StringHashMap(LayoutFieldInfo)) void {
        if (infos.contains(name)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (fields_in) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {
                self.oom = true;
            };
        }
        infos.put(name, .{ .fields = fields, .ordered = fields_in, .repr = repr }) catch {
            fields.deinit();
        };
    }

    fn collectFunctions(self: *Checker, module: ast.Module, functions: *std.StringHashMap(FunctionInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| {
                    if (!functions.contains(fn_decl.name.text)) functions.put(fn_decl.name.text, .{
                        .params = fn_decl.params,
                        .return_ty = fn_decl.return_type,
                        .is_extern = decl.kind == .extern_fn,
                        .no_lang_trap = hasNoLangTrap(decl.attrs),
                        .is_const = fn_decl.is_const,
                        .may_sleep = hasMaySleep(decl.attrs),
                        .irq_context = hasIrqContext(decl.attrs),
                        .error_from = error_from.hasAttr(decl.attrs),
                    }) catch {
                        self.oom = true;
                    };
                },
                .struct_decl, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectEnums(self: *Checker, module: ast.Module, enums: *std.StringHashMap(EnumInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .enum_decl => |enum_decl| self.collectEnum(enum_decl, enums),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectEnum(self: *Checker, enum_decl: ast.EnumDecl, enums: *std.StringHashMap(EnumInfo)) void {
        if (enums.contains(enum_decl.name.text)) return;
        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        for (enum_decl.cases) |case| {
            if (!cases.contains(case.name.text)) cases.put(case.name.text, {}) catch {
                self.oom = true;
            };
        }
        enums.put(enum_decl.name.text, .{ .cases = cases, .is_open = enum_decl.is_open, .repr = enum_decl.repr }) catch {
            cases.deinit();
        };
    }

    fn collectGlobals(self: *Checker, module: ast.Module, globals: *std.StringHashMap(GlobalInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| if (global.ty) |ty| {
                    if (!globals.contains(global.name.text)) globals.put(global.name.text, .{ .ty = ty }) catch {
                        self.oom = true;
                    };
                },
                .fn_decl, .extern_fn, .struct_decl, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectConstGlobalWidths(self: *Checker, module: ast.Module, widths: *std.StringHashMap(u16)) void {
        for (module.decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            if (!global.is_const) continue;
            const ty = global.ty orelse continue;
            const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
            widths.put(global.name.text, bits) catch {
                self.oom = true;
            };
        }
    }

    fn checkTopLevelNames(self: *Checker, module: ast.Module) void {
        var names = std.StringHashMap(void).init(self.reporter.allocator);
        defer names.deinit();

        for (module.decls) |decl| {
            // An `impl Trait for Type` record introduces no top-level name of its own
            // (its methods are separate `Type__m` fn_decls); skip the uniqueness check.
            if (decl.kind == .impl_trait) continue;
            const name = declName(decl);
            if (names.contains(name.text)) {
                self.errorCode(name.span, "E_DUPLICATE_DECLARATION", "top-level declarations must have unique names");
            } else {
                names.put(name.text, {}) catch {
                    self.oom = true;
                };
            }
            if (isCBackendReservedTopLevelName(decl.kind, name.text)) {
                self.errorCode(name.span, "E_RESERVED_C_IDENTIFIER", "identifier is reserved by the C backend or C headers; choose a different source name");
            }
            // A value-level top-level declaration (function or global) may not shadow a
            // module/impl owner name, or `Owner.member` would bind to the qualified symbol
            // instead of this value. Type declarations are exempt: an `impl T` owner IS the
            // type `T`. (Locals and parameters are reserved at their binding sites.)
            if (isValueLevelDecl(decl.kind) and self.isQualifiedOwner(name.text)) {
                self.errorCode(name.span, "E_RESERVED_QUALIFIED_NAME", "a top-level value may not shadow a module/impl name");
            }
        }
    }

    fn checkDecl(self: *Checker, decl: ast.Decl, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const no_lang_trap = hasNoLangTrap(decl.attrs);
        const irq_context = hasIrqContext(decl.attrs);
        const bounded = hasBoundedContext(decl.attrs);
        const is_naked = hasNaked(decl.attrs);
        const type_ctx = Context{ .mmio_structs = mmio_structs, .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .type_aliases = type_aliases };
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                const abi_boundary = decl.kind == .extern_fn or fn_decl.exported;
                self.checkFn(fn_decl, abi_boundary, no_lang_trap, irq_context, bounded, is_naked, mmio_structs, structs, packed_bits, overlay_unions, tagged_unions, enums, functions, globals, type_aliases);
                // T(term)1: bounded-loop / no-unbounded-recursion check for IRQ/atomic
                // and `#[bounded]` functions (opt-in; existing code is unaffected).
                if (hasBoundedContext(decl.attrs)) {
                    if (fn_decl.body) |body| self.checkTermination(fn_decl.name.text, body);
                }
            },
            .struct_decl => |struct_decl| {
                var struct_ctx = type_ctx;
                if (struct_decl.abi) |abi| {
                    struct_ctx.allow_mmio_register_type = std.mem.eql(u8, abi, "mmio");
                }
                self.checkStruct(struct_decl, struct_ctx);
            },
            .enum_decl => |enum_decl| self.checkEnum(enum_decl, type_ctx),
            .union_decl => |union_decl| self.checkTaggedUnion(union_decl, type_ctx),
            .packed_bits_decl => |packed_bits_decl| self.checkPackedBits(packed_bits_decl, type_ctx),
            .overlay_union_decl => |overlay_union_decl| self.checkOverlayUnion(overlay_union_decl, type_ctx),
            .type_alias => |alias| self.checkType(alias.ty, .normal, type_ctx),
            .opaque_decl => {},
            // Trait / impl-trait conformance checks run as their own pass (checkTraits);
            // the impl methods themselves are ordinary `Type__m` fn_decls checked above.
            .trait_decl, .impl_trait => {},
            .global_decl => |global| {
                const type_error_count = self.reporter.diagnostics.items.len;
                if (global.ty) |ty| {
                    self.checkType(ty, .storage, type_ctx);
                } else {
                    self.errorCode(global.name.span, "E_GLOBAL_REQUIRES_TYPE", "global declarations require an explicit storage type");
                    return;
                }
                const type_valid = self.reporter.diagnostics.items.len == type_error_count;
                if (global.init) |initializer| self.checkGlobalInitializer(global, initializer, type_valid, .{ .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .functions = functions, .globals = globals, .type_aliases = type_aliases });
            },
        }
    }

    fn checkEnum(self: *Checker, enum_decl: ast.EnumDecl, ctx: Context) void {
        const repr_class = if (enum_decl.repr) |repr| classifyTypeCtx(repr, ctx) else .checked_isize;
        const repr_bounds = checkedIntBounds(repr_class);
        if (enum_decl.repr) |repr| {
            self.checkType(repr, .normal, ctx);
            if (!isCheckedInt(repr_class)) {
                self.errorCode(repr.span, "E_ENUM_REPR_NOT_INTEGER", "enum representation type must be an integer type");
            }
        }

        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        defer cases.deinit();
        var values = std.AutoHashMap(EnumValueKey, void).init(self.reporter.allocator);
        defer values.deinit();

        for (enum_decl.cases) |case| {
            if (cases.contains(case.name.text)) {
                self.errorCode(case.name.span, "E_DUPLICATE_ENUM_CASE", "enum case names must be unique");
            } else {
                cases.put(case.name.text, {}) catch {
                    self.oom = true;
                };
            }
            if (case.value) |value| self.checkEnumCaseValue(value, repr_bounds, &values);
        }
    }

    fn checkEnumCaseValue(self: *Checker, value: ast.Expr, repr_bounds: ?IntBounds, values: *std.AutoHashMap(EnumValueKey, void)) void {
        _ = self.checkExpr(value, .{});
        const literal = integerLiteralValue(value) orelse {
            self.errorCode(value.span, "E_ENUM_CASE_VALUE_NOT_INTEGER", "enum representation values must be integer literals");
            return;
        };
        const key = enumValueKey(literal);
        if (repr_bounds) |bounds| {
            if (!enumValueFits(key, bounds)) {
                self.errorCode(value.span, "E_ENUM_CASE_VALUE_OUT_OF_RANGE", "enum case value is outside the representation type range");
            }
        }
        if (values.contains(key)) {
            self.errorCode(value.span, "E_DUPLICATE_ENUM_VALUE", "enum case representation values must be unique");
        } else {
            values.put(key, {}) catch {
                self.oom = true;
            };
        }
    }

    fn checkStruct(self: *Checker, struct_decl: ast.StructDecl, ctx_in: Context) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();

        // A generic struct's type parameters are valid type names in its fields.
        var type_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer type_params.deinit();
        for (struct_decl.type_params) |tp| type_params.put(tp.text, {}) catch {
            self.oom = true;
        };
        var ctx = ctx_in;
        if (struct_decl.type_params.len > 0) ctx.type_params = &type_params;

        var empty_aliases = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        defer empty_aliases.deinit();
        const aliases = ctx.type_aliases orelse &empty_aliases;

        for (struct_decl.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            // A linear `move` resource stored by value in a non-`move` struct escapes
            // linear tracking: the aggregate is copyable/leakable, so the resource could be
            // duplicated or dropped without being consumed. This also closes the generic
            // container hole — `Pool<Token, N>`, `Arc<Token>`, etc. monomorphize to a
            // non-move struct with a move-typed field and are rejected here. Hold a move
            // resource in another `move` type, or store it behind a pointer.
            if (self.typeIsMoveArray(field.ty, aliases)) {
                // An array of a `move` type as a field is not yet trackable — element moves need
                // the indexed-place model the checker does not have. Reject it in *any* struct,
                // including a `move` struct: otherwise `s.items[i]` could be moved out twice with
                // no use-after-move diagnostic (a double free). Hold the resources behind
                // pointers, or in a `move` container, until indexed move places exist.
                self.errorCode(field.ty.span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable as a struct field (element moves need place analysis); hold the resources behind pointers or in a `move` container instead");
            } else if (!struct_decl.is_move and self.typeEmbedsMoveByValue(field.ty, aliases)) {
                self.errorCode(field.ty.span, "E_MOVE_FIELD_IN_NONMOVE", "a linear `move` value cannot be stored by value in a non-`move` struct (it would be duplicated or leaked); make the struct `move`, or store the resource behind a pointer");
            }
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_FIELD", "struct field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    // ----- Linear `move`/liveness pass (section 18.1, annex D.7) -----
    //
    // Tracks each `move`-typed binding (params + locals) and enforces that it is
    // used linearly: consumed (moved) exactly once. A by-value use moves it; a
    // borrow (`&x`, `x.field`) does not. Using a moved value is E_USE_AFTER_MOVE;
    // a live binding reaching the end of the function is E_RESOURCE_LEAK. Not a
    // borrow checker — there are no lifetimes or aliasing analysis.

    fn isMoveTypeName(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        const move_types = self.move_types orelse return false;
        var cur = ty;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            switch (cur.kind) {
                .name => |n| {
                    if (move_types.contains(n.text)) return true;
                    if (aliases.get(n.text)) |target| {
                        cur = target;
                        continue;
                    }
                    return false;
                },
                .generic => |g| return move_types.contains(g.base.text),
                else => return false,
            }
        }
        return false;
    }

    // The `move struct` type NAME a type denotes (resolving aliases), or null. Like
    // isMoveTypeName but yields the name so it can be looked up in trivial_drop_types.
    pub fn moveTypeNameOf(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
        const move_types = self.move_types orelse return null;
        var cur = ty;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            switch (cur.kind) {
                .name => |n| {
                    if (move_types.contains(n.text)) return n.text;
                    if (aliases.get(n.text)) |target| {
                        cur = target;
                        continue;
                    }
                    return null;
                },
                .generic => |g| return if (move_types.contains(g.base.text)) g.base.text else null,
                else => return null,
            }
        }
        return null;
    }

    // Whether `ty` embeds a linear `move` resource *by value* — directly, in an array, or
    // behind a qualifier/nullable. A pointer or slice to a move type is NOT by-value (it
    // borrows; the resource lives elsewhere). Used to reject storing a move resource inside
    // a non-move aggregate, where it would escape linear tracking (and be duplicated or
    // leaked) — including a generic container monomorphized over a move type, e.g.
    // `Pool<Token, N>`'s `[N]Token` or `Arc<Token>`'s embedded value.
    pub fn typeEmbedsMoveByValue(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (ty.kind) {
            .name => return self.isMoveTypeName(ty, aliases),
            .generic => |g| {
                if (self.isMoveTypeName(ty, aliases)) return true; // a `move` generic (Arc<T>, …)
                // A built-in generic that stores its type arguments by value (e.g. Result<T,E>)
                // embeds a move resource if any argument does. (User generic structs aren't
                // handled here: they monomorphize to a concrete struct whose fields are checked
                // directly, and a move field in a non-`move` struct is rejected there.)
                if (genericHoldsArgsByValue(g.base.text)) {
                    for (g.args) |arg| {
                        if (self.typeEmbedsMoveByValue(arg, aliases)) return true;
                    }
                }
                return false;
            },
            .array => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .qualified => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .nullable => |child| return self.typeEmbedsMoveByValue(child.*, aliases),
            else => return false, // pointers, slices, fn/closure types: not by-value
        }
    }

    // Whether the resolved type is an array (possibly under a qualifier/nullable) whose element
    // embeds a `move` resource. Such a binding can't be tracked yet — element moves need the
    // place model — so it is rejected rather than silently allowed to duplicate/leak.
    pub fn typeIsMoveArray(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (ty.kind) {
            .array => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .qualified => |node| return self.typeIsMoveArray(node.child.*, aliases),
            .nullable => |child| return self.typeIsMoveArray(child.*, aliases),
            else => return false,
        }
    }

    fn checkTaggedUnion(self: *Checker, union_decl: ast.UnionDecl, ctx_in: Context) void {
        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        defer cases.deinit();

        var type_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer type_params.deinit();
        for (union_decl.type_params) |tp| type_params.put(tp.text, {}) catch {
            self.oom = true;
        };
        var ctx = ctx_in;
        if (union_decl.type_params.len > 0) ctx.type_params = &type_params;

        for (union_decl.cases) |case| {
            if (case.ty) |ty| self.checkType(ty, .storage, ctx);
            if (cases.contains(case.name.text)) {
                self.errorCode(case.name.span, "E_DUPLICATE_UNION_CASE", "safe tagged union case names must be unique");
            } else {
                cases.put(case.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkPackedBits(self: *Checker, packed_bits: ast.PackedBitsDecl, ctx: Context) void {
        self.checkType(packed_bits.repr, .normal, ctx);
        if (!isCheckedInt(classifyTypeCtx(packed_bits.repr, ctx))) {
            self.errorCode(packed_bits.repr.span, "E_PACKED_BITS_REPR_NOT_INTEGER", "packed bits representation type must be an integer type");
        }

        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();
        for (packed_bits.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            if (!isTypeName(field.ty, "bool")) {
                self.errorCode(field.ty.span, "E_PACKED_BITS_FIELD_NOT_BOOL", "packed bits fields must be bool");
            }
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_PACKED_BITS_FIELD", "packed bits field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkOverlayUnion(self: *Checker, overlay_union: ast.OverlayUnionDecl, ctx: Context) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();
        for (overlay_union.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_OVERLAY_FIELD", "overlay union field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkGlobalInitializer(self: *Checker, global: ast.GlobalDecl, initializer: ast.Expr, type_valid: bool, ctx: Context) void {
        const errors_before = self.reporter.diagnostics.items.len;
        const source = self.checkExpr(initializer, ctx);
        const ty = global.ty orelse {
            if (isNullLiteral(initializer)) {
                self.errorCode(initializer.span, "E_NULL_REQUIRES_TARGET", "null requires an explicit nullable pointer target type");
            }
            _ = self.checkTargetlessLiteralInitializer(initializer);
            return;
        };
        const target = classifyTypeCtx(ty, ctx);
        if (isUninitLiteral(initializer)) {
            self.errorCode(initializer.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const literal_checked = self.checkIntegerLiteralInitializer(target, ty, initializer, ctx);
        const null_checked = self.checkNullPointerInitializer(target, initializer);
        const array_literal_checked = self.checkArrayLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, initializer);
        const pointer_conversion_checked = self.checkPointerViewInitializer(ty, initializer, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(ty, initializer, ctx);
        const address_checked = self.checkAddressOfInitializer(target, ty, initializer, ctx);
        const fn_pointer_checked = self.checkFunctionPointerInitializer(ty, initializer, ctx);
        const closure_checked = self.checkClosureInitializer(ty, initializer, ctx);
        const address_class_checked = checkAddressClassConversion(self, initializer.span, target, source);
        const enum_checked = self.checkEnumValueCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion") else false;
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(ty, initializer, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target, source)) {
            self.errorCode(initializer.span, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        }
        // A typed global initializer is static when it is either a C static
        // initializer or folds through the section-22 comptime evaluator. The
        // latter admits expressions like `1 + 2` and const-fn aggregate builders
        // while still rejecting runtime calls.
        const folds_static = self.comptimeConstantFolds(initializer);
        if (type_valid and self.reporter.diagnostics.items.len == errors_before and !isStaticGlobalInitializer(initializer, ctx) and !folds_static) {
            self.errorCode(initializer.span, "E_GLOBAL_INITIALIZER_NOT_STATIC", "global initializer must be a compile-time static value for M0 C emission");
        }
    }

    fn comptimeConstantFolds(self: *Checker, expr: ast.Expr) bool {
        var fb_arena: ?std.heap.ArenaAllocator = null;
        defer if (fb_arena) |*a| a.deinit();
        const fold_alloc = eval.tryFoldScratch() orelse blk: {
            fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            break :blk fb_arena.?.allocator();
        };
        defer if (fb_arena == null) eval.releaseFoldScratch();
        var scope = eval.ComptimeScope.init(fold_alloc);
        self.seedComptimeScope(&scope);
        if (scope.hasOom()) {
            self.noteComptimeOom(&scope);
            return false;
        }
        const folds = switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => true,
            else => false,
        };
        self.noteComptimeOom(&scope);
        return folds;
    }

    fn seedComptimeScope(self: *Checker, scope: *eval.ComptimeScope) void {
        scope.funcs = self.const_fns;
        scope.globals = self.const_globals;
        if (self.reflect_env) |env| {
            scope.reflect = sema_reflect.comptimeReflectThunk;
            scope.reflect_ctx = @constCast(env);
        }
        if (self.const_global_widths) |widths| {
            var it = widths.iterator();
            while (it.next()) |entry| {
                scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*) catch {
                    self.oom = true;
                    return;
                };
            }
        }
    }

    fn noteComptimeOom(self: *Checker, scope: *const eval.ComptimeScope) void {
        if (scope.hasOom()) self.oom = true;
    }

    fn checkFn(self: *Checker, fn_decl: ast.FnDecl, abi_boundary: bool, no_lang_trap: bool, irq_context: bool, bounded: bool, is_naked: bool, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        self.current_fn_name = fn_decl.name.text;
        defer self.current_fn_name = null;
        var scope = Scope.init(self.reporter.allocator);
        defer scope.deinit();
        // G20 block-scoping: params + the fn-body's top-level locals live in the base scope for
        // the whole function. Reset the liveness stack per function (nested blocks push/pop their
        // own markers); it is emptied again when the function returns.
        self.live_locals.clearRetainingCapacity();
        defer self.live_locals.clearRetainingCapacity();
        var mmio_params = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer mmio_params.deinit();

        // Collect `comptime T: type` type parameters first, so the rest of the
        // signature and body may use them as type names (user-defined generics).
        var type_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer type_params.deinit();
        var comptime_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer comptime_params.deinit();
        for (fn_decl.params) |param| {
            if (param.is_comptime and isTypeName(param.ty, "type")) {
                type_params.put(param.name.text, {}) catch {
                    self.oom = true;
                };
            } else if (param.is_comptime) {
                comptime_params.put(param.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
        const sig_ctx = Context{ .mmio_structs = mmio_structs, .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .type_aliases = type_aliases, .type_params = &type_params, .trait_bounds = fn_decl.bounds, .comptime_params = &comptime_params };
        if (abi_boundary) self.checkExternExportStructAbi(fn_decl, sig_ctx);

        for (fn_decl.params) |param| {
            self.checkType(param.ty, .storage, sig_ctx);
            if (isCBackendReservedLocalName(param.name.text)) {
                self.errorCode(param.name.span, "E_RESERVED_C_IDENTIFIER", "parameter name is reserved by the C backend or C headers; choose a different source name");
            } else if (self.isQualifiedOwner(param.name.text)) {
                self.errorCode(param.name.span, "E_RESERVED_QUALIFIED_NAME", "a parameter may not shadow a module/impl name");
            } else if (scope.contains(param.name.text)) {
                self.errorCode(param.name.span, "E_DUPLICATE_PARAMETER", "function parameter names must be unique");
            } else {
                const param_class = classifyTypeCtx(param.ty, sig_ctx);
                const param_address_origin: AddressOrigin = if (param_class == .closure) .local else .none;
                scope.put(param.name.text, .{ .class = param_class, .mutable = false, .ty = param.ty, .origin = .param, .address_origin = param_address_origin }) catch {
                    self.oom = true;
                };
                // Params are live for the whole body, so a local may not shadow one (G20).
                self.pushLiveLocal(param.name.text);
                if (mmioPointee(param.ty)) |struct_name| mmio_params.put(param.name.text, struct_name) catch {
                    self.oom = true;
                };
            }
        }
        const return_kind = if (fn_decl.return_type) |ty| classifyTypeCtx(ty, sig_ctx) else TypeClass.void;
        const returns_never = if (fn_decl.return_type) |ty| blk: {
            self.checkType(ty, .return_type, sig_ctx);
            break :blk isTypeName(ty, "never");
        } else false;
        const returns_void = if (fn_decl.return_type) |ty| isTypeName(ty, "void") else false;
        if (is_naked) {
            // `#[naked]` emits no prologue/epilogue: the body is a single `asm` block
            // that owns the entire calling convention. Anything else has no frame to
            // live in, and a value return cannot be synthesized. The body is an
            // implicit strict-unsafe context (the `asm` needs no `unsafe {}` wrapper),
            // wired below via `.in_unsafe = is_naked`.
            if (fn_decl.return_type != null and !returns_never and !returns_void) {
                self.errorCode(fn_decl.name.span, "E_NAKED_RETURN", "a #[naked] function must return `never` or `void`; it cannot synthesize a value return (the asm body owns the calling convention)");
            }
            if (fn_decl.body) |body| {
                if (ast_query.nakedAsmStmt(body) == null) {
                    const span = if (body.items.len > 0) body.items[0].span else fn_decl.name.span;
                    self.errorCode(span, "E_NAKED_BODY", "a #[naked] function body must be exactly one `asm` block (optionally wrapped in one `unsafe {}`); there is no frame for locals, statements, or expressions");
                }
            }
        }
        if (fn_decl.body) |body| {
            const fn_ctx = Context{
                .no_lang_trap = no_lang_trap,
                .irq_context = irq_context,
                .bounded = bounded,
                .in_unsafe = is_naked,
                .returns_never = returns_never,
                .returns_void = returns_void,
                .return_ty = fn_decl.return_type,
                .return_kind = return_kind,
                .unsafe_contracts = .{},
                .scope = &scope,
                .mmio_structs = mmio_structs,
                .mmio_params = &mmio_params,
                .structs = structs,
                .packed_bits = packed_bits,
                .overlay_unions = overlay_unions,
                .tagged_unions = tagged_unions,
                .enums = enums,
                .type_aliases = type_aliases,
                .functions = functions,
                .globals = globals,
                .const_fns = self.const_fns,
                .const_globals = self.const_globals,
                .type_params = &type_params,
                .trait_bounds = fn_decl.bounds,
                .comptime_params = &comptime_params,
                .trait_decls = self.trait_decls,
            };
            self.checkBlock(body, fn_ctx);
            // A #[naked] body is a single `asm` block that transfers control itself
            // (a jump, an ABI-correct `ret`, or a divergence). There is no synthesized
            // return to fall through to, so the normal return-path obligation does not
            // apply — the asm is the terminator.
            if (!is_naked) {
                if (fallthroughSpan(body, fn_ctx)) |span| {
                    if (returns_never) {
                        self.errorCode(span, "E_NEVER_FALLTHROUGH", "function declared -> never can fall off the end");
                    } else if (fn_decl.return_type != null and !returns_void) {
                        self.errorCode(span, "E_RETURN_MISSING", "function return type requires all paths to return a value");
                    }
                }
            }
        }
    }

    fn checkExternExportStructAbi(self: *Checker, fn_decl: ast.FnDecl, ctx: Context) void {
        const include_plain_structs = true;
        for (fn_decl.params) |param| {
            if (isByValueStructAbiType(param.ty, ctx, include_plain_structs)) {
                self.errorCode(param.ty.span, "E_EXTERN_STRUCT_BY_VALUE", "extern/export functions cannot pass structs by value until C ABI classification is implemented; pass a pointer instead");
            }
        }
        if (fn_decl.return_type) |ret_ty| {
            if (isByValueStructAbiType(ret_ty, ctx, include_plain_structs)) {
                self.errorCode(ret_ty.span, "E_EXTERN_STRUCT_BY_VALUE", "extern/export functions cannot return structs by value until C ABI classification is implemented; return through an out pointer instead");
            }
        }
    }

    // ----- Definite-initialization pass (S0.1) ---------------------------------
    //
    // A typed `var x: T = uninit;` declares storage whose bytes are unspecified;
    // reading it before it is definitely assigned on every control-flow path is a
    // compile error (E_USE_BEFORE_INIT), not a runtime hazard. This is the flow-
    // sensitive "definite assignment" check.
    //
    // State is the set of *pending* names: `uninit` vars declared but not yet
    // proven assigned on the current path. A pending name is:
    //   - removed when it is the whole target of an assignment `x = …` (now assigned),
    //   - kept pending when only its address/member/index storage is used, because
    //     the DI pass does not prove that every byte of the aggregate was written,
    //   - reported (E_USE_BEFORE_INIT) when it is read as a plain value.
    //
    // Aggregates are tracked at the root-storage level only. This pass does not track
    // per-field/per-element coverage, so a member/index write or address-taking
    // operation is not enough evidence for later value reads. Scalars and aggregates
    // both require a direct whole-variable assignment edge to become initialized.
    //
    // Branches (if/else, switch — `if` desugars to a switch on the bool) intersect:
    // a name is assigned after the branch only if assigned on every arm that falls
    // through to the join. A diverging arm (ends in return/break/continue/unreachable)
    // contributes nothing to the join. Loops are conservative: a body assignment is
    // not guaranteed (the loop may run zero times), so pending state is restored
    // after the loop. Reads inside the body are still checked.
    const DefInitPendingKind = enum {
        scalar,
        aggregate,
    };

    const DefInitFactKind = enum {
        pending_scalar,
        pending_aggregate,
        initialized_element,
    };

    const DefInitFact = struct {
        span: diagnostics.Span,
        kind: DefInitFactKind,
        array_len: ?usize = null,
    };

    const DefInitState = std.StringHashMap(DefInitFact);

    // A collected `defer EXPR`. `live_before` is the number of defers already collected when
    // this one was declared — equivalently, this defer's own index — used to scope it to the
    // exit edges that occur while it is live.
    const DiDefer = struct {
        expr: ast.Expr,
        live_before: usize,
    };

    // A snapshot of the still-pending (uninit) names at one exit edge, plus how many defers
    // were live there. Owns its `pending` map.
    const DiExitSnapshot = struct {
        pending: DefInitState,
        live_defers: usize,
    };

    fn checkDefiniteInit(self: *Checker, fn_decl: ast.FnDecl, ctx: Context) void {
        const body = fn_decl.body orelse return;
        var pending = DefInitState.init(self.reporter.allocator);
        defer pending.deinit();
        defer {
            for (self.di_place_keys.items) |key| self.reporter.allocator.free(key);
            self.di_place_keys.deinit(self.reporter.allocator);
            self.di_place_keys = .empty;
        }
        // Collect defer bodies during the walk instead of reading them in place; they
        // execute at scope exit, so their reads are checked against the EXIT state(s).
        var defers: std.ArrayListUnmanaged(DiDefer) = .empty;
        defer defers.deinit(self.reporter.allocator);
        // Exit-edge snapshots (return / `?` propagation) captured while defers are live.
        var exits: std.ArrayListUnmanaged(DiExitSnapshot) = .empty;
        defer {
            for (exits.items) |*s| s.pending.deinit();
            exits.deinit(self.reporter.allocator);
        }
        const prev = self.di_defers;
        const prev_exits = self.di_exits;
        self.di_defers = &defers;
        self.di_exits = &exits;
        defer self.di_defers = prev;
        defer self.di_exits = prev_exits;
        const diverged = self.diBlock(body, &pending, ctx);
        // The fall-through exit is itself an edge a defer can run on (unless the body always
        // diverges first). Record it so the meet below includes it.
        if (!diverged) self.diRecordExit(&pending, defers.items.len);
        // For each defer, a name it reads is use-before-init if that name is still pending on
        // ANY exit edge where the defer is live (meet = union of pending across those edges).
        // This restores the early-return/`?` catch the prior fall-through-only check dropped,
        // while still accepting a var assigned on every edge the defer actually runs on.
        for (defers.items) |d| {
            var meet = DefInitState.init(self.reporter.allocator);
            defer meet.deinit();
            for (exits.items) |*snap| {
                if (snap.live_defers <= d.live_before) continue; // defer not yet live at this edge
                self.diMerge(&meet, &snap.pending);
            }
            self.diRead(d.expr, &meet, ctx);
        }
    }

    // Capture the current pending set as an exit-edge snapshot (only meaningful inside a DI
    // pass with the accumulator installed). `live_defers` is the count of defers live here.
    fn diRecordExit(self: *Checker, state: *const DefInitState, live_defers: usize) void {
        const exits = self.di_exits orelse return;
        exits.append(self.reporter.allocator, .{
            .pending = self.diCloneState(state),
            .live_defers = live_defers,
        }) catch {
            self.oom = true;
        };
    }

    fn diCloneState(self: *Checker, state: *const DefInitState) DefInitState {
        var clone = DefInitState.init(self.reporter.allocator);
        var it = state.iterator();
        while (it.next()) |entry| {
            clone.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
        return clone;
    }

    fn diReplaceState(self: *Checker, dest: *DefInitState, src: *const DefInitState) void {
        dest.clearRetainingCapacity();
        var it = src.iterator();
        while (it.next()) |entry| {
            dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    // Analyze a block's statements in order. Returns whether the block diverges
    // (every path through it ends in return/break/continue/unreachable), so the
    // join after it is unreachable.
    fn diBlock(self: *Checker, block: ast.Block, state: *DefInitState, ctx: Context) bool {
        for (block.items) |stmt| {
            if (self.diStmt(stmt, state, ctx)) return true;
        }
        return false;
    }

    // Returns whether the statement diverges.
    fn diStmt(self: *Checker, stmt: ast.Stmt, state: *DefInitState, ctx: Context) bool {
        switch (stmt.kind) {
            .var_decl => |decl| {
                if (decl.init) |init_expr| {
                    if (isUninitLiteral(init_expr)) {
                        // A typed `var x: T = uninit;` becomes pending until definitely
                        // assigned as a whole value.
                        if (decl.ty) |ty| {
                            if (diPendingKindForType(ty, ctx)) |kind| {
                                for (decl.names) |name| {
                                    const fact_kind: DefInitFactKind = switch (kind) {
                                        .scalar => .pending_scalar,
                                        .aggregate => .pending_aggregate,
                                    };
                                    const arr = if (fact_kind == .pending_aggregate) fixedArrayType(resolveAliasType(ty, ctx), ctx.const_fns, ctx.const_globals) else null;
                                    state.put(name.text, .{ .span = name.span, .kind = fact_kind, .array_len = if (arr) |a| a.len else null }) catch {
                                        self.oom = true;
                                    };
                                }
                            }
                        }
                    } else {
                        self.diRead(init_expr, state, ctx);
                        if (diExprMayMutateThroughCall(init_expr)) self.diRemoveDynamicElementFacts(state);
                    }
                }
                return false;
            },
            .let_decl => |decl| {
                if (decl.init) |init_expr| {
                    self.diRead(init_expr, state, ctx);
                    if (diExprMayMutateThroughCall(init_expr)) self.diRemoveDynamicElementFacts(state);
                }
                return false;
            },
            .assignment => |a| {
                // The value is read first; then the target may become assigned.
                self.diRead(a.value, state, ctx);
                switch (a.target.kind) {
                    .ident => |id| {
                        // Whole-variable assignment: the pending var is now definitely set.
                        _ = state.remove(id.text);
                        self.diRemoveDynamicElementFacts(state);
                    },
                    else => {
                        // Member/deref targets stay address-like storage uses. Array element
                        // targets can prove either one stable element, or the whole fixed array
                        // once every constant element has been written.
                        if (!self.diMarkArrayElementAssignment(a.target, state, ctx)) {
                            self.diUseTarget(a.target, state, ctx);
                        }
                    },
                }
                return false;
            },
            .@"return" => |maybe| {
                if (maybe) |e| self.diRead(e, state, ctx);
                // A defer runs on the way out of this early-return edge; snapshot the pending
                // set (with the return value already read/cleared) so its reads are checked
                // against the state a deferred body would actually observe here.
                self.diRecordExit(state, (self.di_defers orelse return true).items.len);
                return true;
            },
            .@"break", .@"continue" => return true,
            .expr => |e| {
                self.diRead(e, state, ctx);
                if (diExprMayMutateThroughCall(e)) self.diRemoveDynamicElementFacts(state);
                // An expression that cannot fall through (`unreachable`, `trap(...)`, a
                // `-> never` call) ends this path, like `return`.
                if (!exprMayFallThrough(e, ctx) or exprIsNeverCall(e, ctx)) return true;
                return false;
            },
            .assert => |e| {
                self.diRead(e, state, ctx);
                if (diExprMayMutateThroughCall(e)) self.diRemoveDynamicElementFacts(state);
                return false;
            },
            .@"defer" => |e| {
                // (bug #3) Do NOT read here — a defer runs at scope exit, after the rest
                // of the block. Collect it; checkDefiniteInit evaluates it against the
                // exit init-state. (If di_defers is unset we fall back to in-place reads.)
                if (self.di_defers) |defers| {
                    // `live_before` = this defer's index. A defer is live (runs) on exit edges
                    // recorded AFTER it; snapshots whose live_defers <= live_before predate it
                    // and are skipped when computing its read-meet.
                    defers.append(self.reporter.allocator, .{ .expr = e, .live_before = defers.items.len }) catch {
                        self.oom = true;
                    };
                } else {
                    self.diRead(e, state, ctx);
                }
                return false;
            },
            .block, .unsafe_block, .comptime_block => |b| return self.diBlock(b, state, ctx),
            .contract_block => |c| return self.diBlock(c.block, state, ctx),
            .loop => |l| {
                if (l.iterable) |iter| self.diRead(iter, state, ctx);
                // Conservative: a body assignment may not run (zero iterations), so the
                // outer pending set is restored afterwards. Reads inside the body are still
                // checked against the entry state.
                var body_state = self.diCloneState(state);
                defer body_state.deinit();
                _ = self.diBlock(l.body, &body_state, ctx);
                // The loop may run zero times, so control always falls through.
                return false;
            },
            .if_let => |n| {
                self.diRead(n.value, state, ctx);
                var then_state = self.diCloneState(state);
                defer then_state.deinit();
                const then_div = self.diBlock(n.then_block, &then_state, ctx);
                var else_state = self.diCloneState(state);
                defer else_state.deinit();
                var else_div = false;
                if (n.else_block) |eb| {
                    else_div = self.diBlock(eb, &else_state, ctx);
                }
                self.diJoin(state, &then_state, then_div, &else_state, else_div);
                return then_div and (n.else_block != null) and else_div;
            },
            .@"switch" => |sw| {
                self.diRead(sw.subject, state, ctx);
                var joined: ?DefInitState = null;
                defer if (joined) |*m| m.deinit();
                var any_arm = false;
                var all_diverge = true;
                for (sw.arms) |arm| {
                    any_arm = true;
                    var arm_state = self.diCloneState(state);
                    defer arm_state.deinit();
                    const arm_div = switch (arm.body) {
                        .block => |b| self.diBlock(b, &arm_state, ctx),
                        .expr => |e| blk: {
                            self.diRead(e, &arm_state, ctx);
                            break :blk false;
                        },
                    };
                    if (!arm_div) {
                        all_diverge = false;
                        if (joined) |*m| {
                            self.diMerge(m, &arm_state);
                        } else {
                            joined = self.diCloneState(&arm_state);
                        }
                    }
                }
                if (joined) |*m| self.diReplaceState(state, m);
                return any_arm and all_diverge;
            },
            .asm_stmt => return false,
        }
    }

    // Join two arms into `dest`. A diverging arm does not reach the join, so it
    // contributes nothing; only arms that fall through are intersected (a name is
    // assigned after the branch only if assigned on every reaching arm — i.e. it is
    // pending after the branch if it is still pending on any reaching arm).
    fn diJoin(self: *Checker, dest: *DefInitState, left: *const DefInitState, left_div: bool, right: *const DefInitState, right_div: bool) void {
        if (left_div and right_div) return; // join unreachable; leave dest as-is
        if (left_div) {
            self.diReplaceState(dest, right);
            return;
        }
        if (right_div) {
            self.diReplaceState(dest, left);
            return;
        }
        var merged = self.diCloneState(left);
        defer merged.deinit();
        self.diMerge(&merged, right);
        self.diReplaceState(dest, &merged);
    }

    // Merge `other` into `dest` as the union of pending names (a name is pending after
    // the join if it is still pending on EITHER reaching arm — assigned only if
    // assigned on BOTH).
    fn diMerge(self: *Checker, dest: *DefInitState, other: *const DefInitState) void {
        var prune: std.ArrayListUnmanaged([]const u8) = .empty;
        defer prune.deinit(self.reporter.allocator);
        var existing = dest.iterator();
        while (existing.next()) |entry| {
            if (entry.value_ptr.kind != .initialized_element) continue;
            if (!diElementFactSurvives(entry.key_ptr.*, other)) {
                prune.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
        }
        for (prune.items) |key| _ = dest.remove(key);

        var it = other.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .initialized_element) {
                if (!diElementFactSurvives(entry.key_ptr.*, dest)) continue;
            }
            dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    // Walk an expression evaluated for its value, reporting a read of any pending var
    // before whole assignment. Address-like storage uses are handled separately and
    // do not prove initialization.
    fn diRead(self: *Checker, expr: ast.Expr, state: *DefInitState, ctx: Context) void {
        switch (expr.kind) {
            .ident => |id| {
                if (state.get(id.text)) |pending| {
                    _ = pending;
                    self.errorCode(expr.span, "E_USE_BEFORE_INIT", "variable initialized with `uninit` is read before it is definitely initialized on all paths");
                }
            },
            .address_of => |inner| self.diUseTarget(inner.*, state, ctx),
            .grouped => |inner| self.diRead(inner.*, state, ctx),
            .unary => |u| self.diRead(u.expr.*, state, ctx),
            .binary => |b| {
                self.diRead(b.left.*, state, ctx);
                self.diRead(b.right.*, state, ctx);
            },
            .cast => |c| self.diRead(c.value.*, state, ctx),
            .call => |c| {
                if (diStorageMethodBase(c.callee.*)) |base| {
                    self.diUseTarget(base, state, ctx);
                } else {
                    self.diRead(c.callee.*, state, ctx);
                }
                for (c.args) |arg| self.diRead(arg, state, ctx);
            },
            .index => |n| {
                self.diRead(n.index.*, state, ctx);
                if (!self.diIndexReadProvenInitialized(expr, state, ctx)) {
                    self.diRead(n.base.*, state, ctx);
                }
            },
            .slice => |n| {
                self.diRead(n.base.*, state, ctx);
                self.diRead(n.start.*, state, ctx);
                self.diRead(n.end.*, state, ctx);
            },
            .deref => |inner| self.diRead(inner.*, state, ctx),
            .member => |m| self.diRead(m.base.*, state, ctx),
            .array_literal => |items| for (items) |item| self.diRead(item, state, ctx),
            .struct_literal => |fields| for (fields) |field| self.diRead(field.value, state, ctx),
            .block => |b| {
                var inner = self.diCloneState(state);
                defer inner.deinit();
                _ = self.diBlock(b, &inner, ctx);
            },
            .try_expr => |t| {
                self.diRead(t.operand.*, state, ctx);
                if (t.mapped) |m| self.diRead(m.*, state, ctx);
                // `EXPR?` propagates on the error path, exiting the function: a live defer
                // runs on that edge. Snapshot the pending set so deferred reads are checked
                // against it too (an early `?`-exit can leave a var uninit, same as `return`).
                if (self.di_defers) |defers| self.diRecordExit(state, defers.items.len);
            },
            else => {},
        }
    }

    // An assignment/address-of target (or a base used as storage). Storage use alone
    // does not manufacture an initialized value: member/index writes may cover only
    // part of an aggregate, and address-taking/out-param calls have no DI-visible
    // contract proving that the callee wrote every byte. Only whole-variable
    // assignment clears pending state. Index subexpressions are still read-checked.
    fn diUseTarget(self: *Checker, target: ast.Expr, state: *DefInitState, ctx: Context) void {
        switch (target.kind) {
            .ident => {},
            .grouped => |inner| self.diUseTarget(inner.*, state, ctx),
            .member => |m| self.diUseTarget(m.base.*, state, ctx),
            .index => |n| {
                self.diUseTarget(n.base.*, state, ctx);
                self.diRead(n.index.*, state, ctx);
            },
            .deref => |inner| self.diRead(inner.*, state, ctx),
            else => self.diRead(target, state, ctx),
        }
    }

    fn diMarkArrayElementAssignment(self: *Checker, target: ast.Expr, state: *DefInitState, ctx: Context) bool {
        const ix = switch (target.kind) {
            .index => |node| node,
            .grouped => |inner| return self.diMarkArrayElementAssignment(inner.*, state, ctx),
            else => return false,
        };
        self.diUseTarget(target, state, ctx);
        const root = diPendingAggregateRoot(ix.base.*, state) orelse return true;
        if (constIndexLiteral(ix.index.*)) |k| {
            const len = diFixedArrayLenForRoot(root, state) orelse return true;
            if (k >= len) return true;
            self.diPutElementFact(state, target.span, root, ix.index.*, k);
            if (self.diAllConstElementsInitialized(state, root, len)) {
                _ = state.remove(root);
                self.diRemoveElementFacts(state, root);
            }
            return true;
        }
        if (diPureIndexExpr(ix.index.*)) {
            self.diPutElementFact(state, target.span, root, ix.index.*, null);
        }
        return true;
    }

    fn diIndexReadProvenInitialized(self: *Checker, expr: ast.Expr, state: *DefInitState, ctx: Context) bool {
        const ix = switch (expr.kind) {
            .index => |node| node,
            .grouped => |inner| return self.diIndexReadProvenInitialized(inner.*, state, ctx),
            else => return false,
        };
        const root = diPendingAggregateRoot(ix.base.*, state) orelse return false;
        if (constIndexLiteral(ix.index.*)) |k| {
            if (self.diHasElementFact(state, root, ix.index.*, k)) return true;
            return false;
        }
        if (!diPureIndexExpr(ix.index.*)) return false;
        return self.diHasElementFact(state, root, ix.index.*, null);
    }

    fn diPutElementFact(self: *Checker, state: *DefInitState, span: diagnostics.Span, root: []const u8, index: ast.Expr, const_index: ?usize) void {
        const key = self.diOwnedElementKey(root, index, const_index) orelse return;
        state.put(key, .{ .span = span, .kind = .initialized_element }) catch {
            self.oom = true;
        };
    }

    fn diHasElementFact(self: *Checker, state: *const DefInitState, root: []const u8, index: ast.Expr, const_index: ?usize) bool {
        const key = self.diTempElementKey(root, index, const_index) orelse return false;
        defer self.reporter.allocator.free(key);
        return state.get(key) != null;
    }

    fn diAllConstElementsInitialized(self: *Checker, state: *const DefInitState, root: []const u8, len: usize) bool {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}\x1f#{d}", .{ root, i }) catch {
                self.oom = true;
                return false;
            };
            defer self.reporter.allocator.free(key);
            if (state.get(key) == null) return false;
        }
        return true;
    }

    fn diRemoveElementFacts(self: *Checker, state: *DefInitState, root: []const u8) void {
        const prefix = std.fmt.allocPrint(self.reporter.allocator, "{s}\x1f", .{root}) catch {
            self.oom = true;
            return;
        };
        defer self.reporter.allocator.free(prefix);
        var remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer remove.deinit(self.reporter.allocator);
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .initialized_element and std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                remove.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
        }
        for (remove.items) |key| _ = state.remove(key);
    }

    fn diRemoveDynamicElementFacts(self: *Checker, state: *DefInitState) void {
        var remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer remove.deinit(self.reporter.allocator);
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind != .initialized_element) continue;
            const sep = std.mem.indexOfScalar(u8, entry.key_ptr.*, 0x1f) orelse continue;
            if (sep + 1 < entry.key_ptr.*.len and entry.key_ptr.*[sep + 1] == '#') continue;
            remove.append(self.reporter.allocator, entry.key_ptr.*) catch {
                self.oom = true;
            };
        }
        for (remove.items) |key| _ = state.remove(key);
    }

    fn diOwnedElementKey(self: *Checker, root: []const u8, index: ast.Expr, const_index: ?usize) ?[]const u8 {
        const key = self.diTempElementKey(root, index, const_index) orelse return null;
        self.di_place_keys.append(self.reporter.allocator, key) catch {
            self.reporter.allocator.free(key);
            self.oom = true;
            return null;
        };
        return key;
    }

    fn diTempElementKey(self: *Checker, root: []const u8, index: ast.Expr, const_index: ?usize) ?[]const u8 {
        if (const_index) |k| {
            return std.fmt.allocPrint(self.reporter.allocator, "{s}\x1f#{d}", .{ root, k }) catch {
                self.oom = true;
                return null;
            };
        }
        const text = self.diIndexSourceText(index) orelse return null;
        return std.fmt.allocPrint(self.reporter.allocator, "{s}\x1f{s}", .{ root, text }) catch {
            self.oom = true;
            return null;
        };
    }

    fn diIndexSourceText(self: *Checker, index: ast.Expr) ?[]const u8 {
        const end = std.math.add(usize, index.span.offset, index.span.len) catch return null;
        if (end > self.reporter.source.len) return null;
        return std.mem.trim(u8, self.reporter.source[index.span.offset..end], " \t\r\n");
    }

    fn checkBlock(self: *Checker, block: ast.Block, ctx: Context) void {
        for (block.items) |stmt| self.checkStmt(stmt, ctx);
        self.checkUnhandledResultLocals(block, ctx);
    }

    // A nested `{ ... }` block: its `let`/`var` locals are scoped to the block, so a disjoint
    // sibling block may reuse their names (G20). The fn's TOP-LEVEL body is checked via plain
    // `checkBlock` (its locals stay live for the whole body — there is no sibling at that level,
    // and post-body fall-through analysis still needs them live).
    fn checkBlockScoped(self: *Checker, block: ast.Block, ctx: Context) void {
        const mark = self.enterScope();
        self.checkBlock(block, ctx);
        self.leaveScope(mark);
    }

    // Section 22: const-fold the scalar subset of a comptime block. Binds
    // comptime `let`/`var` constants and evaluates `assert(...)` conditions,
    // reporting E_COMPTIME_TRAP when an assertion is provably false or the
    // const evaluation itself traps (divide-by-zero, invalid shift). Statements
    // outside the constant subset are skipped — they are not provably wrong, so
    // they produce no diagnostic here (effect rules are enforced by checkBlock).
    fn foldComptimeBlock(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope) void {
        self.foldComptimeBlockAt(block, scope, null);
    }

    // `report_span`, when set, redirects E_COMPTIME_TRAP to that span — used when
    // re-checking a callee's comptime assertions at a call site (section 22
    // comptime parameters), so the failure points at the call, not the callee.
    fn foldComptimeBlockAt(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope, report_span: ?diagnostics.Span) void {
        for (block.items) |stmt| {
            const span = report_span orelse stmt.span;
            switch (stmt.kind) {
                .let_decl, .var_decl => |local| {
                    if (local.names.len != 1) continue;
                    const init_expr = local.init orelse continue;
                    // `var x: T = uninit;` (e.g. an expression-`switch` desugar temp): bind a
                    // void placeholder so a following assignment can fill it.
                    if (init_expr.kind == .uninit_literal) {
                        scope.bind(local.names[0].text, .void) catch {
                            self.noteComptimeOom(scope);
                            return;
                        };
                        if (local.ty) |lty| scope.bindTypeInfo(local.names[0].text, lty) catch {
                            self.noteComptimeOom(scope);
                            return;
                        };
                        continue;
                    }
                    switch (eval.foldComptimeExpr(scope, init_expr)) {
                        .value => |value| {
                            scope.bind(local.names[0].text, value) catch {
                                self.noteComptimeOom(scope);
                                return;
                            };
                            if (local.ty) |lty| scope.bindTypeInfo(local.names[0].text, lty) catch {
                                self.noteComptimeOom(scope);
                                return;
                            };
                        },
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                        .unknown => {},
                    }
                },
                .assert => |expr| {
                    switch (eval.foldComptimeExpr(scope, expr)) {
                        .value => |value| {
                            if (value == .boolean and !value.boolean) {
                                self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                            }
                        },
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                        .unknown => {},
                    }
                },
                .expr => |expr| {
                    // `comptime_error("message")` as a block statement: a custom compile-time
                    // diagnostic (section 22), better than the generic trap for documenting a
                    // failed generic constraint.
                    if (comptimeErrorMessage(expr)) |msg| {
                        self.errorCode(span, "E_COMPTIME_ERROR", msg);
                        continue;
                    }
                    var single = [_]ast.Stmt{stmt};
                    switch (eval.foldComptimeBlock(scope, .{ .span = stmt.span, .items = &single })) {
                        .ok, .unknown => {},
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                    }
                },
                .assignment, .loop, .@"switch" => {
                    var single = [_]ast.Stmt{stmt};
                    switch (eval.foldComptimeBlock(scope, .{ .span = stmt.span, .items = &single })) {
                        .ok, .unknown => {},
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                    }
                },
                // A comptime block may nest plain/unsafe blocks; recurse so their
                // constants and assertions fold in the same scope.
                .block, .unsafe_block, .comptime_block => |inner| self.foldComptimeBlockAt(inner, scope, report_span),
                else => {},
            }
        }
        self.noteComptimeOom(scope);
    }

    // Returns the folded comptime value of `expr`, or null if it is not a
    // compile-time constant (section 22).
    fn comptimeFoldValue(self: *Checker, expr: ast.Expr) ?eval.ComptimeValue {
        // NOTE: deliberately NOT switched to the shared fold-scratch buffer.
        // Unlike the other fold sites this returns the ComptimeValue itself, and
        // an aggregate value (.bytes/.array/.@"struct") aliases slices allocated
        // from this scope's allocator — the result can escape into the caller's
        // separate scope (checkComptimeCallAsserts binds it). Reusing a shared,
        // reset-on-next-use buffer would risk clobbering that escaped aggregate,
        // so this keeps its own per-call buffer. Not a hot path.
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        self.seedComptimeScope(&scope);
        if (scope.hasOom()) {
            self.noteComptimeOom(&scope);
            return null;
        }
        const folded = switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| v,
            else => null,
        };
        self.noteComptimeOom(&scope);
        return folded;
    }

    // Re-check a called function's comptime assertions with its `comptime`
    // parameters bound to the call's constant arguments (section 22). Failures
    // are reported at the call site.
    fn checkComptimeCallAsserts(self: *Checker, fn_decl: ast.FnDecl, args: []const ast.Expr, call_span: diagnostics.Span) void {
        const body = fn_decl.body orelse return;
        if (args.len != fn_decl.params.len) return;
        var arena = std.heap.ArenaAllocator.init(self.reporter.allocator);
        defer arena.deinit();
        var scope = eval.ComptimeScope.init(arena.allocator());
        self.seedComptimeScope(&scope);
        if (scope.hasOom()) {
            self.noteComptimeOom(&scope);
            return;
        }
        for (fn_decl.params, args) |param, arg| {
            if (!param.is_comptime) continue;
            if (isTypeName(param.ty, "type")) {
                const ty = eval.comptimeTypeArg(&scope, arg) orelse return;
                scope.bindType(param.name.text, ty) catch {
                    self.noteComptimeOom(&scope);
                    return;
                };
                continue;
            }
            const value = self.comptimeFoldValue(arg) orelse return; // non-const arg already diagnosed
            scope.bind(param.name.text, value) catch {
                self.noteComptimeOom(&scope);
                return;
            };
            scope.bindTypeInfo(param.name.text, param.ty) catch {
                self.noteComptimeOom(&scope);
                return;
            };
        }
        self.noteComptimeOom(&scope);
        self.foldComptimeCallBody(body, &scope, call_span);
    }

    // Walk a callee body for `comptime { … }` blocks and fold their assertions
    // with `scope` (which carries the bound comptime parameters), reporting at
    // the call site.
    fn foldComptimeCallBody(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope, call_span: diagnostics.Span) void {
        for (block.items) |stmt| {
            switch (stmt.kind) {
                .comptime_block => |inner| self.foldComptimeBlockAt(inner, scope, call_span),
                .block, .unsafe_block => |inner| self.foldComptimeCallBody(inner, scope, call_span),
                else => {},
            }
        }
    }

    fn checkUnhandledResultLocals(self: *Checker, block: ast.Block, ctx: Context) void {
        for (block.items, 0..) |stmt, i| {
            const local = switch (stmt.kind) {
                .let_decl, .var_decl => |local| local,
                else => continue,
            };
            if (local.init == null) continue;
            const local_ty = local.ty orelse exprResultType(local.init.?, ctx);
            const ty = local_ty orelse continue;
            if (classifyTypeCtx(ty, ctx) != .result) continue;
            for (local.names) |name| {
                if (!resultLocalHandledLater(name.text, block.items[i + 1 ..])) {
                    self.errorCode(name.span, "E_UNHANDLED_RESULT", "Result local must be handled or propagated");
                }
            }
        }

        for (block.items, 0..) |stmt, i| {
            const assignment = switch (stmt.kind) {
                .assignment => |assignment| assignment,
                else => continue,
            };
            const target_name = assignmentResultLocalName(assignment.target, ctx) orelse continue;
            const value_ty = exprResultType(assignment.value, ctx) orelse continue;
            if (classifyTypeCtx(value_ty, ctx) != .result) continue;

            if (resultLocalHasPendingValueBefore(target_name.text, block.items[0..i], ctx)) {
                self.errorCode(assignment.target.span, "E_UNHANDLED_RESULT", "Result local must be handled before reassignment");
            }
            if (!resultLocalHandledLater(target_name.text, block.items[i + 1 ..])) {
                self.errorCode(assignment.value.span, "E_UNHANDLED_RESULT", "assigned Result must be handled or propagated");
            }
        }
    }

    fn checkStmt(self: *Checker, stmt: ast.Stmt, ctx: Context) void {
        switch (stmt.kind) {
            .let_decl => |local| {
                self.checkLocal(local, ctx, false);
            },
            .var_decl => |local| {
                self.checkLocal(local, ctx, true);
            },
            .loop => |loop| {
                if (loop.iterable) |expr| {
                    const condition = self.checkExpr(expr, ctx);
                    if (loop.kind == .@"while" and condition == .secret) {
                        self.errorCode(expr.span, "E_SECRET_BRANCH", "secret value cannot drive a loop condition; this would leak it through control-flow timing");
                    } else if (loop.kind == .@"while" and !isConditionType(condition)) {
                        self.errorCode(expr.span, "E_CONDITION_NOT_BOOL", "condition must be bool");
                    } else if (loop.kind == .@"for" and !isForIterableBase(condition)) {
                        self.errorCode(expr.span, "E_FOR_BASE_NOT_ARRAY_OR_SLICE", "for loops iterate over arrays and slices");
                    }
                }
                var next = ctx;
                next.loop_depth += 1;
                // G7: push this loop's label (if any) so labeled break/continue
                // inside the body can resolve it. `node` lives on this frame for
                // the duration of the body check below.
                var node: LoopLabelNode = undefined;
                if (loop.loop_label) |lbl| {
                    node = .{ .label = lbl.text, .parent = ctx.loop_labels };
                    next.loop_labels = &node;
                }
                if (loop.kind == .@"for") {
                    if (ctx.scope) |scope| {
                        self.checkForBody(loop, next, scope);
                    } else {
                        self.checkBlockScoped(loop.body, next);
                    }
                } else {
                    self.checkBlockScoped(loop.body, next);
                }
            },
            .if_let => |node| {
                const value_class = self.checkExpr(node.value, ctx);
                const pattern_error_count = self.reporter.diagnostics.items.len;
                self.checkIfLetPattern(node.pattern, value_class);
                const pattern_is_valid = self.reporter.diagnostics.items.len == pattern_error_count;
                var then_scope = Scope.init(self.reporter.allocator);
                defer then_scope.deinit();
                var then_ctx = ctx;
                // The pattern binding + the then-block's locals form one lexical scope; mark
                // before binding so both are popped from the liveness stack on exit (G20).
                const then_mark = self.enterScope();
                if (ctx.scope) |scope| {
                    copyScope(scope, &then_scope) catch {
                        self.oom = true;
                    };
                    if (pattern_is_valid) self.addIfLetBinding(node.pattern, node.value, value_class, &then_scope, ctx);
                    then_ctx.scope = &then_scope;
                }
                if (pattern_is_valid) self.checkBlock(node.then_block, then_ctx);
                self.leaveScope(then_mark);
                if (node.else_block) |else_block| self.checkBlockScoped(else_block, ctx);
            },
            .@"switch" => |node| {
                self.checkSwitch(node, ctx);
            },
            .unsafe_block => |block| {
                var next = ctx;
                next.in_unsafe = true;
                self.checkBlockScoped(block, next);
            },
            .comptime_block => |block| {
                var next = ctx;
                next.in_comptime = true;
                self.checkBlockScoped(block, next);
                // Fold the constant subset of the block: bind comptime `let`
                // constants and evaluate `assert(...)` conditions, reporting
                // E_COMPTIME_TRAP for a provably-false assertion or a const-eval
                // trap (section 22: "Trap during const eval is a compile error").
                // An arena backs the fold scope so comptime array temporaries
                // are reclaimed together when the block is done.
                var arena = std.heap.ArenaAllocator.init(self.reporter.allocator);
                defer arena.deinit();
                var scope = eval.ComptimeScope.init(arena.allocator());
                self.seedComptimeScope(&scope);
                if (scope.hasOom()) {
                    self.noteComptimeOom(&scope);
                    return;
                }
                self.foldComptimeBlock(block, &scope);
            },
            .block => |block| self.checkBlockScoped(block, ctx),
            .asm_stmt => |asm_stmt| {
                if (!ctx.in_unsafe) {
                    self.errorCode(stmt.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (asm_stmt.form == .precise and !ctx.unsafe_contracts.has(.precise_asm)) {
                    self.errorCode(stmt.span, "E_PRECISE_ASM_CONTRACT", "precise asm requires #[unsafe_contract(precise_asm)]");
                }
                if (asm_stmt.form == .precise) {
                    // Each output names an assignable local that receives the
                    // result; the contract trusts the declared register/type.
                    for (asm_stmt.outputs) |output| {
                        self.checkType(output.ty, .storage, ctx);
                        const binding = if (ctx.scope) |scope| scope.get(output.name.text) else null;
                        if (binding) |entry| {
                            if (!entry.mutable) {
                                self.errorCode(output.name.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                            }
                        } else {
                            self.errorCode(output.name.span, "E_UNKNOWN_IDENTIFIER", "asm output names an unknown local");
                        }
                    }
                    // Each input feeds a value of the declared type into a register.
                    for (asm_stmt.inputs) |input| {
                        self.checkType(input.ty, .storage, ctx);
                        _ = self.checkExpr(input.value, ctx);
                    }
                }
                // Verify the register/clobber facts the precise-asm contract would
                // otherwise only trust: real registers, one architecture per block,
                // and no register named by two operands or by both an operand and a
                // clobber (an unsupported constraint combination).
                self.checkAsmConstraints(asm_stmt, stmt.span);
            },
            .contract_block => |contract| {
                var next = ctx;
                next.unsafe_contracts = next.unsafe_contracts.with(contract.attr);
                self.checkBlockScoped(contract.block, next);
            },
            .@"return" => |maybe| {
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
                if (maybe) |expr| {
                    const error_count = self.reporter.diagnostics.items.len;
                    const returned = self.checkExpr(expr, ctx);
                    if (ctx.returns_never and returned != .never) {
                        self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                    } else if (ctx.returns_void and returned != .void and returned != .never) {
                        self.errorCode(stmt.span, "E_VOID_RETURNS_VALUE", "function declared -> void cannot return a value");
                    } else if (!ctx.returns_never and !ctx.returns_void and self.reporter.diagnostics.items.len == error_count) {
                        self.checkReturnValue(ctx, returned, expr);
                    }
                } else if (ctx.returns_never) {
                    self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                } else if (ctx.return_ty != null and !ctx.returns_void) {
                    self.errorCode(stmt.span, "E_RETURN_REQUIRES_VALUE", "function return type requires a value");
                }
            },
            .@"break" => |target| {
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_BREAK_OUTSIDE_LOOP", "break is valid only inside a loop");
                } else if (target) |lbl| {
                    if (!LoopLabelNode.contains(ctx.loop_labels, lbl.text)) {
                        self.errorCode(lbl.span, "E_UNKNOWN_LOOP_LABEL", "break targets a loop label that is not in scope");
                    }
                }
            },
            .@"continue" => |target| {
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_CONTINUE_OUTSIDE_LOOP", "continue is valid only inside a loop");
                } else if (target) |lbl| {
                    if (!LoopLabelNode.contains(ctx.loop_labels, lbl.text)) {
                        self.errorCode(lbl.span, "E_UNKNOWN_LOOP_LABEL", "continue targets a loop label that is not in scope");
                    }
                }
            },
            .@"defer" => |expr| {
                const cleanup = self.checkExpr(expr, ctx);
                if (cleanup == .result) {
                    self.errorCode(expr.span, "E_UNHANDLED_RESULT", "Result defer cleanup must be handled or propagated");
                }
                if (cleanup == .never or exprContainsDeferControlFlow(expr, ctx)) {
                    self.errorCode(stmt.span, "E_DEFER_CONTROL_FLOW", "defer is lexical cleanup and must not alter control flow");
                }
            },
            .expr => |expr| {
                const value = self.checkExpr(expr, ctx);
                if (value == .result) {
                    self.errorCode(expr.span, "E_UNHANDLED_RESULT", "Result expression statements must be handled or propagated");
                }
            },
            .assert => |expr| {
                if (ctx.no_lang_trap) {
                    self.errorCode(stmt.span, "E_NO_LANG_TRAP_EDGE", "assert may emit a language trap in #[no_lang_trap]");
                }
                const condition = self.checkExpr(expr, ctx);
                if (!isConditionType(condition)) {
                    self.errorCode(expr.span, "E_CONDITION_NOT_BOOL", "condition must be bool");
                }
                // Comptime assert folding is handled by foldComptimeBlock once
                // the whole comptime block (and its constant bindings) is known.
            },
            .assignment => |node| {
                if (!isAssignableTarget(node.target)) {
                    self.errorCode(node.target.span, "E_INVALID_ASSIGNMENT_TARGET", "assignment target must be assignable storage");
                }
                if (isMmioRegisterTarget(node.target, ctx)) {
                    if (ctx.in_comptime) {
                        self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                    } else {
                        self.errorCode(stmt.span, "E_MMIO_DIRECT_ASSIGN", "MMIO registers must be accessed through typed read/write methods");
                    }
                }
                self.checkAssignmentTarget(node.target, ctx);
                _ = self.checkExpr(node.target, ctx);
                const value_class = self.checkExpr(node.value, ctx);
                self.checkAssignmentValue(node.target, value_class, node.value, ctx);
                updateAssignmentAddressOrigin(node.target, node.value, ctx);
            },
        }
    }

    fn checkLocal(self: *Checker, local: ast.LocalDecl, ctx: Context, mutable: bool) void {
        var inferred_ty: ?ast.TypeExpr = local.ty;
        if (inferred_ty == null) {
            if (local.init) |expr| inferred_ty = exprResultType(expr, ctx);
        }
        const kind = if (inferred_ty) |ty| classifyTypeCtx(ty, ctx) else TypeClass.unknown;
        var address_origin: AddressOrigin = .none;
        if (local.ty) |ty| self.checkType(ty, .storage, ctx);
        if (local.init) |expr| {
            const initializer = self.checkExpr(expr, ctx);
            address_origin = addressOrigin(expr, ctx);
            if (isUninitLiteral(expr)) {
                if (!mutable or local.ty == null) {
                    self.errorCode(expr.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
                }
            } else {
                const literal_checked = if (local.ty) |ty| self.checkIntegerLiteralInitializer(kind, ty, expr, ctx) else false;
                const null_checked = if (local.ty != null) self.checkNullPointerInitializer(kind, expr) else false;
                const null_target_checked = if (local.ty == null and isNullLiteral(expr)) blk: {
                    self.errorCode(expr.span, "E_NULL_REQUIRES_TARGET", "null requires an explicit nullable pointer target type");
                    break :blk true;
                } else false;
                const targetless_literal_checked = if (local.ty == null) self.checkTargetlessLiteralInitializer(expr) else false;
                const array_literal_checked = if (local.ty) |ty| self.checkArrayLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else blk: {
                    if (isArrayLiteral(expr)) {
                        self.errorCode(expr.span, "E_ARRAY_LITERAL_REQUIRES_TARGET", "array literal requires an explicit array target type");
                        break :blk true;
                    }
                    break :blk false;
                };
                const struct_literal_checked = if (local.ty) |ty| self.checkStructLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else blk: {
                    if (isStructLiteral(expr)) {
                        self.errorCode(expr.span, "E_STRUCT_LITERAL_REQUIRES_TARGET", "struct literal requires an explicit struct target type");
                        break :blk true;
                    }
                    break :blk false;
                };
                const packed_bits_literal_checked = if (local.ty) |ty| self.checkPackedBitsLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const array_decay_checked = if (local.ty != null) self.checkArrayDecayInitializer(kind, initializer, expr) else false;
                const pointer_conversion_checked = if (local.ty) |ty| self.checkPointerViewInitializer(ty, expr, ctx) else false;
                const c_void_conversion_checked = if (local.ty) |ty| self.checkCVoidPointerConversion(ty, expr, ctx) else false;
                const address_checked = if (local.ty) |ty| self.checkAddressOfInitializer(kind, ty, expr, ctx) else false;
                const fn_pointer_checked = if (local.ty) |ty| self.checkFunctionPointerInitializer(ty, expr, ctx) else false;
                const closure_checked = if (local.ty) |ty| self.checkClosureInitializer(ty, expr, ctx) else false;
                const dyn_checked = if (local.ty) |ty| self.checkDynCoercionInitializer(ty, expr, ctx) else false;
                const address_class_checked = if (local.ty != null) checkAddressClassConversion(self, expr.span, kind, initializer) else false;
                const enum_checked = if (local.ty) |ty| self.checkEnumValueCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const union_checked = if (local.ty) |ty| self.checkTaggedUnionConstructorCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const secret_checked = if (local.ty) |ty| (kind == .secret and self.checkSecretWrapInitializer(ty, expr, ctx)) else false;
                if (local.ty == null and untargeted_union_checked) {
                    // The diagnostic was emitted above; constructor calls need an explicit union target.
                } else if (local.ty != null and !literal_checked and !null_checked and !null_target_checked and !targetless_literal_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !dyn_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(kind, initializer)) {
                    self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion");
                }
            }
        } else {
            self.errorCode(local.names[0].span, "E_LOCAL_REQUIRES_INITIALIZER", "ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage");
        }
        if (ctx.scope) |scope| {
            for (local.names) |name| {
                self.addLocalBinding(scope, name, .{ .class = kind, .mutable = mutable, .ty = inferred_ty, .origin = .local, .address_origin = address_origin });
            }
        }
    }

    // Block-scoping (G20) liveness helpers. `live_locals` is a flat innermost-last stack of
    // names live across all open scopes; a lexical scope is delimited by a marker (its length
    // on entry) and torn down by truncating back to that marker.
    fn isLiveLocal(self: *Checker, name: []const u8) bool {
        for (self.live_locals.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn pushLiveLocal(self: *Checker, name: []const u8) void {
        self.live_locals.append(self.reporter.allocator, name) catch {
            self.oom = true;
        };
    }

    // Enter a lexical scope: remember the current liveness marker to restore on exit.
    fn enterScope(self: *Checker) usize {
        return self.live_locals.items.len;
    }

    // Leave a lexical scope: names declared since `mark` are no longer live, so a later
    // SIBLING scope may reuse them. The backing `scope` type map is intentionally left
    // intact (keep-all) so post-body passes can still resolve those locals' types.
    fn leaveScope(self: *Checker, mark: usize) void {
        if (self.live_locals.items.len > mark) self.live_locals.shrinkRetainingCapacity(mark);
    }

    fn addLocalBinding(self: *Checker, scope: *Scope, name: ast.Ident, info: LocalInfo) void {
        if (isCBackendReservedLocalName(name.text)) {
            self.errorCode(name.span, "E_RESERVED_C_IDENTIFIER", "local binding name is reserved by the C backend or C headers; choose a different source name");
            return;
        }
        if (self.isQualifiedOwner(name.text)) {
            self.errorCode(name.span, "E_RESERVED_QUALIFIED_NAME", "a local binding may not shadow a module/impl name");
            return;
        }
        // A name still live in THIS or an enclosing scope is a forbidden live-shadow. A name
        // that only lingers in `scope` from an already-exited sibling block is NOT live, so it
        // may be reused — we overwrite its stale type entry below.
        if (self.isLiveLocal(name.text)) {
            self.errorCode(name.span, "E_DUPLICATE_LOCAL", "local bindings must have unique names in the current scope");
            return;
        }
        scope.put(name.text, info) catch {
            self.oom = true;
            return;
        };
        self.pushLiveLocal(name.text);
    }

    fn isQualifiedOwner(self: *Checker, name: []const u8) bool {
        for (self.qualified_owners) |owner| {
            if (std.mem.eql(u8, owner, name)) return true;
        }
        return false;
    }

    fn checkAssignmentTarget(self: *Checker, target: ast.Expr, ctx: Context) void {
        switch (target.kind) {
            .ident => |ident| {
                const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
                if (binding) |entry| {
                    if (!entry.mutable) {
                        self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                    }
                }
            },
            .deref => |inner| {
                if (constStorageBase(inner.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
            },
            .index => |node| {
                if (constStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
                if (immutableIndexedValueStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                }
            },
            .member => |node| {
                if (constStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
                if (!isMmioRegisterTarget(target, ctx) and immutableValueStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                }
            },
            .grouped => |inner| self.checkAssignmentTarget(inner.*, ctx),
            else => {},
        }
    }

    fn checkAssignmentValue(self: *Checker, target: ast.Expr, value_class: TypeClass, value: ast.Expr, ctx: Context) void {
        const target_ty = assignmentTargetType(target, ctx) orelse return;
        if (isUninitLiteral(value)) {
            self.errorCode(value.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const target_class = classifyTypeCtx(target_ty, ctx);
        const literal_checked = self.checkIntegerLiteralInitializer(target_class, target_ty, value, ctx);
        const null_checked = self.checkNullPointerInitializer(target_class, value);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target_class, value_class, value);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, value, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, value, ctx);
        const address_checked = self.checkAddressOfInitializer(target_class, target_ty, value, ctx);
        const fn_pointer_checked = self.checkFunctionPointerInitializer(target_ty, value, ctx);
        const closure_checked = self.checkClosureInitializer(target_ty, value, ctx);
        // The uniform `*T -> *dyn Trait` coercion on an assignment RHS (same as let/return/arg/field).
        const dyn_checked = self.checkDynCoercionInitializer(target_ty, value, ctx);
        const address_class_checked = checkAddressClassConversion(self, value.span, target_class, value_class);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion") else false;
        const secret_checked = target_class == .secret and self.checkSecretWrapInitializer(target_ty, value, ctx);
        // T1.1 lexical region/scope borrows: storing the address of local storage into a
        // location that outlives that local (a `*out`/`out.field` written through a pointer
        // parameter) makes the borrow dangle once the function returns. Reject it.
        if ((isNonNullPointerLike(target_class) or isNullablePointerLike(target_class)) and
            localAddressRoot(value, ctx) != null and assignmentTargetEscapesFunction(target, ctx))
        {
            self.errorCode(value.span, "E_BORROW_ESCAPES_SCOPE", "cannot store the address of local storage where it outlives the local's scope (the borrow would dangle)");
        }
        if (assignmentTargetEscapesFunction(target, ctx)) {
            if (target_class == .closure) {
                if (closureLocalAddressRoot(value, ctx)) |span| {
                    self.errorCode(span, "E_LOCAL_ADDRESS_ESCAPE", "cannot store a closure that captures local storage where it outlives the local's scope");
                }
            }
            if (aggregateLocalAddressRoot(value, ctx)) |span| {
                self.errorCode(span, "E_LOCAL_ADDRESS_ESCAPE", "cannot store a value that captures local storage where it outlives the local's scope");
            }
        }
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !dyn_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target_class, value_class)) {
            self.errorCode(value.span, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        }
    }

    // G8: a bare `EXPR?` that propagates a `Result<_, E1>` out of a function
    // returning `Result<_, E2>` needs an explicit `#[error_from]` conversion when
    // `E1 != E2`. `?` invokes it on the error path (see src/error_from.zig). When no
    // conversion is declared, reject rather than silently reinterpret the error
    // bits. The `? else MAPPED` form supplies its own error and is left untouched.
    // Validate every `#[error_from]` conversion declaration (G8). Each must be shaped `fn(E1) -> E2`
    // with exactly one NAMED source-error parameter and a NAMED target-error return type (a malformed
    // one was previously ignored, then surfaced misleadingly as E_NO_ERROR_CONVERSION at the `?` site).
    // And each (E1 -> E2) pair must be UNIQUE: two conversions for the same error types are ambiguous
    // (the resolver would silently pick one by iteration order), so reject them here.
    fn checkErrorFromDecls(self: *Checker, module: ast.Module) void {
        var seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.reporter.allocator.free(k.*);
            seen.deinit();
        }
        for (module.decls) |decl| {
            const fn_decl = switch (decl.kind) {
                .fn_decl, .extern_fn => |fd| fd,
                else => continue,
            };
            if (!error_from.hasAttr(decl.attrs)) continue;
            const span = fn_decl.name.span;
            if (fn_decl.params.len != 1) {
                self.errorCode(span, "E_INVALID_ERROR_FROM", "#[error_from] fn must take exactly one parameter (the source error type)");
                continue;
            }
            const from = ast_query.typeName(fn_decl.params[0].ty);
            const to = if (fn_decl.return_type) |r| ast_query.typeName(r) else null;
            if (from == null or to == null) {
                self.errorCode(span, "E_INVALID_ERROR_FROM", "#[error_from] fn must convert one named error type to another (fn(E1) -> E2)");
                continue;
            }
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}\x00{s}", .{ from.?, to.? }) catch {
                self.oom = true;
                continue;
            };
            if (seen.contains(key)) {
                self.reporter.allocator.free(key);
                self.errorCode(span, "E_AMBIGUOUS_ERROR_CONVERSION", "multiple #[error_from] conversions for the same source and target error types; keep exactly one");
            } else {
                seen.put(key, {}) catch {
                    self.reporter.allocator.free(key);
                    self.oom = true;
                };
            }
        }
    }

    fn checkTryErrorConversion(self: *Checker, span: ast.Span, inner: anytype, ctx: Context) void {
        if (inner.mapped != null) return; // explicit `? else` remap owns the error
        const return_ty = ctx.return_ty orelse return; // no return type: `?` traps, not propagate
        const fn_err = resultPayloadType(return_ty, "err") orelse return; // enclosing fn returns no Result
        const operand_result_ty = exprResultType(inner.operand.*, ctx) orelse return;
        const op_err = resultPayloadType(operand_result_ty, "err") orelse return; // nullable operand: no error type
        const e1 = ast_query.typeName(resolveAliasType(op_err, ctx)) orelse return;
        const e2 = ast_query.typeName(resolveAliasType(fn_err, ctx)) orelse return;
        if (std.mem.eql(u8, e1, e2)) return; // same error type: propagate as-is (unchanged behavior)
        const functions = ctx.functions orelse return;
        if (error_from.resolve(functions, e1, e2) != null) return; // an #[error_from] conversion exists
        self.errorCode(span, "E_NO_ERROR_CONVERSION", "'?' cannot convert the propagated error to the function's error type; declare an #[error_from] fn converting it");
    }

    fn checkExpr(self: *Checker, expr: ast.Expr, ctx: Context) TypeClass {
        return switch (expr.kind) {
            // The async transform eliminates every `await_expr` pre-sema.
            .await_expr => unreachable,
            .ident => |ident| self.checkIdentExpr(ident, ctx),
            .int_literal => .int_literal,
            .float_literal => .float_literal,
            .void_literal => .void,
            .bool_literal => .bool,
            .null_literal => .null_literal,
            .array_literal => |items| {
                for (items) |item| _ = self.checkExpr(item, ctx);
                return .unknown;
            },
            .struct_literal => |fields| {
                for (fields) |field| _ = self.checkExpr(field.value, ctx);
                return .unknown;
            },
            .string_literal, .char_literal, .uninit_literal, .enum_literal => .unknown,
            .unreachable_expr => {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "reachable unreachable emits a language trap in #[no_lang_trap]");
                }
                if (ctx.in_comptime) {
                    self.errorCode(expr.span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                }
                return .never;
            },
            .grouped, .address_of => |inner| self.checkExpr(inner.*, ctx),
            .try_expr => |inner| {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                const operand = self.checkExpr(inner.operand.*, ctx);
                if (!isTryOperand(operand)) {
                    self.errorCode(expr.span, "E_TRY_REQUIRES_RESULT_OR_NULLABLE", "postfix '?' requires a Result or nullable operand");
                }
                self.checkTryErrorConversion(expr.span, inner, ctx);
                if (tryPayloadType(inner.operand.*, ctx)) |payload_ty| return classifyTypeCtx(payload_ty, ctx);
                return tryResultType(operand);
            },
            .block => |block| {
                self.checkBlockScoped(block, ctx);
                return .unknown;
            },
            .unary => |node| {
                const inner = self.checkExpr(node.expr.*, ctx);
                if (ctx.no_lang_trap and node.op == .neg and isCheckedSigned(inner)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked unary negation may trap in #[no_lang_trap]");
                }
                if (node.op == .neg and isCheckedUnsigned(inner)) {
                    self.errorCode(expr.span, "E_UNSIGNED_NEGATION", "unsigned checked integers do not support unary '-'");
                }
                if (node.op == .neg) {
                    self.checkUnaryNegOperand(expr.span, inner);
                }
                if (node.op == .bit_not and isCheckedSigned(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_SIGNED_OPERAND", "bitwise operations are not defined on signed checked integers");
                }
                if (node.op == .bit_not and inner == .bool) {
                    self.errorCode(expr.span, "E_BITWISE_BOOL_OPERAND", "bitwise operations are not defined on bool operands");
                }
                if (node.op == .bit_not and isPointerLike(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_POINTER_OPERAND", "bitwise operations are not defined on pointer operands");
                }
                if (node.op == .bit_not and isAddressClass(inner)) {
                    self.errorCode(expr.span, "E_ADDRESS_CLASS_OPERATION", "opaque address classes do not support this operator");
                }
                if (node.op == .bit_not and isForbiddenBitwisePolicy(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_ARITH_DOMAIN_OPERAND", "bitwise operations are not defined on this arithmetic domain");
                }
                if (node.op == .bit_not) {
                    self.checkUnaryBitwiseOperand(expr.span, inner);
                }
                if (node.op == .logical_not) {
                    if (!isConditionType(inner)) {
                        self.errorCode(expr.span, "E_BOOL_OPERATOR_OPERAND", "boolean operators are defined only for bool operands");
                    }
                    return .bool;
                }
                return inner;
            },
            .binary => |node| {
                const left = self.checkExpr(node.left.*, ctx);
                const right = self.checkExpr(node.right.*, ctx);
                if (ctx.no_lang_trap and isTrapBinary(node.op) and !isNoTrapArithmeticDomainOp(node.op, left, right) and !isNonTrappingFloatOp(node.op, left, right) and !(self.optimize and divModProvablySafe(node.op, left, node.right.*))) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked operation may trap in #[no_lang_trap]");
                }
                if (isArithmeticBinary(node.op) and arithmeticDomainsImplicitlyMix(left, right)) {
                    self.errorCode(expr.span, "E_ARITH_POLICY_MIX", "arithmetic domains do not implicitly mix");
                }
                if (isArithmeticBinary(node.op)) {
                    self.checkArithmeticOperatorOperands(expr.span, left, right);
                }
                if ((isArithmeticBinary(node.op) or isComparisonBinary(node.op))) {
                    self.checkFloatBinaryOperands(expr.span, left, right);
                }
                if (node.op == .mod and (isFloat(left) or isFloat(right))) {
                    self.errorCode(expr.span, "E_OPERATOR_OPERAND", "remainder is not defined on floating-point operands");
                }
                if ((node.op == .div or node.op == .mod) and (isArithmeticDomain(left) or isArithmeticDomain(right))) {
                    self.errorCode(expr.span, "E_ARITH_DOMAIN_DIVISION", "division and remainder are defined only on checked integers, not arithmetic domains");
                }
                if ((isArithmeticBinary(node.op) or isBitwiseBinary(node.op) or isComparisonBinary(node.op) or isLogicalBinary(node.op)) and (isAddressClass(left) or isAddressClass(right))) {
                    self.errorCode(expr.span, "E_ADDRESS_CLASS_OPERATION", "opaque address classes do not support this operator");
                }
                if (isArithmeticBinary(node.op) or isComparisonBinary(node.op) or
                    node.op == .bit_and or node.op == .bit_or or node.op == .bit_xor)
                {
                    // `& | ^` must width-match their operands like `+ - * /` do; otherwise a
                    // narrow target plus a narrow left operand lets `mergeArithmetic` pick the
                    // narrow type and silently drop the wide operand's high bits. Shifts are
                    // excluded: a shift count is not width-matched to the shifted value.
                    self.checkCheckedIntegerBinaryOperands(expr.span, left, right);
                }
                // `& | ^` (but not the shifts) also adapt a literal operand to the other
                // operand's width, so range-check there too. Shift counts are not width-matched.
                if (isArithmeticBinary(node.op) or isComparisonBinary(node.op) or
                    node.op == .bit_and or node.op == .bit_or or node.op == .bit_xor)
                {
                    self.checkBinaryLiteralOperandRange(node.left.*, left, node.right.*, right);
                }
                if (isComparisonBinary(node.op)) {
                    self.checkPointerComparison(expr.span, node.op, node.left.*, left, node.right.*, right, ctx);
                    self.checkComparisonOperatorOperands(expr.span, node.op, left, right, ctx.in_unsafe);
                }
                if (isPointerArithmeticBinary(node.op) and (isSingleObjectPointerLike(left) or isSingleObjectPointerLike(right))) {
                    self.errorCode(expr.span, "E_POINTER_ARITH_SINGLE_OBJECT", "single-object pointers do not support arithmetic");
                }
                // Constant-time: offsetting a pointer by a secret is a secret-dependent
                // memory address — the same cache leak as a secret array index.
                if (isPointerArithmeticBinary(node.op) and (isPointerLike(left) or isPointerLike(right)) and (left == .secret or right == .secret)) {
                    self.errorCode(expr.span, "E_SECRET_INDEX", "secret value cannot offset a pointer; a secret-dependent memory access leaks it through the cache");
                }
                if (isBitwiseBinary(node.op) and (isCheckedSigned(left) or isCheckedSigned(right))) {
                    self.errorCode(expr.span, "E_BITWISE_SIGNED_OPERAND", "bitwise operations are not defined on signed checked integers");
                }
                // `&`/`|`/`^` on two bools is the bitwise spelling of logical and/or/xor (0/1
                // values). MC normally forbids it, but permits it inside `unsafe` as a C-compat
                // escape hatch (e.g. machine-generated kernel code). A single bool mixed with a
                // non-bool operand is always rejected.
                if (isBitwiseBinary(node.op) and (left == .bool or right == .bool) and
                    !(ctx.in_unsafe and left == .bool and right == .bool))
                {
                    self.errorCode(expr.span, "E_BITWISE_BOOL_OPERAND", "bitwise operations are not defined on bool operands");
                }
                if (isBitwiseBinary(node.op) and (isPointerLike(left) or isPointerLike(right))) {
                    self.errorCode(expr.span, "E_BITWISE_POINTER_OPERAND", "bitwise operations are not defined on pointer operands");
                }
                if (isBitwiseBinary(node.op) and (isForbiddenBitwisePolicy(left) or isForbiddenBitwisePolicy(right))) {
                    self.errorCode(expr.span, "E_BITWISE_ARITH_DOMAIN_OPERAND", "bitwise operations are not defined on this arithmetic domain");
                }
                if (isBitwiseBinary(node.op)) {
                    self.checkBitwiseOperatorOperands(expr.span, left, right);
                }
                if (isLogicalBinary(node.op)) {
                    if (!isConditionType(left) or !isConditionType(right)) {
                        self.errorCode(expr.span, "E_BOOL_OPERATOR_OPERAND", "boolean operators are defined only for bool operands");
                    }
                    return .bool;
                }
                if (isComparisonBinary(node.op)) {
                    // A comparison touching a secret produces a *secret* bool, not a
                    // plain bool: it must not be usable as a branch/switch condition
                    // (that would leak the secret through control flow). Constant-time
                    // code selects on it via bitmask/CMOV helpers after `declassify`.
                    if (left == .secret or right == .secret) return .secret;
                    return .bool;
                }
                // `bool & bool` (the unsafe C-compat case above) yields a bool.
                if (isBitwiseBinary(node.op) and ctx.in_unsafe and left == .bool and right == .bool) return .bool;
                return mergeArithmetic(left, right);
            },
            .cast => |node| {
                const source = self.checkExpr(node.value.*, ctx);
                self.checkType(node.ty.*, .normal, ctx);
                const target = classifyTypeCtx(node.ty.*, ctx);
                if ((source == .c_void_pointer) != (target == .c_void_pointer)) {
                    self.errorCode(expr.span, "E_C_VOID_CONVERSION", "c_void pointer conversions require an explicit FFI boundary operation");
                }
                // SOUNDNESS: a slice (`[]T`) is a fat pointer (ptr+len). A scalar / non-slice
                // value has no length component, so `scalar as []T` cannot be lowered — the
                // backend would cast only the scalar and DROP the length (fabricating garbage).
                // Only a slice-to-slice `as` (e.g. `[]mut T as []const T`) is representable.
                // `.unknown` (generic type param / `*dyn`) and `.never` are left alone to avoid
                // false positives; the MIR/backends reject any residual bad shape.
                if (target == .slice and source != .slice and source != .unknown and source != .never) {
                    self.errorCode(expr.span, "E_ILLEGAL_SLICE_CAST", "cannot cast a non-slice value to a slice: a slice is a fat pointer (ptr+len) and the length has no source. Build one with a slicing expression `a[i..j]`, a byte view (`mem.as_bytes`), or a string literal");
                }
                self.checkEnumCast(expr.span, node.value.*, source, node.ty.*, target, ctx);
                self.checkCastSafetyStrip(expr.span, node.value.*, source, node.ty.*, target, ctx);
                return target;
            },
            .call => |node| {
                // `Union.variant(...)` qualified constructor — self-typed, validated here;
                // skip the generic call machinery (which would treat the union name as a value).
                if (self.checkQualifiedUnionConstructor(expr, node, ctx)) |class| return class;
                const trap_call = isTrapCall(node.callee.*);
                if (ctx.no_lang_trap and isTrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "explicit trap emits a language trap in #[no_lang_trap]");
                }
                if (ctx.in_comptime and trap_call) {
                    self.errorCode(expr.span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                }
                if (ctx.no_lang_trap and isUnwrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                if (ctx.no_lang_trap and isTrappingConversionCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "trap_from may emit a range trap in #[no_lang_trap]");
                }
                if (uncheckedRequirement(node.callee.*)) |required| {
                    if (!ctx.unsafe_contracts.has(required)) {
                        self.errorCode(expr.span, "E_UNCHECKED_OUTSIDE_CONTRACT", "unchecked operation requires matching #[unsafe_contract]");
                    }
                }
                if (isUnsafeOperationCall(node.callee.*) and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                // `arc_get_mut` proves uniqueness only at the instant of its refcount check; the
                // language has no borrow analysis to stop a later `arc_clone` from aliasing the
                // returned `*mut T`. So it requires an unsafe context, where the caller asserts
                // it will not clone or publish the handle while the pointer is live.
                if (isIdentNamed(node.callee.*, "arc_get_mut") and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "arc_get_mut yields an aliasable `*mut T` whose uniqueness the checker cannot enforce; it requires an unsafe context (do not arc_clone/publish the handle while the pointer lives)");
                }
                if (ctx.in_comptime and isComptimeForbiddenCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (ctx.in_comptime and isMmioRegisterAccessCall(node.callee.*, ctx)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                self.checkMmioRegisterAccessCall(expr.span, node.callee.*, node.args, ctx);
                self.checkAtomicCall(expr.span, node.callee.*, node.args, ctx);
                self.checkMaybeUninitCall(expr.span, node.callee.*, node.args, ctx);
                self.checkDmaCall(expr.span, node.callee.*, node.args, ctx);
                self.checkMmioMapCall(expr.span, node, ctx);
                self.checkTypeStaticCall(expr.span, node.callee.*, node.args, ctx);
                self.checkResidueCall(expr.span, node.callee.*, node.args, ctx);
                self.checkReduceCall(expr.span, node, ctx);
                self.checkByteViewCall(expr.span, node, ctx);
                const bitcast_class = self.checkBitcastCall(expr.span, node, ctx);
                const raw_many_offset_class = self.checkRawManyOffsetCall(expr.span, node, ctx);
                const reflection_class = self.checkReflectionCall(expr.span, node, ctx);
                if (reflection_class) |class| return class;
                if (self.checkDeclassifyCall(expr.span, node, ctx)) |class| return class;
                const const_get_class = self.checkConstGetCall(expr.span, node, ctx);
                if (const_get_class) |class| return class;
                if (trap_call) self.checkTrapKind(expr.span, node.args);
                self.checkCallCallee(node.callee.*, ctx);
                for (node.type_args) |ty| self.checkType(ty, .normal, ctx);
                const direct_function = if (!trap_call and node.type_args.len == 0) directCallFunction(node.callee.*, ctx) else null;
                // Calling a value of function-pointer type (callback, vtable
                // field, local): check the call against the pointer's signature.
                const fnptr_ty: ?ast.TypeExpr = if (!trap_call and direct_function == null) calleeFnPointerType(node.callee.*, ctx) else null;
                const closure_ty: ?ast.TypeExpr = if (!trap_call and direct_function == null and fnptr_ty == null) calleeClosureType(node.callee.*, ctx) else null;
                if (fnptr_ty) |fpty| {
                    const sig = fpty.kind.fn_pointer;
                    if (node.args.len != sig.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match function-pointer signature");
                    }
                    // C2 (reconciled with the MIR verifier): in an #[irq_context] function
                    // an INDIRECT/fn-pointer call may reach anything — including a
                    // #[may_sleep] op — so the verifier rejects it with E_IRQ_CONTEXT_CALL.
                    // The sema C2 check below lives inside `if (direct_function)`, so the
                    // indirect path used to PASS `mcc check` but FAIL `mcc verify`. Reject
                    // it here too (conservatively, since the target is unknown), so the two
                    // passes agree.
                    if (ctx.irq_context) {
                        self.errorCode(expr.span, "E_IRQ_CONTEXT_CALL", "an #[irq_context] function may not make an indirect/fn-pointer call (the target may sleep or block)");
                    }
                    // traits-design review #2 (T(term)1 extension): an indirect/fn-pointer
                    // call from a `#[bounded]` function is rejected — the termination check
                    // cannot see through the pointer to bound the callee.
                    if (ctx.bounded and !ctx.irq_context) {
                        self.errorCode(expr.span, "E_UNBOUNDED_INDIRECT_CALL", "a `#[bounded]` function may not make an indirect/fn-pointer call (the callee's termination cannot be checked through the pointer)");
                    }
                }
                if (closure_ty) |cty| {
                    const sig = cty.kind.closure_type;
                    if (node.args.len != sig.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match closure signature");
                    }
                    if (ctx.irq_context) {
                        self.errorCode(expr.span, "E_IRQ_CONTEXT_CALL", "an #[irq_context] function may not make an indirect/closure call (the target may sleep or block)");
                    }
                    if (ctx.bounded and !ctx.irq_context) {
                        self.errorCode(expr.span, "E_UNBOUNDED_INDIRECT_CALL", "a `#[bounded]` function may not make an indirect/closure call (the callee's termination cannot be checked through the closure)");
                    }
                }
                // A method dispatch on a NULLABLE trait object (`?*dyn Trait`) must narrow
                // first: you cannot dispatch through a possibly-absent receiver (the `none`
                // niche has no vtable). Without this gate the call is accepted by sema but
                // un-lowerable on both backends — so reject it here with a must-narrow rule.
                if (nullableDynDispatchReceiver(node.callee.*, ctx)) {
                    self.errorCode(expr.span, "E_NULLABLE_DYN_DISPATCH", "cannot dispatch a method through a `?*dyn Trait` (it may be absent / `none`); narrow it first with `if let` / `switch`, or `unwrap` it to a `*dyn Trait`");
                }
                // Tier 2 dynamic dispatch: `d.method(args)` through a `*dyn Trait`. This is
                // an indirect (load-through-vtable) call, so it inherits every restriction
                // an indirect call carries: rejected in `#[irq_context]` (E_IRQ_CONTEXT_CALL,
                // effect-sound by exclusion — traits-design §6,§9.1) and in `#[bounded]`
                // (review #2). A `move self` method is static-dispatch only.
                if (self.dynDispatchSig(node.callee.*, ctx)) |msig| {
                    // Object-safe traits never have a move-self method, so this fires only on
                    // an unsafe-forged dyn; it locks the linearity guarantee through dispatch.
                    if (msig.self_mode == .move_self or msig.self_mode == .by_value) {
                        self.errorCode(expr.span, "E_DYN_MOVE_SELF", "a consuming (`move self`/by-value) method cannot be called through `*dyn Trait` (you cannot move out of a borrowed trait object)");
                    }
                    // The dispatched method takes `self` first, then the declared params.
                    const dispatch_arity = if (msig.params.len > 0) msig.params.len - 1 else 0;
                    if (node.args.len != dispatch_arity) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match the trait method signature");
                    }
                    if (ctx.irq_context) {
                        self.errorCode(expr.span, "E_IRQ_CONTEXT_CALL", "an #[irq_context] function may not dispatch through `*dyn Trait` (a virtual call is an indirect call whose target may sleep or block)");
                    }
                    if (ctx.bounded and !ctx.irq_context) {
                        self.errorCode(expr.span, "E_UNBOUNDED_INDIRECT_CALL", "a `#[bounded]` function may not dispatch through `*dyn Trait` (the callee's termination cannot be checked through the vtable)");
                    }
                    for (node.args) |arg| _ = self.checkExpr(arg, ctx);
                    if (msig.return_type) |rt| return classifyTypeCtx(rt, ctx);
                    return .void;
                }
                if (direct_function) |function| {
                    // A `const fn` is evaluable at comptime (section 22); only
                    // non-const (runtime) functions are a forbidden effect.
                    if (ctx.in_comptime and !function.is_const) {
                        self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot call runtime functions");
                    }
                    if (ctx.no_lang_trap and !function.no_lang_trap) {
                        self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "call target is not proven #[no_lang_trap]");
                    }
                    // C2 (reconciled with the MIR verifier's E_IRQ_CONTEXT_CALL model):
                    // an IRQ/atomic-context function may only call OTHER irq-context
                    // functions (plus the non-blocking primitives `raw.`/`mmio.`/`atomic.`,
                    // which are member-method builtins and never resolve to `direct_function`
                    // here). A direct call to any other named function would run unbounded,
                    // possibly-sleeping work in interrupt/atomic context.
                    //
                    // Previously the sema check only rejected `#[may_sleep]` callees, so a
                    // plain non-irq call (`ack_irq()`) PASSED `mcc check` but FAILED
                    // `mcc verify` — a check/verify contradiction. We now mirror the
                    // verifier: `#[may_sleep]` callees keep the specific E_SLEEP_IN_ATOMIC
                    // diagnostic; any other non-irq callee is the same E_IRQ_CONTEXT_CALL
                    // the verifier raises, so the two passes agree.
                    if (ctx.irq_context and !function.irq_context) {
                        if (function.may_sleep) {
                            self.errorCode(expr.span, "E_SLEEP_IN_ATOMIC", "calling a #[may_sleep] op from an #[irq_context] function (sleeping in interrupt)");
                        } else {
                            self.errorCode(expr.span, "E_IRQ_CONTEXT_CALL", "an #[irq_context] function may only call other #[irq_context] functions or non-blocking primitives");
                        }
                    }
                    if (node.args.len != function.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
                    } else {
                        // section 22: a `comptime` value parameter's argument must
                        // be a compile-time constant; a `comptime T: type`
                        // parameter's argument must name a type (user generics).
                        for (function.params, node.args) |param, arg| {
                            if (!param.is_comptime) continue;
                            if (isTypeName(param.ty, "type")) {
                                if (typeArgName(arg, ctx)) |tn| {
                                    if (!isKnownTypeName(tn, ctx)) self.errorCode(arg.span, "E_TYPE_ARG_REQUIRED", "type parameter requires a known type argument");
                                } else {
                                    self.errorCode(arg.span, "E_TYPE_ARG_REQUIRED", "type parameter requires a type argument");
                                }
                            } else if (!self.comptimeConstantFolds(arg) and !exprMentionsComptimeParam(arg, ctx)) {
                                self.errorCode(arg.span, "E_COMPTIME_ARG_REQUIRED", "comptime parameter requires a compile-time constant argument");
                            }
                        }
                        // Re-check the callee's comptime assertions with its
                        // comptime parameters bound to these constant arguments.
                        if (directCallName(node.callee.*)) |callee_name| {
                            if (self.comptime_fns) |registry| {
                                if (registry.get(callee_name)) |callee| {
                                    self.checkComptimeCallAsserts(callee, node.args, expr.span);
                                }
                            }
                        }
                    }
                }
                for (node.args, 0..) |arg, index| {
                    // A `comptime T: type` argument is a type, not a value — do
                    // not type-check it as an expression.
                    if (direct_function) |function| {
                        if (index < function.params.len and function.params[index].is_comptime and isTypeName(function.params[index].ty, "type")) continue;
                    }
                    const source = self.checkExpr(arg, ctx);
                    if (direct_function) |function| {
                        if (index < function.params.len) {
                            if (function.is_extern) self.checkClosureArgumentDoesNotEscape(function.params[index].ty, arg, ctx, "cannot pass a closure that captures local storage to an extern function");
                            self.checkCallArgument(function.params[index].ty, arg, source, ctx);
                        }
                    }
                    if (fnptr_ty) |fpty| {
                        const sig = fpty.kind.fn_pointer;
                        if (index < sig.params.len) {
                            self.checkClosureArgumentDoesNotEscape(sig.params[index], arg, ctx, "cannot pass a closure that captures local storage through an indirect function pointer call");
                            self.checkCallArgument(sig.params[index], arg, source, ctx);
                        }
                    }
                    if (closure_ty) |cty| {
                        const sig = cty.kind.closure_type;
                        if (index < sig.params.len) self.checkCallArgument(sig.params[index], arg, source, ctx);
                    }
                }
                if (trap_call) return .never;
                // `drop(x)` consumes a linear `move` value (or is a no-op for a
                // plain value) and yields void. The move/liveness pass consumes
                // the argument via the ordinary call-argument path.
                if (isDropCall(node.callee.*)) {
                    if (node.args.len != 1) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "drop takes exactly one argument");
                    }
                    return .void;
                }
                // `forget_unchecked(x)`: discard a linear value without releasing it — the
                // explicit, greppable escape hatch for the tail of a destructor / a transfer
                // API that already moved the resource's contents elsewhere. Its deliberately
                // alarming name is the audit signal that no release runs here; unlike `drop`
                // it is the only form legal on a resource.
                if (isForgetUncheckedCall(node.callee.*)) {
                    if (node.args.len != 1) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "forget_unchecked takes exactly one argument");
                    }
                    // It discards a linear value without releasing it — a leak if misused — so
                    // it is gated behind `unsafe`, not merely a scary name. Only the trusted
                    // tail of a destructor / transfer API (which has already recorded or moved
                    // the resource) should reach for it, and that code is `unsafe`.
                    if (!ctx.in_unsafe) {
                        self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "forget_unchecked discards a linear value without releasing it; it requires an unsafe context");
                    }
                    return .void;
                }
                if (rawLoadCallReturnType(node)) |ty| return classifyTypeCtx(ty, ctx);
                if (vaCallName(node.callee.*)) |va_name| {
                    if (vaCallReturnType(node)) |ty| return classifyTypeCtx(ty, ctx);
                    if (std.mem.eql(u8, va_name, "end")) return .void;
                }
                if (isRawPtrCall(node.callee.*) and node.type_args.len == 1) {
                    const ptr_ty = ast.TypeExpr{ .span = node.type_args[0].span, .kind = .{ .pointer = .{ .mutability = .mut, .child = @constCast(&node.type_args[0]) } } };
                    return classifyTypeCtx(ptr_ty, ctx);
                }
                if (self.checkEnumRawCall(expr.span, node.callee.*, node.args, ctx)) |class| return class;
                if (atomicCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (self.dmaCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (mmioMapCallPayloadType(node)) |_| return .nullable_pointer;
                if (typeStaticCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (residueCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (reduceCallReturnClass(node, ctx)) |class| return class;
                if (byteViewCallReturnClass(node)) |class| return class;
                if (bitcast_class) |class| return class;
                if (raw_many_offset_class) |class| return class;
                if (directCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (mathBuiltinCallReturnClass(node.callee.*)) |class| return class;
                if (fnptr_ty) |fpty| return classifyTypeCtx(fpty.kind.fn_pointer.ret.*, ctx);
                if (closure_ty) |cty| return classifyTypeCtx(cty.kind.closure_type.ret.*, ctx);
                return .unknown;
            },
            .index => |node| {
                // OPT (annex E): a provably-in-range constant index never emits a Bounds
                // trap, so under `--optimize` it is allowed in `#[no_lang_trap]` — mirroring
                // the MIR-level bounds-check elision so sema and MIR agree.
                if (ctx.no_lang_trap and !(self.optimize and self.indexProvablyInBounds(node.base.*, node.index.*, ctx))) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "indexing may trap in #[no_lang_trap]");
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (!isIndexableBase(base_class)) {
                    self.errorCode(node.base.span, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE", "indexing is defined only for arrays and slices");
                }
                const index_class = self.checkExpr(node.index.*, ctx);
                // Constant-time: a secret value cannot be used as an array/slice
                // index (nor, by the same token, a pointer offset). A secret-dependent
                // memory access reveals the secret through the data-cache footprint.
                if (index_class == .secret) {
                    self.errorCode(node.index.span, "E_SECRET_INDEX", "secret value cannot be used as an array index; a secret-dependent memory access leaks it through the cache — declassify/reveal it first (unsafe) or use a constant-time table scan");
                } else if (!isIndexType(index_class)) {
                    self.errorCode(node.index.span, "E_INDEX_NOT_USIZE", "array and slice indices must be checked usize");
                }
                if (indexResultType(node, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .slice => |node| {
                // A constant range into a fixed array provably never traps, so under `--optimize`
                // it is allowed in `#[no_lang_trap]` — mirroring the const-index elision (annex E).
                if (ctx.no_lang_trap and !(self.optimize and self.sliceProvablyInBounds(node.base.*, node.start.*, node.end.*, ctx))) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "range slicing may trap in #[no_lang_trap]");
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (!isIndexableBase(base_class)) {
                    self.errorCode(node.base.span, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE", "slicing is defined only for arrays and slices");
                }
                const start_class = self.checkExpr(node.start.*, ctx);
                if (!isIndexType(start_class)) {
                    self.errorCode(node.start.span, "E_INDEX_NOT_USIZE", "slice range bounds must be checked usize");
                }
                const end_class = self.checkExpr(node.end.*, ctx);
                if (!isIndexType(end_class)) {
                    self.errorCode(node.end.span, "E_INDEX_NOT_USIZE", "slice range bounds must be checked usize");
                }
                if (sliceResultType(node, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .deref => |inner| {
                const inner_class = self.checkExpr(inner.*, ctx);
                if (ctx.in_comptime and isRuntimePointerDerefClass(inner_class)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (inner_class == .raw_many_pointer and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (inner_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_DEREF", "c_void pointer cannot be dereferenced");
                }
                if (isOpaqueAddressClass(inner_class)) {
                    if (addressDerefDiagnostic(inner_class)) |code| {
                        self.errorCode(expr.span, code, addressDerefMessage(inner_class));
                    }
                }
                if (derefResultType(inner.*, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .member => |node| {
                if (isBuiltinNamespaceMember(node)) return .unknown;
                // A variant-path literal `Enum.variant` used as a value: the base names
                // an enum TYPE, not a runtime value, so it must not be checked as an
                // identifier (that would raise E_UNKNOWN_IDENTIFIER). Classify it as the
                // enum type directly so `Enum.variant` and `Enum.variant.raw()` resolve.
                if (enumVariantPathType(node, ctx)) |variant_ty| {
                    return classifyTypeCtx(variant_ty, ctx);
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (base_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no fields in MC");
                }
                // A direct `.field` on a UserPtr<T> is a kernel dereference of user memory:
                // reading T's field reaches through the user pointer. Forbid it exactly like
                // `p.*` — the only path to a user value is a checked copy_from_user/copy_to_user.
                if (base_class == .user_ptr) {
                    self.errorCode(expr.span, "E_USER_PTR_DEREF", "cannot directly access a field through UserPtr; copy it in with copy_from_user first");
                }
                if (base_class != .c_void_pointer and
                    base_class != .user_ptr and
                    !isMmioRegisterTarget(expr, ctx) and
                    !isKnownAtomicOperationMember(node, ctx) and
                    !isMaybeUninitOperationMember(node, ctx) and
                    !isResidueOperationMember(node, ctx) and
                    !isEnumRawOperationMember(node, ctx))
                {
                    self.checkKnownStructField(expr.span, node.base.*, node.name.text, ctx);
                }
                // Gap #1: reading ANY arm of an overlay union that has at least one `Secret<…>`
                // arm is itself secret — the arms alias the same bytes, so a plain-arm read can
                // observe secret bytes written through the secret arm. Classify the read secret
                // so the subsequent branch/index is rejected (E_SECRET_BRANCH / E_SECRET_INDEX).
                if (exprResultType(node.base.*, ctx) orelse exprStorageType(node.base.*, ctx)) |base_ty| {
                    if (overlayUnionTypeHasSecretArm(base_ty, ctx)) return .secret;
                }
                if (memberResultFieldType(node, ctx)) |field_ty| return classifyTypeCtx(field_ty, ctx);
                return .unknown;
            },
        };
    }

    fn checkIdentExpr(self: *Checker, ident: ast.Ident, ctx: Context) TypeClass {
        if (ctx.scope) |scope| {
            if (scope.get(ident.text)) |binding| return binding.class;
        }
        // A local binding (above) shadows and is exempt; a cross-file reference to a private
        // top-level global / function used as a value is rejected.
        self.checkImportVisibility(ident.text, ident.span);
        if (globalClass(ident.text, ctx)) |class| return class;
        // A top-level function name used as a value is a function pointer.
        if (ctx.functions) |fns| {
            if (fns.contains(ident.text)) return .fn_pointer;
        }
        self.errorCode(ident.span, "E_UNKNOWN_IDENTIFIER", "unknown identifier");
        return .unknown;
    }

    fn checkCallCallee(self: *Checker, callee: ast.Expr, ctx: Context) void {
        switch (callee.kind) {
            .ident => |ident| {
                if (isBuiltinFunctionName(ident.text)) return;
                if (isKnownTaggedUnionConstructorName(ident.text, ctx)) return;
                self.checkImportVisibility(ident.text, ident.span);
                if (ctx.functions != null and ctx.functions.?.contains(ident.text)) return;
                if (ctx.scope != null and ctx.scope.?.contains(ident.text)) return;
                if (globalType(ident.text, ctx)) |ty| {
                    const class = classifyTypeCtx(ty, ctx);
                    if (class == .fn_pointer or class == .closure) return;
                }
                self.errorCode(ident.span, "E_UNKNOWN_FUNCTION", "unknown function");
            },
            .member => |node| {
                if (self.checkGenericTypeParamMemberCallee(node, ctx)) return;
                if (isAtomicOperationMember(node, ctx)) return;
                if (isMaybeUninitOperationMember(node, ctx)) return;
                if (isResidueOperationName(node)) return;
                if (isEnumRawOperationMember(node, ctx)) return;
                if (isDmaOperationMember(node, ctx)) return;
                if (isRawManyOffsetOperationMember(node, ctx)) return;
                if (isTypeStaticMember(node, ctx)) return;
                if (isBuiltinNamespaceMember(node)) return;
                _ = self.checkExpr(callee, ctx);
            },
            .grouped => |inner| self.checkCallCallee(inner.*, ctx),
            else => _ = self.checkExpr(callee, ctx),
        }
    }

    fn checkGenericTypeParamMemberCallee(self: *Checker, member: anytype, ctx: Context) bool {
        const base_ident = switch (member.base.*.kind) {
            .ident => |id| id,
            .grouped => |inner| switch (inner.kind) {
                .ident => |id| id,
                else => return false,
            },
            else => return false,
        };
        const type_params = ctx.type_params orelse return false;
        if (!type_params.contains(base_ident.text)) return false;

        if (self.genericTypeParamBoundDeclaresMember(base_ident.text, member.name.text, ctx)) return true;
        self.errorCode(member.name.span, "E_TRAIT_BOUND_MEMBER", "generic type-parameter member calls require a `where` bound whose trait declares that member");
        return true;
    }

    fn genericTypeParamBoundDeclaresMember(self: *Checker, type_param: []const u8, member_name: []const u8, ctx: Context) bool {
        const trait_decls = ctx.trait_decls orelse self.trait_decls orelse return false;
        for (ctx.trait_bounds) |bound| {
            if (!std.mem.eql(u8, bound.type_param.text, type_param)) continue;
            const trait = trait_decls.get(bound.trait_name.text) orelse continue;
            if (findTraitMethod(trait.methods, member_name) != null) return true;
        }
        return false;
    }

    fn checkType(self: *Checker, ty: ast.TypeExpr, mode: TypeMode, ctx: Context) void {
        switch (ty.kind) {
            .name => |name| {
                if (mode == .ffi_opaque_pointer and std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_MC_VOID_POINTER_FFI", "use c_void for C opaque object pointers, not MC void");
                } else if (mode != .ffi_opaque_pointer and std.mem.eql(u8, name.text, "c_void")) {
                    self.errorCode(name.span, "E_C_VOID_NO_LAYOUT", "c_void has no size or layout in MC; use pointers to c_void at FFI boundaries");
                } else if (mode == .storage and std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_VOID_STORAGE", "void is only valid as a function return type or generic marker");
                } else if (mode == .storage and std.mem.eql(u8, name.text, "never")) {
                    self.errorCode(name.span, "E_NEVER_STORAGE", "never is a control-flow type and cannot be used for storage");
                } else if (!isKnownTypeName(name.text, ctx)) {
                    self.errorCode(name.span, "E_UNKNOWN_TYPE", "unknown type name");
                } else {
                    self.checkImportVisibility(name.text, name.span);
                }
            },
            .enum_literal => {},
            .member => |node| self.checkType(node.base.*, .normal, ctx),
            .nullable => |child| self.checkType(child.*, mode, ctx),
            .qualified => |node| self.checkType(node.child.*, mode, ctx),
            .pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .raw_many_pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .slice => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .array => |node| {
                // A length that folds to a comptime constant — literal
                // arithmetic or a `const fn` result (section 22 comptime↔type) —
                // is a valid compile-time array length and need not type-check
                // as a runtime usize expression.
                if (comptimeUsizeValue(node.len, self.const_fns, self.const_globals) == null) {
                    if (exprMentionsGenericValueParam(node.len, ctx)) return;
                    const len_class = self.checkExpr(node.len, ctx);
                    if (!isIndexType(len_class)) {
                        self.errorCode(node.len.span, "E_ARRAY_LENGTH_TYPE", "array length must be a compile-time checked usize integer expression");
                    }
                }
                self.checkType(node.child.*, if (mode == .storage) .storage else .normal, ctx);
            },
            .generic => |node| {
                if (userGenericTypeExpectedArgs(node.base.text, ctx)) |expected| {
                    if (node.args.len != expected) {
                        self.errorCode(node.base.span, "E_GENERIC_TYPE_ARG_COUNT", "generic type has the wrong number of type arguments");
                    }
                    for (node.args) |arg| self.checkUserGenericTypeArgument(arg, ctx);
                    return;
                }
                if (!isKnownGenericTypeName(node.base.text)) {
                    self.errorCode(node.base.span, "E_UNKNOWN_TYPE", "unknown generic type name");
                } else if (genericTypeExpectedArgs(node.base.text)) |expected| {
                    if (node.args.len != expected) {
                        self.errorCode(node.base.span, "E_GENERIC_TYPE_ARG_COUNT", "generic type has the wrong number of type arguments");
                    }
                }
                for (node.args) |arg| self.checkType(arg, .normal, ctx);
                self.checkGenericTypeArgs(node, ctx);
                if (isArithmeticDomainTypeName(node.base.text) and node.args.len == 1) {
                    if (!isCheckedUnsigned(classifyTypeCtx(node.args[0], ctx))) {
                        self.errorCode(node.args[0].span, "E_ARITH_DOMAIN_UNSIGNED", "MC-C0 arithmetic domains require an unsigned integer type argument");
                    }
                }
            },
            .fn_pointer => |node| {
                // Parameter and return types must themselves be valid storage
                // types (a function-pointer parameter/return cannot be `void`
                // except as the return position).
                for (node.params) |param| self.checkType(param, .storage, ctx);
                self.checkType(node.ret.*, .normal, ctx);
            },
            .closure_type => |node| {
                // Same validity rule as a function pointer: parameters are storage
                // types, the return is a normal type.
                for (node.params) |param| self.checkType(param, .storage, ctx);
                self.checkType(node.ret.*, .normal, ctx);
            },
            // `*dyn Trait` (Tier 2): the trait must exist and be object-safe
            // (traits-design §5). Object safety is checked once per trait in
            // checkTraits; here we only validate that the named trait is one of them.
            .dyn_trait => |node| self.checkDynTraitType(node.trait_name),
        }
    }

    // Validate a `*dyn Trait` pointee: the trait must be declared and object-safe.
    // The set of object-safe trait names is populated by checkTraits (which runs
    // first in `check`).
    fn checkDynTraitType(self: *Checker, trait_name: ast.Ident) void {
        if (!self.known_traits.contains(trait_name.text)) {
            self.errorCode(trait_name.span, "E_UNKNOWN_TRAIT", "unknown trait in `*dyn Trait`");
            return;
        }
        if (!self.object_safe_traits.contains(trait_name.text)) {
            self.errorCode(trait_name.span, "E_TRAIT_NOT_OBJECT_SAFE", "trait is not object-safe (every method must take `self` by pointer and be non-generic) so it cannot be used as `*dyn Trait`");
        }
    }

    fn userGenericTypeExpectedArgs(name: []const u8, ctx: Context) ?usize {
        if (ctx.structs) |structs| {
            if (structs.get(name)) |info| {
                if (info.type_param_count > 0) return info.type_param_count;
            }
        }
        if (ctx.tagged_unions) |tagged_unions| {
            if (tagged_unions.get(name)) |info| {
                if (info.type_param_count > 0) return info.type_param_count;
            }
        }
        return null;
    }

    fn checkUserGenericTypeArgument(self: *Checker, arg: ast.TypeExpr, ctx: Context) void {
        if (typeExprIsGenericValueArg(arg, ctx)) return;
        self.checkType(arg, .normal, ctx);
    }

    fn checkGenericTypeArgs(self: *Checker, node: anytype, ctx: Context) void {
        if (std.mem.eql(u8, node.base.text, "Reg")) {
            if (node.args.len != 2) return;
            self.checkMmioRegisterPosition(node.base.span, ctx);
            self.checkMmioRegisterWidth(node.args[0]);
            self.checkMmioAccessMode(node.args[1]);
        } else if (std.mem.eql(u8, node.base.text, "RegBits")) {
            if (node.args.len != 3) return;
            self.checkMmioRegisterPosition(node.base.span, ctx);
            self.checkMmioRegisterWidth(node.args[0]);
            if (!isPackedBitsTypeName(node.args[1], ctx)) {
                self.errorCode(node.args[1].span, "E_MMIO_REGBITS_TYPE", "RegBits value type must be a known packed bits type");
            }
            self.checkMmioAccessMode(node.args[2]);
        } else if (std.mem.eql(u8, node.base.text, "DmaBuf")) {
            if (node.args.len != 2) return;
            self.checkStoragePayloadType(node.args[0]);
            self.checkDmaBufMode(node.args[1]);
        } else if (std.mem.eql(u8, node.base.text, "atomic")) {
            if (node.args.len != 1) return;
            self.checkStoragePayloadType(node.args[0]);
        } else if (std.mem.eql(u8, node.base.text, "MmioPtr")) {
            if (node.args.len != 1) return;
            self.checkStoragePayloadType(node.args[0]);
            self.checkMmioPtrTarget(node.args[0], ctx);
        } else if (genericHasStoragePayload(node.base.text)) {
            if (node.args.len == 0) return;
            self.checkStoragePayloadType(node.args[0]);
        }
    }

    fn checkMmioRegisterPosition(self: *Checker, span: diagnostics.Span, ctx: Context) void {
        if (!ctx.allow_mmio_register_type) {
            self.errorCode(span, "E_MMIO_REGISTER_POSITION", "Reg and RegBits types are valid only as extern mmio struct fields");
        }
    }

    fn checkMmioPtrTarget(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        const name = typeName(ty) orelse {
            self.errorCode(ty.span, "E_MMIO_PTR_TARGET", "MmioPtr target must be an extern mmio struct type");
            return;
        };
        if (!isKnownTypeName(name, ctx)) return;
        if (!knownMmioStructName(name, ctx)) {
            self.errorCode(ty.span, "E_MMIO_PTR_TARGET", "MmioPtr target must be an extern mmio struct type");
        }
    }

    fn checkStoragePayloadType(self: *Checker, ty: ast.TypeExpr) void {
        switch (ty.kind) {
            .name => |name| {
                if (std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_VOID_STORAGE", "void is only valid as a function return type or generic marker");
                } else if (std.mem.eql(u8, name.text, "never")) {
                    self.errorCode(name.span, "E_NEVER_STORAGE", "never is a control-flow type and cannot be used for storage");
                }
            },
            .qualified => |node| self.checkStoragePayloadType(node.child.*),
            .array => |node| self.checkStoragePayloadType(node.child.*),
            else => {},
        }
    }

    fn checkDmaBufMode(self: *Checker, ty: ast.TypeExpr) void {
        const mode = switch (ty.kind) {
            .enum_literal => |literal| literal.text,
            else => {
                self.errorCode(ty.span, "E_DMA_BUF_MODE", "DmaBuf mode must be .coherent or .noncoherent");
                return;
            },
        };
        if (!isDmaBufMode(mode)) {
            self.errorCode(ty.span, "E_DMA_BUF_MODE", "DmaBuf mode must be .coherent or .noncoherent");
        }
    }

    fn checkMmioRegisterWidth(self: *Checker, ty: ast.TypeExpr) void {
        if (!isFixedUnsignedMmioWidth(ty)) {
            self.errorCode(ty.span, "E_MMIO_REGISTER_WIDTH", "MMIO register width must be u8, u16, u32, or u64");
        }
    }

    fn checkMmioAccessMode(self: *Checker, ty: ast.TypeExpr) void {
        const mode = switch (ty.kind) {
            .enum_literal => |literal| literal.text,
            else => {
                self.errorCode(ty.span, "E_MMIO_ACCESS_MODE", "MMIO register access mode must be .read, .write, or .read_write");
                return;
            },
        };
        if (!isMmioAccessMode(mode)) {
            self.errorCode(ty.span, "E_MMIO_ACCESS_MODE", "MMIO register access mode must be .read, .write, or .read_write");
        }
    }

    fn checkMmioRegisterAccessCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;
        if (!std.mem.eql(u8, member.name.text, "read") and !std.mem.eql(u8, member.name.text, "write")) return;
        const info = mmioRegisterMemberInfo(member.base.*, ctx) orelse return;
        if (std.mem.eql(u8, member.name.text, "read")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MMIO read expects exactly one ordering argument");
                return;
            }
            self.checkMmioReadOrdering(args[0]);
            if (!info.access.allowsRead()) {
                self.errorCode(member.name.span, "E_MMIO_ACCESS_FORBIDDEN", "MMIO register access mode does not allow read");
            }
        }
        if (std.mem.eql(u8, member.name.text, "write")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MMIO write expects a value and one ordering argument");
                return;
            }
            self.checkMmioWriteOrdering(args[1]);
            if (!info.access.allowsWrite()) {
                self.errorCode(member.name.span, "E_MMIO_ACCESS_FORBIDDEN", "MMIO register access mode does not allow write");
            }
        }
    }

    fn checkAtomicCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;

        if (isIdentNamed(member.base.*, "atomic") and std.mem.eql(u8, member.name.text, "init")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic.init expects exactly one initializer argument");
            }
            return;
        }

        const payload_ty = atomicPayloadTypeForValue(member.base.*, ctx) orelse return;
        const payload_class = classifyTypeCtx(payload_ty, ctx);
        if (std.mem.eql(u8, member.name.text, "load")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic load expects exactly one memory ordering argument");
                return;
            }
            self.checkAtomicLoadOrdering(args[0]);
            return;
        }
        if (std.mem.eql(u8, member.name.text, "store")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic store expects a value and one memory ordering argument");
                return;
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkAtomicStoreOrdering(args[1]);
            return;
        }
        if (std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic fetch_add/fetch_sub expects a value and one memory ordering argument");
                return;
            }
            if (!isCheckedInt(payload_class)) {
                self.errorCode(member.name.span, "E_ATOMIC_OPERATION", "atomic fetch_add/fetch_sub requires an integer payload type");
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkAtomicReadModifyWriteOrdering(args[1]);
            return;
        }
        self.errorCode(member.name.span, "E_ATOMIC_OPERATION", "unknown atomic operation");
    }

    fn checkMaybeUninitCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;
        if (!std.mem.eql(u8, member.name.text, "write") and !std.mem.eql(u8, member.name.text, "assume_init")) return;
        const payload_ty = maybeUninitPayloadTypeForValue(member.base.*, ctx) orelse return;
        if (std.mem.eql(u8, member.name.text, "write")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MaybeUninit.write expects exactly one payload argument");
                return;
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkMaybeUninitWritePayload(payload_ty, args[0], ctx);
            return;
        }
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "MaybeUninit.assume_init does not take arguments");
        }
    }

    fn checkMaybeUninitWritePayload(self: *Checker, payload_ty: ast.TypeExpr, arg: ast.Expr, ctx: Context) void {
        const payload_name = structNameOfType(payload_ty, ctx) orelse return;
        if (isStructLiteral(arg)) return;
        const arg_ty = exprDeclaredType(arg, ctx) orelse {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
            return;
        };
        const arg_name = structNameOfType(arg_ty, ctx) orelse {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
            return;
        };
        if (!std.mem.eql(u8, payload_name, arg_name)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
        }
    }

    fn checkAtomicLoadOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic load ordering must be .relaxed, .acquire, or .seq_cst");
            return;
        };
        if (!isAtomicLoadOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic load ordering must be .relaxed, .acquire, or .seq_cst");
        }
    }

    fn checkAtomicStoreOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic store ordering must be .relaxed, .release, or .seq_cst");
            return;
        };
        if (!isAtomicStoreOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic store ordering must be .relaxed, .release, or .seq_cst");
        }
    }

    fn checkAtomicReadModifyWriteOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic read-modify-write ordering must be a valid atomic memory order");
            return;
        };
        if (!isAtomicOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic read-modify-write ordering must be a valid atomic memory order");
        }
    }

    fn checkDmaCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;

        if (isIdentNamed(member.base.*, "cache")) {
            if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return;
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "cache DMA operation expects exactly one DmaBuf argument");
                return;
            }
            const info = dmaBufInfoForValue(args[0], ctx) orelse {
                self.errorCode(args[0].span, "E_DMA_OPERATION", "cache DMA operation requires a DmaBuf argument");
                _ = self.checkExpr(args[0], ctx);
                return;
            };
            if (!std.mem.eql(u8, info.mode, "noncoherent")) {
                self.errorCode(args[0].span, "E_DMA_CACHE_MODE", "cache clean/invalidate are required only for noncoherent DmaBuf values");
            }
            return;
        }

        const is_dma_op = std.mem.eql(u8, member.name.text, "dma_addr") or
            std.mem.eql(u8, member.name.text, "as_slice");
        if (dmaBufInfoForValue(member.base.*, ctx)) |info| {
            if (!is_dma_op) {
                self.errorCode(member.name.span, "E_DMA_OPERATION", "unknown DmaBuf operation");
                return;
            }
            if (args.len != 0) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "DmaBuf operation does not take arguments");
            }
            _ = info;
            return;
        }
        // The base is not a DmaBuf. `dma_addr`/`as_slice` are defined only on DmaBuf values
        // (section 18 — the device-address vs CPU-view bridge), so calling them on anything else
        // is ill-typed. Without this the checker silently accepted e.g. `someArray.as_slice()`
        // (the result still typed as a slice), which no backend can lower — LLVM rejected it with
        // UnsupportedLlvmEmission, a check-vs-backend inconsistency. Any other member call on a
        // non-DmaBuf base is some other construct, so leave it to the remaining checkers.
        if (is_dma_op) {
            self.errorCode(member.name.span, "E_DMA_OPERATION", "dma_addr/as_slice are defined only on DmaBuf values");
            _ = self.checkExpr(member.base.*, ctx);
        }
    }

    fn checkTypeStaticCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;
        const class = staticTypeBaseClass(member.base.*, ctx) orelse return;
        const op = member.name.text;

        // Explicit scalar/domain conversions (section 3, section 5).
        if (isConversionName(op)) {
            if (std.mem.eql(u8, op, "from_mod") and class != .wrap) {
                self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "from_mod is defined only on wrap<T> targets");
                return;
            }
            if (isNarrowingConversionName(op) and !isCheckedInt(class)) {
                self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "try_from/trap_from/wrap_from/sat_from are defined only on scalar integer targets");
                return;
            }
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "conversion expects exactly one source argument");
            }
            return;
        }

        // Two-operand domain operations (section 5.4, section 5.5).
        if (class == .serial or class == .counter) {
            const code = if (class == .serial) "E_SERIAL_OPERATION" else "E_COUNTER_OPERATION";
            const known = if (class == .serial) isSerialOperationName(op) else isCounterOperationName(op);
            if (!known) {
                self.errorCode(member.name.span, code, if (class == .serial) "unknown serial number operation" else "unknown free-running counter operation");
                return;
            }
            const expected = domainOperationArgCount(op);
            if (args.len != expected) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "domain operation has the wrong number of arguments");
                return;
            }
            // The first two operands must share the domain type; a third argument
            // (an external interval bound) is checked only for arity.
            for (args[0..@min(@as(usize, 2), args.len)]) |arg| {
                const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx) orelse continue;
                const arg_class = classifyTypeCtx(arg_ty, ctx);
                if (arg_class != .unknown and arg_class != class) {
                    self.errorCode(arg.span, code, "domain operation operands must have the same arithmetic-domain type");
                }
            }
            return;
        }

        // Scalar/wrap/sat targets only define the conversion constructors above.
        self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "unknown type-level operation");
    }

    fn checkResidueCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = memberExpr(callee) orelse return;
        if (!std.mem.eql(u8, member.name.text, "residue")) return;
        const ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return;
        const class = classifyTypeCtx(ty, ctx);
        if (!isArithmeticDomain(class)) return;
        if (class != .wrap) {
            self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "residue() is defined only on wrap<T> values");
            return;
        }
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "residue expects no arguments");
        }
    }

    fn checkReduceCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        const kind = reduceCallKind(call.callee.*) orelse return;
        const requires_float = kind != .sum_checked;
        if (call.type_args.len != 1) {
            self.errorCode(span, if (requires_float) "E_REDUCE_REQUIRES_FLOAT" else "E_REDUCE_REQUIRES_INTEGER", if (requires_float) "floating-point reduction requires exactly one f32/f64 type argument" else "reduce.sum_checked requires exactly one integer type argument");
            return;
        }
        const t = call.type_args[0];
        const t_name = typeName(t) orelse {
            self.errorCode(t.span, if (requires_float) "E_REDUCE_REQUIRES_FLOAT" else "E_REDUCE_REQUIRES_INTEGER", if (requires_float) "floating-point reductions are restricted to f32/f64" else "reduce.sum_checked is restricted to integer types");
            return;
        };
        if (!requires_float and !isIntegerScalarName(t_name)) {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_INTEGER", "reduce.sum_checked is restricted to integer types");
        }
        if (requires_float and !isFloatScalarName(t_name)) {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_FLOAT", "floating-point reductions are restricted to f32/f64");
        }
        if (call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "reduction expects exactly one slice argument");
            return;
        }
        // The argument is type-checked by the enclosing call arm; here we only
        // confirm it is a slice (§8.2/§8.3: `xs: []const T`).
        const arg_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx) orelse return;
        const arg_class = classifyTypeCtx(arg_ty, ctx);
        if (arg_class != .slice) {
            self.errorCode(call.args[0].span, "E_REDUCE_ARG_NOT_SLICE", "reduction expects a slice (`[]const T`) of the element type");
            return;
        }
        const elem_ty = storageElementType(resolveAliasType(arg_ty, ctx)) orelse return;
        const elem_class = classifyTypeCtx(elem_ty, ctx);
        const target_class = classifyTypeCtx(t, ctx);
        if (elem_class != target_class) {
            self.errorCode(call.args[0].span, "E_REDUCE_ARG_NOT_SLICE", "reduction slice element type must match the reduction type argument");
        }
    }

    fn checkByteViewCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        const kind = byteViewCallKind(call.callee.*) orelse return;
        if (call.type_args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "byte-view operations do not take type arguments");
        }
        switch (kind) {
            .as_bytes => {
                if (call.args.len != 1) {
                    self.errorCode(span, "E_CALL_ARG_COUNT", "mem.as_bytes expects exactly one address argument");
                    return;
                }
                const inner = switch (call.args[0].kind) {
                    .address_of => |target| target.*,
                    .grouped => |grouped| switch (grouped.kind) {
                        .address_of => |target| target.*,
                        else => {
                            self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an address expression");
                            return;
                        },
                    },
                    else => {
                        self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an address expression");
                        return;
                    },
                };
                const source_ty = exprResultType(inner, ctx) orelse exprStorageType(inner, ctx) orelse {
                    self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an addressable value with known storage type");
                    return;
                };
                const resolved = resolveAliasType(source_ty, ctx);
                if (isTypeName(resolved, "void") or isTypeName(resolved, "never")) {
                    self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires byte-addressable storage");
                }
            },
            .bytes_equal => {
                if (call.args.len != 2) {
                    self.errorCode(span, "E_CALL_ARG_COUNT", "mem.bytes_equal expects exactly two byte slices");
                    return;
                }
                for (call.args) |arg| {
                    const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx) orelse continue;
                    if (!isConstU8SliceType(resolveAliasType(arg_ty, ctx))) {
                        self.errorCode(arg.span, "E_BYTE_VIEW_SLICE", "mem.bytes_equal expects []const u8 byte slices");
                    }
                }
            },
        }
    }

    fn checkConstGetCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const member = constGetMember(call.callee.*) orelse return null;
        if (call.args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "const_get expects no runtime arguments");
        }
        const index = if (call.type_args.len == 1) constGetIndexArg(call.type_args[0]) else null;
        if (call.type_args.len != 1 or index == null) {
            self.errorCode(span, "E_CONST_GET_INDEX", "const_get requires exactly one compile-time usize index");
        }
        const base_class = self.checkExpr(member.base.*, ctx);
        if (base_class != .array and base_class != .unknown and base_class != .never) {
            self.errorCode(member.base.span, "E_CONST_GET_BASE", "const_get is defined only for fixed-length arrays");
        }
        const base_ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return .unknown;
        const array = fixedArrayType(resolveAliasType(base_ty, ctx), ctx.const_fns, ctx.const_globals) orelse {
            self.errorCode(member.base.span, "E_CONST_GET_BASE", "const_get is defined only for fixed-length arrays");
            return .unknown;
        };
        if (index) |idx| {
            if (idx >= array.len) {
                self.errorCode(call.type_args[0].span, "E_CONST_GET_BOUNDS", "const_get index is out of bounds for the fixed-length array");
            }
        }
        return classifyTypeCtx(array.child, ctx);
    }

    fn dmaCallReturnClass(self: *Checker, callee: ast.Expr, ctx: Context) ?TypeClass {
        _ = self;
        const member = memberExpr(callee) orelse return null;
        _ = dmaBufInfoForValue(member.base.*, ctx) orelse return null;
        if (std.mem.eql(u8, member.name.text, "dma_addr")) return .dma_addr;
        if (std.mem.eql(u8, member.name.text, "as_slice")) return .slice;
        return null;
    }

    fn checkMmioMapCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        if (!isMmioMapCallName(call.callee.*)) return;
        if (call.type_args.len != 1 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "mmio.map requires exactly one target type and one physical address argument");
            return;
        }
        self.checkMmioPtrTarget(call.type_args[0], ctx);
        const source_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx) orelse return;
        const source = classifyTypeCtx(source_ty, ctx);
        if (source != .paddr and source != .unknown and source != .never) {
            self.errorCode(call.args[0].span, "E_ADDRESS_CLASS_MISMATCH", "mmio.map requires a PAddr argument");
        }
    }

    fn checkBitcastCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        if (!isBitcastCallName(call.callee.*)) return null;

        const target_ty = if (call.type_args.len == 1) call.type_args[0] else null;
        if (call.type_args.len != 1 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "bitcast requires exactly one target type and one value argument");
        }

        const target = if (target_ty) |ty| classifyTypeCtx(ty, ctx) else TypeClass.unknown;
        if (target_ty) |ty| {
            if (!isBitcastLayoutClass(target) or !isBitcastLayoutType(ty, ctx)) {
                self.errorCode(ty.span, "E_BITCAST_TYPE", "bitcast target must have a fixed scalar, pointer, or address-class layout");
            }
        }

        var source_ty: ?ast.TypeExpr = null;
        if (call.args.len == 1) {
            source_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx);
            if (source_ty) |ty| {
                const source = classifyTypeCtx(ty, ctx);
                if (!isBitcastLayoutClass(source) or !isBitcastLayoutType(ty, ctx)) {
                    self.errorCode(call.args[0].span, "E_BITCAST_TYPE", "bitcast source must have a fixed scalar, pointer, or address-class layout");
                }
            } else {
                self.errorCode(call.args[0].span, "E_BITCAST_TYPE", "bitcast source type must be known");
            }
        }

        // Pointer-reinterpret may not cross INTO or OUT OF an opaque/secret/userptr
        // pointee. A value `bitcast` already rejects cross-class scalars with
        // E_BITCAST_TYPE; the pointer case is the same hole one indirection deeper —
        // `bitcast<*Shadow>(pt)` where `pt: *Tainted` would read the opaque struct's
        // private scalar (or the lock-protected Guarded data) through a same-shape
        // plain mirror, with no validator/guard and no `unsafe`. The guard is the
        // POINTEE's privacy class crossing, so ordinary `*A -> *B` kernel-pointer
        // reinterprets (neither side opaque) stay accepted.
        if (target_ty) |tty| {
            if (source_ty) |sty| {
                if (pointeeIsOpaquePrivacy(tty, ctx) != pointeeIsOpaquePrivacy(sty, ctx)) {
                    self.errorCode(span, "E_BITCAST_TYPE", "bitcast pointer-reinterpret may not cross into or out of an opaque/secret/userptr class");
                }
            }
        }

        // Address-class laundering via `bitcast` is the same forge/cross-class hole
        // as the `as`-cast gate, one layout-reinterpret deeper: `bitcast<MmioPtr<Dev>>(p)`
        // forges a device pointer from a plain `*u8`, and `bitcast<VAddr>(pa)` crosses
        // PAddr into VAddr — both with no `unsafe`. A bitcast that mints, crosses, or
        // strips a built-in address class is rejected outside `unsafe` (the controlled
        // escape the typed constructors and raw MMIO path use). A same-class identity
        // bitcast is a no-op and stays allowed.
        if (!ctx.in_unsafe and target_ty != null and source_ty != null) {
            if (isAddressClass(target) or isAddressClass(classifyTypeCtx(source_ty.?, ctx))) {
                const source_cls = classifyTypeCtx(source_ty.?, ctx);
                if (!(isAddressClass(target) and target == source_cls)) {
                    self.errorCode(span, "E_ADDRESS_CLASS_CAST", "bitcast may not mint, cross, or strip a built-in address class (PAddr/VAddr/DmaAddr/MmioPtr/...); use the typed constructor or `unsafe`");
                }
            }
        }

        return target;
    }

    // `declassify(secret)` / `reveal(secret)` — the controlled escape from the
    // constant-time discipline. It takes a `Secret<T>` and yields a plain T, so
    // its result is no longer secret-tainted and CAN feed branches/indices. Because
    // that defeats the leak protection, it is only allowed inside `unsafe` (the
    // caller asserts the timing channel is acceptable here). Returns the inner-T
    // class so taint stops propagating; null if this isn't a declassify call.
    fn checkDeclassifyCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        if (!isDeclassifyCallName(call.callee.*)) return null;
        if (call.type_args.len != 0 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "declassify/reveal takes exactly one secret value argument");
            return .unknown;
        }
        if (!ctx.in_unsafe) {
            self.errorCode(span, "E_UNSAFE_REQUIRED", "declassify/reveal escapes the constant-time discipline and requires unsafe");
        }
        const arg = call.args[0];
        const arg_class = self.checkExpr(arg, ctx);
        if (arg_class != .secret) {
            self.errorCode(arg.span, "E_DECLASSIFY_NOT_SECRET", "declassify/reveal applies only to a Secret<T> value");
            return .unknown;
        }
        // Result is the underlying T, classified from Secret<T>'s payload type.
        const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx);
        if (arg_ty) |ty| {
            if (secretPayloadType(resolveAliasType(ty, ctx))) |inner| return classifyTypeCtx(inner, ctx);
        }
        return .unknown;
    }

    fn checkMmioReadOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = mmioOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO read ordering must be .relaxed or .acquire");
            return;
        };
        if (!isMmioReadOrdering(ordering)) {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO read ordering must be .relaxed or .acquire");
        }
    }

    fn checkMmioWriteOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = mmioOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO write ordering must be .relaxed or .release");
            return;
        };
        if (!isMmioWriteOrdering(ordering)) {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO write ordering must be .relaxed or .release");
        }
    }

    fn mmioOrderingName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .enum_literal => |literal| literal.text,
            else => null,
        };
    }

    fn atomicOrderingName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .enum_literal => |literal| literal.text,
            else => null,
        };
    }

    fn isAtomicOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or
            std.mem.eql(u8, ordering, "acquire") or
            std.mem.eql(u8, ordering, "release") or
            std.mem.eql(u8, ordering, "acq_rel") or
            std.mem.eql(u8, ordering, "seq_cst");
    }

    fn isAtomicLoadOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or
            std.mem.eql(u8, ordering, "acquire") or
            std.mem.eql(u8, ordering, "seq_cst");
    }

    fn isAtomicStoreOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or
            std.mem.eql(u8, ordering, "release") or
            std.mem.eql(u8, ordering, "seq_cst");
    }

    fn isMmioReadOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or std.mem.eql(u8, ordering, "acquire");
    }

    fn isMmioWriteOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or std.mem.eql(u8, ordering, "release");
    }

    pub fn errorCode(self: *Checker, span: diagnostics.Span, code: []const u8, message: []const u8) void {
        self.reporter.err(span, "{s}: {s}", .{ code, message });
    }

    // ----- T(term)1: bounded-loop / no-unbounded-recursion check ----------------
    //
    // A function in IRQ/atomic context (or marked `#[bounded]`) must terminate:
    // a kernel can't hang inside an interrupt. Static termination is undecidable
    // in general, so we recognize SHAPES (not prove termination):
    //
    //   * `for x in ARR/SLICE` — always accepted (iteration is over a finite,
    //     fixed-extent base; the type checker already enforces the base is an
    //     array or slice via E_FOR_BASE_NOT_ARRAY_OR_SLICE).
    //   * `while COUNTER </<=/>/>= BOUND { …; COUNTER = COUNTER +/- k; … }` —
    //     accepted when the condition is a relational comparison naming a local
    //     `COUNTER`, and the body monotonically advances that same counter toward
    //     the bound (increment with `<`/`<=`, decrement with `>`/`>=`). `BOUND`
    //     may be any expression (constant, length, field) — we bound the trip
    //     count by the counter's monotone progress, not by evaluating the bound.
    //   * any `while`/`for` whose body contains a `break` — accepted (the break
    //     is an escape hatch; we do not prove it is reached).
    //
    // Everything else is rejected with E_UNBOUNDED_LOOP — notably `while true {}`
    // and any `while cond {}` whose counter is not advanced. This is conservative
    // (false positives on genuinely-bounded but unrecognized shapes), which is
    // why the whole check is opt-in via the attribute.
    //
    // Recursion: DIRECT self-recursion (the function calls itself by name) from a
    // bounded-context function is E_UNBOUNDED_RECURSION. Mutual/indirect recursion
    // is NOT covered.
    fn checkTermination(self: *Checker, fn_name: []const u8, body: ast.Block) void {
        self.checkTerminationBlock(fn_name, body);
    }

    fn checkTerminationBlock(self: *Checker, fn_name: []const u8, block: ast.Block) void {
        for (block.items) |stmt| self.checkTerminationStmt(fn_name, stmt);
    }

    fn checkTerminationStmt(self: *Checker, fn_name: []const u8, stmt: ast.Stmt) void {
        switch (stmt.kind) {
            .loop => |loop| {
                if (!loopIsBounded(loop)) {
                    self.errorCode(stmt.span, "E_UNBOUNDED_LOOP", "loop in a bounded/IRQ-context function is not statically bounded (no monotone counter toward a bound, fixed-range for, or break)");
                }
                self.checkTerminationBlock(fn_name, loop.body);
            },
            .if_let => |node| {
                self.checkTerminationBlock(fn_name, node.then_block);
                if (node.else_block) |eb| self.checkTerminationBlock(fn_name, eb);
            },
            .@"switch" => |node| {
                for (node.arms) |arm| switch (arm.body) {
                    .block => |b| self.checkTerminationBlock(fn_name, b),
                    .expr => |e| self.checkTerminationExpr(fn_name, e),
                };
            },
            .unsafe_block, .comptime_block, .block => |b| self.checkTerminationBlock(fn_name, b),
            .contract_block => |cb| self.checkTerminationBlock(fn_name, cb.block),
            .@"return" => |maybe| {
                if (maybe) |e| self.checkTerminationExpr(fn_name, e);
            },
            .@"defer" => |e| self.checkTerminationExpr(fn_name, e),
            .assert => |e| self.checkTerminationExpr(fn_name, e),
            .assignment => |a| {
                self.checkTerminationExpr(fn_name, a.target);
                self.checkTerminationExpr(fn_name, a.value);
            },
            .expr => |e| self.checkTerminationExpr(fn_name, e),
            .let_decl, .var_decl => |local| {
                if (local.init) |e| self.checkTerminationExpr(fn_name, e);
            },
            .asm_stmt, .@"break", .@"continue" => {},
        }
    }

    fn checkTerminationExpr(self: *Checker, fn_name: []const u8, expr: ast.Expr) void {
        switch (expr.kind) {
            .call => |c| {
                // Direct self-recursion: callee is the bare name of this function.
                if (c.callee.kind == .ident and std.mem.eql(u8, c.callee.kind.ident.text, fn_name)) {
                    self.errorCode(expr.span, "E_UNBOUNDED_RECURSION", "direct recursion from a bounded/IRQ-context function (a kernel must not recurse unboundedly in interrupt/atomic context)");
                }
                self.checkTerminationExpr(fn_name, c.callee.*);
                for (c.args) |arg| self.checkTerminationExpr(fn_name, arg);
            },
            .block => |b| self.checkTerminationBlock(fn_name, b),
            .grouped, .address_of, .deref => |inner| self.checkTerminationExpr(fn_name, inner.*),
            .unary => |u| self.checkTerminationExpr(fn_name, u.expr.*),
            .binary => |b| {
                self.checkTerminationExpr(fn_name, b.left.*);
                self.checkTerminationExpr(fn_name, b.right.*);
            },
            .cast => |c| self.checkTerminationExpr(fn_name, c.value.*),
            .index => |i| {
                self.checkTerminationExpr(fn_name, i.base.*);
                self.checkTerminationExpr(fn_name, i.index.*);
            },
            .slice => |s| {
                self.checkTerminationExpr(fn_name, s.base.*);
                self.checkTerminationExpr(fn_name, s.start.*);
                self.checkTerminationExpr(fn_name, s.end.*);
            },
            .member => |m| self.checkTerminationExpr(fn_name, m.base.*),
            .try_expr => |t| {
                self.checkTerminationExpr(fn_name, t.operand.*);
                if (t.mapped) |m| self.checkTerminationExpr(fn_name, m.*);
            },
            .array_literal => |items| for (items) |it| self.checkTerminationExpr(fn_name, it),
            .struct_literal => |fields| for (fields) |f| self.checkTerminationExpr(fn_name, f.value),
            else => {},
        }
    }

    // A loop matches a recognized statically-bounded shape (see checkTermination).
    fn loopIsBounded(loop: ast.Loop) bool {
        if (loop.kind == .@"for") return true; // iterates a finite array/slice
        // `while`: a relational comparison whose counter is advanced monotonically
        // toward the bound, or any loop body carrying a `break`.
        if (blockHasBreak(loop.body)) return true;
        const cond = loop.iterable orelse return false;
        const counter = relationalCounter(cond) orelse return false;
        return bodyAdvancesCounter(loop.body, counter.name, counter.toward_increase);
    }

    const CounterRel = struct { name: []const u8, toward_increase: bool };

    // Recognize `COUNTER < BOUND` / `<=` / `>` / `>=` where one side is a bare
    // identifier. `toward_increase` is true when the counter must grow to reach
    // the bound (`<`, `<=`), false when it must shrink (`>`, `>=`).
    fn relationalCounter(cond: ast.Expr) ?CounterRel {
        const expr = if (cond.kind == .grouped) cond.kind.grouped.* else cond;
        const b = switch (expr.kind) {
            .binary => |bin| bin,
            else => return null,
        };
        const counter_on_left: bool = b.left.kind == .ident;
        const counter_on_right: bool = b.right.kind == .ident;
        if (!counter_on_left and !counter_on_right) return null;
        const name = if (counter_on_left) b.left.kind.ident.text else b.right.kind.ident.text;
        // Direction the counter must move to *stay in* the loop's bound, i.e.
        // toward making the condition false. `i < N`: i increases. `i > 0`: i
        // decreases. When the counter is the right operand, flip.
        const increases: bool = switch (b.op) {
            .lt, .le => true,
            .gt, .ge => false,
            else => return null,
        };
        return .{ .name = name, .toward_increase = if (counter_on_left) increases else !increases };
    }

    fn blockHasBreak(block: ast.Block) bool {
        for (block.items) |stmt| if (stmtHasBreak(stmt)) return true;
        return false;
    }

    // A `break` that escapes *this* loop. Breaks nested inside an inner loop
    // belong to that inner loop, so we do not descend into nested loop bodies.
    fn stmtHasBreak(stmt: ast.Stmt) bool {
        return switch (stmt.kind) {
            .@"break" => true,
            .loop => false,
            .if_let => |n| blockHasBreak(n.then_block) or (if (n.else_block) |eb| blockHasBreak(eb) else false),
            .@"switch" => |n| blk: {
                for (n.arms) |arm| switch (arm.body) {
                    .block => |b| if (blockHasBreak(b)) break :blk true,
                    .expr => {},
                };
                break :blk false;
            },
            .unsafe_block, .comptime_block, .block => |b| blockHasBreak(b),
            .contract_block => |cb| blockHasBreak(cb.block),
            else => false,
        };
    }

    // The loop body assigns `name = name +/- k` (or `name = k +/- name`) in the
    // direction that drives the condition false. Recognizes the common increment
    // (`i = i + 1`) and decrement (`i = i - 1`) shapes; also `i = i + step`.
    fn bodyAdvancesCounter(block: ast.Block, name: []const u8, toward_increase: bool) bool {
        for (block.items) |stmt| if (stmtAdvancesCounter(stmt, name, toward_increase)) return true;
        return false;
    }

    fn stmtAdvancesCounter(stmt: ast.Stmt, name: []const u8, toward_increase: bool) bool {
        return switch (stmt.kind) {
            .assignment => |a| blk: {
                if (a.target.kind != .ident or !std.mem.eql(u8, a.target.kind.ident.text, name)) break :blk false;
                const v = if (a.value.kind == .grouped) a.value.kind.grouped.* else a.value;
                const bin = switch (v.kind) {
                    .binary => |b| b,
                    else => break :blk false,
                };
                const refs_left = bin.left.kind == .ident and std.mem.eql(u8, bin.left.kind.ident.text, name);
                const refs_right = bin.right.kind == .ident and std.mem.eql(u8, bin.right.kind.ident.text, name);
                if (!refs_left and !refs_right) break :blk false;
                // `+` advances the counter up; `-` advances it down. (`k - i`
                // is not a monotone self-update, so require the counter on the
                // left for subtraction.)
                break :blk switch (bin.op) {
                    .add => toward_increase,
                    .sub => !toward_increase and refs_left,
                    else => false,
                };
            },
            // Recurse into nested control flow so the update may sit under a
            // conditional/block — still the same loop body.
            .if_let => |n| blk: {
                if (bodyAdvancesCounter(n.then_block, name, toward_increase)) break :blk true;
                if (n.else_block) |eb| if (bodyAdvancesCounter(eb, name, toward_increase)) break :blk true;
                break :blk false;
            },
            // (bug #4) A plain `if`/`else` desugars to a `switch` on the bool, so the
            // counter update may live inside a switch arm — the same loop body. Forgetting
            // this arm was the bounded-loop false positive; mirror `stmtHasBreak`'s switch.
            .@"switch" => |n| blk: {
                for (n.arms) |arm| switch (arm.body) {
                    .block => |b| if (bodyAdvancesCounter(b, name, toward_increase)) break :blk true,
                    .expr => {},
                };
                break :blk false;
            },
            .unsafe_block, .comptime_block, .block => |b| bodyAdvancesCounter(b, name, toward_increase),
            .contract_block => |cb| bodyAdvancesCounter(cb.block, name, toward_increase),
            else => false,
        };
    }

    // ----- inline-asm register/constraint verification (§23.2) ------------------
    //
    // The backends lower precise-asm operands with generic `"r"` constraints and
    // keep the requested registers only as a provenance comment — the contract
    // *trusts* the register facts. These checks *verify* them so a per-architecture
    // precise-asm block is portable-by-construction: each named register is real,
    // the block names registers of a single architecture, and no register is bound
    // to two operands or clobbered while also holding an operand.

    const AsmArch = enum { x86_64, riscv64, aarch64 };

    // Strip the lexeme's surrounding quotes (registers/clobbers are stored as
    // `"rax"`, including the quotes — matching how the lowering emits them).
    fn asmUnquote(reg: []const u8) []const u8 {
        if (reg.len >= 2 and reg[0] == '"' and reg[reg.len - 1] == '"') return reg[1 .. reg.len - 1];
        return reg;
    }

    // `memory` / `cc` are architecture-neutral pseudo-clobbers, valid everywhere.
    fn asmIsPseudoClobber(name: []const u8) bool {
        return std.mem.eql(u8, name, "memory") or std.mem.eql(u8, name, "cc");
    }

    // A generic (machine-independent or register-class) constraint code — a single
    // letter such as `r` (any register), `m` (memory), `i`/`n` (immediate), `f`
    // (float register), or the x86 class letters `a`/`b`/`c`/`d`. These are not
    // physical registers: they are architecture-neutral and may be repeated across
    // operands (two `"r"` operands are two distinct registers), so they are exempt
    // from the per-architecture and register-conflict checks. Named physical
    // registers are always longer than one character (`rax`, `a0`, `x0`, …), so a
    // single alphabetic token is unambiguously a constraint code.
    fn asmIsGenericConstraint(name: []const u8) bool {
        return name.len == 1 and std.ascii.isAlphabetic(name[0]);
    }

    // The architecture a register name unambiguously belongs to, or null when the
    // name is shared across architectures (`x0..x30`, `sp`) — those are accepted
    // but do not pin the block's architecture, so they never cause a false mismatch.
    // Returns error.Unknown for a name that is not a register on any supported arch.
    fn asmRegisterArch(name: []const u8) error{Unknown}!?AsmArch {
        const x86 = [_][]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
        for (x86) |r| if (std.mem.eql(u8, name, r)) return .x86_64;
        // RISC-V ABI names that are unambiguous (excludes `sp`, shared with aarch64).
        const rv = [_][]const u8{ "zero", "ra", "gp", "tp", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7" };
        for (rv) |r| if (std.mem.eql(u8, name, r)) return .riscv64;
        // AArch64 names that are unambiguous (`w0..w30`, `xzr`, `wzr`, `lr`).
        if (std.mem.eql(u8, name, "xzr") or std.mem.eql(u8, name, "wzr") or std.mem.eql(u8, name, "lr")) return .aarch64;
        if (asmNumberedReg(name, "w", 0, 30)) return .aarch64;
        // Shared / ambiguous: `x0..x31` (riscv x-regs ∩ aarch64 x-regs) and `sp`.
        if (std.mem.eql(u8, name, "sp")) return null;
        if (asmNumberedReg(name, "x", 0, 31)) return null;
        // ----- vector / floating-point register files -----
        // x86-64 SSE/AVX/AVX-512: xmm/ymm/zmm 0..31.
        if (asmNumberedReg(name, "xmm", 0, 31) or asmNumberedReg(name, "ymm", 0, 31) or asmNumberedReg(name, "zmm", 0, 31)) return .x86_64;
        // RISC-V floating-point: `f0..f31` plus the ABI names `ft`/`fs`/`fa`.
        if (asmNumberedReg(name, "ft", 0, 11) or asmNumberedReg(name, "fs", 0, 11) or asmNumberedReg(name, "fa", 0, 7) or asmNumberedReg(name, "f", 0, 31)) return .riscv64;
        // AArch64 SIMD/FP register views: q (128b), d (64b), h (16b), b (8b). The `s` (32b)
        // view is intentionally omitted — it collides with the RISC-V saved-GPR ABI names
        // `s1..s11`, so it would be ambiguous.
        if (asmNumberedReg(name, "q", 0, 31) or asmNumberedReg(name, "d", 0, 31) or asmNumberedReg(name, "h", 0, 31) or asmNumberedReg(name, "b", 0, 31)) return .aarch64;
        // The vector register file `v0..v31` is shared (RISC-V vector ∩ AArch64 SIMD) — neutral.
        if (asmNumberedReg(name, "v", 0, 31)) return null;
        return error.Unknown;
    }

    // True when `name` is `prefix` followed by a decimal in [lo, hi] (no leading zeros).
    fn asmNumberedReg(name: []const u8, prefix: []const u8, lo: u32, hi: u32) bool {
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        const digits = name[prefix.len..];
        if (digits.len == 0 or digits.len > 2) return false;
        if (digits.len == 2 and digits[0] == '0') return false;
        const n = std.fmt.parseInt(u32, digits, 10) catch return false;
        return n >= lo and n <= hi;
    }

    fn checkAsmConstraints(self: *Checker, asm_stmt: ast.AsmStmt, span: diagnostics.Span) void {
        var block_arch: ?AsmArch = null;

        // Unify a named register into the block's architecture (or flag a mismatch),
        // reporting an unknown register. Pseudo-clobbers are skipped by the caller.
        const unify = struct {
            fn call(checker: *Checker, sp: diagnostics.Span, arch: *?AsmArch, raw: []const u8) void {
                const name = asmUnquote(raw);
                if (asmIsGenericConstraint(name)) return; // arch-neutral; not a physical register
                const reg_arch = asmRegisterArch(name) catch {
                    checker.errorCode(sp, "E_ASM_UNKNOWN_REGISTER", "inline-asm names a register that is not valid on any supported architecture");
                    return;
                };
                if (reg_arch) |a| {
                    if (arch.* == null) {
                        arch.* = a;
                    } else if (arch.* != a) {
                        checker.errorCode(sp, "E_ASM_ARCH_MIXED", "inline-asm block mixes registers from more than one architecture");
                    }
                }
            }
        }.call;

        // Named operand registers must be unique across outputs+inputs. A generic
        // constraint code (`"r"`, `"m"`, …) is not a physical register and may repeat,
        // so it is exempt from both the conflict and the architecture checks.
        var used = std.StringHashMap(void).init(self.reporter.allocator);
        defer used.deinit();
        for (asm_stmt.outputs) |output| {
            const name = asmUnquote(output.reg);
            unify(self, span, &block_arch, output.reg);
            if (asmIsGenericConstraint(name)) continue;
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_REGISTER_CONFLICT", "inline-asm binds the same register to more than one operand");
            } else used.put(name, {}) catch {
                self.oom = true;
            };
        }
        for (asm_stmt.inputs) |input| {
            const name = asmUnquote(input.reg);
            unify(self, span, &block_arch, input.reg);
            if (asmIsGenericConstraint(name)) continue;
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_REGISTER_CONFLICT", "inline-asm binds the same register to more than one operand");
            } else used.put(name, {}) catch {
                self.oom = true;
            };
        }
        // A clobber may not name a register an operand already holds, and a non-pseudo,
        // non-generic clobber participates in architecture unification too.
        for (asm_stmt.clobbers) |clobber| {
            const name = asmUnquote(clobber);
            if (asmIsPseudoClobber(name) or asmIsGenericConstraint(name)) continue;
            unify(self, span, &block_arch, clobber);
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_CLOBBER_CONFLICT", "inline-asm clobbers a register it also binds to an operand");
            }
        }
    }

    // `#[backend_name("Y")]` overrides the object symbol; two declarations may not map to the
    // same backend symbol, or one would silently shadow the other at link time.
    fn checkBackendNameUniqueness(self: *Checker, module: ast.Module) void {
        var seen = std.StringHashMap(ast.Ident).init(self.reporter.allocator);
        defer seen.deinit();
        for (module.decls) |decl| {
            const name_ident: ast.Ident = switch (decl.kind) {
                .fn_decl => |f| f.name,
                .extern_fn => |f| f.name,
                else => continue,
            };
            const override = backendNameAttr(decl.attrs) orelse continue;
            if (seen.get(override)) |prev| {
                self.reporter.err(name_ident.span, "E_DUPLICATE_BACKEND_NAME: backend symbol \"{s}\" is assigned to both `{s}` and `{s}`", .{ override, prev.text, name_ident.text });
            } else {
                seen.put(override, name_ident) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkTrapKind(self: *Checker, span: diagnostics.Span, args: []ast.Expr) void {
        if (args.len != 1) {
            self.errorCode(span, "E_INVALID_TRAP_KIND", "trap expects exactly one language TrapKind");
            return;
        }
        const kind = switch (args[0].kind) {
            .enum_literal => |literal| literal,
            else => {
                self.errorCode(args[0].span, "E_INVALID_TRAP_KIND", "trap kind must be a language TrapKind enum literal");
                return;
            },
        };
        if (!isLanguageTrapKind(kind.text)) {
            self.errorCode(kind.span, "E_INVALID_TRAP_KIND", "unknown language TrapKind");
        }
    }

    fn checkReflectionCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const kind = reflectionKind(call.callee.*) orelse return null;
        const errors_before = self.reporter.diagnostics.items.len;
        const target = self.reflectionTarget(span, call) orelse return reflectionReturnClass(kind);
        const reflected_ty = target.ty;
        if (isTypeName(reflected_ty, "c_void")) {
            self.errorCode(span, "E_C_VOID_NO_LAYOUT", "c_void has no size or alignment in MC");
            return reflectionReturnClass(kind);
        }
        self.checkReflectedType(reflected_ty, ctx);

        if (reflectionRequiresField(kind)) {
            if (target.args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "field reflection requires exactly one enum-literal field name");
                return reflectionReturnClass(kind);
            }
            const field = enumLiteralName(target.args[0]) orelse {
                self.errorCode(target.args[0].span, "E_REFLECTION_FIELD_LITERAL", "field reflection requires an enum-literal field name");
                return reflectionReturnClass(kind);
            };
            self.checkReflectedField(kind, reflected_ty, field, ctx);
        } else if (target.args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "type reflection builtin does not take runtime arguments");
        }

        if (self.reporter.diagnostics.items.len == errors_before) {
            self.checkComputableReflectionLayout(kind, target, ctx);
        }

        if (kind == .field_type and self.reporter.diagnostics.items.len == errors_before) {
            self.errorCode(span, "E_REFLECTION_TYPE_VALUE", "field_type produces a type and is valid only in type position");
        }

        return reflectionReturnClass(kind);
    }

    fn reflectionTarget(self: *Checker, span: diagnostics.Span, call: anytype) ?ReflectionTarget {
        if (call.type_args.len > 0) {
            if (call.type_args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "reflection builtin requires exactly one reflected type");
                return null;
            }
            return .{ .ty = call.type_args[0], .args = call.args };
        }
        if (call.args.len == 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "reflection builtin requires a reflected type");
            return null;
        }
        const ty = reflectionTypeExprFromArg(call.args[0]) orelse {
            self.errorCode(call.args[0].span, "E_REFLECTION_TYPE_ARG", "reflection type argument must be a type name");
            return null;
        };
        return .{ .ty = ty, .args = call.args[1..] };
    }

    fn checkReflectedType(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        var reflection_ctx = ctx;
        reflection_ctx.allow_mmio_register_type = true;
        self.checkReflectedGenericTypeArgs(ty, reflection_ctx);
        if (reflectionGenericHasWrongArity(ty)) {
            self.errorCode(ty.span, "E_REFLECTION_GENERIC_ARG_COUNT", "reflection generic type has the wrong number of type arguments");
            return;
        }
        if (isKnownLayoutType(ty, ctx)) return;
        self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "reflection requires a known layout-capable type");
    }

    fn checkComputableReflectionLayout(self: *Checker, kind: ReflectionKind, target: ReflectionTarget, ctx: Context) void {
        if (kind == .field_type or reflectionTargetDependsOnGenericParam(target.ty, ctx)) return;
        const env = self.reflect_env orelse return;
        const value: ?i128 = switch (kind) {
            .size => sema_reflect.comptimeSizeOf(env, target.ty, 0),
            .alignment => sema_reflect.comptimeAlignOf(env, target.ty, 0),
            .repr => sema_reflect.comptimeReprOf(env, target.ty, 0),
            .field_offset => blk: {
                const field = enumLiteralName(target.args[0]) orelse return;
                break :blk sema_reflect.comptimeFieldOffset(env, target.ty, field.text, 0);
            },
            .bit_offset => blk: {
                const field = enumLiteralName(target.args[0]) orelse return;
                break :blk sema_reflect.comptimeBitOffset(env, target.ty, field.text, 0);
            },
            .field_type => unreachable,
        };
        if (value == null) {
            self.errorCode(target.ty.span, "E_REFLECTION_UNKNOWN_TYPE", "reflection layout could not be computed for this type");
        }
    }

    fn checkReflectedGenericTypeArgs(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        switch (ty.kind) {
            .generic => |node| {
                self.checkGenericTypeArgs(node, ctx);
                for (node.args) |arg| self.checkReflectedGenericTypeArgs(arg, ctx);
            },
            .qualified => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .nullable => |child| self.checkReflectedGenericTypeArgs(child.*, ctx),
            .pointer => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .raw_many_pointer => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .slice => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .array => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .fn_pointer => |node| {
                for (node.params) |param| self.checkReflectedGenericTypeArgs(param, ctx);
                self.checkReflectedGenericTypeArgs(node.ret.*, ctx);
            },
            .closure_type => |node| {
                for (node.params) |param| self.checkReflectedGenericTypeArgs(param, ctx);
                self.checkReflectedGenericTypeArgs(node.ret.*, ctx);
            },
            .member, .name, .enum_literal, .dyn_trait => {},
        }
    }

    fn checkReflectedField(self: *Checker, kind: ReflectionKind, ty: ast.TypeExpr, field: ast.Ident, ctx: Context) void {
        const name = typeName(ty) orelse {
            self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
            return;
        };
        if (layoutFieldInfo(name, ctx)) |info| {
            if (!info.fields.contains(field.text)) {
                self.errorCode(field.span, "E_UNKNOWN_STRUCT_FIELD", "layout type has no field with this name");
            }
        } else if (kind == .field_type) {
            const tagged_unions = ctx.tagged_unions orelse {
                self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
                return;
            };
            const union_info = tagged_unions.get(name) orelse {
                self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
                return;
            };
            const payload_ty = union_info.cases.get(field.text) orelse {
                self.errorCode(field.span, "E_UNKNOWN_STRUCT_FIELD", "layout type has no field with this name");
                return;
            };
            if (payload_ty == null) {
                self.errorCode(field.span, "E_UNION_CASE_HAS_NO_PAYLOAD", "union case has no payload type");
            }
        } else {
            self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
        }
    }

    fn checkIntegerLiteralInitializer(self: *Checker, target: TypeClass, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const value = integerLiteralValue(expr) orelse {
            if (integerLiteralSyntaxOverflow(expr)) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                return true;
            }
            return false;
        };
        if (target == .wrap or target == .sat) {
            const bounds = arithmeticDomainInnerBounds(resolveAliasType(target_ty, ctx), if (target == .wrap) "wrap" else "sat", ctx) orelse return false;
            if (value.negative or value.magnitude > bounds.max) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                return true;
            }
            return true;
        }
        // `Secret<intT>` accepts an in-range integer literal, range-checked against
        // the inner integer type (a literal is the natural way to introduce a key
        // byte / constant secret).
        if (target == .secret) {
            const inner = secretPayloadType(resolveAliasType(target_ty, ctx)) orelse return false;
            const bounds = checkedIntBounds(classifyTypeCtx(inner, ctx)) orelse return false;
            if (value.negative) {
                if (!bounds.signed or value.magnitude > bounds.min_abs) {
                    self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                }
            } else if (value.magnitude > bounds.max) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return true;
        }
        const bounds = checkedIntBounds(target) orelse return false;
        if (value.negative) {
            if (!bounds.signed or value.magnitude > bounds.min_abs) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return true;
        }
        if (value.magnitude > bounds.max) {
            self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
        }
        return true;
    }

    // A plain value of T (or another Secret<T>) may initialize/assign a Secret<T>:
    // classifying a value as secret is a non-narrowing tag, range-checked by the
    // inner type's own rules. Returns true if it handled the initializer (so the
    // caller skips the generic E_NO_IMPLICIT_CONVERSION gate).
    fn checkSecretWrapInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const inner = secretPayloadType(resolveAliasType(target_ty, ctx)) orelse return false;
        const value_class = self.checkExpr(expr, ctx);
        // Already a secret (Secret<T> -> Secret<T>) or the neutral classes: accept.
        if (value_class == .secret or isDiagnosticNeutralOperand(value_class)) return true;
        // An integer literal is handled by checkIntegerLiteralInitializer; defer.
        if (integerLiteralValue(expr) != null) return false;
        const inner_class = classifyTypeCtx(inner, ctx);
        if (value_class == inner_class) return true;
        self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "Secret<T> can only wrap a value of its underlying type T");
        return true;
    }

    fn checkNullPointerInitializer(self: *Checker, target: TypeClass, expr: ast.Expr) bool {
        if (!isNullLiteral(expr)) return false;
        // `null` initializes any nullable: the pointer nullables (sentinel repr) and
        // a value optional `?T` (tagged repr, `present = false`).
        if (isNullablePointerLike(target) or target == .nullable_dyn_trait or target == .nullable_value) return true;
        if (isNonNullPointerLike(target)) {
            self.errorCode(expr.span, "E_NULL_NON_NULL_POINTER", "null cannot initialize a non-null pointer");
            return true;
        }
        return false;
    }

    fn checkArrayDecayInitializer(self: *Checker, target: TypeClass, initializer: TypeClass, expr: ast.Expr) bool {
        if (initializer != .array) return false;
        if (isPointerLike(target)) {
            self.errorCode(expr.span, "E_ARRAY_TO_POINTER_DECAY", "arrays do not implicitly decay to pointers");
            return true;
        }
        return false;
    }

    fn checkArrayLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const items = arrayLiteralItems(expr) orelse return false;
        const resolved_target_ty = resolveAliasType(target_ty, ctx);
        const array = switch (resolved_target_ty.kind) {
            .array => |node| node,
            .qualified => |node| switch (node.child.kind) {
                .array => |array_node| array_node,
                else => {
                    self.errorCode(expr.span, code, message);
                    return true;
                },
            },
            else => {
                self.errorCode(expr.span, code, message);
                return true;
            },
        };
        const expected_len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse {
            self.errorCode(array.len.span, "E_ARRAY_LITERAL_LENGTH", "array literal target must have a known constant length");
            return true;
        };
        if (items.len != expected_len) {
            self.errorCode(expr.span, "E_ARRAY_LITERAL_LENGTH", "array literal element count must match the target array length");
        }
        const element_ty = array.child.*;
        const element_class = classifyTypeCtx(element_ty, ctx);
        for (items) |item| {
            const item_class = self.checkExpr(item, ctx);
            const literal_checked = self.checkIntegerLiteralInitializer(element_class, element_ty, item, ctx);
            const null_checked = self.checkNullPointerInitializer(element_class, item);
            const array_literal_checked = self.checkArrayLiteralInitializer(element_ty, item, ctx, code, message);
            const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(element_ty, item, ctx, code, message);
            const pointer_conversion_checked = self.checkPointerViewInitializer(element_ty, item, ctx);
            const c_void_conversion_checked = self.checkCVoidPointerConversion(element_ty, item, ctx);
            const address_checked = self.checkAddressOfInitializer(element_class, element_ty, item, ctx);
            const fn_pointer_checked = self.checkFunctionPointerInitializer(element_ty, item, ctx);
            const closure_checked = self.checkClosureInitializer(element_ty, item, ctx);
            const dyn_checked = self.checkDynCoercionInitializer(element_ty, item, ctx);
            const address_class_checked = checkAddressClassConversion(self, item.span, element_class, item_class);
            const enum_checked = self.checkEnumValueCompatibility(element_ty, item, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(element_ty, item, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(item, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !dyn_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(element_class, item_class)) {
                self.errorCode(item.span, code, message);
            }
        }
        return true;
    }

    fn checkStructLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const literal_fields = structLiteralFields(expr) orelse return false;
        const resolved_target_ty = resolveAliasType(target_ty, ctx);
        // An `opaque struct` (including a generic one, e.g. `GenRef<T>`, whose name the
        // plain `structTypeName` below does not resolve) may only be constructed by its
        // own associated functions — a struct literal names every field, so building one
        // outside `impl Name { … }` would forge a handle.
        if (opacityStructName(resolved_target_ty)) |sname| {
            if (ctx.structs) |structs| {
                if (structs.get(sname)) |info| {
                    if (info.is_opaque and !self.opaqueAccessAllowed(sname)) {
                        self.errorCode(expr.span, "E_PRIVATE_FIELD", "cannot construct an `opaque struct` outside its associated functions (`impl` block); its fields are private");
                    }
                }
            }
        }
        if (packedBitsInfoForType(resolved_target_ty, ctx) != null) return false;
        const struct_name = structTypeName(resolved_target_ty) orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };
        const structs = ctx.structs orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };
        const struct_info = structs.get(struct_name) orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };

        var seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer seen.deinit();
        for (literal_fields) |field| {
            if (seen.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_LITERAL_FIELD", "struct literal field names must be unique");
            } else {
                seen.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
            const field_ty = struct_info.fields.get(field.name.text) orelse {
                self.errorCode(field.name.span, "E_UNKNOWN_STRUCT_FIELD", "struct has no field with this name");
                _ = self.checkExpr(field.value, ctx);
                continue;
            };
            const value_class = self.checkExpr(field.value, ctx);
            const field_class = classifyTypeCtx(field_ty, ctx);
            const literal_checked = self.checkIntegerLiteralInitializer(field_class, field_ty, field.value, ctx);
            const null_checked = self.checkNullPointerInitializer(field_class, field.value);
            const array_literal_checked = self.checkArrayLiteralInitializer(field_ty, field.value, ctx, code, message);
            const struct_literal_checked = self.checkStructLiteralInitializer(field_ty, field.value, ctx, code, message);
            const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(field_ty, field.value, ctx, code, message);
            const pointer_conversion_checked = self.checkPointerViewInitializer(field_ty, field.value, ctx);
            const c_void_conversion_checked = self.checkCVoidPointerConversion(field_ty, field.value, ctx);
            const address_checked = self.checkAddressOfInitializer(field_class, field_ty, field.value, ctx);
            const fn_pointer_checked = self.checkFunctionPointerInitializer(field_ty, field.value, ctx);
            const closure_checked = self.checkClosureInitializer(field_ty, field.value, ctx);
            // The uniform `*T -> *dyn Trait` coercion at a struct-field init.
            const dyn_checked = self.checkDynCoercionInitializer(field_ty, field.value, ctx);
            const address_class_checked = checkAddressClassConversion(self, field.value.span, field_class, value_class);
            const enum_checked = self.checkEnumValueCompatibility(field_ty, field.value, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(field_ty, field.value, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(field.value, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !dyn_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(field_class, value_class)) {
                self.errorCode(field.value.span, code, message);
            }
        }

        var required = struct_info.fields.iterator();
        while (required.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) {
                self.errorCode(expr.span, "E_STRUCT_LITERAL_MISSING_FIELD", "struct literal must initialize every field");
            }
        }
        return true;
    }

    fn checkPackedBitsLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const literal_fields = structLiteralFields(expr) orelse return false;
        const packed_info = packedBitsInfoForType(resolveAliasType(target_ty, ctx), ctx) orelse return false;

        var seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer seen.deinit();
        var has_unknown_field = false;
        for (literal_fields) |field| {
            if (seen.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_LITERAL_FIELD", "struct literal field names must be unique");
            } else {
                seen.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
            const field_ty = packed_info.fields.get(field.name.text) orelse {
                self.errorCode(field.name.span, "E_UNKNOWN_STRUCT_FIELD", "packed bits type has no field with this name");
                has_unknown_field = true;
                _ = self.checkExpr(field.value, ctx);
                continue;
            };
            const value_class = self.checkExpr(field.value, ctx);
            const field_class = classifyTypeCtx(field_ty, ctx);
            if (!canInitialize(field_class, value_class)) {
                self.errorCode(field.value.span, code, message);
            }
        }

        if (!has_unknown_field) {
            var required = packed_info.fields.iterator();
            while (required.next()) |entry| {
                if (!seen.contains(entry.key_ptr.*)) {
                    self.errorCode(expr.span, "E_STRUCT_LITERAL_MISSING_FIELD", "packed bits literal must initialize every field");
                }
            }
        }
        return true;
    }

    fn checkAddressOfInitializer(self: *Checker, target: TypeClass, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        if (!isNonNullPointerLike(target) and !isNullablePointerLike(target)) return false;
        const operand = addressOfOperand(expr) orelse return false;
        const source_ty = addressableStorageType(operand.*, ctx) orelse return true;
        if (!addressOfMatchesPointerTarget(target_ty, source_ty, operand.*, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
        }
        return true;
    }

    fn checkFunctionPointerInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        if (classifyTypeCtx(target_ty, ctx) != .fn_pointer) return false;
        if (directCallName(expr)) |name| {
            if (ctx.functions != null and ctx.functions.?.contains(name)) {
                if (!functionMatchesFnPointer(name, target_ty, ctx)) {
                    self.errorCode(expr.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function signature does not match the expected function-pointer type");
                }
                return true;
            }
        }
        const source_ty = exprDeclaredType(expr, ctx) orelse return false;
        if (classifyTypeCtx(source_ty, ctx) != .fn_pointer) return false;
        if (!sameTypeSyntaxCtx(source_ty, target_ty, ctx)) {
            self.errorCode(expr.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function-pointer signature does not match the expected type");
        }
        return true;
    }

    fn checkClosureInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        if (classifyTypeCtx(target_ty, ctx) != .closure) return false;
        if (bindMatchesClosureExpr(expr, target_ty, ctx)) |matches| {
            if (!matches) {
                self.errorCode(expr.span, "E_CLOSURE_SIGNATURE_MISMATCH", "bind target does not match the expected closure type");
            }
            return true;
        }
        const source_ty = exprDeclaredType(expr, ctx) orelse return false;
        if (classifyTypeCtx(source_ty, ctx) != .closure) return false;
        if (!sameTypeSyntaxCtx(source_ty, target_ty, ctx)) {
            self.errorCode(expr.span, "E_CLOSURE_SIGNATURE_MISMATCH", "closure signature does not match the expected type");
        }
        return true;
    }

    // Tier 2 coercion + forge-safety (traits-design §4,§7). The ONLY safe way to build
    // a `*dyn Trait` value is `&x` / `&mut x` where `impl Trait for typeof(x)` exists:
    //  - `&x` → verify the conformance; missing → E_TRAIT_NOT_SATISFIED.
    //  - an existing `*dyn Trait`-typed value (pass-through) → allowed.
    //  - anything else (hand-assembling `{data, vtable}` from raw parts, casts, etc.)
    //    is a forge attempt — rejected in safe code (E_DYN_FORGE); `unsafe` is the only
    //    escape, exactly like opaque-struct value-declassification. `*dyn` is a
    //    compiler-protected type kind.
    // Returns true when the target is `*dyn Trait` (so the caller suppresses the generic
    // E_NO_IMPLICIT_CONVERSION and trusts this dedicated check).
    // If `callee` is `d.method` where `d` has a `*dyn Trait` type and `method` is one
    // of the trait's methods, return the (trait method signature). A call through it is
    // a dynamic dispatch (load-through-vtable indirect call). Null otherwise.
    // True when `callee` is `recv.method` whose receiver `recv` is a nullable trait object
    // (`?*dyn Trait`) — a dispatch that must be narrowed before it is legal.
    fn nullableDynDispatchReceiver(callee: ast.Expr, ctx: Context) bool {
        const member = memberExpr(callee) orelse return false;
        const base_ty = exprDeclaredType(member.base.*, ctx) orelse exprResultType(member.base.*, ctx) orelse return false;
        return switch (resolveAliasType(base_ty, ctx).kind) {
            .nullable => |child| resolveAliasType(child.*, ctx).kind == .dyn_trait,
            else => false,
        };
    }

    fn dynDispatchSig(self: *Checker, callee: ast.Expr, ctx: Context) ?ast.TraitMethodSig {
        const member = memberExpr(callee) orelse return null;
        const base_ty = exprDeclaredType(member.base.*, ctx) orelse return null;
        const resolved_base = resolveAliasType(base_ty, ctx);
        // The receiver may be the trait object itself (`dyn Trait`) OR a pointer to it
        // (`*dyn Trait` / `*mut dyn Trait`, the common form — a method dispatch auto-derefs the
        // pointer). Resolving the trait method here (BEFORE the free-function fallback below) makes
        // `recv.method()` dispatch to the trait method even when a same-named free function is in
        // scope — e.g. a `*mut dyn Allocator`'s `.alloc()` must be Allocator.alloc, not a free
        // `alloc()` that another imported module happens to export.
        const dyn = switch (resolved_base.kind) {
            .dyn_trait => |d| d,
            .pointer => |p| switch (resolveAliasType(p.child.*, ctx).kind) {
                .dyn_trait => |d| d,
                else => return null,
            },
            else => return null,
        };
        const td = self.trait_decls orelse return null;
        const trait = td.get(dyn.trait_name.text) orelse return null;
        return findTraitMethod(trait.methods, member.name.text);
    }

    fn checkDynCoercionInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const resolved = resolveAliasType(target_ty, ctx);
        // The target is `*dyn Trait` or `?*dyn Trait` (nullable trait object): a
        // `null` source is handled by checkNullPointerInitializer; a non-null source
        // coerces into the niche exactly as for the non-nullable trait object.
        const target_is_nullable = resolved.kind == .nullable;
        const dyn = switch (resolved.kind) {
            .dyn_trait => |d| d,
            .nullable => |child| switch (resolveAliasType(child.*, ctx).kind) {
                .dyn_trait => |d| d,
                else => return false,
            },
            else => return false,
        };
        if (isNullLiteral(expr)) return true;
        // A `?*dyn Trait` SOURCE: copying it into another `?*dyn` is fine (a nullable copy),
        // but coercing it into a non-null `*dyn` drops the `none` case — that is not a forge
        // (F3), it is a missing narrow. Require `if let` / `switch` / `unwrap` first.
        if (exprResultType(expr, ctx)) |src0| {
            if (resolveAliasType(src0, ctx).kind == .nullable) {
                if (nullableInnerType(resolveAliasType(src0, ctx))) |inner| {
                    if (resolveAliasType(inner, ctx).kind == .dyn_trait) {
                        if (!target_is_nullable) {
                            self.errorCode(expr.span, "E_NULLABLE_DYN_NARROW", "a `?*dyn Trait` cannot coerce to a non-null `*dyn Trait`: it may be `none`. Narrow it with `if let` / `switch`, or `unwrap` it first");
                        }
                        return true; // nullable->nullable copy is fine; the non-null case erred above
                    }
                }
            }
        }
        // `&x` / `&mut x`: the checked coercion. Verify the concrete type conforms.
        if (addressOfOperand(expr)) |operand| {
            // A `*mut dyn Trait` borrow needs a mutable place.
            if (dyn.mutability == .mut and !addressableStorageIsMutable(operand.*, ctx)) {
                self.errorCode(expr.span, "E_DYN_MUT_BORROW", "a `*mut dyn Trait` requires `&mut` of a mutable place");
                return true;
            }
            const source_ty = addressableStorageType(operand.*, ctx) orelse return true;
            const type_name = typeName(resolveAliasType(source_ty, ctx)) orelse {
                self.errorCode(expr.span, "E_TRAIT_NOT_SATISFIED", "a `*dyn Trait` can only be formed from a concrete nominal type that implements the trait");
                return true;
            };
            if (!self.traitConforms(dyn.trait_name.text, type_name)) {
                self.errorCode(expr.span, "E_TRAIT_NOT_SATISFIED", "no `impl Trait for Type` for this concrete type, so it cannot coerce to `*dyn Trait`");
            }
            return true;
        }
        // A `*T` VALUE (not a `&x` literal — a `*Square` parameter, a `*T` field, a
        // `*T` returned from a call, etc.) coerces to `*dyn Trait` the SAME way `&x`
        // does: the vtable is synthesized from the STATIC pointee type T. This is the
        // uniform coercion — it must work at every assignment context (return, field,
        // arg, …), not only `&x` at a `let`. Verify `impl Trait for T` here; the
        // backend emits `{data, vtable=&__vt_T_Trait}` keyed on T.
        if (exprResultType(expr, ctx) orelse exprDeclaredType(expr, ctx)) |src| {
            const resolved_src = resolveAliasType(src, ctx);
            // Passing an existing `*dyn Trait` value through (same trait): allowed. The
            // target may be `*dyn Trait` or `?*dyn Trait` (the some-coercion), so compare
            // the source's trait against the unwrapped target trait, not the full type.
            if (resolved_src.kind == .dyn_trait) {
                if (std.mem.eql(u8, resolved_src.kind.dyn_trait.trait_name.text, dyn.trait_name.text)) return true;
            }
            // A `*T` value where T is a concrete nominal type that conforms.
            if (dynSourcePointeeTypeName(resolved_src)) |type_name| {
                // A `*mut dyn Trait` target needs a `*mut T` source (mutable borrow).
                if (dyn.mutability == .mut and !pointerSourceIsMutable(resolved_src)) {
                    self.errorCode(expr.span, "E_DYN_MUT_BORROW", "a `*mut dyn Trait` requires a `*mut T` (mutable) source pointer");
                    return true;
                }
                if (!self.traitConforms(dyn.trait_name.text, type_name)) {
                    self.errorCode(expr.span, "E_TRAIT_NOT_SATISFIED", "no `impl Trait for Type` for this concrete type, so it cannot coerce to `*dyn Trait`");
                }
                return true;
            }
        }
        // Anything else is an attempt to fabricate a trait object. Only `unsafe` may.
        if (!ctx.in_unsafe) {
            self.errorCode(expr.span, "E_DYN_FORGE", "a `*dyn Trait` cannot be hand-assembled in safe code; build it with `&x` / `&mut x` (the checked coercion). `*dyn` is a compiler-protected type — fabrication requires `unsafe`");
        }
        return true;
    }

    fn traitConforms(self: *Checker, trait_name: []const u8, type_name: []const u8) bool {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ trait_name, type_name }) catch return false;
        return self.trait_conformances.contains(key);
    }

    fn checkPointerViewInitializer(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (nullablePointerWideningCtx(target, source, ctx)) return true;
        if (implicitPointerViewConversionCtx(target, source, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
            return true;
        }
        return false;
    }

    fn checkReturnValue(self: *Checker, ctx: Context, returned: TypeClass, expr: ast.Expr) void {
        const target_ty = ctx.return_ty orelse return;
        if (isUninitLiteral(expr)) {
            self.errorCode(expr.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const target = ctx.return_kind;
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, expr, ctx);
        const null_checked = self.checkNullPointerInitializer(target, expr);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const array_decay_checked = self.checkArrayDecayInitializer(target, returned, expr);
        const pointer_conversion_checked = self.checkPointerViewReturn(target_ty, expr, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, expr, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, expr, ctx);
        const fn_pointer_checked = self.checkFunctionPointerInitializer(target_ty, expr, ctx);
        const closure_checked = self.checkClosureInitializer(target_ty, expr, ctx);
        // The uniform `*T -> *dyn Trait` coercion (conformance + forge-safety), applied
        // at `return` exactly as at a `let` — so `return p;` (p: *Square) coerces and the
        // backend synthesizes the vtable here; a forged `{data,vtable}` is E_DYN_FORGE.
        const dyn_checked = self.checkDynCoercionInitializer(target_ty, expr, ctx);
        const address_class_checked = checkAddressClassConversion(self, expr.span, target, returned);
        const local_escape_checked = self.checkLocalAddressReturn(target, expr, ctx);
        const closure_local_escape = if (target == .closure) closureLocalAddressRoot(expr, ctx) else null;
        if (closure_local_escape) |span| {
            self.errorCode(span, "E_LOCAL_ADDRESS_ESCAPE", "cannot return a closure that captures local storage (the environment would dangle)");
        }
        // (bug #3) Returning an aggregate literal that embeds `&local` makes the borrow dangle
        // once the frame is gone — even though the return TYPE is a struct/array, not a pointer.
        if (aggregateLocalAddressRoot(expr, ctx)) |span| {
            self.errorCode(span, "E_LOCAL_ADDRESS_ESCAPE", "cannot return the address of local storage inside an aggregate (the borrow would dangle)");
        }
        const enum_checked = self.checkEnumValueCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type") else false;
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(target_ty, expr, ctx);
        const value_optional_checked = checkValueOptionalInitializer(target_ty, target, expr, returned, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !closure_checked and !dyn_checked and !address_class_checked and !local_escape_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !value_optional_checked and !canInitialize(target, returned)) {
            self.errorCode(expr.span, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        }
    }

    fn checkPointerViewReturn(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (nullablePointerWideningCtx(target, source, ctx)) return true;
        if (implicitPointerViewConversionCtx(target, source, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
            return true;
        }
        return false;
    }

    fn checkCVoidPointerConversion(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (implicitCVoidPointerConversionCtx(target, source, ctx)) {
            self.errorCode(expr.span, "E_C_VOID_CONVERSION", "c_void pointer conversions require an explicit FFI boundary operation");
            return true;
        }
        return false;
    }

    fn checkCallArgument(self: *Checker, target_ty: ast.TypeExpr, arg: ast.Expr, source: TypeClass, ctx: Context) void {
        if (isUninitLiteral(arg)) {
            self.errorCode(arg.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        // A function-pointer parameter: the argument is either a named function
        // (check its signature) or another function-pointer value (check the
        // signatures match structurally).
        if (classifyTypeCtx(target_ty, ctx) == .fn_pointer) {
            if (directCallName(arg)) |name| {
                if (ctx.functions != null and ctx.functions.?.contains(name)) {
                    if (!functionMatchesFnPointer(name, target_ty, ctx)) {
                        self.errorCode(arg.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function signature does not match the expected function-pointer type");
                    }
                    return;
                }
            }
            if (exprDeclaredType(arg, ctx)) |arg_ty| {
                if (classifyTypeCtx(arg_ty, ctx) == .fn_pointer) {
                    if (!sameTypeSyntaxCtx(arg_ty, target_ty, ctx)) {
                        self.errorCode(arg.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function-pointer signature does not match the expected type");
                    }
                    return;
                }
            }
        }
        const target = classifyTypeCtx(target_ty, ctx);
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, arg, ctx);
        const null_checked = self.checkNullPointerInitializer(target, arg);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, arg);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, arg, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, arg, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, arg, ctx);
        const closure_checked = self.checkClosureInitializer(target_ty, arg, ctx);
        // The uniform `*T -> *dyn Trait` coercion at a call argument (same as let/return).
        const dyn_checked = self.checkDynCoercionInitializer(target_ty, arg, ctx);
        const address_class_checked = checkAddressClassConversion(self, arg.span, target, source);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion") else false;
        // A struct value passed where a *different* named struct is expected is a
        // type error: distinct struct types (e.g. the move typestates CpuBuffer
        // vs DeviceBuffer) are not interchangeable just because they classify the
        // same. (Struct literals are target-typed and handled above.)
        if (self.checkNamedStructMismatch(target_ty, arg, ctx)) return;
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(target_ty, arg, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !closure_checked and !dyn_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target, source)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        }
    }

    fn checkClosureArgumentDoesNotEscape(self: *Checker, target_ty: ast.TypeExpr, arg: ast.Expr, ctx: Context, message: []const u8) void {
        if (classifyTypeCtx(target_ty, ctx) != .closure) return;
        if (closureLocalAddressRoot(arg, ctx)) |span| {
            self.errorCode(span, "E_LOCAL_ADDRESS_ESCAPE", message);
        }
    }

    // True (and reports) when `arg` is a value of one named struct passed where a
    // different named struct is expected.
    fn checkNamedStructMismatch(self: *Checker, target_ty: ast.TypeExpr, arg: ast.Expr, ctx: Context) bool {
        const tname = structNameOfType(target_ty, ctx) orelse return false;
        const arg_ty = exprDeclaredType(arg, ctx) orelse return false;
        const aname = structNameOfType(arg_ty, ctx) orelse return false;
        if (!std.mem.eql(u8, tname, aname)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "call argument struct type does not match the parameter type");
            return true;
        }
        return false;
    }

    fn checkTaggedUnionConstructorCompatibility(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const union_info = unionInfoForType(target_ty, ctx) orelse return false;
        const call = taggedUnionConstructorCall(expr) orelse return false;
        if (taggedUnionConstructorIsFunction(call.name.text, ctx)) return false;
        const case_payload = union_info.cases.get(call.name.text) orelse {
            self.errorCode(call.name.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
            return true;
        };
        if (case_payload) |payload_ty| {
            if (call.args.len != 1) {
                self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
                return true;
            }
            const source = self.checkExpr(call.args[0], ctx);
            self.checkCallArgument(payload_ty, call.args[0], source, ctx);
        } else if (call.args.len != 0) {
            self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
        }
        _ = code;
        _ = message;
        return true;
    }

    fn checkTaggedUnionConstructorRequiresUnionTarget(self: *Checker, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const call = taggedUnionConstructorCall(expr) orelse return false;
        if (!isKnownTaggedUnionConstructorName(call.name.text, ctx)) return false;
        if (taggedUnionConstructorIsFunction(call.name.text, ctx)) return false;
        self.errorCode(expr.span, code, message);
        return true;
    }

    // `Union.variant(...)` — a qualified, self-typed tagged-union constructor (the
    // collision-proof namespaced form alongside the bare, target-typed `variant(...)`).
    // The owner names the union, so no target type is needed. Validates the variant and
    // its payload and yields the value's TypeClass (`unknown`, like any union value).
    // Returns null when the callee owner is not a known union — then the call is something
    // else (an inherent/associated `impl` call, or an intrinsic) and resolves normally.
    fn checkQualifiedUnionConstructor(self: *Checker, expr: ast.Expr, node: anytype, ctx: Context) ?TypeClass {
        const q = ast_query.qualifiedMemberCallee(node.callee.*) orelse return null;
        const tagged = ctx.tagged_unions orelse return null;
        const info = tagged.get(q.owner) orelse return null;
        // The owner IS a tagged union: this is unambiguously a constructor attempt.
        const case_payload = info.cases.get(q.member.text) orelse {
            self.errorCode(q.member.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
            return .unknown;
        };
        if (case_payload) |payload_ty| {
            if (node.args.len != 1) {
                self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
                return .unknown;
            }
            const source = self.checkExpr(node.args[0], ctx);
            self.checkCallArgument(payload_ty, node.args[0], source, ctx);
        } else if (node.args.len != 0) {
            self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
        }
        return .unknown;
    }

    fn checkEnumValueCompatibility(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const target_enum = enumInfoForType(target_ty, ctx);
        if (enumLiteralName(expr)) |literal| {
            const enum_info = target_enum orelse {
                self.errorCode(expr.span, code, message);
                return true;
            };
            if (!enum_info.cases.contains(literal.text)) {
                self.errorCode(literal.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
            }
            return true;
        }
        if (exprResultType(expr, ctx)) |source_ty| {
            const source_is_enum = enumInfoForType(source_ty, ctx) != null;
            if (target_enum != null or source_is_enum) {
                if (sameTypeSyntaxCtx(target_ty, source_ty, ctx)) return true;
                self.errorCode(expr.span, code, message);
                return true;
            }
        }
        if (target_enum != null) {
            self.errorCode(expr.span, code, message);
            return true;
        }
        return false;
    }

    fn checkEnumCast(self: *Checker, span: diagnostics.Span, value: ast.Expr, source_class: TypeClass, target_ty: ast.TypeExpr, target_class: TypeClass, ctx: Context) void {
        if (enumInfoForType(target_ty, ctx)) |target_enum| {
            if (isIntegerLike(source_class)) {
                if (!target_enum.is_open) {
                    self.errorCode(span, "E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION", "integer-to-closed-enum conversion must use a checked conversion path");
                }
                return;
            }
        }

        // An enum -> integer `as` cast READS the representation ordinal out, exactly
        // like `.raw()`. Reading the tag can never mint an out-of-range enum value, so
        // it can never break the closed invariant and is permitted on BOTH open and
        // closed enums. (The REVERSE, int -> enum above, still requires an `open` enum.)
        _ = value;
        _ = target_class;
    }

    // An `as`-cast must not silently STRIP a safety class to a less-safe one — that
    // would launder a Secret/UserPtr value out of its discipline with no `unsafe`
    // gate, the same hole `reveal`/`declassify` plug for secrets. We gate only the
    // class-stripping direction; numeric/enum/pointer-to-pointer casts and the
    // legitimate `UserPtr <-> usize` round-trip (uaccess.mc) stay accepted.
    fn checkCastSafetyStrip(self: *Checker, span: diagnostics.Span, value: ast.Expr, source: TypeClass, target_ty: ast.TypeExpr, target: TypeClass, ctx: Context) void {
        // `Secret<T> as <non-secret>` declassifies a constant-time value; it is the
        // `reveal` operation in cast clothing and is forbidden outside `unsafe`.
        if (source == .secret and target != .secret and !ctx.in_unsafe) {
            self.errorCode(span, "E_SECRET_DECLASSIFY", "casting a Secret<T> to a non-secret type declassifies it; use reveal/declassify inside unsafe");
        }
        // `UserPtr<T> as <derefable pointer>` turns an unvalidated user-controlled
        // address into a kernel pointer the deref operator will trust. Only the
        // `UserPtr <-> usize` round-trip (which uaccess.mc relies on, and which can
        // never be dereferenced as-is) is allowed.
        if (source == .user_ptr and isDerefablePointerClass(target)) {
            self.errorCode(span, "E_USERPTR_CAST_DEREF", "casting a UserPtr<T> to a derefable kernel pointer bypasses uaccess validation; only UserPtr<->usize is permitted");
        }
        // General opacity gate: a value-level `as` cast whose SOURCE is an
        // `opaque struct` declassifies its private fields with no `unsafe` and no
        // accessor — `b as <inner>` extracts the hidden `.raw`/`.bits`/etc. directly.
        // This generalizes the Secret/UserPtr-specific gates above to the `opaque`
        // property itself, so it uniformly covers `Tainted`, `Cap`, `Rights`,
        // `Guarded`, and any user-defined opaque struct (e.g. closing the `Tainted`
        // checked-length bypass behind U3). Allowed escapes: an `unsafe` block (the
        // controlled declassification) and an identity cast to the SAME opaque type
        // (a no-op). Pointer-class sources are left to the bitcast pointee gate.
        self.checkOpaqueCastDeclassify(span, value, target_ty, ctx);
        // Address-class laundering gate. The built-in address classes
        // (PAddr/VAddr/DmaAddr/UserPtr/MmioPtr/PhysPtr) are kept distinct so the
        // checker can stop a physical address being dereferenced as virtual, a
        // device pointer being forged from an integer, etc. The IMPLICIT-conversion
        // sites already run `checkAddressClassConversion`, but an explicit `as`
        // (this handler) and `bitcast` bypassed it entirely — `n as MmioPtr<Dev>`
        // forged a device pointer with no `unsafe`, and `p as VAddr` crossed PAddr
        // into VAddr. Gate both directions of the laundering here (the same shape as
        // the opaque-declassify gate above), keyed on the address-class PROPERTY:
        //  - crossing between two DIFFERENT address classes, or
        //  - MINTING an address class from a non-address source (integer/plain ptr).
        // The audited boundary (the typed constructors/extractors in std/addr.mc,
        // std/dma.mc, std/virtqueue.mc, uaccess.mc, and the `unsafe` MMIO path)
        // wraps these in `unsafe`, the controlled escape. The EXTRACT direction
        // (address class `as usize`) is NOT gated here: it cannot deref or forge and
        // is the `pa_value`/`va_value` raw-access edge.
        self.checkAddressClassCast(span, source, target, ctx);
    }

    // `as`-cast laundering of the built-in address classes. Rejected unless inside
    // `unsafe`:
    //  - CROSS: source and target are both address classes but different
    //    (PAddr <-> VAddr <-> DmaAddr <-> MmioPtr <-> ...). Reuses the implicit
    //    mismatch diagnostics (E_DMA_ADDR_NOT_PADDR etc.) for parity with the
    //    implicit path, falling back to E_ADDRESS_CLASS_CAST.
    //  - MINT: target is an address class and source is NOT (an integer or plain
    //    pointer) — forging a device/physical/virtual address out of thin air.
    // EXTRACT (address class -> non-address, e.g. `a as usize`) is allowed: it is
    // the audited raw-access edge and can neither deref nor forge.
    fn checkAddressClassCast(self: *Checker, span: diagnostics.Span, source: TypeClass, target: TypeClass, ctx: Context) void {
        if (ctx.in_unsafe) return;
        if (isAddressClass(target) and isAddressClass(source)) {
            if (target == source) return; // identity cast extracts/forges nothing
            self.errorCode(span, addressClassMismatchDiagnostic(target, source), addressClassMismatchMessage(target, source));
            return;
        }
        if (isAddressClass(target) and !isAddressClass(source)) {
            self.errorCode(span, "E_ADDRESS_CLASS_CAST", "casting to a built-in address class forges it from a non-address value; use the typed constructor (pa/va/dma/mmio.map) or `unsafe`");
        }
    }

    fn checkOpaqueCastDeclassify(self: *Checker, span: diagnostics.Span, value: ast.Expr, target_ty: ast.TypeExpr, ctx: Context) void {
        if (ctx.in_unsafe) return;
        const source_ty = exprResultType(value, ctx) orelse return;
        const src_resolved = resolveAliasType(source_ty, ctx);
        // Only a VALUE-level opaque source is gated here; a pointer to an opaque is a
        // pointer reinterpret governed by the bitcast pointee gate (E_BITCAST_TYPE).
        const src_name = switch (src_resolved.kind) {
            .name => |n| n.text,
            .generic => |g| g.base.text,
            .qualified => |q| opacityStructNameOf(q.child.*),
            else => null,
        } orelse return;
        const structs = ctx.structs orelse return;
        const info = structs.get(src_name) orelse return;
        if (!info.is_opaque) return;
        // The opaque type's own associated functions read their fields by `.field`
        // access, not by `as`; but if some `impl` code does `self as inner`, treat it
        // as allowed (it already has full access to the private representation).
        if (self.opaqueAccessAllowed(src_name)) return;
        // Identity / no-op cast to the SAME opaque type extracts nothing.
        if (opacityStructNameOf(resolveAliasType(target_ty, ctx))) |tgt_name| {
            if (std.mem.eql(u8, tgt_name, src_name)) return;
        }
        self.errorCode(span, "E_OPAQUE_DECLASSIFY", "casting an `opaque struct` value to another type declassifies its private fields; use an accessor in its `impl`, or `unsafe`");
    }

    fn checkEnumRawCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []const ast.Expr, ctx: Context) ?TypeClass {
        const member = memberExpr(callee) orelse return null;
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const base_ty = exprResultType(member.base.*, ctx) orelse return null;
        const enum_info = enumInfoForType(base_ty, ctx) orelse return null;
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
        }
        // `.raw()` READS the enum's representation integer. Reading the ordinal out
        // never produces an out-of-range enum value, so it can never break the closed
        // invariant — it is safe on BOTH open and closed enums. (Only the REVERSE,
        // int -> enum, still requires an `open` enum; that lives in checkEnumCast.)
        // This lets a closed enum have BOTH an exhaustive `switch` AND `.raw()`.
        const repr = enum_info.repr orelse return .unknown;
        return classifyTypeCtx(repr, ctx);
    }

    fn checkRawManyOffsetCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const base_ty = rawManyOffsetReturnType(call, ctx) orelse return null;
        if (!ctx.in_unsafe) {
            self.errorCode(span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
        }
        if (call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
            return classifyTypeCtx(base_ty, ctx);
        }
        const index_class = self.checkExpr(call.args[0], ctx);
        if (!isIndexType(index_class)) {
            self.errorCode(call.args[0].span, "E_INDEX_NOT_USIZE", "array and slice indices must be checked usize");
        }
        return classifyTypeCtx(base_ty, ctx);
    }

    fn checkLocalAddressReturn(self: *Checker, target: TypeClass, expr: ast.Expr, ctx: Context) bool {
        if (!isNonNullPointerLike(target) and !isNullablePointerLike(target)) return false;
        if (localAddressRoot(expr, ctx) != null) {
            self.errorCode(expr.span, "E_LOCAL_ADDRESS_ESCAPE", "cannot return the address of local storage");
            return true;
        }
        return false;
    }

    fn checkTargetlessLiteralInitializer(self: *Checker, expr: ast.Expr) bool {
        if (integerLiteralSyntaxOverflow(expr)) {
            self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            return true;
        }

        switch (expr.kind) {
            .enum_literal => {
                self.errorCode(expr.span, "E_ENUM_LITERAL_REQUIRES_TARGET", "enum literal requires an explicit enum target type");
                return true;
            },
            .string_literal, .char_literal => {
                self.errorCode(expr.span, "E_LITERAL_REQUIRES_TARGET", "literal requires an explicit target type");
                return true;
            },
            .grouped => |inner| return self.checkTargetlessLiteralInitializer(inner.*),
            else => return false,
        }
    }

    // An integer literal used as a binary operand adapts to the other operand's type and is
    // emitted as a temporary of that width *before* the checked operation runs, so an
    // out-of-range literal is silently truncated by the C compiler, defeating the overflow
    // check (e.g. `x * 300` with `x: u8` stores `uint8_t = 300` -> 44, then checks `5 * 44`).
    // Range-check each literal operand against the other operand's checked-integer bounds, the
    // same way an initializer is checked by checkIntegerLiteralInitializer.
    fn checkBinaryLiteralOperandRange(self: *Checker, left_expr: ast.Expr, left: TypeClass, right_expr: ast.Expr, right: TypeClass) void {
        self.checkLiteralOperandAgainstClass(left_expr, right);
        self.checkLiteralOperandAgainstClass(right_expr, left);
    }

    fn checkLiteralOperandAgainstClass(self: *Checker, expr: ast.Expr, target: TypeClass) void {
        const bounds = checkedIntBounds(target) orelse return;
        const value = integerLiteralValue(expr) orelse {
            if (integerLiteralSyntaxOverflow(expr)) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return;
        };
        if (value.negative) {
            if (!bounds.signed or value.magnitude > bounds.min_abs) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return;
        }
        if (value.magnitude > bounds.max) {
            self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
        }
    }

    fn checkCheckedIntegerBinaryOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (!isCheckedInt(left) or !isCheckedInt(right)) return;
        if (left == right) return;
        if ((isCheckedSigned(left) and isCheckedUnsigned(right)) or (isCheckedUnsigned(left) and isCheckedSigned(right))) {
            self.errorCode(span, "E_SIGNED_UNSIGNED_MIX", "signed and unsigned integers do not implicitly mix");
            return;
        }
        self.errorCode(span, "E_NO_IMPLICIT_INTEGER_PROMOTION", "integer arithmetic requires matching types or an explicit conversion");
    }

    fn checkUnaryNegOperand(self: *Checker, span: diagnostics.Span, operand: TypeClass) void {
        if (isCheckedUnsigned(operand)) return;
        if (isDiagnosticNeutralOperand(operand) or isCheckedSigned(operand) or isArithmeticDomain(operand) or isFloatish(operand) or operand == .int_literal) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "unary '-' requires a signed integer, floating-point, or arithmetic-domain operand");
    }

    fn checkUnaryBitwiseOperand(self: *Checker, span: diagnostics.Span, operand: TypeClass) void {
        if (isAddressClass(operand)) return;
        if (isCheckedSigned(operand) or operand == .bool or isPointerLike(operand) or isForbiddenBitwisePolicy(operand)) return;
        if (isBitwiseOperand(operand)) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "bitwise operators require unsigned integer or wrapping operands");
    }

    fn checkFloatBinaryOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (!isFloatish(left) and !isFloatish(right)) return;
        if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return;
        if (isFloatish(left) and isFloatish(right)) {
            if (isFloat(left) and isFloat(right) and left != right) {
                self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "f32 and f64 do not implicitly convert; use an explicit conversion");
            }
            return;
        }
        self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "floating-point and non-floating-point operands do not implicitly mix");
    }

    fn checkArithmeticOperatorOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (isSingleObjectPointerLike(left) or isSingleObjectPointerLike(right)) return;
        if (!isArithmeticOperand(left) or !isArithmeticOperand(right)) {
            self.errorCode(span, "E_OPERATOR_OPERAND", "arithmetic operators require integer or arithmetic-domain operands");
        }
    }

    fn checkBitwiseOperatorOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (isCheckedSigned(left) or isCheckedSigned(right)) return;
        if (left == .bool or right == .bool) return;
        if (isPointerLike(left) or isPointerLike(right)) return;
        if (isForbiddenBitwisePolicy(left) or isForbiddenBitwisePolicy(right)) return;
        if (!isBitwiseOperand(left) or !isBitwiseOperand(right)) {
            self.errorCode(span, "E_OPERATOR_OPERAND", "bitwise operators require unsigned integer or wrapping operands");
        }
    }

    fn checkComparisonOperatorOperands(self: *Checker, span: diagnostics.Span, op: ast.BinaryOp, left: TypeClass, right: TypeClass, in_unsafe: bool) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (op == .eq or op == .ne) {
            if (equalityOperandsCompatible(left, right)) return;
            // Inside `unsafe`, a bool may be compared against a bare integer literal (`b != 0`,
            // `b != 1`) — bool models a 0/1 value. A C-compat escape hatch for generated code.
            if (in_unsafe and ((left == .bool and right == .int_literal) or (left == .int_literal and right == .bool))) return;
            self.errorCode(span, "E_OPERATOR_OPERAND", "equality operators require comparable operands");
            return;
        }
        if (isPointerLike(left) or isPointerLike(right) or left == .null_literal or right == .null_literal) return;
        if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return;
        if (isForbiddenOrderingDomain(left) or isForbiddenOrderingDomain(right)) {
            self.errorCode(span, "E_ORDERED_ARITH_DOMAIN_OPERAND", "ordered comparisons are not defined on wrap, serial, or counter arithmetic domains");
            return;
        }
        if (isOrderedComparisonOperand(left) and isOrderedComparisonOperand(right)) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "ordered comparisons require integer or arithmetic-domain operands");
    }

    fn checkPointerComparison(
        self: *Checker,
        span: diagnostics.Span,
        op: ast.BinaryOp,
        left_expr: ast.Expr,
        left: TypeClass,
        right_expr: ast.Expr,
        right: TypeClass,
        ctx: Context,
    ) void {
        if (isAddressClass(left) or isAddressClass(right)) return;

        const left_is_null = left == .null_literal;
        const right_is_null = right == .null_literal;

        // A value optional (`?T`, tagged repr) supports `opt == null` / `opt != null`,
        // testing the `present` tag. Only equality is defined (like the pointers).
        if (left == .nullable_value or right == .nullable_value) {
            if ((left == .nullable_value and right_is_null) or (right == .nullable_value and left_is_null)) {
                if (op != .eq and op != .ne) {
                    self.errorCode(span, "E_POINTER_ORDERING", "optional values support only equality comparisons against null");
                }
                return;
            }
            // Comparing a value optional against a non-null operand has no meaning
            // without narrowing it first; fall through to the mismatch diagnostic.
        }

        const left_ty = exprResultType(left_expr, ctx) orelse exprStorageType(left_expr, ctx);
        const right_ty = exprResultType(right_expr, ctx) orelse exprStorageType(right_expr, ctx);
        const left_is_view = if (left_ty) |ty| viewType(ty) != null else false;
        const right_is_view = if (right_ty) |ty| viewType(ty) != null else false;

        if (!left_is_null and !right_is_null and !left_is_view and !right_is_view) return;

        if (op != .eq and op != .ne) {
            self.errorCode(span, "E_POINTER_ORDERING", "pointer and view values support only equality comparisons");
            return;
        }

        if (left_is_null or right_is_null) {
            if ((left_is_null and right_is_view) or (right_is_null and left_is_view)) return;
            self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "null comparisons require a pointer or view operand");
            return;
        }

        if (!left_is_view or !right_is_view) {
            self.errorCode(span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer comparisons require compatible pointer or view operands");
            return;
        }

        if (!pointerComparableTypesCtx(left_ty.?, right_ty.?, ctx)) {
            self.errorCode(span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer comparisons require compatible pointer or view operands");
        }
    }

    fn checkKnownStructField(self: *Checker, span: diagnostics.Span, base: ast.Expr, field_name: []const u8, ctx: Context) void {
        const base_ty = exprResultType(base, ctx) orelse return;
        // Field of an `opaque struct` (including a generic one) is private outside its
        // associated functions: outside code may hold and pass the value but not read or
        // write its fields. Checked ahead of the plain-struct field-existence path below,
        // which `structTypeName` skips for a generic base.
        if (opacityStructName(base_ty)) |sname| {
            if (ctx.structs) |structs| {
                if (structs.get(sname)) |info| {
                    if (info.is_opaque and !self.opaqueAccessAllowed(sname)) {
                        self.errorCode(span, "E_PRIVATE_FIELD", "field of an `opaque struct` is private to its associated functions (`impl` block)");
                    }
                }
            }
        }
        const layout_name = memberLayoutTypeName(base_ty, ctx) orelse return;
        const layout_info = layoutFieldInfo(layout_name, ctx) orelse {
            self.errorCode(span, "E_UNKNOWN_STRUCT_FIELD", "member access requires a struct, packed-bits, or overlay-union value");
            return;
        };
        if (!layout_info.fields.contains(field_name)) {
            self.errorCode(span, "E_UNKNOWN_STRUCT_FIELD", "struct has no field with this name");
        }
    }

    // OPT (annex E) proof obligation for const-index bounds-check elision, mirroring the
    // MIR builder's `indexProvablyInBounds`: the index is a non-negative integer literal `k`,
    // the base names a fixed array of statically-known length `N`, and `k < N`. Conservative
    // (false when not provable), so it can never let an out-of-range access pass.
    fn indexProvablyInBounds(self: *Checker, base: ast.Expr, index: ast.Expr, ctx: Context) bool {
        _ = self;
        const k = constIndexLiteral(index) orelse return false;
        const base_ty = exprStorageType(base, ctx) orelse return false;
        const arr = switch (resolveAliasType(base_ty, ctx).kind) {
            .array => |node| node,
            else => return false,
        };
        const n = parseArrayLen(arr.len, ctx.const_fns, ctx.const_globals) orelse return false;
        return k < n;
    }

    // Const-slice analogue of `indexProvablyInBounds`: both ends are non-negative integer literals
    // into a fixed array of known length, with `start <= end <= len`. Conservative — false on any
    // non-literal bound or unknown base length, so an out-of-range slice is never proven safe.
    fn sliceProvablyInBounds(self: *Checker, base: ast.Expr, start: ast.Expr, end: ast.Expr, ctx: Context) bool {
        _ = self;
        const lo = constIndexLiteral(start) orelse return false;
        const hi = constIndexLiteral(end) orelse return false;
        if (lo > hi) return false; // start <= end
        const base_ty = exprStorageType(base, ctx) orelse return false;
        const arr = switch (resolveAliasType(base_ty, ctx).kind) {
            .array => |node| node,
            else => return false,
        };
        const n = parseArrayLen(arr.len, ctx.const_fns, ctx.const_globals) orelse return false;
        return hi <= n; // end <= len
    }

    // An `opaque struct`'s private fields may be named only by the struct's own associated
    // functions — those declared in `impl Name { … }`, which the parser mangles to the free
    // symbol `Name__member`. Membership is decided on the leading owner segment (the text
    // before the first `__`): an associated function `GenRef__resolve` and the struct
    // `GenRef` share owner `GenRef`. This also survives monomorphization, which appends a
    // `__<args>` specialization suffix to both — the specialized struct `GenRef__u32` and the
    // specialized accessor `GenRef__resolve__u32` still share the owner `GenRef`. The check
    // is purely on (mangled) names, so it also survives the loader's textual-inclusion
    // flattening of imported modules.
    fn opaqueAccessAllowed(self: *Checker, struct_name: []const u8) bool {
        const fname = self.current_fn_name orelse return false;
        return std.mem.eql(u8, ownerSegment(fname), ownerSegment(struct_name));
    }

    // The declared struct name a (possibly generic / pointer / qualified) type names, for
    // opacity lookups. Unlike `structTypeName`, this also resolves a generic application
    // `GenRef<T>` to its base name `GenRef`.
    fn opacityStructName(ty: ast.TypeExpr) ?[]const u8 {
        return switch (ty.kind) {
            .name => |n| n.text,
            .generic => |g| g.base.text,
            .qualified => |q| opacityStructName(q.child.*),
            .pointer => |p| opacityStructName(p.child.*),
            else => null,
        };
    }

    // The leading owner segment of a (possibly mangled) symbol: the text before the first
    // `__`. `impl`/`module` members and monomorphization specializations are all named
    // `Owner__…`, so two symbols belong to the same owner namespace iff their owner segments
    // are equal. A plain symbol with no `__` is its own owner.
    fn ownerSegment(name: []const u8) []const u8 {
        if (std.mem.indexOf(u8, name, "__")) |idx| return name[0..idx];
        return name;
    }

    // The origin file of a span (its byte offset) in the import-flattened source: the last
    // boundary whose start <= offset. Null when no boundaries are tracked (single-file check).
    fn originFile(self: *Checker, offset: usize) ?[]const u8 {
        const b = self.file_boundaries orelse return null;
        var origin: ?[]const u8 = null;
        for (b) |entry| {
            if (entry.start <= offset) origin = entry.path else break;
        }
        return origin;
    }

    // Opt-in module visibility (§30): reject a reference to a name that is private to a
    // strict module (declared without `pub`) from a DIFFERENT file. A use within the same
    // file, a `pub`/`export` item, or any name in a non-strict module is allowed (the name
    // is simply absent from `private_items`).
    fn checkImportVisibility(self: *Checker, name: []const u8, use_span: diagnostics.Span) void {
        const private = self.private_items orelse return;
        const def_file = private.get(name) orelse return;
        const use_file = self.originFile(use_span.offset) orelse return;
        if (!std.mem.eql(u8, use_file, def_file)) {
            self.errorCode(use_span, "E_PRIVATE_IMPORT", "this name is private to its module (declared without `pub` in a module that marks its public surface); only `pub`/`export` items are visible to importing files");
        }
    }

    // Orphan rule (closes the name-keyed opacity bypass and enforces trait coherence ownership).
    // MC's field-privacy for an `opaque struct` is decided purely on the symbol name
    // (`opaqueAccessAllowed`): a function named `Owner__member` may read `Owner`'s private
    // fields. Because the loader flattens all files into one unit with no module visibility,
    // ANY file could write a peer `impl <OpaqueType> { fn member(...) { ...&t.private... } }` —
    // the parser mangles it to the SAME `Owner__member` symbol and the name-match grants access,
    // defeating Cap/Rights/Tainted/Guarded/Guard opacity with no `unsafe`. This pass requires
    // that every inherent `impl` accessor of an `opaque struct` live in the SAME file as the
    // type's definition. Trait conformance impls are stricter per §32.2: `impl Trait for Type`
    // belongs in the file declaring `Type`, even when `Type` is non-opaque. Co-located
    // stdlib/kernel impls (the legitimate case) are accepted. No-op without file boundaries
    // (single-file/standalone check — nothing cross-file to forge).
    fn checkOrphanImpls(self: *Checker, module: ast.Module) void {
        if (self.file_boundaries == null) return;
        // Map each opaque struct's OWNER segment -> its defining file. Keying on the owner
        // segment (the text before the first `__`) makes this robust to monomorphization, which
        // renames a generic `Box` to a specialized `Box__u32` (owner still `Box`) and an
        // accessor `Box__steal` to `Box__steal__u32` (owner still `Box`). The owner is what the
        // name-keyed private-field gate (`opaqueAccessAllowed`/`ownerSegment`) matches on, so the
        // orphan rule must compare files on the SAME granularity.
        var opaque_files = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer opaque_files.deinit();
        var type_files = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer type_files.deinit();
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| {
                    const file = self.originFile(sd.name.span.offset) orelse continue;
                    self.recordTypeFile(&type_files, sd.name, file);
                    if (sd.is_opaque) {
                        const owner = ownerSegment(sd.name.text);
                        // First definition of an owner wins; later monomorphization
                        // specializations of the same opaque template share the owner and the
                        // same defining file, so ignore dups.
                        if (!opaque_files.contains(owner)) opaque_files.put(owner, file) catch {
                            self.oom = true;
                        };
                    }
                },
                .enum_decl => |ed| if (self.originFile(ed.name.span.offset)) |file| self.recordTypeFile(&type_files, ed.name, file),
                .union_decl => |ud| if (self.originFile(ud.name.span.offset)) |file| self.recordTypeFile(&type_files, ud.name, file),
                .packed_bits_decl => |pd| if (self.originFile(pd.name.span.offset)) |file| self.recordTypeFile(&type_files, pd.name, file),
                .overlay_union_decl => |od| if (self.originFile(od.name.span.offset)) |file| self.recordTypeFile(&type_files, od.name, file),
                .opaque_decl => |name| if (self.originFile(name.span.offset)) |file| self.recordTypeFile(&type_files, name, file),
                .type_alias => |alias| if (self.originFile(alias.name.span.offset)) |file| self.recordTypeFile(&type_files, alias.name, file),
                .fn_decl, .extern_fn, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
        // Any function whose owner segment names an opaque struct is one of its `impl` accessors
        // (the parser mangles `impl Owner { fn m }` to `Owner__m`). It must originate in the SAME
        // file as the type's definition. A plain free function with no `__` owns itself, skipped.
        if (opaque_files.count() > 0) {
            for (module.decls) |decl| {
                const fd = switch (decl.kind) {
                    .fn_decl, .extern_fn => |f| f,
                    else => continue,
                };
                const owner = ownerSegment(fd.name.text);
                if (std.mem.eql(u8, owner, fd.name.text)) continue; // not an impl/qualified member
                const type_file = opaque_files.get(owner) orelse continue; // owner isn't an opaque type
                const member_file = self.originFile(fd.name.span.offset) orelse continue;
                if (!std.mem.eql(u8, member_file, type_file)) {
                    self.errorCode(fd.name.span, "E_ORPHAN_IMPL", "impl of an opaque type must be in its defining module (file); a peer impl in another file cannot reach its private fields");
                }
            }
        }
        // Trait conformance impls attach methods to the target type's flat owner namespace, so
        // the conformance must be declared with that target type. Builtin/scalar targets have no
        // declaring file in this map and are left to the normal trait checks.
        if (type_files.count() > 0) {
            for (module.decls) |decl| {
                const it = switch (decl.kind) {
                    .impl_trait => |node| node,
                    else => continue,
                };
                const type_file = type_files.get(it.type_name.text) orelse continue;
                const impl_file = self.originFile(it.type_name.span.offset) orelse continue;
                if (!std.mem.eql(u8, impl_file, type_file)) {
                    self.errorCode(it.type_name.span, "E_ORPHAN_IMPL", "trait impl for a type must be in the file that declares the type");
                }
            }
        }
    }

    fn recordTypeFile(self: *Checker, files: *std.StringHashMap([]const u8), name: ast.Ident, file: []const u8) void {
        const owner = ownerSegment(name.text);
        if (!files.contains(owner)) files.put(owner, file) catch {
            self.oom = true;
        };
    }

    // Tier 1 trait checks (docs/traits-design.md §7): conformance and coherence. The
    // method bodies are ordinary `Type__m` fn_decls checked elsewhere; this pass works
    // on the `trait_decl` / `impl_trait` records the parser emits.
    fn checkTraits(self: *Checker, module: ast.Module) void {
        // Collect trait declarations by name.
        var traits = std.StringHashMap(ast.TraitDecl).init(self.reporter.allocator);
        defer traits.deinit();
        for (module.decls) |decl| {
            if (decl.kind == .trait_decl) {
                const t = decl.kind.trait_decl;
                if (traits.contains(t.name.text)) {
                    self.errorCode(t.name.span, "E_DUPLICATE_DECLARATION", "duplicate trait declaration");
                } else {
                    traits.put(t.name.text, t) catch {
                        self.oom = true;
                    };
                    self.known_traits.put(t.name.text, {}) catch {
                        self.oom = true;
                    };
                    if (self.trait_decls) |td| {
                        @constCast(td).put(t.name.text, t) catch {
                            self.oom = true;
                        };
                    }
                    // Object safety (traits-design §5): every method must take `self`
                    // by pointer (`*Self`/`*mut Self`) — not `move self`, not by value —
                    // and be non-generic (no `comptime` parameters). A trait that meets
                    // this is usable as `*dyn Trait`; otherwise forming one is rejected
                    // at the use site (E_TRAIT_NOT_OBJECT_SAFE), while Tier 1 still works.
                    if (traitIsObjectSafe(t)) {
                        self.object_safe_traits.put(t.name.text, {}) catch {
                            self.oom = true;
                        };
                    }
                }
            }
        }

        // Coherence: at most one `impl Trait for Type` per (Trait, Type) pair.
        var seen_pairs = std.StringHashMap(void).init(self.reporter.allocator);
        defer {
            var it = seen_pairs.keyIterator();
            while (it.next()) |k| self.reporter.allocator.free(k.*);
            seen_pairs.deinit();
        }

        for (module.decls) |decl| {
            if (decl.kind != .impl_trait) continue;
            const it = decl.kind.impl_trait;

            const pair_key = std.fmt.allocPrint(self.reporter.allocator, "{s}\x00{s}", .{ it.trait_name.text, it.type_name.text }) catch {
                self.oom = true;
                continue;
            };
            if (seen_pairs.contains(pair_key)) {
                self.errorCode(it.trait_name.span, "E_TRAIT_INCOHERENT", "duplicate `impl Trait for Type` (coherence: at most one impl per (Trait, Type) pair)");
                self.reporter.allocator.free(pair_key);
            } else {
                seen_pairs.put(pair_key, {}) catch {
                    self.reporter.allocator.free(pair_key);
                    self.oom = true;
                };
            }

            // Record the conformance so a `&x -> *dyn Trait` coercion can verify it.
            const conf_key = std.fmt.allocPrint(self.reporter.allocator, "{s}\x00{s}", .{ it.trait_name.text, it.type_name.text }) catch {
                self.oom = true;
                continue;
            };
            if (self.trait_conformances.contains(conf_key)) {
                self.reporter.allocator.free(conf_key);
            } else {
                self.trait_conformances.put(conf_key, {}) catch {
                    self.reporter.allocator.free(conf_key);
                    self.oom = true;
                };
            }

            // The trait being implemented must exist.
            const trait = traits.get(it.trait_name.text) orelse {
                self.errorCode(it.trait_name.span, "E_UNKNOWN_TRAIT", "unknown trait in impl");
                continue;
            };

            // Conformance: each trait method must be provided with a matching self-mode
            // and matching effect annotations; no extra methods are allowed.
            for (trait.methods) |tm| {
                const provided = findImplMethod(it.methods, tm.name.text) orelse {
                    self.errorCode(it.type_name.span, "E_TRAIT_MISSING_METHOD", "impl does not provide a trait method");
                    continue;
                };
                if (provided.self_mode != tm.self_mode) {
                    self.errorCode(provided.name.span, "E_TRAIT_SELF_MODE_MISMATCH", "impl method's self-mode does not match the trait signature");
                }
                // Full-signature equality: arity (param count), EACH non-self
                // parameter type, AND the return type must match the trait method.
                // Without this, a wrong-arity/wrong-type impl is accepted and a
                // `*dyn` vtable call (which casts the slot to the trait signature)
                // becomes a wild/UB indirect call with no sema error and no C
                // backstop (the cast suppresses the warning). The `self` parameter
                // is excluded — its form is already covered by the self-mode check
                // (trait writes `*Self`, impl writes `*ConcreteType`).
                else self.checkTraitSignatureEquality(provided, tm, it.type_name.text);
                // Effect contract: an impl method may not be `#[may_sleep]` unless the
                // trait signature also declares it (so the effect a caller sees through
                // the bound matches what conformance verified).
                if (hasMaySleep(provided.attrs) != hasMaySleep(tm.attrs)) {
                    self.errorCode(provided.name.span, "E_TRAIT_EFFECT_MISMATCH", "impl method's effect annotations (#[may_sleep]) do not match the trait signature");
                }
            }
            // Reject methods the trait does not declare.
            for (it.methods) |im| {
                if (findTraitMethod(trait.methods, im.name.text) == null) {
                    self.errorCode(im.name.span, "E_TRAIT_UNKNOWN_METHOD", "impl provides a method the trait does not declare");
                }
            }
        }
    }

    // Full-signature equality for `impl Trait for Type` conformance: the impl
    // method must match the trait method in arity, each non-self parameter type,
    // and the return type. (Self-mode and `#[may_sleep]` effects are checked by the
    // caller.) A `*dyn Trait` vtable slot is *cast* to the trait method signature at
    // dispatch, so a mismatch here would otherwise become a wild/UB indirect call.
    fn checkTraitSignatureEquality(self: *Checker, provided: ast.ImplTraitMethod, tm: ast.TraitMethodSig, self_name: []const u8) void {
        // Both param lists carry `self` as params[0] when a self parameter exists
        // (self_mode != .none); skip it (form covered by the self-mode check) and
        // compare the remaining parameters positionally.
        const self_skip: usize = if (tm.self_mode == .none) 0 else 1;
        const trait_rest = tm.params[@min(self_skip, tm.params.len)..];
        const impl_rest = provided.params[@min(self_skip, provided.params.len)..];

        if (trait_rest.len != impl_rest.len) {
            self.errorCode(provided.name.span, "E_TRAIT_SIGNATURE_MISMATCH", "impl method's parameter count does not match the trait signature");
            return;
        }
        for (trait_rest, impl_rest) |tp, ip| {
            // The trait may write `Self` in any non-receiver parameter position
            // (e.g. `other: *Self`); it must match the concrete impl type there.
            if (!sema_type.sameTraitTypeSyntax(tp.ty, ip.ty, self_name)) {
                self.errorCode(ip.name.span, "E_TRAIT_SIGNATURE_MISMATCH", "impl method's parameter type does not match the trait signature");
            }
        }

        // Return type: a missing `-> R` is the unit/void return; both sides must
        // agree (present-with-equal-type, or both absent).
        const tr = tm.return_type;
        const ir = provided.return_type;
        const ret_matches = if (tr) |t| (if (ir) |i| sema_type.sameTraitTypeSyntax(t, i, self_name) else false) else (ir == null);
        if (!ret_matches) {
            self.errorCode(provided.name.span, "E_TRAIT_SIGNATURE_MISMATCH", "impl method's return type does not match the trait signature");
        }
    }

    fn checkIfLetPattern(self: *Checker, pattern: ast.Pattern, value_class: TypeClass) void {
        switch (pattern.kind) {
            .bind => {
                if (!isNullableValue(value_class)) {
                    self.errorCode(pattern.span, "E_IF_LET_OPTIONAL_REQUIRED", "plain if let binding requires a nullable value");
                }
            },
            .tag_bind => |node| {
                if (!isResultNarrowingTag(node.tag.text)) {
                    if (value_class == .result) {
                        self.errorCode(node.tag.span, "E_IF_LET_RESULT_TAG", "if let result narrowing supports only ok(...) or err(...)");
                    } else {
                        self.errorCode(pattern.span, "E_IF_LET_NARROW_PATTERN", "if let supports only optional bindings and Result ok(...) or err(...) bindings");
                    }
                } else if (value_class != .result) {
                    self.errorCode(pattern.span, "E_IF_LET_RESULT_REQUIRED", "if let ok(...) or err(...) requires a Result value");
                }
            },
            .wildcard, .tag, .literal => {
                self.errorCode(pattern.span, "E_IF_LET_NARROW_PATTERN", "if let supports only optional bindings and Result ok(...) or err(...) bindings");
            },
        }
    }

    fn addIfLetBinding(self: *Checker, pattern: ast.Pattern, value: ast.Expr, value_class: TypeClass, scope: *Scope, ctx: Context) void {
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        switch (pattern.kind) {
            .bind => |ident| {
                if (!isNullableValue(value_class)) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| nullableInnerType(ty) else null;
                // A value optional narrows to its payload type: recover the payload's
                // specific class from the binding's TypeExpr (tryResultType left it
                // unknown). The pointer nullables already carry a precise class.
                const narrowed_class = if (value_class == .nullable_value)
                    (if (narrowed_ty) |ty| classifyTypeCtx(ty, ctx) else .unknown)
                else
                    tryResultType(value_class);
                self.addLocalBinding(scope, ident, .{
                    .class = narrowed_class,
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                });
            },
            .tag_bind => |node| {
                if (!isResultNarrowingTag(node.tag.text) or value_class != .result) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| resultPayloadType(ty, node.tag.text) else null;
                self.addLocalBinding(scope, node.binding, .{
                    .class = if (narrowed_ty) |ty| classifyTypeCtx(ty, ctx) else .unknown,
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                });
            },
            .wildcard, .tag, .literal => {},
        }
    }

    fn addForBinding(self: *Checker, loop: ast.Loop, ctx: Context, scope: *Scope) void {
        const label = loop.label orelse return;
        const iterable = loop.iterable orelse return;
        const element_ty = if (exprResultType(iterable, ctx)) |ty| iterableElementType(ty) else null;
        self.addLocalBinding(scope, label, .{
            .class = if (element_ty) |ty| classifyTypeCtx(ty, ctx) else .unknown,
            .mutable = false,
            .ty = element_ty,
            .origin = .local,
        });
    }

    fn checkForBody(self: *Checker, loop: ast.Loop, ctx: Context, scope: *Scope) void {
        const label = loop.label orelse {
            self.checkBlockScoped(loop.body, ctx);
            return;
        };
        // The element binding + the body's locals form one lexical scope (G20): mark before
        // binding the element so both are popped on exit and a sibling loop may reuse the name.
        const mark = self.enterScope();
        const previous = scope.get(label.text);
        self.addForBinding(loop, ctx, scope);
        self.checkBlock(loop.body, ctx);
        self.leaveScope(mark);
        if (previous) |entry| {
            scope.put(label.text, entry) catch {
                self.oom = true;
            };
        } else {
            _ = scope.remove(label.text);
        }
    }

    fn checkSwitch(self: *Checker, node: ast.Switch, ctx: Context) void {
        const subject_class = self.checkExpr(node.subject, ctx);
        // Constant-time: a secret value must never steer control flow. Both `if`
        // (desugared to a bool `switch`) and `switch` route through here, so this
        // one check forbids `if (secret …)` and `switch (secret) { … }` alike —
        // including a secret *bool* produced by `secret == k`. Reveal it first.
        if (subject_class == .secret) {
            self.errorCode(node.subject.span, "E_SECRET_BRANCH", "secret value cannot drive a branch or switch; this would leak it through control-flow timing — use declassify/reveal (unsafe) or a constant-time select");
        }
        const subject_ty = exprResultType(node.subject, ctx);
        const subject_enum = if (subject_ty) |ty| enumInfoForType(ty, ctx) else null;
        const subject_union = if (subject_ty) |ty| unionInfoForType(ty, ctx) else null;
        var enum_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer enum_cases_seen.deinit();
        var union_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer union_cases_seen.deinit();
        var result_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer result_cases_seen.deinit();
        var bool_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer bool_cases_seen.deinit();
        var literal_cases_seen = std.AutoHashMap(EnumValueKey, void).init(self.reporter.allocator);
        defer literal_cases_seen.deinit();
        self.checkSwitchWildcardOrdering(node);
        for (node.arms) |arm| {
            // A secret subject is already rejected with E_SECRET_BRANCH above;
            // skip per-pattern type checks so the dispositive error isn't buried
            // under spurious pattern/subject mismatches (the bool patterns of a
            // desugared `if secret` would otherwise mismatch the secret class).
            if (subject_class != .secret) self.checkSwitchArmPatterns(arm.patterns, subject_class, subject_ty, ctx);
            if (subject_enum) |enum_info| {
                self.checkDuplicateSwitchEnumCases(arm.patterns, enum_info, &enum_cases_seen);
            }
            if (subject_union) |union_info| {
                self.checkDuplicateSwitchUnionCases(arm.patterns, union_info, &union_cases_seen);
            }
            if (subject_class == .result) {
                self.checkDuplicateSwitchResultCases(arm.patterns, &result_cases_seen);
            }
            if (subject_class == .bool) {
                self.checkDuplicateSwitchBoolCases(arm.patterns, &bool_cases_seen);
            }
            if (isIntegerLike(subject_class)) {
                self.checkDuplicateSwitchIntegerLiteralCases(arm.patterns, &literal_cases_seen);
            }
            var arm_scope = Scope.init(self.reporter.allocator);
            defer arm_scope.deinit();
            var arm_ctx = ctx;
            // The arm's pattern binding + its body form one lexical scope (G20): mark before
            // binding so both are popped on exit and a sibling arm may reuse the name.
            const arm_mark = self.enterScope();
            if (ctx.scope) |scope| {
                copyScope(scope, &arm_scope) catch {
                    self.oom = true;
                };
                self.addSwitchArmBindings(arm.patterns, node.subject, subject_class, &arm_scope, ctx, arm.dup_local_if_binds);
                arm_ctx.scope = &arm_scope;
            }
            switch (arm.body) {
                .block => |block| self.checkBlock(block, arm_ctx),
                .expr => |expr| _ = self.checkExpr(expr, arm_ctx),
            }
            self.leaveScope(arm_mark);
        }
        if (subject_ty) |ty| {
            if (closedEnumInfoForType(ty, ctx)) |enum_info| {
                if (!switchCoversAllEnumCases(node, enum_info)) {
                    self.errorCode(node.subject.span, "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE", "switch over closed enum must cover every case or use '_'");
                }
            }
        }
    }

    fn checkDuplicateSwitchEnumCases(self: *Checker, patterns: []const ast.Pattern, enum_info: EnumInfo, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                else => continue,
            };
            if (!enum_info.cases.contains(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchUnionCases(self: *Checker, patterns: []const ast.Pattern, union_info: UnionInfo, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                .tag_bind => |node| node.tag,
                else => continue,
            };
            if (!union_info.cases.contains(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchResultCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                .tag_bind => |node| node.tag,
                else => continue,
            };
            if (!isResultNarrowingTag(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchBoolCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const value = switchBoolLiteralValue(pattern) orelse continue;
            const key = if (value) "true" else "false";
            if (seen.contains(key)) {
                self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(key, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchIntegerLiteralCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.AutoHashMap(EnumValueKey, void)) void {
        for (patterns) |pattern| {
            const key = switch (pattern.kind) {
                .literal => |expr| if (integerLiteralValue(expr)) |value| enumValueKey(value) else continue,
                else => continue,
            };
            if (seen.contains(key)) {
                self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(key, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkSwitchWildcardOrdering(self: *Checker, node: ast.Switch) void {
        var wildcard_seen = false;
        for (node.arms) |arm| {
            var arm_has_wildcard = false;
            for (arm.patterns) |pattern| {
                if (wildcard_seen) {
                    self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                    continue;
                }
                if (pattern.kind == .wildcard) {
                    if (arm_has_wildcard) {
                        self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                    }
                    arm_has_wildcard = true;
                } else if (arm_has_wildcard) {
                    self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                }
            }
            if (arm_has_wildcard) wildcard_seen = true;
        }
    }

    fn checkSwitchArmPatterns(self: *Checker, patterns: []const ast.Pattern, subject_class: TypeClass, subject_ty: ?ast.TypeExpr, ctx: Context) void {
        var binding_pattern_count: usize = 0;
        const subject_enum = if (subject_ty) |ty| enumInfoForType(ty, ctx) else null;
        const subject_union = if (subject_ty) |ty| unionInfoForType(ty, ctx) else null;
        // If the subject type is already unknown, the real diagnostic is upstream
        // (for example, a failed generic instantiation). Reporting pattern/subject
        // mismatches here only buries that root cause under cascaded noise.
        if (subject_class == .unknown and subject_ty == null) return;
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| {
                    if (subject_enum) |enum_info| {
                        if (!enum_info.cases.contains(tag.text)) {
                            self.errorCode(tag.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
                        }
                    } else if (subject_union) |union_info| {
                        if (!union_info.cases.contains(tag.text)) {
                            self.errorCode(tag.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
                        }
                    } else if (subject_class == .result and !isResultNarrowingTag(tag.text)) {
                        self.errorCode(tag.span, "E_SWITCH_RESULT_TAG", "switch result patterns support only ok or err tags");
                    } else if (subject_class != .result and isResultNarrowingTag(tag.text)) {
                        self.errorCode(tag.span, "E_SWITCH_RESULT_REQUIRED", "switch ok or err patterns require a Result value");
                    }
                },
                .tag_bind => |node| {
                    binding_pattern_count += 1;
                    if (subject_union) |union_info| {
                        if (!union_info.cases.contains(node.tag.text)) {
                            self.errorCode(node.tag.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
                        } else if (unionCasePayloadType(union_info, node.tag.text) == null) {
                            self.errorCode(pattern.span, "E_UNION_CASE_HAS_NO_PAYLOAD", "union case binding requires a payload case");
                        }
                    } else if (!isResultNarrowingTag(node.tag.text)) {
                        self.errorCode(node.tag.span, "E_SWITCH_RESULT_TAG", "switch result binding supports only ok(...) or err(...)");
                    } else if (subject_class != .result) {
                        self.errorCode(pattern.span, "E_SWITCH_RESULT_REQUIRED", "switch ok(...) or err(...) binding requires a Result value");
                    }
                },
                .bind => {
                    binding_pattern_count += 1;
                },
                .literal => |expr| self.checkSwitchLiteralPattern(pattern, expr, subject_class),
                .wildcard => {},
            }
        }
        if (patterns.len > 1 and binding_pattern_count > 0) {
            self.errorCode(patterns[0].span, "E_SWITCH_MULTI_BINDING_ARM", "switch arms with multiple patterns cannot introduce bindings");
        }
    }

    fn checkSwitchLiteralPattern(self: *Checker, pattern: ast.Pattern, expr: ast.Expr, subject_class: TypeClass) void {
        if (subject_class == .unknown) return;
        if (subject_class == .bool) {
            if (switchBoolLiteralValue(pattern) == null) {
                self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
            }
            return;
        }
        if (isIntegerLike(subject_class)) {
            const literal = integerLiteralValue(expr) orelse {
                self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
                return;
            };
            if (checkedIntBounds(subject_class)) |bounds| {
                if (!enumValueFits(enumValueKey(literal), bounds)) {
                    self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
                }
            }
            return;
        }
        self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
    }

    fn addSwitchArmBindings(self: *Checker, patterns: []const ast.Pattern, subject: ast.Expr, subject_class: TypeClass, scope: *Scope, ctx: Context, dup_local_if_binds: bool) void {
        if (patterns.len != 1) return;
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        const subject_ty = exprResultType(subject, binding_ctx) orelse return;
        const subject_union = unionInfoForType(subject_ty, binding_ctx);
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag_bind => |node| {
                    const narrowed_ty = if (subject_class == .result and isResultNarrowingTag(node.tag.text))
                        resultPayloadType(subject_ty, node.tag.text)
                    else if (subject_union) |union_info|
                        unionCasePayloadType(union_info, node.tag.text)
                    else
                        null;
                    const ty = narrowed_ty orelse continue;
                    self.addLocalBinding(scope, node.binding, .{
                        .class = classifyTypeCtx(ty, ctx),
                        .mutable = false,
                        .ty = ty,
                        .origin = .local,
                    });
                },
                .bind => |ident| {
                    if (!isNullableValue(subject_class)) continue;
                    const narrowed_ty = nullableInnerType(subject_ty) orelse continue;
                    // The async lowering flagged this arm: its bound name shadows an enclosing local it
                    // lifted to a future-struct field, hidden from this scope. Now that the resolved
                    // subject type confirms the bare `.bind` DOES bind (nullable), the source-level
                    // shadow is a real E_DUPLICATE_LOCAL, which a non-async fn reports directly. (For a
                    // non-nullable subject we never reach here, so the valid catch-all form is accepted.)
                    if (dup_local_if_binds) {
                        self.errorCode(ident.span, "E_DUPLICATE_LOCAL", "local bindings must have unique names in the current scope");
                        continue;
                    }
                    self.addLocalBinding(scope, ident, .{
                        .class = classifyTypeCtx(narrowed_ty, ctx),
                        .mutable = false,
                        .ty = narrowed_ty,
                        .origin = .local,
                    });
                },
                .wildcard, .tag, .literal => {},
            }
        }
    }
};

fn copyScope(source: *const Scope, dest: *Scope) !void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try dest.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

// An ordinary kernel pointer the `*` operator will dereference into kernel memory.
// Excludes the opaque address classes (`UserPtr`/`PAddr`/`VAddr`/…), which cannot be
// dereferenced as-is — so casting INTO one of these is not a deref-strip.
// True iff `ty` is a pointer whose POINTEE is a privacy-protected class: an
// `opaque struct` (Tainted/Guarded/…), `Secret<T>`, or `UserPtr<T>`. Used to forbid
// a pointer-`bitcast` from crossing into/out of such a class (which would expose the
// pointee's private bytes through a same-shape plain mirror). Non-pointers and
// pointers to ordinary types return false.
fn pointeeIsOpaquePrivacy(ty: ast.TypeExpr, ctx: Context) bool {
    const child = switch (resolveAliasType(ty, ctx).kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .nullable => |node| return pointeeIsOpaquePrivacy(node.*, ctx),
        else => return false,
    };
    const resolved = resolveAliasType(child, ctx);
    switch (classifyType(resolved)) {
        // `Secret<T>` / `UserPtr<T>` pointees are privacy classes in their own right.
        .secret, .user_ptr => return true,
        else => {},
    }
    // An `opaque struct` pointee — fields are private to its `impl`; reinterpreting a
    // pointer to it as a same-shape plain struct would read those private fields.
    // Resolve a generic application (`Tainted<T>`) to its declared base name.
    const sname = switch (resolved.kind) {
        .name => |n| n.text,
        .generic => |g| g.base.text,
        .qualified => |q| opacityStructNameOf(q.child.*),
        else => null,
    };
    if (sname) |name| {
        if (ctx.structs) |structs| {
            if (structs.get(name)) |info| return info.is_opaque;
        }
    }
    return false;
}

fn opacityStructNameOf(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |n| n.text,
        .generic => |g| g.base.text,
        .qualified => |q| opacityStructNameOf(q.child.*),
        .pointer => |p| opacityStructNameOf(p.child.*),
        else => null,
    };
}

// Definite-init (S0.1) tracks typed `uninit` locals whose whole value can later be
// read. Scalars and aggregates are reported on any value read before whole assignment.
// Aggregates are tracked at the root; partial member/index writes and address-taking
// are not enough proof that the whole aggregate is initialized.
fn diPendingKindForType(ty: ast.TypeExpr, ctx: Context) ?Checker.DefInitPendingKind {
    const resolved = resolveAliasType(ty, ctx);
    if (maybeUninitPayloadType(resolved) != null) return null;
    if (diIsScalarType(resolved, ctx)) return .scalar;
    if (diIsAggregateType(resolved, ctx)) return .aggregate;
    return null;
}

fn diPendingAggregateRoot(expr: ast.Expr, state: *const Checker.DefInitState) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| blk: {
            const fact = state.get(id.text) orelse break :blk null;
            break :blk if (fact.kind == .pending_aggregate) id.text else null;
        },
        .grouped => |inner| diPendingAggregateRoot(inner.*, state),
        else => null,
    };
}

fn diFixedArrayLenForRoot(root: []const u8, state: *const Checker.DefInitState) ?usize {
    const fact = state.get(root) orelse return null;
    return fact.array_len;
}

fn diPureIndexExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident, .int_literal, .char_literal => true,
        .grouped => |inner| diPureIndexExpr(inner.*),
        .cast => |node| diPureIndexExpr(node.value.*),
        .unary => |node| diPureIndexExpr(node.expr.*),
        .binary => |node| diPureIndexExpr(node.left.*) and diPureIndexExpr(node.right.*),
        else => false,
    };
}

fn diExprMayMutateThroughCall(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => true,
        .grouped => |inner| diExprMayMutateThroughCall(inner.*),
        .address_of => |inner| diExprMayMutateThroughCall(inner.*),
        .deref => |inner| diExprMayMutateThroughCall(inner.*),
        .member => |node| diExprMayMutateThroughCall(node.base.*),
        .index => |node| diExprMayMutateThroughCall(node.base.*) or diExprMayMutateThroughCall(node.index.*),
        .slice => |node| diExprMayMutateThroughCall(node.base.*) or diExprMayMutateThroughCall(node.start.*) or diExprMayMutateThroughCall(node.end.*),
        .cast => |node| diExprMayMutateThroughCall(node.value.*),
        .unary => |node| diExprMayMutateThroughCall(node.expr.*),
        .binary => |node| diExprMayMutateThroughCall(node.left.*) or diExprMayMutateThroughCall(node.right.*),
        .array_literal => |items| {
            for (items) |item| if (diExprMayMutateThroughCall(item)) return true;
            return false;
        },
        .struct_literal => |fields| {
            for (fields) |field| if (diExprMayMutateThroughCall(field.value)) return true;
            return false;
        },
        .try_expr => |node| diExprMayMutateThroughCall(node.operand.*) or if (node.mapped) |m| diExprMayMutateThroughCall(m.*) else false,
        .block => |block| {
            for (block.items) |stmt| if (diStmtMayMutateThroughCall(stmt)) return true;
            return false;
        },
        else => false,
    };
}

fn diStmtMayMutateThroughCall(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .var_decl, .let_decl => |decl| if (decl.init) |init| diExprMayMutateThroughCall(init) else false,
        .assignment => |node| diExprMayMutateThroughCall(node.target) or diExprMayMutateThroughCall(node.value),
        .expr, .assert, .@"defer" => |expr| diExprMayMutateThroughCall(expr),
        .@"return" => |maybe| if (maybe) |expr| diExprMayMutateThroughCall(expr) else false,
        .block, .unsafe_block, .comptime_block => |block| {
            for (block.items) |item| if (diStmtMayMutateThroughCall(item)) return true;
            return false;
        },
        .contract_block => |node| {
            for (node.block.items) |item| if (diStmtMayMutateThroughCall(item)) return true;
            return false;
        },
        .if_let => |node| blk: {
            if (diExprMayMutateThroughCall(node.value)) break :blk true;
            for (node.then_block.items) |item| if (diStmtMayMutateThroughCall(item)) break :blk true;
            if (node.else_block) |block| for (block.items) |item| if (diStmtMayMutateThroughCall(item)) break :blk true;
            break :blk false;
        },
        .loop => |node| blk: {
            if (node.iterable) |iter| if (diExprMayMutateThroughCall(iter)) break :blk true;
            for (node.body.items) |item| if (diStmtMayMutateThroughCall(item)) break :blk true;
            break :blk false;
        },
        .@"switch" => |node| blk: {
            if (diExprMayMutateThroughCall(node.subject)) break :blk true;
            for (node.arms) |arm| switch (arm.body) {
                .expr => |expr| if (diExprMayMutateThroughCall(expr)) break :blk true,
                .block => |block| for (block.items) |item| if (diStmtMayMutateThroughCall(item)) break :blk true,
            };
            break :blk false;
        },
        .@"break", .@"continue", .asm_stmt => false,
    };
}

fn diElementFactRoot(key: []const u8) ?[]const u8 {
    const sep = std.mem.indexOfScalar(u8, key, 0x1f) orelse return null;
    return key[0..sep];
}

fn diElementFactSurvives(key: []const u8, other: *const Checker.DefInitState) bool {
    if (other.get(key)) |fact| return fact.kind == .initialized_element;
    const root = diElementFactRoot(key) orelse return false;
    const root_fact = other.get(root) orelse return true;
    return root_fact.kind != .pending_aggregate;
}

fn diIsScalarType(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (classifyTypeCtx(ty, ctx)) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_u128, .checked_usize, .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_i128, .checked_isize, .wrap, .sat, .serial, .counter, .pointer, .raw_many_pointer, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer, .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr, .secret, .fn_pointer, .bool, .f32, .f64, .duration, .order => true,
        else => false,
    };
}

fn diIsAggregateType(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (classifyTypeCtx(ty, ctx)) {
        .array, .slice, .nullable_dyn_trait, .nullable_value, .result, .atomic, .dma_buf => true,
        else => diNamedAggregateTypeIsKnown(ty, ctx),
    };
}

fn diNamedAggregateTypeIsKnown(ty: ast.TypeExpr, ctx: Context) bool {
    const resolved = resolveAliasType(ty, ctx);
    const name = switch (resolved.kind) {
        .name => |n| n.text,
        .generic => |g| g.base.text,
        .qualified => |q| return diNamedAggregateTypeIsKnown(q.child.*, ctx),
        else => return false,
    };
    if (ctx.type_params) |type_params| {
        if (type_params.contains(name)) return false;
    }
    if (ctx.structs) |structs| if (structs.contains(name)) return true;
    if (ctx.packed_bits) |packed_bits| if (packed_bits.contains(name)) return true;
    if (ctx.tagged_unions) |tagged_unions| if (tagged_unions.contains(name)) return true;
    return false;
}

fn diStorageMethodBase(callee: ast.Expr) ?ast.Expr {
    const member = memberExpr(callee) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "store")) return null;
    return member.base.*;
}

fn atomicPayloadTypeForValue(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return atomicPayloadType(resolveAliasType(ty, ctx));
}

fn maybeUninitPayloadTypeForValue(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return maybeUninitPayloadType(resolveAliasType(ty, ctx));
}

fn dmaBufInfoForValue(expr: ast.Expr, ctx: Context) ?DmaBufInfo {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return dmaBufInfo(resolveAliasType(ty, ctx));
}

fn wrapValueInnerType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .generic => |node| if (std.mem.eql(u8, node.base.text, "wrap") and node.args.len == 1) node.args[0] else null,
        else => null,
    };
}

// `.residue()` exposes the raw modulo representative of a wrap<T> value (section 5.2).
fn residueCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const member = memberExpr(callee) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "residue")) return null;
    const inner = wrapValueInnerType(member.base.*, ctx) orelse return null;
    return classifyTypeCtx(inner, ctx);
}

fn atomicCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const member = memberExpr(callee) orelse return null;
    if (std.mem.eql(u8, member.name.text, "load") or std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
        return atomicPayloadTypeForValue(member.base.*, ctx);
    }
    return null;
}

fn maybeUninitCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const member = memberExpr(callee) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "assume_init")) return null;
    return maybeUninitPayloadTypeForValue(member.base.*, ctx);
}

fn atomicCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const ty = atomicCallReturnType(callee, ctx) orelse return null;
    return classifyTypeCtx(ty, ctx);
}

fn bitcastCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isBitcastCallName(call.callee.*) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

// `raw.load<T>(addr)` reads a `T` from a raw address (the dual of `raw.store`).
fn isRawLoadCall(callee: ast.Expr) bool {
    const member = memberExpr(callee) orelse return false;
    return isIdentNamed(member.base.*, "raw") and std.mem.eql(u8, member.name.text, "load");
}

fn rawLoadCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isRawLoadCall(call.callee.*) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

// `va.arg<T>(&ap)` yields a `T` (the next C-ABI variadic slot); `va.start()` yields a
// `va_list`; `va.end(&ap)` yields void. These give the call its result type.
fn vaCallName(callee: ast.Expr) ?[]const u8 {
    const member = memberExpr(callee) orelse return null;
    return if (isIdentNamed(member.base.*, "va")) member.name.text else null;
}

fn vaCallReturnType(call: anytype) ?ast.TypeExpr {
    const name = vaCallName(call.callee.*) orelse return null;
    if (std.mem.eql(u8, name, "arg")) {
        if (call.type_args.len != 1) return null;
        return call.type_args[0];
    }
    if (std.mem.eql(u8, name, "start")) {
        return ast.TypeExpr{ .span = call.callee.span, .kind = .{ .name = .{ .text = "va_list", .span = call.callee.span } } };
    }
    return null; // va.end -> void (no type)
}

// `raw.ptr<T>(addr)` mints a `*mut T` from a raw address — the typed-pointer companion
// of raw.load/store (used to view an allocation as a typed object: Arc blocks, etc.).
fn isRawPtrCall(callee: ast.Expr) bool {
    const member = memberExpr(callee) orelse return false;
    return isIdentNamed(member.base.*, "raw") and std.mem.eql(u8, member.name.text, "ptr");
}

fn tryPayloadType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    switch (expr.kind) {
        .call => |node| if (mmioMapCallPayloadType(node)) |ty| return ty,
        .grouped => |inner| return tryPayloadType(inner.*, ctx),
        else => {},
    }
    const ty = exprResultType(expr, ctx) orelse return null;
    return nullableInnerType(ty) orelse resultPayloadType(ty, "ok");
}

fn iterableElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| iterableElementType(node.child.*),
        else => null,
    };
}

fn storageElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| storageElementType(node.child.*),
        else => null,
    };
}

// The nominal pointee type name of a `*T` source that may coerce to `*dyn Trait`:
// a single (`.pointer`) pointer to a named nominal type. A `[*]` raw-many pointer, a
// slice, or a non-nominal pointee is NOT a `*T` trait-object source. The vtable is
// synthesized from this static pointee type T (`__vt_T_Trait`).
fn dynSourcePointeeTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .pointer => |node| switch (node.child.*.kind) {
            .name => |name| name.text,
            .qualified => |q| switch (q.child.*.kind) {
                .name => |name| name.text,
                else => null,
            },
            else => null,
        },
        .qualified => |node| dynSourcePointeeTypeName(node.child.*),
        else => null,
    };
}

// True when a `*T` source pointer permits a mutable borrow (`*mut T`): a `*mut dyn
// Trait` target requires it. A plain `*T` (shared) cannot form a `*mut dyn`.
fn pointerSourceIsMutable(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer => |node| node.mutability == .mut,
        .qualified => |node| pointerSourceIsMutable(node.child.*),
        else => false,
    };
}

fn structTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .generic => |node| node.base.text,
        .qualified => |node| structTypeName(node.child.*),
        // Member access auto-dereferences a pointer (`p.field` == `(*p).field`), so
        // the field-type lookup must see through a pointer to the struct too.
        .pointer => |node| structTypeName(node.child.*),
        else => null,
    };
}

fn memberLayoutTypeName(ty: ast.TypeExpr, ctx: Context) ?[]const u8 {
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .name => |name| name.text,
        .generic => |node| node.base.text,
        .qualified => |node| memberLayoutTypeName(node.child.*, ctx),
        .pointer => |node| memberLayoutTypeName(node.child.*, ctx),
        else => null,
    };
}

fn enumTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| enumTypeName(node.child.*),
        else => null,
    };
}

fn enumInfoForType(ty: ast.TypeExpr, ctx: Context) ?EnumInfo {
    const name = enumTypeName(ty) orelse return null;
    const enums = ctx.enums orelse return null;
    return enums.get(name);
}

// A variant-path literal `Enum.variant` used as a VALUE (not a `.field` access on a
// runtime enum value): the base is a bare identifier that names a known enum type and
// the member is one of its cases. Yields the enum's own type so `Enum.variant` has the
// enum type — e.g. `Enum.variant.raw()` reads the case's ordinal constant. Returns null
// when the base is a value binding (a local/global shadowing the type name), so a real
// `.field` access is unaffected.
fn enumVariantPathType(member: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ident = switch (member.base.*.kind) {
        .ident => |id| id,
        else => return null,
    };
    if (ctx.scope) |scope| {
        if (scope.get(base_ident.text) != null) return null;
    }
    if (globalType(base_ident.text, ctx) != null) return null;
    const enums = ctx.enums orelse return null;
    const info = enums.get(base_ident.text) orelse return null;
    if (!info.cases.contains(member.name.text)) return null;
    return ast.TypeExpr{ .span = base_ident.span, .kind = .{ .name = base_ident } };
}

fn closedEnumInfoForType(ty: ast.TypeExpr, ctx: Context) ?EnumInfo {
    const enum_info = enumInfoForType(ty, ctx) orelse return null;
    return if (enum_info.is_open) null else enum_info;
}

fn unionTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .generic => |node| node.base.text,
        .qualified => |node| unionTypeName(node.child.*),
        else => null,
    };
}

fn unionInfoForType(ty: ast.TypeExpr, ctx: Context) ?UnionInfo {
    const name = unionTypeName(ty) orelse return null;
    const tagged_unions = ctx.tagged_unions orelse return null;
    return tagged_unions.get(name);
}

fn unionCasePayloadType(union_info: UnionInfo, case_name: []const u8) ?ast.TypeExpr {
    return union_info.cases.get(case_name) orelse null;
}

const TaggedUnionConstructorCall = struct {
    name: ast.Ident,
    args: []const ast.Expr,
};

fn taggedUnionConstructorCall(expr: ast.Expr) ?TaggedUnionConstructorCall {
    const call = callExpr(expr) orelse return null;
    const name = calleeIdentName(call.callee.*) orelse return null;
    return .{ .name = .{ .text = name, .span = call.callee.*.span }, .args = call.args };
}

fn isKnownTaggedUnionConstructorName(name: []const u8, ctx: Context) bool {
    const tagged_unions = ctx.tagged_unions orelse return false;
    var values = tagged_unions.valueIterator();
    while (values.next()) |union_info| {
        if (union_info.cases.contains(name)) return true;
    }
    return false;
}

fn taggedUnionConstructorIsFunction(name: []const u8, ctx: Context) bool {
    const functions = ctx.functions orelse return false;
    return functions.contains(name);
}

// A value optional `?T` accepts a `T` (present) or `null` (absent). `null` is handled by
// checkNullPointerInitializer; this covers the present coercion of a plain payload value.
// Returns true when accepted (so the generic mismatch diagnostic is suppressed).
fn checkValueOptionalInitializer(target_ty: ast.TypeExpr, target: TypeClass, expr: ast.Expr, source: TypeClass, ctx: Context) bool {
    if (target != .nullable_value) return false;
    if (isNullLiteral(expr)) return true; // absent (also caught by checkNullPointerInitializer)
    if (source == .nullable_value) return true; // ?T -> ?T pass-through
    const inner = nullableInnerType(resolveAliasType(target_ty, ctx)) orelse return false;
    const inner_class = classifyTypeCtx(inner, ctx);
    // present: the payload value must be assignable to the payload type T.
    return canInitialize(inner_class, source);
}

fn exprMentionsComptimeParam(expr: ast.Expr, ctx: Context) bool {
    const params = ctx.comptime_params orelse return false;
    return exprMentionsAnyName(expr, params);
}

fn exprMentionsGenericValueParam(expr: ast.Expr, ctx: Context) bool {
    if (exprMentionsComptimeParam(expr, ctx)) return true;
    const params = ctx.type_params orelse return false;
    return exprMentionsAnyName(expr, params);
}

fn reflectionTargetDependsOnGenericParam(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (ty.kind) {
        .name => |name| blk: {
            if (ctx.type_params) |params| {
                if (params.contains(name.text)) break :blk true;
            }
            break :blk false;
        },
        .member, .enum_literal, .dyn_trait => false,
        .nullable => |child| reflectionTargetDependsOnGenericParam(child.*, ctx),
        .qualified => |node| reflectionTargetDependsOnGenericParam(node.child.*, ctx),
        .pointer => |node| reflectionTargetDependsOnGenericParam(node.child.*, ctx),
        .raw_many_pointer => |node| reflectionTargetDependsOnGenericParam(node.child.*, ctx),
        .slice => |node| reflectionTargetDependsOnGenericParam(node.child.*, ctx),
        .array => |node| exprMentionsGenericValueParam(node.len, ctx) or reflectionTargetDependsOnGenericParam(node.child.*, ctx),
        .generic => |node| blk: {
            for (node.args) |arg| {
                if (reflectionTargetDependsOnGenericParam(arg, ctx)) break :blk true;
            }
            break :blk false;
        },
        .fn_pointer => |node| blk: {
            for (node.params) |param| {
                if (reflectionTargetDependsOnGenericParam(param, ctx)) break :blk true;
            }
            break :blk reflectionTargetDependsOnGenericParam(node.ret.*, ctx);
        },
        .closure_type => |node| blk: {
            for (node.params) |param| {
                if (reflectionTargetDependsOnGenericParam(param, ctx)) break :blk true;
            }
            break :blk reflectionTargetDependsOnGenericParam(node.ret.*, ctx);
        },
    };
}

fn typeExprIsGenericValueArg(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (ty.kind) {
        .name => |name| blk: {
            if (ctx.comptime_params) |params| {
                if (params.contains(name.text)) break :blk true;
            }
            break :blk numeric.parseIntegerLiteral(name.text) != null;
        },
        .qualified => |node| typeExprIsGenericValueArg(node.child.*, ctx),
        else => false,
    };
}

fn exprMentionsAnyName(expr: ast.Expr, names: *const std.StringHashMap(void)) bool {
    return switch (expr.kind) {
        .ident => |ident| names.contains(ident.text),
        .grouped, .address_of, .deref, .await_expr => |inner| exprMentionsAnyName(inner.*, names),
        .try_expr => |inner| exprMentionsAnyName(inner.operand.*, names) or if (inner.mapped) |mapped| exprMentionsAnyName(mapped.*, names) else false,
        .unary => |node| exprMentionsAnyName(node.expr.*, names),
        .binary => |node| exprMentionsAnyName(node.left.*, names) or exprMentionsAnyName(node.right.*, names),
        .cast => |node| exprMentionsAnyName(node.value.*, names),
        .call => |node| blk: {
            if (exprMentionsAnyName(node.callee.*, names)) break :blk true;
            for (node.args) |arg| if (exprMentionsAnyName(arg, names)) break :blk true;
            break :blk false;
        },
        .index => |node| exprMentionsAnyName(node.base.*, names) or exprMentionsAnyName(node.index.*, names),
        .slice => |node| exprMentionsAnyName(node.base.*, names) or exprMentionsAnyName(node.start.*, names) or exprMentionsAnyName(node.end.*, names),
        .member => |node| exprMentionsAnyName(node.base.*, names),
        .array_literal => |items| blk: {
            for (items) |item| if (exprMentionsAnyName(item, names)) break :blk true;
            break :blk false;
        },
        .struct_literal => |fields| blk: {
            for (fields) |field| if (exprMentionsAnyName(field.value, names)) break :blk true;
            break :blk false;
        },
        .block => |block| blockMentionsAnyName(block, names),
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .unreachable_expr,
        .void_literal,
        .enum_literal,
        => false,
    };
}

fn blockMentionsAnyName(block: ast.Block, names: *const std.StringHashMap(void)) bool {
    for (block.items) |stmt| {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.init) |init| {
                if (exprMentionsAnyName(init, names)) return true;
            },
            .loop => |loop| {
                if (loop.iterable) |iterable| if (exprMentionsAnyName(iterable, names)) return true;
                if (blockMentionsAnyName(loop.body, names)) return true;
            },
            .if_let => |node| {
                if (exprMentionsAnyName(node.value, names) or blockMentionsAnyName(node.then_block, names)) return true;
                if (node.else_block) |else_block| if (blockMentionsAnyName(else_block, names)) return true;
            },
            .@"switch" => |node| {
                if (exprMentionsAnyName(node.subject, names)) return true;
                for (node.arms) |arm| {
                    for (arm.patterns) |pattern| {
                        if (pattern.kind == .literal and exprMentionsAnyName(pattern.kind.literal, names)) return true;
                    }
                    switch (arm.body) {
                        .block => |body| if (blockMentionsAnyName(body, names)) return true,
                        .expr => |body| if (exprMentionsAnyName(body, names)) return true,
                    }
                }
            },
            .block, .unsafe_block, .comptime_block => |inner| if (blockMentionsAnyName(inner, names)) return true,
            .contract_block => |node| if (blockMentionsAnyName(node.block, names)) return true,
            .@"return" => |maybe| if (maybe) |expr| {
                if (exprMentionsAnyName(expr, names)) return true;
            },
            .@"defer", .assert, .expr => |expr| if (exprMentionsAnyName(expr, names)) return true,
            .assignment => |node| if (exprMentionsAnyName(node.target, names) or exprMentionsAnyName(node.value, names)) return true,
            .asm_stmt, .@"break", .@"continue" => {},
        }
    }
    return false;
}

fn canInitialize(target: TypeClass, initializer: TypeClass) bool {
    if (target == .unknown or initializer == .unknown) return true;
    if (initializer == .never) return true;
    if (target == initializer) return true;
    if (isNullablePointerLike(target) and initializer == .null_literal) return true;
    if (isCheckedInt(target) and initializer == .int_literal) return true;
    if (isFloat(target) and initializer == .float_literal) return true;
    return false;
}

fn isByValueStructAbiType(ty: ast.TypeExpr, ctx: Context, include_plain_structs: bool) bool {
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .name => |name| blk: {
            const structs = ctx.structs orelse break :blk false;
            const info = structs.get(name.text) orelse break :blk false;
            break :blk include_plain_structs or info.abi != null;
        },
        .qualified => |node| isByValueStructAbiType(node.child.*, ctx, include_plain_structs),
        else => false,
    };
}

fn integerLiteralSyntaxOverflow(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal => |literal| numeric.parseIntegerLiteral(literal) == null,
        .grouped => |inner| integerLiteralSyntaxOverflow(inner.*),
        .unary => |node| node.op == .neg and integerLiteralSyntaxOverflow(node.expr.*),
        else => false,
    };
}

fn checkedIntBounds(kind: TypeClass) ?IntBounds {
    return switch (kind) {
        .checked_u8 => .{ .signed = false, .max = maxUnsigned(8) },
        .checked_u16 => .{ .signed = false, .max = maxUnsigned(16) },
        .checked_u32 => .{ .signed = false, .max = maxUnsigned(32) },
        .checked_u64 => .{ .signed = false, .max = maxUnsigned(64) },
        .checked_u128 => .{ .signed = false, .max = maxUnsigned(128) },
        .checked_usize => .{ .signed = false, .max = maxUnsigned(64) },
        .checked_i8 => signedBounds(8),
        .checked_i16 => signedBounds(16),
        .checked_i32 => signedBounds(32),
        .checked_i64 => signedBounds(64),
        .checked_i128 => signedBounds(128),
        .checked_isize => signedBounds(64),
        else => null,
    };
}

fn arithmeticDomainInnerBounds(ty: ast.TypeExpr, domain: []const u8, ctx: Context) ?IntBounds {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        .qualified => |node| return arithmeticDomainInnerBounds(resolveAliasType(node.child.*, ctx), domain, ctx),
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, domain) or generic.args.len != 1) return null;
    return checkedIntBounds(classifyTypeCtx(generic.args[0], ctx));
}

const EnumValueKey = struct {
    negative: bool,
    magnitude: u128,
};

fn enumValueKey(value: LiteralValue) EnumValueKey {
    return .{
        .negative = value.negative and value.magnitude != 0,
        .magnitude = value.magnitude,
    };
}

fn enumValueFits(value: EnumValueKey, bounds: IntBounds) bool {
    if (value.negative) {
        return bounds.signed and value.magnitude <= bounds.min_abs;
    }
    return value.magnitude <= bounds.max;
}

fn addressableStorageType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.ty;
            return globalType(ident.text, ctx);
        },
        .deref => |inner| if (exprStorageType(inner.*, ctx)) |ty| storageElementType(ty) else null,
        .index => |node| if (exprStorageType(node.base.*, ctx)) |ty| storageElementType(ty) else null,
        .member => |node| memberFieldType(node, ctx),
        .grouped => |inner| addressableStorageType(inner.*, ctx),
        else => null,
    };
}

fn addressOfMatchesPointerTarget(target: ast.TypeExpr, source_child: ast.TypeExpr, operand: ast.Expr, ctx: Context) bool {
    return switch (target.kind) {
        .pointer => |node| {
            if (node.mutability == .mut and !addressableStorageIsMutable(operand, ctx)) return false;
            return sameTypeSyntaxCtx(node.child.*, source_child, ctx);
        },
        .nullable => |child| addressOfMatchesPointerTarget(child.*, source_child, operand, ctx),
        .qualified => |node| addressOfMatchesPointerTarget(node.child.*, source_child, operand, ctx),
        else => false,
    };
}

fn addressableStorageIsMutable(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.mutable;
            const globals = ctx.globals orelse return true;
            if (globals.contains(ident.text)) return true;
            return true;
        },
        .deref => |inner| !constStorageBase(inner.*, ctx),
        .index => |node| !constStorageBase(node.base.*, ctx),
        // A field's assignability is the base's: through a non-const pointer it is mutable
        // even though the pointer binding itself is immutable (a `*mut T` parameter permits
        // `p.field = …`), so `&mut p.field` is allowed too. Mirrors the assignment check.
        .member => |node| !immutableValueStorageBase(node.base.*, ctx) and !constStorageBase(node.base.*, ctx),
        .grouped => |inner| addressableStorageIsMutable(inner.*, ctx),
        else => false,
    };
}

fn isBitcastLayoutType(ty: ast.TypeExpr, ctx: Context) bool {
    return isBitcastLayoutClass(classifyTypeCtx(resolveAliasType(ty, ctx), ctx));
}

fn checkAddressClassConversion(self: *Checker, span: diagnostics.Span, target: TypeClass, source: TypeClass) bool {
    if (!isAddressClass(target) or !isAddressClass(source)) return false;
    if (target == source) return false;
    self.errorCode(span, addressClassMismatchDiagnostic(target, source), addressClassMismatchMessage(target, source));
    return true;
}

fn addressClassMismatchDiagnostic(target: TypeClass, source: TypeClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "E_DMA_ADDR_NOT_PADDR";
    if (source == .dma_addr and target == .vaddr) return "E_DMA_ADDR_NOT_VADDR";
    return "E_ADDRESS_CLASS_MISMATCH";
}

fn addressClassMismatchMessage(target: TypeClass, source: TypeClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "DmaAddr is not PAddr";
    if (source == .dma_addr and target == .vaddr) return "DmaAddr is not VAddr";
    return "opaque address classes are not implicitly interchangeable";
}

fn addressDerefDiagnostic(kind: TypeClass) ?[]const u8 {
    return switch (kind) {
        .paddr => "E_PADDR_DEREF",
        .vaddr => "E_VADDR_DEREF",
        .dma_addr => "E_DMA_ADDR_DEREF",
        .user_ptr => "E_USER_PTR_DEREF",
        .mmio_ptr => "E_MMIO_PTR_DEREF",
        .phys_ptr => "E_PHYS_PTR_DEREF",
        else => null,
    };
}

fn addressDerefMessage(kind: TypeClass) []const u8 {
    return switch (kind) {
        .paddr => "cannot dereference PAddr; map it into the current virtual address space first",
        .vaddr => "cannot dereference VAddr; convert it to a typed virtual pointer first",
        .dma_addr => "cannot dereference DmaAddr; convert through the appropriate DMA mapping API first",
        .user_ptr => "cannot directly dereference UserPtr; use user.load or user.copy_from",
        .mmio_ptr => "cannot directly dereference MmioPtr; use typed MMIO register accessors",
        .phys_ptr => "cannot directly dereference PhysPtr; map it into the current virtual address space first",
        else => "cannot directly dereference opaque address class",
    };
}

fn deinitMmioStructs(mmio_structs: *std.StringHashMap(MmioStruct)) void {
    var structs = mmio_structs.valueIterator();
    while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
    mmio_structs.deinit();
}

fn deinitStructs(structs: *std.StringHashMap(StructInfo)) void {
    var values = structs.valueIterator();
    while (values.next()) |struct_info| struct_info.fields.deinit();
    structs.deinit();
}

fn deinitLayoutFieldInfos(infos: *std.StringHashMap(LayoutFieldInfo)) void {
    var values = infos.valueIterator();
    while (values.next()) |info| info.fields.deinit();
    infos.deinit();
}

fn deinitTaggedUnions(tagged_unions: *std.StringHashMap(UnionInfo)) void {
    var values = tagged_unions.valueIterator();
    while (values.next()) |union_info| union_info.cases.deinit();
    tagged_unions.deinit();
}

fn deinitEnums(enums: *std.StringHashMap(EnumInfo)) void {
    var values = enums.valueIterator();
    while (values.next()) |enum_info| enum_info.cases.deinit();
    enums.deinit();
}

fn isMmioRegisterTarget(target: ast.Expr, ctx: Context) bool {
    const member = memberExpr(target) orelse return false;
    if (mmioRegisterMemberInfo(target, ctx) != null) return true;
    if (isMmioRegisterTarget(member.base.*, ctx)) return true;
    const struct_name = mmioStructNameForValue(member.base.*, ctx) orelse return false;
    const mmio_structs = ctx.mmio_structs orelse return false;
    const mmio_struct = mmio_structs.get(struct_name) orelse return false;
    return mmio_struct.fields.contains(member.name.text);
}

fn isMmioRegisterAccessCall(callee: ast.Expr, ctx: Context) bool {
    const member = memberExpr(callee) orelse return false;
    if (!std.mem.eql(u8, member.name.text, "read") and !std.mem.eql(u8, member.name.text, "write")) return false;
    return mmioRegisterMemberInfo(member.base.*, ctx) != null;
}

fn isAtomicOperationMember(member: anytype, ctx: Context) bool {
    if (isIdentNamed(member.base.*, "atomic")) return std.mem.eql(u8, member.name.text, "init");
    _ = atomicPayloadTypeForValue(member.base.*, ctx) orelse return false;
    return true;
}

fn isKnownAtomicOperationMember(member: anytype, ctx: Context) bool {
    if (isIdentNamed(member.base.*, "atomic")) return std.mem.eql(u8, member.name.text, "init");
    _ = atomicPayloadTypeForValue(member.base.*, ctx) orelse return false;
    return std.mem.eql(u8, member.name.text, "load") or
        std.mem.eql(u8, member.name.text, "store") or
        std.mem.eql(u8, member.name.text, "fetch_add") or
        std.mem.eql(u8, member.name.text, "fetch_sub");
}

fn isMaybeUninitOperationMember(member: anytype, ctx: Context) bool {
    if (!std.mem.eql(u8, member.name.text, "write") and !std.mem.eql(u8, member.name.text, "assume_init")) return false;
    _ = maybeUninitPayloadTypeForValue(member.base.*, ctx) orelse return false;
    return true;
}

fn isResidueOperationMember(member: anytype, ctx: Context) bool {
    if (!isResidueOperationName(member)) return false;
    _ = wrapValueInnerType(member.base.*, ctx) orelse return false;
    return true;
}

fn isResidueOperationName(member: anytype) bool {
    return std.mem.eql(u8, member.name.text, "residue");
}

fn isEnumRawOperationMember(member: anytype, ctx: Context) bool {
    if (!std.mem.eql(u8, member.name.text, "raw")) return false;
    const base_ty = exprResultType(member.base.*, ctx) orelse return false;
    _ = enumInfoForType(base_ty, ctx) orelse return false;
    return true;
}

fn isDmaOperationMember(member: anytype, ctx: Context) bool {
    if (isIdentNamed(member.base.*, "cache")) {
        return std.mem.eql(u8, member.name.text, "clean") or
            std.mem.eql(u8, member.name.text, "invalidate");
    }
    _ = dmaBufInfoForValue(member.base.*, ctx) orelse return false;
    return true;
}

fn isRawManyOffsetOperationMember(member: anytype, ctx: Context) bool {
    if (!std.mem.eql(u8, member.name.text, "offset")) return false;
    const base_ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return false;
    return isRawManyPointerTypeCtx(base_ty, ctx);
}

fn mmioRegisterMemberInfo(expr: ast.Expr, ctx: Context) ?MmioFieldInfo {
    const member = memberExpr(expr) orelse return null;
    const struct_name = mmioStructNameForValue(member.base.*, ctx) orelse return null;
    const mmio_structs = ctx.mmio_structs orelse return null;
    const mmio_struct = mmio_structs.get(struct_name) orelse return null;
    return mmio_struct.fields.get(member.name.text);
}

fn mmioStructNameForValue(expr: ast.Expr, ctx: Context) ?[]const u8 {
    if (calleeIdentName(expr)) |base_name| {
        if (ctx.mmio_params) |mmio_params| {
            if (mmio_params.get(base_name)) |struct_name| return struct_name;
        }
    }
    const ty = exprStorageType(expr, ctx) orelse exprResultType(expr, ctx) orelse return null;
    return mmioPointee(resolveAliasType(ty, ctx));
}

fn isAssignableTarget(target: ast.Expr) bool {
    return switch (target.kind) {
        .ident => true,
        .deref => |inner| isAssignableDerefOperand(inner.*),
        .index => |node| isAssignableTarget(node.base.*),
        .member => |node| isAssignableTarget(node.base.*),
        .grouped => |inner| isAssignableTarget(inner.*),
        else => false,
    };
}

fn isAssignableDerefOperand(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |node| isRawManyOffsetCallSyntax(node),
        .grouped => |inner| isAssignableDerefOperand(inner.*),
        else => isAssignableTarget(expr),
    };
}

fn isRawManyOffsetCallSyntax(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 1) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    return std.mem.eql(u8, member.name.text, "offset");
}

fn constStorageBase(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.ty) |ty| return isConstStorageType(ty);
                return false;
            }
            if (globalType(ident.text, ctx)) |ty| return isConstStorageType(ty);
            return false;
        },
        .deref => |inner| constStorageBase(inner.*, ctx),
        .index => |node| constStorageBase(node.base.*, ctx),
        .member => |node| constStorageBase(node.base.*, ctx),
        .call => |node| if (rawManyOffsetReturnType(node, ctx)) |ty| isConstStorageType(ty) else false,
        .grouped => |inner| constStorageBase(inner.*, ctx),
        else => false,
    };
}

fn immutableValueStorageBase(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                // A field reached through a pointer auto-derefs; its
                // assignability is the *pointer's* mutability (a const pointer is
                // caught separately by constStorageBase), not the binding's. So a
                // `*mut T` parameter permits `p.field = …` even though `p` itself
                // is an immutable binding.
                if (entry.ty) |ty| {
                    if (ty.kind == .pointer) return false;
                }
                return !entry.mutable;
            }
            return false;
        },
        // A deref (`(*p).field`) is likewise governed by the pointer's const-ness.
        .deref => false,
        .member => |node| immutableValueStorageBase(node.base.*, ctx),
        .grouped => |inner| immutableValueStorageBase(inner.*, ctx),
        else => false,
    };
}

fn immutableIndexedValueStorageBase(expr: ast.Expr, ctx: Context) bool {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return false;
    if (!isArrayType(ty)) return false;
    return immutableValueStorageBase(expr, ctx);
}

fn isArrayType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .array => true,
        .qualified => |node| isArrayType(node.child.*),
        else => false,
    };
}

fn exprStorageType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.ty;
            return globalType(ident.text, ctx);
        },
        .call => |node| rawManyOffsetReturnType(node, ctx),
        .grouped => |inner| exprStorageType(inner.*, ctx),
        // A struct-field array base (`x.field[k]`): the field's declared type, so a constant
        // index into a fixed-size struct field is provably in bounds too. Mirrors the MIR
        // builder's `baseTypeExpr` member case.
        .member => |node| blk: {
            const base_ty = exprStorageType(node.base.*, ctx) orelse break :blk null;
            const struct_name = structTypeName(base_ty) orelse break :blk null;
            const structs = ctx.structs orelse break :blk null;
            const info = structs.get(struct_name) orelse break :blk null;
            break :blk info.fields.get(node.name.text);
        },
        // An arithmetic/bitwise binary expression has the type of its operands. This lets a
        // `bitcast<f32>((a + b) << c)` learn its source's integer type (the shift/add result
        // is the left operand's type; a literal operand carries none, so prefer the other side).
        .binary => |node| arithmeticBinaryType(node, ctx),
        .unary => |node| if (node.op == .neg) exprStorageType(node.expr.*, ctx) else null,
        else => null,
    };
}

// The result type of an arithmetic/bitwise binary operator: the type of whichever operand
// carries a concrete type (a bare literal operand has none). Comparison/logical operators are
// handled by the caller (they yield bool), so this only sees value-producing operators.
// Operands are resolved via `exprResultType` so a nested call (`bitcast<T>(..)`, a function
// call) contributes its return type, not just storage-typed idents.
fn arithmeticBinaryType(node: anytype, ctx: Context) ?ast.TypeExpr {
    if (isComparisonBinary(node.op) or isLogicalBinary(node.op)) return null;
    // For a shift, the result type is the left (shifted) operand's type.
    if (node.op == .shl or node.op == .shr) return exprResultType(node.left.*, ctx);
    return exprResultType(node.left.*, ctx) orelse exprResultType(node.right.*, ctx);
}

fn globalType(name: []const u8, ctx: Context) ?ast.TypeExpr {
    const globals = ctx.globals orelse return null;
    const global = globals.get(name) orelse return null;
    return global.ty;
}

fn globalClass(name: []const u8, ctx: Context) ?TypeClass {
    const ty = globalType(name, ctx) orelse return null;
    return classifyTypeCtx(ty, ctx);
}

// A qualified tagged-union constructor `Union.variant(...)` is self-typed: its result
// type is `Union`, taken from the callee's owner (no target type needed). null when the
// callee owner is not a known tagged union or the member is not one of its cases — then
// the call is something else (an impl/associated call, an intrinsic) and resolves normally.
fn qualifiedUnionConstructorReturnType(node: anytype, ctx: Context) ?ast.TypeExpr {
    const q = ast_query.qualifiedMemberCallee(node.callee.*) orelse return null;
    const tagged = ctx.tagged_unions orelse return null;
    const info = tagged.get(q.owner) orelse return null;
    if (!info.cases.contains(q.member.text)) return null;
    return ast.TypeExpr{ .span = node.callee.*.span, .kind = .{ .name = .{ .text = q.owner, .span = q.member.span } } };
}

pub fn exprResultType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| constGetReturnType(node, ctx) orelse rawManyOffsetReturnType(node, ctx) orelse byteViewCallReturnType(node) orelse vaCallReturnType(node) orelse atomicCallReturnType(node.callee.*, ctx) orelse maybeUninitCallReturnType(node.callee.*, ctx) orelse bitcastCallReturnType(node) orelse mathBuiltinReturnType(node.callee.*) orelse unwrapCallReturnType(node, ctx) orelse dynDispatchReturnType(node, ctx) orelse closureCallReturnType(node.callee.*, ctx) orelse fnPointerCallReturnType(node.callee.*, ctx) orelse qualifiedUnionConstructorReturnType(node, ctx) orelse if (node.type_args.len == 0) directCallReturnType(node.callee.*, ctx) else null,
        .try_expr => |inner| tryPayloadType(inner.operand.*, ctx),
        .cast => |node| node.ty.*,
        .deref => |inner| derefResultType(inner.*, ctx),
        .index => |node| indexResultType(node, ctx),
        .slice => |node| sliceResultType(node, ctx),
        .member => |node| enumVariantPathType(node, ctx) orelse memberResultFieldType(node, ctx),
        .grouped => |inner| exprResultType(inner.*, ctx),
        // Comparison and logical operators yield `bool`; surfacing that lets a
        // `switch a < b { true => …, false => … }` count as exhaustive.
        .binary => |node| if (isComparisonBinary(node.op) or isLogicalBinary(node.op))
            boolTypeExpr(expr.span)
        else
            exprStorageType(expr, ctx),
        .unary => |node| if (node.op == .logical_not) boolTypeExpr(expr.span) else exprStorageType(expr, ctx),
        else => exprStorageType(expr, ctx),
    };
}

fn boolTypeExpr(span: diagnostics.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = "bool", .span = span } } };
}

// The float result type of a pass-through math builtin call (`__builtin_sqrtf` -> f32,
// `__builtin_sqrt` -> f64), so a `let x: f32 = __builtin_sqrtf(..)` typechecks.
fn mathBuiltinReturnType(callee: ast.Expr) ?ast.TypeExpr {
    const callee_name = calleeIdentName(callee) orelse return null;
    const name = if (mathBuiltinFloatClass(callee_name)) |class| (if (class == .f32) "f32" else "f64") else return null;
    return ast.TypeExpr{ .span = callee.span, .kind = .{ .name = .{ .text = name, .span = callee.span } } };
}

fn byteViewCallReturnType(call: anytype) ?ast.TypeExpr {
    const kind = byteViewCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .as_bytes => constU8SliceType(call.callee.*.span),
        .bytes_equal => boolTypeExpr(call.callee.*.span),
    };
}

fn isConstU8SliceType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .slice => |node| node.mutability == .@"const" and isTypeName(node.child.*, "u8"),
        .qualified => |node| isConstU8SliceType(node.child.*),
        else => false,
    };
}

fn constGetMember(callee: ast.Expr) ?struct { base: *ast.Expr, name: ast.Ident } {
    const member = memberExpr(callee) orelse return null;
    return if (std.mem.eql(u8, member.name.text, "const_get")) .{ .base = member.base, .name = member.name } else null;
}

const ConstGetInfo = struct {
    base: *ast.Expr,
    index: ?usize,
    len: usize,
    element_ty: ast.TypeExpr,
};

fn constGetInfo(call: anytype, ctx: Context) ?ConstGetInfo {
    const member = constGetMember(call.callee.*) orelse return null;
    const base_ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return null;
    const array = fixedArrayType(resolveAliasType(base_ty, ctx), ctx.const_fns, ctx.const_globals) orelse return null;
    return .{
        .base = member.base,
        .index = if (call.type_args.len == 1) constGetIndexArg(call.type_args[0]) else null,
        .len = array.len,
        .element_ty = array.child,
    };
}

fn constGetReturnType(call: anytype, ctx: Context) ?ast.TypeExpr {
    const info = constGetInfo(call, ctx) orelse return null;
    return info.element_ty;
}

fn rawManyOffsetReturnType(call: anytype, ctx: Context) ?ast.TypeExpr {
    if (call.type_args.len != 0) return null;
    const member = memberCallee(call.callee.*) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "offset")) return null;
    const base_ty = exprResultType(member.base.*, ctx) orelse return null;
    return if (isRawManyPointerTypeCtx(base_ty, ctx)) base_ty else null;
}

fn isRawManyPointerTypeCtx(ty: ast.TypeExpr, ctx: Context) bool {
    return isRawManyPointerType(resolveAliasType(ty, ctx));
}

fn assignmentTargetType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (!entry.mutable) return null;
                return entry.ty;
            }
            return globalType(ident.text, ctx);
        },
        .deref => |inner| if (exprStorageType(inner.*, ctx)) |ty| storageElementType(ty) else null,
        .index => |node| if (exprStorageType(node.base.*, ctx)) |ty| storageElementType(ty) else null,
        .member => |node| if (isMmioRegisterTarget(expr, ctx)) null else memberFieldType(node, ctx),
        .grouped => |inner| assignmentTargetType(inner.*, ctx),
        else => null,
    };
}

fn derefResultType(base: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(base, ctx) orelse return null;
    return storageElementType(base_ty);
}

fn indexResultType(index: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(index.base.*, ctx) orelse return null;
    return storageElementType(base_ty);
}

fn sliceResultType(slice: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(slice.base.*, ctx) orelse exprStorageType(slice.base.*, ctx) orelse return null;
    return sliceTypeForBase(base_ty, slice.base.*.span);
}

fn sliceTypeForBase(base_ty: ast.TypeExpr, span: diagnostics.Span) ?ast.TypeExpr {
    return switch (base_ty.kind) {
        .slice => base_ty,
        .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
        .qualified => |node| sliceTypeForBase(node.child.*, span),
        else => null,
    };
}

fn memberFieldType(member: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprStorageType(member.base.*, ctx) orelse return null;
    return structFieldType(base_ty, member.name.text, ctx);
}

fn memberResultFieldType(member: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(member.base.*, ctx) orelse return null;
    return structFieldType(base_ty, member.name.text, ctx);
}

pub fn structFieldType(base_ty: ast.TypeExpr, field_name: []const u8, ctx: Context) ?ast.TypeExpr {
    const layout_name = memberLayoutTypeName(base_ty, ctx) orelse return null;
    const layout_info = layoutFieldInfo(layout_name, ctx) orelse return null;
    return layout_info.fields.get(field_name);
}

fn directCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const function = directCallFunction(callee, ctx) orelse return null;
    const return_ty = function.return_ty orelse return .void;
    return classifyTypeCtx(return_ty, ctx);
}

pub fn directCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const function = directCallFunction(callee, ctx) orelse return null;
    return function.return_ty;
}

fn fnPointerCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = calleeFnPointerType(callee, ctx) orelse return null;
    return ty.kind.fn_pointer.ret.*;
}

fn closureCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = calleeClosureType(callee, ctx) orelse return null;
    return ty.kind.closure_type.ret.*;
}

fn directCallFunction(callee: ast.Expr, ctx: Context) ?FunctionInfo {
    const name = calleeIdentName(callee) orelse return null;
    const functions = ctx.functions orelse return null;
    return functions.get(name);
}

// A direct call to a function declared `-> never` diverges: control never returns
// to the call site (the callee panics/loops/traps). Used by the control-flow
// fall-through and linear-`move` analyses so a `panic()`-style helper ends a path
// exactly like an inline `trap(...)`/`unreachable` does.
fn callReturnsNever(call: anytype, ctx: Context) bool {
    const info = directCallFunction(call.callee.*, ctx) orelse return false;
    const ty = info.return_ty orelse return false;
    return isTypeName(ty, "never");
}

// Whether an expression statement is a direct call to a `-> never` function. The linear
// `move` join treats such a statement as a diverging (Unreachable) path so a resource
// consumed before it is not spuriously re-merged as live on the falling-through arm.
pub fn exprIsNeverCall(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .call => |node| callReturnsNever(node, ctx),
        .grouped => |inner| exprIsNeverCall(inner.*, ctx),
        else => false,
    };
}

// The type name of a type-parameter argument after production monomorphization.
fn typeArgName(arg: ast.Expr, ctx: Context) ?[]const u8 {
    return switch (arg.kind) {
        .ident => |id| id.text,
        .grouped => |inner| typeArgName(inner.*, ctx),
        else => null,
    };
}

// The struct name a type expression directly names (a known struct/move type),
// or null if it isn't a plain named struct.
fn structNameOfType(ty: ast.TypeExpr, ctx: Context) ?[]const u8 {
    const structs = ctx.structs orelse return null;
    return switch (ty.kind) {
        .name => |n| if (structs.contains(n.text)) n.text else null,
        else => null,
    };
}

// The declared type of an expression usable for struct-name comparison: a local
// or global binding's type, or a direct call's return type.
fn exprDeclaredType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| blk: {
            if (ctx.scope) |scope| {
                if (scope.get(ident.text)) |entry| break :blk entry.ty;
            }
            break :blk globalType(ident.text, ctx);
        },
        .call => |node| blk: {
            const name = directCallName(node.callee.*) orelse break :blk null;
            const fns = ctx.functions orelse break :blk null;
            const info = fns.get(name) orelse break :blk null;
            break :blk info.return_ty;
        },
        .member => |node| memberFieldType(node, ctx),
        .grouped => |inner| exprDeclaredType(inner.*, ctx),
        else => null,
    };
}

// If `callee` is a value of function-pointer type (a local, global, parameter, or
// struct field), return its signature type; otherwise null.
fn calleeFnPointerType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprDeclaredType(callee, ctx) orelse return null;
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .fn_pointer => resolved,
        else => null,
    };
}

fn calleeClosureType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprDeclaredType(callee, ctx) orelse return null;
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .closure_type => resolved,
        else => null,
    };
}

fn isBindCallNode(call: anytype) bool {
    return call.type_args.len == 0 and call.args.len == 2 and isIdentNamed(call.callee.*, "bind");
}

fn bindMatchesClosureExpr(expr: ast.Expr, expected: ast.TypeExpr, ctx: Context) ?bool {
    return switch (expr.kind) {
        .call => |node| if (isBindCallNode(node)) bindMatchesClosure(node, expected, ctx) else null,
        .grouped => |inner| bindMatchesClosureExpr(inner.*, expected, ctx),
        else => null,
    };
}

// Does the named top-level function's signature match an expected `fn(...) -> R`
// type? Compared structurally, without allocating an intermediate type.
fn functionMatchesFnPointer(fn_name: []const u8, expected: ast.TypeExpr, ctx: Context) bool {
    const node = switch (resolveAliasType(expected, ctx).kind) {
        .fn_pointer => |n| n,
        else => return false,
    };
    const fns = ctx.functions orelse return false;
    const info = fns.get(fn_name) orelse return false;
    if (info.params.len != node.params.len) return false;
    for (info.params, node.params) |param, expected_param| {
        if (!sameTypeSyntaxCtx(param.ty, expected_param, ctx)) return false;
    }
    const void_ty = ast.TypeExpr{ .span = expected.span, .kind = .{ .name = .{ .text = "void", .span = expected.span } } };
    const ret_ty = info.return_ty orelse void_ty;
    return sameTypeSyntaxCtx(ret_ty, node.ret.*, ctx);
}

fn bindMatchesClosure(call: anytype, expected: ast.TypeExpr, ctx: Context) bool {
    const node = switch (resolveAliasType(expected, ctx).kind) {
        .closure_type => |n| n,
        else => return false,
    };
    const fname = calleeIdentName(call.args[1]) orelse return false;
    const fns = ctx.functions orelse return false;
    const info = fns.get(fname) orelse return false;
    if (info.params.len == 0) return false;
    if (!exprCanInitializeType(info.params[0].ty, call.args[0], ctx)) return false;
    if (info.params.len - 1 != node.params.len) return false;
    for (info.params[1..], node.params) |param, expected_param| {
        if (!sameTypeSyntaxCtx(param.ty, expected_param, ctx)) return false;
    }
    const void_ty = ast.TypeExpr{ .span = expected.span, .kind = .{ .name = .{ .text = "void", .span = expected.span } } };
    const ret_ty = info.return_ty orelse void_ty;
    return sameTypeSyntaxCtx(ret_ty, node.ret.*, ctx);
}

fn exprCanInitializeType(target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
    const target = classifyTypeCtx(target_ty, ctx);
    if (addressOfOperand(expr)) |operand| {
        const source_ty = addressableStorageType(operand.*, ctx) orelse return false;
        return addressOfMatchesPointerTarget(target_ty, source_ty, operand.*, ctx);
    }
    if (literalCanInitializeType(target_ty, target, expr, ctx)) return true;
    const source_ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse exprDeclaredType(expr, ctx) orelse return false;
    if (sameTypeSyntaxCtx(source_ty, target_ty, ctx)) return true;
    return canInitialize(target, classifyTypeCtx(source_ty, ctx));
}

fn literalCanInitializeType(target_ty: ast.TypeExpr, target: TypeClass, expr: ast.Expr, ctx: Context) bool {
    if (integerLiteralValue(expr)) |value| return integerLiteralFitsType(target_ty, target, value, ctx);
    if (integerLiteralSyntaxOverflow(expr)) return false;
    return switch (expr.kind) {
        .grouped => |inner| literalCanInitializeType(target_ty, target, inner.*, ctx),
        .float_literal => canInitialize(target, .float_literal),
        .bool_literal => canInitialize(target, .bool),
        .null_literal => canInitialize(target, .null_literal),
        .void_literal => canInitialize(target, .void),
        else => false,
    };
}

fn integerLiteralFitsType(target_ty: ast.TypeExpr, target: TypeClass, value: LiteralValue, ctx: Context) bool {
    if (target == .wrap or target == .sat) {
        const bounds = arithmeticDomainInnerBounds(resolveAliasType(target_ty, ctx), if (target == .wrap) "wrap" else "sat", ctx) orelse return false;
        return integerLiteralFitsBounds(value, bounds);
    }
    if (target == .secret) {
        const inner = secretPayloadType(resolveAliasType(target_ty, ctx)) orelse return false;
        const bounds = checkedIntBounds(classifyTypeCtx(inner, ctx)) orelse return false;
        return integerLiteralFitsBounds(value, bounds);
    }
    const bounds = checkedIntBounds(target) orelse return canInitialize(target, .int_literal);
    return integerLiteralFitsBounds(value, bounds);
}

fn integerLiteralFitsBounds(value: LiteralValue, bounds: IntBounds) bool {
    if (value.negative) return bounds.signed and value.magnitude <= bounds.min_abs;
    return value.magnitude <= bounds.max;
}

fn directCallName(callee: ast.Expr) ?[]const u8 {
    return calleeIdentName(callee);
}

fn updateAssignmentAddressOrigin(target: ast.Expr, value: ast.Expr, ctx: Context) void {
    switch (target.kind) {
        .ident => |ident| {
            const scope = ctx.scope orelse return;
            const entry = scope.getPtr(ident.text) orelse return;
            if (!entry.mutable) return;
            entry.address_origin = addressOrigin(value, ctx);
        },
        .grouped => |inner| updateAssignmentAddressOrigin(inner.*, value, ctx),
        else => {},
    }
}

// ----- unified place-root classification (closes the bug-#1/#2 class) -------
//
// "What storage does this lvalue ultimately name?" was previously re-derived in
// THREE places with divergent coverage (localAddressRoot/localStorageRoot,
// pointerParamRoot, aliasReferentName) — and the divergence WAS the soundness holes:
//   - the escape check only knew pointer *params* outlive the frame, not globals (#2);
//   - the alias check only matched `&ident`, never an alias copied into a new slot (#1).
// `placeRoot` is the single classifier all the lifetime/escape checks consult.
const PlaceRoot = union(enum) {
    // A function-local binding (`var`/`let` at function scope).
    local: struct { span: diagnostics.Span },
    // A function parameter; `class` is its type class (for pointer-like tests).
    param: struct { span: diagnostics.Span, class: TypeClass },
    // A module-level global — outlives every frame.
    global,
    // Not resolvable to a known binding (a temporary, a builtin, etc.).
    none,
};

// Resolve the root binding that a bare-ident (peeling `grouped`) names.
fn placeRoot(expr: ast.Expr, ctx: Context) PlaceRoot {
    return switch (expr.kind) {
        .ident => |ident| {
            if (ctx.scope) |scope| {
                if (scope.get(ident.text)) |entry| {
                    return switch (entry.origin) {
                        .local => .{ .local = .{ .span = expr.span } },
                        .param => .{ .param = .{
                            .span = expr.span,
                            .class = if (entry.ty) |ty| classifyTypeCtx(ty, ctx) else entry.class,
                        } },
                    };
                }
            }
            // A name not in the local scope that IS a declared global.
            if (ctx.globals) |globals| {
                if (globals.contains(ident.text)) return .global;
            }
            return .none;
        },
        .grouped => |inner| placeRoot(inner.*, ctx),
        else => .none,
    };
}

fn localAddressRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .address_of => |inner| localStorageRoot(inner.*, ctx),
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.address_origin == .local) return expr.span;
            }
            return null;
        },
        .grouped => |inner| localAddressRoot(inner.*, ctx),
        else => null,
    };
}

// (bug #3, borrow-escape through an aggregate) The span of a `&local` (the address of local
// storage) that appears as a FIELD/ELEMENT of a struct or array literal — i.e. the address
// is laundered into an aggregate that then escapes (returned by value). Recurses through
// nested aggregate literals. Returns null if no laundered local address is found. This is a
// no-false-positive slice: a field that is itself `&local` (or a nested aggregate holding
// one) is the only thing flagged; a plain `&local` not inside an aggregate is already caught
// by the direct pointer-return / escape checks.
fn aggregateLocalAddressRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .grouped => |inner| aggregateLocalAddressRoot(inner.*, ctx),
        .struct_literal => |fields| {
            for (fields) |f| {
                if (localAddressRoot(f.value, ctx)) |span| return span;
                if (closureLocalAddressRoot(f.value, ctx)) |span| return span;
                if (aggregateLocalAddressRoot(f.value, ctx)) |span| return span;
            }
            return null;
        },
        .array_literal => |items| {
            for (items) |item| {
                if (localAddressRoot(item, ctx)) |span| return span;
                if (closureLocalAddressRoot(item, ctx)) |span| return span;
                if (aggregateLocalAddressRoot(item, ctx)) |span| return span;
            }
            return null;
        },
        else => null,
    };
}

fn closureLocalAddressRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .call => |node| if (isBindCallNode(node)) localAddressRoot(node.args[0], ctx) else null,
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.address_origin == .local) return expr.span;
            }
            return null;
        },
        .grouped => |inner| closureLocalAddressRoot(inner.*, ctx),
        else => null,
    };
}

fn addressOrigin(expr: ast.Expr, ctx: Context) AddressOrigin {
    return switch (expr.kind) {
        .address_of => |inner| if (localStorageRoot(inner.*, ctx) != null) .local else .none,
        .call => if (closureLocalAddressRoot(expr, ctx) != null) .local else .none,
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.address_origin;
            return .none;
        },
        .grouped => |inner| addressOrigin(inner.*, ctx),
        else => .none,
    };
}

// T1.2: if `expr` is `&<ident>` (the address of a bare local binding, possibly under
// `grouped`), return that binding's name — the referent a derived pointer alias points at.
// Scoped to the bare-ident case: `&a` aliases the binding `a`. `&a.field` / `&a[i]` are NOT
// reported (the move checker tracks whole bindings and one-level fields by separate keys; a
// pointer into a sub-place is a follow-up). This is the sound, no-false-positive slice.
fn aliasReferentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .address_of => |inner| identName(inner.*),
        .grouped => |inner| aliasReferentName(inner.*),
        else => null,
    };
}

// T1.2 (bug #1, stale-alias laundering): the move-binding that a `let`-initializer
// derives a pointer alias of, given the current move `state`. Two shapes:
//   - `let p = &a;`  → the referent is `a` (handled by `aliasReferentName`).
//   - `let q = p;`   → copying an existing alias slot. `q` must INHERIT `p`'s
//     `alias_of`, otherwise a use-after-move through `q` is a false negative (the
//     copy "launders" the staleness). We resolve to the ORIGINAL referent so the
//     stale check has one referent to consult regardless of the alias chain length.
pub fn aliasReferentOf(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    if (aliasReferentName(expr)) |referent| return referent;
    if (identName(expr)) |name| {
        if (state.get(name)) |slot| {
            if (slot.alias_of) |inherited| return inherited;
        }
    }
    return null;
}

// T1.2 (conservative rejection): the root binding name of the *place* whose address an
// `&…` expression takes, when that root is a tracked move binding — at ANY nesting depth.
// `&t` → `t`, `&t.inner` → `t`, `&t[i]` → `t`, `&t.a.b` → `t`. Also resolves the address of
// an existing borrow alias (`&p` where `p` aliases `t`) back to the original referent. This
// is broader than `aliasReferentOf` (which is the no-false-positive scalar-alias slice): it
// is used only to mark a move binding as having an ESCAPED borrow, where over-approximation
// is the safe direction. Returns null if the address is not rooted at a tracked move binding.
// T1.3 ptr-to-int round-trip: if `expr` is a cast-to-INTEGER of a value rooted at a tracked
// `move` binding (`<move-place> as usize`, grouped peeled), return that move root; else null.
// Used by the borrow-escape scan to treat `&<move> as int` as a provenance-stripping escape.
// Narrow by construction: a non-integer target type or a non-move-rooted cast operand → null,
// so the pervasive integer<->pointer kernel/uaccess code is unaffected.
pub fn castToIntegerMoveRoot(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    switch (expr.kind) {
        .grouped => |inner| return castToIntegerMoveRoot(self, inner.*, state),
        .cast => |c| {
            const mctx = self.move_ctx orelse return null;
            if (!isIntegerLike(classifyTypeCtx(c.ty.*, mctx.*))) return null;
            return placeRootMoveName(c.value.*, state);
        },
        else => return null,
    }
}

pub fn borrowedMoveRoot(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    const target = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .grouped => |inner| return borrowedMoveRoot(inner.*, state),
        else => return null,
    };
    return placeRootMoveName(target, state);
}

// The root binding name of an lvalue place (`x`, `x.f`, `x[i]`, `x.f[i].g`), if that root is
// a tracked move binding. Resolves an alias root back to its original referent.
pub fn placeRootMoveName(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    switch (expr.kind) {
        .ident => |id| {
            const slot = state.get(id.text) orelse return null;
            if (slot.alias_of) |referent| return referent; // an alias: resolve to its target
            return id.text;
        },
        .grouped => |inner| return placeRootMoveName(inner.*, state),
        .member => |m| return placeRootMoveName(m.base.*, state),
        .index => |ix| return placeRootMoveName(ix.base.*, state),
        .deref => |inner| return placeRootMoveName(inner.*, state),
        else => return null,
    }
}

// The bare-binding name of an lvalue, peeling `grouped`. Null if it is not a simple ident.
fn identName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| id.text,
        .grouped => |inner| identName(inner.*),
        else => null,
    };
}

fn localStorageRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.origin == .local) return expr.span;
            }
            return null;
        },
        // Member access whose base is a POINTER auto-derefs (`p.f` == `p->f`), so the
        // address `&p.f` points into the POINTED-TO storage (caller-owned / heap), not
        // this frame's stack slot — it is NOT a local-storage root, and returning it does
        // not dangle (G14). Only a base that is a by-value aggregate keeps recursing; there
        // the field lives inside a stack local, which is the genuine dangling case.
        .member => |node| if (placeGoesThroughPointer(node.base.*, ctx)) null else localStorageRoot(node.base.*, ctx),
        .index => |node| indexedLocalArrayStorageRoot(node.base.*, ctx),
        .grouped => |inner| localStorageRoot(inner.*, ctx),
        else => null,
    };
}

// True when reaching a place through `expr` dereferences a POINTER — i.e. `expr` is a
// pointer-typed base of a `.field` / `[i]` access (auto-deref, `p.f` == `p->f`). Taking
// the address of such a place yields a pointer into the pointed-to storage, which
// outlives this frame, so it is never a local-storage-escape root.
fn placeGoesThroughPointer(base: ast.Expr, ctx: Context) bool {
    const ty = exprResultType(base, ctx) orelse return false;
    return isPointerLikeClass(classifyTypeCtx(ty, ctx));
}

// T1.1 lexical region/scope borrows: does an assignment *target* write to storage
// that OUTLIVES the current function's locals?
//
// Two such places exist, and BOTH must be caught (a write to only one was bug #2):
//   - *through a pointer parameter* — `*out = ...` / `out.field = ...` where `out`
//     is a pointer parameter; the caller owns that storage, so it outlives us.
//   - *a GLOBAL pointer* — `gp = &local;` where `gp` is a module-level global;
//     a global outlives every frame, so the stored borrow dangles after return.
//
// This is the sound, no-false-positive slice. A bare-ident target that resolves to a
// *local* (`p = ...`) is a same-function binding and does NOT outlive a local referent
// (that needs nested-scope/lifetime analysis, T1.3), so it is never reported here.
//
// Passing `&local` DOWN to a callee is unaffected (that is a call argument, never an
// assignment target), so the `init(&x); use(x)` idiom keeps compiling.
fn assignmentTargetEscapesFunction(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        // A bare-ident target escapes only if it resolves to a (pointer-like) global.
        .ident => placeRoot(expr, ctx) == .global,
        // `*p = ...` / `p.field = ...` escape when `p` resolves to a pointer parameter
        // OR a pointer-like global (storage that outlives this frame either way).
        .deref => |inner| placeOutlivesFrame(inner.*, ctx),
        .member => |node| placeOutlivesFrame(node.base.*, ctx),
        .index => |node| placeOutlivesFrame(node.base.*, ctx),
        .grouped => |inner| assignmentTargetEscapesFunction(inner.*, ctx),
        else => false,
    };
}

// Whether `expr` resolves to storage that OUTLIVES this function's stack frame —
// either a pointer *parameter* (caller-owned) or a pointer-like *global* (outlives
// every frame). A local pointer is NOT included (it cannot outlive the function it
// lives in). Used as the base of `*p`/`p.field`/`p[i]` escape targets.
fn placeOutlivesFrame(expr: ast.Expr, ctx: Context) bool {
    return switch (placeRoot(expr, ctx)) {
        .param => |p| isPointerLikeClass(p.class),
        .global => true,
        else => false,
    };
}

fn indexedLocalArrayStorageRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    if (!isArrayType(ty)) return null;
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.origin == .local or entry.origin == .param) return expr.span;
            }
            return null;
        },
        .call => expr.span,
        .grouped => |inner| indexedLocalArrayStorageRoot(inner.*, ctx),
        else => localStorageRoot(expr, ctx),
    };
}

fn pointerComparableTypesCtx(left: ast.TypeExpr, right: ast.TypeExpr, ctx: Context) bool {
    const resolved_left = resolveAliasType(left, ctx);
    const resolved_right = resolveAliasType(right, ctx);
    const left_view = viewType(resolved_left) orelse return false;
    const right_view = viewType(resolved_right) orelse return false;
    if (left_view.kind != right_view.kind) return false;
    const left_child = viewElementType(resolved_left) orelse return false;
    const right_child = viewElementType(resolved_right) orelse return false;
    return sameTypeSyntaxCtx(left_child, right_child, ctx);
}

fn implicitPointerViewConversionCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    _ = viewType(resolved_target) orelse return false;
    _ = viewType(resolved_source) orelse return false;
    if (nullablePointerWideningCtx(resolved_target, resolved_source, ctx)) return false;
    // A `[]mut T` -> `[]const T` slice (G12) or `*mut T` -> `*const T` single-pointer (G30)
    // const-narrowing is safe (representation is layout-identical; only the pointee's
    // constness differs) and is allowed implicitly.
    if (constNarrowingViewConversionCtx(resolved_target, resolved_source, ctx)) return false;
    const target_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_target, ctx));
    const source_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_source, ctx));
    if (target_is_c_void != source_is_c_void) return false;
    return !sameTypeSyntaxCtx(resolved_target, resolved_source, ctx);
}

// True for a safe const-narrowing view conversion: `[]mut T` -> `[]const T` (G12 slices) or
// `*mut T` -> `*const T` (G30 single pointers). Both sides are the SAME view kind over the
// same element type and nullability, and the ONLY difference is the pointee's constness
// (mut source -> const target). Representation is identical (a plain pointer for a single
// object, a `{ptr,len}` fat pointer for a slice), so this is a no-op coercion the backends
// emit as a plain assignment / struct copy. Scoped to single pointers + slices; raw-many
// (`[*]mut`) const-narrows stay explicit, and the REVERSE (const -> mut) widening is never
// allowed (source must be `.mut`, target `.const`).
fn constNarrowingViewConversionCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const target_view = viewType(target) orelse return false;
    const source_view = viewType(source) orelse return false;
    if (target_view.kind != source_view.kind) return false;
    if (!(target_view.kind == .slice or target_view.kind == .pointer)) return false;
    if (target_view.nullable != source_view.nullable) return false;
    // mut source -> immutable target only. The target may be spelled `*const T` (`.const`)
    // or the bare immutable `*T` (`.none`); both are read-only. The REVERSE (immutable -> mut
    // widening) is never narrowing, so it stays rejected (source must be `.mut`).
    if (source_view.mutability != .mut or target_view.mutability == .mut) return false;
    const target_elem = viewElementType(target) orelse return false;
    const source_elem = viewElementType(source) orelse return false;
    return sameTypeSyntaxCtx(target_elem, source_elem, ctx);
}

fn nullablePointerWideningCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    const target_view = viewType(resolved_target) orelse return false;
    const source_view = viewType(resolved_source) orelse return false;
    if (!target_view.nullable or source_view.nullable) return false;
    if (target_view.kind != source_view.kind or target_view.mutability != source_view.mutability) return false;
    const target_child = nullableInnerType(resolved_target) orelse return false;
    return sameTypeSyntaxCtx(target_child, resolved_source, ctx);
}

fn implicitCVoidPointerConversionCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    _ = viewType(resolved_target) orelse return false;
    _ = viewType(resolved_source) orelse return false;
    const target_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_target, ctx));
    const source_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_source, ctx));
    return target_is_c_void != source_is_c_void;
}

fn sameTypeSyntaxCtx(left: ast.TypeExpr, right: ast.TypeExpr, ctx: Context) bool {
    return sameTypeSyntax(resolveAliasType(left, ctx), resolveAliasType(right, ctx));
}

fn mmioFieldInfoFromType(ty: ast.TypeExpr) ?MmioFieldInfo {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    const access_arg: ast.TypeExpr = if (std.mem.eql(u8, generic.base.text, "Reg") and generic.args.len == 2)
        generic.args[1]
    else if (std.mem.eql(u8, generic.base.text, "RegBits") and generic.args.len == 3)
        generic.args[2]
    else
        return null;
    const access = mmioRegisterAccessFromModeType(access_arg) orelse return null;
    return .{ .access = access };
}

fn packedBitsInfoForType(ty: ast.TypeExpr, ctx: Context) ?LayoutFieldInfo {
    const name = typeName(ty) orelse return null;
    const packed_bits = ctx.packed_bits orelse return null;
    return packed_bits.get(name);
}

// Gap #1 [secret overlay-reinterpret]: an `overlay union` whose arms ALIAS the same bytes.
// If ANY arm is a `Secret<…>`, then reading ANY arm reinterprets the secret bytes — writing
// the secret arm and reading a plain arm would otherwise strip secrecy. So a read of ANY
// member of such a union must be classified `.secret`. A union with NO secret arm stays
// non-secret (do not over-broaden).
fn overlayUnionTypeHasSecretArm(base_ty: ast.TypeExpr, ctx: Context) bool {
    const overlay_unions = ctx.overlay_unions orelse return false;
    const name = structTypeName(base_ty) orelse return false;
    const info = overlay_unions.get(name) orelse return false;
    var it = info.fields.valueIterator();
    while (it.next()) |field_ty| {
        if (classifyTypeCtx(field_ty.*, ctx) == .secret) return true;
    }
    return false;
}

// `unwrap(x)` yields the payload of a nullable `x` — the non-null inner type (e.g.
// `unwrap(?*dyn Trait)` -> `*dyn Trait`). Wiring this into exprResultType lets the
// unwrapped value flow into a typed binding (including the strict `*dyn` coercion).
fn unwrapCallReturnType(node: anytype, ctx: Context) ?ast.TypeExpr {
    if (!isUnwrapCall(node.callee.*)) return null;
    if (node.args.len != 1) return null;
    const operand_ty = exprResultType(node.args[0], ctx) orelse return null;
    return nullableInnerType(operand_ty);
}

// The return type of a trait-object dispatch `recv.method(args)` where `recv` is a
// `*dyn Trait` — looked up from the trait method signature. Wiring this into
// exprResultType lets a dispatch result flow into a typed binding (e.g. an enum-returning
// method assigned to `let x: SomeEnum = d.method()`), where a scalar would coerce anyway.
fn dynDispatchReturnType(node: anytype, ctx: Context) ?ast.TypeExpr {
    const member = switch (node.callee.*.kind) {
        .member => |m| m,
        else => return null,
    };
    const base_ty = exprDeclaredType(member.base.*, ctx) orelse return null;
    const dyn = switch (resolveAliasType(base_ty, ctx).kind) {
        .dyn_trait => |d| d,
        else => return null,
    };
    const td = ctx.trait_decls orelse return null;
    const trait = td.get(dyn.trait_name.text) orelse return null;
    const m = findTraitMethod(trait.methods, member.name.text) orelse return null;
    return m.return_type;
}

fn fallthroughSpan(block: ast.Block, ctx: Context) ?diagnostics.Span {
    if (block.items.len == 0) return block.span;
    const last = block.items[block.items.len - 1];
    return if (stmtMayFallThrough(last, ctx)) last.span else null;
}

fn stmtMayFallThrough(stmt: ast.Stmt, ctx: Context) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue", .asm_stmt => false,
        .expr => |expr| exprMayFallThrough(expr, ctx),
        .block, .unsafe_block, .comptime_block => |block| fallthroughSpan(block, ctx) != null,
        .contract_block => |contract| fallthroughSpan(contract.block, ctx) != null,
        .if_let => |node| node.else_block == null or
            fallthroughSpan(node.then_block, ctx) != null or
            fallthroughSpan(node.else_block.?, ctx) != null,
        .@"switch" => |node| switchMayFallThrough(node, ctx),
        else => true,
    };
}

fn switchMayFallThrough(node: ast.Switch, ctx: Context) bool {
    var has_wildcard = false;
    var has_result_ok = false;
    var has_result_err = false;
    var has_bool_true = false;
    var has_bool_false = false;
    const subject_is_result = if (exprResultType(node.subject, ctx)) |ty| classifyTypeCtx(ty, ctx) == .result else false;
    const subject_is_bool = if (exprResultType(node.subject, ctx)) |ty| classifyTypeCtx(ty, ctx) == .bool else false;
    const closed_enum = if (exprResultType(node.subject, ctx)) |ty| closedEnumInfoForType(ty, ctx) else null;
    const tagged_union = if (exprResultType(node.subject, ctx)) |ty| unionInfoForType(ty, ctx) else null;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag, .tag_bind => {
                    const tag = switch (pattern.kind) {
                        .tag => |ident| ident.text,
                        .tag_bind => |tag_bind| tag_bind.tag.text,
                        else => unreachable,
                    };
                    if (subject_is_result and std.mem.eql(u8, tag, "ok")) has_result_ok = true;
                    if (subject_is_result and std.mem.eql(u8, tag, "err")) has_result_err = true;
                },
                .literal => {
                    if (subject_is_bool) {
                        if (switchBoolLiteralValue(pattern)) |value| {
                            if (value) {
                                has_bool_true = true;
                            } else {
                                has_bool_false = true;
                            }
                        }
                    }
                },
                .bind => {},
            }
        }
        if (switchBodyMayFallThrough(arm.body, ctx)) return true;
    }
    if (closed_enum) |enum_info| {
        return !has_wildcard and !switchCoversAllEnumCases(node, enum_info);
    }
    if (tagged_union) |union_info| {
        return !has_wildcard and !switchCoversAllUnionCases(node, union_info);
    }
    if (subject_is_bool) {
        return !has_wildcard and !(has_bool_true and has_bool_false);
    }
    return !has_wildcard and !(has_result_ok and has_result_err);
}

fn switchBodyMayFallThrough(body: ast.SwitchBody, ctx: Context) bool {
    return switch (body) {
        .block => |block| fallthroughSpan(block, ctx) != null,
        .expr => |expr| exprMayFallThrough(expr, ctx),
    };
}

pub fn exprMayFallThrough(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .unreachable_expr => false,
        .grouped => |inner| exprMayFallThrough(inner.*, ctx),
        .call => |node| !isTrapCall(node.callee.*),
        .block => |block| fallthroughSpan(block, ctx) != null,
        else => true,
    };
}

fn resultLocalHasPendingValueBefore(name: []const u8, stmts: []const ast.Stmt, ctx: Context) bool {
    var pending = false;
    for (stmts) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) {
            pending = false;
            continue;
        }
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (!localDeclaresName(local, name)) continue;
                const local_ty = local.ty orelse if (local.init) |expr| exprResultType(expr, ctx) else null;
                const ty = local_ty orelse continue;
                if (classifyTypeCtx(ty, ctx) == .result and local.init != null) pending = true;
            },
            .assignment => |assignment| {
                if (!exprIsIdentNamed(assignment.target, name)) continue;
                const value_ty = exprResultType(assignment.value, ctx) orelse continue;
                pending = classifyTypeCtx(value_ty, ctx) == .result;
            },
            else => {},
        }
    }
    return pending;
}

fn assignmentResultLocalName(target: ast.Expr, ctx: Context) ?ast.Ident {
    return switch (target.kind) {
        .ident => |ident| {
            const scope = ctx.scope orelse return null;
            const binding = scope.get(ident.text) orelse return null;
            if (binding.origin != .local or !binding.mutable) return null;
            const ty = binding.ty orelse return null;
            if (classifyTypeCtx(ty, ctx) != .result) return null;
            return ident;
        },
        .grouped => |inner| assignmentResultLocalName(inner.*, ctx),
        else => null,
    };
}

fn blockContainsDeferControlFlow(block: ast.Block, ctx: Context) bool {
    for (block.items) |stmt| {
        if (stmtContainsDeferControlFlow(stmt, ctx)) return true;
    }
    return false;
}

fn stmtContainsDeferControlFlow(stmt: ast.Stmt, ctx: Context) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue" => true,
        .let_decl, .var_decl => |local| if (local.init) |expr| exprContainsDeferControlFlow(expr, ctx) else false,
        .loop => |node| (if (node.iterable) |iterable| exprContainsDeferControlFlow(iterable, ctx) else false) or
            blockContainsDeferControlFlow(node.body, ctx),
        .if_let => |node| exprContainsDeferControlFlow(node.value, ctx) or
            blockContainsDeferControlFlow(node.then_block, ctx) or
            (if (node.else_block) |else_block| blockContainsDeferControlFlow(else_block, ctx) else false),
        .@"switch" => |node| switchContainsDeferControlFlow(node, ctx),
        .unsafe_block, .comptime_block, .block => |block| blockContainsDeferControlFlow(block, ctx),
        .contract_block => |contract| blockContainsDeferControlFlow(contract.block, ctx),
        .@"defer", .expr, .assert => |expr| exprContainsDeferControlFlow(expr, ctx),
        .assignment => |node| exprContainsDeferControlFlow(node.target, ctx) or exprContainsDeferControlFlow(node.value, ctx),
        .asm_stmt => false,
    };
}

fn switchContainsDeferControlFlow(node: ast.Switch, ctx: Context) bool {
    if (exprContainsDeferControlFlow(node.subject, ctx)) return true;
    for (node.arms) |arm| {
        const body_contains_control_flow = switch (arm.body) {
            .block => |block| blockContainsDeferControlFlow(block, ctx),
            .expr => |expr| exprContainsDeferControlFlow(expr, ctx),
        };
        if (body_contains_control_flow) return true;
    }
    return false;
}

fn exprContainsDeferControlFlow(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .try_expr, .unreachable_expr => true,
        .grouped, .address_of, .deref => |inner| exprContainsDeferControlFlow(inner.*, ctx),
        .block => |block| blockContainsDeferControlFlow(block, ctx),
        .unary => |node| exprContainsDeferControlFlow(node.expr.*, ctx),
        .binary => |node| exprContainsDeferControlFlow(node.left.*, ctx) or exprContainsDeferControlFlow(node.right.*, ctx),
        .cast => |node| exprContainsDeferControlFlow(node.value.*, ctx),
        .call => |node| callContainsDeferControlFlow(node, ctx),
        .index => |node| exprContainsDeferControlFlow(node.base.*, ctx) or exprContainsDeferControlFlow(node.index.*, ctx),
        .member => |node| exprContainsDeferControlFlow(node.base.*, ctx),
        else => if (exprResultType(expr, ctx)) |ty| classifyTypeCtx(ty, ctx) == .never else false,
    };
}

fn callContainsDeferControlFlow(node: anytype, ctx: Context) bool {
    if (isTrapCall(node.callee.*)) return true;
    if (exprContainsDeferControlFlow(node.callee.*, ctx)) return true;
    for (node.args) |arg| {
        if (exprContainsDeferControlFlow(arg, ctx)) return true;
    }
    return false;
}

fn isCBackendGeneratedTopLevelValueName(name: []const u8) bool {
    return hasPrefixAndDecimalSuffix(name, "mc_tmp") or
        hasPrefixAndDecimalSuffix(name, "mc_acc") or
        hasPrefixAndDecimalSuffix(name, "mc_xs") or
        hasPrefixAndDecimalSuffix(name, "mc_i") or
        hasPrefixAndDecimalSuffix(name, "mc_a");
}

fn hasPrefixAndDecimalSuffix(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const suffix = name[prefix.len..];
    if (suffix.len == 0) return false;
    for (suffix) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isCBackendReservedHeaderName(name: []const u8) bool {
    const reserved = [_][]const u8{
        // Macros and typedefs from the headers emitted by the C prelude.
        "bool",       "true",        "false",     "NULL",       "offsetof",
        "size_t",     "ptrdiff_t",   "uintptr_t", "intptr_t",   "uint8_t",
        "uint16_t",   "uint32_t",    "uint64_t",  "int8_t",     "int16_t",
        "int32_t",    "int64_t",     "UINT8_MAX", "UINT16_MAX", "UINT32_MAX",
        "UINT64_MAX", "UINTPTR_MAX", "INT8_MIN",  "INT16_MIN",  "INT32_MIN",
        "INT64_MIN",  "INTPTR_MIN",  "INT8_MAX",  "INT16_MAX",  "INT32_MAX",
        "INT64_MAX",  "INTPTR_MAX",  "CHAR_BIT",  "MC_UNUSED",  "MC_NORETURN",
        "MC_WEAK",
    };
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}
