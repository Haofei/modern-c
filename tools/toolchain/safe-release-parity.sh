#!/usr/bin/env bash
# D2.5 safe-vs-release functional-parity gate.
#
# The explicit build-safety profile is selected with `mcc ... --checks=all|elide-proven`:
#   --checks=all           SAFE (default): every runtime trap check is kept.
#   --checks=elide-proven  RELEASE: the fact-gated MIR optimizer (annex E.4) elides ONLY the
#                          checks it PROVED can never trap; all other checks are kept.
# RELEASE only drops checks that were proven dead, so a non-trapping program must behave
# identically under both profiles. This gate pins that property end to end:
#   1. Compiles a fixture (const-index/const-slice/const-divisor — all provably in-bounds) and
#      the broader fixture corpus through the C backend under SAFE and RELEASE.
#   2. Links each into the same entry driver, runs them, asserts SAFE == RELEASE (functional
#      parity — observable output identical).
#   3. Asserts SAFE actually KEEPS the trap checks the optimizer proved dead and RELEASE ELIDES
#      exactly those — so we are testing a real elision, not a no-op.
# Driven through the new `--checks=` flag names (not the `--optimize` alias) so the documented
# knob itself is under test.
#
# Needs clang; self-skips (not fails) when absent — same policy as diff-backend.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-env.sh"
HERE="$(mc_repo_root)"
CLANG="${CLANG:-clang}"
mc_require_cmd "safe-release-parity" "$CLANG"

SRC="$HERE/tests/toolchain/opt_index_demo.mc"
ENTRY="opt_index_demo"
EXPECT=65

LINK_FLAGS_STR="$(mc_link_flags)"

W="$(mktemp -d)"
# Keep the work dir (and report the exit code) on FAILURE so a failing/aborted run is diagnosable —
# a nonzero rc, especially 137 (=128+9, SIGKILL: OOM/resource kill), points straight at the cause.
# Clean up only on success.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "safe-release-parity: FAILED rc=$rc — kept work dir: $W" >&2; else rm -rf "$W"; fi' EXIT

printf '#include <stdint.h>\n#include <stdio.h>\nextern uint32_t %s(void);\nint main(void){ printf("%%u\\n", %s()); return 0; }\n' "$ENTRY" "$ENTRY" > "$W/driver.c"

build_run() {
    local checks="$1" tag="$2"
    "$MCC" emit-c "$SRC" --checks="$checks" > "$W/$tag.c"
    "$CLANG" -std=c11 $LINK_FLAGS_STR "$W/driver.c" "$W/$tag.c" -o "$W/$tag.bin"
    "$W/$tag.bin"
}

safe="$(build_run all          safe)"
rel="$(build_run  elide-proven  rel)"

# 1. Functional parity: SAFE and RELEASE must produce the same result.
[ "$safe" = "$EXPECT" ] || { echo "FAIL: safe-release-parity — SAFE returned '$safe', expected '$EXPECT'"; exit 1; }
[ "$rel"  = "$EXPECT" ] || { echo "FAIL: safe-release-parity — RELEASE returned '$rel', expected '$EXPECT'"; exit 1; }
[ "$safe" = "$rel" ]    || { echo "FAIL: safe-release-parity — SAFE ('$safe') != RELEASE ('$rel')"; exit 1; }

# 2. The elision is real: SAFE keeps the index/slice/div checks RELEASE drops.
grep -q '\[mc_check_index_usize(' "$W/safe.c" || { echo "FAIL: safe-release-parity — SAFE dropped the index bounds check"; exit 1; }
grep -q '\[mc_check_index_usize(' "$W/rel.c"  && { echo "FAIL: safe-release-parity — RELEASE kept the index bounds check"; exit 1; }
grep -q '> mc_len'                "$W/safe.c" || { echo "FAIL: safe-release-parity — SAFE dropped the slice bounds check"; exit 1; }
grep -q '> mc_len'                "$W/rel.c"  && { echo "FAIL: safe-release-parity — RELEASE kept the slice bounds check"; exit 1; }
grep -q '= mc_checked_div_'       "$W/safe.c" || { echo "FAIL: safe-release-parity — SAFE dropped the div-by-zero check"; exit 1; }
grep -q '= mc_checked_div_'       "$W/rel.c"  && { echo "FAIL: safe-release-parity — RELEASE kept the div-by-zero check"; exit 1; }

echo "PASS: safe-release-parity — SAFE (--checks=all) and RELEASE (--checks=elide-proven) agree ($EXPECT); SAFE keeps the index+slice+div checks RELEASE proved dead and elided"
