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

Do these in order unless a failing test forces a narrower slice:

1. Remove the transitional function return-type syntax payload.
2. Normalize global, type-declaration, and trait declaration codegen facts.
3. Move comptime evaluation before `LowerRequest` construction.
4. Reduce backend `ast_bridge`, `eval`, and `declaration_artifacts` imports to
   zero, lowering the exact ratchets with every deletion.
5. Remove legacy MIR compatibility projections after their canonical typed
   replacements are direct builder outputs.
6. Keep advanced language forms experimental and frozen during this cutover.

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
