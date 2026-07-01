// selfhost/sema — mcc2's SEMANTIC ANALYZER (name resolution + type checking), ported from the
// Zig reference (src/sema.zig `checkModule`) as Phase 3 of the self-hosting plan
// (docs/self-host-plan.md). It consumes the Phase-2 flat index-arena AST (selfhost/parser.mc)
// over the Phase-1 token stream (selfhost/lexer.mc) and reports a SUBSET of the reference's
// checks (not its 207 error codes): unknown names, call arg-count/type mismatches, non-bool
// `if`/`while` conditions, `let`-annotation mismatches, return-type mismatches, and
// assign-to-immutable.
//
// DESIGN (two-pass, mirroring the reference):
//   * PASS 1 collects every `fn` signature (param types + return type) into `SmSig` records held
//     in a `Vec<SmSig>`, with a name -> (sig_index + 1) `StrHashMap<u32>` (the +1 keeps 0 as the
//     "absent" sentinel, since MC has no by-value `?u32` — gap G11). Param types are flattened
//     into one `Vec<SmType>` addressed by `(start, count)` per sig.
//   * PASS 2 checks each `fn` body against a per-function locals table `StrHashMap<SmType>`
//     (params seeded first; `let` adds bindings — names are unique per fn, gap G20).
//
// TYPES are a small COPYABLE `SmType { kind, ptr_depth, nstart, nlen }`: `kind` is an `open enum`
// ordinal, `ptr_depth` counts leading `*`/`*mut` (so `*u32` is `{u32, 1}`), and `nstart`/`nlen`
// are source byte offsets of a named (struct) type's identifier for lexeme comparison. Integer
// literals are `int_lit` (untyped): they unify with any concrete numeric type, so
// `let x: u64 = 5;` and `return 5;` from a `-> u32` fn do not spuriously mismatch.
//
// GAP NOTES carried from the ledger and observed here:
//   * G22 flat namespace: every helper is prefixed `sm_` so it cannot collide with the imported
//     lexer/parser (which already own `advance`/`peek`/`make`/`expect`/`at`/...).
//   * G20: the P2 grammar has no `var` — every local is a `let` (immutable) and params are
//     immutable, so ANY assignment target is immutable; the "assign to a mutable local" success
//     path is unreachable in this subset (recorded for the ledger).
//   * G13: token lexemes are recovered by copying `source` into a plain local and precomputing
//     the sub-slice endpoints (a struct-field slice base / `a..a+n` endpoint would not lower).

import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/collections/dynarray.mc";
import "std/collections/hashmap.mc";
import "selfhost/parser.mc";

// The type lattice for the checked subset. `open enum ... : u32` so `.raw()` yields the ordinal
// (used for the contiguous-numeric range test and the gate's first-error code). Numeric kinds
// (`int_lit` .. `isize_`, ordinals 4..14) are kept contiguous so "is numeric" is a range check.
open enum SmKind: u32 {
    unknown,   // 0  error / unresolved
    void_,     // 1
    bool_,     // 2
    slice_,    // 3  `[]const T` / `[]mut T` (element type not tracked in the subset)
    int_lit,   // 4  untyped integer literal (unifies with any concrete numeric)
    u8_,       // 5
    u16_,      // 6
    u32_,      // 7
    u64_,      // 8
    usize_,    // 9
    i8_,       // 10
    i16_,      // 11
    i32_,      // 12
    i64_,      // 13
    isize_,    // 14
    named_,    // 15 a named (struct) type; identify by lexeme at [nstart .. nstart+nlen]
}

// The first-error code surfaced to the gate (an `open enum` so `.raw()` gives the ordinal the C
// driver asserts). Ordinals are the sema-test contract; keep the order stable.
open enum SmErr: u32 {
    none,             // 0
    unknown_name,     // 1
    arg_count,        // 2
    arg_type,         // 3
    not_bool_cond,    // 4
    ret_mismatch,     // 5
    assign_immutable, // 6
    type_mismatch,    // 7  binary-operand / let-annotation mismatch
}

// A resolved type. Copyable (all scalar fields), so it stores freely in `Vec`/`StrHashMap`.
struct SmType {
    kind: SmKind,
    ptr_depth: u32,
    nstart: usize, // named type: source byte offset of the identifier
    nlen: usize,   // named type: identifier byte length
}

// A collected function signature: return type + a `(start, count)` window into `SmState.ptypes`.
struct SmSig {
    ret: SmType,
    param_start: u32,
    param_count: u32,
}

// The analyzer state + owned inputs. `p` OWNS the parser arena (see selfhost/parser.mc); free the
// whole thing exactly once with `sema_free`. `fns`/`sigs`/`ptypes` are the pass-1 symbol table;
// `locals` is rebuilt per function in pass 2; `cur_ret` is the function currently being checked.
struct SmState {
    p: Parser,
    fns: StrHashMap<u32>,      // name -> sig_index + 1 (0 = absent)
    sigs: Vec<SmSig>,
    ptypes: Vec<SmType>,       // flattened param types for all sigs
    locals: StrHashMap<SmType>,// current function's params + lets
    cur_ret: SmType,
    err_count: u32,
    first_err: SmErr,
}

// ----- small constructors + predicates -----

// A depth-0 type of kind `k`.
fn sm_ty(k: SmKind) -> SmType {
    return .{ .kind = k, .ptr_depth = 0, .nstart = 0, .nlen = 0 };
}

// The error/unresolved type.
fn sm_ty_unknown() -> SmType {
    return sm_ty(.unknown);
}

// True when a kind ordinal is numeric: `int_lit` (4) or a concrete integer (5..14).
fn sm_is_num_raw(r: u32) -> bool {
    if r == 4 { return true; }
    if r >= 5 && r <= 14 { return true; }
    return false;
}

// Record an error, remembering the first code (the parser uses the same first-wins convention).
fn sm_err(s: *mut SmState, code: SmErr) -> void {
    if s.err_count == 0 {
        s.first_err = code;
    }
    s.err_count = s.err_count + 1;
}

// ----- arena / token access (all through a plain local `*mut Parser`, per G13) -----

fn sm_node(s: *mut SmState, i: u32) -> Node {
    let par: *mut Parser = &s.p;
    return vec_get(Node, &par.nodes, i as usize);
}

fn sm_extra(s: *mut SmState, i: u32) -> u32 {
    let par: *mut Parser = &s.p;
    return vec_get(u32, &par.extra, i as usize);
}

// The source lexeme of token `tok`. `source` is copied to a local and the sub-slice endpoints are
// precomputed so the slice lowers on the C backend (gap G13).
fn sm_tok_text(s: *mut SmState, tok: u32) -> []const u8 {
    let par: *mut Parser = &s.p;
    let src: []const u8 = par.source;
    let st: usize = token_start_at(&par.tl, tok as usize);
    let ln: usize = token_len_at(&par.tl, tok as usize);
    let end: usize = st + ln;
    return src[st..end];
}

// The lexeme identifying a named type (its offsets were captured at collection time).
fn sm_name_text(s: *mut SmState, t: SmType) -> []const u8 {
    let par: *mut Parser = &s.p;
    let src: []const u8 = par.source;
    let end: usize = t.nstart + t.nlen;
    return src[t.nstart..end];
}

// ----- type construction from AST type nodes -----

// Map a scalar type name lexeme to its `SmKind`, or `.unknown` when it is not a scalar keyword.
fn sm_scalar_kind(txt: []const u8) -> SmKind {
    var b_void: [4]u8 = .{ 118, 111, 105, 100 }; // "void"
    if mem_eql(txt, mem.as_bytes(&b_void)) { return .void_; }
    var b_bool: [4]u8 = .{ 98, 111, 111, 108 }; // "bool"
    if mem_eql(txt, mem.as_bytes(&b_bool)) { return .bool_; }
    var b_u8: [2]u8 = .{ 117, 56 }; // "u8"
    if mem_eql(txt, mem.as_bytes(&b_u8)) { return .u8_; }
    var b_u16: [3]u8 = .{ 117, 49, 54 }; // "u16"
    if mem_eql(txt, mem.as_bytes(&b_u16)) { return .u16_; }
    var b_u32: [3]u8 = .{ 117, 51, 50 }; // "u32"
    if mem_eql(txt, mem.as_bytes(&b_u32)) { return .u32_; }
    var b_u64: [3]u8 = .{ 117, 54, 52 }; // "u64"
    if mem_eql(txt, mem.as_bytes(&b_u64)) { return .u64_; }
    var b_usize: [5]u8 = .{ 117, 115, 105, 122, 101 }; // "usize"
    if mem_eql(txt, mem.as_bytes(&b_usize)) { return .usize_; }
    var b_i8: [2]u8 = .{ 105, 56 }; // "i8"
    if mem_eql(txt, mem.as_bytes(&b_i8)) { return .i8_; }
    var b_i16: [3]u8 = .{ 105, 49, 54 }; // "i16"
    if mem_eql(txt, mem.as_bytes(&b_i16)) { return .i16_; }
    var b_i32: [3]u8 = .{ 105, 51, 50 }; // "i32"
    if mem_eql(txt, mem.as_bytes(&b_i32)) { return .i32_; }
    var b_i64: [3]u8 = .{ 105, 54, 52 }; // "i64"
    if mem_eql(txt, mem.as_bytes(&b_i64)) { return .i64_; }
    var b_isize: [5]u8 = .{ 105, 115, 105, 122, 101 }; // "isize"
    if mem_eql(txt, mem.as_bytes(&b_isize)) { return .isize_; }
    return .unknown;
}

// Resolve an AST type node into an `SmType`. `*T` bumps `ptr_depth`; a slice becomes `slice_`;
// an unknown identifier becomes a `named_` type carrying its lexeme offsets for later comparison.
fn sm_type_from_node(s: *mut SmState, tn: u32) -> SmType {
    if tn == 0 {
        return sm_ty_unknown();
    }
    let nd: Node = sm_node(s, tn);
    if nd.kind == .type_ptr {
        var inner: SmType = sm_type_from_node(s, nd.lhs);
        inner.ptr_depth = inner.ptr_depth + 1;
        return inner;
    }
    if nd.kind == .type_slice_const {
        return sm_ty(.slice_);
    }
    if nd.kind == .type_slice_mut {
        return sm_ty(.slice_);
    }
    if nd.kind == .type_name {
        let par: *mut Parser = &s.p;
        let st: usize = token_start_at(&par.tl, nd.main_token as usize);
        let ln: usize = token_len_at(&par.tl, nd.main_token as usize);
        let txt: []const u8 = sm_tok_text(s, nd.main_token);
        let k: SmKind = sm_scalar_kind(txt);
        if k.raw() == 0 {
            return .{ .kind = .named_, .ptr_depth = 0, .nstart = st, .nlen = ln };
        }
        return sm_ty(k);
    }
    return sm_ty_unknown();
}

// ----- type compatibility -----

// Structural type equality with untyped-int-literal unification: an `int_lit` operand matches any
// concrete numeric type (and vice versa); pointers must agree in depth and base; named types are
// compared by lexeme. Two operands are never compared as `call() == call()` (gap G23): each side
// is bound to a local first.
fn sm_types_match(s: *mut SmState, a: SmType, b: SmType) -> bool {
    if a.ptr_depth != b.ptr_depth {
        return false;
    }
    let ak: u32 = a.kind.raw();
    let bk: u32 = b.kind.raw();
    let a_num: bool = sm_is_num_raw(ak);
    let b_num: bool = sm_is_num_raw(bk);
    if ak == 4 && b_num {
        return true;
    }
    if bk == 4 && a_num {
        return true;
    }
    if ak != bk {
        return false;
    }
    if ak == 15 {
        let ta: []const u8 = sm_name_text(s, a);
        let tb: []const u8 = sm_name_text(s, b);
        return mem_eql(ta, tb);
    }
    return true;
}

// The more-concrete of two unified numeric types (an `int_lit` yields to a concrete numeric).
fn sm_concrete(a: SmType, b: SmType) -> SmType {
    if a.kind.raw() == 4 {
        return b;
    }
    return a;
}

// ----- expression typing -----

// Resolve a bare identifier: a local/param yields its bound type; a function name resolves (no
// error) but has no value type in the subset (`unknown`); anything else is an unknown-name error.
fn sm_type_of_ident(s: *mut SmState, tok: u32) -> SmType {
    let name: []const u8 = sm_tok_text(s, tok);
    let is_local: bool = strmap_contains(SmType, &s.locals, name);
    if is_local {
        return strmap_get_or(SmType, &s.locals, name, sm_ty_unknown());
    }
    let is_fn: bool = strmap_contains(u32, &s.fns, name);
    if is_fn {
        return sm_ty_unknown();
    }
    sm_err(s, .unknown_name);
    return sm_ty_unknown();
}

// Binary arithmetic (`+ - * / %`): both operands the same numeric type -> that type.
fn sm_arith(s: *mut SmState, nd: Node) -> SmType {
    let lt: SmType = sm_type_of_expr(s, nd.lhs);
    let rt: SmType = sm_type_of_expr(s, nd.rhs);
    let lnum: bool = sm_is_num_raw(lt.kind.raw());
    let rnum: bool = sm_is_num_raw(rt.kind.raw());
    let m: bool = sm_types_match(s, lt, rt);
    if lnum && rnum && m {
        return sm_concrete(lt, rt);
    }
    sm_err(s, .type_mismatch);
    return sm_ty_unknown();
}

// Comparison (`== != < > <= >=`): operands comparable (same type) -> `bool`.
fn sm_cmp(s: *mut SmState, nd: Node) -> SmType {
    let lt: SmType = sm_type_of_expr(s, nd.lhs);
    let rt: SmType = sm_type_of_expr(s, nd.rhs);
    let m: bool = sm_types_match(s, lt, rt);
    if m {
        return sm_ty(.bool_);
    }
    sm_err(s, .type_mismatch);
    return sm_ty(.bool_);
}

// Logical (`&& ||`): both operands `bool` -> `bool`.
fn sm_logic(s: *mut SmState, nd: Node) -> SmType {
    let lt: SmType = sm_type_of_expr(s, nd.lhs);
    let rt: SmType = sm_type_of_expr(s, nd.rhs);
    // Bind each `.raw()` result to a local before comparing (a `<call> == <lit>` operand in a
    // let-init cannot recover its operand type in the C backend — gap G23).
    let lraw: u32 = lt.kind.raw();
    let rraw: u32 = rt.kind.raw();
    let lb: bool = lraw == 2;
    let rb: bool = rraw == 2;
    if lb && rb {
        return sm_ty(.bool_);
    }
    sm_err(s, .type_mismatch);
    return sm_ty(.bool_);
}

// Walk a length-prefixed argument run purely for its side-effects (error collection), ignoring
// the arg types — used on the error/indirect-callee paths where there is no signature to match.
fn sm_walk_args(s: *mut SmState, args_run: u32, argc: u32) -> void {
    var i: u32 = 0;
    while i < argc {
        let an: u32 = sm_extra(s, args_run + 1 + i);
        sm_type_of_expr(s, an); // discard: only errors matter here
        i = i + 1;
    }
}

// Type-check a call: callee names a known fn; arg count matches; each arg type matches its param.
fn sm_check_call(s: *mut SmState, node: u32) -> SmType {
    let nd: Node = sm_node(s, node);
    let callee: u32 = nd.lhs;
    let args_run: u32 = nd.rhs;
    let argc: u32 = sm_extra(s, args_run);
    let cnode: Node = sm_node(s, callee);
    if cnode.kind != .ident_expr {
        sm_type_of_expr(s, callee); // discard: walk an indirect callee for errors
        sm_walk_args(s, args_run, argc);
        return sm_ty_unknown();
    }
    let name: []const u8 = sm_tok_text(s, cnode.main_token);
    let present: bool = strmap_contains(u32, &s.fns, name);
    if !present {
        sm_err(s, .unknown_name);
        sm_walk_args(s, args_run, argc);
        return sm_ty_unknown();
    }
    let sig_ref: u32 = strmap_get_or(u32, &s.fns, name, 0);
    let sig_idx: u32 = sig_ref - 1;
    let sig: SmSig = vec_get(SmSig, &s.sigs, sig_idx as usize);
    if argc != sig.param_count {
        sm_err(s, .arg_count);
    }
    var i: u32 = 0;
    while i < argc {
        let an: u32 = sm_extra(s, args_run + 1 + i);
        let at: SmType = sm_type_of_expr(s, an);
        if i < sig.param_count {
            let pty: SmType = vec_get(SmType, &s.ptypes, (sig.param_start + i) as usize);
            let matched: bool = sm_types_match(s, pty, at);
            if !matched {
                sm_err(s, .arg_type);
            }
        }
        i = i + 1;
    }
    return sig.ret;
}

// The type of an expression node (recursively). Dispatches over `NodeKind` with a `switch`; the
// open enum forces a `_` default (there is no exhaustiveness help — see the ledger note).
fn sm_type_of_expr(s: *mut SmState, node: u32) -> SmType {
    let nd: Node = sm_node(s, node);
    switch nd.kind {
        .int_literal => { return sm_ty(.int_lit); }
        .ident_expr => { return sm_type_of_ident(s, nd.main_token); }
        .call => { return sm_check_call(s, node); }
        .un_neg => {
            let t: SmType = sm_type_of_expr(s, nd.lhs);
            if sm_is_num_raw(t.kind.raw()) { return t; }
            sm_err(s, .type_mismatch);
            return t;
        }
        .un_not => {
            let t: SmType = sm_type_of_expr(s, nd.lhs);
            if t.kind.raw() == 2 { return sm_ty(.bool_); }
            sm_err(s, .type_mismatch);
            return sm_ty(.bool_);
        }
        .index => {
            sm_type_of_expr(s, nd.lhs); // discard: walk base + subscript for errors
            sm_type_of_expr(s, nd.rhs);
            return sm_ty_unknown();
        }
        .field => {
            sm_type_of_expr(s, nd.lhs); // discard: field types are not tracked in the subset
            return sm_ty_unknown();
        }
        .bin_add => { return sm_arith(s, nd); }
        .bin_sub => { return sm_arith(s, nd); }
        .bin_mul => { return sm_arith(s, nd); }
        .bin_div => { return sm_arith(s, nd); }
        .bin_mod => { return sm_arith(s, nd); }
        .bin_eq => { return sm_cmp(s, nd); }
        .bin_ne => { return sm_cmp(s, nd); }
        .bin_lt => { return sm_cmp(s, nd); }
        .bin_gt => { return sm_cmp(s, nd); }
        .bin_le => { return sm_cmp(s, nd); }
        .bin_ge => { return sm_cmp(s, nd); }
        .bin_lor => { return sm_logic(s, nd); }
        .bin_land => { return sm_logic(s, nd); }
        _ => { return sm_ty_unknown(); }
    }
}

// ----- statement + block checking -----

// Type-check one statement (also dispatches nested blocks, e.g. an `if`/`while` body or an
// `else` block, which arrive here as `.block`; an `else if` chain arrives as `.if_stmt`).
fn sm_check_stmt(s: *mut SmState, node: u32) -> void {
    let nd: Node = sm_node(s, node);
    if nd.kind == .block {
        sm_check_block(s, node);
        return;
    }
    if nd.kind == .let_decl {
        let it: SmType = sm_type_of_expr(s, nd.rhs);
        var bind_ty: SmType = it;
        if nd.lhs != 0 {
            let ann: SmType = sm_type_from_node(s, nd.lhs);
            let matched: bool = sm_types_match(s, ann, it);
            if !matched {
                sm_err(s, .type_mismatch);
            }
            bind_ty = ann;
        }
        let name: []const u8 = sm_tok_text(s, nd.main_token);
        strmap_put(SmType, &s.locals, name, bind_ty);
        return;
    }
    if nd.kind == .return_stmt {
        if nd.lhs == 0 {
            if s.cur_ret.kind != .void_ {
                sm_err(s, .ret_mismatch);
            }
            return;
        }
        let vt: SmType = sm_type_of_expr(s, nd.lhs);
        let matched: bool = sm_types_match(s, s.cur_ret, vt);
        if !matched {
            sm_err(s, .ret_mismatch);
        }
        return;
    }
    if nd.kind == .if_stmt {
        let ct: SmType = sm_type_of_expr(s, nd.lhs);
        if ct.kind != .bool_ {
            sm_err(s, .not_bool_cond);
        }
        let then_b: u32 = sm_extra(s, nd.rhs);
        let else_b: u32 = sm_extra(s, nd.rhs + 1);
        sm_check_stmt(s, then_b);
        if else_b != 0 {
            sm_check_stmt(s, else_b);
        }
        return;
    }
    if nd.kind == .while_stmt {
        let ct: SmType = sm_type_of_expr(s, nd.lhs);
        if ct.kind != .bool_ {
            sm_err(s, .not_bool_cond);
        }
        sm_check_stmt(s, nd.rhs);
        return;
    }
    if nd.kind == .assign {
        sm_type_of_expr(s, nd.rhs); // discard: walk rhs for errors (unknown names, etc.)
        let lnode: Node = sm_node(s, nd.lhs);
        if lnode.kind == .ident_expr {
            let name: []const u8 = sm_tok_text(s, lnode.main_token);
            let is_local: bool = strmap_contains(SmType, &s.locals, name);
            if is_local {
                // Every binding in the P2 subset is immutable (no `var`; params immutable, G20).
                sm_err(s, .assign_immutable);
                return;
            }
        }
        sm_type_of_expr(s, nd.lhs); // discard: not a known binding -> surface an unknown-name error
        return;
    }
    if nd.kind == .expr_stmt {
        sm_type_of_expr(s, nd.lhs); // discard: walk for errors
        return;
    }
}

// Type-check every statement in a block (its `lhs` is a length-prefixed run of stmt indices).
fn sm_check_block(s: *mut SmState, block: u32) -> void {
    let nd: Node = sm_node(s, block);
    let run: u32 = nd.lhs;
    let count: u32 = sm_extra(s, run);
    var i: u32 = 0;
    while i < count {
        let stmt: u32 = sm_extra(s, run + 1 + i);
        sm_check_stmt(s, stmt);
        i = i + 1;
    }
}

// ----- module driver (two passes) -----

// PASS 1: collect one `SmSig` per `fn` decl and register its name -> (index + 1).
fn sm_collect(s: *mut SmState, root: u32) -> void {
    let rnode: Node = sm_node(s, root);
    let drun: u32 = rnode.lhs;
    let dcount: u32 = sm_extra(s, drun);
    var di: u32 = 0;
    while di < dcount {
        let d: u32 = sm_extra(s, drun + 1 + di);
        let dn: Node = sm_node(s, d);
        if dn.kind == .fn_decl {
            let frec: u32 = dn.lhs;
            let params_run: u32 = sm_extra(s, frec + 1);
            let ret_node: u32 = sm_extra(s, frec + 2);
            let ret_ty: SmType = sm_type_from_node(s, ret_node);
            let pcount: u32 = sm_extra(s, params_run);
            let pstart: u32 = vec_len(SmType, &s.ptypes) as u32;
            var pi: u32 = 0;
            while pi < pcount {
                let pnode: u32 = sm_extra(s, params_run + 1 + pi);
                let pn: Node = sm_node(s, pnode);
                let pty: SmType = sm_type_from_node(s, pn.lhs);
                vec_push(SmType, &s.ptypes, pty);
                pi = pi + 1;
            }
            let sig_idx: u32 = vec_len(SmSig, &s.sigs) as u32;
            vec_push(SmSig, &s.sigs, .{ .ret = ret_ty, .param_start = pstart, .param_count = pcount });
            let name: []const u8 = sm_tok_text(s, dn.main_token);
            strmap_put(u32, &s.fns, name, sig_idx + 1);
        }
        di = di + 1;
    }
}

// PASS 2: check each `fn` body with a fresh per-function locals table seeded with its params.
fn sm_check_fns(s: *mut SmState, root: u32) -> void {
    let rnode: Node = sm_node(s, root);
    let drun: u32 = rnode.lhs;
    let dcount: u32 = sm_extra(s, drun);
    var di: u32 = 0;
    while di < dcount {
        let d: u32 = sm_extra(s, drun + 1 + di);
        let dn: Node = sm_node(s, d);
        if dn.kind == .fn_decl {
            let frec: u32 = dn.lhs;
            let params_run: u32 = sm_extra(s, frec + 1);
            let ret_node: u32 = sm_extra(s, frec + 2);
            let body: u32 = sm_extra(s, frec + 3);
            // Reset the locals table (reusable after free) and seed the params.
            strmap_free(SmType, &s.locals);
            s.cur_ret = sm_type_from_node(s, ret_node);
            let pcount: u32 = sm_extra(s, params_run);
            var pi: u32 = 0;
            while pi < pcount {
                let pnode: u32 = sm_extra(s, params_run + 1 + pi);
                let pn: Node = sm_node(s, pnode);
                let pty: SmType = sm_type_from_node(s, pn.lhs);
                let pname: []const u8 = sm_tok_text(s, pn.main_token);
                strmap_put(SmType, &s.locals, pname, pty);
                pi = pi + 1;
            }
            sm_check_block(s, body);
        }
        di = di + 1;
    }
}

// ----- public entry points -----

// Lex + parse + type-check `source`. The returned `SmState` OWNS its parser arena and symbol
// tables (all backed by `a`); free it exactly once with `sema_free`. `source` is borrowed and
// must outlive the state (types reference it for named-type lexeme comparison).
export fn sema_check(source: []const u8, a: *mut dyn Allocator) -> SmState {
    var s: SmState = .{
        .p = parser_run(source, a),
        .fns = strmap_new(u32, a),
        .sigs = vec_new(SmSig, a),
        .ptypes = vec_new(SmType, a),
        .locals = strmap_new(SmType, a),
        .cur_ret = sm_ty_unknown(),
        .err_count = 0,
        .first_err = .none,
    };
    let root: u32 = parser_root(&s.p);
    sm_collect(&s, root);
    sm_check_fns(&s, root);
    return s;
}

// Number of semantic errors found (parse errors are separate; see `sema_parse_err_count`).
export fn sema_err_count(s: *SmState) -> u32 {
    return s.err_count;
}

// The first semantic error's code ordinal (0 = none; see `SmErr`).
export fn sema_first_err(s: *SmState) -> u32 {
    return s.first_err.raw();
}

// Number of PARSE errors (so a gate can separate malformed input from type errors).
export fn sema_parse_err_count(s: *SmState) -> u32 {
    return parser_err_count(&s.p);
}

// Release the parser arena and all symbol tables. Call exactly once when done.
export fn sema_free(s: *mut SmState) -> void {
    strmap_free(SmType, &s.locals);
    strmap_free(u32, &s.fns);
    vec_free(SmSig, &s.sigs);
    vec_free(SmType, &s.ptypes);
    parser_free(&s.p);
}
