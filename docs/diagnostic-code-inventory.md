# Diagnostic code inventory

`tools/toolchain/diagnostic-code-inventory.py --check` extracts production
`E_*` diagnostics from non-test `src/*.zig` files and requires each code to be
owned by either:

- a negative fixture comment in `tests/spec/**/*.mc`, `tests/c_emit/bad/*.mc`,
  `kernel/bad/*.mc`, or `demo/bad/*.mc`; or
- an explicit `// DIAGNOSTIC_UNIT: E_CODE` marker in `src/*_tests.zig`,
  placed next to a unit test assertion for the exact diagnostic code; or
- an allowlist row below with a concrete reason.

Unit-test ownership is reserved for internal diagnostics that are not
appropriate to synthesize through source fixtures, such as malformed internal
IR verifier states. Allowlist entries are intentionally narrow. If fixture or
unit-test ownership is added for one of these codes, remove the row; the gate
fails on redundant or stale entries.

| Code | Reason |
|---|---|
| `E_INTERNAL_OOM` | Defensive compiler out-of-memory diagnostic. It should not be forced through a deterministic fixture. |
