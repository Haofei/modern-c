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

`src/compiler_session.zig` owns request-scoped compiler state.
`src/artifact_publisher.zig` owns artifact output. `src/main.zig` is only the
CLI composition root.

## Non-goals

- new language surface area;
- new backends;
- editor product or persistent service work;
- deployable kernel, Agent product, runtime, package, or hardware claims;
- validation workloads defining compiler semantics.

## Active phases

| Phase | Theme | Exit signal |
|---:|---|---|
| 0 | Stop backend authority growth | `semantic-facts-inventory-test` does not grow, or each remaining exception is exact-count-gated. |
| 1 | Typed MIR identity | backend-critical type, symbol, value, ABI/layout, representation, control, and ownership facts are typed or verifier-owned. |
| 2 | `VerifiedProgram` narrowing | C/LLVM entrypoints no longer expose AST as semantic input. |

Phases 0–2 are the work. Artifact packaging, manifests, LSP, kernel/QEMU, and
tooling polish must not displace these compiler-core phases.

## Current queue

Do these in order unless a failing test forces a narrower slice:

1. Delete remaining historical compatibility surfaces that are not part of the
   current CLI, gate, or compiler API.
2. Remove or quarantine the next backend-local semantic helper.
3. Convert the next backend-critical fact family toward typed IDs or
   verifier-owned facts.
4. Narrow the next `VerifiedProgram` or codegen request syntax ingress.

## Patch rules

Each patch should change one invariant family and include one focused proof:

- inventory test for authority-boundary changes;
- direct backend/MIR regression for semantic changes;
- CLI/tool test for surface removals;
- no unrelated kernel/product edits.

Focused compiler-authority checks:

```text
git diff --check
zig build semantic-facts-inventory-test --summary all
zig build architecture-boundary-inventory-test --summary all
```

Use broader C/LLVM, fuzz, or QEMU validation only when the touched slice changes
that path.
