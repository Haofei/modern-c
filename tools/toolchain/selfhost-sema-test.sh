#!/usr/bin/env bash
# selfhost-sema-test: build the Phase-3 self-hosted SEMANTIC ANALYZER (selfhost/sema.mc, mcc2's
# name-resolver + type-checker ported from src/sema.zig `checkModule`) over the Phase-2 flat AST,
# link it with a C driver, and assert its diagnostics for representative inputs. The driver
# supplies mc_malloc/mc_free (the arena is a malloc-backed Vec) and runs the FULL pipeline
# (lex -> parse -> sema) per case: it asserts the well-typed accept case reports zero semantic
# errors, and each reject case reports at least one error with the expected first-error code. Its
# `SE_*` ordinals mirror selfhost/sema.mc's `SmErr`.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_sema_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-sema-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/sema.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t sema_case_err_count(uint32_t c);
extern uint32_t sema_case_first_err(uint32_t c);
extern uint32_t sema_case_parse_err_count(uint32_t c);

/* SmErr ordinals — same declaration order as selfhost/sema.mc's SmErr enum. */
enum {
    SE_NONE = 0, SE_UNKNOWN_NAME, SE_ARG_COUNT, SE_ARG_TYPE, SE_NOT_BOOL_COND,
    SE_RET_MISMATCH, SE_ASSIGN_IMMUTABLE, SE_TYPE_MISMATCH
};

static int fails = 0;
static void eq(const char *what, uint32_t got, uint32_t want) {
    if (got != want) { printf("FAIL: %s: got %u want %u\n", what, got, want); fails++; }
}
static void ne0(const char *what, uint32_t got) {
    if (got == 0) { printf("FAIL: %s: got 0, expected non-zero\n", what); fails++; }
}

int main(void) {
    /* All inputs are well-FORMED (parse cleanly); only their TYPES differ. */
    for (uint32_t c = 0; c <= 6; c++) eq("parse clean", sema_case_parse_err_count(c), 0);

    /* ---- case 0: a well-typed module (two fns, a matching call) -> zero semantic errors ---- */
    eq("case0 accept err count", sema_case_err_count(0), 0);

    /* ---- reject cases: each must report >=1 error with the expected first-error code ---- */
    ne0("case1 unknown-name errs",   sema_case_err_count(1));
    eq ("case1 unknown-name code",   sema_case_first_err(1), SE_UNKNOWN_NAME);

    ne0("case2 arg-count errs",      sema_case_err_count(2));
    eq ("case2 arg-count code",      sema_case_first_err(2), SE_ARG_COUNT);

    ne0("case3 arg-type errs",       sema_case_err_count(3));
    eq ("case3 arg-type code",       sema_case_first_err(3), SE_ARG_TYPE);

    ne0("case4 non-bool-cond errs",  sema_case_err_count(4));
    eq ("case4 non-bool-cond code",  sema_case_first_err(4), SE_NOT_BOOL_COND);

    ne0("case5 ret-mismatch errs",   sema_case_err_count(5));
    eq ("case5 ret-mismatch code",   sema_case_first_err(5), SE_RET_MISMATCH);

    ne0("case6 assign-param errs",   sema_case_err_count(6));
    eq ("case6 assign-param code",   sema_case_first_err(6), SE_ASSIGN_IMMUTABLE);

    if (fails != 0) { printf("FAIL: selfhost-sema-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/sema.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-sema-test — mcc2 sema (selfhost/sema.mc) type-checked the Phase-2 AST: a well-typed module passed clean, and it rejected unknown names, call arg-count/type mismatches, a non-bool if-condition, a return-type mismatch, and assign-to-param (first-error codes match SmErr / src/sema.zig subset)"
    exit 0
fi
echo "FAIL: selfhost-sema-test — program returned non-zero"
exit 1
