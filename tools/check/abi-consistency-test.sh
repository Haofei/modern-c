#!/usr/bin/env bash
# abi-consistency gate (pure host check — no toolchain, never skips).
#
# user/abi.mc is the SINGLE source of truth for the confined-guest syscall numbers. The C
# guest userspace runtime and the kernel-side dispatchers must hardcode the SAME
# numbers (they cannot `import` the .mc constant). This gate fails the build if any of those
# C `#define SYS_<NAME> <N>` drift from abi.mc — the same belt-and-suspenders philosophy the
# virtqueue layout uses with `_Static_assert`.
#
# SCOPE: only files that consume the canonical guest ABI are checked. The standalone M6/M8
# user-hello demos and the older kernel demos deliberately use their OWN self-contained
# mini-ABIs (e.g. SYS_EXIT=2) and are intentionally NOT covered here.
set -euo pipefail
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
TEST_NAME="abi-consistency-test"
ABI="$HERE/user/abi.mc"

# Files that share the canonical guest ABI with abi.mc (C side, which must hardcode it).
GUEST_ABI_FILES=(
    user/runtime/usys.h
)
# The retained MC crt0/app_traps runtime hardcodes SYS_EXIT=3 in its naked
# RISC-V _start (an MC immediate, not a C #define), so it is excluded from this
# C-side grep. usys.h is the remaining C header that hardcodes ABI numbers.

# abi_num NAME -> the canonical number from abi.mc, or empty if NAME is not a canonical
# guest-ABI constant. (No associative arrays: portable to macOS bash 3.2 and Docker bash.)
abi_num() {
    grep -E "^export const $1:" "$ABI" \
        | sed -n 's/^export const SYS_[A-Z_]*:[^=]*=[[:space:]]*\([0-9][0-9]*\).*$/\1/p' \
        | head -n1
}

n_const=$(grep -c '^export const SYS_' "$ABI" || true)
if [ "$n_const" -eq 0 ]; then
    echo "FAIL: $TEST_NAME (could not parse any SYS_* constants from $ABI)"; exit 1
fi

fail=0
for rel in "${GUEST_ABI_FILES[@]}"; do
    f="$HERE/$rel"
    [ -e "$f" ] || { echo "FAIL: $TEST_NAME (missing file $rel)"; fail=1; continue; }
    # Each `#define SYS_<NAME> <N>[uUlL]*` whose NAME is in the canonical ABI must match.
    while IFS= read -r d; do
        name=$(printf '%s' "$d" | sed -n 's/^#define[[:space:]]*\(SYS_[A-Z_]*\)[[:space:]].*$/\1/p')
        num=$(printf '%s'  "$d" | sed -n 's/^#define[[:space:]]*SYS_[A-Z_]*[[:space:]]*\([0-9][0-9]*\).*$/\1/p')
        [ -n "$name" ] || continue
        want=$(abi_num "$name")
        # Only enforce names that exist in the canonical guest ABI.
        [ -n "$want" ] || continue
        if [ "$num" != "$want" ]; then
            echo "FAIL: $TEST_NAME — $rel defines $name=$num but abi.mc says $want"
            fail=1
        fi
    done < <(grep -E '^#define[[:space:]]+SYS_[A-Z_]+[[:space:]]' "$f")
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "PASS: $TEST_NAME — guest ABI C defines match user/abi.mc ($n_const constants in abi.mc, ${#GUEST_ABI_FILES[@]} files checked)"
