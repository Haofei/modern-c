# Test architecture

How the MC test suite is organized, what contract each fixture declares, and the
invariant every gate must uphold. This is the reference the test-refactor plan builds on:
the suite already has the pieces (a manifest, parity twins, conformance lanes, a reject
convention); this document makes the **fixture contract** explicit so gates stop drifting
from it.

## The one invariant

> **A gate must exercise each fixture under the configuration the fixture's contract
> declares — its target ISA, its compile profile, and its expected outcome — never one
> fixed configuration applied blindly to the whole corpus.**

Every fixture-semantics bug this suite has had was a violation of this invariant: a gate
globbed a directory and compiled *everything* one way. Concretely:

- `kernel/arch/x86_64/*.mc` carry x86 inline asm but were compiled for riscv64.
- `demo/virtio-net/runtime.mc` carries RISC-V inline asm but was compiled for the host.
- the precise-asm spec fixtures were assembled against the host default triple.
- `tests/c_emit/initialization.mc` held a *must-reject* function inside a *must-compile* glob.
- the spec sweeps forced *sema-diagnostic* fixtures through a *must-emit-C* path.

The fix in every case is the same shape: read the fixture's declared contract (below) and
route it to the matching expectation.

## Layers (cheapest reliable layer first)

| Layer | What it proves | Where | Speed |
|---|---|---|---|
| In-process unit tests | front-end/MIR/lowering logic | `zig build test` (`src/**` `test {}` blocks, incl. `src/spec_tests.zig`) | fast, no external tools |
| Emit + compile-check | emitted C/IR is well-formed for a target | `c-test`, `sweep`, `llvm-sweep`, `llvm-spec-obj-sweep`, `kernel-test`, `demo-test` | fast (clang/llc, no QEMU) |
| Differential / fuzz | C and LLVM backends agree; no soundness holes | `diff-backend`, `mcfuzz/*`, `move-fuzz` | fast, no QEMU |
| Host-driver execution | runtime behavior on the host | `tools/lib/host-tests.tsv` via `host-harness.sh` | medium |
| QEMU execution | real boot / device / network behavior | the per-feature QEMU gates (`virtio-test`, `https-get-test`, …) | slow |

Aggregate lanes compose these: **`fast`** = unit + emit-C + differential/fuzz (no QEMU);
**`c0`** (spec §L.1) = unit + `c-test` + `sweep` + `demo-test`; **`c1`** (spec §L.2) =
`c0` + `kernel-test`; **`m0`** = the full conformance set including QEMU.

## The expected-outcome taxonomy

A fixture declares exactly one expected outcome. The convention is now uniform across the
corpora:

| Outcome | How it is declared | Gate that owns it | Asserted by |
|---|---|---|---|
| **Compiles** | default (a file in the must-compile glob) | `c-test`, `kernel-test`, `demo-test`, the spec sweeps | emit-c/llvm + clang/llc succeed |
| **Rejected with a named diagnostic** | a `// EXPECT: E_CODE` line, in a `bad/` sibling dir | `c-test` (`tests/c_emit/bad/`), `kernel-test` (`kernel/bad/`), `demo-test` (`demo/bad/`) | `mcc check`/`emit-c` fails *and* stderr contains `E_CODE` |
| **Rejected (spec, per-declaration)** | a `// SPEC: ... EXPECT_ERROR` comment on the negative declaration | the spec sweeps strip it; `src/spec_tests.zig` validates the rejection | declaration removed before emit; reject checked in `spec_tests.zig` |
| **Not lowerable (checker-only)** | a `phase=sema` fixture whose `check=` is all `E_*` diagnostics | `src/spec_tests.zig` (not the emit sweeps) | listed in the sweep's `OUT_OF_SCOPE` with a documented reason |
| **Runtime output** | `tools/lib/host-tests.tsv` row, or a QEMU gate's expected serial/pcap | the host-harness / per-gate QEMU script | captured output matches |

Two rules keep the taxonomy honest:

1. A **`bad/` reject fixture** must name the diagnostic it expects (`EXPECT:` / `EXPECT_ERROR`),
   and the gate must assert that *specific* code — not merely that compilation failed.
2. An **`OUT_OF_SCOPE` entry** must carry a reason and point at the gate that *does* own the
   fixture's contract. A fixture with a real `lower-*` check may never be allowlisted there —
   that would hide a genuine emit regression. Exclusions are printed by the gate, never silent.

## Per-fixture contract dimensions

Beyond the outcome, a fixture (or its manifest row) carries the axes a gate must honor:

- **arch** — the target ISA. For kernel modules it is the `kernel/arch/<arch>/` path; for
  inline-asm fixtures it is the ISA the asm is written in. Gates compile per-arch
  (`kernel-test`, `llvm-kernel-test`) or pin a deterministic triple (`llvm-spec-obj-sweep`,
  `demo-test`) — never the host default.
- **profile** — kernel vs hosted (the C0/C1 split); selects CFLAGS (`-ffreestanding`,
  `-mcmodel`, …).
- **mode** — for host-driver tests, `entry` (a named entry fn + `spec`) vs `driver`
  (a `main`); see the `mode` column in `tools/lib/host-tests.tsv`.
- **mcc_flags** — per-fixture `-Wno-*` etc. (the `mcc_flags` column in the manifest).
- **phase / check / expect** — for spec fixtures, the `// SPEC:` header
  (`phase=parse,sema,lower-c,lower-ir,verifier`; `check=` a diagnostic `E_*` or a `lower-*`
  fact; `expect=pass,compile_error,...`). `src/spec_tests.zig` is the authoritative reader of
  this header and classifies each `check` as `diagnostic` / `ir_fact` / `lower_c` /
  `unsupported`.

## Manifests (the source of truth, extend — don't rebuild)

- `tools/lib/host-tests.tsv` — the host-driver test manifest (`name · fixture · mode · spec ·
  mcc_flags · description`). New host-driver tests are rows here, run by `host-harness.sh`.
- The `// SPEC:` headers across `tests/spec/*.mc` — the conformance manifest, read by
  `src/spec_tests.zig`.
- Backend parity is encoded by the `llvm-*` twin gates (a C gate and its LLVM counterpart):
  parity means **same fixture, both backends, behavior agrees**, validated behaviorally by
  `diff-backend` and the differential fuzzers — not an artifact diff of emitted C vs IR.

## Adding a test

1. **A language accept/reject case** → a spec fixture under `tests/spec/` with a `// SPEC:`
   header (positive) or an `EXPECT_ERROR` declaration (negative); or, for backend-emit cases,
   a `tests/c_emit/*.mc` fixture (must-compile) or `tests/c_emit/bad/*.mc` (`// EXPECT: E_CODE`).
2. **A kernel module / typestate misuse** → it is picked up by `kernel-test`'s glob; a misuse
   goes in `kernel/bad/` with an `EXPECT:` line.
3. **A runtime/driver behavior** → a row in `tools/lib/host-tests.tsv` (host) and/or a QEMU gate.
4. **A regression found by fuzzing** → distill it to a minimal fixture in the matching corpus,
   so it is locked in deterministically.

Whatever the layer: declare the contract (arch/profile/outcome) in the fixture, and the gate
will honor it.
