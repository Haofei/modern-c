# Remediation report for review baseline `ea79fe74`

Baseline reviewed: `ea79fe742abf0a7c034a22d76f0b3f1bbdf5c43e`

Fix commit: this remediation patch.

## Closed in this remediation

### H-03 — Diagnostics OOM visibility

`diagnostics.Reporter` now records an emergency `diagnostic_oom` state whenever
diagnostic message, note, or append allocation fails. This state forces
`has_errors = true` and is rendered as `E_DIAGNOSTIC_OOM` in both text and JSON
diagnostic output.

Regression coverage injects allocation failure into `Reporter.err()` and asserts
that the emergency diagnostic is observable rather than silently losing the
error.

### H-05 — `std/mem.mc` overflow-safe overlap/alignment checks

`mem_copy` no longer computes `s + len` or `d + len` when checking overlap.
The overlap predicate now uses subtraction-only distance checks, so hostile
near-`usize::MAX` inputs cannot trap before the overlap policy runs.

The 8-byte alignment loops also avoid full `d + i` arithmetic for modulo-8
checks and instead compute the low bits directly.

### BUG-01 — `mcc build` final output transaction

`mcc build` now asks clang to write a sibling temporary executable and commits it
to the requested `-o` path with an atomic rename only after clang succeeds.
Failed clang invocations or interrupted builds no longer directly truncate or
partially write the final executable path.

The compiler also reserves the temporary executable path before invoking clang
and fails closed if the sibling temp already exists.

### DOC-01 — Single risk-status source

Added `docs/review-risk-register.yaml` as the machine-readable source for broad
review blockers that remain open across remediation reports. This avoids
hand-maintained markdown counters being interpreted as platform-wide production
closure.

## Still open architecture/security work

These items are deliberately not claimed as closed by this patch:

- complete `CompilationSession` migration;
- typed MIR identity (`TypeId`/`ValueId`/`SymbolId`) and removal of stringly
  typed MIR state;
- complete removal of backend-local semantic inference;
- removal of C backend reserved-name policy from general sema;
- formal artifact/source-map digest metadata object;
- exact-byte kernel `VerifiedBundle` secure-boot chain;
- privileged capability/right mint module boundary;
- third-party TCB CVE intake automation;
- real hardware, power-loss, soak, and external security audit qualification.

## Validation

Validated locally:

- `zig build test --summary all`
  - 6/6 steps succeeded
  - 848/848 tests passed
- `zig build c-test mcc-build-test mcc-cli-test diff-backend lsp-test --summary all`
  - 18/18 steps succeeded
  - `c-test`: 166 compile fixtures and 34 reject fixtures
  - `diff-backend`: C/LLVM agree on 173 comparable host fixtures
- `python3 tools/toolchain/diagnostics-reference.py --check`
- `python3 tools/toolchain/std-api-docs.py --check`
- `git diff --check`
- `bash -n tools/toolchain/mcc-build.sh tools/toolchain/mcc-cc.sh tools/toolchain/mcc-launcher.sh tools/toolchain/mcc-build-test.sh tools/m0-parallel.sh tools/fast-parallel.sh`
- `python3 -m py_compile tools/lsp/mc-lsp.py tools/lsp/lsp-test.py`

Docker validation was not rerun for this patch in this environment.
