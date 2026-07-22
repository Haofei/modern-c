#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLC="${LLC:-llc}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-sched-test" || echo "x86-sched-test")
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (no clang)"; exit 0; }
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (no llc)"; exit 0; }; fi
case "$(uname -m)" in x86_64|amd64) ;; *) echo "SKIP: $TEST_NAME (host not x86-64)"; exit 0;; esac
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
case "$BACKEND" in
    c)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/x86/sched_x86_demo.mc" -o "$WORK/sched.o" -Wno-switch-bool >/dev/null
        ;;
    llvm)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/sched_x86_demo.mc" -o "$WORK/sched.o" \
            -mtriple=x86_64-unknown-linux-gnu \
            -relocation-model=pic
        "$CLANG" -std=c11 -O1 -Wall -Wextra -Wno-unused-parameter -x c -c /dev/null -o "$WORK/llvm-support.o"
        ;;
    *)
        echo "unknown kernel backend: $BACKEND" >&2
        exit 2
        ;;
esac
# The context-switch primitives are now PURE MC (kernel/arch/x86_64/context_runtime.mc): naked
# mc_switch_context / mc_switch_context_vm / first-switch trampoline + mc_thread_init. Compile
# that MC module to a native object the same way as the scheduler demo above. The old
# context_runtime.c is deleted.
case "$BACKEND" in
    c)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/kernel/arch/x86_64/context_runtime.mc" -o "$WORK/ctx.o" -Wno-switch-bool >/dev/null
        ;;
    llvm)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/kernel/arch/x86_64/context_runtime.mc" -o "$WORK/ctx.o" \
            -mtriple=x86_64-unknown-linux-gnu \
            -relocation-model=pic
        ;;
esac
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t sched_x86_run(void);
int main(void){ uint32_t r = sched_x86_run(); printf("x86 cooperative sched -> %u (1 = ABCABCABC)\n", r); return r==1 ? 0 : 1; }
EOF
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
"$CLANG" -std=c11 -O1 "$WORK/driver.c" "$WORK/sched.o" "$WORK/ctx.o" $SUPPORT_OBJ -o "$WORK/app"
if "$WORK/app"; then echo "PASS: $TEST_NAME — $BACKEND backend x86-64 cooperative context switch: 3 threads on private stacks round-robin (ABCABCABC) via real mc_switch_context/mc_thread_init"; exit 0; fi
echo "FAIL: $TEST_NAME"; exit 1
