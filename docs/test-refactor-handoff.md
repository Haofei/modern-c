# Test-suite refactor — status & handoff

Companion to [test-architecture.md](test-architecture.md) (the taxonomy + the
fixture-contract invariant). This file tracks what the refactor has *done*, what
remains, and the proven fix patterns, so the remaining large/environment-bound work
can be picked up efficiently (ideally on a quiet host or CI).

## Done

All landed on `master`, each verified in Docker (`docker compose run --rm dev zig build <gate>`):

- **Fixture-contract architecture**: `tests/c_emit/bad/` reject corpus; `host-tests.tsv`
  manifest + shared `host-harness.sh`; `docs/test-architecture.md`; `contract-lint` (now
  in `fast`, `m0`, `c0`, `c1`).
- **~15 pre-existing red gates fixed** (the host-triple class, per-arch CFLAGS, irq_context
  MIR verifier gap, `zeroInitializer` C/LLVM parity, demo riscv pin, sweep `OUT_OF_SCOPE`
  soundness). See the per-gate detail in the git history for this refactor.
- **Host-independent spec sweep**: `spec-emit-sweep.py` pins `--target=x86_64-unknown-none
  -ffreestanding` (was host-dependent → broke `fast` on macOS/Mach-O).
- **Sound reject contract**: `check-generated-c.sh` / `kernel-test.sh` / `demo-test.sh` now
  require a *nonzero exit* before matching the diagnostic (was spoofable by a fixture that
  compiles and merely emits a symbol named like the code).
- **Strict conformance tiers**: `MC_REQUIRE_TARGET=1` makes a missing riscv64 toolchain a
  hard FAIL in `m0`/`c0`/`c1` (was a vacuous skip); standalone steps stay lenient.
- **Struct-mirror drift eliminated** across all 5 host-native logic drivers (paging/heap/
  page/std): the driver logic lives in MC behind a scalar entry; the C harness mirrors no
  MC struct. The `--stub-asm` emit flag (both backends) lets arch modules with inline asm
  build host-native.
- **Phase 4 (slice)**: one shared runner `tools/lib/host-mc-logic-test.sh` for those host
  MC-driver logic tests; per-test scripts are ~10-line wrappers.
- **Phase 7 (high-leverage portion)**: shared `kernel_boot_link_run` + 24 single-marker
  riscv64 boot gates migrated to it (see the Phase 7 entry under "Remaining work" for the
  principled boundary on what stays custom).
- **DRY**: shared `tools/toolchain/spec_sweep_lib.py` (sweep parser); `virtio-test` /
  `mcfuzz` flaky-timeout mitigations.

## QEMU long-tail — status

Methodology: these are real boots under `qemu-system-{riscv64,x86_64,aarch64}`. They split into
three reliability classes:

- **Deterministic** (compile/boot/IPC/FS/device logic) — load-independent; safe to gate.
- **Timing-sensitive** (TCG single-thread races, e.g. `virtio-test` TX-reap) — mitigated with
  bounded retry; can still need a quiet host for a clean first-pass.
- **Network-dependent** (dns/http/https) — hit the real internet; need connectivity + are slower.

**Swept GREEN this session — 42 gates across every group** (host load came down to ~5, so even
the flake-prone groups passed cleanly):
- core kernel: kmain/rtc/trap/sbi-boot/fdt-boot/fdt/bootinfo/uart-driver
- ipc: ipc/ipc2/signal/registry/registry2/timeout/endpoint/mailbox
- fs: ramfs/vfs/diskfs/blockfs/bcache/fdspace
- device/arch: driver/x86-timer/x86-pci/smode-timer/blk/blk-smode
- net: nic/net/net-smode + **dns/http-get/https-get** (real DNS resolution + HTTP + TLS to the
  real internet, pcap-captured)
- qjs: qjs-run/qjs-confined/qjs-agent
- multi-arch: arm-user/arm-vm/aarch64/x86-user
- agent: fault-probe/agent-confined

Not exhaustively swept (but none known-red): the deeper agent-containment / s-mode-agent / async
matrix and the remaining tcp/socket/server variants. `virtio-test` remains the one TCG timing
flake (bounded-retry mitigated; passed first-try this session). A full belt-and-suspenders pass
belongs on CI, but the long-tail is in good shape — not a backlog of reds.

## Remaining work

- **QEMU long-tail completion** — finish the net/TLS/qjs/arm sweep on a quiet host/CI. No code
  expected; just confirmation runs (+ bounded-retry for any TCG timing flake, the proven pattern).
- **Phase 4 (full)** — the broader runner consolidation. The manifest + `host-harness.sh`
  already drive 123 host-native rows; the ~419 `build.zig` steps / ~173 scripts beyond that are
  mostly QEMU boots that legitimately need their own harness. A full consolidation is a large,
  design-heavy refactor (gate-name preservation, per-test QEMU args, backend split) — scope it
  deliberately, slice by category (the host-MC-logic slice above is the template).
- **Phase 7 — QEMU-tier unification** — the high-leverage portion is **done**: a shared
  `kernel_boot_link_run` (in `kernel-boot-lib.sh`) collapses the link + boot + UART-dump +
  marker-grep + PASS/FAIL tail, and **all 24 cleanly-uniform single-marker riscv64 `-bios none`
  boot gates** now use it (cow/demand/mmap/paging-activate/contain/isolation/ipc2/privilege/
  alloc/backtrace/block-server/cnum/cstr/fs-server/registry/sched-vm/signal/stdio/timeout/
  usched/vararg/vm-switch/vmctx/vmspace — each verified ×c/llvm under QEMU).
  The **remaining ~70 boot scripts stay custom by design** — consolidating them would *lose
  assertions or diagnostics*, which is a regression, not a cleanup. Their breakdown:
  multi-marker field assertions (~37, e.g. bootinfo checks 7 BootInfo fields), networked
  (~25, need `-netdev`/`-device`/pcap), multi-arch/s-mode (~8, different emulator/`-m`/`-smp`),
  dynamic diagnostics (~4, e.g. rtc's EPOCH extraction). These are the irreducible per-test
  variation; the shared compile primitives (`kernel_boot_compile_*`) already factor out the
  common build. Any future extension (a marker-list / qemu-args-parameterized variant) should
  be added only when a *new* clean group appears that would otherwise duplicate it.

## Proven fix patterns (reuse these)

1. **Host-triple pin** — any `clang`/`llc` that *assembles* target-specific code (asm, section
   attrs, precise-asm) must pin a triple (`--target=`/`-mtriple=x86_64-unknown-none`), and for
   emit-c add `-ffreestanding` (kernel-profile C uses builtin headers). Host-native *portable*
   logic correctly uses the host target — don't over-pin.
2. **MC-driver, no C mirror** — a host logic test must not mirror an MC struct in C (it drifts
   silently). Put the logic in an `export fn …(…) -> u32` (0 = pass, nonzero = first-failed-check
   id); the C harness is trap stubs + `main`. Use `--stub-asm` for arch modules with inline asm.
3. **Sound reject** — assert a *nonzero exit* before grepping the diagnostic; never `|| true`
   then grep (spoofable).
4. **Strict-skip in tiers** — gate a skip behind `MC_REQUIRE_TARGET`-style env so conformance
   tiers fail rather than pass vacuously; dev runs stay lenient.
5. **Shared runner / parser** — extract the duplicated flow (compile→link→run; comment-aware
   fixture stripping) into one file; keep per-test config (OUT_OF_SCOPE, triples) local.
6. **Ground-truth subagent claims** — a worktree subagent's "behavior-preserving" / pass-fail
   report can be wrong (one gutted the sweep `OUT_OF_SCOPE` and misreported the breakage as
   pre-existing). Always re-verify the real gate on `master` before trusting it.
