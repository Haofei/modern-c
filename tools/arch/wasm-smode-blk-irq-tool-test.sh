#!/usr/bin/env bash
# WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): a confined WASM guest's brokered fs_read is
# serviced through a REAL S-mode virtio-blk PLIC interrupt and delivered via production SYS_POLL — the
# WASM peer of qjs-smode-net-irq-tool-test.sh. Same confined WASM agent ELF (WAMR + the comprehensive wamr_full_host +
# all-MC libc + wasm_host running a stock wasm32-wasi guest) as the other S-mode peers, but the kernel
# wires the virtio-blk device + PLIC IRQ + DMA platform so an FS_READ completion arrives by interrupt.
#
# Usage: tools/arch/wasm-smode-blk-irq-tool-test.sh <mcc> [c|llvm] [guest.c] [expect] [name-base]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wasm/wasi_blk_irq.c}"
EXPECT="${4:-blk-irq: ok}"
NAME_BASE="${5:-wasm-smode-blk-irq-tool}"
GUEST_KIND="${6:-wasi}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
ZIG="${ZIG:-zig}"
QEMU="${QEMU:-qemu-system-riscv64}"
AR="${AR:-llvm-ar}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
WAMR="$HERE/third_party/wamr"
WC="$WAMR/core"
WASMDIR="$HERE/examples/apps/wasm"
HOST="$HERE/examples/apps/wamr_full_host.c"             # the comprehensive WAMR host (WASI + FS + mc)
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/arch/qjs_smode_demo.mc"                  # ELF load + ABI + supervisor gigapage
BLKIRQ="$HERE/tests/qemu/arch/app_run_blk_irq.mc"             # virtio-blk IRQ wiring (agent-agnostic)
RUNTIME="$HERE/tests/qemu/arch/qjs_smode_blk_irq_runtime.mc"  # S-mode blk-IRQ bring-up
USERMODE="$HERE/tests/qemu/arch/smode_usermode_runtime.mc"    # S-mode trap vector + syscall dispatch
CTX_STUBS="$HERE/tests/qemu/mem/proc_ctx_stubs.mc"            # link-only process context externs
PLATFORM="$HERE/kernel/arch/riscv64/sbi_dma_time.mc"          # DMA + timer + interrupt controller
LDSCRIPT="$HERE/tests/qemu/sbi.ld"                            # OpenSBI payload @ 0x80200000
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then echo "KEEP_WORK: $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi

# ---- 0. The guest: a wasm32-wasi binary (off-the-shelf zig + wasi-libc), feature-pinned for WAMR ----
WASI_MCPU="mvp+bulk_memory+sign_ext+mutable_globals+nontrapping_fptoint"
if [ "$GUEST_KIND" = qjs ]; then
    QCACHE="$HERE/.wamr-cache/qjs-wasm"; mkdir -p "$QCACHE"
    QWANT="$(printf '%s ' "$WASI_MCPU"; ls -la "$QJS"/dtoa.c "$QJS"/libunicode.c "$QJS"/libregexp.c "$QJS"/quickjs.c "$QJS"/*.h 2>/dev/null | md5sum)"
    exec 8>"$QCACHE/.lock"; flock 8
    if [ "$(cat "$QCACHE/stamp" 2>/dev/null)" != "$QWANT" ]; then
        for f in dtoa libunicode libregexp quickjs; do
            "$ZIG" cc -target wasm32-wasi -mcpu="$WASI_MCPU" -O2 -I"$QJS" -D__wasi__ -c "$QJS/$f.c" -o "$QCACHE/$f.o"
        done
        printf '%s' "$QWANT" > "$QCACHE/stamp"
    fi
    flock -u 8
    "$ZIG" cc -target wasm32-wasi -mcpu="$WASI_MCPU" -O2 -s -I"$QJS" -D__wasi__ -Wl,-z,stack-size=524288 \
        "$HERE/$GUEST_REL" "$QCACHE"/dtoa.o "$QCACHE"/libunicode.o "$QCACHE"/libregexp.o "$QCACHE"/quickjs.o \
        -o "$WORK/guest.wasm"
else
    "$ZIG" cc -target wasm32-wasi -mcpu="$WASI_MCPU" -O2 -s -Wl,-z,stack-size=262144 "$HERE/$GUEST_REL" -o "$WORK/guest.wasm"
fi
{
    echo "const unsigned char wasm_blob[] = {"
    od -An -v -tu1 "$WORK/guest.wasm" | awk '{ for (i = 1; i <= NF; i++) printf "%s,", $i }'
    echo "};"
    echo "const unsigned int wasm_blob_len = sizeof(wasm_blob);"
} > "$WORK/wasm_blob.h"

# ---- 1. The confined U-mode host ELF: WAMR (cached) + wamr_full_host + all-MC libc (hardware FP) ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
            -fno-builtin -Wno-implicit-function-declaration -I"$HERE/user/libc/include")
WINC=(-I"$WC/shared/platform/include" -I"$WC/shared/platform/mc" -I"$WC/shared/utils"
      -I"$WC/shared/utils/uncommon" -I"$WC/shared/mem-alloc" -I"$WC/shared/mem-alloc/ems"
      -I"$WC/iwasm/include" -I"$WC/iwasm/common" -I"$WC/iwasm/interpreter" -I"$WC")
WDEF=(-DBH_PLATFORM_MC -DBUILD_TARGET_RISCV64_LP64D -DWASM_ENABLE_INTERP=1
      -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_BULK_MEMORY=1
      -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_REF_TYPES=1
      -DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free)

# Build the WAMR engine ONCE into a cached archive (flock-guarded, stamped on WDEF + source mtimes).
CACHE="$HERE/.wamr-cache"; mkdir -p "$CACHE"
WAMR_LIB="$CACHE/libwamr.a"
WANT="$(printf '%s ' "${WDEF[@]}"; find "$WC/shared/platform/mc" "$WC/shared/utils" "$WC/shared/mem-alloc" "$WC/iwasm/common" "$WC/iwasm/interpreter" \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null | sort | xargs ls -la 2>/dev/null | md5sum)"
exec 9>"$CACHE/.lock"; flock 9
if [ ! -f "$WAMR_LIB" ] || [ "$(cat "$CACHE/stamp" 2>/dev/null)" != "$WANT" ]; then
    CB="$CACHE/obj"; rm -rf "$CB"; mkdir -p "$CB"; OBJS=(); j=0
    cwamr() { "$CLANG" "${APP_CFLAGS[@]}" "${WINC[@]}" "${WDEF[@]}" -c "$1" -o "$2"; OBJS+=("$2"); }
    cwamr "$WC/shared/platform/mc/mc_platform.c" "$CB/w_mc.o"
    for f in "$WC"/shared/utils/*.c; do cwamr "$f" "$CB/wu_$((j++)).o"; done
    cwamr "$WC/shared/mem-alloc/mem_alloc.c" "$CB/w_ma.o"
    for f in "$WC"/shared/mem-alloc/ems/ems_alloc.c "$WC"/shared/mem-alloc/ems/ems_hmu.c "$WC"/shared/mem-alloc/ems/ems_kfc.c; do cwamr "$f" "$CB/we_$((j++)).o"; done
    for f in "$WC"/iwasm/common/*.c; do case "$f" in *wasm_application.c) continue;; esac; cwamr "$f" "$CB/wc_$((j++)).o"; done
    cwamr "$WC/iwasm/interpreter/wasm_runtime.c" "$CB/w_rt.o"
    cwamr "$WC/iwasm/interpreter/wasm_interp_classic.c" "$CB/w_interp.o"
    cwamr "$WC/iwasm/interpreter/wasm_loader.c" "$CB/w_loader.o"
    "$CLANG" "${APP_CFLAGS[@]}" -c "$WC/iwasm/common/arch/invokeNative_riscv.S" -o "$CB/w_tramp.o"; OBJS+=("$CB/w_tramp.o")
    "$AR" rcs "$WAMR_LIB" "${OBJS[@]}"
    printf '%s' "$WANT" > "$CACHE/stamp"
fi
flock -u 9

"$CLANG" "${APP_CFLAGS[@]}" -I"$WC/iwasm/include" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

CFLAGS=("${APP_CFLAGS[@]}")   # kernel_boot_compile_mc_object reads CFLAGS for the target ABI (lp64d)
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/host.o" --whole-archive "$WAMR_LIB" --no-whole-archive \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the host ELF for the kernel to load ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'unsigned long mc_app_image(void) { return (unsigned long)app_image; }\n'
    printf 'unsigned long mc_app_image_len(void) { return (unsigned long)app_image_len; }\n'
} >"$WORK/app_image.c"

# ---- 3. The kernel image, with the virtio-net IRQ + DMA platform. Separate compile dirs avoid
#         generated-file collisions across the MC objects; --allow-multiple-definition tolerates the
#         overlapping virtio/PLIC/DMA/syscall stubs the IRQ modules + platform each pull in. ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
mkdir -p "$WORK/app" "$WORK/blkirq" "$WORK/runtime" "$WORK/platform" "$WORK/ctx" "$WORK/um"
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/app.o" "$WORK/app"
kernel_boot_compile_mc_object "$BACKEND" "$BLKIRQ" "$WORK/blkirq.o" "$WORK/blkirq"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/runtime"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/platform"
kernel_boot_compile_mc_object "$BACKEND" "$CTX_STUBS" "$WORK/ctx_stubs.o" "$WORK/ctx"
kernel_boot_compile_mc_object "$BACKEND" "$USERMODE" "$WORK/usermode.o" "$WORK/um"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" --allow-multiple-definition -T "$LDSCRIPT" \
    "$WORK/freestanding.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/app.o" \
    "$WORK/blkirq.o" "$WORK/platform.o" "$WORK/ctx_stubs.o" \
    "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

# A small virtio-blk backing image whose first bytes are "DISK" (the rest zero-filled).
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
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined WASM guest's brokered fs_read completed through production SYS_POLL from a real S-mode virtio-blk PLIC interrupt, under REAL OpenSBI."
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + 'CONFINED...' + '$EXPECT' + 'USER-EXIT from U'"
exit 1
