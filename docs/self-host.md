# MC Subset Bootstrap Record and Full Self-Host Guide

> Single consolidated record of the MC self-hosting stress-test and subset bootstrap proof, plus the
> implementation guide for full self-hosting. **This is not a record of MC replacing the Zig compiler
> in `src/` yet.** §6 defines the remaining work to replace `src/`. Supersedes and merges the former
> `self-host-plan.md`, `self-host-arch.md`, `self-host-gaps.md`, `language-gap-fixes.md`, and
> `self-host-perf.md` (merged 2026-07-02). Section numbers below (§1–§5) are the five former docs.

## ⚠️ STATUS TERMS — read this first

| Term | Meaning | Current status |
|---|---|---|
| **True self-hosting / replacement** | An MC-written compiler replaces the ~67k-line Zig compiler in `src/` and passes the same whole-corpus gates. | **NOT achieved** |
| **Subset bootstrap proof** | `mcc2`, written in MC, compiles the subset needed for `mcc2` itself + its std deps, emits C, and reaches a byte-identical fixpoint. | **Achieved** |
| **Stress-test gap-fix program** | Use the subset compiler effort to find language/library/compiler gaps, then fix them in the real Zig compiler. | **Achieved for the logged gaps** |

**The ideal goal (NOT yet achieved): a compiler written in MC that REPLACES the ~67,000-line Zig
compiler in `src/`.** That has not happened and is a large, largely-unstarted effort. §6 is the
guide for finishing that replacement.

**What HAS been achieved** is a strictly narrower thing — a **subset bootstrap proof plus gap-driven
hardening of the real (Zig) compiler:**

- `mcc2` (the MC-compiler-in-MC under `selfhost/`, **~8,900 lines of MC**) compiles **a SUBSET of MC** —
  namely *itself + its std dependencies* — to a byte-identical fixpoint (gate `selfhost-bootstrap-test`).
  That gate is **C-backend only**: `mcc2` emits C, so the fixpoint is proven through the C backend +
  clang (`tools/toolchain/selfhost-bootstrap-test.sh`). The broader C/LLVM m0 suite also stayed green,
  but LLVM there gates the *Zig* compiler's other features — **not** the mcc2 fixpoint (mcc2 has no LLVM
  backend). This **proves the language can host a real compiler subset**. It does NOT compile the full MC
  language, the kernel, the full std, or with the full checker, and it is **not a replacement for `src/`**.
- The self-host attempt was used as a **stress test** to surface everything MC can't express or does
  slowly (the §3 gap ledger); the gaps it found were then **fixed in the real Zig compiler** (§4 —
  those are `src/*.zig` edits, e.g. G7/G8/G11–G30).
- `mcc2` itself was **architecture-hardened** (§2, typed pipeline) and **review-hardened** (§3).

**Scale gap (why true self-hosting is not finished):** production compiler = **67,097 LoC Zig** vs. `mcc2`
= **8,875 LoC MC** covering a subset. To make MC truly self-host you must reimplement in MC the full
checker (all hardening/move/effect/trait passes), **both** backends' complete feature coverage, the
optimizer/opt-equiv paths, the whole std/kernel language surface, and the driver — none of which `mcc2`
does today. See **[§6 — Full self-host implementation guide](#6-full-self-host-implementation-guide)**.

## Contents

1. [Plan and execution](#1-plan-and-execution) — the stress-test goal, phases P0–P5, and how the SUBSET bootstrap proof was reached.
2. [Architecture hardening](#2-architecture-hardening) — the 7-phase refactor of `mcc2` to a typed pipeline (parse-once → typed facts → scope stack → impl/generic checking).
3. [Gap ledger](#3-gap-ledger) — every language/library gap the effort surfaced (G1–G35) with current status.
4. [Real-compiler language fixes](#4-real-compiler-language-fixes) — the `src/*.zig` fixes that closed most of those gaps.
5. [Performance](#5-performance) — scale/throughput measurements.
6. [Full self-host implementation guide](#6-full-self-host-implementation-guide) — the acceptance criteria, harness, phases, and cutover plan for replacing the 67k-line Zig compiler.

---

## 1. Plan and execution


> **STATUS (2026-07-02): SUBSET BOOTSTRAP PROOF achieved — `mcc2` compiles `mcc2` (byte-identical
> fixpoint), gated by `selfhost-bootstrap-test` in m0.** This is a SUBSET proof, NOT full self-hosting —
> see the ⚠️ STATUS TERMS box at the top of this document and [§6](#6-full-self-host-implementation-guide). The
> sections below are the ORIGINAL PLAN + phase-by-phase EXECUTION LOG (historical); any early celebratory
> wording means "the subset fixpoint closed", not "the Zig compiler was replaced." 13+
> language/compiler gaps were found+fixed in the real compiler (§4); perf measured (§5).

**Goal (the "why"):** bootstrap the MC compiler *in MC* to stress-test the language and
compiler harder than any synthetic benchmark can. The largest MC program written to date is
~1.1k lines; a compiler is 12–55k. The point is not primarily to ship `mcc2` — it is to
**find everything MC does not support, or does slowly, at scale.** The two ledgers below are
the real deliverables:

- [`§3`](#3-gap-ledger) — every feature MC can't express or expresses
  badly, with a minimal repro. ("what we do not support")
- [`§5`](#5-performance) — cycle/wall measurements at scale. ("or slow")

**Scope decision:** *subset self-compile* (Phase 0 + P1–P5). We build a subset `mcc2` that
emits **C only** and can compile its own (subset-restricted) source. Full parity (LLVM
backend, async-lowering, full generics/traits) is Phase 6, pursued only as far as stress-test
ROI justifies. Target runtime: **hosted profile** (`std/hosted_io.mc`, compiled via the
existing Zig `mcc` → C → clang → host binary).

---

### 1. Feasibility summary (why this is tractable)

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

#### Known flat gaps found during review (repro before fixing)
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

### 2. Strategy: bootstrap-by-subset, not big-bang

Porting 55k lines before anything runs would bury the gap-signal under a year of plumbing.
Instead, grow a subset compiler; each phase stresses a **distinct** language subsystem and
produces a runnable milestone. The existing Zig `mcc` is the **differential oracle**; the corpus and the *kind* of parity are
phase-specific — see the oracle rules in Section 4 (full-corpus exact diffs for lex/parse,
subset behavioral parity for sema/lower/self-compile).

Skip until late (adds ~12k lines, little new *language* stress): LLVM backend,
`async_lower.zig`, monomorphization edge cases.

---

### 3. Phase 0 — De-risk the blocker + close flat gaps (DO FIRST, highest signal)

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

### 4. Phases 1–5 — Grow the subset

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

### 5. Execution mechanics (MC standing rules)

- Commit **directly on master** (never create branches); worktree agents cherry-picked →
  Docker-verified; respect the worktree-base ff gotcha.
- **Strict per-file `git add`** (never `-A`).
- Build/test via **Docker**; host skips LLVM/qemu gates.
- **Measure first** (rdcycle/wall, cycle CSR); **parity both backends**; **full m0** as the
  differential gate (it repeatedly catches what narrow gate sets miss).
- End commits with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Non-goals unchanged: no JIT/AOT (W^X), never weaken the hardening suite for speed.

---

### 6. Effort & risk

- **Subset self-compile ≈ 12–18k lines of MC** — exercises every language subsystem hard.
  Weeks-to-a-couple-months of agent-parallel work, *not* the 9–12 months a naive full-port
  estimate implies (that estimate assumed building language features MC already has).
- **Top risk:** generics can't cleanly express `Vec<T>`/`HashMap<K,V>` (value-semantics
  containers, `move`-type interaction, per-import monomorphization blowup). **Mitigated by
  Phase 0** — learned on day one.
- **Second risk:** monomorphization / compile-time explosion at scale. This is a *measurement
  target*, not a failure mode.

---

### 7. Ledgers (living — updated every phase)

The gap and perf ledgers are the primary output. Scaffolds live in
[§3](#3-gap-ledger) and [§5](#5-performance).

---

### SUBSET BOOTSTRAP FIXPOINT ACHIEVED (2026-07-02)
> NOTE: "achieved" here = the SUBSET fixpoint closed (`mcc2` compiles `mcc2`). It does NOT mean MC replaced the
> 67k-line Zig compiler — see the ⚠️ STATUS TERMS box up top and [§6](#6-full-self-host-implementation-guide).

**`mcc2` compiles `mcc2`.** All 5 core modules (lexer, parser, sema, emit_c, main) + all std deps compile
through `mcc2` to clang-clean C; the emitted whole-program TU links into `mcc2′`; `mcc2′` compiles a program
and its output is **byte-identical to `mcc2`'s (a true fixpoint)**. Permanently gated: `selfhost-bootstrap-test`
(`605b8cc1`) in m0 — builds mcc2 → mcc2 self-emits mcc2′ (diagnostic-clean, 314 KB TU) → links → fixpoint
byte-identical → mcc2′ compiles+runs a program. Per-module gates: selfhost-{lexself,parseself,semaself,emitself,
mainself}-test. This is a subset bootstrap result; the original stress-test goal ("what MC doesn't support,
or is slow") is fully answered — 13 real language/compiler gaps found+fixed along the way (§4), perf
measured (mcc2 ~2 MB/s, faster than clang -O0 on its output).

### Execution log (post-gap-fix continuation, 2026-07-01)
- After the 13-gap compiler fix + selfhost refactor (see §4), continued widening
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

### Execution log

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


---

## 2. Architecture hardening


**Status: ✅ IMPLEMENTED (2026-07-02) — all 7 phases (0–6) landed, each byte-identical + m0-green.**
Commits: Phase 0 `bd98665b` (parse once), Phase 1+2 `200b222d` (fact table + enum resolution),
Phase 3 `412fadd4` (expr types → facts), Phase 4 `d107cd1c` (scope stack), Phase 5 `55c15ee7` (impl
bodies), Phase 6 `0e48e728` (generic bodies, lenient). Every phase kept `selfhost-bootstrap-test`
byte-identical and passed full Docker m0 on both backends. Perf: mcc2-cli-test ~0.070s → ~0.049s
(~1.4×) from Phase 0's single parse. The section below is the original plan, preserved for the record.

**(original plan)** Prerequisite for making `mcc2` a trustworthy full
replacement for the Zig `mcc`, and the precondition for the two structural gaps that are still fully
open (semantic checking of generic instantiations + impl-method bodies).

**North star:** re-architect `mcc2` so that **parse happens once**, **sema builds a typed symbol
table**, and **emit consumes typed facts** instead of re-deriving them. This is NOT a rewrite and NOT
a port of the ~57k Zig lines — it is a staged refactor of the existing `selfhost/*.mc`, with the
`selfhost-bootstrap-test` byte-identical fixpoint held green at every commit.

Related durable records: `§1` (how we got here), `§3` (the
G1–G35 ledger; G28/G33/G34/G35 are the review-hardening patches this refactor will *subsume*),
`§5` (the ~2× headroom this refactor cashes in).

---

### 1. Why (the debt, from the code)

The current pipeline (`selfhost/main.mc`) is:

```
sema_check(src)   // parses src into SmState.p, type-checks, reports err counts, FREES everything
emit_c_run(src)   // parses src AGAIN, walks the fresh AST, emits C
```

Two independent parses of the same bytes; **sema's computed facts are discarded** before emit runs.
Consequences, each observed in the tree:

1. **Double parse.** Pure wasted work; `§5` records ~2× headroom "dedup the
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

### 2. Target architecture

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

#### 2.1 The typed side-table (`Fact`)

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

#### 2.2 Scope stack (retires `strmap_del` and the fn-wide locals model)

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

#### 2.3 Checking generic templates and impl bodies

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

### 3. Migration order — bootstrap stays byte-identical at every step

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

### 4. Risks & mitigations

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

### 5. Non-goals

- Full/bidirectional type inference beyond what the selfhost subset needs.
- Replacing monomorph-at-emit with a standalone mono pass (orthogonal; abstract-check doesn't need it).
- Feature parity with the Zig `mcc` / porting `src/*.zig`. This refactor makes `mcc2`'s *architecture*
  trustworthy; broadening *coverage* is the separate Phase 7+ long tail.

### 6. Expected payoff

- One parse → ~2× faster `mcc2` (perf ledger headroom realized in Phase 0).
- Emit becomes a straight-line printer over typed facts — deletes the shadow type system
  (`e_*_type_node`, `e_base_is_*`, enum re-resolution) and the `strmap_del` scope hack.
- G28/G34/G35 become structural guarantees rather than site-by-site patches; G32 falls out.
- Generic + impl bodies get real semantic checking — the last blocker between "proves MC can
  self-host a subset" and "mcc2 is a trustworthy compiler architecture."

---

### 7. Execution log (what actually landed)

All phases held the invariant: `selfhost-bootstrap-test` byte-identical fixpoint + full Docker m0
`real_failures=0` on both backends, per commit.

- **Phase 0** (`bd98665b`): `main.mc` parses once; emit reuses sema's parse via `emit_c_on(*Parser)` +
  `sema_parser`. Banked ~1.4× (mcc2-cli-test 0.070→0.049s). Realisation that this UNLOCKS everything
  else — before it, sema and emit had separate parses so no fact could cross.
- **Phase 1+2** (`200b222d`): `Vec<Fact>{ty,decl,flags}` indexed by node id; sema records each
  `enum_lit`'s resolved `enum_decl`; emit reads it via a `Parser.facts_addr` stash (mcc2's subset
  doesn't distinguish `*const`/`*mut`, and real-mcc's G30 is fixed, so the address round-trip is
  clean). Deleted the emit-side G28 re-resolution (`e_expr_targeted` et al).
- **Phase 3** (`412fadd4`): sema records every expression's `SmType`; `e_base_is_slice/is_ptr/is_dyn`
  read the fact (slice_=3, ptr_depth>0, dyn_=17), falling back to `e_local_type_node` only where sema
  didn't type a node. `e_local_type_node` stays as that fallback (retire once all consumers migrate).
- **Phase 4** (`d107cd1c`): a real lexical scope stack (`Vec<Binding>` + mark/pop) replaced the
  fn-wide `locals`/`muts` maps and `strmap_del`. Now catches block-local `let` used after its block.
- **Phase 5** (`55c15ee7`): `sm_check_impls` runs the shared per-fn checker over `impl` method bodies
  (their `self: *mut TYPE` is an ordinary pointer param). Closes "impl bodies unchecked"; `self.f = v`
  is allowed via the pointer-mutability path (G32 falls out).
- **Phase 6** (`0e48e728`): generic template bodies checked in a LENIENT mode (type param bound
  `unknown`; `sm_err` keeps only `unknown_name`/`arg_count`). Surfaced + fixed two latent builtins
  sema never had to know while generic bodies were skipped: `forget_unchecked` (move husk) and
  `mem.bytes_equal` (module-qualified builtin).

**Findings / residuals:**
- Regular helper calls inside a generic body are supported and now gated by `selfhost-generic-test`
  (`box_plus_one_u32` calls the non-generic `add1`). Phase 6's practical catch is still intentionally
  limited to generic-template **identifier** / arity errors, not full concrete per-instantiation
  type checking.
- `.variant` in `switch`-arm case labels and `assign` lvalues still use the emit name-scan (no
  expr-node fact for those positions) — documented G28 residual, unchanged by this refactor.
- Not yet done (future cleanup, not blocking): fully retire `e_local_type_node` once generic/impl
  facts cover its remaining consumers; migrate the `facts_addr` stash to a threaded emit context.


---

## 3. Gap ledger


Every MC language/library feature the subset bootstrap/stress-test effort ([§1](#1-plan-and-execution))
found missing, broken, or awkward — with a minimal repro. This is the "what MC does not support"
output of the stress test.

**Status legend:** `open` · `workaround` (usable but ugly) · `fixed` (commit) · `wontfix` (by design)

### Pre-seeded from review (2026-07-01, before any code)

| ID | Area | Gap | Repro / evidence | Severity | Status |
|----|------|-----|------------------|----------|--------|
| G1 | stdlib | No growable `Vec<T>` (only fixed-capacity containers; `std/collections/vec.mc` is SIMD lanes) | `find std -name '*.mc'`; no dynamic array | blocker | **fixed** — `std/collections/dynarray.mc` (`Vec<T>`), vec-test gate green host+Docker. Generics fully express a heap-backed growable container. |
| G2 | stdlib | No `HashMap<K,V>` anywhere | grep tree | blocker | **fixed** — `std/collections/hashmap.mc` `StrHashMap<V>` (string-keyed, open-addressing, FNV-1a, grow+rehash), hashmap-test green. Fully-generic-key blocked by G16. |
| G3 | runtime | Hosted MC has no argument access (`argv`/`argc`); hosted `main` is nullary. (Kernel-side argv DOES exist: `kernel/lib/args.mc`.) Gap is the hosted-`main` ABI for `mcc2`. | all hosted examples `fn main() -> i32`; kernel/lib/args.mc:1 | high | **fixed** — `std/hosted_args.mc` + `tools/toolchain/hosted_args_rt.c` shim (`export fn mc_main`), argv-test green. NB: MC has NO compiler-level `main` at all — entry is a pure link/crt concern (`grep '"main"' src/` = 0 hits). |
| G4 | stdlib | No string builder / no `allocPrint`-equivalent | `std/fmt/*` is fixed-size / streaming only | high | **fixed** — `std/strbuf.mc` `StrBuf` over `Vec<u8>` (put_byte/str/u32/hex), strbuf-test green. `sb_as_slice` NOT possible (G12); read via `sb_byte`. |
| G5 | stdlib | `std/mem.mc` lacks `eql`/`indexOf`/`startsWith`/`splitScalar` | grep | high | **fixed** — `std/mem.mc` `mem_eql`/`mem_starts_with`/`mem_index_of[_byte]`/`split_by`+`split_next`, memstr-test green (C+LLVM). `?usize`/`?[]const u8` returns became result structs (G11). |
| G6 | design (NOT a language gap) | Pointer-recursive structs DO work — `struct Node { next: *mut Node, value: u32 }` lowers to a forward-declared `typedef struct Node Node;` + `struct Node *next;` (`src/lower_c_emitter.zig:792`). Design note only: **prefer an index-arena AST** for scale/ownership, not because MC can't express pointer recursion. | verified emit; emitter:792 | note | n/a |
| G9 | stdlib/API | `Allocator` trait exposes only `alloc`/`free` — **no `realloc`/`try_alloc`** (`std/alloc/alloc.mc:13`). `heap_try_grow_in_place` exists but is not in the trait. | std/alloc/alloc.mc:13 | medium | **decided** — growth is allocate-copy-free (no trait change); capacity doubling gives amortized O(1). |
| G10 | toolchain | `mcc-cc.sh` compiles emitted C with `-Werror=unused-parameter`, so every trait-impl method must reference all params (an allocator ignoring `align`/`self`). Idiom: a cheap validating `unreachable` guard, as `arena_free_noop` does. | vec spike | low | workaround |
| G7 | ergonomics | No labeled break/continue | spec §11 | low | ~~open~~ **FIXED (2026-07-02, `02a1d7da`).** Zig-style labeled loops `outer: while/for {…}` + `break :outer;` / `continue :outer;` (bare jumps unchanged = innermost). New `Loop.loop_label` AST field (separate from the for-binding); break/continue carry an optional target; new diagnostic `E_UNKNOWN_LOOP_LABEL`; both backends; spec §8.5; gate `labeled-break-run-test` in m0 (labeled≠bare proof). Labeled jumps inside an await-bearing async loop are rejected (documented limit). **Follow-up (`bb0ba0e4`):** review found the C backend skipped the TARGET loop's defers on a labeled jump (ran only the innermost loop's) — returned 101 vs LLVM's 1101; fixed via `loopDeferMarkFor` (cleanup starts at the target loop's defer mark); regression added to the gate (now 1420). |
| G8 | ergonomics + **soundness** | `?` needs matching return type (no error-set auto-coerce like Zig `try`) | spec | ~~low (watch)~~ **was a SOUNDNESS HOLE** | ~~open~~ **FIXED (2026-07-02, `c0603cfa`).** Finding: cross-error-type `?` was NOT rejected — it was silently UNSOUND (C bit-copied `E1` into the `E2` slot; LLVM trapped on repr mismatch). Now `?` across differing error types requires an EXPLICIT user-written conversion, invoked automatically on the error path; absent one → new diagnostic `E_NO_ERROR_CONVERSION`. Mechanism: an `#[error_from]` free fn `#[error_from] fn(E1) -> E2` (a `From<E1>` trait is not expressible — impl blocks are keyed by `(trait,type)`, so one target can't carry two `From` impls; the attribute convention needs zero parser changes and stays explicit). Both backends; spec §21; gate `error-from-run-test` in m0 (proves the CONVERTED variant, not a reinterpret). `E1==E2` byte-identical. **Follow-up (`ceac9fff`):** review found duplicate `#[error_from]` for one `(E1,E2)` was accepted (resolver picked one by iteration order) and malformed signatures silently ignored → new `checkErrorFromDecls` rejects both (`E_AMBIGUOUS_ERROR_CONVERSION` / `E_INVALID_ERROR_FROM`); reject fixtures added. |

### Discovered during execution (Phase 0, 2026-07-01)

These are the substantive stress-test findings. **G11 and G12 are the two dominant themes** — a
compiler uses value-optionals and `[]const u8` on nearly every line, so both likely warrant a
proper compiler fix (candidate Phase 0.6) before the P1–P5 port, rather than per-site workarounds.

> **⚠️ STATUS SUPERSEDED (2026-07-01+). The per-row `Status` cells below record DISCOVERY-time state.**
> The follow-up program ([§4](#4-real-compiler-language-fixes)) **fixed most of these in the real
> compiler, both backends, m0-green.** FULLY FIXED: **G11, G12, G14, G16, G18, G19, G20, G22, G24, G25, G27,
> G30** (each row below is annotated). `G29` is **by-design** (Linux hosted target). NON-GAPS (misprofiled,
> no fix needed): `match`, `?T`-not-needed-for-selfhost, and the broad "no Hash/Eq bounds" (bounds work via
> `where`+UFCS — only Self-in-param, = G16, was a real gap).
>
> **Real-compiler gap status** (updated 2026-07-02): the last two "open" ergonomic gaps were implemented —
> **G7** (labeled break/continue, `02a1d7da`) and **G8** (`?` error coercion — which turned out to be a
> SOUNDNESS hole, `c0603cfa`). Together with the earlier wave (**G13** `4ae2a25a`, **G23** `ba25302d`,
> **G15** `6ab8b667`), every actionable real-compiler gap this ledger tracks is now FIXED, both backends
> m0-green. Only **G10**/**G26** remain as deliberate low toolchain workarounds (usable as-is). The
> `G28`/`G31`–`G35` rows carry their own current status inline.

| ID | Phase | Area | Gap | Repro / root cause | Severity | Status |
|----|-------|------|-----|--------------------|----------|--------|
| G11 | 0.2/0.5 | language | **Value optionals `?V` are not expressible** — only pointer-shaped optionals work (`?*T`, `?*dyn`, `?c_void*`). `?usize`/`?[]const u8`/`?u32` can be declared & `return null`'d but NO consumer form accepts them: `if let` → `E_IF_LET_OPTIONAL_REQUIRED`; `== null` → `E_NO_IMPLICIT_CONVERSION`; `switch` → `E_SWITCH_RESULT_TAG`. So a value optional is write-only. | `src/sema_type.zig` `isNullableValue()` admits only nullable pointers; `classifyNullableType()` → `.unknown` for value types | **high** | ~~workaround~~ **FIXED (real compiler, §4)** — value optionals `?T` implemented with a tagged `{present,value}` repr; `if let` / `== null` / `switch` all accept them. Was: result structs / `?*mut V` / sentinel. |
| G12 | 0.3/0.4/0.5 | language/codegen | **`[]const u8` slice support is half-implemented.** (a) string literals are `*const u8`, NOT `[]const u8` — `let s: []const u8 = "hi"` type-checks but `emit-c` → `UnsupportedCEmission` (`ast_query.isStringLiteralTarget`). (b) cannot construct a slice from raw ptr+len (no slice-from-parts); struct-literal to a slice type → `E_RETURN_TYPE_MISMATCH`. (c) `[]mut u8` → `[]const u8`: implicit → `E_NO_IMPLICIT_POINTER_CONVERSION`, explicit `as` → emits undeclared `mc_slice_mut_u8` / `E_REPRESENTATION_CHECK_MISSING`. (d) **soundness hole:** `pa_value(p) as []const u8` passes the checker but emits invalid C (casts the scalar, drops the length). | multiple 5-line probes (0.3/0.5 reports) | **high** | ~~workaround~~ **FIXED (real compiler, §4)** — string-literal→`[]const u8`, `[]mut`→`[]const` coercion, and the `x as []const u8` SOUNDNESS hole all closed (the illegal scalar-as-slice cast now errors `E_ILLEGAL_SLICE_CAST`). Was: `mem.as_bytes(&arr)` / `ByteReader`. |
| G13 | 0.5 | codegen | **Sub-slicing `base[a..b]` only lowers when `base` is a plain local/param of slice type.** A struct-field base (`sp.s[a..b]`), a re-slice, or a `mem.as_bytes(...)` result base → `exprSourceTypeForEmission`→null→`UnsupportedCEmission`. Also range endpoints must be simple operands (`hay[start..start+n]` fails; precompute `end`). | 0.5 `sn.mc` probe | medium | **FIXED (2026-07-02, `4ae2a25a`).** Re-slice, `mem.as_bytes(&a)[a..b]` base, and complex endpoints were already fixed; the struct-FIELD base `sp.s[a..b]` / `sp.s[i]` residual is now fixed too — `exprSourceTypeForEmission` (and the index/address-of paths) resolve a `.member` base's declared type (value or pointer-to-struct). Both backends (LLVM already handled it); spec fixtures `slice_ranges.mc`/`indexing.mc`. |
| G14 | 0.2 | soundness/analysis | **Escape analysis over-rejects returning `&field` reached through a heap pointer** (`return &slot.val` where `slot: *mut Entry`) → `E_LOCAL_ADDRESS_ESCAPE`, even though the storage is heap. | 0.2 report | medium | ~~workaround~~ **FIXED (real compiler, §4)** — escape analysis now allows returning a pointer-rooted `&field` (heap-reached), so `return &slot.val` is accepted. |
| G15 | 0.2 | stdlib | **No `wrapping_mul_u32`** in `std/math.mc` (has wrapping add/sub/shl). FNV-1a needs mod-2³² multiply; `*` is checked and traps. Cross-domain `wrap<u32>`↔checked needs explicit conversions both ways (`E_NO_IMPLICIT_CONVERSION`). | 0.2 report | low | ~~workaround~~ **FIXED (2026-07-02, `6ab8b667`)** — `std/math.mc` now exports `wrapping_mul_u32` (u64 product truncated to u32, staying in the checked domain); std-test covers the wraparound case. |
| G16 | 0.2 | language | **No `Hash`/`Eq` trait bounds** usable on a comptime-generic value → a fully-generic `HashMap<K,V>` can't hash/compare an arbitrary `K`. String-keyed only for v0. | 0.2 report | medium | ~~open~~ **FIXED (real compiler, §4)** — trait bounds on a generic `K` work via `where K: Trait` + UFCS `K.method(x)`; the real gap was `Self` in a non-receiver param position, now supported. (The broad "no bounds" framing was misprofiled.) |
| G17 | 0.3 | toolchain | Diamond-import dedup needs an **absolute** path to the root `.mc`; a relative path caused spurious `ImportNotFound`. `mcc-cc.sh` already passes absolute paths. | 0.3 report | low | note |
| G18 | 0.6-probe | language | **Tagged unions cannot be generic** — `union Opt<T> { some: T, none }` fails to parse (`expected '{' after union name`, `src/parser.zig:1769`). So a generic value-optional / generic sum type is not expressible; the idiomatic workaround for G11 (a generic `Opt<T>`) is blocked. Structs ARE generic; unions are not. | `union Opt<T>{...}` → ParseFailed | medium | ~~open~~ **FIXED (real compiler, §4)** — generic tagged unions parse and monomorphize (pre-sema, zero backend change). |
| G19 | P1 | codegen | **`raw.load<T>`/`raw.store<T>` only lower for SCALAR T on the C backend** — an aggregate T → `UnsupportedCEmission` (`rawScalarSuffix` src/lower_c_type.zig:205, src/lower_c_call.zig:479). Meant `Vec<Token>` (struct element) wouldn't compile; the lexer had to flatten tokens into `Vec<usize>`. | `vec_push(Token,...)` struct → UnsupportedCEmission | **high** | **fixed (library)** `1855eab` — `Vec<T>` now uses `raw.ptr<T>`+whole-value deref (`p.* = x`/`out = p.*`), which lowers for scalar AND struct T on both backends. Underlying `raw.load/store` scalar-only limit remains (candidate compiler fix, low priority now). |
| G20 | P1 | language | **`let` is function-scoped, not block-scoped** — the same name in two sibling blocks → `E_DUPLICATE_LOCAL: local bindings must have unique names in the current scope`. In Zig each block re-declares freely. Forces name-mangling across loops (`c`/`cf`/`ce`). | two `while` blocks each `let c` | medium | ~~workaround~~ **FIXED (real compiler, §4)** — `let`/`var` are block-scoped (liveness stack); sibling blocks may reuse a name. (mcc2's own sema gained the same via the arch Phase 4 scope stack.) |
| G21 | P1 | language | **enum→int needs `open enum` + `.raw()`** — a plain (closed) enum rejects both `x as u32` (`E_ENUM_RAW_REQUIRES_OPEN_ENUM`) and `.raw()`. To read ordinals (e.g. token kinds for a driver), the enum must be `open enum TokKind: u32` and use `.raw()`. (Corrects a stale note that `kind as usize` works.) | closed `enum` `.raw()`/`as` → error | low | ~~workaround~~ **FIXED (real compiler, via the G25 fix)** — a closed enum now supports `.raw()`/`as`; `open enum` no longer required just to read ordinals. |
| — | P1 | correction | NOT gaps: `std/ascii.mc` DOES export `is_digit`/`is_alpha`/`is_whitespace`/… (usable directly); char literals `'f'`/`'\n'`/`'\''` work as `u8` incl. in `[N]u8` initializers. | — | — | n/a |

| G22 | P2 | language/modules | **Flat cross-import top-level namespace** — `import` pulls ALL top-level fn names (incl. non-`export`) into one shared flat namespace; no module qualification at use sites, no overloading. `parser.mc`'s private `fn advance(p:*mut Parser)` collided with `lexer.mc`'s private `fn advance(lx:*mut Lexer)` → `E_DUPLICATE_DECLARATION`. Real scaling hazard: lexer+parser+sema+lowering all want `advance`/`peek`/`expect`/`make`. | two imported files each `fn advance(...)` | **medium-high** | ~~workaround~~ **FIXED (real compiler, §4)** — file-private names no longer collide across imports (new `src/mangle_private.zig` renames non-`export` names `name__mcpN`). (Use-site module qualification is a separate, still-open production nicety — see the arch verdict.) |
| G23 | P2 | codegen | **C backend can't emit `return <call> == <call>`** — `sequencedConditionOperandTypes` (`lower_c_flow.zig:391`) can't recover the operand type when BOTH comparison operands are call exprs → `UnsupportedCEmission`. | `fn at(p,k)->bool{ return cur(p)==k.raw(); }` | medium | **FIXED (2026-07-02, `ba25302d`).** `<call> == <call>` and both OPEN- and CLOSED-enum `.raw()` in value contexts (typed `let bool =` and `return`) now emit. Root cause of the closed-enum residual: `callReturnTypeForCall`/`callSourceTypeForEmission` had no case for an enum `.raw()` method call, so operand-type recovery returned null → `UnsupportedCEmission`. New `enumRawReturnTypeForCall` recovers `.raw()`'s repr integer type; both backends, gate `enum-raw-cmp-run-test` (covers closed enums) in m0. |

| G24 | P3 | language | **Reserved keywords steal common local names** — `ok`, `err`, `type`, `use`, `open`, `sat`, `wrap` are keywords (the lexer emits `kw_ok`/`kw_err` for Result sugar etc.), so `let ok: bool = ...` → `expected local name`. A compiler port's own vocabulary overlaps MC keywords. | `let ok: u32 = 1;` → parse error | low-medium | ~~workaround~~ **FIXED (real compiler, §4)** — reserved words usable as contextual-keyword identifiers (`ok`/`err`/`type`/`use`/…) where a name is expected. |
| G25 | P3 | language | **`.raw()` and switch-exhaustiveness are mutually exclusive for enums.** An `open enum` supports `.raw()` (needed for ordinal access / driver assertions, G21) but its `switch` REQUIRES a `_ =>` default → the compiler gives ZERO missing-case diagnostics. A closed enum gives exhaustiveness but rejects `.raw()`/`as`. A compiler AST enum wants BOTH. | `switch openEnumVal {...}` forces `_` | **medium** | ~~open~~ **FIXED (real compiler, §4)** — a closed enum now supports `.raw()` (+`as`), so exhaustiveness and ordinal access are no longer mutually exclusive. |
| G26 | P3 | toolchain | **Unused `let` is a hard error** (`-Werror=unused-variable` in emitted C) — every bound local must be consumed; side-effect-only walks must discard a struct-returning call directly rather than binding it. | bind-and-ignore a local | low | workaround (discard directly) |

**G23 WIDENED (P3):** the `<call> == x` codegen gap (`UnsupportedCEmission`, `sequencedConditionOperandTypes`)
also fires in a **typed `let`-initializer** (`let b: bool = k.raw() == 2;`), not just `return`. It does
NOT fire inside an `if` condition — so it's specific to value-producing contexts (return / typed let-init).
Workaround unchanged: bind the call operand to a typed local first.

**P4 (emit-C) — G12 emission SOLVED via `sb_put_cstr`.** `export fn sb_put_cstr(sb, s: *const u8)`
(appends a NUL-terminated literal) makes fixed C-fragment emission ergonomic — string literals ARE
`*const u8`, so `sb_put_cstr(&sb, "uint32_t")` compiles directly. New confirmed fact: a raw `*const u8`
casts to `usize` with `as usize`. Recommend `sb_put_cstr` as the canonical "emit fixed text" primitive.
Big string-building is still ~2–3× the Zig emitter (no `writer.print`/format interpolation — one call per
fragment). **G25 is AVOIDABLE**: the emitter used `if/else` chains on `nd.kind == .variant` (works on
imported `open enum`) + a contiguous-ordinal range check for the 13 bin-ops, sidestepping the
exhaustiveness/`.raw()` tension entirely.

**⚠️ SUPERSEDED SNAPSHOT (P5.0-era; kept for history). ALL of this list was subsequently implemented** —
`mcc2` reaches the subset bootstrap fixpoint (gate `selfhost-bootstrap-test`); its parser handles keyword scalar types, `var`, structs/
enums/generics/slices/`switch`/`unsafe`/`raw`/imports, etc. Read the paragraph below as a P5-start to-do, not
current state.

**P5 self-compile gap list (what the subset compiler CANNOT yet handle — the remaining front-end work):**
`bool`/`void` as parseable type annotations (they're keywords; `parse_type` takes only identifiers);
untyped `let x = e` (needs type inference; currently emits `void x`); slices (`[]const T` emitted as `T*`,
length dropped); and NOT in the P2 grammar at all: `struct`/`enum`/`union`/global/const decls, `for`,
`match`/`switch`, `defer`, `&`/`*` address-deref, bitwise `<< >> & | ^`, `as` casts, string/char/float
literal expressions, method/UFCS calls, generics, multi-module imports/mangling. mcc2's OWN source uses
nearly all of these — true self-compile requires widening the front end across all of them (large, multi-phase).

| G27 | P5.1 | language | **`.raw()` works on an enum-typed PARAMETER but not on a variant-path literal** — `TokKind.l_brace.raw()` → `E_UNKNOWN_IDENTIFIER`. To get the ordinal of a known variant you must pass it as a param and call `.raw()` there (a typed-param indirection). | `SomeEnum.variant.raw()` | low-medium | ~~workaround~~ **FIXED (real compiler, §4)** — `.raw()` works on a variant-path literal (`SomeEnum.variant.raw()`). |

**G23 broadened again (P5.1):** also fires for `let b: bool = x.kind == .variant` and `let b: bool = call.raw() == N`
(any typed-`let bool` whose rhs is a comparison with a call/field-`.raw()` operand). Fine as an `if` condition;
`UnsupportedCEmission` as a `let bool =`. Recurring, easy-to-hit trap — bind the operand to a `u32` local first.

| G28 | P5.2 | selfhost-design | **`enum_lit` AST node carries only the variant token, not its enum** — sema resolved via threaded expected-type, but the emitter (no type table) resolved an enum literal by scanning all module enum decls for a matching variant (first match wins). Silently mis-emitted if two enums share a variant name. | `.variant` emit | ~~medium~~ **FIXED (arch Phase 2 + follow-up)** | Sema publishes the resolved `enum_decl` as a per-node fact (`sema_fact_decl`); emit reads it for `.variant` value positions (`return` / typed `let`/`var` / call args / `ok`·`err` payloads / struct fields / `assign`) AND for `switch`-arm case labels (a fact on the switch node = the subject's enum, consumed by `e_case_label`). No first-match scan on any resolved path. **This corrected a latent bug in mcc2 itself: `sm_type_of_expr_inner`'s `switch nd.kind` (a NodeKind) had been emitting `case TokKind_char_literal`/`TokKind_string_literal` (TokKind is scanned first and shares those variant names) — now `NodeKind_*`.** Fallback scan remains only when no fact (the self-parsing `emit_c_run` path). |

**Pre-existing emitter bug found+fixed by P5.2:** `if (<fully-parenthesized binop>)` emitted `if ((n == 1))`
→ clang `-Wparentheses-equality -Werror` rejects. The enum gate was the first selfhost test with a comparison
in a control-flow condition. Fixed via `e_cond` (skip redundant parens when the condition is already a binop).
This is exactly the class of latent codegen bug the stress test exists to surface.

| G29 | P5.4 | stdlib/portability | **`std/hosted_io.mc` hardcodes Linux `AT_FDCWD = -100`** — on macOS it's `-2`, so `openat` with relative paths fails on a macOS host (absolute paths ignore dirfd and work). Linux/Docker CI unaffected. | relative `io_open` on macOS | low | note (make AT_FDCWD target-conditional) |

**P5.4 forward-prototype pass:** the subset emitter now emits C fn prototypes before definitions
(`e_fn_sig`), so flattened/concatenated modules are order-independent and support cross-module mutual
recursion — needed once imports put a caller textually before its callee.

**⚠️ SUPERSEDED SNAPSHOT (this paragraph is a P5.4-era status, kept for history).** As of 2026-07-02
**the SUBSET bootstrap proof is closed**: all five `mcc2` modules + std deps compile through `mcc2` to a byte-identical fixpoint
(gate `selfhost-bootstrap-test`). Every "recommended order" item below was subsequently done (generics
over structs, `impl`/traits, `unsafe`/`raw`, value-optionals; `match`/`?` — some turned out already-present).
See §1 "SUBSET BOOTSTRAP FIXPOINT ACHIEVED" and §4.

**HONEST self-compile status (after P5.4):** the subset can compile **~0%** of `mcc2`'s OWN source. Import
plumbing was necessary but not the bottleneck — mcc2's modules pervasively use features the subset still
lacks: **generics** (`Vec<T>` ~30 uses), **fixed byte arrays + `mem.as_bytes`** (~77 uses), **`impl`/traits**
(Allocator), **`unsafe`/`raw.*`**, **`match`**, **`?` propagation**, string-literal exprs. Recommended order
to true self-compile: **generics** (monomorphized `Vec<T>` + fixed arrays + array-slices) → `impl`/traits →
`unsafe`/`raw` intrinsics → `match`/`?`. Each is a large vertical; true self-compile remains multi-phase.

| G30 | P5.5 | language | **`*mut Vec<T>` param → `*const Vec<T>` param rejected** (`E_NO_IMPLICIT_POINTER_CONVERSION`) even though mut→const is a safe narrowing; but `&local`/`&field` address-of expressions DO coerce. Passing a `*mut` pointer *variable* to a `*const`-expecting fn (e.g. `vec_len(u32, v)` where `v: *mut Vec<u32>`) fails — must reborrow `&*v`. | `fn c(v:*mut Vec<u32>)->usize{return vec_len(u32,v);}` fails; `vec_len(u32,&*v)` works | medium | ~~workaround~~ **FIXED (real compiler, §4)** — `*mut → *const` pointer coercion at call sites; no `&*v` reborrow needed. |

**P5.5 monomorphizer lesson (for the ledger / any arena-scanning monomorphizer):** a monomorphizer that
collects instantiations by scanning the flat arena for `S<...>` uses will also find the TEMPLATE's own
signature use `S<T>` (arg = abstract `T`) → collecting it produces `S_T` whose `T→T` substitution recurses
forever (stack overflow). Fix: collect ONLY when the type arg is a known concrete scalar lexeme. That filter
IS the scope boundary (why nested/struct type-args are deferred). Substitution was done via threaded scratch
fields on the Parser (set/clear around each monomorphic emit) rather than an arena clone — pragmatic given
no `?T`/node-maps.

**P5.6 array findings:** MC array-literal is `.{ e0, e1, ... }` — the SAME leading-dot-brace as a struct
literal `.{ .f = e }` but positional; disambiguated by 3-token lookahead (`.` IDENT `=` ⇒ struct). The
subset has **no `as` cast expression** yet (deferred). Widening a flat `SmType` with fields forces updating
every full struct-literal site (MC requires all fields present) — O(literal-sites) churn. Field access through
an ABSTRACT type param isn't type-checkable (element type is `named_ T`); works only inside generic-fn bodies
(sema-skipped) whose return substitutes to concrete — same pattern as P5.5.

**P5.7 slices — the accumulating structural cost:** the emitter has NO shared typed IR (parser/sema/emit
are 3 separate passes over the flat arena), so to lower `s[i]`/`s[a..b]`/`.len` correctly the emitter had to
build its own mini local-type resolver (~150 of 349 LOC: a `cur_fn` scratch field + a recursive scan of
params/`let`/`var` to recover a base identifier's declared type). This re-derivation recurs for EVERY
type-directed lowering and is the compounding tax of not having sema annotate the arena. Slice C repr matches
the real backend (`mc_slice_const_<T>{ const T* ptr; size_t len; }`). Also: added a `&` address-of node
(`un_addr`) for `mem.as_bytes(&arr)`; still no `as` casts (cross-width arithmetic must be avoided).

| G31 | P5.10 | codegen | **Pointer field access `p.field` (p: `*mut T`) must emit C `->`, not `.`** — the subset emitter emitted `.` because prior fixtures never did pointer-field access in the accept set. Latent wrong-C bug; fixed with `e_base_is_ptr` (dyn fat pointers stay `.`). | `fn f(p:*mut S)->u32{return p.x;}` → `p.x` (wrong) | medium | fixed (selfhost) |
| G32 | P5.10 | selfhost-sema | **Mutation through a `*mut` pointer receiver is flagged immutable** — `self.total = x` where `self: *mut Acc` → the subset's `sm_target_mutable` only allows `var` locals, so it errors `assign_immutable`. Worked around by NOT sema-checking impl/method bodies → blocks real conformance checking. | `fn m(self:*mut S)->void{self.x=1;}` | ~~medium~~ **FIXED (arch Phase 5)** | `sm_target_mutable` already allows a write through a pointer-typed root (`ptr_depth>0`); once `sm_check_impls` (arch plan Phase 5, `§2`) began checking impl method bodies, `self.x = v` type-checks. No workaround left. |

**ARCH-HARDENING refactor (2026-07-02, `§2`, commits `bd98665b`→`0e48e728`):** mcc2
moved from a 3-pass AST re-walker (parse-twice, emit re-infers types, fn-wide locals, generic/impl
bodies unchecked) to a typed pipeline — parse once (Phase 0, ~1.4×) → sema builds a node-indexed
`Vec<Fact>` typed table (Phase 1) + a lexical scope stack (Phase 4) → emit consumes typed facts for
enum resolution (Phase 2) and slice/ptr/dyn base classification (Phase 3) → impl (Phase 5) and generic
(Phase 6) bodies are now type-checked. Every phase byte-identical + m0-green both backends. This turns
G28-value/G34/G35 into structural guarantees and closes G32. Two latent builtins surfaced by first-time
generic-body checking (`forget_unchecked`, `mem.bytes_equal`) were taught to sema. Follow-up review passes
then fully closed G28 (switch-arm case labels + assign now resolve via facts — see the G28 row) and G33
(all decl kinds + cross-namespace + traits). Regular helper calls inside generic bodies are now covered by
`selfhost-generic-test`; Phase 6's catch is still intentionally limited to undefined idents/arity, not
full concrete per-instantiation type checking.
| G33 | post-P5 | selfhost-sema | **Duplicate top-level declaration accepted** — `sm_collect` overwrote the symbol-table entry, so a repeated top-level name type-checked (exit 0) and the emitter output duplicate C definitions. Found across four review passes (fn-only → same-kind struct/const/global/enum → cross-namespace → traits). | `fn f`×2 / `struct S`+`fn S` / `const X`+`fn X` / `enum Y`+`struct Y` / `trait T`×2 / `trait T`+`fn T` → dup C; `trait T { fn m; fn m; }` → dup vtable field | ~~medium~~ **FIXED (all kinds + cross-namespace + traits)** | every top-level registration in collect calls `sm_toplevel_taken(name)`, which checks ALL FIVE tables (`fns`/`structs`/`enums`/`traits`/`globals`); trait names now register in `s.traits`; a clash in either declaration order emits `duplicate_decl` (SmErr 17). Method names are also deduped WITHIN each trait. MC has one flat top-level namespace (G22), so this matches the language. |
| G34 | post-P5 | selfhost-sema | **`if let` binding leaked past its block** — the payload binding was added to the fn-wide locals table and never removed, so a use *after* the `if`/`else` type-checked (exit 0) and emitted C referencing a variable out of its C block scope (invalid C). Found by review. Same for `if let ok(v)/err(e)`. | `if let y=o {} return y;` | ~~high~~ **FIXED** | Originally: a new `strmap_del` dropped the binding at the then-block's end. SUPERSEDED by arch Phase 4 — sema now uses a lexical SCOPE STACK (`sm_scope_mark`/`sm_scope_pop` around the then-block, `selfhost/sema.mc`), so the `if let` binding (and any block-local `let`) is out of scope after the block. `strmap_del` is no longer used by sema. |
| G35 | post-P5 | selfhost-sema | **`ok(x)`/`err(x)` payload type unchecked** — the ctor yielded a LOOSE `result_` that unified with any target `Result<T,E>` without comparing the payload, so `return ok(true)` into `-> Result<u32,u32>` type-checked (exit 0). Found by review. | `ok(true)` into `Result<u32,u32>` | ~~medium~~ **FIXED** | `sm_check_result_ctor` checks a non-literal `ok`/`err` arg against the target's OK/ERR payload at `return` and typed `let`/`var` sites |

**P5.10 traits:** representation matches the real backend — rodata `static const NAME__vtable`, fat pointer
`{void* data; const NAME__vtable* vtbl}`, `void*`-self thunks (`(TYPE*)self`, avoids `-Wincompatible-pointer-types`),
dispatch `d.vtbl->m(d.data, ...)`. Coercion `*mut T`→`*mut dyn Trait` at CALL ARGS only (returns/assigns deferred).
`Self` is a non-problem (erased to `void*` in the vtable; concrete in impl methods).

**⚠️ SUPERSEDED SNAPSHOT (P5.10-era status, kept for history) — ALL RESOLVED as of 2026-07-02.** Every
"remaining blocker" below was subsequently closed: value optionals (P5.15), module-qualified calls + opaque
address classes (P5.14/5.19), the std API incl. `StrHashMap` over struct values (P5.19), G32 impl-body
mutation (P5.15); `match` was a non-gap. **The SUBSET bootstrap proof is closed** — `mcc2` compiles all of selfhost/*.mc + std deps
to a byte-identical fixpoint (gate `selfhost-bootstrap-test`). See §1 "SUBSET BOOTSTRAP FIXPOINT ACHIEVED".

**REMAINING blockers to LITERAL `mcc2`-compiles-`mcc2`** (after 11 verticals, ~70–75% coverage): `?T`
optionals (G11 — selfhost mostly avoids), `match` + payload binding, GENERAL module-qualified calls (`mod.fn`
— only `mem.as_bytes`/`raw.*` special-cased today; `pa()`/`pa_value`/etc. not), the OPAQUE `PAddr` address
class from `std/addr.mc`, and the full std API surface (StrHashMap over struct values, exact signatures). Plus
closing G32 for real impl-body checking. These are a mix of a few more features + a substantial end-to-end
INTEGRATION effort (feeding all of selfhost/*.mc + std deps through mcc2 and fixing the long tail).

**Structural observation (P5.1):** parser/sema/emit each re-implement length-prefixed "pair run" walking
(`[count,(a,b)*]`, `fi*2(+1)` indexing) with no shared arena-access module → off-by-one-prone duplication
across 3 files. A shared `selfhost/ast.mc` accessor layer would cut this; deferred (works, just repetitive).

**mcc2 CLI findings (2ac36e7):** G12 file-input ceiling is REAL — to feed the `[]const u8` pipeline you
must read into a compile-time-sized `global g_src:[1048576]u8` and `mem.as_bytes(&g_src)[0..nread]`; a
writable `PAddr` for `io_read` comes from `(&g_src) as usize` → `pa(...)` (the sanctioned addr↔usize
boundary). Files > the fixed buffer are rejected, not truncated. G22 also bit as re-declaring an imported
`extern "C"` (`mc_argv`) → `E_DUPLICATE_DECLARATION` (call the imported one). Canonical idioms confirmed:
**discard a must-handle `Result` via `if let err(e) = expr {}`** (no `let _ = expr;` statement discard,
G26-exempt); Result has no `is_ok`/`unwrap` — use `if let ok(v) = ...` or `?` propagation.

**P3 subset-grammar gaps to widen before P4/P5 (⚠️ SUPERSEDED — both since DONE):** the P2 parser's
`parse_type` accepted only `.identifier` (keyword-types `bool`/`void`/`u32`… didn't parse) and there was no
`var`. Both were subsequently added — the parser now accepts keyword scalar types (`selfhost/parser.mc`
`parse_type`) and `var` decls (`selfhost/parser.mc`), as required for real mcc2 source at P5.

**G20 refined (P2):** *nested* if/else branches CAN reuse a `let` name, but *sequential* sibling blocks
at the same fn level cannot (`E_DUPLICATE_LOCAL`). Safe rule: **every `let`/`var` unique per function.**
Also confirmed: **params are immutable** (`E_ASSIGN_TO_IMMUTABLE_LOCAL`) — mutate via a `*mut` field, not param rebind.

**P2 verbosity vs Zig original: ~1.3–1.4×** real code lines — driven by G20 unique-naming, explicit type
annotations, and the G23 two-line workaround; the parse *structure* is a faithful 1:1 port. Token-kind
comparisons (via the lexer's `open enum TokKind`+`.raw()`) were friction-free — the parser needs almost
no string compares, unlike the lexer.

**P1 keyword-matching friction quantified (G12 consequence):** the 47-keyword table took **~94 lines**
of `[N]u8` + `mem_eql(lex, mem.as_bytes(&kN))` boilerplate (2 lines/keyword) vs ~47 one-line rows in
Zig — ~2× — because string literals are `*const u8`, not `[]const u8`, so `str_eq(lex, "fn")` is
impossible without a slice-from-literal path. This is the strongest single argument for eventually
fixing G12.


---

## 4. Real-compiler language fixes


Fixing the real MC compiler (`src/*.zig`) gaps that self-hosting surfaced (see
[§3](#3-gap-ledger), G9–G32), so `mcc2` can be de-workaround-ed and the
rest of the subset bootstrap work done idiomatically. **User directive: fix ALL of them, incl. the
by-design/ergonomic ones.** Order: fix language → refactor selfhost → continue self-host work.

**Gating per fix (MC rules):** reproduce first (probe); fix in sema + **both** backends (C +
LLVM); add a spec/`c_emit` test + parity; full `m0` green both backends; front-end changes get
`llvm-trap-test` (kernel-emit validation), not just tests. Worktree agent → host-verify →
cherry-pick → m0.

**Current status (2026-07-02): COMPLETE.** The batching tables below are the original execution map,
updated to current state: every actionable real-compiler gap in this section is fixed and m0-gated
except G29, which is intentionally Linux-hosted by design.

### Batching (by disjoint files, to parallelize safely)

#### Batch 1 — correctness bugs, file-disjoint (DONE)
| Gap | What | Primary files | Status |
|-----|------|---------------|--------|
| G23 | `<call>==x` fails in `return`/`let bool=` (works in `if`) → `UnsupportedCEmission` | `src/lower_c_flow.zig` (+llvm equiv) | **fixed + m0-gated** |
| G19 | `raw.load/store<T>` of aggregate T → `UnsupportedCEmission` (scalar-only) | `src/lower_c_type.zig`, `lower_c_call.zig` (+llvm) | **fixed + m0-gated** |
| G24 | reserved words (`ok/err/type/use/open/sat/wrap`) can't be locals → contextual keywords | `src/lexer.zig`, `src/parser.zig` | **fixed + m0-gated** |

#### Batch 2 — the two big features (DONE)
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G12 | slices: string-literal→`[]const u8` lowering; `[]mut`→`[]const`; **the `x as []const u8` soundness hole** closed | `sema_type.zig`, `lower_c_emitter.zig`, `lower_llvm*.zig` | **fixed + m0-gated** |
| G11 | value optionals `?V` (tagged `{present,value}` repr; `if let`/`==null`/`.?`; `switch` deferred) | `sema_type.zig`, `lower_c_*`, `lower_llvm*` | **fixed + m0-gated** |

#### Batch 3 — ergonomic / design (DONE)
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G20 | block-scoped `let` | `sema.zig` scopes | **fixed + m0-gated** |
| G22 | file-private imported names no longer collide; call-site module qualification/overloading remains out of scope | `loader.zig`, `sema.zig`, `mangle_private.zig` | **fixed + m0-gated** |
| G25 | `.raw()` on closed enums, preserving closed-enum exhaustiveness | `sema.zig`, `sema_type.zig` | **fixed + m0-gated** |
| G18 | generic tagged unions (`union Opt<T>`) | `parser.zig`, `sema.zig`, `monomorphize.zig` | **fixed + m0-gated** |
| G16 | `Self` in non-receiver trait param/return positions, unlocking Hash/Eq-style bounds | `sema.zig`, `monomorphize.zig` | **fixed + m0-gated** |

#### Batch 4 — narrower (DONE)
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G14 | escape analysis over-rejects `return &heapptr.field` | `sema_move.zig`/escape | **fixed + m0-gated** |
| G27 | `.raw()` on a variant-path literal (`Enum.variant.raw()`) | `sema.zig` | **fixed + m0-gated** |
| G30 | `*mut T`→`*const T` param coercion | `sema_type.zig` | **fixed + m0-gated** |
| G29 | `hosted_io` `AT_FDCWD` Linux-hardcoded (macOS relative imports) | `std/hosted_io.mc` | **by design** — hosted target is Linux libc; use absolute paths on macOS or run Docker/Linux |

### Selfhost refactor (2026-07-01) — flagship de-workarounds DONE + m0-green
- **R1** (`5bed952`) — byte-array keyword/scalar tables → string-literal `mem_eql(s,"fn")` across
  selfhost lexer/sema/emit/parser/main (**−98 LOC**); block-scoped-let cleanup (dropped `cf`/`ce`
  dodges). Proves G12 in real code.
- **R-std** (`b99c5aed`, −11 LOC) — `mem_index_of → ?usize`, dropped `MemFound` + the hashmap `+1`
  sentinel. Proves G11 in real code. Later G11 follow-up covers `?[]const u8` and `.?` unwrap;
  optional `switch` remains deferred.
- **De-prefix (G22) + closed-enum-switches (G25): SKIPPED as low-value/high-churn** — the `lex_/p_/sm_/e_`
  prefixes aren't ugly workarounds (G22 already proven by g22-priv-name-test), and the if/else-on-kind
  form works fine; converting to closed enums is churn with regression risk. Available as future polish.

### Continue self-host (integration long-tail → literal mcc2-compiles-mcc2)
**SUPERSEDED by later §1 execution:** P5.12+ and the dependency long-tail were completed for the subset.
The current capstone is `selfhost-bootstrap-test`: all `selfhost/*.mc` plus std deps are compiled by
`mcc2` into a byte-identical second-generation `mcc2′`. Full replacement of `src/` remains the separate
full-self-hosting guide in §6.

### Execution log
- **2026-07-01 — Batch 1 landed** (G19 `6ef4534`, G23 `a3f5305`, G24 `5dbef9e`; fixture fix included).
  - **G19** — aggregate `raw.load/store<T>` now lower (whole-object typed load/store) on C + LLVM; scalar/MMIO path untouched. `diff-backend`/`c-test` green.
  - **G23** — sequenced-comparison operand-type recovery in value contexts (`return`/`let bool=`) for call/`.raw()`/member operands (C backend; LLVM was already correct — types via sema, not AST heuristics). New `enum_raw_compare` fixture.
  - **G24** — `ok`/`err`/`type`/`use`/`open`/`sat`/`wrap` now usable as locals/params/fields (contextual keywords in the parser; lexer table unchanged so keyword semantics preserved). Caveat: `ok(..)`/`err(..)` calls still resolve to the Result ctor by lexeme.
  - Fixture bug caught by full `m0`: the G24 fixture returned 143 but host-suite entry contract needs `return 1` (both backends compute 143 identically — no compiler bug); fixed.
- **2026-07-01 — Batch 2 landed + m0-green (both backends).**
  - **G12 (slices)** (`910ec9f`) — soundness hole closed (`E_ILLEGAL_SLICE_CAST` rejects scalar→slice), string-literal→`[]const u8` lowering, `[]mut`→`[]const` coercion; C + LLVM, `diff-backend` 161. Slice-from-raw-parts deferred (unsafe length-fabricating primitive, own design). m0 real_failures=0.
  - **G11 (value optionals `?T`)** (`3cc7416`, 21 files) — `?u32`/`?usize`/`?struct`/`?[]const u8` via a tagged `{present,value}` aggregate (C `mc_opt_<T>`, LLVM `{i1,T}`); pointer optionals keep the null sentinel unchanged. `if let`/`==null`/`.?`(traps on absent)/struct-field/by-value all work; `switch`-on-optional deferred. `diff-backend` 162, entry fixture returns 1 both backends, m0 real_failures=0.
- **2026-07-01 — Batch 3 landed + m0-green.**
  - **G18 (generic unions)** (`a97f4e9`) — `union Opt<T>` monomorphizes like generic structs; since monomorphize runs before sema/backends, rewriting `Opt<u32>`→`Opt__u32` needed ZERO sema/backend changes. diff-backend 163.
  - **G20 (block-scoped `let`)** (`4ccf7f4`) — liveness stack (marker/pop) with keep-all type map so the post-body exhaustiveness pass still resolves types; sibling blocks reuse names, live-shadow still rejected; backend clones locals per block. diff-backend 164, 0 skipped. (A first attempt using copy-scope-per-block regressed 28 fixtures and was discarded.)
- **2026-07-01 — Batch 3/4 landed + m0-green (real_failures=0).**
  - **G25+G27 (enum `.raw()`)** (`275226f`) — `.raw()`/enum→int allowed on CLOSED enums (read-only is safe) so a closed enum gets BOTH exhaustiveness AND ordinal access; variant-path `Enum.v.raw()` works; int→enum still requires `open`. diff-backend 165.
  - **G30 (`*mut`→`*const` param coercion)** (`46332b4`, completed from a stalled agent's verified WIP) — safe const-narrow at call/assign/return (incl. bare `*T`); const→mut + element-mismatch stay rejected; mirrors G12 slice coercion in sema + MIR verifier.
  - **G14 (escape over-rejection)** (`603be36`) — `&base.field`/`&base[i]` through a POINTER base is no longer flagged as a local-address escape (real gap: local-pointer-copy + array-through-pointer); `return &local` still rejected (25/25 markers).
  - **sweep allowlist** — `pointer_view_conversions.mc` added to the 4 sweeps' OUT_OF_SCOPE (mixed accept/reject sema fixture the chunk-strip can't isolate after G12/G30 turned rejects into accepts; accept-emit covered by c_emit fixtures, rejects by check/spec_tests). This resolved the one m0 hiccup (4 sweeps).
- **2026-07-01 — G22 (file-private namespace) landed + m0-green** (`1f8a7417`). New pre-sema pass
  `src/mangle_private.zig`: a name defined only by renameable file-private value-decls (non-exported `fn`
  with body / plain `global`) in ≥2 files is scope-aware-renamed to `name__mcpN` per origin file → two
  private `advance`s become distinct symbols; `pub`/`export`/`extern` keep their exact ABI name. Two `pub`
  same-name, same-file private dups, and private-vs-pub collisions still `E_DUPLICATE_DECLARATION`.
  diff-backend 168, 0 skipped. Completes §30 (no call-site qualification / no overloading, per intent).
- **G16 (Hash/Eq bounds) — NARROWED to a real small gap, then fixed.** Probing showed `where K: Trait`
  bounds + UFCS `K.method(x)` calls ALREADY work (traits_tier1); a self-only bounded method works. The ONLY
  gap: `Self` in a NON-receiver param/return position (`eq(self: *Self, other: *Self)`) → `E_TRAIT_SIGNATURE_MISMATCH`
  in conformance checking. Fix substitutes `Self` in all positions → unlocks fully-generic `HashMap<K,V>` via
  `where K: Keyed`+UFCS. (So "no Hash/Eq bounds" was overstated — bounds work; only Self-in-param was broken.)
- **G29 (AT_FDCWD) — BY DESIGN / documented, not fixed.** `std/hosted_io.mc` explicitly targets Linux libc
  (`AT_FDCWD=-100` is correct for the actual hosted/CI/Docker target); the macOS-host relative-`openat`
  failure is local-dev-only and a portable fix needs comptime OS detection MC lacks. Workaround: absolute
  paths or run in Docker. Recorded as by-design.

- **2026-07-01 — G16 (Self-in-param trait signature) landed** (`d8909ed`). `sameTraitTypeSyntax` substitutes
  `Self` (bare/`*`/`*mut`/`*const`/`[]`/`?`/nested) in ALL param + return positions during conformance;
  genuine mismatches still reject. Unlocks fully-generic `HashMap<K,V>` via `where K: Keyed` + UFCS
  (demo runs both backends). diff-backend 169; m0 green.

### GAP-FIX PROGRAM COMPLETE
**13 real gaps fixed on both backends, each m0-green:** G11 (value optionals), G12 (slices + soundness hole),
G14 (escape), G18 (generic unions), G19 (aggregate raw.*), G20 (block-scoped let), G22 (file-private names),
G23 (call-compare codegen), G24 (reserved-word idents), G25 (closed-enum .raw() + exhaustiveness), G27
(variant-path .raw()), G30 (*mut→*const coercion), G16 (Self-in-param). Plus 2 real codegen bugs found+fixed
(double-paren `if`, and G19). G29 = by-design (Linux hosted target). The follow-on selfhost cleanup and
subset bootstrap are also complete; see §1 and §2 for the capstone evidence.

**NON-GAPS discovered (overstated in the ledger, no fix needed):** `match` (selfhost uses 0 real `match` —
`grep` counted prose); `?T`-not-needed-for-selfhost (0 uses); broad "no Hash/Eq bounds" (bounds work via
`where`+UFCS; only Self-in-param was the real gap = G16).
_(append per landed fix: gap, commit, what changed, backends, m0)_


---

## 5. Performance


Scale/perf measurements from the subset bootstrap/stress-test effort ([§1](#1-plan-and-execution)).
This is the "or slow" output of the stress test. Every entry is a first-principle measurement
(cycle CSR / wall clock), per MC rules.

**What to measure as the subset grows:**

| Metric | Why it matters | How |
|--------|----------------|-----|
| `mcc2` compile speed vs Zig `mcc` | is MC-generated code competitive on a real workload? | wall time on the same input |
| Monomorphization blowup | per-import monomorph could explode at compiler scale | count distinct instantiations; generated-C size |
| Generated-C size (`mcc2` output) | codegen density | `wc -c` emitted C |
| clang time on `mcc2`'s emitted C | end-to-end toolchain cost | wall time |
| `Vec<T>` grow / `HashMap` insert throughput | container primitives are hot everywhere | cycle-count bench (Phase 0) |
| Peak memory (arena high-water) | allocate-and-never-free at scale | instrument arena |

### Measurements

**2026-07-01 — `mcc2` CLI throughput on subset source (mcc2-cli-test, commit `2ac36e7`).**
Workload: 1000 generated subset functions (`fn f_N(a,b:u32)->u32 { let/let/return }`), 98,780 bytes.

| Metric | Value |
|--------|-------|
| Input | 98,780 bytes, 1000 functions |
| `mcc2` wall (lex→parse→sema→emit→stdout) | **~0.048 s** |
| Throughput | **~20,800 functions/sec ≈ 2.0 MB source/sec** |
| Emitted C | 117,821 bytes |
| `clang -O0` wall on the emitted C | ~0.073 s |

**Verdict: `mcc2` is fast.** Its entire front-end+emit pipeline (48 ms) costs *less* than clang's
`-O0` compile of the C it produces (73 ms). No allocator/scaling pathology at 1000 fns (linear).
**Known ~2× headroom:** the CLI runs `sema_check` (which lexes+parses) and then `emit_c_run`
(which lexes+parses again) — feeding emit from the already-parsed arena would roughly halve mcc2's
wall. Not yet done (correctness first). Fixed input ceiling: 1 MiB (`global g_src:[1048576]u8`;
can't build `[]const u8` from a malloc'd ptr+len — gap G12).

_(append: phase, metric, workload, baseline, result, delta, commit)_

---

## 6. Full self-host implementation guide

This section is the project guide for **true self-hosting**: replacing the Zig compiler in `src/`
with an MC-written compiler for the normal toolchain path. Sections §1–§5 are historical evidence:
`mcc2` can host a serious compiler subset and the stress test hardened the real compiler. §6 is the
remaining implementation contract.

Until every acceptance criterion below passes, MC **does not self-host in the full sense**. A C-only
bootstrap, a subset fixpoint, or an MC compiler that still depends on Zig for sema/backends is useful
progress, but it must be named as a lesser milestone.

### 6.1 Definition of done

True self-hosting is achieved only when all of these are true:

| Area | Required end state | Required proof |
|---|---|---|
| Source of record | The production compiler implementation is written in MC, not Zig. Zig `src/*.zig` may remain as a seed/oracle/fallback during transition, but not as the production compiler. | The default compiler entry point used by local tests and CI is the MC implementation. |
| Language coverage | The MC compiler accepts the whole MC language used by `std/`, `kernel/`, `examples/`, `demo/`, `user/`, and the test corpus, not just the `selfhost/` subset. | Parser, sema, lowering, and backend sweeps pass with the MC compiler under test. |
| Checker coverage | The MC compiler implements the full checker: type resolution, const-eval, definite-init, move/borrow rules, effects, traits/bounds/coherence, hardening types, exhaustiveness, layout, and all current diagnostics. | Differential check gates match the Zig compiler on success/failure and diagnostic codes for `tests/spec/` plus widened negative fixtures. |
| Backend coverage | Both production backends are implemented in MC: C and LLVM. | `diff-backend`, LLVM object/sweep/debug/opt gates, and C backend gates pass under the MC compiler. |
| Driver/toolchain | `mcc-cc`, `mcc-llvm-cc`, profiles, imports, package/registry flows, source maps, diagnostics, and reproducible-build behavior work through the MC compiler. | Toolchain gates pass with the MC compiler selected. |
| Whole corpus | The MC compiler builds the full hosted and kernel corpus, including QEMU tests. | `zig build m0` and `tools/m0-parallel.sh <jobs>` report `real_failures=0` with the MC compiler under test. |
| Bootstrap fixpoint | The compiler can build itself twice and reach a stable artifact. | Stage0 -> Stage1 -> Stage2 bootstrap succeeds; Stage1 and Stage2 outputs are byte-identical or match an explicitly-normalized stable-output contract. |

**Non-negotiable naming rule:** do not write "self-hosting achieved" until the full definition of done
passes. Before then, use precise names: "subset bootstrap", "C-only bootstrap", "parser parity",
"sema parity", "backend parity", or "stage1/stage2 bootstrap".

### 6.2 Bootstrap model

Use explicit stage names in scripts and logs:

| Stage | Builder | Output | Purpose |
|---|---|---|---|
| Stage0 | Current Zig compiler (`src/*.zig`) | First MC compiler binary | Seed the transition and provide an oracle. |
| Stage1 | Stage0 MC compiler | Rebuilt MC compiler binary | Prove the MC compiler can compile its own source. |
| Stage2 | Stage1 MC compiler | Rebuilt MC compiler binary | Prove the self-built compiler is stable. |
| Cutover | Stage2 MC compiler | Default `mcc` toolchain | Replace the Zig compiler in normal workflows. |

The Zig compiler remains valid as a seed and comparison oracle until cutover. After cutover, it should
be kept temporarily as an explicitly named fallback such as `mcc-zig`, while the MC compiler owns the
default `mcc` path. Retire or archive the Zig implementation only after a fallback period with clean
full-corpus runs.

### 6.3 Existing assets to reuse

Do not restart from scratch. Build on these assets:

| Asset | Current role | How to use it for full self-host |
|---|---|---|
| `src/*.zig` | Production compiler and truth source for behavior. | Use as the executable oracle until each subsystem has MC parity. Port behavior in vertical slices, not by hand-waving around drift. |
| `selfhost/*.mc` | `mcc2` subset compiler with lexer/parser/sema/C emit/main and byte-identical fixpoint gate. | Reuse architecture lessons and useful code, but do not treat it as production-complete. Promote only pieces that survive the full parity gates. |
| `tools/toolchain/selfhost-*-test.sh` | Subset bootstrap and feature gates. | Keep them as fast inner-loop gates; add new full-selfhost gates beside them instead of weakening their contracts. |
| `tools/toolchain/diff-backend.sh` and fuzz gates | C/LLVM agreement checks for the Zig compiler. | Re-run them with the MC compiler selected; add oracle comparison while both compilers exist. |
| LLVM sweep/object/debug/opt scripts | Current LLVM backend coverage. | Make these pass under the MC LLVM backend before claiming full replacement. |
| `tools/toolchain/mcc-cc.sh`, `mcc-llvm-cc.sh`, `mcc-pkg.sh`, `mcc-registry.sh` | Toolchain and packaging surface. | Audit each script so it can select the compiler under test via an explicit environment variable or argument. |
| `build/tiers.zig` and `tools/m0-parallel.sh` | Full conformance gate list and parallel local runner. | Treat `m0` as the final acceptance gate. The parallel runner is for fast local confidence; `zig build m0` remains the serial truth gate. |
| `std/`, `kernel/`, `examples/`, `demo/`, `user/`, `tests/` | Real language surface. | Expand the corpus in this order: hosted std subset -> full std -> examples/demo/user -> kernel/QEMU -> whole `m0`. |

### 6.4 Harness required before large porting

Build the harness first. Without it, the project becomes a large rewrite with no trustworthy proof.

1. **Compiler selector.** Every gate that invokes `zig-out/bin/mcc` must accept an explicit compiler
   path, for example `${MCC_UNDER_TEST:-zig-out/bin/mcc}`. Scripts may keep their current defaults, but
   the full-selfhost run must be able to swap in a Stage1 or Stage2 compiler without editing scripts.
2. **Oracle runner.** Add a differential runner such as `tools/toolchain/full-selfhost-diff.sh` that
   runs the Zig compiler and MC compiler over the same corpus, then compares status, diagnostic code,
   normalized diagnostics, emitted C, emitted LLVM IR, object behavior, and runtime output as appropriate.
3. **Diagnostic normalization.** Normalize absolute paths, temp dirs, line-ending differences, generated
   symbol suffixes, source-map paths, and backend tool noise before diffing. Do not normalize away error
   codes, source spans, safety checks, ABI-relevant symbols, layout, or runtime behavior.
4. **Stage script.** Add a bootstrap script such as `tools/toolchain/full-selfhost-stage.sh`:
   Stage0 builds the MC compiler, Stage1 rebuilds it, Stage2 rebuilds it again, then the script compares
   Stage1/Stage2 artifacts and runs a smoke corpus with Stage2.
5. **Corpus manifest.** Add a checked-in manifest for the self-host corpus rather than discovering files
   ad hoc. Track expected mode per file: parse-only, check-fail, emit-C, emit-LLVM, object, run, QEMU.
6. **Ledger.** Add a full-selfhost ledger section or companion file that records phase, corpus size,
   pass/fail counts, unsupported features, performance, and the commit that changed the result.

The first meaningful milestone is not "ported lots of code"; it is a harness that can say which exact
Zig behavior the MC compiler matches and where it still diverges.

### 6.5 Work phases

Each phase must land as vertical slices. A phase is done only when its new corpus slice passes with both
the Zig oracle and the MC implementation under the same harness. If a slice needs a temporary limitation,
record it as a named lesser milestone and keep the full-self-host status as NOT achieved.

| Phase | Scope | Done when | Main gates |
|---|---|---|---|
| P0. Contract and harness | Compiler selector, oracle runner, stage script, corpus manifest, normalization rules, ledger. | A tiny corpus can be run through Zig-vs-MC comparison and Stage0/Stage1/Stage2 scripts with meaningful pass/fail output. | New full-selfhost harness gates plus existing `selfhost-bootstrap-test`. |
| P1. Production architecture in MC | Promote the typed architecture needed for a full compiler: AST, typed facts/IR, scopes, module graph, diagnostics, allocator conventions, deterministic output. | The MC compiler can parse/check a small multi-file corpus using the same module/import model and diagnostic style as the Zig compiler. | Parser/sema oracle diff on initial corpus. |
| P2. Full parser parity | Implement the complete grammar: attrs, imports/privacy, structs/enums/unions/packed/overlay/opaque, generics, traits/impls, effects syntax, comptime syntax, async/await, inline asm, MMIO forms, extern/export, literals, patterns, and all current statements/expressions. | Every parse-valid file in the manifest builds the same AST-relevant facts, and every parse-invalid fixture reports the same diagnostic code/span class. | Parse oracle diff over `tests/spec/`, `std/`, and selected `kernel/` files. |
| P3. Full sema/checker parity | Type model, name resolution, module privacy, const-eval, layout, definite-init, moves/borrows, effects, traits/bounds/coherence, dyn trait rules, hardening types (`UserPtr`, `Cap`, `Rights`, `Secret`), exhaustiveness, escape checks, unsafe rules, and diagnostic parity. | The MC compiler accepts and rejects the same corpus as Zig with matching diagnostic codes, and no hardening pass is skipped or weakened. | Sema oracle diff, negative spec fixtures, hardening gates, move/fuzz gates. |
| P4. Monomorphization and generic lowering | Deterministic generic instantiation for nested/multi-param generics, generic structs/unions/enums, trait bounds, impl methods, UFCS, dyn interactions, and cross-module instantiations. | Generic-heavy std/kernel fixtures compile with stable symbol names and no emit-time type guessing. | Generic corpus, `diff-backend`, std collection gates. |
| P5. Typed lowering and optimizer inputs | MC-side HIR/MIR or equivalent typed lowering, layout facts, control-flow facts, safety-check facts, source maps, and optimizer metadata. | The lowerer produces verifier-clean IR/facts for all accepted corpus files and preserves safety checks before optimization. | HIR/MIR verifier, source-map tests, opt precondition tests. |
| P6. Full C backend | Feature-complete C emission: async state machines, atomics, fences, checked arithmetic, u128, SIMD where supported, inline asm, MMIO/volatile, ABI/layout, intrinsics, panic/trap paths, runtime hooks, debug/source-map expectations. | Emitted C compiles warning-clean where current gates require it and matches Zig C backend behavior on object/run/QEMU corpus. | C emit sweeps, `mcc-cc-test`, runtime tests, kernel C gates, C side of `diff-backend`. |
| P7. Full LLVM backend | Textual LLVM IR emission, object lowering, debug metadata, target ABI/layout, atomics, traps, async/runtime paths, kernel profile, and forbidden-assumption policy. | LLVM gates that pass under Zig also pass under MC, including object/run/QEMU coverage. | `llvm-test`, object/sweep/debug/opt/pkg/runtime/std/kernel/QEMU gates. |
| P8. Optimizer and equivalence | Port optimizer decisions and opt-equiv behavior without changing the safety contract. | Optimized and unoptimized C/LLVM outputs remain behavior-equivalent and preserve required checks. | `opt-test`, `opt-equiv-test`, LLVM opt sweeps, fuzz equivalence. |
| P9. Driver, packages, and tools | CLI compatibility, `emit-c`, `emit-llvm`, `emit-map`, profiles, `mcc-cc`, `mcc-llvm-cc`, package manifests, registry/lockfiles, editor diagnostics surface, reproducible builds. | Toolchain scripts and package flows work with the MC compiler selected. | Toolchain, package, registry, map, reproducible-build, and editor-facing diagnostic gates. |
| P10. Corpus widening and cutover | Full std, examples, demo, userland, kernel, QEMU, fuzz, and complete `m0` under Stage2. | Stage2 is the default compiler for the full gate matrix and reports zero real failures. | `tools/m0-parallel.sh <jobs>` and final `zig build m0` with MC compiler selected. |

### 6.6 Subsystem checklist

Use this checklist when breaking phases into issues or commits. Each row needs an oracle test, a positive
fixture, and a negative fixture where rejection behavior matters.

| Subsystem | Must cover before cutover |
|---|---|
| Lexer/parser | All token forms, attributes, imports, visibility/privacy, type declarations, generics, traits/impls, `where`, effects syntax, async/await, inline asm, unsafe/raw, comptime syntax, patterns, and all literals. |
| Module/import system | Relative paths, duplicate declarations, file-private names, import cycles/errors, module-qualified lookup, private symbol mangling, and deterministic cross-file order. |
| Type model/layout | Scalars, pointers, slices, arrays, structs, packed bits, overlay unions, unions, enums/open enums, optionals/results, dyn traits, function pointers, alignment, ABI size, and target-specific layout. |
| Const-eval | Constants, comptime expressions/blocks, enum raw values, array lengths, layout constants, compile-time errors, overflow behavior, and deterministic evaluation order. |
| Sema and hardening | Type checking, coercions, moves/borrows, definite-init, escape checks, unsafe boundaries, effects, IRQ/sleep/bounded rules, user pointer validation, capabilities/rights/secrets, exhaustiveness, and diagnostic codes. |
| Generics/traits | Multi-param and nested generics, trait bounds, impl coherence, method resolution, UFCS, generic containers, generic unions/enums, dyn coercions, vtables, and stable instantiated names. |
| C backend | Every accepted feature, warning-clean C, runtime hooks, source maps, debug names, ABI/layout parity, volatile/MMIO, atomics/fences, checked operations, panic/trap, async lowering, and kernel profile constraints. |
| LLVM backend | IR validity, object generation, debug metadata, ABI/layout parity, forbidden-assumption policy, atomics/fences, traps, runtime hooks, async/kernel lowering, and target-specific object behavior. |
| Optimizer | Safety-preserving rewrites, bounds/div/null checks, alias/poison policy, opt-equiv behavior, deterministic output, and backend agreement after optimization. |
| Driver/toolchain | CLI flags, profiles, import paths, object/link flows, package registry, lockfiles, reproducibility, diagnostics formatting, source-map output, and editor/LSP expectations. |
| Performance | Compiler wall time, memory, output size, generated C/LLVM size, QEMU-heavy gate time, and comparison to Zig compiler baselines. |

### 6.7 Cutover checklist

Cutover starts only after P0–P9 are green on the widened corpus.

1. Build Stage0 with the Zig compiler.
2. Use Stage0 to build Stage1 from the MC compiler source.
3. Use Stage1 to build Stage2 from the same source.
4. Compare Stage1 and Stage2 artifacts using the documented normalization contract.
5. Run the full oracle corpus with Stage2 selected as `MCC_UNDER_TEST`.
6. Run `tools/m0-parallel.sh <jobs>` and require `real_failures=0`.
7. Run the serial truth gate, `zig build m0`, with the MC compiler selected for compiler-produced
   artifacts.
8. Switch the default `mcc` toolchain entry point to Stage2/MC.
9. Keep the Zig implementation available only as an explicitly named fallback/oracle during a fixed
   stabilization window.
10. After the fallback window, either archive the Zig compiler or keep it in a non-production oracle
    location with docs that say it is no longer the default compiler.

If any step fails, revert only the cutover wiring and keep the MC implementation behind the selector.
Do not weaken `m0`, `diff-backend`, hardening checks, LLVM checks, or diagnostic gates to force cutover.

### 6.8 Lesser milestones and status labels

These are valid milestones, but none equals true self-hosting:

| Milestone | Meaning | Status label to use |
|---|---|---|
| Subset bootstrap | `mcc2` compiles its own subset and reaches the existing byte-identical C fixpoint. | `Subset bootstrap achieved` |
| C-only self-compile | An MC compiler compiles itself through C but has no LLVM backend parity. | `C-only bootstrap achieved; true self-hosting not achieved` |
| Parser parity | MC parser matches Zig parser on the chosen corpus. | `Parser parity achieved` |
| Sema parity | MC checker matches Zig checker on success/failure and diagnostic codes. | `Sema parity achieved` |
| Backend parity | MC C and LLVM backends match behavior and gate coverage. | `Backend parity achieved` |
| Stage2 stable | Stage1-built compiler rebuilds itself to stable output. | `Stage2 bootstrap stable` |
| Full replacement | Stage2 MC compiler is default and full `m0` passes on both backends. | `True self-hosting achieved` |

### 6.9 Work rules

- Keep every slice vertically gated: parser + sema + lowering + backend + test for the smallest real
  feature. Avoid landing large ungated ports.
- Use the Zig compiler as oracle until the corresponding MC subsystem has better proof than the oracle.
- Preserve the MC safety contract. Never bypass hardening, move/effect checks, or backend forbidden-
  assumption rules to get a bootstrap milestone.
- Keep C and LLVM honest. If a feature lands in one backend first, the status must say backend parity is
  incomplete and the other backend must have a tracked blocker.
- Prefer deterministic data structures and stable traversal order from the start. Bootstrap diffs become
  painful if symbol order, import order, or diagnostics are nondeterministic.
- Update this document or the full-selfhost ledger whenever a phase changes status, a corpus expands, or
  a gap is discovered.
- Use strict file staging for commits. Do not mix unrelated fixes with self-host phase work.
- For local confidence use `tools/m0-parallel.sh <jobs>`; for final acceptance use serial `zig build m0`.

### 6.10 Open risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| Scale | The target is the full 67k-line Zig compiler behavior, not the 8.9k-line subset. | Corpus-first phases; never claim replacement from line count alone. |
| Diagnostic drift | Tooling and tests depend on stable error codes/spans. | Diff diagnostics early, normalize only incidental text, and gate negative fixtures. |
| Sema complexity | Most safety value lives in checker passes, not parsing. | Port checker subsystems with hardening-focused negative tests before backend work hides bugs. |
| LLVM effort | `mcc2` has no LLVM backend. | Treat LLVM as a first-class phase; a C-only bootstrap is explicitly a lesser milestone. |
| Determinism | Self-host fixpoints require stable output. | Stable maps/order, deterministic symbol naming, checked normalization contract. |
| Performance | A correct compiler that is too slow may make `m0` impractical. | Record wall/cycle/memory metrics by phase and compare to Zig baselines. |
| Bootstrap trust | A compiler that only works when seeded by Zig may hide stage-specific behavior. | Require Stage0/Stage1/Stage2 and keep the Zig oracle until after cutover stabilization. |
| Safety regression pressure | Bootstrap pressure can tempt weakening checks. | No hardening waiver counts toward true self-hosting; waivers must block cutover. |

### 6.11 Immediate next actions

1. Add the compiler-selector contract to the toolchain scripts: default to the current compiler, but allow
   `MCC_UNDER_TEST` or an equivalent explicit argument everywhere a gate invokes `mcc`.
2. Add a full-selfhost differential harness for a tiny manifest: one positive hosted file, one negative
   diagnostic fixture, one emitted-C run, and one emitted-LLVM/object run.
3. Add the Stage0/Stage1/Stage2 bootstrap script with stable artifact comparison, even if the first MC
   compiler source is still the current `selfhost/` subset.
4. Create the corpus manifest and grow it in this order: `selfhost/` -> hosted `std/` subset -> full
   `std/` -> `examples/`/`demo/`/`user/` -> `kernel/` -> full `m0`.
5. Start P1/P2 with parser and diagnostic parity, because every later phase depends on trustworthy
   source locations, module paths, and diagnostics.

The historical result in §1 is therefore useful but not sufficient: MC has proven a subset bootstrap.
The full self-host project is complete only when this §6 guide reaches cutover and the MC compiler is
the default compiler passing the full gate matrix.
