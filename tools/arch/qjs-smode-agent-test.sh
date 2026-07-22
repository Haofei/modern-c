#!/usr/bin/env bash
# M3 (M3b): run a PURE-JS AGENT confined under REAL OpenSBI in S-mode. The S-mode analogue of
# tools/lang/qjs-agent-test.sh: the agent is JavaScript (examples/agents/agent.js by default), the
# C host (examples/apps/qjs_host.c) is FIXED and generic, and the agent does async host I/O over
# SYS_SUBMIT/SYS_POLL with back-pressure. The agent ELF (host + embedded engine + all-MC libc +
# openlibm, §0 ingress via SYS_READ) is built IDENTICALLY to the M-mode harness; only the KERNEL
# side changes to the S-mode pieces, and QEMU runs the real OpenSBI firmware (no `-bios none`):
#   USERMODE -> smode_usermode_runtime.c   (S-mode trap vector + ecall dispatch through mc_syscall)
#   RUNTIME  -> qjs_smode_confined_runtime.c (S-mode OpenSBI bring-up: build space, satp, enter_user)
#   SRC      -> qjs_smode_demo.mc           (app_run_demo's loader/ABI + supervisor kernel gigapage)
#   LDSCRIPT -> tests/qemu/sbi.ld           (OpenSBI payload @ 0x80200000)
# The async agent uses POLLED non-blocking SUBMIT/POLL (not interrupts), so the M3a S-mode trap
# dispatch already serves it — no UART-RX IRQ needed. PASS requires the OpenSBI banner +
# confinement + the agent's EXPECT line + U-mode exit. The kernel is mapped supervisor-only
# (unreachable from U), so it remains unmapped from the agent.
#
# Usage: tools/arch/qjs-smode-agent-test.sh <path-to-mcc> [c|llvm] [agent.js] [expect-substring] [name]
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
AGENT_JS_REL="${3:-examples/agents/agent.js}"
EXPECT="${4:-agent: done}"
NAME_BASE="${5:-qjs-smode-agent}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/arch/qjs_smode_demo.mc"                     # kernel side (S-mode): loader/ABI + supervisor gigapage + UART page
RUNTIME="$HERE/tests/qemu/arch/qjs_smode_confined_runtime.mc"  # S-mode bring-up under OpenSBI, now PURE MC
USERMODE="$HERE/tests/qemu/arch/smode_usermode_runtime.mc"     # S-mode trap vector + syscall dispatch
CTX_STUBS="$HERE/tests/qemu/mem/proc_ctx_stubs.mc"             # link-only process context externs
HOST="$HERE/examples/apps/qjs_host.c"        # the FIXED generic host (never changes per agent)
AGENT_JS="$HERE/$AGENT_JS_REL"               # the agent: PURE JS
LDSCRIPT="$HERE/tests/qemu/sbi.ld"           # OpenSBI payload @ 0x80200000
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. The confined U-mode agent ELF: fixed host + embedded JS agent + engine + all-MC libc ----
#         (IDENTICAL to the M-mode qjs-agent-test.sh — only the kernel side differs below.)
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
# QuickJS engine objects: build once per (compiler+flags), cached + cp'd in (build-qjs.sh).
bash "$HERE/tools/user/build-qjs.sh" "$WORK" "$CLANG" "${APP_CFLAGS[@]}"
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HOST" -o "$WORK/host.o"
# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS.
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

# §0 ingress: embed the PURE-JS agent into the KERNEL and serve it via SYS_READ. The host ELF
# stays fixed/generic — shipping a new agent changes only this .js, never the host. A STRONG
# mc_agent_source here overrides the weak default in qjs_smode_confined_runtime.c.
{
    printf 'static const char agent_js[] = {'
    od -An -v -tx1 "$AGENT_JS" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js;\n'
    printf '    return (unsigned long)agent_js;\n}\n'
} >"$WORK/agent_src.c"

# Integer-only kernel (the loader/ABI/confinement), linked at the OpenSBI payload address. The
# S-mode runtime owns _start and routes console + power through SBI (no context_runtime.c).
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$CTX_STUBS" "$WORK/ctx_stubs.o" "$WORK"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/ctx_stubs.o" \
    "$WORK/app_image.o" "$WORK/agent_src.o" $K_SUPPORT -o "$WORK/kernel.elf"

# Real OpenSBI (the default firmware): NO `-bios none`. OpenSBI boots our kernel in S-mode.
OUT="$(timeout 120 "$QEMU" -machine virt -nographic -m 256M \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- OpenSBI + kernel UART output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

# PASS requires: OpenSBI actually ran (banner) — proves S-mode under the real firmware; the
# kernel is mapped supervisor-only (CONFINED — unreachable from U) in the agent's space; the
# pure-JS agent ran in U-mode and printed its EXPECT line (host I/O over SYS_SUBMIT/SYS_POLL);
# and the agent left U-mode via SYS_EXIT.
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "CONFINED: kernel not user-accessible in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran a PURE-JS agent (the C host is fixed/generic) confined in an isolated U-mode Sv39 space under REAL OpenSBI in S-mode, with async host I/O over SYS_SUBMIT/SYS_POLL; the kernel is mapped supervisor-only (unreachable from U) and the agent reached it only via ecall"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + 'CONFINED...', '$EXPECT', and 'USER-EXIT from U'"
exit 1
