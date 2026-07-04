# WAMR (vendored)

- **Upstream:** <https://github.com/bytecodealliance/wasm-micro-runtime>
- **Recorded version:** `2.4.3`, from `WAMR_VERSION_MAJOR/MINOR/PATCH` in
  `core/version.h`. This is an untagged upstream `main` snapshot after
  `WAMR-2.4.3`; the upstream version header still reports `2.4.3`.
- **Recorded commit:** `0e65961d8e560b3d8a125045a29336ce6a0b16ad`.
- **Source archive:**
  <https://github.com/bytecodealliance/wasm-micro-runtime/archive/0e65961d8e560b3d8a125045a29336ce6a0b16ad.tar.gz>.
- **Archive SHA-256:**
  `dc27b60a1aff64b89d2ca51f036e0f1baee000e156ed7e9283e4f97b660e6e65`.
- **License:** Apache-2.0 WITH LLVM-exception (see `LICENSE`)

## What is kept

This is a lean interpreter-focused WAMR subset used by the confined WASM agent
path:

- `core/iwasm/common/` and `core/iwasm/interpreter/` sources used by the classic
  and fast interpreter builds.
- `core/iwasm/include/` public headers used by the local WAMR hosts.
- Header-only AOT/compilation/GC pieces needed by unconditional includes in the
  retained sources.
- `core/shared/utils/`, `core/shared/mem-alloc/`, and selected common platform
  support used by the interpreter build.
- Architecture trampolines under `core/iwasm/common/arch/`.
- `core/config.h`, `core/version.h`, and `LICENSE`.

Upstream product examples, standalone apps, tests, full CMake/SCons project
scaffolding, docs, nonessential host tooling, and unused runtime variants were
dropped. AOT/JIT engines are not built here.

## Local modifications

`core/shared/platform/mc/` is a local freestanding platform port. It maps WAMR's
`os_*` hooks onto the all-MC libc heap, single-threaded synchronization stubs,
stdio, and optional demand-paged linear-memory growth.

The build also selects local feature defines rather than upstream defaults:
`BH_PLATFORM_MC`, `WASM_ENABLE_INTERP=1`,
`WASM_ENABLE_INSTRUCTION_METERING=1`, bulk memory/ref-types support,
`WASM_ENABLE_CALL_INDIRECT_OVERLONG=1`, and optional
`WASM_ENABLE_FAST_INTERP`.

All retained upstream files match commit
`0e65961d8e560b3d8a125045a29336ce6a0b16ad`. The only local source subtree is
`core/shared/platform/mc/`.

## How it is built and used

WAMR is built directly by the WASM test scripts instead of through upstream
CMake. Representative build logic lives in `tools/lang/wasm-confined-test.sh`,
`tools/lang/wamr-run-test.sh`, and the architecture-specific WASM scripts under
`tools/arch/`.

The local build compiles the `mc` platform port, shared utility/memory allocator
sources, retained `iwasm/common` sources except `wasm_application.c`, the
interpreter runtime/loader, one interpreter translation unit, and the target
architecture trampoline. The resulting archive links into WAMR hosts such as
`examples/apps/wamr_host.c`, `examples/apps/wamr_agent_host.c`,
`examples/apps/wamr_wasi_host.c`, and `examples/apps/wamr_full_host.c`.
