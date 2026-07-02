# mcc2 architecture hardening — from a 3-pass re-walker to a typed pipeline

**Status:** PLAN (2026-07-02). Not started. Prerequisite for making `mcc2` a trustworthy full
replacement for the Zig `mcc`, and the precondition for the two structural gaps that are still fully
open (semantic checking of generic instantiations + impl-method bodies).

**North star:** re-architect `mcc2` so that **parse happens once**, **sema builds a typed symbol
table**, and **emit consumes typed facts** instead of re-deriving them. This is NOT a rewrite and NOT
a port of the ~57k Zig lines — it is a staged refactor of the existing `selfhost/*.mc`, with the
`selfhost-bootstrap-test` byte-identical fixpoint held green at every commit.

Related durable records: `docs/self-host-plan.md` (how we got here), `docs/self-host-gaps.md` (the
G1–G35 ledger; G28/G33/G34/G35 are the review-hardening patches this refactor will *subsume*),
`docs/self-host-perf.md` (the ~2× headroom this refactor cashes in).

---

## 1. Why (the debt, from the code)

The current pipeline (`selfhost/main.mc`) is:

```
sema_check(src)   // parses src into SmState.p, type-checks, reports err counts, FREES everything
emit_c_run(src)   // parses src AGAIN, walks the fresh AST, emits C
```

Two independent parses of the same bytes; **sema's computed facts are discarded** before emit runs.
Consequences, each observed in the tree:

1. **Double parse.** Pure wasted work; `docs/self-host-perf.md` records ~2× headroom "dedup the
   sema+emit re-parse". Phase 0 below cashes this in.

2. **Emit re-infers what sema already knew.** The emitter carries a shadow type system to recover
   facts sema computed and threw away:
   - `e_enum_decl_for_type` / `e_expr_targeted` (added for G28) — re-resolve which enum a `.variant`
     targets, at emit time, at every value site.
   - `e_local_type_node`, `e_fn_param_type_node`, `e_ret_type_node` — re-derive binding/param/return
     types by re-walking decls.
   - `e_base_is_slice`, `e_base_is_ptr` — re-classify an expression's type to pick `.ptr[i]` vs
     `a[i]` and `->` vs `.` (P5.7/G31). The P5.7 slice work alone needed a ~150-LOC local-type
     resolver *inside emit*.

3. **No lexical scopes.** `sema.mc` models all locals in one function-wide `StrHashMap` (`s.locals`,
   `s.muts`), relying on G20's "names unique per fn" assumption. The G34 fix had to add
   `strmap_del` (backward-shift deletion) to manually drop an `if let` binding when its block ends —
   a workaround for the absence of scope frames.

4. **Generic templates + impl bodies aren't semantically checked.** `sm_check_fns` skips generic
   templates (their `T` is abstract with no concrete type in hand), and impl-method bodies with a
   `self` receiver are not even in the parser subset today. So a whole class of code emits without
   ever being checked — the reviewer's #1 concern, correct in spirit even though the specific repro
   is rejected at parse.

The common root of 2/3/4 is the same: **there is no shared, typed intermediate representation.** Every
pass re-discovers structure. The patches for G28/G34/G35 are band-aids on this; the refactor removes
the wound.

---

## 2. Target architecture

One parse, one AST, one authoritative set of typed facts:

```
Program {
    p:     Parser        // the single lex+parse result (nodes + extra arena)
    facts: Vec<Fact>     // typed side-table, indexed 1:1 by node id (parallel to p.nodes)
    // symbol tables (fns/structs/enums/globals) — populated in collect, kept for emit
}

parse(src)  -> Program          // once
sema(&prog) -> void             // fills prog.facts + reports errors
emit(&prog) -> StrBuf           // reads prog.facts; no re-inference, no re-parse
```

### 2.1 The typed side-table (`Fact`)

Node ids are dense arena indices (`Vec<Node>` in `Parser`), so a parallel `Vec<Fact>` sized to the
node count gives O(1) lookup by node id — no hashing. `Fact` holds exactly what emit needs so it can
stop re-inferring. Every field is subset-expressible (scalars / enums / the existing `SmType`):

```
struct Fact {
    ty:    SmType   // resolved type of an EXPRESSION node (kind .unknown for non-expr nodes)
    decl:  u32      // resolution target, node-id + 1 (0 = none):
                    //   enum_lit  -> the enum_decl node it belongs to   (kills G28 scan)
                    //   ident     -> the binding/decl node it resolves to
                    //   call      -> the callee fn_decl / extern_fn node
    flags: u32      // small bitset: is_slice_base, is_ptr_base, needs_dyn_coerce, ...
}
```

Start minimal (`ty` + enum-lit `decl`) and grow `flags` as each emit re-inference site is retired.
The migration is safe because every reader uses a **fall-back-to-rederive** rule: if `facts[n]` is
absent/unknown, use the old re-walk path. This lets consumers move one at a time without a big-bang
cutover.

### 2.2 Scope stack (retires `strmap_del` and the fn-wide locals model)

Replace `s.locals` / `s.muts` with a single binding stack:

```
struct Binding { nstart: usize, nlen: usize, ty: SmType, is_mut: bool, scope: u32 }
bindings: Vec<Binding>          // used as a stack

enter_scope() -> usize          // returns marker = vec_len(bindings)
exit_scope(marker)              // while vec_len > marker: vec_pop   (drops the frame)
bind(name, ty, mut)             // vec_push
lookup(name) -> Binding?        // scan from the TOP (end) for the nearest name match (mem_eql)
```

Classic lexical scoping as a stack of bindings with a reverse linear scan. Functions in a compiler are
small, so the scan is fine (add a per-scope hashmap later only if a profile demands it). This gives
correct `if let` / block / shadowing scoping *for free* and deletes the `strmap_del` workaround. It is
trivially expressible in the mcc2 subset (Vec push/pop + a reverse loop with `mem_eql`).

### 2.3 Checking generic templates and impl bodies

Two independent unlocks, both enabled once sema owns typed facts:

- **Generic templates (abstract check).** Add a sema mode where the type-param name (`T`) resolves to
  an *abstract* `SmType` that answers only what the `where`-bounds permit. Check the template body
  ONCE for name resolution, arity, and non-generic operations. Catches the "`no_such_fn` in a generic
  body" class without per-instantiation cost. (Concrete per-instantiation checking, option B, stays
  out of scope — monomorph-at-emit is unchanged.)

- **Impl methods.** Prerequisite: extend the *parser* to accept `impl T { fn m(self, …) … }` with a
  `self` receiver (today it exits 4 at parse). Then sema visits the body with `self` bound to the impl
  type; `sm_target_mutable` already needs the G32 fix (treat deref-of-`*mut self` as a mutable
  lvalue), which this makes natural.

---

## 3. Migration order — bootstrap stays byte-identical at every step

**Invariant:** after each phase, `selfhost-bootstrap-test` is green — `mcc2` emits a byte-identical
`mcc2′` (fixpoint) and the per-module `selfhost-{lex,parse,sema,emit,main}self-test` gates pass, on
both backends via Docker m0. Phases that intentionally change emitted bytes (only Phase 2's collision
cases) must still *converge* (mcc2 and mcc2′ both run the new emit), which the bootstrap verifies.

| Phase | Change | Output delta | Retires |
|------|--------|--------------|---------|
| **0** | **Unify the parse.** `main.mc` parses once into a `Program`; hand the SAME program to sema then emit. Emit stops calling its own parse but still re-derives types (ignores the table). | **byte-identical** (validates unification alone) — and banks the ~2× perf win | second `parse` in `emit_c_run` |
| **1** | **Add `facts` table**, populated by sema; emit ignores it. Scaffolding only. | byte-identical | — |
| **2** | **Enum-lit resolution → table.** Sema records the target `enum_decl` on each `enum_lit`; emit reads `facts[n].decl` (fallback: scan). | byte-identical for unique variant names; **fixes** the remaining `switch`-arm + assign collision cases (still fixpoint-stable) | `e_enum_decl_for_type`, `e_expr_targeted` threading, G28 scan |
| **3** | **Expr types → table.** Sema records resolved `SmType` per expr; emit's slice/ptr/local/param helpers read `facts[n].ty`. | byte-identical (same facts, one source) | `e_base_is_slice`, `e_base_is_ptr`, `e_local_type_node`, `e_fn_param_type_node`, the ~150-LOC emit resolver |
| **4** | **Scope stack** replaces `locals`/`muts`/`strmap_del`. | byte-identical (scoping only tightens sema; emit unaffected) | `strmap_del`, G20/G34 workarounds |
| **5** | **impl-with-`self` parsing + sema body check** (+ G32 lvalue fix). | new acceptance; emit thunks already exist — watch fixpoint | the "skip impl bodies" workaround |
| **6** | **Generic-template abstract check.** | new acceptance; no emit change | the `sm_check_fns` generic skip |
| **7+** | Expand coverage on the clean base: module/name system (replace flattened textual import), checked index/slice lowering, fuller host/target portability (hosted IO, paths, argv, tool runtime). | feature-gated | flattened-import assumptions |

Per-phase method (unchanged, proven): worktree agent → host `selfhost-*` + `mcc2-cli-test` →
cherry-pick to master → one Docker `tools/m0-parallel.sh` (`real_failures=0`). See
`self-hosting-mc.md`, `worktree-base-gotcha`, `m0-parallel-runner`, `use-docker-for-dev`.

---

## 4. Risks & mitigations

- **Fixpoint drift on an emit change (Phase 2).** Mitigation: the fall-back rule makes Phase 2
  byte-identical wherever the old scan already picked the only match; the *only* intended byte change
  is a variant name shared across enums used in a `switch`/assign — rare, and covered by a dedicated
  fixture before landing.
- **Incremental table adoption reading absent facts.** Mitigation: every consumer treats
  `unknown`/`0` as "re-derive the old way", so a half-migrated tree is always correct, just not yet
  faster/cleaner.
- **Node-id stability.** Not a risk — ids are arena indices from the single parse; the table is built
  and read within one `Program` lifetime.
- **Scope-stack scan cost.** Bounded by per-function local count (small); revisit with a profile only
  if it shows up (it won't at compiler scale).

## 5. Non-goals

- Full/bidirectional type inference beyond what the selfhost subset needs.
- Replacing monomorph-at-emit with a standalone mono pass (orthogonal; abstract-check doesn't need it).
- Feature parity with the Zig `mcc` / porting `src/*.zig`. This refactor makes `mcc2`'s *architecture*
  trustworthy; broadening *coverage* is the separate Phase 7+ long tail.

## 6. Expected payoff

- One parse → ~2× faster `mcc2` (perf ledger headroom realized in Phase 0).
- Emit becomes a straight-line printer over typed facts — deletes the shadow type system
  (`e_*_type_node`, `e_base_is_*`, enum re-resolution) and the `strmap_del` scope hack.
- G28/G34/G35 become structural guarantees rather than site-by-site patches; G32 falls out.
- Generic + impl bodies get real semantic checking — the last blocker between "proves MC can
  self-host a subset" and "mcc2 is a trustworthy compiler architecture."
