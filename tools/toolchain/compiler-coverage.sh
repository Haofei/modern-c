#!/usr/bin/env bash
# Compiler front-end/semantics function-coverage report.
#
# Measures function-entry coverage for the production parser/sema/monomorphize/
# async front-end semantics slice. This is deliberately the same fidelity as the
# lowering coverage gate: function-level source instrumentation plus a deterministic
# compiler corpus, not full line/branch coverage.
#
# Source set:
#   src/parser.zig
#   src/sema*.zig, excluding *_tests.zig
#   src/monomorphize.zig
#   src/generic_precheck.zig
#   src/async_lower.zig
#
# The files are instrumented in an isolated temporary checkout by default, then an
# instrumented mcc is built and driven through frontend-heavy existing checks. Raw
# uncovered lists are written to zig-out/compiler-cov.
set -euo pipefail

SRC_ROOT="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"

OUTDIR="${OUTDIR:-$SRC_ROOT/zig-out/compiler-cov}"
BASELINE="${COMPILER_COV_BASELINE:-$SRC_ROOT/tools/toolchain/compiler-coverage-baseline.tsv}"
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
    if [ -n "$WORKROOT" ] && [ "${COMPILER_COV_IN_PLACE:-0}" != "1" ]; then
        rm -rf "$WORKROOT"
    fi
}

prepare_workroot() {
    if [ "${COMPILER_COV_IN_PLACE:-0}" = "1" ]; then
        cd "$SRC_ROOT"
        return
    fi

    WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/mc-compiler-cov.XXXXXX")"
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

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR/cov" "$OUTDIR/logs"
prepare_workroot

collect_frontend_files() {
    {
        [ -f src/parser.zig ] && printf '%s\n' src/parser.zig
        find src -maxdepth 1 -type f -name 'sema*.zig' ! -name '*_tests.zig' | sort
        for f in src/monomorphize.zig src/generic_precheck.zig src/async_lower.zig; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    } | sort -u
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

trap 'status=$?; restore; cleanup_workroot; exit "$status"' EXIT

: > "$OUTDIR/universe_compiler.txt"
instrumented_files=0
compiler_file_count="$(collect_frontend_files | wc -l | tr -d ' ')"
for src in $(collect_frontend_files); do
    bak="$(mktemp)"
    cp "$src" "$bak"
    backup_files="${backup_files}${src}	${bak}
"
    python3 tools/toolchain/lowering-cov-instrument.py "$src" >> "$OUTDIR/universe_compiler.txt"
    instrumented_files=$((instrumented_files + 1))
done
echo "instrumented: $(wc -l < "$OUTDIR/universe_compiler.txt") fns across $compiler_file_count compiler frontend files"

echo "building instrumented mcc..."
if ! zig build > "$OUTDIR/build.log" 2>&1; then
    echo "FAIL: compiler-coverage instrumented build failed"
    tail -80 "$OUTDIR/build.log"
    exit 1
fi

WRAPPER="$OUTDIR/mcc-coverage-wrapper.sh"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cov="\$(mktemp "$OUTDIR/cov/hit.XXXXXX")"
MC_LOWER_COV="\$cov" exec "$PWD/$MCC" "\$@"
EOF
chmod +x "$WRAPPER"

# Existing deterministic check corpora that heavily exercise parse/sema without QEMU.
nspec=0
for fixture in tests/spec/*.mc; do
    [ -f "$fixture" ] || continue
    "$WRAPPER" check "$fixture" >/dev/null 2>&1 || true
    nspec=$((nspec + 1))
done
echo "folded $nspec spec fixtures as check invocations"

ncemit=0
for fixture in tests/c_emit/*.mc tests/c_emit/bad/*.mc; do
    [ -f "$fixture" ] || continue
    "$WRAPPER" check "$fixture" >/dev/null 2>&1 || true
    ncemit=$((ncemit + 1))
done
echo "folded $ncemit c_emit fixtures as check invocations"

# Fold the host-test manifest as check invocations only. Failures are tolerated
# here because some rows are backend/toolchain/host specific; they still
# contribute all front-end functions reached before rejection.
nfix=0
MANIFEST="tools/lib/host-tests.tsv"
while IFS=$'\t' read -r name fixture mode spec flags desc; do
    case "$name" in ''|\#*) continue;; esac
    [ -f "$fixture" ] || continue
    "$WRAPPER" check "$fixture" >/dev/null 2>&1 || true
    nfix=$((nfix + 1))
done < "$MANIFEST"
echo "folded $nfix host manifest fixtures as check invocations"

cat "$OUTDIR"/cov/* 2>/dev/null | sort -u > "$OUTDIR/covered.txt"
sort -u "$OUTDIR/universe_compiler.txt" > "$OUTDIR/universe_compiler.sorted"
comm -23 "$OUTDIR/universe_compiler.sorted" "$OUTDIR/covered.txt" > "$OUTDIR/uncovered_compiler.txt"

pct() {
    local c="$1" t="$2"
    [ "$t" -eq 0 ] && { echo "n/a"; return; }
    awk -v c="$c" -v t="$t" 'BEGIN{printf "%.1f%%", 100*c/t}'
}

uni=$(wc -l < "$OUTDIR/universe_compiler.sorted")
unc=$(wc -l < "$OUTDIR/uncovered_compiler.txt")
cov=$((uni - unc))

echo
echo "================= COMPILER-COVERAGE REPORT (function-level) ================="
echo "source set: parser.zig, sema*.zig excluding tests, monomorphize.zig, generic_precheck.zig, async_lower.zig"
echo "corpus: $nspec spec fixtures + $ncemit c_emit fixtures + $nfix host manifest fixtures as check invocations"
echo
printf "  compiler frontend : %d/%d functions covered (%s)  - %d UNCOVERED\n" "$cov" "$uni" "$(pct "$cov" "$uni")" "$unc"
echo
echo "--- NOTABLE UNCOVERED compiler frontend functions (file:function:line) ---"
sort "$OUTDIR/uncovered_compiler.txt" > "$OUTDIR/uncovered_compiler.sorted"
sed -n '1,80p' "$OUTDIR/uncovered_compiler.sorted"
echo "... ($unc total; full list: $OUTDIR/uncovered_compiler.txt)"
echo "============================================================================"

if [ "$check_mode" -eq 1 ]; then
    if [ ! -f "$BASELINE" ]; then
        echo "FAIL: compiler-coverage baseline not found: $BASELINE"
        exit 1
    fi
    row="$(awk -F'\t' '$1 == "compiler" { print $0 }' "$BASELINE")"
    if [ -z "$row" ]; then
        echo "FAIL: compiler-coverage baseline must contain a compiler row"
        exit 1
    fi
    base_files="$(printf '%s\n' "$row" | awk -F'\t' '{ print $2 }')"
    base_universe="$(printf '%s\n' "$row" | awk -F'\t' '{ print $3 }')"
    max_unc="$(printf '%s\n' "$row" | awk -F'\t' '{ print $4 }')"
    if [ "$compiler_file_count" -lt "$base_files" ]; then
        echo "FAIL: compiler-coverage source set shrank (compiler files=$compiler_file_count min=$base_files)"
        exit 1
    fi
    if [ "$uni" -lt "$base_universe" ]; then
        echo "FAIL: compiler-coverage universe shrank (compiler labels=$uni min=$base_universe)"
        exit 1
    fi
    if [ "$unc" -gt "$max_unc" ]; then
        echo "FAIL: compiler coverage regressed (compiler uncovered=$unc max=$max_unc)"
        exit 1
    fi
    echo "PASS: compiler-coverage ratchet - uncovered count did not grow"
fi
