# Virtio-rng comparison evidence snapshot

Date: 2026-07-24

Scope: bounded protocol core, DMA typestate fixtures, and driver lifecycle
policy. This is a developer reproduction, not an independent audit or a
complete-driver performance study.

## Environment

```text
host: Apple M3 Max, arm64, Darwin 25.5.0
clang: Homebrew clang 22.1.8
rustc: 1.95.0 (59807616e 2026-04-14)
zig: 0.16.0
mcc: 0.7.0-dev
```

The runner builds all protocol objects with optimization enabled and strips
debug sections before comparing object bytes. The benchmark executes seven
rotated samples of one million valid `begin_submit`/`complete`/`copy` cycles per
core in one process and reports three events per cycle. Rotation prevents one
implementation from always occupying the coldest or warmest position; the
reported value is the median. Results still vary with host load and must be
regenerated before publication.

## Source, trust-marker, and object snapshot

| Implementation | Component | Source LOC | Trusted markers | Object bytes |
|---|---|---:|---:|---:|
| C baseline | protocol core | 190 | 23 | 3,192 |
| Rust raw FFI | protocol core | 308 | 25 | 3,632 |
| MC raw | protocol core | 312 | 3 | 4,352 |
| Rust safe typestate | DMA fixture | 51 | 7 | 336 |
| MC contract | DMA fixture | 48 | 6 | 336 |

“Trusted markers” is a mechanically defined source count, not a proof-weighted
TCB size: C counts raw pointer declarations/accesses; Rust counts `unsafe`;
MC counts `unsafe` and extern declarations. The separate component rows must
not be combined into a language-wide percentage.

## Protocol-core throughput snapshot

| Core | Events | ns/event | Events/second |
|---|---:|---:|---:|
| C | 3,000,000 | 3.524 | 283,795,289 |
| Rust | 3,000,000 | 4.497 | 222,386,953 |
| MC | 3,000,000 | 3.963 | 252,312,868 |

The previous single-sample result exposed a byte-at-a-time MC copy path and an
unfair object-size comparison that charged only MC for debug metadata. The MC
core now uses one explicit ABI-audited `memcpy`, and immutable scalar `const`
value reads lower directly rather than through unordered atomic loads. In the
rotated median run MC is 1.12 times C's per-event cost and 0.88 times Rust's,
inside the runner's predeclared 1.25-times material-regression limit for both
comparators.

This resolves the bounded protocol-core performance blocker; it does not
establish device throughput, tail latency, IRQ latency, stack cost, reviewer
cost, or the cost of common C glue.

## Mutation snapshot

`run-contract-mutations.sh` confirms that the raw C and raw-FFI Rust controls
compile a deliberate device-owned CPU read, while Rust-safe and MC-contract
reject it. MC additionally rejects the bounded IRQ, trap, move/resource,
restricted region, lock, MMIO, and address-class mutations enumerated by the
runner. The ordinary specification suite checks accepted controls in the mixed
fixtures, preventing a compiler that rejects every program from passing.

## Five-candidate lifecycle snapshot

The lifecycle ABI compares five implementations against a separate executable
specification:

| Candidate | Representation |
|---|---|
| C | direct ABI state |
| Rust raw FFI | direct ABI state through raw pointers |
| Rust safe-value | decoded closed stage, booleans, and optional pending length |
| MC raw | direct ABI state |
| MC contract | closed stage plus typed logical fields |

The modeled boundary includes registration success/failure, callback
completion, publication, unregister-once, callback drain, final external clear,
and logical death. Host BFS reaches 31 unique states and performs 1,550
candidate comparisons. It includes invalid event ordering and the removal
window in which a callback completes logically before removal begins and
publishes before callback drain. Final clear is legal only after drain. An
injected mutation that changes the C final-clear result is detected with exit
status 2.

Linux allocation, hwrng calls, device reset, callback synchronization,
virtqueue deletion, and the actual external store remain common C. This closes
the next lifecycle-policy slice; it is not evidence for five independently
owned complete drivers. The clean x86-64 QEMU KUnit configuration executes
30/30 passing tests, including all four new lifecycle/differential cases.

The live lifecycle gate exposes a read-only snapshot only after callbacks have
been drained and teardown has completed. The guest requires the selected
lifecycle to be `Dead`, external availability to be zero, the lifecycle event
count to be nonzero, and the mismatch count to be zero. C, Rust, and MC live
controllers each pass:

| Live mode | Required outcome |
|---|---|
| normal | synchronized post-core/pre-publication removal; 1,217 protocol and 368 lifecycle events |
| completion/queue fault | zero-length, oversized, stale-generation, and queue-add recovery |
| registration failure | documented bound degraded state followed by explicit clean unbind |
| PM | three device-level suspend/restore cycles and final clean unbind |
| hotplug | QMP PCI removal/re-add, read recovery, and final clean unbind |

The normal gate is also repeated for all three controllers under strict KCSAN
and under the combined KASAN/UBSAN/lockdep/DEBUG_ATOMIC_SLEEP/DMA-API-debug
configuration. Every run executes 30/30 KUnit tests, records 1,217 protocol and
368 lifecycle events, reaches `Dead` with zero availability and mismatches, and
reports no sanitizer, race, locking, atomic-sleep, or DMA-API diagnostic.

Reproduce the snapshot with:

```sh
tools/virtio-rng-experiment/run-host-differential.sh \
  ../linux-vrng-fix zig-out/bin/mcc
tools/virtio-rng-experiment/run-dma-ownership.sh \
  ../linux-vrng-fix zig-out/bin/mcc
tools/virtio-rng-experiment/run-contract-mutations.sh \
  ../linux-vrng-fix zig-out/bin/mcc /tmp/vrng-mutations.tsv
tools/virtio-rng-experiment/run-comparison-metrics.sh \
  ../linux-vrng-fix zig-out/bin/mcc /tmp/vrng-comparison-metrics.tsv
```

K2 remains unsatisfied because whole-driver runtime/stack costs and a
review-cost method are still unmeasured. K3 and K4 additionally require
language-owned Linux resource lifetimes beyond this policy boundary,
real-hardware qualification, and independent reproduction.
