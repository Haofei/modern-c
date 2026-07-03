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
| `E_ASYNC_AWAIT_UNRESOLVED` | Async lowering fail-closed path for await shapes that cannot be resolved before semantic analysis. Existing async bad fixtures cover user-facing unsupported constructs; this path needs a targeted future fixture when dynamic-future await work resumes. |
| `E_ASYNC_BRANCH_UNSUPPORTED` | Async v0 structural limitation for await-bearing branch shapes. Current async bad coverage exercises the general unsupported path; individual branch-shape fixtures are deferred until the async subset is expanded. |
| `E_ASYNC_LOOP_UNSUPPORTED` | Async v0 structural limitation for await-bearing loop shapes. Current async bad coverage exercises the general unsupported path; individual loop-shape fixtures are deferred until the async subset is expanded. |
| `E_BACKEND_UNSUPPORTED` | CLI backend integration path is covered by `diagnostics-test`, which creates temporary C and LLVM backend unsupported fixtures and asserts source-spanned diagnostics instead of raw backend errors. |
| `E_CONST_GET_BASE` | `const_get` intrinsic misuse for non-array bases. This is a narrow compile-time intrinsic edge without a dedicated negative fixture yet. |
| `E_CONST_GET_BOUNDS` | `const_get` intrinsic compile-time bounds misuse. This is a narrow intrinsic edge without a dedicated negative fixture yet. |
| `E_CONST_GET_INDEX` | `const_get` intrinsic arity/index misuse. This is a narrow intrinsic edge without a dedicated negative fixture yet. |
| `E_ENUM_RAW_REQUIRES_OPEN_ENUM` | MIR verifier fallback for `.raw()` on non-open enums. Positive enum raw behavior is covered; this verifier diagnostic does not have a negative fixture yet. |
| `E_IMPORT_NOT_FOUND` | CLI integration path is covered by `diagnostics-test`, which creates temporary import failures rather than a stable corpus fixture. |
| `E_IMPORT_OUTSIDE_SANDBOX` | CLI integration path is covered by `diagnostics-test`, which creates temporary sandbox import failures rather than a stable corpus fixture. |
| `E_INTERNAL_OOM` | Defensive compiler out-of-memory diagnostic. It should not be forced through a deterministic fixture. |
| `E_MIR_CFG` | MIR verifier internal malformed-CFG diagnostic. User-facing source fixtures should not normally construct malformed MIR. |
| `E_NESTING_TOO_DEEP` | Parser recursion guard. A focused stress fixture would be large and brittle; keep the guard documented until a compact generator-based fixture exists. |
| `E_NULLABLE_DYN_NARROW` | Nullable dynamic trait narrowing error. Existing dynamic trait fixtures cover nullable dispatch and forge cases; this coercion edge remains fixture debt. |
| `E_PRIVATE_IMPORT` | Cross-file module privacy diagnostic. Import diagnostics are integration-tested, but no stable negative fixture currently asserts this privacy edge. |
| `E_REPRESENTATION_CHECK_MISSING` | MIR verifier internal representation-proof diagnostic. Source fixtures should prove or reject via higher-level rules rather than synthesize missing verifier facts. |
| `E_TRAIT_UNKNOWN_METHOD` | Trait implementation provides an undeclared method. Existing trait reject fixtures cover missing and mismatched methods; this edge remains fixture debt. |
| `E_TRIVIAL_DROP_NOT_MOVE` | Attribute misuse for `#[trivial_drop]` on non-move structs. No focused attribute negative fixture exists yet. |
| `E_TYPE_ARG_REQUIRED` | Generic type argument inference failure. Generic fixtures cover arity and body precheck cases; this inference edge remains fixture debt. |
