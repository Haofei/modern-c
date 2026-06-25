# Kernel-Language Hardening — Actionable Backlog

> **Historical status.** The main hardening campaign described here is resolved
> or explicitly deferred. For current open work, start with [`todo.md`](todo.md).

A prioritized backlog for hardening MC **as a kernel language** — no hosted runtime, no GC, no
userland allocator, so hardening must be **static** (type system, zero runtime cost), **cheap
dynamic** (the trap model / sanitizers in the QEMU build), or **verification / hardware**.

Two parts: **Part I — Memory & UB**, **Part II — other kernel-language axes** (concurrency, the
trust boundary, parsing, capabilities/IFC, ABI, termination, side channels, fault isolation).
Each item is sized (PR / multi-PR / research) with **What / Where / Test / Prior art / Depends**.
`[ ]` = todo, `[x]` = done, `[~]` = partial/deferred (with rationale inline). IDs: Part I uses
tier-dotted (`S0.1`, `D2.1`); Part II uses letter (`C1`, `A1`).

> **STATUS (resolved).** 24 items DONE + 2 PARTIAL (T1.1, T1.2 — both lexical-borrow checks
> are sound only for their direct-binding fragment; aggregate/interprocedural laundering is a
> known false negative, = T1.3), each landed on `master` with a commit
> hash, both-backend (`diff-backend`) parity, and the relevant QEMU/fuzz gates green; built via
> worktree sub-agents, integrated + independently re-validated. **10 items DEFERRED** with
> rationale — genuine research (formal proofs, CHERI/MTE hardware, IFC, model checking, verified
> parsers) or prerequisite-blocked (T(term)2 needs an agent loader). The hardening surfaced and
> fixed **several real latent bugs** (Virtq struct drift ×3, a forgeable `Cap`, a `UserPtr`
> field-deref hole, read-before-init, the overlay miscompile) and proved the parsers robust
> (4.8M malformed inputs, 0 over-reads). Every static check is opt-in/additive — the kernel boots
> unchanged on both backends.
>
> **Soundness is adversarially re-probed, and the claims are now self-verifying.** Three review
> rounds (review-by-area, then re-review of the fixes, then a launder-through-indirection probe
> sweep of each *guarantee*) found, in order: 14 bugs → 1 fix-induced regression + 4 gaps → 1
> systemic cast/bitcast class-strip (bypassing secret/UserPtr/Tainted/Guarded at once) + the
> recurring lesson that **the *claim* runs ahead of the *code*** ("sound" / "no X remains" with
> counterexamples). Fix: the probe matrix is promoted into committed `tests/spec/soundness_*.mc`
> fixtures (use-after-move channels, cast-strip, secret incl. overlay, UserPtr/Tainted/Cap, IRQ
> direct+indirect, definite-init) — so every "closed" claim, and the documented conservative
> over-rejections, FAIL `zig build test` if they silently regress. Write claims from adversarial
> test results, not intended design.
>
> Later rounds extended the probing past the type-law surface to the **runtime and structural**
> guarantees (the shapes `mcc check` can't reach). The QEMU sanitizer sweep verified coverage by
> *execution* and fixed a KCSAN false-positive (`172445b`). The structural-launder round found the
> two deepest holes: a **systemic name-keyed opacity bypass** (any file could write a peer `impl`
> of an opaque type and read its private field — undercutting Cap/Rights/Tainted/Guarded) → fixed
> with an **orphan rule** (`a882495`); and **address classes laundered by `as`/`bitcast`** (forge
> an `MmioPtr` from an integer → device write, no `unsafe`) → fixed by gating cast/bitcast on the
> address-class property and moving the legit mint sites behind `unsafe` (`d385c8c`). The recurring
> shape across every fix: **a gate keyed on enumerated cases misses the general property** — the
> durable answer is gates keyed on the property + self-verifying fixtures.

## What MC already has (harden the gaps, don't reinvent)
- **Spatial, trapping:** `mc_check_index_usize` (bounds), checked arithmetic, `__builtin_trap`,
  with **proof-based elision** (`range_facts`/`elided_bounds` in `src/mir.zig`).
- **Temporal (partial):** linear `move` types; `move-fuzz` asserts release-exactly-once.
- **Concurrency primitives:** `acquire`/`release`/`atomic`/`fence`/`spinlock`/`mutex`,
  `mc_race_load`/`mc_race_store`; an IRQ controller (`kernel/drivers/irq/plic.mc`), scheduler.
- **Trust boundary primitive:** `kernel/core/uaccess.mc`.
- **Capability primitives:** `Cap<>`, grants (`kernel/lib/granttab.mc`, `std/grant.mc`), `Mask32`.
- **Aliasing UB avoided** via the `memcpy`-reinterpret discipline; typed addresses (`std/addr.mc`).
- **Toolchain oracles:** `sanitize`/`fuzz-sanitize` (ASan+UBSan), `fuzz-trap` (trap-consistency),
  `fuzz-failclosed`, `fuzz-reference` (independent interpreter `tools/fuzz/mcref.py`),
  `fuzz-metamorphic`, `fuzz-determinism`.

The recurring shape: MC has the **mechanisms**; hardening pulls their **disciplines** into the
type system (static) or the trap/sanitizer model (cheap dynamic). The most on-thesis items
(**K**, **T2**) are what let the kernel run *untrusted agent code* with static guarantees.

---
# Part I — Memory & UB

## Tier 0 — Foundations & obvious gaps (cheap, do first)

- [x] **S0.1 — Definite-initialization analysis** *(DONE `40c6cc7`; plain uninit-vars already required init — FOUND+CLOSED the gap: reading a `var x=uninit` scalar before assign-on-all-paths is now `E_USE_BEFORE_INIT` (flow-sensitive, branch/loop aware). Scalar-only to avoid false positives on the aggregate fill idiom. R3 boundary: taking `&x` clears the pending flag (to support the `init(&x)` idiom), so ANY read of `x` after `&x` is taken is accepted — not just a read laundered through the alias, but a direct `let p=&x; return x;` with `x` never assigned (the address-of unconditionally clears the init-pending flag); soundly closing it needs escape/init tracking (T1.3))* — reading `uninit` before assignment is a
  **compile error**, flow-sensitive. **Where:** sema (`src/hir.zig`). **Test:** `fuzz-failclosed`
  + fixtures; no false positives on the `var x:T=uninit; … x=v;` idiom. **Prior art:** Zig/Rust
  definite-assignment; KMSAN (dynamic counterpart, D2.2). **Depends:** none.
- [x] **S0.2 — Define & enforce the `unsafe` boundary** *(DONE `df72851`; MC already type-enforces `unsafe {}` + `#[unsafe_contract]` via sema `E_UNSAFE_REQUIRED` — added `unsafe-audit` lint + `docs/unsafe-boundary.md` inventory (146 sites, boundary clean). Follow-up: whole-function safe/unsafe effect typing)* — enumerate every
  UB-introducing construct (raw pointer arithmetic, `uninit`, `extern mmio`, memcpy-reinterpret,
  manual `move` overrides) behind an explicit greppable marker; the *safe* subset is provably free
  of them. **Where:** spec + sema. **Test:** safe code contains zero unsafe ops; an audited list of
  unsafe sites in `kernel/`. **Prior art:** Rust `unsafe` + RustBelt; Zig. **Depends:** none.
- [x] **S0.3 — Pin down inherited C UB in the C backend** *(DONE `ef14ee4`; `docs/c-ub-matrix.md` + `-fno-strict-aliasing`/`-fwrapv`/`-fno-delete-null-pointer-checks` on emitted C + 9 UBSan-clean fixtures; only `-fno-strict-aliasing` is load-bearing — MMIO type-pun)* — a UB-class matrix (signed
  overflow, strict aliasing, OOB, shift≥width, INT_MIN/-1, null deref, uninit, eval order): for
  each, "MC forbids / checks+traps / defines away." Emit with `-fno-strict-aliasing`/`-fwrapv`
  where checks don't cover it. **Where:** `src/lower_c.zig` + `tools/toolchain/mcc-cc.sh`. **Test:**
  the matrix + `fuzz-sanitize` clean. **Prior art:** MISRA C, Frama-C, Regehr's UB work. **Depends:**
  none. *(LLVM backend mostly sidesteps this.)*

## Tier 1 — Static type system: temporal safety (highest leverage, zero runtime cost)

- [~] **T1.1 — Lexical region/scope borrows** *(PARTIAL `a0d2ace`; `return &local` already caught — CLOSED the gap of storing a stack borrow outward through a pointer param (`*out=&local`) → `E_BORROW_ESCAPES_SCOPE`. NOT covered (→ T1.3 lifetimes): escape-to-global, escape-to-outer-block — needs per-block region machinery)* — a reference may not outlive the region
  of the value it borrows (catch use-after-scope/dangling). Start lexical. **Where:** borrow pass
  (`src/hir.zig`). **Test:** escaping-reference fixtures rejected (`fuzz-failclosed`); kernel still
  type-checks; `move-fuzz` borrow cases. **Prior art:** Rust borrow checker, Cyclone regions,
  **RustBelt**. **Depends:** S0.2.
- [~] **T1.2 — Use-after-move for derived aliases** *(PARTIAL `beb6b72`,`cca5ad4`. NOT "sound" — sound only for the direct-pointer-local fragment. COVERED (rejected): direct alias chains `let q=p=&t`, reassignment, struct-LITERAL field aliases `H{.p=&t}`, and returning an aggregate containing `&local`. The whole **lexical aggregate/call-flow class is now structurally CLOSED** (`962242f`): one unified recursive scan flags an address-of-a-move-place at ANY nesting depth, run at decl-init, assignment, and **call arguments** — so struct-field/array assignment, subfield alias, `id(p)` call laundering, array-literal `.{&t}`, struct-of-struct `o.h.p`, call-arg aggregate `sink(.{.p=&t})`, and the `&move as usize` ptr-to-int round-trip all reject (precise reject-at-use where a place exists, conservative reject-at-move otherwise). **Honest remaining boundary (NOT closed = T1.3):** a borrow embedded in a function's RETURN aggregate (`let h = mkHolder(&t)`) — interprocedural return-value provenance, which needs function summaries/lifetimes, not a lexical scan. The residual `[~]` is (a) that interprocedural case and (b) conservative-rejection OVER-rejecting some safe programs (recorded in `tests/spec/soundness_conservative_overrejection.mc`). **Every closed channel is a committed `tests/spec/soundness_use_after_move.mc` fixture (15 reject cases), so a silent re-opening fails `zig build test`)* — invalidate any pointer/alias derived
  from a moved-out value (not just double-free of the owner). **Where:** move checker (`src/ir.zig`).
  **Test:** `move-fuzz` stale-alias cases. **Prior art:** Rust move/affine types. **Depends:** T1.1.
- [~] **T1.3 — Lifetime-parameterized references** (DEFERRED — full lifetime/region system; deliberate language-design building on the T1.1 lexical slice) *(research → multi-PR)* — for fns returning/storing
  borrows. **Where:** type system. **Test:** differential + `fuzz-failclosed`. **Prior art:** Rust
  lifetimes, RustBelt. **Depends:** T1.1.
- [~] **T1.4 — Soundness spec for the safe subset** (DEFERRED — formal proof-obligation document; follows T1.3 maturity) *(doc, research)* — "well-typed safe MC has no
  UB," proof obligations per construct (informal first). **Prior art:** RustBelt, seL4. **Depends:**
  S0.2, T1.1.

## Tier 2 — Cheap dynamic sanitizers in the QEMU build (best near-term ROI)

- [x] **D2.1 — KASAN-style shadow memory** *(DONE `9078889`; opt-in `--checks=ksan`; 1:8 shadow, `raw.load`/`raw.store` instrumented + heap poison-on-free; QEMU demo catches UAF/OOB on ACCESS, both backends. Coverage (R3): `raw.load`/`raw.store` + globals (load/store) + global struct-field/array + pointer struct-field LOADs are now instrumented (`2b8ded9` — a field-reached UAF is now KASAN-DETECTED, both backends). STILL missed: pointer/local field STORES, local array index, stack locals, MMIO; and the check FAILS OPEN outside the one armed `heap_new_ksan` pool (a stray pointer is waved through). Broader than "raw-only" now, but still not a total heap net)* — instrument
  loads/stores against a shadow map; poison freed heap (`kernel/core/heap.mc` free path), redzone
  allocations, trap on poisoned access. **Where:** an emit profile/instrument pass + shadow runtime
  + heap hooks. **Test:** a QEMU boot demo triggering UAF + OOB → trap → `KASAN-OK` (mirror the
  `*-test.sh`/`m0` wiring). **Prior art:** **Linux KASAN**, ASan. **Depends:** none.
- [x] **D2.2 — KMSAN-style uninit-use detection** *(DONE `13197f9`; 3-state shadow (clean/uninit/poison) under `--checks=msan`; load of never-written heap byte traps, both backends. Coverage (R3): raw deref + globals + global-field/array + pointer-field LOADs of armed-pool heap (`2b8ded9`); still missed: pointer/local field stores, local array, stack. Under `--checks=msan` a write THROUGH a freed pointer is not caught (use `ksan`). No origin tracking)* — shadow-track
  initialized-ness; trap on use of uninit (dynamic complement to S0.1). **Where:** instrument +
  shadow. **Test:** QEMU demo reads uninit heap → trap. **Prior art:** **Linux KMSAN**, MSan.
  **Depends:** D2.1.
- [x] **D2.3 — KCSAN-style data-race detection** *(DONE `20ee08d`; opt-in `--checks=csan` watchpoint table; race detected on a REAL preempting timer-IRQ vs boot-thread access (the timing window is widened for determinism; the preemption is genuine). Coverage (R3): kernel `global`/global-field/global-array accesses are now instrumented (`2b8ded9` — they no longer lower to an UNinstrumented path), so a race on real global data is now in scope; but detection still requires the pair be exactly boot-thread vs the CLINT timer-IRQ (watchpoint table hard-wired to 2 contexts) and both be on the armed pool — so it's broader than before but still bounded to that 2-context shape, not a general SMP race net. The QEMU sweep FOUND+FIXED a FALSE POSITIVE (`172445b`): the synchronized `mc_race_*` path wrongly carried watchpoints, so a properly-locked global access raced by the timer IRQ was reported as a race — now the synchronized path sets no watchpoint. Coverage is now QEMU-execution-verified, detect-cases gate-asserted; one residual: KASAN array-field load detects on C but not LLVM)* — build on
  `mc_race_load`/`store` to detect conflicting concurrent accesses. **Test:** racy demo flagged.
  **Prior art:** **Linux KCSAN**, TSan. **Depends:** D2.1. *(Dynamic complement to Part II/C.)*
- [x] **D2.4 — Guard pages + heap redzones + stack canaries** *(redzones+canary DONE `eed0482`; guard pages deferred — need paging. Coverage limits (R3 sweep): detection is on free/`heap_check_block`, NOT at the bad access; a never-freed overflow is silent; a write ≥16B past the allocation skips the 16B guard into the next block; a read-only OOB is not caught (only clobbered poison is). UAF is KASAN's job, not redzone's)* — unmapped guard pages around
  stacks, redzone the kernel heap, optional canaries. **Where:** `kernel/core/heap.mc` + stack
  setup. **Test:** stack/heap-overflow demo traps. **Prior art:** Linux stackguard, glibc canaries.
  **Depends:** none.
- [x] **D2.5 — Explicit safe vs release profile** *(DONE `efbe0f4`; `--checks=all` (safe, default) / `--checks=elide-proven` (release); formalizes existing proven-dead elision; `safe-release-parity` gate proves functional equivalence)* — safe keeps all trap checks; release elides
  proven-dead ones (machinery exists). Kernel default = safe. **Where:** `src/mir.zig` + profile +
  `build.zig`. **Test:** parity gate that safe & release agree functionally. **Prior art:** Zig
  ReleaseSafe/ReleaseFast. **Depends:** none.

## Tier 3 — Verification / translation validation (the compiler is a UB source)
> The overlay-read miscompile was found by fuzz luck, not structurally. Push the existing oracle
> culture toward real validation.

- [x] **V3.1 — Per-construct translation validation** *(DONE `8319ec6`; reference interpreter `mcref.py` now independently evaluates @offset layout, overlay reads (scalar/byte/non-byte/expr-position), and the switch families — fuzz-reference PASS 300, no compiler-vs-interpreter divergence)* — extend `tools/fuzz/mcref.py` /
  `fuzz-reference` to assert each MIR construct's lowering matches reference semantics, focused on
  the separate-per-backend-path constructs (offset/overlay/switch-family). **Test:** the suite;
  would have caught the overlay bug structurally. **Prior art:** translation validation (Pnueli),
  CompCert. **Depends:** the reference oracle.
- [x] **V3.2 — Lowering coverage instrumentation** *(DONE `bec15f0`; function-level — lower_c 72.5%, lower_llvm 85.3%; uncovered MMIO-read/overlay/atomics paths reported in `docs/lowering-coverage.md`)* — measure which `lower_c`/`lower_llvm`
  branches the fixtures+fuzzer hit, to surface untested divergence-prone paths (the overlay bug
  lived in an uncovered branch). **Test:** a coverage gate. **Prior art:** lcov/kcov, mutation
  testing. **Depends:** none.
- [x] **V3.3 — Memory-op metamorphic checks** *(DONE `ac3fb0b`; field-reorder@offset, overlay read recompose + position-swap, sizeof/offset identities, slice/index equivalence; fuzz-metamorphic PASS 600 seeds — no divergence)* — semantics-preserving transforms over
  layout/offset/overlay/slice ops must not change results. **Where:** `fuzz-metamorphic`. **Depends:**
  the offset/overlay generator surface (added).
- [~] **V3.4 — Machine-checked soundness of a core subset** (DEFERRED — Coq/Isabelle/Lean proof artifact; multi-month research) *(research)* — formal semantics + a proof
  that well-typed safe programs have no UB (and/or lowering refinement). **Prior art:** **seL4**,
  **CompCert**, RustBelt, RefinedC/Iris. **Depends:** T1.4.

## Tier 4 — Hardware-assisted (future; aligns with the capability thesis)

- [~] **H4.1 — CHERI target** (DEFERRED — new hardware backend; needs a CHERI/Morello toolchain + the native-backend abstraction; research) *(research)* — hardware capabilities = spatial **and** temporal safety
  at pointer granularity; the kernel is already a *capability* microkernel. **Where:** a backend
  behind `src/backend.zig`. **Prior art:** CHERI/Morello, CheriBSD. **Depends:** the backend
  abstraction; ideally a native backend.
- [~] **H4.2 — ARM MTE heap tagging** (DEFERRED — needs aarch64 MTE hardware/target maturity; research) *(research)* — cheap probabilistic UAF/OOB in production.
  **Where:** `kernel/core/heap.mc` + aarch64. **Prior art:** Android/Linux arm64 MTE. **Depends:**
  aarch64 maturity.

---
# Part II — Other kernel-language axes

## C — Concurrency discipline (static; complements D2.3/KCSAN)
> Data races + deadlocks + sleep-in-atomic are the worst kernel bug class. Primitives exist;
> nothing enforces their use.

- [x] **C1 — Lock-guards-data** *(DONE `c3ce2c0`; `std/guarded.mc` `Guarded<T>` (opaque, data private → `E_PRIVATE_FIELD` on direct access) + linear `Guard` (must-release, no-dup via the move checker), tied to the specific lock instance. The structural-launder round FOUND+FIXED THREE bypasses: `bitcast<*Shadow>(g)` (`E_BITCAST_TYPE`); the **systemic name-keyed opacity hole** — any file could write a peer `impl Guarded` and read `.data` (affected Cap/Rights/Tainted too) → now an **orphan rule** (`a882495`): `impl` of an opaque type must be in its defining file, else `E_ORPHAN_IMPL`; and the **public `Guard` fields** (`g.data` read / wrong-lock `ga.data=gb.data` / forge-a-guard) → `Guard` is now `opaque` (`E_PRIVATE_FIELD`). Linearity was already sound. Only remaining bypass is explicit `unsafe`. Lock ORDERING = C3, follow-up)* — associate data with its lock (data inside the lock);
  access requires static proof the lock is held. **Where:** `std/sync` + a check pass. **Test:**
  `fuzz-failclosed` (unlocked access rejected); migrate kernel locks incrementally. **Prior art:**
  Rust `Mutex<T>`, Rust-for-Linux **klint**, lockdep. **Depends:** none.
- [x] **C2 — IRQ/atomic-context discipline** *(DONE `2410f32`; `#[irq_context]` + `#[may_sleep]` attributes (built on MC's existing attr machinery) + sema `E_SLEEP_IN_ATOMIC`; `heap_alloc`/`sched_yield`/`mutex_lock` marked sleepable, `claim_if_pending` irq-context — no real violation. R3: indirect/fn-pointer calls in irq context now also rejected by `check` (`E_IRQ_CONTEXT_CALL`, check==verify — closed a check/verify disagreement); transitive sleep via a marked `#[irq_context]` helper is blocked (each link is checked at its own def). Remaining gap: the `#[may_sleep]` set is hand-marked — an unmarked sleepable op is invisible)* — mark fns IRQ-context vs sleepable; a sleepable
  op (mutex/alloc) from IRQ context is a compile error. **Where:** an effect/attribute +
  `kernel/core/sched.mc`/`kernel/drivers/irq/`. **Test:** sleep-in-IRQ fixture rejected. **Prior art:**
  Linux `might_sleep`/lockdep, Rust-for-Linux context types. **Depends:** none.
- [~] **C3 — Static lock ordering (deadlock-freedom)** (DEFERRED — partial-order/deadlock-freedom typing on top of C1; multi-PR follow-up) *(multi-PR)* — a partial order over locks;
  out-of-order acquisition rejected. **Where:** lock types + check. **Test:** cyclic acquisition
  rejected. **Prior art:** lockdep, Abadi–Flanagan. **Depends:** C1.
- [~] **C4 — Concurrency model checking** (DEFERRED — Loom/Coyote-style bounded model checker; research harness) *(research)* — bounded model-checking (Loom/Coyote-style)
  of IPC/scheduler vs the memory model. **Where:** harness over `kernel/core/proc_ipc.mc`/`sched.mc`.
  **Prior art:** Loom, Coyote, CDSChecker. **Depends:** C1.

## U — Trusted/untrusted boundary (the #1 attack surface)

- [x] **U1 — User-pointer type** *(DONE `5072599`; `UserPtr<T>` opaque address class — deref/index/arithmetic already rejected, FOUND+FIXED a real hole: `.field` through a UserPtr was a kernel deref of user memory, now `E_USER_PTR_DEREF`. uaccess copy-in/out is the only path. R3 sweep FOUND+FIXED a second hole: `p as *u32` cast-stripped to a derefable kernel pointer (a user-address deref) → now `E_USERPTR_CAST_DEREF`; `UserPtr↔usize` still allowed. The only remaining deref path is an explicit `unsafe` cast/bitcast)* — a `UserPtr<T>` that **cannot be dereferenced**; only
  checked copy-in/out yields a value. **Where:** `kernel/core/uaccess.mc` + `kernel/core/syscall.mc`
  + the user_runtime path. **Test:** direct deref rejected (`fuzz-failclosed`); syscall paths adopt
  it. **Prior art:** Linux `__user`+sparse, Rust-for-Linux `UserSlice`/`UserPtr`. **Depends:** none.
- [x] **U2 — No double-fetch / TOCTOU** *(DONE `29c700d`; `UserSnapshot<T>` + `fetch_user` copy-once frozen value (structural defense) + `double-fetch-audit` lint flagging same-`UserPtr` re-reads; current kernel clean, self-test flags a textbook double-fetch)* — a copied-in value is an immutable snapshot;
  re-reading the same user datum (the double-fetch CVE class) is flagged. **Where:** uaccess + lint.
  **Test:** double-fetch fixture flagged. **Prior art:** double-fetch CVEs, Bochspwn. **Depends:** U1.
- [x] **U3 — Taint untrusted lengths/indices** *(DONE `b2e6f40`; `Tainted<T>` wrapper with no raw accessor — only `checked_len`/`checked_index`/`validate_bound` extract a usable value (fail-closed) + `taint-audit` lint flagging unvalidated tainted length/index/loop-bound use; kernel clean. Sweeps FOUND+FIXED two opacity bypasses: `bitcast<*Shadow>(t)` pointer-reinterpret (→ `E_BITCAST_TYPE`) and value-level `t as u8` (→ `E_OPAQUE_DECLASSIFY`, `d3d963d` — the gate is now keyed on the `opaque` property, so it covers Tainted/Cap/Rights/Guarded/any opaque struct uniformly; the only declassify path left is an explicit `unsafe`). The `taint-audit` lint is best-effort (misses cross-fn / reassign laundering — it's a lint, not a type). Full sema taint typing is follow-up)* — values from `UserPtr` are untrusted ints,
  bounds-validated before use as length/index/loop bound. **Where:** a taint pass. **Test:**
  unvalidated user length used as index rejected. **Prior art:** taint analysis, IFC (K2). **Depends:**
  U1.

## P — Untrusted-input parsing (we now parse attacker bytes: TCP/IP/DNS/TLS, ELF, fs)

- [x] **P1 — Total, bounds-checked parser primitives** *(DONE `33b3e82`; `std/bytes.mc` reads were already bounds-checked — added non-trapping `br_try_*` + adopted in DNS/TCP parsers; `parser-fuzz` oracle: 4.82M malformed parses, 0 over-reads, teeth verified)* — a parser API (over
  `std/bytes.mc` `ByteReader`) where every read is bounds-checked and a parser is a **total
  function** over a finite buffer (no read past end, no infinite loop). Adopt in `kernel/net/*`,
  `kernel/core/elf.mc`, fs decode. **Where:** `std/bytes.mc` + the parsers. **Test:** a **parser fuzz
  oracle** — truncated/malformed input must reject cleanly, never OOB/hang. **Prior art:**
  **EverParse**, langsec, nom. **Depends:** none.
- [x] **P2 — Never trust a length field** *(DONE `c25eb99`; `br_validate_len` gates rdlength (DNS), IP total-length, UDP length, ELF phnum×phentsize + filesz before they drive loops/copies; 196K hostile-length fuzz cases rejected, 0 over-reads)* — wire length/count fields validated against the
  remaining buffer before driving a copy/loop. **Where:** parser type + check. **Test:**
  unvalidated-length fixture rejected. **Prior art:** Heartbleed. **Depends:** P1.
- [~] **P3 — Verified parsers for the wire formats** (DEFERRED — EverParse-style spec→verified-parser generation; research. P1/P2 give the total + length-validated slice) *(research)* — generate TCP/IP/DNS/TLS-record
  parsers from a spec with machine-checked safety. **Prior art:** EverParse/miTLS. **Depends:** P1.

## K — Capability & information-flow in the type system (on-thesis)

- [x] **K1 — Unforgeable, monotonic capability types** *(DONE `c6ba536`; FOUND+FIXED a forgeable `Cap` (public field → struct-literal forge) by making it `opaque`; added `std/rights.mc` opaque narrow-only `Rights` + `RCap<R>` — forging/widening now `E_PRIVATE_FIELD`. Grant attenuation already runtime-enforced)* — `Cap<T, Rights>` constructible
  only by the kernel; rights only **narrow**, never widen; no ambient authority. The
  attenuated-subgrant property becomes a *type law*. **Where:** the `Cap<>`/grant types
  (`kernel/lib/granttab.mc`, `std/grant.mc`, `std/mask.mc`). **Test:** forging/widening rejected
  (`fuzz-failclosed`); parent⊇child mask law as a test. **Prior art:** **seL4** capability calculus.
  **Depends:** none.
- [~] **K2 — Information-flow / taint for secret & untrusted data** (DEFERRED — full IFC/label typing; research. U3 + secret<T> give the runtime/lint + constant-time slice) *(research)* — label data; secret
  cannot flow to an untrusted sink (the agent-exfiltration threat, lifted to types). **Where:** an
  IFC pass. **Test:** labeled-flow fixture; metamorphic. **Prior art:** **Jif, HiStar, Flume**.
  **Depends:** K1. *(Pairs with U3.)*

## A — ABI / FFI layout safety (proven gap — the Virtq drift bug)
> A `std/virtqueue.mc` struct mirrored in a C runtime drifted → BSS corruption → boot hang.

- [x] **A1 — Auto-generated layout assertions for shared structs** *(DONE `1f538e5`; `mcc emit-layout` → `_Static_assert(sizeof/offsetof)`; also FIXED real Virtq drift in 3 C mirrors that were ~32B short)* —
  emit `static_assert(sizeof==…, offsetof(f)==…)` for every MC struct mirrored in a C runtime, so
  drift is a **compile error**. Would have caught the Virtq bug. **Where:** the C emit + `*_runtime.c`
  headers. **Test:** deliberately drift a struct → build fails; regression fixture. **Prior art:**
  `cbindgen`, Rust `#[repr(C)]` layout tests. **Depends:** none.
- [x] **A2 — Single source of truth for shared structs** *(DONE `175684f`; `mcc emit-c-struct` generates the full C struct from MC; the virtqueue structs are no longer hand-written — `grep "typedef struct Virtq"` finds only the generated header → drift structurally impossible)* — generate the C mirror from the MC
  struct (or vice-versa) — drift becomes impossible. **Where:** a header-codegen step. **Test:**
  generated header matches; no hand-edit path. **Prior art:** `bindgen`. **Depends:** A1.

## T — Termination & bounded resources / the agent-program verifier (on-thesis)

- [x] **T(term)1 — Bounded-loop / no-unbounded-recursion check for critical code** *(DONE `9b38b3c`; in `#[irq_context]`/`#[bounded]` fns a loop must match a bounded shape (for-over-array, monotone counter<bound, or has a break) else `E_UNBOUNDED_LOOP`; direct recursion → `E_UNBOUNDED_RECURSION`. Shapes not proofs — opt-in; mutual recursion is follow-up)* — loops in
  critical sections + IRQ handlers must be statically bounded; no unbounded recursion. **Where:** a
  check pass + region marking. **Test:** unbounded loop in a critical region rejected. **Prior art:**
  eBPF verifier, SPARK. **Depends:** C2.
- [~] **T(term)2 — Agent-program verifier (the eBPF-verifier analog)** (DEFERRED — BLOCKED on the agent-program loader (R3), which doesn't exist yet; the capstone, builds on K1 + T(term)1) *(multi-PR → research) —
  agent-OS capstone* — before a loaded agent program runs, statically verify it is memory-safe,
  bounded/total, and only invokes its **granted capabilities**. The loader gate that lets the kernel
  run untrusted agent code. **Where:** a verify pass + the agent loader (deferred R3) +
  `kernel/core/agent.mc`. **Test:** unsafe/unbounded/over-privileged agent rejected at load;
  conforming one runs confined. **Prior art:** the **eBPF verifier**, proof-carrying code, seL4.
  **Depends:** K1, T(term)1, the agent loader.

## S — Constant-time / secret types (side channels; relevant since TLS landed)

- [x] **S(secret)1 — `secret<T>` type** *(DONE `f1f3320`; `Secret<T>` opaque zero-cost class; `E_SECRET_BRANCH` (if/switch/while), `E_SECRET_INDEX` (array/slice/ptr-offset); taint propagates through arithmetic + comparison (secret bool); `declassify`/`reveal` behind `unsafe`. Both backends. R3 sweep FOUND+FIXED an `as`-cast declassify bypass (`s as u32` stripped secrecy with no unsafe → now `E_SECRET_DECLASSIFY`) AND the overlay-reinterpret channel (`f93838a`): a read of ANY arm of an overlay union with a `Secret` arm is now itself secret, so write-`.s`/read-`.plain` no longer strips secrecy. No known sema bypass remains outside an explicit `unsafe` cast)* — forbids secret-dependent branches, indexing,
  and memory access (timing/cache side channels) for key/crypto material; apply to the TLS/key path.
  **Where:** a type + constant-time check + the TLS glue. **Test:** secret-dependent branch rejected;
  constant-time lint. **Prior art:** **FaCT**, HACL*/Vale, Rust `subtle`. **Depends:** none.
  *(BearSSL is already constant-time; this covers MC's own secret handling.)*

## F — Fault isolation / panic discipline

- [x] **F1 — Classify traps + contain agent faults** *(DONE `1e88424`; real M-mode trap from an illegal op classified by fault domain → faulting agent killed+reclaimed, kernel+others survive. Honest limit: from-trap context-switch INTO another agent's saved register context not yet wired — agents are inline-driven, as elsewhere)* — traps classified recoverable vs fatal;
  a recoverable fault in an agent is contained to its capability/fault domain (reuse
  `proc_oom_kill`/death path), not a kernel halt. **Where:** `kernel/arch/riscv64/trap_runtime.c` +
  the process fault path. **Test:** a faulting-agent demo — kernel survives, agent killed, others run
  (extends the OOM-kill keystone). **Prior art:** microkernel fault model, Tock. **Depends:** none.

---
# Unified critical path

1. **Cheap, evidence-backed foundations:** **A1** (retires the Virtq drift class), **S0.1**
   (definite-init), **S0.2** (`unsafe` boundary), **U1** (user-pointer type), **P1** (parser
   totality).
2. **Biggest dynamic ROI:** **D2.1** (KASAN-in-QEMU) — reuses the boot gates.
3. **Worst bug class:** **C1 + C2** (concurrency discipline), with **D2.3** (KCSAN) as the dynamic net.
4. **Codegen-is-a-UB-source:** **V3.2** (coverage) + **V3.1** (translation validation).
5. **On-thesis isolation:** **K1** (capability types) + **F1** (fault containment).
6. **Temporal safety:** **T1.1 → T1.2** (region/move borrows).
7. **Agent-OS capstone:** **T(term)2** (agent-program verifier; needs K1 + T(term)1 + the loader).
8. Everything else (S0.3, T1.3/4, D2.2/4/5, V3.3/4, H4.*, C3/C4, U2/U3, P2/P3, K2, A2, S(secret)1)
   trails by dependency.

The throughline: MC has the mechanisms; hardening pulls their disciplines into the type system
(static, zero-cost) or the trap/sanitizer model (cheap dynamic). **K** + **T(term)2** are what make
this an *agent* OS — static guarantees for running untrusted agent code.

See also `docs/mcfuzz-coverage-todo.md` (fuzzer generator surface), `docs/agent-os-vision.md`, and
memory `differential-testing.md`.
