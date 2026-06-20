const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Span = diagnostics.Span;

pub const Ident = struct {
    text: []const u8,
    span: Span,
};

pub const Module = struct {
    decls: []Decl,
    /// Names that own a qualified namespace (`module X`, `impl X`). Resolution rewrites
    /// `X.member` to a mangled top-level symbol, so these names are reserved against local
    /// bindings — a local may not shadow them (sema enforces this).
    qualified_owners: [][]const u8 = &.{},

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
        // `#[backend_name("Y")]` — override the object/backend symbol of a declaration
        // (RSS namespace isolation: source symbol X lowers as backend symbol Y).
        backend_name: []const u8,
        // `#[origin("generated"|"copied"|...)]` — FFI/autogen boundary classification so
        // tooling can tell ported source from bound/generated/copied-runtime declarations.
        origin: []const u8,
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
    // `pub` — opt-in module visibility (§30). A file with at least one `pub` declaration
    // is "strict": only its `pub` (and `export`) items are visible to importing files;
    // the rest are file-private (E_PRIVATE_IMPORT on cross-file use). A file with no `pub`
    // declaration is unrestricted (every top-level item visible), so existing code is
    // unaffected — a module opts into the boundary by marking its public surface.
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
    abi: ?[]const u8,
    params: []Param,
    return_type: ?TypeExpr,
    body: ?Block,
    is_const: bool,
    exported: bool = false,
    // `where T: Trait, ...` bounds on the function's comptime type parameters.
    bounds: []TraitBound = &.{},
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
        @"break",
        @"continue",
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
