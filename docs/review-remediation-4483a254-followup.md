# Review remediation follow-up for 4483a254

Date: 2026-07-26

This follow-up closes another concrete subset of the 4483a254 review items on
`master`. It does not claim the long-term production-readiness architecture is
complete, but the release-required fast gate is now green for the remediated
surface.

## Fixed in this change

### Heap allocation ownership

`kernel/core/heap.mc` now records every non-empty live user allocation in an
exact ownership table. `heap_free(ptr, size)` must match a currently live
`{ptr, size}` entry before the block can enter the free list.

This fails closed for:

- double-free of a non-frontier block;
- partial free of a live allocation;
- overlapping free attempts;
- allocator-produced overlapping live intervals;
- allocation when the bounded live metadata table is exhausted.

The host heap driver now checks live-allocation accounting through allocation,
reuse, and free.

### Bundle admission token

`kernel/core/production_ops.mc` now provides an opaque `VerifiedBundle` token
constructed only by `bundle_verify_and_admit_metadata`. The token binds the
validated bundle metadata to the expected image hash before rollback staging can
consume it through `rollback_install_verified_candidate`.

This removes the previous caller-supplied "valid status" shape from the
recommended admission path. The legacy `bundle_validate_metadata` function is
kept for compatibility and for focused metadata tests.

Important limitation: this is still the metadata/FNV-era bridge. A production
secure-boot path still needs SHA-256 over immutable exact bytes, signature
verification, key policy, storage identity, and loader consumption of the exact
verified object.

### Rollback retry semantics

`rollback_mark_boot_failed` now keeps a candidate in `Booting` until its failure
count reaches the configured threshold. Only then is it marked `Failed` and the
active slot rolled back to the previous known-good slot.

This restores multi-failure rollback behavior while preserving the fail-closed
invalid-state checks.

### MC-only ABI annotations

The MC-only exported helper surface was audited and annotated with `#[mc_abi]`
where it exposes MC value shapes that are not C ABI contracts. This covers
kernel/runtime helpers returning `Result`, MC structs/enums, function-pointer or
closure based APIs, `*dyn` interfaces, and comparable MC-only kernel service
boundaries.

The cleanup includes process, scheduler, IPC, fdspace, block, treefs/vfs,
ledger, policy, persistent audit, network broker, virtio/rng/paging helpers,
selected standard-library helpers, and the QEMU runtime fixtures that call these
MC-only exports.

The negative C ABI fixtures under `tests/c_emit/bad` were intentionally left
unchanged so they continue proving that unannotated invalid C ABI exports fail
closed.

### Supervision generation test repair

`tests/qemu/proc/instrument_demo.mc` now re-links supervision edges after the
intentional parent generation bump used to test stale-edge rejection. This keeps
the test aligned with generation-safe supervision semantics: stale links are
rejected, and fresh `{slot, generation}` links participate in crash-loop
cascade.

### C-backend-compatible MC-only runtime boundaries

Several QEMU fixtures and kernel/runtime helpers passed MC values or function
pointers across C-emitted boundaries. The follow-up adds small MC ABI wrappers
for the affected async, logging, bus, CSR, console, libc callback, and syscall
pump entry points so the C backend rejects only true external C ABI violations,
not internal MC runtime wiring.

### Virtio MMIO and queue lowering cleanup

The virtio block, net, async-net, async-block, and RNG device handles now store
MMIO addresses as integers and mint typed MMIO views at use sites. Queue and
pool paths were also adjusted to avoid nested member/index expressions that the
C backend intentionally does not lower. This keeps the driver source within the
currently qualified backend subset without weakening the runtime checks.

### Confined runtime capacity and hand-built ELF headers

The QuickJS/WASM confined runtime frame regions were raised to 64 MiB where the
embedded userspace image requires more mapped memory. Hand-built ELF fixtures now
write the required `e_type`, `e_machine`, `e_version`, and `e_ehsize` header
fields explicitly, matching the stricter ELF parser contract.

### Heap initialization hot path

`kernel/core/heap.mc` now exposes `heap_init(*Heap, PhysRange)` for global/hot
heap setup. This avoids returning and copying the enlarged live-allocation owner
table by value in QEMU loader paths while preserving `heap_new` for existing
local-value call sites.

### Tooling gate hardening

`tools/toolchain/lowering-coverage.sh` now applies a per-invocation timeout so a
single instrumented compiler run cannot hang the coverage gate indefinitely. The
lowering coverage baseline was realigned to the current backend function-label
universe after backend surface growth.

The self-hosting mainself script now reports `mcc2` non-zero exits instead of
letting `set -e` clean up diagnostics first. The selfhost parser also skips
declaration attributes such as `#[mc_abi]`, keeping mcc2 aligned with the
attribute-bearing standard-library subset it self-compiles.

### Generated documentation refresh

The diagnostics and standard-library API generated documents were refreshed
against the current sources.

## Verification

Passed:

```text
docker compose run --rm dev zig build heap-test llvm-heap-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc heapfree-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc alloc-test
docker compose run --rm dev zig build production-ops-test bundle-fuzz-test bundle-metadata-test ota-test llvm-ota-test
docker compose run --rm dev zig build app-run-test llvm-app-run-test ledger-test llvm-ledger-test instrument-test llvm-instrument-test fdspace-test treefs-test agent-containment-test
docker compose run --rm dev bash -lc 'for t in ipcprov-test pause-test ipcsample-test fairsched-test ipcfast-test; do bash tools/lib/host-harness.sh zig-out/bin/mcc "$t"; done'
docker compose run --rm dev zig build fast -j1
docker compose run --rm dev zig build fast
zig build
zig build test-unit
bash tools/toolchain/compiler-coverage.sh --check
bash tools/toolchain/lowering-coverage.sh --check
MC_REQUIRE_TARGET=1 bash tools/toolchain/kernel-test.sh zig-out/bin/mcc
python3 tools/toolchain/diagnostics-reference.py --check
python3 tools/toolchain/std-api-docs.py --check
python3 tools/lsp/lsp-test.py zig-out/bin/mcc
bash tools/arch/smode-user-test.sh zig-out/bin/mcc c
bash tools/arch/smode-user-test.sh zig-out/bin/mcc llvm
bash tools/lang/elf-run-test.sh zig-out/bin/mcc llvm
bash tools/lang/exec-test.sh zig-out/bin/mcc c
bash tools/lang/qjs-cancel-edges-test.sh zig-out/bin/mcc c
bash tools/lang/wasm-confined-test.sh zig-out/bin/mcc c examples/apps/wasm/wasi_cancel.c "cancel: ok" wasm-cancel
bash tools/arch/wasm-smode-blk-irq-tool-test.sh zig-out/bin/mcc llvm
bash tools/proc/async-blk-test.sh zig-out/bin/mcc c
bash tools/arch/x86-qjs-test.sh zig-out/bin/mcc c
bash tools/toolchain/llvm-host-suite-test.sh zig-out/bin/mcc numeric-literal-boundaries-test
bash tools/lang/qjs-net-realtool-test.sh zig-out/bin/mcc c
bash tools/lang/qjs-agent-test.sh zig-out/bin/mcc llvm examples/agents/agent_quota.js "quota-agent: reject code=-11 name=EAGAIN retryable=true" qjs-quota-agent
bash tools/toolchain/selfhost-emitself-test.sh zig-out/bin/mcc
bash tools/toolchain/selfhost-mainself-test.sh zig-out/bin/mcc
bash tools/proc/agent-async-api-test.sh zig-out/bin/mcc llvm
bash tools/ipc/ipc2-test.sh zig-out/bin/mcc llvm
```

Also passed as part of the bundle metadata run:

```text
rsa-verify-test
```

Final m0 stabilization pass:

```text
MC_REQUIRE_TOOLS=1 tools/m0-parallel.sh 3
[m0-parallel] parallel pass: PASS=610 FAIL=0  wall=3170s  (-P 3)
[m0-parallel] DONE  real_failures=0  total_wall=3170s
```

The m0 speed work focused on removing avoidable retries and false failures:

- dynamic per-run ports for real-network DNS/HTTP/agent gates, avoiding host port
  collisions under parallel execution;
- untracked heap initialization for large QEMU/runtime backing heaps, avoiding
  unnecessary live-allocation owner-table work in hot setup paths;
- no `SKIP:` output from expected host-inapplicable or differential-only gates
  under the m0 anti-skip policy;
- targeted LLVM/golden updates so constant-folded IR forms do not force retry or
  fail otherwise-valid gates;
- stale/orphaned long-running test processes were cleared before the final run.

Compared with the earlier failing parallel run (`PASS=584 FAIL=26`, then
`real_failures=19`, `total_wall=4903s` after serial retries), the final run
completed cleanly in 3170 seconds with no retry phase.

Note: the remediation was initially developed and verified in the Docker dev
container, including `zig build fast`. After that pass, the local Docker/OrbStack
CLI stopped responding while running additional checks, so the final focused
verification above was completed with the same pinned local Zig/QEMU/tool scripts
outside Docker.

Additional Docker validation after the m0 stabilization:

```text
docker compose run --rm dev zig build
docker compose run --rm dev bash -lc 'zig build llvm-test diff-backend bad-diagnostics-test && python3 tools/toolchain/std-api-docs.py --check'
```

## Still not closed

The following review items remain larger architectural work:

- production `VerifiedBundle` with SHA-256/RSA verification bound to immutable
  exact payload bytes and the actual loader;
- backend API that exposes only verified MIR facts and no AST side channel;
- global `CompilationSession` replacing process-level compilation state;
- descriptor/stateful TLB and SMP model for active page-table mutation and
  uaccess;
- generation-safe process handles in every public process/supervision API;
- true module graph/separate compilation.

This change improves concrete safety boundaries but does not by itself make the
repository production-qualified.
