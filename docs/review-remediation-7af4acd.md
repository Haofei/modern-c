# Remediation report for review baseline `7af4acd`

Baseline reviewed: `7af4acd00de66256d9ea7c11713415593242991d`

Fix commit: this remediation patch.

## Closed in this remediation

### F-01 — Nullable C lowering fixed-buffer fallback

`NullableSwitchSubject` no longer formats some-tests or payload expressions through
fixed 256-byte buffers and no longer falls back to semantic constants such as
`"0"` on formatting failure. Nullable conditions and payload expressions are now
appended directly into the generated artifact buffer and propagate allocation or
writer errors normally.

Regression coverage was added for long legal identifiers through both nullable
`if let` and nullable `switch` lowering.

### F-02 — Value optional switch binding

Nullable `switch` bindings now use the same payload emission helper as nullable
`if let`. For value optionals (`?T`), the generated C binding reads `.value`
instead of binding the whole optional wrapper.

### F-03 — `mcc build` CLI contract

The installed `mcc` launcher no longer intercepts `build`. The documented
`mcc build <file.mc> -o <exe>` command is handled by the compiler's real CLI
dispatch path.

The implementation is intentionally narrow and hosted-only:

- emits hosted C through the C backend;
- requires an exported no-argument `main`;
- wraps it as the host C `main`;
- links with `clang -std=c11 ... -lm`;
- fails closed on missing `-o`, multiple inputs, missing entry point, or clang
  failure.

### F-04 — Backend registry and `VerifiedProgram`

`emit-c` and `emit-llvm` now construct `backend.VerifiedProgram` and invoke the
selected backend through `backend.byName(...).lower(...)` rather than directly
calling concrete lowering functions from `main.zig`.

This does not complete the larger typed-MIR architecture migration, but it closes
the CLI bypass of the existing verified backend seam.

### F-06 — Source map/artifact option drift

`emit-map` now uses the same verified program, lowering options, and generated C
artifact as codegen. Backend source-map emission receives the generated artifact
and `LowerOptions`, including `--checks`, `--profile`, and `--stub-asm`, rather
than independently regenerating a default C artifact from raw AST.

### F-07 — `mcc symbols` fail-open behavior

`mcc symbols` no longer reports every hard failure as a successful empty JSON
index. Successful output now includes `complete: true`. Parse/internal failures
emit `complete: false` with a diagnostic payload and return nonzero.

The LSP symbol cache was updated to cache only `rc == 0 && complete == true`
indexes.

### Related hardening

- `--checks=all,elide-proven` and the reverse order are now rejected instead of
  being order-sensitive.
- Unknown source commands now fail before reading source/imports.
- `mcc build` multi-input errors are explicit.
- `--linux-kernel` is carried through `backend.LowerOptions`, so the LLVM backend
  registry path can express the complete CLI request.

## Still open architecture work

These review items remain broader architecture migrations and are not honestly
closed by this patch:

- complete `CompilationSession` replacement for all process-global compilation
  state;
- removal of backend-local semantic inference;
- typed MIR migration away from stringly typed type/value identity;
- moving C backend reserved-name policy out of general sema;
- artifact/source-map digest binding as a formal metadata object;
- kernel exact-byte `VerifiedBundle` secure-boot chain;
- third-party TCB CVE intake automation.

## Validation

Validated locally:

- `zig build test`
- `zig build c-test`
- `zig build mcc-build-test`
- `zig build mcc-cli-test`
- `zig build diff-backend`
- `zig build lsp-test`
- manual `mcc symbols` parse-failure smoke: nonzero + `complete=false`
- manual `mcc build` smoke: generated executable returned the MC `main` status

Docker validation was attempted with the same focused gate set, but Docker did
not return output for either the validation command or `docker version`; the
attempt was interrupted and is not counted as passing evidence.
