# MC Compiler Implementation Test Plan

This plan turns the early normative parts of `MC_0.6.1_Final_Design.md` into executable milestones for the Zig implementation. The first test suite should be spec-driven: every fixture records the spec section, expected phase, expected result, and the observable condition a harness must verify.

## Scope

Initial implementation work should focus on a small MC-C0 profile before broad language coverage:

1. Parse enough MC syntax to accept the fixtures in `tests/spec`.
2. Build checked IR for arithmetic, traps, unsafe contracts, FFI declarations, ordinary memory, and MMIO access.
3. Run semantic verification before backend lowering.
4. Lower to C or a backend-inspection form without importing C undefined behavior as MC semantics.

Non-goals for the first suite:

1. Full optimizer implementation.
2. Full standard library implementation.
3. Complete hardware-specific MMIO execution tests.
4. Thread scheduler/runtime implementation.

## Harness Shape

Each `.mc` fixture starts with `// SPEC:` metadata. A Zig test runner can initially treat these as golden fixtures:

```txt
// SPEC: section=<design section>
// SPEC: phase=parse|sema|mir|lower-c|run
// SPEC: expect=pass|compile_error|trap|reject|inspect
// SPEC: check=<stable diagnostic, trap kind, or lowering invariant>
```

The runner should support four early modes:

1. `compile_pass`: source parses and verifies.
2. `compile_fail`: source is rejected with a stable diagnostic code.
3. `run_trap`: source reaches a specific language trap.
4. `lowering_inspect`: generated IR/C contains required helpers or does not contain forbidden assumptions.

Diagnostics should use stable symbolic codes instead of prose matching.

## Milestone 1: Arithmetic Semantics

Spec basis:

- Section 5.1: primitive integers are checked by default.
- `+`, `-`, `*` trap with `.IntegerOverflow` when the mathematical result is outside the destination range.
- `/` and `%` trap with `.DivideByZero` for zero divisors.
- Signed `min_value / -1`, `min_value % -1`, and unary `-min_value` trap with `.IntegerOverflow`.
- Unsigned unary `-` is not defined.
- Section G: C lowering must not use plain unsigned wrap for checked arithmetic, and signed checked arithmetic must avoid C signed overflow.

Initial fixtures:

- `tests/spec/arithmetic_checked.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| `u32` addition overflow | run | trap | `.IntegerOverflow` edge is emitted and reached |
| `u32` subtraction underflow | run | trap | `.IntegerOverflow` edge is emitted and reached |
| `u32` multiplication overflow | run | trap | `.IntegerOverflow` edge is emitted and reached |
| division by zero | run | trap | `.DivideByZero` edge is emitted and reached |
| `i32_min / -1` | run | trap | `.IntegerOverflow` before target division |
| `i32_min % -1` | run | trap | `.IntegerOverflow` before target remainder |
| unary `-i32_min` | run | trap | `.IntegerOverflow` before target negation |
| unary `-` on `u32` | sema | compile error | `E_UNSIGNED_NEGATION` |
| `checked<T>` and `wrap<T>` mixing | sema | compile error | `E_ARITH_POLICY_MIX` |
| C lowering for checked `+` | lower-c | inspect | overflow helper/check appears; plain wrapping expression is not the only operation |

## Milestone 2: `#[unsafe_contract]` Scoping

Spec basis:

- Section 1.3 and E.3: unchecked optimizer assumptions are explicit contract regions.
- `unchecked_add_assume_no_overflow` may appear only inside a `no_overflow` contract region.
- Backend optimizations may not change the scope of unsafe contract assumptions.
- LLVM backend notes: contract-derived metadata must not survive as persistent parameter, return, global, or call-site metadata outside the covered region unless independently proven.

Initial fixtures:

- `tests/spec/unsafe_contract_scope.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| unchecked add outside contract | sema | compile error | `E_UNCHECKED_OUTSIDE_CONTRACT` |
| unchecked add inside `no_overflow` | mir | pass | MIR contains a bounded `contract_region` |
| value used after contract | lower-c/IR | inspect | no contract-only overflow metadata is attached outside the region |
| false noalias contract | run/analysis | unspecified region only | harness records region boundary; no whole-program UB assumption |

## Milestone 3: `#[no_lang_trap]`

Spec basis:

- Section 20.1: compiler must not emit any language-trap edge from a `#[no_lang_trap]` function.
- Rejected operations include checked arithmetic, bounds checks, unwrap, assert, and reachable `unreachable`.
- Target faults are not language traps.

Initial fixtures:

- `tests/spec/no_lang_trap.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| checked add in `#[no_lang_trap]` | verifier | reject | `E_NO_LANG_TRAP_EDGE` |
| bounds-checked indexing in `#[no_lang_trap]` | verifier | reject | `E_NO_LANG_TRAP_EDGE` |
| wrapping add in `#[no_lang_trap]` | verifier | pass | no language-trap edge in MIR |
| opaque volatile asm in `#[no_lang_trap]` | verifier | pass | target-fault-capable operation is not classified as a language trap |

## Milestone 4: `c_void` FFI

Spec basis:

- Section 24: C ABI uses `*mut c_void` and `*const c_void`.
- `c_void` is not MC `void`.
- `c_void` has no size, alignment, fields, or valid dereference operation.
- Pointers to `c_void` may be passed, compared, and converted only through explicit FFI boundary operations.

Initial fixtures:

- `tests/spec/c_void_ffi.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| `extern "C"` declaration with `*mut c_void` | sema | pass | ABI type is accepted |
| dereference `*mut c_void` | sema | compile error | `E_C_VOID_DEREF` |
| `sizeof(c_void)` or alignment query | sema | compile error | `E_C_VOID_NO_LAYOUT` |
| using `*mut void` for C opaque pointer | sema | compile error | `E_MC_VOID_POINTER_FFI` |

## Milestone 5: Ordinary Data Races

Spec basis:

- Section 17: ordinary data races are bugs, but not optimizer-license UB.
- Compiler may not assume data races never happen.
- Ordinary loads/stores do not synchronize.
- Racing load result is target-defined, may tear subject to target width/alignment, and creates no happens-before edge.
- Section I.13: C backend must not lower possibly racing ordinary accesses to normal C accesses whose correctness depends on C data-race UB.

Initial fixtures:

- `tests/spec/data_race_semantics.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| local proven non-racing access | lower-c | inspect | normal C load/store allowed |
| shared possibly racing ordinary access | lower-c | inspect/reject | race-tolerant helper is used, or backend rejects emission |
| ordinary racing load | sema | pass with bug classification | no synchronization edge inferred |
| optimization over race | lower-c/IR | inspect | no metadata or transform assumes races impossible |

## Milestone 6: MMIO Ordering

Spec basis:

- Section 17: MMIO is typed and not ordinary volatile pointer arithmetic.
- Access mode, width, ordering, and layout are part of the type.
- `.acquire` read prevents later ordinary memory, atomic, DMA-descriptor, and MMIO operations from moving before the read.
- `.release` write prevents earlier ordinary memory, atomic, DMA-descriptor, and MMIO operations from moving after the write.
- Section I.14: backend must not merge, delete, widen, narrow, or reorder MMIO operations across ordering constraints.

Initial fixtures:

- `tests/spec/mmio_ordering.mc`

Test matrix:

| Case | Phase | Expected | Required Evidence |
| --- | --- | --- | --- |
| typed `.acquire` status read | sema/lower | pass | read width and ordering retained |
| typed `.release` data write | sema/lower | pass | write width and ordering retained |
| assignment to MMIO register field | sema | compile error | `E_MMIO_DIRECT_ASSIGN` |
| read/write reorder across acquire/release | lower-c/IR | inspect | emitted barriers or ordering markers prevent motion |
| MMIO access widening/narrowing | lower-c/IR | inspect | generated access width equals register width |

## Zig Implementation Work Split

Use separate implementation threads or sub-agents around stable artifacts:

1. Parser and fixture metadata reader: parse MC enough for the initial fixtures and expose expected test metadata to Zig tests.
2. Semantic verifier: implement stable diagnostics for arithmetic policy, `c_void`, MMIO direct assignment, unsafe contracts, and `no_lang_trap`.
3. Checked IR builder: emit explicit trap edges and `contract_region` boundaries.
4. C/backend lowering inspector: generate checkable text for arithmetic helpers, race-tolerant memory access, contract metadata containment, and MMIO barriers.
5. Test harness: map `tests/spec/*.mc` metadata to Zig `std.testing` cases and golden assertions.

These can progress independently as long as fixture metadata remains stable.

## Exit Criteria For The Initial Suite

The initial compiler milestone is complete when:

1. Every fixture in `tests/spec` is discovered by a Zig test runner.
2. Every `SPEC:` expectation is enforced by a stable assertion.
3. Arithmetic trap tests distinguish `.IntegerOverflow` from `.DivideByZero`.
4. `#[unsafe_contract]` tests prove region-local acceptance and out-of-region rejection.
5. `#[no_lang_trap]` tests inspect MIR after lowering to prove trap edges are absent.
6. `c_void` tests reject layout/deref use while accepting C ABI pointers.
7. Data-race lowering tests prove the backend does not rely on C data-race UB.
8. MMIO tests prove width, volatility, and ordering survive lowering.
