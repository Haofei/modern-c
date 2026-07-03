#!/usr/bin/env bash
# Runtime proof that `#[naked]` functions (§20.1) actually execute correctly on BOTH
# backends — not just emit. A naked function emits no prologue/epilogue; its body is
# a single basic-asm block that owns the calling convention. We pick the fixture for
# the host ISA, emit it to C and to LLVM IR, compile each to a native binary
# (cc / clang), run it, and assert the side effect: the asm stores 42 through the
# pointer that arrives in the ABI arg0 register. A prologue would corrupt the frame
# before the hand-written `ret`; the 42 read back is the proof it was omitted.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
EXPECT=42

case "$(uname -m)" in
  aarch64|arm64) SRC="tests/exec/naked_run_arm64.mc" ;;
  x86_64|amd64)  SRC="tests/exec/naked_run_x86_64.mc" ;;
  *) echo "SKIP: naked-run-test — no naked fixture for ISA $(uname -m)"; exit 0 ;;
esac
echo "naked-run: host ISA $(uname -m) -> $SRC"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

main_c() {
  cat <<EOF
#include <stdio.h>
extern void naked_store(unsigned* out);
int main(void){ unsigned v = 0; naked_store(&v); fprintf(stderr, "  naked_store -> %u (expect ${EXPECT})\n", v); return v == ${EXPECT}u ? 0 : 1; }
EOF
}

# ---- C backend: emit + append main, compile with cc, run ----
echo "[C backend]"
"$MCC" emit-c "$SRC" > "$TMP/prog.c"
main_c >> "$TMP/prog.c"
cc -O0 "$TMP/prog.c" -o "$TMP/prog_c"
"$TMP/prog_c"
echo "  C backend: PASS"

# ---- LLVM backend: emit IR, link with a C harness, compile with clang, run ----
echo "[LLVM backend]"
"$MCC" emit-llvm "$SRC" > "$TMP/prog.ll"
main_c > "$TMP/harness.c"
clang -O0 "$TMP/harness.c" "$TMP/prog.ll" -o "$TMP/prog_llvm"
"$TMP/prog_llvm"
echo "  LLVM backend: PASS"

echo "naked runtime proof: BOTH backends stored ${EXPECT} through the ABI arg register with no prologue."
