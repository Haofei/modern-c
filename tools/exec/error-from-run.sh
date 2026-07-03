#!/usr/bin/env bash
# Runtime proof (G8) that postfix `?` invokes the user-written `#[error_from]`
# conversion on the error path when the operand's error type differs from the
# enclosing function's error type, on BOTH backends.
#
# tests/exec/error_from_run.mc uses a NON-identity raw mapping (LowErr.io(0) ->
# HighErr.fatal(2), LowErr.eof(1) -> HighErr.low(0)), so a silent bit-reinterpret
# of the error payload (the pre-G8 unsound behavior) would yield 1017 while a real
# conversion yields 1207. Emits to C and to LLVM IR, compiles each to a native
# binary (cc / clang), runs it, and asserts 1207 — proving the CONVERTED error
# variant reaches the caller on both backends.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
SRC="tests/exec/error_from_run.mc"
EXPECT=1207

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

echo "error-from runtime proof: BOTH backends returned ${EXPECT} (converted, not reinterpreted)."
