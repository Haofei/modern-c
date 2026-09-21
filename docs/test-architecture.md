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

- Kernel validation is RISC-V/QEMU-focused; language-level target coverage lives in the
  standalone target/asm gates, not in extra kernel ports.
- RISC-V demo runtimes carry inline asm but were compiled for the host.
- the precise-asm spec fixtures were assembled against the host default triple.
- `tests/c_emit/initialization.mc` held a *must-reject* function inside a *must-compile* glob.
- the spec sweeps forced *sema-diagnostic* fixtures through a *must-emit-C* path.

The fix in every case is the same shape: read the fixture's declared contract (below) and
route it to the matching expectation.

## Layers (cheapest reliable layer first)

| Layer | What it proves | Where | Speed |
|---|---|---|---|
| In-process unit tests | front-end/MIR/lowering logic | `zig build test` (`src/**` `test {}` blocks, incl. `src/spec_tests.zig`) | fast, no external tools |
| Emit + compile-check | emitted C/IR is well-formed for a target | `c-test`, `sweep`, `llvm-sweep`, `llvm-spec-obj-sweep`, `demo-test` | fast (clang/llc, no QEMU) |
| Differential / fuzz | C and LLVM backends agree; no soundness holes | `diff-backend`, `mcfuzz/*`, `move-fuzz` | fast, no QEMU |
| Host-driver execution | runtime behavior on the host | `tools/lib/host-tests.tsv` via `host-harness.sh` | medium |
| QEMU execution | real boot / low-level behavior | retained per-feature QEMU gates such as typed MMIO and trap checks | slow |

Aggregate lanes compose these: **`fast`** = spec + emit-C + differential (no fuzz/QEMU);
**`c0`** (spec §L.1) = unit + `c-test` + `sweep` + `demo-test`; **`c1`** (spec §L.2) =
`c0` + retained freestanding fixtures; **`m0`** = the deterministic compiler-core validation set;
it keeps C-backend smoke coverage but leaves the full `c-test` fixture sweep to
`fast`/`c0`/`m0-full`; **`m0-full`** = the full conformance set including fuzz,
host-driver fixtures, and QEMU.

## The expected-outcome taxonomy

A fixture declares exactly one expected outcome. The convention is now uniform across the
corpora:

| Outcome | How it is declared | Gate that owns it | Asserted by |
|---|---|---|---|
| **Compiles** | default (a file in the must-compile glob) | `c-test`, `demo-test`, the spec sweeps | emit-c/llvm + clang/llc succeed |
| **Rejected with a named diagnostic** | a `// EXPECT: E_CODE` line, in a `bad/` sibling dir | `c-test` (`tests/c_emit/bad/`), `demo-test` (`demo/bad/`), diagnostic inventory (`tests/diagnostics/bad/`) | `mcc check`/`emit-c` fails *and* stderr contains `E_CODE` |
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

- **arch** — the target ISA. For inline-asm fixtures it is the ISA the asm is written in. Gates compile per-arch
  or pin a deterministic triple (`llvm-spec-obj-sweep`,
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
- `tests/mir/<name>.mc` plus `tests/mir/<name>.expect` — the MIR dump corpus, walked by the
  one table-driven test in `src/mir_fixture_tests.zig`.
- `tests/mir_verify/<name>.mc` plus `tests/mir_verify/<name>.expect` — the MIR
  **verification-fact** corpus, walked by the one table-driven test in
  `src/mir_verify_fixture_tests.zig`. The text a rule matches is the verifier's findings
  (`mir verify fn=… pass=… finding=…`, one line per fact) followed by its diagnostics
  (`mir diagnostic <message>`, one line each). Both are in one text on purpose: the facts say
  what the verifier *found*, the diagnostics say what it *reported*, and a finding that stops
  being reported is a real regression, so a fixture asserts both halves the way the in-Zig
  test it replaced did.

  Both corpora share one `.expect` grammar, in `src/fixture_expect.zig`. A line is
  `+ "needle"` (must appear), `- "needle"` (must not), `= <n> "needle"` (exactly n times), or
  `>= <n> "needle"` (at least n times); `mode: raw|resolved|checked` names how far the front
  end runs before the dump is taken. A new MIR dump or verification expectation is two files
  in the matching directory, not another golden string in the unit suite.

  What stays in Zig beside these corpora is only what a dump cannot say: a module built or
  mutated by hand (no MC source produces it), and an assertion about the built MIR that the
  dump does not print — a `mmio_check` instruction in the stream, a range fact's `result_ty`.
  Those tests read their program from the fixture rather than keeping a second copy of it,
  and each says in a comment why it is not a fixture.
- Backend parity is encoded by the `llvm-*` twin gates (a C gate and its LLVM counterpart):
  parity means **same fixture, both backends, behavior agrees**, validated behaviorally by
  `diff-backend` and the differential fuzzers — not an artifact diff of emitted C vs IR.

## Adding a test

1. **A language accept/reject case** → a spec fixture under `tests/spec/` with a `// SPEC:`
   header (positive) or an `EXPECT_ERROR` declaration (negative); or, for backend-emit cases,
   a `tests/c_emit/*.mc` fixture (must-compile) or `tests/c_emit/bad/*.mc` (`// EXPECT: E_CODE`).
2. **A freestanding validation case** → put runnable behavior in a focused `tests/qemu/`
   fixture or a host harness; typestate misuses can still live in `tests/diagnostics/bad/` with an `EXPECT:`
   line for diagnostic inventory coverage.
3. **A runtime/driver behavior** → a row in `tools/lib/host-tests.tsv` (host) and/or a QEMU gate.
4. **A regression found by fuzzing** → distill it to a minimal fixture in the matching corpus,
   so it is locked in deterministically.
5. **A MIR dump expectation** → a `tests/mir/` fixture pair; **a MIR verifier expectation**
   (a finding, a diagnostic, or the exact count of either) → a `tests/mir_verify/` pair. Keep
   an in-Zig assertion only when the module is built or mutated by hand, which no MC source
   produces, or when what is asserted is not in the dump at all.

Whatever the layer: declare the contract (arch/profile/outcome) in the fixture, and the gate
will honor it.
