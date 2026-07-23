# Virtio-rng comparison evidence snapshot

Date: 2026-07-22

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

The runner builds all protocol objects with optimization enabled. The benchmark
executes one million valid `begin_submit`/`complete`/`copy` cycles per core in
one process and reports three events per cycle. Results vary with host load and
must be regenerated before publication.

## Source, trust-marker, and object snapshot

| Implementation | Component | Source LOC | Trusted markers | Object bytes |
|---|---|---:|---:|---:|
| C baseline | protocol core | 190 | 23 | 3,192 |
| Rust raw FFI | protocol core | 308 | 25 | 3,632 |
| MC raw | protocol core | 313 | 5 | 10,216 |
| Rust safe typestate | DMA fixture | 51 | 7 | 336 |
| MC contract | DMA fixture | 48 | 6 | 808 |

“Trusted markers” is a mechanically defined source count, not a proof-weighted
TCB size: C counts raw pointer declarations/accesses; Rust counts `unsafe`;
MC counts `unsafe` and extern declarations. The separate component rows must
not be combined into a language-wide percentage.

## Protocol-core throughput snapshot

| Core | Events | ns/event | Events/second |
|---|---:|---:|---:|
| C | 3,000,000 | 8.968 | 111,507,583 |
| Rust | 3,000,000 | 16.723 | 59,799,075 |
| MC | 3,000,000 | 26.806 | 37,305,545 |

This run is negative evidence for K2: MC was about 2.99 times slower per event
than C and about 1.60 times slower than Rust in this microbenchmark. It would be
incorrect to claim “no material runtime regression.” The result identifies an
optimization/code-generation task; it says nothing yet about device throughput,
tail latency, IRQ latency, or the cost of common C glue.

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

K2 remains unsatisfied until the performance regression is resolved and
whole-driver runtime/stack costs plus a review-cost method are measured. K3 and
K4 additionally require the idiomatic Rust-safe complete-driver comparison,
real-hardware qualification, and independent reproduction.
