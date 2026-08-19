# P0 codegen-ingress worklist (function-body fallback)

Goal (docs/review-goal-status.json `function-body-fallback`): C/LLVM codegen no
longer ingests the AST body (`FunctionBodyFallbackArtifact.syntax: ast.Block`);
every function body lowers from verified MIR. This file is the census-derived,
evidence-backed worklist for that goal — so the remaining work is attacked
head-of-distribution, not by blind shape enumeration.

## Measurement

`tools/toolchain/fallback-census.sh` (recorder: `src/fallback_census.zig`) hooks
the real admission branch in each backend's `emitFunctionDefinitions` and ranks
which function shapes still fall back. On the test corpus ~20–28% of distinct
functions are fast-path admitted; the rest still ingest the AST body.

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

## Remaining families, by tractability

### Closed this migration (direct-return / direct-void, all both-backend)

Each was a recognizer family + gate case + render case, validated identically
(both shards green, emitted C/LLVM compile under clang, source map has no
`generated_c_line=0`, soundness/parity probes). Two real bugs were caught by
that discipline before commit: an `?u32`-deref miscompile (a single load that
dropped the optional tag) and an LLVM pointer-`icmp` render break.

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

### Remaining families, by tractability

| Family | Example | Blocker | Effort |
|---|---|---|---|
| Builtin / `call_target` returns | `bitcast`, `bitcast_float_to_bits` | fast path emits single `return <expr>;`; bitcast needs addressable temps + `__builtin_memcpy` — **statement-level** emission the return path can't do | **large** |
| Builtin / `call_target` void bodies | `store_release`, atomics | same statement-level/builtin gap (plain void calls already admitted) | **large** |
| Checked-operand comparison | `return (a+b) == b` | `SimpleMirCompareBinary` operands are `SimpleMirArg` (no `checked_binary` variant); needs a richer operand type | **medium** |
| Multi-statement returns | `let x = f(); return g(x)` | fast path emits one expression; genuine (non-folded) lets can be admitted with full fidelity but need statement-prefix emission on the return path | **medium–large** (highest-count family, ~182) |
| Folded-`let` families | `let y=x+1; return y` | fast path drops per-construct source map | **large** — needs the source map derived from MIR source points, not `#line` matching |

The remaining chunk is no longer recognizer-shaped: it needs the fast path
extended to **statement-level** emission (multi-statement returns, builtin/void
bodies) and, for folded-`let`, a source-map-derived-from-MIR change. Plain
function-call returns/voids are already admitted; only builtin (`call_target`)
ones fall back.

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
