# Full Self-Host Ledger

This ledger tracks the pending full self-host project from `docs/self-host.md` §6. It is not a
completion claim. A row may say "green" only when the listed evidence was produced by the current
implementation and can be rerun from the recorded command.

## Status terms

| Term | Meaning |
|---|---|
| Not started | No checked-in implementation or harness exists for the phase. |
| In progress | Implementation exists but evidence is incomplete, weak, or failing. |
| Green | The phase's required proof command passes for the stated corpus. |
| Blocked | The same external blocker has repeated and no meaningful progress is possible without it. |

## Phase ledger

| Phase | Status | Corpus | Required evidence | Latest evidence |
|---|---|---|---|---|
| P0. Contract and harness | In progress | Tiny full-selfhost manifest: hosted C run, negative diagnostic, LLVM object run; subset Stage0/Stage1/Stage2 scaffold | `zig build full-selfhost-p0`; broader selector audit still required before full P0 is green | Initial harness slice PASS on 2026-07-03; true full self-hosting still NOT achieved. |
| P1. Production architecture in MC | Not started | Initial multi-file corpus | Parser/sema oracle diff | None. |
| P2. Full parser parity | Not started | `tests/spec/`, `std/`, selected `kernel/` | Parse oracle diff | None. |
| P3. Full sema/checker parity | Not started | Positive and negative spec/hardening corpus | Sema oracle diff and hardening gates | None. |
| P4. Monomorphization and generic lowering | Not started | Generic-heavy std/kernel fixtures | Generic corpus and backend diff | None. |
| P5. Typed lowering and optimizer inputs | Not started | Accepted corpus | HIR/MIR verifier and source-map tests | None. |
| P6. Full C backend | Not started | C emit/object/run/QEMU corpus | C sweeps and C side of `diff-backend` | None. |
| P7. Full LLVM backend | Not started | LLVM IR/object/run/QEMU corpus | LLVM test/sweep/object/debug/opt gates | None. |
| P8. Optimizer and equivalence | Not started | Optimizer corpus | `opt-test`, `opt-equiv-test`, fuzz equivalence | None. |
| P9. Driver, packages, and tools | Not started | Toolchain/package/registry corpus | Toolchain, package, registry, map, reproducible-build gates | None. |
| P10. Corpus widening and cutover | Not started | Full `m0` corpus | Stage2-selected `tools/m0-parallel.sh <jobs>` and serial `zig build m0` | None. |

## Evidence log

| Date | Phase | Command | Result | Notes |
|---|---|---|---|---|
| 2026-07-03 | P0 | `zig build --help` | PASS | Build graph parses and lists `full-selfhost-diff`, `full-selfhost-stage`, and `full-selfhost-p0`. Harness scripts still pending. |
| 2026-07-03 | P0 | `zig build full-selfhost-diff` | PASS | 3 manifest rows: hosted C run, `E_USE_BEFORE_INIT` negative diagnostic, LLVM object run. |
| 2026-07-03 | P0 | `zig build full-selfhost-stage` | PASS | Stage0/Stage1/Stage2 subset scaffold passed; Stage1/Stage2 emitted C byte-identical. |
| 2026-07-03 | P0 | `zig build full-selfhost-p0` | PASS | Aggregate P0 gate passed. This is a harness milestone, not true self-hosting. |
| 2026-07-03 | P0 | `MCC_UNDER_TEST=zig-out/bin/mcc zig build cc-test llvm-cc-test selfhost-bootstrap-test` | PASS | Existing driver and subset bootstrap gates honor the compiler selector. |
