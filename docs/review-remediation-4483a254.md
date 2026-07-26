# Review remediation for 4483a254

This remediation was performed directly on `master`. No branch was created.
Development and verification were run in the repository Docker environment until
Docker stopped responding during the second full `fast` run; host-only unit tests
were used only as supplemental evidence.

## Fixed

- Enforced user-page execute permissions consistently across AArch64, x86-64,
  and RISC-V page-table helpers. AArch64 now distinguishes EL0 execute from
  PXN, x86-64 enables NXE during boot and emits NX for non-executable pages, and
  the ELF loader demo checks executable text and non-executable data.
- Tightened ELF admission by rejecting `ET_DYN` until PIE/relocation support
  exists, parsing and validating `p_align`, checking offset/vaddr congruence,
  and carrying that validation into the loader planning path.
- Hardened kernel lifecycle/resource paths: rollback validation now rejects bad
  active/previous state combinations and `max_failures == 0`; policy terminal
  states cannot be revived by allow/throttle; supervision records parent
  generation; heap free rejects overlapping free intervals.
- Fixed C/LLVM backend parity issues found by the fuzz gates:
  contextual unsuffixed integer operands now use the target or peer operand type
  instead of silently narrowing comparisons; MIR switch subjects now infer the
  type of arithmetic/bitwise subjects such as `x % 3`; deeply grouped/binary MIR
  construction no longer recurses through the entire left spine.
- Fixed C emission defects: exact same-type comparison for C float literal
  targets no longer includes source spans, and `DmaBuf.as_slice()` C compound
  literal emission no longer emits an extra `}`.
- Marked the RISC-V `hart_id` typestate helper as `#[mc_abi]`, avoiding an
  accidental explicit C ABI check on a generic MC-only export.
- Updated qualification metadata and generated docs: diagnostics reference,
  std API docs, bad diagnostics golden output, diff-backend expected skips, and
  the spec emit sweep out-of-scope list for a pure sema move-place fixture.

## Docker verification completed

The following commands passed in Docker after the relevant fixes:

```text
zig build install
zig build test heap-test elf-test elf-loader-test llvm-elf-loader-test production-ops-test -j1
python3 tools/fuzz/mcfuzz.py run --oracle trapsite --trapping --count 300 --mcc zig-out/bin/mcc
bash tools/toolchain/diff-fuzz.sh zig-out/bin/mcc
bash tools/toolchain/diff-backend.sh zig-out/bin/mcc
python3 tools/toolchain/spec-emit-sweep.py zig-out/bin/mcc tests/spec
python3 tools/toolchain/diagnostics-reference.py --check
python3 tools/toolchain/std-api-docs.py --check
python3 tools/toolchain/bad-diagnostics-test.py --check --mcc zig-out/bin/mcc
```

The second full Docker run of `zig build fast -j1` did not complete because the
Docker daemon stopped responding after more than one hour. At the time it was
interrupted, the previously fixed gates already observed in the output included
bad diagnostics, numeric comptime matrix, mcfuzz robust/failclosed, and
path-remap. A later `docker compose run --rm dev true` also hung, confirming this
as an environment failure rather than a new compiler diagnostic.

Supplemental host-only verification:

```text
git diff --check
zig build test -j1
```

Host LLVM/Clang is Homebrew LLVM 22, not the qualified LLVM 18 toolchain, so host
results are not counted as Docker qualification evidence.

## Remaining limitations

- The heap fix rejects double/overlapping free-list intervals, but it is still
  not a full live-allocation ownership map. Partial frees of live allocations
  remain a production allocator design item.
- `diff-backend` still has 68 expected skips. The gate now records those skips
  explicitly and compares 105 fixtures, but the skipped fixtures remain backend
  coverage debt.
- The full `fast` gate should be rerun in a fresh Docker daemon before making a
  release qualification claim.
