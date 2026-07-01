// selfhost/emit_c — mcc2's C-CODE EMITTER, Phase 4 of the self-hosting plan
// (docs/self-host-plan.md). It walks the Phase-2 flat index-arena AST (selfhost/parser.mc) over
// the Phase-1 token stream (selfhost/lexer.mc) and emits SUBSET C source into a `StrBuf`
// (std/strbuf.mc). The pipeline entry `emit_c_run` runs lex -> parse -> emit and returns the
// emitted C bytes; the selfhost-emit-test gate clang-compiles those bytes with a C driver that
// calls the emitted function and asserts the result — that lex->parse->emit->clang->run
// round-trip is the phase's milestone.
//
// SUBSET (matches the P2 grammar):
//   * each `fn` (honoring `export`) -> a C function; scalar identifier types map
//     u8/u16/u32/u64->uintN_t, usize->size_t, i8..i64->intN_t, isize->ptrdiff_t; `*T`/`*mut T`
//     -> `T*`. (`bool`/`void` are keywords, not annotations in the subset, so a return type of
//     0 emits `void`.)
//   * statements: `let (x:T)? = e;` -> `T x = e;` (no annotation defaults to `uint32_t`);
//     `return e;`/`return;`; `if (e) {} else {}`; `while (e) {}`; `expr;`; `lhs = rhs;`.
//   * expressions: integer literal + identifier emit their source lexeme; binary ops emit
//     `(lhs OP rhs)` fully parenthesized (so C precedence is preserved trivially); unary
//     `-`/`!`; call `f(args)`; index `b[i]`; field `b.f`.
//
// GAP NOTES (self-host ledger):
//   * G12: MC string literals lower to `*const u8`, NOT `[]const u8`, so fixed C fragments are
//     emitted with `sb_put_cstr` (NUL-terminated `*const u8`); only genuine `[]const u8` slices
//     (an identifier's recovered source lexeme) go through `sb_put_str`.
//   * G22 flat namespace: every helper is prefixed `e_` so it cannot collide with the imported
//     lexer/parser/strbuf (which own advance/peek/make/at/expect/sb_*/... ).
//   * G13: token lexemes are recovered by copying `source` into a plain local and precomputing
//     the sub-slice endpoints (a struct-field slice base / `a..a+n` endpoint would not lower).
//   * G25: node dispatch uses `if`/`else if` chains on `kind ==` (not `switch`) to sidestep the
//     open-enum exhaustiveness gap.

import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/collections/dynarray.mc";
import "std/strbuf.mc";
import "selfhost/parser.mc";

// ----- arena / token access (all through a plain local `*mut Parser`, per G13) -----

fn e_node(p: *mut Parser, i: u32) -> Node {
    return vec_get(Node, &p.nodes, i as usize);
}

fn e_extra(p: *mut Parser, i: u32) -> u32 {
    return vec_get(u32, &p.extra, i as usize);
}

// The source lexeme of token `tok` as a genuine `[]const u8` (endpoints precomputed, gap G13).
fn e_tok_text(p: *mut Parser, tok: u32) -> []const u8 {
    let src: []const u8 = p.source;
    let st: usize = token_start_at(&p.tl, tok as usize);
    let ln: usize = token_len_at(&p.tl, tok as usize);
    let end: usize = st + ln;
    return src[st..end];
}

// Emit `depth` levels of 4-space indentation (cosmetic; clang ignores it, but it makes the
// emitted C — and the report — readable).
fn e_indent(sb: *mut StrBuf, depth: u32) -> void {
    var i: u32 = 0;
    while i < depth {
        sb_put_cstr(sb, "    ");
        i = i + 1;
    }
}

// ----- type emission -----

// Emit the C spelling of a scalar type name lexeme, or the lexeme verbatim if not a known scalar.
fn e_scalar_name(sb: *mut StrBuf, txt: []const u8) -> void {
    var b_u8: [2]u8 = .{ 117, 56 }; // "u8"
    if mem_eql(txt, mem.as_bytes(&b_u8)) { sb_put_cstr(sb, "uint8_t"); return; }
    var b_u16: [3]u8 = .{ 117, 49, 54 }; // "u16"
    if mem_eql(txt, mem.as_bytes(&b_u16)) { sb_put_cstr(sb, "uint16_t"); return; }
    var b_u32: [3]u8 = .{ 117, 51, 50 }; // "u32"
    if mem_eql(txt, mem.as_bytes(&b_u32)) { sb_put_cstr(sb, "uint32_t"); return; }
    var b_u64: [3]u8 = .{ 117, 54, 52 }; // "u64"
    if mem_eql(txt, mem.as_bytes(&b_u64)) { sb_put_cstr(sb, "uint64_t"); return; }
    var b_usize: [5]u8 = .{ 117, 115, 105, 122, 101 }; // "usize"
    if mem_eql(txt, mem.as_bytes(&b_usize)) { sb_put_cstr(sb, "size_t"); return; }
    var b_i8: [2]u8 = .{ 105, 56 }; // "i8"
    if mem_eql(txt, mem.as_bytes(&b_i8)) { sb_put_cstr(sb, "int8_t"); return; }
    var b_i16: [3]u8 = .{ 105, 49, 54 }; // "i16"
    if mem_eql(txt, mem.as_bytes(&b_i16)) { sb_put_cstr(sb, "int16_t"); return; }
    var b_i32: [3]u8 = .{ 105, 51, 50 }; // "i32"
    if mem_eql(txt, mem.as_bytes(&b_i32)) { sb_put_cstr(sb, "int32_t"); return; }
    var b_i64: [3]u8 = .{ 105, 54, 52 }; // "i64"
    if mem_eql(txt, mem.as_bytes(&b_i64)) { sb_put_cstr(sb, "int64_t"); return; }
    var b_isize: [5]u8 = .{ 105, 115, 105, 122, 101 }; // "isize"
    if mem_eql(txt, mem.as_bytes(&b_isize)) { sb_put_cstr(sb, "ptrdiff_t"); return; }
    // Unknown named type (a struct in the fuller language): emit its lexeme verbatim.
    sb_put_str(sb, txt);
}

// Emit an AST type node. `0` -> `void`; `*T`/`*mut T` -> `T*`; `[]const/mut T` -> `T*`
// (element pointer, best-effort — the subset does not model slice length); a `type_name`
// maps its scalar spelling.
fn e_type(p: *mut Parser, sb: *mut StrBuf, tn: u32) -> void {
    if tn == 0 {
        sb_put_cstr(sb, "void");
        return;
    }
    let nd: Node = e_node(p, tn);
    if nd.kind == .type_ptr {
        e_type(p, sb, nd.lhs);
        sb_put_cstr(sb, "*");
        return;
    }
    if nd.kind == .type_slice_const {
        // P5.7: a slice is a fat-pointer struct `mc_slice_const_<T>` (see `e_slice_typedefs`), not a
        // bare element pointer — so `.len`, sub-slicing, and by-value passing all work.
        sb_put_cstr(sb, "mc_slice_const_");
        let selc: []const u8 = e_type_arg_lexeme(p, nd.lhs);
        sb_put_str(sb, selc);
        return;
    }
    if nd.kind == .type_slice_mut {
        sb_put_cstr(sb, "mc_slice_mut_");
        let selm: []const u8 = e_type_arg_lexeme(p, nd.lhs);
        sb_put_str(sb, selm);
        return;
    }
    // A generic instance `S<T>` (P5.5) emits the MANGLED monomorphic name `S_<concrete>` (the type
    // arg's lexeme, with the active type param substituted). This matches the typedef emitted by
    // `e_gstruct_mono` and the mangled names elsewhere.
    if nd.kind == .type_generic {
        let base: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, base);
        sb_put_cstr(sb, "_");
        let arg_lex: []const u8 = e_type_arg_lexeme(p, nd.lhs);
        sb_put_str(sb, arg_lex);
        return;
    }
    // The `type` keyword annotation (a `comptime T: type` param) has no C spelling; it is dropped
    // from emitted signatures (see `e_gfn_sig_mono`), so nothing is emitted here.
    if nd.kind == .type_kw {
        return;
    }
    // type_name
    let txt: []const u8 = e_tok_text(p, nd.main_token);
    // Monomorphization substitution (P5.5): when this names the active type param, emit the concrete
    // type node instead (e.g. `T` -> `uint32_t`). The concrete node is not the type param, so the
    // recursion terminates.
    if p.sub_concrete != 0 {
        let subname: []const u8 = e_sub_name(p);
        let hit: bool = mem_eql(txt, subname);
        if hit {
            e_type(p, sb, p.sub_concrete);
            return;
        }
    }
    e_scalar_name(sb, txt);
}

// Emit a C DECLARATOR `<type> <name>`, honoring fixed-size arrays (P5.6): a `[N]T` type must lower
// to `T name[N]` (the `[N]` binds to the NAME in C, not the type), so it cannot go through the plain
// `e_type` + name path. Used everywhere a named binding is emitted: locals, struct fields, params,
// and their monomorphic copies. `type_node` 0 (no annotation) falls through to `void name`.
fn e_emit_decl(p: *mut Parser, sb: *mut StrBuf, type_node: u32, name: []const u8) -> void {
    if type_node != 0 {
        let nd: Node = e_node(p, type_node);
        if nd.kind == .type_array {
            // `T name[N]` — the element type may itself be the active generic type param (substituted
            // by `e_type`); N is the integer-literal `main_token`'s lexeme, emitted verbatim.
            e_type(p, sb, nd.lhs);
            sb_put_cstr(sb, " ");
            sb_put_str(sb, name);
            sb_put_cstr(sb, "[");
            let ltxt: []const u8 = e_tok_text(p, nd.main_token);
            sb_put_str(sb, ltxt);
            sb_put_cstr(sb, "]");
            return;
        }
    }
    e_type(p, sb, type_node);
    sb_put_cstr(sb, " ");
    sb_put_str(sb, name);
}

// The source lexeme of the ACTIVE type param (`source[sub_name_start .. +sub_name_len]`), recovered
// through a plain local per gap G13. Only meaningful while `sub_concrete != 0`.
fn e_sub_name(p: *mut Parser) -> []const u8 {
    let src: []const u8 = p.source;
    let st: usize = p.sub_name_start;
    let en: usize = st + p.sub_name_len;
    return src[st..en];
}

// The lexeme of a node's `main_token` (works for both a `type_name` type arg and an `ident_expr`
// type argument at a call site — both carry the concrete type spelling, e.g. `u32`, in `main_token`).
fn e_node_lexeme(p: *mut Parser, node: u32) -> []const u8 {
    let nd: Node = e_node(p, node);
    return e_tok_text(p, nd.main_token);
}

// The effective concrete lexeme of a generic type argument node: the type param's substitution when
// active and matching, else the node's own lexeme. Used to build mangled names (`S_<concrete>`).
fn e_type_arg_lexeme(p: *mut Parser, arg_node: u32) -> []const u8 {
    let nd: Node = e_node(p, arg_node);
    let txt: []const u8 = e_tok_text(p, nd.main_token);
    if p.sub_concrete != 0 {
        if nd.kind == .type_name {
            let subname: []const u8 = e_sub_name(p);
            let hit: bool = mem_eql(txt, subname);
            if hit {
                return e_node_lexeme(p, p.sub_concrete);
            }
        }
    }
    return txt;
}

// Set / clear the monomorphization substitution context on the shared arena (see the Parser fields):
// `tparam_tok` names the type param; `concrete_node` is the concrete type/ident node to substitute.
fn e_set_sub(p: *mut Parser, tparam_tok: u32, concrete_node: u32) -> void {
    p.sub_name_start = token_start_at(&p.tl, tparam_tok as usize);
    p.sub_name_len = token_len_at(&p.tl, tparam_tok as usize);
    p.sub_concrete = concrete_node;
}

fn e_clear_sub(p: *mut Parser) -> void {
    p.sub_concrete = 0;
}

// ----- P5.7 slice (fat-pointer) support -----

// True when a `[]const/mut T` element node names a plain scalar (so a fat-pointer struct can be
// generated for it). Generic type-param elements are skipped (deferred — see the ledger).
fn e_slice_elem_is_scalar(p: *mut Parser, elem_node: u32) -> bool {
    let nd: Node = e_node(p, elem_node);
    if nd.kind != .type_name {
        return false;
    }
    let txt: []const u8 = e_tok_text(p, nd.main_token);
    return e_is_scalar_lexeme(txt);
}

// Find the declared type node of a local named `name` in the function currently being emitted
// (`p.cur_fn`): scan the params, then the body's `let`/`var` decls (recursing into nested blocks).
// Returns the type node index, or 0 if not found / no current function. Lets the emitter tell a
// slice base (`s.ptr[i]`) from an array base (`a[i]`) without threading sema types through emit.
fn e_local_type_node(p: *mut Parser, name: []const u8) -> u32 {
    let fnn: u32 = p.cur_fn;
    if fnn == 0 {
        return 0;
    }
    let nd: Node = e_node(p, fnn);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let pcount: u32 = e_extra(p, params_run);
    var k: u32 = 0;
    while k < pcount {
        let pn: u32 = e_extra(p, params_run + 1 + k);
        let pnode: Node = e_node(p, pn);
        let pname: []const u8 = e_tok_text(p, pnode.main_token);
        let hit: bool = mem_eql(pname, name);
        if hit {
            return pnode.lhs;
        }
        k = k + 1;
    }
    let body: u32 = e_extra(p, frec + 3);
    return e_find_local_in_block(p, body, name);
}

// Recurse a block's statements looking for a `let`/`var` decl of `name`; returns its type node or 0.
fn e_find_local_in_block(p: *mut Parser, block_node: u32, name: []const u8) -> u32 {
    let nd: Node = e_node(p, block_node);
    let run: u32 = nd.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let st: u32 = e_extra(p, run + 1 + i);
        let r: u32 = e_find_local_in_stmt(p, st, name);
        if r != 0 {
            return r;
        }
        i = i + 1;
    }
    return 0;
}

// Inspect one statement (and any nested blocks) for a `let`/`var` decl of `name`.
fn e_find_local_in_stmt(p: *mut Parser, st: u32, name: []const u8) -> u32 {
    let sn: Node = e_node(p, st);
    if sn.kind == .let_decl || sn.kind == .var_decl {
        let nm: []const u8 = e_tok_text(p, sn.main_token);
        let hit: bool = mem_eql(nm, name);
        if hit {
            return sn.lhs;
        }
        return 0;
    }
    if sn.kind == .block {
        return e_find_local_in_block(p, st, name);
    }
    if sn.kind == .if_stmt {
        let then_b: u32 = e_extra(p, sn.rhs);
        let else_b: u32 = e_extra(p, sn.rhs + 1);
        let rt: u32 = e_find_local_in_stmt(p, then_b, name);
        if rt != 0 {
            return rt;
        }
        if else_b != 0 {
            return e_find_local_in_stmt(p, else_b, name);
        }
        return 0;
    }
    if sn.kind == .while_stmt {
        return e_find_local_in_stmt(p, sn.rhs, name);
    }
    return 0;
}

// True when `base` is a slice-typed identifier in the current function (its declared type node is a
// `[]const/mut T`). Only bare identifiers are resolved (a field/index base is treated as non-slice —
// deferred; see the ledger).
fn e_base_is_slice(p: *mut Parser, base: u32) -> bool {
    let bn: Node = e_node(p, base);
    if bn.kind != .ident_expr {
        return false;
    }
    let name: []const u8 = e_tok_text(p, bn.main_token);
    let tn: u32 = e_local_type_node(p, name);
    if tn == 0 {
        return false;
    }
    let tnode: Node = e_node(p, tn);
    return tnode.kind == .type_slice_const || tnode.kind == .type_slice_mut;
}

// Emit the fat-pointer struct type NAME for a base identifier's declared slice/array type, e.g.
// `mc_slice_const_u32`. For a slice base it mirrors the base's own const/mut and element; for an
// array base it is always a `[]const <elem>`. Precondition: base is a slice- or array-typed ident.
fn e_emit_base_slice_name(p: *mut Parser, sb: *mut StrBuf, base: u32) -> void {
    let bn: Node = e_node(p, base);
    let name: []const u8 = e_tok_text(p, bn.main_token);
    let tn: u32 = e_local_type_node(p, name);
    let tnode: Node = e_node(p, tn);
    if tnode.kind == .type_slice_mut {
        sb_put_cstr(sb, "mc_slice_mut_");
    } else {
        sb_put_cstr(sb, "mc_slice_const_");
    }
    let lex: []const u8 = e_type_arg_lexeme(p, tnode.lhs);
    sb_put_str(sb, lex);
}

// Emit all fat-pointer struct typedefs used in the module, deduped by (mutability, element). A slice
// `[]const/mut T` lowers to `typedef struct mc_slice_<m>_<T> { const T* ptr; size_t len; } ...;` —
// matching the real C backend's `mc_slice_const_u8` naming (src/lower_c_names.zig) so semantics are
// identical. `size_t` (not the real backend's `uintptr_t`) is used for `len` so it agrees with the
// subset's `usize` spelling. Emitted before all other typedefs (a struct field may embed a slice).
fn e_slice_typedefs(p: *mut Parser, sb: *mut StrBuf) -> void {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var emitted: u32 = 0;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        let is_const: bool = nd.kind == .type_slice_const;
        let is_mut: bool = nd.kind == .type_slice_mut;
        if is_const || is_mut {
            let scalar: bool = e_slice_elem_is_scalar(p, nd.lhs);
            if scalar {
                let mflag: u32 = e_slice_mut_flag(is_mut);
                let lex: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
                let dup: bool = e_slice_dup_before(p, i, mflag, lex);
                if !dup {
                    e_emit_one_slice_typedef(sb, mflag, lex);
                    emitted = emitted + 1;
                }
            }
        }
        i = i + 1;
    }
    // Only add the separating blank line when at least one typedef was emitted, so a module with no
    // slices produces byte-identical output to before P5.7.
    if emitted > 0 {
        sb_put_cstr(sb, "\n");
    }
}

// 1 for a `[]mut` element, 0 for `[]const` (bound to a local per G23-style clarity).
fn e_slice_mut_flag(is_mut: bool) -> u32 {
    if is_mut {
        return 1;
    }
    return 0;
}

// True when a slice typedef with the same (mutability, element lexeme) was already emitted by an
// EARLIER slice type node (index < `cur`) — the dedup for `e_slice_typedefs`.
fn e_slice_dup_before(p: *mut Parser, cur: u32, mflag: u32, lex: []const u8) -> bool {
    var j: u32 = 1;
    while j < cur {
        let nd: Node = e_node(p, j);
        let jc: bool = nd.kind == .type_slice_const;
        let jm: bool = nd.kind == .type_slice_mut;
        if jc || jm {
            let jscalar: bool = e_slice_elem_is_scalar(p, nd.lhs);
            if jscalar {
                let jflag: u32 = e_slice_mut_flag(jm);
                if jflag == mflag {
                    let jlex: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
                    let same: bool = mem_eql(jlex, lex);
                    if same {
                        return true;
                    }
                }
            }
        }
        j = j + 1;
    }
    return false;
}

// Emit one `typedef struct mc_slice_<m>_<T> { <cv> <cT>* ptr; size_t len; } mc_slice_<m>_<T>;`.
fn e_emit_one_slice_typedef(sb: *mut StrBuf, mflag: u32, lex: []const u8) -> void {
    sb_put_cstr(sb, "typedef struct mc_slice_");
    if mflag == 1 {
        sb_put_cstr(sb, "mut_");
    } else {
        sb_put_cstr(sb, "const_");
    }
    sb_put_str(sb, lex);
    sb_put_cstr(sb, " {\n    ");
    if mflag == 0 {
        sb_put_cstr(sb, "const ");
    }
    e_scalar_name(sb, lex);
    sb_put_cstr(sb, "* ptr;\n    size_t len;\n} mc_slice_");
    if mflag == 1 {
        sb_put_cstr(sb, "mut_");
    } else {
        sb_put_cstr(sb, "const_");
    }
    sb_put_str(sb, lex);
    sb_put_cstr(sb, ";\n");
}

// Emit a sub-slice `base[start..end]` as a fat-pointer compound literal (P5.7). For a SLICE base:
//   `(mc_slice_<m>_<T>){ .ptr = (base).ptr + (start), .len = (end) - (start) }`
// For an ARRAY base (which decays to a pointer): `.ptr = (base) + (start)` — i.e. `&base[start]`.
// Bounds are NOT checked in the subset (deferred). Endpoints are emitted inline (the subset only
// forms sub-slices with simple, side-effect-free endpoints — see the ledger note on G13).
fn e_slice_range(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    let nd: Node = e_node(p, n);
    let base: u32 = nd.lhs;
    let rec: u32 = nd.rhs;
    let start_e: u32 = e_extra(p, rec);
    let end_e: u32 = e_extra(p, rec + 1);
    let base_is_slice: bool = e_base_is_slice(p, base);
    sb_put_cstr(sb, "(");
    if base_is_slice {
        e_emit_base_slice_name(p, sb, base);
    } else {
        // Array base: the result is a `[]const <elem>`.
        e_emit_base_array_slice_name(p, sb, base);
    }
    sb_put_cstr(sb, "){ .ptr = ");
    if base_is_slice {
        sb_put_cstr(sb, "(");
        e_expr(p, sb, base);
        sb_put_cstr(sb, ").ptr + (");
    } else {
        sb_put_cstr(sb, "(");
        e_expr(p, sb, base);
        sb_put_cstr(sb, ") + (");
    }
    e_expr(p, sb, start_e);
    sb_put_cstr(sb, "), .len = (");
    e_expr(p, sb, end_e);
    sb_put_cstr(sb, ") - (");
    e_expr(p, sb, start_e);
    sb_put_cstr(sb, ") }");
}

// Emit the `mc_slice_const_<elem>` name for an array-typed base identifier (its element becomes the
// slice element). Precondition: `base` is an array-typed ident.
fn e_emit_base_array_slice_name(p: *mut Parser, sb: *mut StrBuf, base: u32) -> void {
    let bn: Node = e_node(p, base);
    let name: []const u8 = e_tok_text(p, bn.main_token);
    let tn: u32 = e_local_type_node(p, name);
    let tnode: Node = e_node(p, tn);
    sb_put_cstr(sb, "mc_slice_const_");
    // `type_array` lhs is the element type node.
    let lex: []const u8 = e_type_arg_lexeme(p, tnode.lhs);
    sb_put_str(sb, lex);
}

// True when call node `n` is `<recv>.as_bytes(<one arg>)` — the `mem.as_bytes` slice builtin.
fn e_call_is_as_bytes(p: *mut Parser, n: u32) -> bool {
    let nd: Node = e_node(p, n);
    let cnode: Node = e_node(p, nd.lhs);
    if cnode.kind != .field {
        return false;
    }
    var b_asb: [8]u8 = .{ 97, 115, 95, 98, 121, 116, 101, 115 }; // "as_bytes"
    let fname: []const u8 = e_tok_text(p, cnode.main_token);
    let is_asb: bool = mem_eql(fname, mem.as_bytes(&b_asb));
    if !is_asb {
        return false;
    }
    let argc: u32 = e_extra(p, nd.rhs);
    return argc == 1;
}

// Emit `mem.as_bytes(&x)` as `(mc_slice_const_u8){ .ptr = (const uint8_t*)(&(x)), .len = sizeof(x) }`.
fn e_as_bytes(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    let nd: Node = e_node(p, n);
    let arg: u32 = e_extra(p, nd.rhs + 1);
    let an: Node = e_node(p, arg);
    sb_put_cstr(sb, "(mc_slice_const_u8){ .ptr = (const uint8_t*)(");
    e_expr(p, sb, arg);
    sb_put_cstr(sb, "), .len = sizeof(");
    // `sizeof` must be of the pointee OBJECT, not the pointer: unwrap a leading `&`.
    if an.kind == .un_addr {
        e_expr(p, sb, an.lhs);
    } else {
        e_expr(p, sb, arg);
    }
    sb_put_cstr(sb, ") }");
}

// ----- P5.8 low-level intrinsics -----

// Emit a `raw.ptr<T>(e)` / `raw.load<T>(e)` / `raw.store<T>(e, v)` intrinsic (P5.8), matching the
// real backend's cast-through-pointer lowering:
//   ptr   -> `(T*)(e)`            — mint a typed pointer from an address
//   load  -> `(*(T*)(e))`         — read a T through the address
//   store -> `(*(T*)(e) = (v))`   — write v (a T) through the address
// The element type `T` goes through `e_type` so a monomorphized type param is substituted (a `Vec<T>`
// template body uses `raw.ptr<T>`). The op is recovered from the member lexeme in `main_token`.
fn e_raw_op(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    let nd: Node = e_node(p, n);
    let ty: u32 = nd.lhs;
    let rec: u32 = nd.rhs;
    let arg0: u32 = e_extra(p, rec);
    let arg1: u32 = e_extra(p, rec + 1);
    let member: []const u8 = e_tok_text(p, nd.main_token);
    var b_ptr: [3]u8 = .{ 112, 116, 114 }; // "ptr"
    let is_ptr: bool = mem_eql(member, mem.as_bytes(&b_ptr));
    if is_ptr {
        sb_put_cstr(sb, "(");
        e_type(p, sb, ty);
        sb_put_cstr(sb, "*)(");
        e_expr(p, sb, arg0);
        sb_put_cstr(sb, ")");
        return;
    }
    var b_load: [4]u8 = .{ 108, 111, 97, 100 }; // "load"
    let is_load: bool = mem_eql(member, mem.as_bytes(&b_load));
    if is_load {
        sb_put_cstr(sb, "(*(");
        e_type(p, sb, ty);
        sb_put_cstr(sb, "*)(");
        e_expr(p, sb, arg0);
        sb_put_cstr(sb, "))");
        return;
    }
    // `store`: `(*(T*)(addr) = (value))`.
    sb_put_cstr(sb, "(*(");
    e_type(p, sb, ty);
    sb_put_cstr(sb, "*)(");
    e_expr(p, sb, arg0);
    sb_put_cstr(sb, ") = (");
    e_expr(p, sb, arg1);
    sb_put_cstr(sb, "))");
}

// ----- expression emission -----

// Emit the C spelling (with surrounding spaces) of a binary NodeKind operator.
fn e_binop(sb: *mut StrBuf, k: NodeKind) -> void {
    if k == .bin_add { sb_put_cstr(sb, " + "); return; }
    if k == .bin_sub { sb_put_cstr(sb, " - "); return; }
    if k == .bin_mul { sb_put_cstr(sb, " * "); return; }
    if k == .bin_div { sb_put_cstr(sb, " / "); return; }
    if k == .bin_mod { sb_put_cstr(sb, " % "); return; }
    if k == .bin_eq  { sb_put_cstr(sb, " == "); return; }
    if k == .bin_ne  { sb_put_cstr(sb, " != "); return; }
    if k == .bin_lt  { sb_put_cstr(sb, " < "); return; }
    if k == .bin_gt  { sb_put_cstr(sb, " > "); return; }
    if k == .bin_le  { sb_put_cstr(sb, " <= "); return; }
    if k == .bin_ge  { sb_put_cstr(sb, " >= "); return; }
    if k == .bin_land { sb_put_cstr(sb, " && "); return; }
    if k == .bin_lor  { sb_put_cstr(sb, " || "); return; }
    // Not a binary operator; emit nothing.
}

// True for the binary NodeKind tags (bin_lor .. bin_mod are contiguous ordinals 22..34).
fn e_is_binop(k: NodeKind) -> bool {
    let o: u32 = k.raw();
    return o >= 22 && o <= 34;
}

// Emit an expression node. Binary exprs are FULLY PARENTHESIZED so C precedence is preserved.
fn e_expr(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    if n == 0 {
        return;
    }
    let nd: Node = e_node(p, n);
    if nd.kind == .int_literal {
        let txt: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, txt);
        return;
    }
    if nd.kind == .ident_expr {
        let txt2: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, txt2);
        return;
    }
    if e_is_binop(nd.kind) {
        sb_put_cstr(sb, "(");
        e_expr(p, sb, nd.lhs);
        e_binop(sb, nd.kind);
        e_expr(p, sb, nd.rhs);
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .un_neg {
        sb_put_cstr(sb, "(-");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .un_not {
        sb_put_cstr(sb, "(!");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .call {
        // `mem.as_bytes(&x)` (P5.7) is a builtin producing a `[]const u8` byte view of `x`:
        //   `(mc_slice_const_u8){ .ptr = (const uint8_t*)(&x), .len = sizeof(x) }`
        // The `.len` uses `sizeof` of the address-of operand (the object), not the pointer. This
        // matches the real backend's byte-view semantics.
        let asb: bool = e_call_is_as_bytes(p, n);
        if asb {
            e_as_bytes(p, sb, n);
            return;
        }
        // `enumval.raw()` lowers to the receiver itself: the enum's C type is a transparent typedef
        // of its repr integer, so the value already IS the raw integer (no cast needed).
        let cnode: Node = e_node(p, nd.lhs);
        if cnode.kind == .field {
            var b_raw: [3]u8 = .{ 114, 97, 119 }; // "raw"
            let fname: []const u8 = e_tok_text(p, cnode.main_token);
            let argc0: u32 = e_extra(p, nd.rhs);
            let is_raw: bool = mem_eql(fname, mem.as_bytes(&b_raw));
            if is_raw && argc0 == 0 {
                e_expr(p, sb, cnode.lhs); // emit just the receiver
                return;
            }
        }
        // P5.5: a GENERIC call `f(u32, ...)` lowers to `f_u32(...)` — the mangled monomorphic callee
        // with the leading type argument DROPPED (it selected the instantiation, it is not a value).
        if cnode.kind == .ident_expr {
            let cname: []const u8 = e_tok_text(p, cnode.main_token);
            let is_gen: bool = e_is_generic_fn(p, cname);
            if is_gen {
                let grun: u32 = nd.rhs;
                let gargc: u32 = e_extra(p, grun);
                let a0: u32 = e_extra(p, grun + 1);
                let a0lex: []const u8 = e_node_lexeme(p, a0);
                sb_put_str(sb, cname);
                sb_put_cstr(sb, "_");
                sb_put_str(sb, a0lex);
                sb_put_cstr(sb, "(");
                var gk: u32 = 1; // skip the type arg at index 0
                while gk < gargc {
                    if gk > 1 {
                        sb_put_cstr(sb, ", ");
                    }
                    let garg: u32 = e_extra(p, grun + 1 + gk);
                    e_expr(p, sb, garg);
                    gk = gk + 1;
                }
                sb_put_cstr(sb, ")");
                return;
            }
        }
        e_expr(p, sb, nd.lhs); // callee
        sb_put_cstr(sb, "(");
        let arg_run: u32 = nd.rhs;
        let argc: u32 = e_extra(p, arg_run);
        var k: u32 = 0;
        while k < argc {
            if k > 0 {
                sb_put_cstr(sb, ", ");
            }
            let arg: u32 = e_extra(p, arg_run + 1 + k);
            e_expr(p, sb, arg);
            k = k + 1;
        }
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .index {
        // A slice index `s[i]` lowers to `(s).ptr[i]` (fat-pointer element access, P5.7); an array (or
        // other) base keeps the plain `a[i]`. Bounds are NOT checked in the subset (deferred). The
        // slice check binds to a local first (gap G23).
        let idx_is_slice: bool = e_base_is_slice(p, nd.lhs);
        if idx_is_slice {
            sb_put_cstr(sb, "(");
            e_expr(p, sb, nd.lhs);
            sb_put_cstr(sb, ").ptr[");
            e_expr(p, sb, nd.rhs);
            sb_put_cstr(sb, "]");
            return;
        }
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, "[");
        e_expr(p, sb, nd.rhs);
        sb_put_cstr(sb, "]");
        return;
    }
    if nd.kind == .slice_range {
        e_slice_range(p, sb, n);
        return;
    }
    if nd.kind == .un_addr {
        sb_put_cstr(sb, "&(");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .raw_op {
        e_raw_op(p, sb, n);
        return;
    }
    if nd.kind == .deref {
        // `p.*` -> `(*(p))` (P5.8). Matches the real backend's pointer-deref lowering.
        sb_put_cstr(sb, "(*(");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, "))");
        return;
    }
    if nd.kind == .field {
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ".");
        let fld: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, fld);
        return;
    }
    if nd.kind == .struct_lit {
        // Cast-less designated initializer (a target-typed compound literal is emitted by
        // `e_struct_lit` where the annotation type is known — see `e_stmt`).
        e_struct_lit_body(p, sb, n);
        return;
    }
    if nd.kind == .enum_lit {
        e_enum_lit(p, sb, n);
        return;
    }
    if nd.kind == .array_lit {
        // Bare aggregate `{ e0, ... }` (valid as an initializer or nested inside another literal).
        e_array_lit_body(p, sb, n);
        return;
    }
    // Any other node kind is outside the emitter subset; emit nothing.
}

// Emit an enum literal `.variant` as its C constant `<EnumName>_<variant>` (matching the anonymous
// `enum {}` block emitted by `e_enum_decl`). The AST does not carry which enum a bare `.variant`
// belongs to, so the module's enum decls are scanned for the one that declares this variant. (In
// the subset variant names are assumed unique across enums — first match wins; see the ledger.)
fn e_enum_lit(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    let vtext: []const u8 = e_tok_text(p, nd.main_token);
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .enum_decl {
            let rec: u32 = dn.lhs;
            let vrun: u32 = e_extra(p, rec + 3);
            let vc: u32 = e_extra(p, vrun);
            var j: u32 = 0;
            while j < vc {
                let vtok: u32 = e_extra(p, vrun + 1 + j);
                let vn: []const u8 = e_tok_text(p, vtok);
                let m: bool = mem_eql(vtext, vn);
                if m {
                    let ename: []const u8 = e_tok_text(p, dn.main_token);
                    sb_put_str(sb, ename);
                    sb_put_cstr(sb, "_");
                    sb_put_str(sb, vtext);
                    return;
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
    // Unresolved (sema would have rejected this): emit the bare variant lexeme as a fallback.
    sb_put_str(sb, vtext);
}

// Emit the `{ .f0 = e0, ... }` body of a struct literal (no leading cast). The field run is
// `[count, (name_tok, val_node)*]` (see parser `struct_lit`).
fn e_struct_lit_body(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    let run: u32 = nd.lhs;
    let fcount: u32 = e_extra(p, run);
    sb_put_cstr(sb, "{ ");
    var fi: u32 = 0;
    while fi < fcount {
        if fi > 0 {
            sb_put_cstr(sb, ", ");
        }
        let name_tok: u32 = e_extra(p, run + 1 + fi * 2);
        let val_node: u32 = e_extra(p, run + 1 + fi * 2 + 1);
        sb_put_cstr(sb, ".");
        let fname: []const u8 = e_tok_text(p, name_tok);
        sb_put_str(sb, fname);
        sb_put_cstr(sb, " = ");
        e_expr(p, sb, val_node);
        fi = fi + 1;
    }
    sb_put_cstr(sb, " }");
}

// Emit a target-typed compound literal `(TYPE){ .f0 = e0, ... }` for a struct literal assigned to
// a known type (a typed `let`/`var` init). `type_node` is the annotation's AST type node.
fn e_struct_lit(p: *mut Parser, sb: *mut StrBuf, node: u32, type_node: u32) -> void {
    sb_put_cstr(sb, "(");
    e_type(p, sb, type_node);
    sb_put_cstr(sb, ")");
    e_struct_lit_body(p, sb, node);
}

// Emit the `{ e0, e1, ... }` body of an array literal (P5.6). Directly usable as a C aggregate
// INITIALIZER (`T a[N] = { .. }`); the element run is `[count, node*]` (see parser `array_lit`).
// Elements are ordinary expressions (which may themselves be nested `.{...}` — emitted recursively).
fn e_array_lit_body(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    let run: u32 = nd.lhs;
    let ecount: u32 = e_extra(p, run);
    sb_put_cstr(sb, "{ ");
    var ei: u32 = 0;
    while ei < ecount {
        if ei > 0 {
            sb_put_cstr(sb, ", ");
        }
        let en: u32 = e_extra(p, run + 1 + ei);
        e_expr(p, sb, en);
        ei = ei + 1;
    }
    sb_put_cstr(sb, " }");
}

// ----- statement / block emission -----

// Emit an `if`/`while` condition. A binary-op condition already emits its own outer parentheses
// (see `e_expr`), so wrapping it again would produce `if ((a == b))` — which clang rejects under
// `-Wparentheses-equality -Werror`. Only non-binop conditions (a bare ident/call) get parens.
fn e_cond(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    let nd: Node = e_node(p, n);
    if e_is_binop(nd.kind) {
        e_expr(p, sb, n); // already `(lhs OP rhs)`
        return;
    }
    sb_put_cstr(sb, "(");
    e_expr(p, sb, n);
    sb_put_cstr(sb, ")");
}

fn e_stmt(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    if nd.kind == .let_decl || nd.kind == .var_decl {
        e_indent(sb, depth);
        // `e_emit_decl` emits `TYPE name`, or `T name[N]` for a fixed-size array (P5.6). The subset
        // always annotates in practice; a bare `let`/`var` would emit `void name`. `var` == `let` in C.
        let name: []const u8 = e_tok_text(p, nd.main_token);
        e_emit_decl(p, sb, nd.lhs, name);
        sb_put_cstr(sb, " = ");
        let init_nd: Node = e_node(p, nd.rhs);
        if init_nd.kind == .struct_lit {
            // Emit a target-typed compound literal using the annotation's type.
            e_struct_lit(p, sb, nd.rhs, nd.lhs);
        } else if init_nd.kind == .array_lit {
            // Aggregate initializer `{ .. }` (a C array cannot use a compound-literal cast here).
            e_array_lit_body(p, sb, nd.rhs);
        } else {
            e_expr(p, sb, nd.rhs);
        }
        sb_put_cstr(sb, ";\n");
        return;
    }
    if nd.kind == .return_stmt {
        e_indent(sb, depth);
        if nd.lhs == 0 {
            sb_put_cstr(sb, "return;\n");
        } else {
            sb_put_cstr(sb, "return ");
            e_expr(p, sb, nd.lhs);
            sb_put_cstr(sb, ";\n");
        }
        return;
    }
    if nd.kind == .if_stmt {
        e_indent(sb, depth);
        sb_put_cstr(sb, "if ");
        e_cond(p, sb, nd.lhs);
        sb_put_cstr(sb, " ");
        let rec: u32 = nd.rhs;
        let then_b: u32 = e_extra(p, rec);
        let else_b: u32 = e_extra(p, rec + 1);
        e_block(p, sb, then_b, depth);
        if else_b != 0 {
            sb_put_cstr(sb, " else ");
            let en: Node = e_node(p, else_b);
            if en.kind == .if_stmt {
                // `else if` chain: emit the nested if inline (no extra indentation prefix).
                e_stmt_inline(p, sb, else_b, depth);
            } else {
                e_block(p, sb, else_b, depth);
            }
        }
        sb_put_cstr(sb, "\n");
        return;
    }
    if nd.kind == .while_stmt {
        e_indent(sb, depth);
        sb_put_cstr(sb, "while ");
        e_cond(p, sb, nd.lhs);
        sb_put_cstr(sb, " ");
        e_block(p, sb, nd.rhs, depth);
        sb_put_cstr(sb, "\n");
        return;
    }
    if nd.kind == .assign {
        e_indent(sb, depth);
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, " = ");
        e_expr(p, sb, nd.rhs);
        sb_put_cstr(sb, ";\n");
        return;
    }
    if nd.kind == .expr_stmt {
        e_indent(sb, depth);
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ";\n");
        return;
    }
    if nd.kind == .switch_stmt {
        e_switch(p, sb, n, depth);
        return;
    }
    if nd.kind == .unsafe_block {
        // `unsafe { ... }` (P5.8): C has no `unsafe`, so emit the inner block as a plain brace block.
        e_indent(sb, depth);
        e_block(p, sb, nd.lhs, depth);
        sb_put_cstr(sb, "\n");
        return;
    }
    // Unknown statement kind: emit nothing.
}

// True when arm-pattern token `tok` is the `_` wildcard (a `.variant` arm stores an `identifier`
// token). Both operands are bound to locals before comparing, per gap G23.
fn e_is_underscore(p: *mut Parser, tok: u32) -> bool {
    let k: u32 = token_kind_at(&p.tl, tok as usize);
    let uw: TokKind = .underscore;
    let want: u32 = uw.raw();
    return k == want;
}

// Emit the C `case` constant `<EnumName>_<variant>` for a `.variant` arm whose variant ident is
// token `vtok`. Like `e_enum_lit`, the AST does not carry which enum the bare `.variant` belongs to,
// so the module's enum decls are scanned for the one declaring this variant (gap G28: variant names
// are assumed unique across enums — first match wins).
fn e_case_label(p: *mut Parser, sb: *mut StrBuf, vtok: u32) -> void {
    let vtext: []const u8 = e_tok_text(p, vtok);
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .enum_decl {
            let rec: u32 = dn.lhs;
            let vrun: u32 = e_extra(p, rec + 3);
            let vc: u32 = e_extra(p, vrun);
            var j: u32 = 0;
            while j < vc {
                let etok: u32 = e_extra(p, vrun + 1 + j);
                let vn: []const u8 = e_tok_text(p, etok);
                let m: bool = mem_eql(vtext, vn);
                if m {
                    let ename: []const u8 = e_tok_text(p, dn.main_token);
                    sb_put_str(sb, ename);
                    sb_put_cstr(sb, "_");
                    sb_put_str(sb, vtext);
                    return;
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
    // Unresolved (sema would have rejected this): emit the bare variant lexeme as a fallback.
    sb_put_str(sb, vtext);
}

// Emit a `switch` statement. The subject is a transparent integer typedef (see `e_enum_decl`), so a
// C `switch` on it is direct; each `.variant` arm becomes `case <EnumName>_<variant>: { .. } break;`
// and a `_` arm becomes `default: { .. } break;`. The arms run is `[count, (pat_tok, block)*]` (see
// parser `switch_stmt`); `e_is_underscore` distinguishes a wildcard pattern from a variant one.
fn e_switch(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    e_indent(sb, depth);
    sb_put_cstr(sb, "switch (");
    e_expr(p, sb, nd.lhs);
    sb_put_cstr(sb, ") {\n");
    let run: u32 = nd.rhs;
    let arm_count: u32 = e_extra(p, run);
    var ai: u32 = 0;
    while ai < arm_count {
        let pat_tok: u32 = e_extra(p, run + 1 + ai * 2);
        let blk: u32 = e_extra(p, run + 1 + ai * 2 + 1);
        e_indent(sb, depth + 1);
        let is_wild: bool = e_is_underscore(p, pat_tok);
        if is_wild {
            sb_put_cstr(sb, "default: ");
        } else {
            sb_put_cstr(sb, "case ");
            e_case_label(p, sb, pat_tok);
            sb_put_cstr(sb, ": ");
        }
        e_block(p, sb, blk, depth + 1);
        sb_put_cstr(sb, " break;\n");
        ai = ai + 1;
    }
    e_indent(sb, depth);
    sb_put_cstr(sb, "}\n");
}

// Emit a statement WITHOUT a leading indent (used for the `else if` inline case).
fn e_stmt_inline(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    if nd.kind == .if_stmt {
        sb_put_cstr(sb, "if ");
        e_cond(p, sb, nd.lhs);
        sb_put_cstr(sb, " ");
        let rec: u32 = nd.rhs;
        let then_b: u32 = e_extra(p, rec);
        let else_b: u32 = e_extra(p, rec + 1);
        e_block(p, sb, then_b, depth);
        if else_b != 0 {
            sb_put_cstr(sb, " else ");
            let en: Node = e_node(p, else_b);
            if en.kind == .if_stmt {
                e_stmt_inline(p, sb, else_b, depth);
            } else {
                e_block(p, sb, else_b, depth);
            }
        }
        return;
    }
    // Only `if` is reachable here.
}

// Emit a block `{ ... }`. Statements are indented at `depth + 1`; the closing brace sits at
// `depth`.
fn e_block(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    sb_put_cstr(sb, "{\n");
    let run: u32 = nd.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let s: u32 = e_extra(p, run + 1 + i);
        e_stmt(p, sb, s, depth + 1);
        i = i + 1;
    }
    e_indent(sb, depth);
    sb_put_cstr(sb, "}");
}

// ----- declaration / module emission -----

// Emit a function's C signature `RET NAME(PARAMS)` (no trailing space, no body). Shared by the
// forward-prototype pass and the definition pass so a call can name a callee declared in ANY module
// regardless of concatenation order (the loader flattens imports in dependency-agnostic order — see
// e_module's prototype loop).
fn e_fn_sig(p: *mut Parser, sb: *mut StrBuf, fn_node: u32) -> void {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    // Fixed record [exported, params_run, ret_type, body]; `exported` has no C spelling.
    let params_run: u32 = e_extra(p, frec + 1);
    let ret_ty: u32 = e_extra(p, frec + 2);

    e_type(p, sb, ret_ty);
    sb_put_cstr(sb, " ");
    let name: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_str(sb, name);
    sb_put_cstr(sb, "(");
    let pcount: u32 = e_extra(p, params_run);
    if pcount == 0 {
        sb_put_cstr(sb, "void");
    } else {
        var k: u32 = 0;
        while k < pcount {
            if k > 0 {
                sb_put_cstr(sb, ", ");
            }
            let pn: u32 = e_extra(p, params_run + 1 + k);
            let pnode: Node = e_node(p, pn);
            let pname: []const u8 = e_tok_text(p, pnode.main_token);
            e_emit_decl(p, sb, pnode.lhs, pname); // `T p[N]` for a fixed-array param (P5.6)
            k = k + 1;
        }
    }
    sb_put_cstr(sb, ")");
}

fn e_fn(p: *mut Parser, sb: *mut StrBuf, fn_node: u32) -> void {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    let body: u32 = e_extra(p, frec + 3);
    e_fn_sig(p, sb, fn_node);
    sb_put_cstr(sb, " ");
    p.cur_fn = fn_node; // P5.7: slice-aware accesses resolve base types against this function
    e_block(p, sb, body, 0);
    p.cur_fn = 0;
    sb_put_cstr(sb, "\n\n");
}

// Emit an `extern "C" fn` as a C prototype `RET NAME(PARAMS);` (P5.8). The symbol is provided by
// the C side (libc / a driver shim), so only a declaration is emitted; call sites reference NAME
// like any function. The record is [params_run, ret_type] (see parser `extern_fn`).
fn e_extern_fn(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    let exrec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, exrec);
    let ret_ty: u32 = e_extra(p, exrec + 1);
    e_type(p, sb, ret_ty);
    sb_put_cstr(sb, " ");
    let name: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_str(sb, name);
    sb_put_cstr(sb, "(");
    let pcount: u32 = e_extra(p, params_run);
    if pcount == 0 {
        sb_put_cstr(sb, "void");
    } else {
        var k: u32 = 0;
        while k < pcount {
            if k > 0 {
                sb_put_cstr(sb, ", ");
            }
            let pn: u32 = e_extra(p, params_run + 1 + k);
            let pnode: Node = e_node(p, pn);
            let pname: []const u8 = e_tok_text(p, pnode.main_token);
            e_emit_decl(p, sb, pnode.lhs, pname);
            k = k + 1;
        }
    }
    sb_put_cstr(sb, ");\n");
}

// Emit a struct declaration as a C typedef: `typedef struct NAME { T0 f0; ... } NAME;`. The field
// run is `[count, (name_tok, type_node)*]` (see parser `struct_decl`).
fn e_struct_decl(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    sb_put_cstr(sb, "typedef struct ");
    let name: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_str(sb, name);
    sb_put_cstr(sb, " {\n");
    let run: u32 = nd.lhs;
    let fcount: u32 = e_extra(p, run);
    var fi: u32 = 0;
    while fi < fcount {
        let name_tok: u32 = e_extra(p, run + 1 + fi * 2);
        let type_node: u32 = e_extra(p, run + 1 + fi * 2 + 1);
        sb_put_cstr(sb, "    ");
        let fname: []const u8 = e_tok_text(p, name_tok);
        e_emit_decl(p, sb, type_node, fname); // `T f[N]` for a fixed-array field (P5.6)
        sb_put_cstr(sb, ";\n");
        fi = fi + 1;
    }
    sb_put_cstr(sb, "} ");
    sb_put_str(sb, name);
    sb_put_cstr(sb, ";\n\n");
}

// Emit an enum declaration as a transparent typedef over its repr integer plus an anonymous C
// `enum {}` giving each variant its ordinal constant `<NAME>_<variant>` (0,1,2,... in order). This
// mirrors the real C backend (src/lower_c_defs.zig `emitEnumType`): the typedef makes the enum a
// plain integer (so `.raw()` is the identity) and the constants match the source order exactly.
// The fixed record is [exported, is_open, repr_type(0=none), variants_run] (see parser `enum_decl`).
fn e_enum_decl(p: *mut Parser, sb: *mut StrBuf, node: u32) -> void {
    let nd: Node = e_node(p, node);
    let rec: u32 = nd.lhs;
    let repr_node: u32 = e_extra(p, rec + 2);
    let vrun: u32 = e_extra(p, rec + 3);
    let name: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_cstr(sb, "typedef ");
    if repr_node == 0 {
        sb_put_cstr(sb, "uint32_t"); // default repr when the enum omits `: TYPE`
    } else {
        e_type(p, sb, repr_node);
    }
    sb_put_cstr(sb, " ");
    sb_put_str(sb, name);
    sb_put_cstr(sb, ";\nenum {\n");
    let vc: u32 = e_extra(p, vrun);
    var vi: u32 = 0;
    while vi < vc {
        let vtok: u32 = e_extra(p, vrun + 1 + vi);
        sb_put_cstr(sb, "    ");
        sb_put_str(sb, name);
        sb_put_cstr(sb, "_");
        let vn: []const u8 = e_tok_text(p, vtok);
        sb_put_str(sb, vn);
        sb_put_cstr(sb, ",\n"); // no explicit value: C auto-numbers 0,1,2,... matching ordinals
        vi = vi + 1;
    }
    sb_put_cstr(sb, "};\n\n");
}

// ----- P5.5 monomorphization -----

// True when a fn's param run contains a `comptime` param (`param_decl.rhs == 1`) — i.e. the fn is a
// generic template. Such templates are NOT emitted directly; one monomorphic copy is emitted per
// distinct concrete type argument used at a call site (see `e_module`).
fn e_fn_has_comptime(p: *mut Parser, params_run: u32) -> bool {
    let pc: u32 = e_extra(p, params_run);
    var i: u32 = 0;
    while i < pc {
        let pn: u32 = e_extra(p, params_run + 1 + i);
        let pnode: Node = e_node(p, pn);
        if pnode.rhs == 1 {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// True when `name_text` names a generic fn template in this module (a `fn_decl` with a comptime
// param). Used to route a call `f(u32, ...)` to the mangled monomorphic callee.
fn e_is_generic_fn(p: *mut Parser, name_text: []const u8) -> bool {
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .fn_decl {
            let nm: []const u8 = e_tok_text(p, dn.main_token);
            let m: bool = mem_eql(name_text, nm);
            if m {
                let frec: u32 = dn.lhs;
                let params_run: u32 = e_extra(p, frec + 1);
                let has: bool = e_fn_has_comptime(p, params_run);
                if has {
                    return true;
                }
            }
        }
        i = i + 1;
    }
    return false;
}

// The type param's name token of a generic fn (its `comptime` param's `main_token`), or 0 if none.
fn e_gfn_tparam(p: *mut Parser, fn_node: u32) -> u32 {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let pc: u32 = e_extra(p, params_run);
    var i: u32 = 0;
    while i < pc {
        let pn: u32 = e_extra(p, params_run + 1 + i);
        let pnode: Node = e_node(p, pn);
        if pnode.rhs == 1 {
            return pnode.main_token;
        }
        i = i + 1;
    }
    return 0;
}

// True when `txt` is a supported CONCRETE scalar type spelling. Instantiations are collected ONLY at
// concrete scalar type args (the subset's scope); this critically EXCLUDES the abstract type param
// itself (e.g. `Box<T>` in a template's own signature), which would otherwise self-substitute
// `T -> T` forever. Nested/struct type args are deferred (see the ledger).
fn e_is_scalar_lexeme(txt: []const u8) -> bool {
    var b_u8: [2]u8 = .{ 117, 56 }; // "u8"
    if mem_eql(txt, mem.as_bytes(&b_u8)) { return true; }
    var b_u16: [3]u8 = .{ 117, 49, 54 }; // "u16"
    if mem_eql(txt, mem.as_bytes(&b_u16)) { return true; }
    var b_u32: [3]u8 = .{ 117, 51, 50 }; // "u32"
    if mem_eql(txt, mem.as_bytes(&b_u32)) { return true; }
    var b_u64: [3]u8 = .{ 117, 54, 52 }; // "u64"
    if mem_eql(txt, mem.as_bytes(&b_u64)) { return true; }
    var b_usize: [5]u8 = .{ 117, 115, 105, 122, 101 }; // "usize"
    if mem_eql(txt, mem.as_bytes(&b_usize)) { return true; }
    var b_i8: [2]u8 = .{ 105, 56 }; // "i8"
    if mem_eql(txt, mem.as_bytes(&b_i8)) { return true; }
    var b_i16: [3]u8 = .{ 105, 49, 54 }; // "i16"
    if mem_eql(txt, mem.as_bytes(&b_i16)) { return true; }
    var b_i32: [3]u8 = .{ 105, 51, 50 }; // "i32"
    if mem_eql(txt, mem.as_bytes(&b_i32)) { return true; }
    var b_i64: [3]u8 = .{ 105, 54, 52 }; // "i64"
    if mem_eql(txt, mem.as_bytes(&b_i64)) { return true; }
    var b_isize: [5]u8 = .{ 105, 115, 105, 122, 101 }; // "isize"
    if mem_eql(txt, mem.as_bytes(&b_isize)) { return true; }
    return false;
}

// True when a concrete type/ident node whose lexeme equals `arg`'s is already in `out` (dedup by
// lexeme — the subset has no set type, so instantiations are deduped with a linear scan; gap-noted).
fn e_arg_present(p: *mut Parser, out: *Vec<u32>, arg: u32) -> bool {
    let at: []const u8 = e_node_lexeme(p, arg);
    let n: usize = vec_len(u32, out);
    var i: usize = 0;
    while i < n {
        let ex: u32 = vec_get(u32, out, i);
        let et: []const u8 = e_node_lexeme(p, ex);
        let m: bool = mem_eql(at, et);
        if m {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// Collect the DISTINCT concrete type-arg nodes used with generic struct base `base_text` — every
// `type_generic` node in the flat arena whose base name matches (deduped by lexeme). Scanning the
// whole node array is simpler than a tree walk and finds every use regardless of context.
fn e_collect_type_insts(p: *mut Parser, base_text: []const u8, out: *mut Vec<u32>) -> void {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        if nd.kind == .type_generic {
            let b: []const u8 = e_tok_text(p, nd.main_token);
            let m: bool = mem_eql(base_text, b);
            if m {
                let arg_lex: []const u8 = e_node_lexeme(p, nd.lhs);
                let concrete: bool = e_is_scalar_lexeme(arg_lex);
                if concrete {
                    let present: bool = e_arg_present(p, &*out, nd.lhs);
                    if !present {
                        vec_push(u32, out, nd.lhs);
                    }
                }
            }
        }
        i = i + 1;
    }
}

// Collect the DISTINCT concrete type-arg nodes used at calls to generic fn `fn_text` — the first arg
// (the type argument) of every `call` whose callee ident matches (deduped by lexeme).
fn e_collect_call_insts(p: *mut Parser, fn_text: []const u8, out: *mut Vec<u32>) -> void {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        if nd.kind == .call {
            let cnode: Node = e_node(p, nd.lhs);
            if cnode.kind == .ident_expr {
                let cname: []const u8 = e_tok_text(p, cnode.main_token);
                let m: bool = mem_eql(fn_text, cname);
                if m {
                    let arg_run: u32 = nd.rhs;
                    let argc: u32 = e_extra(p, arg_run);
                    if argc >= 1 {
                        let a0: u32 = e_extra(p, arg_run + 1);
                        let a0lex: []const u8 = e_node_lexeme(p, a0);
                        let concrete: bool = e_is_scalar_lexeme(a0lex);
                        if concrete {
                            let present: bool = e_arg_present(p, &*out, a0);
                            if !present {
                                vec_push(u32, out, a0);
                            }
                        }
                    }
                }
            }
        }
        i = i + 1;
    }
}

// Emit ONE monomorphic struct `typedef struct S_<concrete> { ... } S_<concrete>;` for generic
// template `template_node` at concrete type `concrete_node`, substituting the type param throughout.
fn e_gstruct_mono(p: *mut Parser, sb: *mut StrBuf, template_node: u32, concrete_node: u32) -> void {
    let nd: Node = e_node(p, template_node);
    let grec: u32 = nd.lhs;
    let tparam_tok: u32 = e_extra(p, grec);
    let fields_run: u32 = e_extra(p, grec + 1);
    e_set_sub(p, tparam_tok, concrete_node);
    let base: []const u8 = e_tok_text(p, nd.main_token);
    let clex: []const u8 = e_node_lexeme(p, concrete_node);
    sb_put_cstr(sb, "typedef struct ");
    sb_put_str(sb, base);
    sb_put_cstr(sb, "_");
    sb_put_str(sb, clex);
    sb_put_cstr(sb, " {\n");
    let fcount: u32 = e_extra(p, fields_run);
    var fi: u32 = 0;
    while fi < fcount {
        let name_tok: u32 = e_extra(p, fields_run + 1 + fi * 2);
        let type_node: u32 = e_extra(p, fields_run + 1 + fi * 2 + 1);
        sb_put_cstr(sb, "    ");
        let fname: []const u8 = e_tok_text(p, name_tok);
        // `T f[N]` for a fixed-array field; the element type param is substituted by the active sub
        // context (e.g. `[4]T` -> `uint32_t f[4]` when monomorphizing at u32). (P5.6)
        e_emit_decl(p, sb, type_node, fname);
        sb_put_cstr(sb, ";\n");
        fi = fi + 1;
    }
    sb_put_cstr(sb, "} ");
    sb_put_str(sb, base);
    sb_put_cstr(sb, "_");
    sb_put_str(sb, clex);
    sb_put_cstr(sb, ";\n\n");
    e_clear_sub(p);
}

// Emit a monomorphic fn signature `RET NAME_<concrete>(PARAMS)` for generic template `fn_node` at
// `concrete_node` — the comptime type param is DROPPED and the type param is substituted in the
// return type and remaining param types. The substitution context must be set by the caller.
fn e_gfn_sig_mono(p: *mut Parser, sb: *mut StrBuf, fn_node: u32, concrete_node: u32) -> void {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let ret_ty: u32 = e_extra(p, frec + 2);
    e_type(p, sb, ret_ty);
    sb_put_cstr(sb, " ");
    let base: []const u8 = e_tok_text(p, nd.main_token);
    let clex: []const u8 = e_node_lexeme(p, concrete_node);
    sb_put_str(sb, base);
    sb_put_cstr(sb, "_");
    sb_put_str(sb, clex);
    sb_put_cstr(sb, "(");
    let pcount: u32 = e_extra(p, params_run);
    var emitted: u32 = 0;
    var k: u32 = 0;
    while k < pcount {
        let pn: u32 = e_extra(p, params_run + 1 + k);
        let pnode: Node = e_node(p, pn);
        if pnode.rhs != 1 {
            if emitted > 0 {
                sb_put_cstr(sb, ", ");
            }
            let pname: []const u8 = e_tok_text(p, pnode.main_token);
            e_emit_decl(p, sb, pnode.lhs, pname); // `T p[N]` for a fixed-array param (P5.6)
            emitted = emitted + 1;
        }
        k = k + 1;
    }
    if emitted == 0 {
        sb_put_cstr(sb, "void");
    }
    sb_put_cstr(sb, ")");
}

// Emit one monomorphic fn PROTOTYPE for generic template `fn_node` at `concrete_node`.
fn e_gfn_proto_mono(p: *mut Parser, sb: *mut StrBuf, fn_node: u32, concrete_node: u32) -> void {
    let tparam_tok: u32 = e_gfn_tparam(p, fn_node);
    e_set_sub(p, tparam_tok, concrete_node);
    e_gfn_sig_mono(p, sb, fn_node, concrete_node);
    sb_put_cstr(sb, ";\n");
    e_clear_sub(p);
}

// Emit one monomorphic fn DEFINITION for generic template `fn_node` at `concrete_node`.
fn e_gfn_mono(p: *mut Parser, sb: *mut StrBuf, fn_node: u32, concrete_node: u32) -> void {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    let body: u32 = e_extra(p, frec + 3);
    let tparam_tok: u32 = e_gfn_tparam(p, fn_node);
    e_set_sub(p, tparam_tok, concrete_node);
    e_gfn_sig_mono(p, sb, fn_node, concrete_node);
    sb_put_cstr(sb, " ");
    p.cur_fn = fn_node;
    e_block(p, sb, body, 0);
    p.cur_fn = 0;
    sb_put_cstr(sb, "\n\n");
    e_clear_sub(p);
}

// Emit the whole module: the fixed prelude, every enum then struct typedef (so they precede any
// use), then one C function per `fn` decl.
fn e_module(p: *mut Parser, sb: *mut StrBuf) -> void {
    sb_put_cstr(sb, "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n\n");
    // P5.7: fat-pointer slice typedefs first (a struct field or fn signature may reference one).
    e_slice_typedefs(p, sb);
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var ei: u32 = 0;
    while ei < count {
        let ed: u32 = e_extra(p, run + 1 + ei);
        let edn: Node = e_node(p, ed);
        if edn.kind == .enum_decl {
            e_enum_decl(p, sb, ed);
        }
        ei = ei + 1;
    }
    var si: u32 = 0;
    while si < count {
        let sd: u32 = e_extra(p, run + 1 + si);
        let sdn: Node = e_node(p, sd);
        if sdn.kind == .struct_decl {
            e_struct_decl(p, sb, sd);
        }
        si = si + 1;
    }
    // P5.5 monomorphic structs: for each generic struct template, emit one typedef per distinct
    // concrete type argument used anywhere in the module (deduped). These precede all functions.
    var gsi: u32 = 0;
    while gsi < count {
        let gd: u32 = e_extra(p, run + 1 + gsi);
        let gdn: Node = e_node(p, gd);
        if gdn.kind == .struct_gdecl {
            let base: []const u8 = e_tok_text(p, gdn.main_token);
            var insts: Vec<u32> = vec_new(u32, p.a);
            e_collect_type_insts(p, base, &insts);
            let ni: usize = vec_len(u32, &insts);
            var ii: usize = 0;
            while ii < ni {
                let concrete: u32 = vec_get(u32, &insts, ii);
                e_gstruct_mono(p, sb, gd, concrete);
                ii = ii + 1;
            }
            vec_free(u32, &insts);
        }
        gsi = gsi + 1;
    }
    // Forward prototypes for every function, so a call resolves regardless of the order the loader
    // concatenated the modules in (an importer may textually precede the module it depends on). A
    // generic template is skipped here and emitted as monomorphic prototypes below.
    var fi: u32 = 0;
    while fi < count {
        let fd: u32 = e_extra(p, run + 1 + fi);
        let fdn: Node = e_node(p, fd);
        if fdn.kind == .extern_fn {
            // P5.8: emit the C prototype for each `extern "C" fn` (its symbol is provided externally).
            e_extern_fn(p, sb, fd);
        }
        if fdn.kind == .fn_decl {
            let frec: u32 = fdn.lhs;
            let params_run: u32 = e_extra(p, frec + 1);
            let generic: bool = e_fn_has_comptime(p, params_run);
            if !generic {
                e_fn_sig(p, sb, fd);
                sb_put_cstr(sb, ";\n");
            }
        }
        fi = fi + 1;
    }
    // P5.5 monomorphic fn prototypes: one per distinct concrete type argument at a call site.
    var gpi: u32 = 0;
    while gpi < count {
        let gpd: u32 = e_extra(p, run + 1 + gpi);
        let gpdn: Node = e_node(p, gpd);
        if gpdn.kind == .fn_decl {
            let frec2: u32 = gpdn.lhs;
            let params_run2: u32 = e_extra(p, frec2 + 1);
            let generic2: bool = e_fn_has_comptime(p, params_run2);
            if generic2 {
                let fname: []const u8 = e_tok_text(p, gpdn.main_token);
                var pinsts: Vec<u32> = vec_new(u32, p.a);
                e_collect_call_insts(p, fname, &pinsts);
                let pn2: usize = vec_len(u32, &pinsts);
                var pj: usize = 0;
                while pj < pn2 {
                    let pconcrete: u32 = vec_get(u32, &pinsts, pj);
                    e_gfn_proto_mono(p, sb, gpd, pconcrete);
                    pj = pj + 1;
                }
                vec_free(u32, &pinsts);
            }
        }
        gpi = gpi + 1;
    }
    sb_put_cstr(sb, "\n");
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .fn_decl {
            let frec3: u32 = dn.lhs;
            let params_run3: u32 = e_extra(p, frec3 + 1);
            let generic3: bool = e_fn_has_comptime(p, params_run3);
            if !generic3 {
                e_fn(p, sb, d);
            }
        }
        i = i + 1;
    }
    // P5.5 monomorphic fn definitions: one per distinct concrete type argument at a call site.
    var gfi: u32 = 0;
    while gfi < count {
        let gfd: u32 = e_extra(p, run + 1 + gfi);
        let gfdn: Node = e_node(p, gfd);
        if gfdn.kind == .fn_decl {
            let frec4: u32 = gfdn.lhs;
            let params_run4: u32 = e_extra(p, frec4 + 1);
            let generic4: bool = e_fn_has_comptime(p, params_run4);
            if generic4 {
                let fname2: []const u8 = e_tok_text(p, gfdn.main_token);
                var dinsts: Vec<u32> = vec_new(u32, p.a);
                e_collect_call_insts(p, fname2, &dinsts);
                let dn2: usize = vec_len(u32, &dinsts);
                var dj: usize = 0;
                while dj < dn2 {
                    let dconcrete: u32 = vec_get(u32, &dinsts, dj);
                    e_gfn_mono(p, sb, gfd, dconcrete);
                    dj = dj + 1;
                }
                vec_free(u32, &dinsts);
            }
        }
        gfi = gfi + 1;
    }
}

// ----- public entry -----

// Lex + parse + emit: run the full front end over `source` and return a `StrBuf` owning the
// emitted C bytes. The caller reads the bytes back (sb_len/sb_byte) and frees the buffer with
// sb_free. `a` backs both the (internally freed) parser arena and the returned buffer.
export fn emit_c_run(source: []const u8, a: *mut dyn Allocator) -> StrBuf {
    var p: Parser = parser_run(source, a);
    var sb: StrBuf = sb_new(a);
    e_module(&p, &sb);
    parser_free(&p);
    return sb;
}
