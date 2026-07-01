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
        "qjs-smode-confined-test",
        "llvm-qjs-smode-confined-test",
        "qjs-smode-agent-test",
        "llvm-qjs-smode-agent-test",
        "qjs-realtool-test",
        "llvm-qjs-realtool-test",
        "qjs-nettool-test",
        "llvm-qjs-nettool-test",
        "qjs-net-realtool-test",
        "llvm-qjs-net-realtool-test",
        "qjs-smode-net-irq-tool-test",
        "llvm-qjs-smode-net-irq-tool-test",
        "qjs-smode-blk-irq-tool-test",
        "llvm-qjs-smode-blk-irq-tool-test",
        "visionfive2-readiness-test",
        "llvm-visionfive2-readiness-test",
    };

    const riscv_qemu_validation_step = b.step("riscv-qemu-validation", "Run the RISC-V QEMU/OpenSBI validation surrogate for the selected real-board path");
    for (riscv_qemu_validation) |name| {
        riscv_qemu_validation_step.dependOn(ctx.cmd(name));
    }

    const m0_step = b.step("m0", "Run M0 conformance gates");
    // Fixture-contract lint guards the test corpus itself (reject EXPECT lines, sweep
    // OUT_OF_SCOPE soundness, host-tests.tsv well-formedness). It belongs in every
    // conformance tier, not only `fast`, so a contract regression can't slip into m0/c0/c1.
    m0_step.dependOn(ctx.cmd("test-lint"));
    m0_step.dependOn(ctx.cmd("abi-consistency-test"));
    m0_step.dependOn(ctx.cmd("arch-emit-test"));
    m0_step.dependOn(ctx.cmd("test"));
    m0_step.dependOn(ctx.cmd("c-test"));
    m0_step.dependOn(ctx.cmd("sweep"));
    m0_step.dependOn(ctx.cmd("sanitize"));
    m0_step.dependOn(ctx.cmd("diff-backend"));
    m0_step.dependOn(ctx.cmd("diff-fuzz"));
    m0_step.dependOn(ctx.cmd("move-fuzz"));
    m0_step.dependOn(ctx.cmd("fuzz"));
    m0_step.dependOn(ctx.cmd("fuzz-sanitize"));
    m0_step.dependOn(ctx.cmd("fuzz-trap"));
    m0_step.dependOn(ctx.cmd("fuzz-robust"));
    m0_step.dependOn(ctx.cmd("fuzz-failclosed"));
    m0_step.dependOn(ctx.cmd("fuzz-determinism"));
    m0_step.dependOn(ctx.cmd("fuzz-pipeline"));
    // LLVM backend gates: IR assembly, object lowering, spec sweep, broad
    // c_emit fixture sweeps, and host link/run smoke tests.
    m0_step.dependOn(ctx.cmd("llvm-test"));
    m0_step.dependOn(ctx.cmd("llvm-obj-test"));
    m0_step.dependOn(ctx.cmd("llvm-debug-test"));
    m0_step.dependOn(ctx.cmd("llvm-sweep"));
    m0_step.dependOn(ctx.cmd("llvm-spec-obj-sweep"));
    m0_step.dependOn(ctx.cmd("llvm-c-sweep"));
    m0_step.dependOn(ctx.cmd("llvm-opt-sweep"));
    m0_step.dependOn(ctx.cmd("llvm-c-obj-sweep"));
    m0_step.dependOn(ctx.cmd("llvm-cc-test"));
    m0_step.dependOn(ctx.cmd("llvm-move-test"));
    m0_step.dependOn(ctx.cmd("llvm-runtime-test"));
    m0_step.dependOn(ctx.cmd("llvm-std-test"));
    m0_step.dependOn(ctx.cmd("llvm-toolchain-test"));
    m0_step.dependOn(ctx.cmd("llvm-pkg-test"));
    m0_step.dependOn(ctx.cmd("llvm-demo-test"));
    m0_step.dependOn(ctx.cmd("llvm-kernel-test"));
    m0_step.dependOn(ctx.cmd("llvm-hosted-demo-test"));
    m0_step.dependOn(ctx.cmd("llvm-host-suite-test"));
    m0_step.dependOn(ctx.cmd("llvm-qemu-test"));
    m0_step.dependOn(ctx.cmd("llvm-trap-test"));
    m0_step.dependOn(ctx.cmd("llvm-thread-test"));
    m0_step.dependOn(ctx.cmd("llvm-sched-test"));
    m0_step.dependOn(ctx.cmd("llvm-syscall-test"));
    m0_step.dependOn(ctx.cmd("llvm-user-test"));
    m0_step.dependOn(ctx.cmd("llvm-process-test"));
    m0_step.dependOn(ctx.cmd("llvm-elf-run-test"));
    m0_step.dependOn(ctx.cmd("llvm-uaccess-pt-test"));
    m0_step.dependOn(ctx.cmd("llvm-elf-loader-test"));
    m0_step.dependOn(ctx.cmd("llvm-uaccess-snapshot-test"));
    m0_step.dependOn(ctx.cmd("llvm-uaccess-taint-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-confined-test"));
    m0_step.dependOn(ctx.cmd("llvm-app-run-test"));
    m0_step.dependOn(ctx.cmd("llvm-compute-app-test"));
    m0_step.dependOn(ctx.cmd("math-app-test"));
    m0_step.dependOn(ctx.cmd("llvm-math-app-test"));
    m0_step.dependOn(ctx.cmd("trig-app-test"));
    m0_step.dependOn(ctx.cmd("llvm-trig-app-test"));
    m0_step.dependOn(ctx.cmd("vararg-test"));
    m0_step.dependOn(ctx.cmd("llvm-vararg-test"));
    m0_step.dependOn(ctx.cmd("qjs-alloc-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-alloc-test"));
    m0_step.dependOn(ctx.cmd("cstr-test"));
    m0_step.dependOn(ctx.cmd("llvm-cstr-test"));
    m0_step.dependOn(ctx.cmd("cnum-test"));
    m0_step.dependOn(ctx.cmd("llvm-cnum-test"));
    m0_step.dependOn(ctx.cmd("stdio-test"));
    m0_step.dependOn(ctx.cmd("llvm-stdio-test"));
    m0_step.dependOn(ctx.cmd("qjs-run-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-run-test"));
    m0_step.dependOn(ctx.cmd("wamr-run-test"));
    m0_step.dependOn(ctx.cmd("llvm-wamr-run-test"));
    m0_step.dependOn(ctx.cmd("wamr-fuel-test"));
    m0_step.dependOn(ctx.cmd("llvm-wamr-fuel-test"));
    m0_step.dependOn(ctx.cmd("wamr-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wamr-agent-test"));
    // The wamr-{wasi-hello,async,net,fs,js} gates were the pre-flip WAMR proofs; the wasm-* gates now
    // run on WAMR (see wasm-confined-test.sh), so those duplicates are dropped. wamr-run/fuel/agent
    // stay: the engine spike, the UNIQUE deterministic-fuel gate, and the freestanding-mc agent.
    m0_step.dependOn(ctx.cmd("wasm-wasi-hello-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-wasi-hello-test"));
    m0_step.dependOn(ctx.cmd("wasm-realtool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-realtool-test"));
    m0_step.dependOn(ctx.cmd("wasm-nettool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-nettool-test"));
    m0_step.dependOn(ctx.cmd("wasm-js-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-js-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-js-nettool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-js-nettool-test"));
    m0_step.dependOn(ctx.cmd("wasm-async-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-async-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-cancel-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-cancel-test"));
    m0_step.dependOn(ctx.cmd("wasm-quota-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-quota-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-spurious-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-spurious-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-agent-smoke-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-agent-smoke-test"));
    m0_step.dependOn(ctx.cmd("wasm-cancel-edges-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-cancel-edges-test"));
    m0_step.dependOn(ctx.cmd("wasm-broker-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-broker-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-smode-confined-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-smode-confined-test"));
    m0_step.dependOn(ctx.cmd("wasm-smode-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-smode-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-smode-async-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-smode-async-agent-test"));
    m0_step.dependOn(ctx.cmd("wasm-smode-net-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-smode-net-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("wasm-smode-blk-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-smode-blk-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("wasm-net-realtool-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-net-realtool-test"));
    m0_step.dependOn(ctx.cmd("arm-wasm-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-arm-wasm-async-test"));
    m0_step.dependOn(ctx.cmd("x86-wasm-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-wasm-async-test"));
    m0_step.dependOn(ctx.cmd("wasm-js-bench-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-js-bench-test"));
    m0_step.dependOn(ctx.cmd("wasm-memcap-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-memcap-test"));
    m0_step.dependOn(ctx.cmd("sbrk-grow-test"));
    m0_step.dependOn(ctx.cmd("llvm-sbrk-grow-test"));
    m0_step.dependOn(ctx.cmd("wasm-watchdog-test"));
    m0_step.dependOn(ctx.cmd("llvm-wasm-watchdog-test"));
    m0_step.dependOn(ctx.cmd("qjs-confined-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-confined-test"));
    m0_step.dependOn(ctx.cmd("qjs-smode-confined-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-smode-confined-test"));
    m0_step.dependOn(ctx.cmd("qjs-smode-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-smode-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-smode-async-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-smode-async-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-realtool-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-realtool-test"));
    m0_step.dependOn(ctx.cmd("qjs-nettool-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-nettool-test"));
    m0_step.dependOn(ctx.cmd("qjs-net-realtool-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-net-realtool-test"));
    m0_step.dependOn(ctx.cmd("qjs-smode-net-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-smode-net-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("qjs-smode-blk-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-smode-blk-irq-tool-test"));
    m0_step.dependOn(ctx.cmd("qjs-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-async-test"));
    m0_step.dependOn(ctx.cmd("qjs-io-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-io-test"));
    m0_step.dependOn(ctx.cmd("qjs-worker-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-worker-test"));
    m0_step.dependOn(ctx.cmd("qjs-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-async-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-async-agent-test"));
    m0_step.dependOn(ctx.cmd("fault-probe-test"));
    m0_step.dependOn(ctx.cmd("llvm-fault-probe-test"));
    m0_step.dependOn(ctx.cmd("quota-probe-test"));
    m0_step.dependOn(ctx.cmd("llvm-quota-probe-test"));
    m0_step.dependOn(ctx.cmd("qjs-quota-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-quota-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-cancel-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-cancel-test"));
    m0_step.dependOn(ctx.cmd("qjs-agent-smoke-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-agent-smoke-test"));
    m0_step.dependOn(ctx.cmd("qjs-cancel-edges-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-cancel-edges-test"));
    m0_step.dependOn(ctx.cmd("broker-probe-test"));
    m0_step.dependOn(ctx.cmd("llvm-broker-probe-test"));
    m0_step.dependOn(ctx.cmd("qjs-broker-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-broker-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-spurious-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-spurious-agent-test"));
    m0_step.dependOn(ctx.cmd("qjs-mc-host-test"));
    m0_step.dependOn(ctx.cmd("llvm-qjs-mc-host-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-confined-tool-test"));
    m0_step.dependOn(ctx.cmd("llvm-fs-syscall-test"));
    m0_step.dependOn(ctx.cmd("llvm-socket-syscall-test"));
    m0_step.dependOn(ctx.cmd("llvm-exec-test"));
    m0_step.dependOn(ctx.cmd("llvm-kmain-test"));
    m0_step.dependOn(ctx.cmd("llvm-kmain-net-test"));
    m0_step.dependOn(ctx.cmd("llvm-vm-switch-test"));
    m0_step.dependOn(ctx.cmd("llvm-vmspace-test"));
    m0_step.dependOn(ctx.cmd("llvm-vmctx-test"));
    m0_step.dependOn(ctx.cmd("llvm-sched-vm-test"));
    m0_step.dependOn(ctx.cmd("llvm-timeout-test"));
    m0_step.dependOn(ctx.cmd("llvm-signal-test"));
    m0_step.dependOn(ctx.cmd("llvm-registry-test"));
    m0_step.dependOn(ctx.cmd("llvm-ipc2-test"));
    m0_step.dependOn(ctx.cmd("llvm-ipc-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-irq-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-cancel-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-pollmany-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-future-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-multi-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-blk-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-net-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-select-test"));
    m0_step.dependOn(ctx.cmd("llvm-async-agent-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-async-api-test"));
    m0_step.dependOn(ctx.cmd("llvm-usched-test"));
    m0_step.dependOn(ctx.cmd("llvm-heartbeat-test"));
    m0_step.dependOn(ctx.cmd("llvm-privilege-test"));
    m0_step.dependOn(ctx.cmd("llvm-cap-test"));
    m0_step.dependOn(ctx.cmd("llvm-restart-test"));
    m0_step.dependOn(ctx.cmd("llvm-contain-test"));
    m0_step.dependOn(ctx.cmd("llvm-cow-test"));
    m0_step.dependOn(ctx.cmd("llvm-isolation-test"));
    m0_step.dependOn(ctx.cmd("llvm-demand-test"));
    m0_step.dependOn(ctx.cmd("llvm-mmap-test"));
    m0_step.dependOn(ctx.cmd("llvm-paging-activate-test"));
    m0_step.dependOn(ctx.cmd("llvm-block-server-test"));
    m0_step.dependOn(ctx.cmd("llvm-fs-server-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-server-test"));
    m0_step.dependOn(ctx.cmd("llvm-rtc-test"));
    m0_step.dependOn(ctx.cmd("llvm-userserver-test"));
    m0_step.dependOn(ctx.cmd("llvm-backtrace-test"));
    m0_step.dependOn(ctx.cmd("llvm-driver-test"));
    m0_step.dependOn(ctx.cmd("llvm-preempt-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-preempt-test"));
    // llvm-proc-supervisor-test runs the LLVM-lowered running supervisor loop (proc_supervisor_scan) under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-proc-supervisor-test"));
    // llvm-instrument-test runs the LLVM-lowered instrumented ProcTable (ledger + metrics + supervision-tree/leases) under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-instrument-test"));
    // llvm-ledger-test runs the LLVM-lowered unified resource ledger under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-ledger-test"));
    // llvm-soak-test runs the LLVM-lowered single-boot soak workload under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-soak-test"));
    m0_step.dependOn(ctx.cmd("llvm-signed-boot-test"));
    // llvm-ota-test runs the LLVM-lowered chunked OTA transport + admission + rollback under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-ota-test"));
    // llvm-metrics-test runs the LLVM-lowered structured metrics + deterministic replay under QEMU.
    m0_step.dependOn(ctx.cmd("llvm-metrics-test"));
    m0_step.dependOn(ctx.cmd("llvm-page-test"));
    m0_step.dependOn(ctx.cmd("llvm-heap-test"));
    m0_step.dependOn(ctx.cmd("llvm-paging-test"));
    m0_step.dependOn(ctx.cmd("llvm-smp-test"));
    m0_step.dependOn(ctx.cmd("llvm-smp-lock-test"));
    m0_step.dependOn(ctx.cmd("llvm-ipi-test"));
    m0_step.dependOn(ctx.cmd("llvm-tcp-server-test"));
    m0_step.dependOn(ctx.cmd("llvm-virtio-test"));
    m0_step.dependOn(ctx.cmd("llvm-udp-net-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-smode-test"));
    m0_step.dependOn(ctx.cmd("llvm-smode-timer-test"));
    // smode-plic-test proves REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI;
    // the multishot variant proves the re-armed steady-state path (regression gate for the former
    // C-backend async-IRQ reset, fixed by #[align(4)] on naked trap vectors).
    m0_step.dependOn(ctx.cmd("llvm-smode-plic-test"));
    m0_step.dependOn(ctx.cmd("llvm-smode-plic-multishot-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-smode-irq-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-smode-irq-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-smode-rx-irq-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-smode-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-test"));
    m0_step.dependOn(ctx.cmd("llvm-nic-test"));
    m0_step.dependOn(ctx.cmd("llvm-e1000-test"));
    m0_step.dependOn(ctx.cmd("llvm-net-rx-live-test"));
    m0_step.dependOn(ctx.cmd("llvm-http-get-test"));
    m0_step.dependOn(ctx.cmd("llvm-dns-test"));
    m0_step.dependOn(ctx.cmd("llvm-https-get-test"));

    // qemu-test is gated separately (needs a riscv cross-toolchain + QEMU); it
    // self-skips when those are absent, so it is safe to include in m0 too.
    m0_step.dependOn(ctx.cmd("qemu-test"));
    // cc-test exercises the mcc-cc toolchain driver (needs clang); self-skips
    // when clang is absent.
    m0_step.dependOn(ctx.cmd("cc-test"));
    // std-test compiles and runs std/core through the toolchain (needs clang).
    m0_step.dependOn(ctx.cmd("std-test"));
    // import-test exercises the module system end-to-end (needs clang).
    m0_step.dependOn(ctx.cmd("import-test"));
    // mono-test exercises comptime-parameter monomorphization (needs clang).
    m0_step.dependOn(ctx.cmd("mono-test"));
    // reflect-test validates the comptime layout model against the C ABI.
    m0_step.dependOn(ctx.cmd("reflect-test"));
    // abi-test validates advanced packed/overlay/MMIO layout against the C ABI + LLVM.
    m0_step.dependOn(ctx.cmd("abi-test"));
    // opt-test validates the fact-gated MIR optimizer (const-index bounds-check elision).
    m0_step.dependOn(ctx.cmd("opt-test"));
    // opt-equiv-test validates the elided bounds check is behavior-preserving (C vs LLVM).
    m0_step.dependOn(ctx.cmd("opt-equiv-test"));
    // reproducible-build-test validates emitted C + LLVM text is byte-identical across two compiles.
    m0_step.dependOn(ctx.cmd("reproducible-build-test"));
    // safe-release-parity (D2.5): SAFE/RELEASE profiles agree functionally; RELEASE elides
    // only the optimizer-proven-dead checks SAFE keeps.
    m0_step.dependOn(ctx.cmd("safe-release-parity"));
    // comptime-fold-test validates comptime-only folds (byte strings, wrap/sat domains).
    m0_step.dependOn(ctx.cmd("comptime-fold-test"));
    // asm-targets-test validates per-architecture precise-asm register vocabularies.
    m0_step.dependOn(ctx.cmd("asm-targets-test"));
    // mcmap-test validates .mcmap stable IDs + object-symbol correlation on both backends.
    m0_step.dependOn(ctx.cmd("mcmap-test"));
    // fmt-test validates the formatter; mcc-symbols-test the symbol index; lsp-test the server;
    // editor-client-test the VS Code client.
    m0_step.dependOn(ctx.cmd("fmt-test"));
    m0_step.dependOn(ctx.cmd("mcc-symbols-test"));
    m0_step.dependOn(ctx.cmd("lsp-test"));
    m0_step.dependOn(ctx.cmd("editor-client-test"));
    // pkg-test exercises the mcc-pkg manifest build (needs clang).
    m0_step.dependOn(ctx.cmd("pkg-test"));
    // pkg-registry-test exercises registry publish/resolve/install + lockfile reproducibility.
    m0_step.dependOn(ctx.cmd("pkg-registry-test"));
    // stack-test exercises the generic std/stack collection (needs clang).
    m0_step.dependOn(ctx.cmd("stack-test"));
    // move-test exercises linear `move` handle erasure (needs clang).
    m0_step.dependOn(ctx.cmd("move-test"));
    // try-defer-test checks `defer` runs on the `?` error branch in both backends (needs clang).
    m0_step.dependOn(ctx.cmd("try-defer-test"));
    // sync-test exercises std/sync locks + linear guards (needs clang).
    m0_step.dependOn(ctx.cmd("sync-test"));
    // nic-test runs the demo NIC driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(ctx.cmd("nic-test"));
    // virtio-test runs the real virtio-net driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(ctx.cmd("virtio-test"));
    // blk-test runs the virtio-blk driver reading a sector under QEMU.
    m0_step.dependOn(ctx.cmd("blk-test"));
    m0_step.dependOn(ctx.cmd("blk-persist-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-persist-test"));
    // blk-audit-persist-test proves a block-backed policy/audit checkpoint survives a real reboot.
    m0_step.dependOn(ctx.cmd("blk-audit-persist-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-audit-persist-test"));
    // blk-audit-frame-persist-test proves a block-backed AUDIT FRAME (drained IpcTrace provenance) survives a real reboot.
    m0_step.dependOn(ctx.cmd("blk-audit-frame-persist-test"));
    m0_step.dependOn(ctx.cmd("llvm-blk-audit-frame-persist-test"));
    // blk-smode-test revalidates the same virtio-blk driver under REAL OpenSBI in S-mode.
    m0_step.dependOn(ctx.cmd("blk-smode-test"));
    // smode-timer-test proves REAL S-mode timer-interrupt delivery under OpenSBI (SBI TIME ext).
    m0_step.dependOn(ctx.cmd("smode-timer-test"));
    // smode-plic-test proves REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI;
    // the multishot variant proves the re-armed steady-state path on the C backend (regression
    // gate for the former async-IRQ reset).
    m0_step.dependOn(ctx.cmd("smode-plic-test"));
    m0_step.dependOn(ctx.cmd("smode-plic-multishot-test"));
    m0_step.dependOn(ctx.cmd("blk-smode-irq-test"));
    m0_step.dependOn(ctx.cmd("net-smode-irq-test"));
    m0_step.dependOn(ctx.cmd("net-smode-rx-irq-test"));
    m0_step.dependOn(ctx.cmd("net-smode-test"));
    // bearssl-smode-test revalidates the freestanding BearSSL SHA-256 + virtio-rng
    // entropy (the TLS crypto stack) under REAL OpenSBI in S-mode. Deterministic (no
    // network egress), so gated in m0.
    m0_step.dependOn(ctx.cmd("bearssl-smode-test"));
    // rsa-verify-test proves the MC signature-verify binding over BearSSL i31 (signed-bundle
    // primitive, P4): a real RSA-2048/SHA-256 signature verifies; tampered + wrong-message
    // are rejected. Host-based, deterministic, both backends.
    m0_step.dependOn(ctx.cmd("rsa-verify-test"));
    m0_step.dependOn(ctx.cmd("llvm-rsa-verify-test"));
    // https-smode-test revalidates the in-kernel REAL BearSSL TLS 1.2 handshake +
    // HTTPS GET under REAL OpenSBI in S-mode. Deterministic — the TLS peer is a
    // LOCAL python server over slirp loopback (no internet egress) — so gated in m0
    // (mirrors the M-mode https-get-test, which is also in m0).
    m0_step.dependOn(ctx.cmd("https-smode-test"));
    // udp-net-test transmits a real UDP datagram over virtio-net (pcap-verified).
    m0_step.dependOn(ctx.cmd("udp-net-test"));
    // smp-test boots multiple harts synchronizing on a shared atomic under QEMU.
    m0_step.dependOn(ctx.cmd("smp-test"));
    // smp-lock-test contends a ticket spinlock across harts under QEMU.
    m0_step.dependOn(ctx.cmd("smp-lock-test"));
    // ipi-test sends a CLINT software interrupt between harts under QEMU.
    m0_step.dependOn(ctx.cmd("ipi-test"));
    // demo-test compile-checks the whole demo/ suite (needs clang).
    m0_step.dependOn(ctx.cmd("demo-test-strict"));
    // net-test runs the kernel virtio-net RX/TX ARP exchange under QEMU.
    m0_step.dependOn(ctx.cmd("net-test"));
    // kernel-test compile-checks kernel/ for riscv64 + typestate rejects.
    m0_step.dependOn(ctx.cmd("kernel-test-strict"));
    // page-test links + runs the physical frame allocator (needs clang).
    m0_step.dependOn(ctx.cmd("page-test"));
    // heap-test links + runs the kernel heap (needs clang).
    m0_step.dependOn(ctx.cmd("heap-test"));
    // redzone-test boots the D2.4 redzone+canary demo under QEMU (needs clang+qemu).
    m0_step.dependOn(ctx.cmd("redzone-test"));
    m0_step.dependOn(ctx.cmd("llvm-redzone-test"));
    // ksan-test (D2.1): access-time UAF/OOB detection via KASAN shadow memory.
    m0_step.dependOn(ctx.cmd("ksan-test"));
    m0_step.dependOn(ctx.cmd("llvm-ksan-test"));
    // kmsan-test (D2.2): access-time use-of-uninitialized-heap detection on the ksan shadow.
    m0_step.dependOn(ctx.cmd("kmsan-test"));
    m0_step.dependOn(ctx.cmd("llvm-kmsan-test"));
    // kcsan-test (D2.3): data-race detection via a watchpoint on the shadow (csan profile).
    m0_step.dependOn(ctx.cmd("kcsan-test"));
    // elf-test links + runs the ELF64 parser (needs clang).
    m0_step.dependOn(ctx.cmd("elf-test"));
    // ramfs-test links + runs the in-memory filesystem (needs clang).
    m0_step.dependOn(ctx.cmd("ramfs-test"));
    // vfs-test links + runs the fd-table VFS over ramfs (needs clang).
    m0_step.dependOn(ctx.cmd("vfs-test"));
    // blockfs-test links + runs the block-backed file store (needs clang).
    m0_step.dependOn(ctx.cmd("blockfs-test"));
    // udp-test links + runs the UDP build/parse + checksum (needs clang).
    m0_step.dependOn(ctx.cmd("udp-test"));
    m0_step.dependOn(ctx.cmd("dns-host-test"));
    // alloc-test links + runs the type-erased Allocator (needs clang).
    m0_step.dependOn(ctx.cmd("alloc-test"));
    m0_step.dependOn(ctx.cmd("arc-test"));
    m0_step.dependOn(ctx.cmd("constgen-test"));
    m0_step.dependOn(ctx.cmd("ipc2-test"));
    m0_step.dependOn(ctx.cmd("registry-test"));
    m0_step.dependOn(ctx.cmd("signal-test"));
    m0_step.dependOn(ctx.cmd("privilege-test"));
    m0_step.dependOn(ctx.cmd("timeout-test"));
    m0_step.dependOn(ctx.cmd("heartbeat-test"));
    m0_step.dependOn(ctx.cmd("diskfs-test"));
    m0_step.dependOn(ctx.cmd("mmap-test"));
    m0_step.dependOn(ctx.cmd("demand-test"));
    m0_step.dependOn(ctx.cmd("isolation-test"));
    m0_step.dependOn(ctx.cmd("userserver-test"));
    m0_step.dependOn(ctx.cmd("usched-test"));
    m0_step.dependOn(ctx.cmd("cow-test"));
    m0_step.dependOn(ctx.cmd("pipe-test"));
    m0_step.dependOn(ctx.cmd("bcache-test"));
    m0_step.dependOn(ctx.cmd("perm-test"));
    m0_step.dependOn(ctx.cmd("pgroup-test"));
    m0_step.dependOn(ctx.cmd("tty-test"));
    m0_step.dependOn(ctx.cmd("time-test"));
    m0_step.dependOn(ctx.cmd("vqfault-test"));
    m0_step.dependOn(ctx.cmd("wrap-test"));
    m0_step.dependOn(ctx.cmd("args-test"));
    m0_step.dependOn(ctx.cmd("libc-test"));
    // hosted-test runs the hosted-profile float I/O round-trip (needs clang+python3).
    m0_step.dependOn(ctx.cmd("hosted-test"));
    m0_step.dependOn(ctx.cmd("shell-test"));
    m0_step.dependOn(ctx.cmd("shell2-test"));
    m0_step.dependOn(ctx.cmd("ushell-test"));
    m0_step.dependOn(ctx.cmd("llvm-ushell-test"));
    m0_step.dependOn(ctx.cmd("vfsmount-test"));
    // treefs-test links + runs the hierarchical tree filesystem (needs clang); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("treefs-test"));
    // fs-toolserver-test links + runs the capability-checked FS tool server (M1); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("fs-toolserver-test"));
    // agent-fs-test links + runs the agent FS tool front door (M3 seed); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("agent-fs-test"));
    // policy-test links + runs the policy-plane drainer (M5 seed); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("policy-test"));
    // persistent-audit-test links + runs the BlobStore-backed policy/audit checkpoint substrate.
    m0_step.dependOn(ctx.cmd("persistent-audit-test"));
    // block-persistent-audit-test moves the policy/audit checkpoint substrate onto BlockDevice.
    m0_step.dependOn(ctx.cmd("block-persistent-audit-test"));
    // agent-abi-test pins the versioned SYS_SUBMIT/SYS_POLL request/completion contract.
    m0_step.dependOn(ctx.cmd("agent-abi-test"));
    // production-ops-test gates bundle/update/watchdog/reboot/policy-actuation state transitions.
    m0_step.dependOn(ctx.cmd("production-ops-test"));
    // netcap-test links + runs capability-gated network egress (milestone #3); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("netcap-test"));
    // agent-containment-test links + runs the capstone M6-shape integration; LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("agent-containment-test"));
    // mcp-test links + runs the MCP-compatible facade (M4); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("mcp-test"));
    // showcase-test links + runs the language feature showcase (emit-c); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(ctx.cmd("showcase-test"));
    // mc-test runs the native #[test] facility (process-isolated) on both backends.
    m0_step.dependOn(ctx.cmd("mc-test"));
    m0_step.dependOn(ctx.cmd("llvm-mc-test"));
    // mod-visibility-test checks opt-in `pub` module boundaries on both backends.
    m0_step.dependOn(ctx.cmd("mod-visibility-test"));
    m0_step.dependOn(ctx.cmd("llvm-mod-visibility-test"));
    // sort-test exercises std/sort on both backends.
    m0_step.dependOn(ctx.cmd("sort-test"));
    m0_step.dependOn(ctx.cmd("llvm-sort-test"));
    m0_step.dependOn(ctx.cmd("fdspace-test"));
    m0_step.dependOn(ctx.cmd("snapshot-test"));
    m0_step.dependOn(ctx.cmd("waitqueue-test"));
    m0_step.dependOn(ctx.cmd("service-test"));
    m0_step.dependOn(ctx.cmd("plugin-test"));
    m0_step.dependOn(ctx.cmd("endpoint-test"));
    m0_step.dependOn(ctx.cmd("supervisor-test"));
    m0_step.dependOn(ctx.cmd("registry2-test"));
    m0_step.dependOn(ctx.cmd("manifest-test"));
    m0_step.dependOn(ctx.cmd("scheduler-test"));
    m0_step.dependOn(ctx.cmd("info-test"));
    m0_step.dependOn(ctx.cmd("granttab-test"));
    m0_step.dependOn(ctx.cmd("x86-sched-test"));
    m0_step.dependOn(ctx.cmd("x86-qemu-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-sched-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-qemu-test"));
    m0_step.dependOn(ctx.cmd("x86-vm-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-vm-test"));
    m0_step.dependOn(ctx.cmd("x86-timer-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-timer-test"));
    m0_step.dependOn(ctx.cmd("x86-pci-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-pci-test"));
    m0_step.dependOn(ctx.cmd("x86-user-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-user-test"));
    m0_step.dependOn(ctx.cmd("x86-qjs-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-qjs-test"));
    m0_step.dependOn(ctx.cmd("x86-qjs-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-x86-qjs-async-test"));
    m0_step.dependOn(ctx.cmd("slotmap-test"));
    m0_step.dependOn(ctx.cmd("mask-test"));
    m0_step.dependOn(ctx.cmd("rights-test"));
    m0_step.dependOn(ctx.cmd("mmio-test"));
    m0_step.dependOn(ctx.cmd("synclock-test"));
    m0_step.dependOn(ctx.cmd("ipc-result-test"));
    m0_step.dependOn(ctx.cmd("arp-cache-test"));
    m0_step.dependOn(ctx.cmd("tlb-shootdown-test"));
    m0_step.dependOn(ctx.cmd("mutex-test"));
    m0_step.dependOn(ctx.cmd("mailbox-test"));
    m0_step.dependOn(ctx.cmd("tryelse-test"));
    m0_step.dependOn(ctx.cmd("byteview-test"));
    m0_step.dependOn(ctx.cmd("scan-test"));
    m0_step.dependOn(ctx.cmd("posix-test"));
    m0_step.dependOn(ctx.cmd("userland-test"));
    m0_step.dependOn(ctx.cmd("smprq-test"));
    m0_step.dependOn(ctx.cmd("rtc-test"));
    m0_step.dependOn(ctx.cmd("contain-test"));
    m0_step.dependOn(ctx.cmd("tcp-server-test"));
    m0_step.dependOn(ctx.cmd("fdt-test"));
    m0_step.dependOn(ctx.cmd("fb-test"));
    m0_step.dependOn(ctx.cmd("dynlink-test"));
    m0_step.dependOn(ctx.cmd("aarch64-test"));
    m0_step.dependOn(ctx.cmd("llvm-aarch64-test"));
    m0_step.dependOn(ctx.cmd("arm-vm-test"));
    m0_step.dependOn(ctx.cmd("llvm-arm-vm-test"));
    m0_step.dependOn(ctx.cmd("arm-user-test"));
    m0_step.dependOn(ctx.cmd("llvm-arm-user-test"));
    m0_step.dependOn(ctx.cmd("arm-qjs-test"));
    m0_step.dependOn(ctx.cmd("arm-qjs-async-test"));
    m0_step.dependOn(ctx.cmd("llvm-arm-qjs-test"));
    m0_step.dependOn(ctx.cmd("llvm-arm-qjs-async-test"));
    m0_step.dependOn(ctx.cmd("liveupdate-test"));
    m0_step.dependOn(ctx.cmd("sbi-boot-test"));
    m0_step.dependOn(ctx.cmd("llvm-sbi-boot-test"));
    m0_step.dependOn(ctx.cmd("smode-user-test"));
    m0_step.dependOn(ctx.cmd("llvm-smode-user-test"));
    m0_step.dependOn(ctx.cmd("bootinfo-test"));
    m0_step.dependOn(ctx.cmd("llvm-bootinfo-test"));
    m0_step.dependOn(ctx.cmd("uart-driver-test"));
    m0_step.dependOn(ctx.cmd("llvm-uart-driver-test"));
    m0_step.dependOn(ctx.cmd("e1000-test"));
    m0_step.dependOn(ctx.cmd("grant-test"));
    m0_step.dependOn(ctx.cmd("ipc-test"));
    m0_step.dependOn(ctx.cmd("async-test"));
    m0_step.dependOn(ctx.cmd("async-irq-test"));
    m0_step.dependOn(ctx.cmd("async-cancel-test"));
    m0_step.dependOn(ctx.cmd("async-pollmany-test"));
    m0_step.dependOn(ctx.cmd("async-future-test"));
    m0_step.dependOn(ctx.cmd("async-multi-test"));
    m0_step.dependOn(ctx.cmd("async-blk-test"));
    m0_step.dependOn(ctx.cmd("async-net-test"));
    m0_step.dependOn(ctx.cmd("async-select-test"));
    m0_step.dependOn(ctx.cmd("async-agent-test"));
    m0_step.dependOn(ctx.cmd("agent-async-api-test"));
    m0_step.dependOn(ctx.cmd("block-server-test"));
    m0_step.dependOn(ctx.cmd("fs-server-test"));
    m0_step.dependOn(ctx.cmd("net-server-test"));
    m0_step.dependOn(ctx.cmd("cap-test"));
    m0_step.dependOn(ctx.cmd("restart-test"));
    m0_step.dependOn(ctx.cmd("arc-pkt-test"));
    m0_step.dependOn(ctx.cmd("arena-test"));
    m0_step.dependOn(ctx.cmd("genref-test"));
    m0_step.dependOn(ctx.cmd("owned-test"));
    m0_step.dependOn(ctx.cmd("net-arena-test"));
    m0_step.dependOn(ctx.cmd("dma-try-test"));
    m0_step.dependOn(ctx.cmd("pool-test"));
    // closure-test links + runs a bind() capturing closure (needs clang).
    m0_step.dependOn(ctx.cmd("closure-test"));
    // ring-test links + runs the generic in-place Ring<T> (needs clang).
    m0_step.dependOn(ctx.cmd("ring-test"));
    // trace-test links + runs the trace ring buffer (needs clang).
    m0_step.dependOn(ctx.cmd("trace-test"));
    // log-test links + runs the leveled tracepoint logger (needs clang).
    m0_step.dependOn(ctx.cmd("log-test"));
    // tcp-test links + runs the TCP build/parse + checksum (needs clang).
    m0_step.dependOn(ctx.cmd("tcp-test"));
    // tcp-conn-test links + runs the TCP connection state machine (needs clang).
    m0_step.dependOn(ctx.cmd("tcp-conn-test"));
    // tcp-window-test links + runs the TCP window/data-plane bookkeeping (needs clang).
    m0_step.dependOn(ctx.cmd("tcp-window-test"));
    // tcp-reasm-test links + runs TCP reassembly + go-back-N retransmit (needs clang).
    m0_step.dependOn(ctx.cmd("tcp-reasm-test"));
    // tcp-rtx-test links + runs the TCP retransmit timer (needs clang).
    m0_step.dependOn(ctx.cmd("tcp-rtx-test"));
    // symbols-test links + runs the symbol table / address symbolizer (needs clang).
    m0_step.dependOn(ctx.cmd("symbols-test"));
    // socket-test links + runs the UDP socket bind/deliver/recv layer (needs clang).
    m0_step.dependOn(ctx.cmd("socket-test"));
    // net-rx-test links + runs the RX demux path (frame -> socket_deliver) (needs clang).
    m0_step.dependOn(ctx.cmd("net-rx-test"));
    // net-fuzz-test fuzzes the RX parser with random frames (needs clang).
    m0_step.dependOn(ctx.cmd("net-fuzz-test"));
    // parser-fuzz-test (P1) fuzzes the DNS+TCP parsers with malformed/truncated bytes:
    // every parse is total over its finite buffer — no over-read, garbage rejected (clang).
    m0_step.dependOn(ctx.cmd("parser-fuzz-test"));
    // bundle-fuzz-test (P6) fuzzes the bundle/OTA admission surface (bundle_validate + rollback)
    // over adversarial headers + random op-sequences: every call total, fail-closed, no trap (clang).
    m0_step.dependOn(ctx.cmd("bundle-fuzz-test"));
    // net-rx-live-test routes a real virtio-net RX frame through net_rx_deliver under QEMU.
    m0_step.dependOn(ctx.cmd("net-rx-live-test"));
    // http-get-test active-opens a real TCP connection and HTTP GETs a live server under QEMU.
    m0_step.dependOn(ctx.cmd("http-get-test"));
    // dns-test resolves a name via a real DNS A-query then HTTP GETs that host under QEMU.
    m0_step.dependOn(ctx.cmd("dns-test"));
    // https-get-test runs a REAL BearSSL TLS 1.2 handshake over the kernel TCP and
    // decrypts an HTTPS GET from a local python HTTPS server under QEMU (Phase 2 TLS).
    m0_step.dependOn(ctx.cmd("https-get-test"));
    // NB: google-https-test (REAL google.com:443) is intentionally NOT in m0 -- it is a
    // standalone best-effort check (PASS or honest SKIP), to avoid a flaky internet gate.
    // backtrace-test walks the frame-pointer chain + symbolizes under QEMU.
    m0_step.dependOn(ctx.cmd("backtrace-test"));
    // paging-test links + runs the Sv39 page-table map/translate (needs clang).
    m0_step.dependOn(ctx.cmd("paging-test"));
    // fnptr-test links + runs function-pointer dispatch (needs clang).
    m0_step.dependOn(ctx.cmd("fnptr-test"));
    // trap-test runs the typed-CPU trap/timer interrupt path under QEMU.
    m0_step.dependOn(ctx.cmd("trap-test"));
    // thread-test runs cooperative context switching under QEMU.
    m0_step.dependOn(ctx.cmd("thread-test"));
    // sched-test runs the round-robin scheduler under QEMU.
    m0_step.dependOn(ctx.cmd("sched-test"));
    // preempt-test runs the timer-driven preemptive scheduler under QEMU.
    m0_step.dependOn(ctx.cmd("preempt-test"));
    // agent-preempt-test runs timer-driven preemption of agent PROCESSES (ProcTable) under QEMU.
    m0_step.dependOn(ctx.cmd("agent-preempt-test"));
    // proc-supervisor-test runs the running supervisor loop (proc_supervisor_scan) over supervised PROCESSES under QEMU.
    m0_step.dependOn(ctx.cmd("proc-supervisor-test"));
    // instrument-test proves the instrumented ProcTable end to end (unified ledger gating real IPC/blk/DMA ops + exact hot-path metrics + supervision-tree cascade with leases) under QEMU.
    m0_step.dependOn(ctx.cmd("instrument-test"));
    // ledger-test runs the unified resource ledger (charge/release + overflow-edge) under QEMU.
    m0_step.dependOn(ctx.cmd("ledger-test"));
    // soak-test runs the single-boot soak workload (thousands of spawn/charge/supervise/reclaim/
    // reap cycles return to baseline; no leak, no counter-overflow trap) under QEMU.
    m0_step.dependOn(ctx.cmd("soak-test"));
    // signed-boot-test runs signed-image admission + A/B rollback (production_ops) end to end under QEMU.
    m0_step.dependOn(ctx.cmd("signed-boot-test"));
    // ota-test runs chunked OTA transport (kernel/core/ota) + admission + rollback end to end under QEMU.
    m0_step.dependOn(ctx.cmd("ota-test"));
    // metrics-test runs structured metrics + deterministic event-log replay under QEMU.
    m0_step.dependOn(ctx.cmd("metrics-test"));
    // syscall-test runs the ecall syscall dispatch skeleton under QEMU.
    m0_step.dependOn(ctx.cmd("syscall-test"));
    // user-test runs the M->U privilege drop + user-mode syscalls under QEMU.
    m0_step.dependOn(ctx.cmd("user-test"));
    // process-test runs process lifecycle (spawn/run/exit) under QEMU.
    m0_step.dependOn(ctx.cmd("process-test"));
    // elf-run-test loads an ELF64 and runs it in U-mode under QEMU.
    m0_step.dependOn(ctx.cmd("elf-run-test"));
    // The uaccess demos run under QEMU (they import riscv paging.mc, so they can't run on the host suite).
    m0_step.dependOn(ctx.cmd("uaccess-pt-test"));
    m0_step.dependOn(ctx.cmd("elf-loader-test"));
    m0_step.dependOn(ctx.cmd("uaccess-snapshot-test"));
    m0_step.dependOn(ctx.cmd("uaccess-taint-test"));
    // agent-confined-test (step 0): separate ELF into an isolated address space, run confined in U-mode.
    m0_step.dependOn(ctx.cmd("agent-confined-test"));
    m0_step.dependOn(ctx.cmd("app-run-test"));
    m0_step.dependOn(ctx.cmd("compute-app-test"));
    // agent-confined-tool-test (step 0 + M1): confined U-mode agent drives the capability front door.
    m0_step.dependOn(ctx.cmd("agent-confined-tool-test"));
    // driver-test runs the char-device driver framework (vtable dispatch) under QEMU.
    m0_step.dependOn(ctx.cmd("driver-test"));
    // fs-syscall-test runs U-mode file syscalls over the VFS under QEMU.
    m0_step.dependOn(ctx.cmd("fs-syscall-test"));
    // socket-syscall-test runs U-mode recvfrom over the UDP socket layer under QEMU.
    m0_step.dependOn(ctx.cmd("socket-syscall-test"));
    // exec-test runs sys_exec: a U-mode program loads + runs another ELF under QEMU.
    m0_step.dependOn(ctx.cmd("exec-test"));
    // paging-activate-test activates Sv39 satp in S-mode + reads a translated VA.
    m0_step.dependOn(ctx.cmd("paging-activate-test"));
    // kmain-test boots one integrated kernel image (heap+console+log+VFS+scheduler).
    m0_step.dependOn(ctx.cmd("kmain-test"));
    // agentos-test boots the agent-OS governance keystone (OOM-kill + reclaim) under QEMU.
    m0_step.dependOn(ctx.cmd("agentos-test"));
    m0_step.dependOn(ctx.cmd("llvm-agentos-test"));
    // fault-isolation-test boots the F1 keystone: a real agent trap is CONTAINED (faulting agent
    // killed+reclaimed via the death path, kernel + other agents survive) under QEMU.
    m0_step.dependOn(ctx.cmd("fault-isolation-test"));
    m0_step.dependOn(ctx.cmd("llvm-fault-isolation-test"));
    // agent-e2e-test boots the end-to-end sandboxed-agent showcase under QEMU.
    m0_step.dependOn(ctx.cmd("agent-e2e-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-e2e-test"));
    m0_step.dependOn(ctx.cmd("agent-net-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-net-test"));
    // agent-net-real-test boots the broker's REAL tcp_socket transport: a sandboxed agent makes a
    // genuinely brokered (egress-checked/budgeted/audited) network call to a live server under QEMU.
    m0_step.dependOn(ctx.cmd("agent-net-real-test"));
    m0_step.dependOn(ctx.cmd("llvm-agent-net-real-test"));
    // vm-switch-test switches satp between two address spaces (per-process VM).
    m0_step.dependOn(ctx.cmd("vm-switch-test"));
    // vmspace-test switches satp per process slot (per-process page tables).
    m0_step.dependOn(ctx.cmd("vmspace-test"));
    // vmctx-test: a context switch that swaps satp per thread (address space in the switch).
    m0_step.dependOn(ctx.cmd("vmctx-test"));
    // sched-vm-test: the scheduler switches per-process address spaces (proc_yield_vm).
    m0_step.dependOn(ctx.cmd("sched-vm-test"));
    // kmain-net-test boots the integrated kernel + network in one image.
    m0_step.dependOn(ctx.cmd("kmain-net-test"));

    // fast: the inner-loop gate — every host-only m0 check that never boots an
    // emulator, so it finishes in seconds and parallelizes across cores. It is
    // the compiler/spec unit suite, the emit-C sweep, the C-vs-LLVM differential
    // and move-resource checks, and the type-directed fuzz family (generation,
    // trap consistency, checker robustness, fail-closed soundness, emit
    // determinism, and full-pipeline lowering). It deliberately omits the QEMU
    // boot tests and the env-fragile gates (LLVM-IR sweeps needing `llvm-as`, the
    // ASan/UBSan sanitize pass, and the riscv-assembler paths) — run `m0` for
    // those. Pair it with `-j` oversubscription (e.g. `zig build fast -j28`).
    const fast_step = b.step("fast", "Inner-loop gate: host-only unit + spec-coverage tests, emit-C sweep, C/LLVM differential, and the fuzz family — no QEMU");
    fast_step.dependOn(ctx.cmd("test"));
    fast_step.dependOn(ctx.cmd("test-lint"));
    fast_step.dependOn(ctx.cmd("c-test"));
    fast_step.dependOn(ctx.cmd("sweep"));
    fast_step.dependOn(ctx.cmd("diff-backend"));
    fast_step.dependOn(ctx.cmd("diff-fuzz"));
    fast_step.dependOn(ctx.cmd("move-fuzz"));
    fast_step.dependOn(ctx.cmd("fuzz"));
    fast_step.dependOn(ctx.cmd("fuzz-trap"));
    fast_step.dependOn(ctx.cmd("fuzz-robust"));
    fast_step.dependOn(ctx.cmd("fuzz-failclosed"));
    fast_step.dependOn(ctx.cmd("fuzz-determinism"));
    fast_step.dependOn(ctx.cmd("fuzz-pipeline"));

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
