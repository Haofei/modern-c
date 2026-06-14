# mcfuzz — remaining coverage gaps

What the type-directed fuzzer (`tools/fuzz/mcfuzz.py`) does **not** cover yet, ranked by
value-to-close. The scalar/value/control-flow core is well covered (see the "done" list in
`mcfuzz-coverage-todo.md`); this doc is the forward gap list.

Status legend: `[x]` done · `[ ]` open · `[~]` partial · `[blocked]` needs a backend/architecture change first.

## Progress (2026-06-14)

**Done:** G1 reference interpreter (`fuzz-reference`, `tools/fuzz/mcref.py` — independent Python
evaluator over the unsigned-int core; closes the shared-frontend blind spot), G3 aggregate ABI,
G4 float bit-level oracle (`fuzz-floatbits`), G10 recursion, G16 second metamorphic transform
(reverse-fold), G17 `report` coverage mode, G18 pipeline extended to all lowering stages
(lower-hir/verify-hir/lower-mir/verify/lower-ir/facts/emit-c/emit-map/emit-llvm). Eleven oracles
now; all green at the gate.

**Done (second pass, 2026-06-14):**
- **G14** deeper aggregates — tuples (incl. tuples-of-aggregates), structs-of-pointers,
  arrays-of-`Result`; all verified through both backends, each ~50% of seeds.
- **G12 / partial G8** — `mem.as_bytes(&intArray)` is the one slice-construction form that lowers
  through both backends; over a contiguous, fully-initialized integer array its bytes are a sound,
  backend-stable observable. The generator now builds such a `[]const u8` and exercises it via
  `reduce.sum_checked<u8>` (the hot checked-reduction path) and a bounds-checked `bv[i]`/`.len`
  loop. (~46% of seeds.) Note: switching directly on the `reduce.*` builtin call doesn't lower —
  it goes through a wrapper fn; the `arr[0..n]` general-slice form is still blocked (G8).
- **G17 corpus** — `tools/fuzz/corpus/*.mc` freezes the three fixed codegen bugs as minimized
  repros; `mcfuzz.py corpus` + `fuzz-corpus` gate replay them through differential+sanitize.

**Backend-limited (discovered this pass):** G11 expression-`switch` — `var r = switch e {…}`
fails `emit-llvm`; statement/fold switch only.

**Done this pass too:** G2 kernel surface (runnable subset) — atomics + packed-bits registers now
fuzzed by all 11 oracles. The non-runnable kernel features (MMIO/address-classes/overlay/DMA/asm)
are left to the sema + QEMU fixtures (they have no in-process digest-foldable observable).

**Still blocked/covered:** G5–G9, G12–G15. These need net-new **compiler/backend features**, not
fuzzer work: array→slice construction with bounds-checked dual-backend lowering (unblocks
G6/G8/G12/G14 at once), tagged-union codegen (G7), expression-`switch` LLVM lowering (G11),
cross-domain conversion runnable surface (G13), interceptable trap entrypoints (G5), and an
in-process coverage harness (G15). G9 is covered by `mcgen_move.py`.

**Bonus bug found + fixed this pass:** probing slice construction surfaced a real sema hole —
`as_slice`/`dma_addr` on a *non-DmaBuf* value (e.g. `someArray.as_slice()`) passed `check` (typed
as a slice) but failed only at LLVM lowering (`UnsupportedLlvmEmission`), a check-vs-backend
inconsistency. Fixed in `src/sema.zig` (emits `E_DMA_OPERATION`); regression cases in
`tests/spec/dma_cache.mc`.

---

## P0 — highest leverage

### G1 `[x]` Reference interpreter (the shared-frontend blind spot) — DONE (`fuzz-reference`)
Every value oracle except `pipeline`/`failclosed` compares C vs LLVM (or a program against
itself), so a bug in the **shared frontend / verifier / constant-folder** is invisible — a case
where both backends *agree but are wrong* slips through. (The verifier bug was only caught
because `pipeline` is a status oracle.)
- **Done:** `tools/fuzz/mcref.py` is a self-contained generator over the **unsigned-integer
  core** (plain/wrap/sat domains, modular conversions, comparisons, if/else, bounded `while`,
  early return). It renders MC from a single typed AST **and** evaluates that same AST in pure
  Python; the `reference` oracle asserts the compiled output equals the Python value.
- **Soundness:** only unsigned types (so `as u64` is unambiguous zero-extension) and only
  trap-free ops are generated, so a trap or a mismatch is necessarily a real compiler bug — it
  can never emit a false finding. Validated 1000/1000 seeds = C backend, zero skips.
- **Not yet modelled (deliberately out, to stay sound):** signed `as u64`, floats (fold-by-
  comparison semantics), structs/enums/Result/pointers/closures. These can be added to `mcref`
  incrementally once each one's exact semantics is pinned down.

### G2 `[~]` Kernel / driver surface (MC's actual target domain) — runnable subset DONE
mcfuzz generates portable compute and touched **none** of the features the spec exists for
(sections 16–20, 28). The features split by whether the in-process digest model can *run* them:
- **DONE (runnable, now fuzzed by all 11 oracles):**
  - **Atomics** — single-threaded `atomic<uN>` (init/store/fetch_add/fetch_sub/load) with
    spec-correct orderings; loaded/returned values fold into the digest. (~41% of seeds.)
  - **Packed-bits** registers — struct of bool fields over u8/u16/u32 storage, no C bitfields;
    fields set and read into the digest. (~51% of seeds.)
- **Not cleanly fuzzable by the in-process value oracles (deliberately left to sema/QEMU
  fixtures):**
  - **MMIO** typed registers (`Reg<T,.read/.write>`) — need real memory-mapped addresses; not
    runnable in a hosted process.
  - **Address-space types** (`PAddr`/`VAddr`/user/dma) — can't be dereferenced, so nothing folds;
    they are typing rules, already covered by `tests/spec/address_classes.mc` (a fail-closed
    surface) — could be added to the `failclosed` oracle but not the value oracles.
  - **Overlay unions** — runtime construction needs an explicit conversion and the spec exercises
    them reflection-only (`field_offset`), so there is no runnable construct/read pattern (blocked
    like slices, G8).
  - **DMA/cache, memory barriers, concurrency** — ordering/ownership semantics with no
    digest-foldable single-threaded observable.
  - **Inline assembly** — opaque / target-specific, not portable to host execution.

### G3 `[x]` Aggregate ABI (cheapest concrete win) — DONE
Helper functions only take and return **scalars**. The by-value ABI for aggregates is unfuzzed.
- **Do:** generate helper functions with struct / array / tuple / `Result` **parameters** and
  **return values**; harness calls them and folds the result.
- **Effort:** low–medium (extend `gen_functions`).

---

## P1 — generated-but-can't-detect (observation gaps)

### G4 `[x]` Float bit-level precision — DONE (`fuzz-floatbits`)
f32/f64 are folded by **comparison**, not bitcast, so ~1-ULP divergences are hidden (the f32
double-rounding bug needed a separate bit-level check). A bitcast fold would flake on NaN/inf.
- **Do:** a dedicated f32/f64 oracle that bitcast-compares **finite** results only (skip NaN/inf
  via an `is_finite` guard), so it observes the bits without flaking.

### G5 `[blocked-on-backend]` Trap-location agreement (E8)
The trapping differential only checks "both backends trap," not "at the same logical site/kind."
- **Analysis:** both backends *do* route through per-kind `mc_trap_<Kind>` symbols (C emits them
  `static inline __builtin_trap()`; LLVM links the test's extern stubs). So trap-kind agreement is
  observable in principle — but only by making **both** builds report the kind. The C side's trap
  functions are `static inline`, so this needs a small backend change to emit traps *interceptably*
  (e.g. a weak/extern trap entrypoint a test can define), not fragile string-surgery on generated
  C. That is net-new backend instrumentation, deferred.

### G6 `[blocked]` Memory-safety oracle (E5)
Pointers only target globals (no heap). Byte-view slices now exist (G8/G12), but MC slice
indexing is **bounds-checked** — an out-of-bounds access *traps* (a `mc_trap`) before it can
become a memory error, so ASan still finds nothing. A useful G6 needs heap allocation or raw
unchecked pointer arithmetic, neither of which has a runnable generated surface today. (The
bounds-check *trap* itself is observable and could feed a trap-consistency oracle, but that's
trap-location/G5 territory, not ASan.)

---

## P2 — language features not generated

- G7 `[blocked]` **Tagged unions with payload (A2)** — backend can't lower them (even the spec's
  `ReflectToken` fails both `emit-c`/`emit-llvm`). Needs tagged-union codegen first.
- G8 `[~]` **Slices `[]T` (A5)** — the general `arr[0..n]` form is still blocked
  (`E_NO_IMPLICIT_POINTER_CONVERSION`), but the **byte-view** slice `mem.as_bytes(&intArray)` now
  lowers through both backends and is fuzzed (see G12): a real `[]const u8` with `.len`, indexing,
  and reduction. Full `[]T` of arbitrary element type still needs net-new construction lowering.
- G9 `[ ]` **Aggregate function params/returns of `move` types**, and **`move`/`defer`** in
  mcfuzz (today only in `mcgen_move.py` — covered there, just not in the type-directed framework).
- G10 `[x]` **Recursion** — DONE (depth-bounded `recf(n)=n+recf(n-1)`, base `n==0`).
- G11 `[blocked]` **`switch` as an expression** — `emit-llvm` rejects it; statement/fold switch
  only. (`defer` in non-move contexts still open.)
- G12 `[~]` **Hot checked reductions** — DONE: `reduce.sum_checked<u8>` over a byte-view slice is
  now fuzzed (see G8). Floating reductions (`reduce.sum_left`/`sum_fast`) need a `[]const fN` slice
  which has no runnable construction form, and closure captures of *locals* still hit a C-emit gap
  (only global-env captures work) — both still open.
- G13 `[blocked]` **Cross-domain conversions (C4)**, **`extern fn` calls (D2)**, **multi-module /
  imports (D5)** — no clean/runnable surface today.
- G14 `[x]` Deeper aggregates: structs-of-pointers, arrays-of-`Result`, tuples-of-aggregates —
  DONE (all three lower through both backends, ~50% of seeds each). Union/slice-of-aggregate forms
  stay blocked on G7/G8.

---

## P3 — methodology / infrastructure

- G15 `[blocked]` **Coverage-guided / byte-seed fuzzing (F1)** — the subprocess-per-seed model
  can't do in-process coverage feedback; needs a persistent/in-process harness.
- G16 `[~]` **Mutation-based *semantic* fuzzing** — metamorphic oracle now has two
  semantics-preserving transforms (body-in-helper + reverse digest fold); more could be added.
  (Original wording:) of valid programs (vs only crash/hang mutation
  in `robust`).
- G17 `[x]` **`report` coverage mode + persisted regression corpus** — DONE. `mcfuzz.py report`
  tallies construct coverage; `tools/fuzz/corpus/*.mc` + `mcfuzz.py corpus` + the `fuzz-corpus`
  gate replay the three fixed codegen bugs as permanent regression gates. (Source is frozen rather
  than bare seeds, since the generator drifts.)
- G18 `[x]` **`facts` / `emit-map` / `lower-hir/-mir/-ir` in the pipeline oracle** (E4) — DONE.
  (Original also mentioned:) and
  **round-trip / idempotence** (E6).

---

## Recommended order
1. ~~**G1** reference interpreter~~ — DONE (unsigned-int core). Extend `mcref` to signed/floats
   /aggregates next, once each one's exact `as u64`/fold semantics is pinned down.
2. ~~**G3** aggregate ABI~~ — DONE.
3. ~~**G2** kernel/driver surface~~ — runnable subset DONE (atomics + packed-bits). Non-runnable
   features (MMIO/address-classes/overlay/DMA/asm) stay as sema/QEMU fixtures.
4. ~~**G4** float bit oracle~~ — DONE.
5. ~~**G14** deeper aggregates~~, ~~**G12** hot checked reductions / byte-view slices~~,
   ~~**G17** corpus~~ — DONE.

## What remains (all blocked on net-new compiler/backend features, not fuzzer work)
Every gap that is implementable as pure fuzzer/generator/oracle work is now closed. The remainder
each require a compiler change first, after which the fuzzer hook is small:
- **G7** tagged-union payload codegen — both backends reject even the spec's `ReflectToken`.
- **G8 (full)** general `arr[0..n]` → `[]T` slice construction for an arbitrary element type
  (byte-view `[]const u8` already works). Unblocks G6/G14-of-slices and floating reductions.
- **G11** expression-`switch` LLVM lowering.
- **G13** cross-domain conversions / `extern fn` / multi-module runnable surface.
- **G5** interceptable trap entrypoints (the C side's `mc_trap_*` are `static inline`).
- **G6** heap / raw unchecked pointers (bounds-checked slices trap before ASan sees anything).
- **G15** in-process coverage feedback (the subprocess-per-seed model can't do it).
- **G9** is covered by `mcgen_move.py`; folding `move`/`defer` into the type-directed digest model
  is duplicative and risks unsoundness, so it stays in the dedicated generator.
