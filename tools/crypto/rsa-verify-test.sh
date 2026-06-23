#!/usr/bin/env bash
# MC RSA-PKCS#1/SHA-256 signature-verify binding (kernel/crypto/rsa_verify.mc) over the
# vendored constant-time BearSSL "i31" engine — the signed-bundle / image verification
# primitive for production-readiness plan P4.
#
# Compiles the MC binding + runtime (which embeds a REAL RSA-2048 public key and a genuine
# openssl-produced SHA-256 PKCS#1 signature of "MC bundle v1") through the requested backend,
# links it with the vendored BearSSL compiled for the HOST, and runs it natively. The runtime
# returns 1 iff the valid signature VERIFIES and BOTH a one-bit-tampered signature and a wrong
# message are REJECTED. PASS requires the program to print 1.
#
# Host-based (no QEMU) so it is fast and runs the same on every dev box; the binding itself is
# arch-neutral MC, so a green run on both the C and LLVM backends is the parity proof.
#
# Usage: tools/crypto/rsa-verify-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when clang (or llc, for the llvm backend) is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
B="$HERE/third_party/bearssl"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-rsa-verify-test" || echo "rsa-verify-test")

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNTIME="$HERE/tests/qemu/crypto/rsa_verify_runtime.mc"

# Lower the MC binding+runtime to a host object via the requested backend.
case "$BACKEND" in
    c)
        "$MCC" emit-c "$RUNTIME" > "$WORK/mod.c"
        "$CLANG" -c "$WORK/mod.c" -o "$WORK/mod.o" -I"$B/inc" -Wno-everything
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" bash "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$RUNTIME" -o "$WORK/mod.o"
        ;;
    *)
        echo "FAIL: $TEST_NAME — unknown backend '$BACKEND'"; exit 1 ;;
esac

# Compile the vendored BearSSL for the host (constant-time i31 RSA + SHA-256 + big-int).
mkdir -p "$WORK/bo"; i=0
while IFS= read -r f; do
    "$CLANG" -c "$f" -o "$WORK/bo/b$i.o" -I"$B/inc" -I"$B/src" -Wno-everything 2>/dev/null && i=$((i+1)) || true
done < <(find "$B/src" -name '*.c' | sort)

cat > "$WORK/driver.c" <<'C'
#include <stdint.h>
#include <stdio.h>
extern uint32_t rsa_verify_run(void);
int main(void){ uint32_t r = rsa_verify_run(); printf("%u\n", r); return r==1 ? 0 : 1; }
C

# The LLVM backend externalizes the trap helpers; provide trapping stubs (never reached here).
cat > "$WORK/trap_stubs.c" <<'C'
void mc_trap_Assert(void){__builtin_trap();}
void mc_trap_Bounds(void){__builtin_trap();}
void mc_trap_DivideByZero(void){__builtin_trap();}
void mc_trap_IntegerOverflow(void){__builtin_trap();}
void mc_trap_InvalidRepresentation(void){__builtin_trap();}
void mc_trap_InvalidShift(void){__builtin_trap();}
void mc_trap_NullUnwrap(void){__builtin_trap();}
void mc_trap_Unreachable(void){__builtin_trap();}
C
STUBS=""
[ "$BACKEND" = llvm ] && STUBS="$WORK/trap_stubs.c"

"$CLANG" "$WORK/driver.c" $STUBS "$WORK/mod.o" "$WORK"/bo/*.o -o "$WORK/app"

OUT="$("$WORK/app" || true)"
echo "--- rsa-verify ($BACKEND) output: '$OUT' (compiled $i BearSSL objs) ---"
if [ "$OUT" = "1" ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: real RSA-2048/SHA-256 signature VERIFIED, tampered signature + wrong message REJECTED, via constant-time BearSSL i31"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '1' (accept valid + reject tampered/wrong), got '$OUT'"
exit 1
