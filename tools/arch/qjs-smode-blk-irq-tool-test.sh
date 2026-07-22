#!/usr/bin/env bash
# Pure-JS host_fs_read resolved through SYS_POLL from a real S-mode virtio-blk IRQ.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
AGENT_JS_REL="${3:-examples/agents/agent_blk_irq_tool.js}"
EXPECT="${4:-blk-irq: ok}"
NAME_BASE="${5:-qjs-smode-blk-irq-tool}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/arch/qjs_smode_demo.mc"
BLKIRQ="$HERE/tests/qemu/arch/app_run_blk_irq.mc"
RUNTIME="$HERE/tests/qemu/arch/qjs_smode_blk_irq_runtime.mc"
USERMODE="$HERE/tests/qemu/arch/smode_usermode_runtime.mc"
CTX_STUBS="$HERE/tests/qemu/mem/proc_ctx_stubs.mc"
PLATFORM="$HERE/kernel/arch/riscv64/sbi_dma_time.mc"
HOST="$HERE/examples/apps/qjs_host.c"
AGENT_JS="$HERE/$AGENT_JS_REL"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'unsigned long mc_app_image(void) { return (unsigned long)app_image; }\n'
    printf 'unsigned long mc_app_image_len(void) { return (unsigned long)app_image_len; }\n'
} >"$WORK/app_image.c"

{
    printf 'static const char agent_js[] = {'
    od -An -v -tx1 "$AGENT_JS" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js;\n'
    printf '    return (unsigned long)agent_js;\n'
    printf '}\n'
} >"$WORK/agent_src.c"

KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
mkdir -p "$WORK/app" "$WORK/blkirq" "$WORK/runtime" "$WORK/platform" "$WORK/ctx"
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/app.o" "$WORK/app"
kernel_boot_compile_mc_object "$BACKEND" "$BLKIRQ" "$WORK/blkirq.o" "$WORK/blkirq"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/runtime"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/platform"
kernel_boot_compile_mc_object "$BACKEND" "$CTX_STUBS" "$WORK/ctx_stubs.o" "$WORK/ctx"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" --allow-multiple-definition -T "$LDSCRIPT" \
    "$WORK/freestanding.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/app.o" \
    "$WORK/blkirq.o" "$WORK/platform.o" "$WORK/ctx_stubs.o" \
    "$WORK/app_image.o" "$WORK/agent_src.o" $K_SUPPORT -o "$WORK/kernel.elf"

printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null

OUT="$(timeout 120 "$QEMU" -machine virt -nographic -m 256M \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode IRQ blk tool output ---"
printf '%s\n' "$OUT"
echo "--------------------------------------------"

if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "CONFINED: kernel not user-accessible in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend pure-JS host_fs_read resolved through production SYS_POLL from a real S-mode virtio-blk PLIC interrupt."
    exit 0
fi

echo "FAIL: $TEST_NAME — expected OpenSBI banner + confinement + '$EXPECT' + USER-EXIT"
exit 1
