# Review remediation follow-up for 4483a254

Date: 2026-07-26

This follow-up closes another concrete subset of the 4483a254 review items on
`master`. It does not claim the long-term production-readiness architecture is
complete.

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

The OTA chunk/finish APIs and two MC-only helper exports were annotated with
`#[mc_abi]` so they no longer claim C ABI compatibility for MC-only value
shapes such as `Result` and function pointers.

## Verification run in Docker

Passed:

```text
docker compose run --rm dev zig build heap-test llvm-heap-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc heapfree-test
docker compose run --rm dev bash tools/lib/host-harness.sh zig-out/bin/mcc alloc-test
docker compose run --rm dev zig build production-ops-test bundle-fuzz-test bundle-metadata-test ota-test llvm-ota-test
docker compose run --rm dev zig build bundle-fuzz-test
```

Also passed as part of the bundle metadata run:

```text
rsa-verify-test
```

Known remaining failure observed during this follow-up:

```text
docker compose run --rm dev zig build app-run-test
```

The failure is a broad existing ABI-cleanup issue: many MC-only `export fn`
helpers across process, fdspace, treefs, net broker, ledger, IPC and related
runtime modules expose `Result`, enum, struct, or function-pointer values through
the explicit C ABI surface. These need a deliberate pass to separate true C ABI
entry points from MC-only exported kernel/runtime helpers, not a blind mechanical
rewrite.

## Still not closed

The following review items remain larger architectural work:

- production `VerifiedBundle` with SHA-256/RSA verification bound to immutable
  exact payload bytes and the actual loader;
- complete C ABI/MC ABI surface audit for all exported kernel/runtime helpers;
- backend API that exposes only verified MIR facts and no AST side channel;
- global `CompilationSession` replacing process-level compilation state;
- descriptor/stateful TLB and SMP model for active page-table mutation and
  uaccess;
- generation-safe process handles in every public process/supervision API;
- true module graph/separate compilation;
- full release-required `fast -j1` / parallel backend parity gates green.

This change improves concrete safety boundaries but does not by itself make the
repository production-qualified.
