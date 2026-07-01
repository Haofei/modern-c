const std = @import("std");
const h = @import("helpers.zig");

// QEMU kernel/arch boot tests, the host-driver link/run suite, and every other
// per-fixture gate. The bulk of the corpus.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "move-fuzz", "Generate move-resource programs; assert every resource is released once (live_count==0) on both backends", &.{ "bash", "tools/toolchain/move-fuzz.sh", "zig-out/bin/mcc" });

    // ABI consistency: the confined-agent syscall numbers in user/abi.mc are the single source
    // of truth; the C agent userspace (crt0/usys/app_traps) + agent dispatchers must hardcode the
    // same numbers. Pure source scan (no mcc), so it always runs and never silently skips.
    _ = h.addScriptTestOpts(ctx, "abi-consistency-test", "Check the C agent-ABI #defines (crt0/usys/app_traps + agent dispatchers) match user/abi.mc", &.{ "bash", "tools/check/abi-consistency-test.sh" }, .{ .install = false });

    // Arch-selection seam (R0b): emit-c the portable core modules under every --arch. Pure host
    // (no ld.lld/QEMU), so it catches active-import regressions the x86/ARM QEMU gates would miss
    // when their cross toolchain is absent. Depends on the installed mcc.
    _ = h.addScriptTest(ctx, "arch-emit-test", "emit-c the portable core modules (elf_loader/uaccess_pt/uaccess/mmap) under --arch=riscv64|x86_64|aarch64", &.{ "bash", "tools/check/arch-emit-test.sh" });

    _ = h.addScriptTest(ctx, "qemu-test", "Run the typed-MMIO program on emulated hardware under QEMU", &.{ "bash", "tools/arch/qemu-mmio-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qemu-test", "Run the LLVM-lowered typed-MMIO program under QEMU", &.{ "bash", "tools/arch/qemu-mmio-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "nulldyn-run-test", "Compile + RUN nullable trait objects (?*dyn) as native binaries on both backends (needs cc + clang)", &.{ "bash", "tools/exec/nullable-dyn-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "naked-run-test", "Compile + RUN a #[naked] function (no prologue/epilogue) as native binaries on both backends (needs cc + clang)", &.{ "bash", "tools/exec/naked-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "cc-test", "Compile an MC module to an object with mcc-cc, link, and run it", &.{ "bash", "tools/toolchain/mcc-cc-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-cc-test", "Compile an MC module to an object with mcc-llvm-cc, link, and run it", &.{ "bash", "tools/toolchain/mcc-llvm-cc-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "std-test", "Compile std/core, link it against a C driver, and run the checks", &.{ "bash", "tools/toolchain/std-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-std-test", "Compile std modules through LLVM, link them against a C driver, and run the checks", &.{ "bash", "tools/toolchain/llvm-std-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-toolchain-test", "Build, link, and run import, monomorphization, and reflection modules through LLVM", &.{ "bash", "tools/toolchain/llvm-toolchain-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "import-test", "Compile an import-merged module (sibling + std), link, and run it", &.{ "bash", "tools/toolchain/import-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "mono-test", "Compile a comptime-param type-generic module, link, and run the specialization", &.{ "bash", "tools/toolchain/mono-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "reflect-test", "Validate comptime sizeof/alignof folding against clang's C ABI", &.{ "bash", "tools/toolchain/reflect-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "abi-test", "Validate advanced packed/overlay/MMIO layout against clang's C ABI and the LLVM backend", &.{ "bash", "tools/toolchain/abi-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "opt-test", "Validate the fact-gated MIR optimizer: const-index bounds-check elision under --optimize", &.{ "bash", "tools/toolchain/opt-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "opt-equiv-test", "Validate the optimizer's elided bounds check is behavior-preserving: C vs LLVM, default vs --optimize", &.{ "bash", "tools/toolchain/opt-equiv-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "reproducible-build-test", "Validate emitted C + LLVM text is byte-identical across two compiles of a fixed input (build determinism)", &.{ "bash", "tools/toolchain/reproducible-build-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "comptime-fold-test", "Validate comptime-only folds (byte strings, wrap/sat arithmetic domains) evaluate correctly", &.{ "bash", "tools/toolchain/comptime-fold-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "asm-targets-test", "Validate per-architecture precise-asm register vocabularies (x86-64/RISC-V/AArch64)", &.{ "bash", "tools/toolchain/asm-targets-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "mcmap-test", "Validate .mcmap stable typed-AST/MIR IDs and object-symbol correlation (C + LLVM)", &.{ "bash", "tools/toolchain/mcmap-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fmt-test", "Validate `mcc fmt` is token-preserving + idempotent across the corpus, and --check semantics", &.{ "bash", "tools/toolchain/fmt-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "mcc-symbols-test", "Validate the `mcc symbols` index: refs resolve to their declarations", &.{ "bash", "tools/toolchain/mcc-symbols-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTestOpts(ctx, "editor-client-test", "Validate the VS Code editor client manifest/grammar/extension", &.{ "bash", "tools/toolchain/editor-client-test.sh" }, .{ .install = false });

    _ = h.addScriptTest(ctx, "lsp-test", "Drive the mc-lsp language server and assert it publishes mcc diagnostics with matching E_ codes", &.{ "python3", "tools/lsp/lsp-test.py", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "stack-test", "Build, link, and run the generic std/stack collection", &.{ "bash", "tools/toolchain/stack-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "pkg-test", "Build a package from its manifest with mcc-pkg, link, and run it", &.{ "bash", "tools/toolchain/pkg-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-pkg-test", "Build a package from its manifest through LLVM, link, and run it", &.{ "bash", "tools/toolchain/llvm-pkg-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "pkg-registry-test", "Registry publish/resolve/install + lockfile reproducibility for the package manager", &.{ "bash", "tools/toolchain/pkg-registry-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-demo-test", "Compile supported demo drivers through LLVM to objects", &.{ "bash", "tools/toolchain/llvm-demo-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-kernel-test", "Compile kernel modules through LLVM to target objects", &.{ "bash", "tools/toolchain/llvm-kernel-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-hosted-demo-test", "Compile the hosted demo through LLVM, link it, and run the stdin/stdout check", &.{ "bash", "tools/toolchain/llvm-hosted-demo-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-host-suite-test", "Compile host-driver manifest fixtures through LLVM, link them, and run them", &.{ "bash", "tools/toolchain/llvm-host-suite-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "move-test", "Build, link, and run a linear `move` handle through the toolchain", &.{ "bash", "tools/toolchain/move-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-move-test", "Build, link, and run a linear `move` handle through the LLVM toolchain", &.{ "bash", "tools/toolchain/llvm-move-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "try-defer-test", "Build, link, and run a `defer` before `?` through the C and LLVM backends (issue #3 regression)", &.{ "bash", "tools/toolchain/try-defer-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-runtime-test", "Build, link, and run imported generic, sync, and fn-pointer modules through the LLVM toolchain", &.{ "bash", "tools/toolchain/llvm-runtime-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "sync-test", "Build, link, and run a std/sync guarded critical section", &.{ "bash", "tools/toolchain/sync-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "nic-test", "Build and run the demo NIC driver (driver-library profile) under QEMU", &.{ "bash", "tools/net/nic-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-nic-test", "Build and run the LLVM-lowered demo NIC driver under QEMU", &.{ "bash", "tools/net/nic-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "virtio-test", "Build and run the real virtio-net driver against virtio-net-device under QEMU", &.{ "bash", "tools/net/virtio-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-virtio-test", "Build and run the LLVM-lowered virtio-net driver under QEMU", &.{ "bash", "tools/net/virtio-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-test", "Build and run the virtio-blk driver reading a sector under QEMU", &.{ "bash", "tools/fs/blk-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-test", "Build and run the LLVM-lowered virtio-blk driver under QEMU", &.{ "bash", "tools/fs/blk-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-persist-test", "Persist-across-reboot: a sentinel written to virtio-blk survives a second QEMU boot (durable storage)", &.{ "bash", "tools/fs/blk-persist-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-persist-test", "Persist-across-reboot (LLVM): virtio-blk write/read survives a real reboot under QEMU", &.{ "bash", "tools/fs/blk-persist-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-audit-persist-test", "Durable policy/audit: a block_persistent_audit policy checkpoint written to virtio-blk is field-verified after a second QEMU boot", &.{ "bash", "tools/fs/blk-audit-persist-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-audit-persist-test", "Durable policy/audit (LLVM): block-backed policy checkpoint over virtio-blk survives a real reboot under QEMU", &.{ "bash", "tools/fs/blk-audit-persist-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-audit-frame-persist-test", "Durable audit frame: a block_persistent_audit frame (drained IpcTrace provenance records) written to virtio-blk is field-verified after a second QEMU boot", &.{ "bash", "tools/fs/blk-audit-frame-persist-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-audit-frame-persist-test", "Durable audit frame (LLVM): block-backed audit frame over virtio-blk survives a real reboot under QEMU", &.{ "bash", "tools/fs/blk-audit-frame-persist-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-smode-test", "Build and run the virtio-blk driver reading a sector under REAL OpenSBI in S-mode", &.{ "bash", "tools/arch/blk-smode-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-smode-test", "Build and run the LLVM-lowered virtio-blk driver under REAL OpenSBI in S-mode", &.{ "bash", "tools/arch/blk-smode-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "blk-smode-irq-test", "Build and run async virtio-blk completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/blk-smode-irq-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-blk-smode-irq-test", "Build and run LLVM-lowered async virtio-blk completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/blk-smode-irq-test.sh", "zig-out/bin/mcc", "llvm" });

    // Item (4): REAL S-mode timer-interrupt delivery under OpenSBI — a flat
    // S-mode kernel arms the SBI TIME extension, enables S-mode timer
    // interrupts, and counts ticks in its trap handler (re-arming each tick,
    // wfi-parked). The RISC-V analogue of the x86 X4 LAPIC-timer proof.
    _ = h.addScriptTest(ctx, "smode-timer-test", "Build and run the flat S-mode kernel taking REAL S-mode timer interrupts under REAL OpenSBI", &.{ "bash", "tools/arch/smode-timer-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-timer-test", "Build and run the LLVM-lowered flat S-mode timer-interrupt kernel under REAL OpenSBI", &.{ "bash", "tools/arch/smode-timer-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "smode-plic-test", "Build and run the flat S-mode kernel taking REAL S-mode EXTERNAL interrupts through the PLIC under REAL OpenSBI", &.{ "bash", "tools/arch/smode-plic-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-plic-test", "Build and run the LLVM-lowered flat S-mode external-interrupt (PLIC) kernel under REAL OpenSBI", &.{ "bash", "tools/arch/smode-plic-test.sh", "zig-out/bin/mcc", "llvm" });

    // Steady-state (re-armed) variant: 3 discrete external interrupts. The regression gate for
    // the former C-backend S-mode async-IRQ reset (root cause: a 2-byte-aligned naked trap
    // vector → reserved stvec MODE; fixed by #[align(4)] / naked-defaults-to-4).
    _ = h.addScriptTest(ctx, "smode-plic-multishot-test", "Build and run the flat S-mode kernel taking 3 RE-ARMED REAL S-mode EXTERNAL interrupts via the PLIC under REAL OpenSBI", &.{ "bash", "tools/arch/smode-plic-multishot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-plic-multishot-test", "Build and run the LLVM-lowered re-armed S-mode external-interrupt (PLIC) kernel under REAL OpenSBI", &.{ "bash", "tools/arch/smode-plic-multishot-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "net-smode-test", "Build and run the virtio-net RX/TX ARP+ping exchange under REAL OpenSBI in S-mode", &.{ "bash", "tools/arch/net-smode-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-net-smode-test", "Build and run the LLVM-lowered virtio-net RX/TX exchange under REAL OpenSBI in S-mode", &.{ "bash", "tools/arch/net-smode-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "net-smode-irq-test", "Build and run async virtio-net TX completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/net-smode-irq-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-net-smode-irq-test", "Build and run LLVM-lowered async virtio-net TX completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/net-smode-irq-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "net-smode-rx-irq-test", "Build and run async virtio-net RX completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/net-smode-rx-irq-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-net-smode-rx-irq-test", "Build and run LLVM-lowered async virtio-net RX completion from a REAL S-mode PLIC interrupt under OpenSBI", &.{ "bash", "tools/arch/net-smode-rx-irq-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "udp-net-test", "Transmit a real UDP datagram over virtio-net under QEMU (pcap-verified)", &.{ "bash", "tools/net/udp-net-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-udp-net-test", "Transmit a real LLVM-lowered UDP datagram over virtio-net under QEMU", &.{ "bash", "tools/net/udp-net-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "smp-test", "Boot multiple harts and synchronize on a shared atomic under QEMU", &.{ "bash", "tools/proc/smp-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-smp-test", "Run LLVM-lowered SMP boot/sync under QEMU", &.{ "bash", "tools/proc/smp-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "smp-lock-test", "Contend a ticket spinlock across harts under QEMU (mutual exclusion)", &.{ "bash", "tools/proc/smp-lock-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-smp-lock-test", "Run LLVM-lowered SMP ticket-lock contention under QEMU", &.{ "bash", "tools/proc/smp-lock-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "ipi-test", "Send a CLINT software interrupt (IPI) between harts under QEMU", &.{ "bash", "tools/proc/ipi-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ipi-test", "Run LLVM-lowered inter-processor interrupt under QEMU", &.{ "bash", "tools/proc/ipi-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "demo-test", "Lower every demo/ driver to C and compile-check it", &.{ "bash", "tools/toolchain/demo-test.sh", "zig-out/bin/mcc" });

    // Conformance-tier variant: MC_REQUIRE_TARGET=1 makes a missing clang/riscv64 target a
    // hard FAILURE instead of a skip, so a conformance tier (m0/c0) cannot pass vacuously
    // when the riscv64 compile never ran. The standalone `demo-test` step stays lenient
    // (host dev without a riscv64 clang skips). Used by the tiers below, not exposed as a step.
    const demo_test_strict_cmd = h.addRawCmd(ctx, "demo-test-strict", &.{ "bash", "tools/toolchain/demo-test.sh", "zig-out/bin/mcc" });
    demo_test_strict_cmd.setEnvironmentVariable("MC_REQUIRE_TARGET", "1");
    // Expose as a public step too, so the parallel runner (tools/m0-parallel.sh) can invoke it alone.
    ctx.b.step("demo-test-strict", "Strict demo-test (riscv64 required; m0/c0 variant)").dependOn(&demo_test_strict_cmd.step);

    _ = h.addScriptTest(ctx, "net-test", "Run the kernel virtio-net RX/TX ARP exchange under QEMU", &.{ "bash", "tools/net/net-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-net-test", "Run the LLVM-lowered kernel virtio-net RX/TX ARP exchange under QEMU", &.{ "bash", "tools/net/net-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "kernel-test", "Compile-check kernel/ for riscv64 and verify typestate rejects", &.{ "bash", "tools/toolchain/kernel-test.sh", "zig-out/bin/mcc" });

    // Conformance-tier variant (see demo_test_strict_cmd): skip-on-missing-riscv64 becomes a
    // hard failure under MC_REQUIRE_TARGET=1 so m0/c1 cannot pass without the riscv64 compile.
    const kernel_test_strict_cmd = h.addRawCmd(ctx, "kernel-test-strict", &.{ "bash", "tools/toolchain/kernel-test.sh", "zig-out/bin/mcc" });
    kernel_test_strict_cmd.setEnvironmentVariable("MC_REQUIRE_TARGET", "1");
    // Expose as a public step too, so the parallel runner (tools/m0-parallel.sh) can invoke it alone.
    ctx.b.step("kernel-test-strict", "Strict kernel-test (riscv64 required; m0/c1 variant)").dependOn(&kernel_test_strict_cmd.step);

    _ = h.addScriptTest(ctx, "page-test", "Link + run the physical frame allocator (bump + free-list reclaim)", &.{ "bash", "tools/mem/page-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-page-test", "Link + run the LLVM-lowered physical frame allocator", &.{ "bash", "tools/mem/page-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "heap-test", "Link + run the kernel heap (aligned bump over a PhysRange)", &.{ "bash", "tools/mem/heap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-heap-test", "Link + run the LLVM-lowered kernel heap", &.{ "bash", "tools/mem/heap-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "elf-test", "Link + run the ELF64 parser (header + program headers, bounds-checked)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "elf-test" });

    _ = h.addScriptTest(ctx, "ramfs-test", "Link + run the in-memory filesystem (create/write/read/lookup)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ramfs-test" });

    _ = h.addScriptTest(ctx, "vfs-test", "Link + run the fd-table VFS over ramfs (open/read/write/close)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfs-test" });

    _ = h.addScriptTest(ctx, "blockfs-test", "Link + run the block-backed file store (block device vtable)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "blockfs-test" });

    _ = h.addScriptTest(ctx, "udp-test", "Link + run the UDP datagram build/parse + checksum", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "udp-test" });

    _ = h.addScriptTest(ctx, "dns-host-test", "Link + run the DNS A-query build + response parse (host fixture)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dns-test" });

    _ = h.addScriptTest(ctx, "arena-test", "move Arena: bump alloc, reset/reuse, destroy", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arena-test" });

    _ = h.addScriptTest(ctx, "genref-test", "generational handle: live resolve, stale-after-reset trap", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "genref-test" });

    _ = h.addScriptTest(ctx, "owned-test", "create<T> typed linear allocation, leak-checked", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "owned-test" });

    _ = h.addScriptTest(ctx, "net-arena-test", "RX scratch from a move Arena + generational handle", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-arena-test" });
    _ = h.addScriptTest(ctx, "dma-try-test", "std/dma typed fallible alloc: try_alloc -> err(OutOfMemory) on exhaustion", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dma-try-test" });

    _ = h.addScriptTest(ctx, "pool-test", "generational pool: use-after-free/double-free caught", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pool-test" });

    _ = h.addScriptTest(ctx, "block-server-test", "storage driver as a user-mode server (block read/write via IPC)", &.{ "bash", "tools/fs/block-server-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-block-server-test", "Run LLVM-lowered block server under QEMU", &.{ "bash", "tools/fs/block-server-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "fs-server-test", "filesystem as a user-mode server (open/write/read via IPC)", &.{ "bash", "tools/fs/fs-server-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-fs-server-test", "Run LLVM-lowered filesystem server under QEMU", &.{ "bash", "tools/fs/fs-server-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "net-server-test", "UDP socket layer as a user-mode server (bind/recv via IPC)", &.{ "bash", "tools/net/net-server-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-net-server-test", "Run LLVM-lowered network server under QEMU", &.{ "bash", "tools/net/net-server-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "constgen-test", "Const-generic Ring<T,N> at two capacities", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "constgen-test" });

    _ = h.addScriptTest(ctx, "pipe-test", "Pipe FIFO", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pipe-test" });

    _ = h.addScriptTest(ctx, "bcache-test", "Write-back block cache", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "bcache-test" });
    _ = h.addScriptTest(ctx, "perm-test", "POSIX permission checks", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "perm-test" });

    _ = h.addScriptTest(ctx, "pgroup-test", "Process groups + sessions", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pgroup-test" });
    _ = h.addScriptTest(ctx, "tty-test", "TTY line discipline", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tty-test" });

    _ = h.addScriptTest(ctx, "time-test", "std/time counter<u64> timeout arithmetic", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "time-test" });

    _ = h.addScriptTest(ctx, "vqfault-test", "virtqueue completion fault injection (bad id / not-in-flight / length overflow)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vqfault-test" });

    _ = h.addScriptTest(ctx, "wrap-test", "long-running ring-index/pool-generation wrap and pool exhaustion invariants", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "wrap-test" });

    _ = h.addScriptTest(ctx, "args-test", "argv/envp vector", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "args-test" });
    _ = h.addScriptTest(ctx, "libc-test", "Minimal libc core", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "libc-test" });

    // hosted-test runs the hosted-profile float round-trip end to end: MC ->
    // C (--profile=hosted) -> clang -lm -> execute, feeding a binary f32 buffer
    // on stdin and verifying the f32 results on stdout. Self-skips without
    // clang/python3.
    _ = h.addScriptTest(ctx, "hosted-test", "Hosted-profile elementwise float kernel: stdin/stdout f32 round-trip via libc/libm", &.{ "bash", "demo/hosted/run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "shell-test", "Minimal shell", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell-test" });
    _ = h.addScriptTest(ctx, "shell2-test", "Shell: tokenize + builtins with output", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell2-test" });
    _ = h.addScriptTest(ctx, "ushell-test", "Shell running in user mode via syscalls", &.{ "bash", "tools/lang/ushell-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-ushell-test", "LLVM-lowered shell running in user mode via syscalls", &.{ "bash", "tools/lang/ushell-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vfsmount-test", "VFS mount switch", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfsmount-test" });

    _ = h.addScriptTest(ctx, "treefs-test", "Hierarchical tree FS: nested mkdir/create, path resolution, ./.. traversal, getdents listing, typed errors", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "treefs-test" });

    _ = h.addScriptTest(ctx, "fs-toolserver-test", "Capability-checked FS tool server: workspace-scoped path caps deny /etc + .. escapes with audit/attribution (M1 walking skeleton)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fs-toolserver-test" });

    _ = h.addScriptTest(ctx, "agent-fs-test", "Agent FS tool front door: allowlist+budget gate over the path-capability server; M6-shape acceptance (deny+audit+attribute)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "agent-fs-test" });

    _ = h.addScriptTest(ctx, "policy-test", "Policy plane: drain audit provenance into per-agent counters; denial pressure escalates Allow/Throttle/Revoke/Kill (M5 seed)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "policy-test" });
    _ = h.addScriptTest(ctx, "persistent-audit-test", "Persistent policy/audit checkpoint: policy metadata and audited IPC events survive BlobStore reopen", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "persistent-audit-test" });
    _ = h.addScriptTest(ctx, "block-persistent-audit-test", "Block-backed persistent policy/audit checkpoint: policy metadata and audited IPC events survive BlockDevice remount", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "block-persistent-audit-test" });
    _ = h.addScriptTest(ctx, "agent-abi-test", "Versioned agent SYS_SUBMIT/SYS_POLL ABI: request validation and stable typed completion status mapping", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "agent-abi-test" });
    _ = h.addScriptTest(ctx, "production-ops-test", "Production ops primitives: signed-bundle metadata, rollback, watchdog/reboot reason, policy actuation", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "production-ops-test" });

    _ = h.addScriptTest(ctx, "netcap-test", "Capability-gated network egress: default-deny NetCap, audited+attributed allow/deny, attenuation only narrows (milestone #3)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "netcap-test" });

    _ = h.addScriptTest(ctx, "agent-containment-test", "Capstone M6-shape integration: every containment layer over a shared audit ring; benign task completes, all injected forbidden actions denied+audited, policy escalates", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "agent-containment-test" });

    _ = h.addScriptTest(ctx, "mcp-test", "MCP-compatible facade: method names resolve to native capability-checked tools (speak MCP, enforce with MC caps)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mcp-test" });

    // examples/feature_showcase.mc — one self-verifying tour of the language; emit-c via
    // the host harness here, emit-llvm auto-covered by llvm-host-suite-test. Returns 1 iff
    // every demonstrated feature produces its expected result on the backend under test.
    _ = h.addScriptTest(ctx, "showcase-test", "Language feature showcase (examples/feature_showcase.mc): one self-verifying program touring MC's features; returns 1 iff every feature's result is exactly right", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "showcase-test" });

    // Native `#[test]` facility: discover #[test] functions (mcc list-tests) and run each
    // process-isolated, reporting pass/fail by name. emit-c here, emit-llvm below.
    _ = h.addScriptTest(ctx, "mc-test", "Run the native #[test] functions in tests/test/lang_tests.mc, each process-isolated (a failing assert -> named FAIL), via tools/test/mc-test-runner.sh (emit-c)", &.{ "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "c", "tests/test/lang_tests.mc" });

    _ = h.addScriptTest(ctx, "llvm-mc-test", "Run the native #[test] functions through the LLVM backend, each process-isolated, via tools/test/mc-test-runner.sh", &.{ "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "llvm", "tests/test/lang_tests.mc" });

    // Opt-in module visibility (`pub`): a strict module's pub surface is reachable across
    // files, its private items are not (E_PRIVATE_IMPORT). Checks both directions.
    _ = h.addScriptTest(ctx, "mod-visibility-test", "Opt-in `pub` module visibility (emit-c): a strict module's pub API is reachable across files; cross-file use of a private item is E_PRIVATE_IMPORT", &.{ "bash", "tools/test/module-visibility-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-mod-visibility-test", "Opt-in `pub` module visibility (LLVM backend): pub API reachable across files; private cross-file use is E_PRIVATE_IMPORT", &.{ "bash", "tools/test/module-visibility-test.sh", "zig-out/bin/mcc", "llvm" });

    // std/sort — in-place insertion sort + ordered search (concrete u32 + generic comparator).
    _ = h.addScriptTest(ctx, "sort-test", "std/sort (emit-c): in-place sort + binary search (concrete u32 and generic comparator-closure), via the #[test] runner", &.{ "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "c", "tests/test/sort_test.mc" });

    _ = h.addScriptTest(ctx, "llvm-sort-test", "std/sort (LLVM backend): in-place sort + binary search, via the #[test] runner", &.{ "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "llvm", "tests/test/sort_test.mc" });

    _ = h.addScriptTest(ctx, "fdspace-test", "FdSpace (kernel/lib): fd alloc/select, sentinel-free", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdspace-test" });
    _ = h.addScriptTest(ctx, "slotmap-test", "SlotMap<T,N> index handle table", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "slotmap-test" });
    _ = h.addScriptTest(ctx, "mask-test", "Mask32 bit set", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mask-test" });
    _ = h.addScriptTest(ctx, "mailbox-test", "Mailbox<T,N> bounded queue + source filter", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mailbox-test" });
    _ = h.addScriptTest(ctx, "tryelse-test", "EXPR? else MAPPED error remap", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tryelse-test" });
    _ = h.addScriptTest(ctx, "byteview-test", "ByteBuf<N> inline buffer view", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "byteview-test" });
    _ = h.addScriptTest(ctx, "scan-test", "find_index/any closure scan", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scan-test" });

    _ = h.addScriptTest(ctx, "rights-test", "K1 unforgeable+monotonic Rights/RCap (narrow-only attenuation, parent⊇child law)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "rights-test" });

    _ = h.addScriptTest(ctx, "mmio-test", "std/mmio register-field helpers + ordered IO-memory copy", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mmio-test" });

    _ = h.addScriptTest(ctx, "synclock-test", "std/rwlock + std/seqlock reader-writer and sequence locks", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "synclock-test" });

    _ = h.addScriptTest(ctx, "ipc-result-test", "ipc_send_result: typed bounded send (Denied/DeadTarget/Timeout)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ipc-result-test" });

    _ = h.addScriptTest(ctx, "arp-cache-test", "ARP IP->MAC cache: insert/lookup/refresh/invalidate/eviction", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arp-cache-test" });

    _ = h.addScriptTest(ctx, "tlb-shootdown-test", "TLB shootdown bookkeeping: target/ack core masks + completion", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tlb-shootdown-test" });

    _ = h.addScriptTest(ctx, "mutex-test", "sleeping Mutex: try_lock, blocking enqueue, FIFO hand-off on unlock", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mutex-test" });

    _ = h.addScriptTest(ctx, "posix-test", "POSIX syscall surface", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "posix-test" });
    _ = h.addScriptTest(ctx, "userland-test", "Userland echo utility", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "userland-test" });
    _ = h.addScriptTest(ctx, "smprq-test", "SMP per-core run queues + work stealing", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "smprq-test" });
    _ = h.addScriptTest(ctx, "rtc-test", "Wall-clock via goldfish-RTC: read the 64-bit epoch and assert a plausible live 'now'", &.{ "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-rtc-test", "Run LLVM-lowered goldfish-RTC MMIO under QEMU", &.{ "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "contain-test", "MMU crash containment", &.{ "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-contain-test", "Run LLVM-lowered MMU crash containment under QEMU", &.{ "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "tcp-server-test", "TCP connection state machine as a server", &.{ "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-tcp-server-test", "LLVM-lowered TCP connection state machine as a server", &.{ "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-test", "Device-tree (FDT) header parsing", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdt-test" });

    _ = h.addScriptTest(ctx, "fb-test", "Linear framebuffer device", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fb-test" });
    _ = h.addScriptTest(ctx, "dynlink-test", "Dynamic-linking relocation core", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dynlink-test" });
    _ = h.addScriptTest(ctx, "aarch64-test", "Second architecture (aarch64) bring-up", &.{ "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-aarch64-test", "LLVM-lowered second architecture (aarch64) bring-up", &.{ "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "arm-vm-test", "AArch64 stage-1 page-table VM + MMU enable (real VA->PA translation)", &.{ "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-vm-test", "LLVM-lowered AArch64 stage-1 page-table VM + MMU enable", &.{ "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "arm-user-test", "AArch64 EL0 user hello: SYS_WRITE via svc #0, bad user ptr -> -EFAULT via a software page-table walk (no data abort), clean SYS_EXIT", &.{ "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-user-test", "LLVM-lowered AArch64 EL0 user hello: EL0 syscall round-trip + bad-ptr -EFAULT software walk under QEMU", &.{ "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "liveupdate-test", "Live update (state handoff)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "liveupdate-test" });
    _ = h.addScriptTest(ctx, "sbi-boot-test", "Boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-sbi-boot-test", "LLVM-lowered boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-boot-test", "Boot under OpenSBI + parse DTB /memory (FDT discovery)", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-fdt-boot-test", "LLVM-lowered boot under OpenSBI + parse DTB /memory", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-devices-test", "Boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT compatible strings", &.{ "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-fdt-devices-test", "LLVM-lowered boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT", &.{ "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "bootinfo-test", "Boot under OpenSBI + normalize FDT into the arch-neutral BootInfo (§3.1)", &.{ "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-bootinfo-test", "LLVM-lowered boot under OpenSBI + normalize FDT into the arch-neutral BootInfo", &.{ "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "visionfive2-readiness-test", "Boot under OpenSBI + validate the VisionFive 2 FDT-resource readiness adapter against QEMU", &.{ "bash", "tools/arch/visionfive2-readiness-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-visionfive2-readiness-test", "LLVM-lowered VisionFive 2 FDT-resource readiness adapter against QEMU", &.{ "bash", "tools/arch/visionfive2-readiness-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "uart-driver-test", "Boot under OpenSBI + discover UART base from FDT + drive first-class LSR-polled NS16550 driver", &.{ "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-uart-driver-test", "LLVM-lowered boot under OpenSBI + FDT-discovered first-class NS16550 driver", &.{ "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "smode-user-test", "S-mode U-mode hello under OpenSBI (SYS_WRITE + bad-ptr -EFAULT)", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-user-test", "LLVM-lowered S-mode U-mode hello under OpenSBI", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "e1000-test", "Real e1000 NIC PCI probe", &.{ "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-e1000-test", "LLVM-lowered real e1000 NIC PCI probe", &.{ "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "llvm" });

    // M9: confined QuickJS agent on AArch64 EL0 (the AArch64 analogue of x86 M7 / riscv M3).
    _ = h.addScriptTest(ctx, "arm-qjs-test", "M9: run a PURE-JS agent (fixed generic C host) confined in an aarch64 EL0 space under QEMU, with async host I/O over svc #0", &.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-qjs-test", "M9 (LLVM): run a PURE-JS agent confined in an aarch64 EL0 space under QEMU, with async host I/O", &.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "arm-qjs-async-test", "M9: a pure-JS agent proves overlap + back-pressure/denial over async host I/O in aarch64 EL0", &.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "arm-qjs-async" });

    // WASM-agent Phase 6 cross-arch (aarch64): a stock wasm32-wasi guest on WAMR runs confined in
    // EL0 with async host I/O over svc #0. The WASM peer of arm-qjs-async-test.
    _ = h.addScriptTest(ctx, "arm-wasm-async-test", "WASM-agent Phase 6: a confined WASM guest proves overlap + back-pressure over async host I/O in aarch64 EL0 under QEMU", &.{ "bash", "tools/arch/arm-wasm-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-wasm-async-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest proves async host I/O in aarch64 EL0 under QEMU", &.{ "bash", "tools/arch/arm-wasm-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "llvm-arm-qjs-async-test", "M9 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O in aarch64 EL0", &.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "arm-qjs-async" });

    _ = h.addScriptTest(ctx, "snapshot-test", "proc_snapshot (kernel/lib): stable process enumeration", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "snapshot-test" });

    _ = h.addScriptTest(ctx, "waitqueue-test", "WaitQueue (kernel/lib): block/wake/idle policy", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "waitqueue-test" });

    _ = h.addScriptTest(ctx, "service-test", "service (kernel/lib): request/reply server loop", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "service-test" });

    _ = h.addScriptTest(ctx, "plugin-test", "pluggable boot flow: device/bus probe-attach + registry + discovery", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "plugin-test" });

    _ = h.addScriptTest(ctx, "endpoint-test", "MINIX hardening: endpoints/generations, derived runnable, death cleanup", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "endpoint-test" });

    _ = h.addScriptTest(ctx, "supervisor-test", "service supervisor: declarative manifests + restart policy", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "supervisor-test" });

    _ = h.addScriptTest(ctx, "registry2-test", "Registry v2: multiple-per-class, generations, unregister-on-death", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "registry2-test" });

    _ = h.addScriptTest(ctx, "manifest-test", "enforced service manifests: privileges applied + enforced", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "manifest-test" });

    _ = h.addScriptTest(ctx, "scheduler-test", "scheduler service: quantum expiry notify + refresh", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scheduler-test" });

    _ = h.addScriptTest(ctx, "info-test", "info/snapshot service: top queries over IPC", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "info-test" });

    _ = h.addScriptTest(ctx, "granttab-test", "owner-tracked grants: bounded IPC sharing + revoke-on-death", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "granttab-test" });

    _ = h.addScriptTest(ctx, "x86-sched-test", "x86-64 arch port: cooperative context switch (native)", &.{ "bash", "tools/arch/x86-sched-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-sched-test", "LLVM-lowered x86-64 arch port: cooperative context switch (native)", &.{ "bash", "tools/arch/x86-sched-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "x86-qemu-test", "x86-64 kernel boots under QEMU (multiboot -> long mode)", &.{ "bash", "tools/arch/x86-qemu-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-qemu-test", "LLVM-lowered x86-64 kernel boots under QEMU (multiboot -> long mode)", &.{ "bash", "tools/arch/x86-qemu-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "x86-vm-test", "x86-64 builds a fresh 4-level page table, loads CR3, reads a translation-only VA (real VA->PA)", &.{ "bash", "tools/arch/x86-vm-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-vm-test", "LLVM-lowered x86-64 4-level page-table VM: build, CR3 reload, translation-only readback under QEMU", &.{ "bash", "tools/arch/x86-vm-test.sh", "zig-out/bin/mcc", "llvm" });

    // X4: x86-64 Local-APIC timer — REAL, non-polled interrupt delivery. PICs masked, LAPIC timer
    // periodic at IDT vec 0x20, sti + hlt-spin until ticks fire.
    _ = h.addScriptTest(ctx, "x86-timer-test", "x86-64 Local-APIC timer fires real interrupts (PICs masked) at IDT vec 0x20; sti + hlt-spin until ticks>=3 under QEMU", &.{ "bash", "tools/arch/x86-timer-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-timer-test", "LLVM-lowered x86-64 Local-APIC timer: real periodic interrupts at vec 0x20, hlt-spin until ticks>=3 under QEMU", &.{ "bash", "tools/arch/x86-timer-test.sh", "zig-out/bin/mcc", "llvm" });

    // X5: x86-64 PCI / virtio-pci device discovery — REAL config-space enumeration via the legacy
    // CAM port-I/O mechanism (0xCF8/0xCFC). Scans bus 0, finds the QEMU virtio-blk-pci device
    // (vendor 0x1AF4), reports its identity over COM1 (the analogue of RISC-V FDT/ECAM discovery).
    _ = h.addScriptTest(ctx, "x86-pci-test", "x86-64 enumerates PCI bus 0 via legacy CAM port I/O (0xCF8/0xCFC), discovers the QEMU virtio-pci device (vendor 0x1AF4) under QEMU", &.{ "bash", "tools/arch/x86-pci-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-pci-test", "LLVM-lowered x86-64 PCI discovery: legacy CAM port-I/O enumeration of the QEMU virtio-pci device under QEMU", &.{ "bash", "tools/arch/x86-pci-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "x86-user-test", "x86-64 ring-3 user hello: SYS_WRITE via int 0x80, bad user ptr -> -EFAULT via a software page-table walk (no #PF), clean SYS_EXIT", &.{ "bash", "tools/arch/x86-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-user-test", "LLVM-lowered x86-64 ring-3 user hello: ring-3 syscall round-trip + bad-ptr -EFAULT software walk under QEMU", &.{ "bash", "tools/arch/x86-user-test.sh", "zig-out/bin/mcc", "llvm" });

    // M7: confined QuickJS agent on x86_64 ring-3 (the x86 analogue of the riscv M3 qjs-smode-agent).
    _ = h.addScriptTest(ctx, "x86-qjs-test", "M7: run a PURE-JS agent (fixed generic C host) confined in an x86-64 ring-3 space under QEMU, with async host I/O over int 0x80", &.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-qjs-test", "M7 (LLVM): run a PURE-JS agent confined in an x86-64 ring-3 space under QEMU, with async host I/O", &.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "x86-qjs-async-test", "M7: a pure-JS agent proves overlap + back-pressure/denial over async host I/O in x86-64 ring 3", &.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "x86-qjs-async" });

    // WASM-agent Phase 6 cross-arch (x86_64): a stock wasm32-wasi guest on WAMR runs confined in
    // ring 3 with async host I/O over int 0x80. The WASM peer of x86-qjs-async-test.
    _ = h.addScriptTest(ctx, "x86-wasm-async-test", "WASM-agent Phase 6: a confined WASM guest proves overlap + back-pressure over async host I/O in x86-64 ring 3 under QEMU", &.{ "bash", "tools/arch/x86-wasm-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-x86-wasm-async-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest proves async host I/O in x86-64 ring 3 under QEMU", &.{ "bash", "tools/arch/x86-wasm-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "llvm-x86-qjs-async-test", "M7 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O in x86-64 ring 3", &.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "x86-qjs-async" });

    _ = h.addScriptTest(ctx, "cow-test", "Copy-on-write: shared RO page diverges on write", &.{ "bash", "tools/mem/cow-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cow-test", "Run LLVM-lowered copy-on-write fault handling under QEMU", &.{ "bash", "tools/mem/cow-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "usched-test", "Userspace-set scheduling policy (priority)", &.{ "bash", "tools/proc/usched-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-usched-test", "Run LLVM-lowered userspace-set scheduling policy under QEMU", &.{ "bash", "tools/proc/usched-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "userserver-test", "A server running in user mode via syscalls", &.{ "bash", "tools/lang/userserver-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-userserver-test", "Run LLVM-lowered user-mode server under QEMU", &.{ "bash", "tools/lang/userserver-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "isolation-test", "Per-server MMU isolation + cross-AS IPC", &.{ "bash", "tools/proc/isolation-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-isolation-test", "Run LLVM-lowered per-server MMU isolation under QEMU", &.{ "bash", "tools/proc/isolation-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "demand-test", "Demand paging: fault -> map -> retry", &.{ "bash", "tools/mem/demand-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-demand-test", "Run LLVM-lowered demand paging under QEMU", &.{ "bash", "tools/mem/demand-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "mmap-test", "mmap anonymous pages into a page table (active satp)", &.{ "bash", "tools/mem/mmap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-mmap-test", "Run LLVM-lowered anonymous mmap under QEMU", &.{ "bash", "tools/mem/mmap-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "diskfs-test", "On-disk FS: persistent format + inodes + named lookup", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "diskfs-test" });

    _ = h.addScriptTest(ctx, "heartbeat-test", "Reincarnation with heartbeat liveness detection", &.{ "bash", "tools/proc/heartbeat-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-heartbeat-test", "Run LLVM-lowered heartbeat restart detection under QEMU", &.{ "bash", "tools/proc/heartbeat-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "timeout-test", "IPC timeout: bounded receive, no infinite block", &.{ "bash", "tools/ipc/timeout-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-timeout-test", "Run LLVM-lowered IPC timeout under QEMU", &.{ "bash", "tools/ipc/timeout-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "privilege-test", "Least privilege: IPC allow-list + kernel-call gate", &.{ "bash", "tools/proc/privilege-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-privilege-test", "Run LLVM-lowered least-privilege IPC and kcall gates under QEMU", &.{ "bash", "tools/proc/privilege-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "signal-test", "Signals: deliver + poll + take an async signal", &.{ "bash", "tools/ipc/signal-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-signal-test", "Run LLVM-lowered signal delivery under QEMU", &.{ "bash", "tools/ipc/signal-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "registry-test", "Name/registry server: lookup a service by name", &.{ "bash", "tools/ipc/registry-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-registry-test", "Run LLVM-lowered name/registry server under QEMU", &.{ "bash", "tools/ipc/registry-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "ipc2-test", "IPC completeness: multi-slot + source filter + notify", &.{ "bash", "tools/ipc/ipc2-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ipc2-test", "Run LLVM-lowered IPC multi-slot/source-filter/notify under QEMU", &.{ "bash", "tools/ipc/ipc2-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "grant-test", "Memory grant: bounded delegation + revocation", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "grant-test" });

    _ = h.addScriptTest(ctx, "ipc-test", "kernel-mediated IPC: client/server message round-trip", &.{ "bash", "tools/ipc/ipc-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ipc-test", "Run LLVM-lowered kernel-mediated IPC under QEMU", &.{ "bash", "tools/ipc/ipc-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-test (async/await roadmap Phase B): request-id-keyed PARK/WAKE completion broker
    // (kernel/lib/async.mc). A waiter PARKS on submitted requests; a completer wakes it
    // (out-of-order completions) under the real cooperative scheduler. WCR + ASYNC-OK.
    _ = h.addScriptTest(ctx, "async-test", "async Phase B: request-id park/wake completion broker (submit/await/complete) under the scheduler", &.{ "bash", "tools/proc/async-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-test", "LLVM-lowered async park/wake completion broker under QEMU", &.{ "bash", "tools/proc/async-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-irq-test (async/await Phase C): a real M-mode TIMER interrupt completes an in-flight
    // request and wakes a task parked in async_await_irq (irq-off wait-prepare closes the
    // lost-wake window). The production shape: a task sleeps in wfi until an interrupt resumes it.
    _ = h.addScriptTest(ctx, "async-irq-test", "async Phase C: a real timer interrupt completes an async request and wakes the parked task (IRQ-backed completion)", &.{ "bash", "tools/proc/async-irq-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-irq-test", "LLVM-lowered IRQ-backed async completion under QEMU", &.{ "bash", "tools/proc/async-irq-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-cancel-test (async/await Phase D step 6, runtime half): the broker CANCELLATION
    // primitive kernel/lib/async.mc `async_cancel`. Fill the inflight quota, cancel one request,
    // prove its slot is RECLAIMED (a fresh submit reuses it), a late completion is a no-op, and a
    // double-cancel is idempotent — so a dropped pending future does not leak its slot. FXR + OK.
    _ = h.addScriptTest(ctx, "async-cancel-test", "async Phase D: async_cancel reclaims a dropped request's inflight slot (no leak on drop)", &.{ "bash", "tools/proc/async-cancel-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-cancel-test", "LLVM-lowered async_cancel slot reclamation under QEMU", &.{ "bash", "tools/proc/async-cancel-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-pollmany-test: the VECTORED DRAIN kernel/lib/async.mc `async_poll_many` — harvest many
    // completed in-flight requests per wakeup over the inflight table (the kernel analogue of
    // SYS_POLL(events, max)). Capped + re-enterable drain; pending requests never harvested. SD + OK.
    _ = h.addScriptTest(ctx, "async-pollmany-test", "async vectored drain: async_poll_many harvests many completions per wakeup over the inflight table", &.{ "bash", "tools/proc/async-pollmany-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-pollmany-test", "LLVM-lowered async_poll_many vectored drain under QEMU", &.{ "bash", "tools/proc/async-pollmany-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-future-test: the compiler's `async fn`/`await` lowering wired to the REAL kernel broker.
    // An async fn's two awaits resolve through ReqFut leaves (async_submit/async_slot_ready/
    // async_take/async_cancel_slot) driven to completion by drive_irq while sleeping in wfi; a
    // re-armed timer ISR delivers one real async_complete per request. WR + ASYNC-FUTURE-OK (42).
    _ = h.addScriptTest(ctx, "async-future-test", "broker-backed async: an async fn's awaits resolve against real broker completions driven by drive_irq (ReqFut leaves)", &.{ "bash", "tools/proc/async-future-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-future-test", "LLVM-lowered broker-backed async fn under QEMU", &.{ "bash", "tools/proc/async-future-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-multi-test (async/await E6): the MULTI-FUTURE cooperative executor `drive_many`. THREE
    // independent async fns are driven CONCURRENTLY by ONE drive_many call, sleeping in wfi between
    // ISR completions; a re-armed timer completes the in-flight requests OUT OF ORDER, so they
    // resolve interleaved. Generalizes drive_irq (one future) to N with the same lost-wakeup-free
    // IRQ-off idle discipline; adversarial to a leaked slot (active count -> 0) and a lost wakeup
    // (a stranded future would exhaust the idle budget and be cancelled, dropping drive_many < 3).
    // WR + ASYNC-MULTI-OK (drive_many=3, each result, 3 completions, 0 active).
    _ = h.addScriptTest(ctx, "async-multi-test", "multi-future cooperative async: drive_many drives three async fns concurrently, completed out-of-order by a re-armed timer ISR, no slot leak", &.{ "bash", "tools/proc/async-multi-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-multi-test", "LLVM-lowered multi-future cooperative async executor (drive_many) under QEMU", &.{ "bash", "tools/proc/async-multi-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-blk-test: DEVICE-BACKED async completion. An async fn's await resolves against a REAL
    // virtio-blk device interrupt: blk_read_sector_async submits a read + ties the head descriptor id
    // to a broker request id; the PLIC-routed used-ring IRQ reaps the completion in interrupt context
    // (blk_irq_reap -> async_complete) and wakes the task parked in drive_irq. Trace W i R + the sector
    // word "DISK" + ASYNC-BLK-OK prove the completion came from the device IRQ, not a polling loop.
    _ = h.addScriptTest(ctx, "async-blk-test", "device-backed async: an async fn's await resolves against a real virtio-blk device interrupt (PLIC used-ring completion reaped in interrupt context)", &.{ "bash", "tools/proc/async-blk-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-blk-test", "LLVM-lowered device-backed async virtio-blk completion under QEMU", &.{ "bash", "tools/proc/async-blk-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-net-test: DEVICE-BACKED async completion over the NIC. An async fn's await resolves
    // against a REAL virtio-net TX device interrupt: net_send_frame_async submits a frame + ties the
    // TX head descriptor id to a broker request id; the PLIC-routed TX used-ring IRQ reaps the
    // completion in interrupt context (net_irq_reap -> async_complete) and wakes the task parked in
    // drive_irq. Trace W i R + ASYNC-NET-OK + free=8/NET-NOLEAK-OK prove the completion came from the
    // device IRQ (not a poll loop) and no descriptor/DMA leaks across repeated sends.
    _ = h.addScriptTest(ctx, "async-net-test", "device-backed async: an async fn's await resolves against a real virtio-net TX device interrupt (PLIC used-ring completion reaped in interrupt context)", &.{ "bash", "tools/proc/async-net-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-net-test", "LLVM-lowered device-backed async virtio-net TX completion under QEMU", &.{ "bash", "tools/proc/async-net-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-select-test: select / cancel-the-loser over the real broker. Two in-flight requests are
    // raced (ReqRace2); a timer ISR completes the winner; the race cancels the loser and the active
    // slot count returns to 0 — the MAX_INFLIGHT-returns-to-zero acceptance. WR + ASYNC-SELECT-OK.
    _ = h.addScriptTest(ctx, "async-select-test", "broker-backed select: race two requests, cancel the loser, active slots return to 0", &.{ "bash", "tools/proc/async-select-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-select-test", "LLVM-lowered broker-backed select / cancel-the-loser under QEMU", &.{ "bash", "tools/proc/async-select-test.sh", "zig-out/bin/mcc", "llvm" });

    // agent-async-api-test: the AGENT-FACING async API end-to-end. An `async fn` agent does
    // `let a = await read_async(...); let b = await tool_call_async(...)` plus sleep_async (timeout)
    // and a timeout-then-CANCEL, driven by pump_run_to_completion over the ToolFut/ToolPump leaves
    // (user/agent_async.mc) against an in-kernel broker shim with app_run_demo's sys_submit/sys_poll
    // semantics. ARW + AGENT-ASYNC-API-OK (result 42) proves the awaits resolved over the API and
    // the cancel reclaimed the broker slot. Both backends.
    _ = h.addScriptTest(ctx, "agent-async-api-test", "agent-facing async API: an async fn agent awaits read_async/tool_call_async + sleep_async + timeout-then-cancel over the ToolFut/ToolPump leaves under QEMU", &.{ "bash", "tools/proc/agent-async-api-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-agent-async-api-test", "LLVM-lowered agent-facing async API (ToolFut/ToolPump wrappers) end-to-end under QEMU", &.{ "bash", "tools/proc/agent-async-api-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-agent-test: the capstone — an agent in real async/await over the kernel broker.
    // async-fn-awaiting-async-fn (agent -> tool_fetch/tool_read -> ReqFut) resolves two sequential
    // tool calls (page+cfg==42), then TIMES OUT a slow tool call by racing it against a deadline
    // (slow tool cancelled, inflight count back to 0). FRT + ASYNC-AGENT-OK.
    _ = h.addScriptTest(ctx, "async-agent-test", "capstone: an agent in real async/await resolves tool calls over the broker + times out a slow call", &.{ "bash", "tools/proc/async-agent-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-agent-test", "LLVM-lowered agent async/await over the broker under QEMU", &.{ "bash", "tools/proc/async-agent-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "cap-test", "capability least-privilege: driver-as-server holds the console cap", &.{ "bash", "tools/proc/cap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cap-test", "Run LLVM-lowered capability least-privilege server under QEMU", &.{ "bash", "tools/proc/cap-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "restart-test", "reincarnation: supervisor restarts a crashed server", &.{ "bash", "tools/proc/restart-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-restart-test", "Run LLVM-lowered reincarnation restart under QEMU", &.{ "bash", "tools/proc/restart-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "arc-test", "Arc<T> shared ownership: clone/last-drop-frees, handles leak-checked", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-test" });

    _ = h.addScriptTest(ctx, "arc-pkt-test", "packet Arc-shared between two consumers (skb/mbuf pattern)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-pkt-test" });

    _ = h.addScriptTest(ctx, "alloc-test", "Link + run the type-erased std/alloc Allocator over a captured heap", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "alloc-test" });

    _ = h.addScriptTest(ctx, "closure-test", "Link + run a bind() closure (capture + call across calls)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "closure-test" });

    _ = h.addScriptTest(ctx, "ring-test", "Link + run the generic in-place Ring<T> (push/pop/wrap)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ring-test" });

    _ = h.addScriptTest(ctx, "trace-test", "Link + run the trace ring buffer (retention/wrap/sequence)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "trace-test" });

    _ = h.addScriptTest(ctx, "log-test", "Link + run the leveled tracepoint logger (threshold/levels)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "log-test" });

    _ = h.addScriptTest(ctx, "tcp-test", "Link + run the TCP segment build/parse + checksum", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-test" });

    _ = h.addScriptTest(ctx, "tcp-conn-test", "Link + run the TCP connection state machine (handshake/close)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-conn-test" });

    _ = h.addScriptTest(ctx, "tcp-window-test", "Link + run the TCP send/recv window + ACK processing (data plane)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-window-test" });

    _ = h.addScriptTest(ctx, "tcp-reasm-test", "Link + run TCP reassembly + go-back-N retransmit", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-reasm-test" });

    _ = h.addScriptTest(ctx, "tcp-rtx-test", "Link + run the TCP retransmit timer (RTO -> go-back-N)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-rtx-test" });

    _ = h.addScriptTest(ctx, "symbols-test", "Link + run the symbol table (symbolize address -> function+offset)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "symbols-test" });

    _ = h.addScriptTest(ctx, "socket-test", "Link + run the UDP socket layer (bind/deliver/recv demux)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "socket-test" });

    _ = h.addScriptTest(ctx, "net-rx-test", "Link + run the RX demux path (frame -> socket_deliver -> recv)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-rx-test" });

    _ = h.addScriptTest(ctx, "net-fuzz-test", "Fuzz the RX parser with random frames (no OOB)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-fuzz-test" });

    // P1: parser fuzz oracle — drive the DNS + TCP parsers over a million random /
    // truncated / malformed byte buffers; every parse must terminate and never over-read
    // (each read now routes through std/bytes' total checked reader, br_try_*).
    _ = h.addScriptTest(ctx, "parser-fuzz-test", "Fuzz the DNS+TCP parsers with malformed bytes (total, no over-read)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "parser-fuzz-test" });

    // P6: bundle/OTA admission fuzz oracle — drive kernel/core/production_ops.mc's
    // bundle_validate over >200k adversarial headers (fail-closed typed reject) + 50k random
    // rollback A/B op-sequences (slot-index invariant); every call total, never a trap.
    _ = h.addScriptTest(ctx, "bundle-fuzz-test", "Fuzz the bundle/OTA admission surface (bundle_validate + rollback) with adversarial input (total, fail-closed, no trap)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "bundle-fuzz-test" });

    _ = h.addScriptTest(ctx, "net-rx-live-test", "Route a real virtio-net RX frame through net_rx_deliver under QEMU", &.{ "bash", "tools/net/net-rx-live-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-net-rx-live-test", "Route a real LLVM-lowered virtio-net RX frame through net_rx_deliver under QEMU", &.{ "bash", "tools/net/net-rx-live-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "http-get-test", "Active-open a real TCP connection and HTTP GET a live server over virtio-net under QEMU", &.{ "bash", "tools/net/http-get-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-http-get-test", "Active-open a real LLVM-lowered TCP connection and HTTP GET a live server over virtio-net under QEMU", &.{ "bash", "tools/net/http-get-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "bearssl-smoke-test", "Compute a SHA-256 vector via freestanding BearSSL and pull live virtio-rng entropy in a bare-metal riscv64 kernel under QEMU (Phase 1 TLS de-risking)", &.{ "bash", "tools/tls/bearssl-smoke-test.sh", "zig-out/bin/mcc", "c" });

    // rsa-verify-test: the MC RSA-PKCS#1/SHA-256 signature-verify binding
    // (kernel/crypto/rsa_verify.mc) over the constant-time BearSSL i31 engine — the
    // signed-bundle / image-verification primitive (production plan P4). Host-based and
    // deterministic; a real RSA-2048 signature must VERIFY while a tampered signature and a
    // wrong message are REJECTED. Both backends, so a green run is the parity proof.
    _ = h.addScriptTest(ctx, "rsa-verify-test", "Verify a real RSA-2048/SHA-256 signature (accept valid, reject tampered+wrong) via the MC BearSSL-i31 binding", &.{ "bash", "tools/crypto/rsa-verify-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-rsa-verify-test", "LLVM-backend RSA-2048/SHA-256 signature verify via the MC BearSSL-i31 binding", &.{ "bash", "tools/crypto/rsa-verify-test.sh", "zig-out/bin/mcc", "llvm" });

    // bearssl-smode-test revalidates the SAME freestanding BearSSL SHA-256 vector +
    // live virtio-rng entropy under REAL OpenSBI in S-mode (boot seam only: SBI
    // console/shutdown, sbi.ld, rdtime CSR; no `-bios none`). Deterministic — no
    // network egress — so it is gated in m0.
    _ = h.addScriptTest(ctx, "bearssl-smode-test", "Revalidate the freestanding BearSSL SHA-256 vector + live virtio-rng entropy under REAL OpenSBI in S-mode (TLS crypto stack on the OpenSBI boot seam)", &.{ "bash", "tools/arch/bearssl-smode-test.sh", "zig-out/bin/mcc", "c" });

    // https-smode-test revalidates the SAME deterministic in-kernel REAL BearSSL
    // TLS 1.2 handshake + HTTPS GET (against the LOCAL self-signed python server
    // over slirp loopback — no internet egress) under REAL OpenSBI in S-mode.
    _ = h.addScriptTest(ctx, "https-smode-test", "Revalidate the in-kernel REAL BearSSL TLS 1.2 handshake + HTTPS GET (local server over slirp) under REAL OpenSBI in S-mode", &.{ "bash", "tools/arch/https-smode-test.sh", "zig-out/bin/mcc", "c" });

    // https-get-test: a REAL BearSSL TLS 1.2 handshake over the kernel's TCP, validating
    // a self-signed trust anchor and decrypting an HTTPS GET from a local python HTTPS
    // server under QEMU (Phase 2 of in-kernel TLS; deterministic CI gate).
    _ = h.addScriptTest(ctx, "https-get-test", "Run a REAL BearSSL TLS 1.2 handshake over the kernel TCP and decrypt an HTTPS GET from a local python HTTPS server under QEMU", &.{ "bash", "tools/tls/https-get-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-https-get-test", "Run a REAL LLVM-lowered BearSSL TLS 1.2 handshake over the kernel TCP and decrypt an HTTPS GET from a local python HTTPS server under QEMU", &.{ "bash", "tools/tls/https-get-test.sh", "zig-out/bin/mcc", "llvm" });

    // google-https-test: best-effort REAL google.com:443 fetch validating Google's actual
    // cert chain against the embedded GTS Root R1. Standalone (PASS or honest SKIP);
    // deliberately NOT added to the m0 gate (no flaky CI dependency on internet egress).
    _ = h.addScriptTest(ctx, "google-https-test", "Best-effort REAL google.com:443 HTTPS fetch validating Google's actual cert chain against the embedded GTS Root R1 under QEMU (standalone; PASS or honest SKIP)", &.{ "bash", "tools/tls/google-https-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "dns-test", "Resolve a name via a real DNS A-query then HTTP GET that host over virtio-net under QEMU", &.{ "bash", "tools/net/dns-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-dns-test", "Resolve a name via a real LLVM-lowered DNS A-query then HTTP GET that host over virtio-net under QEMU", &.{ "bash", "tools/net/dns-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "backtrace-test", "Walk the frame-pointer chain and symbolize the frames under QEMU", &.{ "bash", "tools/lang/backtrace-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-backtrace-test", "Run LLVM-lowered backtrace symbolization under QEMU", &.{ "bash", "tools/lang/backtrace-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "paging-test", "Link + run Sv39 page-table map/translate", &.{ "bash", "tools/mem/paging-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-paging-test", "Link + run the LLVM-lowered Sv39 page-table map/translate", &.{ "bash", "tools/mem/paging-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "fnptr-test", "Link + run function-pointer dispatch (callback, vtable, return)", &.{ "bash", "tools/toolchain/fnptr-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "trap-test", "Run the typed-CPU trap/timer interrupt path under QEMU", &.{ "bash", "tools/arch/trap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-trap-test", "Run the LLVM-lowered typed-CPU trap/timer path under QEMU", &.{ "bash", "tools/arch/trap-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "thread-test", "Run cooperative context switching (main/worker ping-pong) under QEMU", &.{ "bash", "tools/proc/thread-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-thread-test", "Run LLVM-lowered cooperative context switching under QEMU", &.{ "bash", "tools/proc/thread-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "sched-test", "Run the round-robin scheduler (3 heap-stacked threads) under QEMU", &.{ "bash", "tools/proc/sched-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-sched-test", "Run the LLVM-lowered round-robin scheduler under QEMU", &.{ "bash", "tools/proc/sched-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "preempt-test", "Run the timer-driven preemptive scheduler under QEMU", &.{ "bash", "tools/proc/preempt-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-preempt-test", "Run LLVM-lowered timer-driven preemption under QEMU", &.{ "bash", "tools/proc/preempt-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "agent-preempt-test", "Run timer-driven preemption of agent PROCESSES (ProcTable) under QEMU", &.{ "bash", "tools/proc/agent-preempt-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-preempt-test", "Run LLVM-lowered timer-driven preemption of agent PROCESSES under QEMU", &.{ "bash", "tools/proc/agent-preempt-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "proc-supervisor-test", "Run the running supervisor loop (proc_supervisor_scan) over 3 supervised PROCESSES under QEMU: one healthy, one restarted once, one given up exactly once", &.{ "bash", "tools/proc/proc-supervisor-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-proc-supervisor-test", "Run the LLVM-lowered running supervisor loop (proc_supervisor_scan) over 3 supervised PROCESSES under QEMU", &.{ "bash", "tools/proc/proc-supervisor-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "instrument-test", "Run the instrumented ProcTable (unified ledger gating real IPC/blk/DMA ops + exact hot-path metrics + supervision-tree cascade with leases) under QEMU", &.{ "bash", "tools/proc/instrument-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-instrument-test", "Run the LLVM-lowered instrumented ProcTable (ledger + metrics + supervision-tree/leases) under QEMU", &.{ "bash", "tools/proc/instrument-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "ledger-test", "Run the unified resource ledger (charge/release + overflow-edge) under QEMU", &.{ "bash", "tools/proc/ledger-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ledger-test", "Run the LLVM-lowered unified resource ledger under QEMU", &.{ "bash", "tools/proc/ledger-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "soak-test", "Run the single-boot soak workload (thousands of spawn/charge/supervise/reclaim/reap cycles return to baseline, no leak/overflow) under QEMU", &.{ "bash", "tools/proc/soak-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-soak-test", "Run the LLVM-lowered single-boot soak workload under QEMU", &.{ "bash", "tools/proc/soak-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "signed-boot-test", "Run signed-image admission + A/B rollback (kernel/core/production_ops) end to end under QEMU", &.{ "bash", "tools/fs/signed-boot-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-signed-boot-test", "Run the LLVM-lowered signed-image admission + A/B rollback end to end under QEMU", &.{ "bash", "tools/fs/signed-boot-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "ota-test", "Run chunked OTA transport (kernel/core/ota) + admission + rollback end to end under QEMU", &.{ "bash", "tools/fs/ota-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ota-test", "Run the LLVM-lowered chunked OTA transport + admission + rollback end to end under QEMU", &.{ "bash", "tools/fs/ota-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "metrics-test", "Run structured metrics + deterministic event-log replay under QEMU", &.{ "bash", "tools/proc/metrics-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-metrics-test", "Run LLVM-lowered structured metrics + deterministic event-log replay under QEMU", &.{ "bash", "tools/proc/metrics-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "syscall-test", "Run the ecall syscall dispatch skeleton under QEMU", &.{ "bash", "tools/lang/syscall-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-syscall-test", "Run the LLVM-lowered ecall syscall dispatch skeleton under QEMU", &.{ "bash", "tools/lang/syscall-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "user-test", "Run the M->U privilege drop + user-mode syscalls under QEMU", &.{ "bash", "tools/lang/user-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-user-test", "Run the LLVM-lowered M->U privilege drop + user-mode syscalls under QEMU", &.{ "bash", "tools/lang/user-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "process-test", "Run process lifecycle (spawn/run/exit) under QEMU", &.{ "bash", "tools/proc/process-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-process-test", "Run the LLVM-lowered process lifecycle under QEMU", &.{ "bash", "tools/proc/process-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "elf-run-test", "Load an ELF64 and run it in U-mode under QEMU", &.{ "bash", "tools/lang/elf-run-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-elf-run-test", "Load an ELF64 from an LLVM-lowered kernel image and run it in U-mode under QEMU", &.{ "bash", "tools/lang/elf-run-test.sh", "zig-out/bin/mcc", "llvm" });

    // The uaccess demos exercise kernel/core/uaccess.mc, which imports riscv paging.mc
    // (sfence.vma) — not host-assemblable — so they run under QEMU on the real target,
    // not on the host driver suite. One generic runtime+harness, parameterized by the
    // fixture and its entry symbol.
    _ = h.addScriptTest(ctx, "uaccess-pt-test", "Page-table-aware user copies under QEMU: Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected (imports riscv paging.mc, so QEMU-only)", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-pt-test", "Page-table-aware user copies under QEMU (LLVM backend): Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test" });

    // kernel/core/elf_loader: real multi-segment ELF loader (Phase 1 of the QuickJS-agent
    // plan / review F3) — maps every PT_LOAD at its vaddr with per-segment perms, zeroes bss.
    _ = h.addScriptTest(ctx, "elf-loader-test", "Multi-segment ELF64 loader under QEMU: maps every PT_LOAD at its vaddr with per-segment R/W/X perms, copies file bytes, zeroes bss; synthetic 2-segment image, asserts mappings/content/bss/perms", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });

    _ = h.addScriptTest(ctx, "llvm-elf-loader-test", "Multi-segment ELF64 loader under QEMU (LLVM backend): per-segment perms, file copy, bss zero", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });

    _ = h.addScriptTest(ctx, "uaccess-snapshot-test", "Single-snapshot uaccess (U2 double-fetch/TOCTOU defense) under QEMU: fetch_user freezes a user datum once; later user-byte flips don't change the snapshot", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_snapshot_demo.mc", "uaccess_snapshot_run", "uaccess-snapshot-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-snapshot-test", "Single-snapshot uaccess (U2) under QEMU (LLVM backend): fetch_user freezes a user datum once; later user-byte flips don't change the snapshot", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_snapshot_demo.mc", "uaccess_snapshot_run", "uaccess-snapshot-test" });

    _ = h.addScriptTest(ctx, "uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU: a user-derived scalar must pass checked_len/checked_index/validate_bound (fail closed) before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU (LLVM backend): a user-derived scalar must pass checked_len/checked_index/validate_bound before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    _ = h.addScriptTest(ctx, "agent-confined-test", "Step 0: load a separate ELF into an isolated Sv39 address space (kernel unmapped) and run it confined in U-mode under QEMU", &.{ "bash", "tools/proc/agent-confined-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-confined-test", "Step 0 (LLVM): load a separate ELF into an isolated Sv39 address space and run it confined in U-mode under QEMU", &.{ "bash", "tools/proc/agent-confined-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 1 spine: build a real MC app (examples/apps/hello.mc) into a
    // multi-segment U-mode ELF via the userspace SDK, load it with the real elf_loader into
    // an isolated Sv39 space, and run it confined under QEMU — prints via SYS_WRITE (uaccess),
    // exits via SYS_EXIT.
    _ = h.addScriptTest(ctx, "app-run-test", "QuickJS-agent Phase 1: build an MC app into a multi-segment ELF, load it (real elf_loader) into an isolated U-mode space, run it confined under QEMU — SYS_WRITE via uaccess + SYS_EXIT", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-app-run-test", "QuickJS-agent Phase 1 (LLVM): build + run a confined MC app in an isolated U-mode space under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm" });

    // Direct syscall-ABI fault test (review item 2): a confined MC app hands bad user pointers to
    // SYS_WRITE/SYS_READ/SYS_POLL and asserts -E_FAULT at runtime — proving the uaccess path fails
    // closed, rather than relying on static review of the kernel. Both backends.
    _ = h.addScriptTest(ctx, "fault-probe-test", "Syscall-ABI fault test: a confined app gets -E_FAULT from SYS_WRITE/READ/POLL on bad pointers under QEMU", &.{ "bash", "tools/proc/fault-probe-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-fault-probe-test", "Syscall-ABI fault test (LLVM): bad pointers to SYS_WRITE/READ/POLL return -E_FAULT under QEMU", &.{ "bash", "tools/proc/fault-probe-test.sh", "zig-out/bin/mcc", "llvm" });

    // Tool-ABI quota test (review item 4): a confined MC app submits ToolReqs that breach each
    // quota and asserts the SPECIFIC errno — payload>MAX_REQ_BYTES/cap>MAX_RES_BYTES => -E_NOCAP,
    // unknown op => -E_DENIED, ring full => -E_AGAIN. Reuses app-run-test.sh (app+marker params).
    _ = h.addScriptTest(ctx, "quota-probe-test", "Tool-ABI quota test: ToolReq quota breaches return -E_NOCAP/-E_DENIED/-E_AGAIN under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/quota_probe.mc", "QUOTA-PROBE: PASS", "quota-probe" });

    _ = h.addScriptTest(ctx, "llvm-quota-probe-test", "Tool-ABI quota test (LLVM): quota breaches return the specific errno under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/quota_probe.mc", "QUOTA-PROBE: PASS", "quota-probe" });

    // Mock-broker cancellation/timeout (review item 3): a confined MC app submits a delayed request
    // and cancels it (-E_CANCELED), and a TIMEOUT op (-E_TIMEDOUT), asserting the completion status.
    _ = h.addScriptTest(ctx, "broker-probe-test", "Mock-broker cancellation/timeout: completions carry -E_CANCELED / -E_TIMEDOUT under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/broker_probe.mc", "BROKER-PROBE: PASS", "broker-probe" });

    _ = h.addScriptTest(ctx, "llvm-broker-probe-test", "Mock-broker cancellation/timeout (LLVM) under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/broker_probe.mc", "BROKER-PROBE: PASS", "broker-probe" });

    // Out-of-order delivery (review item 3): a pure-JS agent submits a slow (delay 5) then a fast
    // (delay 1) request; the broker delivers fast first, so the resolve order is "FS". Both backends.
    _ = h.addScriptTest(ctx, "qjs-broker-agent-test", "A pure-JS agent proves out-of-order broker completion (Promise reorder) under QEMU", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_broker.js", "broker-agent: order=FS", "qjs-broker-agent" });

    _ = h.addScriptTest(ctx, "llvm-qjs-broker-agent-test", "A pure-JS agent proves out-of-order broker completion under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_broker.js", "broker-agent: order=FS", "qjs-broker-agent" });

    // Unknown completion id is fatal (review item 6): a pure-JS agent drives the spurious op, whose
    // completion carries a bogus id; the host must fail loudly ("host: unknown completion id").
    _ = h.addScriptTest(ctx, "qjs-spurious-agent-test", "An unknown completion id is a fatal host error under QEMU", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_spurious.js", "host: unknown completion id", "qjs-spurious-agent" });

    _ = h.addScriptTest(ctx, "llvm-qjs-spurious-agent-test", "An unknown completion id is a fatal host error under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_spurious.js", "host: unknown completion id", "qjs-spurious-agent" });

    // QuickJS-agent Phase 2: a confined C app (examples/apps/compute.c) over the freestanding
    // libc (user/libc: malloc arena + mem/str) — the C-app + libc path QuickJS (also C) uses.
    _ = h.addScriptTest(ctx, "compute-app-test", "QuickJS-agent Phase 2: a confined C app over the freestanding libc (malloc+string) runs in an isolated U-mode space under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/compute.c", "compute-ok", "compute-app" });

    _ = h.addScriptTest(ctx, "llvm-compute-app-test", "QuickJS-agent Phase 2 (LLVM kernel): a confined C app over the freestanding libc runs under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/compute.c", "compute-ok", "compute-app" });

    // QuickJS-agent Phase 3: a confined C app over the freestanding libm (user/libc/math —
    // the exact half: classification/rounding/fmod + hardware sqrt) on real doubles. Proves
    // hardware FP is enabled for the app (kernel sets mstatus.FS before enter_user) — the
    // prerequisite for JS numbers.
    _ = h.addScriptTest(ctx, "math-app-test", "QuickJS-agent Phase 3: a confined C app over the freestanding libm (exact functions + hardware sqrt, FP enabled) runs under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/mathtest.c", "math-ok", "math-app" });

    _ = h.addScriptTest(ctx, "llvm-math-app-test", "QuickJS-agent Phase 3 (LLVM kernel): a confined C app over the freestanding libm runs under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/mathtest.c", "math-ok", "math-app" });

    // QuickJS-agent Phase 3 (complete): a confined C app over the vendored-openlibm
    // transcendentals (pow/exp/log/sin/cos/tan/atan2/cbrt/hypot) — the full double libm JS
    // Math needs, built freestanding into a cached archive and linked confined under FP.
    _ = h.addScriptTest(ctx, "trig-app-test", "QuickJS-agent Phase 3: a confined C app over the vendored openlibm transcendentals runs under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/transcendental.c", "trig-ok", "trig-app" });

    _ = h.addScriptTest(ctx, "llvm-trig-app-test", "QuickJS-agent Phase 3 (LLVM kernel): a confined C app over the vendored openlibm transcendentals runs under QEMU", &.{ "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/transcendental.c", "trig-ok", "trig-app" });

    // QuickJS-agent Phase 4: MC C-ABI varargs (the `va.*` intrinsics). A variadic MC function
    // is driven from a C runtime under QEMU on both backends — the printf-family interop the
    // (all-MC) libc needs so QuickJS can call our snprintf/printf shims.
    _ = h.addScriptTest(ctx, "vararg-test", "QuickJS-agent Phase 4: a C-ABI variadic MC fn (va.start/va.arg/va.end) runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vararg-test", "QuickJS-agent Phase 4 (LLVM): a C-ABI variadic MC fn runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 4: the all-MC C-ABI allocator (user/libc/alloc.mc), reusing
    // kernel/core/heap.mc's free-list. Driven via malloc/free/calloc/realloc from a C runtime
    // under QEMU on both backends — the heap QuickJS allocates against.
    _ = h.addScriptTest(ctx, "qjs-alloc-test", "QuickJS-agent Phase 4: the all-MC C-ABI allocator (reusing heap.mc) runs under QEMU", &.{ "bash", "tools/lang/alloc-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-alloc-test", "QuickJS-agent Phase 4 (LLVM): the all-MC C-ABI allocator runs under QEMU", &.{ "bash", "tools/lang/alloc-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 4: the all-MC mem/string core (user/libc/cstr.mc) — memcpy/memset/
    // memmove/memcmp/strlen/strcmp/strncmp/strchr/memchr, driven from a C runtime under QEMU on
    // both backends. The freestanding bytes QuickJS leans on constantly.
    _ = h.addScriptTest(ctx, "cstr-test", "QuickJS-agent Phase 4: the all-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cstr-test", "QuickJS-agent Phase 4 (LLVM): the all-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 4: the all-MC ctype + integer parsing (user/libc/cnum.mc) — is*/to*,
    // abs, strtol/strtoul/strtoll/strtoull/atoi (with endptr, sign, 0x/0 prefixes, wraparound),
    // driven from a C runtime under QEMU on both backends.
    _ = h.addScriptTest(ctx, "cnum-test", "QuickJS-agent Phase 4: the all-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cnum-test", "QuickJS-agent Phase 4 (LLVM): the all-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 4: the all-MC printf family (user/libc/stdio.mc, built on the va.*
    // varargs intrinsics), compiled as part of the AGGREGATED libc (user/libc/libc.mc — the
    // single-unit artifact QuickJS links). snprintf/printf checked against expected strings from
    // a C runtime under QEMU on both backends.
    _ = h.addScriptTest(ctx, "stdio-test", "QuickJS-agent Phase 4: the all-MC printf family (aggregated libc) runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-stdio-test", "QuickJS-agent Phase 4 (LLVM): the all-MC printf family runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 4 KEYSTONE: build the vendored QuickJS engine freestanding against the
    // all-MC libc + openlibm, link the confined qjs_agent, and EVALUATE JavaScript under QEMU
    // (1 + 2*3 == 7). Both backends.
    _ = h.addScriptTest(ctx, "qjs-run-test", "QuickJS-agent Phase 4: build QuickJS freestanding against the all-MC libc and evaluate JS under QEMU", &.{ "bash", "tools/lang/qjs-run-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-run-test", "QuickJS-agent Phase 4 (LLVM): build QuickJS freestanding and evaluate JS under QEMU", &.{ "bash", "tools/lang/qjs-run-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM-agent Phase 0 (docs/wasm-migration-plan.md §5): the spike that proves a general WASM
    // engine confines, links, and reaches the kernel — the mirror of qjs-run-test. RETIRED with
    // wasm3: superseded by wamr-run-test below (the WAMR engine spike, which also adds the
    // deterministic instruction-metering fuel wasm3 lacked).

    // WASM engine swap (tools/wamr/README.md): the WAMR interpreter (vendored third_party/wamr, built
    // freestanding via the `mc` platform port) runs a real wasm32 module CONFINED — the WAMR analogue
    // of wasm-run-test (wasm3). WAMR adds deterministic instruction-metering fuel that wasm3 lacks.
    _ = h.addScriptTest(ctx, "wamr-run-test", "WASM engine swap: build WAMR freestanding against the all-MC libc and run a real wasm32 module CONFINED under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wamr-run-test", "WASM engine swap (LLVM): build WAMR freestanding and run a real wasm32 module CONFINED under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM engine swap — the payoff: DETERMINISTIC per-instruction fuel (wasm_runtime_set_instruction
    // _count_limit). The same burn() guest is terminated mid-loop under a low limit and completes
    // under a high one — a precise instruction budget wasm3 cannot provide (cf. the coarse watchdog).
    _ = h.addScriptTest(ctx, "wamr-fuel-test", "WASM engine swap: WAMR deterministic instruction-fuel — a confined guest is terminated at a low instruction limit and completes at a high one, under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wamr/burn.c", "examples/apps/wamr_fuel_host.c", "WAMR-FUEL: ok", "wamr-fuel", "burn" });
    _ = h.addScriptTest(ctx, "llvm-wamr-fuel-test", "WASM engine swap (LLVM): WAMR deterministic instruction-fuel under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wamr/burn.c", "examples/apps/wamr_fuel_host.c", "WAMR-FUEL: ok", "wamr-fuel", "burn" });

    // WASM engine swap: WAMR drives the kernel broker (SYS_SUBMIT/SYS_POLL) from a confined agent —
    // an async SUM tool op resolves by id (result=7) over the mc tool ABI. Proves WAMR runs real
    // broker AGENTS (not just compute), the core agent-runtime capability for replacing wasm3.
    _ = h.addScriptTest(ctx, "wamr-agent-test", "WASM engine swap: a confined WAMR agent drives the broker (async SUM over SYS_SUBMIT/SYS_POLL) under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wamr/agent.c", "examples/apps/wamr_agent_host.c", "agent: ok", "wamr-agent", "agent_main" });
    _ = h.addScriptTest(ctx, "llvm-wamr-agent-test", "WASM engine swap (LLVM): a confined WAMR agent drives the broker over SYS_SUBMIT/SYS_POLL under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wamr/agent.c", "examples/apps/wamr_agent_host.c", "agent: ok", "wamr-agent", "agent_main" });

    // WASM engine swap: WAMR runs a STOCK wasm32-wasi guest (wasi-libc printf via the WASI P1 shim ->
    // SYS_WRITE) CONFINED — the WAMR analogue of wasm-wasi-hello-test. WAMR is built with
    // CALL_INDIRECT_OVERLONG support, so stock wasi-libc output loads without feature-pinning.
    _ = h.addScriptTest(ctx, "wamr-wasi-hello-test", "WASM engine swap: WAMR runs a stock wasm32-wasi guest CONFINED via the WASI P1 shim under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_hello.c", "examples/apps/wamr_wasi_host.c", "WASI-HELLO=ok", "wamr-wasi-hello", "", "wasi" });
    _ = h.addScriptTest(ctx, "llvm-wamr-wasi-hello-test", "WASM engine swap (LLVM): WAMR runs a stock wasm32-wasi guest CONFINED under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_hello.c", "examples/apps/wamr_wasi_host.c", "WASI-HELLO=ok", "wamr-wasi-hello", "", "wasi" });

    // WASM engine swap: WAMR runs the REAL broker agents (stock wasm32-wasi: wasi-libc printf + the mc
    // tool ABI) confined via the comprehensive host (WASI P1 + mc net_fetch/tool_submit/tool_poll).
    _ = h.addScriptTest(ctx, "wamr-async-test", "WASM engine swap: WAMR runs the async broker agent (overlap + back-pressure) confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_async.c", "examples/apps/wamr_full_host.c", "async: ok", "wamr-async", "", "wasi" });
    _ = h.addScriptTest(ctx, "llvm-wamr-async-test", "WASM engine swap (LLVM): WAMR runs the async broker agent confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_async.c", "examples/apps/wamr_full_host.c", "async: ok", "wamr-async", "", "wasi" });

    _ = h.addScriptTest(ctx, "wamr-net-test", "WASM engine swap: WAMR runs the brokered net-fetch agent (allow/deny/budget) confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_net.c", "examples/apps/wamr_full_host.c", "net: ok", "wamr-net", "", "wasi" });
    _ = h.addScriptTest(ctx, "llvm-wamr-net-test", "WASM engine swap (LLVM): WAMR runs the brokered net-fetch agent confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_net.c", "examples/apps/wamr_full_host.c", "net: ok", "wamr-net", "", "wasi" });

    // WASM engine swap: WAMR drives the real capability-checked WASI FS tool path (path_open/fd_read/
    // fd_write whole-file + mkdir-deny + outside-preopen-deny) confined — the WAMR analogue of
    // wasm-realtool-test, via the full host's brokered /ws preopen (TOOL_OP_FS_* over SYS_SUBMIT).
    _ = h.addScriptTest(ctx, "wamr-fs-test", "WASM engine swap: WAMR drives the capability-checked WASI FS path (allow + deny audit) confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_fs.c", "examples/apps/wamr_full_host.c", "fs: ok", "wamr-fs", "", "wasi" });
    _ = h.addScriptTest(ctx, "llvm-wamr-fs-test", "WASM engine swap (LLVM): WAMR drives the capability-checked WASI FS path confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_fs.c", "examples/apps/wamr_full_host.c", "fs: ok", "wamr-fs", "", "wasi" });

    // WASM engine swap — THE KEYSTONE: JavaScript (QuickJS compiled to wasm32-wasi: guest + 4 TUs)
    // runs on WAMR confined -> "js: ok". WAMR now covers the full retired wasm3 agent family. The
    // full host's 1 MB operand stack carries QuickJS's eval recursion.
    _ = h.addScriptTest(ctx, "wamr-js-test", "WASM engine swap keystone: JavaScript (QuickJS-on-wasm) runs on WAMR confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_js.c", "examples/apps/wamr_full_host.c", "js: ok", "wamr-js", "", "qjs" });
    _ = h.addScriptTest(ctx, "llvm-wamr-js-test", "WASM engine swap keystone (LLVM): JavaScript (QuickJS-on-wasm) runs on WAMR confined under QEMU", &.{ "bash", "tools/lang/wamr-run-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_js.c", "examples/apps/wamr_full_host.c", "js: ok", "wamr-js", "", "qjs" });

    // WASM-agent Phase 1 (docs/wasm-migration-plan.md §5): run a STOCK wasm32-wasi guest CONFINED.
    // Build WAMR + the comprehensive wamr_full_host (WASI P1 + the brokered FS + the mc tool ABI) +
    // the all-MC libc into a U-mode ELF, load it with the real elf_loader into an isolated Sv39
    // space (kernel UNMAPPED), and run an embedded `zig cc -target wasm32-wasi` printf hello —
    // reaching the kernel only through SYS_WRITE/SYS_EXIT. The mirror of qjs-confined-test. Both
    // backends.
    _ = h.addScriptTest(ctx, "wasm-wasi-hello-test", "WASM-agent Phase 1: run a stock wasm32-wasi guest confined in an isolated U-mode Sv39 space via the WASI P1 shim under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-wasm-wasi-hello-test", "WASM-agent Phase 1 (LLVM): run a stock wasm32-wasi guest confined via the WASI P1 shim under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM-agent Phase 2 (docs/wasm-migration-plan.md §5): WASI filesystem via preopen -> PathCap.
    // A stock wasm32-wasi guest does POSIX file I/O (open/write/read/close + mkdir) which wasi-libc
    // lowers to path_open/fd_read/fd_write/path_create_directory against the "/ws" preopen; the shim
    // routes these to TOOL_OP_FS_* through agent_fs_call (allowlist -> budget -> path-cap, allow+deny
    // audit). Write/read round-trip is ALLOWED; mkdir is DENIED (not allowlisted) and the guest
    // observes EACCES — the WASM mirror of qjs-realtool-test. Both backends.
    _ = h.addScriptTest(ctx, "wasm-realtool-test", "WASM-agent Phase 2: a stock wasm32-wasi guest drives the real capability-checked FS tool path (allow + deny audit) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_fs.c", "fs: ok", "wasm-realtool" });

    _ = h.addScriptTest(ctx, "llvm-wasm-realtool-test", "WASM-agent Phase 2 (LLVM): a stock wasm32-wasi guest drives the real capability-checked FS tool path (allow + deny audit) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_fs.c", "fs: ok", "wasm-realtool" });

    // WASM-agent Phase 3 (docs/wasm-migration-plan.md §5): brokered FETCH-ONLY network egress via
    // NetCap. A WASM guest calls the MC host tool net_fetch(endpoint, token) (module "mc", not
    // general WASI sockets), which the shim maps to TOOL_OP_NET_FETCH through the net broker
    // (egress allowlist -> budget -> endpoint). Endpoint 1 allowed (107/108), endpoint 9 DENIED
    // (EDENIED), budget exhaustion (EAGAIN) — the WASM mirror of qjs-nettool-test. Both backends.
    _ = h.addScriptTest(ctx, "wasm-nettool-test", "WASM-agent Phase 3: a WASM guest drives the brokered fetch-only network egress tool (allow/deny/budget) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_net.c", "net: ok", "wasm-nettool" });

    _ = h.addScriptTest(ctx, "llvm-wasm-nettool-test", "WASM-agent Phase 3 (LLVM): a WASM guest drives the brokered fetch-only network egress tool (allow/deny/budget) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_net.c", "net: ok", "wasm-nettool" });

    // WASM-agent Phase 4 KEYSTONE (docs/wasm-migration-plan.md §5): JavaScript on the WASM path.
    // The repo's vendored QuickJS compiled to wasm32-wasi (the Javy approach — Javy IS QuickJS-ng
    // on wasm32-wasi — built with zig cc + wasi-libc since the Javy binary is unavailable here) runs
    // a representative JS program (recursion + objects + JSON + closures) on the WAMR host + WASI
    // shim, confined. Proves JS agents survive the migration ("keep JS, retire the hack"). Both
    // backends. (The 6th arg selects the QuickJS-on-wasm guest build.)
    _ = h.addScriptTest(ctx, "wasm-js-agent-test", "WASM-agent Phase 4 keystone: JavaScript (QuickJS compiled to wasm32-wasi) runs on WAMR confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_js.c", "js: ok", "wasm-js-agent", "qjs" });

    _ = h.addScriptTest(ctx, "llvm-wasm-js-agent-test", "WASM-agent Phase 4 keystone (LLVM): JavaScript (QuickJS compiled to wasm32-wasi) runs on WAMR confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_js.c", "js: ok", "wasm-js-agent", "qjs" });

    // WASM-agent Phase 4b (docs/wasm-migration-plan.md §5): a JS AGENT drives the kernel broker on
    // the WASM path. QuickJS-on-wasm registers net_fetch() as a JS global backed by the mc.net_fetch
    // import, which the shim routes to TOOL_OP_NET_FETCH; the JS observes the broker's allow (107/108)
    // / deny (EDENIED) / budget (EAGAIN) decisions — the WASM mirror of qjs-nettool-test, but driven
    // from JS. Full JS-agent broker parity, completing the keystone. Both backends.
    _ = h.addScriptTest(ctx, "wasm-js-nettool-test", "WASM-agent Phase 4b: a JS agent (QuickJS-on-wasm) drives the brokered network tool (allow/deny/budget) from JavaScript, confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_js_net.c", "js-net: ok", "wasm-js-nettool", "qjs" });

    _ = h.addScriptTest(ctx, "llvm-wasm-js-nettool-test", "WASM-agent Phase 4b (LLVM): a JS agent (QuickJS-on-wasm) drives the brokered network tool (allow/deny/budget) from JavaScript, confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_js_net.c", "js-net: ok", "wasm-js-nettool", "qjs" });

    // WASM-agent Phase 5 (docs/wasm-migration-plan.md §5): native async over the tool ABI. A WASM
    // guest uses the mc.tool_submit / mc.tool_poll surface to keep multiple ops in flight and drain
    // completions by id — mirrors the QuickJS async agents.
    //   async  : 12 overlapping SUM ops; 8 accepted + complete, 4 denied -E_AGAIN (ok=8 rejected=4).
    //   cancel : a slow op cancelled (TOOL_OP_CANCEL) completes -E_CANCELED while a fast one resolves.
    //   quota  : the 9th submit on a full 8-deep queue returns exactly -E_AGAIN.
    //   spurious: the spurious op's completion carries a bogus id the guest must detect.
    _ = h.addScriptTest(ctx, "wasm-async-agent-test", "WASM-agent Phase 5: overlapping async tool ops + back-pressure (ok=8 rejected=4) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_async.c", "async: ok", "wasm-async-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-async-agent-test", "WASM-agent Phase 5 (LLVM): overlapping async tool ops + back-pressure confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_async.c", "async: ok", "wasm-async-agent" });

    _ = h.addScriptTest(ctx, "wasm-cancel-test", "WASM-agent Phase 5: cancel an in-flight async tool op (structured -E_CANCELED) confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_cancel.c", "cancel: ok", "wasm-cancel" });
    _ = h.addScriptTest(ctx, "llvm-wasm-cancel-test", "WASM-agent Phase 5 (LLVM): cancel an in-flight async tool op confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_cancel.c", "cancel: ok", "wasm-cancel" });

    _ = h.addScriptTest(ctx, "wasm-quota-agent-test", "WASM-agent Phase 5: tool-ABI back-pressure surfaces as -E_AGAIN confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_quota.c", "quota: ok", "wasm-quota-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-quota-agent-test", "WASM-agent Phase 5 (LLVM): tool-ABI back-pressure surfaces as -E_AGAIN confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_quota.c", "quota: ok", "wasm-quota-agent" });

    _ = h.addScriptTest(ctx, "wasm-spurious-agent-test", "WASM-agent Phase 5: a spurious completion's unknown id is detected confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_spurious.c", "spurious: ok", "wasm-spurious-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-spurious-agent-test", "WASM-agent Phase 5 (LLVM): a spurious completion's unknown id is detected confined under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_spurious.c", "spurious: ok", "wasm-spurious-agent" });

    // WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): substrate peers of the qjs agent gates,
    // proving the WASM path reaches the SAME confined-agent surface. agent-smoke walks the whole
    // happy path in one run (async SUM resolve + capability-checked FS round-trip + timeout cancel);
    // cancel-edges asserts the broker rejects ill-formed cancels (post-completion + never-submitted
    // -> -E_DENIED). Both are stock wasm32-wasi guests, both backends.
    _ = h.addScriptTest(ctx, "wasm-agent-smoke-test", "WASM-agent Phase 6: a confined WASM guest walks the async happy path (SUM resolve + FS round-trip + timeout cancel) under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_smoke.c", "smoke: ok", "wasm-agent-smoke" });
    _ = h.addScriptTest(ctx, "llvm-wasm-agent-smoke-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest walks the async happy path (SUM + FS + timeout cancel) under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_smoke.c", "smoke: ok", "wasm-agent-smoke" });

    _ = h.addScriptTest(ctx, "wasm-cancel-edges-test", "WASM-agent Phase 6: the broker rejects ill-formed cancels (post-completion + never-submitted -> -E_DENIED) from a confined WASM guest under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_cancel_edges.c", "cancel-edges: ok", "wasm-cancel-edges" });
    _ = h.addScriptTest(ctx, "llvm-wasm-cancel-edges-test", "WASM-agent Phase 6 (LLVM): the broker rejects ill-formed cancels (post-completion + never-submitted -> -E_DENIED) from a confined WASM guest under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_cancel_edges.c", "cancel-edges: ok", "wasm-cancel-edges" });

    _ = h.addScriptTest(ctx, "wasm-broker-agent-test", "WASM-agent Phase 6: out-of-order broker completion (slow-then-fast submit -> fast resolves first, order=FS) from a confined WASM guest under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_broker.c", "broker-agent: order=FS", "wasm-broker-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-broker-agent-test", "WASM-agent Phase 6 (LLVM): out-of-order broker completion (slow-then-fast submit -> fast resolves first, order=FS) from a confined WASM guest under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_broker.c", "broker-agent: order=FS", "wasm-broker-agent" });

    // WASM-agent Phase 6 basic syscall-driven agent (mirrors qjs-agent-test): submit a brokered tool
    // op and demultiplex its completion by id over SYS_SUBMIT/SYS_POLL, confined.
    _ = h.addScriptTest(ctx, "wasm-agent-test", "WASM-agent Phase 6: a confined WASM agent submits a brokered tool op and resolves it by id over SYS_SUBMIT/SYS_POLL under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_agent.c", "agent: ok", "wasm-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-agent-test", "WASM-agent Phase 6 (LLVM): a confined WASM agent resolves a brokered tool op by id over SYS_SUBMIT/SYS_POLL under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_agent.c", "agent: ok", "wasm-agent" });

    // WASM-agent Phase 6 S-mode peers (docs/wasm-migration-plan.md §5): the same confined WASM agent
    // ELF, but the kernel runs in S-mode under REAL OpenSBI (kernel mapped supervisor-only). Mirrors
    // the qjs-smode-* gates; one parameterized script covers confined / agent / async-agent by guest.
    _ = h.addScriptTest(ctx, "wasm-smode-confined-test", "WASM-agent Phase 6: a WASM guest runs CONFINED under REAL OpenSBI (S-mode), kernel supervisor-only, under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-smode-confined-test", "WASM-agent Phase 6 (LLVM): a WASM guest runs CONFINED under REAL OpenSBI (S-mode) under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "wasm-smode-agent-test", "WASM-agent Phase 6: a WASM agent walks the async happy path (SUM + FS + timeout cancel) CONFINED under REAL OpenSBI (S-mode) under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_smoke.c", "smoke: ok", "wasm-smode-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-smode-agent-test", "WASM-agent Phase 6 (LLVM): a WASM agent walks the async happy path CONFINED under REAL OpenSBI (S-mode) under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_smoke.c", "smoke: ok", "wasm-smode-agent" });

    _ = h.addScriptTest(ctx, "wasm-smode-async-agent-test", "WASM-agent Phase 6: overlapping async tool ops + back-pressure (ok=8 rejected=4) CONFINED under REAL OpenSBI (S-mode) under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_async.c", "async: ok", "wasm-smode-async-agent" });
    _ = h.addScriptTest(ctx, "llvm-wasm-smode-async-agent-test", "WASM-agent Phase 6 (LLVM): overlapping async tool ops + back-pressure CONFINED under REAL OpenSBI (S-mode) under QEMU", &.{ "bash", "tools/arch/wasm-smode-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_async.c", "async: ok", "wasm-smode-async-agent" });

    // WASM-agent Phase 6 S-mode device-IRQ peers: a confined WASM guest's brokered tool completes
    // through a REAL S-mode virtio PLIC interrupt + production SYS_POLL. Mirror qjs-smode-{net,blk}-irq.
    _ = h.addScriptTest(ctx, "wasm-smode-net-irq-tool-test", "WASM-agent Phase 6: a confined WASM guest's net_fetch completes via a real S-mode virtio-net PLIC interrupt under QEMU", &.{ "bash", "tools/arch/wasm-smode-net-irq-tool-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-smode-net-irq-tool-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest's net_fetch completes via a real S-mode virtio-net PLIC interrupt under QEMU", &.{ "bash", "tools/arch/wasm-smode-net-irq-tool-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "wasm-smode-blk-irq-tool-test", "WASM-agent Phase 6: a confined WASM guest's fs_read completes via a real S-mode virtio-blk PLIC interrupt under QEMU", &.{ "bash", "tools/arch/wasm-smode-blk-irq-tool-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-smode-blk-irq-tool-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest's fs_read completes via a real S-mode virtio-blk PLIC interrupt under QEMU", &.{ "bash", "tools/arch/wasm-smode-blk-irq-tool-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM-agent Phase 6 real-TCP peer: a confined WASM guest's net_fetch reaches a LIVE HTTP server
    // through the kernel's real TCP transport over virtio-net (validated by UART marker + HTTP access
    // log + pcap). Mirrors qjs-net-realtool-test. Self-skips if python3 is unavailable.
    _ = h.addScriptTest(ctx, "wasm-net-realtool-test", "WASM-agent Phase 6: a confined WASM guest's net_fetch reaches a live HTTP server through the real TCP-backed broker over virtio-net under QEMU", &.{ "bash", "tools/lang/wasm-net-realtool-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-net-realtool-test", "WASM-agent Phase 6 (LLVM): a confined WASM guest's net_fetch reaches a live HTTP server through the real TCP-backed broker over virtio-net under QEMU", &.{ "bash", "tools/lang/wasm-net-realtool-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM-agent Phase 7 (docs/wasm-migration-plan.md §5): JS perf benchmark — native QuickJS vs
    // QuickJS-on-WASM on the SAME workload. Gate is functional-parity (same numeric result) + report
    // emission (zig-out/wasm-js-bench-*.json); QEMU timings are indicative (recorded, not gated on).
    _ = h.addScriptTest(ctx, "wasm-js-bench-test", "WASM-agent Phase 7: native QuickJS vs QuickJS-on-WASM evaluate the same JS workload to the same result; emit the comparison report under QEMU", &.{ "bash", "tools/lang/wasm-js-bench-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-js-bench-test", "WASM-agent Phase 7 (LLVM): native QuickJS vs QuickJS-on-WASM JS benchmark + comparison report under QEMU", &.{ "bash", "tools/lang/wasm-js-bench-test.sh", "zig-out/bin/mcc", "llvm" });

    // WASM-agent Phase 5 linear-memory cap: a confined guest's heap is BOUNDED and hitting the bound
    // fails GRACEFULLY (malloc -> NULL at the cap, no trap, agent stays confined) — an untrusted agent
    // cannot exhaust host memory and OOM is a normal confined error, not a crash.
    _ = h.addScriptTest(ctx, "wasm-memcap-test", "WASM-agent Phase 5: a confined WASM guest's linear memory is bounded; OOM is graceful (malloc->NULL, no trap) under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/wasm/wasi_memcap.c", "memcap: ok", "wasm-memcap" });
    _ = h.addScriptTest(ctx, "llvm-wasm-memcap-test", "WASM-agent Phase 5 (LLVM): a confined WASM guest's linear memory is bounded; OOM is graceful under QEMU", &.{ "bash", "tools/lang/wasm-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/wasm/wasi_memcap.c", "memcap: ok", "wasm-memcap" });

    // Demand-grown guest heap (Increment 1): a confined agent's libc heap grows ON DEMAND past the
    // fixed static arena via SYS_SBRK — the kernel maps fresh frames at the running break, so the heap
    // scales with real RAM instead of a compile-time .bss array. The agent malloc()s far past the arena
    // and writes+reads every page, proving the demand-mapped frames are real.
    _ = h.addScriptTest(ctx, "sbrk-grow-test", "Demand-grown heap: a confined agent's libc heap grows past the static arena via SYS_SBRK (40 MiB, every page written+read) under QEMU", &.{ "bash", "tools/lang/sbrk-grow-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-sbrk-grow-test", "Demand-grown heap (LLVM): a confined agent's libc heap grows past the static arena via SYS_SBRK under QEMU", &.{ "bash", "tools/lang/sbrk-grow-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "sbrk-cap-test", "Demand-grown heap cap: a confined agent grows past the arena then hits the unified-ledger memory ceiling with a clean NULL (no trap) under QEMU", &.{ "bash", "tools/lang/sbrk-grow-test.sh", "zig-out/bin/mcc", "c", "examples/apps/sbrk_cap.c", "SBRK-CAP-OK", "sbrk-cap" });
    _ = h.addScriptTest(ctx, "llvm-sbrk-cap-test", "Demand-grown heap cap (LLVM): a confined agent grows past the arena then hits the unified-ledger memory ceiling with a clean NULL under QEMU", &.{ "bash", "tools/lang/sbrk-grow-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/sbrk_cap.c", "SBRK-CAP-OK", "sbrk-cap" });

    // WASM-agent Phase 5 CPU-runaway watchdog: a runaway agent (infinite loop, no syscalls) is
    // preempted by the machine-timer watchdog and KILLED past its CPU budget — a coarse liveness
    // bound (NOT deterministic fuel) proving an untrusted agent cannot wedge the system.
    _ = h.addScriptTest(ctx, "wasm-watchdog-test", "WASM-agent Phase 5: a confined runaway WASM agent is preempted + killed by the machine-timer CPU watchdog under QEMU", &.{ "bash", "tools/lang/wasm-watchdog-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-wasm-watchdog-test", "WASM-agent Phase 5 (LLVM): a confined runaway WASM agent is preempted + killed by the machine-timer CPU watchdog under QEMU", &.{ "bash", "tools/lang/wasm-watchdog-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 6: run QuickJS CONFINED — build the engine + all-MC libc into a U-mode
    // ELF, load it with the real elf_loader into an isolated Sv39 space (kernel UNMAPPED), and
    // evaluate JS in U-mode, reaching the kernel only via SYS_WRITE/SYS_EXIT. Both backends.
    _ = h.addScriptTest(ctx, "qjs-confined-test", "QuickJS-agent Phase 6: evaluate JS in a CONFINED isolated U-mode Sv39 space under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-confined-test", "QuickJS-agent Phase 6 (LLVM): evaluate JS confined in an isolated U-mode space under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm" });

    // M3a (first half): the SAME confined QuickJS agent, but the KERNEL runs in S-mode under REAL
    // OpenSBI (no `-bios none`) instead of M-mode. The agent's space additionally maps the kernel
    // as a supervisor-only gigapage (satp is effective in S-mode) + the UART MMIO page; JS is
    // evaluated in U-mode, reaching the kernel only via SYS_WRITE/SYS_EXIT. Both backends.
    _ = h.addScriptTest(ctx, "qjs-smode-confined-test", "M3a: evaluate JS in a CONFINED isolated U-mode Sv39 space under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-confined-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-smode-confined-test", "M3a (LLVM): evaluate JS confined in an isolated U-mode space under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-confined-test.sh", "zig-out/bin/mcc", "llvm" });

    // M3 (M3b): the PURE-JS AGENT under REAL OpenSBI (S-mode). The S-mode analogue of
    // qjs-agent-test: same fixed generic C host + embedded JS agent doing async host I/O over
    // SYS_SUBMIT/SYS_POLL with back-pressure, but the kernel runs in S-mode under the real OpenSBI
    // firmware (no `-bios none`) and the kernel is mapped supervisor-only (unreachable from U). The
    // async agent is purely polled (no interrupts), so M3a's S-mode syscall dispatch already serves
    // it. Default agent.js -> "agent: done".
    _ = h.addScriptTest(ctx, "qjs-smode-agent-test", "M3: run a PURE-JS agent (fixed generic C host) confined under REAL OpenSBI (S-mode), with async host I/O", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-smode-agent-test", "M3 (LLVM): run a PURE-JS agent confined under REAL OpenSBI (S-mode), with async host I/O", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm" });

    // M3 (M3b) async-under-load: the same agent_async.js + EXPECT the M-mode qjs-async-agent-test
    // uses, now under REAL OpenSBI (S-mode). Proves Promise overlap + back-pressure/denial over
    // async host I/O while the kernel stays unmapped (supervisor-only) from the agent.
    _ = h.addScriptTest(ctx, "qjs-smode-async-agent-test", "M3: a pure-JS agent proves overlap + back-pressure/denial over async host I/O under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-smode-async-agent" });

    _ = h.addScriptTest(ctx, "llvm-qjs-smode-async-agent-test", "M3 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-smode-async-agent" });

    // M5b.2: a pure-JS agent drives the REAL, capability-checked FS tool path through the SAME
    // async ABI (SYS_SUBMIT/SYS_POLL). The shared app_run_demo broker dispatches host_fs_write /
    // host_fs_read / host_fs_mkdir through agent_fs_call (allowlist -> budget -> path cap), so the
    // agent proves allow (read=hi), deny (mkdir not allowlisted -> structured error), and audit
    // end-to-end from JS. EXPECT "fs: ok" is reached only AFTER both the read-back and the denied
    // mkdir, so the gate fails if the real capability checks did not run.
    _ = h.addScriptTest(ctx, "qjs-realtool-test", "M5b.2: a pure-JS agent drives the REAL capability-checked FS tool path (allow/deny/audit) over the async ABI under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_fs.js", "fs: ok", "qjs-realtool" });

    _ = h.addScriptTest(ctx, "llvm-qjs-realtool-test", "M5b.2 (LLVM): a pure-JS agent drives the REAL capability-checked FS tool path over the async ABI under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_fs.js", "fs: ok", "qjs-realtool" });

    _ = h.addScriptTest(ctx, "qjs-nettool-test", "M5b.3: a pure-JS agent drives the brokered network fetch tool path over the async ABI under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_net_tool.js", "net: ok", "qjs-nettool" });

    _ = h.addScriptTest(ctx, "llvm-qjs-nettool-test", "M5b.3 (LLVM): a pure-JS agent drives the brokered network fetch tool path over the async ABI under REAL OpenSBI (S-mode)", &.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_net_tool.js", "net: ok", "qjs-nettool" });

    _ = h.addScriptTest(ctx, "qjs-net-realtool-test", "M5b.4: a pure-JS agent drives host_net_fetch through the REAL TCP-backed broker transport over virtio-net", &.{ "bash", "tools/lang/qjs-net-realtool-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-net-realtool-test", "M5b.4 (LLVM): a pure-JS agent drives host_net_fetch through the REAL TCP-backed broker transport over virtio-net", &.{ "bash", "tools/lang/qjs-net-realtool-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "qjs-smode-net-irq-tool-test", "M5b.5: a pure-JS host_net_fetch completes through production SYS_POLL from a real S-mode virtio-net PLIC interrupt", &.{ "bash", "tools/arch/qjs-smode-net-irq-tool-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-smode-net-irq-tool-test", "M5b.5 (LLVM): a pure-JS host_net_fetch completes through production SYS_POLL from a real S-mode virtio-net PLIC interrupt", &.{ "bash", "tools/arch/qjs-smode-net-irq-tool-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "qjs-smode-blk-irq-tool-test", "M5b.6: a pure-JS host_fs_read completes through production SYS_POLL from a real S-mode virtio-blk PLIC interrupt", &.{ "bash", "tools/arch/qjs-smode-blk-irq-tool-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-smode-blk-irq-tool-test", "M5b.6 (LLVM): a pure-JS host_fs_read completes through production SYS_POLL from a real S-mode virtio-blk PLIC interrupt", &.{ "bash", "tools/arch/qjs-smode-blk-irq-tool-test.sh", "zig-out/bin/mcc", "llvm" });

    // QuickJS-agent Phase 7: the EVENT LOOP. The confined agent evaluates a Promise chain and
    // drains the job queue (JS_ExecutePendingJob) — the microtask concurrency real agents need
    // (Promise/async do nothing without it). ASYNC=42 after the loop runs. Both backends.
    _ = h.addScriptTest(ctx, "qjs-async-test", "QuickJS-agent Phase 7: the confined agent's Promise/microtask event loop under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_async_agent.c", "ASYNC=42", "qjs-async" });

    _ = h.addScriptTest(ctx, "llvm-qjs-async-test", "QuickJS-agent Phase 7 (LLVM): the confined agent's event loop under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_async_agent.c", "ASYNC=42", "qjs-async" });

    // QuickJS-agent Phase 7 (full): NON-BLOCKING kernel I/O resolving a JS Promise. The confined
    // agent's host_async() does SYS_SUBMIT and returns a pending Promise; the event loop SYS_POLLs
    // the completion and resolves it (the .then then runs). IO=42, never blocking. Both backends.
    _ = h.addScriptTest(ctx, "qjs-io-test", "QuickJS-agent Phase 7: non-blocking SYS_SUBMIT/SYS_POLL I/O resolving a JS Promise under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_io_agent.c", "IO=42", "qjs-io" });

    _ = h.addScriptTest(ctx, "llvm-qjs-io-test", "QuickJS-agent Phase 7 (LLVM): non-blocking I/O resolving a JS Promise under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_io_agent.c", "IO=42", "qjs-io" });

    // QuickJS-agent Phase 8: WORKERS (single-core v0). The confined agent spawns a worker (a
    // separate, isolated JS context), posts a message, runs its event loop, and gets a result
    // back — the spawn/mailbox substrate. WORKER=42 isolated=1 (the worker scope didn't leak).
    _ = h.addScriptTest(ctx, "qjs-worker-test", "QuickJS-agent Phase 8: a confined agent spawns an isolated JS worker (message-passing) under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_worker_agent.c", "WORKER=42 isolated=1", "qjs-worker" });

    _ = h.addScriptTest(ctx, "llvm-qjs-worker-test", "QuickJS-agent Phase 8 (LLVM): a confined agent spawns an isolated JS worker under QEMU", &.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_worker_agent.c", "WORKER=42 isolated=1", "qjs-worker" });

    // The payoff: a PURE-JS agent (examples/agents/agent.js — async/await over host I/O, no C) run
    // by the FIXED generic host (qjs_host.c), confined under QEMU. You write the agent in JS only.
    _ = h.addScriptTest(ctx, "qjs-agent-test", "Run a PURE-JS agent (fixed generic C host) confined under QEMU, with async host I/O", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-agent-test", "Run a PURE-JS agent confined under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm" });

    // Async-I/O UNDER LOAD: a pure-JS agent (examples/agents/agent_async.js) that fires overlapping
    // host_async() requests (Promise.all) AND bursts past the kernel's 8-deep completion queue, so
    // the excess is denied (-E_AGAIN) and those Promises REJECT instead of hanging. Proves overlap,
    // independent completion, and back-pressure/denial — not just the single-request happy path.
    _ = h.addScriptTest(ctx, "qjs-async-agent-test", "A pure-JS agent proves overlap + back-pressure/denial over async host I/O under QEMU", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-async-agent" });

    _ = h.addScriptTest(ctx, "llvm-qjs-async-agent-test", "A pure-JS agent proves overlap + back-pressure/denial over async host I/O under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-async-agent" });

    // Structured-error surfacing (review item 4): a pure-JS agent bursts past the in-flight quota
    // and asserts the rejections arrive as structured { code:-11, name:"EAGAIN", retryable:true }
    // objects, not bare integers. Proves the host surfaces tool-ABI errno into JS as structured
    // errors. Both backends.
    _ = h.addScriptTest(ctx, "qjs-quota-agent-test", "A pure-JS agent proves tool-ABI back-pressure surfaces as a structured JS error under QEMU", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_quota.js", "quota-agent: reject code=-11 name=EAGAIN retryable=true", "qjs-quota-agent" });

    _ = h.addScriptTest(ctx, "llvm-qjs-quota-agent-test", "A pure-JS agent proves tool-ABI back-pressure surfaces as a structured JS error under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_quota.js", "quota-agent: reject code=-11 name=EAGAIN retryable=true", "qjs-quota-agent" });

    // A pure-JS agent CANCELS an in-flight async request (AbortController-like { promise, cancel }
    // handle from the host prelude): the cancelled request rejects with a structured ECANCELED, a
    // concurrent request still resolves, and the kernel broker slot is reclaimed (host inflight=0).
    _ = h.addScriptTest(ctx, "qjs-cancel-test", "A pure-JS agent cancels an in-flight async request (structured ECANCELED reject + broker-slot reclamation) under QEMU", &.{ "bash", "tools/lang/qjs-cancel-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-cancel-test", "A pure-JS agent cancels an in-flight async request (structured ECANCELED reject + broker-slot reclamation) under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-cancel-test.sh", "zig-out/bin/mcc", "llvm" });

    // THE canonical "agent async smoke" gate (item 3): ONE confined PURE-JS agent walks the whole
    // async happy path in a single run — host_call (SUM resolve) -> host_fs_read (real cap-checked FS
    // read) -> host_sleep (async timeout) -> cancel (in-flight ECANCELED) — and prints AGENT-SMOKE-OK
    // only if every stage passed AND the host drained to inflight=0 with no unknown completion id.
    _ = h.addScriptTest(ctx, "qjs-agent-smoke-test", "Canonical agent async smoke: a confined pure-JS agent walks host_call+FS-read+timeout+cancel and reclaims every slot (AGENT-SMOKE-OK) under QEMU", &.{ "bash", "tools/lang/qjs-agent-smoke-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-agent-smoke-test", "Canonical agent async smoke (LLVM): host_call+FS-read+timeout+cancel, all slots reclaimed (AGENT-SMOKE-OK) under QEMU", &.{ "bash", "tools/lang/qjs-agent-smoke-test.sh", "zig-out/bin/mcc", "llvm" });

    // Negative cancellation-edge gate (item 4) at the JS/host layer: a confined pure-JS agent proves
    // post-completion cancel is denied, a failed-submit cancel hits nothing, a late completion after
    // cancel produces NO fatal unknown-id, and an FS read resolves non-empty — each with a distinct
    // marker; the host drains to inflight=0.
    _ = h.addScriptTest(ctx, "qjs-cancel-edges-test", "Negative cancellation edges (pure-JS): post-complete cancel denied, failed-submit cancel hits nothing, late completion is no unknown-id, FS read non-empty under QEMU", &.{ "bash", "tools/lang/qjs-cancel-edges-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qjs-cancel-edges-test", "Negative cancellation edges (pure-JS, LLVM): post-complete/failed-submit/late-completion cancels are harmless, FS read non-empty under QEMU", &.{ "bash", "tools/lang/qjs-cancel-edges-test.sh", "zig-out/bin/mcc", "llvm" });

    // The host ITSELF in MC (examples/apps/qjs_host.mc): MC drives the QuickJS C API directly —
    // JSValue (the 16-byte struct) by value, JS_Eval/JS_GetPropertyStr/JS_ToInt32 from MC —
    // evaluating 6*7=42 confined. Proves the host need not be C either. Both backends.
    _ = h.addScriptTest(ctx, "qjs-mc-host-test", "An MC host (not C) drives QuickJS and evaluates JS, confined under QEMU", &.{ "bash", "tools/lang/qjs-mc-host-test.sh", "zig-out/bin/mcc", "c", "", "6*7 -> 42", "qjs-mc-host" });

    _ = h.addScriptTest(ctx, "llvm-qjs-mc-host-test", "An MC host drives QuickJS, confined under QEMU (LLVM)", &.{ "bash", "tools/lang/qjs-mc-host-test.sh", "zig-out/bin/mcc", "llvm", "", "6*7 -> 42", "qjs-mc-host" });

    _ = h.addScriptTest(ctx, "agent-confined-tool-test", "Step 0 + M1: a confined U-mode agent drives the capability tool front door via syscalls; /workspace allowed, /etc denied under QEMU", &.{ "bash", "tools/proc/agent-confined-tool-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-confined-tool-test", "Step 0 + M1 (LLVM): a confined U-mode agent drives the capability tool front door; /workspace allowed, /etc denied under QEMU", &.{ "bash", "tools/proc/agent-confined-tool-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "driver-test", "Run the char-device driver framework (vtable dispatch) under QEMU", &.{ "bash", "tools/arch/driver-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-driver-test", "Run LLVM-lowered char-device driver framework under QEMU", &.{ "bash", "tools/arch/driver-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "fs-syscall-test", "Run U-mode file syscalls (open/write/read/close) over the VFS under QEMU", &.{ "bash", "tools/fs/fs-syscall-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-fs-syscall-test", "Run LLVM-lowered U-mode file syscalls over the VFS under QEMU", &.{ "bash", "tools/fs/fs-syscall-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "socket-syscall-test", "Run U-mode recvfrom over the UDP socket layer under QEMU", &.{ "bash", "tools/net/socket-syscall-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-socket-syscall-test", "Run LLVM-lowered U-mode recvfrom over the UDP socket layer under QEMU", &.{ "bash", "tools/net/socket-syscall-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "exec-test", "Run sys_exec: a U-mode program loads + runs another ELF under QEMU", &.{ "bash", "tools/lang/exec-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-exec-test", "Run LLVM-lowered sys_exec under QEMU", &.{ "bash", "tools/lang/exec-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "paging-activate-test", "Activate Sv39 satp in S-mode and read a translation-only VA under QEMU", &.{ "bash", "tools/mem/paging-activate-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-paging-activate-test", "Run LLVM-lowered Sv39 activation under QEMU", &.{ "bash", "tools/mem/paging-activate-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "kmain-test", "Boot one integrated kernel image (heap+console+log+VFS+scheduler) under QEMU", &.{ "bash", "tools/proc/kmain-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-kmain-test", "Boot one LLVM-lowered integrated kernel image under QEMU", &.{ "bash", "tools/proc/kmain-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "agentos-test", "Boot the agent-OS governance keystone (OOM-kill + reclaim) under QEMU", &.{ "bash", "tools/proc/agentos-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agentos-test", "Boot the LLVM-lowered agent-OS governance keystone under QEMU", &.{ "bash", "tools/proc/agentos-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "fault-isolation-test", "Boot the F1 fault-isolation keystone (a real agent trap is contained: faulting agent killed+reclaimed, kernel+others survive) under QEMU", &.{ "bash", "tools/proc/fault-isolation-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-fault-isolation-test", "Boot the LLVM-lowered F1 fault-isolation keystone under QEMU", &.{ "bash", "tools/proc/fault-isolation-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "agent-e2e-test", "Boot the end-to-end sandboxed-agent showcase (capability-checked/budgeted/audited tool calls) under QEMU", &.{ "bash", "tools/proc/agent-e2e-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-e2e-test", "Boot the LLVM-lowered end-to-end sandboxed-agent showcase under QEMU", &.{ "bash", "tools/proc/agent-e2e-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "agent-net-test", "Boot the agent-OS network-model showcase (brokered/egress-checked/budgeted/audited network calls) under QEMU", &.{ "bash", "tools/proc/agent-net-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-net-test", "Boot the LLVM-lowered agent-OS network-model showcase under QEMU", &.{ "bash", "tools/proc/agent-net-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "agent-net-real-test", "Boot the agent-OS network model with the REAL tcp_socket transport: a sandboxed agent makes a genuinely brokered (egress-checked/budgeted/audited) network call to a live server under QEMU", &.{ "bash", "tools/proc/agent-net-real-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-agent-net-real-test", "Boot the LLVM-lowered agent-OS real-transport brokered network call under QEMU", &.{ "bash", "tools/proc/agent-net-real-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "kmain-net-test", "Boot the integrated kernel + network in one image under QEMU", &.{ "bash", "tools/net/kmain-net-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-kmain-net-test", "Boot the LLVM-lowered integrated kernel + network image under QEMU", &.{ "bash", "tools/net/kmain-net-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vm-switch-test", "Switch satp between two address spaces under QEMU (per-process VM)", &.{ "bash", "tools/mem/vm-switch-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vm-switch-test", "Run LLVM-lowered satp switching between two address spaces under QEMU", &.{ "bash", "tools/mem/vm-switch-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vmspace-test", "Per-process page tables: switch satp by process slot under QEMU", &.{ "bash", "tools/mem/vmspace-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vmspace-test", "Run LLVM-lowered per-process page tables under QEMU", &.{ "bash", "tools/mem/vmspace-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vmctx-test", "Context switch that swaps satp per thread under QEMU", &.{ "bash", "tools/mem/vmctx-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vmctx-test", "Run LLVM-lowered context switching with satp swaps under QEMU", &.{ "bash", "tools/mem/vmctx-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "sched-vm-test", "Scheduler switching per-process address spaces (proc_yield_vm) under QEMU", &.{ "bash", "tools/proc/sched-vm-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-sched-vm-test", "Run LLVM-lowered scheduler switching per-process address spaces under QEMU", &.{ "bash", "tools/proc/sched-vm-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTestOpts(ctx, "run-ushell", "Build + boot the user-mode MC shell in QEMU (interactive)", &.{ "bash", "tools/lang/run-ushell.sh", "c" }, .{ .inherit_stdio = true });

    _ = h.addScriptTestOpts(ctx, "run-llvm-ushell", "Build + boot the LLVM-lowered user-mode MC shell in QEMU (interactive)", &.{ "bash", "tools/lang/run-ushell.sh", "llvm" }, .{ .inherit_stdio = true });

    // Preflight: explicit toolchain check for the QEMU milestone gates (clang/ld.lld/llc/qemu +
    // riscv64 target). `zig build preflight`. Milestone gates with MC_REQUIRE_TOOLS=1/CI=1 fail
    // rather than skip when a tool is missing (tools/qemu/kernel-boot-lib.sh).
    _ = h.addScriptTestOpts(ctx, "preflight", "Check the toolchain (clang/ld.lld/llc/qemu + riscv64 target) the QEMU milestone gates need", &.{ "bash", "tools/preflight.sh" }, .{ .install = false });
}
