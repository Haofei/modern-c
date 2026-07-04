# Lowering-coverage instrumentation (hardening V3.2)

A repeatable way to measure which functions of the split backend modules —
`src/lower_c*.zig` (C backend) and `src/lower_llvm*.zig` (LLVM backend), excluding
tests/instrumentation — the differential corpus actually exercises, and to
**report the UNCOVERED ones**.
Divergence-prone lowering paths that no fixture or fuzz program ever hits are
exactly where backend miscompiles hide: the overlay-read miscompile (V-series)
lived in such an uncovered branch, where the C and LLVM lowerings of the same
construct silently disagreed because nothing differentially compiled it.

Regenerate the report:

```sh
bash tools/toolchain/lowering-coverage.sh        # or: zig build lowering-coverage
```

## Mechanism and fidelity (honest)

There is **no `kcov`** in the dev image, and **Zig 0.16's self-hosted compiler
exposes no `-fprofile-instr-generate` / source-coverage flag** for its own output
(`llvm-cov`/`llvm-profdata` are installed but only instrument LLVM-emitted
binaries, which the Zig compiler does not produce for `mcc` here). So true
`llvm-cov` line/branch coverage of the `mcc` binary is **not available**.

Instead this is **function-level coverage by source instrumentation**:

1. `tools/toolchain/lowering-cov-instrument.py` injects a
   `lower_cov.hit("<file>:<fn>:<line>")` probe as the first statement of every
   function in every production backend file (currently 40 C backend files and
   12 LLVM backend files).
2. `lowering-coverage.sh` copies the checkout to a temporary work directory,
   instruments that copy, and builds the instrumented `mcc` there. The main
   checkout is not rewritten, so the gate is safe inside aggregate/parallel
   runs such as `m0` and `tools/m0-parallel.sh`.
3. It runs the instrumented `mcc` — `emit-c` (kernel **and** hosted profiles) and
   `emit-llvm` — over **(a)** every diff-backend host fixture
   (`tools/lib/host-tests.tsv`) and **(b)** a batch of `tools/fuzz/mcfuzz.py`
   generated programs. Each invocation writes its fired-function set to a
   per-invocation file named by the `MC_LOWER_COV` env var (`src/lower_cov.zig`).
4. The union of fired sets, subtracted from the universe of probes, is the
   **uncovered** list.

A function counts as covered if it was **entered at least once**. This is coarser
than branch coverage — it cannot tell you an *if-branch inside a covered function*
went untaken — but it is precisely the granularity that surfaces "this whole
lowering family is never exercised," which is the V3.2 target. The instrumentation
is gated on `MC_LOWER_COV`; a normally-built `mcc` pays nothing (a single dead
branch). The script instruments a temporary checkout by default, so the main tree
stays clean and aggregate gates can run it safely.

The checked build step also ratchets the source set, probe universe, and uncovered
counts via `tools/toolchain/lowering-coverage-baseline.tsv`; a shrinking source set
or a growing uncovered count fails `zig build lowering-coverage`.

## Current headline (170 host fixtures + 60 mcfuzz programs)

| file | covered | uncovered | % |
| --- | --- | --- | --- |
| `src/lower_c*.zig` | 1038 / 1306 | **268** | 79.5% |
| `src/lower_llvm*.zig` | 353 / 409 | **56** | 86.3% |

> **Caveat on the LLVM number.** The diff-backend harness *skips* any fixture the
> LLVM backend cannot yet lower, and the fuzzer's LLVM path is narrower than its C
> path. So the `lower_llvm*.zig` percentage over-states how much is *differentially
> compared* against the C backend — several uncovered LLVM functions below are the
> ones that would actually catch a divergence if exercised.

## Notable uncovered lowering branches (actionable)

These are examples of divergence-prone families still present in the current smoke
baseline. Use `zig-out/lowering-cov/uncovered_lower_*.txt` after a fresh run as the
authoritative list; line numbers move frequently across backend refactors.

### C backend (`lower_c*.zig`)

- **Alternate public entry points** — `lower_c.zig:appendC`,
  `appendCProfile`, `appendCSourceMap`, `appendInspection`, `appendLayoutAsserts`,
  and `appendStructDecls`. These are usually not miscompile risks; they indicate
  commands such as `emit-map`/layout inspection are not part of the coverage corpus.
- **Index/address temp paths** — `lower_c_access.zig` functions such as
  `emitDirectCallArrayIndexAddressValueTemp`, `emitDirectCallSliceIndexValueTemp`,
  and `emitLocalSliceIndexStore`.
- **Aggregate temp paths** — `lower_c_aggregate.zig` functions such as
  `emitArrayLiteralWithTemps`, `emitStructLiteralWithTemps`, and
  unchecked-add aggregate call-argument helpers.
- **Inline asm / atomics / float reduce** — `lower_c_asm.zig:emitAsmStmt`,
  `lower_c_atomic.zig:asmHasMemoryClobber`, and
  `lower_c_arith.zig:emitFloatReduceCall`.

Full list: `zig-out/lowering-cov/uncovered_lower_c.txt`.

### LLVM backend (`lower_llvm*.zig`)

The cross-backend-comparable trap/conversion/string paths the diff corpus never
reaches on the LLVM side:

- **Trap, unwrap, and conversion checks** — `emitAssert`, `emitNullUnwrapCheck`,
  `emitResultUnwrapCheck`, `emitTrapConversion`, `emitSaturatingConversion`,
  `emitConversionOutOfRange`, and `emitTryConversion`.
- **Variadic ABI paths** — `emitVaArg`, `emitAarch64VaArg`,
  `emitVaListCursorArg`, and related va_list cursor helpers.
- **Reflection / global address / packed bits / DMA** — examples include
  `comptimeFieldOffset`, `globalAddressInitializer`, `packedBitsComptimeValue`,
  and `dmaBufInfo`.
- **Inline asm and reduce helpers** — `emitAsmStmt`, `emitPreciseAsmStmt`,
  `emitReduceCall`, `emitReduceFloat`, and `emitReduceSumChecked`.

Full list: `zig-out/lowering-cov/uncovered_lower_llvm.txt`.

## Acting on it

To close a row, add a differential fixture to `tools/lib/host-tests.tsv` (or a
generator case to `tools/fuzz/mcfuzz.py`) that drives the construct through **both**
backends, then re-run `zig build lowering-coverage` and confirm the function moves
out of the uncovered list. The MMIO-read and overlay/packed-bits families are the
priority, being adjacent to the known overlay-read miscompile.

## Closed rows (differential gates added)

- **MMIO-read-in-non-trivial-position** (the family adjacent to the overlay-read
  miscompile) — `fuzz-mmio-read-positions-test`
  (`tests/c_emit/fuzz_mmio_read_positions.mc`). Drives a typed `Reg`/`RegBits` read
  through the inferred-local-init, call-argument, checked-unary-operand, and
  packed-bits-mask-test positions over a host-backed device window. C and LLVM agree.
- **Atomics** (`atomicAccess` / order-synchronizes family) — `fuzz-atomics-test`
  (`tests/c_emit/fuzz_atomics.mc`). `atomic<T>` load/store/fetch_add/fetch_sub
  across all five memory orders, 32- and 64-bit, including inferred RMW result
  locals for u64 and signed payloads plus nested result expressions in call
  arguments, arithmetic operands, and casted arithmetic operands. C and LLVM agree.
