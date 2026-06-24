#!/usr/bin/env bash
# End-to-end gate for the AGENT-FACING async API (user/agent_async.mc): an `async fn` agent does
# `let a = await read_async(...); let b = await tool_call_async(...)` plus a sleep_async (timeout)
# and a timeout-then-CANCEL, all driven by pump_run_to_completion over the ToolFut/ToolPump leaves,
# running on a bare riscv64 kernel under QEMU. The broker (sys_submit/sys_poll contract) is an
# in-kernel shim with app_run_demo's semantics — the permitted kernel-mode fallback to a full
# user-process gate; it drives the SAME leaves for real (await resolves through the ABI, cancel
# reclaims the slot, timeout fires).
#
# The trace `ARW` (Agent constructed -> Resolved -> Wrapped up) + AGENT-ASYNC-API-OK (result 42 ==
# read(5) + sum(35)->37) proves both awaits resolved over the API and the cancel reclaimed the slot.
#
# Usage: tools/proc/agent-async-api-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/agent_async_demo.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agent-async-api-test" || echo "agent-async-api-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$SHARED" "$WORK/shared.o" "$WORK/rt"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/demo.o" $SUPPORT_OBJ -o "$WORK/agent.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/agent.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "ARW" \
   && printf '%s' "$OUT" | grep -q "AGENT-ASYNC-API-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: an async fn agent ran 'let a = await read_async(...); let b = await tool_call_async(...)' over the agent-facing API (ToolFut/ToolPump), then slept (sleep_async->E_TIMEDOUT) and timed-out-then-cancelled a request (cancel reclaimed the broker slot, inflight back to 0) — ARW, AGENT-ASYNC-API-OK (result 42) — under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected ARW and AGENT-ASYNC-API-OK in kernel output"
exit 1
