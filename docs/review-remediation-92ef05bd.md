# Remediation report for the `92ef05bd` repository review

Date: 2026-07-25

Scope: the fourteen findings reported against
`92ef05bd929c0fb1d1937119cf69fa8a09707630`.

Development and qualification environment: the repository Docker development
service (Ubuntu 24.04, Zig 0.16.0, Clang/LLVM 18). Host-only results are reported
separately and are not used as proof of portable compiler behavior.

## Result

| Finding | Resolution | Regression evidence |
|---|---|---|
| Registry checksum/copy inventory mismatch | Publication computes a length-delimited SHA-256 over every regular file that installation can copy. Installation copies exactly that authenticated inventory and rejects non-regular or unexpected entries. Newline-containing paths are unambiguous. | injected post-publication `evil.o`; malformed checksum matrix; `pkg-registry-test` |
| Workspace deadline excluded indexing | One monotonic deadline now covers discovery, reads, compiler invocations, result construction, and serialization estimates. Compiler calls receive only the remaining budget. Independent invocation, symbol-count, and result-byte caps apply. | sleeping fake-index regression; `lsp-test` |
| Malformed JSON-RPC terminated the server | Validation establishes JSON-RPC, method, ID, and parameter types before dispatch; `null` parameters are normalized and propagated. A final per-message exception boundary returns an internal error without ending the process. | non-string method, null params, malformed-then-valid session; `lsp-test` |
| Generic named-loop metadata | Specialization preserves `loop_label` as well as break/continue targets. | specialized labeled-loop unit test plus semantic check |
| Incomplete generic AST traversal | Generic dependency detection now visits every child-bearing expression, pattern, statement contract, and precise-assembly operand/type. Cloning deeply substitutes patterns, contract arguments, and precise assembly. Switches are exhaustive for the current AST variants. | nested call in array length and structural clone unit tests |
| Statement contract private rewrite | Private-name rewriting visits the statement-level contract attribute as well as its body. | cross-file collision whose only reference is a contract argument |
| Generated/user symbol collision | Generic specializations reject a collision with any source declaration using `E_GENERATED_NAME_COLLISION`. Private mangling allocates and reserves a unique spelling when its first generated candidate is occupied. | `Box__u32` and `LIMIT__mcp0` collision unit tests |
| Package output self-overwrite | Package outputs must be `.o`, cannot equal the entry or package manifest/lock, and cannot enter managed dependency or VCS metadata paths. Builds retain fresh-file-plus-rename output semantics. | entry and manifest overwrite tests; `pkg-test` |
| Publish package/index split commit | Immutable package directories are authoritative; the index is rebuilt from them as a cache. A package committed before index failure remains resolvable and installable, so no immutable-but-invisible state remains. Locks carry process ownership and stale owners are recovered. | injected post-package-commit failure; `pkg-registry-test` |
| Install vendor/lock split commit | Installation writes an owner/phase transaction record. A hard stop after the vendor commit is completed idempotently on the next invocation, keeping vendor and lock generations aligned. | injected `SIGKILL` recovery; `pkg-registry-test` |
| Native macOS job | The public failure was traced to the repository-wide `fast` gate: unit tests passed, while the existing floatbits C/LLVM differential corpus remained red. This remediation does not misclassify that unrelated backend debt as fixed. See qualification status below. | GitHub Actions job `89708099331` log; Docker focused gates |
| Documentation overclaim | LSP and readiness text now describe an end-to-end request deadline and explicit caps. Registry text describes the authenticated inventory and recoverable cache/generation protocol rather than claiming a two-rename atomic transaction. | docs/readiness checks |
| Workspace directory-swap race | Workspace files are opened relative to an already-open physical root; every intermediate directory and the final component use no-follow descriptor-relative opens where the host supports them. `fstat` remains the authority for regular-file and size admission. | symlink/FIFO/outside-root workspace regressions |
| Newline registry filenames | Registry hashing and copying use Python byte paths and length-delimited records instead of newline-delimited `find` pipelines. | registry inventory tests and shell syntax gate |

## Security and compatibility notes

- Registry metadata is local integrity metadata, not authenticated public
  repository metadata. A network registry still needs signed metadata and an
  independently trusted key policy.
- Descriptor-relative no-follow traversal is used when the host Python exposes
  the necessary `dir_fd` support. The fallback retains physical containment,
  final-component no-follow, `fstat`, and bounded reads.
- Compiler-generated-name collision rejection is intentional and deterministic.
  A future IR-level symbol identity would remove textual generated names
  entirely, but is not required to prevent silent misbinding now.
- MC remains a research prototype and these fixes do not add general memory
  safety or a general borrow checker.

## Required Docker gates

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

## Qualification status

The focused remediation gates above are the closure authority. The broader
`fast` and `m0` gates are reported separately. At the reviewed baseline,
`fast` is not green: the public native macOS job completed all compiler unit
tests and later failed in existing fuzz/backend differential work, including
194/300 `mcfuzz/floatbits` C-versus-LLVM divergences. The same class of broad
baseline failure was already documented in the prior remediation report.

The full 300-seed Docker parallel inventory was also attempted for this
follow-up. Its parallel phase completed in 303 seconds with 35/49 gates passing
and the same 14 gates failing as the public run. Serial contention filtering
reconfirmed `diff-backend` and `fuzz-trap` as real failures before the remaining
long serial retries were stopped; this report does not relabel the other twelve
parallel failures as passing.

Accordingly, this report closes the reviewed defects only. It does **not** claim
that commit `92ef05bd` or this follow-up is release-qualified until the
repository-wide `fast`/`m0` backend debt is resolved.
