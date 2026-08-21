# P0 codegen-ingress worklist (function-body fallback)

Goal (docs/review-goal-status.json `function-body-fallback`): C/LLVM codegen no
longer ingests the AST body (`FunctionBodyFallbackArtifact.syntax: ast.Block`);
every function body lowers from verified MIR. This file is the census-derived,
evidence-backed worklist for that goal — so the remaining work is attacked
head-of-distribution, not by blind shape enumeration.

## Measurement

`tools/toolchain/fallback-census.sh` (recorder: `src/fallback_census.zig`) hooks
the real admission branch in each backend's `emitFunctionDefinitions` and ranks
which function shapes still fall back. The strict ratchet corpus currently
admits 44.4% of C functions and 45.0% of LLVM functions; the rest still ingest
the AST body.

### Last completed broad census snapshot (C, 2026-08-20, before typed binary domain admission)

1611 distinct functions, **439 admitted (27.3%)**, 1172 fallback. The current
strict ratchet corpus below includes the typed binary slice and is the blocking
measurement. Remaining broad-snapshot fallbacks ranked by family
(term / ret / blocks / traps):

| n | %fb | family | examples | remaining blocker |
|---|---|---|---|---|
| 195 | 17% | return `<ident>` 1 blk 0 trap | region_holds, nested | remaining local-computed / multi-statement forms |
| 140 | 12% | return `<ident>` 2 blk 1 trap | frame_base, slice_of_struct | same + a bounds/repr trap |
| 82 | 7% | return `<ident>` 3-4 blk 2+ trap | pr_len, nested_index | same, more control flow |
| 74 | 6% | fallthrough void 1 blk 0 trap | call_literal, store_release | builtin/atomic void body → statement-level |
| 43 | 4% | return binary 2 blk 1 trap | pa_is_aligned, counter_differs | richer compare operand: `(a%a)==0` (checked), `load(p)!=x` (atomic) |
| 36 | 3% | return binary 1 blk 0 trap | sat_mul, ordered_bitwise_return, bool_and | ordering-sensitive (`next()&next()`) or short-circuit (`&&`) or sat-domain |
| 30+ | — | switch/branch/loop 5+ blk | pa_align_down, loop_condition | control-flow families → large |

Every remaining bucket is now either **large** (a new emission primitive for the
local/multi-statement `<ident>` returns, ~36% of fallbacks; or statement-level
builtin/void lowering) or **medium-with-risk** (widening compare/binary operands
to carry checked-arith or atomic-load sub-expressions — real evaluation-order and
trap-counting hazards, the same class that produced two miscompiles this session).
The clean recognizer-only wins are exhausted.

## The fidelity-safe admission method (established, must be preserved)

The MIR fast path is a **deliberately simplified emission with lower fidelity**
than the AST fallback. Admitting a family must not regress fidelity (policy
choice: *preserve fidelity first*). Two verified fidelity gaps:

1. **Folded `let`.** The fast path folds `let y = a+b; return y` into
   `return a+b`, dropping that construct's source-map / `#line` entry. Gate
   admission on `simpleMirEntryBlockFoldsLocal(fn_mir) == false` — direct-return
   shapes fold nothing and lose no source map; let-folding functions stay on the
   fallback that still emits their per-construct map.
2. **Param debug info.** The fast path omits param `llvm.dbg.value` — already
   accepted policy (the migrated functions lack it), so not a *new* regression,
   but confirm per family.

Validation per slice (all host-runnable): `zig build test-shard-lower-c
test-shard-lower-llvm` green; emitted C/LLVM compile under `clang`
(`/opt/homebrew/opt/llvm/bin`); `mcc emit-map` shows no `generated_c_line=0` for
an admitted function. Then Docker m0 regenerates emit-snapshots.

## Ratchet gate

`zig build fallback-census-ratchet-test` runs
`tools/toolchain/fallback-census.sh --check` over the explicit C/LLVM-positive
`tools/toolchain/fallback-census-roots.txt` corpus. Unlike the broad report mode,
check mode fails on any compile error, timeout, or crash; it does not use `|| true`
to turn a failed root into a successful gate. The checked-in baseline is
`tools/toolchain/fallback-census-baseline.tsv`:

| Backend | Total min | Admitted min | Fallback max | Unsupported max | Admission bps min |
|---|---:|---:|---:|---:|---:|
| C | 160 | 71 | 89 | 0 | 4437 |
| LLVM | 160 | 72 | 88 | 0 | 4500 |

New MIR admissions should increase `admitted_min` and/or lower `fallback_max`
in that baseline when the checked corpus improves.

## Remaining families, by tractability

### Closed this migration (direct-return / direct-void, all both-backend)

Each was a recognizer family + gate case + render case, validated identically
(both shards green, emitted C/LLVM compile under clang, all function source-map
entries have nonzero generated lines, soundness/parity probes). The same discipline caught
optional-deref, pointer-compare, evaluation-order, unequal-width bitcast, and
typed-unary operand-descendant bugs before commit.

| Family | Example | Commit |
|---|---|---|
| Direct-return checked arithmetic | `pa_diff`, `wrap_add` | `71b3299d` |
| Bare param return past elided nonnull | `return p` (`p: *u32`) | (session) |
| Scalar deref of param ptr | `return p.*` | (session) |
| Plain unsigned binary (add/sub/mul/and/or/xor) | `return a + b` | (session) |
| Plain unary | `return -a`, `return !b` | (session) |
| Pointer-field load | `return s.next` | (session) |
| Address constructor (`phys`) | `return phys(v)` → `uintptr_t` | (session) |
| Bitwise binary | `return a & b` | (session) |
| Address-typed field / deref | `PAddr`/`VAddr` field & `*p` | (session) |
| Pointer comparison | `return a == b` (ptr params) | `8591552e` |
| Local call chain | `let x = f(); return g(x)` | (current batch) |
| Nested local call initializer (C) | `let x = f(g(a), b); return h(x)` | (current batch) |
| Leaf-operand typed unary call targets | numeric conversion, `phys`, `bitcast`, `enum.raw`; root keyed by `typed_unary_operand` SpanId/type fact | (current batch) |
| Leaf-operand typed binary domain calls | `wrapping.add`, serial before/after/distance, counter delta; indexed roots keyed by owner-qualified `typed_call_operand` facts | (current batch) |
| Shared straight-line statement plan | discarded non-void call; zero-argument function-pointer call through param/local | (current batch) |
| Typed indirect call return plan | `return op(x,y)`, global function-pointer, global struct-field function-pointer | (current batch) |
| Pure logical return tree | `return a && b`, `return !a || (b && c)`; MIR owns typed operand edges | (current batch) |

### Remaining families, by tractability

| Family | Example | Blocker | Effort |
|---|---|---|---|
| Remaining builtin / `call_target` returns | bounded/assumption/Result-producing and three-operand domain calls | each kind still needs an explicit typed semantic descriptor, control/result model, and backend rendering; leaf binary domain calls no longer fall back | **medium per semantic family** |
| Builtin / `call_target` void bodies | `store_release`, atomics | same statement-level/builtin gap (plain void calls already admitted) | **large** |
| Checked-operand comparison | `return (a+b) == b` | `SimpleMirCompareBinary` operands are `SimpleMirArg` (no `checked_binary` variant); needs a richer operand type | **medium** |
| Remaining multi-statement returns | locals initialized by non-call expressions, multiple locals, assignments, traps | C now also covers one nested call inside the initializer; LLVM and the remaining shapes need a general MIR statement/value sequence | **large** |
| Folded-`let` families | `let y=x+1; return y` | fast path drops per-construct source map | **large** — needs the source map derived from MIR source points, not `#line` matching |

The remaining chunk is no longer mostly recognizer-shaped. Pure boolean
parameter trees now use explicit operator operand `SpanId` edges and one shared
plan; neither backend reconstructs their shape from source. The shared
statement-level plan admits discarded non-void calls and zero-argument
function-pointer calls through params or one direct-call-initialized local. A
second shared plan admits value-producing indirect calls returned immediately;
MIR owns the indexed argument values and canonical callee root/projection, and
both backends only render that plan. Closures, non-leaf arguments,
reassignment, traps, and cleanup still fail closed. The next expansion must add
explicit MIR operands rather than another backend-local recognizer.
Multi-statement returns, builtin/void bodies and,
for folded-`let`, a source-map-derived-from-MIR change remain. Plain
function-call returns/voids are already admitted. Leaf-operand
typed unary call targets now share one descriptor; complex roots remain on the
full path until the entire expression is representable. New kinds must supply
complete MIR type facts and explicit rendering rather than add another return
union variant.

## Honest bottom line

After the one clean gate-widen (checked arithmetic), the remaining families are
NOT quick recognizer additions — they need the fast path extended to
statement-level and builtin lowering (large), plus a source-map-from-MIR change
to admit folded-`let` shapes without losing fidelity (large). Completing P0
(deleting the AST body ingress) is effectively re-implementing full body
emission on MIR at fallback fidelity. Multi-week. Related: the two P1 goals
(typed-HIR canonical identity, module-graph cutover) are separate large
foundations; see [[p0-spanid-decoupling-blocked]] for the corrected dependency
analysis (P0 is NOT coupled to module-graph's source basis).
