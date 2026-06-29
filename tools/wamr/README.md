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

## Status update — engine swap COMPLETE, wasm3 retired

All historical milestones below are DONE: the engine landed, the WASI-libc loader blocker was
solved (feature-pin), the full agent family runs on WAMR, and wasm3 has been deleted. See the
coverage-status section at the bottom for the current state. The notes below are kept as the
record of how each blocker was resolved.

## WASI-libc loader — SOLVED (feature-pin the guest build)

WAMR's classic-interp loader desynced on a code-section opcode in zig's wasi-libc (printf's
`call_indirect`), surfacing as "unknown table 128". Root cause: zig emits **multivalue /
reference-types** forms WAMR's INTERP mis-parses. Fix is guest-side — build the wasm32-wasi guest
with a pinned feature set so zig REBUILDS wasi-libc without them (a `-mno-*` flag does NOT, but
`-mcpu=` changes the target hash and does):
`zig cc -target wasm32-wasi -mcpu=mvp+bulk_memory+sign_ext+mutable_globals+nontrapping_fptoint`.
With that, WAMR runs a stock wasm32-wasi guest CONFINED — `wamr-wasi-hello-test` (printf ->
WASI fd_write -> SYS_WRITE). WAMR config also needs `WASM_ENABLE_BULK_MEMORY_OPT=1` (memory.copy/
fill) + `WASM_ENABLE_REF_TYPES=1`. This unblocks the WASI/QuickJS-on-wasm guests for the migration.

## WAMR coverage status — wasm3 RETIRED (m0 green, 647 PASS, 0 FAIL)

WAMR has **fully replaced** wasm3. Every WASM gate — the confined agent family + net-realtool
+ watchdog + bench, the 3 S-mode (OpenSBI) peers, and the 2 cross-arch peers (x86_64 ring-3,
aarch64 EL0) — runs on WAMR, both backends, **gated in `zig build m0`** (verified green at
647 PASS / 0 FAIL). `third_party/wasm3`, `examples/apps/wasm_host.c`, and
`examples/apps/wasm/wasi_shim.{c,h}` are **deleted**; the superseded `wasm-run` Phase-0 spike
is retired in favour of `wamr-run`/`wamr-fuel`/`wamr-agent` (the latter adds the deterministic
instruction-count fuel wasm3 lacked).

Engine builds are cached once, per arch, into `.wamr-cache/<arch>/libwamr.a` (riscv64 lives at
`.wamr-cache/libwamr.a`); the 4 QuickJS TUs are cached as wasm objects in `.wamr-cache/qjs-wasm`
(both flock-guarded + mtime-stamped) so the family doesn't bloat m0. Cross-arch uses WAMR's
per-arch invokeNative trampolines: `invokeNative_em64.s` (x86_64), `invokeNative_aarch64.s`
(aarch64), `invokeNative_riscv.S` (riscv64).

Three WAMR hosts remain: `wamr_host.c` (no-WASI named-export guests: compute/burn),
`wamr_wasi_host.c` (WASI stdout slice), `wamr_full_host.c` (the comprehensive host: WASI P1 +
brokered FS + mc net_fetch/tool_submit/tool_poll — the real agents). Guests are built
`zig cc -target wasm32-wasi -mcpu=mvp+bulk_memory+sign_ext+mutable_globals+nontrapping_fptoint`
(feature-pin so wasi-libc avoids the multivalue/ref-types forms WAMR's INTERP mis-parses).

Verification note: a long Docker session degrades the host (m0 slows, background wrappers get
killed). Use the detached-to-mounted-file + poll method: `docker compose run --rm -d dev bash
-c 'zig build m0 > /work/.wamr-cache/m0.log 2>&1; echo EXIT=$? ...'` then poll
`.wamr-cache/m0.log` for the `EXIT=` marker.

## Old remaining-work notes (superseded by the list above)


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
