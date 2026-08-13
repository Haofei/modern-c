const std = @import("std");
const h = @import("helpers.zig");

// QEMU kernel/arch boot tests, the host-driver link/run suite, and every other
// per-fixture gate. The bulk of the corpus.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "move-fuzz", "Generate move-resource programs; assert every resource is released once (live_count==0) on both backends", &.{ "bash", "tools/toolchain/move-fuzz.sh", "zig-out/bin/mcc" });

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
    _ = h.addScriptTestOpts(ctx, "kernel-scope-inventory-test", "Check kernel docs/code stay scoped as a language-validation workload, not an OS deliverable track", &.{ "python3", "tools/toolchain/kernel-scope-inventory.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "std-api-docs-test", "Check docs/std-api.md covers exported stdlib declarations", &.{ "python3", "tools/toolchain/std-api-docs.py", "--check" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "no-committed-private-keys-test", "Reject committed PEM private keys", &.{ "python3", "tools/toolchain/no-committed-private-keys.py" }, .{ .install = false });
    _ = h.addScriptTestOpts(ctx, "gate-manifest-test", "Check the gate manifest matches registered build tiers", &.{ "python3", "tools/toolchain/gate-manifest-test.py" }, .{ .install = false });
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

    _ = h.addScriptTest(ctx, "llvm-hosted-demo-test", "Compile the hosted demo through LLVM, link it, and run the stdin/stdout check", &.{ "bash", "tools/toolchain/llvm-hosted-demo-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-host-suite-test", "Compile host-driver manifest fixtures through LLVM, link them, and run them", &.{ "bash", "tools/toolchain/llvm-host-suite-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "move-test", "Build, link, and run a linear `move` handle through the toolchain", &.{ "bash", "tools/toolchain/move-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-move-test", "Build, link, and run a linear `move` handle through the LLVM toolchain", &.{ "bash", "tools/toolchain/llvm-move-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "try-defer-test", "Build, link, and run a `defer` before `?` through the C and LLVM backends (issue #3 regression)", &.{ "bash", "tools/toolchain/try-defer-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-runtime-test", "Build, link, and run imported generic, sync, and fn-pointer modules through the LLVM toolchain", &.{ "bash", "tools/toolchain/llvm-runtime-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "sync-test", "Build, link, and run a std/sync guarded critical section", &.{ "bash", "tools/toolchain/sync-test.sh", "zig-out/bin/mcc" });


    // S-mode timer-interrupt validation under OpenSBI. The fixture arms the
    // SBI TIME extension, enables timer interrupts, and counts re-armed ticks.
    _ = h.addScriptTest(ctx, "smode-timer-test", "Build and run the S-mode timer-interrupt validation fixture under OpenSBI", &.{ "bash", "tools/arch/smode-timer-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-timer-test", "Build and run the LLVM-lowered S-mode timer-interrupt validation fixture under OpenSBI", &.{ "bash", "tools/arch/smode-timer-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "smode-plic-test", "Build and run the S-mode external-interrupt validation fixture through the PLIC under OpenSBI", &.{ "bash", "tools/arch/smode-plic-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-plic-test", "Build and run the LLVM-lowered S-mode external-interrupt validation fixture through the PLIC under OpenSBI", &.{ "bash", "tools/arch/smode-plic-test.sh", "zig-out/bin/mcc", "llvm" });

    // Steady-state (re-armed) variant: 3 discrete external interrupts. The regression gate for
    // the former C-backend S-mode async-IRQ reset (root cause: a 2-byte-aligned naked trap
    // vector → reserved stvec MODE; fixed by #[align(4)] / naked-defaults-to-4).
    _ = h.addScriptTest(ctx, "smode-plic-multishot-test", "Build and run the re-armed S-mode external-interrupt validation fixture through the PLIC under OpenSBI", &.{ "bash", "tools/arch/smode-plic-multishot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-plic-multishot-test", "Build and run the LLVM-lowered re-armed S-mode external-interrupt validation fixture through the PLIC under OpenSBI", &.{ "bash", "tools/arch/smode-plic-multishot-test.sh", "zig-out/bin/mcc", "llvm" });


    _ = h.addScriptTest(ctx, "demo-test", "Lower every demo/ driver to C and compile-check it", &.{ "bash", "tools/toolchain/demo-test.sh", "zig-out/bin/mcc" });

    // Conformance-tier variant: MC_REQUIRE_TARGET=1 makes a missing clang/riscv64 target a
    // hard FAILURE instead of a skip, so a conformance tier (m0/c0) cannot pass vacuously
    // when the riscv64 compile never ran. The standalone `demo-test` step stays lenient
    // (host dev without a riscv64 clang skips). Used by the tiers below, not exposed as a step.
    const demo_test_strict_cmd = h.addRawCmd(ctx, "demo-test-strict", &.{ "bash", "tools/toolchain/demo-test.sh", "zig-out/bin/mcc" });
    demo_test_strict_cmd.setEnvironmentVariable("MC_REQUIRE_TARGET", "1");
    // Expose as a public step too, so the parallel runner (tools/m0-parallel.sh) can invoke it alone.
    ctx.b.step("demo-test-strict", "Strict demo-test (riscv64 required; m0/c0 variant)").dependOn(&demo_test_strict_cmd.step);


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

    _ = h.addScriptTest(ctx, "mutex-test", "sleeping Mutex: try_lock, blocking enqueue, FIFO hand-off on unlock", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mutex-test" });

    _ = h.addScriptTest(ctx, "fdt-test", "Device-tree (FDT) header parsing", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdt-test" });

    _ = h.addScriptTest(ctx, "sbi-boot-test", "Boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-sbi-boot-test", "LLVM-lowered boot under OpenSBI (real firmware)", &.{ "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "fdt-boot-test", "Boot under OpenSBI + parse DTB /memory (FDT discovery)", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-fdt-boot-test", "LLVM-lowered boot under OpenSBI + parse DTB /memory", &.{ "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "llvm" });
    _ = h.addScriptTest(ctx, "smode-user-test", "S-mode U-mode hello under OpenSBI (SYS_WRITE + bad-ptr -EFAULT)", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "c" });
    _ = h.addScriptTest(ctx, "llvm-smode-user-test", "LLVM-lowered S-mode U-mode hello under OpenSBI", &.{ "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "llvm" });


    // Phase 2.2 re-land condition: differential scheduler gate — after each randomized runnability
    // transition, next_runnable's pick must equal an independent authoritative is_runnable scan.
    // Reproduces the stale-cache regression that reverted the first O(1)/O(children) attempt.
    _ = h.addScriptTest(ctx, "sched-difftest", "differential scheduler gate: next_runnable pick == independent authoritative scan across randomized transitions (stale-cache regression guard)", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "sched-difftest" });

    _ = h.addScriptTest(ctx, "grant-test", "Memory grant: bounded delegation + revocation", &.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "grant-test" });


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

    _ = h.addScriptTest(ctx, "elf-loader-test", "Multi-segment ELF64 loader under QEMU: maps every PT_LOAD at its vaddr with per-segment R/W/X perms, copies file bytes, zeroes bss; synthetic 2-segment image, asserts mappings/content/bss/perms", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });

    _ = h.addScriptTest(ctx, "llvm-elf-loader-test", "Multi-segment ELF64 loader under QEMU (LLVM backend): per-segment perms, file copy, bss zero", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test" });


    _ = h.addScriptTest(ctx, "uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU: a user-derived scalar must pass checked_len/checked_index/validate_bound (fail closed) before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    _ = h.addScriptTest(ctx, "llvm-uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU (LLVM backend): a user-derived scalar must pass checked_len/checked_index/validate_bound before driving a copy length or index", &.{ "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm", "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test" });

    _ = h.addScriptTest(ctx, "vararg-test", "C-ABI variadic MC fn (va.start/va.arg/va.end) runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-vararg-test", "LLVM: C-ABI variadic MC fn runs under QEMU", &.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "cstr-test", "All-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cstr-test", "LLVM: all-MC mem/string core runs under QEMU", &.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "llvm" });

    // abs, strtol/strtoul/strtoll/strtoull/atoi (with endptr, sign, 0x/0 prefixes, wraparound),
    // driven from a C runtime under QEMU on both backends.
    _ = h.addScriptTest(ctx, "cnum-test", "All-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-cnum-test", "LLVM: all-MC ctype + integer parsing runs under QEMU", &.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "llvm" });

    _ = h.addScriptTest(ctx, "stdio-test", "All-MC printf family (aggregated libc) runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-stdio-test", "LLVM: all-MC printf family runs under QEMU", &.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "llvm" });

    // Preflight: explicit toolchain check for QEMU validation gates (clang/ld.lld/llc/qemu +
    // riscv64 target). `zig build preflight`. Validation gates with MC_REQUIRE_TOOLS=1/CI=1 fail
    // rather than skip when a tool is missing (tools/qemu/kernel-boot-lib.sh).
    _ = h.addScriptTestOpts(ctx, "preflight", "Check the toolchain (clang/ld.lld/llc/qemu + riscv64 target) needed by QEMU validation gates", &.{ "bash", "tools/preflight.sh" }, .{ .install = false });
}
