# Remediation report for review at `2aee2481`

Date: 2026-07-25

This report records the changes made in response to the architecture and TCB
review of `2aee2481beef414c9e20694e172e56db89978118`. Validation was performed
inside the repository's Docker development environment.

The review mixes concrete defects, architectural migrations, hardware
qualification, and governance work. This patch closes the bounded defects that
can be implemented and qualified without misrepresenting independent primitives
as an end-to-end security proof. The remaining multi-release work is listed
explicitly below.

## Closed in this patch

| Review area | Resolution | Evidence |
| --- | --- | --- |
| Backend authority | The registered backend interface now accepts a `VerifiedProgram`; construction runs the MIR verifier, and C/LLVM registered entry points consume the supplied typed MIR. Stateless backend context is nullable rather than `undefined`. | Zig unit suite; C fixture sweep; focused C/LLVM gates |
| Artifact integrity | File artifacts are written through a same-directory atomic temporary file and replace the destination only after a complete write. | Zig unit suite and CLI/C gates |
| Import open TOCTOU | Resolved imports are read through an opened authority-root directory using `resolve_beneath`, no final symlink following, and the same opened file descriptor that is read. | Zig unit suite and install-layout test |
| Arbitrary `fetch_user<T>` representation | Snapshot helpers are byte-only. External byte sequences must be decoded explicitly instead of being reinterpreted as arbitrary enums, optionals, pointers, or structs. | C/LLVM `uaccess-snapshot-test` and `uaccess-taint-test`; audit script update |
| ELF identity | ELF parsing validates object type, version, header size, and target machine. The loader requires an explicit machine and admitted user VA window; entry must lie in an executable load segment. | host `elf-test`; C/LLVM QEMU ELF-loader tests, including wrong-machine and non-executable-entry negatives |
| ELF resource transaction | The loader plans aggregate segment/page use before allocation, bounds total pages and segments, rejects invalid file/memory sizes, and rolls back payload mappings and frames on every later failure. | C/LLVM QEMU ELF-loader tests |
| Public ELF segment copy | `elf_load_segment` now rejects `filesz > memsz` before copying. | host `elf-test` |
| BearSSL ABI | MC no longer constructs BearSSL structs with hard-coded offsets or context sizes. A C shim owns the real types, validates pointer/length pairs, and performs the constant-time digest comparison. | C/LLVM RSA-2048/SHA-256 gates |
| Caller-forged signature status | The public `SignatureStatus.Valid` path and the kind-optional validation entry point were removed. Metadata validation always requires the expected kind and cannot accept a caller-supplied “verified” enum. | production-ops and bundle-fuzz gates |
| Misleading secure-boot evidence | The old signed-boot demo/gates were renamed to bundle-metadata gates. Documentation now states that RSA verification, metadata policy, and rollback are independent mechanisms and do not prove exact-byte secure boot. | C/LLVM bundle-metadata QEMU gates; dev-gates test |
| Rollback corrupt state | Slot indices are validated before subtraction/indexing; corrupt persistent state fails closed without a checked-arithmetic or bounds trap. Failure counters saturate. | production-ops test |
| Long-running counters | Watchdog comparisons use modular elapsed time; process ticks use `u64` with saturation; fair-cost accumulation is overflow-safe. | production-ops test |
| Contradictory agent state | Four independent lifecycle booleans were replaced by one `AgentLifecycle` enum. | production-ops test |
| Internal aggregate ABI declarations | Paging, ELF-loader, and uaccess functions returning internal `Result` values explicitly use `#[mc_abi]`; the external C ABI default-deny rule remains unchanged. | C/LLVM QEMU ELF-loader and uaccess tests |

## Partial mitigation

### Bounded heap metadata

The fixed 64-entry free-list still cannot represent arbitrary fragmentation.
The previous silent loss is now observable through a saturating
`dropped_free_bytes` counter, and a deterministic 65-hole regression exercises
the degradation path. This is an availability signal, not a replacement for a
buddy/slab allocator. Production policy must treat any nonzero counter as
allocator degradation.

### Verified MIR boundary

The registered backend seam is verifier-gated, but `VerifiedProgram` still
attaches the syntax module for source spelling and declaration metadata that MIR
does not yet own. Direct legacy lowering helpers also remain for tests and
migration. Closing the entire architectural workstream requires moving all
remaining code-generation facts into MIR and removing those legacy entry points.

### ELF transaction ownership

Payload leaf mappings and data frames are rolled back. Interior page-table
pages remain owned by the address space and are reclaimed when the address space
is destroyed. A future page-table transaction API can reclaim newly-created
interior tables immediately, but failed ELF loads no longer leak payload frames.

## Open architectural and qualification work

The following review items are not honestly closable by a bounded patch:

1. **Opaque exact-byte secure boot.** A private `VerifiedBundle` must bind
   canonical raw bytes, SHA-256, signature, key/policy decision, loader payload,
   and runtime identity. The loader must accept only that object. The current
   RSA and metadata gates remain independent by design.
2. **Compilation session migration.** `main.zig` still contains process-global
   invocation context. Replacing it requires threading an explicit
   `CompilationSession` through every command/pass and adding concurrent
   in-process compilation tests.
3. **Real module graph and separate compilation.** The loader still flattens
   source text. Per-module AST/facts/MIR, caching, dependency identities, and
   manifest-driven resolution are a multi-release compiler architecture change.
4. **God-module decomposition and streaming artifacts.** Splitting sema/MIR/LLVM
   and converting all emitters to an `ArtifactSink` requires staged refactors
   with invariant-preserving tests.
5. **Unified work budget.** Loader/parser/local evaluator limits remain separate;
   a compilation-wide CPU, memory, node, diagnostic, and artifact budget is open.
6. **SMP uaccess atomicity.** Byte-only decoding closes invalid
   representation construction. All-or-nothing copy semantics under concurrent
   unmap still require an address-space lock or bounce-buffer commit design.
7. **Production heap allocator.** Observable free-list exhaustion does not
   replace buddy/slab allocation.
8. **Third-party lifecycle governance, hermetic release images, machine-readable
   evidence, real-board/soak/power-failure qualification, and external audits**
   remain release-governance work.

These items remain release blockers where the corresponding production claim
depends on them.

## Docker verification

Passed:

```text
zig build test                              837/837
zig build c-test                            166 compile fixtures; 34 rejects
zig build elf-test
zig build elf-loader-test llvm-elf-loader-test
zig build production-ops-test
zig build bundle-fuzz-test
zig build bundle-metadata-test llvm-bundle-metadata-test
zig build rsa-verify-test llvm-rsa-verify-test
zig build uaccess-snapshot-test llvm-uaccess-snapshot-test
zig build uaccess-taint-test llvm-uaccess-taint-test
python3 tools/toolchain/dev-gates-test.py
bash tools/lib/host-harness.sh zig-out/bin/mcc heapfree-test
git diff --check
```

`zig build fast -j1` is not green. It reproduced pre-existing deterministic
fuzz failures, including:

* C backend `E_BACKEND_UNSUPPORTED` for generated grouped/binary expressions;
* C/LLVM differential output divergence;
* one-backend-traps and trapsite divergence.

The run was stopped after those existing failure classes were reproduced.
Accordingly, this patch does not claim repository-wide production
qualification, and release-readiness language must remain scoped to the focused
gates above.
