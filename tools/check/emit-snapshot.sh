#!/usr/bin/env bash
# emit-snapshot.sh — differential oracle for behavior-preserving refactors.
#
# Runs `mcc emit-c` and `mcc emit-llvm` over a fixed fixture corpus and records,
# per (fixture, backend), a hash of stdout or ERR:<exitcode> on failure. A pure
# structural refactor (file splits, build.zig decomposition) MUST reproduce a
# byte-identical snapshot. This is NOT a correctness oracle — it only proves
# "no observable change in emitted output", which is exactly the Phase 0/1/2
# invariant in docs/refactor-plan.md.
#
# Usage:
#   tools/check/emit-snapshot.sh capture            # write baseline
#   tools/check/emit-snapshot.sh verify             # diff against baseline
#
# Env: MCC (default zig-out/bin/mcc), SNAP_DIR (default .refactor-baseline).
set -u

MODE="${1:-verify}"
MCC="${MCC_UNDER_TEST:-${MCC:-zig-out/bin/mcc}}"
SNAP_DIR="${SNAP_DIR:-.refactor-baseline}"
CUR="$SNAP_DIR/current.txt"
BASE="$SNAP_DIR/baseline.txt"

if [ ! -x "$MCC" ]; then
  echo "error: mcc not found/executable at $MCC (run: zig build)" >&2
  exit 2
fi

# Deterministic corpus: every must-compile + reject fixture in these trees.
# Sorted so the snapshot order is stable across machines. Portable (no mapfile;
# works on macOS bash 3.2 and dash).
FIXTURE_LIST="$(find tests/c_emit tests/spec tests/llvm -name '*.mc' 2>/dev/null | LC_ALL=C sort)"

hash_cmd() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

# One job per (fixture, backend); print "file<TAB>backend<TAB>hash-or-ERR".
# Exported for the xargs subshell. Parallelized to keep verify fast (this runs
# after every Phase-2 split per docs/refactor-plan.md).
emit_one() {
  sub="$1"; file="$2"; tag="$3"
  out="$("$MCC" "$sub" "$file" 2>/dev/null)"; rc=$?
  if [ $rc -ne 0 ]; then h="ERR:$rc"
  else h="$(printf '%s' "$out" | hash_cmd)"; fi
  printf '%s\t%s\t%s\n' "$file" "$tag" "$h"
}
export -f emit_one hash_cmd
export MCC

mkdir -p "$SNAP_DIR"
JOBS="$SNAP_DIR/jobs.txt"
: > "$JOBS"
count=0
# Space-separated columns "sub file tag" (fixture paths contain no spaces). This
# feeds `xargs -n3`, which passes the three columns as positional args — no fragile
# IFS/here-string parsing inside the subshell (an earlier tab+read approach silently
# dropped the path, making the snapshot vacuous).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  printf 'emit-c %s c\n'      "$f" >> "$JOBS"
  printf 'emit-llvm %s llvm\n' "$f" >> "$JOBS"
  count=$((count + 1))
done <<EOF
$FIXTURE_LIST
EOF

NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
# Run jobs in parallel, then sort for a stable, order-independent snapshot.
xargs -P "$NPROC" -n3 bash -c 'emit_one "$1" "$2" "$3"' _ < "$JOBS" \
  | LC_ALL=C sort > "$CUR"

echo "snapshot: $count fixtures x 2 backends ($NPROC-way) -> $CUR"

if [ "$MODE" = "capture" ]; then
  cp "$CUR" "$BASE"
  echo "baseline written: $BASE"
  exit 0
fi

if [ ! -f "$BASE" ]; then
  echo "error: no baseline at $BASE (run: $0 capture)" >&2
  exit 2
fi

if diff -u "$BASE" "$CUR" > "$SNAP_DIR/diff.txt"; then
  echo "OK: emit output identical to baseline (no behavior change)"
  exit 0
else
  echo "FAIL: emit output differs from baseline:" >&2
  head -40 "$SNAP_DIR/diff.txt" >&2
  echo "... (full diff in $SNAP_DIR/diff.txt)" >&2
  exit 1
fi
