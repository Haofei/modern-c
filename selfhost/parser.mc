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
    if at(p, .plus)          { return .{ .present = true, .lbp = 17, .rbp = 18, .kind = .bin_add }; }
    if at(p, .minus)         { return .{ .present = true, .lbp = 17, .rbp = 18, .kind = .bin_sub }; }
    if at(p, .star)          { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_mul }; }
    if at(p, .slash)         { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_div }; }
    if at(p, .percent)       { return .{ .present = true, .lbp = 19, .rbp = 20, .kind = .bin_mod }; }
    return .{ .present = false, .lbp = 0, .rbp = 0, .kind = .invalid };
}

// ----- type grammar: IDENT | `*` Type | `*mut` Type | `[]const` Type | `[]mut` Type -----

fn parse_type(p: *mut Parser) -> u32 {
    if eat(p, .star) {
        var is_mut: u32 = 0;
        if eat(p, .kw_mut) {
            is_mut = 1;
        } else if eat(p, .kw_const) {
            is_mut = 0;
        }
        let pointee: u32 = parse_type(p);
        return add_node(p, .type_ptr, 0, pointee, is_mut);
    }
    if at(p, .l_bracket) {
        let br_tok: u32 = p.tok as u32;
        p_advance(p); // `[`
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
    let name_tok: u32 = p.tok as u32;
    if !expect(p, .identifier) {
        return 0;
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

// primary := INT | IDENT | `(` Expr `)`
fn parse_primary(p: *mut Parser) -> u32 {
    if at(p, .integer_literal) {
        let it: u32 = p.tok as u32;
        p_advance(p);
        return add_node(p, .int_literal, it, 0, 0);
    }
    if at(p, .identifier) {
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
            return parse_struct_lit(p);
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
            expect(p, .r_bracket);
            expr = add_node(p, .index, idx_tok, expr, subscript);
            continue;
        }
        if at(p, .dot) {
            p_advance(p); // `.`
            let field_tok: u32 = p.tok as u32;
            expect(p, .identifier);
            expr = add_node(p, .field, field_tok, expr, 0);
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
    let prim: u32 = parse_primary(p);
    return prim;
}

// expr := precedence-climb over the infix table, with postfix applied to each operand.
fn parse_expr(p: *mut Parser, min_bp: u32) -> u32 {
    var lhs: u32 = parse_prefix(p);
    while true {
        lhs = parse_postfix(p, lhs);
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

// switch := `switch` Expr `{` (Pat `=>` Block (`,`)?)* `}`  where Pat is `.` IDENT | `_`.
// (trailing comma allowed, per MC). Each arm is a (pattern-token, block-node) PAIR flushed via
// `emit_pair_list`: the pattern token is the variant IDENT for a `.variant` arm and the `_`
// underscore token for a wildcard arm; sema/emit tell them apart by the token's kind (so no
// separate marker slot is needed). rhs = the arms run; lhs = the subject expr. (Statement form
// only: switch-as-expression and payload-binding `variant(x) =>` are deferred — see the ledger.)
fn parse_switch(p: *mut Parser) -> u32 {
    let sw_tok: u32 = p.tok as u32;
    p_advance(p); // `switch`
    let subject: u32 = parse_expr(p, 0);
    expect(p, .l_brace);
    var arms: Vec<u32> = vec_new(u32, p.a); // (pattern_tok, block_node) pairs
    if !at(p, .r_brace) {
        while true {
            var pat_tok: u32 = p.tok as u32;
            if at(p, .dot) {
                p_advance(p); // `.`
                pat_tok = p.tok as u32; // the variant ident
                expect(p, .identifier);
            } else if at(p, .underscore) {
                pat_tok = p.tok as u32; // the `_` token (recognized by kind at sema/emit)
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
            if !eat(p, .comma) {
                break;
            }
            if at(p, .r_brace) {
                break; // trailing comma
            }
        }
    }
    expect(p, .r_brace);
    let arms_run: u32 = emit_pair_list(p, &arms);
    vec_free(u32, &arms);
    return add_node(p, .switch_stmt, sw_tok, subject, arms_run);
}

// stmt := let | return | if | while | switch | (assign | expr) `;`
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
        return parse_if(p);
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

// decl := `export`? `open`? (`enum` ... | `fn` ... | `struct` ...)
fn parse_decl(p: *mut Parser) -> u32 {
    var exported: u32 = 0;
    if eat(p, .kw_export) {
        exported = 1;
    }
    // `open` only ever precedes an `enum` in this subset (an open enum permits `.raw()`).
    var is_open: u32 = 0;
    if eat(p, .kw_open) {
        is_open = 1;
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
