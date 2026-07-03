#!/usr/bin/env bash
# Lowering-coverage report (hardening item V3.2).
#
# Measures which functions of the two backends — src/lower_c.zig and src/lower_llvm.zig —
# the differential corpus actually exercises, and reports the UNCOVERED ones. Divergence-
# prone lowering paths that no fixture or fuzz program ever hits are exactly where
# miscompiles hide (the overlay-read miscompile lived in such an uncovered branch).
#
# MECHANISM (and its honest fidelity): there is no kcov in the dev image, and Zig 0.16's
# self-hosted compiler exposes no -fprofile-instr-generate / source-coverage flag for its
# own output, so true llvm-cov line/branch coverage of the `mcc` binary is unavailable.
# Instead this script does FUNCTION-LEVEL coverage by source instrumentation:
#   1. inject a `lower_cov.hit("<file>:<fn>:<line>")` probe at the top of every function
#      in the two backend files (tools/toolchain/lowering-cov-instrument.py),
#   2. build that instrumented `mcc`,
#   3. run it (emit-c AND emit-llvm) over (a) every diff-backend host fixture and
#      (b) a batch of mcfuzz-generated programs, each writing its fired-function set to a
#      per-invocation file (MC_LOWER_COV),
#   4. union the fired sets and subtract from the universe of probes → the uncovered list.
# A function counts as covered if it was ENTERED at least once. This is coarser than
# branch coverage but is precisely the granularity that surfaces "this whole lowering
# family is never exercised" — the class V3.2 targets.
#
# The two backend files are restored from backup on exit (trap), so this script leaves the
# tree clean. Output: a human report on stdout; the raw uncovered lists in $OUTDIR.
set -euo pipefail

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
cd "$HERE"

FUZZ_N="${FUZZ_N:-60}"          # number of mcfuzz programs to fold into the corpus
OUTDIR="${OUTDIR:-zig-out/lowering-cov}"
MCC="${MCC_UNDER_TEST:-zig-out/bin/mcc}"
LC="src/lower_c.zig"
LL="src/lower_llvm.zig"

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR/cov" "$OUTDIR/progs"

# --- 1. instrument (with restore-on-exit) ------------------------------------------------
LC_BAK="$(mktemp)"; LL_BAK="$(mktemp)"
cp "$LC" "$LC_BAK"; cp "$LL" "$LL_BAK"
restore() { cp "$LC_BAK" "$LC"; cp "$LL_BAK" "$LL"; rm -f "$LC_BAK" "$LL_BAK"; }
trap restore EXIT

python3 tools/toolchain/lowering-cov-instrument.py "$LC" > "$OUTDIR/universe_lower_c.txt"
python3 tools/toolchain/lowering-cov-instrument.py "$LL" > "$OUTDIR/universe_lower_llvm.txt"
echo "instrumented: $(wc -l < "$OUTDIR/universe_lower_c.txt") fns in lower_c.zig, $(wc -l < "$OUTDIR/universe_lower_llvm.txt") in lower_llvm.zig"

# --- 2. build the instrumented mcc -------------------------------------------------------
echo "building instrumented mcc..."
zig build >/dev/null 2>&1 || { echo "FAIL: instrumented build failed"; exit 1; }

# --- helper: run both backends over one .mc, accumulating coverage -----------------------
i=0
run_one() {
    local mc="$1"
    i=$((i+1))
    # emit-c (kernel + hosted profiles) and emit-llvm; failures are fine (uncompilable
    # fuzz programs / LLVM-unsupported fixtures just contribute whatever they reached).
    MC_LOWER_COV="$OUTDIR/cov/c_k_$i.txt"  "$MCC" emit-c   "$mc" --profile=kernel >/dev/null 2>&1 || true
    MC_LOWER_COV="$OUTDIR/cov/c_h_$i.txt"  "$MCC" emit-c   "$mc" --profile=hosted >/dev/null 2>&1 || true
    MC_LOWER_COV="$OUTDIR/cov/l_$i.txt"    "$MCC" emit-llvm "$mc"                  >/dev/null 2>&1 || true
}

# --- 3a. diff-backend host fixtures ------------------------------------------------------
MANIFEST="tools/lib/host-tests.tsv"
nfix=0
while IFS=$'\t' read -r name fixture mode spec flags desc; do
    case "$name" in ''|\#*) continue;; esac
    [ -f "$fixture" ] || continue
    run_one "$fixture"
    nfix=$((nfix+1))
done < "$MANIFEST"
echo "folded $nfix host fixtures"

# --- 3b. a batch of mcfuzz-generated programs --------------------------------------------
nfuzz=0
seed=1
while [ "$nfuzz" -lt "$FUZZ_N" ]; do
    prog="$OUTDIR/progs/fuzz_$seed.mc"
    if python3 tools/fuzz/mcfuzz.py gen "$seed" > "$prog" 2>/dev/null && [ -s "$prog" ]; then
        run_one "$prog"
        nfuzz=$((nfuzz+1))
    fi
    seed=$((seed+1))
    [ "$seed" -gt $((FUZZ_N*4)) ] && break
done
echo "folded $nfuzz mcfuzz programs"

# --- 4. union fired sets, compute uncovered ----------------------------------------------
cat "$OUTDIR"/cov/*.txt 2>/dev/null | sort -u > "$OUTDIR/covered.txt"
sort -u "$OUTDIR/universe_lower_c.txt"    > "$OUTDIR/universe_lower_c.sorted"
sort -u "$OUTDIR/universe_lower_llvm.txt" > "$OUTDIR/universe_lower_llvm.sorted"
# uncovered = universe set-minus covered
comm -23 "$OUTDIR/universe_lower_c.sorted"    "$OUTDIR/covered.txt" > "$OUTDIR/uncovered_lower_c.txt"
comm -23 "$OUTDIR/universe_lower_llvm.sorted" "$OUTDIR/covered.txt" > "$OUTDIR/uncovered_lower_llvm.txt"

pct() { # covered total
    local c="$1" t="$2"
    [ "$t" -eq 0 ] && { echo "n/a"; return; }
    awk -v c="$c" -v t="$t" 'BEGIN{printf "%.1f%%", 100*c/t}'
}

uni_c=$(wc -l < "$OUTDIR/universe_lower_c.sorted");     unc_c=$(wc -l < "$OUTDIR/uncovered_lower_c.txt");     cov_c=$((uni_c-unc_c))
uni_l=$(wc -l < "$OUTDIR/universe_lower_llvm.sorted");  unc_l=$(wc -l < "$OUTDIR/uncovered_lower_llvm.txt");  cov_l=$((uni_l-unc_l))

echo
echo "================= LOWERING-COVERAGE REPORT (function-level) ================="
echo "corpus: $nfix host fixtures + $nfuzz mcfuzz programs, each through emit-c (kernel+hosted) and emit-llvm"
echo
printf "  lower_c.zig    : %d/%d functions covered (%s)  — %d UNCOVERED\n" "$cov_c" "$uni_c" "$(pct "$cov_c" "$uni_c")" "$unc_c"
printf "  lower_llvm.zig : %d/%d functions covered (%s)  — %d UNCOVERED\n" "$cov_l" "$uni_l" "$(pct "$cov_l" "$uni_l")" "$unc_l"
echo

# Notable uncovered: group by function base-name (strip :line) and show families.
echo "--- NOTABLE UNCOVERED lower_c.zig branches (function : line) ---"
sed 's/^lower_c.zig://' "$OUTDIR/uncovered_lower_c.txt" | sort | head -40
echo "... ($unc_c total; full list: $OUTDIR/uncovered_lower_c.txt)"
echo
echo "--- NOTABLE UNCOVERED lower_llvm.zig branches (function : line) ---"
sed 's/^lower_llvm.zig://' "$OUTDIR/uncovered_lower_llvm.txt" | sort | head -40
echo "... ($unc_l total; full list: $OUTDIR/uncovered_lower_llvm.txt)"
echo "============================================================================"
