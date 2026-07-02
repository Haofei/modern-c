#!/usr/bin/env bash
# Runtime proof (G23) that a value-producing comparison over an enum `.raw()` operand
# — `enum.raw() == N` in a typed `let bool` and in a `return` — actually EXECUTES
# correctly on BOTH backends, not just emits. Emits tests/exec/enum_raw_cmp_run.mc to C
# and to LLVM IR, compiles each to a native binary (cc / clang), runs it, and asserts the
# checksum. The C backend previously failed these value contexts with UnsupportedCEmission
# (the comparison-operand type recovery could not resolve the `.raw()` call's repr integer
# type); a wrong/absent result changes the checksum and fails the run.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
SRC="tests/exec/enum_raw_cmp_run.mc"
EXPECT=55

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
  { grep -oE '@mc_trap_[A-Za-z]+' "$TMP/prog.ll" || true; } | sed 's/@//' | sort -u \
    | while read -r t; do echo "void ${t}(void){ fprintf(stderr, \"TRAP: ${t}\n\"); abort(); }"; done
  main_c
} > "$TMP/harness.c"
clang -O0 "$TMP/harness.c" "$TMP/prog.ll" -o "$TMP/prog_llvm"
"$TMP/prog_llvm"
echo "  LLVM backend: PASS"

echo "enum-raw-cmp runtime proof: BOTH backends returned ${EXPECT}."
