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
    if mem_eql(txt, "u8") { sb_put_cstr(sb, "uint8_t"); return; }
    if mem_eql(txt, "u16") { sb_put_cstr(sb, "uint16_t"); return; }
    if mem_eql(txt, "u32") { sb_put_cstr(sb, "uint32_t"); return; }
    if mem_eql(txt, "u64") { sb_put_cstr(sb, "uint64_t"); return; }
    if mem_eql(txt, "usize") { sb_put_cstr(sb, "size_t"); return; }
    if mem_eql(txt, "i8") { sb_put_cstr(sb, "int8_t"); return; }
    if mem_eql(txt, "i16") { sb_put_cstr(sb, "int16_t"); return; }
    if mem_eql(txt, "i32") { sb_put_cstr(sb, "int32_t"); return; }
    if mem_eql(txt, "i64") { sb_put_cstr(sb, "int64_t"); return; }
    if mem_eql(txt, "isize") { sb_put_cstr(sb, "ptrdiff_t"); return; }
    if mem_eql(txt, "f64") { sb_put_cstr(sb, "double"); return; }
    if mem_eql(txt, "f32") { sb_put_cstr(sb, "float"); return; }
    // Address classes (subset model): opaque word-backed scalars -> `uintptr_t` (stdint.h is in the
    // prelude). Sema collapses them to `usize`; the emitted C type is `uintptr_t` (matching the real
    // backend's address-word model). `phys()` and `as`-cast minting are plain word round-trips.
    if mem_eql(txt, "PAddr") { sb_put_cstr(sb, "uintptr_t"); return; }
    if mem_eql(txt, "VAddr") { sb_put_cstr(sb, "uintptr_t"); return; }
    if mem_eql(txt, "DmaAddr") { sb_put_cstr(sb, "uintptr_t"); return; }
    if mem_eql(txt, "UserAddr") { sb_put_cstr(sb, "uintptr_t"); return; }
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
    // A `*mut dyn TRAIT` / `*dyn TRAIT` trait object (P5.10) is the fat-pointer struct `TRAIT__dyn`
    // ({ void* data; const TRAIT__vtable* vtbl; }, emitted by `e_trait_typedefs`) — passed BY VALUE,
    // so no trailing `*`. main_token names the trait.
    if nd.kind == .type_dyn {
        let tr: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, tr);
        sb_put_cstr(sb, "__dyn");
        return;
    }
    // A value optional `?T` (G11) is the tagged aggregate `mc_opt_<T>` (see `e_opt_typedefs`). The
    // payload's lexeme (with the active generic type param substituted) names the struct, matching the
    // real backend's `mc_opt_<T>` (src/lower_c_names.zig).
    if nd.kind == .type_optional {
        e_put_opt_name(p, sb, nd.lhs);
        return;
    }
    // A `Result<T,E>` (the real backend's builtin tagged type) is the struct `mc_result_<T>_<E>` (see
    // `e_result_typedefs`), matching src/lower_c_names.zig's `mc_result_<oksuffix>_<errsuffix>`.
    if nd.kind == .type_result {
        e_result_type_name(p, sb, tn);
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
        // A type arg written as a bare `T` is a `type_name` in a TYPE position (struct field, sig) but
        // an `ident_expr` in an EXPRESSION position (a call's leading type arg, e.g. `vec_reserve(T, ..)`);
        // both carry the spelling in `main_token` and must substitute to the active concrete type.
        let is_type_name: bool = nd.kind == .type_name;
        let is_ident: bool = nd.kind == .ident_expr;
        if is_type_name || is_ident {
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

// ----- value-optional `?T` support (G11 in the subset) -----
//
// A `?T` for a scalar payload T lowers to the real backend's tagged aggregate
//   typedef struct mc_opt_<T> { bool present; <T> value; } mc_opt_<T>;
// Present = `(mc_opt_<T>){ .present = true, .value = v }`; absent (`null`) = `{ .present = false }`;
// `if let v = opt` -> `if (opt.present) { T v = opt.value; .. }`; `opt == null` -> `(!opt.present)`.
// The payload SUFFIX uses the MC type name (e.g. `usize`), matching src/lower_c_names.zig's mc_opt_<T>.

// Emit the `mc_opt_<T>` type NAME for a payload type node (T's lexeme, with substitution applied).
fn e_put_opt_name(p: *mut Parser, sb: *mut StrBuf, payload_tn: u32) -> void {
    sb_put_cstr(sb, "mc_opt_");
    let lex: []const u8 = e_type_arg_lexeme(p, payload_tn);
    sb_put_str(sb, lex);
}

// True when a `?T` payload node uses the tagged value repr (a `type_name`: scalar/address/struct). A
// pointer/slice/dyn payload keeps a sentinel repr (deferred in the subset), so it is skipped.
fn e_opt_payload_ok(p: *mut Parser, payload_tn: u32) -> bool {
    let nd: Node = e_node(p, payload_tn);
    return nd.kind == .type_name;
}

// True when an EARLIER `type_optional` node (index < `cur`) has the same payload lexeme — the dedup
// for `e_opt_typedefs` (mirrors `e_slice_dup_before`).
fn e_opt_dup_before(p: *mut Parser, cur: u32, lex: []const u8) -> bool {
    var j: u32 = 1;
    while j < cur {
        let nd: Node = e_node(p, j);
        if nd.kind == .type_optional {
            let ok: bool = e_opt_payload_ok(p, nd.lhs);
            if ok {
                let jlex: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
                let same: bool = mem_eql(jlex, lex);
                if same {
                    return true;
                }
            }
        }
        j = j + 1;
    }
    return false;
}

// Emit one `typedef struct mc_opt_<T> { bool present; <T> value; } mc_opt_<T>;`.
fn e_emit_one_opt_typedef(p: *mut Parser, sb: *mut StrBuf, payload_tn: u32) -> void {
    let lex: []const u8 = e_tok_text(p, e_node(p, payload_tn).main_token);
    sb_put_cstr(sb, "typedef struct mc_opt_");
    sb_put_str(sb, lex);
    sb_put_cstr(sb, " {\n    bool present;\n    ");
    e_type(p, sb, payload_tn);
    sb_put_cstr(sb, " value;\n} mc_opt_");
    sb_put_str(sb, lex);
    sb_put_cstr(sb, ";\n");
}

// Emit every `mc_opt_<T>` typedef used in the module, deduped by payload lexeme. Emitted after the
// slice typedefs and before enum/struct typedefs (a struct field or fn signature may reference one).
fn e_opt_typedefs(p: *mut Parser, sb: *mut StrBuf) -> void {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var emitted: u32 = 0;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        if nd.kind == .type_optional {
            let ok: bool = e_opt_payload_ok(p, nd.lhs);
            if ok {
                let lex: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
                let dup: bool = e_opt_dup_before(p, i, lex);
                if !dup {
                    e_emit_one_opt_typedef(p, sb, nd.lhs);
                    emitted = emitted + 1;
                }
            }
        }
        i = i + 1;
    }
    if emitted > 0 {
        sb_put_cstr(sb, "\n");
    }
}

// ----- `Result<T,E>` support (the real backend's builtin tagged type) -----
//
// A `Result<T,E>` lowers to the real C backend's tagged struct (src/lower_c_defs.zig `emitResultType`):
//   typedef struct mc_result_<T>_<E> { bool is_ok; union { <T> ok; <E> err; } payload; } mc_result_<T>_<E>;
// `ok(x)`  = `(mc_result_..){ .is_ok = true,  .payload.ok  = x }`
// `err(x)` = `(mc_result_..){ .is_ok = false, .payload.err = x }`
// `if let`/`switch` test `.is_ok` and read `.payload.ok`/`.payload.err`; `expr?` early-returns on error.

// Emit the `mc_result_<T>_<E>` type NAME for a `type_result` node (its ok/err type-arg lexemes, with
// generic substitution applied). Matches the real backend's `mc_result_<oksuffix>_<errsuffix>`.
fn e_result_type_name(p: *mut Parser, sb: *mut StrBuf, result_tn: u32) -> void {
    let rn: Node = e_node(p, result_tn);
    sb_put_cstr(sb, "mc_result_");
    let oklex: []const u8 = e_type_arg_lexeme(p, rn.lhs);
    sb_put_str(sb, oklex);
    sb_put_cstr(sb, "_");
    let errlex: []const u8 = e_type_arg_lexeme(p, rn.rhs);
    sb_put_str(sb, errlex);
}

// True when an EARLIER `type_result` node (index < `cur`) has the same (ok, err) lexeme pair — the
// dedup for `e_result_typedefs` (mirrors `e_opt_dup_before`).
fn e_result_dup_before(p: *mut Parser, cur: u32, oklex: []const u8, errlex: []const u8) -> bool {
    var j: u32 = 1;
    while j < cur {
        let nd: Node = e_node(p, j);
        if nd.kind == .type_result {
            let jok: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
            let jerr: []const u8 = e_tok_text(p, e_node(p, nd.rhs).main_token);
            let a: bool = mem_eql(jok, oklex);
            let b: bool = mem_eql(jerr, errlex);
            if a && b {
                return true;
            }
        }
        j = j + 1;
    }
    return false;
}

// Emit one `typedef struct mc_result_<T>_<E> { bool is_ok; union { <T> ok; <E> err; } payload; } ...;`.
fn e_emit_one_result_typedef(p: *mut Parser, sb: *mut StrBuf, result_tn: u32) -> void {
    let rn: Node = e_node(p, result_tn);
    sb_put_cstr(sb, "typedef struct ");
    e_result_type_name(p, sb, result_tn);
    sb_put_cstr(sb, " {\n    bool is_ok;\n    union {\n        ");
    e_type(p, sb, rn.lhs);
    sb_put_cstr(sb, " ok;\n        ");
    e_type(p, sb, rn.rhs);
    sb_put_cstr(sb, " err;\n    } payload;\n} ");
    e_result_type_name(p, sb, result_tn);
    sb_put_cstr(sb, ";\n");
}

// Emit every `mc_result_<T>_<E>` typedef used in the module, deduped by (ok, err) lexeme pair. Emitted
// after the value-optional typedefs and before enum/struct typedefs (a fn signature or field may use one).
fn e_result_typedefs(p: *mut Parser, sb: *mut StrBuf) -> void {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var emitted: u32 = 0;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        if nd.kind == .type_result {
            let oklex: []const u8 = e_tok_text(p, e_node(p, nd.lhs).main_token);
            let errlex: []const u8 = e_tok_text(p, e_node(p, nd.rhs).main_token);
            let dup: bool = e_result_dup_before(p, i, oklex, errlex);
            if !dup {
                e_emit_one_result_typedef(p, sb, i);
                emitted = emitted + 1;
            }
        }
        i = i + 1;
    }
    if emitted > 0 {
        sb_put_cstr(sb, "\n");
    }
}

// Emit an `ok(x)` / `err(x)` constructor as the real backend's compound literal against the target
// `Result` type node `result_tn`. A literal arg (`.variant` / `.{..}`) is target-typed against the
// ok/err payload node; any other arg is emitted as a plain expression.
fn e_result_ctor(p: *mut Parser, sb: *mut StrBuf, call_node: u32, result_tn: u32, is_ok: bool) -> void {
    let cn: Node = e_node(p, call_node);
    let rn: Node = e_node(p, result_tn);
    var payload_tn: u32 = rn.rhs;
    if is_ok {
        payload_tn = rn.lhs;
    }
    let arg: u32 = e_extra(p, cn.rhs + 1);
    let argn: Node = e_node(p, arg);
    sb_put_cstr(sb, "(");
    e_result_type_name(p, sb, result_tn);
    if is_ok {
        sb_put_cstr(sb, "){ .is_ok = true, .payload.ok = ");
    } else {
        sb_put_cstr(sb, "){ .is_ok = false, .payload.err = ");
    }
    if argn.kind == .struct_lit {
        e_struct_lit(p, sb, arg, payload_tn);
    } else if argn.kind == .array_lit {
        e_array_lit_body(p, sb, arg);
    } else if argn.kind == .enum_lit {
        e_enum_lit(p, sb, arg);
    } else {
        e_expr(p, sb, arg);
    }
    sb_put_cstr(sb, " }");
}

// The current function's declared return TYPE node (`p.cur_fn`'s [.,.,ret_ty,.] record), or 0.
fn e_ret_type_node(p: *mut Parser) -> u32 {
    let fnn: u32 = p.cur_fn;
    if fnn == 0 {
        return 0;
    }
    let nd: Node = e_node(p, fnn);
    return e_extra(p, nd.lhs + 2);
}

// The PAYLOAD type node of an optional-typed expression (an ident bound to a `?T` local, or a call to
// a fn returning `?T`), or 0 when the expression is not resolvably optional. Used to type the `if let`
// binding and its temp.
fn e_opt_payload_type_node(p: *mut Parser, expr: u32) -> u32 {
    let nd: Node = e_node(p, expr);
    if nd.kind == .ident_expr {
        let name: []const u8 = e_tok_text(p, nd.main_token);
        let tn: u32 = e_local_type_node(p, name);
        if tn == 0 {
            return 0;
        }
        let tnode: Node = e_node(p, tn);
        if tnode.kind == .type_optional {
            return tnode.lhs;
        }
        return 0;
    }
    if nd.kind == .call {
        let cnode: Node = e_node(p, nd.lhs);
        if cnode.kind == .ident_expr {
            let cname: []const u8 = e_tok_text(p, cnode.main_token);
            let fnn: u32 = e_find_fn(p, cname);
            if fnn != 0 {
                let fnnode: Node = e_node(p, fnn);
                let rtn: u32 = e_extra(p, fnnode.lhs + 2);
                if rtn != 0 {
                    let rnode: Node = e_node(p, rtn);
                    if rnode.kind == .type_optional {
                        return rnode.lhs; // the payload type node
                    }
                }
            }
        }
        return 0;
    }
    return 0;
}

// True when an expression ALREADY yields a `?T` aggregate (so it should pass through a coercion site
// unchanged, not be re-wrapped as present). `null` is NOT optional-typed here (it is handled as the
// explicit absent case by the caller).
fn e_expr_is_optional(p: *mut Parser, expr: u32) -> bool {
    let tn: u32 = e_opt_payload_type_node(p, expr);
    return tn != 0;
}

// Coerce `val_node` into the value optional whose TYPE node is `opt_tn` (a `type_optional`): `null` ->
// `(mc_opt_<T>){ .present = false }`; an already-optional source -> pass-through; any other value ->
// `(mc_opt_<T>){ .present = true, .value = <val> }`. Mirrors the real backend's emitValueOptionalCoercion.
fn e_emit_opt_value(p: *mut Parser, sb: *mut StrBuf, val_node: u32, opt_tn: u32) -> void {
    let opt_node: Node = e_node(p, opt_tn);
    let payload_tn: u32 = opt_node.lhs;
    let vnd: Node = e_node(p, val_node);
    if vnd.kind == .null_literal {
        sb_put_cstr(sb, "(");
        e_put_opt_name(p, sb, payload_tn);
        sb_put_cstr(sb, "){ .present = false }");
        return;
    }
    let passthrough: bool = e_expr_is_optional(p, val_node);
    if passthrough {
        e_expr(p, sb, val_node);
        return;
    }
    sb_put_cstr(sb, "(");
    e_put_opt_name(p, sb, payload_tn);
    sb_put_cstr(sb, "){ .present = true, .value = ");
    e_expr(p, sb, val_node);
    sb_put_cstr(sb, " }");
}

// Emit just the STATEMENTS of a block (no surrounding braces) at `depth` — used to inline an `if let`
// then-branch after its narrowed binding is declared.
fn e_emit_block_body(p: *mut Parser, sb: *mut StrBuf, block_node: u32, depth: u32) -> void {
    let nd: Node = e_node(p, block_node);
    let run: u32 = nd.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let s: u32 = e_extra(p, run + 1 + i);
        e_stmt(p, sb, s, depth);
        i = i + 1;
    }
}

// Emit an `if let NAME = EXPR { .. } (else ..)?` (G11). EXPR is stashed in a per-statement temp (named
// by the node index, unique) so a call subject is evaluated exactly once, then narrowed:
//   { mc_opt_<T> __mc_iflet_N = <EXPR>;
//     if (__mc_iflet_N.present) { <T> NAME = __mc_iflet_N.value; <then> } else { <else> } }
fn e_if_let(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    let name: []const u8 = e_tok_text(p, nd.main_token);
    let opt_expr: u32 = nd.lhs;
    let rec: u32 = nd.rhs;
    let then_b: u32 = e_extra(p, rec);
    let else_b: u32 = e_extra(p, rec + 1);
    let payload_tn: u32 = e_opt_payload_type_node(p, opt_expr);
    e_indent(sb, depth);
    sb_put_cstr(sb, "{\n");
    // temp: mc_opt_<T> __mc_iflet_N = <EXPR>;
    e_indent(sb, depth + 1);
    e_put_opt_name(p, sb, payload_tn);
    sb_put_cstr(sb, " __mc_iflet_");
    sb_put_u32(sb, n);
    sb_put_cstr(sb, " = ");
    e_expr(p, sb, opt_expr);
    sb_put_cstr(sb, ";\n");
    // if (__mc_iflet_N.present) { <T> NAME = __mc_iflet_N.value; <then stmts> }
    e_indent(sb, depth + 1);
    sb_put_cstr(sb, "if (__mc_iflet_");
    sb_put_u32(sb, n);
    sb_put_cstr(sb, ".present) {\n");
    e_indent(sb, depth + 2);
    e_emit_decl(p, sb, payload_tn, name);
    sb_put_cstr(sb, " = __mc_iflet_");
    sb_put_u32(sb, n);
    sb_put_cstr(sb, ".value;\n");
    e_emit_block_body(p, sb, then_b, depth + 2);
    e_indent(sb, depth + 1);
    sb_put_cstr(sb, "}");
    if else_b != 0 {
        sb_put_cstr(sb, " else ");
        let en: Node = e_node(p, else_b);
        if en.kind == .if_stmt {
            e_stmt_inline(p, sb, else_b, depth + 1);
        } else {
            e_block(p, sb, else_b, depth + 1);
        }
    }
    sb_put_cstr(sb, "\n");
    e_indent(sb, depth);
    sb_put_cstr(sb, "}\n");
}

// Emit an `if let ok(v) = EXPR { .. } (else ..)?` / `if let err(e) = EXPR { .. }` (Result). EXPR is
// evaluated ONCE into a temp (its type recovered via `__typeof__`, which does not evaluate its operand),
// then the matching arm binds the payload:
//   { __typeof__(EXPR) __mc_iflet_N = EXPR;
//     if ([!]__mc_iflet_N.is_ok) { __typeof__(__mc_iflet_N.payload.F) NAME = __mc_iflet_N.payload.F; (void)NAME; <then> }
//     else { <else> } }
fn e_if_let_result(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    let name: []const u8 = e_tok_text(p, nd.main_token);
    let rexpr: u32 = nd.lhs;
    let rec: u32 = nd.rhs;
    let tag_tok: u32 = e_extra(p, rec);
    let then_b: u32 = e_extra(p, rec + 1);
    let else_b: u32 = e_extra(p, rec + 2);
    let tagtext: []const u8 = e_tok_text(p, tag_tok);
    let is_ok: bool = mem_eql(tagtext, "ok");
    e_indent(sb, depth);
    sb_put_cstr(sb, "{\n");
    e_indent(sb, depth + 1);
    sb_put_cstr(sb, "__typeof__(");
    e_expr(p, sb, rexpr);
    sb_put_cstr(sb, ") __mc_iflet_");
    sb_put_u32(sb, n);
    sb_put_cstr(sb, " = ");
    e_expr(p, sb, rexpr);
    sb_put_cstr(sb, ";\n");
    e_indent(sb, depth + 1);
    if is_ok {
        sb_put_cstr(sb, "if (__mc_iflet_");
    } else {
        sb_put_cstr(sb, "if (!__mc_iflet_");
    }
    sb_put_u32(sb, n);
    sb_put_cstr(sb, ".is_ok) {\n");
    e_indent(sb, depth + 2);
    sb_put_cstr(sb, "__typeof__(__mc_iflet_");
    sb_put_u32(sb, n);
    if is_ok {
        sb_put_cstr(sb, ".payload.ok) ");
    } else {
        sb_put_cstr(sb, ".payload.err) ");
    }
    sb_put_str(sb, name);
    sb_put_cstr(sb, " = __mc_iflet_");
    sb_put_u32(sb, n);
    if is_ok {
        sb_put_cstr(sb, ".payload.ok;\n");
    } else {
        sb_put_cstr(sb, ".payload.err;\n");
    }
    e_indent(sb, depth + 2);
    sb_put_cstr(sb, "(void)");
    sb_put_str(sb, name);
    sb_put_cstr(sb, ";\n");
    e_emit_block_body(p, sb, then_b, depth + 2);
    e_indent(sb, depth + 1);
    sb_put_cstr(sb, "}");
    if else_b != 0 {
        sb_put_cstr(sb, " else ");
        let en: Node = e_node(p, else_b);
        if en.kind == .if_stmt {
            e_stmt_inline(p, sb, else_b, depth + 1);
        } else {
            e_block(p, sb, else_b, depth + 1);
        }
    }
    sb_put_cstr(sb, "\n");
    e_indent(sb, depth);
    sb_put_cstr(sb, "}\n");
}

// Emit a `switch r { ok(v) => {..}, err(e) => {..} }` (Result). The subject is evaluated ONCE into a
// temp; each arm is an `is_ok`-guarded block that binds its payload (via `__typeof__`). Arms run of
// TRIPLES [count, (tag_tok, bind_tok, block)*].
fn e_result_switch(p: *mut Parser, sb: *mut StrBuf, n: u32, depth: u32) -> void {
    let nd: Node = e_node(p, n);
    let subject: u32 = nd.lhs;
    let run: u32 = nd.rhs;
    let count: u32 = e_extra(p, run);
    e_indent(sb, depth);
    sb_put_cstr(sb, "{\n");
    e_indent(sb, depth + 1);
    sb_put_cstr(sb, "__typeof__(");
    e_expr(p, sb, subject);
    sb_put_cstr(sb, ") __mc_sw_");
    sb_put_u32(sb, n);
    sb_put_cstr(sb, " = ");
    e_expr(p, sb, subject);
    sb_put_cstr(sb, ";\n");
    var ai: u32 = 0;
    while ai < count {
        let tag_tok: u32 = e_extra(p, run + 1 + ai * 3);
        let bind_tok: u32 = e_extra(p, run + 1 + ai * 3 + 1);
        let blk: u32 = e_extra(p, run + 1 + ai * 3 + 2);
        let tagtext: []const u8 = e_tok_text(p, tag_tok);
        let is_ok: bool = mem_eql(tagtext, "ok");
        let bind: []const u8 = e_tok_text(p, bind_tok);
        if ai == 0 {
            e_indent(sb, depth + 1);
        } else {
            sb_put_cstr(sb, " else ");
        }
        if is_ok {
            sb_put_cstr(sb, "if (__mc_sw_");
        } else {
            sb_put_cstr(sb, "if (!__mc_sw_");
        }
        sb_put_u32(sb, n);
        sb_put_cstr(sb, ".is_ok) {\n");
        e_indent(sb, depth + 2);
        sb_put_cstr(sb, "__typeof__(__mc_sw_");
        sb_put_u32(sb, n);
        if is_ok {
            sb_put_cstr(sb, ".payload.ok) ");
        } else {
            sb_put_cstr(sb, ".payload.err) ");
        }
        sb_put_str(sb, bind);
        sb_put_cstr(sb, " = __mc_sw_");
        sb_put_u32(sb, n);
        if is_ok {
            sb_put_cstr(sb, ".payload.ok;\n");
        } else {
            sb_put_cstr(sb, ".payload.err;\n");
        }
        e_indent(sb, depth + 2);
        sb_put_cstr(sb, "(void)");
        sb_put_str(sb, bind);
        sb_put_cstr(sb, ";\n");
        e_emit_block_body(p, sb, blk, depth + 2);
        e_indent(sb, depth + 1);
        sb_put_cstr(sb, "}");
        ai = ai + 1;
    }
    sb_put_cstr(sb, "\n");
    e_indent(sb, depth);
    sb_put_cstr(sb, "}\n");
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

// True when `base` is a plain-pointer-typed identifier (`*T`/`*mut T`) in the current function — so a
// member access `base.field` must lower to `base->field` in C (MC auto-derefs a `.` through a pointer,
// e.g. an `impl` method's `self: *mut TYPE`). A trait-object (`type_dyn`) is a by-value fat pointer,
// NOT a plain pointer, so it stays `.` (its `.data`/`.vtbl` are direct fields). (P5.10)
fn e_base_is_ptr(p: *mut Parser, base: u32) -> bool {
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
    return tnode.kind == .type_ptr;
}

// True when `base` is a trait-object-typed identifier (`*mut dyn TRAIT`) in the current function — so
// a method call `base.m(..)` lowers to a vtable dispatch `(base).vtbl->m((base).data, ..)`. (P5.10)
fn e_base_is_dyn(p: *mut Parser, base: u32) -> bool {
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
    return tnode.kind == .type_dyn;
}

// Emit a dynamic-dispatch call `recv.m(args)` (P5.10) as `(recv).vtbl->m((recv).data, args)`: the
// method is looked up through the receiver's rodata vtable and `self` is threaded as the erased
// `void*` data pointer. `n` is the `.call` node; its callee is a `.field` (`recv.m`).
fn e_dyn_dispatch(p: *mut Parser, sb: *mut StrBuf, n: u32) -> void {
    let nd: Node = e_node(p, n);
    let cnode: Node = e_node(p, nd.lhs);
    let recv: u32 = cnode.lhs;
    let mname: []const u8 = e_tok_text(p, cnode.main_token);
    sb_put_cstr(sb, "(");
    e_expr(p, sb, recv);
    sb_put_cstr(sb, ").vtbl->");
    sb_put_str(sb, mname);
    sb_put_cstr(sb, "((");
    e_expr(p, sb, recv);
    sb_put_cstr(sb, ").data");
    let arg_run: u32 = nd.rhs;
    let argc: u32 = e_extra(p, arg_run);
    var k: u32 = 0;
    while k < argc {
        sb_put_cstr(sb, ", ");
        let arg: u32 = e_extra(p, arg_run + 1 + k);
        e_expr(p, sb, arg);
        k = k + 1;
    }
    sb_put_cstr(sb, ")");
}

// Find the module-level `fn_decl` named `name`, returning its node index (or 0 if none). Used at a
// call site to recover the callee's declared param types so a `*mut TYPE` argument passed where a
// `*mut dyn TRAIT` is expected can be coerced to a fat pointer. (P5.10)
fn e_find_fn(p: *mut Parser, name: []const u8) -> u32 {
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
            let m: bool = mem_eql(name, nm);
            if m {
                return d;
            }
        }
        i = i + 1;
    }
    return 0;
}

// The declared type node of param `k` of fn `fn_node`, or 0 if out of range. (P5.10)
fn e_fn_param_type_node(p: *mut Parser, fn_node: u32, k: u32) -> u32 {
    let nd: Node = e_node(p, fn_node);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let pc: u32 = e_extra(p, params_run);
    if k >= pc {
        return 0;
    }
    let pn: u32 = e_extra(p, params_run + 1 + k);
    let pnode: Node = e_node(p, pn);
    return pnode.lhs;
}

// The `type_name` node whose lexeme names the CONCRETE type of a coercion argument (P5.10): for `&x`
// or a bare pointer `x`, resolve `x`'s declared type — a value/`*mut TYPE` yields the `TYPE` name node.
// Returns 0 when the concrete type can't be recovered (e.g. the arg is already a trait object).
fn e_dyn_concrete_type_node(p: *mut Parser, arg: u32) -> u32 {
    let an: Node = e_node(p, arg);
    var target: u32 = arg;
    if an.kind == .un_addr {
        target = an.lhs;
    }
    let tn: Node = e_node(p, target);
    if tn.kind != .ident_expr {
        return 0;
    }
    let nm: []const u8 = e_tok_text(p, tn.main_token);
    let tnode_idx: u32 = e_local_type_node(p, nm);
    if tnode_idx == 0 {
        return 0;
    }
    let tnode: Node = e_node(p, tnode_idx);
    if tnode.kind == .type_name {
        return tnode_idx;
    }
    if tnode.kind == .type_ptr {
        let pointee_idx: u32 = tnode.lhs;
        let pointee: Node = e_node(p, pointee_idx);
        if pointee.kind == .type_name {
            return pointee_idx;
        }
    }
    return 0;
}

// Emit a trait-object coercion at a call arg (P5.10): a `*mut TYPE` value passed where a
// `*mut dyn TRAIT` is expected becomes the fat pointer
//   `(TRAIT__dyn){ .data = (void*)(<arg>), .vtbl = &TYPE__TRAIT__vtable }`.
// `dyn_type_node` is the parameter's `type_dyn` node (naming the trait). When the concrete type can't
// be recovered (the arg is already a trait object), the arg is passed through unchanged.
fn e_dyn_coerce(p: *mut Parser, sb: *mut StrBuf, arg: u32, dyn_type_node: u32) -> void {
    let dn: Node = e_node(p, dyn_type_node);
    let trait: []const u8 = e_tok_text(p, dn.main_token);
    let concrete_node: u32 = e_dyn_concrete_type_node(p, arg);
    if concrete_node == 0 {
        e_expr(p, sb, arg); // already a trait object (or unresolved): pass through
        return;
    }
    let cn: Node = e_node(p, concrete_node);
    let concrete: []const u8 = e_tok_text(p, cn.main_token);
    sb_put_cstr(sb, "(");
    sb_put_str(sb, trait);
    sb_put_cstr(sb, "__dyn){ .data = (void*)(");
    e_expr(p, sb, arg);
    sb_put_cstr(sb, "), .vtbl = &");
    sb_put_str(sb, concrete);
    sb_put_cstr(sb, "__");
    sb_put_str(sb, trait);
    sb_put_cstr(sb, "__vtable }");
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
    let fname: []const u8 = e_tok_text(p, cnode.main_token);
    let is_asb: bool = mem_eql(fname, "as_bytes");
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
    let is_ptr: bool = mem_eql(member, "ptr");
    if is_ptr {
        sb_put_cstr(sb, "(");
        e_type(p, sb, ty);
        sb_put_cstr(sb, "*)(");
        e_expr(p, sb, arg0);
        sb_put_cstr(sb, ")");
        return;
    }
    let is_load: bool = mem_eql(member, "load");
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
    if k == .bin_bor  { sb_put_cstr(sb, " | "); return; }
    if k == .bin_bxor { sb_put_cstr(sb, " ^ "); return; }
    if k == .bin_band { sb_put_cstr(sb, " & "); return; }
    if k == .bin_shl  { sb_put_cstr(sb, " << "); return; }
    if k == .bin_shr  { sb_put_cstr(sb, " >> "); return; }
    // Not a binary operator; emit nothing.
}

// True for the binary NodeKind tags. Two ranges: the original tower (bin_lor..bin_mod, 22..34) and
// the appended bitwise/shift ops (bin_bor..bin_shr, 60..64) — kept as a second range so the earlier
// ordinals stay stable (the gate reads them via `.raw()`).
fn e_is_binop(k: NodeKind) -> bool {
    let o: u32 = k.raw();
    if o >= 22 && o <= 34 {
        return true;
    }
    return o >= 60 && o <= 64;
}

// The decoded byte length of a string literal from its LEXEME (surrounding quotes included). Each
// escape sequence (`\n \t \r \0 \\ \' \"`) is two source chars but ONE decoded byte; every other
// char is one byte. Matches the `.len` a `[]const u8` slice literal must carry (no trailing NUL).
fn e_str_byte_len(lex: []const u8) -> usize {
    var n: usize = 0;
    var i: usize = 1;            // skip the opening quote
    let last: usize = lex.len - 1; // index of the closing quote
    while i < last {
        let c: u8 = lex[i];
        if c == 92 { // backslash: a two-char escape -> one byte
            i = i + 2;
        } else {
            i = i + 1;
        }
        n = n + 1;
    }
    return n;
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
    // A char literal's lexeme (quotes included) is emitted verbatim — it is already a valid C char
    // literal (MC's `\n \t \r \0 \\ \' \"` escapes are all valid C escapes too).
    if nd.kind == .char_literal {
        let ctxt: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, ctxt);
        return;
    }
    // A string literal `"..."` is a `[]const u8` — emit the fat-pointer slice value over the static C
    // string literal (which is program-lifetime, so the borrow is always valid). The pointer is the
    // lexeme itself (a valid C string literal); the length is the decoded byte count.
    if nd.kind == .string_literal {
        let stxt: []const u8 = e_tok_text(p, nd.main_token);
        let blen: usize = e_str_byte_len(stxt);
        sb_put_cstr(sb, "((mc_slice_const_u8){ .ptr = (const uint8_t*)");
        sb_put_str(sb, stxt);
        sb_put_cstr(sb, ", .len = ");
        sb_put_u32(sb, blen as u32);
        sb_put_cstr(sb, " })");
        return;
    }
    if nd.kind == .bool_literal {
        // The lexeme is literally "true"/"false" (from the kw_true/kw_false token), which is valid C
        // once <stdbool.h> is included (it is, in the prelude).
        let btxt: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, btxt);
        return;
    }
    if nd.kind == .ident_expr {
        let txt2: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, txt2);
        return;
    }
    if e_is_binop(nd.kind) {
        // `opt == null` / `opt != null` (G11): a value optional cannot be compared to a bare literal in
        // C, so lower to a `.present` test — `== null` -> `(!(opt).present)`, `!= null` -> `((opt).present)`.
        let is_eq: bool = nd.kind == .bin_eq;
        let is_ne: bool = nd.kind == .bin_ne;
        if is_eq || is_ne {
            // Bind each operand Node to a local before the `.kind ==` test: a `<call>.kind == <lit>`
            // sequenced comparison cannot recover its operand type in the C backend (gap G23).
            let lnode: Node = e_node(p, nd.lhs);
            let rnode: Node = e_node(p, nd.rhs);
            let lnull: bool = lnode.kind == .null_literal;
            let rnull: bool = rnode.kind == .null_literal;
            if lnull || rnull {
                var other: u32 = nd.lhs;
                if lnull {
                    other = nd.rhs;
                }
                if is_eq {
                    sb_put_cstr(sb, "(!(");
                } else {
                    sb_put_cstr(sb, "((");
                }
                e_expr(p, sb, other);
                sb_put_cstr(sb, ").present)");
                return;
            }
        }
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
        // `ok(x)` / `err(x)` Result constructors: emit the tagged compound literal against the target
        // Result type. The target is the enclosing fn's return type (the dominant/only site is
        // `return ok(..)` / `return err(..)`, where the return type IS the target Result).
        if cnode.kind == .ident_expr {
            let cname0: []const u8 = e_tok_text(p, cnode.main_token);
            let is_ok0: bool = mem_eql(cname0, "ok");
            let is_err0: bool = mem_eql(cname0, "err");
            let cargc0: u32 = e_extra(p, nd.rhs);
            if (is_ok0 || is_err0) && cargc0 == 1 {
                let rtn0: u32 = e_ret_type_node(p);
                if rtn0 != 0 {
                    let rtnn0: Node = e_node(p, rtn0);
                    if rtnn0.kind == .type_result {
                        e_result_ctor(p, sb, n, rtn0, is_ok0);
                        return;
                    }
                }
            }
        }
        if cnode.kind == .field {
            let fname: []const u8 = e_tok_text(p, cnode.main_token);
            let argc0: u32 = e_extra(p, nd.rhs);
            let is_raw: bool = mem_eql(fname, "raw");
            if is_raw && argc0 == 0 {
                e_expr(p, sb, cnode.lhs); // emit just the receiver
                return;
            }
        }
        // P5.10: a dynamic-dispatch call `d.m(args)` on a trait-object receiver (`*mut dyn TRAIT`)
        // lowers to `(d).vtbl->m((d).data, args)`.
        if cnode.kind == .field {
            let recv_dyn: bool = e_base_is_dyn(p, cnode.lhs);
            if recv_dyn {
                e_dyn_dispatch(p, sb, n);
                return;
            }
        }
        // `phys(x)` builtin (address-class model): mint a PAddr from an integer word. Since the
        // address class is a word-backed `uintptr_t` in the subset, this is a plain cast (effectively
        // identity) `((uintptr_t)(x))`.
        if cnode.kind == .ident_expr {
            let pcname: []const u8 = e_tok_text(p, cnode.main_token);
            let is_phys: bool = mem_eql(pcname, "phys");
            let prun: u32 = nd.rhs;
            let pargc: u32 = e_extra(p, prun);
            if is_phys && pargc == 1 {
                sb_put_cstr(sb, "((uintptr_t)(");
                let parg: u32 = e_extra(p, prun + 1);
                e_expr(p, sb, parg);
                sb_put_cstr(sb, "))");
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
                // Use the SUBSTITUTED lexeme: inside a monomorphic body the type arg may itself be the
                // enclosing fn's type param `T` (e.g. `vec_reserve(T, ..)` inside `vec_push<usize>`),
                // which must mangle to the concrete `vec_reserve_usize`, not `vec_reserve_T`.
                let a0lex: []const u8 = e_type_arg_lexeme(p, a0);
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
        // P5.10: recover the callee's declared params so a `*mut TYPE` arg passed where a
        // `*mut dyn TRAIT` is expected is coerced to a `{data,vtable}` fat pointer at this site.
        var callee_fn: u32 = 0;
        if cnode.kind == .ident_expr {
            let cnm: []const u8 = e_tok_text(p, cnode.main_token);
            callee_fn = e_find_fn(p, cnm);
        }
        var k: u32 = 0;
        while k < argc {
            if k > 0 {
                sb_put_cstr(sb, ", ");
            }
            let arg: u32 = e_extra(p, arg_run + 1 + k);
            var ptn: u32 = 0;
            if callee_fn != 0 {
                ptn = e_fn_param_type_node(p, callee_fn, k);
            }
            var is_dyn_param: bool = false;
            if ptn != 0 {
                let ptnode: Node = e_node(p, ptn);
                is_dyn_param = ptnode.kind == .type_dyn;
            }
            if is_dyn_param {
                e_dyn_coerce(p, sb, arg, ptn);
            } else {
                e_expr(p, sb, arg);
            }
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
    // `expr?` (Result propagation): a statement-expression that evaluates EXPR ONCE (via `__typeof__`,
    // which does not evaluate its operand), early-returns the enclosing fn's `err(..)` on the error arm,
    // and yields the ok payload otherwise. RET is the enclosing fn's Result type (recovered from cur_fn).
    if nd.kind == .try_op {
        let rtn: u32 = e_ret_type_node(p);
        sb_put_cstr(sb, "({ __typeof__(");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, ") __mc_try_");
        sb_put_u32(sb, n);
        sb_put_cstr(sb, " = ");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, "; if (!__mc_try_");
        sb_put_u32(sb, n);
        sb_put_cstr(sb, ".is_ok) { return (");
        e_result_type_name(p, sb, rtn);
        sb_put_cstr(sb, "){ .is_ok = false, .payload.err = __mc_try_");
        sb_put_u32(sb, n);
        sb_put_cstr(sb, ".payload.err }; } __mc_try_");
        sb_put_u32(sb, n);
        sb_put_cstr(sb, ".payload.ok; })");
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
        // A pointer-typed base auto-derefs: `p.field` -> `p->field` (P5.10, e.g. `self->total` in an
        // impl method whose `self` is `*mut TYPE`). A value/dyn base keeps `.`.
        let base_ptr: bool = e_base_is_ptr(p, nd.lhs);
        e_expr(p, sb, nd.lhs);
        if base_ptr {
            sb_put_cstr(sb, "->");
        } else {
            sb_put_cstr(sb, ".");
        }
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
    if nd.kind == .cast {
        // `expr as TYPE` (P5.9) -> `((<ctype>)(operand))` — matching the real C backend. The target
        // goes through `e_type` so a monomorphized generic type param is substituted (P5.5); the
        // operand is parenthesized so a compound operand casts cleanly.
        sb_put_cstr(sb, "((");
        e_type(p, sb, nd.rhs);
        sb_put_cstr(sb, ")(");
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, "))");
        return;
    }
    if nd.kind == .sizeof_op {
        // `sizeof(TYPE)` (P5.9) -> `sizeof(<ctype>)`. `e_type` substitutes an active generic type
        // param, so `sizeof(T)` in a `Vec<u32>` instance emits `sizeof(uint32_t)`.
        sb_put_cstr(sb, "sizeof(");
        e_type(p, sb, nd.lhs);
        sb_put_cstr(sb, ")");
        return;
    }
    if nd.kind == .alignof_op {
        // `alignof(TYPE)` (P5.9) -> `_Alignof(<ctype>)` (C11 keyword; same substitution as sizeof).
        sb_put_cstr(sb, "_Alignof(");
        e_type(p, sb, nd.lhs);
        sb_put_cstr(sb, ")");
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
        let init_nd: Node = e_node(p, nd.rhs);
        // `var x: T = uninit;` -> a bare C declaration `T x;` (no initializer), matching the real
        // backend's uninitialized-local lowering.
        if init_nd.kind == .uninit_literal {
            sb_put_cstr(sb, ";\n");
            return;
        }
        sb_put_cstr(sb, " = ");
        // `let x: ?T = <init>;` (G11): coerce the init into the tagged optional (`null` -> absent, an
        // optional-typed source -> pass-through, any other value -> present). The declared type node
        // is `nd.lhs`; `e_emit_decl` already emitted `mc_opt_<T> x`.
        var ann_is_opt: bool = false;
        if nd.lhs != 0 {
            let annode: Node = e_node(p, nd.lhs);
            ann_is_opt = annode.kind == .type_optional;
        }
        if ann_is_opt {
            e_emit_opt_value(p, sb, nd.rhs, nd.lhs);
        } else if init_nd.kind == .struct_lit {
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
            // `return .{ ... };` returns a struct value directly: emit a target-typed compound literal
            // `(RET){...}` (a bare `{...}` is not a valid C expression). The target type is the current
            // function's declared return type (recovered from `p.cur_fn`'s [.,.,ret_ty,.] record).
            let rv_nd: Node = e_node(p, nd.lhs);
            // `return <v>;` from a `-> ?T` fn (G11): coerce into the tagged optional (`null` -> absent,
            // an optional-typed source -> pass-through, any other value -> present).
            let ret_tn: u32 = e_ret_type_node(p);
            var ret_is_opt: bool = false;
            if ret_tn != 0 {
                let retnode: Node = e_node(p, ret_tn);
                ret_is_opt = retnode.kind == .type_optional;
            }
            if ret_is_opt {
                e_emit_opt_value(p, sb, nd.lhs, ret_tn);
            } else if rv_nd.kind == .struct_lit {
                let fn_nd: Node = e_node(p, p.cur_fn);
                let ret_ty: u32 = e_extra(p, fn_nd.lhs + 2);
                e_struct_lit(p, sb, nd.lhs, ret_ty);
            } else {
                e_expr(p, sb, nd.lhs);
            }
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
    if nd.kind == .unreachable_stmt {
        // `unreachable;` -> the real backend's trap (src/lower_c_emitter.zig:3263). `mc_trap_Unreachable`
        // is a NORETURN `__builtin_trap` defined in the emitted prelude, so a fn ending here needs no
        // trailing return (the C compiler sees the path as dead).
        e_indent(sb, depth);
        sb_put_cstr(sb, "mc_trap_Unreachable();\n");
        return;
    }
    if nd.kind == .if_let_stmt {
        // `if let NAME = EXPR { .. } (else ..)?` (G11): narrow the optional into a temp + payload binding.
        e_if_let(p, sb, n, depth);
        return;
    }
    if nd.kind == .if_let_result_stmt {
        // `if let ok(v)=EXPR {..}` / `if let err(e)=EXPR {..}` (Result): tag-test + payload binding.
        e_if_let_result(p, sb, n, depth);
        return;
    }
    if nd.kind == .result_switch_stmt {
        // `switch r { ok(v) => {..}, err(e) => {..} }` (Result): tag-guarded blocks with payload binding.
        e_result_switch(p, sb, n, depth);
        return;
    }
    if nd.kind == .break_stmt {
        e_indent(sb, depth);
        sb_put_cstr(sb, "break;\n");
        return;
    }
    if nd.kind == .continue_stmt {
        e_indent(sb, depth);
        sb_put_cstr(sb, "continue;\n");
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

// ----- P5.10 traits + `*dyn` dynamic dispatch -----

// Emit a trait's two C typedefs (P5.10): the fn-pointer vtable and the {data,vtable} fat pointer —
// matching MC's real Tier-2 `*dyn` C representation (src/lower_c: a rodata vtable + a fat pointer,
// no heap). Each trait method `m(self: *mut Self, p: T) -> R` becomes a slot
// `R (*m)(void* self, T p)` (the `self` receiver is erased to `void*`; the first param is skipped).
//   typedef struct TRAIT__vtable { R (*m)(void* self, ..); .. } TRAIT__vtable;
//   typedef struct TRAIT__dyn { void* data; const TRAIT__vtable* vtbl; } TRAIT__dyn;
fn e_trait_typedef(p: *mut Parser, sb: *mut StrBuf, trait_node: u32) -> void {
    let nd: Node = e_node(p, trait_node);
    let tname: []const u8 = e_tok_text(p, nd.main_token);
    let mrun: u32 = nd.lhs;
    let mcount: u32 = e_extra(p, mrun);
    sb_put_cstr(sb, "typedef struct ");
    sb_put_str(sb, tname);
    sb_put_cstr(sb, "__vtable {\n");
    var mi: u32 = 0;
    while mi < mcount {
        let m: u32 = e_extra(p, mrun + 1 + mi);
        let mn: Node = e_node(p, m); // trait_method
        let mmname: []const u8 = e_tok_text(p, mn.main_token);
        let params_run: u32 = mn.lhs;
        let ret_ty: u32 = mn.rhs;
        sb_put_cstr(sb, "    ");
        e_type(p, sb, ret_ty);
        sb_put_cstr(sb, " (*");
        sb_put_str(sb, mmname);
        sb_put_cstr(sb, ")(void* self");
        let pc: u32 = e_extra(p, params_run);
        var k: u32 = 1; // skip the `self` receiver at index 0
        while k < pc {
            sb_put_cstr(sb, ", ");
            let pn: u32 = e_extra(p, params_run + 1 + k);
            let pnode: Node = e_node(p, pn);
            let pname: []const u8 = e_tok_text(p, pnode.main_token);
            e_emit_decl(p, sb, pnode.lhs, pname);
            k = k + 1;
        }
        sb_put_cstr(sb, ");\n");
        mi = mi + 1;
    }
    sb_put_cstr(sb, "} ");
    sb_put_str(sb, tname);
    sb_put_cstr(sb, "__vtable;\n");
    sb_put_cstr(sb, "typedef struct ");
    sb_put_str(sb, tname);
    sb_put_cstr(sb, "__dyn {\n    void* data;\n    const ");
    sb_put_str(sb, tname);
    sb_put_cstr(sb, "__vtable* vtbl;\n} ");
    sb_put_str(sb, tname);
    sb_put_cstr(sb, "__dyn;\n\n");
}

// Emit every trait's typedefs (vtable + fat pointer). Called before the prototype pass, since a fn
// signature may take a `TRAIT__dyn` by value (e.g. `drive(c: *mut dyn Counter, ..)`).
fn e_trait_typedefs(p: *mut Parser, sb: *mut StrBuf) -> void {
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .trait_decl {
            e_trait_typedef(p, sb, d);
        }
        i = i + 1;
    }
}

// Find the module-level `trait_decl` named `name`, or 0. Used to emit a vtable's slots in TRAIT order.
fn e_find_trait(p: *mut Parser, name: []const u8) -> u32 {
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .trait_decl {
            let nm: []const u8 = e_tok_text(p, dn.main_token);
            let m: bool = mem_eql(name, nm);
            if m {
                return d;
            }
        }
        i = i + 1;
    }
    return 0;
}

// True when a type node is `void` (a 0 node, or a `type_name` whose lexeme is "void"). Lets an
// impl thunk drop the `return` for a void-returning method (a `return void_call();` is illegal C).
fn e_type_is_void(p: *mut Parser, ty_node: u32) -> bool {
    if ty_node == 0 {
        return true;
    }
    let nd: Node = e_node(p, ty_node);
    if nd.kind != .type_name {
        return false;
    }
    let txt: []const u8 = e_tok_text(p, nd.main_token);
    return mem_eql(txt, "void");
}

// Emit an impl method's free-fn signature `RET TYPE__mname(PARAMS)` (P5.10) — the method desugared to
// an inherent-style free function. `method_node` is a `fn_decl`; its `self` param stays a concrete
// `*mut TYPE` (so `self->field` accesses lower directly). `type_name` is the impl target type.
fn e_impl_method_sig(p: *mut Parser, sb: *mut StrBuf, type_name: []const u8, method_node: u32) -> void {
    let nd: Node = e_node(p, method_node);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let ret_ty: u32 = e_extra(p, frec + 2);
    e_type(p, sb, ret_ty);
    sb_put_cstr(sb, " ");
    sb_put_str(sb, type_name);
    sb_put_cstr(sb, "__");
    let mname: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_str(sb, mname);
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
    sb_put_cstr(sb, ")");
}

// Emit an impl method's free-fn DEFINITION `RET TYPE__mname(PARAMS) { body }` (P5.10). `cur_fn` is set
// so pointer-`self` field accesses lower to `self->field` and slice-aware accesses resolve.
fn e_impl_method_def(p: *mut Parser, sb: *mut StrBuf, type_name: []const u8, method_node: u32) -> void {
    let nd: Node = e_node(p, method_node);
    let frec: u32 = nd.lhs;
    let body: u32 = e_extra(p, frec + 3);
    e_impl_method_sig(p, sb, type_name, method_node);
    sb_put_cstr(sb, " ");
    p.cur_fn = method_node;
    e_block(p, sb, body, 0);
    p.cur_fn = 0;
    sb_put_cstr(sb, "\n\n");
}

// Emit an impl method's `void*`-self THUNK (P5.10): the vtable slot points here, casting the erased
// receiver back to the concrete type — so the vtable is a plain fn-pointer table with no
// `-Wincompatible-pointer-types` casts at the call site (matching the real backend's thunk approach):
//   static RET TYPE__mname__dyn(void* self, <rest>) { return TYPE__mname((TYPE*)self, <rest>); }
fn e_impl_thunk(p: *mut Parser, sb: *mut StrBuf, type_name: []const u8, method_node: u32) -> void {
    let nd: Node = e_node(p, method_node);
    let frec: u32 = nd.lhs;
    let params_run: u32 = e_extra(p, frec + 1);
    let ret_ty: u32 = e_extra(p, frec + 2);
    let mname: []const u8 = e_tok_text(p, nd.main_token);
    let is_void: bool = e_type_is_void(p, ret_ty);
    sb_put_cstr(sb, "static ");
    e_type(p, sb, ret_ty);
    sb_put_cstr(sb, " ");
    sb_put_str(sb, type_name);
    sb_put_cstr(sb, "__");
    sb_put_str(sb, mname);
    sb_put_cstr(sb, "__dyn(void* self");
    let pc: u32 = e_extra(p, params_run);
    var k: u32 = 1; // skip the `self` receiver
    while k < pc {
        sb_put_cstr(sb, ", ");
        let pn: u32 = e_extra(p, params_run + 1 + k);
        let pnode: Node = e_node(p, pn);
        let pname: []const u8 = e_tok_text(p, pnode.main_token);
        e_emit_decl(p, sb, pnode.lhs, pname);
        k = k + 1;
    }
    sb_put_cstr(sb, ") {\n    ");
    if !is_void {
        sb_put_cstr(sb, "return ");
    }
    sb_put_str(sb, type_name);
    sb_put_cstr(sb, "__");
    sb_put_str(sb, mname);
    sb_put_cstr(sb, "((");
    sb_put_str(sb, type_name);
    sb_put_cstr(sb, "*)self");
    var k2: u32 = 1;
    while k2 < pc {
        sb_put_cstr(sb, ", ");
        let pn2: u32 = e_extra(p, params_run + 1 + k2);
        let pnode2: Node = e_node(p, pn2);
        let pname2: []const u8 = e_tok_text(p, pnode2.main_token);
        sb_put_str(sb, pname2);
        k2 = k2 + 1;
    }
    sb_put_cstr(sb, ");\n}\n\n");
}

// Emit the rodata vtable instance for an `impl TRAIT for TYPE` (P5.10):
//   static const TRAIT__vtable TYPE__TRAIT__vtable = { &TYPE__m__dyn, .. };
// Slots are laid out in TRAIT declaration order (found via `e_find_trait`); each slot is the thunk
// for the same-named method. `const` places it in rodata (no heap), as the real backend does.
fn e_impl_vtable(p: *mut Parser, sb: *mut StrBuf, trait_name: []const u8, type_name: []const u8) -> void {
    sb_put_cstr(sb, "static const ");
    sb_put_str(sb, trait_name);
    sb_put_cstr(sb, "__vtable ");
    sb_put_str(sb, type_name);
    sb_put_cstr(sb, "__");
    sb_put_str(sb, trait_name);
    sb_put_cstr(sb, "__vtable = { ");
    let trait_node: u32 = e_find_trait(p, trait_name);
    if trait_node != 0 {
        let tn: Node = e_node(p, trait_node);
        let mrun: u32 = tn.lhs;
        let mc: u32 = e_extra(p, mrun);
        var mi: u32 = 0;
        while mi < mc {
            if mi > 0 {
                sb_put_cstr(sb, ", ");
            }
            let m: u32 = e_extra(p, mrun + 1 + mi);
            let mn: Node = e_node(p, m);
            let mname: []const u8 = e_tok_text(p, mn.main_token);
            sb_put_cstr(sb, "&");
            sb_put_str(sb, type_name);
            sb_put_cstr(sb, "__");
            sb_put_str(sb, mname);
            sb_put_cstr(sb, "__dyn");
            mi = mi + 1;
        }
    }
    sb_put_cstr(sb, " };\n\n");
}

// Emit a whole `impl TRAIT for TYPE` block (P5.10): each method's free-fn definition, then each
// method's `void*`-self thunk, then the rodata vtable. The rec is [type_name_tok, methods_run].
fn e_impl_decl(p: *mut Parser, sb: *mut StrBuf, impl_node: u32) -> void {
    let nd: Node = e_node(p, impl_node);
    let trait_name: []const u8 = e_tok_text(p, nd.main_token);
    let rec: u32 = nd.lhs;
    let type_tok: u32 = e_extra(p, rec);
    let methods_run: u32 = e_extra(p, rec + 1);
    let type_name: []const u8 = e_tok_text(p, type_tok);
    let mcount: u32 = e_extra(p, methods_run);
    var mi: u32 = 0;
    while mi < mcount {
        let mdef: u32 = e_extra(p, methods_run + 1 + mi);
        e_impl_method_def(p, sb, type_name, mdef);
        mi = mi + 1;
    }
    var ti: u32 = 0;
    while ti < mcount {
        let mthk: u32 = e_extra(p, methods_run + 1 + ti);
        e_impl_thunk(p, sb, type_name, mthk);
        ti = ti + 1;
    }
    e_impl_vtable(p, sb, trait_name, type_name);
}

// Emit every `impl` block. Placed after all prototypes (so a method body can call any fn) and before
// the normal fn definitions (so a rodata vtable precedes any coercion site that takes its address).
fn e_impl_decls(p: *mut Parser, sb: *mut StrBuf) -> void {
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .impl_decl {
            e_impl_decl(p, sb, d);
        }
        i = i + 1;
    }
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
    if mem_eql(txt, "u8") { return true; }
    if mem_eql(txt, "u16") { return true; }
    if mem_eql(txt, "u32") { return true; }
    if mem_eql(txt, "u64") { return true; }
    if mem_eql(txt, "usize") { return true; }
    if mem_eql(txt, "i8") { return true; }
    if mem_eql(txt, "i16") { return true; }
    if mem_eql(txt, "i32") { return true; }
    if mem_eql(txt, "i64") { return true; }
    if mem_eql(txt, "isize") { return true; }
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

// True when SOME call in the module invokes generic fn `callee_name` FORWARDING the type-param lexeme
// `tparam_lex` as its type argument (e.g. `vec_reserve(T, ..)`). Used to propagate a caller generic
// fn's concrete instantiations to the generic fns it forwards its own type param to (transitive
// monomorphization). (The subset's type params are conventionally named `T`; the check is by lexeme.)
fn e_generic_forwards_to(p: *mut Parser, callee_name: []const u8, tparam_lex: []const u8) -> bool {
    let total: u32 = vec_len(Node, &p.nodes) as u32;
    var i: u32 = 1;
    while i < total {
        let nd: Node = e_node(p, i);
        if nd.kind == .call {
            let cnode: Node = e_node(p, nd.lhs);
            if cnode.kind == .ident_expr {
                let cn: []const u8 = e_tok_text(p, cnode.main_token);
                let mc: bool = mem_eql(cn, callee_name);
                if mc {
                    let arg_run: u32 = nd.rhs;
                    let argc: u32 = e_extra(p, arg_run);
                    if argc >= 1 {
                        let a0: u32 = e_extra(p, arg_run + 1);
                        let a0n: Node = e_node(p, a0);
                        if a0n.kind == .ident_expr {
                            let a0lex: []const u8 = e_tok_text(p, a0n.main_token);
                            let ma: bool = mem_eql(a0lex, tparam_lex);
                            if ma {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        i = i + 1;
    }
    return false;
}

// Merge every concrete node in `src` into `out`, deduped by lexeme (linear scan; the subset has no set).
fn e_merge_insts(p: *mut Parser, out: *mut Vec<u32>, src: *Vec<u32>) -> void {
    let n: usize = vec_len(u32, src);
    var i: usize = 0;
    while i < n {
        let c: u32 = vec_get(u32, src, i);
        let present: bool = e_arg_present(p, &*out, c);
        if !present {
            vec_push(u32, out, c);
        }
        i = i + 1;
    }
}

// Collect the DISTINCT concrete instances of generic fn `fname` INCLUDING transitive ones: besides
// the direct concrete call sites (`e_collect_call_insts`), any generic fn `G` that forwards its own
// type param to `fname` contributes ALL of G's instances (recursively). This is what makes a generic
// fn calling another generic fn — `vec_push<usize>` calling `vec_reserve(T, ..)` — instantiate
// `vec_reserve_usize`. `depth` bounds recursion so a forwarding cycle terminates.
fn e_collect_insts_tr(p: *mut Parser, fname: []const u8, out: *mut Vec<u32>, depth: u32) -> void {
    if depth > 8 {
        return;
    }
    // Direct concrete call sites.
    e_collect_call_insts(p, fname, &*out);
    // Transitive: each generic fn template G whose body forwards its type param to `fname`.
    let root: u32 = p.root;
    let rnode: Node = e_node(p, root);
    let run: u32 = rnode.lhs;
    let count: u32 = e_extra(p, run);
    var di: u32 = 0;
    while di < count {
        let d: u32 = e_extra(p, run + 1 + di);
        let dn: Node = e_node(p, d);
        if dn.kind == .fn_decl {
            let frec: u32 = dn.lhs;
            let params_run: u32 = e_extra(p, frec + 1);
            let generic: bool = e_fn_has_comptime(p, params_run);
            if generic {
                let gname: []const u8 = e_tok_text(p, dn.main_token);
                let is_self: bool = mem_eql(gname, fname);
                if !is_self {
                    let tp_tok: u32 = e_gfn_tparam(p, d);
                    let tplex: []const u8 = e_tok_text(p, tp_tok);
                    let fwd: bool = e_generic_forwards_to(p, fname, tplex);
                    if fwd {
                        var tmp: Vec<u32> = vec_new(u32, p.a);
                        e_collect_insts_tr(p, gname, &tmp, depth + 1);
                        e_merge_insts(p, &*out, &tmp);
                        vec_free(u32, &tmp);
                    }
                }
            }
        }
        di = di + 1;
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
// Emit a module-level constant: `static const <ctype> NAME = <value>;`. `e_emit_decl` builds the
// `<ctype> NAME` declarator (so a `[N]T` const would lower to `T NAME[N]` correctly); the initializer
// is emitted with the normal expression emitter (a constant expression: literal or simple arithmetic).
fn e_const_decl(p: *mut Parser, sb: *mut StrBuf, d: u32) -> void {
    let nd: Node = e_node(p, d);
    let name: []const u8 = e_tok_text(p, nd.main_token);
    sb_put_cstr(sb, "static const ");
    e_emit_decl(p, sb, nd.lhs, name);
    sb_put_cstr(sb, " = ");
    e_expr(p, sb, nd.rhs);
    sb_put_cstr(sb, ";\n");
}

fn e_module(p: *mut Parser, sb: *mut StrBuf) -> void {
    sb_put_cstr(sb, "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n\n");
    // The `unreachable;` trap (matches src/lower_c_runtime.zig's `mc_trap_Unreachable`): NORETURN so a
    // fn ending in `unreachable;` needs no trailing return, and __attribute__((unused)) so it does not
    // warn under -Werror when a module has no `unreachable`.
    sb_put_cstr(sb, "__attribute__((noreturn, unused)) static inline void mc_trap_Unreachable(void) { __builtin_trap(); }\n\n");
    // P5.7: fat-pointer slice typedefs first (a struct field or fn signature may reference one).
    e_slice_typedefs(p, sb);
    // G11: value-optional `mc_opt_<T>` typedefs (a struct field, fn signature, or local may use one).
    e_opt_typedefs(p, sb);
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
    // P5.10 trait typedefs: each trait's `TRAIT__vtable` fn-pointer table + `TRAIT__dyn` fat pointer.
    // Emitted BEFORE any struct (a struct field may be a `TRAIT__dyn` fat pointer BY VALUE — e.g.
    // `Vec<T>`'s allocator field — so the trait typedef must precede it). Traits themselves depend on
    // nothing (their vtable uses `void* self`), so they are safe to emit first.
    e_trait_typedefs(p, sb);
    // P5.5 monomorphic structs: for each generic struct template, emit one typedef per distinct
    // concrete type argument used anywhere in the module (deduped). Emitted BEFORE the regular structs
    // because a regular struct may embed a generic instance BY VALUE (e.g. `TokenList { data: Vec<usize> }`),
    // and a generic instance's own fields are scalars / trait objects (already emitted above).
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
    var si: u32 = 0;
    while si < count {
        let sd: u32 = e_extra(p, run + 1 + si);
        let sdn: Node = e_node(p, sd);
        if sdn.kind == .struct_decl {
            e_struct_decl(p, sb, sd);
        }
        si = si + 1;
    }
    // Result: `mc_result_<T>_<E>` tagged-struct typedefs. Emitted AFTER enums/structs (a Result payload
    // may be a named enum/struct — e.g. `Result<Fd, IoError>` — so those typedefs must precede it) and
    // before fn prototypes (a fn signature may return a Result).
    e_result_typedefs(p, sb);
    // Module-level `const NAME: T = value;` -> file-scope `static const T NAME = value;`. Emitted
    // after ALL type typedefs (a const's type may name an enum/struct) and before the fn prototypes
    // (a fn body may reference the const). `static` is correct here: the loader concatenates every
    // module into ONE translation unit, so a file-scope static const is visible to all uses.
    var ci: u32 = 0;
    while ci < count {
        let cd: u32 = e_extra(p, run + 1 + ci);
        let cdn: Node = e_node(p, cd);
        if cdn.kind == .const_decl {
            e_const_decl(p, sb, cd);
        }
        ci = ci + 1;
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
                e_collect_insts_tr(p, fname, &pinsts, 0);
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
    // P5.10 impl blocks: each `impl TRAIT for TYPE` emits its methods' free fns + `void*`-self thunks
    // + the rodata vtable. Placed after all prototypes (a method may call any fn) and before the normal
    // fn definitions (a vtable must be defined before a coercion site takes its address).
    e_impl_decls(p, sb);
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
                e_collect_insts_tr(p, fname2, &dinsts, 0);
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
