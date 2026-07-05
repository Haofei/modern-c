#!/usr/bin/env bash
# qjs-agent-smoke-test — THE canonical "agent async smoke" gate: ONE confined PURE-JS agent that, in
# a single run, walks the WHOLE async-agent happy path and prints a single deterministic token
# `AGENT-SMOKE-OK` only if every stage produced its expected result. The stages are:
#   1. host_call  — a SUM tool call that RESOLVES (op = arg+2 -> host_call(7)=9)
#   2. host_fs_read — a REAL capability-checked FS read that RESOLVES with bytes ("hi" round-trip)
#   3. host_sleep — an async TIMEOUT raced against its deadline (fired timer == structured ETIMEDOUT)
#   4. cancel — a CANCEL of an in-flight request (rejects structured ECANCELED, reclaims the slot)
# then the host event loop drains to inflight=0 with NO "unknown completion id". The agent is
# examples/agents/agent_smoke.js; the C host (examples/apps/qjs_host.c) is FIXED and generic.
#
# Usage: tools/lang/qjs-agent-smoke-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
AGENT_JS_REL="examples/agents/agent_smoke.js"
NAME_BASE="qjs-agent-smoke"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
RUNTIME="$HERE/tests/qemu/lang/qjs_confined_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
HOST="$HERE/examples/apps/qjs_host.c"        # the FIXED generic host (never changes per agent)
AGENT_JS="$HERE/$AGENT_JS_REL"               # the agent: PURE JS
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. The confined U-mode agent ELF: fixed host + embedded JS agent + engine + all-MC libc ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
# QuickJS engine objects: build once per (compiler+flags), cached + cp'd in (build-qjs.sh).
bash "$HERE/tools/user/build-qjs.sh" "$WORK" "$CLANG" "${APP_CFLAGS[@]}"
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HOST" -o "$WORK/host.o"
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

CFLAGS=("${APP_CFLAGS[@]}")
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/host.o" \
    "$WORK/dtoa.o" "$WORK/libunicode.o" "$WORK/libregexp.o" "$WORK/quickjs.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the agent ELF + build the kernel (loader/ABI/confinement) ----
APP_HASH="$(python3 - "$WORK/agent.elf" <<'PY'
import pathlib
import sys
h = 0x811c9dc5
for b in pathlib.Path(sys.argv[1]).read_bytes():
    h = ((h ^ b) * 0x01000193) & 0xffffffff
print(h)
PY
)"
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'const unsigned long long app_image_hash = %sULL;\n' "$APP_HASH"
} >"$WORK/app_image.c"

{
    printf 'static const char agent_js[] = {'
    od -An -v -tx1 "$AGENT_JS" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js;\n'
    printf '    return (unsigned long)agent_js;\n}\n'
} >"$WORK/agent_src.c"

KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" "$WORK/agent_src.o" $K_SUPPORT -o "$WORK/kernel.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# Assert the full smoke story: confinement held; each of the four stages produced its expected
# result (per-stage markers); the canonical token printed; the host loop drained to inflight=0 with
# NO unknown completion id; clean U-mode exit.
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "smoke-agent: stage1 resolved v=9" \
   && printf '%s' "$OUT" | grep -q "smoke-agent: stage2 read=hi" \
   && printf '%s' "$OUT" | grep -q "smoke-agent: stage3 slept (timer fired) name=ETIMEDOUT" \
   && printf '%s' "$OUT" | grep -q "smoke-agent: stage4 cancel rejected code=-125 name=ECANCELED" \
   && printf '%s' "$OUT" | grep -q "AGENT-SMOKE-OK" \
   && printf '%s' "$OUT" | grep -q "host: inflight=0 (all slots reclaimed)" \
   && ! printf '%s' "$OUT" | grep -q "host: unknown completion id" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "QJS-AGENT-SMOKE-OK"
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined PURE-JS agent walked the whole async happy path (host_call resolve + FS read + timeout + cancel) and the broker slots were reclaimed (inflight=0)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected confinement + all four stages + AGENT-SMOKE-OK + inflight=0 + clean exit (no unknown-completion)"
exit 1
