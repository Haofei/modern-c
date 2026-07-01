#!/usr/bin/env bash
# selfhost-parse-test: build the Phase-2 self-hosted PARSER (selfhost/parser.mc, mcc2's
# recursive-descent parser + flat index-arena AST ported from src/parser.zig + src/ast.zig),
# link it with a C driver, and assert the parsed AST for representative inputs. The driver
# supplies mc_malloc/mc_free (the arena is a malloc-backed Vec) and WALKS the flat node arena
# (kind/lhs/rhs + the length-prefixed `extra` run array) to check node kinds/counts, the
# fn/param/block structure, operator precedence shape (`a + b * c` nests `*` under `+`), and
# that a malformed input yields a non-zero error count. Its `NK_*` ordinals mirror
# selfhost/parser.mc's `NodeKind`.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_parse_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-parse-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/parse.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t parse_node_count(uint32_t c);
extern uint32_t parse_kind_at(uint32_t c, uint32_t i);
extern uint32_t parse_lhs_at(uint32_t c, uint32_t i);
extern uint32_t parse_rhs_at(uint32_t c, uint32_t i);
extern uint32_t parse_extra_at(uint32_t c, uint32_t i);
extern uint32_t parse_err_count(uint32_t c);
extern uint32_t parse_root(uint32_t c);
extern uint32_t parse_main_token_at(uint32_t c, uint32_t i);

/* NodeKind ordinals — same declaration order as selfhost/parser.mc's NodeKind enum. */
enum {
    NK_INVALID = 0, NK_MODULE, NK_FN_DECL, NK_PARAM_DECL, NK_TYPE_NAME, NK_TYPE_PTR,
    NK_TYPE_SLICE_CONST, NK_TYPE_SLICE_MUT, NK_BLOCK, NK_LET_DECL, NK_RETURN_STMT,
    NK_IF_STMT, NK_WHILE_STMT, NK_EXPR_STMT, NK_ASSIGN, NK_INT_LITERAL, NK_IDENT_EXPR,
    NK_CALL, NK_INDEX, NK_FIELD, NK_UN_NEG, NK_UN_NOT, NK_BIN_LOR, NK_BIN_LAND, NK_BIN_EQ,
    NK_BIN_NE, NK_BIN_LT, NK_BIN_GT, NK_BIN_LE, NK_BIN_GE, NK_BIN_ADD, NK_BIN_SUB,
    NK_BIN_MUL, NK_BIN_DIV, NK_BIN_MOD
};

static int fails = 0;
static void eq(const char *what, uint32_t got, uint32_t want) {
    if (got != want) { printf("FAIL: %s: got %u want %u\n", what, got, want); fails++; }
}
static void ne0(const char *what, uint32_t got) {
    if (got == 0) { printf("FAIL: %s: got 0, expected non-zero\n", what); fails++; }
}

int main(void) {
    /* ---- case 0: a full fn, walked structurally from the module root ---- *
     *   export fn f(a: u32, b: u32) -> u32 {
     *       let x = a + b * c;
     *       if x { return x; } else { return b; }
     *       while x { g(a); }
     *       return x;
     *   }
     */
    uint32_t c = 0;
    eq("case0 err", parse_err_count(c), 0);

    /* root is a module node */
    uint32_t root = parse_root(c);
    eq("case0 root kind", parse_kind_at(c, root), NK_MODULE);

    /* module.lhs -> length-prefixed run of decls; exactly one fn decl */
    uint32_t decl_run = parse_lhs_at(c, root);
    eq("case0 decl count", parse_extra_at(c, decl_run), 1);
    uint32_t fn = parse_extra_at(c, decl_run + 1);
    eq("case0 fn kind", parse_kind_at(c, fn), NK_FN_DECL);

    /* fn.lhs -> fixed record [exported, params_run, ret_type, body] */
    uint32_t frec = parse_lhs_at(c, fn);
    eq("case0 exported", parse_extra_at(c, frec + 0), 1);
    uint32_t params_run = parse_extra_at(c, frec + 1);
    uint32_t ret_type   = parse_extra_at(c, frec + 2);
    uint32_t body       = parse_extra_at(c, frec + 3);
    eq("case0 ret type kind", parse_kind_at(c, ret_type), NK_TYPE_NAME);
    eq("case0 body kind", parse_kind_at(c, body), NK_BLOCK);

    /* two params, each a param_decl whose lhs is a type_name */
    eq("case0 param count", parse_extra_at(c, params_run), 2);
    uint32_t p0 = parse_extra_at(c, params_run + 1);
    uint32_t p1 = parse_extra_at(c, params_run + 2);
    eq("case0 p0 kind", parse_kind_at(c, p0), NK_PARAM_DECL);
    eq("case0 p1 kind", parse_kind_at(c, p1), NK_PARAM_DECL);
    eq("case0 p0 type kind", parse_kind_at(c, parse_lhs_at(c, p0)), NK_TYPE_NAME);

    /* body has 4 statements: let, if, while, return */
    uint32_t body_run = parse_lhs_at(c, body);
    eq("case0 stmt count", parse_extra_at(c, body_run), 4);
    uint32_t s_let   = parse_extra_at(c, body_run + 1);
    uint32_t s_if    = parse_extra_at(c, body_run + 2);
    uint32_t s_while = parse_extra_at(c, body_run + 3);
    uint32_t s_ret   = parse_extra_at(c, body_run + 4);
    eq("case0 s0 kind", parse_kind_at(c, s_let), NK_LET_DECL);
    eq("case0 s1 kind", parse_kind_at(c, s_if), NK_IF_STMT);
    eq("case0 s2 kind", parse_kind_at(c, s_while), NK_WHILE_STMT);
    eq("case0 s3 kind", parse_kind_at(c, s_ret), NK_RETURN_STMT);

    /* PRECEDENCE: `a + b * c` -> add at the top with `*` nested under its rhs.
       let has no type annotation (lhs == 0); its init (rhs) is the add. */
    eq("case0 let no type", parse_lhs_at(c, s_let), 0);
    uint32_t add = parse_rhs_at(c, s_let);
    eq("case0 init is add", parse_kind_at(c, add), NK_BIN_ADD);
    eq("case0 add.lhs is ident", parse_kind_at(c, parse_lhs_at(c, add)), NK_IDENT_EXPR);
    uint32_t mul = parse_rhs_at(c, add);
    eq("case0 add.rhs is mul (precedence)", parse_kind_at(c, mul), NK_BIN_MUL);
    eq("case0 mul.lhs is ident", parse_kind_at(c, parse_lhs_at(c, mul)), NK_IDENT_EXPR);
    eq("case0 mul.rhs is ident", parse_kind_at(c, parse_rhs_at(c, mul)), NK_IDENT_EXPR);

    /* if: cond is an ident; rec [then_block, else_block] both blocks, each with one return */
    eq("case0 if cond kind", parse_kind_at(c, parse_lhs_at(c, s_if)), NK_IDENT_EXPR);
    uint32_t if_rec = parse_rhs_at(c, s_if);
    uint32_t then_b = parse_extra_at(c, if_rec + 0);
    uint32_t else_b = parse_extra_at(c, if_rec + 1);
    eq("case0 then kind", parse_kind_at(c, then_b), NK_BLOCK);
    eq("case0 else kind", parse_kind_at(c, else_b), NK_BLOCK);
    ne0("case0 else present", else_b);
    uint32_t then_run = parse_lhs_at(c, then_b);
    eq("case0 then stmt count", parse_extra_at(c, then_run), 1);
    eq("case0 then stmt kind", parse_kind_at(c, parse_extra_at(c, then_run + 1)), NK_RETURN_STMT);

    /* while: cond ident; body block with a single call expr-stmt */
    eq("case0 while cond kind", parse_kind_at(c, parse_lhs_at(c, s_while)), NK_IDENT_EXPR);
    uint32_t wbody = parse_rhs_at(c, s_while);
    eq("case0 while body kind", parse_kind_at(c, wbody), NK_BLOCK);
    uint32_t wrun = parse_lhs_at(c, wbody);
    eq("case0 while stmt count", parse_extra_at(c, wrun), 1);
    uint32_t es = parse_extra_at(c, wrun + 1);
    eq("case0 while stmt kind", parse_kind_at(c, es), NK_EXPR_STMT);
    uint32_t call = parse_lhs_at(c, es);
    eq("case0 call kind", parse_kind_at(c, call), NK_CALL);
    eq("case0 call callee kind", parse_kind_at(c, parse_lhs_at(c, call)), NK_IDENT_EXPR);
    uint32_t arg_run = parse_rhs_at(c, call);
    eq("case0 call argc", parse_extra_at(c, arg_run), 1);
    eq("case0 call arg kind", parse_kind_at(c, parse_extra_at(c, arg_run + 1)), NK_IDENT_EXPR);

    /* node index 0 is the reserved invalid sentinel */
    eq("case0 sentinel kind", parse_kind_at(c, 0), NK_INVALID);

    /* ---- case 1: malformed input must report errors ---- */
    ne0("case1 err count > 0", parse_err_count(1));

    if (fails != 0) { printf("FAIL: selfhost-parse-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/parse.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-parse-test — mcc2 parser (selfhost/parser.mc) built a flat index-arena AST for a full fn (params + let/if-else/while/return + a call), verified fn/param/block structure, operator precedence (a + b * c nests * under +), and reported errors on malformed input (kinds/counts/shape match src/parser.zig)"
    exit 0
fi
echo "FAIL: selfhost-parse-test — program returned non-zero"
exit 1
