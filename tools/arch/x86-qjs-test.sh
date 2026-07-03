#!/usr/bin/env bash
# M7 "confined QuickJS agent on x86_64 ring-3". The x86-64 analogue of tools/arch/qjs-smode-agent-test.sh
# (RISC-V M3) and a sibling of tools/arch/x86-user-test.sh (M6).
#
# Builds the SAME confined QuickJS user ELF the riscv harness builds — the FIXED generic C host
# (examples/apps/qjs_host.c) + an embedded PURE-JS agent + QuickJS + the all-MC libc + openlibm —
# but for x86_64: the only arch-specific user-side pieces are crt0_x86.c (the int-0x80 ecall +
# _start) and app_traps_x86.c (the trap-edge exit), linked with user_qjs_x86.ld. SSE is on (x86_64
# default; QuickJS double math needs it, and the M6 ring-3 path inherits CR4.OSFXSR from boot.S).
#
# The KERNEL side is the M6 ring-3 machinery extended for the agent: kernel/arch/x86_64/boot.S +
# qjs_user_runtime.c (GDT/TSS/IDT + int-0x80 dispatch through mc_syscall + enter_user) and the MC
# fixture tests/x86/qjs_x86_demo.mc (the x86 elf_loader/uaccess/paging loader + the QuickJS syscall
# ABI + mock broker + the kernel supervisor-only identity window). Boots qemu-system-x86_64; reports
# over COM1; PASS requires CONFINED + the agent's EXPECT line + USER-EXIT.
#
# Usage: tools/arch/x86-qjs-test.sh <path-to-mcc> [c|llvm] [agent.js] [expect-substring] [name]
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
AGENT_JS_REL="${3:-examples/agents/agent.js}"
EXPECT="${4:-agent: done}"
NAME_BASE="${5:-x86-qjs}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
ARCH="$HERE/kernel/arch/x86_64"
QJS="$HERE/third_party/quickjs"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the riscv gates.
# (kernel-boot-lib is also re-sourced below for its compile helpers; sourcing twice is harmless.)
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$OBJCOPY" >/dev/null 2>&1 || skip "llvm-objcopy not found"
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"

# kernel-boot-lib gives us the MC-object compile helpers (emit-c / mcc-llvm-cc) the riscv qjs
# harness uses; we reuse them so the C/LLVM backend selection is identical.
source "$(CDPATH= cd -- "$HERE/tools/qemu" && pwd)/kernel-boot-lib.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HOST="$HERE/examples/apps/qjs_host.c"
AGENT_JS="$HERE/$AGENT_JS_REL"

# ---- 1. The confined ring-3 QuickJS agent ELF: fixed host + embedded JS + engine + all-MC libc ----
#         SSE on (x86_64 default); the arch-specific user pieces are crt0_x86 + app_traps_x86.
APP_CFLAGS=(--target=x86_64-unknown-elf
            -nostdlib -ffreestanding -fno-pic -fno-pie -mno-red-zone -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
# QuickJS engine objects: build once per (compiler+flags), cached + cp'd in (build-qjs.sh).
bash "$HERE/tools/user/build-qjs.sh" "$WORK" "$CLANG" "${APP_CFLAGS[@]}"
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HOST" -o "$WORK/host.o"
# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS (app_traps.mc is the
# arch-neutral stdout/stderr/stdin shim, shared across all arches).
"$MCC" emit-c "$HERE/user/runtime/crt0_x86.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"
# openlibm's amd64 lrint/rint-family reaches out-of-line fenv ops (feholdexcept/feupdateenv/...)
# whose amd64 source was not vendored; provide freestanding SSE-MXCSR stubs (JS Math needs no FP
# exception semantics). On riscv these were inline in the header, so no equivalent file existed.
"$CLANG" "${APP_CFLAGS[@]}" -c "$HERE/user/runtime/fenv_amd64_stub.c" -o "$WORK/fenv.o"

# The all-MC libc + the U-mode syscall shim. emit-c is arch-neutral, so for the C backend we
# emit C and compile it with the x86 APP_CFLAGS; for LLVM we drive mcc-llvm-cc.sh with the x86
# triple directly (the riscv kernel_boot_compile_mc_object helper hardcodes the riscv triple, so
# it cannot serve the x86 user side).
build_user_mc() { # <src.mc> <out.o>
    local src="$1" out="$2"
    case "$BACKEND" in
      c)
        "$MCC" emit-c "$src" > "$WORK/mc.c"
        $CLANG "${APP_CFLAGS[@]}" -Wno-switch-bool -c "$WORK/mc.c" -o "$out"
        ;;
      llvm)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" \
          -mtriple=x86_64-unknown-elf -relocation-model=static -code-model=small
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

# openlibm (the double-precision libm QuickJS Math needs), built freestanding for x86_64. The
# vendored build-openlibm.sh is riscv-only, so compile the archive inline here with x86 flags.
OLM="$HERE/third_party/openlibm"
OLM_CFLAGS=(--target=x86_64-unknown-elf -nostdlib -ffreestanding -fno-pic -fno-pie -mno-red-zone
            -O2 -fno-builtin -DASSEMBLER=0 -I"$OLM/include" -I"$OLM/src" -I"$OLM")
mkdir -p "$WORK/olm"
for f in "$OLM"/src/*.c; do
    b="$(basename "$f" .c)"
    "$CLANG" "${OLM_CFLAGS[@]}" -c "$f" -o "$WORK/olm/$b.o" 2>/dev/null || true
done
"${LLVM_AR:-llvm-ar}" rcs "$WORK/libm.a" "$WORK"/olm/*.o

"$LLD" -T "$HERE/user/runtime/user_qjs_x86.ld" \
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

# ---- 3. The multiboot kernel: boot.S + qjs_user_runtime.c + the MC fixture (integer-only) ----
KCF="--target=x86_64-unknown-elf -ffreestanding -fno-pic -fno-pie -mno-red-zone -nostdlib -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
case "$BACKEND" in
  c)
    # --arch=x86_64 resolves the fixture's `kernel/arch/active/...` (uaccess_pt) to x86 paging.
    "$MCC" emit-c "$HERE/tests/x86/qjs_x86_demo.mc" --arch=x86_64 > "$WORK/fixture.c"
    $CLANG $KCF -Wno-switch-bool -c "$WORK/fixture.c" -o "$WORK/fixture.o"
    SUPPORT_OBJ=
    ;;
  llvm)
    MC_ARCH=x86_64 MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/qjs_x86_demo.mc" -o "$WORK/fixture.o" \
      -mtriple=x86_64-unknown-elf -relocation-model=static -code-model=kernel
    $CLANG $KCF -x c -c /dev/null -o "$WORK/llvm-support.o"
    SUPPORT_OBJ="$WORK/llvm-support.o"
    ;;
  *) echo "unknown kernel backend: $BACKEND" >&2; exit 2 ;;
esac
# The kernel-side runtime is now PURE MC (tests/x86/qjs_user_x86_runtime.mc); lower it through
# the selected backend with the x86 triple, exactly like the fixture above.
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/qjs_user_x86_runtime.mc" > "$WORK/qjs_runtime.c"
    $CLANG $KCF -Wno-switch-bool -c "$WORK/qjs_runtime.c" -o "$WORK/qjs_runtime.o"
    ;;
  llvm)
    MC_ARCH=x86_64 MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/qjs_user_x86_runtime.mc" -o "$WORK/qjs_runtime.o" \
      -mtriple=x86_64-unknown-elf -relocation-model=static -code-model=kernel
    ;;
esac
$CLANG --target=x86_64-unknown-elf -ffreestanding -c "$ARCH/boot.S" -o "$WORK/boot.o"
$CLANG $KCF -c "$WORK/app_image.c" -o "$WORK/app_image.o"
$CLANG $KCF -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
# Freestanding mem*: the pure-MC runtime's emit-c lowering calls memset/memcpy for aggregate
# init/copy (the old C runtime had clang inline them); link the shared arch-neutral object.
"$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$WORK/freestanding_gen.c" # freestanding mem* is now pure MC
$CLANG $KCF -fno-builtin -c "$WORK/freestanding_gen.c" -o "$WORK/freestanding.o"
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" \
    "$WORK/boot.o" "$WORK/qjs_runtime.o" "$WORK/fixture.o" \
    "$WORK/app_image.o" "$WORK/agent_src.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"

OUT="$(timeout 120 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot -m 256M \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"

echo "--- x86 QuickJS-agent kernel serial output ---"
printf '%s\n' "$OUT"
echo "----------------------------------------------"

# PASS requires: the kernel is mapped supervisor-only (CONFINED — unreachable from ring 3) in the
# agent's space; the pure-JS agent ran in ring 3 and printed its EXPECT line (host I/O over the
# full SYS_WRITE/READ/SUBMIT/POLL ABI); and the agent left ring 3 via SYS_EXIT.
if printf '%s' "$OUT" | grep -qa "CONFINED: kernel mapped supervisor-only" \
   && printf '%s' "$OUT" | grep -qa "$EXPECT" \
   && printf '%s' "$OUT" | grep -qa "USER-EXIT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran a PURE-JS agent (the C host is fixed/generic) confined in an isolated x86-64 ring-3 space under QEMU, with async host I/O over int-0x80 SYS_SUBMIT/SYS_POLL; the kernel is mapped supervisor-only (unreachable from ring 3) and the agent reached it only via int 0x80"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED: kernel mapped supervisor-only', '$EXPECT', and 'USER-EXIT'"
exit 1
