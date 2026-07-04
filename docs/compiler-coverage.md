# Compiler Coverage

`zig build compiler-coverage` measures function-entry coverage for the compiler
front-end/semantics slice:

- `src/parser.zig`
- `src/sema*.zig`, excluding `*_tests.zig`
- `src/monomorphize.zig`
- `src/generic_precheck.zig`
- `src/async_lower.zig`

The gate is intentionally bounded. It reuses the lowering coverage mechanism:
`tools/toolchain/lowering-cov-instrument.py` injects `lower_cov.hit(...)` probes
into a temporary checkout, builds an instrumented `mcc`, runs deterministic
frontend-heavy corpora, then subtracts fired labels from the instrumented
function universe. This is function coverage only; it does not claim line or
branch coverage.

The ratchet lives in `tools/toolchain/compiler-coverage-baseline.tsv` and fails
when the source set or function universe shrinks, or when the uncovered function
count grows. Raw coverage artifacts are written to `zig-out/compiler-cov`,
including `uncovered_compiler.txt`.
