#!/usr/bin/env bash
# selfhost-emit-test: build the Phase-4 self-hosted C-CODE EMITTER (selfhost/emit_c.mc, mcc2's
# subset C emitter over the Phase-2 flat index-arena AST), and prove the milestone round-trip
# lex -> parse -> emit -> clang -> run. Stage A links the emitter with a C "dumper" that calls
# the exported emit_len/emit_byte to reconstruct the emitted C for two fixed MC snippets and
# writes them to out0.c / out1.c. Stage B clang-compiles those emitted C files together with a
# small C `main` that calls the emitted functions and asserts add(2,3)==5 and fact(5)==120. A
# green run proves mcc2 emitted C that clang compiled and ran.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_emit_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-emit-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/emit.o" >/dev/null

# ----- Stage A: dump the emitted C for each case to a file -----
cat >"$WORK/dumper.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t emit_len(uint32_t c);
extern uint32_t emit_byte(uint32_t c, uint32_t i);

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: dumper out0.c out1.c\n"); return 2; }
    for (uint32_t c = 0; c <= 1; c++) {
        FILE *f = fopen(argv[1 + c], "wb");
        if (!f) { perror("fopen"); return 3; }
        uint32_t n = emit_len(c);
        for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(c, i), f);
        fclose(f);
    }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/emit.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out0.c" "$WORK/out1.c"

echo "----- emitted out0.c (add) -----"
cat "$WORK/out0.c"
echo "----- emitted out1.c (fact) -----"
cat "$WORK/out1.c"

# ----- Stage B: compile the emitted C + a driver main that calls it -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t add(uint32_t a, uint32_t b);
extern uint32_t fact(uint32_t n);

int main(void) {
    int fails = 0;
    if (add(2, 3) != 5)   { printf("FAIL: add(2,3)=%u want 5\n", add(2,3)); fails++; }
    if (add(40, 2) != 42) { printf("FAIL: add(40,2)=%u want 42\n", add(40,2)); fails++; }
    if (fact(5) != 120)   { printf("FAIL: fact(5)=%u want 120\n", fact(5)); fails++; }
    if (fact(0) != 1)     { printf("FAIL: fact(0)=%u want 1\n", fact(0)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-emit-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out0.c" "$WORK/out1.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-emit-test — mcc2 emitter (selfhost/emit_c.mc) emitted C for add + iterative fact that clang compiled and ran (add(2,3)==5, add(40,2)==42, fact(5)==120, fact(0)==1) — lex->parse->emit->clang->run round-trip"
    exit 0
fi
echo "FAIL: selfhost-emit-test — program returned non-zero"
exit 1
