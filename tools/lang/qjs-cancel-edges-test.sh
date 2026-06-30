#!/usr/bin/env bash
# qjs-cancel-edges-test — NEGATIVE cancellation-edge gate (item 4) at the JS/host layer. A confined
# PURE-JS agent (examples/agents/agent_cancel_edges.js) proves each degenerate cancel is HARMLESS:
#   (a) cancel AFTER completion        -> host_cancel(id) of a completed id returns -E_DENIED, no
#                                         second rejection.
#   (c) FAILED-submit cancel           -> a back-pressure-rejected submit left g_last_id=-1, so its
#                                         cancel() targets nothing (-E_DENIED), harmlessly.
#   (d) LATE completion after cancel    -> cancel one of two overlapping requests; the sibling still
#                                         resolves and the run reaches inflight=0 with NO unknown id.
#   (e) host_fs_read non-empty payload -> a real FS read resolves with a non-empty string.
# Each edge prints a distinct deterministic marker; the gate fails if any is missing, and the host
# must NOT hit its fatal "unknown completion id" path and must drain to inflight=0. The C host
# (examples/apps/qjs_host.c) is FIXED and generic.
#
# Usage: tools/lang/qjs-cancel-edges-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
AGENT_JS_REL="examples/agents/agent_cancel_edges.js"
NAME_BASE="qjs-cancel-edges"
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
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
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

# Assert every negative cancellation edge produced its distinct marker; the host never hit its fatal
# unknown-completion path; the loop drained to inflight=0; clean U-mode exit.
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "edges: A post-complete cancel denied rc=-13" \
   && printf '%s' "$OUT" | grep -q "edges: A no second settle" \
   && printf '%s' "$OUT" | grep -q "edges: C failed-submit cancel hit nothing rc=-13" \
   && printf '%s' "$OUT" | grep -q "edges: D slow cancelled name=ECANCELED" \
   && printf '%s' "$OUT" | grep -q "edges: D both settled no unknown id" \
   && printf '%s' "$OUT" | grep -q "edges: E fs_read non-empty" \
   && printf '%s' "$OUT" | grep -q "host: inflight=0 (all slots reclaimed)" \
   && ! printf '%s' "$OUT" | grep -q "host: unknown completion id" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "QJS-CANCEL-EDGES-OK"
    echo "PASS: $TEST_NAME — $BACKEND backend: post-completion cancel denied, failed-submit cancel hit nothing, late completion produced no unknown id, FS read non-empty; slots reclaimed (inflight=0)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected edges (a)(c)(d)(e) markers + no unknown-completion + inflight=0 + clean exit"
exit 1
