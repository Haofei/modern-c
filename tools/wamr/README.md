# WAMR engine-swap spike (Phase 8-prep: "better WASM implementation")

Goal: replace the **wasm3** agent engine with **WAMR** (WebAssembly Micro Runtime) to gain what
wasm3 lacks — **deterministic per-instruction fuel** (`wasm_runtime_set_instruction_count_limit`,
WAMR's `WASM_ENABLE_INSTRUCTION_METERING`) and a path to **WASI Preview 2** — while keeping the
confined U-mode model unchanged (engine is an untrusted payload; kernel TCB untouched).

## Status: engine RUNS wasm via the `mc` port (host-validated end-to-end)

`tools/wamr/build-host-validate.sh` builds WAMR's classic interpreter + the freestanding `mc`
platform port (`mc-platform/`) and runs an embedded no-WASI module exporting `compute()` →
**`WAMR-RESULT=42`, exit 0**. The full chain works: `wasm_runtime_full_init` → `load` →
`instantiate` → `create_exec_env` → `lookup_function` → `call_wasm`. This validates the port +
engine + `wasm_export.h` usage independent of the confined build (host libc + the same `mc` port).

Proven along the way:
- WAMR's interpreter **builds freestanding** against the all-MC libc (the decisive unknown). The
  `mc` port (`mc-platform/`, ~70 lines: libc-heap malloc, linear memory from a static pool,
  single-thread mutex/cond/thread stubs, printf→libc, a conservative stack boundary) satisfies the
  ~22 vmcore `os_*` plus a few extension stubs (`os_mremap`, `os_dumps_proc_mem_info`).
- WAMR defaults are minimal (AOT/JIT/threads/GC/libc-wasi off), so the config override is tiny
  (`INTERP` + `INSTRUCTION_METERING` + `BULK_MEMORY` + `BH_MALLOC/FREE` + the build-target/platform
  defines). Source set = `iwasm/common/*.c` (minus `wasm_application.c`) + `iwasm/interpreter/{wasm_runtime,wasm_interp_classic,wasm_loader}.c` + `shared/{utils,mem-alloc/ems}` + the `invokeNative_<arch>` trampoline.
- **Key gotcha:** WAMR processes the module buffer **in place** — pass a **writable** copy to
  `wasm_runtime_load` (a `const`/`.rodata` blob segfaults). The confined harness must copy the
  embedded wasm into a writable buffer before load.
- All-MC-libc: `strtok_r` is now declared in `user/libc/include/string.h` (decl-only — the caller
  `bh_strtok_r` is uncalled, so the linker drops it), giving a clean **17/17 freestanding compile**.
  The confined build additionally links openlibm for `sqrt`/`signbit`/etc.

## Reproduce / continue

1. Fetch WAMR (kept out of git via `.gitignore` `.wamr-tmp/`):
   ```sh
   mkdir -p .wamr-tmp && cd .wamr-tmp
   wget -O wamr.tar.gz https://codeload.github.com/bytecodealliance/wasm-micro-runtime/tar.gz/refs/heads/main
   tar xzf wamr.tar.gz && mv wasm-micro-runtime-main wamr
   ```
2. Drop the platform port in: `cp -r tools/wamr/mc-platform .wamr-tmp/wamr/core/shared/platform/mc`.
3. Compile the core set freestanding:
   ```sh
   INC="-I$W/core/shared/platform/include -I$W/core/shared/platform/mc -I$W/core/shared/utils \
        -I$W/core/shared/mem-alloc -I$W/core/iwasm/include -I$W/core/iwasm/common \
        -I$W/core/iwasm/interpreter -I$W/core"
   DEF="-DBH_PLATFORM_MC -DBUILD_TARGET_RISCV64_LP64D -DWASM_ENABLE_INTERP=1 \
        -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_BULK_MEMORY=1 \
        -DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free"
   CF="--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -nostdlib -ffreestanding \
       -fno-pic -mcmodel=medany -O1 -fno-builtin -I user/libc/include"
   # core set: core/shared/utils/bh_*.c, core/shared/mem-alloc/mem_alloc.c (+ems),
   #           core/iwasm/common/wasm_{exec_env,native,memory,runtime_common}.c,
   #           core/iwasm/interpreter/wasm_{loader,runtime,interp_classic}.c, mc-platform/mc_platform.c
   ```

## Remaining work (multi-session)

- **A.** Close the libc gap (`strtok_r`); finish the `os_*` extension stubs needed at link time.
- **B.** `wamr_host.c` — replace `examples/apps/wasm_host.c`'s wasm3 API (`m3_*`) with the
  ~8 WAMR `wasm_export.h` calls (`wasm_runtime_full_init`, `wasm_runtime_load`,
  `wasm_runtime_instantiate`, `wasm_runtime_lookup_function`, `wasm_runtime_call_wasm`,
  `wasm_runtime_set_instruction_count_limit`).
- **C.** Port `examples/apps/wasm/wasi_shim.c`'s ~30 imports from the `m3ApiRawFunction` macros to
  WAMR `NativeSymbol` arrays + `wasm_runtime_register_natives`.
- **D.** New gate `wamr-run-test` (WAMR runs a hello wasm confined) — the WAMR analogue of Phase-0
  `wasm-run-test`; keep wasm3 + all gates green (additive) until WAMR passes the family.
- **E.** The payoff: `wamr-fuel-test` — set an instruction-count limit, a compute-heavy guest is
  terminated DETERMINISTICALLY at the limit (vs the coarse timer watchdog).
- **F.** Migrate the gate family / make WAMR the default; retire wasm3.

WAMR version spiked: `bytecodealliance/wasm-micro-runtime` `main` (~6 MB tarball).
