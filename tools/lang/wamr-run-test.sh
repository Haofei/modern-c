#!/usr/bin/env bash
# WASM engine swap (docs/wasm-migration-plan.md; tools/wamr/README.md): run the WAMR engine CONFINED,
# the WAMR analogue of Phase-0 wasm-run-test (wasm3). Build WAMR's classic interpreter (freestanding
# against the all-MC libc via the `mc` platform port) + the confined wamr_host into a U-mode ELF, load
# it with the real elf_loader into an ISOLATED Sv39 space (kernel UNMAPPED), drop to U-mode, and let
# the host run an embedded no-WASI wasm module — reaching the kernel ONLY through SYS_WRITE/SYS_EXIT.
# PASS requires confinement + the engine's result marker + a clean U-mode exit.
#
# Usage: tools/lang/wamr-run-test.sh <mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wamr/compute.c}"   # a no-WASI wasm guest (built by zig)
HOST_REL="${4:-examples/apps/wamr_host.c}"       # the confined WAMR host front-end
EXPECT="${5:-WAMR=5050}"
NAME_BASE="${6:-wamr-run}"
GUEST_EXPORTS="${7:-compute}"                    # space-separated wasm exports the host looks up
GUEST_KIND="${8:-freestanding}"                  # "freestanding" (named exports) | "wasi" (_start)
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
ZIG="${ZIG:-zig}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
WAMR="$HERE/third_party/wamr"
WC="$WAMR/core"
HOST="$HERE/$HOST_REL"
GUEST="$HERE/$GUEST_REL"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
RUNTIME="$HERE/tests/qemu/lang/qjs_confined_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then echo "KEEP_WORK: $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi

# ---- 0. The guest: a no-WASI wasm32 module exporting compute() (off-the-shelf zig) ----
# No feature-pin: WAMR is built with WASM_ENABLE_CALL_INDIRECT_OVERLONG=1 (see WDEF below), so the
# loader correctly reads the linker's overlong (5-byte relocatable LEB) call_indirect table-index
# encoding that stock wasm32-wasi modules carry. We therefore run zig's PREBUILT wasi-libc as-is —
# no `-mcpu=` rebuild. WASI_MCPU stays overridable purely for diagnostics (e.g. WASI_MCPU=mvp+...).
WASI_MCPU="${WASI_MCPU:-none}"
if [ "$WASI_MCPU" = none ]; then MCPU=(); else MCPU=(-mcpu="$WASI_MCPU"); fi
if [ "$GUEST_KIND" = qjs ]; then
    # KEYSTONE: JavaScript on WAMR — the vendored QuickJS compiled to wasm32-wasi (guest + 4 TUs).
    # Larger stack for the JS engine. The 4 QuickJS TUs are identical across
    # every qjs gate, so compile them to wasm objects ONCE into a flock-guarded cache and reuse them —
    # each gate then only compiles its small guest .c and links. See tools/wamr/README.
    QJS="$HERE/third_party/quickjs"
    QCACHE="$HERE/.wamr-cache/qjs-wasm"; mkdir -p "$QCACHE"
    QWANT="$(printf '%s ' "$WASI_MCPU"; ls -la "$QJS"/dtoa.c "$QJS"/libunicode.c "$QJS"/libregexp.c "$QJS"/quickjs.c "$QJS"/*.h 2>/dev/null | md5sum)"
    kernel_boot_lock 8 "$QCACHE/.lock"
    if [ "$(cat "$QCACHE/stamp" 2>/dev/null)" != "$QWANT" ]; then
        for f in dtoa libunicode libregexp quickjs; do
            "$ZIG" cc -target wasm32-wasi "${MCPU[@]}" -O2 -I"$QJS" -D__wasi__ -c "$QJS/$f.c" -o "$QCACHE/$f.o"
        done
        printf '%s' "$QWANT" > "$QCACHE/stamp"
    fi
    kernel_boot_unlock 8 "$QCACHE/.lock"
    "$ZIG" cc -target wasm32-wasi "${MCPU[@]}" -O2 -s -I"$QJS" -D__wasi__ -Wl,-z,stack-size=524288 \
        "$GUEST" "$QCACHE"/dtoa.o "$QCACHE"/libunicode.o "$QCACHE"/libregexp.o "$QCACHE"/quickjs.o -o "$WORK/guest.wasm"
elif [ "$GUEST_KIND" = wasi ]; then
    "$ZIG" cc -target wasm32-wasi "${MCPU[@]}" -O2 -s -Wl,-z,stack-size=262144 "$GUEST" -o "$WORK/guest.wasm"
else
    EXPFLAGS=(); for e in $GUEST_EXPORTS; do EXPFLAGS+=(-Wl,--export="$e"); done
    "$ZIG" cc -target wasm32-freestanding -nostdlib -Wl,--no-entry "${EXPFLAGS[@]}" -O2 "$GUEST" -o "$WORK/guest.wasm"
fi
{
    echo "const unsigned char wasm_blob[] = {"
    od -An -v -tu1 "$WORK/guest.wasm" | awk '{ for (i = 1; i <= NF; i++) printf "%s,", $i }'
    echo "};"
    echo "const unsigned int wasm_blob_len = sizeof(wasm_blob);"
} > "$WORK/wasm_blob.h"

# ---- 1. The confined U-mode host ELF: WAMR interpreter + mc port + wamr_host + all-MC libc ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
            -fno-builtin -Wno-implicit-function-declaration -I"$HERE/user/libc/include")
WINC=(-I"$WC/shared/platform/include" -I"$WC/shared/platform/mc" -I"$WC/shared/utils"
      -I"$WC/shared/utils/uncommon" -I"$WC/shared/mem-alloc" -I"$WC/shared/mem-alloc/ems"
      -I"$WC/iwasm/include" -I"$WC/iwasm/common" -I"$WC/iwasm/interpreter" -I"$WC")
WDEF=(-DBH_PLATFORM_MC -DBUILD_TARGET_RISCV64_LP64D -DWASM_ENABLE_INTERP=1
      -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_BULK_MEMORY=1
      -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_REF_TYPES=1
      -DWASM_ENABLE_CALL_INDIRECT_OVERLONG=1
      -DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free)

# Build the WAMR core source set (the cmake INTERP globs: platform/mc + shared utils + mem-alloc/ems +
# iwasm/common/*.c minus wasm_application.c + the three interpreter TUs + the riscv trampoline) ONCE
# into a cached archive. The objects are backend-independent (clang C, fixed APP_CFLAGS), so ~25 TUs ×
# every wamr gate would dominate m0; an flock-guarded build-once keyed on a (WDEF + source mtimes)
# stamp cuts it to a single build reused across all wamr gates. Cache: .wamr-cache/ (gitignored).
AR="${AR:-llvm-ar}"
CACHE="$HERE/.wamr-cache"; mkdir -p "$CACHE"
WAMR_LIB="$CACHE/libwamr.a"
WANT="$(printf '%s ' "${WDEF[@]}"; find "$WC/shared/platform/mc" "$WC/shared/utils" "$WC/shared/mem-alloc" "$WC/iwasm/common" "$WC/iwasm/interpreter" \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null | sort | xargs ls -la 2>/dev/null | md5sum)"
kernel_boot_lock 9 "$CACHE/.lock"
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
kernel_boot_unlock 9 "$CACHE/.lock"

# The confined host front-end (sees wasm_blob.h + WAMR's public header).
"$CLANG" "${APP_CFLAGS[@]}" -I"$WC/iwasm/include" -I"$HERE/examples/apps/wasm" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS.
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

# The all-MC libc + the U-mode syscall shim, with hardware FP; + openlibm for sqrt/signbit/etc.
CFLAGS=("${APP_CFLAGS[@]}")
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
} >"$WORK/app_image.c"

# ---- 3. The kernel image (integer-only; the loader/ABI/confinement) ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: the WAMR interpreter, built freestanding against the all-MC libc (mc platform port), ran a real wasm32 module CONFINED in an isolated U-mode Sv39 space under QEMU; the kernel is unmapped in the host and it reached the kernel only via SYS_WRITE/SYS_EXIT"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED...', '$EXPECT', and 'USER-EXIT from U'"
exit 1
