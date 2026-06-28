#!/usr/bin/env bash
# Host validation of the WAMR engine + the freestanding `mc` platform port: builds WAMR's classic
# interpreter with the mc port (host libc) and runs an embedded no-WASI wasm exporting compute()->42.
# Proves the port + engine + wasm_export.h API usage are correct, independent of the confined build.
# Prereq: fetch WAMR into .wamr-tmp (see README) and drop in mc-platform/ (this script does both).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$HERE"
W="$HERE/.wamr-tmp/wamr"
[ -d "$W" ] || { echo "fetch WAMR first (see tools/wamr/README.md)"; exit 1; }
cp -r "$HERE/tools/wamr/mc-platform" "$W/core/shared/platform/mc" 2>/dev/null || true
zig cc -target wasm32-freestanding -nostdlib -Wl,--no-entry -Wl,--export=compute -O2 -xc - -o /tmp/tiny.wasm \
  <<<'__attribute__((export_name("compute"))) int compute(void){ return 6*7; }'
{ echo "const unsigned char tiny_wasm[] = {"; od -An -v -tu1 /tmp/tiny.wasm | awk '{for(i=1;i<=NF;i++)printf "%s,",$i}'; echo "};"; echo "const unsigned int tiny_wasm_len = sizeof(tiny_wasm);"; } > /tmp/tiny_wasm.c
INC="-I$W/core/shared/platform/include -I$W/core/shared/platform/mc -I$W/core/shared/utils -I$W/core/shared/utils/uncommon -I$W/core/shared/mem-alloc -I$W/core/shared/mem-alloc/ems -I$W/core/iwasm/include -I$W/core/iwasm/common -I$W/core/iwasm/interpreter -I$W/core"
DEF="-DBH_PLATFORM_MC -DBUILD_TARGET_AARCH64 -DWASM_ENABLE_INTERP=1 -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_BULK_MEMORY=1 -DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free"
COMMON=$(ls "$W"/core/iwasm/common/*.c | grep -v wasm_application.c)
UTILS=$(ls "$W"/core/shared/utils/*.c "$W"/core/shared/utils/uncommon/*.c 2>/dev/null)
MEM="$W/core/shared/mem-alloc/mem_alloc.c $W/core/shared/mem-alloc/ems/ems_alloc.c $W/core/shared/mem-alloc/ems/ems_hmu.c $W/core/shared/mem-alloc/ems/ems_kfc.c"
INTERP="$W/core/iwasm/interpreter/wasm_runtime.c $W/core/iwasm/interpreter/wasm_interp_classic.c $W/core/iwasm/interpreter/wasm_loader.c"
clang -O1 -w -Wno-implicit-function-declaration $INC $DEF \
  "$W/core/shared/platform/mc/mc_platform.c" $UTILS $MEM $COMMON $INTERP \
  "$W/core/iwasm/common/arch/invokeNative_aarch64.s" \
  "$HERE/tools/wamr/wamr_min_host.c" /tmp/tiny_wasm.c -lm -o /tmp/wamr_host
out="$(/tmp/wamr_host)"; echo "$out"
[ "$out" = "WAMR-RESULT=42" ] && echo "PASS: WAMR host validation (engine + mc port run wasm)" || { echo "FAIL"; exit 1; }
