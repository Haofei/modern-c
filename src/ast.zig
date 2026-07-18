const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Span = diagnostics.Span;

pub const Ident = struct {
    text: []const u8,
    span: Span,
};

pub const VisibilityMode = enum {
    legacy_pub_opt_in,
    explicit_public,
};

pub const Module = struct {
    decls: []Decl,
    /// Names that own a qualified namespace (`module X`, `impl X`). Resolution rewrites
    /// `X.member` to a mangled top-level symbol, so these names are reserved against local
    /// bindings — a local may not shadow them (sema enforces this).
    qualified_owners: [][]const u8 = &.{},
    visibility_mode: VisibilityMode = .legacy_pub_opt_in,

    pub fn withDecls(self: Module, decls: []Decl) Module {
        return .{ .decls = decls, .qualified_owners = self.qualified_owners, .visibility_mode = self.visibility_mode };
    }

    /// Shallow free of the top-level `decls` slice only. The AST is built with an
    /// arena allocator that owns all nested allocations (params, bodies, block
    /// items, type exprs, …), so they are reclaimed when the arena is freed. This
    /// is NOT a recursive destructor; do not use it with a non-arena allocator.
    pub fn deinit(self: Module, allocator: std.mem.Allocator) void {
        allocator.free(self.decls);
    }
};

pub const Attr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        unsafe_contract: UnsafeContract,
        no_lang_trap,
        // `#[naked]` — emit no prologue/epilogue; the body is a single `asm` block that
        // owns the whole calling convention (reset vectors, trap stubs, trampolines).
        naked,
        // `#[noinline]` — forbid inlining the function. Needed where distinct physical
        // call frames must exist (e.g. a frame-pointer backtrace walking nested frames).
        @"noinline",
        // `#[weak]` — emit the symbol with WEAK linkage so a strong definition in another
        // compilation unit overrides it. Lets a platform runtime ship an overridable default
        // (e.g. `mc_agent_source` returning "no source" that a source-serving test replaces).
        weak,
        // `#[backend_name("Y")]` — override the object/backend symbol of a declaration
        // (RSS namespace isolation: source symbol X lowers as backend symbol Y).
        backend_name: []const u8,
        // `#[origin("generated"|"copied"|...)]` — FFI/autogen boundary classification so
        // tooling can tell ported source from bound/generated/copied-runtime declarations.
        origin: []const u8,
        // `#[section(".text.boot")]` — place the declaration's object symbol in the named
        // linker section (the `section` function attribute). Needed for bare-metal entry
        // points whose linker script pins a section to a fixed load address (e.g. the
        // OpenSBI S-mode payload `_start` at 0x80200000 via `KEEP(*(.text.boot))`).
        section: []const u8,
        // `#[align(N)]` — emit the FUNCTION with at least N-byte alignment (N a power of
        // two). Currently applies to function definitions only (global/object alignment is
        // not yet wired). Required for code whose ADDRESS is loaded into an alignment-sensitive
        // register: a RISC-V trap vector written to `stvec`/`mtvec` MUST be 4-byte aligned
        // because the low two bits of that CSR are the MODE field — a 2-byte-aligned vector
        // silently sets a reserved MODE and traps to the wrong PC. `#[naked]` functions
        // default to 4-byte alignment for this reason.
        @"align": u32,
        named: Ident,
    };
};

pub const UnsafeContract = struct {
    name: Ident,
    args: []Expr,
};

pub const Decl = struct {
    span: Span,
    attrs: []Attr,
    kind: Kind,
    // Explicit public visibility. In legacy mode, a file containing any `pub` opts into
    // private-by-default behavior. In explicit mode, every file is private by default and
    // this bit (or `export`) is the only way to expose a declaration to importers.
    is_pub: bool = false,

    pub const Kind = union(enum) {
        fn_decl: FnDecl,
        type_alias: TypeAlias,
        extern_fn: FnDecl,
        struct_decl: StructDecl,
        enum_decl: EnumDecl,
        union_decl: UnionDecl,
        packed_bits_decl: PackedBitsDecl,
        overlay_union_decl: OverlayUnionDecl,
        opaque_decl: Ident,
        global_decl: GlobalDecl,
        // `trait Name { fn sig(...) -> R; ... }` — a set of method signatures (Tier 1).
        trait_decl: TraitDecl,
        // `impl Trait for Type { ... }` — a conformance record. The methods themselves
        // are desugared to free functions `Type__m` (like an inherent impl); this node
        // carries the (Trait, Type) pair plus the provided method names for sema's
        // conformance / coherence / orphan checks.
        impl_trait: ImplTrait,
    };
};

// One trait-method signature (no body).
pub const TraitMethodSig = struct {
    name: Ident,
    params: []Param,
    return_type: ?TypeExpr,
    self_mode: SelfMode,
    // The annotated effect attributes on the signature (e.g. `#[may_sleep]`),
    // carried so conformance can require each impl method to match.
    attrs: []Attr = &.{},
};

pub const TraitDecl = struct {
    name: Ident,
    methods: []TraitMethodSig,
};

// A method provided by an `impl Trait for Type` block: the trait-relative name and
// the mangled free-function it desugared to (`Type__m`).
pub const ImplTraitMethod = struct {
    name: Ident,
    mangled: []const u8,
    self_mode: SelfMode,
    attrs: []Attr = &.{},
    // The impl method's full parameter list and return type (from the desugared
    // free function), carried so conformance can verify FULL-signature equality
    // against the trait method (arity + each param type + return type), not just
    // name + self-mode. Without this a wrong-arity/wrong-type impl is accepted and
    // a `*dyn` vtable call becomes a wild/UB indirect call (the cast erases it).
    params: []Param = &.{},
    return_type: ?TypeExpr = null,
};

// The `self` parameter form of a (trait or impl) method.
pub const SelfMode = enum {
    none, // no self parameter
    by_ptr, // self: *Self
    by_mut_ptr, // self: *mut Self
    by_value, // self: Self
    move_self, // move self
};

pub const ImplTrait = struct {
    trait_name: Ident,
    type_name: Ident,
    methods: []ImplTraitMethod,
};

// `where T: TraitA, U: TraitB` — a bound on a `comptime T: type` generic parameter.
pub const TraitBound = struct {
    type_param: Ident,
    trait_name: Ident,
};

pub const FnDecl = struct {
    name: Ident,
    // Exact source owner for a function declared in `impl Owner`. This semantic
    // relationship survives mangling and monomorphization; access checks must not
    // reconstruct it from `name`.
    associated_owner: ?Ident = null,
    abi: ?[]const u8,
    params: []Param,
    return_type: ?TypeExpr,
    body: ?Block,
    is_const: bool,
    exported: bool = false,
    // C-ABI variadic: the parameter list ended with `...` (after the named params).
    // Only meaningful for the C interop boundary (printf-family shims for QuickJS);
    // the body reads the extra args via the `va.*` intrinsics. Mirrors C `...`.
    is_variadic: bool = false,
    // `where T: Trait, ...` bounds on the function's comptime type parameters.
    bounds: []TraitBound = &.{},
    // `async fn …` — a stackless async function (async/await roadmap Phase D). A pre-sema
    // transform (src/async_lower.zig) rewrites every `is_async` fn into a Future state machine
    // (a struct + `impl Future` poll + `_take_result` + constructor), so no `is_async` fn nor
    // `await_expr` survives to sema/backends. v0: straight-line awaits only.
    is_async: bool = false,
};

pub const Param = struct {
    name: Ident,
    ty: TypeExpr,
    // A `comptime NAME: T` parameter (section 22): its argument must be a
    // compile-time constant, evaluated when the call's comptime asserts are
    // checked.
    is_comptime: bool = false,
};

pub const TypeAlias = struct {
    name: Ident,
    ty: TypeExpr,
};

pub const StructDecl = struct {
    name: Ident,
    // Stable source identity retained when a generic struct is specialized and
    // its emitted name changes. Null on legacy/generated nodes means `name`.
    semantic_identity: ?Ident = null,
    abi: ?[]const u8,
    fields: []Field,
    // Type parameters for a generic struct `struct Name<T, …>` (section 22);
    // empty for an ordinary struct.
    type_params: []Ident = &.{},
    // `move struct …` — a linear resource type (section 18.1): its values are
    // used linearly (moved/consumed exactly once), not copied.
    is_move: bool = false,
    // `opaque struct …` — the fields are private to the struct's associated
    // functions (`impl Name { … }`). Outside code may hold and pass a value but
    // may not name its fields in a struct literal or `.field` access, so the
    // value cannot be forged or inspected — constructor-only handle capabilities.
    is_opaque: bool = false,
    // `#[c_union]` — a compiler-internal *addressable, runtime-selected union*. Laid out
    // as a real C `union` (all fields at offset 0; size = largest field, align = max),
    // so `&value.field` is a stable, in-place, alias-safe pointer to the shared storage
    // reinterpreted as that field's type (member access is the canonical strict-aliasing
    // exception in C). Distinct from `overlay union` (a `storage[]` byte-blob accessed by
    // value memcpy, no member address) and from a tagged union (pattern-access only). The
    // active arm is selected at runtime by the surrounding code (e.g. the async state
    // machine's `state`); only one arm is live at a time. Field TYPING is identical to a
    // struct — the sole difference is the union layout and the emitted aggregate keyword.
    is_c_union: bool = false,
};

pub const PackedBitsDecl = struct {
    name: Ident,
    repr: TypeExpr,
    fields: []Field,
};

pub const OverlayUnionDecl = struct {
    name: Ident,
    fields: []Field,
};

pub const GlobalDecl = struct {
    name: Ident,
    ty: ?TypeExpr,
    init: ?Expr,
    // A `const NAME: T = <comptime constant>` declaration: a named compile-time
    // constant (section 22), usable in array lengths and comptime asserts.
    is_const: bool = false,
    // `export global NAME: T = ...` — a data symbol with EXTERNAL linkage, visible to
    // other compilation units (e.g. a platform runtime providing `stdout`/`stderr` data
    // symbols a vendored C engine links against). Plain `global` stays module-private.
    exported: bool = false,
    // `extern global NAME: T;` — a DECLARATION (no storage) of a data symbol defined in
    // another compilation unit (e.g. a harness-generated `app_image[]` blob). Read it, or
    // take its address, like any global; the linker binds it to the real definition.
    is_extern: bool = false,
};

pub const EnumDecl = struct {
    name: Ident,
    repr: ?TypeExpr,
    cases: []EnumCase,
    is_open: bool,
};

pub const EnumCase = struct {
    name: Ident,
    value: ?Expr,
};

pub const UnionDecl = struct {
    name: Ident,
    cases: []UnionCase,
    // Type parameters for a generic tagged union `union Name<T, …>` (section 22),
    // parallel to `StructDecl.type_params`; empty for an ordinary tagged union. A
    // generic union is a template: each concrete use `Name<u32>` monomorphizes to a
    // distinct non-generic tagged union (`Name__u32`) before sema/lowering.
    type_params: []Ident = &.{},
};

pub const UnionCase = struct {
    name: Ident,
    ty: ?TypeExpr,
};

pub const Field = struct {
    name: Ident,
    ty: TypeExpr,
    // Explicit byte offset from `@offset(N)` (MMIO register maps); null = packed
    // after the previous field.
    offset: ?u64 = null,
};

pub const Mutability = enum {
    none,
    mut,
    @"const",
};

pub const TypeExpr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        name: Ident,
        enum_literal: Ident,
        member: struct {
            base: *TypeExpr,
            field: Ident,
        },
        nullable: *TypeExpr,
        qualified: struct {
            mutability: Mutability,
            child: *TypeExpr,
        },
        pointer: struct {
            mutability: Mutability,
            child: *TypeExpr,
        },
        raw_many_pointer: struct {
            mutability: Mutability,
            child: *TypeExpr,
        },
        slice: struct {
            mutability: Mutability,
            child: *TypeExpr,
        },
        array: struct {
            len: Expr,
            child: *TypeExpr,
        },
        generic: struct {
            base: Ident,
            args: []TypeExpr,
        },
        // A function-pointer type: `fn(P0, P1) -> R`. Lowers to a C function
        // pointer; the value side is a top-level function's name.
        fn_pointer: struct {
            params: []TypeExpr,
            ret: *TypeExpr,
        },
        // A closure type: `closure(P0, P1) -> R`. A capturing function value —
        // lowers to a `{ code, env }` fat pointer (the env is a type-erased pointer
        // to a captured object). Built with `bind(&obj, fn(*E, P...) -> R)`.
        closure_type: struct {
            params: []TypeExpr,
            ret: *TypeExpr,
        },
        // A trait object pointer `*dyn Trait` / `*mut dyn Trait` (traits-design §4).
        // The whole `*dyn` is one fat pointer `{ data, vtable }` — the leading `*`
        // is folded into this node (mutability records `*` vs `*mut`). It lowers,
        // like a closure, to a two-word `{ ptr, ptr }` value; dispatch loads the
        // method pointer out of the rodata vtable and calls it with `data` first.
        dyn_trait: struct {
            mutability: Mutability,
            trait_name: Ident,
        },
    };
};

pub const Block = struct {
    span: Span,
    items: []Stmt,
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        let_decl: LocalDecl,
        var_decl: LocalDecl,
        loop: Loop,
        if_let: IfLet,
        @"switch": Switch,
        unsafe_block: Block,
        comptime_block: Block,
        contract_block: ContractBlock,
        asm_stmt: AsmStmt,
        block: Block,
        @"return": ?Expr,
        // Optional loop label targets a named enclosing loop (G7 labeled
        // break/continue). Null means the innermost loop (unchanged behavior).
        @"break": ?Ident,
        @"continue": ?Ident,
        @"defer": Expr,
        assert: Expr,
        assignment: struct {
            target: Expr,
            value: Expr,
        },
        expr: Expr,
    };
};

pub const AsmStmt = struct {
    form: AsmForm,
    is_volatile: bool,
    templates: []const []const u8,
    clobbers: []const []const u8,
    /// Precise-asm output operands (`out("reg") name: T`). Empty for opaque asm.
    outputs: []const AsmOutput = &.{},
    /// Precise-asm input operands (`in("reg") expr: T`). Empty for opaque asm.
    inputs: []const AsmInput = &.{},
};

/// Precise-asm output: a register-constraint string, the assignable local that
/// receives the result, and its type. The constraint string lexeme keeps its
/// surrounding quotes (e.g. `"rax"`), matching how clobbers are stored.
pub const AsmOutput = struct {
    reg: []const u8,
    name: Ident,
    ty: TypeExpr,
};

/// Precise-asm input: a register-constraint string, the value expression fed in,
/// and its type.
pub const AsmInput = struct {
    reg: []const u8,
    value: Expr,
    ty: TypeExpr,
};

pub const AsmForm = enum {
    @"opaque",
    precise,
};

pub const LocalDecl = struct {
    names: []Ident,
    ty: ?TypeExpr,
    init: ?Expr,
};

pub const Loop = struct {
    kind: Kind,
    label: ?Ident,
    // G7: optional loop label naming this loop as a break/continue target
    // (`outer: while ...`). Distinct from `label`, which is the for-binding.
    loop_label: ?Ident = null,
    iterable: ?Expr,
    body: Block,

    pub const Kind = enum {
        @"for",
        @"while",
    };
};

pub const IfLet = struct {
    pattern: Pattern,
    value: Expr,
    then_block: Block,
    else_block: ?Block,
};

pub const Switch = struct {
    subject: Expr,
    arms: []SwitchArm,
};

pub const SwitchArm = struct {
    patterns: []Pattern,
    body: SwitchBody,
    // Set by the async lowering (src/async_lower.zig) on a single bare-`.bind` arm whose bound name
    // shadows an enclosing local that the lowering lifted to a future-struct field (so sema, checking
    // the generated poll fn, can no longer see the source collision). Binding-ness is TYPE-DEPENDENT —
    // a bare `.bind` binds only for a nullable subject — so the lowering cannot decide pre-sema whether
    // the collision is real. When this is set and sema DOES bind the arm (nullable subject, resolved
    // type), it reports E_DUPLICATE_LOCAL — recovering exact non-async parity for any subject shape
    // (param/local/call/member/...) without the lowering re-deriving the type. Default false; untouched
    // for non-async code and compiler-synthesized arms.
    dup_local_if_binds: bool = false,
};

pub const SwitchBody = union(enum) {
    block: Block,
    expr: Expr,
};

pub const ContractBlock = struct {
    attr: Attr,
    block: Block,
};

pub const Pattern = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        wildcard,
        bind: Ident,
        tag: Ident,
        tag_bind: struct {
            tag: Ident,
            binding: Ident,
        },
        literal: Expr,
    };
};

pub const StructLiteralField = struct {
    name: Ident,
    value: Expr,
};

pub const Expr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        ident: Ident,
        int_literal: []const u8,
        float_literal: []const u8,
        string_literal: []const u8,
        char_literal: []const u8,
        bool_literal: bool,
        null_literal,
        uninit_literal,
        unreachable_expr,
        void_literal,
        enum_literal: Ident,
        array_literal: []Expr,
        struct_literal: []StructLiteralField,
        grouped: *Expr,
        block: Block,
        unary: struct {
            op: UnaryOp,
            expr: *Expr,
        },
        binary: struct {
            op: BinaryOp,
            left: *Expr,
            right: *Expr,
        },
        cast: struct {
            value: *Expr,
            ty: *TypeExpr,
        },
        address_of: *Expr,
        call: struct {
            callee: *Expr,
            type_args: []TypeExpr,
            args: []Expr,
        },
        index: struct {
            base: *Expr,
            index: *Expr,
        },
        slice: struct {
            base: *Expr,
            start: *Expr,
            end: *Expr,
        },
        deref: *Expr,
        member: struct {
            base: *Expr,
            name: Ident,
        },
        // `EXPR?` (propagate the error as-is) or `EXPR? else MAPPED` (remap the error to
        // `MAPPED`, of the enclosing function's error type, before propagating).
        try_expr: struct {
            operand: *Expr,
            mapped: ?*Expr = null,
        },
        // `await EXPR` — a suspend point inside an `async fn` (async/await roadmap Phase D).
        // The pre-sema async transform (src/async_lower.zig) eliminates every `await_expr`;
        // it must never reach sema or a backend. Post-transform switches treat it as an error.
        await_expr: *Expr,
    };
};

pub const UnaryOp = enum {
    neg,
    bit_not,
    logical_not,
};

pub const BinaryOp = enum {
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

pub fn makePtr(allocator: std.mem.Allocator, value: anytype) !*@TypeOf(value) {
    const ptr = try allocator.create(@TypeOf(value));
    ptr.* = value;
    return ptr;
}
