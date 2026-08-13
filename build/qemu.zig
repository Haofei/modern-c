const std = @import("std");
const h = @import("helpers.zig");

// QEMU kernel/arch boot tests, the host-driver link/run suite, and every other
// per-fixture gate. The bulk of the corpus.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "move-fuzz", "Generate move-resource programs; assert every resource is released once (live_count==0) on both backends", &.{ "bash", "tools/toolchain/move-fuzz.sh", "zig-out/bin/mcc" });

    // ABI consistency: the confined-agent syscall numbers in user/abi.mc are the single source
    // of truth; the C agent userspace (crt0/usys/app_traps) + agent dispatchers must hardcode the
    // same numbers. Pure source scan (no mcc), so it always runs and never silently skips.
    _ = h.addScriptTestOpts(ctx, "abi-consistency-test", "Check the C guest-ABI #defines (crt0/usys/app_traps + dispatchers) match user/abi.mc", &.{ "bash", "tools/check/abi-consistency-test.sh" }, .{ .install = false });

    // Arch-selection seam (R0b): emit-c the portable core modules under every --arch. Pure host
    // (no ld.lld/QEMU), so it catches active-import regressions the x86/ARM QEMU gates would miss
    // when their cross toolchain is absent. Depends on the installed mcc.
    _ = h.addScriptTest(ctx, "arch-emit-test", "emit-c the portable core modules (elf_loader/uaccess_pt/uaccess/mmap) under --arch=riscv64|x86_64|aarch64", &.{ "bash", "tools/check/arch-emit-test.sh" });

    _ = h.addScriptTest(ctx, "qemu-test", "Run the typed-MMIO program on emulated hardware under QEMU", &.{ "bash", "tools/arch/qemu-mmio-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-qemu-test", "Run the LLVM-lowered typed-MMIO program under QEMU", &.{ "bash", "tools/arch/qemu-mmio-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "nulldyn-run-test", "Compile + RUN nullable trait objects (?*dyn) as native binaries on both backends (needs cc + clang)", &.{ "bash", "tools/exec/nullable-dyn-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "naked-run-test", "Compile + RUN a #[naked] function (no prologue/epilogue) as native binaries on both backends (needs cc + clang)", &.{ "bash", "tools/exec/naked-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "enum-raw-cmp-run-test", "Compile + RUN a value-producing `enum.raw() == N` comparison (typed `let bool` and `return`) as native binaries on both backends (G23; needs cc + clang)", &.{ "bash", "tools/exec/enum-raw-cmp-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "labeled-break-run-test", "Compile + RUN labeled `break :L` / `continue :L` targeting a named outer loop as native binaries on both backends (G7; needs cc + clang)", &.{ "bash", "tools/exec/labeled-break-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "error-from-run-test", "Compile + RUN `?` error coercion via an explicit `#[error_from]` conversion as native binaries on both backends (G8; asserts the CONVERTED error variant, not a reinterpret; needs cc + clang)", &.{ "bash", "tools/exec/error-from-run.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "cc-test", "Compile an MC module to an object with mcc-cc, link, and run it", &.{ "bash", "tools/toolchain/mcc-cc-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "mcc-build-test", "Compile and run a hosted executable through installed `mcc build`", &.{ "bash", "tools/toolchain/mcc-build-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-cc-test", "Compile an MC module to an object with mcc-llvm-cc, link, and run it", &.{ "bash", "tools/toolchain/mcc-llvm-cc-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "std-test", "Compile std/core, link it against a C driver, and run the checks", &.{ "bash", "tools/toolchain/std-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-std-test", "Compile std modules through LLVM, link them against a C driver, and run the checks", &.{ "bash", "tools/toolchain/llvm-std-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-toolchain-test", "Build, link, and run import, monomorphization, and reflection modules through LLVM", &.{ "bash", "tools/toolchain/llvm-toolchain-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "import-test", "Compile an import-merged module (sibling + std), link, and run it", &.{ "bash", "tools/toolchain/import-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "diagnostics-test", "Validate import-aware diagnostic locations, missing-import errors, and UTF-8 BOM handling", &.{ "bash", "tools/toolchain/diagnostics-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTestOpts(ctx, "diagnostics-reference-test", "Check docs/diagnostics.md covers every compiler E_* diagnostic code", &.{ "python3", "tools/toolchain/diagnostics-reference.py", "--check" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "diagnostic-code-inventory-test", "Check every emitted E_* diagnostic has a negative fixture or documented allowlist entry", &.{ "python3", "tools/toolchain/diagnostic-code-inventory.py", "--check" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "lowering-coverage-inventory-test", "Check lowering-coverage stays pointed at split backend files with a ratcheted baseline", &.{ "python3", "tools/toolchain/lowering-coverage-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "semantic-facts-inventory-test", "Check backend semantic inference families and fact consumers stay inventoried", &.{ "python3", "tools/toolchain/semantic-facts-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "architecture-boundary-inventory-test", "Check backend cleanup state stays deleted and syntax escapes are ratcheted", &.{ "python3", "tools/toolchain/architecture-boundary-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "compilation-session-inventory-test", "Check compiler request context stays behind CompilationSession", &.{ "python3", "tools/toolchain/compilation-session-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "mir-identity-inventory-test", "Check typed MIR identity migration seed stays anchored", &.{ "python3", "tools/toolchain/mir-identity-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-unsupported-inventory-test", "Check fail-closed move-array unsupported channels have fixed emission and fixture coverage", &.{ "python3", "tools/toolchain/move-unsupported-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-place-identity-inventory-test", "Check move checker alias assignment identity stays typed-place based", &.{ "python3", "tools/toolchain/move-place-identity-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-cfg-skeleton-inventory-test", "Check move checker CFG skeleton and worklist tests stay anchored", &.{ "python3", "tools/toolchain/move-cfg-skeleton-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-dynamic-place-policy-inventory-test", "Check move checker dynamic-place overlap policy stays explicit", &.{ "python3", "tools/toolchain/move-dynamic-place-policy-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-pointer-pointee-boundary-inventory-test", "Check move checker pointer-pointee accept/reject boundary stays explicit", &.{ "python3", "tools/toolchain/move-pointer-pointee-boundary-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "move-projection-inventory-test", "Check move checker projection admission map stays explicit", &.{ "python3", "tools/toolchain/move-projection-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "ownership-experimental-surface-inventory-test", "Check view/region/thread_move/borrow-return stay experimental ownership forms", &.{ "python3", "tools/toolchain/ownership-experimental-surface-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "kernel-contract-inventory-test", "Check the bounded kernel region/effect/FFI contract surface stays explicit", &.{ "python3", "tools/toolchain/kernel-contract-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "kernel-scope-inventory-test", "Check kernel docs/code stay scoped as language-validation workload, not product roadmap", &.{ "python3", "tools/toolchain/kernel-scope-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "std-api-docs-test", "Check docs/std-api.md covers exported stdlib declarations", &.{ "python3", "tools/toolchain/std-api-docs.py", "--check" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "vendoring-test", "Check vendored dependency provenance and license docs", &.{ "python3", "tools/toolchain/vendoring-test.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "third-party-licenses-test", "Check the aggregated third-party license manifest", &.{ "python3", "tools/toolchain/third-party-licenses-test.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "no-committed-private-keys-test", "Reject committed PEM private keys", &.{ "python3", "tools/toolchain/no-committed-private-keys.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "profile-manifest-test", "Check product profiles reference known risks and registered gates", &.{ "python3", "tools/toolchain/profile-manifest-test.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "gate-manifest-test", "Check the gate manifest matches registered build tiers", &.{ "python3", "tools/toolchain/gate-manifest-test.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "qmp-ordering-test", "Verify QMP command responses and asynchronous events are never discarded under legal reorderings", &.{ "python3", "tools/qemu/test_qmp_hotplug.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "numeric-comptime-matrix-test", "Check width/domain arithmetic boundaries across every fixed integer width", &.{ "python3", "tools/toolchain/numeric-comptime-matrix.py", "zig-out/bin/mcc" }, .{ .install = true });
    _ = h.addScriptTestOpts(ctx, "parallel-runner-test", "Check full-tier parallel runners preserve coverage while bounding nested workers", &.{ "python3", "tools/toolchain/parallel-runner-test.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "m0-timing-report-test", "Check m0 timing reports rank gate bottlenecks deterministically", &.{ "python3", "tools/toolchain/m0-timing-report-test.py" }, .{ .install = false });

    _ = h.addScriptTest(ctx, "mcc-cli-test", "Validate mcc help/version/usage exit behavior and stdout/stderr channels", &.{ "bash", "tools/toolchain/mcc-cli-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "path-remap-test", "Validate emit-c/emit-map source path remapping for reproducible artifacts", &.{ "bash", "tools/toolchain/path-remap-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTestOpts(ctx, "ci-pass-gates-test", "Check CI PASS assertions are derived from gate manifest and tier definitions", &.{ "python3", "tools/ci/pass-gates.py", "check" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "dev-gates-test", "Check focused development gate routing contracts", &.{ "python3", "tools/toolchain/dev-gates-test.py" }, .{ .install = false });

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
    _ = h.addScriptTest(ctx, "mcc-inspection-modules-test", "Validate inspection artifacts consume per-file resolved modules across imports", &.{ "bash", "tools/toolchain/mcc-inspection-modules-test.sh", "zig-out/bin/mcc" });
    _ = h.addScriptTest(ctx, "mcc-list-tests-modules-test", "Validate list-tests consumes per-file resolved modules across imports", &.{ "bash", "tools/toolchain/mcc-list-tests-modules-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "stack-test", "Build, link, and run the generic std/stack collection", &.{ "bash", "tools/toolchain/stack-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "vec-test", "Build, link, and run the generic heap-backed std/collections/dynarray (Vec<T>)", &.{ "bash", "tools/toolchain/vec-test.sh", "zig-out/bin/mcc" });
    _ = h.addScriptTest(ctx, "hashmap-test", "Build, link, and run the generic heap-backed std/collections/hashmap (StrHashMap<V>)", &.{ "bash", "tools/toolchain/hashmap-test.sh", "zig-out/bin/mcc" });
    _ = h.addScriptTest(ctx, "strbuf-test", "Build, link, and run the growable std/strbuf (StrBuf over Vec<u8>)", &.{ "bash", "tools/toolchain/strbuf-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "argv-test", "Build, link with the hosted_args_rt shim, and run a program that reads its real argv", &.{ "bash", "tools/toolchain/argv-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "memstr-test", "Build, link, and run the allocation-free std/mem byte-slice string ops", &.{ "bash", "tools/toolchain/memstr-test.sh", "zig-out/bin/mcc" });














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





    _ = h.addScriptTest(ctx, "arena-test", "move Arena: bump alloc, reset/reuse, destroy", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arena-test" });

    _ = h.addScriptTest(ctx, "genref-test", "generational handle: live resolve, stale-after-reset trap", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "genref-test" });

    _ = h.addScriptTest(ctx, "owned-test", "create<T> typed linear allocation, leak-checked", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "owned-test" });

    _ = h.addScriptTest(ctx, "dma-try-test", "std/dma typed fallible alloc: try_alloc -> err(OutOfMemory) on exhaustion", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dma-try-test" });

    _ = h.addScriptTest(ctx, "pool-test", "generational pool: use-after-free/double-free caught", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pool-test" });



    _ = h.addScriptTest(ctx, "constgen-test", "Const-generic Ring<T,N> at two capacities", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "constgen-test" });



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

    _ = h.addScriptTest(ctx, "smprq-test", "SMP per-core run queues + work stealing", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "smprq-test" });
    _ = h.addScriptTest(ctx, "rtc-test", "Wall-clock via goldfish-RTC: read the 64-bit epoch and assert a plausible live 'now'", &.{ "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-rtc-test", "Run LLVM-lowered goldfish-RTC MMIO under QEMU", &.{ "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "contain-test", "MMU crash containment", &.{ "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-contain-test", "Run LLVM-lowered MMU crash containment under QEMU", &.{ "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-test", "Device-tree (FDT) header parsing", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdt-test" });

    _ = h.addScriptTest(ctx, "fb-test", "Linear framebuffer device", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fb-test" });
    _ = h.addScriptTest(ctx, "aarch64-test", "Second architecture (aarch64) bring-up", &.{ "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-aarch64-test", "LLVM-lowered second architecture (aarch64) bring-up", &.{ "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "arm-vm-test", "AArch64 stage-1 page-table VM + MMU enable (real VA->PA translation)", &.{ "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-vm-test", "LLVM-lowered AArch64 stage-1 page-table VM + MMU enable", &.{ "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "arm-user-test", "AArch64 EL0 user hello: SYS_WRITE via svc #0, bad user ptr -> -EFAULT via a software page-table walk (no data abort), clean SYS_EXIT", &.{ "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-arm-user-test", "LLVM-lowered AArch64 EL0 user hello: EL0 syscall round-trip + bad-ptr -EFAULT software walk under QEMU", &.{ "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "sbi-boot-test", "Boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-sbi-boot-test", "LLVM-lowered boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-boot-test", "Boot under OpenSBI + parse DTB /memory (FDT discovery)", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-fdt-boot-test", "LLVM-lowered boot under OpenSBI + parse DTB /memory", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-devices-test", "Boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT compatible strings", &.{ "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-fdt-devices-test", "LLVM-lowered boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT", &.{ "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "bootinfo-test", "Boot under OpenSBI + normalize FDT into the arch-neutral BootInfo (§3.1)", &.{ "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-bootinfo-test", "LLVM-lowered boot under OpenSBI + normalize FDT into the arch-neutral BootInfo", &.{ "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "visionfive2-resource-test", "Boot under OpenSBI + validate the VisionFive 2 FDT-resource fixture against QEMU", &.{ "bash", "tools/arch/visionfive2-resource-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-visionfive2-resource-test", "LLVM-lowered VisionFive 2 FDT-resource fixture against QEMU", &.{ "bash", "tools/arch/visionfive2-resource-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "uart-driver-test", "Boot under OpenSBI + discover UART base from FDT + drive first-class LSR-polled NS16550 driver", &.{ "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-uart-driver-test", "LLVM-lowered boot under OpenSBI + FDT-discovered first-class NS16550 driver", &.{ "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "smode-user-test", "S-mode U-mode hello under OpenSBI (SYS_WRITE + bad-ptr -EFAULT)", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-user-test", "LLVM-lowered S-mode U-mode hello under OpenSBI", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "e1000-test", "Real e1000 NIC PCI probe", &.{ "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-e1000-test", "LLVM-lowered real e1000 NIC PCI probe", &.{ "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "llvm" });





    _ = h.addScriptTest(ctx, "endpoint-test", "MINIX hardening: endpoints/generations, derived runnable, death cleanup", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "endpoint-test" });

    // Phase 2.2 re-land condition: differential scheduler gate — after each randomized runnability
    // transition, next_runnable's pick must equal an independent authoritative is_runnable scan.
    // Reproduces the stale-cache regression that reverted the first O(1)/O(children) attempt.
    _ = h.addScriptTest(ctx, "sched-difftest", "differential scheduler gate: next_runnable pick == independent authoritative scan across randomized transitions (stale-cache regression guard)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "sched-difftest" });




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


    _ = h.addScriptTest(ctx, "cow-test", "Copy-on-write: shared RO page diverges on write", &.{ "bash", "tools/mem/cow-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cow-test", "Run LLVM-lowered copy-on-write fault handling under QEMU", &.{ "bash", "tools/mem/cow-test.sh", "zig-out/bin/mcc", "llvm" });




    _ = h.addScriptTest(ctx, "isolation-test", "Per-server MMU isolation + cross-AS IPC", &.{ "bash", "tools/proc/isolation-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-isolation-test", "Run LLVM-lowered per-server MMU isolation under QEMU", &.{ "bash", "tools/proc/isolation-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "demand-test", "Demand paging: fault -> map -> retry", &.{ "bash", "tools/mem/demand-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-demand-test", "Run LLVM-lowered demand paging under QEMU", &.{ "bash", "tools/mem/demand-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "mmap-test", "mmap anonymous pages into a page table (active satp)", &.{ "bash", "tools/mem/mmap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-mmap-test", "Run LLVM-lowered anonymous mmap under QEMU", &.{ "bash", "tools/mem/mmap-test.sh", "zig-out/bin/mcc", "llvm" });




    _ = h.addScriptTest(ctx, "privilege-test", "Least privilege: IPC allow-list + kernel-call gate", &.{ "bash", "tools/proc/privilege-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-privilege-test", "Run LLVM-lowered least-privilege IPC and kcall gates under QEMU", &.{ "bash", "tools/proc/privilege-test.sh", "zig-out/bin/mcc", "llvm" });




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
    // lost-wake window). The validation shape: a task sleeps in wfi until an interrupt resumes it.
    _ = h.addScriptTest(ctx, "async-irq-test", "async Phase C: a real timer interrupt completes an async request and wakes the parked task (IRQ-backed completion)", &.{ "bash", "tools/proc/async-irq-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-irq-test", "LLVM-lowered IRQ-backed async completion under QEMU", &.{ "bash", "tools/proc/async-irq-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-cancel-test (async/await Phase D step 6, runtime half): the broker CANCELLATION
    // primitive kernel/lib/async.mc `async_cancel`. Fill the inflight quota, cancel one request,
    // prove its slot is RECLAIMED (a fresh submit reuses it), a late completion is a no-op, and a
    // double-cancel is idempotent — so a dropped pending future does not leak its slot. FXR + OK.
    _ = h.addScriptTest(ctx, "async-cancel-test", "async Phase D: async_cancel reclaims a dropped request's inflight slot (no leak on drop)", &.{ "bash", "tools/proc/async-cancel-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-cancel-test", "LLVM-lowered async_cancel slot reclamation under QEMU", &.{ "bash", "tools/proc/async-cancel-test.sh", "zig-out/bin/mcc", "llvm" });

    // async-pollmany-test: the VECTORED DRAIN kernel/lib/async.mc `async_poll_many` — harvest many
    // completed in-flight requests per wakeup over the inflight table. Capped + re-enterable drain;
    // pending requests never harvested. SD + OK.
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
    // word "DISK" + ASYNC-BLK-OK prove the completion came from the device IRQ, not a polling loop.
    _ = h.addScriptTest(ctx, "async-blk-test", "device-backed async: an async fn's await resolves against a real virtio-blk device interrupt (PLIC used-ring completion reaped in interrupt context)", &.{ "bash", "tools/proc/async-blk-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-blk-test", "LLVM-lowered device-backed async virtio-blk completion under QEMU", &.{ "bash", "tools/proc/async-blk-test.sh", "zig-out/bin/mcc", "llvm" });


    // async-select-test: select / cancel-the-loser over the real broker. Two in-flight requests are
    // raced (ReqRace2); a timer ISR completes the winner; the race cancels the loser and the active
    // slot count returns to 0 — the MAX_INFLIGHT-returns-to-zero acceptance. WR + ASYNC-SELECT-OK.
    _ = h.addScriptTest(ctx, "async-select-test", "broker-backed select: race two requests, cancel the loser, active slots return to 0", &.{ "bash", "tools/proc/async-select-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-async-select-test", "LLVM-lowered broker-backed select / cancel-the-loser under QEMU", &.{ "bash", "tools/proc/async-select-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "cap-test", "capability least-privilege: driver-as-server holds the console cap", &.{ "bash", "tools/proc/cap-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cap-test", "Run LLVM-lowered capability least-privilege server under QEMU", &.{ "bash", "tools/proc/cap-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "arc-test", "Arc<T> shared ownership: clone/last-drop-frees, handles leak-checked", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-test" });

    _ = h.addScriptTest(ctx, "arc-pkt-test", "packet Arc-shared between two consumers (skb/mbuf pattern)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-pkt-test" });

    _ = h.addScriptTest(ctx, "alloc-test", "Link + run the type-erased std/alloc Allocator over a captured heap", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "alloc-test" });

    _ = h.addScriptTest(ctx, "closure-test", "Link + run a bind() closure (capture + call across calls)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "closure-test" });

    _ = h.addScriptTest(ctx, "ring-test", "Link + run the generic in-place Ring<T> (push/pop/wrap)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ring-test" });

















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


    _ = h.addScriptTest(ctx, "ledger-test", "Run the unified resource ledger (charge/release + overflow-edge) under QEMU", &.{ "bash", "tools/proc/ledger-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ledger-test", "Run the LLVM-lowered unified resource ledger under QEMU", &.{ "bash", "tools/proc/ledger-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "syscall-test", "Run the ecall syscall dispatch skeleton under QEMU", &.{ "bash", "tools/lang/syscall-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-syscall-test", "Run the LLVM-lowered ecall syscall dispatch skeleton under QEMU", &.{ "bash", "tools/lang/syscall-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "user-test", "Run the M->U privilege drop + user-mode syscalls under QEMU", &.{ "bash", "tools/lang/user-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-user-test", "Run the LLVM-lowered M->U privilege drop + user-mode syscalls under QEMU", &.{ "bash", "tools/lang/user-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "process-test", "Run process lifecycle (spawn/run/exit) under QEMU", &.{ "bash", "tools/proc/process-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-process-test", "Run the LLVM-lowered process lifecycle under QEMU", &.{ "bash", "tools/proc/process-test.sh", "zig-out/bin/mcc", "llvm" });



    // The uaccess demos exercise kernel/core/uaccess.mc, which imports riscv paging.mc
    // (sfence.vma) — not host-assemblable — so they run under QEMU on the real target,
    // not on the host driver suite. One generic runtime+harness, parameterized by the
    // fixture and its entry symbol.
    _ = h.addScriptTest(ctx, "uaccess-pt-test", "Page-table-aware user copies under QEMU: Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected (imports riscv paging.mc, so QEMU-only)", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-pt-test", "Page-table-aware user copies under QEMU (LLVM backend): Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test" });

    // Word-aligned mem ops (perf refactor Phase 1.1): mem_copy/mem_set/memmove copy 8-byte
    // words for the aligned bulk. Correctness gate boots a self-contained runtime that asserts
    // byte-exact results across boundary lengths + alignments + memmove overlap both directions.
    _ = h.addScriptTest(ctx, "mem-test", "Word-aligned mem ops under QEMU: mem_copy/mem_set/memmove byte-exact across lengths 0..4096, misaligned src/dst, memmove overlap both directions", &.{ "bash", "tools/mem/mem-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-mem-test", "Word-aligned mem ops under QEMU (LLVM backend): mem_copy/mem_set/memmove byte-exact across lengths+alignments, memmove overlap both directions", &.{ "bash", "tools/mem/mem-test.sh", "zig-out/bin/mcc", "llvm" });

    // Phase 0 mem microbenchmark (NOT in m0): rdcycle totals for a 64x 1 MiB copy/fill.
    _ = h.addScriptTest(ctx, "mem-bench", "Mem microbenchmark under QEMU: 64x 1 MiB mem_copy + mem_set, prints MEMCPY-CYCLES / MEMSET-CYCLES via rdcycle", &.{ "bash", "tools/mem/mem-bench.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-mem-bench", "Mem microbenchmark under QEMU (LLVM backend): 64x 1 MiB mem_copy + mem_set cycle totals", &.{ "bash", "tools/mem/mem-bench.sh", "zig-out/bin/mcc", "llvm" });

    // Phase 2.4 uaccess microbenchmark (NOT in m0): rdcycle totals for a 32x 1 MiB copy
    // through the page-table-aware copy_to_user_pt / copy_from_user_pt (single-pass walk).
    _ = h.addScriptTest(ctx, "uaccess-bench", "Page-table uaccess microbenchmark under QEMU: 32x 1 MiB copy_to_user_pt + copy_from_user_pt, prints UACCESS-CYCLES via rdcycle", &.{ "bash", "tools/mem/uaccess-bench.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-bench", "Page-table uaccess microbenchmark under QEMU (LLVM backend): 32x 1 MiB copy_to_user_pt + copy_from_user_pt cycle totals", &.{ "bash", "tools/mem/uaccess-bench.sh", "zig-out/bin/mcc", "llvm" });

    // Phase 2.2 scheduler pick-path microbenchmark (NOT in m0): average cycles per
    // next_runnable() round-robin pick. In the re-land the pick path is unchanged (design B),
    // so this stays the standing baseline tool; the algorithmic win was the O(children)
    // supervisor cascade, not the pick.


    // Phase 2.1 heap microbenchmark (NOT in m0): rdcycle total for an adversarial
    // fragment-and-coalesce free sequence that drives the free list to capacity — the
    // before/after number for killing the O(n^2) coalesce in kernel/core/heap.mc.
    _ = h.addScriptTest(ctx, "heap-bench", "Heap free-path microbenchmark under QEMU: adversarial fragment+coalesce free sequence, prints HEAPFREE-CYCLES via rdcycle", &.{ "bash", "tools/mem/heap-bench.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-heap-bench", "Heap free-path microbenchmark under QEMU (LLVM backend): adversarial fragment+coalesce free sequence, HEAPFREE-CYCLES total", &.{ "bash", "tools/mem/heap-bench.sh", "zig-out/bin/mcc", "llvm" });

    // plan / review F3) — maps every PT_LOAD at its vaddr with per-segment perms, zeroes bss.
    _ = h.addScriptTest(ctx, "elf-loader-test", "Multi-segment ELF64 loader under QEMU: maps every PT_LOAD at its vaddr with per-segment R/W/X perms, copies file bytes, zeroes bss; synthetic 2-segment image, asserts mappings/content/bss/perms", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });

    _ = h.addScriptTest(ctx, "llvm-elf-loader-test", "Multi-segment ELF64 loader under QEMU (LLVM backend): per-segment perms, file copy, bss zero", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });



    _ = h.addScriptTest(ctx, "uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU: a user-derived scalar must pass checked_len/checked_index/validate_bound (fail closed) before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU (LLVM backend): a user-derived scalar must pass checked_len/checked_index/validate_bound before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    // (delay 1) request; the broker delivers fast first, so the resolve order is "FS". Both backends.


    // completion carries a bogus id; the host must fail loudly ("host: unknown completion id").



    // is driven from a C runtime under QEMU on both backends — the printf-family interop the
    _ = h.addScriptTest(ctx, "vararg-test", "C-ABI variadic MC fn (va.start/va.arg/va.end) runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vararg-test", "LLVM: C-ABI variadic MC fn runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "llvm" });

    // kernel/core/heap.mc's free-list. Driven via malloc/free/calloc/realloc from a C runtime


    // memmove/memcmp/strlen/strcmp/strncmp/strchr/memchr, driven from a C runtime under QEMU on
    _ = h.addScriptTest(ctx, "cstr-test", "All-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cstr-test", "LLVM: all-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "llvm" });

    // abs, strtol/strtoul/strtoll/strtoull/atoi (with endptr, sign, 0x/0 prefixes, wraparound),
    // driven from a C runtime under QEMU on both backends.
    _ = h.addScriptTest(ctx, "cnum-test", "All-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cnum-test", "LLVM: all-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "llvm" });

    // varargs intrinsics), compiled as part of the AGGREGATED libc (user/libc/libc.mc — the
    // a C runtime under QEMU on both backends.
    _ = h.addScriptTest(ctx, "stdio-test", "All-MC printf family (aggregated libc) runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-stdio-test", "LLVM: all-MC printf family runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "llvm" });

    // (1 + 2*3 == 7). Both backends.


    // _count_limit). The same burn() guest is terminated mid-loop under a low limit and completes


    // CALL_INDIRECT_OVERLONG support, so stock wasi-libc output loads without feature-pinning.



    // async happy path in a single run — host_call (SUM resolve) -> host_fs_read (real cap-checked FS
    // read) -> host_sleep (async timeout) -> cancel (in-flight ECANCELED) — and prints AGENT-SMOKE-OK
    // only if every stage passed AND the host drained to inflight=0 with no unknown completion id.


    // post-completion cancel is denied, a failed-submit cancel hits nothing, a late completion after
    // cancel produces NO fatal unknown-id, and an FS read resolves non-empty — each with a distinct
    // marker; the host drains to inflight=0.


    // evaluating 6*7=42 confined. Proves the host need not be C either. Both backends.


    _ = h.addScriptTest(ctx, "driver-test", "Run the char-device driver framework (vtable dispatch) under QEMU", &.{ "bash", "tools/arch/driver-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-driver-test", "Run LLVM-lowered char-device driver framework under QEMU", &.{ "bash", "tools/arch/driver-test.sh", "zig-out/bin/mcc", "llvm" });





    _ = h.addScriptTest(ctx, "paging-activate-test", "Activate Sv39 satp in S-mode and read a translation-only VA under QEMU", &.{ "bash", "tools/mem/paging-activate-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-paging-activate-test", "Run LLVM-lowered Sv39 activation under QEMU", &.{ "bash", "tools/mem/paging-activate-test.sh", "zig-out/bin/mcc", "llvm" });


    _ = h.addScriptTest(ctx, "fault-isolation-test", "Boot the F1 fault-isolation keystone (a real agent trap is contained: faulting agent killed+reclaimed, kernel+others survive) under QEMU", &.{ "bash", "tools/proc/fault-isolation-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-fault-isolation-test", "Boot the LLVM-lowered F1 fault-isolation keystone under QEMU", &.{ "bash", "tools/proc/fault-isolation-test.sh", "zig-out/bin/mcc", "llvm" });


    _ = h.addScriptTest(ctx, "vm-switch-test", "Switch satp between two address spaces under QEMU (per-process VM)", &.{ "bash", "tools/mem/vm-switch-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vm-switch-test", "Run LLVM-lowered satp switching between two address spaces under QEMU", &.{ "bash", "tools/mem/vm-switch-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vmspace-test", "Per-process page tables: switch satp by process slot under QEMU", &.{ "bash", "tools/mem/vmspace-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vmspace-test", "Run LLVM-lowered per-process page tables under QEMU", &.{ "bash", "tools/mem/vmspace-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "vmctx-test", "Context switch that swaps satp per thread under QEMU", &.{ "bash", "tools/mem/vmctx-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vmctx-test", "Run LLVM-lowered context switching with satp swaps under QEMU", &.{ "bash", "tools/mem/vmctx-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "sched-vm-test", "Scheduler switching per-process address spaces (proc_yield_vm) under QEMU", &.{ "bash", "tools/proc/sched-vm-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-sched-vm-test", "Run LLVM-lowered scheduler switching per-process address spaces under QEMU", &.{ "bash", "tools/proc/sched-vm-test.sh", "zig-out/bin/mcc", "llvm" });

    // Preflight: explicit toolchain check for the QEMU milestone gates (clang/ld.lld/llc/qemu +
    // riscv64 target). `zig build preflight`. Milestone gates with MC_REQUIRE_TOOLS=1/CI=1 fail
    // rather than skip when a tool is missing (tools/qemu/kernel-boot-lib.sh).
    _ = h.addScriptTestOpts(ctx, "preflight", "Check the toolchain (clang/ld.lld/llc/qemu + riscv64 target) the QEMU milestone gates need", &.{ "bash", "tools/preflight.sh" }, .{ .install = false });
}
