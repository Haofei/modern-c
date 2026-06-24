# Repo-wide refactor plan

Status: proposed (2026-06-24). Scope: **everything** — compiler (`src/`), build
system (`build.zig`), kernel, stdlib, userland, tools, tests. Style: **phased
with checkpoints** — each phase ends at a green gate before the next begins.

This plan combines four goals the way they actually depend on each other:

1. **Split monster files** (pure structure, behavior-preserving)
2. **Reduce `build.zig`** (pure structure)
3. **Fix soundness** (semantics — move checker + stdlib/kernel over-claims, per `review.md`)
4. **Restructure directories** (boundaries/naming)

Ordering principle: **do the behavior-preserving structural work first** (it is
mechanically verifiable and makes the soundness work reviewable), then do the
semantic work on the now-readable code, then re-organize directories last.

---

## Invariants (hold for every commit)

- **Both backends stay at parity.** No change lands unless C and LLVM emit agree
  (validated behaviorally by `diff-backend` + fuzzers, not artifact diffs).
- **Gates stay green at every checkpoint.** Lanes, cheapest-first:
  `fast` (unit+emit+diff, no QEMU) → `c0` (+ c-test + sweep + demo-test) →
  `c1` (+ kernel-test) → `m0` (full, QEMU under Docker).
- **Docker is the source of truth.** Host runs skip LLVM/QEMU gates; validate
  front-end changes against kernel emit under QEMU (see memory: *Validate
  against kernel emit*, *Use Docker for dev*).
- **Commit directly on `master`.** No feature branches (see memory: *Never
  create branches*). Each commit is a self-contained, gate-green step.
- **The fixture-contract invariant is law.** Each fixture exercises itself under
  its declared config (ISA/profile/outcome). Extend manifests
  (`tools/lib/host-tests.tsv`, `// SPEC:` headers), never rebuild them. See
  `docs/test-architecture.md`.
- **Structural commits assert "no behavior change"** in the message; semantic
  commits name the soundness hole they close and add a `bad/` reject fixture.

---

## Phase 0 — Safety net & baseline (prereq, ~0.5 day)

Goal: be able to prove "no behavior change" mechanically before touching code.

1. Capture a baseline of emitted artifacts for a representative corpus: for each
   `tests/c_emit/*.mc` and `tests/spec/*.mc`, store `mcc --emit-c` and
   `--emit-llvm` output hashes. This is a throwaway oracle (gitignored) used to
   diff structural refactors — emitted text must be byte-identical after a
   pure-structure split.
2. Confirm `make fast`, `zig build c0`, `zig build c1` all green on `master`
   today; record timings. Confirm `m0` green under Docker.
3. Write `tools/check/emit-snapshot.sh` (compare current emit against the
   baseline) so each structural commit can self-verify with a single command.

Checkpoint: baseline captured, all lanes green, snapshot tool works.

---

## Phase 1 — Decompose `build.zig` (pure structure, ~1–2 days)

`build.zig` is 4,481 lines in a single `build()` with **453 `b.step()` calls**.
~53% of the file is mechanical duplication: a 5-line `_cmd`/`_step` boilerplate
per test (×453) and an 18-line C-vs-LLVM pair block (×~159).

Steps (each independently gate-green):

1. **Introduce `build/helpers.zig`** with two functions, no behavior change:
   - `addScriptTest(b, name, desc, argv) *Step` — collapses the 5-line boilerplate.
   - `addBackendPair(b, base, desc, scriptPath) struct{c,llvm}` — collapses the
     18-line C/LLVM duplication into one call (emits `<name>` + `llvm-<name>`).
   Migrate steps in batches of ~30, running `zig build c0` after each batch to
   confirm the step graph is unchanged (`zig build --help` step list diff = ∅).
2. **Split `build()` into composable sections** imported by a thin top-level:
   - `build/compiler.zig` — mcc exe + in-process unit tests
   - `build/sweep.zig` — spec/C/LLVM IR + object sweeps
   - `build/fuzz.zig` — the 12 mcfuzz oracles
   - `build/hardening.zig` — KASAN/KMSAN/KCSAN + static audit gates
   - `build/qemu.zig` — QEMU kernel/arch tests + host-tests.tsv expansion
   - `build/tiers.zig` — `fast`/`c0`/`c1`/`m0` aggregation
   Top-level `build()` becomes a ~40-line orchestrator calling each module.
3. **Make host-tests data-driven (optional, high-value).** Today the ~152
   `host-tests.tsv` rows are *validated* by Python but the ~300 QEMU step
   declarations are hand-written. Have `build/qemu.zig` read the TSV at build
   time and generate the C+LLVM step pair per row. This deletes ~600 lines and
   makes the TSV the single source of truth (matches the fixture-contract goal).

Checkpoint: `zig build --help` lists the **same** step names as the Phase-0
baseline; `c1` green; `build.zig` proper < ~300 lines.

---

## Phase 2 — Split compiler monster files (pure structure, ~3–5 days)

Behavior-preserving extraction. After each split, **emit output must be
byte-identical** (Phase-0 snapshot tool) and `c1` green. These are the targets,
ordered low-risk → higher-coupling.

### 2a. `lower_c.zig` (17,244 lines → ~8 files)
Split along the natural seams identified in the codebase:
- `lower_c_expr.zig`   ← expression lowering (`emitExpr` family, ~1.2k lines)
- `lower_c_stmt.zig`   ← statement lowering (`emitStmt`, switch/for/if-let, ~1.5k)
- `lower_c_type.zig`   ← declarators + C type mapping (`cType`, pointers, aliases)
- `lower_c_aggregate.zig` ← struct/union/array/layout/forward-decl emission
- `lower_c_mmio.zig`   ← MMIO + sequenced volatile-read orchestration (~1.4k)
- `lower_c_trait.zig`  ← vtables, dyn dispatch, closures, bind-thunks
- `lower_c_global.zig` ← globals + const-init folding
- `lower_c.zig`        ← `CEmitter` struct, module collection, public API (the spine)

Mechanism: keep the `CEmitter` struct in the spine; extracted files take
`*CEmitter` and live as `usingnamespace`-style method groups or free functions
operating on the emitter. No state moves; only code location changes.

### 2b. `sema.zig` (10,705 lines → ~5 files)
- `sema_move.zig`  ← the move/linear checker (lines ~876–2077; **isolate before
  Phase 3 rewrites it** — this is the most valuable split)
- `sema_stmt.zig`  ← statement + expression + assignment checking
- `sema_calls.zig` ← MMIO/atomic/DMA/reflection/bitcast/declassify call validation
- `sema_type.zig`  ← `checkType`, type-class/numeric-domain helpers
- `sema.zig`       ← `Checker` struct, `checkModule`, decl dispatch (the spine)

### 2c. `lower_llvm.zig` (6,912 lines → ~4 files)
Mirror the `lower_c` split so the two backends stay structurally parallel:
- `lower_llvm_fn.zig`, `lower_llvm_expr.zig`, `lower_llvm_helpers.zig`, spine.

### Not split (intentionally)
- `mir.zig` — CFG + type tables are mutually dependent; splitting creates import
  cycles for little gain. Leave as-is.
- `async_lower.zig`, `parser.zig` — single-pass, tight grammar coupling; marginal benefit.

Checkpoint after each file: emit snapshot identical, `c1` green, `fast` green.

---

## Phase 3 — Move-checker soundness: CFG dataflow rewrite (semantics, ~2–4 wks)

This is the deepest change. `review.md`'s core finding: the move/linear checker
is a statement-walker with cloned hashmaps, not a CFG dataflow analysis. It
misses leaks on: early `return`, loop zero/many-iteration, branch-merge of
single-arm resources, `if let` move payloads, and nested lexical scopes.

Build on infrastructure that already exists: `mir.zig` has `Block{successors,
terminator}` and a dominator-walk pattern (`blockHasDominatingRepresentationCheck`).

Sub-steps (each gated by new `tests/spec` + `kernel/bad/` reject fixtures):

1. **Pin current behavior first.** Add reject fixtures for every hole in
   `review.md §1` (early-return leak, loop leak, branch-merge drop, if-let
   payload, nested-scope) as `EXPECT: E_LEAK`-style cases. They will *fail*
   (compiler wrongly accepts) — that's the red baseline the rewrite turns green.
2. **Define the lattice** in `sema_move.zig`: per-binding
   `Live | Moved | Deferred | MaybeLive | Unreachable`, replacing the current
   `MoveSlot{live,deferred,...}` bool pair. Keep `alias_of`/`escaped_borrow`.
3. **Run dataflow over the CFG**, not the statement list. Worklist fixed-point
   over MIR blocks (or a CFG built from HIR if move-check must precede MIR).
   Decide the IR level early — move-check currently runs in sema (pre-MIR), so
   either (a) build a lightweight CFG in sema for the move pass, or (b) move the
   pass after MIR build. **(a) is lower-risk** (keeps diagnostics in sema with
   source spans). Prototype both on one function before committing.
4. **Check every exit edge:** `return`, `?` error-exit, `break`, `continue`,
   trap/panic edges, and fallthrough — call leak-check at each, not just final state.
5. **Loops:** reject moving an outer resource inside a loop body unless proven
   one-shot. Model the back-edge explicitly.
6. **Branch merge:** at joins, a resource live on *either* arm but consumed on
   the other is a leak (fix `mergeMoveBranches` dropping right-only keys).
7. **`if let` / `switch`:** add move-typed payload bindings to the matched arm
   uniformly (switch already does; if-let must too).
8. **Lexical scopes:** push/pop a move scope at every `{ }`, leak-checking
   block-locals at scope exit.

Risk controls: this *will* shift diagnostic line numbers across the spec/kernel
corpus. Expect a large but mechanical fixture churn. Land behind a temporary
`--move-cfg` flag defaulting off, flip the default only when `m0` is green with
it on, then delete the old path and the flag.

Checkpoint: all `review.md §1` reject fixtures green; full `m0` green with CFG
checker as the only path; old statement-walker deleted.

---

## Phase 4 — stdlib API soundness (semantics, ~1 wk)

Each fix pairs a code change with a `bad/` reject or `std`-test fixture proving
the new contract. From `review.md §2`:

- **`std/arc`**: `arc_get` returns `*mut T` with no uniqueness → split into
  `arc_get` (`*const T`) + a guarded/locked mutable path; add refcount-overflow
  check in `arc_clone`.
- **`std/owned` + `std/arc`**: allocator provenance separated from handle →
  bind the allocator into the handle type so wrong-allocator frees can't type-check.
- **`std/virtqueue`**: stop trusting device-reported completion `len`; store the
  original submitted length and validate on `vq_complete`. Fix chain-API
  ownership loss on timeout (free the chain).
- **`std/arena`**: document/enforce generation-wrap behavior; make handle structs
  opaque so generations can't be forged.
- **`std/pool`**: `pool_alloc` must not hand out a slot that `pool_load` can read
  uninitialized — require init-before-load (typestate) or zero on alloc.
- **`std/mem`**: enforce documented preconditions (`align_up` power-of-two,
  `mem_copy` non-overlap) with checks/asserts.

Several of these become *much* stronger once Phase 3 lands (real linear checking
backs the ownership claims) — sequence Phase 4 after Phase 3 deliberately.

Checkpoint: new std reject fixtures green; `c1` + relevant QEMU gates green.

---

## Phase 5 — kernel soundness (semantics, ~1–2 wks)

From `review.md §3`, validated against kernel emit under QEMU (not just tests):

- **`kernel/core/process.mc`**: replace bare `u32 parent` with `{slot,gen}`
  Endpoint identity; default `allow_mask`/`kcall_mask` to least-privilege (not
  all-ones); wire grant/registry cleanup into `proc_death_cleanup`.
- **`kernel/core/uaccess.mc`**: validate against current process page tables
  (PTE_U/R/W), not just numeric ranges; provide fault-safe copy.
- **`kernel/arch/riscv64/paging.mc`**: distinguish interior vs leaf PTEs; reject
  conflicting mappings instead of silently overwriting.
- **`kernel/fs/ramfs.mc` + `vfs.mc`**: enforce per-file capacity in `ramfs_write`;
  honor `fd.pos` in `vfs_write`.
- **`kernel/core/cow.mc` + `demand.mc`**: replace single-global `g_shared` COW
  with per-frame refcounts + per-PTE COW bits; validate regions in `dp_handle_fault`.
  (This couples with the deferred trace/cow kernel-layering task.)

Each change gated by the matching QEMU milestone gate; use the worktree-agent →
cherry-pick → Docker-verify workflow for the arch-specific ones.

Checkpoint: `m0` green; kernel reject fixtures in `kernel/bad/` green.

---

## Phase 6 — Directory restructuring (boundaries, ~2–3 days)

Lowest urgency, highest churn-to-importers ratio — do last, when the code above
is settled.

- **`std/` is flat (40 files).** Group by concern into subdirs:
  `std/alloc/` (alloc, arena, dma, pool), `std/sync/` (spinlock, rwlock, seqlock,
  barrier, mutex), `std/fmt/` (fmt, fmt_sink), `std/bytes/` (bytes, byteview,
  ascii, scan), `std/collections/` (arc, ring, slotmap, guarded). Update import
  paths repo-wide in one mechanical commit per group; `c1` green after each.
- **`kernel/core/trace.mc`** (28 importers) — finish the deferred move to
  `kernel/lib/` now that churn has settled (see memory: *Kernel layering refactor*).
- **`kernel/core/cow.mc`/`demand.mc`** — relocate after Phase 5 reworks them
  (needs arch-neutral large-page/AS-encode hooks; was deferred as task #22).
- Audit `tools/` empty subdirs (crypto/exec/fs/ipc/lsp/qemu/tls/user have no
  contents) — remove or document why they exist.

Checkpoint: `m0` green; import graph has no dangling paths; docs updated.

---

## Sequencing summary

```
Phase 0  safety net            (0.5d)  ── prereq
Phase 1  build.zig             (1-2d)  ── pure structure, unblocks readable diffs
Phase 2  split src/ monsters   (3-5d)  ── pure structure; 2b isolates move checker
Phase 3  move-checker CFG      (2-4w)  ── deepest; needs 2b done first
Phase 4  stdlib soundness      (1w)    ── stronger once Phase 3 lands
Phase 5  kernel soundness      (1-2w)  ── QEMU-gated
Phase 6  directory restructure (2-3d)  ── last; highest import churn
```

Phases 1–2 are safe, parallelizable, and reviewable. Phase 3 is the real work
and the main risk. Phases 4–5 deliver the soundness the project's value
proposition rests on. Phase 6 is cosmetic and deferrable.

## Open decisions to confirm before Phase 3

- **IR level for the move CFG**: build a sema-local CFG (keeps source-span
  diagnostics, lower risk) vs. move the pass after MIR build (reuses existing
  `mir.Block` CFG, but diagnostics need span back-mapping). Recommendation: (a).
- **How aggressive on loops**: strict (reject any outer-resource move in a loop)
  vs. permissive with a one-shot proof. Strict first, relax later if it blocks
  real kernel code.
