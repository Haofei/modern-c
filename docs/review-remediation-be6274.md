# Remediation report for the `be6274b4` repository review

Date: 2026-07-25

Scope: the nine findings reported against
`be6274b48a6368947f1cc072115027edf5765553`.

Qualification environment: the repository `Dockerfile` and `docker-compose.yml`
development service (Ubuntu 24.04, Zig 0.16.0, Clang/LLVM 18). Host-only results
are not used as closure evidence.

## Result

| Finding | Resolution | Regression evidence |
|---|---|---|
| MC-01 move/borrow depth fail-open | Type queries now treat traversal-budget exhaustion as move/borrow carrying. Deep array and alias cases therefore reach an existing stable rejection instead of being classified copyable. | `src/sema_tests.zig`; compiler unit gate |
| MC-02 registry publication race | Registry publication has one registry-wide atomic-directory lock covering destination recheck, package commit, and index replacement. Installation has a package-local lock covering vendor and lockfile commit. Interrupted stages are removed by traps. | `pkg-registry-test` lock-contention and transaction tests |
| MC-03 unbounded LSP workspace reads | Workspace discovery resolves physical roots, rejects symlinks and non-regular files, uses `O_NOFOLLOW` plus `fstat`, enforces containment, and applies file-size, cumulative-byte, file-count, and elapsed-time budgets. | `lsp-test` regular/symlink/FIFO/oversize cases |
| MC-04 malformed LSP parameters | Known requests receive structural parameter validation. Invalid requests return JSON-RPC `-32602`; invalid notifications are ignored without terminating the server. | malformed hover followed by a successful workspace request |
| MC-05 incomplete private-name rewriting | The walker now exhaustively handles every declaration kind, declaration and method attributes, all type-bearing fields, enum values, contracts, and precise-assembly operands. Pattern-shadow allocation errors propagate instead of being ignored. | declaration-level array-length collision test and compiler unit gate |
| MC-06 incomplete monomorphization traversal | Every declaration kind is cloned through the substituting type/expression cloner. Generic uses in aliases, extern signatures, layouts, traits, impl records, enum values, and attributes are discovered; generated declaration attributes retain substitution. | alias-only and extern-only generic instance test |
| MC-07 hardlinked package output | Compilation writes a fresh temporary object in the verified output directory and atomically renames it over the final path. It never truncates an existing hardlinked inode. | outside-inode sentinel and inode-separation test |
| MC-08 symlinked package root | The manifest directory and containment checks consistently use the physical package root. | package build invoked through a symlinked root |
| MC-09 invalid LSP rename | Rename replacement text must match MC identifier syntax and must not be a keyword. | direct identifier tests and InvalidParams request validation |

## Security and scope notes

- Complexity exhaustion is deliberately conservative. It may reject an
  unusually deep safe type, but it cannot silently authorize a copy or stored
  borrow.
- Registry locks are local-filesystem transaction locks. They do not claim
  distributed locking, crash-recovery leases, or authenticated public-registry
  metadata.
- LSP scanning remains synchronous but has bounded work and cannot block on a
  FIFO/device admitted as a source. Open editor buffers remain controlled by the
  LSP client and are outside the unopened-workspace scan budget.
- MC remains a research prototype and does not gain general memory safety or a
  general borrow checker from these fixes.

## Required gates

The remediation is accepted only when the following pass inside the development
container:

```text
zig build test
zig build c-test llvm-test
zig build diagnostics-test
zig build lsp-test
zig build pkg-test pkg-registry-test
zig build readiness-ledger-test
python3 tools/test/contract-lint.py .
git diff --check
```

The broader `fast`/`m0` results, including any pre-existing platform skips or
backend divergences, must be reported separately rather than hidden by this
focused closure report.

## Qualification result

The final working tree passed the focused suite in the development container:

- compiler unit tests: 833/833;
- C fixtures: 166 accepted and 34 expected rejects;
- LLVM fixture gate;
- diagnostics, LSP, package, and registry gates;
- contract lint, diagnostic ownership, readiness ledger, and development-gate
  routing checks;
- Zig, Python, and shell syntax/format checks plus `git diff --check`.

`zig build fast` was also attempted in the container but is not a green
repository-wide gate at the reviewed baseline. A detached worktree at
`be6274b48a6368947f1cc072115027edf5765553`, using the same image, reproduced
the existing `mcfuzz/roundtrip` unsupported-emission/crash findings and the
`bad-diagnostics-test` primary-diagnostic mismatch. Other `fast` failures are
not reclassified as fixed or baseline-proven by this focused remediation.
