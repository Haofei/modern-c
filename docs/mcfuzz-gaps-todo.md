# mcfuzz — remaining coverage gaps

What the type-directed fuzzer (`tools/fuzz/mcfuzz.py`) does **not** cover yet, ranked by
value-to-close. The scalar/value/control-flow core is well covered (see the "done" list in
`mcfuzz-coverage-todo.md`); this doc is the forward gap list.

Status legend: `[x]` done · `[ ]` open · `[~]` partial · `[blocked]` needs a backend/architecture change first.

## Progress (2026-06-14)

**Done:** G3 aggregate ABI, G4 float bit-level oracle (`fuzz-floatbits`), G10 recursion,
G16 second metamorphic transform (reverse-fold), G17 `report` coverage mode, G18 pipeline
extended to all lowering stages (lower-hir/verify-hir/lower-mir/verify/lower-ir/facts/emit-c/
emit-map/emit-llvm). Ten oracles now; all green at the gate.

**Backend-limited (discovered this pass):** G11 expression-`switch` — `var r = switch e {…}`
fails `emit-llvm`; statement/fold switch only.

**Still large/blocked:** G1 (reference interpreter), G2 (kernel/driver surface) — the two big
P0 items; plus G5–G9, G12–G15 (blocked on backend features, covered elsewhere, or architecture).

---

## P0 — highest leverage

### G1 `[ ]` Reference interpreter (the shared-frontend blind spot)
Every value oracle except `pipeline`/`failclosed` compares C vs LLVM (or a program against
itself), so a bug in the **shared frontend / verifier / constant-folder** is invisible — a case
where both backends *agree but are wrong* slips through. (The verifier bug was only caught
because `pipeline` is a status oracle.)
- **Do:** evaluate `harness()` from the AST/HIR in Python and assert the digest equals the
  compiled output.
- **Risk:** a subtly-wrong interpreter yields *false* findings. Build it **conservatively** —
  model the domains' exact semantics (checked-trap / wrap-modular / sat-clamp / conversions /
  enum discriminants / Result / pointers-to-globals), and **skip** (return None) any program it
  can't fully evaluate, so it never emits a false positive.
- **Effort:** high, multi-session.

### G2 `[ ]` Kernel / driver surface (MC's actual target domain)
mcfuzz generates portable compute and touches **none** of the features the spec exists for
(sections 16–20, 28). A type-directed fuzzer here tests the safety guarantees that matter most.
- **MMIO** typed registers (`Reg<T,.read/.write>`, `@offset` layouts) — read/write lowering,
  width/ordering preservation.
- **Address-space types** (`PAddr`/`VAddr`/user/dma pointers) — class-mismatch + deref rules.
- **Packed-bits** and **overlay unions** — byte-storage layout, no C bitfields.
- **Atomics / concurrency**, **DMA / cache** ops, **memory barriers** — race-helper + ordering
  lowering.
- **Inline assembly** (opaque / precise), `#[unsafe_contract]` / `#[no_lang_trap]` paths.
- **Note:** some of these are exercised by the QEMU/driver fixtures and `mcgen`, but not by the
  type-directed generator. Decide per-feature: extend mcfuzz vs keep as fixtures.
- **Effort:** medium per feature; large in aggregate.

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

### G5 `[ ]` Trap-location agreement (E8)
The trapping differential only checks "both backends trap," not "at the same logical site."
- **Do:** compare the trap kind/site (the C inlines traps; LLVM links stubs — needs a shared
  trap-tag channel).

### G6 `[blocked]` Memory-safety oracle (E5)
Pointers only target globals (no heap), so ASan finds little. Unblocks once slices/heap exist.

---

## P2 — language features not generated

- G7 `[blocked]` **Tagged unions with payload (A2)** — backend can't lower them (even the spec's
  `ReflectToken` fails both `emit-c`/`emit-llvm`). Needs tagged-union codegen first.
- G8 `[blocked]` **Slices `[]T` (A5)** — `arr[0..n]` → `E_NO_IMPLICIT_POINTER_CONVERSION`;
  construction surface is finicky. Unblocks G6.
- G9 `[ ]` **Aggregate function params/returns of `move` types**, and **`move`/`defer`** in
  mcfuzz (today only in `mcgen_move.py`).
- G10 `[x]` **Recursion** — DONE (depth-bounded `recf(n)=n+recf(n-1)`, base `n==0`).
- G11 `[blocked]` **`switch` as an expression** — `emit-llvm` rejects it; statement/fold switch
  only. (`defer` in non-move contexts still open.)
- G12 `[ ]` **Closure captures of locals** — only global env tested; local capture hits a C-emit
  gap. **Hot checked reductions** (`reduce.sum_checked`, floating reductions).
- G13 `[blocked]` **Cross-domain conversions (C4)**, **`extern fn` calls (D2)**, **multi-module /
  imports (D5)** — no clean/runnable surface today.
- G14 `[ ]` Deeper aggregates: structs-of-pointers, arrays-of-`Result`, tuples-of-aggregates
  (after G3/G7/G8).

---

## P3 — methodology / infrastructure

- G15 `[blocked]` **Coverage-guided / byte-seed fuzzing (F1)** — the subprocess-per-seed model
  can't do in-process coverage feedback; needs a persistent/in-process harness.
- G16 `[~]` **Mutation-based *semantic* fuzzing** — metamorphic oracle now has two
  semantics-preserving transforms (body-in-helper + reverse digest fold); more could be added.
  (Original wording:) of valid programs (vs only crash/hang mutation
  in `robust`).
- G17 `[~]` **`report` coverage-statistics mode** — DONE (`mcfuzz.py report`). Persisted
  regression seed-corpus still open. (Original:) keep found-bug seeds as permanent gates, and a
  `--report` coverage-statistics mode.
- G18 `[x]` **`facts` / `emit-map` / `lower-hir/-mir/-ir` in the pipeline oracle** (E4) — DONE.
  (Original also mentioned:) and
  **round-trip / idempotence** (E6).

---

## Recommended order
1. **G1** reference interpreter — closes the one bug class no current oracle can see.
2. **G3** aggregate ABI — cheap, real new lowering surface.
3. **G2** kernel/driver surface — where MC's safety guarantees actually live.
4. **G4** float bit oracle — turns a known hidden class into a caught one.
5. Then unblock G7/G8 (tagged-union codegen, slice construction), which also unblock G6/G14.
