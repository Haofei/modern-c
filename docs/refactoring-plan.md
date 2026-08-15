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

## Non-goals

- new language surface area;
- new backends;
- editor integration or persistent service work;
- deployable kernel, Agent, runtime, package, or hardware scope;
- validation workloads defining compiler semantics.

## Active phases

| Phase | Theme | Exit signal |
|---:|---|---|
| 0 | Stop backend authority growth | `semantic-facts-inventory-test` does not grow, or each remaining exception is exact-count-gated. |
| 1 | Typed MIR identity | backend-critical type, symbol, value, ABI/layout, representation, control, and ownership facts are typed or verifier-owned. |
| 2 | `VerifiedProgram` narrowing | C/LLVM entrypoints no longer expose AST as semantic input. |

`docs/codegen-ingress-migration.json` is the working migration ledger for Phase
2. It records the remaining AST-shaped declaration payloads still carried beside
`VerifiedProgram`, normalized facts already split out, and C/LLVM consumer
counts. `codegen-ingress-migration-test` must pass in every core tier; migration
patches should lower those budgets instead of adding new compatibility paths.

Phases 0–2 are the work. Artifact packaging, manifests, LSP, QEMU, and
tooling polish must not displace these compiler-core phases.

## Current queue

Do these in order unless a failing test forces a narrower slice:

1. Keep architecture ratchets exact: backend `ast_bridge`, `eval`, and
   `declaration_artifacts` ingress may only shrink.
2. Remove or quarantine the next backend-local semantic helper.
3. Convert the next backend-critical fact family toward typed IDs or
   verifier-owned facts.
4. Narrow the next `VerifiedProgram` or codegen request syntax ingress.
5. Keep advanced language forms experimental and frozen until phases 0–2 close.

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
