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
        e_type(p, sb, nd.lhs);
        sb_put_cstr(sb, "*");
        return;
    }
    if nd.kind == .type_slice_mut {
        e_type(p, sb, nd.lhs);
        sb_put_cstr(sb, "*");
        return;
    }
    // type_name
    let txt: []const u8 = e_tok_text(p, nd.main_token);
    e_scalar_name(sb, txt);
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
        e_expr(p, sb, nd.lhs);
        sb_put_cstr(sb, "[");
        e_expr(p, sb, nd.rhs);
        sb_put_cstr(sb, "]");
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
        e_type(p, sb, nd.lhs); // 0 (no annotation) emits "void" via e_type
        // The subset always annotates in practice; a bare `let`/`var` with no type would emit
        // `void`, which is not a valid C variable type. `var` lowers identically to `let` in C.
        sb_put_cstr(sb, " ");
        let name: []const u8 = e_tok_text(p, nd.main_token);
        sb_put_str(sb, name);
        sb_put_cstr(sb, " = ");
        let init_nd: Node = e_node(p, nd.rhs);
        if init_nd.kind == .struct_lit {
            // Emit a target-typed compound literal using the annotation's type.
            e_struct_lit(p, sb, nd.rhs, nd.lhs);
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
            e_type(p, sb, pnode.lhs);
            sb_put_cstr(sb, " ");
            let pname: []const u8 = e_tok_text(p, pnode.main_token);
            sb_put_str(sb, pname);
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
    e_block(p, sb, body, 0);
    sb_put_cstr(sb, "\n\n");
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
        e_type(p, sb, type_node);
        sb_put_cstr(sb, " ");
        let fname: []const u8 = e_tok_text(p, name_tok);
        sb_put_str(sb, fname);
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

// Emit the whole module: the fixed prelude, every enum then struct typedef (so they precede any
// use), then one C function per `fn` decl.
fn e_module(p: *mut Parser, sb: *mut StrBuf) -> void {
    sb_put_cstr(sb, "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n\n");
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
    // Forward prototypes for every function, so a call resolves regardless of the order the loader
    // concatenated the modules in (an importer may textually precede the module it depends on).
    var fi: u32 = 0;
    while fi < count {
        let fd: u32 = e_extra(p, run + 1 + fi);
        let fdn: Node = e_node(p, fd);
        if fdn.kind == .fn_decl {
            e_fn_sig(p, sb, fd);
            sb_put_cstr(sb, ";\n");
        }
        fi = fi + 1;
    }
    sb_put_cstr(sb, "\n");
    var i: u32 = 0;
    while i < count {
        let d: u32 = e_extra(p, run + 1 + i);
        let dn: Node = e_node(p, d);
        if dn.kind == .fn_decl {
            e_fn(p, sb, d);
        }
        i = i + 1;
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
