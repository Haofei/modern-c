# Self-Hosting MC — Plan (stress-test-driven)

> **✅ STATUS (2026-07-02): SELF-HOSTING ACHIEVED — `mcc2` compiles `mcc2` (byte-identical fixpoint),
> gated by `selfhost-bootstrap-test` in m0.** The sections below are the ORIGINAL PLAN + phase-by-phase
> EXECUTION LOG (historical). Where an early section says a phase is "remaining/partial", read it as the
> state *at that point in the log* — the "SELF-HOSTING ACHIEVED" entry near the end (and
> docs/language-gap-fixes.md) reflects the final state. 13 language/compiler gaps were found+fixed; perf
> measured (~2 MB/s, faster than clang -O0 on mcc2's output).

**Goal (the "why"):** bootstrap the MC compiler *in MC* to stress-test the language and
compiler harder than any synthetic benchmark can. The largest MC program written to date is
~1.1k lines; a compiler is 12–55k. The point is not primarily to ship `mcc2` — it is to
**find everything MC does not support, or does slowly, at scale.** The two ledgers below are
the real deliverables:

- [`docs/self-host-gaps.md`](self-host-gaps.md) — every feature MC can't express or expresses
  badly, with a minimal repro. ("what we do not support")
- [`docs/self-host-perf.md`](self-host-perf.md) — cycle/wall measurements at scale. ("or slow")

**Scope decision:** *subset self-compile* (Phase 0 + P1–P5). We build a subset `mcc2` that
emits **C only** and can compile its own (subset-restricted) source. Full parity (LLVM
backend, async-lowering, full generics/traits) is Phase 6, pursued only as far as stress-test
ROI justifies. Target runtime: **hosted profile** (`std/hosted_io.mc`, compiled via the
existing Zig `mcc` → C → clang → host binary).

---

## 1. Feasibility summary (why this is tractable)

Two inventories were taken: MC's language capability matrix, and the Zig compiler's
feature-dependency surface. Reconciling them: **4 of the 5 "hardest" Zig dependencies already
exist in MC.** The language is ~85% there; the dominant work is *library* + *scale hardening*.

| Zig dependency (compiler leans on) | MC status today | Work |
|---|---|---|
| Tagged unions + exhaustive `switch` | ✅ `union{...}` payloads, `switch` binding, exhaustiveness, comptime layout reflection | none — maps 1:1 |
| Error unions `!T` + `try` | ✅ `Result<T,E>` + `?` propagation operator | none — maps to `Result`/`?` |
| Allocator abstraction + `defer` | ✅ `*mut dyn Allocator`, `std/alloc/arena.mc`, `defer` | none — maps 1:1 |
| Slices + `std.mem` string ops | 🟡 `[]const u8` + `std/mem.mc`; missing `eql/indexOf/split` + string builder + `allocPrint` | library |
| Generic `HashMap` / `ArrayList` (2000+ uses) | 🔴 generics exist (`comptime T:type`, monomorphized) but **no growable Vec, no HashMap, all std containers fixed-capacity** | **the one real blocker** |

### Known flat gaps found during review (repro before fixing)
- **No hosted `argv`/`argc`** — hosted `main()` is nullary; `mcc2 in.mc -o out.c` needs argument
  access. (Kernel-side argv exists in `kernel/lib/args.mc`; the gap is the *hosted* `main` ABI.)
- **`std/collections/vec.mc` is SIMD lane helpers, not a dynamic array.** Name collision to resolve.
- **No hashmap anywhere** in the tree.
- **AST design choice — prefer an index-arena** (node IDs into a flat `Vec`), like Zig's own
  compiler, for scale/ownership. *Note:* this is a preference, **not** a language limitation —
  MC does support pointer-recursive structs (`struct Node { next: *mut Node, ... }` lowers to a
  forward-declared `typedef` + `struct Node *next;`, `src/lower_c_emitter.zig:792`). The
  index-arena is chosen for cache behavior and simpler lifetime, and it makes the `Vec` work
  load-bearing.
- **No string builder / no `allocPrint`** (needed ~180 sites in the Zig compiler).
- Ergonomic watch-items (not blockers): no labeled break/continue; `?` requires matching
  return type (Zig's `try` auto-coerces error sets — expect friction in deep call chains);
  no default/named args; no inline lambdas (have `bind`+closure).

---

## 2. Strategy: bootstrap-by-subset, not big-bang

Porting 55k lines before anything runs would bury the gap-signal under a year of plumbing.
Instead, grow a subset compiler; each phase stresses a **distinct** language subsystem and
produces a runnable milestone. The existing Zig `mcc` is the **differential oracle**; the corpus and the *kind* of parity are
phase-specific — see the oracle rules in Section 4 (full-corpus exact diffs for lex/parse,
subset behavioral parity for sema/lower/self-compile).

Skip until late (adds ~12k lines, little new *language* stress): LLVM backend,
`async_lower.zig`, monomorphization edge cases.

---

## 3. Phase 0 — De-risk the blocker + close flat gaps (DO FIRST, highest signal)

Spike the missing containers *before* porting any compiler code — if MC's generics can't
express them, that is the single most important finding of the whole exercise.

| # | Deliverable | Stress-test questions it answers |
|---|---|---|
| 0.0 | **DECIDED (b): allocate-copy-free**, no trait change. The `Allocator` trait exposes only `alloc`/`free`; growth allocates a new block (capacity ×2, start 4), copies, frees the old. Amortized O(1). | resolved by the spike; copy cost tracked in perf ledger |
| 0.1 | **DONE** — `std/collections/dynarray.mc` (`Vec<T>`, heap-backed, growable, allocator stored as provenance like `Arc`); `vec-test` gate green host+Docker. Generics fully express it; `Vec<T>` is copyable (not `move`), `vec_free` is manual. | ✅ answered: generic struct holds `PAddr`+`*mut dyn Allocator`, grows, monomorphizes at `Vec<u32>`; element access via `raw.load/store<T>` |
| 0.2 | **DONE** — `std/collections/hashmap.mc` `StrHashMap<V>` (string keys, open-addressing, FNV-1a, grow+rehash); hashmap-test green. | fully-generic key blocked by no Hash/Eq bounds (G16); grow+rehash works |
| 0.3 | **DONE** — `std/strbuf.mc` `StrBuf` over `Vec<u8>`; strbuf-test green. | growable byte buffer + put_u32/hex works; `sb_as_slice` blocked by G12 |
| 0.4 | **DONE** — `std/hosted_args.mc` + `hosted_args_rt.c` shim; argv-test green. | MC has no compiler-level `main`; entry is a link concern |
| 0.5 | **DONE** — `std/mem.mc` `mem_eql`/`starts_with`/`index_of[_byte]`/`split_*`; memstr-test green (C+LLVM). | `.len`/indexing/sub-slice work; `?usize` returns blocked by G11 |

**All Phase 0 gates green (host + integrated); 5 new m0 gates registered.** Dominant gaps
surfaced — **G11 (value optionals `?V`)**, **G12 (`[]const u8` half-implemented)**, **G18
(unions can't be generic)** — see the gap ledger.

**Phase 0.6 DECISION: DEFER the deep compiler fixes; proceed to P1 with workarounds.**
Rationale (first principle): fixing value-optionals + real slices + generic unions is weeks of
deep sema/backend surgery, and we should not invest it *speculatively*. Idiomatic workarounds
exist and are enough to write a lexer: `Result<T,E>` value returns (these DO work), per-type
concrete unions, `mem.as_bytes`, `ByteReader`, and **index-based tokens** (store `{kind,start,len}`
into the source buffer — exactly how Zig's own tokenizer works, no per-token slices). P1 (lexer)
will then produce EMPIRICAL evidence of how painful G11/G12/G18 really are; that evidence — not
speculation — justifies a Phase 0.6 if warranted.

**Gates (MC rules):** each ships with a first-principle before/after **cycle-count bench** +
**m0 green both backends**. Any container that cannot be expressed → immediate top-priority
gap-ledger entry (this is the make-or-break risk, learned on day one).

---

## 4. Phases 1–5 — Grow the subset

Each phase: worktree sub-agents, measure before/after, parity-gate both backends, **full m0 as
the differential gate**, and differential-check against the Zig `mcc` oracle — but the corpus
and the *kind* of parity are **phase-specific**. Lex/parse are language-total, so they use the
full 117-file spec corpus with exact artifact diffs. Sema/lower/self-compile are **subset**
milestones, so they use a **subset corpus** and **behavioral / normalized-artifact** parity
(same accept/reject verdict, same program output) rather than exact emitted-C byte diffs (the
subset `mcc2` legitimately emits different C than the full Zig `mcc`).

| Phase | Subsystem (~LOC) | Language subsystem stressed | Corpus & parity | Milestone |
|---|---|---|---|---|
| **P1** | Lexer (~1.5k) | slices, byte handling, enums, `Vec<Token>` | **full corpus**, exact token diff | `mcc2 lex` token-diffs vs Zig `mcc` |
| **P2** | Parser + AST (~2.5k) | index-arena AST, `Vec`-heavy tree build, `Result`/`?` recovery | **full corpus**, AST-dump diff | AST-dump parity on 117 spec files |
| **P3** | Sema subset (~4k) | `HashMap` symbol tables at scale, exhaustive switch over 20+ AST variants, `?`-propagation under deep chains | **subset corpus**, same accept/reject verdict | type-checks subset; rejects the subset `*_reject.mc` cases |
| **P4** | Lower-to-C subset (~5k) | big string building (`strbuf`/allocPrint), name mangling, deep recursion | **subset corpus**, behavioral (run output ==) | **`mcc2` compiles `hello.mc` → C → clang → runs** |
| **P5** | **Self-compile the subset** | scale: monomorphization blowup, compile-time speed, generated-C size, clang time on that C | subset-restricted `mcc2` source, behavioral | **`mcc2` compiles `mcc2`**; behavior matches Zig-`mcc`-built `mcc2` |

**P6 (optional, ROI-gated):** widen subset toward parity — user-code generics, traits, async,
LLVM backend. Full parity is *not* required; the gaps are the point.

---

## 5. Execution mechanics (MC standing rules)

- Commit **directly on master** (never create branches); worktree agents cherry-picked →
  Docker-verified; respect the worktree-base ff gotcha.
- **Strict per-file `git add`** (never `-A`).
- Build/test via **Docker**; host skips LLVM/qemu gates.
- **Measure first** (rdcycle/wall, cycle CSR); **parity both backends**; **full m0** as the
  differential gate (it repeatedly catches what narrow gate sets miss).
- End commits with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Non-goals unchanged: no JIT/AOT (W^X), never weaken the hardening suite for speed.

---

## 6. Effort & risk

- **Subset self-compile ≈ 12–18k lines of MC** — exercises every language subsystem hard.
  Weeks-to-a-couple-months of agent-parallel work, *not* the 9–12 months a naive full-port
  estimate implies (that estimate assumed building language features MC already has).
- **Top risk:** generics can't cleanly express `Vec<T>`/`HashMap<K,V>` (value-semantics
  containers, `move`-type interaction, per-import monomorphization blowup). **Mitigated by
  Phase 0** — learned on day one.
- **Second risk:** monomorphization / compile-time explosion at scale. This is a *measurement
  target*, not a failure mode.

---

## 7. Ledgers (living — updated every phase)

The gap and perf ledgers are the primary output. Scaffolds live in
[`self-host-gaps.md`](self-host-gaps.md) and [`self-host-perf.md`](self-host-perf.md).

---

## 🎉 SELF-HOSTING ACHIEVED (2026-07-02)
**`mcc2` compiles `mcc2`.** All 5 core modules (lexer, parser, sema, emit_c, main) + all std deps compile
through `mcc2` to clang-clean C; the emitted whole-program TU links into `mcc2′`; `mcc2′` compiles a program
and its output is **byte-identical to `mcc2`'s (a true fixpoint)**. Permanently gated: `selfhost-bootstrap-test`
(`605b8cc1`) in m0 — builds mcc2 → mcc2 self-emits mcc2′ (diagnostic-clean, 314 KB TU) → links → fixpoint
byte-identical → mcc2′ compiles+runs a program. Per-module gates: selfhost-{lexself,parseself,semaself,emitself,
mainself}-test. The subset self-hosts; the original stress-test goal ("what MC doesn't support, or is slow") is
fully answered — 13 real language/compiler gaps found+fixed along the way (docs/language-gap-fixes.md), perf
measured (mcc2 ~2 MB/s, faster than clang -O0 on its output).

## Execution log (post-gap-fix continuation, 2026-07-01)
- After the 13-gap compiler fix + selfhost refactor (see docs/language-gap-fixes.md), continued widening
  mcc2 and pushing toward literal self-compile:
  - **P5.12 opaque struct** (`6d4fa5ee`) — contextual `opaque` qualifier reusing the struct path.
  - **P5.13 `unreachable;` + infix bitwise/shift** (`d6e7605`) — `& | ^ << >>` with C precedence; prefix-`&`
    vs infix-`&` by position; `unreachable`→`mc_trap_Unreachable()`.
  - **P5.14 bool literals + address-class model** (`627c022`) — `true`/`false`; `PAddr`/`VAddr`/`DmaAddr`→
    `uintptr_t`, `phys()`, `as`-mint casts, struct-literal return compound-literal. **MILESTONE: `mcc2`
    compiles a REAL std module `std/addr.mc` end-to-end → clang-clean C** (`selfhost-addr-test`), all 18 prior
    gates + mcc2-cli green.
- **State:** mcc2 language-subset coverage ~85–90% of its own source; compiles a real std module. **Next real
  blocker: `std/mem.mc` needs value optionals `?usize`+`if let` IN mcc2's SUBSET** (note the recursion — the
  R-std refactor made std/mem USE `?usize`, so mcc2 must now support it to compile mem.mc). Then multi-file std
  (G29 macOS-only), then feed all selfhost/*.mc + std deps through mcc2 → literal self-compile. Each a vertical.

## Execution log

- **2026-07-01 — Phase 0 COMPLETE (master @ c3106bb + follow-ups).** Vec<T> (`8b5c22b`),
  StrHashMap<V> (`fd603ed`), StrBuf (`6eab817`), hosted argv (`5b04389`), mem string ops
  (`6782fb5`), all cherry-picked from parallel worktree agents. 5 new m0 gates registered.
  **Full Docker `m0` green: real_failures=0 (259s)** — both backends, nothing regressed. The
  make-or-break spike (heap-backed generic `Vec<T>`) proved MC generics fully express growable
  containers. Findings G9–G18 recorded in the gap ledger; two dominant gaps (G11 value
  optionals, G12 slices) → Phase 0.6 deferred (workarounds suffice; let P1 prove the need).
- **2026-07-01 — P1 (lexer) DONE** (`dc41aa4`). `selfhost/lexer.mc` (~500 LOC) reproduces all 95
  `TokKind` variants (7 base + 47 kw + 41 ops/punct), 9 gate inputs assert kinds/counts/spans vs
  `src/lexer.zig`; `selfhost-lex-test` gate registered. Index-based tokens were pleasant; the pain
  was **G19** (below). Findings: G19 (Vec of struct), G20 (`let` function-scoped), G21 (enum→int
  needs `open enum`); corrections (ascii predicates exist, char literals fine). Keyword table = ~2×
  the Zig line count (G12 consequence).
- **2026-07-01 — G19 FIXED** (`1855eab`). `Vec<T>` element access switched to `raw.ptr<T>`+deref →
  works for struct T (scalar `raw.load/store` was aggregate-incompatible). Unblocks the P2
  index-arena AST (`Vec<AstNode>`). vec-test now covers a struct element.
- **2026-07-01 — P2 (subset parser + index-arena AST) DONE** (`5cb1a2a`). `selfhost/parser.mc`
  (~340 code LOC): flat `Vec<Node>{kind,main_token,lhs,rhs}` + length-prefixed `Vec<u32>` extra
  runs; precedence-climbing ported verbatim from `src/parser.zig`. Gate asserts fn/param/block
  structure, `a+b*c` precedence, if/else, while+call, and err-count on malformed input. Index-arena
  "felt natural" (validates G19 fix); mutual recursion works via forward decls. New findings G22
  (flat cross-import namespace collision), G23 (`return call==call` codegen gap); G20 refined.
  Verbosity ~1.3–1.4× the Zig original.
- **2026-07-01 — P3 (subset sema) DONE** (`8122cf9`). `selfhost/sema.mc` (~497 code LOC): two-pass
  name-res + type-check over the P2 arena; `StrHashMap<u32>` fn table + per-fn `StrHashMap<SmType>`
  locals (struct value — G19 dividend). Gate: 1 accept + 6 reject cases (unknown name, arg count/type,
  non-bool cond, return mismatch, assign-to-param). `StrHashMap` scaled cleanly; Result/struct-return
  propagation painless. New findings G24 (keywords steal locals), **G25 (`.raw()` vs switch-exhaustiveness
  mutually exclusive — sharpest compiler-ergonomics loss)**, G26 (unused-let hard error); G23 widened to
  typed let-init. Verbosity ~1.4–1.5×. G22 prefix discipline (sm_) held with a 3rd module. Next: P4
  (lower-to-C subset) — and widen the P2 grammar (keyword-types, `var`) toward real mcc2 source.
- **2026-07-01 — P4 (subset emit-C) DONE — MILESTONE** (`073354b`). `selfhost/emit_c.mc` (~300 code
  LOC) walks the arena → C via `StrBuf`; added `sb_put_cstr(*const u8)` to `std/strbuf.mc` (solves the
  G12 emission problem — string literals are `*const u8`). **End-to-end round-trip green: `mcc2` source
  → emitted C → clang → running binary** (`add(2,3)==5`, `fact(5)==120`). No new gaps; G25 avoided via
  `if`-chains + ordinal-range. **The P1–P4 arc = a working subset MC-compiler-in-MC.**
- **P5 (full self-compile) — REMAINING, large.** mcc2's own source uses structs/enums/generics/slices/
  match/imports/etc. — none in the current subset. True `mcc2`-compiles-`mcc2` needs the front end
  widened across the whole P5 gap list (see gap ledger). Next concrete step: package the pipeline as a
  standalone `mcc2` CLI (`selfhost/main.mc` via hosted argv+IO) and MEASURE it (fills the perf ledger,
  the "or slow" deliverable), then widen the grammar incrementally.
- **2026-07-01 — `mcc2` CLI + perf DONE** (`2ac36e7`). `selfhost/main.mc` (~140 LOC): `mcc2 in.mc` reads
  the file (hosted argv+IO into a 1 MiB `global` buffer → `mem.as_bytes` slice), runs the pipeline, writes
  emitted C to stdout. **PERF (perf ledger): ~20,800 fns/s ≈ 2.0 MB/s; mcc2 wall 48 ms < clang -O0 73 ms
  on its own output — mcc2 is FAST, no scaling pathology at 1000 fns.** ~2× headroom (dedup sema/emit
  re-parse). `mcc2-cli-test` gate registered. This closes the "or slow" half of the goal for the subset.
- **2026-07-01 — P5.1 (structs vertical) DONE** (`4138ed1`). Parser+sema+emit extended for `struct` decls,
  member access (chains free), struct literals in typed positions, `var`/mutation, `bool`/`void` types.
  `selfhost-struct-test` green (`mk(2,3)==6`, rejects unknown field); 4 prior gates still pass. New: G27
  (`.raw()` on variant-path literal rejected), G23 broadened, duplicated pair-run walking across 3 stages.
  **NEXT self-compile blocker = enums** (`open enum`, `.variant`, `switch`, `.raw()` — mcc2's own source is
  built on them), then generics, imports, traits.
- **2026-07-01 — P5.2 (enums vertical, no switch) DONE** (`f77c011`). Parser+sema+emit for `open? enum`
  decls, `.variant` literals, `== .variant`, `.raw()`, enum-typed values; C repr matches
  `src/lower_c_defs.zig` (transparent `typedef <repr> NAME;` + auto-numbered `enum{}`). `selfhost-enum-test`
  green (`pick`); all 5 prior gates pass. Found G28 (enum-lit node lacks its enum) + fixed a real
  double-paren `if` codegen bug. Next vertical: **`switch`** (lets mcc2 stop paying the G25 if/else tax and
  match its own dispatch idiom), then generics.
- **2026-07-01 — P5.3 (`switch` vertical) DONE** (`be68e27`). `switch` statement over enum subjects with
  `.variant`/`_` arms, real exhaustiveness (closed→all variants or error; open→`_` required; duplicate-arm
  error) — the payoff the G25 if/else workaround couldn't express. C `switch` on the transparent-int enum
  (no `-Wswitch` hazard). `selfhost-switch-test` green (accept + 2 reject); all 6 prior gates pass. No new
  gaps (smoothest vertical). Note: `sema.mc` itself now uses `switch`, so mcc2's own source already needs
  this. Next vertical: **multi-module imports** (mcc2 is split across selfhost/*.mc + std/* — can't resolve
  yet), then generics.
- **2026-07-01 — P5.4 (multi-module imports) DONE** (`ee8adf4`). Loader in `main.mc`: BFS-reads +
  dedups + concatenates imported modules (root-dir- then as-given-relative path resolution) into a 4 MiB
  buffer, runs the pipeline once (flat namespace). `import` is an identifier+string (not a keyword),
  parsed as a no-op `import_decl`. Added an emit forward-prototype pass (order-independent, cross-module
  mutual recursion). `selfhost-import-test` green (linear + diamond dedup); all 7 prior gates pass. Found
  G29 (hosted_io AT_FDCWD Linux-hardcoded). **HONEST: subset compiles ~0% of mcc2's own source — the hard
  blockers remain: generics, fixed arrays, traits, unsafe/raw, match, `?`.** Next: generics (decisive).
- **2026-07-01 — P5.5 (generics vertical) DONE** (`de34d4d`) — the hardest so far. Monomorphized generic
  structs (`S<T>`) + generic fns (`comptime T: type`): per-concrete-type emission (`Box_u32`/`Box_u64`),
  dedup, multi-instantiation, call-site type-arg dropping (`f(u32,x)→f_u32(x)`), type-param return subst.
  Substitution via threaded scratch fields (not arena clone); scalar-only instantiation filter avoids the
  self-recursion trap. `selfhost-generic-test` green (accept + arity reject); all 8 prior gates pass. New
  G30 (`*mut→*const` param). Deferred: multi-param, nested generics, trait bounds, const-generics, template-
  body type-checking. Next blocker: **fixed `[N]T` arrays**, then `impl`/traits, then `*mut dyn`.
- **2026-07-01 — P5.6 (fixed `[N]T` arrays) DONE** (`92df433`). `[N]T` types (const-int N), positional
  array literals `.{ e0, e1 }` (disambiguated from struct-literal `.{ .f = e }` via 3-token lookahead),
  `a[i]` read/write, and array-in-generic monomorphization (`[4]T`→`uint32_t data[4]`). `selfhost-array-test`
  green (`asum`, generic `Buf<T>`, length-mismatch reject); all 9 prior gates pass. Findings: MC array-lit is
  leading-dot-brace positional; NO `as` cast in subset yet; SmType is flat (nested arrays need a type arena);
  field access through an abstract type param isn't type-checkable (sidestep via generic accessor fn).
  **Self-compile estimate now ~35–40%** (data-shapes largely covered). Next lever: **`impl`/methods** (→~60%).
- **2026-07-01 — P5.7 (proper slices) DONE** (`b9816e2`). `[]const T`/`[]mut T` as fat pointers matching the
  real backend (`mc_slice_const_<T>{ptr,len}`); `.len`, `s[i]`, sub-slice from array & slice bases, by-value
  pass/return, `&` address-of, `mem.as_bytes(&arr)`. `selfhost-slice-test` green; all 10 prior gates pass.
  Key structural finding: emit has no shared typed IR → built a mini local-type resolver (~150 LOC); this
  re-derivation is the compounding tax of the 3-pass split. **Self-compile ~50–55%.** Next: `impl`/methods,
  traits/`*mut dyn`, then `unsafe`/`raw` intrinsics, `match`, `?`, `as` casts.
- **2026-07-01 — P5.8 (low-level: `unsafe`/`raw.*`/`extern "C"`) DONE** (`6acaaad`). `unsafe{}` blocks,
  `raw.ptr/load/store<T>` (cast-through-pointer, matching the real backend), `p.*` deref (read+write),
  `extern "C" fn` protos. Parsing `raw.op<T>(...)` needed a 4-token lookahead pinned to the `raw` namespace
  (C++ `<>` ambiguity). Addresses modeled as plain integers (no opaque PAddr yet). `selfhost-lowlevel-test`
  green; all 11 prior gates pass. **Self-compile ~60–65%** — the container/mem deps now PARSE. Next lever:
  **`as` casts + `sizeof`/`alignof`** (mechanical, used everywhere in dynarray), then **traits/`*mut dyn`**
  (structural — the Allocator seam). `match`/`?` are lowest (selfhost avoids them by design).
- **2026-07-01 — P5.9 (`as` casts + `sizeof`/`alignof`) DONE** (`e14aa90`). `x as T` (bind tighter than binary,
  looser than postfix — `as` is an identifier, not a keyword), `sizeof(T)`/`alignof(T)`→usize; `sizeof(T)`
  composes with generic substitution for free. Mechanical, NO new gaps. `selfhost-cast-test` green; all 12
  prior gates pass. **Self-compile ~65–70%** (container/mem bodies now type-check+emit). Last structural
  lever: **traits/`*mut dyn`** (vtables + method desugar + fat pointers — the Allocator seam; genuinely hard).
- **2026-07-01 — P5.10 (traits + `*mut dyn`) DONE** (`9603f78`) — the last major structural lever. `trait`
  decls, `impl Trait for Type` (methods desugared to `Type__m` + a rodata vtable), `*mut dyn` fat pointers,
  `*mut T`→`*mut dyn` coercion at call args, dynamic dispatch `d.vtbl->m(d.data,..)` — matching the real
  backend (thunks, no heap). All 14 selfhost gates + CLI green. Found+fixed G31 (`p.field`→`->`); G32
  (mutation-through-`*mut` flagged immutable → impl bodies not sema-checked). **Self-compile ~70–75%.**
  Remaining to literal self-compile: `?T`, `match`, general `mod.fn` calls, opaque `PAddr`, full std API +
  the end-to-end integration.
- **2026-07-01 — P5.11 (`match`) DONE** (`4106979`) — but a NON-feature: the "match 8×" estimate was a
  `grep` false positive (counted prose "ordinals match"/"first match wins"). Selfhost uses ZERO real `match`
  (and zero `?T`). `match` desugars to the existing `switch` (2 parser edits, no new gaps). **Lesson: profile
  by AST/keyword-token, not word-grep.** Language-feature coverage for the selfhost subset is now effectively
  complete.
- **2026-07-01 — END-TO-END SELF-COMPILE PROBE (ground truth).** Built standalone `mcc2` (251 KB) and fed it
  real files. Result: with an ABSOLUTE path, `mcc2` loads `std/addr.mc` (0 imports), parses+sema's most of it,
  and EMITS 197 lines of C — then reports parse/sema errors on advanced constructs. Relative-path imports fail
  on the macOS host (G29 `AT_FDCWD`; Linux/Docker fine). **So self-compile is PARTIAL-and-real: `mcc2` loads +
  partially compiles actual std source.** The remaining ~25% is INTEGRATION LONG-TAIL, not core features: per
  real file, a few advanced constructs (opaque structs, `wrap`/`sat` arithmetic domains, `bitcast`, `#[attr]`s,
  const globals) + `Result`/`if let` payload binding (for `main.mc`) + closing G32; plus G29 for macOS imports.
  Each is a small vertical; literal `mcc2`-compiles-`mcc2` is a bounded-but-multi-step integration from here.
- **STATUS: P1–P4 + CLI + perf + 11 grammar verticals (structs→traits→match) COMPLETE — a working, fast, subset MC-compiler-in-MC (~70–75% of its own source's features); end-to-end probe shows it loads + partially compiles real std files.** Remaining for
  *true* self-compile (P5): widen the front end across the P5 gap list (structs/enums/generics/slices/
  match/imports/…). That is a large, multi-phase effort; the subset milestone + the G9–G26 gap ledger +
  perf data already deliver the stress-test's north star ("what MC doesn't support, or is slow").
