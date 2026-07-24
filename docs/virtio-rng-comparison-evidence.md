# Virtio-rng comparison evidence snapshot

Date: 2026-07-23

Scope: bounded protocol core plus DMA typestate fixtures. This is a developer
reproduction, not an independent audit or a complete-driver performance study.

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
review-cost method are still unmeasured. K3 and K4 additionally require the
idiomatic Rust-safe complete-driver comparison, real-hardware qualification,
and independent reproduction.
