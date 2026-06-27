#!/usr/bin/env bash
# WASM-agent Phase 0 (docs/wasm-migration-plan.md §5): build the vendored wasm3 interpreter
# (third_party/wasm3) freestanding against the all-MC libc (user/libc/libc.mc) + the vendored
# openlibm — exactly like the QuickJS payload — link the confined wasm3 front-end
# (examples/apps/wasm_agent.c) with the bare-metal platform runtime, and run under QEMU. The agent
# instantiates a real, off-toolchain-built .wasm guest (examples/apps/wasm/hello.c, compiled with
# clang --target=wasm32 + wasm-ld) that prints a marker via a WASI-shaped fd_write import mapped to
# SYS_WRITE, then proc_exit. PASS requires the marker.
#
# This is the spike gate that proves a general WASM engine confines, links, and reaches the kernel
# through the unchanged syscall boundary — the mirror of qjs-run-test.
#
# Usage: tools/lang/wasm-run-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
WASMLD="${WASMLD:-wasm-ld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
W3="$HERE/third_party/wasm3/source"
LIBC="$HERE/user/libc/libc.mc"
AGENT="$HERE/examples/apps/wasm_agent.c"
GUEST="$HERE/examples/apps/wasm/hello.c"
RUNTIME="$HERE/tests/qemu/lang/wasm_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="WASM=ok"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-wasm-run-test" || echo "wasm-run-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 0. Build the guest .wasm with the off-the-shelf wasm32 toolchain (clang + wasm-ld). A genuine
#    module, not hand-assembled bytes; --no-entry because _start is an export (not the wasm start
#    function), --allow-undefined so the WASI imports resolve at link-in-engine time.
"$CLANG" --target=wasm32 -nostdlib -O2 \
    -Wl,--no-entry -Wl,--export=_start -Wl,--allow-undefined \
    "$GUEST" -o "$WORK/hello.wasm"

# Embed the module as a C byte array (portable od; xxd is not guaranteed in the image).
{
    echo "const unsigned char wasm_blob[] = {"
    od -An -v -tu1 "$WORK/hello.wasm" | awk '{ for (i = 1; i <= NF; i++) printf "%s,", $i }'
    echo "};"
    echo "const unsigned int wasm_blob_len = sizeof(wasm_blob);"
} > "$WORK/wasm_blob.h"

# Hardware-FP freestanding target (wasm float ops compute on doubles), matching the libc's lp64d.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
        -fno-builtin -I"$HERE/user/libc/include")

# wasm3 needs reliable tail-call optimization (its interpreter chains op functions in tail
# position) and aliasing-heavy slot punning: build the engine objects at -O2 with strict aliasing
# off. -O0 overflows the native C stack (upstream documents this).
W3FLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
         -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
         -fno-strict-aliasing -fno-builtin -I"$HERE/user/libc/include" -I"$W3")

# 1. wasm3 engine core (the 9 TUs; m3_info.c is excluded — see third_party/wasm3/VENDOR.md).
for f in m3_bind m3_code m3_compile m3_core m3_env m3_exec m3_function m3_module m3_parse; do
    "$CLANG" "${W3FLAGS[@]}" -c "$W3/$f.c" -o "$WORK/$f.o"
done

# 2. The confined wasm3 front-end (embeds the guest blob).
"$CLANG" "${CFLAGS[@]}" -I"$W3" -I"$WORK" -c "$AGENT" -o "$WORK/agent.o"

# 3. The all-MC libc, as one unit, through the selected backend (hardware FP).
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$LIBC" "$WORK/libc.o" "$WORK"

# 4. openlibm (transcendentals wasm3 may call) + the platform runtime (same lp64d ABI).
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"

# 5. Link the bare-metal image.
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/agent.o" \
    "$WORK/m3_bind.o" "$WORK/m3_code.o" "$WORK/m3_compile.o" "$WORK/m3_core.o" \
    "$WORK/m3_env.o" "$WORK/m3_exec.o" "$WORK/m3_function.o" "$WORK/m3_module.o" "$WORK/m3_parse.o" \
    "$WORK/libc.o" $SUPPORT_OBJ "$WORK/libm.a" -o "$WORK/wasm.elf"

OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/wasm.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: wasm3 built freestanding against the all-MC libc, instantiated a real wasm32 module and printed via a WASI fd_write import mapped to SYS_WRITE, confined under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' (guest fd_write marker) in output"
exit 1
