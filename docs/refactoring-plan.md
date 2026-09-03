# Refactoring plan

This is the active code-facing cleanup plan for the compiler core.

## Goal

Remove duplicate semantic authority. Backends may use source spelling for
emission mechanics, but not as authority for type, representation, ABI, layout,
provenance, control flow, ownership, or safety decisions.

Target shape:

```text
CompilationSession
        ↓
resolved semantic facts
        ↓
minimal syntax-free CheckedProgram
        ↓
typed MIR + MIR verifier
        ↓
VerifiedProgram
        ↓
mechanical C/LLVM emission
```

`src/compiler_session.zig` owns `CompilationSession`: file-boundary,
diagnostic, parsing, checking, MIR construction, and request-scoped compiler
state. `src/artifact_publisher.zig` owns artifact output. `src/main.zig` is
only the CLI composition root.

MIR already has typed seeds for block, function symbol, value, type, and span.
Verifier/admission checks reject result/span/owner drift.

`CheckedProgram` is deliberately a thin semantic table, not a second expression
IR. It owns callable/body identity, signature representation, ABI, and closed
effect flags; executable body semantics remain in typed MIR. The existing
inspection HIR remains a dump tool and is not promoted into the pipeline.

## Non-goals

- new language surface area;
- new backends;
- a full Typed HIR or second expression/control-flow representation;
- incremental query databases, serialized semantic caches, or separate compilation;
- editor integration or persistent service work;
- deployable kernel, Agent, runtime, package, or hardware scope;
- validation workloads defining compiler semantics.

## Completed review phases

| Phase | Theme | Closed evidence |
|---:|---|---|
| 0 | Stop backend authority growth | Remaining exceptions are exact-count-gated by the architecture and semantic-facts inventories. |
| 1 | CheckedProgram + executable MIR body identity | `CheckedProgram` is syntax-free and executable function bodies no longer use legacy AST fallback emitters. |
| 2 | Per-file source/module cutover | The loader no longer builds a combined textual source; parsing and source identity are per-file. |

`docs/codegen-ingress-migration.json` is the working migration ledger for Phase
2. It records the remaining AST-shaped declaration payloads still carried beside
`VerifiedProgram`, normalized facts already split out, and C/LLVM consumer
counts. `codegen-ingress-migration-test` must pass in every core tier; migration
patches should lower those budgets instead of adding new compatibility paths.

The machine-readable completion evidence for these bounded review goals lives
in `docs/review-goal-status.json`. Their completion does not claim that all
backend declaration syntax ingress or internal MIR compatibility projections
have been removed.

## Current queue

The review is executed as ten bounded cutovers. A row is complete only when its
old ingress is physically absent and an inventory or admission test prevents it
from returning.

| Priority | Cutover | Status | Exit condition |
|---|---|---|---|
| P0 | Function-body fallback | complete | Both backends consume only verified executable MIR; legacy body emitters and fallback request payloads are absent. |
| P0 | Function/body type payloads | complete | Callable signatures and body declaration-shape dependencies are `SignatureTypeId`s; no body `ast.TypeExpr` fact exists. |
| P0 | Global declarations | active | Every admitted global has a syntax-free initializer plan; `GlobalArtifact` and `GlobalInitFacts.init` are deleted. |
| P0 | Type declarations | complete | Struct, enum, tagged union, overlay union, packed bits, and aliases use checked facts; `TransitionalTypeDeclArtifact` is deleted. |
| P1 | Trait/dynamic declaration ingress | complete | Qualified codegen rejects dynamic traits before lowering and retains no trait-method AST artifact. |
| P1 | Backend comptime provider | blocked by globals | Comptime evaluation finishes before request construction; `ComptimeFunctionDeclarations` and backend `eval` imports are deleted. |
| P1 | MIR compatibility projections | active | Canonical typed IDs replace AST/source/string double-writes one domain at a time; each removed field is ratcheted at zero. |
| P1 | Per-file module identity | complete | No combined source or textual inclusion path exists; spans and definitions retain per-file identity. |
| P1 | Minimal CheckedProgram | complete | Syntax-free callable/global/signature facts are admitted before verified MIR without adding a second expression IR. |
| P1 | Final backend request | blocked by globals/types/comptime | `LowerRequest` contains only `VerifiedProgram`, output, and emission options; declaration artifacts are absent. |

Active work proceeds in dependency order: finish globals, remove the backend
comptime provider, delete remaining MIR compatibility projections, then close
`LowerRequest`. Advanced language forms stay frozen during this cutover.

The callable ingress is closed: `CallableEmissionFact` owns render-only
callable details while `CheckedCallableFact` and `SignatureTypeTable` own its
signature. `FunctionArtifact`, `FunctionSignatureFacts`, and the callable arm
of `DeclArtifact` are deleted. The only remaining callable AST compatibility
provider is `ComptimeFunctionDeclarations`, which is restricted to const
evaluation and is tracked by the separate backend-comptime cutover.

## Patch rules

Each patch should change one invariant family and include one focused proof:

- inventory test for authority-boundary changes;
- direct backend/MIR regression for semantic changes;
- CLI/tool test for surface removals;
- no unrelated kernel or validation-workload edits.

Focused compiler-authority checks:

```text
git diff --check
zig build semantic-facts-inventory-test --summary all
zig build architecture-boundary-inventory-test --summary all
zig build codegen-ingress-migration-test --summary all
```

Use broader C/LLVM, fuzz, or QEMU validation only when the touched slice changes
that path.
