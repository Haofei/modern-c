#!/usr/bin/env bash
# Differential backend tester: compile the same MC fixture through the C backend AND the LLVM
# backend, link each into the same driver, run both host executables, and assert they agree.
# A divergence is a backend codegen bug (evaluation order, switch/Result/optional lowering,
# move lowering, ABI) — the class static review is worst at finding.
#
#   entry mode  : the driver prints the entry function's u32 return; compare stdout AND exit.
#   driver mode : the bespoke driver encodes pass/fail in its exit code; compare exit only
#                 (its stdout may carry non-deterministic detail like addresses).
#
# The LLVM backend is an in-progress slice (spec annex M), so a fixture it cannot yet lower or
# link is a SKIP — a running inventory of LLVM-backend gaps, not a failure. A fixture the C
# backend cannot build on this host (riscv-only inline asm on x86) is likewise skipped.
# Each row is independent, so the corpus fans out across cores (override with JOBS=N).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: diff-backend (clang not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: diff-backend (llc not found)"; exit 0; }
MANIFEST="$HERE/tools/lib/host-tests.tsv"

# The LLVM backend externalizes the trap helpers (the C backend inlines them); -no-pie matches
# the existing LLVM host suite's link on Linux. (Scalar, not an array, so it survives the
# `export -f` worker subshells.)
LINK_FLAGS_STR=""
if [ "$(uname -s)" = "Linux" ]; then LINK_FLAGS_STR="-no-pie"; fi

export MCC HERE CLANG LLC MANIFEST LINK_FLAGS_STR

diff_one() {
    local name="$1"
    local fixture mode spec mcc_flags
    fixture="$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$MANIFEST")"
    mode="$(awk -F'\t' -v n="$name" '$1==n{print $3; exit}' "$MANIFEST")"
    spec="$(awk -F'\t' -v n="$name" '$1==n{print $4; exit}' "$MANIFEST")"
    mcc_flags="$(awk -F'\t' -v n="$name" '$1==n{print $5; exit}' "$MANIFEST")"
    local W; W="$(mktemp -d)"; trap 'rm -rf "$W"' RETURN

    case "$mode" in
        entry)  printf '#include <stdint.h>\n#include <stdio.h>\nextern uint32_t %s(void);\nint main(void){ printf("%%u\\n", %s()); return 0; }\n' "$spec" "$spec" > "$W/driver.c" ;;
        driver) cp "$HERE/tools/lib/host-drivers/$name.c" "$W/driver.c" ;;
        *)      echo "FAIL: diff-backend $name — unknown manifest mode '$mode'"; return 1 ;;
    esac

    if ! MCC="$MCC" bash "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/$fixture" -o "$W/c.o" $mcc_flags >/dev/null 2>&1; then
        echo "SKIP: diff-backend $name (C backend does not build on this host)"; return 0
    fi
    if ! MCC="$MCC" LLC="$LLC" bash "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/$fixture" -o "$W/l.o" >/dev/null 2>&1; then
        echo "SKIP: diff-backend $name (LLVM backend cannot lower this fixture yet)"; return 0
    fi
    # The C backend inlines its mc_trap_* helpers; the LLVM backend references them externally,
    # so the LLVM link needs trap stubs. Neither passing fixture actually traps, so __builtin_trap
    # stubs are never reached — they only resolve the symbols.
    cat > "$W/trap_stubs.c" <<'C'
void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }
C
    if ! "$CLANG" -std=c11 $LINK_FLAGS_STR "$W/driver.c" "$W/c.o" -o "$W/c.bin" >/dev/null 2>&1; then
        echo "SKIP: diff-backend $name (C link failed)"; return 0
    fi
    if ! "$CLANG" -std=c11 $LINK_FLAGS_STR "$W/driver.c" "$W/trap_stubs.c" "$W/l.o" -o "$W/l.bin" >/dev/null 2>&1; then
        echo "SKIP: diff-backend $name (LLVM link failed)"; return 0
    fi

    local c_out l_out c_rc l_rc
    c_out="$("$W/c.bin" 2>&1)"; c_rc=$?
    l_out="$("$W/l.bin" 2>&1)"; l_rc=$?
    if [ "$c_rc" != "$l_rc" ]; then
        echo "FAIL: diff-backend $name — exit codes differ: C=$c_rc LLVM=$l_rc"; return 1
    fi
    if [ "$mode" = "entry" ] && [ "$c_out" != "$l_out" ]; then
        echo "FAIL: diff-backend $name — entry return differs: C='$c_out' LLVM='$l_out'"; return 1
    fi
    return 0
}
export -f diff_one

names=()
while IFS= read -r name; do
    names+=("$name")
done < <(awk -F'\t' '/^#/{next} NF>=2 && $1!=""{print $1}' "$MANIFEST")
count="${#names[@]}"
out="$(printf '%s\0' "${names[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'diff_one "$@"' _ {} 2>&1)" || true
[ -n "$out" ] && printf '%s\n' "$out"

fails="$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)"
skips="$(printf '%s\n' "$out" | grep -c '^SKIP:' || true)"
compared=$(( count - skips ))
if [ "$fails" -gt 0 ]; then
    echo "FAIL: diff-backend — $fails backend divergence(s) across $count fixtures"
    exit 1
fi
echo "PASS: diff-backend — C and LLVM agree on $compared comparable host fixtures ($skips skipped, $count total)"
