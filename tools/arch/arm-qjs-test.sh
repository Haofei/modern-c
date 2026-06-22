#!/usr/bin/env bash
# M9 "confined QuickJS agent on AArch64 EL0". The AArch64 analogue of tools/arch/x86-qjs-test.sh
# (x86 M7) and tools/arch/qjs-smode-agent-test.sh (RISC-V M3), and a sibling of
# tools/arch/arm-user-test.sh (M8).
#
# Builds the SAME confined QuickJS user ELF the x86/riscv harnesses build — the FIXED generic C
# host (examples/apps/qjs_host.c) + an embedded PURE-JS agent + QuickJS + the all-MC libc +
# openlibm — but for aarch64: the only arch-specific user-side pieces are crt0_aarch64.c (the
# svc #0 ecall + _start), app_traps_aarch64.c (the trap-edge exit) and fenv_aarch64_stub.c
# (openlibm's one out-of-line fenv symbol), linked with user_qjs_aarch64.ld. FP/NEON is on
# (-march=armv8-a, default FPU; QuickJS double math needs it, and the kernel sets CPACR FPEN).
#
# The KERNEL side is the M8 EL0 machinery extended for the agent: kernel/arch/aarch64/
# qjs_user_runtime.c (VBAR + EL1 vectors + svc dispatch through mc_syscall + enter_user, CPACR
# FPEN, MAIR/TCR/MMU) and the MC fixture tests/arm/qjs_arm_demo.mc (the aarch64 elf_loader/uaccess/
# paging loader + the QuickJS syscall ABI + mock broker + the kernel RAM/UART EL1-only window).
# Boots qemu-system-aarch64 'virt' (cortex-a72); reports over the PL011 UART; PASS requires
# CONFINED + the agent's EXPECT line + USER-EXIT.
#
# Usage: tools/arch/arm-qjs-test.sh <path-to-mcc> [c|llvm] [agent.js] [expect-substring] [name]
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
AGENT_JS_REL="${3:-examples/agents/agent.js}"
EXPECT="${4:-agent: done}"
NAME_BASE="${5:-arm-qjs}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-aarch64}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
ARCH="$HERE/kernel/arch/aarch64"
QJS="$HERE/third_party/quickjs"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the riscv gates.
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q aarch64 || skip "clang has no aarch64 target"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HOST="$HERE/examples/apps/qjs_host.c"
AGENT_JS="$HERE/$AGENT_JS_REL"

# ---- 1. The confined EL0 QuickJS agent ELF: fixed host + embedded JS + engine + all-MC libc ----
#         FP/NEON on (armv8-a default); the arch-specific user pieces are crt0/app_traps/fenv.
APP_CFLAGS=(--target=aarch64-unknown-elf -march=armv8-a
            -nostdlib -ffreestanding -fno-pic -fno-pie -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
for f in dtoa libunicode libregexp quickjs; do
    "$CLANG" "${APP_CFLAGS[@]}" -c "$QJS/$f.c" -o "$WORK/$f.o"
done
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HOST" -o "$WORK/host.o"
# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS (app_traps.mc is the
# arch-neutral stdout/stderr/stdin shim, shared across all arches).
"$MCC" emit-c "$HERE/user/runtime/crt0_aarch64.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"
# openlibm's aarch64 fenv ops are inline (like riscv), but it declares ONE external symbol —
# __fe_dfl_env (the default FP environment). Provide it (all-zero == round-nearest, masked).
"$CLANG" "${APP_CFLAGS[@]}" -c "$HERE/user/runtime/fenv_aarch64_stub.c" -o "$WORK/fenv.o"

# The all-MC libc + the U-mode syscall shim. emit-c is arch-neutral, so for the C backend we
# emit C and compile it with the aarch64 APP_CFLAGS; for LLVM we drive mcc-llvm-cc.sh with the
# aarch64 triple directly.
build_user_mc() { # <src.mc> <out.o>
    local src="$1" out="$2"
    case "$BACKEND" in
      c)
        "$MCC" emit-c "$src" > "$WORK/mc.c"
        $CLANG "${APP_CFLAGS[@]}" -Wno-switch-bool -c "$WORK/mc.c" -o "$out"
        ;;
      llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" \
          -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small
        ;;
    esac
}
build_user_mc "$HERE/user/libc/libc.mc" "$WORK/libc.o"
build_user_mc "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o"
APP_SUPPORT=
if [ "$BACKEND" = llvm ]; then
    $CLANG "${APP_CFLAGS[@]}" -x c -c /dev/null -o "$WORK/app-support.o"
    APP_SUPPORT="$WORK/app-support.o"
fi

# openlibm (the double-precision libm QuickJS Math needs), built freestanding for aarch64. The
# vendored build-openlibm.sh is riscv-only, so compile the archive inline here with aarch64 flags.
OLM="$HERE/third_party/openlibm"
OLM_CFLAGS=(--target=aarch64-unknown-elf -march=armv8-a -nostdlib -ffreestanding -fno-pic -fno-pie
            -O2 -fno-builtin -DASSEMBLER=0 -I"$OLM/include" -I"$OLM/src" -I"$OLM")
mkdir -p "$WORK/olm"
for f in "$OLM"/src/*.c; do
    b="$(basename "$f" .c)"
    "$CLANG" "${OLM_CFLAGS[@]}" -c "$f" -o "$WORK/olm/$b.o" 2>/dev/null || true
done
"${LLVM_AR:-llvm-ar}" rcs "$WORK/libm.a" "$WORK"/olm/*.o

# lld defaults to a 64 KiB max page size on aarch64 and, with RELRO, emits the GOT as its OWN
# read-only PT_LOAD segment that begins mid-page and shares one 4 KiB page with the preceding
# .rodata segment. Our 4 KiB-granule elf_loader maps each segment's page span and rejects a
# double-map (W^X / AlreadyMapped), so:
#   -z max-page-size=0x1000 forces 4 KiB segment alignment (matches x86/riscv's default), and
#   -z norelro folds the GOT into the writable .data segment (the link script captures .got there),
# giving every PT_LOAD disjoint 4 KiB pages.
"$LLD" -z max-page-size=0x1000 -z norelro -T "$HERE/user/runtime/user_qjs_aarch64.ld" \
    "$WORK/crt0.o" "$WORK/host.o" \
    "$WORK/dtoa.o" "$WORK/libunicode.o" "$WORK/libregexp.o" "$WORK/quickjs.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" "$WORK/fenv.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the agent ELF + the PURE-JS agent (served via SYS_READ §0 ingress) ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
} >"$WORK/app_image.c"

# §0 ingress: a STRONG mc_agent_source (the embedded JS) overrides the weak default in
# qjs_user_runtime.c. The host ELF stays fixed/generic — shipping a new agent changes only this .js.
{
    printf 'static const char agent_js[] = {'
    od -An -v -tx1 "$AGENT_JS" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js;\n'
    printf '    return (unsigned long)agent_js;\n}\n'
} >"$WORK/agent_src.c"

# ---- 3. The flat aarch64 kernel: qjs_user_runtime.c + the MC fixture (integer-only) ----
KCF=(--target=aarch64-unknown-elf -march=armv8-a -ffreestanding -nostdlib -fno-pic -fno-pie -mgeneral-regs-only -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function)
case "$BACKEND" in
  c)
    # --arch=aarch64 resolves the fixture's `kernel/arch/active/...` (uaccess_pt) to ARM paging.
    "$MCC" emit-c "$HERE/tests/arm/qjs_arm_demo.mc" --arch=aarch64 > "$WORK/fixture.c"
    $CLANG "${KCF[@]}" -Wno-switch-bool -c "$WORK/fixture.c" -o "$WORK/fixture.o"
    SUPPORT_OBJ=
    ;;
  llvm)
    MC_ARCH=aarch64 MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/qjs_arm_demo.mc" -o "$WORK/fixture.o" \
      -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small
    $CLANG "${KCF[@]}" -x c -c /dev/null -o "$WORK/llvm-support.o"
    SUPPORT_OBJ="$WORK/llvm-support.o"
    ;;
  *) echo "unknown kernel backend: $BACKEND" >&2; exit 2 ;;
esac
# The kernel-side runtime is now PURE MC (tests/arm/qjs_user_arm_runtime.mc); lower it through
# the selected backend with the aarch64 triple, exactly like the fixture above.
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/arm/qjs_user_arm_runtime.mc" > "$WORK/qjs_runtime.c"
    $CLANG "${KCF[@]}" -Wno-switch-bool -c "$WORK/qjs_runtime.c" -o "$WORK/qjs_runtime.o"
    ;;
  llvm)
    MC_ARCH=aarch64 MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/qjs_user_arm_runtime.mc" -o "$WORK/qjs_runtime.o" \
      -mtriple=aarch64-unknown-elf -relocation-model=static -code-model=small
    ;;
esac
$CLANG "${KCF[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
$CLANG "${KCF[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
# Freestanding mem*: the pure-MC runtime's emit-c lowering calls memset/memcpy for aggregate
# init/copy (the old C runtime had clang inline them); link the shared arch-neutral object.
"$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$WORK/freestanding_gen.c" # freestanding mem* is now pure MC
$CLANG "${KCF[@]}" -fno-builtin -c "$WORK/freestanding_gen.c" -o "$WORK/freestanding.o"
$LLD -T "$HERE/tests/arm/aarch64-user.ld" \
    "$WORK/qjs_runtime.o" "$WORK/fixture.o" \
    "$WORK/app_image.o" "$WORK/agent_src.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/k.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -cpu cortex-a72 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"

echo "--- aarch64 QuickJS-agent kernel UART ---"
printf '%s\n' "$OUT"
echo "-----------------------------------------"

# PASS requires: the kernel is mapped EL1-only (CONFINED — unreachable from EL0) in the agent's
# space; the pure-JS agent ran in EL0 and printed its EXPECT line (host I/O over the full
# SYS_WRITE/READ/SUBMIT/POLL ABI); and the agent left EL0 via SYS_EXIT.
if printf '%s' "$OUT" | grep -qa "CONFINED: kernel mapped EL1-only" \
   && printf '%s' "$OUT" | grep -qa "$EXPECT" \
   && printf '%s' "$OUT" | grep -qa "USER-EXIT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran a PURE-JS agent (the C host is fixed/generic) confined in an isolated aarch64 EL0 space under QEMU, with async host I/O over svc SYS_SUBMIT/SYS_POLL; the kernel is mapped EL1-only (unreachable from EL0) and the agent reached it only via svc #0"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED: kernel mapped EL1-only', '$EXPECT', and 'USER-EXIT'"
exit 1
