#!/usr/bin/env bash
# Package-build test: build the demo package from its manifest with mcc-pkg,
# then link the resulting object against a C driver and run it.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
PKG="$HERE/tests/pkg"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: pkg-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "$PKG/demo.o"' EXIT

# `info` must report the manifest fields.
MCC="$MCC" "$HERE/tools/toolchain/mcc-pkg.sh" info "$PKG" | grep -q "package: demo" || {
    echo "FAIL: pkg-test — mcc-pkg info did not report the package name"
    exit 1
}

DEPS_OUT="$(MCC="$MCC" "$HERE/tools/toolchain/mcc-pkg.sh" deps "$PKG")"

# `deps` must resolve the declared dependency and its transitive dependency at
# their required versions.
printf '%s\n' "$DEPS_OUT" | grep -q "dep: mathlib 0.1.0" || {
    echo "FAIL: pkg-test — mcc-pkg deps did not resolve mathlib@0.1.0"
    exit 1
}
printf '%s\n' "$DEPS_OUT" | grep -q "dep: baselib 0.1.0" || {
    echo "FAIL: pkg-test — mcc-pkg deps did not resolve transitive baselib@0.1.0"
    exit 1
}

BADPKG="$WORK/badpkg"
cp -R "$PKG" "$BADPKG"
awk '{ if ($1 == "version") print "version = 9.9.9"; else print }' \
    "$BADPKG/deps/baselib/mcpkg.txt" >"$BADPKG/deps/baselib/mcpkg.txt.tmp"
mv "$BADPKG/deps/baselib/mcpkg.txt.tmp" "$BADPKG/deps/baselib/mcpkg.txt"
if MCC="$MCC" "$HERE/tools/toolchain/mcc-pkg.sh" deps "$BADPKG" >"$WORK/bad_deps.out" 2>&1; then
    echo "FAIL: pkg-test — transitive dependency version mismatch was accepted"
    exit 1
fi
grep -q "dependency 'baselib' version mismatch" "$WORK/bad_deps.out" || {
    echo "FAIL: pkg-test — transitive version mismatch did not report baselib"
    cat "$WORK/bad_deps.out"
    exit 1
}

# `build` must produce the object from the entry + its imports.
MCC="$MCC" "$HERE/tools/toolchain/mcc-pkg.sh" build "$PKG" >/dev/null
cp "$PKG/demo.o" "$WORK/demo.o"

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t demo_main(uint32_t);
void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }
// demo_main(x) = clamp_u32(scale(x) + cube(x), 0, 1000) = clamp(10*x + x*x*x, 0, 1000).
int main(void) {
    if (demo_main(5) != 175) return 1;    // 50 + 125
    if (demo_main(10) != 1000) return 2;  // 100 + 1000 -> clamped
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/demo.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: pkg-test — package built from manifest, linked, and ran"
    exit 0
fi
echo "FAIL: pkg-test — program returned non-zero"
exit 1
