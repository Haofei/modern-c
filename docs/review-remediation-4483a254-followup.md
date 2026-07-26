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

## Verification run in Docker

Passed:

```text
docker compose run --rm dev zig build heap-test llvm-heap-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc heapfree-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc alloc-test
docker compose run --rm dev zig build production-ops-test bundle-fuzz-test bundle-metadata-test ota-test llvm-ota-test
docker compose run --rm dev zig build app-run-test llvm-app-run-test ledger-test llvm-ledger-test instrument-test llvm-instrument-test fdspace-test treefs-test agent-containment-test
docker compose run --rm dev bash -lc 'for t in ipcprov-test pause-test ipcsample-test fairsched-test ipcfast-test; do bash tools/lib/host-harness.sh zig-out/bin/mcc "$t"; done'
docker compose run --rm dev zig build fast -j1
```

Also passed as part of the bundle metadata run:

```text
rsa-verify-test
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
- true module graph/separate compilation;
- parallel backend parity release gate evidence on the target CI matrix.

This change improves concrete safety boundaries but does not by itself make the
repository production-qualified.
