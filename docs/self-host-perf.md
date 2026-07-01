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

**2026-07-01 — `mcc2` CLI throughput on subset source (mcc2-cli-test, commit `2ac36e7`).**
Workload: 1000 generated subset functions (`fn f_N(a,b:u32)->u32 { let/let/return }`), 98,780 bytes.

| Metric | Value |
|--------|-------|
| Input | 98,780 bytes, 1000 functions |
| `mcc2` wall (lex→parse→sema→emit→stdout) | **~0.048 s** |
| Throughput | **~20,800 functions/sec ≈ 2.0 MB source/sec** |
| Emitted C | 117,821 bytes |
| `clang -O0` wall on the emitted C | ~0.073 s |

**Verdict: `mcc2` is fast.** Its entire front-end+emit pipeline (48 ms) costs *less* than clang's
`-O0` compile of the C it produces (73 ms). No allocator/scaling pathology at 1000 fns (linear).
**Known ~2× headroom:** the CLI runs `sema_check` (which lexes+parses) and then `emit_c_run`
(which lexes+parses again) — feeding emit from the already-parsed arena would roughly halve mcc2's
wall. Not yet done (correctness first). Fixed input ceiling: 1 MiB (`global g_src:[1048576]u8`;
can't build `[]const u8` from a malloc'd ptr+len — gap G12).

_(append: phase, metric, workload, baseline, result, delta, commit)_
