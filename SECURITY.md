# Security Policy

MC is a compiler and kernel research prototype. Do not treat the current `master`
branch or any `0.7.0-dev` snapshot as production hardened.

## Supported Versions

| Version | Security support |
|---|---|
| `master` / `0.7.0-dev` | Best-effort fixes only; no embargo or SLA. |
| Tagged releases | Not yet available. A release support policy must be published before the first production claim. |

## Reporting

Until a private advisory channel exists, report security issues by opening a GitHub
issue with a minimal reproducer and the exact `mcc --version` output. If the issue
requires private handling, ask for a private contact in the issue without posting
exploit details.

Useful report fields:

- host OS and architecture
- Zig, clang/LLVM, and QEMU versions when relevant
- the command that was run
- input files or a minimized reproducer
- expected outcome versus actual diagnostics, crash, hang, or emitted output

## Scope

Security-sensitive compiler issues include crashes or hangs on user input, silent
miscompiles, fail-open diagnostics, unsupported features accepted silently, and
incorrect emitted runtime checks. Kernel/appliance issues include violations of the
agent isolation, broker capability, resource accounting, audit, and hostile-input
boundaries described in `docs/threat-model.md` and `docs/security-review.md`.

Vendored third-party engines are part of the trusted computing base where linked.
Track upstream advisories for those projects until this repository has a formal CVE
intake and vendored-dependency update process.
