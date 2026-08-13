const std = @import("std");
const h = @import("helpers.zig");

// Tier aggregations: m0 (full), fast (host-only inner loop), c0/c1 (spec §L conformance).
// These look up the command steps the other modules registered, by name, via ctx.cmd().
pub fn register(ctx: *h.Ctx) void {
    const b = ctx.b;
    const riscv_qemu_validation = [_][]const u8{
        "smode-timer-test",
        "llvm-smode-timer-test",
        "smode-plic-test",
        "llvm-smode-plic-test",
        "smode-plic-multishot-test",
        "llvm-smode-plic-multishot-test",
        "blk-smode-test",
        "llvm-blk-smode-test",
        "net-smode-test",
        "llvm-net-smode-test",
        "blk-smode-irq-test",
        "llvm-blk-smode-irq-test",
        "net-smode-irq-test",
        "llvm-net-smode-irq-test",
        "net-smode-rx-irq-test",
        "llvm-net-smode-rx-irq-test",
        "visionfive2-resource-test",
        "llvm-visionfive2-resource-test",
    };

    // Positive CI anti-vacuity assertions for m0 are declared in
    // docs/gate-manifest.json. tools/ci/pass-gates.py verifies every manifest
    // assertion is still an m0 dependency, and CI uses that manifest-backed list
    // when grepping the m0 log and re-running the async QEMU gates in Docker.

    const riscv_qemu_validation_step = b.step("riscv-qemu-validation", "Run the RISC-V QEMU/OpenSBI validation surrogate for the selected real-board path");
    for (riscv_qemu_validation) |name| {
        riscv_qemu_validation_step.dependOn(ctx.cmd(name));
    }

    const m0_full_step = b.step("m0-full", "Run full M0 qualification matrix");
    // Fixture-contract lint guards the test corpus itself (reject EXPECT lines, sweep
    // OUT_OF_SCOPE soundness, host-tests.tsv well-formedness). It belongs in every
    // conformance tier, not only `fast`, so a contract regression can't slip into m0/c0/c1.
    m0_full_step.dependOn(ctx.cmd("test-lint"));
    m0_full_step.dependOn(ctx.cmd("bad-diagnostics-test"));
    m0_full_step.dependOn(ctx.cmd("abi-consistency-test"));
    m0_full_step.dependOn(ctx.cmd("arch-emit-test"));
    m0_full_step.dependOn(ctx.cmd("lowering-coverage-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("compilation-session-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("mir-identity-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("test"));
    m0_full_step.dependOn(ctx.cmd("c-test"));
    m0_full_step.dependOn(ctx.cmd("sweep"));
    m0_full_step.dependOn(ctx.cmd("sanitize"));
    // Coverage ratchets are part of the main qualification tier.
    m0_full_step.dependOn(ctx.cmd("lowering-coverage"));
    m0_full_step.dependOn(ctx.cmd("compiler-coverage"));
    m0_full_step.dependOn(ctx.cmd("diff-backend"));
    m0_full_step.dependOn(ctx.cmd("diff-fuzz"));
    m0_full_step.dependOn(ctx.cmd("move-fuzz"));
    m0_full_step.dependOn(ctx.cmd("fuzz"));
    m0_full_step.dependOn(ctx.cmd("fuzz-async"));
    m0_full_step.dependOn(ctx.cmd("fuzz-sanitize"));
    m0_full_step.dependOn(ctx.cmd("fuzz-asan"));
    m0_full_step.dependOn(ctx.cmd("fuzz-trap"));
    m0_full_step.dependOn(ctx.cmd("fuzz-trapsite"));
    m0_full_step.dependOn(ctx.cmd("fuzz-robust"));
    m0_full_step.dependOn(ctx.cmd("fuzz-failclosed"));
    m0_full_step.dependOn(ctx.cmd("fuzz-determinism"));
    m0_full_step.dependOn(ctx.cmd("fuzz-pipeline"));
    m0_full_step.dependOn(ctx.cmd("fuzz-artifacts"));
    m0_full_step.dependOn(ctx.cmd("fuzz-roundtrip"));
    m0_full_step.dependOn(ctx.cmd("fuzz-metamorphic"));
    m0_full_step.dependOn(ctx.cmd("fuzz-optlevel"));
    m0_full_step.dependOn(ctx.cmd("fuzz-floatbits"));
    m0_full_step.dependOn(ctx.cmd("fuzz-corpus"));
    m0_full_step.dependOn(ctx.cmd("fuzz-reference"));
    // LLVM backend gates: IR assembly, object lowering, spec sweep, broad
    // c_emit fixture sweeps, and host link/run smoke tests.
    m0_full_step.dependOn(ctx.cmd("llvm-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-obj-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-debug-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-sweep"));
    m0_full_step.dependOn(ctx.cmd("llvm-spec-obj-sweep"));
    m0_full_step.dependOn(ctx.cmd("llvm-c-sweep"));
    m0_full_step.dependOn(ctx.cmd("llvm-opt-sweep"));
    m0_full_step.dependOn(ctx.cmd("llvm-c-obj-sweep"));
    m0_full_step.dependOn(ctx.cmd("llvm-cc-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-move-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-runtime-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-std-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-toolchain-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-demo-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-kernel-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-hosted-demo-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-host-suite-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-qemu-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-trap-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-thread-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-sched-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-syscall-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-user-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-process-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-elf-run-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-uaccess-pt-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-elf-loader-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-uaccess-snapshot-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-uaccess-taint-test"));
    m0_full_step.dependOn(ctx.cmd("vararg-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-vararg-test"));
    m0_full_step.dependOn(ctx.cmd("cstr-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-cstr-test"));
    m0_full_step.dependOn(ctx.cmd("cnum-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-cnum-test"));
    m0_full_step.dependOn(ctx.cmd("stdio-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-stdio-test"));
    m0_full_step.dependOn(ctx.cmd("mem-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-mem-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-fs-syscall-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-exec-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-kmain-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-vm-switch-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-vmspace-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-vmctx-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-sched-vm-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-timeout-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-signal-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-ipc2-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-ipc-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-irq-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-cancel-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-pollmany-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-future-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-multi-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-blk-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-net-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-async-select-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-usched-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-privilege-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-cap-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-contain-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-cow-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-isolation-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-demand-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-mmap-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-paging-activate-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-rtc-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-backtrace-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-driver-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-preempt-test"));
    // llvm-ledger-test runs the LLVM-lowered unified resource ledger under QEMU.
    m0_full_step.dependOn(ctx.cmd("llvm-ledger-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-page-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-heap-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-paging-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-smp-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-smp-lock-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-ipi-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-virtio-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-udp-net-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-blk-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-blk-smode-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-smode-timer-test"));
    // smode-plic-test proves REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI;
    // the multishot variant proves the re-armed steady-state path (regression gate for the former
    // C-backend async-IRQ reset, fixed by #[align(4)] on naked trap vectors).
    m0_full_step.dependOn(ctx.cmd("llvm-smode-plic-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-smode-plic-multishot-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-blk-smode-irq-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-net-smode-irq-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-net-smode-rx-irq-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-net-smode-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-net-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-nic-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-e1000-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-net-rx-live-test"));

    // qemu-test is gated separately (needs a riscv cross-toolchain + QEMU); it
    // self-skips when those are absent, so it is safe to include in m0 too.
    m0_full_step.dependOn(ctx.cmd("qemu-test"));
    // cc-test exercises the mcc-cc toolchain driver (needs clang); self-skips
    // when clang is absent.
    m0_full_step.dependOn(ctx.cmd("cc-test"));
    // enum-raw-cmp-run-test compiles+runs a value-context `enum.raw() == N` compare on
    // both backends (G23; needs cc + clang).
    m0_full_step.dependOn(ctx.cmd("enum-raw-cmp-run-test"));
    // labeled-break-run-test compiles+runs labeled `break :L` / `continue :L`
    // targeting a named outer loop on both backends (G7; needs cc + clang).
    m0_full_step.dependOn(ctx.cmd("labeled-break-run-test"));
    // error-from-run-test compiles+runs `?` error coercion via an explicit
    // `#[error_from]` conversion on both backends (G8; needs cc + clang).
    m0_full_step.dependOn(ctx.cmd("error-from-run-test"));
    // std-test compiles and runs std/core through the toolchain (needs clang).
    m0_full_step.dependOn(ctx.cmd("std-test"));
    // import-test exercises the module system end-to-end (needs clang).
    m0_full_step.dependOn(ctx.cmd("import-test"));
    // diagnostics-test locks down import-aware file/line rendering and clean CLI failures.
    m0_full_step.dependOn(ctx.cmd("diagnostics-test"));
    // install-layout-test locks down installed std import fallback without broadening explicit imports.
    m0_full_step.dependOn(ctx.cmd("install-layout-test"));
    // diagnostics-reference-test keeps the generated E_* reference in sync with compiler sources.
    m0_full_step.dependOn(ctx.cmd("diagnostics-reference-test"));
    // diagnostic-code-inventory-test ensures every emitted E_* has fixture or allowlist ownership.
    m0_full_step.dependOn(ctx.cmd("diagnostic-code-inventory-test"));
    // move-unsupported-inventory-test keeps fail-closed move-array unsupported channels named and fixture-owned.
    m0_full_step.dependOn(ctx.cmd("move-unsupported-inventory-test"));
    // move-place-identity-inventory-test keeps alias assignment ownership checks typed-place based.
    m0_full_step.dependOn(ctx.cmd("move-place-identity-inventory-test"));
    // move-cfg-skeleton-inventory-test keeps the explicit move-CFG/worklist boundary anchored.
    m0_full_step.dependOn(ctx.cmd("move-cfg-skeleton-inventory-test"));
    // move-dynamic-place-policy-inventory-test keeps stable dynamic indexes distinct from unknown wildcards.
    m0_full_step.dependOn(ctx.cmd("move-dynamic-place-policy-inventory-test"));
    // move-pointer-pointee-boundary-inventory-test keeps pointer-pointee move-resource accept/reject policy explicit.
    m0_full_step.dependOn(ctx.cmd("move-pointer-pointee-boundary-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("move-projection-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("ownership-experimental-surface-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("kernel-contract-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("kernel-scope-inventory-test"));
    m0_full_step.dependOn(ctx.cmd("qmp-ordering-test"));
    m0_full_step.dependOn(ctx.cmd("numeric-comptime-matrix-test"));
    m0_full_step.dependOn(ctx.cmd("parallel-runner-test"));
    m0_full_step.dependOn(ctx.cmd("m0-timing-report-test"));
    // std-api-docs-test keeps the generated stdlib API index in sync with std/**/*.mc exports.
    m0_full_step.dependOn(ctx.cmd("std-api-docs-test"));
    // vendoring-test keeps third_party provenance and license docs present.
    m0_full_step.dependOn(ctx.cmd("vendoring-test"));
    // third-party-licenses-test keeps the aggregated license manifest complete.
    m0_full_step.dependOn(ctx.cmd("third-party-licenses-test"));
    // no-committed-private-keys-test keeps test/private key material out of the repo.
    m0_full_step.dependOn(ctx.cmd("no-committed-private-keys-test"));
    // profile-manifest-test keeps product/profile claims tied to known risks and gates.
    m0_full_step.dependOn(ctx.cmd("profile-manifest-test"));
    // gate-manifest-test pilots machine-readable gate ownership for compiler-core gates.
    m0_full_step.dependOn(ctx.cmd("gate-manifest-test"));
    // mcc-cli-test pins documented top-level help/version/usage behavior.
    m0_full_step.dependOn(ctx.cmd("mcc-cli-test"));
    // mcc-build-test validates the installed `mcc build` hosted executable driver.
    m0_full_step.dependOn(ctx.cmd("mcc-build-test"));
    // path-remap-test keeps generated C/source-map paths reproducible under temp build roots.
    m0_full_step.dependOn(ctx.cmd("path-remap-test"));
    // ci-pass-gates-test prevents CI's positive PASS assertions from drifting away from tiers.zig.
    m0_full_step.dependOn(ctx.cmd("ci-pass-gates-test"));
    // dev-gates-test keeps focused local gate routing cheap and conservative.
    m0_full_step.dependOn(ctx.cmd("dev-gates-test"));
    // mono-test exercises comptime-parameter monomorphization (needs clang).
    m0_full_step.dependOn(ctx.cmd("mono-test"));
    // reflect-test validates the comptime layout model against the C ABI.
    m0_full_step.dependOn(ctx.cmd("reflect-test"));
    // abi-test validates advanced packed/overlay/MMIO layout against the C ABI + LLVM.
    m0_full_step.dependOn(ctx.cmd("abi-test"));
    // opt-test validates the fact-gated MIR optimizer (const-index bounds-check elision).
    m0_full_step.dependOn(ctx.cmd("opt-test"));
    // opt-equiv-test validates the elided bounds check is behavior-preserving (C vs LLVM).
    m0_full_step.dependOn(ctx.cmd("opt-equiv-test"));
    // reproducible-build-test validates emitted C + LLVM text is byte-identical across two compiles.
    m0_full_step.dependOn(ctx.cmd("reproducible-build-test"));
    // safe-release-parity (D2.5): SAFE/RELEASE profiles agree functionally; RELEASE elides
    // only the optimizer-proven-dead checks SAFE keeps.
    m0_full_step.dependOn(ctx.cmd("safe-release-parity"));
    // comptime-fold-test validates comptime-only folds (byte strings, wrap/sat domains).
    m0_full_step.dependOn(ctx.cmd("comptime-fold-test"));
    // asm-targets-test validates per-architecture precise-asm register vocabularies.
    m0_full_step.dependOn(ctx.cmd("asm-targets-test"));
    // mcmap-test validates .mcmap stable IDs + object-symbol correlation on both backends.
    m0_full_step.dependOn(ctx.cmd("mcmap-test"));
    // fmt-test validates the formatter; mcc-symbols-test validates the symbol index.
    m0_full_step.dependOn(ctx.cmd("fmt-test"));
    m0_full_step.dependOn(ctx.cmd("mcc-symbols-test"));
    m0_full_step.dependOn(ctx.cmd("mcc-inspection-modules-test"));
    m0_full_step.dependOn(ctx.cmd("mcc-list-tests-modules-test"));
    // stack-test exercises the generic std/stack collection (needs clang).
    m0_full_step.dependOn(ctx.cmd("stack-test"));
    // vec-test exercises the generic heap-backed std/collections/dynarray Vec<T> (needs clang).
    m0_full_step.dependOn(ctx.cmd("vec-test"));
    // hashmap-test exercises the generic heap-backed std/collections/hashmap StrHashMap<V> (needs clang).
    m0_full_step.dependOn(ctx.cmd("hashmap-test"));
    // strbuf-test exercises the growable std/strbuf StrBuf over Vec<u8> (needs clang).
    m0_full_step.dependOn(ctx.cmd("strbuf-test"));
    // argv-test exercises hosted command-line argument access (std/hosted_args + shim; needs clang).
    m0_full_step.dependOn(ctx.cmd("argv-test"));
    // memstr-test exercises the allocation-free std/mem byte-slice string ops (needs clang).
    m0_full_step.dependOn(ctx.cmd("memstr-test"));
    // move-test exercises linear `move` handle erasure (needs clang).
    m0_full_step.dependOn(ctx.cmd("move-test"));
    // try-defer-test checks `defer` runs on the `?` error branch in both backends (needs clang).
    m0_full_step.dependOn(ctx.cmd("try-defer-test"));
    // sync-test exercises std/sync locks + linear guards (needs clang).
    m0_full_step.dependOn(ctx.cmd("sync-test"));
    // nic-test runs the demo NIC driver under QEMU (self-skips without QEMU).
    m0_full_step.dependOn(ctx.cmd("nic-test"));
    // virtio-test runs the real virtio-net driver under QEMU (self-skips without QEMU).
    m0_full_step.dependOn(ctx.cmd("virtio-test"));
    // blk-test runs the virtio-blk driver reading a sector under QEMU.
    m0_full_step.dependOn(ctx.cmd("blk-test"));
    m0_full_step.dependOn(ctx.cmd("blk-persist-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-blk-persist-test"));
    // blk-smode-test revalidates the same virtio-blk driver under REAL OpenSBI in S-mode.
    m0_full_step.dependOn(ctx.cmd("blk-smode-test"));
    // smode-timer-test proves REAL S-mode timer-interrupt delivery under OpenSBI (SBI TIME ext).
    m0_full_step.dependOn(ctx.cmd("smode-timer-test"));
    // smode-plic-test proves REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI;
    // the multishot variant proves the re-armed steady-state path on the C backend (regression
    // gate for the former async-IRQ reset).
    m0_full_step.dependOn(ctx.cmd("smode-plic-test"));
    m0_full_step.dependOn(ctx.cmd("smode-plic-multishot-test"));
    m0_full_step.dependOn(ctx.cmd("blk-smode-irq-test"));
    m0_full_step.dependOn(ctx.cmd("net-smode-irq-test"));
    m0_full_step.dependOn(ctx.cmd("net-smode-rx-irq-test"));
    m0_full_step.dependOn(ctx.cmd("net-smode-test"));
    // udp-net-test transmits a real UDP datagram over virtio-net (pcap-verified).
    m0_full_step.dependOn(ctx.cmd("udp-net-test"));
    // smp-test boots multiple harts synchronizing on a shared atomic under QEMU.
    m0_full_step.dependOn(ctx.cmd("smp-test"));
    // smp-lock-test contends a ticket spinlock across harts under QEMU.
    m0_full_step.dependOn(ctx.cmd("smp-lock-test"));
    // ipi-test sends a CLINT software interrupt between harts under QEMU.
    m0_full_step.dependOn(ctx.cmd("ipi-test"));
    // demo-test compile-checks the whole demo/ suite (needs clang).
    m0_full_step.dependOn(ctx.cmd("demo-test-strict"));
    // net-test runs the kernel virtio-net RX/TX ARP exchange under QEMU.
    m0_full_step.dependOn(ctx.cmd("net-test"));
    // kernel-test compile-checks kernel/ for riscv64 + typestate rejects.
    m0_full_step.dependOn(ctx.cmd("kernel-test-strict"));
    // page-test links + runs the physical frame allocator (needs clang).
    m0_full_step.dependOn(ctx.cmd("page-test"));
    // heap-test links + runs the kernel heap (needs clang).
    m0_full_step.dependOn(ctx.cmd("heap-test"));
    // redzone-test boots the D2.4 redzone+canary demo under QEMU (needs clang+qemu).
    m0_full_step.dependOn(ctx.cmd("redzone-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-redzone-test"));
    // ksan-test (D2.1): access-time UAF/OOB detection via KASAN shadow memory.
    m0_full_step.dependOn(ctx.cmd("ksan-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-ksan-test"));
    // kmsan-test (D2.2): access-time use-of-uninitialized-heap detection on the ksan shadow.
    m0_full_step.dependOn(ctx.cmd("kmsan-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-kmsan-test"));
    // kcsan-test (D2.3): data-race detection via a watchpoint on the shadow (csan profile).
    m0_full_step.dependOn(ctx.cmd("kcsan-test"));
    // elf-test links + runs the ELF64 parser (needs clang).
    m0_full_step.dependOn(ctx.cmd("elf-test"));
    // ramfs-test links + runs the in-memory filesystem (needs clang).
    m0_full_step.dependOn(ctx.cmd("ramfs-test"));
    // vfs-test links + runs the fd-table VFS over ramfs (needs clang).
    m0_full_step.dependOn(ctx.cmd("vfs-test"));
    // blockfs-test links + runs the block-backed file store (needs clang).
    m0_full_step.dependOn(ctx.cmd("blockfs-test"));
    // udp-test links + runs the UDP build/parse + checksum (needs clang).
    m0_full_step.dependOn(ctx.cmd("udp-test"));
    m0_full_step.dependOn(ctx.cmd("dns-parser-test"));
    // alloc-test links + runs the type-erased Allocator (needs clang).
    m0_full_step.dependOn(ctx.cmd("alloc-test"));
    m0_full_step.dependOn(ctx.cmd("arc-test"));
    m0_full_step.dependOn(ctx.cmd("constgen-test"));
    m0_full_step.dependOn(ctx.cmd("ipc2-test"));
    m0_full_step.dependOn(ctx.cmd("signal-test"));
    m0_full_step.dependOn(ctx.cmd("privilege-test"));
    m0_full_step.dependOn(ctx.cmd("timeout-test"));
    m0_full_step.dependOn(ctx.cmd("diskfs-test"));
    m0_full_step.dependOn(ctx.cmd("mmap-test"));
    m0_full_step.dependOn(ctx.cmd("demand-test"));
    m0_full_step.dependOn(ctx.cmd("isolation-test"));
    m0_full_step.dependOn(ctx.cmd("usched-test"));
    m0_full_step.dependOn(ctx.cmd("cow-test"));
    m0_full_step.dependOn(ctx.cmd("pipe-test"));
    m0_full_step.dependOn(ctx.cmd("bcache-test"));
    m0_full_step.dependOn(ctx.cmd("perm-test"));
    m0_full_step.dependOn(ctx.cmd("pgroup-test"));
    m0_full_step.dependOn(ctx.cmd("tty-test"));
    m0_full_step.dependOn(ctx.cmd("time-test"));
    m0_full_step.dependOn(ctx.cmd("vqfault-test"));
    m0_full_step.dependOn(ctx.cmd("wrap-test"));
    m0_full_step.dependOn(ctx.cmd("args-test"));
    m0_full_step.dependOn(ctx.cmd("libc-test"));
    // hosted-test runs the hosted-profile float I/O round-trip (needs clang+python3).
    m0_full_step.dependOn(ctx.cmd("hosted-test"));
    m0_full_step.dependOn(ctx.cmd("shell-test"));
    m0_full_step.dependOn(ctx.cmd("shell2-test"));
    m0_full_step.dependOn(ctx.cmd("vfsmount-test"));
    // treefs-test links + runs the hierarchical tree filesystem (needs clang); LLVM side via llvm-host-suite-test.
    m0_full_step.dependOn(ctx.cmd("treefs-test"));
    // showcase-test links + runs the language feature showcase (emit-c); LLVM side via llvm-host-suite-test.
    m0_full_step.dependOn(ctx.cmd("showcase-test"));
    // mc-test runs the native #[test] facility (process-isolated) on both backends.
    m0_full_step.dependOn(ctx.cmd("mc-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-mc-test"));
    // mod-visibility-test checks opt-in `pub` module boundaries on both backends.
    m0_full_step.dependOn(ctx.cmd("mod-visibility-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-mod-visibility-test"));
    // sort-test exercises std/sort on both backends.
    m0_full_step.dependOn(ctx.cmd("sort-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-sort-test"));
    m0_full_step.dependOn(ctx.cmd("fdspace-test"));
    m0_full_step.dependOn(ctx.cmd("snapshot-test"));
    m0_full_step.dependOn(ctx.cmd("waitqueue-test"));
    m0_full_step.dependOn(ctx.cmd("service-test"));
    m0_full_step.dependOn(ctx.cmd("plugin-test"));
    m0_full_step.dependOn(ctx.cmd("endpoint-test"));
    m0_full_step.dependOn(ctx.cmd("sched-difftest"));
    m0_full_step.dependOn(ctx.cmd("registry2-test"));
    m0_full_step.dependOn(ctx.cmd("info-test"));
    m0_full_step.dependOn(ctx.cmd("granttab-test"));
    m0_full_step.dependOn(ctx.cmd("x86-sched-test"));
    m0_full_step.dependOn(ctx.cmd("x86-qemu-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-sched-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-qemu-test"));
    m0_full_step.dependOn(ctx.cmd("x86-vm-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-vm-test"));
    m0_full_step.dependOn(ctx.cmd("x86-timer-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-timer-test"));
    m0_full_step.dependOn(ctx.cmd("x86-pci-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-pci-test"));
    m0_full_step.dependOn(ctx.cmd("x86-user-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-x86-user-test"));
    m0_full_step.dependOn(ctx.cmd("slotmap-test"));
    m0_full_step.dependOn(ctx.cmd("mask-test"));
    m0_full_step.dependOn(ctx.cmd("rights-test"));
    m0_full_step.dependOn(ctx.cmd("mmio-test"));
    m0_full_step.dependOn(ctx.cmd("synclock-test"));
    m0_full_step.dependOn(ctx.cmd("ipc-result-test"));
    m0_full_step.dependOn(ctx.cmd("arp-cache-test"));
    m0_full_step.dependOn(ctx.cmd("tlb-shootdown-test"));
    m0_full_step.dependOn(ctx.cmd("mutex-test"));
    m0_full_step.dependOn(ctx.cmd("mailbox-test"));
    m0_full_step.dependOn(ctx.cmd("tryelse-test"));
    m0_full_step.dependOn(ctx.cmd("byteview-test"));
    m0_full_step.dependOn(ctx.cmd("scan-test"));
    m0_full_step.dependOn(ctx.cmd("posix-test"));
    m0_full_step.dependOn(ctx.cmd("userland-test"));
    m0_full_step.dependOn(ctx.cmd("smprq-test"));
    m0_full_step.dependOn(ctx.cmd("rtc-test"));
    m0_full_step.dependOn(ctx.cmd("contain-test"));
    m0_full_step.dependOn(ctx.cmd("fdt-test"));
    m0_full_step.dependOn(ctx.cmd("fb-test"));
    m0_full_step.dependOn(ctx.cmd("dynlink-test"));
    m0_full_step.dependOn(ctx.cmd("aarch64-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-aarch64-test"));
    m0_full_step.dependOn(ctx.cmd("arm-vm-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-arm-vm-test"));
    m0_full_step.dependOn(ctx.cmd("arm-user-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-arm-user-test"));
    m0_full_step.dependOn(ctx.cmd("sbi-boot-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-sbi-boot-test"));
    m0_full_step.dependOn(ctx.cmd("smode-user-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-smode-user-test"));
    m0_full_step.dependOn(ctx.cmd("bootinfo-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-bootinfo-test"));
    m0_full_step.dependOn(ctx.cmd("uart-driver-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-uart-driver-test"));
    m0_full_step.dependOn(ctx.cmd("e1000-test"));
    m0_full_step.dependOn(ctx.cmd("grant-test"));
    m0_full_step.dependOn(ctx.cmd("ipc-test"));
    m0_full_step.dependOn(ctx.cmd("async-test"));
    m0_full_step.dependOn(ctx.cmd("async-irq-test"));
    m0_full_step.dependOn(ctx.cmd("async-cancel-test"));
    m0_full_step.dependOn(ctx.cmd("async-pollmany-test"));
    m0_full_step.dependOn(ctx.cmd("async-future-test"));
    m0_full_step.dependOn(ctx.cmd("async-multi-test"));
    m0_full_step.dependOn(ctx.cmd("async-blk-test"));
    m0_full_step.dependOn(ctx.cmd("async-net-test"));
    m0_full_step.dependOn(ctx.cmd("async-select-test"));
    m0_full_step.dependOn(ctx.cmd("cap-test"));
    m0_full_step.dependOn(ctx.cmd("arc-pkt-test"));
    m0_full_step.dependOn(ctx.cmd("arena-test"));
    m0_full_step.dependOn(ctx.cmd("genref-test"));
    m0_full_step.dependOn(ctx.cmd("owned-test"));
    m0_full_step.dependOn(ctx.cmd("net-arena-test"));
    m0_full_step.dependOn(ctx.cmd("dma-try-test"));
    m0_full_step.dependOn(ctx.cmd("pool-test"));
    // closure-test links + runs a bind() capturing closure (needs clang).
    m0_full_step.dependOn(ctx.cmd("closure-test"));
    // ring-test links + runs the generic in-place Ring<T> (needs clang).
    m0_full_step.dependOn(ctx.cmd("ring-test"));
    // trace-test links + runs the trace ring buffer (needs clang).
    m0_full_step.dependOn(ctx.cmd("trace-test"));
    // log-test links + runs the leveled tracepoint logger (needs clang).
    m0_full_step.dependOn(ctx.cmd("log-test"));
    // tcp-test links + runs the TCP build/parse + checksum (needs clang).
    m0_full_step.dependOn(ctx.cmd("tcp-test"));
    // tcp-conn-test links + runs the TCP connection state machine (needs clang).
    m0_full_step.dependOn(ctx.cmd("tcp-conn-test"));
    // tcp-window-test links + runs the TCP window/data-plane bookkeeping (needs clang).
    m0_full_step.dependOn(ctx.cmd("tcp-window-test"));
    // tcp-reasm-test links + runs TCP reassembly + go-back-N retransmit (needs clang).
    m0_full_step.dependOn(ctx.cmd("tcp-reasm-test"));
    // tcp-rtx-test links + runs the TCP retransmit timer (needs clang).
    m0_full_step.dependOn(ctx.cmd("tcp-rtx-test"));
    // symbols-test links + runs the symbol table / address symbolizer (needs clang).
    m0_full_step.dependOn(ctx.cmd("symbols-test"));
    // socket-test links + runs the UDP socket bind/deliver/recv layer (needs clang).
    m0_full_step.dependOn(ctx.cmd("socket-test"));
    // net-rx-test links + runs the RX demux path (frame -> socket_deliver) (needs clang).
    m0_full_step.dependOn(ctx.cmd("net-rx-test"));
    // net-fuzz-test fuzzes the RX parser with random frames (needs clang).
    m0_full_step.dependOn(ctx.cmd("net-fuzz-test"));
    // parser-fuzz-test (P1) fuzzes the DNS+TCP parsers with malformed/truncated bytes:
    // every parse is total over its finite buffer — no over-read, garbage rejected (clang).
    m0_full_step.dependOn(ctx.cmd("parser-fuzz-test"));
    // net-rx-live-test routes a real virtio-net RX frame through net_rx_deliver under QEMU.
    m0_full_step.dependOn(ctx.cmd("net-rx-live-test"));
    // backtrace-test walks the frame-pointer chain + symbolizes under QEMU.
    m0_full_step.dependOn(ctx.cmd("backtrace-test"));
    // paging-test links + runs the Sv39 page-table map/translate (needs clang).
    m0_full_step.dependOn(ctx.cmd("paging-test"));
    // fnptr-test links + runs function-pointer dispatch (needs clang).
    m0_full_step.dependOn(ctx.cmd("fnptr-test"));
    // trap-test runs the typed-CPU trap/timer interrupt path under QEMU.
    m0_full_step.dependOn(ctx.cmd("trap-test"));
    // thread-test runs cooperative context switching under QEMU.
    m0_full_step.dependOn(ctx.cmd("thread-test"));
    // sched-test runs the round-robin scheduler under QEMU.
    m0_full_step.dependOn(ctx.cmd("sched-test"));
    // preempt-test runs the timer-driven preemptive scheduler under QEMU.
    m0_full_step.dependOn(ctx.cmd("preempt-test"));
    // ledger-test runs the unified resource ledger (charge/release + overflow-edge) under QEMU.
    m0_full_step.dependOn(ctx.cmd("ledger-test"));
    // syscall-test runs the ecall syscall dispatch skeleton under QEMU.
    m0_full_step.dependOn(ctx.cmd("syscall-test"));
    // user-test runs the M->U privilege drop + user-mode syscalls under QEMU.
    m0_full_step.dependOn(ctx.cmd("user-test"));
    // process-test runs process lifecycle (spawn/run/exit) under QEMU.
    m0_full_step.dependOn(ctx.cmd("process-test"));
    // elf-run-test loads an ELF64 and runs it in U-mode under QEMU.
    m0_full_step.dependOn(ctx.cmd("elf-run-test"));
    // The uaccess demos run under QEMU (they import riscv paging.mc, so they can't run on the host suite).
    m0_full_step.dependOn(ctx.cmd("uaccess-pt-test"));
    m0_full_step.dependOn(ctx.cmd("elf-loader-test"));
    m0_full_step.dependOn(ctx.cmd("uaccess-snapshot-test"));
    m0_full_step.dependOn(ctx.cmd("uaccess-taint-test"));
    // driver-test runs the char-device driver framework (vtable dispatch) under QEMU.
    m0_full_step.dependOn(ctx.cmd("driver-test"));
    // fs-syscall-test runs U-mode file syscalls over the VFS under QEMU.
    m0_full_step.dependOn(ctx.cmd("fs-syscall-test"));
    // exec-test runs sys_exec: a U-mode program loads + runs another ELF under QEMU.
    m0_full_step.dependOn(ctx.cmd("exec-test"));
    // paging-activate-test activates Sv39 satp in S-mode + reads a translated VA.
    m0_full_step.dependOn(ctx.cmd("paging-activate-test"));
    // kmain-test boots one integrated kernel image (heap+console+log+VFS+scheduler).
    m0_full_step.dependOn(ctx.cmd("kmain-test"));
    // fault-isolation-test boots the F1 keystone: a real agent trap is CONTAINED (faulting agent
    // killed+reclaimed via the death path, kernel + other agents survive) under QEMU.
    m0_full_step.dependOn(ctx.cmd("fault-isolation-test"));
    m0_full_step.dependOn(ctx.cmd("llvm-fault-isolation-test"));
    // vm-switch-test switches satp between two address spaces (per-process VM).
    m0_full_step.dependOn(ctx.cmd("vm-switch-test"));
    // vmspace-test switches satp per process slot (per-process page tables).
    m0_full_step.dependOn(ctx.cmd("vmspace-test"));
    // vmctx-test: a context switch that swaps satp per thread (address space in the switch).
    m0_full_step.dependOn(ctx.cmd("vmctx-test"));
    // sched-vm-test: the scheduler switches per-process address spaces (proc_yield_vm).
    m0_full_step.dependOn(ctx.cmd("sched-vm-test"));

    // fast: the inner-loop gate for deterministic host-only confidence. It
    // covers the spec/unit harness, emit-C sweep, C-vs-LLVM differential, and
    // static inventory checks, while leaving fuzz, QEMU, and env-fragile LLVM/
    // sanitizer sweeps to m0-full/nightly/release profiles. For process-level
    // parallelism without nested-worker oversubscription, use
    // `tools/fast-parallel.sh`.
    const core_dev_step = b.step("core-dev", "Fast compiler-core development loop: cleanup/MIR authority, C sweep, LLVM smoke, and inventories");
    core_dev_step.dependOn(ctx.cmd("cleanup-fast"));
    core_dev_step.dependOn(ctx.cmd("c-test"));
    core_dev_step.dependOn(ctx.cmd("llvm-test"));
    core_dev_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    core_dev_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    core_dev_step.dependOn(ctx.cmd("mir-identity-inventory-test"));

    const ownership_cleanup_dev_step = b.step("ownership-cleanup-dev", "Fast ownership cleanup authority loop: MIR cleanup shard and semantic/MIR inventories");
    ownership_cleanup_dev_step.dependOn(ctx.cmd("test-shard-mir-cleanup"));
    ownership_cleanup_dev_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    ownership_cleanup_dev_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    ownership_cleanup_dev_step.dependOn(ctx.cmd("mir-identity-inventory-test"));

    const ownership_backend_dev_step = b.step("ownership-backend-dev", "Ownership cleanup backend loop: MIR cleanup shard, C/LLVM lowering shards, and inventories");
    ownership_backend_dev_step.dependOn(ctx.cmd("test-shard-mir-cleanup"));
    ownership_backend_dev_step.dependOn(ctx.cmd("test-shard-lower-c"));
    ownership_backend_dev_step.dependOn(ctx.cmd("test-shard-lower-llvm"));
    ownership_backend_dev_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    ownership_backend_dev_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    ownership_backend_dev_step.dependOn(ctx.cmd("mir-identity-inventory-test"));

    const m0_step = b.step("m0", "Run core M0 compiler qualification gates");
    // Keep the default M0 tier focused on deterministic compiler-core confidence.
    // The former exhaustive matrix remains available as `m0-full` for release/nightly qualification.
    m0_step.dependOn(ctx.cmd("test-lint"));
    m0_step.dependOn(ctx.cmd("bad-diagnostics-test"));
    m0_step.dependOn(ctx.cmd("diagnostics-reference-test"));
    m0_step.dependOn(ctx.cmd("diagnostic-code-inventory-test"));
    m0_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    m0_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    m0_step.dependOn(ctx.cmd("compilation-session-inventory-test"));
    m0_step.dependOn(ctx.cmd("mir-identity-inventory-test"));
    m0_step.dependOn(ctx.cmd("gate-manifest-test"));
    m0_step.dependOn(ctx.cmd("ci-pass-gates-test"));
    m0_step.dependOn(ctx.cmd("dev-gates-test"));
    m0_step.dependOn(ctx.cmd("test-spec"));
    // The 166-fixture C backend compile sweep is the largest default-m0 cost.
    // Keep it in fast/c0/m0-full; m0 keeps narrower C smoke coverage through
    // mcc-build, mcmap, package, CLI, and generated-reference gates.
    m0_step.dependOn(ctx.cmd("mcc-cli-test"));
    m0_step.dependOn(ctx.cmd("mcc-build-test"));
    m0_step.dependOn(ctx.cmd("path-remap-test"));
    m0_step.dependOn(ctx.cmd("mcmap-test"));
    m0_step.dependOn(ctx.cmd("profile-manifest-test"));
    m0_step.dependOn(ctx.cmd("ownership-experimental-surface-inventory-test"));
    m0_step.dependOn(ctx.cmd("kernel-scope-inventory-test"));
    m0_step.dependOn(ctx.cmd("std-api-docs-test"));
    m0_step.dependOn(ctx.cmd("vendoring-test"));
    m0_step.dependOn(ctx.cmd("third-party-licenses-test"));
    m0_step.dependOn(ctx.cmd("no-committed-private-keys-test"));

    const fast_step = b.step("fast", "Inner-loop gate: host-only unit + spec-coverage tests, emit-C sweep, and C/LLVM differential — no fuzz or QEMU");
    fast_step.dependOn(ctx.cmd("test-spec"));
    fast_step.dependOn(ctx.cmd("test-lint"));
    fast_step.dependOn(ctx.cmd("bad-diagnostics-test"));
    fast_step.dependOn(ctx.cmd("install-layout-test"));
    fast_step.dependOn(ctx.cmd("diagnostics-reference-test"));
    fast_step.dependOn(ctx.cmd("diagnostic-code-inventory-test"));
    fast_step.dependOn(ctx.cmd("lowering-coverage-inventory-test"));
    fast_step.dependOn(ctx.cmd("semantic-facts-inventory-test"));
    fast_step.dependOn(ctx.cmd("architecture-boundary-inventory-test"));
    fast_step.dependOn(ctx.cmd("compilation-session-inventory-test"));
    fast_step.dependOn(ctx.cmd("mir-identity-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-unsupported-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-place-identity-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-cfg-skeleton-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-dynamic-place-policy-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-pointer-pointee-boundary-inventory-test"));
    fast_step.dependOn(ctx.cmd("move-projection-inventory-test"));
    fast_step.dependOn(ctx.cmd("ownership-experimental-surface-inventory-test"));
    fast_step.dependOn(ctx.cmd("kernel-contract-inventory-test"));
    fast_step.dependOn(ctx.cmd("kernel-scope-inventory-test"));
    fast_step.dependOn(ctx.cmd("qmp-ordering-test"));
    fast_step.dependOn(ctx.cmd("numeric-comptime-matrix-test"));
    fast_step.dependOn(ctx.cmd("parallel-runner-test"));
    fast_step.dependOn(ctx.cmd("std-api-docs-test"));
    fast_step.dependOn(ctx.cmd("vendoring-test"));
    fast_step.dependOn(ctx.cmd("third-party-licenses-test"));
    fast_step.dependOn(ctx.cmd("no-committed-private-keys-test"));
    fast_step.dependOn(ctx.cmd("profile-manifest-test"));
    fast_step.dependOn(ctx.cmd("gate-manifest-test"));
    fast_step.dependOn(ctx.cmd("mcc-cli-test"));
    fast_step.dependOn(ctx.cmd("mcc-build-test"));
    fast_step.dependOn(ctx.cmd("path-remap-test"));
    fast_step.dependOn(ctx.cmd("ci-pass-gates-test"));
    fast_step.dependOn(ctx.cmd("dev-gates-test"));
    fast_step.dependOn(ctx.cmd("c-test"));
    fast_step.dependOn(ctx.cmd("sweep"));
    fast_step.dependOn(ctx.cmd("diff-backend"));

    // Spec §L conformance-level tiers: subsets of the full m0 gate aligned to the
    // staged C-backend profiles, so a contributor can validate the level they touch.
    //   c0 (§L.1 baseline trustworthy backend): the core language surface — the
    //     fixture/unit harness (including the spec-section coverage gate), the spec
    //     emit-C sweep, and the demo driver lowering.
    //   c1 (§L.2 kernel backend profile): c0 plus the kernel suite, whose modules
    //     exercise the C1 additions — full typed MMIO, typed DMA, linear move
    //     checking, and advanced address-space lowering.
    // (§L.3 MC-C2 is intentionally beyond this repo's backend finish line, so it is
    // not gated here.)
    const c0_step = b.step("c0", "Spec §L.1 MC-C0 baseline-language gates: fixtures + spec coverage, emit-C sweep, demo lowering");
    c0_step.dependOn(ctx.cmd("test-lint")); // contract lint guards the corpus; c1 inherits it
    c0_step.dependOn(ctx.cmd("bad-diagnostics-test")); // golden wording for reject diagnostics
    c0_step.dependOn(ctx.cmd("diagnostics-reference-test")); // generated diagnostic-code reference stays current
    c0_step.dependOn(ctx.cmd("diagnostic-code-inventory-test")); // emitted diagnostics stay fixture-owned or documented
    c0_step.dependOn(ctx.cmd("lowering-coverage-inventory-test")); // split backend coverage ratchet stays pointed at production files
    c0_step.dependOn(ctx.cmd("semantic-facts-inventory-test")); // backend semantic authority stays registered and anchored
    c0_step.dependOn(ctx.cmd("architecture-boundary-inventory-test")); // backend syntax escapes and deleted cleanup state stay ratcheted
    c0_step.dependOn(ctx.cmd("compilation-session-inventory-test")); // request-scoped compiler context stays anchored
    c0_step.dependOn(ctx.cmd("mir-identity-inventory-test")); // typed MIR identity migration seed stays anchored
    c0_step.dependOn(ctx.cmd("move-unsupported-inventory-test")); // fail-closed move-array unsupported channels stay named and covered
    c0_step.dependOn(ctx.cmd("move-place-identity-inventory-test")); // alias assignment ownership checks stay typed-place based
    c0_step.dependOn(ctx.cmd("move-cfg-skeleton-inventory-test")); // explicit move-CFG/worklist boundary stays anchored
    c0_step.dependOn(ctx.cmd("move-dynamic-place-policy-inventory-test")); // stable dynamic indexes stay distinct from unknown wildcards
    c0_step.dependOn(ctx.cmd("move-pointer-pointee-boundary-inventory-test")); // pointer-pointee move-resource accept/reject policy stays explicit
    c0_step.dependOn(ctx.cmd("move-projection-inventory-test")); // projection admission map stays explicit
    c0_step.dependOn(ctx.cmd("ownership-experimental-surface-inventory-test")); // advanced ownership forms stay outside the stable v0 surface
    c0_step.dependOn(ctx.cmd("kernel-contract-inventory-test")); // bounded region/effect/FFI profile stays explicit
    c0_step.dependOn(ctx.cmd("kernel-scope-inventory-test")); // kernel remains a language-validation workload, not a product roadmap
    c0_step.dependOn(ctx.cmd("qmp-ordering-test")); // lifecycle qualification transport preserves asynchronous events
    c0_step.dependOn(ctx.cmd("numeric-comptime-matrix-test")); // every fixed-width arithmetic domain keeps its comptime semantics
    c0_step.dependOn(ctx.cmd("parallel-runner-test")); // full-tier acceleration retains the exact gate inventory and CPU budget
    c0_step.dependOn(ctx.cmd("std-api-docs-test")); // generated stdlib API index stays current
    c0_step.dependOn(ctx.cmd("vendoring-test")); // third_party provenance and license process stay documented
    c0_step.dependOn(ctx.cmd("third-party-licenses-test")); // aggregated third-party license manifest stays complete
    c0_step.dependOn(ctx.cmd("no-committed-private-keys-test")); // test/private key material stays generated, not committed
    c0_step.dependOn(ctx.cmd("profile-manifest-test")); // product/profile claims stay tied to known risks and gates
    c0_step.dependOn(ctx.cmd("gate-manifest-test")); // gate manifest stays tied to build tiers
    c0_step.dependOn(ctx.cmd("mcc-cli-test")); // top-level CLI help/version/usage behavior stays documented
    c0_step.dependOn(ctx.cmd("mcc-build-test")); // installed mcc build hosted executable driver remains functional
    c0_step.dependOn(ctx.cmd("path-remap-test")); // generated C/source-map source paths can be remapped for reproducibility
    c0_step.dependOn(ctx.cmd("ci-pass-gates-test")); // CI anti-vacuity assertions stay manifest-backed and tier-checked.
    c0_step.dependOn(ctx.cmd("test"));
    c0_step.dependOn(ctx.cmd("c-test"));
    c0_step.dependOn(ctx.cmd("sweep"));
    // Strict variant: a missing riscv64 toolchain FAILS the conformance tier (the demo
    // lowering must actually run), rather than skipping and passing vacuously.
    c0_step.dependOn(ctx.cmd("demo-test-strict"));

    const c1_step = b.step("c1", "Spec §L.2 MC-C1 kernel-profile gates: c0 + kernel suite (MMIO, DMA, move checking, address-space lowering)");
    c1_step.dependOn(c0_step);
    c1_step.dependOn(ctx.cmd("kernel-test-strict")); // strict: skip-on-missing-riscv64 is a failure here
}
