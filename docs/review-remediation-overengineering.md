# Remediation report for over-engineering review

Baseline context: follow-up review after `0dcda556`.

Fix commit: this remediation patch.

## Closed in this remediation

### Scope/profile control made explicit

Added `docs/scope-control-plan.md` to separate production-blocking profiles from
experimental subsystems. The document captures the current project imbalance:
the product surface is broad while the compiler's typed semantic boundary is
still being consolidated.

The plan defines the following profiles:

- `compiler-subset`;
- `llvm-experimental`;
- `selfhost-experimental`;
- `kernel-qemu`;
- `production-kernel`;
- `developer-tools`.

This prevents LLVM, selfhost, kernel, Agent runtime, secure boot, advanced LSP,
and vendored runtime work from being implicitly treated as one production claim.

### Over-engineering risks added to the risk register

`docs/review-risk-register.yaml` now tracks the scope-control items surfaced by
the review:

- `SCOPE-PRODUCT-SURFACE`;
- `ARCH-HIR-AUTHORITY`;
- `BACKEND-LLVM-PROFILE`;
- `SELFHOST-PROFILE`;
- `GATE-MANIFEST`;
- `LSP-COMPILER-SERVICE`;
- `TCB-PROFILE-MINIMIZATION`.

These entries complement the existing open items for `CompilationSession`, typed
MIR, backend facts, exact-byte `VerifiedBundle`, capability mint, TCB CVE intake,
and real hardware qualification.

### Documentation map updated

`docs/README.md` now names the risk register and scope-control plan as active
sources of truth. This reduces the chance that historical readiness or
remediation documents are read as current production closure.

## Still open implementation work

This patch does not:

- remove backend-local semantic inference;
- demote LLVM build targets in `build.zig`;
- change selfhost gates;
- implement `CompilationSession`;
- introduce a typed MIR identity model;
- generate gates from a manifest;
- replace LSP subprocess orchestration with a compiler service;
- minimize vendored TCB by build profile.

Those are larger implementation tasks. The purpose of this patch is to make the
scope policy explicit before changing build behavior.

## Validation

Validated locally:

- `python3 tools/toolchain/diagnostics-reference.py --check`
- `python3 tools/toolchain/std-api-docs.py --check`
- `git diff --check`

Attempted:

- YAML schema smoke check for `docs/review-risk-register.yaml`; skipped because
  `PyYAML` is not installed in this environment.
