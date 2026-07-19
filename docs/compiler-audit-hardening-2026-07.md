# Compiler Audit Hardening Tracker (2026-07)

This temporary tracker converts the audit of commit `5df7d566` into work that is
verified against current `master`. Delete this file only after every row is done
and its acceptance gate passes.

| ID | Priority | Status | Problem | Implementation | Acceptance gate |
|---|---|---|---|---|---|
| AH-01 | P0 | complete | Registry package names and versions can escape registry/vendor roots and drive recursive deletion. | Package identities are validated, managed roots are canonicalized, symlinked roots/components are rejected, and publish/install use root-local staging plus rename. | `zig build pkg-registry-test` covers traversal, malformed identities, and registry/vendor symlink escapes while preserving outside sentinels. |
| AH-02 | P0 | complete | A pinned lock version is used even when it no longer satisfies the manifest constraint. | `version_satisfies` now validates the pinned version directly and malformed constraints/lock entries fail closed. | `zig build pkg-registry-test` covers incompatible pins, malformed constraints, missing registry versions, and frozen drift. |
| AH-03 | P0 release | complete | Release publication did not run the complete qualification gate, bind all version sources, or keep assets immutable. | The release workflow binds `GITHUB_SHA`, source/binary versions, clean state, and a no-skip `m0`; existing releases are rejected and upload replacement is disabled. | `release-metadata-test`, package tests, and workflow assertions lock every invariant. |
| AH-04 | P1 | complete | CI could accumulate superseded runs and had no explicit job deadlines. | CI now cancels superseded ref runs, sets per-job deadlines and a pinned Zig cache, runs `fast` for PRs, and reserves full no-skip `m0` for pushes. | `release-metadata-test` checks concurrency, routing, cache pinning, and timeouts. |
| AH-05 | P1 | complete | The Zig source package excluded files required by the complete qualification surface. | `.paths` includes selfhost, vendored/license, editor, workflow, and release inputs; a fetched package is tested outside Git. | `zig build source-package-test` materializes the package and passes unit/release metadata gates without `.git`. |
| AH-06 | P1 | complete | LSP URI conversion, sibling temp files, subprocess lifetime, and workspace indexing were incomplete. | Standards-based file URIs, stdin overlays, hard timeouts, imported diagnostics, source-bearing symbol spans, and workspace discovery are implemented. | `zig build mcc-symbols-test lsp-test` covers encoded/unicode paths, read-only sources, timeout recovery, imported diagnostics, and cross-file navigation/rename. |
| AH-07 | P1 docs/architecture | complete | Public `verified backend/MIR` and `full language server` wording exceeded the qualified guarantees. | Public positioning now says differentially qualified backend subset and CLI-backed language server; typed MIR remains an explicit open architecture objective. | `release-metadata-test` rejects the former over-claims. |
| AH-08 | P1 docs | complete | Production-readiness prose mixed stale historical observations with current facts. | The single readiness document retains an explicit superseded historical snapshot while current LSP/release/security facts and evidence are updated. | `readiness-ledger-test` and `release-metadata-test` reject known stale statements. |
| AH-09 | P2 | complete | Docker/CI wording implied bit-for-bit exact apt tooling although apt microversions float. | Docker now states exactly which inputs are pinned and that apt microversions prevent bit-for-bit identity. | `release-metadata-test` locks the honest wording. |
| AH-10 | P1 process | complete | Security reports required a public issue before private contact. | `SECURITY.md` routes directly to GitHub private reporting with response/disclosure targets; repository Private Vulnerability Reporting is enabled and the external audit verifies it. | Metadata gate rejects public-first text; GitHub API and publication audit report PVR enabled. |

## Completion Rule

The tracker may be removed only when all ten rows are complete, focused tests pass,
`zig build test`, `zig build c-test`, and the locally available release/readiness
gates pass, `git diff --check` is clean, and any unavailable external qualification
is described by a deterministic repository-local gate rather than silently skipped.
