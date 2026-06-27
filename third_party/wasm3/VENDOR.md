# Vendored: wasm3

- Upstream: https://github.com/wasm3/wasm3
- Version: 0.5.2
- Commit: d77cd814aa0bc68cb1df917580a6304d34cfb30b
- License: MIT (see `LICENSE`)

Only `source/` is vendored (the engine). The WASM migration (docs/wasm-migration-plan.md)
Phase 0 uses wasm3 as the spike interpreter: it builds **freestanding** against the
all-MC libc (`user/libc/libc.mc`) + openlibm, exactly like the QuickJS payload, and runs
as a confined U-mode/bare-metal payload behind the narrow syscall ABI.

## Freestanding build notes

- Compile set is the 9 core engine TUs (the same list CMake builds, minus the diagnostics):
  `m3_bind m3_code m3_compile m3_core m3_env m3_exec m3_function m3_module m3_parse`.
- `m3_info.c` is **excluded**: it is a `printf`/`sprintf` disassembler used only on debug
  paths the freestanding image never takes, and the MC libc deliberately omits `printf`.
  Its one unconditionally-referenced symbol, `m3_PrintProfilerInfo()` (called from
  `m3_FreeRuntime`), is provided as an empty stub by the host TU.
- `m3_api_*.c` (libc/wasi/uvwasi/tracer host bindings) are **not** compiled. The migration
  provides its own WASI shim that maps onto the kernel capability brokers; Phase 0 links a
  minimal `fd_write`/`proc_exit` import directly in the host.
- Engine config is upstream defaults (`m3_config.h`): interpreter only (no JIT — satisfies
  the W^X constraint in the migration plan §3), `d_m3HasFloat=1` (hardware FP via lp64d),
  `d_m3FixedHeap=false` (uses the libc malloc arena).

No upstream source files are modified. Build/exclude decisions live entirely in the test
harness (`tools/lang/wasm-run-test.sh`).
