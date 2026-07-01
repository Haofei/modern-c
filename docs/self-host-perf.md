# Self-Host Performance Ledger

Scale/perf measurements from the self-hosting effort ([`self-host-plan.md`](self-host-plan.md)).
This is the "or slow" output of the stress test. Every entry is a first-principle measurement
(cycle CSR / wall clock), per MC rules.

**What to measure as the subset grows:**

| Metric | Why it matters | How |
|--------|----------------|-----|
| `mcc2` compile speed vs Zig `mcc` | is MC-generated code competitive on a real workload? | wall time on the same input |
| Monomorphization blowup | per-import monomorph could explode at compiler scale | count distinct instantiations; generated-C size |
| Generated-C size (`mcc2` output) | codegen density | `wc -c` emitted C |
| clang time on `mcc2`'s emitted C | end-to-end toolchain cost | wall time |
| `Vec<T>` grow / `HashMap` insert throughput | container primitives are hot everywhere | cycle-count bench (Phase 0) |
| Peak memory (arena high-water) | allocate-and-never-free at scale | instrument arena |

## Measurements

_(append: phase, metric, workload, baseline, result, delta, commit)_
