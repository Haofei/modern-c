# Diagnostic code inventory

`tools/toolchain/diagnostic-code-inventory.py --check` extracts production
`E_*` diagnostics from non-test `src/*.zig` files and requires each code to be
owned by either:

- a negative fixture comment in `tests/spec/*.mc`, `tests/c_emit/bad/*.mc`,
  `kernel/bad/*.mc`, or `demo/bad/*.mc`; or
- an allowlist row below with a concrete reason.

Allowlist entries are intentionally narrow. If a fixture is added for one of
these codes, remove the row; the gate fails on redundant or stale entries.

| Code | Reason |
|---|---|
| `E_ADDRESS_CLASS_DEREF` | Fallback verifier code for unknown address-class dereference findings. Specific concrete classes already have fixture coverage, and this fallback is reserved for verifier-internal coverage gaps. |
| `E_INTERNAL_OOM` | Defensive compiler out-of-memory diagnostic. It should not be forced through a deterministic fixture. |
| `E_MIR_CFG` | MIR verifier internal malformed-CFG diagnostic. User-facing source fixtures should not normally construct malformed MIR. |
| `E_REPRESENTATION_CHECK_MISSING` | MIR verifier internal representation-proof diagnostic. Source fixtures should prove or reject via higher-level rules rather than synthesize missing verifier facts. |
