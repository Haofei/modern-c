# Lowering-coverage instrumentation (hardening V3.2)

A repeatable way to measure which functions of the two backends —
`src/lower_c.zig` (C backend) and `src/lower_llvm.zig` (LLVM backend) — the
differential corpus actually exercises, and to **report the UNCOVERED ones**.
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
   function in the two backend files (615 in `lower_c.zig`, 326 in
   `lower_llvm.zig`).
2. `lowering-coverage.sh` builds that instrumented `mcc`.
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
branch). The two backend files are restored from backup on script exit, so the
tree stays clean.

## Current headline (99 host fixtures + 60 mcfuzz programs)

| file | covered | uncovered | % |
| --- | --- | --- | --- |
| `src/lower_c.zig` | 446 / 615 | **169** | 72.5% |
| `src/lower_llvm.zig` | 278 / 326 | **48** | 85.3% |

> **Caveat on the LLVM number.** The diff-backend harness *skips* any fixture the
> LLVM backend cannot yet lower, and the fuzzer's LLVM path is narrower than its C
> path. So `lower_llvm.zig`'s 85.3% over-states how much is *differentially
> compared* against the C backend — several uncovered LLVM functions below are the
> ones that would actually catch a divergence if exercised.

## Notable uncovered lowering branches (actionable)

These are the divergence-prone families never entered by the corpus — the
highest-value targets for new differential fixtures. (`function:line`, current
positions.)

### C backend (`lower_c.zig`)

- **MMIO read in non-trivial positions** — the family closest to the overlay-read
  bug class: `emitMmioReadAssert:2898`, `emitMmioReadOperandTemp:4344`,
  `emitMmioReadCallArgTemp:3006`, `emitMmioReadCallArgTemps:3014`,
  `emitMmioReadInferredLocalInit:4391`, `emitMmioReadExprInferredLocalInit:4366`,
  `emitCheckedUnaryWithMmioReplacements:5846`,
  `emitPackedBitsMaskTestWithMmioReplacements:5934`,
  `mmioReadReplacementValueTypeForExpr:11932`, `mmioAccess:10959`,
  `collectMmioStruct:10463`.
- **Overlay / packed-bits lowering & source-map** — `writeOverlayUnionLowering:10455`,
  `writePackedBitsLowering:10447`, `overlayByteArrayLen:11861`,
  `cTaggedUnionTagSize:11285`, `emitTaggedUnionCallInferredLocalInit:6998`.
- **Atomics** — `atomicAccess:12084`, `atomicOrderSynchronizes:12190`,
  `isAtomicInitCallee:6304`, `writeAtomicCallMetadata:10870`.
- **DMA** — `dmaOperation:12114`, `dmaAddrHandoffObject:12152`,
  `writeDmaCallMetadata:10893`.
- **Arithmetic-domain / wrap / trap classification** —
  `writeArithmeticDomainLowering:10776`, `arithmeticDomainForBinary:12279`,
  `isWrapPreservingBinary:12027`, `trapKindForBinary:12264`,
  `trapHelperForKind:12065`, `exprHasArithmeticDomain:12285`,
  `hasMirNoOverflowRangeFact:8481`.
- **Float-reduce / bitcast inferred-local** — `emitFloatReduceCall:5190`,
  `writeFloatReduceMetadata:10726`, `emitBitcastInferredLocalInit:8068`,
  `writeBitcastMetadata:10939`, `emitConversionBoundTemp:4842`.
- **Inline-asm metadata** — `asmHasMemoryClobber:12173`, `writeAsmMetadata:10950`.

(Plus a tail of public-API entry-point wrappers — `appendC`, `appendCProfile`,
`appendInspection`, `appendCSourceMap`, `appendMapString*` — that `emit-c`/
`emit-map` don't route through; these are *not* miscompile risks, just alternate
entry points. The full list is `zig-out/lowering-cov/uncovered_lower_c.txt`.)

### LLVM backend (`lower_llvm.zig`)

The cross-backend-comparable trap/conversion/string paths the diff corpus never
reaches on the LLVM side:

- **Trap & unwrap checks** — `emitAssert:1104`, `emitNullUnwrapCheck:1167`,
  `emitResultUnwrapCheck:1159`, `emitTrapConversion:2912`, `trapHelperForKind:5782`.
- **Conversions** — `emitSaturatingConversion:2922`,
  `emitConversionOutOfRange:3045`, `emitTryConversion:3030`.
- **Wrap shift / domain ops / float reduce** — `emitWrapShift:3175`,
  `emitDomainOpCall:3360`, `emitReduceFloat:3495`.
- **String literals** — `emitStringLiteral:3576`, `internStringLiteral:3585`,
  `llvmStringLiteralBytes:5377`, `stringLiteralText:5386`.
- **Atomics / packed-bits / DMA / asm** — `atomicInitValue:5564`,
  `isAtomicInitExpr:5520`, `packedBitsComptimeValue:4203`, `dmaBufInfo:4691`,
  `llvmAsmClobbers:5341`.

Full list: `zig-out/lowering-cov/uncovered_lower_llvm.txt`.

## Acting on it

To close a row, add a differential fixture to `tools/lib/host-tests.tsv` (or a
generator case to `tools/fuzz/mcfuzz.py`) that drives the construct through **both**
backends, then re-run `zig build lowering-coverage` and confirm the function moves
out of the uncovered list. The MMIO-read and overlay/packed-bits families are the
priority, being adjacent to the known overlay-read miscompile.
