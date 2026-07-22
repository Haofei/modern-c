#!/usr/bin/env bash
# Runtime proof that nullable trait objects (`?*dyn Trait`) actually execute correctly on
# BOTH backends — not just emit. Emits tests/exec/nullable_dyn_run.mc to C and to LLVM IR,
# compiles each to a native binary (cc / clang), runs it, and asserts the niche checksum.
# A wrong/absent niche (null not surviving store->load, none not skipped, some not
# dispatching) changes the result and fails the run.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
SRC="tests/exec/nullable_dyn_run.mc"
EXPECT=4022

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

main_c() {
  cat <<EOF
#include <stdio.h>
extern unsigned run(void);
int main(void){ unsigned r = run(); fprintf(stderr, "  run() = %u (expect ${EXPECT})\n", r); return r == ${EXPECT}u ? 0 : 1; }
EOF
}

# ---- C backend: emit + append main, compile with cc, run ----
echo "[C backend]"
"$MCC" emit-c "$SRC" > "$TMP/prog.c"
main_c >> "$TMP/prog.c"
cc -O0 "$TMP/prog.c" -o "$TMP/prog_c"
"$TMP/prog_c"
echo "  C backend: PASS"

# ---- LLVM backend: emit IR, define the trap externs it declares, compile with clang, run ----
echo "[LLVM backend]"
"$MCC" emit-llvm "$SRC" > "$TMP/prog.ll"
{
  echo '#include <stdio.h>'
  echo '#include <stdlib.h>'
  # The IR references `mc_trap_*` helpers (bounds/overflow/...); none are taken here. Emit a strong
  # abort-with-message override for each so a fired trap is diagnosed (it wins over the IR's own weak
  # self-provided `define weak ... { call @llvm.trap }`). Match the symbol name wherever it appears
  # (a `define weak`/`declare` decl or a `call` site); `|| true` keeps the no-trap case from tripping
  # `set -o pipefail` when grep finds nothing.
  { grep -oE '@mc_trap_[A-Za-z]+' "$TMP/prog.ll" || true; } | sed 's/@//' | sort -u \
    | while read -r t; do echo "void ${t}(void){ fprintf(stderr, \"TRAP: ${t}\n\"); abort(); }"; done
  main_c
} > "$TMP/harness.c"
clang -O0 "$TMP/harness.c" "$TMP/prog.ll" -o "$TMP/prog_llvm"
"$TMP/prog_llvm"
echo "  LLVM backend: PASS"

echo "nullable-dyn runtime proof: BOTH backends returned ${EXPECT}."
