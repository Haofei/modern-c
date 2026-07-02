// selfhost/parser — mcc2's PARSER + AST, ported from the Zig reference (src/parser.zig +
// src/ast.zig) as Phase 2 of the self-hosting plan (docs/self-host-plan.md). It builds on
// the Phase-1 lexer (selfhost/lexer.mc) and parses a bounded SUBSET of MC good enough to
// later self-compile a subset: `fn` decls with params + a body of `let`/`return`/`if`-`else`/
// `while`/expr statements, and full-precedence expressions (call/index/field postfix, unary
// `-`/`!`, and the binary tower `|| && ==/!=/</>/<=/>= + - * / %`).
//
// DESIGN (a flat INDEX-ARENA AST, mirroring Zig's own compiler `Ast`, NOT a pointer tree):
//   * Every node is a plain COPYABLE `Node { kind, main_token, lhs, rhs }` stored in a
//     `Vec<Node>`. Children are u32 INDICES into that same vec, never pointers — so the whole
//     tree is one growable array with no per-node allocation and no ownership tangle. (This is
//     exactly why `Vec<struct>` had to work first — self-host gap ledger G19.)
//   * `main_token` indexes the lexer's flat token stream (`TokenList`); a node's source text is
//     recovered as `source[tok.start .. tok.start+tok.len]`. lhs/rhs are child node indices or
//     small inline payloads (e.g. a pointer-mutability flag), 0 meaning "none".
//   * VARIABLE-LENGTH children (a module's decls, a block's stmts, a fn's params, a call's args)
//     live in a side `Vec<u32>` "extra" array as a LENGTH-PREFIXED run: a node stores the run's
//     start index, and `extra[start]` is the element count, followed by that many node indices.
//     Fixed multi-field records (fn_decl, if_stmt) are stored the same way as a small fixed run.
//   * Node index 0 is a reserved `.invalid` SENTINEL (so an lhs/rhs of 0 reads as "none"); real
//     nodes start at 1.
//
// ERRORS are kept minimal (per the plan): no `?T` value-optionals (gap G11) and no `try` sugar
// for user errors, so the parser carries a plain `err_count` + `first_err_tok` and returns the
// `.invalid` sentinel (index 0) on a failed production. A no-progress guard in each list loop
// guarantees termination on malformed input.

import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/collections/dynarray.mc";
import "selfhost/lexer.mc";

// The AST node tag. `open enum ... : u32` (like `TokKind`) so the gate can read ordinals via
// `.raw()` (closed enums reject `.raw()` and integer casts — gap G21). The ordinals below are
// the contract the selfhost-parse-test C driver asserts against; keep this order stable.
open enum NodeKind: u32 {
    invalid,          // 0  reserved sentinel at node index 0 ("none")
    module,           // 1  lhs = extra run of decl node indices
    fn_decl,          // 2  main_token = name; lhs = fixed run [exported, params_run, ret_type, body]
    param_decl,       // 3  main_token = name; lhs = type node
    type_name,        // 4  main_token = type-name ident
    type_ptr,         // 5  lhs = pointee node; rhs = 1 if `*mut` else 0
    type_slice_const, // 6  `[]const T`; lhs = element type node
    type_slice_mut,   // 7  `[]mut T`;   lhs = element type node
    block,            // 8  lhs = extra run of stmt node indices
    let_decl,         // 9  main_token = name; lhs = type node (0 = inferred); rhs = init expr
    return_stmt,      // 10 main_token = `return`; lhs = value expr (0 = bare return)
    if_stmt,          // 11 main_token = `if`; lhs = cond; rhs = fixed run [then_block, else(0=none)]
    while_stmt,       // 12 main_token = `while`; lhs = cond; rhs = body block
    expr_stmt,        // 13 lhs = expr
    assign,           // 14 main_token = `=`; lhs = target; rhs = value
    int_literal,      // 15 main_token = integer token
    ident_expr,       // 16 main_token = identifier token
    call,             // 17 lhs = callee; rhs = extra run of arg node indices
    index,            // 18 main_token = `[`; lhs = base; rhs = index expr
    field,            // 19 main_token = field-name ident; lhs = base
    un_neg,           // 20 main_token = `-`; lhs = operand
    un_not,           // 21 main_token = `!`; lhs = operand
    bin_lor,          // 22 `||`
    bin_land,         // 23 `&&`
    bin_eq,           // 24 `==`
    bin_ne,           // 25 `!=`
    bin_lt,           // 26 `<`
    bin_gt,           // 27 `>`
    bin_le,           // 28 `<=`
    bin_ge,           // 29 `>=`
    bin_add,          // 30 `+`
    bin_sub,          // 31 `-`
    bin_mul,          // 32 `*`
    bin_div,          // 33 `/`
    bin_mod,          // 34 `%`
    // ----- P5.1 struct-support additions (appended to keep ordinals 0..34 stable for the gate) -----
    struct_decl,      // 35 main_token = name; lhs = fields run [count, (name_tok, type_node)*]; rhs = exported
    var_decl,         // 36 mutable local: main_token = name; lhs = type node (0 = inferred); rhs = init expr
    struct_lit,       // 37 `.{ .f = e, ... }`: main_token = leading `.`; lhs = fields run [count, (name_tok, val_node)*]
    // ----- P5.2 enum-support additions (appended to keep prior ordinals stable) -----
    enum_decl,        // 38 main_token = name; lhs = fixed rec [exported, is_open, repr_type(0=none), variants_run]
    enum_lit,         // 39 `.variant` primary: main_token = the variant ident (no operand)
    // ----- P5.3 switch-statement additions (appended to keep prior ordinals stable) -----
    switch_stmt,      // 40 main_token = `switch`; lhs = subject expr; rhs = arms run [count, (pat_tok, block)*]
    // ----- P5.4 multi-module import additions (appended to keep prior ordinals stable) -----
    import_decl,      // 41 `import "path";` directive; main_token = the path string-literal token.
                      //    A NO-OP for sema/emit: the imported file's decls are supplied by the
                      //    loader (selfhost/main.mc), which flattens all modules into one source by
                      //    textual concatenation, so nothing needs type-checking or emitting here.
    // ----- P5.5 generics (monomorphized) additions (appended to keep prior ordinals stable) -----
    type_generic,     // 42 `S<T>` in type position: main_token = base-name ident; lhs = single
                      //    type-arg node (ONE type param in the subset — nested/multi is deferred).
    type_kw,          // 43 the `type` keyword as a type (a `comptime T: type` param's annotation).
    struct_gdecl,     // 44 generic struct decl `struct S<T> { ... }`: main_token = name; lhs = fixed
                      //    rec [tparam_tok, fields_run, exported]. Fields run is as `struct_decl`.
                      //    (A generic FUNCTION reuses `fn_decl`: its type param is a leading
                      //    `comptime T: type` param — a `param_decl` whose lhs is a `type_kw` node
                      //    and whose rhs = 1 marks it comptime.)
    // ----- P5.6 fixed-size array additions (appended to keep prior ordinals stable) -----
    type_array,       // 45 `[N]T` fixed array TYPE: main_token = the integer-literal token N (a const
                      //    length in the subset — a `comptime N` size param is deferred); lhs = the
                      //    element type node. (Multi-dim `[N][M]T` nests via the element being another
                      //    `type_array`, but sema only fully types one level — see the ledger.)
    array_lit,        // 46 `.{ e0, e1, ... }` positional array literal: main_token = leading `.`; lhs =
                      //    extra run of element expr node indices. Distinct from `struct_lit` (whose
                      //    elements are `.field = e`); disambiguated by a `.ident =` lookahead.
    // ----- P5.7 slice (fat-pointer) additions (appended to keep prior ordinals stable) -----
    slice_range,      // 47 sub-slice `base[start..end]`: main_token = `[`; lhs = base; rhs = a fixed
                      //    2-slot extra record [start_expr, end_expr] (NOT length-prefixed — read
                      //    directly at rhs+0 / rhs+1, like the `if_stmt` then/else record).
    un_addr,          // 48 address-of `&expr`: main_token = `&`; lhs = operand. Used by the
                      //    `mem.as_bytes(&arr)` slice builtin (and general pointer taking).
    // ----- P5.8 low-level layer additions (appended to keep prior ordinals stable) -----
    unsafe_block,     // 49 `unsafe { <stmts> }`: main_token = `unsafe`; lhs = the inner block node.
                      //    A pure wrapper — C has no `unsafe`, so emit lowers it to a plain `{ ... }`.
    raw_op,           // 50 a `raw.ptr<T>(e)` / `raw.load<T>(e)` / `raw.store<T>(e, v)` intrinsic call:
                      //    main_token = the member ident (`ptr`/`load`/`store`, distinguishing the op);
                      //    lhs = the `<T>` type-arg node; rhs = a fixed 2-slot extra record [arg0, arg1]
                      //    (arg1 = 0 for the single-arg `ptr`/`load`; the value operand for `store`).
    deref,            // 51 pointer deref `p.*` (read or assign target): main_token = the `*` token;
                      //    lhs = the pointer operand. Emits `(*(p))`.
    extern_fn,        // 52 `extern "C" fn NAME(params) -> RET;`: main_token = name; lhs = a fixed
                      //    record [params_run, ret_type]. No body — a callable prototype only.
    // ----- P5.9 casts + sizeof/alignof additions (appended to keep prior ordinals stable) -----
    cast,             // 53 `expr as TYPE`: main_token = the `as` ident token; lhs = operand expr;
                      //    rhs = target type node. Binds TIGHTER than any binary op but looser than
                      //    postfix/unary — recognized in the infix position by the `as` identifier
                      //    lexeme (`as` is NOT a keyword), mirroring src/parser.zig. Emits
                      //    `((<ctype>)(operand))`; types as its target type.
    sizeof_op,        // 54 `sizeof(TYPE)`: main_token = the `sizeof` keyword; lhs = the TYPE node
                      //    (the subset's `sizeof` takes a type, not an expr). Emits `sizeof(<ctype>)`;
                      //    types as `usize`. A generic type param T is substituted at emit (P5.5).
    alignof_op,       // 55 `alignof(TYPE)`: main_token = the `alignof` keyword; lhs = the TYPE node.
                      //    Emits `_Alignof(<ctype>)`; types as `usize`.
    // ----- P5.10 traits + `*dyn` dynamic dispatch additions (appended to keep prior ordinals stable) -----
    trait_decl,       // 56 `trait NAME { fn m(self: *mut Self, ..) -> R; .. }`: main_token = the trait
                      //    name; lhs = a length-prefixed run of `trait_method` node indices. Emits a
                      //    `NAME__vtable` fn-pointer typedef + a `NAME__dyn` {data,vtable} fat-pointer typedef.
    trait_method,     // 57 one bodyless trait-method signature: main_token = method name; lhs = params
                      //    run (its first param is `self`); rhs = the return-type node.
    impl_decl,        // 58 `impl TRAIT for TYPE { fn m(self: *mut TYPE, ..) -> R { body } .. }`:
                      //    main_token = the TRAIT name; lhs = a fixed rec [type_name_tok, methods_run]
                      //    where methods_run is a length-prefixed run of `fn_decl` node indices. Each
                      //    method is emitted as a free fn `TYPE__m`, plus a `void*`-self thunk and a
                      //    `static const TYPE__TRAIT__vtable` rodata vtable.
    type_dyn,         // 59 `*mut dyn NAME` / `*dyn NAME` TYPE (a trait-object fat pointer): main_token =
                      //    the trait NAME token; rhs = 1 if `*mut` else 0. The leading `*`/`*mut` is
                      //    consumed into this node (the fat pointer struct `NAME__dyn` IS the value),
                      //    so it carries no separate pointer wrapper.
    // ----- infix bitwise/shift + `unreachable` additions (appended to keep prior ordinals stable) -----
    // These are NOT contiguous with the 22..34 binary tower (bin_lor..bin_mod); emit's `e_is_binop`
    // special-cases this second range (60..64). Precedence mirrors src/parser.zig's `infix` table
    // (bit-or 9/10, xor 11/12, bit-and 13/14, shifts 15/16 — all between comparison 7/8 and add 17/18).
    bin_bor,          // 60 `|`  bitwise OR
    bin_bxor,         // 61 `^`  bitwise XOR
    bin_band,         // 62 `&`  bitwise AND (INFIX only; PREFIX `&x` is `un_addr`, disambiguated by
                      //    parse position — the unary form is handled in parse_prefix before the
                      //    binary loop ever consults the infix table).
    bin_shl,          // 63 `<<` left shift
    bin_shr,          // 64 `>>` right shift
    unreachable_stmt, // 65 `unreachable;` — a diverging terminator statement (no fall-through). Emits
                      //    the real backend's `mc_trap_Unreachable();` (a NORETURN `__builtin_trap`).
    // ----- bool-literal addition (appended to keep prior ordinals stable) -----
    bool_literal,     // 66 `true` / `false` primary: main_token = the `kw_true`/`kw_false` token. Types
                      //    as `bool`; emits the C `true`/`false` (stdbool.h is in the prelude).
    // ----- value-optional `?T` additions (G11 mirrored inside mcc2's subset) — appended to keep
    // prior ordinals stable. A `?T` for a scalar payload T lowers to a tagged `{present, value}`
    // struct `mc_opt_<T>` (matching the real backend's mc_opt_<T> / isValueOptionalPayloadClass).
    type_optional,    // 67 `?T` value-optional TYPE: lhs = the payload type node. Scalar payloads only
                      //    in the subset (aggregate/slice payloads deferred — see the ledger).
    null_literal,     // 68 `null` primary: main_token = the `null` keyword token. No operand. Coerces
                      //    to any `?T` as the ABSENT value; only valid where an optional target is known.
    if_let_stmt,      // 69 `if let NAME = EXPR { .. } (else ..)?`: main_token = the binding NAME token;
                      //    lhs = the optional-typed EXPR; rhs = a fixed 2-slot rec [then_block,
                      //    else(0=none)] (like `if_stmt`). Narrows EXPR to its payload, binding NAME.
    break_stmt,       // 70 `break;` loop terminator (no operand). Emits the C `break;`.
    continue_stmt,    // 71 `continue;` loop continuation (no operand). Emits the C `continue;`.
    // ----- `Result<T,E>` + `?` error-propagation additions (appended to keep prior ordinals stable).
    // Result is the real backend's builtin two-arm tagged type: a `{ bool is_ok; union { T ok; E err; }
    // payload; }` struct (src/lower_c_defs.zig `emitResultType`). `ok(x)`/`err(x)` are parsed as plain
    // `call` nodes (callee ident `ok`/`err`, one arg) and lowered specially by sema/emit against the
    // target Result type — no dedicated ctor node is needed (like `phys(x)` / `.variant`).
    type_result,        // 72 `Result<T, E>` TYPE: main_token = the `Result` name; lhs = ok type node;
                        //    rhs = err type node.
    try_op,             // 73 postfix `expr?` error propagation: main_token = the `?` token; lhs = the
                        //    Result-typed operand. Lowers to a statement-expression that returns the
                        //    enclosing fn's `err(..)` on the error arm, else yields the ok payload.
    result_switch_stmt, // 74 `switch r { ok(v) => {..}, err(e) => {..} }`: main_token = `switch`; lhs =
                        //    subject; rhs = arms run of TRIPLES [count, (tag_tok, bind_tok, block)*] where
                        //    tag_tok is the `ok`/`err` ident and bind_tok is the payload binding.
    if_let_result_stmt, // 75 `if let ok(v) = EXPR { .. } (else ..)?` / `if let err(e) = EXPR { .. }`:
                        //    main_token = the binding NAME token; lhs = the Result EXPR; rhs = a fixed
                        //    3-slot rec [tag_tok, then_block, else(0=none)].
    // ----- char-literal + module-const additions (appended to keep prior ordinals stable) -----
    char_literal,       // 76 `'a'` / `'\n'` / `'\\'` etc. primary: main_token = the char-literal token.
                        //    Types as `u8`; emits the source lexeme verbatim (a valid C char literal —
                        //    MC's escapes `\n \t \r \0 \\ \' \"` are all valid C escapes too).
    const_decl,         // 77 module-level `const NAME: T = <const-expr>;` (and `export const`):
                        //    main_token = the NAME token; lhs = the declared TYPE node; rhs = the
                        //    initializer expr. Emits a file-scope `static const T NAME = <value>;`
                        //    (correct in the subset's single-TU concat model). Registered as a global
                        //    so uses of NAME resolve to type T.
    uninit_literal,     // 78 the `uninit` primary (an explicitly-uninitialized value). main_token =
                        //    the `uninit` keyword token. Valid only as a `let`/`var` initializer of a
                        //    known type; emit drops the initializer (`T name;`), matching C.
    string_literal,     // 79 a `"..."` byte-string literal. main_token = the string token. Types as
                        //    `[]const u8` (a byte slice), matching the real backend. Emits the fat-
                        //    pointer slice value `((mc_slice_const_u8){ .ptr = (const uint8_t*)"..",
                        //    .len = N })` where N is the decoded byte count (escapes count as 1).
}

// A flat AST node: `main_token` indexes the token stream; `lhs`/`rhs` are child node indices
// or small inline payloads (0 = none) per the per-kind contract documented on `NodeKind`.
struct Node {
    kind: NodeKind,
    main_token: u32,
    lhs: u32,
    rhs: u32,
}

// The parser + arena. `tl`/`source` are the lexed input; `tok` is the current token index;
// `nodes`/`extra` are the flat AST (see the file header). `a` is the backing allocator, held
// so the list-building temporaries can allocate. Diagnostics are `err_count` + `first_err_tok`.
struct Parser {
    tl: TokenList,
    source: []const u8,
    tok: usize,
    nodes: Vec<Node>,
    extra: Vec<u32>,
    a: *mut dyn Allocator,
    root: u32,
    err_count: u32,
    first_err_tok: u32,
    // P5.5 emit-time monomorphization scratch (set/cleared by selfhost/emit_c.mc while emitting a
    // generic template's monomorphic copy): when `sub_concrete` != 0, a `type_name` whose lexeme is
    // `source[sub_name_start .. sub_name_start+sub_name_len]` (the type param, e.g. `T`) is emitted
    // as the concrete type node `sub_concrete` instead. Not used by parse/sema; 0 means inactive.
    sub_name_start: usize,
    sub_name_len: usize,
    sub_concrete: u32,
    // Generic-close `>>` split state (mirrors src/parser.zig consumeGenericClose): a nested generic
    // like `Entry<V>>` / `raw.ptr<Entry<V>>` lexes its trailing `>>` as ONE `.shift_right` token. When
    // an inner generic-close sees that token it consumes only the first `>` and sets `pending_gt`,
    // leaving a synthetic `>` for the enclosing close (which then advances past the token). Only ever
    // set/read by `consume_generic_close`, and only between two adjacent closes (no interleaved reads).
    pending_gt: bool,
    // P5.7 emit-time scratch: the fn decl node currently being emitted, so a slice-aware access
    // (`s.ptr[i]` / sub-slice) can resolve a base identifier's declared type (param or local) by
    // scanning this function. 0 while not emitting a function body. Not used by parse/sema.
    cur_fn: u32,
}

// Prefix-operator operand binding power: above every binary `left_bp` (max 19, `* / %`) so a
// prefix operand never absorbs a trailing binary operator — `-a * b` is `(-a) * b`, per C.
const PREFIX_OPERAND_BP: u32 = 21;

// The result of a binary-operator lookup (no `?T` value-optionals — gap G11 — so "not an infix
// operator" is a `present = false` struct instead of a null). `lbp`/`rbp` are the left/right
// binding powers (odd/even to encode left-associativity); `kind` is the node kind to build.
struct OpInfo {
    present: bool,
    lbp: u32,
    rbp: u32,
    kind: NodeKind,
}

// ----- token cursor primitives -----

// The kind ordinal of the current token, or `.eof`'s ordinal (0) past the end.
fn cur(p: *mut Parser) -> u32 {
    let n: usize = token_count(&p.tl);
    if p.tok >= n {
        return 0; // eof
    }
    return token_kind_at(&p.tl, p.tok);
}

// The kind ordinal of the token `off` positions ahead of the cursor, or eof (0) past the end.
fn peek_kind(p: *mut Parser, off: usize) -> u32 {
    let n: usize = token_count(&p.tl);
    let i: usize = p.tok + off;
    if i >= n {
        return 0; // eof
    }
    return token_kind_at(&p.tl, i);
}

// True when the token `off` positions ahead of the cursor has kind `k` (a bounded lookahead used
// to disambiguate a struct literal `.{` from postfix member access). `k.raw()` is bound to a local
// first, mirroring `at` (a bare `call() == call()` return can't recover its operand type — G23).
fn at_next(p: *mut Parser, off: usize, k: TokKind) -> bool {
    let c: u32 = peek_kind(p, off);
    let want: u32 = k.raw();
    return c == want;
}

// True when the current token has kind `k`.
fn at(p: *mut Parser, k: TokKind) -> bool {
    // Bind both operands to locals first: the C backend's sequenced-comparison return path
    // can't recover the operand type of a bare `call() == call()` and bails (UnsupportedCEmission).
    let c: u32 = cur(p);
    let want: u32 = k.raw();
    return c == want;
}

// Advance one token (saturating at the end so the cursor never runs off the stream).
fn p_advance(p: *mut Parser) -> void {
    let n: usize = token_count(&p.tl);
    if p.tok < n {
        p.tok = p.tok + 1;
    }
}

// If the current token is `k`, consume it and return true; otherwise leave the cursor put.
fn eat(p: *mut Parser, k: TokKind) -> bool {
    if at(p, k) {
        p_advance(p);
        return true;
    }
    return false;
}

// Record a parse error at the current token (first error's token is remembered for diagnostics).
fn record_error(p: *mut Parser) -> void {
    if p.err_count == 0 {
        p.first_err_tok = p.tok as u32;
    }
    p.err_count = p.err_count + 1;
}

// Consume `k` or record an error (best-effort recovery: the cursor is left in place so the
// caller's no-progress guard can still make forward progress).
fn expect(p: *mut Parser, k: TokKind) -> bool {
    if at(p, k) {
        p_advance(p);
        return true;
    }
    record_error(p);
    return false;
}

// Close a generic / type-argument list, splitting a `>>` (`.shift_right`) token into two `>` so a
// nested generic like `Entry<V>>` / `raw.ptr<Entry<V>>` parses (mirrors src/parser.zig
// consumeGenericClose). Consumes exactly one `>`. On a `>>` it consumes the first `>` and leaves a
// synthetic `>` (via `pending_gt`) for the enclosing close to consume.
fn consume_generic_close(p: *mut Parser) -> void {
    if p.pending_gt {
        p.pending_gt = false;
        p_advance(p); // consume the second `>` of the split `>>`, moving past the shift_right token
        return;
    }
    if at(p, .greater) {
        p_advance(p);
        return;
    }
    if at(p, .shift_right) {
        p.pending_gt = true; // consumed the first `>`; leave a synthetic `>` for the outer close
        return;
    }
    record_error(p);
}

// ----- arena builders -----

// Append a node and return its index.
fn add_node(p: *mut Parser, kind: NodeKind, main_tok: u32, lhs: u32, rhs: u32) -> u32 {
    let idx: u32 = vec_len(Node, &p.nodes) as u32;
    vec_push(Node, &p.nodes, .{ .kind = kind, .main_token = main_tok, .lhs = lhs, .rhs = rhs });
    return idx;
}

// Flush a temporary list of child indices into `extra` as a length-prefixed run, returning the
// run's start index (`extra[start]` = count, then that many indices). The temp is not freed here.
fn emit_list(p: *mut Parser, items: *Vec<u32>) -> u32 {
    let start: u32 = vec_len(u32, &p.extra) as u32;
    let count: usize = vec_len(u32, items);
    vec_push(u32, &p.extra, count as u32);
    var li: usize = 0;
    while li < count {
        vec_push(u32, &p.extra, vec_get(u32, items, li));
        li = li + 1;
    }
    return start;
}

// ----- infix operator table (mirrors src/parser.zig's `infix` binding powers exactly) -----

fn infix_op(p: *mut Parser) -> OpInfo {
    if at(p, .pipe_pipe)     { return .{ .present = true, .lbp = 1,  .rbp = 2,  .kind = .bin_lor }; }
    if at(p, .amp_amp)       { return .{ .present = true, .lbp = 3,  .rbp = 4,  .kind = .bin_land }; }
    if at(p, .equal_equal)   { return .{ .present = true, .lbp = 5,  .rbp = 6,  .kind = .bin_eq }; }
    if at(p, .bang_equal)    { return .{ .present = true, .lbp = 5,  .rbp = 6,  .kind = .bin_ne }; }
    if at(p, .less)          { return .{ .present = true, .lbp = 7,  .rbp = 8,  .kind = .bin_lt }; }
    if at(p, .less_equal)    { return .{ .present = true, .lbp = 7,  .rbp = 8,  .kind = .bin_le }; }
    if at(p, .greater)       { return .{ .present = true, .lbp = 7,  .rbp = 8,  .kind = .bin_gt }; }
    if at(p, .greater_equal) { return .{ .present = true, .lbp = 7,  .rbp = 8,  .kind = .bin_ge }; }
    // Bitwise + shift (mirroring src/parser.zig): all bind LOOSER than add/mul but the shifts bind
    // TIGHTER than the bitwise ops, and every one of these binds tighter than comparison (7/8). The
    // INFIX `&` here is bitwise-and; the PREFIX address-of `&x` is handled in parse_prefix, so this
    // table (consulted only after an lhs is parsed) never sees a unary `&`.
    if at(p, .pipe)          { return .{ .present = true, .lbp = 9,  .rbp = 10, .kind = .bin_bor }; }
    if at(p, .caret)         { return .{ .present = true, .lbp = 11, .rbp = 12, .kind = .bin_bxor }; }
    if at(p, .amp)           { return .{ .present = true, .lbp = 13, .rbp = 14, .kind = .bin_band }; }
    if at(p, .shift_left)    { return .{ .present = true, .lbp = 15, .rbp = 16, .kind = .bin_shl }; }
    if at(p, .shift_right)   { return .{ .present = true, .lbp = 15, .rbp = 16, .kind = .bin_shr }; }
    if at(p, .plus)          { return .{ .present = true, .lbp = 17, .rbp = 18, .kind = .bin_add }; }
    if at(p, .minus)         { return .{ .present = true, .lbp = 17, .rbp = 18, .kind = .bin_sub }; }
    if at(p, .star)          { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_mul }; }
    if at(p, .slash)         { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_div }; }
    if at(p, .percent)       { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_mod }; }
    return .{ .present = false, .lbp = 0, .rbp = 0, .kind = .invalid };
}

// ----- type grammar: IDENT | `*` Type | `*mut` Type | `[]const` Type | `[]mut` Type -----

fn parse_type(p: *mut Parser) -> u32 {
    // `?T` value optional (G11 in the subset): a leading `?` wraps the payload type. The payload is
    // parsed recursively (a scalar in the subset), and the whole thing becomes a `type_optional` node
    // that emit lowers to the tagged `mc_opt_<T>` aggregate.
    if eat(p, .question) {
        let payload: u32 = parse_type(p);
        return add_node(p, .type_optional, 0, payload, 0);
    }
    if eat(p, .star) {
        var is_mut: u32 = 0;
        if eat(p, .kw_mut) {
            is_mut = 1;
        } else if eat(p, .kw_const) {
            is_mut = 0;
        }
        // `*mut dyn NAME` / `*dyn NAME` (P5.10): a trait-object fat pointer. `dyn` is NOT a lexer
        // keyword (it lexes as a plain identifier, like `as`/`raw`); recognize it by lexeme, consume
        // it and the trait name, and fold the whole thing into a single `type_dyn` node (the fat
        // pointer struct IS the value, so no separate `type_ptr` wrapper is produced).
        if at(p, .identifier) {
            let is_dyn: bool = tok_is_dyn(p, p.tok as u32);
            if is_dyn {
                p_advance(p); // `dyn`
                let tr_tok: u32 = p.tok as u32;
                expect(p, .identifier);
                return add_node(p, .type_dyn, tr_tok, 0, is_mut);
            }
        }
        let pointee: u32 = parse_type(p);
        return add_node(p, .type_ptr, 0, pointee, is_mut);
    }
    if at(p, .l_bracket) {
        let br_tok: u32 = p.tok as u32;
        p_advance(p); // `[`
        // A fixed-size array `[N]T` (P5.6): a `[` immediately followed by an integer-literal length
        // (N a const literal in the subset — a `comptime N` size param is deferred). An empty `[]`
        // is the slice form handled below. main_token = the length token; lhs = the element type.
        if at(p, .integer_literal) {
            let n_tok: u32 = p.tok as u32;
            p_advance(p); // N
            expect(p, .r_bracket);
            let elem_a: u32 = parse_type(p);
            return add_node(p, .type_array, n_tok, elem_a, 0);
        }
        expect(p, .r_bracket);
        if eat(p, .kw_const) {
            let elem_c: u32 = parse_type(p);
            return add_node(p, .type_slice_const, br_tok, elem_c, 0);
        }
        if eat(p, .kw_mut) {
            let elem_m: u32 = parse_type(p);
            return add_node(p, .type_slice_mut, br_tok, elem_m, 0);
        }
        // Malformed slice qualifier: record and still consume an element type for recovery.
        record_error(p);
        let elem_bad: u32 = parse_type(p);
        return add_node(p, .type_slice_const, br_tok, elem_bad, 0);
    }
    // Keyword scalar types `bool`/`void` lex as `kw_bool`/`kw_void` (not identifiers); build a
    // `type_name` on the keyword token — its recovered lexeme ("bool"/"void") is what sema/emit map.
    if at(p, .kw_bool) {
        let bt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .type_name, bt, 0, 0);
    }
    if at(p, .kw_void) {
        let vt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .type_name, vt, 0, 0);
    }
    // The `type` keyword as a type — only appears as a `comptime T: type` param annotation (P5.5).
    if at(p, .kw_type) {
        let tt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .type_kw, tt, 0, 0);
    }
    let name_tok: u32 = p.tok as u32;
    if !expect(p, .identifier) {
        return 0;
    }
    // A generic instance `S<T>` (P5.5): the `<` is unambiguous in type position (no comparison
    // operators occur here). ONE type argument is supported; nested/multi type args are deferred.
    if at(p, .less) {
        p_advance(p); // `<`
        let arg: u32 = parse_type(p);
        // `Result<T, E>` (two type args): a `,` after the first arg is the tagged Result type. Only
        // `Result` uses two args in the subset; a single arg stays a mono `S<T>` generic instance.
        if eat(p, .comma) {
            let arg2: u32 = parse_type(p);
            consume_generic_close(p);
            return add_node(p, .type_result, name_tok, arg, arg2);
        }
        consume_generic_close(p);
        return add_node(p, .type_generic, name_tok, arg, 0);
    }
    return add_node(p, .type_name, name_tok, 0, 0);
}

// ----- expression grammar (precedence-climbing, faithful to src/parser.zig) -----

// Flush a temporary list of (token, node) PAIRS into `extra` as a run whose length prefix is the
// PAIR count (not the raw element count): `extra[start]` = pairs, then that many `tok, node` pairs.
// Used by both `struct_decl` (field name/type) and `struct_lit` (field name/value). Temp not freed.
fn emit_pair_list(p: *mut Parser, pairs: *Vec<u32>) -> u32 {
    let start: u32 = vec_len(u32, &p.extra) as u32;
    let raw: usize = vec_len(u32, pairs);
    let count: u32 = (raw / 2) as u32;
    vec_push(u32, &p.extra, count);
    var i: usize = 0;
    while i < raw {
        vec_push(u32, &p.extra, vec_get(u32, pairs, i));
        i = i + 1;
    }
    return start;
}

// struct_lit := `.` `{` (`.` IDENT `=` Expr (`,`)?)* `}`  (trailing comma allowed, per MC)
fn parse_struct_lit(p: *mut Parser) -> u32 {
    let dot_tok: u32 = p.tok as u32;
    p_advance(p); // `.`
    expect(p, .l_brace);
    var pairs: Vec<u32> = vec_new(u32, p.a);
    if !at(p, .r_brace) {
        while true {
            expect(p, .dot);
            let fname: u32 = p.tok as u32;
            expect(p, .identifier);
            expect(p, .equal);
            let fval: u32 = parse_expr(p, 0);
            vec_push(u32, &pairs, fname);
            vec_push(u32, &pairs, fval);
            if !eat(p, .comma) {
                break;
            }
            if at(p, .r_brace) {
                break; // trailing comma
            }
        }
    }
    expect(p, .r_brace);
    let run: u32 = emit_pair_list(p, &pairs);
    vec_free(u32, &pairs);
    return add_node(p, .struct_lit, dot_tok, run, 0);
}

// array_lit := `.` `{` (Expr (`,`)?)* `}`  (trailing comma allowed, per MC). Positional elements
// (no `.field =`), so it is distinguished from `struct_lit` by the `.ident =` lookahead in
// `dot_is_struct_lit`. main_token = the leading `.`; lhs = a length-prefixed run of element exprs.
fn parse_array_lit(p: *mut Parser) -> u32 {
    let dot_tok: u32 = p.tok as u32;
    p_advance(p); // `.`
    expect(p, .l_brace);
    var elems: Vec<u32> = vec_new(u32, p.a);
    if !at(p, .r_brace) {
        while true {
            let e: u32 = parse_expr(p, 0);
            vec_push(u32, &elems, e);
            if !eat(p, .comma) {
                break;
            }
            if at(p, .r_brace) {
                break; // trailing comma
            }
        }
    }
    expect(p, .r_brace);
    let run: u32 = emit_list(p, &elems);
    vec_free(u32, &elems);
    return add_node(p, .array_lit, dot_tok, run, 0);
}

// True when a leading `.{` opens a STRUCT literal (its first entry is `.field = ...`) rather than a
// positional ARRAY literal. The cursor is at the `.`; offsets: 0 = `.`, 1 = `{`, 2.. = first entry.
// A struct entry begins `.` IDENT `=` (offsets 2,3,4); anything else (an int, an ident, a nested
// `.{`, or `}` for an empty literal) is an array literal.
fn dot_is_struct_lit(p: *mut Parser) -> bool {
    let a: bool = at_next(p, 2, .dot);
    let b: bool = at_next(p, 3, .identifier);
    let c: bool = at_next(p, 4, .equal);
    return a && b && c;
}

// True when token `tok` is the identifier `raw` (the low-level intrinsic namespace, which is NOT a
// lexer keyword — it lexes as a plain identifier, like `import`). Bound to a local per G13.
fn tok_is_raw(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "raw");
}

// True when token `tok` is the identifier `as` (the cast operator, which is NOT a lexer keyword —
// it lexes as a plain identifier, exactly as MC's real parser recognizes it in src/parser.zig:
// `self.current.kind == .identifier and eql(self.current.lexeme, "as")`). Bound to a local per G13.
fn tok_is_as(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "as");
}

// True when token `tok` is the identifier `dyn` (the trait-object marker, which is NOT a lexer
// keyword — it lexes as a plain identifier, like `as`/`raw`). Bound to a local per G13. (P5.10)
fn tok_is_dyn(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "dyn");
}

// True when token `tok` is the identifier `trait` (the trait-decl keyword — NOT a lexer keyword;
// it lexes as a plain identifier, like `import`). Bound to a local per G13. (P5.10)
fn tok_is_trait(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "trait");
}

// True when token `tok` is the identifier `impl` (the impl-block keyword — NOT a lexer keyword;
// it lexes as a plain identifier, like `import`). Bound to a local per G13. (P5.10)
fn tok_is_impl(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "impl");
}

// True when token `tok` is the identifier `opaque` (the contextual field-privacy qualifier before
// `struct` in the real grammar — NOT a lexer keyword; it lexes as a plain identifier, like
// `import`/`trait`). Bound to a local per G13. (P5.1 opaque-struct)
fn tok_is_opaque(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "opaque");
}

// `move` is a contextual qualifier before `struct` (a linear/move struct), lexed as a plain
// identifier (not a keyword) — like `opaque`. The subset does NOT enforce move/linearity (a checker
// concern, not needed to COMPILE), so a `move struct` is parsed/typed/emitted as a regular struct.
fn tok_is_move(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "move");
}

// raw_op := `raw` `.` (`ptr`|`load`|`store`) `<` Type `>` `(` Expr (`,` Expr)? `)`  (P5.8). The
// member ident (`ptr`/`load`/`store`) becomes main_token so emit/sema recover the op by lexeme; the
// `<T>` reuses `parse_type`; the value args are a fixed 2-slot record [arg0, arg1] (arg1 = 0 for the
// single-arg `ptr`/`load`). The cursor is at the `raw` identifier.
fn parse_raw_op(p: *mut Parser) -> u32 {
    p_advance(p); // `raw`
    p_advance(p); // `.`
    let op_tok: u32 = p.tok as u32; // `ptr` / `load` / `store`
    expect(p, .identifier);
    expect(p, .less);
    let ty: u32 = parse_type(p);
    consume_generic_close(p);
    expect(p, .l_paren);
    let arg0: u32 = parse_expr(p, 0);
    var arg1: u32 = 0;
    if eat(p, .comma) {
        arg1 = parse_expr(p, 0);
    }
    expect(p, .r_paren);
    let rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, arg0);
    vec_push(u32, &p.extra, arg1);
    return add_node(p, .raw_op, op_tok, ty, rec);
}

// primary := INT | IDENT | `(` Expr `)`
fn parse_primary(p: *mut Parser) -> u32 {
    if at(p, .integer_literal) {
        let it: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .int_literal, it, 0, 0);
    }
    // `'a'` / `'\n'` / `'\\'` char literal: the lexer emits a single `.char_literal` token whose
    // lexeme INCLUDES the surrounding quotes (a valid C char literal, escapes and all). main_token
    // keeps the token so emit can recover the spelling verbatim.
    if at(p, .char_literal) {
        let ct: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .char_literal, ct, 0, 0);
    }
    // `true` / `false` bool literals: the lexer emits `kw_true`/`kw_false`; main_token keeps the token
    // so emit can recover the spelling ("true"/"false"), which is also valid C (stdbool.h in prelude).
    if at(p, .kw_true) {
        let bt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .bool_literal, bt, 0, 0);
    }
    if at(p, .kw_false) {
        let bf: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .bool_literal, bf, 0, 0);
    }
    // `"..."` byte-string literal: the lexeme (quotes + escapes included) is a valid C string literal
    // and is kept in main_token; emit builds a `[]const u8` fat-pointer slice value from it.
    if at(p, .string_literal) {
        let st: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .string_literal, st, 0, 0);
    }
    // `uninit` primary: an explicitly-uninitialized value, valid as a `let`/`var` initializer of a
    // known type (`var x: T = uninit;`). Emit drops the initializer, matching C's default declaration.
    if at(p, .kw_uninit) {
        let ut: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .uninit_literal, ut, 0, 0);
    }
    // `null` primary (G11 in the subset): the ABSENT value of a value optional. It carries no type of
    // its own — sema/emit resolve it against the expected `?T` target (a typed init/return, or the
    // other side of `== null`). main_token keeps the `null` keyword token for diagnostics.
    if at(p, .kw_null) {
        let nt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .null_literal, nt, 0, 0);
    }
    // `ok(x)` / `err(x)` Result constructors. `ok`/`err` are lexer KEYWORDS (kw_ok/kw_err), so they are
    // parsed here into a plain `call` node whose callee is an `ident_expr` on the keyword token — its
    // recovered lexeme ("ok"/"err") is what sema/emit key off (like `phys`), so no dedicated ctor node
    // is needed. Exactly one argument in the subset.
    if at(p, .kw_ok) || at(p, .kw_err) {
        let ctor_tok: u32 = p.tok as u32;
        p_advance(p); // `ok` / `err`
        expect(p, .l_paren);
        let ctor_arg: u32 = parse_expr(p, 0);
        expect(p, .r_paren);
        let callee: u32 = add_node(p, .ident_expr, ctor_tok, 0, 0);
        let run: u32 = vec_len(u32, &p.extra) as u32;
        vec_push(u32, &p.extra, 1); // arg count
        vec_push(u32, &p.extra, ctor_arg);
        return add_node(p, .call, ctor_tok, callee, run);
    }
    // `sizeof(TYPE)` / `alignof(TYPE)` (P5.9): both are lexer KEYWORDS (kw_sizeof/kw_alignof) and take
    // a TYPE (not an expr) in the subset — matching MC's builtins. The type node is kept in `lhs`.
    if at(p, .kw_sizeof) {
        let sz_tok: u32 = p.tok as u32;
        p_advance(p); // `sizeof`
        expect(p, .l_paren);
        let sz_ty: u32 = parse_type(p);
        expect(p, .r_paren);
        return add_node(p, .sizeof_op, sz_tok, sz_ty, 0);
    }
    if at(p, .kw_alignof) {
        let al_tok: u32 = p.tok as u32;
        p_advance(p); // `alignof`
        expect(p, .l_paren);
        let al_ty: u32 = parse_type(p);
        expect(p, .r_paren);
        return add_node(p, .alignof_op, al_tok, al_ty, 0);
    }
    if at(p, .identifier) {
        // A `raw.ptr<T>(...)` / `raw.load<T>(...)` / `raw.store<T>(...)` intrinsic (P5.8): the base
        // ident is literally `raw`, followed by `.` MEMBER `<` — unambiguous, since a normal member
        // access is never followed by `<` in expression position here. Parse it as a `raw_op` node so
        // the `<T>` type arg is not misread as a `less-than` comparison.
        let is_raw_head: bool = tok_is_raw(p, p.tok as u32);
        if is_raw_head {
            let d1: bool = at_next(p, 1, .dot);
            let m2: bool = at_next(p, 2, .identifier);
            let l3: bool = at_next(p, 3, .less);
            if d1 && m2 && l3 {
                return parse_raw_op(p);
            }
        }
        let idt: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .ident_expr, idt, 0, 0);
    }
    if eat(p, .l_paren) {
        let inner: u32 = parse_expr(p, 0);
        expect(p, .r_paren);
        return inner; // grouping is structural only; no wrapper node
    }
    // A leading `.` introduces either a struct literal `.{ ... }` (P5.1) or an enum literal
    // `.variant` (P5.2). Distinguish by the token after the dot: a `{` is a struct literal, an
    // identifier is an enum literal (main_token = the variant ident).
    if at(p, .dot) {
        if at_next(p, 1, .l_brace) {
            // `.{` opens a struct literal (`.field = ...`) or a positional array literal (P5.6).
            if dot_is_struct_lit(p) {
                return parse_struct_lit(p);
            }
            return parse_array_lit(p);
        }
        if at_next(p, 1, .identifier) {
            p_advance(p); // `.`
            let vtok: u32 = p.tok as u32;
            expect(p, .identifier);
            return add_node(p, .enum_lit, vtok, 0, 0);
        }
    }
    // Not the start of any expression.
    record_error(p);
    p_advance(p); // guarantee progress past the offending token
    return 0;
}

// postfix := primary ( `(` args `)` | `[` Expr `]` | `.` IDENT )*
fn parse_postfix(p: *mut Parser, input: u32) -> u32 {
    var expr: u32 = input;
    while true {
        if at(p, .l_paren) {
            let call_tok: u32 = p.tok as u32;
            p_advance(p); // `(`
            var args: Vec<u32> = vec_new(u32, p.a);
            if !at(p, .r_paren) {
                while true {
                    let arg: u32 = parse_expr(p, 0);
                    vec_push(u32, &args, arg);
                    if !eat(p, .comma) {
                        break;
                    }
                }
            }
            expect(p, .r_paren);
            let args_run: u32 = emit_list(p, &args);
            vec_free(u32, &args);
            expr = add_node(p, .call, call_tok, expr, args_run);
            continue;
        }
        if at(p, .l_bracket) {
            let idx_tok: u32 = p.tok as u32;
            p_advance(p); // `[`
            let subscript: u32 = parse_expr(p, 0);
            // A `..` after the first index makes this a SUB-SLICE `base[start..end]` (P5.7): parse the
            // end expr and record a fixed 2-slot [start, end] extra record. Otherwise it is a plain
            // element index `base[i]`.
            if at(p, .dot_dot) {
                p_advance(p); // `..`
                let end_expr: u32 = parse_expr(p, 0);
                expect(p, .r_bracket);
                let rec: u32 = vec_len(u32, &p.extra) as u32;
                vec_push(u32, &p.extra, subscript);
                vec_push(u32, &p.extra, end_expr);
                expr = add_node(p, .slice_range, idx_tok, expr, rec);
                continue;
            }
            expect(p, .r_bracket);
            expr = add_node(p, .index, idx_tok, expr, subscript);
            continue;
        }
        if at(p, .dot) {
            p_advance(p); // `.`
            // Pointer deref `p.*` (P5.8): a `.` followed by `*` (read or assignment target).
            if at(p, .star) {
                let star_tok: u32 = p.tok as u32;
                p_advance(p); // `*`
                expr = add_node(p, .deref, star_tok, expr, 0);
                continue;
            }
            let field_tok: u32 = p.tok as u32;
            expect(p, .identifier);
            expr = add_node(p, .field, field_tok, expr, 0);
            continue;
        }
        // Postfix `expr?` error-propagation (Result). `?` in expression position is unambiguous (MC has
        // no ternary; the `?T` optional TYPE form is parsed only in parse_type). Binds tighter than any
        // binary/cast op, like the other postfixes.
        if at(p, .question) {
            let q_tok: u32 = p.tok as u32;
            p_advance(p); // `?`
            expr = add_node(p, .try_op, q_tok, expr, 0);
            continue;
        }
        break;
    }
    return expr;
}

// prefix := (`-` | `!`) prefix | postfix(primary)
fn parse_prefix(p: *mut Parser) -> u32 {
    if at(p, .minus) {
        let neg_tok: u32 = p.tok as u32;
        p_advance(p);
        let neg_operand: u32 = parse_expr(p, PREFIX_OPERAND_BP);
        return add_node(p, .un_neg, neg_tok, neg_operand, 0);
    }
    if at(p, .bang) {
        let not_tok: u32 = p.tok as u32;
        p_advance(p);
        let not_operand: u32 = parse_expr(p, PREFIX_OPERAND_BP);
        return add_node(p, .un_not, not_tok, not_operand, 0);
    }
    // Address-of `&expr` (P5.7): needed for the `mem.as_bytes(&arr)` slice builtin, and useful for
    // taking pointers generally. Binds like the other prefix operators.
    if at(p, .amp) {
        let amp_tok: u32 = p.tok as u32;
        p_advance(p);
        let addr_operand: u32 = parse_expr(p, PREFIX_OPERAND_BP);
        return add_node(p, .un_addr, amp_tok, addr_operand, 0);
    }
    // Prefix pointer deref `*expr` (C-style, distinct from the postfix `p.*` form). Reuses the same
    // `.deref` node so sema/emit need no new case. Binds like the other prefix operators.
    if at(p, .star) {
        let star_tok: u32 = p.tok as u32;
        p_advance(p);
        let deref_operand: u32 = parse_expr(p, PREFIX_OPERAND_BP);
        return add_node(p, .deref, star_tok, deref_operand, 0);
    }
    let prim: u32 = parse_primary(p);
    return prim;
}

// expr := precedence-climb over the infix table, with postfix applied to each operand.
fn parse_expr(p: *mut Parser, min_bp: u32) -> u32 {
    var lhs: u32 = parse_prefix(p);
    while true {
        lhs = parse_postfix(p, lhs);
        // `expr as TYPE` (P5.9): recognized in the infix position by the `as` identifier lexeme (it is
        // NOT a keyword). Checked BEFORE the binary table and `continue`d regardless of `min_bp`, so a
        // cast binds tighter than every binary operator but looser than postfix/unary — exactly as
        // src/parser.zig does it (so `a as u32 + b` is `(a as u32) + b`, `a * b as u32` is
        // `a * (b as u32)`). lhs = the operand; rhs = the target type node.
        if at(p, .identifier) {
            let is_as: bool = tok_is_as(p, p.tok as u32);
            if is_as {
                let as_tok: u32 = p.tok as u32;
                p_advance(p); // `as`
                let cast_ty: u32 = parse_type(p);
                lhs = add_node(p, .cast, as_tok, lhs, cast_ty);
                continue;
            }
        }
        let op: OpInfo = infix_op(p);
        if !op.present {
            break;
        }
        if op.lbp < min_bp {
            break;
        }
        let op_tok: u32 = p.tok as u32;
        p_advance(p);
        let rhs: u32 = parse_expr(p, op.rbp);
        lhs = add_node(p, op.kind, op_tok, lhs, rhs);
    }
    return lhs;
}

// ----- statement grammar -----

// if := `if` Expr Block (`else` (Block | if))?
fn parse_if(p: *mut Parser) -> u32 {
    let if_tok: u32 = p.tok as u32;
    p_advance(p); // `if`
    let cond: u32 = parse_expr(p, 0);
    let then_block: u32 = parse_block(p);
    var else_node: u32 = 0;
    if eat(p, .kw_else) {
        if at(p, .kw_if) {
            else_node = parse_if(p); // `else if` chain
        } else {
            else_node = parse_block(p);
        }
    }
    let if_rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, then_block);
    vec_push(u32, &p.extra, else_node);
    return add_node(p, .if_stmt, if_tok, cond, if_rec);
}

// if-let := `if` `let` IDENT `=` Expr Block (`else` (Block | if))?  (G11 in the subset). Narrows an
// optional-typed EXPR to its payload, binding IDENT in the then-branch. main_token = the binding
// IDENT; lhs = EXPR (the `?T` value); rhs = a fixed 2-slot rec [then_block, else(0=none)] (same shape
// as `if_stmt`, so emit can share the else/else-if handling). The cursor is at `if`.
fn parse_if_let(p: *mut Parser) -> u32 {
    p_advance(p); // `if`
    p_advance(p); // `let`
    // Result tag form `if let ok(v) = EXPR { .. }` / `if let err(e) = EXPR { .. }`: a binding head of
    // the `ok`/`err` keyword distinguishes it from the optional form `if let NAME = EXPR` (IDENT head).
    let is_result: bool = at(p, .kw_ok) || at(p, .kw_err);
    if is_result {
        let tag_tok: u32 = p.tok as u32; // `ok` / `err` keyword
        p_advance(p);
        expect(p, .l_paren);
        let bind: u32 = p.tok as u32; // the payload binding name
        expect(p, .identifier);
        expect(p, .r_paren);
        expect(p, .equal);
        let rexpr: u32 = parse_expr(p, 0);
        let rthen: u32 = parse_block(p);
        var relse: u32 = 0;
        if eat(p, .kw_else) {
            if at(p, .kw_if) {
                relse = parse_if(p);
            } else {
                relse = parse_block(p);
            }
        }
        let rrec: u32 = vec_len(u32, &p.extra) as u32;
        vec_push(u32, &p.extra, tag_tok);
        vec_push(u32, &p.extra, rthen);
        vec_push(u32, &p.extra, relse);
        return add_node(p, .if_let_result_stmt, bind, rexpr, rrec);
    }
    let name: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .equal);
    let opt_expr: u32 = parse_expr(p, 0);
    let then_block: u32 = parse_block(p);
    var else_node: u32 = 0;
    if eat(p, .kw_else) {
        if at(p, .kw_if) {
            else_node = parse_if(p); // `else if` chain
        } else {
            else_node = parse_block(p);
        }
    }
    let rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, then_block);
    vec_push(u32, &p.extra, else_node);
    return add_node(p, .if_let_stmt, name, opt_expr, rec);
}

// switch := `switch` Expr `{` (Pat `=>` Block (`,`)?)* `}`  where Pat is `.` IDENT | `_`.
// (trailing comma allowed, per MC). Each arm is a (pattern-token, block-node) PAIR flushed via
// `emit_pair_list`: the pattern token is the variant IDENT for a `.variant` arm and the `_`
// underscore token for a wildcard arm; sema/emit tell them apart by the token's kind (so no
// separate marker slot is needed). rhs = the arms run; lhs = the subject expr. (Statement form
// only: switch-as-expression and payload-binding `variant(x) =>` are deferred — see the ledger.)
// Parse the arms of a Result tag switch `switch r { ok(v) => {..}, err(e) => {..} }` (the cursor is
// just past the opening `{`). Each arm is `TAG ( BIND ) => Block`; arms are flushed into `extra` as a
// run of TRIPLES `[count, (tag_tok, bind_tok, block)*]` (count is the TRIPLE count). Returns a
// `result_switch_stmt` node. `sema`/`emit` tell ok from err by the tag token's lexeme.
fn parse_result_switch_arms(p: *mut Parser, sw_tok: u32, subject: u32) -> u32 {
    var arms: Vec<u32> = vec_new(u32, p.a); // (tag_tok, bind_tok, block) triples
    if !at(p, .r_brace) {
        while true {
            let arm_start: usize = p.tok; // no-progress guard
            let tag_tok: u32 = p.tok as u32; // `ok` / `err` keyword
            p_advance(p);
            expect(p, .l_paren);
            let bind_tok: u32 = p.tok as u32; // the payload binding
            expect(p, .identifier);
            expect(p, .r_paren);
            expect(p, .fat_arrow);
            let arm_block: u32 = parse_block(p);
            vec_push(u32, &arms, tag_tok);
            vec_push(u32, &arms, bind_tok);
            vec_push(u32, &arms, arm_block);
            // Separator optional after a `}`-block arm (see parse_switch); comma still accepted.
            eat(p, .comma);
            if at(p, .r_brace) || at(p, .eof) {
                break;
            }
            if p.tok == arm_start {
                break; // no forward progress — avoid an infinite loop
            }
        }
    }
    expect(p, .r_brace);
    // Flush the triples: `extra[start]` = triple count, then that many (tag, bind, block) triples.
    let start: u32 = vec_len(u32, &p.extra) as u32;
    let raw: usize = vec_len(u32, &arms);
    let count: u32 = (raw / 3) as u32;
    vec_push(u32, &p.extra, count);
    var i: usize = 0;
    while i < raw {
        vec_push(u32, &p.extra, vec_get(u32, &arms, i));
        i = i + 1;
    }
    vec_free(u32, &arms);
    return add_node(p, .result_switch_stmt, sw_tok, subject, start);
}

fn parse_switch(p: *mut Parser) -> u32 {
    let sw_tok: u32 = p.tok as u32;
    p_advance(p); // `switch`
    let subject: u32 = parse_expr(p, 0);
    expect(p, .l_brace);
    // Result tag switch `switch r { ok(v) => {..}, err(e) => {..} }`: arms headed by the `ok`/`err`
    // keyword route to the Result arm parser. An enum switch's arms are `.variant`/`_`.
    let is_result: bool = at(p, .kw_ok) || at(p, .kw_err);
    if is_result {
        return parse_result_switch_arms(p, sw_tok, subject);
    }
    var arms: Vec<u32> = vec_new(u32, p.a); // (pattern_tok, block_node) pairs
    if !at(p, .r_brace) {
        while true {
            let arm_start: usize = p.tok; // no-progress guard (expect() leaves the cursor put on error)
            var pat_tok: u32 = p.tok as u32;
            if at(p, .dot) {
                p_advance(p); // `.`
                pat_tok = p.tok as u32; // the variant ident
                expect(p, .identifier);
            } else if at(p, .underscore) {
                pat_tok = p.tok as u32; // the `_` token (recognized by kind at sema/emit)
                p_advance(p);
            } else if at(p, .kw_true) || at(p, .kw_false) {
                // A `switch` over a `bool` (or an integer): the pattern is the literal `true`/`false`
                // (or an integer literal) itself. main_token keeps the token; emit's `e_case_label`
                // falls back to the bare lexeme (`case true:` / `case 3:`), which is valid C.
                pat_tok = p.tok as u32;
                p_advance(p);
            } else if at(p, .integer_literal) {
                pat_tok = p.tok as u32;
                p_advance(p);
            } else {
                // Not a valid pattern head: record and leave `pat_tok` at the offending token so the
                // no-progress guard in the enclosing loop can still advance.
                record_error(p);
            }
            expect(p, .fat_arrow);
            let arm_block: u32 = parse_block(p);
            vec_push(u32, &arms, pat_tok);
            vec_push(u32, &arms, arm_block);
            // The arm separator is OPTIONAL: real MC (and mcc2's own source) omits the comma after a
            // `}`-block-bodied arm (`.a => { .. } .b => { .. }`), but a comma is still accepted
            // (matching src/parser.zig: `_ = match(.comma)` unconditionally after each arm body).
            eat(p, .comma);
            if at(p, .r_brace) || at(p, .eof) {
                break;
            }
            if p.tok == arm_start {
                break; // no forward progress (malformed arm) — avoid an infinite loop
            }
        }
    }
    expect(p, .r_brace);
    let arms_run: u32 = emit_pair_list(p, &arms);
    vec_free(u32, &arms);
    return add_node(p, .switch_stmt, sw_tok, subject, arms_run);
}

// match := `match` Expr `{` (Pat `=>` Block (`,`)?)* `}`  where Pat is `.` IDENT | `_` (P5.11).
// In the checked subset a `match` is GRAMMATICALLY identical to a `switch`: the subset has no
// tagged-union / `Result` / payload-carrying enum types, so a pattern can never bind a payload
// (`variant(x) =>` is unrepresentable here — see the ledger). `match` therefore reuses parse_switch
// verbatim and desugars to the same `switch_stmt` node; sema (exhaustiveness) and emit (C `switch`)
// need no `match`-specific handling. parse_switch keys off the CURRENT token, so the `match` keyword
// is consumed correctly. (Payload binding is deferred until the subset grows tagged unions.)
fn parse_match(p: *mut Parser) -> u32 {
    return parse_switch(p);
}

// stmt := let | return | if | while | switch | match | (assign | expr) `;`
fn parse_stmt(p: *mut Parser) -> u32 {
    if at(p, .kw_let) {
        p_advance(p);
        let let_name: u32 = p.tok as u32;
        expect(p, .identifier);
        var let_ty: u32 = 0;
        if eat(p, .colon) {
            let_ty = parse_type(p);
        }
        expect(p, .equal);
        let let_init: u32 = parse_expr(p, 0);
        expect(p, .semicolon);
        return add_node(p, .let_decl, let_name, let_ty, let_init);
    }
    if at(p, .kw_var) {
        p_advance(p);
        let var_name: u32 = p.tok as u32;
        expect(p, .identifier);
        var var_ty: u32 = 0;
        if eat(p, .colon) {
            var_ty = parse_type(p);
        }
        expect(p, .equal);
        let var_init: u32 = parse_expr(p, 0);
        expect(p, .semicolon);
        return add_node(p, .var_decl, var_name, var_ty, var_init);
    }
    if at(p, .kw_return) {
        let ret_tok: u32 = p.tok as u32;
        p_advance(p);
        var ret_val: u32 = 0;
        if !at(p, .semicolon) {
            ret_val = parse_expr(p, 0);
        }
        expect(p, .semicolon);
        return add_node(p, .return_stmt, ret_tok, ret_val, 0);
    }
    if at(p, .kw_if) {
        // `if let NAME = EXPR { .. }` (G11): a `let` right after `if` opens the optional-narrowing form.
        if at_next(p, 1, .kw_let) {
            return parse_if_let(p);
        }
        return parse_if(p);
    }
    // `break;` / `continue;` loop control statements.
    if at(p, .kw_break) {
        let bt: u32 = p.tok as u32;
        p_advance(p);
        expect(p, .semicolon);
        return add_node(p, .break_stmt, bt, 0, 0);
    }
    if at(p, .kw_continue) {
        let ct: u32 = p.tok as u32;
        p_advance(p);
        expect(p, .semicolon);
        return add_node(p, .continue_stmt, ct, 0, 0);
    }
    if at(p, .kw_while) {
        let while_tok: u32 = p.tok as u32;
        p_advance(p);
        let while_cond: u32 = parse_expr(p, 0);
        let while_body: u32 = parse_block(p);
        return add_node(p, .while_stmt, while_tok, while_cond, while_body);
    }
    if at(p, .kw_switch) {
        return parse_switch(p);
    }
    if at(p, .kw_match) {
        return parse_match(p);
    }
    // `unsafe { <stmts> }` (P5.8): a block-statement wrapper. C has no `unsafe`, so this lowers to a
    // plain brace block; sema simply checks the inner statements (no effect tracking in the subset).
    if at(p, .kw_unsafe) {
        let u_tok: u32 = p.tok as u32;
        p_advance(p); // `unsafe`
        let ubody: u32 = parse_block(p);
        return add_node(p, .unsafe_block, u_tok, ubody, 0);
    }
    // `unreachable;` — a diverging terminator statement (like `return`, no fall-through). `unreachable`
    // IS a lexer keyword (kw_unreachable). Lowers to the real backend's `mc_trap_Unreachable();`.
    if at(p, .kw_unreachable) {
        let ur_tok: u32 = p.tok as u32;
        p_advance(p); // `unreachable`
        expect(p, .semicolon);
        return add_node(p, .unreachable_stmt, ur_tok, 0, 0);
    }
    // Expression statement or assignment.
    let head: u32 = parse_expr(p, 0);
    if at(p, .equal) {
        let assign_tok: u32 = p.tok as u32;
        p_advance(p);
        let assign_val: u32 = parse_expr(p, 0);
        expect(p, .semicolon);
        return add_node(p, .assign, assign_tok, head, assign_val);
    }
    expect(p, .semicolon);
    return add_node(p, .expr_stmt, 0, head, 0);
}

// block := `{` Stmt* `}`
fn parse_block(p: *mut Parser) -> u32 {
    let brace_tok: u32 = p.tok as u32;
    expect(p, .l_brace);
    var stmts: Vec<u32> = vec_new(u32, p.a);
    while true {
        if at(p, .r_brace) {
            break;
        }
        if at(p, .eof) {
            record_error(p);
            break;
        }
        let before: usize = p.tok;
        let s: u32 = parse_stmt(p);
        vec_push(u32, &stmts, s);
        if p.tok == before {
            p_advance(p); // no-progress guard on malformed input
        }
        if p.err_count > 100 {
            break;
        }
    }
    expect(p, .r_brace);
    let stmts_run: u32 = emit_list(p, &stmts);
    vec_free(u32, &stmts);
    return add_node(p, .block, brace_tok, stmts_run, 0);
}

// ----- declarations -----

// fn := `export`? `fn` IDENT `(` Params `)` `->` Type Block
fn parse_fn(p: *mut Parser, exported: u32) -> u32 {
    p_advance(p); // `fn`
    let fn_name: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .l_paren);
    var params: Vec<u32> = vec_new(u32, p.a);
    if !at(p, .r_paren) {
        while true {
            // A leading `comptime` marks a compile-time param; with a `type` annotation it is the
            // generic type param (`comptime T: type`, P5.5). `rhs = is_comptime` records the marker.
            var is_comptime: u32 = 0;
            if eat(p, .kw_comptime) {
                is_comptime = 1;
            }
            let param_name: u32 = p.tok as u32;
            expect(p, .identifier);
            expect(p, .colon);
            let param_ty: u32 = parse_type(p);
            let param: u32 = add_node(p, .param_decl, param_name, param_ty, is_comptime);
            vec_push(u32, &params, param);
            if !eat(p, .comma) {
                break;
            }
        }
    }
    expect(p, .r_paren);
    expect(p, .arrow);
    let ret_ty: u32 = parse_type(p);
    let body: u32 = parse_block(p);
    let params_run: u32 = emit_list(p, &params);
    vec_free(u32, &params);
    // Fixed record: [exported, params_run, ret_type, body].
    let fn_rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, exported);
    vec_push(u32, &p.extra, params_run);
    vec_push(u32, &p.extra, ret_ty);
    vec_push(u32, &p.extra, body);
    return add_node(p, .fn_decl, fn_name, fn_rec, 0);
}

// struct := `struct` IDENT `{` (IDENT `:` Type (`,`)?)* `}`  (trailing comma allowed, per MC)
fn parse_struct(p: *mut Parser, exported: u32) -> u32 {
    p_advance(p); // `struct`
    let sname: u32 = p.tok as u32;
    expect(p, .identifier);
    // An optional `<T>` type-param list marks a GENERIC struct (P5.5). ONE param is supported.
    var tparam_tok: u32 = 0;
    var is_generic: u32 = 0;
    if at(p, .less) {
        p_advance(p); // `<`
        tparam_tok = p.tok as u32;
        expect(p, .identifier);
        expect(p, .greater);
        is_generic = 1;
    }
    expect(p, .l_brace);
    var pairs: Vec<u32> = vec_new(u32, p.a); // (name_tok, type_node) pairs
    if !at(p, .r_brace) {
        while true {
            let fname: u32 = p.tok as u32;
            expect(p, .identifier);
            expect(p, .colon);
            let fty: u32 = parse_type(p);
            vec_push(u32, &pairs, fname);
            vec_push(u32, &pairs, fty);
            if !eat(p, .comma) {
                break;
            }
            if at(p, .r_brace) {
                break; // trailing comma
            }
        }
    }
    expect(p, .r_brace);
    let run: u32 = emit_pair_list(p, &pairs);
    vec_free(u32, &pairs);
    if is_generic == 1 {
        // Generic struct: fixed rec [tparam_tok, fields_run, exported].
        let grec: u32 = vec_len(u32, &p.extra) as u32;
        vec_push(u32, &p.extra, tparam_tok);
        vec_push(u32, &p.extra, run);
        vec_push(u32, &p.extra, exported);
        return add_node(p, .struct_gdecl, sname, grec, 0);
    }
    return add_node(p, .struct_decl, sname, run, exported);
}

// enum := `enum` IDENT (`:` Type)? `{` (IDENT (`,`)?)* `}`  (trailing comma allowed, per MC).
// `exported`/`is_open` are captured by the caller (`parse_decl`) from the leading keywords; the
// fixed record is [exported, is_open, repr_type(0=none), variants_run] where `variants_run` is a
// length-prefixed run of variant name-tokens.
fn parse_enum(p: *mut Parser, exported: u32, is_open: u32) -> u32 {
    p_advance(p); // `enum`
    let ename: u32 = p.tok as u32;
    expect(p, .identifier);
    var repr_node: u32 = 0;
    if eat(p, .colon) {
        repr_node = parse_type(p);
    }
    expect(p, .l_brace);
    var vs: Vec<u32> = vec_new(u32, p.a);
    if !at(p, .r_brace) {
        while true {
            let vtok: u32 = p.tok as u32;
            expect(p, .identifier);
            vec_push(u32, &vs, vtok);
            if !eat(p, .comma) {
                break;
            }
            if at(p, .r_brace) {
                break; // trailing comma
            }
        }
    }
    expect(p, .r_brace);
    let vrun: u32 = emit_list(p, &vs);
    vec_free(u32, &vs);
    // Fixed record: [exported, is_open, repr_type, variants_run].
    let rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, exported);
    vec_push(u32, &p.extra, is_open);
    vec_push(u32, &p.extra, repr_node);
    vec_push(u32, &p.extra, vrun);
    return add_node(p, .enum_decl, ename, rec, 0);
}

// The lexeme (`source[start..start+len]`) of token `tok`. Bound to a plain local first (the C
// backend recovers a slice's element type from a local, not from a struct-field access — see the
// lexer's SOURCE-AS-A-SLICE-FIELD note).
fn tok_lexeme(p: *mut Parser, tok: u32) -> []const u8 {
    let st: usize = token_start_at(&p.tl, tok as usize);
    let ln: usize = token_len_at(&p.tl, tok as usize);
    let s: []const u8 = p.source;
    return s[st..st + ln];
}

// True when token `tok` is the identifier `import` (the module-directive keyword, which is NOT a
// lexer keyword — it lexes as a plain identifier, exactly as MC's real loader recognizes it).
fn tok_is_import(p: *mut Parser, tok: u32) -> bool {
    let lex: []const u8 = tok_lexeme(p, tok);

    return mem_eql(lex, "import");
}

// import := `import` STRING `;`  (a top-level directive). The path string is kept as the node's
// main_token; the directive is otherwise a no-op — the loader supplies the imported decls.
fn parse_import(p: *mut Parser) -> u32 {
    p_advance(p); // `import`
    let path_tok: u32 = p.tok as u32;
    expect(p, .string_literal);
    expect(p, .semicolon);
    return add_node(p, .import_decl, path_tok, 0, 0);
}

// extern := `extern` STRING `fn` IDENT `(` Params `)` `->` Type `;`  (P5.8). A bodyless prototype
// binding a C symbol (typically libc). The ABI string (`"C"`) is consumed and ignored (the subset
// only targets the C ABI). The fixed record is [params_run, ret_type]; there is no body.
fn parse_extern_fn(p: *mut Parser) -> u32 {
    p_advance(p); // `extern`
    expect(p, .string_literal); // the ABI string, e.g. "C"
    expect(p, .kw_fn);
    let fn_name: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .l_paren);
    var params: Vec<u32> = vec_new(u32, p.a);
    if !at(p, .r_paren) {
        while true {
            let param_name: u32 = p.tok as u32;
            expect(p, .identifier);
            expect(p, .colon);
            let param_ty: u32 = parse_type(p);
            let param: u32 = add_node(p, .param_decl, param_name, param_ty, 0);
            vec_push(u32, &params, param);
            if !eat(p, .comma) {
                break;
            }
        }
    }
    expect(p, .r_paren);
    expect(p, .arrow);
    let ret_ty: u32 = parse_type(p);
    expect(p, .semicolon);
    let params_run: u32 = emit_list(p, &params);
    vec_free(u32, &params);
    // Fixed record: [params_run, ret_type].
    let ext_rec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, params_run);
    vec_push(u32, &p.extra, ret_ty);
    return add_node(p, .extern_fn, fn_name, ext_rec, 0);
}

// trait := `trait` IDENT `{` (`fn` IDENT `(` Params `)` `->` Type `;`?)* `}`  (P5.10). Each method is a
// bodyless signature stored as a `trait_method` node (main_token = method name; lhs = params run whose
// FIRST param is `self`; rhs = return type). The trailing `;` after a method is OPTIONAL (both `-> R;`
// and `-> R` before the next `fn`/`}` are accepted). The cursor is at the `trait` identifier.
fn parse_trait(p: *mut Parser) -> u32 {
    p_advance(p); // `trait`
    let tname: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .l_brace);
    var methods: Vec<u32> = vec_new(u32, p.a);
    while true {
        if at(p, .r_brace) {
            break;
        }
        if at(p, .eof) {
            record_error(p);
            break;
        }
        let before: usize = p.tok;
        expect(p, .kw_fn);
        let mname: u32 = p.tok as u32;
        expect(p, .identifier);
        expect(p, .l_paren);
        var params: Vec<u32> = vec_new(u32, p.a);
        if !at(p, .r_paren) {
            while true {
                let param_name: u32 = p.tok as u32;
                expect(p, .identifier);
                expect(p, .colon);
                let param_ty: u32 = parse_type(p);
                let param: u32 = add_node(p, .param_decl, param_name, param_ty, 0);
                vec_push(u32, &params, param);
                if !eat(p, .comma) {
                    break;
                }
            }
        }
        expect(p, .r_paren);
        expect(p, .arrow);
        let ret_ty: u32 = parse_type(p);
        eat(p, .semicolon); // optional method terminator
        let mrun: u32 = emit_list(p, &params);
        vec_free(u32, &params);
        let m: u32 = add_node(p, .trait_method, mname, mrun, ret_ty);
        vec_push(u32, &methods, m);
        if p.tok == before {
            p_advance(p); // no-progress guard
        }
        if p.err_count > 100 {
            break;
        }
    }
    expect(p, .r_brace);
    let methods_run: u32 = emit_list(p, &methods);
    vec_free(u32, &methods);
    return add_node(p, .trait_decl, tname, methods_run, 0);
}

// impl := `impl` IDENT `for` IDENT `{` (`fn` ...)* `}`  (P5.10). Each method is a FULL `fn` with a body,
// parsed by `parse_fn` into a `fn_decl` node (its `self` param is a concrete `*mut TYPE`). The fixed rec
// [type_name_tok, methods_run] records the impl target type + the run of `fn_decl` node indices. The
// cursor is at the `impl` identifier.
fn parse_impl(p: *mut Parser) -> u32 {
    p_advance(p); // `impl`
    let trait_tok: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .kw_for);
    let type_tok: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .l_brace);
    var methods: Vec<u32> = vec_new(u32, p.a);
    while true {
        if at(p, .r_brace) {
            break;
        }
        if at(p, .eof) {
            record_error(p);
            break;
        }
        let before: usize = p.tok;
        if at(p, .kw_fn) {
            let m: u32 = parse_fn(p, 0); // a full fn_decl (with a body)
            vec_push(u32, &methods, m);
        } else {
            record_error(p);
            p_advance(p);
        }
        if p.tok == before {
            p_advance(p); // no-progress guard
        }
        if p.err_count > 100 {
            break;
        }
    }
    expect(p, .r_brace);
    let methods_run: u32 = emit_list(p, &methods);
    vec_free(u32, &methods);
    // Fixed rec [type_name_tok, methods_run].
    let irec: u32 = vec_len(u32, &p.extra) as u32;
    vec_push(u32, &p.extra, type_tok);
    vec_push(u32, &p.extra, methods_run);
    return add_node(p, .impl_decl, trait_tok, irec, 0);
}

// decl := `import` STRING `;` | `extern` ... | `trait` ... | `impl` ... | `export`? `open`? (`enum` ... | `fn` ... | `struct` ...)
// `const NAME: T = <const-expr>;` — a module-level constant. main_token = NAME; lhs = the declared
// TYPE node (required in the subset — no inference); rhs = the initializer expr (a constant
// expression: int/char/enum literal or simple arithmetic over such).
fn parse_const(p: *mut Parser) -> u32 {
    p_advance(p); // `const`
    let cname: u32 = p.tok as u32;
    expect(p, .identifier);
    expect(p, .colon);
    let cty: u32 = parse_type(p);
    expect(p, .equal);
    let cinit: u32 = parse_expr(p, 0);
    expect(p, .semicolon);
    return add_node(p, .const_decl, cname, cty, cinit);
}

fn parse_decl(p: *mut Parser) -> u32 {
    // A leading `import "..."` is the module directive (an identifier `import`, not a keyword).
    if at(p, .identifier) {
        if tok_is_import(p, p.tok as u32) {
            return parse_import(p);
        }
        // `trait NAME { .. }` / `impl TRAIT for TYPE { .. }` (P5.10): `trait`/`impl` are identifiers,
        // not lexer keywords, so they are recognized here by lexeme (like `import`).
        if tok_is_trait(p, p.tok as u32) {
            return parse_trait(p);
        }
        if tok_is_impl(p, p.tok as u32) {
            return parse_impl(p);
        }
    }
    // `extern "C" fn NAME(...) -> RET;` — a bodyless C-symbol prototype (P5.8).
    if at(p, .kw_extern) {
        return parse_extern_fn(p);
    }
    var exported: u32 = 0;
    if eat(p, .kw_export) {
        exported = 1;
    }
    // A leading `const` is EITHER a `const fn NAME(..)` (a comptime const FUNCTION) or a module-level
    // `const NAME: T = ..` VALUE. Disambiguate by the token after `const`: a `fn` means the function
    // form — treated as a plain fn in the subset (const-ness is a comptime property, irrelevant to
    // emit). Otherwise it is a constant value. The `exported` flag is not stored for a const value:
    // the loader concatenates all modules into ONE translation unit, so a file-scope `static const`
    // is visible to every use regardless of export.
    if at(p, .kw_const) {
        if at_next(p, 1, .kw_fn) {
            p_advance(p); // consume `const`; `parse_fn` starts at `fn`
            return parse_fn(p, exported);
        }
        return parse_const(p);
    }
    // `open` only ever precedes an `enum` in this subset (an open enum permits `.raw()`).
    var is_open: u32 = 0;
    if eat(p, .kw_open) {
        is_open = 1;
    }
    // `opaque` is a contextual qualifier before `struct` (field privacy in the real grammar). The
    // subset does NOT enforce opacity — a cross-module access-control concern (§31) that is not
    // needed to COMPILE the code — so an `opaque struct` is parsed/typed/emitted EXACTLY as a
    // regular struct. `opaque` is not a lexer keyword (it lexes as a plain identifier, like
    // `trait`/`impl`), so it is recognized here by lexeme and consumed before the `struct` head.
    if at(p, .identifier) {
        if tok_is_opaque(p, p.tok as u32) {
            p_advance(p); // `opaque`
        }
    }
    // `move` (optionally after `opaque`): a linear/move struct qualifier. Consumed and ignored (the
    // subset treats a `move struct` as a regular struct — see `tok_is_move`).
    if at(p, .identifier) {
        if tok_is_move(p, p.tok as u32) {
            p_advance(p); // `move`
        }
    }
    if at(p, .kw_enum) {
        return parse_enum(p, exported, is_open);
    }
    if at(p, .kw_struct) {
        return parse_struct(p, exported);
    }
    if at(p, .kw_fn) {
        return parse_fn(p, exported);
    }
    // Unknown declaration head: record and skip a token so the module loop makes progress.
    record_error(p);
    p_advance(p);
    return 0;
}

// module := Decl*
fn parse_module(p: *mut Parser) -> u32 {
    var decls: Vec<u32> = vec_new(u32, p.a);
    while true {
        if at(p, .eof) {
            break;
        }
        let before: usize = p.tok;
        let d: u32 = parse_decl(p);
        if d != 0 {
            vec_push(u32, &decls, d);
        }
        if p.tok == before {
            p_advance(p); // no-progress guard
        }
        if p.err_count > 100 {
            break;
        }
    }
    let decls_run: u32 = emit_list(p, &decls);
    vec_free(u32, &decls);
    return add_node(p, .module, 0, decls_run, 0);
}

// ----- public entry points -----

// Lex + parse `source` into a fresh arena. The returned `Parser` OWNS its token list and node
// arena (all backed by `a`); free it exactly once with `parser_free`. `source` is borrowed and
// must outlive the parser (nodes reference it for lexeme recovery).
export fn parser_run(source: []const u8, a: *mut dyn Allocator) -> Parser {
    var p: Parser = .{
        .tl = token_list_new(a),
        .source = source,
        .tok = 0,
        .nodes = vec_new(Node, a),
        .extra = vec_new(u32, a),
        .a = a,
        .root = 0,
        .err_count = 0,
        .first_err_tok = 0,
        .sub_name_start = 0,
        .sub_name_len = 0,
        .sub_concrete = 0,
        .cur_fn = 0,
        .pending_gt = false,
    };
    lex(source, &p.tl);
    // Node index 0 is the reserved `.invalid` sentinel ("none").
    add_node(&p, .invalid, 0, 0, 0);
    let r: u32 = parse_module(&p);
    p.root = r;
    return p;
}

// The module (root) node index.
export fn parser_root(p: *Parser) -> u32 {
    return p.root;
}

// Total node count (including the index-0 sentinel).
export fn parser_node_count(p: *Parser) -> u32 {
    return vec_len(Node, &p.nodes) as u32;
}

// The `NodeKind` ordinal of node `i` (via `.raw()`; matches the `open enum` order above).
export fn parser_kind_at(p: *Parser, i: u32) -> u32 {
    let n: Node = vec_get(Node, &p.nodes, i as usize);
    return n.kind.raw();
}

// The `main_token` of node `i` (an index into the token stream).
export fn parser_main_token_at(p: *Parser, i: u32) -> u32 {
    let n: Node = vec_get(Node, &p.nodes, i as usize);
    return n.main_token;
}

// The `lhs` payload of node `i` (a child node index or inline value; 0 = none).
export fn parser_lhs_at(p: *Parser, i: u32) -> u32 {
    let n: Node = vec_get(Node, &p.nodes, i as usize);
    return n.lhs;
}

// The `rhs` payload of node `i` (a child node index or inline value; 0 = none).
export fn parser_rhs_at(p: *Parser, i: u32) -> u32 {
    let n: Node = vec_get(Node, &p.nodes, i as usize);
    return n.rhs;
}

// The `extra` array slot at `i` (for walking length-prefixed runs: `extra[run]` = count).
export fn parser_extra_at(p: *Parser, i: u32) -> u32 {
    return vec_get(u32, &p.extra, i as usize);
}

// Number of parse errors encountered.
export fn parser_err_count(p: *Parser) -> u32 {
    return p.err_count;
}

// The token index of the first parse error (0 if none).
export fn parser_first_err_tok(p: *Parser) -> u32 {
    return p.first_err_tok;
}

// Release the arena + token list. Call exactly once when done.
export fn parser_free(p: *mut Parser) -> void {
    vec_free(Node, &p.nodes);
    vec_free(u32, &p.extra);
    token_list_free(&p.tl);
}
