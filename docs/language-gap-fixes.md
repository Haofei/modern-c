# Language Gap Fixes (from self-hosting)

Fixing the real MC compiler (`src/*.zig`) gaps that self-hosting surfaced (see
[`self-host-gaps.md`](self-host-gaps.md), G9–G32), so `mcc2` can be de-workaround-ed and the
rest of self-hosting done idiomatically. **User directive: fix ALL of them, incl. the
by-design/ergonomic ones.** Order: fix language → refactor selfhost → continue self-host work.

**Gating per fix (MC rules):** reproduce first (probe); fix in sema + **both** backends (C +
LLVM); add a spec/`c_emit` test + parity; full `m0` green both backends; front-end changes get
`llvm-trap-test` (kernel-emit validation), not just tests. Worktree agent → host-verify →
cherry-pick → m0.

## Batching (by disjoint files, to parallelize safely)

### Batch 1 — correctness bugs, file-disjoint (START)
| Gap | What | Primary files | Status |
|-----|------|---------------|--------|
| G23 | `<call>==x` fails in `return`/`let bool=` (works in `if`) → `UnsupportedCEmission` | `src/lower_c_flow.zig` (+llvm equiv) | pending |
| G19 | `raw.load/store<T>` of aggregate T → `UnsupportedCEmission` (scalar-only) | `src/lower_c_type.zig`, `lower_c_call.zig` (+llvm) | pending |
| G24 | reserved words (`ok/err/type/use/open/sat/wrap`) can't be locals → contextual keywords | `src/lexer.zig`, `src/parser.zig` | pending |

### Batch 2 — the two big features
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G12 | slices: string-literal→`[]const u8` lowering; construct-from-parts; `[]mut`→`[]const`; **the `x as []const u8` soundness hole** (checker accepts, emits length-dropping C) | `sema_type.zig`, `lower_c_emitter.zig`, `lower_llvm*.zig` | pending |
| G11 | value optionals `?V` (tagged `{present,value}` repr; `if let`/`==null`/`switch`) | `sema_type.zig`, `lower_c_*`, `lower_llvm*` | pending |

### Batch 3 — ergonomic / design (user opted in)
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G20 | block-scoped `let` (currently function-scoped) | `sema.zig` scopes | pending |
| G22 | module-qualified imports / overloading (flat namespace today) | `loader.zig`, `sema.zig` | pending |
| G25 | `.raw()` on closed enums OR exhaustiveness on `open enum` switches (resolve the tension) | `sema.zig`, `sema_type.zig` | pending |
| G18 | generic tagged unions (`union Opt<T>`) | `parser.zig`, `sema.zig`, `monomorphize.zig` | pending |
| G16 | `Hash`/`Eq` trait bounds for generic containers | `sema.zig`, `monomorphize.zig` | pending |

### Batch 4 — narrower
| Gap | What | Files | Status |
|-----|------|-------|--------|
| G14 | escape analysis over-rejects `return &heapptr.field` | `sema_move.zig`/escape | pending |
| G27 | `.raw()` on a variant-path literal (`Enum.variant.raw()`) | `sema.zig` | pending |
| G30 | `*mut T`→`*const T` param coercion | `sema_type.zig` | pending |
| G29 | `hosted_io` `AT_FDCWD` Linux-hardcoded (macOS relative imports) | `std/hosted_io.mc` | pending |

## Then
- **Refactor `selfhost/*.mc`** to drop the workarounds (value optionals instead of `{present}`
  structs / `?*V`; `[]const u8` string literals instead of byte-array keyword tables; block-scoped
  `let`; module-qualified calls; `match`/`switch` with `.raw()` exhaustiveness; etc.).
- **Continue self-host** integration long-tail (opaque structs, `Result`/`if let`, arithmetic
  domains, const globals) → literal `mcc2`-compiles-`mcc2`.

## Execution log
- **2026-07-01 — Batch 1 landed** (G19 `6ef4534`, G23 `a3f5305`, G24 `5dbef9e`; fixture fix `<pending>`).
  - **G19** — aggregate `raw.load/store<T>` now lower (whole-object typed load/store) on C + LLVM; scalar/MMIO path untouched. `diff-backend`/`c-test` green.
  - **G23** — sequenced-comparison operand-type recovery in value contexts (`return`/`let bool=`) for call/`.raw()`/member operands (C backend; LLVM was already correct — types via sema, not AST heuristics). New `enum_raw_compare` fixture.
  - **G24** — `ok`/`err`/`type`/`use`/`open`/`sat`/`wrap` now usable as locals/params/fields (contextual keywords in the parser; lexer table unchanged so keyword semantics preserved). Caveat: `ok(..)`/`err(..)` calls still resolve to the Result ctor by lexeme.
  - Fixture bug caught by full `m0`: the G24 fixture returned 143 but host-suite entry contract needs `return 1` (both backends compute 143 identically — no compiler bug); fixed.
- **2026-07-01 — Batch 2 landed + m0-green (both backends).**
  - **G12 (slices)** (`910ec9f`) — soundness hole closed (`E_ILLEGAL_SLICE_CAST` rejects scalar→slice), string-literal→`[]const u8` lowering, `[]mut`→`[]const` coercion; C + LLVM, `diff-backend` 161. Slice-from-raw-parts deferred (unsafe length-fabricating primitive, own design). m0 real_failures=0.
  - **G11 (value optionals `?T`)** (`3cc7416`, 21 files) — `?u32`/`?usize`/`?struct`/`?[]const u8` via a tagged `{present,value}` aggregate (C `mc_opt_<T>`, LLVM `{i1,T}`); pointer optionals keep the null sentinel unchanged. `if let`/`==null`/`.?`(traps on absent)/struct-field/by-value all work; `switch`-on-optional deferred. `diff-backend` 162, entry fixture returns 1 both backends, m0 real_failures=0.
_(append per landed fix: gap, commit, what changed, backends, m0)_
