# Self-Hosting MC — Plan (stress-test-driven)

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
  Verbosity ~1.3–1.4× the Zig original. Next: P3 (sema subset) — but first adopt `module{}`
  wrappers per selfhost file to head off G22 as more modules land.
