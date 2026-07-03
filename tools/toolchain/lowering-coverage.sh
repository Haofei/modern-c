#!/usr/bin/env bash
# Lowering-coverage report (hardening item V3.2).
#
# Measures which functions of the split C/LLVM backend modules (`src/lower_c*.zig`
# and `src/lower_llvm*.zig`, excluding tests/instrumentation) the differential
# corpus actually exercises, and reports the UNCOVERED ones. Divergence-
# prone lowering paths that no fixture or fuzz program ever hits are exactly where
# miscompiles hide (the overlay-read miscompile lived in such an uncovered branch).
#
# MECHANISM (and its honest fidelity): there is no kcov in the dev image, and Zig 0.16's
# self-hosted compiler exposes no -fprofile-instr-generate / source-coverage flag for its
# own output, so true llvm-cov line/branch coverage of the `mcc` binary is unavailable.
# Instead this script does FUNCTION-LEVEL coverage by source instrumentation:
#   1. inject a `lower_cov.hit("<file>:<fn>:<line>")` probe at the top of every function
#      in each production backend module (tools/toolchain/lowering-cov-instrument.py),
#   2. build that instrumented `mcc`,
#   3. run it (emit-c AND emit-llvm) over (a) every diff-backend host fixture and
#      (b) a batch of mcfuzz-generated programs, each writing its fired-function set to a
#      per-invocation file (MC_LOWER_COV),
#   4. union the fired sets and subtract from the universe of probes → the uncovered list.
# A function counts as covered if it was ENTERED at least once. This is coarser than
# branch coverage but is precisely the granularity that surfaces "this whole lowering
# family is never exercised" — the class V3.2 targets.
#
# The backend files are instrumented in an isolated temporary checkout by default,
# so this script is safe to run from aggregate/parallel gates. Output: a human
# report on stdout; the raw uncovered lists in $OUTDIR.
set -euo pipefail

SRC_ROOT="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"

FUZZ_N="${FUZZ_N:-60}"          # number of mcfuzz programs to fold into the corpus
OUTDIR="${OUTDIR:-$SRC_ROOT/zig-out/lowering-cov}"
BASELINE="${LOWERING_COV_BASELINE:-$SRC_ROOT/tools/toolchain/lowering-coverage-baseline.tsv}"
MCC="zig-out/bin/mcc"

case "$OUTDIR" in
    /*) ;;
    *) OUTDIR="$SRC_ROOT/$OUTDIR" ;;
esac
case "$BASELINE" in
    /*) ;;
    *) BASELINE="$SRC_ROOT/$BASELINE" ;;
esac

check_mode=0
if [ "${1:-}" = "--check" ]; then
    check_mode=1
fi

WORKROOT=""
cleanup_workroot() {
    if [ -n "$WORKROOT" ] && [ "${LOWERING_COV_IN_PLACE:-0}" != "1" ]; then
        rm -rf "$WORKROOT"
    fi
}

prepare_workroot() {
    if [ "${LOWERING_COV_IN_PLACE:-0}" = "1" ]; then
        cd "$SRC_ROOT"
        return
    fi

    WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/mc-lowering-cov.XXXXXX")"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude '.git' \
            --exclude '.zig-cache' \
            --exclude 'zig-cache' \
            --exclude 'zig-out' \
            --exclude '.wamr-cache' \
            "$SRC_ROOT"/ "$WORKROOT"/
    else
        (
            cd "$SRC_ROOT"
            git ls-files --cached --others --exclude-standard -z \
                | tar --null -T - -cf -
        ) | (
            cd "$WORKROOT"
            tar -xf -
        )
    fi
    cd "$WORKROOT"
}

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR/cov" "$OUTDIR/progs"
prepare_workroot

collect_backend_files() {
    local prefix="$1"
    find src -maxdepth 1 -type f -name "${prefix}*.zig" \
        ! -name "${prefix}_tests.zig" \
        ! -name "lower_cov.zig" \
        | sort
}

backend_kind() {
    case "$1" in
        src/lower_c*) echo "lower_c" ;;
        src/lower_llvm*) echo "lower_llvm" ;;
        *) echo "unknown" ;;
    esac
}

backup_files=""
restore() {
    if [ -n "$backup_files" ]; then
        printf '%s\n' "$backup_files" | while IFS='	' read -r src bak; do
            [ -n "$src" ] || continue
            cp "$bak" "$src"
            rm -f "$bak"
        done
    fi
}

# --- 1. instrument (with restore-on-exit) ------------------------------------------------
trap 'status=$?; restore; cleanup_workroot; exit "$status"' EXIT

: > "$OUTDIR/universe_lower_c.txt"
: > "$OUTDIR/universe_lower_llvm.txt"
instrumented_files=0
lower_c_file_count="$(collect_backend_files "lower_c" | wc -l | tr -d ' ')"
lower_llvm_file_count="$(collect_backend_files "lower_llvm" | wc -l | tr -d ' ')"
for src in $(collect_backend_files "lower_c") $(collect_backend_files "lower_llvm"); do
    bak="$(mktemp)"
    cp "$src" "$bak"
    backup_files="${backup_files}${src}	${bak}
"
    kind="$(backend_kind "$src")"
    python3 tools/toolchain/lowering-cov-instrument.py "$src" >> "$OUTDIR/universe_${kind}.txt"
    instrumented_files=$((instrumented_files + 1))
done
echo "instrumented: $(wc -l < "$OUTDIR/universe_lower_c.txt") fns across $lower_c_file_count C backend files, $(wc -l < "$OUTDIR/universe_lower_llvm.txt") across $lower_llvm_file_count LLVM backend files"

# --- 2. build the instrumented mcc -------------------------------------------------------
echo "building instrumented mcc..."
if ! zig build > "$OUTDIR/build.log" 2>&1; then
    echo "FAIL: instrumented build failed"
    tail -80 "$OUTDIR/build.log"
    exit 1
fi

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
printf "  lower_c*.zig    : %d/%d functions covered (%s)  — %d UNCOVERED\n" "$cov_c" "$uni_c" "$(pct "$cov_c" "$uni_c")" "$unc_c"
printf "  lower_llvm*.zig : %d/%d functions covered (%s)  — %d UNCOVERED\n" "$cov_l" "$uni_l" "$(pct "$cov_l" "$uni_l")" "$unc_l"
echo

# Notable uncovered: group by function base-name (strip :line) and show families.
echo "--- NOTABLE UNCOVERED lower_c*.zig branches (file:function:line) ---"
sort "$OUTDIR/uncovered_lower_c.txt" > "$OUTDIR/uncovered_lower_c.sorted"
sed -n '1,40p' "$OUTDIR/uncovered_lower_c.sorted"
echo "... ($unc_c total; full list: $OUTDIR/uncovered_lower_c.txt)"
echo
echo "--- NOTABLE UNCOVERED lower_llvm*.zig branches (file:function:line) ---"
sort "$OUTDIR/uncovered_lower_llvm.txt" > "$OUTDIR/uncovered_lower_llvm.sorted"
sed -n '1,40p' "$OUTDIR/uncovered_lower_llvm.sorted"
echo "... ($unc_l total; full list: $OUTDIR/uncovered_lower_llvm.txt)"
echo "============================================================================"

if [ "$check_mode" -eq 1 ]; then
    if [ ! -f "$BASELINE" ]; then
        echo "FAIL: lowering-coverage baseline not found: $BASELINE"
        exit 1
    fi
    row_c="$(awk -F'\t' '$1 == "lower_c" { print $0 }' "$BASELINE")"
    row_l="$(awk -F'\t' '$1 == "lower_llvm" { print $0 }' "$BASELINE")"
    if [ -z "$row_c" ] || [ -z "$row_l" ]; then
        echo "FAIL: lowering-coverage baseline must contain lower_c and lower_llvm rows"
        exit 1
    fi
    base_c_files="$(printf '%s\n' "$row_c" | awk -F'\t' '{ print $2 }')"
    base_c_universe="$(printf '%s\n' "$row_c" | awk -F'\t' '{ print $3 }')"
    max_unc_c="$(printf '%s\n' "$row_c" | awk -F'\t' '{ print $4 }')"
    base_l_files="$(printf '%s\n' "$row_l" | awk -F'\t' '{ print $2 }')"
    base_l_universe="$(printf '%s\n' "$row_l" | awk -F'\t' '{ print $3 }')"
    max_unc_l="$(printf '%s\n' "$row_l" | awk -F'\t' '{ print $4 }')"
    if [ "$lower_c_file_count" -lt "$base_c_files" ] || [ "$lower_llvm_file_count" -lt "$base_l_files" ]; then
        echo "FAIL: lowering-coverage source set shrank (lower_c files=$lower_c_file_count min=$base_c_files; lower_llvm files=$lower_llvm_file_count min=$base_l_files)"
        exit 1
    fi
    if [ "$uni_c" -lt "$base_c_universe" ] || [ "$uni_l" -lt "$base_l_universe" ]; then
        echo "FAIL: lowering-coverage universe shrank (lower_c labels=$uni_c min=$base_c_universe; lower_llvm labels=$uni_l min=$base_l_universe)"
        exit 1
    fi
    if [ "$unc_c" -gt "$max_unc_c" ] || [ "$unc_l" -gt "$max_unc_l" ]; then
        echo "FAIL: lowering coverage regressed (lower_c uncovered=$unc_c max=$max_unc_c; lower_llvm uncovered=$unc_l max=$max_unc_l)"
        exit 1
    fi
    echo "PASS: lowering-coverage ratchet — uncovered counts did not grow"
fi
