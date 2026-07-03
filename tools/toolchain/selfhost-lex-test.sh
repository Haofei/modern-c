#!/usr/bin/env bash
# selfhost-lex-test: build the Phase-1 self-hosted LEXER (selfhost/lexer.mc, mcc2's
# scanner ported from src/lexer.zig + src/token.zig), link it with a C driver, and
# assert the token stream for representative inputs. The driver supplies mc_malloc/
# mc_free (the token store is a malloc-backed Vec) and checks token kinds/counts/spans
# whose expected values are derived from the Zig reference's semantics. Its `TK_*`
# ordinals mirror selfhost/lexer.mc's `TokKind` (which mirrors src/token.zig's `Kind`).
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_lex_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-lex-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/lex.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t lex_count(uint32_t c);
extern uint32_t lex_kind_at(uint32_t c, uint32_t i);
extern uint32_t lex_len_at(uint32_t c, uint32_t i);
extern uint32_t lex_line_at(uint32_t c, uint32_t i);
extern uint32_t lex_col_at(uint32_t c, uint32_t i);

/* TokKind ordinals — same declaration order as src/token.zig's Kind enum. */
enum {
    TK_EOF = 0, TK_INVALID, TK_IDENTIFIER, TK_INTEGER, TK_FLOAT, TK_STRING, TK_CHAR,
    TK_KW_FIRST /* = 7 (kw_alignof) */
};
#define TK_KW_FN        24
#define TK_UNDERSCORE   68
/* multi-char operators */
#define TK_DOUBLE_COLON 63
#define TK_ARROW        82
#define TK_FAT_ARROW    83
#define TK_EQUAL_EQUAL  84
#define TK_BANG_EQUAL   85
#define TK_LESS_EQUAL   86
#define TK_GREATER_EQUAL 87
#define TK_AMP_AMP      88
#define TK_PIPE_PIPE    89
#define TK_SHIFT_LEFT   90
#define TK_SHIFT_RIGHT  91
#define TK_DOT_DOT      92
#define TK_DOT_DOT_DOT  93
/* single-char punctuation/operators */
#define TK_L_PAREN 54
#define TK_R_PAREN 55
#define TK_L_BRACE 56
#define TK_R_BRACE 57
#define TK_L_BRACKET 58
#define TK_R_BRACKET 59
#define TK_COMMA 60
#define TK_DOT 61
#define TK_COLON 62
#define TK_SEMICOLON 64
#define TK_QUESTION 65
#define TK_HASH 66
#define TK_AT 67
#define TK_TILDE 77
#define TK_CARET 76
#define TK_PLUS 69
#define TK_MINUS 70
#define TK_STAR 71
#define TK_SLASH 72
#define TK_PERCENT 73
#define TK_AMP 74
#define TK_PIPE 75
#define TK_EQUAL 79
#define TK_LESS 80

static int fails = 0;
static void eq(const char *what, uint32_t got, uint32_t want) {
    if (got != want) { printf("FAIL: %s: got %u want %u\n", what, got, want); fails++; }
}
/* Assert case `c`'s kind stream equals `want[0..n)` (n includes the trailing EOF). */
static void kinds(uint32_t c, const uint32_t *want, uint32_t n) {
    eq("count", lex_count(c), n);
    for (uint32_t i = 0; i < n; i++) {
        char buf[32];
        snprintf(buf, sizeof buf, "case%u kind[%u]", c, i);
        eq(buf, lex_kind_at(c, i), want[i]);
    }
}

int main(void) {
    /* case 0: "fn foo" — keyword vs identifier */
    { uint32_t w[] = { TK_KW_FN, TK_IDENTIFIER, TK_EOF }; kinds(0, w, 3);
      eq("case0 len[0]", lex_len_at(0, 0), 2);   /* "fn"  */
      eq("case0 len[1]", lex_len_at(0, 1), 3); } /* "foo" */

    /* case 1: all 13 multi-char operators */
    { uint32_t w[] = { TK_DOUBLE_COLON, TK_ARROW, TK_FAT_ARROW, TK_EQUAL_EQUAL,
        TK_BANG_EQUAL, TK_LESS_EQUAL, TK_GREATER_EQUAL, TK_AMP_AMP, TK_PIPE_PIPE,
        TK_SHIFT_LEFT, TK_SHIFT_RIGHT, TK_DOT_DOT, TK_DOT_DOT_DOT, TK_EOF };
      kinds(1, w, 14); }

    /* case 2: "42 0xFF 1_000" — decimal, hex, digit separators */
    { uint32_t w[] = { TK_INTEGER, TK_INTEGER, TK_INTEGER, TK_EOF }; kinds(2, w, 4);
      eq("case2 len[0]", lex_len_at(2, 0), 2);   /* "42"    */
      eq("case2 len[1]", lex_len_at(2, 1), 4);   /* "0xFF"  */
      eq("case2 len[2]", lex_len_at(2, 2), 5); } /* "1_000" */

    /* case 3: "3.14 1e5 2.5E-3 inf nan" — fraction, exponent, inf/nan-as-float */
    { uint32_t w[] = { TK_FLOAT, TK_FLOAT, TK_FLOAT, TK_FLOAT, TK_FLOAT, TK_EOF };
      kinds(3, w, 6); }

    /* case 4: "a\nb\t\"c" string literal with escapes (single token) */
    { uint32_t w[] = { TK_STRING, TK_EOF }; kinds(4, w, 2);
      eq("case4 len[0]", lex_len_at(4, 0), 11); } /* whole quoted lexeme */

    /* case 5: 'x' char literal */
    { uint32_t w[] = { TK_CHAR, TK_EOF }; kinds(5, w, 2);
      eq("case5 len[0]", lex_len_at(5, 0), 3); }

    /* case 6: line and block comments skipped; line/col tracked */
    { uint32_t w[] = { TK_IDENTIFIER, TK_IDENTIFIER, TK_IDENTIFIER, TK_EOF };
      kinds(6, w, 4);
      eq("case6 line[1]", lex_line_at(6, 1), 2);   /* 'b' is on line 2 */
      eq("case6 col[1]",  lex_col_at(6, 1),  2); } /* after the leading space */

    /* case 7: "_ foo" — underscore token vs identifier */
    { uint32_t w[] = { TK_UNDERSCORE, TK_IDENTIFIER, TK_EOF }; kinds(7, w, 3); }

    /* case 8: 24 single-char punctuation/operator tokens */
    { uint32_t w[] = { TK_L_PAREN, TK_R_PAREN, TK_L_BRACE, TK_R_BRACE, TK_L_BRACKET,
        TK_R_BRACKET, TK_COMMA, TK_DOT, TK_COLON, TK_SEMICOLON, TK_QUESTION, TK_HASH,
        TK_AT, TK_TILDE, TK_CARET, TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT,
        TK_AMP, TK_PIPE, TK_EQUAL, TK_LESS, TK_EOF };
      kinds(8, w, 25); }

    if (fails != 0) { printf("FAIL: selfhost-lex-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/lex.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-lex-test — mcc2 lexer (selfhost/lexer.mc) tokenized 9 inputs across keywords/identifiers, all 13 multi-char + 24 single-char operators, int/hex/float literals, string+char escapes, and skipped comments (kinds/counts/spans match src/lexer.zig)"
    exit 0
fi
echo "FAIL: selfhost-lex-test — program returned non-zero"
exit 1
