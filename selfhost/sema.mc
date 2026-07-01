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
    unknown_field,    // 8  member access / struct-literal field not present on the struct
    struct_target,    // 9  struct literal `.{...}` used where no struct target type is known
    unknown_variant,  // 10 `.variant` names a variant not present on the expected enum
    enum_target,      // 11 `.variant` used where no enum target type is known
    // ----- P5.3 switch-statement additions (appended to keep prior ordinals stable) -----
    nonexhaustive_switch, // 12 closed enum switch misses a variant with no `_`, or an open enum lacks `_`
    duplicate_arm,        // 13 two arms name the same enum variant
    switch_subject,       // 14 switch subject is not an enum-typed value
}

// A resolved type. Copyable (all scalar fields), so it stores freely in `Vec`/`StrHashMap`.
struct SmType {
    kind: SmKind,
    ptr_depth: u32,
    nstart: usize, // named type: source byte offset of the identifier
    nlen: usize,   // named type: identifier byte length
}

// A collected function signature: return type + a `(start, count)` window into `SmState.ptypes`.
// P5.5: a GENERIC fn (one with a leading `comptime T: type` param) sets `is_generic = 1` and
// records its type-param lexeme offsets; `ret_is_tparam = 1` when the declared return type is
// exactly that type param (so a call substitutes the concrete type-arg's kind for the result).
// `param_count` is the DECLARED arity (comptime param included), which the call's arg count must
// match. Generic-fn bodies are not type-checked in the subset (the type param is abstract).
struct SmSig {
    ret: SmType,
    param_start: u32,
    param_count: u32,
    is_generic: u32,
    tparam_start: usize,
    tparam_len: usize,
    ret_is_tparam: u32,
}

// One struct field: its name (recovered by lexeme offsets, like a named `SmType`) + resolved type.
struct SmField {
    nstart: usize,
    nlen: usize,
    ty: SmType,
}

// A collected struct definition: a `(start, count)` window into `SmState.fields`. P5.5: a GENERIC
// struct (`struct S<T> {..}`) sets `is_generic = 1`; a struct literal targeting it only has its
// field NAMES checked (field-type matching is skipped, since the field type may be the abstract T).
struct SmStruct {
    field_start: u32,
    field_count: u32,
    is_generic: u32,
}

// One enum variant: its name (recovered by lexeme offsets, like a named `SmType`).
struct SmEVar {
    nstart: usize,
    nlen: usize,
}

// A collected enum definition: a `(start, count)` window into `SmState.evariants` plus the repr
// integer kind (the type `.raw()` yields; defaults to `u32_` when the enum omits `: TYPE`).
struct SmEnum {
    variant_start: u32,
    variant_count: u32,
    repr: SmKind,
    is_open: u32, // 1 when declared `open` (a switch then REQUIRES a `_` arm — see sm_check_switch)
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
    muts: StrHashMap<u32>,     // current function's MUTABLE locals (a `var`); value 1 = mutable
    structs: StrHashMap<u32>,  // struct name -> struct_defs index + 1 (0 = absent)
    struct_defs: Vec<SmStruct>,
    fields: Vec<SmField>,      // flattened fields for all structs
    enums: StrHashMap<u32>,    // enum name -> enum_defs index + 1 (0 = absent)
    enum_defs: Vec<SmEnum>,
    evariants: Vec<SmEVar>,    // flattened variants for all enums
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

// The lexeme naming a struct field (offsets captured at collection time, like `sm_name_text`).
fn sm_field_name(s: *mut SmState, f: SmField) -> []const u8 {
    let par: *mut Parser = &s.p;
    let src: []const u8 = par.source;
    let end: usize = f.nstart + f.nlen;
    return src[f.nstart..end];
}

// The lexeme naming an enum variant (offsets captured at collection time, like `sm_field_name`).
fn sm_evar_name(s: *mut SmState, v: SmEVar) -> []const u8 {
    let par: *mut Parser = &s.p;
    let src: []const u8 = par.source;
    let end: usize = v.nstart + v.nlen;
    return src[v.nstart..end];
}

// True when a named type identifies a KNOWN enum (used to route `.raw()` and `.variant` handling
// away from the struct paths, since both structs and enums resolve to `named_`).
fn sm_is_enum_type(s: *mut SmState, t: SmType) -> bool {
    if t.kind.raw() != 15 {
        return false;
    }
    let name: []const u8 = sm_name_text(s, t);
    return strmap_contains(u32, &s.enums, name);
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
    // A generic instance `S<T>` (P5.5) resolves to a `named_` type carrying the BASE name's lexeme
    // offsets — enough for struct-literal field-NAME checking (which is all generic instances get in
    // the subset). The concrete type argument is not tracked in the resolved type.
    if nd.kind == .type_generic {
        let par: *mut Parser = &s.p;
        let gst: usize = token_start_at(&par.tl, nd.main_token as usize);
        let gln: usize = token_len_at(&par.tl, nd.main_token as usize);
        return .{ .kind = .named_, .ptr_depth = 0, .nstart = gst, .nlen = gln };
    }
    // The `type` keyword annotation of a `comptime T: type` param has no value type in the subset.
    if nd.kind == .type_kw {
        return sm_ty_unknown();
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

// Comparison (`== != < > <= >=`): operands comparable (same type) -> `bool`. A bare `.variant`
// literal has no standalone type, so when one side is an `enum_lit` it is resolved against the
// OTHER operand's (enum) type — this is where `x == .green` gets its enum.
fn sm_cmp(s: *mut SmState, nd: Node) -> SmType {
    let lnode: Node = sm_node(s, nd.lhs);
    let rnode: Node = sm_node(s, nd.rhs);
    let l_lit: bool = lnode.kind == .enum_lit;
    let r_lit: bool = rnode.kind == .enum_lit;
    if r_lit && !l_lit {
        let lt2: SmType = sm_type_of_expr(s, nd.lhs);
        sm_check_enum_lit(s, nd.rhs, lt2);
        return sm_ty(.bool_);
    }
    if l_lit && !r_lit {
        let rt2: SmType = sm_type_of_expr(s, nd.rhs);
        sm_check_enum_lit(s, nd.lhs, rt2);
        return sm_ty(.bool_);
    }
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
    // `enumval.raw()` is a method-shaped call: callee is a `.field` named `raw` with zero args on an
    // enum-typed receiver. It yields the enum's repr integer type. (Closed enums reject `.raw()` in
    // the full language, but the subset does not model closedness — see the ledger.)
    if cnode.kind == .field {
        var b_raw: [3]u8 = .{ 114, 97, 119 }; // "raw"
        let fname: []const u8 = sm_tok_text(s, cnode.main_token);
        let is_raw: bool = mem_eql(fname, mem.as_bytes(&b_raw));
        if is_raw && argc == 0 {
            let recv: SmType = sm_type_of_expr(s, cnode.lhs);
            if sm_is_enum_type(s, recv) {
                let rname: []const u8 = sm_name_text(s, recv);
                let eref: u32 = strmap_get_or(u32, &s.enums, rname, 0);
                let ed: SmEnum = vec_get(SmEnum, &s.enum_defs, (eref - 1) as usize);
                return sm_ty(ed.repr);
            }
            // `.raw()` on a non-enum is outside the subset; yield unknown without a spurious error.
            return sm_ty_unknown();
        }
    }
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
    // P5.5: a GENERIC call `f(u32, ...)` — the first arg is the type argument. Only ARITY is
    // checked (against the declared param count, comptime param included); the abstract-typed value
    // args are not individually type-checked in the subset (see the ledger). The result type is the
    // concrete type-arg's kind when the return type is the type param, else the declared return.
    if sig.is_generic == 1 {
        if argc != sig.param_count {
            sm_err(s, .arg_count);
        }
        if sig.ret_is_tparam == 1 && argc >= 1 {
            let a0: u32 = sm_extra(s, args_run + 1);
            let a0n: Node = sm_node(s, a0);
            if a0n.kind == .ident_expr {
                let a0text: []const u8 = sm_tok_text(s, a0n.main_token);
                let ak: SmKind = sm_scalar_kind(a0text);
                return sm_ty(ak);
            }
        }
        return sig.ret;
    }
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

// Resolve `obj.field`: `obj` must be a named struct type (a bare value or a pointer-to-struct —
// the subset dereferences implicitly). Returns the field's type, or reports `unknown_field` and
// yields `unknown` when the base is not a known struct or the field is absent.
fn sm_field_type(s: *mut SmState, obj: SmType, field_tok: u32) -> SmType {
    if obj.kind.raw() != 15 {
        sm_err(s, .unknown_field);
        return sm_ty_unknown();
    }
    let sname: []const u8 = sm_name_text(s, obj);
    let present: bool = strmap_contains(u32, &s.structs, sname);
    if !present {
        sm_err(s, .unknown_field);
        return sm_ty_unknown();
    }
    let sref: u32 = strmap_get_or(u32, &s.structs, sname, 0);
    let sidx: u32 = sref - 1;
    let sd: SmStruct = vec_get(SmStruct, &s.struct_defs, sidx as usize);
    let ftext: []const u8 = sm_tok_text(s, field_tok);
    var fi: u32 = 0;
    while fi < sd.field_count {
        let f: SmField = vec_get(SmField, &s.fields, (sd.field_start + fi) as usize);
        let fname: []const u8 = sm_field_name(s, f);
        let m: bool = mem_eql(ftext, fname);
        if m {
            return f.ty;
        }
        fi = fi + 1;
    }
    sm_err(s, .unknown_field);
    return sm_ty_unknown();
}

// Check a struct literal `.{ .f = e, ... }` against a KNOWN expected type. Each field must exist on
// the target struct (else `unknown_field`) and its value type must match the field type. A literal
// whose expected type is not a known struct reports `struct_target` (values are still walked for
// nested errors).
fn sm_check_struct_lit(s: *mut SmState, node: u32, expected: SmType) -> void {
    let nd: Node = sm_node(s, node);
    let run: u32 = nd.lhs;
    let fcount: u32 = sm_extra(s, run);
    let ek: u32 = expected.kind.raw();
    var known: bool = false;
    var gen: bool = false;
    if ek == 15 {
        let sname: []const u8 = sm_name_text(s, expected);
        known = strmap_contains(u32, &s.structs, sname);
        if known {
            // A GENERIC target struct (P5.5): only field NAMES are checked below — field-TYPE
            // matching is skipped because the field type may be the abstract type param T.
            let sref: u32 = strmap_get_or(u32, &s.structs, sname, 0);
            let sd: SmStruct = vec_get(SmStruct, &s.struct_defs, (sref - 1) as usize);
            if sd.is_generic == 1 {
                gen = true;
            }
        }
    }
    if !known {
        sm_err(s, .struct_target);
    }
    var fi: u32 = 0;
    while fi < fcount {
        let fname_tok: u32 = sm_extra(s, run + 1 + fi * 2);
        let val_node: u32 = sm_extra(s, run + 1 + fi * 2 + 1);
        let vt: SmType = sm_type_of_expr(s, val_node);
        if known {
            let ft: SmType = sm_field_type(s, expected, fname_tok);
            let fk: u32 = ft.kind.raw();
            if fk != 0 && !gen {
                let m: bool = sm_types_match(s, ft, vt);
                if !m {
                    sm_err(s, .type_mismatch);
                }
            }
        }
        fi = fi + 1;
    }
}

// Check an enum literal `.variant` against a KNOWN expected type. The expected type must be a known
// enum (else `enum_target`) and the variant must be one of its cases (else `unknown_variant`). No
// value is returned: callers already know the resolved type is `expected` (this only diagnoses).
fn sm_check_enum_lit(s: *mut SmState, node: u32, expected: SmType) -> void {
    let nd: Node = sm_node(s, node);
    let vtext: []const u8 = sm_tok_text(s, nd.main_token);
    let is_enum: bool = sm_is_enum_type(s, expected);
    if !is_enum {
        sm_err(s, .enum_target);
        return;
    }
    let ename: []const u8 = sm_name_text(s, expected);
    let eref: u32 = strmap_get_or(u32, &s.enums, ename, 0);
    let ed: SmEnum = vec_get(SmEnum, &s.enum_defs, (eref - 1) as usize);
    var found: bool = false;
    var vi: u32 = 0;
    while vi < ed.variant_count {
        let v: SmEVar = vec_get(SmEVar, &s.evariants, (ed.variant_start + vi) as usize);
        let vn: []const u8 = sm_evar_name(s, v);
        let m: bool = mem_eql(vtext, vn);
        if m {
            found = true;
        }
        vi = vi + 1;
    }
    if !found {
        sm_err(s, .unknown_variant);
    }
}

// True when an assignment target's root binding is a mutable local (`var`). Walks through member
// (`.f`) and index (`[i]`) chains to the root identifier; anything else is not assignable.
fn sm_target_mutable(s: *mut SmState, node: u32) -> bool {
    let nd: Node = sm_node(s, node);
    if nd.kind == .ident_expr {
        let name: []const u8 = sm_tok_text(s, nd.main_token);
        return strmap_contains(u32, &s.muts, name);
    }
    if nd.kind == .field {
        return sm_target_mutable(s, nd.lhs);
    }
    if nd.kind == .index {
        return sm_target_mutable(s, nd.lhs);
    }
    return false;
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
            let obj: SmType = sm_type_of_expr(s, nd.lhs);
            return sm_field_type(s, obj, nd.main_token);
        }
        .struct_lit => {
            // A struct literal is only valid where a struct target type is known (a typed `let`/
            // `var` init or a `-> S` return); reaching it here means no target was threaded in.
            sm_check_struct_lit(s, node, sm_ty_unknown());
            return sm_ty_unknown();
        }
        .enum_lit => {
            // Likewise an enum literal needs an expected enum type (typed init/return, or the
            // other side of a comparison); reaching it here means none was threaded in.
            sm_check_enum_lit(s, node, sm_ty_unknown());
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

// ----- switch-statement checking -----

// True when arm-pattern token `tok` is the `_` wildcard (a `.variant` arm stores an `identifier`
// token instead). Both operands are bound to locals before comparing, per gap G23.
fn sm_arm_is_wild(s: *mut SmState, tok: u32) -> bool {
    let par: *mut Parser = &s.p;
    let k: u32 = token_kind_at(&par.tl, tok as usize);
    let uw: TokKind = .underscore;
    let want: u32 = uw.raw();
    return k == want;
}

// True when the named variant lexeme `vtext` is one of enum `ed`'s variants.
fn sm_enum_has_variant(s: *mut SmState, ed: SmEnum, vtext: []const u8) -> bool {
    var found: bool = false;
    var vi: u32 = 0;
    while vi < ed.variant_count {
        let v: SmEVar = vec_get(SmEVar, &s.evariants, (ed.variant_start + vi) as usize);
        let vn: []const u8 = sm_evar_name(s, v);
        let m: bool = mem_eql(vtext, vn);
        if m {
            found = true;
        }
        vi = vi + 1;
    }
    return found;
}

// True when some `.variant` arm in the run covers the variant lexeme `vtext` (used for the
// closed-enum exhaustiveness sweep). Wildcard arms are skipped (they are handled separately).
fn sm_switch_covers(s: *mut SmState, run: u32, arm_count: u32, vtext: []const u8) -> bool {
    var covered: bool = false;
    var ai: u32 = 0;
    while ai < arm_count {
        let pat_tok: u32 = sm_extra(s, run + 1 + ai * 2);
        let is_wild: bool = sm_arm_is_wild(s, pat_tok);
        if !is_wild {
            let ptext: []const u8 = sm_tok_text(s, pat_tok);
            let m: bool = mem_eql(vtext, ptext);
            if m {
                covered = true;
            }
        }
        ai = ai + 1;
    }
    return covered;
}

// Check a `switch EXPR { .variant => {..}, _ => {..} }`. The subject must be enum-typed; each
// `.variant` pattern must be a case of that enum (else `unknown_variant`) and appear at most once
// (else `duplicate_arm`); a `_` is the default. EXHAUSTIVENESS: a CLOSED enum with no `_` must
// cover every variant (else `nonexhaustive_switch`); an OPEN enum REQUIRES a `_` (else
// `nonexhaustive_switch`). Every arm block is checked regardless of pattern validity.
fn sm_check_switch(s: *mut SmState, node: u32) -> void {
    let nd: Node = sm_node(s, node);
    let subj_ty: SmType = sm_type_of_expr(s, nd.lhs);
    let run: u32 = nd.rhs;
    let arm_count: u32 = sm_extra(s, run);
    let is_enum: bool = sm_is_enum_type(s, subj_ty);
    if !is_enum {
        sm_err(s, .switch_subject);
        // Still walk every arm block so nested errors are not lost.
        var wi: u32 = 0;
        while wi < arm_count {
            let blk: u32 = sm_extra(s, run + 1 + wi * 2 + 1);
            sm_check_stmt(s, blk);
            wi = wi + 1;
        }
        return;
    }
    let ename: []const u8 = sm_name_text(s, subj_ty);
    let eref: u32 = strmap_get_or(u32, &s.enums, ename, 0);
    let ed: SmEnum = vec_get(SmEnum, &s.enum_defs, (eref - 1) as usize);
    var has_default: bool = false;
    var ai: u32 = 0;
    while ai < arm_count {
        let pat_tok: u32 = sm_extra(s, run + 1 + ai * 2);
        let blk: u32 = sm_extra(s, run + 1 + ai * 2 + 1);
        let is_wild: bool = sm_arm_is_wild(s, pat_tok);
        if is_wild {
            has_default = true;
        } else {
            let vtext: []const u8 = sm_tok_text(s, pat_tok);
            let known: bool = sm_enum_has_variant(s, ed, vtext);
            if !known {
                sm_err(s, .unknown_variant);
            }
            // Duplicate: any earlier `.variant` arm naming the same case.
            var dup: bool = false;
            var aj: u32 = 0;
            while aj < ai {
                let pj: u32 = sm_extra(s, run + 1 + aj * 2);
                let pj_wild: bool = sm_arm_is_wild(s, pj);
                if !pj_wild {
                    let pjtext: []const u8 = sm_tok_text(s, pj);
                    let dm: bool = mem_eql(vtext, pjtext);
                    if dm {
                        dup = true;
                    }
                }
                aj = aj + 1;
            }
            if dup {
                sm_err(s, .duplicate_arm);
            }
        }
        sm_check_stmt(s, blk);
        ai = ai + 1;
    }
    // Exhaustiveness.
    if ed.is_open == 1 {
        if !has_default {
            sm_err(s, .nonexhaustive_switch);
        }
    } else {
        if !has_default {
            var all_covered: bool = true;
            var vi: u32 = 0;
            while vi < ed.variant_count {
                let v: SmEVar = vec_get(SmEVar, &s.evariants, (ed.variant_start + vi) as usize);
                let vn: []const u8 = sm_evar_name(s, v);
                let cov: bool = sm_switch_covers(s, run, arm_count, vn);
                if !cov {
                    all_covered = false;
                }
                vi = vi + 1;
            }
            if !all_covered {
                sm_err(s, .nonexhaustive_switch);
            }
        }
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
    if nd.kind == .let_decl || nd.kind == .var_decl {
        let init_nd: Node = sm_node(s, nd.rhs);
        var bind_ty: SmType = sm_ty_unknown();
        if nd.lhs != 0 {
            let ann: SmType = sm_type_from_node(s, nd.lhs);
            if init_nd.kind == .struct_lit {
                sm_check_struct_lit(s, nd.rhs, ann);
            } else if init_nd.kind == .enum_lit {
                sm_check_enum_lit(s, nd.rhs, ann);
            } else {
                let it: SmType = sm_type_of_expr(s, nd.rhs);
                let matched: bool = sm_types_match(s, ann, it);
                if !matched {
                    sm_err(s, .type_mismatch);
                }
            }
            bind_ty = ann;
        } else {
            // No annotation: a struct literal has no target type here (error via sm_type_of_expr).
            bind_ty = sm_type_of_expr(s, nd.rhs);
        }
        let name: []const u8 = sm_tok_text(s, nd.main_token);
        strmap_put(SmType, &s.locals, name, bind_ty);
        if nd.kind == .var_decl {
            strmap_put(u32, &s.muts, name, 1);
        }
        return;
    }
    if nd.kind == .return_stmt {
        if nd.lhs == 0 {
            if s.cur_ret.kind != .void_ {
                sm_err(s, .ret_mismatch);
            }
            return;
        }
        let rv_nd: Node = sm_node(s, nd.lhs);
        if rv_nd.kind == .struct_lit {
            // `return .{...}` in an `-> S` fn: the return type is the struct target.
            sm_check_struct_lit(s, nd.lhs, s.cur_ret);
            return;
        }
        if rv_nd.kind == .enum_lit {
            // `return .variant` in an `-> EnumT` fn: the return type is the enum target.
            sm_check_enum_lit(s, nd.lhs, s.cur_ret);
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
    if nd.kind == .switch_stmt {
        sm_check_switch(s, node);
        return;
    }
    if nd.kind == .assign {
        let lnode: Node = sm_node(s, nd.lhs);
        if lnode.kind == .ident_expr {
            let name: []const u8 = sm_tok_text(s, lnode.main_token);
            let is_local: bool = strmap_contains(SmType, &s.locals, name);
            if is_local {
                let is_mut: bool = strmap_contains(u32, &s.muts, name);
                if !is_mut {
                    // A `let` local or a param — immutable (assigning it is an error).
                    sm_err(s, .assign_immutable);
                    return;
                }
                let lt: SmType = strmap_get_or(SmType, &s.locals, name, sm_ty_unknown());
                let rhs_nd: Node = sm_node(s, nd.rhs);
                if rhs_nd.kind == .enum_lit {
                    // `c = .variant`: the literal resolves against the target's enum type.
                    sm_check_enum_lit(s, nd.rhs, lt);
                    return;
                }
                let rt: SmType = sm_type_of_expr(s, nd.rhs);
                let m: bool = sm_types_match(s, lt, rt);
                if !m {
                    sm_err(s, .type_mismatch);
                }
                return;
            }
            sm_type_of_expr(s, nd.rhs); // walk rhs for errors
            sm_type_of_expr(s, nd.lhs); // unknown binding -> unknown-name error
            return;
        }
        if lnode.kind == .field {
            // Member assignment `a.f = e`: the root binding must be a mutable `var`.
            let root_mut: bool = sm_target_mutable(s, nd.lhs);
            if !root_mut {
                sm_err(s, .assign_immutable);
                return;
            }
            let lt: SmType = sm_type_of_expr(s, nd.lhs); // checks the field access (unknown_field)
            let rt: SmType = sm_type_of_expr(s, nd.rhs);
            let m: bool = sm_types_match(s, lt, rt);
            if !m {
                sm_err(s, .type_mismatch);
            }
            return;
        }
        sm_type_of_expr(s, nd.rhs); // walk both sides of any other assignment target for errors
        sm_type_of_expr(s, nd.lhs);
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

// Collect one struct definition (name -> fields window) from a field run `[count, (name,type)*]`.
// Shared by the concrete `struct_decl` and generic `struct_gdecl` paths (P5.5); `is_generic` marks
// the latter so a targeting struct literal only has its field NAMES checked (see sm_check_struct_lit).
fn sm_collect_struct(s: *mut SmState, name_tok: u32, srun: u32, is_generic: u32) -> void {
    let fcount: u32 = sm_extra(s, srun);
    let fstart: u32 = vec_len(SmField, &s.fields) as u32;
    let par: *mut Parser = &s.p;
    var fi: u32 = 0;
    while fi < fcount {
        let fn_tok: u32 = sm_extra(s, srun + 1 + fi * 2);
        let type_node: u32 = sm_extra(s, srun + 1 + fi * 2 + 1);
        let fty: SmType = sm_type_from_node(s, type_node);
        let fst: usize = token_start_at(&par.tl, fn_tok as usize);
        let fln: usize = token_len_at(&par.tl, fn_tok as usize);
        vec_push(SmField, &s.fields, .{ .nstart = fst, .nlen = fln, .ty = fty });
        fi = fi + 1;
    }
    let sidx: u32 = vec_len(SmStruct, &s.struct_defs) as u32;
    vec_push(SmStruct, &s.struct_defs, .{ .field_start = fstart, .field_count = fcount, .is_generic = is_generic });
    let sname: []const u8 = sm_tok_text(s, name_tok);
    strmap_put(u32, &s.structs, sname, sidx + 1);
}

// True when a fn's param run contains a `comptime` param (`param_decl.rhs == 1`) — i.e. the fn is
// generic (P5.5). Used by pass 2 to SKIP type-checking a generic template body (the type param is
// abstract), and mirrors the pass-1 detection that fills `SmSig.is_generic`.
fn sm_fn_is_generic(s: *mut SmState, params_run: u32) -> bool {
    let pcount: u32 = sm_extra(s, params_run);
    var pi: u32 = 0;
    while pi < pcount {
        let pnode: u32 = sm_extra(s, params_run + 1 + pi);
        let pn: Node = sm_node(s, pnode);
        if pn.rhs == 1 {
            return true;
        }
        pi = pi + 1;
    }
    return false;
}

// PASS 1: collect one `SmSig` per `fn` decl and register its name -> (index + 1).
fn sm_collect(s: *mut SmState, root: u32) -> void {
    let rnode: Node = sm_node(s, root);
    let drun: u32 = rnode.lhs;
    let dcount: u32 = sm_extra(s, drun);
    var di: u32 = 0;
    while di < dcount {
        let d: u32 = sm_extra(s, drun + 1 + di);
        let dn: Node = sm_node(s, d);
        if dn.kind == .struct_decl {
            sm_collect_struct(s, dn.main_token, dn.lhs, 0);
        }
        if dn.kind == .struct_gdecl {
            // Generic struct rec [tparam_tok, fields_run, exported]; register the template by name
            // with its fields (field types may reference the abstract type param T).
            let grec: u32 = dn.lhs;
            let gfields: u32 = sm_extra(s, grec + 1);
            sm_collect_struct(s, dn.main_token, gfields, 1);
        }
        if dn.kind == .enum_decl {
            let erec: u32 = dn.lhs;
            let is_open: u32 = sm_extra(s, erec + 1);
            let repr_node: u32 = sm_extra(s, erec + 2);
            let vrun: u32 = sm_extra(s, erec + 3);
            let vcount: u32 = sm_extra(s, vrun);
            let vstart: u32 = vec_len(SmEVar, &s.evariants) as u32;
            let epar: *mut Parser = &s.p;
            var evi: u32 = 0;
            while evi < vcount {
                let vtok: u32 = sm_extra(s, vrun + 1 + evi);
                let vst: usize = token_start_at(&epar.tl, vtok as usize);
                let vln: usize = token_len_at(&epar.tl, vtok as usize);
                vec_push(SmEVar, &s.evariants, .{ .nstart = vst, .nlen = vln });
                evi = evi + 1;
            }
            var repr_kind: SmKind = .u32_;
            if repr_node != 0 {
                let rt: SmType = sm_type_from_node(s, repr_node);
                repr_kind = rt.kind;
            }
            let eidx: u32 = vec_len(SmEnum, &s.enum_defs) as u32;
            vec_push(SmEnum, &s.enum_defs, .{ .variant_start = vstart, .variant_count = vcount, .repr = repr_kind, .is_open = is_open });
            let ename: []const u8 = sm_tok_text(s, dn.main_token);
            strmap_put(u32, &s.enums, ename, eidx + 1);
        }
        if dn.kind == .fn_decl {
            let frec: u32 = dn.lhs;
            let params_run: u32 = sm_extra(s, frec + 1);
            let ret_node: u32 = sm_extra(s, frec + 2);
            let ret_ty: SmType = sm_type_from_node(s, ret_node);
            let pcount: u32 = sm_extra(s, params_run);
            let pstart: u32 = vec_len(SmType, &s.ptypes) as u32;
            // P5.5: scan params for a leading `comptime T: type` param (a `param_decl` with rhs == 1
            // whose type node is `type_kw`) — that names the generic type param T.
            var is_generic: u32 = 0;
            var tp_start: usize = 0;
            var tp_len: usize = 0;
            let gpar: *mut Parser = &s.p;
            var pi: u32 = 0;
            while pi < pcount {
                let pnode: u32 = sm_extra(s, params_run + 1 + pi);
                let pn: Node = sm_node(s, pnode);
                let pty: SmType = sm_type_from_node(s, pn.lhs);
                vec_push(SmType, &s.ptypes, pty);
                if pn.rhs == 1 {
                    is_generic = 1;
                    tp_start = token_start_at(&gpar.tl, pn.main_token as usize);
                    tp_len = token_len_at(&gpar.tl, pn.main_token as usize);
                }
                pi = pi + 1;
            }
            // `ret_is_tparam`: the declared return type is exactly the type param (compared by
            // lexeme). A call then yields the concrete type-arg's kind rather than a `named_` T.
            var ret_is_tp: u32 = 0;
            if is_generic == 1 {
                let rn: Node = sm_node(s, ret_node);
                if rn.kind == .type_name {
                    let rtext: []const u8 = sm_tok_text(s, rn.main_token);
                    let src: []const u8 = gpar.source;
                    let tpend: usize = tp_start + tp_len;
                    let tptext: []const u8 = src[tp_start..tpend];
                    if mem_eql(rtext, tptext) {
                        ret_is_tp = 1;
                    }
                }
            }
            let sig_idx: u32 = vec_len(SmSig, &s.sigs) as u32;
            vec_push(SmSig, &s.sigs, .{ .ret = ret_ty, .param_start = pstart, .param_count = pcount, .is_generic = is_generic, .tparam_start = tp_start, .tparam_len = tp_len, .ret_is_tparam = ret_is_tp });
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
            // P5.5: SKIP generic templates — their bodies reference the abstract type param T (which
            // has no concrete type here), so checking is deferred to each monomorphic instantiation
            // (not modeled in the subset). A generic call site is still arity-checked (sm_check_call).
            let generic: bool = sm_fn_is_generic(s, params_run);
            if generic {
                di = di + 1;
                continue;
            }
            // Reset the locals + mutability tables (reusable after free) and seed the params.
            strmap_free(SmType, &s.locals);
            strmap_free(u32, &s.muts);
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
        .muts = strmap_new(u32, a),
        .structs = strmap_new(u32, a),
        .struct_defs = vec_new(SmStruct, a),
        .fields = vec_new(SmField, a),
        .enums = strmap_new(u32, a),
        .enum_defs = vec_new(SmEnum, a),
        .evariants = vec_new(SmEVar, a),
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
    strmap_free(u32, &s.muts);
    strmap_free(u32, &s.structs);
    strmap_free(u32, &s.enums);
    strmap_free(u32, &s.fns);
    vec_free(SmStruct, &s.struct_defs);
    vec_free(SmField, &s.fields);
    vec_free(SmEnum, &s.enum_defs);
    vec_free(SmEVar, &s.evariants);
    vec_free(SmSig, &s.sigs);
    vec_free(SmType, &s.ptypes);
    parser_free(&s.p);
}
