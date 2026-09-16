# Changelog

This project has not shipped a tagged release yet. Changes below describe the current
`0.7.0-dev` development line, newest first.

## 0.7.0-dev

### September 2026: compiler-core review follow-through

- Sema now has a symbol table: every declaration, including parameters and
  locals, gets a `DefId`, and scopes resolve identifiers to ids.
- Sema records an interned, structural resolved type for every expression it
  types (scalars, nominals by id, pointers, slices, arrays, optionals,
  `Result`, signatures, generic instantiations, trait objects). The MIR builder
  reads that table for literals, identifiers, member/index/slice/deref/cast/try,
  direct-call results, and arithmetic under sema's operand rule, instead of
  re-inferring from the AST. Emitted C, LLVM, and diagnostics are unchanged
  across the fixture corpus.
- Integer, float, and access facts join to MIR instructions by identity rather
  than by source span. This fixed the async fixtures, whose generated bodies
  shared one span across many instructions.
- A non-zero `mcc` exit always prints a diagnostic. Stage failures used to
  drop recorded diagnostics on some paths.
- Integer literals may take an arithmetic-domain context (`sat<u8>`,
  `wrap<u32>`) in MIR, matching what sema already accepted.
- Arrays of enum values and alias-typed arrays are admitted and rendered as
  global initializers.
- `c-test` and `sweep` assert against a named known-gap manifest
  (`docs/backend-expected-failures.json`), so both gates are green and carry
  signal; a recorded entry that starts passing fails the gate until removed.
- C is the primary backend. LLVM is a differential oracle: its gates moved to
  the `llvm-oracle` tier, run from `m0-full` only. No LLVM code was removed.
- Async/await moved to the `experimental-surface` branch; the parser rejects
  the keywords with `E_ASYNC_ON_BRANCH`. The unreachable AST remnants are gone.
- The fifteen needle-count inventory scripts and their JSON ledgers were
  deleted. One structural test, `architecture-boundary-test`, enforces that
  backend and MIR-body modules do not import the syntax front end and lists
  every remaining exception by name.
- `src/mir.zig` was split into builder, verifier, cleanup-CFG, and dump
  modules behind a thin facade.
- `docs/refactoring-plan.md` merged into `docs/todo.md`; the documentation map
  in `docs/README.md` now classifies each document as source of truth,
  reference, audit record, or rationale.

### Earlier

- Added top-level `mcc --help`, `mcc help`, and `mcc --version` behavior with a
  transcript gate.
- Added generated diagnostic-code reference coverage for compiler `E_*` messages.
- Hardened early core reliability blockers: parser nesting limits,
  monomorphization limits, 128-bit arithmetic guards, oversized integer literal
  diagnostics, fail-closed diagnostic allocation, closure typing, while-condition
  move checking, extern aggregate ABI rejection, and LLVM check-elision parity.
- Improved diagnostics with import-aware source locations, missing-import errors,
  UTF-8 BOM handling, source snippets, and caret underlines.
- Added golden wording coverage for bad/reject fixtures.
