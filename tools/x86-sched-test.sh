#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: x86-sched-test (no clang)"; exit 0; }
case "$(uname -m)" in x86_64|amd64) ;; *) echo "SKIP: x86-sched-test (host not x86-64)"; exit 0;; esac
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/x86/sched_x86_demo.mc" -o "$WORK/sched.o" -Wno-switch-bool >/dev/null
"$CLANG" -std=c11 -O1 -Wall -Wextra -Wno-unused-parameter -c "$HERE/kernel/arch/x86_64/context_runtime.c" -o "$WORK/ctx.o"
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t sched_x86_run(void);
int main(void){ uint32_t r = sched_x86_run(); printf("x86 cooperative sched -> %u (1 = ABCABCABC)\n", r); return r==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -O1 "$WORK/driver.c" "$WORK/sched.o" "$WORK/ctx.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: x86-sched-test — x86-64 cooperative context switch: 3 threads on private stacks round-robin (ABCABCABC) via real mc_switch_context/mc_thread_init"; exit 0; fi
echo "FAIL: x86-sched-test"; exit 1
