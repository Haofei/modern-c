# Changelog

This project has not shipped a tagged release yet. Changes below describe the current
`0.7.0-dev` development line.

## 0.7.0-dev

- Added top-level `mcc --help`, `mcc help`, and `mcc --version` behavior with a
  transcript gate.
- Added generated diagnostic-code reference coverage for compiler `E_*` messages.
- Hardened early production-readiness blockers: parser nesting limits,
  monomorphization limits, 128-bit arithmetic guards, oversized integer literal
  diagnostics, fail-closed diagnostic allocation, closure typing, while-condition
  move checking, extern aggregate ABI rejection, and LLVM check-elision parity.
- Improved diagnostics with import-aware source locations, missing-import errors,
  UTF-8 BOM handling, source snippets, and caret underlines.
- Added golden wording coverage for bad/reject fixtures.
