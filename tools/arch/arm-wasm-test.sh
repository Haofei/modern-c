#!/usr/bin/env bash
# WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): a confined WASM agent on AArch64 EL0 — the
# cross-arch WASM peer of tools/arch/arm-qjs-test.sh. Builds the SAME confined EL0 agent ELF the
# RISC-V/x86 WASM harnesses build (wasm3 + WASI P1 shim + wasm_host + all-MC libc + openlibm, running
# an embedded stock wasm32-wasi guest), but for aarch64: the arch-specific user pieces are
# crt0_aarch64 + app_traps + fenv_aarch64_stub, linked with user_qjs_aarch64.ld. The KERNEL side is
# the existing aarch64 EL0 agent machinery (tests/arm/qjs_arm_demo.mc + qjs_user_arm_runtime.mc) —
# unchanged, agent-agnostic. Boots qemu-system-aarch64 'virt'; PASS requires CONFINED (EL1-only) +
# the guest's marker + USER-EXIT.
#
# Usage: tools/arch/arm-wasm-test.sh <mcc> [c|llvm] [guest.c] [expect] [name-base] [wasi|qjs]
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wasm/wasi_async.c}"
EXPECT="${4:-async: ok}"
NAME_BASE="${5:-arm-wasm-async}"
GUEST_KIND="${6:-wasi}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; ZIG="${ZIG:-zig}"; QEMU="${QEMU:-qemu-system-aarch64}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
W3="$HERE/third_party/wasm3/source"
WASMDIR="$HERE/examples/apps/wasm"
HOST="$HERE/examples/apps/wasm_host.c"
SHIM="$WASMDIR/wasi_shim.c"
QJS="$HERE/third_party/quickjs"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"   >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$QEMU"  >/dev/null 2>&1 || skip "$QEMU not found"
command -v "$ZIG"   >/dev/null 2>&1 || skip "zig not found"
"$CLANG" --print-targets 2>/dev/null | grep -q aarch64 || skip "clang has no aarch64 target"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then echo "KEEP_WORK: $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi

# ---- 0. The guest: a wasm32-wasi binary (off-the-shelf zig + wasi-libc) ----
if [ "$GUEST_KIND" = qjs ]; then
    "$ZIG" cc -target wasm32-wasi -O2 -s -I"$QJS" -D__wasi__ -Wl,-z,stack-size=524288 \
        "$HERE/$GUEST_REL" "$QJS"/dtoa.c "$QJS"/libunicode.c "$QJS"/libregexp.c "$QJS"/quickjs.c \
        -o "$WORK/guest.wasm"
else
    "$ZIG" cc -target wasm32-wasi -O2 -s -Wl,-z,stack-size=262144 "$HERE/$GUEST_REL" -o "$WORK/guest.wasm"
fi
{
    echo "const unsigned char wasm_blob[] = {"
    od -An -v -tu1 "$WORK/guest.wasm" | awk '{ for (i = 1; i <= NF; i++) printf "%s,", $i }'
    echo "};"
    echo "const unsigned int wasm_blob_len = sizeof(wasm_blob);"
} > "$WORK/wasm_blob.h"

# ---- 1. The confined EL0 host ELF (FP/NEON on; armv8-a default FPU) ----
APP_CFLAGS=(--target=aarch64-unknown-elf -march=armv8-a
            -nostdlib -ffreestanding -fno-pic -fno-pie -O1
            -fno-builtin -I"$HERE/user/libc/include")
W3FLAGS=(--target=aarch64-unknown-elf -march=armv8-a
         -nostdlib -ffreestanding -fno-pic -fno-pie -O2
         -fno-strict-aliasing -fno-builtin -I"$HERE/user/libc/include" -I"$W3")

for f in m3_bind m3_code m3_compile m3_core m3_env m3_exec m3_function m3_module m3_parse; do
    "$CLANG" "${W3FLAGS[@]}" -c "$W3/$f.c" -o "$WORK/$f.o"
done
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -c "$SHIM" -o "$WORK/wasi_shim.o"
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

"$MCC" emit-c "$HERE/user/runtime/crt0_aarch64.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"
"$CLANG" "${APP_CFLAGS[@]}" -c "$HERE/user/runtime/fenv_aarch64_stub.c" -o "$WORK/fenv.o"

# The all-MC libc + the U-mode syscall shim, lowered for aarch64 through the selected backend.
build_user_mc() { # <src.mc> <out.o>
    local src="$1" out="$2"
    case "$BACKEND" in
      c)
        "$MCC" emit-c "$src" > "$WORK/mc.c"
        $CLANG "${APP_CFLAGS[@]}" -Wno-switch-bool -c "$WORK/mc.c" -o "$out" ;;
      llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" \
          -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small ;;
    esac
}
build_user_mc "$HERE/user/libc/libc.mc" "$WORK/libc.o"
build_user_mc "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o"
APP_SUPPORT=
if [ "$BACKEND" = llvm ]; then
    $CLANG "${APP_CFLAGS[@]}" -x c -c /dev/null -o "$WORK/app-support.o"; APP_SUPPORT="$WORK/app-support.o"
fi

# openlibm (double-precision libm), built freestanding for aarch64 (the vendored script is riscv-only).
OLM="$HERE/third_party/openlibm"
OLM_CFLAGS=(--target=aarch64-unknown-elf -march=armv8-a -nostdlib -ffreestanding -fno-pic -fno-pie
            -O2 -fno-builtin -DASSEMBLER=0 -I"$OLM/include" -I"$OLM/src" -I"$OLM")
mkdir -p "$WORK/olm"
for f in "$OLM"/src/*.c; do
    b="$(basename "$f" .c)"; "$CLANG" "${OLM_CFLAGS[@]}" -c "$f" -o "$WORK/olm/$b.o" 2>/dev/null || true
done
"${LLVM_AR:-llvm-ar}" rcs "$WORK/libm.a" "$WORK"/olm/*.o

# -z max-page-size=0x1000 -z norelro: 4 KiB-disjoint PT_LOAD segments for the 4 KiB-granule loader.
"$LLD" -z max-page-size=0x1000 -z norelro -T "$HERE/user/runtime/user_qjs_aarch64.ld" \
    "$WORK/crt0.o" "$WORK/host.o" "$WORK/wasi_shim.o" \
    "$WORK/m3_bind.o" "$WORK/m3_code.o" "$WORK/m3_compile.o" "$WORK/m3_core.o" \
    "$WORK/m3_env.o" "$WORK/m3_exec.o" "$WORK/m3_function.o" "$WORK/m3_module.o" "$WORK/m3_parse.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" "$WORK/fenv.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the host ELF (the wasm guest is baked into host.o via wasm_blob.h; no §0 ingress) ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
} >"$WORK/app_image.c"

# ---- 3. The flat aarch64 kernel: qjs_user_arm_runtime.mc + the MC fixture (integer-only) ----
KCF=(--target=aarch64-unknown-elf -march=armv8-a -ffreestanding -nostdlib -fno-pic -fno-pie -mgeneral-regs-only -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function)
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/arm/qjs_arm_demo.mc" --arch=aarch64 > "$WORK/fixture.c"
    $CLANG "${KCF[@]}" -Wno-switch-bool -c "$WORK/fixture.c" -o "$WORK/fixture.o"; SUPPORT_OBJ= ;;
  llvm)
    MC_ARCH=aarch64 MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/qjs_arm_demo.mc" -o "$WORK/fixture.o" \
      -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small -mattr=-neon
    $CLANG "${KCF[@]}" -x c -c /dev/null -o "$WORK/llvm-support.o"; SUPPORT_OBJ="$WORK/llvm-support.o" ;;
  *) echo "unknown kernel backend: $BACKEND" >&2; exit 2 ;;
esac
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/arm/qjs_user_arm_runtime.mc" > "$WORK/qjs_runtime.c"
    $CLANG "${KCF[@]}" -Wno-switch-bool -c "$WORK/qjs_runtime.c" -o "$WORK/qjs_runtime.o" ;;
  llvm)
    MC_ARCH=aarch64 MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/qjs_user_arm_runtime.mc" -o "$WORK/qjs_runtime.o" \
      -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small -mattr=-neon ;;
esac
$CLANG "${KCF[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
"$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$WORK/freestanding_gen.c"
$CLANG "${KCF[@]}" -fno-builtin -c "$WORK/freestanding_gen.c" -o "$WORK/freestanding.o"
$LLD -T "$HERE/tests/arm/aarch64-user.ld" \
    "$WORK/qjs_runtime.o" "$WORK/fixture.o" \
    "$WORK/app_image.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/k.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -cpu cortex-a72 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"

echo "--- aarch64 WASM-agent kernel UART ---"
printf '%s\n' "$OUT"
echo "--------------------------------------"

if printf '%s' "$OUT" | grep -qa "CONFINED: kernel mapped EL1-only" \
   && printf '%s' "$OUT" | grep -qa "$EXPECT" \
   && printf '%s' "$OUT" | grep -qa "USER-EXIT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran a STOCK wasm32-wasi guest on wasm3 confined in an isolated aarch64 EL0 space under QEMU, with async host I/O over svc SYS_SUBMIT/SYS_POLL; the kernel is mapped EL1-only (unreachable from EL0) and the agent reached it only via svc #0"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED: kernel mapped EL1-only', '$EXPECT', and 'USER-EXIT'"
exit 1
