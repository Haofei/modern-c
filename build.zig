const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mcc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MC compiler");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const c_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/check-generated-c.sh",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
        "zig-out/c-test",
    });
    c_test_cmd.step.dependOn(b.getInstallStep());
    const c_test_step = b.step("c-test", "Emit C for smoke fixture and compile-check it with clang");
    c_test_step.dependOn(&c_test_cmd.step);

    const llvm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-test.sh",
        "zig-out/bin/mcc",
        "zig-out/llvm-test",
    });
    llvm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_test_step = b.step("llvm-test", "Emit LLVM IR for the initial backend slice and validate it with llvm-as");
    llvm_test_step.dependOn(&llvm_test_cmd.step);

    const llvm_obj_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-obj-test.sh",
        "zig-out/bin/mcc",
        "zig-out/llvm-obj-test",
    });
    llvm_obj_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_obj_test_step = b.step("llvm-obj-test", "Compile LLVM backend fixtures to object files with llc");
    llvm_obj_test_step.dependOn(&llvm_obj_test_cmd.step);

    const llvm_debug_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-debug-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_debug_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_debug_test_step = b.step("llvm-debug-test", "Verify LLVM object DWARF source and line mappings");
    llvm_debug_test_step.dependOn(&llvm_debug_test_cmd.step);

    const sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    sweep_cmd.step.dependOn(b.getInstallStep());
    const sweep_step = b.step("sweep", "Emit C for every valid spec-corpus function and compile-check it with clang");
    sweep_step.dependOn(&sweep_cmd.step);

    const sanitize_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/sanitize-test.sh",
        "zig-out/bin/mcc",
    });
    sanitize_cmd.step.dependOn(b.getInstallStep());
    const sanitize_step = b.step("sanitize", "Run the host-driver corpus under ASan + UBSan over the emitted C");
    sanitize_step.dependOn(&sanitize_cmd.step);

    const diff_backend_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/diff-backend.sh",
        "zig-out/bin/mcc",
    });
    diff_backend_cmd.step.dependOn(b.getInstallStep());
    const diff_backend_step = b.step("diff-backend", "Run each host fixture through both backends and assert C and LLVM agree");
    diff_backend_step.dependOn(&diff_backend_cmd.step);

    const diff_fuzz_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/diff-fuzz.sh",
        "zig-out/bin/mcc",
    });
    diff_fuzz_cmd.step.dependOn(b.getInstallStep());
    const diff_fuzz_step = b.step("diff-fuzz", "Generate random MC programs and assert the C and LLVM backends agree on each");
    diff_fuzz_step.dependOn(&diff_fuzz_cmd.step);

    const move_fuzz_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/move-fuzz.sh",
        "zig-out/bin/mcc",
    });
    move_fuzz_cmd.step.dependOn(b.getInstallStep());
    const move_fuzz_step = b.step("move-fuzz", "Generate move-resource programs; assert every resource is released once (live_count==0) on both backends");
    move_fuzz_step.dependOn(&move_fuzz_cmd.step);

    // V3.2: function-level lowering-coverage report. The script instruments the two
    // backend files, builds an instrumented mcc itself, and restores the sources on
    // exit — so it deliberately does NOT depend on the normal install step.
    const lowering_cov_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/lowering-coverage.sh",
    });
    const lowering_cov_step = b.step("lowering-coverage", "Report which lower_c.zig/lower_llvm.zig functions the differential corpus never exercises (V3.2)");
    lowering_cov_step.dependOn(&lowering_cov_cmd.step);

    // The three source-level security audits (unsafe boundary / double-fetch / taint) are
    // now one parameterized tool, tools/toolchain/mc-audit.sh, invoked with `--mode`. Pure
    // source scans (no mcc dependency), so they do not depend on the install step.

    // S0.2: source-level audit of the unsafe boundary.
    const unsafe_audit_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mc-audit.sh",
        "--mode",
        "unsafe",
    });
    const unsafe_audit_step = b.step("unsafe-audit", "Audit the MC unsafe boundary: flag gated unsafe ops outside an unsafe/unsafe_contract region and inventory the audited sites in kernel/ + std/ (S0.2)");
    unsafe_audit_step.dependOn(&unsafe_audit_cmd.step);

    // U2: source-level audit of double-fetch / TOCTOU on user memory.
    const double_fetch_audit_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mc-audit.sh",
        "--mode",
        "double-fetch",
    });
    const double_fetch_audit_step = b.step("double-fetch-audit", "Audit user-memory double-fetch / TOCTOU: flag a function that copies the same UserPtr in more than once (U2)");
    double_fetch_audit_step.dependOn(&double_fetch_audit_cmd.step);

    // U3: source-level audit of untrusted (user-derived) lengths/indices.
    const taint_audit_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mc-audit.sh",
        "--mode",
        "taint",
    });
    const taint_audit_step = b.step("taint-audit", "Audit user-derived (tainted) values: flag a value from copy_from_user/fetch_user used as a length/index/loop-bound without passing checked_len/checked_index/validate_bound (U3)");
    taint_audit_step.dependOn(&taint_audit_cmd.step);

    // ABI consistency: the confined-agent syscall numbers in user/abi.mc are the single source
    // of truth; the C agent userspace (crt0/usys/app_traps) + agent dispatchers must hardcode the
    // same numbers. Pure source scan (no mcc), so it always runs and never silently skips.
    const abi_consistency_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/check/abi-consistency-test.sh",
    });
    const abi_consistency_step = b.step("abi-consistency-test", "Check the C agent-ABI #defines (crt0/usys/app_traps + agent dispatchers) match user/abi.mc");
    abi_consistency_step.dependOn(&abi_consistency_cmd.step);

    // Arch-selection seam (R0b): emit-c the portable core modules under every --arch. Pure host
    // (no ld.lld/QEMU), so it catches active-import regressions the x86/ARM QEMU gates would miss
    // when their cross toolchain is absent. Depends on the installed mcc.
    const arch_emit_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/check/arch-emit-test.sh",
    });
    arch_emit_cmd.step.dependOn(b.getInstallStep());
    const arch_emit_step = b.step("arch-emit-test", "emit-c the portable core modules (elf_loader/uaccess_pt/uaccess/mmap) under --arch=riscv64|x86_64|aarch64");
    arch_emit_step.dependOn(&arch_emit_cmd.step);

    const fuzz_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "differential", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_cmd.step.dependOn(b.getInstallStep());
    const fuzz_step = b.step("fuzz", "mcfuzz: type-directed differential fuzzer over the full scalar type system (C vs LLVM)");
    fuzz_step.dependOn(&fuzz_cmd.step);

    const fuzz_sanitize_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "sanitize", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_sanitize_cmd.step.dependOn(b.getInstallStep());
    const fuzz_sanitize_step = b.step("fuzz-sanitize", "mcfuzz: run generated full-type-system programs' emitted C under UBSan");
    fuzz_sanitize_step.dependOn(&fuzz_sanitize_cmd.step);

    const fuzz_trap_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "differential", "--trapping", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_trap_cmd.step.dependOn(b.getInstallStep());
    const fuzz_trap_step = b.step("fuzz-trap", "mcfuzz: trap-consistency — generated programs that may trap must trap on both backends together");
    fuzz_trap_step.dependOn(&fuzz_trap_cmd.step);

    const fuzz_robust_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "robust", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_robust_cmd.step.dependOn(b.getInstallStep());
    const fuzz_robust_step = b.step("fuzz-robust", "mcfuzz: robustness — mcc check must never crash/hang on mutated input");
    fuzz_robust_step.dependOn(&fuzz_robust_cmd.step);

    const fuzz_failclosed_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "failclosed", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_failclosed_cmd.step.dependOn(b.getInstallStep());
    const fuzz_failclosed_step = b.step("fuzz-failclosed", "mcfuzz: fail-closed soundness — mcc check must reject ill-typed programs");
    fuzz_failclosed_step.dependOn(&fuzz_failclosed_cmd.step);

    const fuzz_determinism_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "determinism", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_determinism_cmd.step.dependOn(b.getInstallStep());
    const fuzz_determinism_step = b.step("fuzz-determinism", "mcfuzz: emit-c/emit-llvm must be byte-deterministic");
    fuzz_determinism_step.dependOn(&fuzz_determinism_cmd.step);

    const fuzz_pipeline_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "pipeline", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_pipeline_cmd.step.dependOn(b.getInstallStep());
    const fuzz_pipeline_step = b.step("fuzz-pipeline", "mcfuzz: every lowering/verify stage must succeed on a check-accepted program");
    fuzz_pipeline_step.dependOn(&fuzz_pipeline_cmd.step);

    const fuzz_metamorphic_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "metamorphic", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_metamorphic_cmd.step.dependOn(b.getInstallStep());
    const fuzz_metamorphic_step = b.step("fuzz-metamorphic", "mcfuzz: a semantics-preserving source transform must not change the result");
    fuzz_metamorphic_step.dependOn(&fuzz_metamorphic_cmd.step);

    const fuzz_optlevel_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "optlevel", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_optlevel_cmd.step.dependOn(b.getInstallStep());
    const fuzz_optlevel_step = b.step("fuzz-optlevel", "mcfuzz: emitted C must give the same result at -O0 and -O2 (no optimization-sensitive UB)");
    fuzz_optlevel_step.dependOn(&fuzz_optlevel_cmd.step);

    const fuzz_floatbits_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "floatbits", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_floatbits_cmd.step.dependOn(b.getInstallStep());
    const fuzz_floatbits_step = b.step("fuzz-floatbits", "mcfuzz: f32/f64 results must match bit-for-bit across backends (finite-only)");
    fuzz_floatbits_step.dependOn(&fuzz_floatbits_cmd.step);

    const fuzz_reference_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "reference", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_reference_cmd.step.dependOn(b.getInstallStep());
    const fuzz_reference_step = b.step("fuzz-reference", "mcfuzz: compiled output must match the independent Python reference interpreter (shared-frontend bugs)");
    fuzz_reference_step.dependOn(&fuzz_reference_cmd.step);

    const fuzz_corpus_cmd = b.addSystemCommand(&.{
        "python3", "tools/fuzz/mcfuzz.py", "corpus", "--mcc", "zig-out/bin/mcc",
    });
    fuzz_corpus_cmd.step.dependOn(b.getInstallStep());
    const fuzz_corpus_step = b.step("fuzz-corpus", "mcfuzz: replay the persisted regression corpus — each fixed-bug repro must stay clean");
    fuzz_corpus_step.dependOn(&fuzz_corpus_cmd.step);

    const llvm_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-llvm-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    llvm_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_sweep_step = b.step("llvm-sweep", "Emit LLVM IR for every in-scope valid spec-corpus fixture and validate it with llvm-as");
    llvm_sweep_step.dependOn(&llvm_sweep_cmd.step);

    const llvm_spec_obj_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-llvm-obj-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
        "zig-out/llvm-spec-obj-sweep",
    });
    llvm_spec_obj_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_spec_obj_sweep_step = b.step("llvm-spec-obj-sweep", "Compile every in-scope valid spec-corpus fixture to an LLVM object with llc");
    llvm_spec_obj_sweep_step.dependOn(&llvm_spec_obj_sweep_cmd.step);

    const llvm_c_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-c-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
    });
    llvm_c_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_c_sweep_step = b.step("llvm-c-sweep", "Emit LLVM IR for every checked C-emission fixture and validate it with llvm-as");
    llvm_c_sweep_step.dependOn(&llvm_c_sweep_cmd.step);

    const llvm_opt_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-opt-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
        "tests/c_emit/*.mc",
    });
    llvm_opt_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_opt_sweep_step = b.step("llvm-opt-sweep", "Run LLVM verifier, O2 optimizer, and optimized object checks over broad emitted IR");
    llvm_opt_sweep_step.dependOn(&llvm_opt_sweep_cmd.step);

    const llvm_c_obj_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-c-obj-sweep.py",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
        "zig-out/llvm-c-obj-sweep",
    });
    llvm_c_obj_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_c_obj_sweep_step = b.step("llvm-c-obj-sweep", "Compile every checked C-emission fixture to an LLVM object with llc");
    llvm_c_obj_sweep_step.dependOn(&llvm_c_obj_sweep_cmd.step);

    const qemu_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/qemu-mmio-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    qemu_test_cmd.step.dependOn(b.getInstallStep());
    const qemu_test_step = b.step("qemu-test", "Run the typed-MMIO program on emulated hardware under QEMU");
    qemu_test_step.dependOn(&qemu_test_cmd.step);

    const llvm_qemu_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/qemu-mmio-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_qemu_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qemu_test_step = b.step("llvm-qemu-test", "Run the LLVM-lowered typed-MMIO program under QEMU");
    llvm_qemu_test_step.dependOn(&llvm_qemu_test_cmd.step);

    const nulldyn_run_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/exec/nullable-dyn-run.sh",
        "zig-out/bin/mcc",
    });
    nulldyn_run_cmd.step.dependOn(b.getInstallStep());
    const nulldyn_run_step = b.step("nulldyn-run-test", "Compile + RUN nullable trait objects (?*dyn) as native binaries on both backends (needs cc + clang)");
    nulldyn_run_step.dependOn(&nulldyn_run_cmd.step);

    const naked_run_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/exec/naked-run.sh",
        "zig-out/bin/mcc",
    });
    naked_run_cmd.step.dependOn(b.getInstallStep());
    const naked_run_step = b.step("naked-run-test", "Compile + RUN a #[naked] function (no prologue/epilogue) as native binaries on both backends (needs cc + clang)");
    naked_run_step.dependOn(&naked_run_cmd.step);

    const cc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mcc-cc-test.sh",
        "zig-out/bin/mcc",
    });
    cc_test_cmd.step.dependOn(b.getInstallStep());
    const cc_test_step = b.step("cc-test", "Compile an MC module to an object with mcc-cc, link, and run it");
    cc_test_step.dependOn(&cc_test_cmd.step);

    const llvm_cc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mcc-llvm-cc-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_cc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cc_test_step = b.step("llvm-cc-test", "Compile an MC module to an object with mcc-llvm-cc, link, and run it");
    llvm_cc_test_step.dependOn(&llvm_cc_test_cmd.step);

    const std_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/std-test.sh",
        "zig-out/bin/mcc",
    });
    std_test_cmd.step.dependOn(b.getInstallStep());
    const std_test_step = b.step("std-test", "Compile std/core, link it against a C driver, and run the checks");
    std_test_step.dependOn(&std_test_cmd.step);

    const llvm_std_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-std-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_std_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_std_test_step = b.step("llvm-std-test", "Compile std modules through LLVM, link them against a C driver, and run the checks");
    llvm_std_test_step.dependOn(&llvm_std_test_cmd.step);

    const llvm_toolchain_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-toolchain-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_toolchain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_toolchain_test_step = b.step("llvm-toolchain-test", "Build, link, and run import, monomorphization, and reflection modules through LLVM");
    llvm_toolchain_test_step.dependOn(&llvm_toolchain_test_cmd.step);

    const import_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/import-test.sh",
        "zig-out/bin/mcc",
    });
    import_test_cmd.step.dependOn(b.getInstallStep());
    const import_test_step = b.step("import-test", "Compile an import-merged module (sibling + std), link, and run it");
    import_test_step.dependOn(&import_test_cmd.step);

    const mono_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mono-test.sh",
        "zig-out/bin/mcc",
    });
    mono_test_cmd.step.dependOn(b.getInstallStep());
    const mono_test_step = b.step("mono-test", "Compile a comptime-param type-generic module, link, and run the specialization");
    mono_test_step.dependOn(&mono_test_cmd.step);

    const reflect_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/reflect-test.sh",
        "zig-out/bin/mcc",
    });
    reflect_test_cmd.step.dependOn(b.getInstallStep());
    const reflect_test_step = b.step("reflect-test", "Validate comptime sizeof/alignof folding against clang's C ABI");
    reflect_test_step.dependOn(&reflect_test_cmd.step);

    const abi_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/abi-test.sh",
        "zig-out/bin/mcc",
    });
    abi_test_cmd.step.dependOn(b.getInstallStep());
    const abi_test_step = b.step("abi-test", "Validate advanced packed/overlay/MMIO layout against clang's C ABI and the LLVM backend");
    abi_test_step.dependOn(&abi_test_cmd.step);

    const opt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/opt-test.sh",
        "zig-out/bin/mcc",
    });
    opt_test_cmd.step.dependOn(b.getInstallStep());
    const opt_test_step = b.step("opt-test", "Validate the fact-gated MIR optimizer: const-index bounds-check elision under --optimize");
    opt_test_step.dependOn(&opt_test_cmd.step);

    const opt_equiv_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/opt-equiv-test.sh",
        "zig-out/bin/mcc",
    });
    opt_equiv_test_cmd.step.dependOn(b.getInstallStep());
    const opt_equiv_test_step = b.step("opt-equiv-test", "Validate the optimizer's elided bounds check is behavior-preserving: C vs LLVM, default vs --optimize");
    opt_equiv_test_step.dependOn(&opt_equiv_test_cmd.step);

    // D2.5: explicit SAFE vs RELEASE build-safety profile (`--checks=all|elide-proven`).
    // Asserts the two profiles agree functionally and that RELEASE elides exactly the
    // checks SAFE keeps (the optimizer-proven-dead ones).
    const safe_release_parity_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/safe-release-parity.sh",
        "zig-out/bin/mcc",
    });
    safe_release_parity_cmd.step.dependOn(b.getInstallStep());
    const safe_release_parity_step = b.step("safe-release-parity", "D2.5: SAFE (--checks=all) and RELEASE (--checks=elide-proven) agree functionally; RELEASE elides only proven-dead checks");
    safe_release_parity_step.dependOn(&safe_release_parity_cmd.step);

    const comptime_fold_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/comptime-fold-test.sh",
        "zig-out/bin/mcc",
    });
    comptime_fold_test_cmd.step.dependOn(b.getInstallStep());
    const comptime_fold_test_step = b.step("comptime-fold-test", "Validate comptime-only folds (byte strings, wrap/sat arithmetic domains) evaluate correctly");
    comptime_fold_test_step.dependOn(&comptime_fold_test_cmd.step);


    const asm_targets_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/asm-targets-test.sh",
        "zig-out/bin/mcc",
    });
    asm_targets_test_cmd.step.dependOn(b.getInstallStep());
    const asm_targets_test_step = b.step("asm-targets-test", "Validate per-architecture precise-asm register vocabularies (x86-64/RISC-V/AArch64)");
    asm_targets_test_step.dependOn(&asm_targets_test_cmd.step);


    const mcmap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mcmap-test.sh",
        "zig-out/bin/mcc",
    });
    mcmap_test_cmd.step.dependOn(b.getInstallStep());
    const mcmap_test_step = b.step("mcmap-test", "Validate .mcmap stable typed-AST/MIR IDs and object-symbol correlation (C + LLVM)");
    mcmap_test_step.dependOn(&mcmap_test_cmd.step);


    const fmt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/fmt-test.sh",
        "zig-out/bin/mcc",
    });
    fmt_test_cmd.step.dependOn(b.getInstallStep());
    const fmt_test_step = b.step("fmt-test", "Validate `mcc fmt` is token-preserving + idempotent across the corpus, and --check semantics");
    fmt_test_step.dependOn(&fmt_test_cmd.step);

    const mcc_symbols_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/mcc-symbols-test.sh",
        "zig-out/bin/mcc",
    });
    mcc_symbols_test_cmd.step.dependOn(b.getInstallStep());
    const mcc_symbols_test_step = b.step("mcc-symbols-test", "Validate the `mcc symbols` index: refs resolve to their declarations");
    mcc_symbols_test_step.dependOn(&mcc_symbols_test_cmd.step);

    const editor_client_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/editor-client-test.sh",
    });
    const editor_client_test_step = b.step("editor-client-test", "Validate the VS Code editor client manifest/grammar/extension");
    editor_client_test_step.dependOn(&editor_client_test_cmd.step);

    const lsp_test_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/lsp/lsp-test.py",
        "zig-out/bin/mcc",
    });
    lsp_test_cmd.step.dependOn(b.getInstallStep());
    const lsp_test_step = b.step("lsp-test", "Drive the mc-lsp language server and assert it publishes mcc diagnostics with matching E_ codes");
    lsp_test_step.dependOn(&lsp_test_cmd.step);

    const stack_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/stack-test.sh",
        "zig-out/bin/mcc",
    });
    stack_test_cmd.step.dependOn(b.getInstallStep());
    const stack_test_step = b.step("stack-test", "Build, link, and run the generic std/stack collection");
    stack_test_step.dependOn(&stack_test_cmd.step);

    const pkg_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/pkg-test.sh",
        "zig-out/bin/mcc",
    });
    pkg_test_cmd.step.dependOn(b.getInstallStep());
    const pkg_test_step = b.step("pkg-test", "Build a package from its manifest with mcc-pkg, link, and run it");
    pkg_test_step.dependOn(&pkg_test_cmd.step);

    const llvm_pkg_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-pkg-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_pkg_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_pkg_test_step = b.step("llvm-pkg-test", "Build a package from its manifest through LLVM, link, and run it");
    llvm_pkg_test_step.dependOn(&llvm_pkg_test_cmd.step);

    const pkg_registry_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/pkg-registry-test.sh",
        "zig-out/bin/mcc",
    });
    pkg_registry_test_cmd.step.dependOn(b.getInstallStep());
    const pkg_registry_test_step = b.step("pkg-registry-test", "Registry publish/resolve/install + lockfile reproducibility for the package manager");
    pkg_registry_test_step.dependOn(&pkg_registry_test_cmd.step);

    const llvm_demo_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-demo-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_demo_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_demo_test_step = b.step("llvm-demo-test", "Compile supported demo drivers through LLVM to objects");
    llvm_demo_test_step.dependOn(&llvm_demo_test_cmd.step);

    const llvm_kernel_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-kernel-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_kernel_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kernel_test_step = b.step("llvm-kernel-test", "Compile kernel modules through LLVM to target objects");
    llvm_kernel_test_step.dependOn(&llvm_kernel_test_cmd.step);

    const llvm_hosted_demo_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-hosted-demo-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_hosted_demo_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_hosted_demo_test_step = b.step("llvm-hosted-demo-test", "Compile the hosted demo through LLVM, link it, and run the stdin/stdout check");
    llvm_hosted_demo_test_step.dependOn(&llvm_hosted_demo_test_cmd.step);

    const llvm_host_suite_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-host-suite-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_host_suite_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_host_suite_test_step = b.step("llvm-host-suite-test", "Compile host-driver manifest fixtures through LLVM, link them, and run them");
    llvm_host_suite_test_step.dependOn(&llvm_host_suite_test_cmd.step);

    const move_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/move-test.sh",
        "zig-out/bin/mcc",
    });
    move_test_cmd.step.dependOn(b.getInstallStep());
    const move_test_step = b.step("move-test", "Build, link, and run a linear `move` handle through the toolchain");
    move_test_step.dependOn(&move_test_cmd.step);

    const llvm_move_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-move-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_move_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_move_test_step = b.step("llvm-move-test", "Build, link, and run a linear `move` handle through the LLVM toolchain");
    llvm_move_test_step.dependOn(&llvm_move_test_cmd.step);

    const try_defer_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/try-defer-test.sh",
        "zig-out/bin/mcc",
    });
    try_defer_test_cmd.step.dependOn(b.getInstallStep());
    const try_defer_test_step = b.step("try-defer-test", "Build, link, and run a `defer` before `?` through the C and LLVM backends (issue #3 regression)");
    try_defer_test_step.dependOn(&try_defer_test_cmd.step);

    const llvm_runtime_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-runtime-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_runtime_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_runtime_test_step = b.step("llvm-runtime-test", "Build, link, and run imported generic, sync, and fn-pointer modules through the LLVM toolchain");
    llvm_runtime_test_step.dependOn(&llvm_runtime_test_cmd.step);

    const sync_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/sync-test.sh",
        "zig-out/bin/mcc",
    });
    sync_test_cmd.step.dependOn(b.getInstallStep());
    const sync_test_step = b.step("sync-test", "Build, link, and run a std/sync guarded critical section");
    sync_test_step.dependOn(&sync_test_cmd.step);

    const nic_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/nic-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_nic_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/nic-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    nic_test_cmd.step.dependOn(b.getInstallStep());
    const nic_test_step = b.step("nic-test", "Build and run the demo NIC driver (driver-library profile) under QEMU");
    nic_test_step.dependOn(&nic_test_cmd.step);
    llvm_nic_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_nic_test_step = b.step("llvm-nic-test", "Build and run the LLVM-lowered demo NIC driver under QEMU");
    llvm_nic_test_step.dependOn(&llvm_nic_test_cmd.step);

    const virtio_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/virtio-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_virtio_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/virtio-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    virtio_test_cmd.step.dependOn(b.getInstallStep());
    const virtio_test_step = b.step("virtio-test", "Build and run the real virtio-net driver against virtio-net-device under QEMU");
    virtio_test_step.dependOn(&virtio_test_cmd.step);
    llvm_virtio_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_virtio_test_step = b.step("llvm-virtio-test", "Build and run the LLVM-lowered virtio-net driver under QEMU");
    llvm_virtio_test_step.dependOn(&llvm_virtio_test_cmd.step);

    const blk_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/blk-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_blk_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/blk-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    blk_test_cmd.step.dependOn(b.getInstallStep());
    const blk_test_step = b.step("blk-test", "Build and run the virtio-blk driver reading a sector under QEMU");
    blk_test_step.dependOn(&blk_test_cmd.step);
    llvm_blk_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_blk_test_step = b.step("llvm-blk-test", "Build and run the LLVM-lowered virtio-blk driver under QEMU");
    llvm_blk_test_step.dependOn(&llvm_blk_test_cmd.step);

    const blk_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/blk-smode-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_blk_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/blk-smode-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    blk_smode_test_cmd.step.dependOn(b.getInstallStep());
    const blk_smode_test_step = b.step("blk-smode-test", "Build and run the virtio-blk driver reading a sector under REAL OpenSBI in S-mode");
    blk_smode_test_step.dependOn(&blk_smode_test_cmd.step);
    llvm_blk_smode_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_blk_smode_test_step = b.step("llvm-blk-smode-test", "Build and run the LLVM-lowered virtio-blk driver under REAL OpenSBI in S-mode");
    llvm_blk_smode_test_step.dependOn(&llvm_blk_smode_test_cmd.step);

    // Item (4): REAL S-mode timer-interrupt delivery under OpenSBI — a flat
    // S-mode kernel arms the SBI TIME extension, enables S-mode timer
    // interrupts, and counts ticks in its trap handler (re-arming each tick,
    // wfi-parked). The RISC-V analogue of the x86 X4 LAPIC-timer proof.
    const smode_timer_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/smode-timer-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_smode_timer_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/smode-timer-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    smode_timer_test_cmd.step.dependOn(b.getInstallStep());
    const smode_timer_test_step = b.step("smode-timer-test", "Build and run the flat S-mode kernel taking REAL S-mode timer interrupts under REAL OpenSBI");
    smode_timer_test_step.dependOn(&smode_timer_test_cmd.step);
    llvm_smode_timer_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smode_timer_test_step = b.step("llvm-smode-timer-test", "Build and run the LLVM-lowered flat S-mode timer-interrupt kernel under REAL OpenSBI");
    llvm_smode_timer_test_step.dependOn(&llvm_smode_timer_test_cmd.step);

    const net_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/net-smode-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_net_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/net-smode-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    net_smode_test_cmd.step.dependOn(b.getInstallStep());
    const net_smode_test_step = b.step("net-smode-test", "Build and run the virtio-net RX/TX ARP+ping exchange under REAL OpenSBI in S-mode");
    net_smode_test_step.dependOn(&net_smode_test_cmd.step);
    llvm_net_smode_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_net_smode_test_step = b.step("llvm-net-smode-test", "Build and run the LLVM-lowered virtio-net RX/TX exchange under REAL OpenSBI in S-mode");
    llvm_net_smode_test_step.dependOn(&llvm_net_smode_test_cmd.step);

    const udp_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/udp-net-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_udp_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/udp-net-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    udp_net_test_cmd.step.dependOn(b.getInstallStep());
    const udp_net_test_step = b.step("udp-net-test", "Transmit a real UDP datagram over virtio-net under QEMU (pcap-verified)");
    udp_net_test_step.dependOn(&udp_net_test_cmd.step);
    llvm_udp_net_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_udp_net_test_step = b.step("llvm-udp-net-test", "Transmit a real LLVM-lowered UDP datagram over virtio-net under QEMU");
    llvm_udp_net_test_step.dependOn(&llvm_udp_net_test_cmd.step);

    const smp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    smp_test_cmd.step.dependOn(b.getInstallStep());
    const smp_test_step = b.step("smp-test", "Boot multiple harts and synchronize on a shared atomic under QEMU");
    smp_test_step.dependOn(&smp_test_cmd.step);

    const llvm_smp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_smp_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smp_test_step = b.step("llvm-smp-test", "Run LLVM-lowered SMP boot/sync under QEMU");
    llvm_smp_test_step.dependOn(&llvm_smp_test_cmd.step);

    const smp_lock_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-lock-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    smp_lock_test_cmd.step.dependOn(b.getInstallStep());
    const smp_lock_test_step = b.step("smp-lock-test", "Contend a ticket spinlock across harts under QEMU (mutual exclusion)");
    smp_lock_test_step.dependOn(&smp_lock_test_cmd.step);

    const llvm_smp_lock_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-lock-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_smp_lock_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smp_lock_test_step = b.step("llvm-smp-lock-test", "Run LLVM-lowered SMP ticket-lock contention under QEMU");
    llvm_smp_lock_test_step.dependOn(&llvm_smp_lock_test_cmd.step);

    const ipi_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/ipi-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipi_test_cmd.step.dependOn(b.getInstallStep());
    const ipi_test_step = b.step("ipi-test", "Send a CLINT software interrupt (IPI) between harts under QEMU");
    ipi_test_step.dependOn(&ipi_test_cmd.step);

    const llvm_ipi_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/ipi-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipi_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipi_test_step = b.step("llvm-ipi-test", "Run LLVM-lowered inter-processor interrupt under QEMU");
    llvm_ipi_test_step.dependOn(&llvm_ipi_test_cmd.step);

    const demo_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/demo-test.sh",
        "zig-out/bin/mcc",
    });
    demo_test_cmd.step.dependOn(b.getInstallStep());
    const demo_test_step = b.step("demo-test", "Lower every demo/ driver to C and compile-check it");
    demo_test_step.dependOn(&demo_test_cmd.step);

    const net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    net_test_cmd.step.dependOn(b.getInstallStep());
    const net_test_step = b.step("net-test", "Run the kernel virtio-net RX/TX ARP exchange under QEMU");
    net_test_step.dependOn(&net_test_cmd.step);
    llvm_net_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_net_test_step = b.step("llvm-net-test", "Run the LLVM-lowered kernel virtio-net RX/TX ARP exchange under QEMU");
    llvm_net_test_step.dependOn(&llvm_net_test_cmd.step);

    const kernel_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/kernel-test.sh",
        "zig-out/bin/mcc",
    });
    kernel_test_cmd.step.dependOn(b.getInstallStep());
    const kernel_test_step = b.step("kernel-test", "Compile-check kernel/ for riscv64 and verify typestate rejects");
    kernel_test_step.dependOn(&kernel_test_cmd.step);

    const page_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/page-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    page_test_cmd.step.dependOn(b.getInstallStep());
    const page_test_step = b.step("page-test", "Link + run the physical frame allocator (bump + free-list reclaim)");
    page_test_step.dependOn(&page_test_cmd.step);

    const llvm_page_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/page-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_page_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_page_test_step = b.step("llvm-page-test", "Link + run the LLVM-lowered physical frame allocator");
    llvm_page_test_step.dependOn(&llvm_page_test_cmd.step);

    const heap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/heap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    heap_test_cmd.step.dependOn(b.getInstallStep());
    const heap_test_step = b.step("heap-test", "Link + run the kernel heap (aligned bump over a PhysRange)");
    heap_test_step.dependOn(&heap_test_cmd.step);

    const llvm_heap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/heap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_heap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_heap_test_step = b.step("llvm-heap-test", "Link + run the LLVM-lowered kernel heap");
    llvm_heap_test_step.dependOn(&llvm_heap_test_cmd.step);

    // D2.4: heap-redzone + stack-canary runtime detection under QEMU.
    const redzone_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/redzone-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    redzone_test_cmd.step.dependOn(b.getInstallStep());
    const redzone_test_step = b.step("redzone-test", "Boot the redzone+canary demo under QEMU (detects heap overflow + smashed canary)");
    redzone_test_step.dependOn(&redzone_test_cmd.step);

    const llvm_redzone_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/redzone-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_redzone_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_redzone_test_step = b.step("llvm-redzone-test", "Boot the LLVM-lowered redzone+canary demo under QEMU");
    llvm_redzone_test_step.dependOn(&llvm_redzone_test_cmd.step);

    // ksan-test boots the D2.1 KASAN demo under QEMU: access-time use-after-free + OOB
    // detection via shadow memory (the `--checks=ksan` profile), strictly finer than D2.4.
    const ksan_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/ksan-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ksan_test_cmd.step.dependOn(b.getInstallStep());
    const ksan_test_step = b.step("ksan-test", "Boot the KASAN demo under QEMU (access-time use-after-free + OOB detection)");
    ksan_test_step.dependOn(&ksan_test_cmd.step);

    const llvm_ksan_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/ksan-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ksan_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ksan_test_step = b.step("llvm-ksan-test", "Boot the LLVM-lowered KASAN demo under QEMU");
    llvm_ksan_test_step.dependOn(&llvm_ksan_test_cmd.step);

    // kmsan-test boots the D2.2 KMSAN demo under QEMU: access-time use-of-uninitialized-heap
    // detection on the ksan shadow (the `--checks=msan` profile) — a read of never-written
    // heap memory traps, the dynamic complement to S0.1's static check.
    const kmsan_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/kmsan-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kmsan_test_cmd.step.dependOn(b.getInstallStep());
    const kmsan_test_step = b.step("kmsan-test", "Boot the KMSAN demo under QEMU (access-time uninitialized-heap-use detection)");
    kmsan_test_step.dependOn(&kmsan_test_cmd.step);

    const llvm_kmsan_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/kmsan-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_kmsan_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kmsan_test_step = b.step("llvm-kmsan-test", "Boot the LLVM-lowered KMSAN demo under QEMU");
    llvm_kmsan_test_step.dependOn(&llvm_kmsan_test_cmd.step);

    // kcsan-test boots the D2.3 KCSAN demo under QEMU: data-race detection via a watchpoint
    // on the shadow (the `--checks=csan` profile). An unsynchronized boot-thread access
    // racing a REAL preempting timer-IRQ access is caught by the watchpoint conflict check
    // (CSAN-DETECTED); a properly-synchronized (mc_race_*) access is clean (CSAN-OK). C
    // backend only — the LLVM backend does not implement the csan watchpoint instrumentation.
    const kcsan_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/kcsan-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kcsan_test_cmd.step.dependOn(b.getInstallStep());
    const kcsan_test_step = b.step("kcsan-test", "Boot the KCSAN demo under QEMU (data-race detection on the watchpoint)");
    kcsan_test_step.dependOn(&kcsan_test_cmd.step);

    const elf_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "elf-test",
    });
    elf_test_cmd.step.dependOn(b.getInstallStep());
    const elf_test_step = b.step("elf-test", "Link + run the ELF64 parser (header + program headers, bounds-checked)");
    elf_test_step.dependOn(&elf_test_cmd.step);

    const ramfs_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ramfs-test",
    });
    ramfs_test_cmd.step.dependOn(b.getInstallStep());
    const ramfs_test_step = b.step("ramfs-test", "Link + run the in-memory filesystem (create/write/read/lookup)");
    ramfs_test_step.dependOn(&ramfs_test_cmd.step);

    const vfs_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfs-test",
    });
    vfs_test_cmd.step.dependOn(b.getInstallStep());
    const vfs_test_step = b.step("vfs-test", "Link + run the fd-table VFS over ramfs (open/read/write/close)");
    vfs_test_step.dependOn(&vfs_test_cmd.step);

    const blockfs_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "blockfs-test",
    });
    blockfs_test_cmd.step.dependOn(b.getInstallStep());
    const blockfs_test_step = b.step("blockfs-test", "Link + run the block-backed file store (block device vtable)");
    blockfs_test_step.dependOn(&blockfs_test_cmd.step);

    const udp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "udp-test",
    });
    udp_test_cmd.step.dependOn(b.getInstallStep());
    const udp_test_step = b.step("udp-test", "Link + run the UDP datagram build/parse + checksum");
    udp_test_step.dependOn(&udp_test_cmd.step);

    const dns_host_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dns-test",
    });
    dns_host_test_cmd.step.dependOn(b.getInstallStep());
    const dns_host_test_step = b.step("dns-host-test", "Link + run the DNS A-query build + response parse (host fixture)");
    dns_host_test_step.dependOn(&dns_host_test_cmd.step);

    const arena_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arena-test",
    });
    arena_test_cmd.step.dependOn(b.getInstallStep());
    const arena_test_step = b.step("arena-test", "move Arena: bump alloc, reset/reuse, destroy");
    arena_test_step.dependOn(&arena_test_cmd.step);

    const genref_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "genref-test",
    });
    genref_test_cmd.step.dependOn(b.getInstallStep());
    const genref_test_step = b.step("genref-test", "generational handle: live resolve, stale-after-reset trap");
    genref_test_step.dependOn(&genref_test_cmd.step);

    const owned_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "owned-test",
    });
    owned_test_cmd.step.dependOn(b.getInstallStep());
    const owned_test_step = b.step("owned-test", "create<T> typed linear allocation, leak-checked");
    owned_test_step.dependOn(&owned_test_cmd.step);

    const net_arena_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-arena-test",
    });
    net_arena_test_cmd.step.dependOn(b.getInstallStep());
    const net_arena_test_step = b.step("net-arena-test", "RX scratch from a move Arena + generational handle");
    net_arena_test_step.dependOn(&net_arena_test_cmd.step);

    const pool_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pool-test",
    });
    pool_test_cmd.step.dependOn(b.getInstallStep());
    const pool_test_step = b.step("pool-test", "generational pool: use-after-free/double-free caught");
    pool_test_step.dependOn(&pool_test_cmd.step);

    const block_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/block-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    block_server_test_cmd.step.dependOn(b.getInstallStep());
    const block_server_test_step = b.step("block-server-test", "storage driver as a user-mode server (block read/write via IPC)");
    block_server_test_step.dependOn(&block_server_test_cmd.step);

    const llvm_block_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/block-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_block_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_block_server_test_step = b.step("llvm-block-server-test", "Run LLVM-lowered block server under QEMU");
    llvm_block_server_test_step.dependOn(&llvm_block_server_test_cmd.step);

    const fs_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fs_server_test_cmd.step.dependOn(b.getInstallStep());
    const fs_server_test_step = b.step("fs-server-test", "filesystem as a user-mode server (open/write/read via IPC)");
    fs_server_test_step.dependOn(&fs_server_test_cmd.step);

    const llvm_fs_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fs_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fs_server_test_step = b.step("llvm-fs-server-test", "Run LLVM-lowered filesystem server under QEMU");
    llvm_fs_server_test_step.dependOn(&llvm_fs_server_test_cmd.step);

    const net_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    net_server_test_cmd.step.dependOn(b.getInstallStep());
    const net_server_test_step = b.step("net-server-test", "UDP socket layer as a user-mode server (bind/recv via IPC)");
    net_server_test_step.dependOn(&net_server_test_cmd.step);

    const llvm_net_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_net_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_net_server_test_step = b.step("llvm-net-server-test", "Run LLVM-lowered network server under QEMU");
    llvm_net_server_test_step.dependOn(&llvm_net_server_test_cmd.step);

    const constgen_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "constgen-test",
    });
    constgen_test_cmd.step.dependOn(b.getInstallStep());
    const constgen_test_step = b.step("constgen-test", "Const-generic Ring<T,N> at two capacities");
    constgen_test_step.dependOn(&constgen_test_cmd.step);

    const pipe_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pipe-test",
    });
    pipe_test_cmd.step.dependOn(b.getInstallStep());
    const pipe_test_step = b.step("pipe-test", "Pipe FIFO");
    pipe_test_step.dependOn(&pipe_test_cmd.step);

    const bcache_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "bcache-test",
    });
    const perm_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "perm-test",
    });
    perm_test_cmd.step.dependOn(b.getInstallStep());
    const perm_test_step = b.step("perm-test", "POSIX permission checks");
    perm_test_step.dependOn(&perm_test_cmd.step);

    const pgroup_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pgroup-test",
    });
    const tty_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tty-test",
    });
    tty_test_cmd.step.dependOn(b.getInstallStep());
    const tty_test_step = b.step("tty-test", "TTY line discipline");
    tty_test_step.dependOn(&tty_test_cmd.step);

    const time_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "time-test",
    });
    time_test_cmd.step.dependOn(b.getInstallStep());
    const time_test_step = b.step("time-test", "std/time counter<u64> timeout arithmetic");
    time_test_step.dependOn(&time_test_cmd.step);

    const vqfault_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vqfault-test",
    });
    vqfault_test_cmd.step.dependOn(b.getInstallStep());
    const vqfault_test_step = b.step("vqfault-test", "virtqueue completion fault injection (bad id / not-in-flight / length overflow)");
    vqfault_test_step.dependOn(&vqfault_test_cmd.step);

    const wrap_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "wrap-test",
    });
    wrap_test_cmd.step.dependOn(b.getInstallStep());
    const wrap_test_step = b.step("wrap-test", "long-running ring-index/pool-generation wrap and pool exhaustion invariants");
    wrap_test_step.dependOn(&wrap_test_cmd.step);

    const args_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "args-test",
    });
    const libc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "libc-test",
    });
    libc_test_cmd.step.dependOn(b.getInstallStep());
    const libc_test_step = b.step("libc-test", "Minimal libc core");
    libc_test_step.dependOn(&libc_test_cmd.step);

    // hosted-test runs the hosted-profile float round-trip end to end: MC ->
    // C (--profile=hosted) -> clang -lm -> execute, feeding a binary f32 buffer
    // on stdin and verifying the f32 results on stdout. Self-skips without
    // clang/python3.
    const hosted_test_cmd = b.addSystemCommand(&.{
        "bash", "demo/hosted/run.sh", "zig-out/bin/mcc",
    });
    hosted_test_cmd.step.dependOn(b.getInstallStep());
    const hosted_test_step = b.step("hosted-test", "Hosted-profile elementwise float kernel: stdin/stdout f32 round-trip via libc/libm");
    hosted_test_step.dependOn(&hosted_test_cmd.step);

    const shell_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell-test",
    });
    const shell2_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell2-test",
    });
    const ushell_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lang/ushell-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_ushell_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lang/ushell-test.sh", "zig-out/bin/mcc", "llvm",
    });
    ushell_test_cmd.step.dependOn(b.getInstallStep());
    const ushell_test_step = b.step("ushell-test", "Shell running in user mode via syscalls");
    ushell_test_step.dependOn(&ushell_test_cmd.step);
    llvm_ushell_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ushell_test_step = b.step("llvm-ushell-test", "LLVM-lowered shell running in user mode via syscalls");
    llvm_ushell_test_step.dependOn(&llvm_ushell_test_cmd.step);


    shell2_test_cmd.step.dependOn(b.getInstallStep());
    const shell2_test_step = b.step("shell2-test", "Shell: tokenize + builtins with output");
    shell2_test_step.dependOn(&shell2_test_cmd.step);


    const vfsmount_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfsmount-test",
    });
    vfsmount_test_cmd.step.dependOn(b.getInstallStep());
    const vfsmount_test_step = b.step("vfsmount-test", "VFS mount switch");
    vfsmount_test_step.dependOn(&vfsmount_test_cmd.step);

    const treefs_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "treefs-test",
    });
    treefs_test_cmd.step.dependOn(b.getInstallStep());
    const treefs_test_step = b.step("treefs-test", "Hierarchical tree FS: nested mkdir/create, path resolution, ./.. traversal, getdents listing, typed errors");
    treefs_test_step.dependOn(&treefs_test_cmd.step);

    const fs_toolserver_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fs-toolserver-test",
    });
    fs_toolserver_test_cmd.step.dependOn(b.getInstallStep());
    const fs_toolserver_test_step = b.step("fs-toolserver-test", "Capability-checked FS tool server: workspace-scoped path caps deny /etc + .. escapes with audit/attribution (M1 walking skeleton)");
    fs_toolserver_test_step.dependOn(&fs_toolserver_test_cmd.step);

    const agent_fs_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "agent-fs-test",
    });
    agent_fs_test_cmd.step.dependOn(b.getInstallStep());
    const agent_fs_test_step = b.step("agent-fs-test", "Agent FS tool front door: allowlist+budget gate over the path-capability server; M6-shape acceptance (deny+audit+attribute)");
    agent_fs_test_step.dependOn(&agent_fs_test_cmd.step);

    const policy_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "policy-test",
    });
    policy_test_cmd.step.dependOn(b.getInstallStep());
    const policy_test_step = b.step("policy-test", "Policy plane: drain audit provenance into per-agent counters; denial pressure escalates Allow/Throttle/Revoke/Kill (M5 seed)");
    policy_test_step.dependOn(&policy_test_cmd.step);

    const netcap_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "netcap-test",
    });
    netcap_test_cmd.step.dependOn(b.getInstallStep());
    const netcap_test_step = b.step("netcap-test", "Capability-gated network egress: default-deny NetCap, audited+attributed allow/deny, attenuation only narrows (milestone #3)");
    netcap_test_step.dependOn(&netcap_test_cmd.step);

    const agent_containment_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "agent-containment-test",
    });
    agent_containment_test_cmd.step.dependOn(b.getInstallStep());
    const agent_containment_test_step = b.step("agent-containment-test", "Capstone M6-shape integration: every containment layer over a shared audit ring; benign task completes, all injected forbidden actions denied+audited, policy escalates");
    agent_containment_test_step.dependOn(&agent_containment_test_cmd.step);

    const mcp_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mcp-test",
    });
    mcp_test_cmd.step.dependOn(b.getInstallStep());
    const mcp_test_step = b.step("mcp-test", "MCP-compatible facade: method names resolve to native capability-checked tools (speak MCP, enforce with MC caps)");
    mcp_test_step.dependOn(&mcp_test_cmd.step);

    // examples/feature_showcase.mc — one self-verifying tour of the language; emit-c via
    // the host harness here, emit-llvm auto-covered by llvm-host-suite-test. Returns 1 iff
    // every demonstrated feature produces its expected result on the backend under test.
    const showcase_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "showcase-test",
    });
    showcase_test_cmd.step.dependOn(b.getInstallStep());
    const showcase_test_step = b.step("showcase-test", "Language feature showcase (examples/feature_showcase.mc): one self-verifying program touring MC's features; returns 1 iff every feature's result is exactly right");
    showcase_test_step.dependOn(&showcase_test_cmd.step);

    // Native `#[test]` facility: discover #[test] functions (mcc list-tests) and run each
    // process-isolated, reporting pass/fail by name. emit-c here, emit-llvm below.
    const mc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "c", "tests/test/lang_tests.mc",
    });
    mc_test_cmd.step.dependOn(b.getInstallStep());
    const mc_test_step = b.step("mc-test", "Run the native #[test] functions in tests/test/lang_tests.mc, each process-isolated (a failing assert -> named FAIL), via tools/test/mc-test-runner.sh (emit-c)");
    mc_test_step.dependOn(&mc_test_cmd.step);

    const llvm_mc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "llvm", "tests/test/lang_tests.mc",
    });
    llvm_mc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_mc_test_step = b.step("llvm-mc-test", "Run the native #[test] functions through the LLVM backend, each process-isolated, via tools/test/mc-test-runner.sh");
    llvm_mc_test_step.dependOn(&llvm_mc_test_cmd.step);

    // Opt-in module visibility (`pub`): a strict module's pub surface is reachable across
    // files, its private items are not (E_PRIVATE_IMPORT). Checks both directions.
    const mod_visibility_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/module-visibility-test.sh", "zig-out/bin/mcc", "c",
    });
    mod_visibility_test_cmd.step.dependOn(b.getInstallStep());
    const mod_visibility_test_step = b.step("mod-visibility-test", "Opt-in `pub` module visibility (emit-c): a strict module's pub API is reachable across files; cross-file use of a private item is E_PRIVATE_IMPORT");
    mod_visibility_test_step.dependOn(&mod_visibility_test_cmd.step);

    const llvm_mod_visibility_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/module-visibility-test.sh", "zig-out/bin/mcc", "llvm",
    });
    llvm_mod_visibility_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_mod_visibility_test_step = b.step("llvm-mod-visibility-test", "Opt-in `pub` module visibility (LLVM backend): pub API reachable across files; private cross-file use is E_PRIVATE_IMPORT");
    llvm_mod_visibility_test_step.dependOn(&llvm_mod_visibility_test_cmd.step);

    // std/sort — in-place insertion sort + ordered search (concrete u32 + generic comparator).
    const sort_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "c", "tests/test/sort_test.mc",
    });
    sort_test_cmd.step.dependOn(b.getInstallStep());
    const sort_test_step = b.step("sort-test", "std/sort (emit-c): in-place sort + binary search (concrete u32 and generic comparator-closure), via the #[test] runner");
    sort_test_step.dependOn(&sort_test_cmd.step);

    const llvm_sort_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/test/mc-test-runner.sh", "zig-out/bin/mcc", "llvm", "tests/test/sort_test.mc",
    });
    llvm_sort_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sort_test_step = b.step("llvm-sort-test", "std/sort (LLVM backend): in-place sort + binary search, via the #[test] runner");
    llvm_sort_test_step.dependOn(&llvm_sort_test_cmd.step);

    const fdspace_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdspace-test",
    });
    const slotmap_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "slotmap-test",
    });
    const mask_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mask-test",
    });
    const mailbox_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mailbox-test",
    });
    const tryelse_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tryelse-test",
    });
    const byteview_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "byteview-test",
    });
    const scan_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scan-test",
    });
    scan_test_cmd.step.dependOn(b.getInstallStep());
    const scan_test_step = b.step("scan-test", "find_index/any closure scan");
    scan_test_step.dependOn(&scan_test_cmd.step);


    byteview_test_cmd.step.dependOn(b.getInstallStep());
    const byteview_test_step = b.step("byteview-test", "ByteBuf<N> inline buffer view");
    byteview_test_step.dependOn(&byteview_test_cmd.step);


    tryelse_test_cmd.step.dependOn(b.getInstallStep());
    const tryelse_test_step = b.step("tryelse-test", "EXPR? else MAPPED error remap");
    tryelse_test_step.dependOn(&tryelse_test_cmd.step);


    mailbox_test_cmd.step.dependOn(b.getInstallStep());
    const mailbox_test_step = b.step("mailbox-test", "Mailbox<T,N> bounded queue + source filter");
    mailbox_test_step.dependOn(&mailbox_test_cmd.step);


    mask_test_cmd.step.dependOn(b.getInstallStep());
    const mask_test_step = b.step("mask-test", "Mask32 bit set");
    mask_test_step.dependOn(&mask_test_cmd.step);


    const rights_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "rights-test",
    });
    rights_test_cmd.step.dependOn(b.getInstallStep());
    const rights_test_step = b.step("rights-test", "K1 unforgeable+monotonic Rights/RCap (narrow-only attenuation, parent⊇child law)");
    rights_test_step.dependOn(&rights_test_cmd.step);


    const mmio_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mmio-test",
    });
    mmio_test_cmd.step.dependOn(b.getInstallStep());
    const mmio_test_step = b.step("mmio-test", "std/mmio register-field helpers + ordered IO-memory copy");
    mmio_test_step.dependOn(&mmio_test_cmd.step);


    const synclock_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "synclock-test",
    });
    synclock_test_cmd.step.dependOn(b.getInstallStep());
    const synclock_test_step = b.step("synclock-test", "std/rwlock + std/seqlock reader-writer and sequence locks");
    synclock_test_step.dependOn(&synclock_test_cmd.step);


    const ipc_result_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ipc-result-test",
    });
    ipc_result_test_cmd.step.dependOn(b.getInstallStep());
    const ipc_result_test_step = b.step("ipc-result-test", "ipc_send_result: typed bounded send (Denied/DeadTarget/Timeout)");
    ipc_result_test_step.dependOn(&ipc_result_test_cmd.step);


    const arp_cache_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arp-cache-test",
    });
    arp_cache_test_cmd.step.dependOn(b.getInstallStep());
    const arp_cache_test_step = b.step("arp-cache-test", "ARP IP->MAC cache: insert/lookup/refresh/invalidate/eviction");
    arp_cache_test_step.dependOn(&arp_cache_test_cmd.step);


    const tlb_shootdown_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tlb-shootdown-test",
    });
    tlb_shootdown_test_cmd.step.dependOn(b.getInstallStep());
    const tlb_shootdown_test_step = b.step("tlb-shootdown-test", "TLB shootdown bookkeeping: target/ack core masks + completion");
    tlb_shootdown_test_step.dependOn(&tlb_shootdown_test_cmd.step);


    const mutex_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mutex-test",
    });
    mutex_test_cmd.step.dependOn(b.getInstallStep());
    const mutex_test_step = b.step("mutex-test", "sleeping Mutex: try_lock, blocking enqueue, FIFO hand-off on unlock");
    mutex_test_step.dependOn(&mutex_test_cmd.step);


    slotmap_test_cmd.step.dependOn(b.getInstallStep());
    const slotmap_test_step = b.step("slotmap-test", "SlotMap<T,N> index handle table");
    slotmap_test_step.dependOn(&slotmap_test_cmd.step);


    const posix_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "posix-test",
    });
    const userland_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "userland-test",
    });
    const smprq_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "smprq-test",
    });
    const rtc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_rtc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const contain_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_contain_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const tcp_server_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_tcp_server_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const fdt_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdt-test",
    });
    fdt_test_cmd.step.dependOn(b.getInstallStep());
    const fdt_test_step = b.step("fdt-test", "Device-tree (FDT) header parsing");
    fdt_test_step.dependOn(&fdt_test_cmd.step);

    const fb_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fb-test",
    });
    const dynlink_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dynlink-test",
    });
    const aarch64_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_aarch64_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const arm_vm_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_arm_vm_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/arm-vm-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const arm_user_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_arm_user_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/arm-user-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const liveupdate_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "liveupdate-test",
    });
    const sbi_boot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_sbi_boot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const fdt_boot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_fdt_boot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/fdt-boot-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const fdt_devices_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_fdt_devices_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/fdt-devices-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const bootinfo_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_bootinfo_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/bootinfo-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const uart_driver_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_uart_driver_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/uart-driver-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const smode_user_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_smode_user_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/smode-user-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const e1000_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_e1000_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/e1000-test.sh", "zig-out/bin/mcc", "llvm",
    });
    e1000_test_cmd.step.dependOn(b.getInstallStep());
    const e1000_test_step = b.step("e1000-test", "Real e1000 NIC PCI probe");
    e1000_test_step.dependOn(&e1000_test_cmd.step);
    llvm_e1000_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_e1000_test_step = b.step("llvm-e1000-test", "LLVM-lowered real e1000 NIC PCI probe");
    llvm_e1000_test_step.dependOn(&llvm_e1000_test_cmd.step);


    sbi_boot_test_cmd.step.dependOn(b.getInstallStep());
    const sbi_boot_test_step = b.step("sbi-boot-test", "Boot under OpenSBI (real firmware)");
    sbi_boot_test_step.dependOn(&sbi_boot_test_cmd.step);
    llvm_sbi_boot_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sbi_boot_test_step = b.step("llvm-sbi-boot-test", "LLVM-lowered boot under OpenSBI (real firmware)");
    llvm_sbi_boot_test_step.dependOn(&llvm_sbi_boot_test_cmd.step);

    fdt_boot_test_cmd.step.dependOn(b.getInstallStep());
    const fdt_boot_test_step = b.step("fdt-boot-test", "Boot under OpenSBI + parse DTB /memory (FDT discovery)");
    fdt_boot_test_step.dependOn(&fdt_boot_test_cmd.step);
    llvm_fdt_boot_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fdt_boot_test_step = b.step("llvm-fdt-boot-test", "LLVM-lowered boot under OpenSBI + parse DTB /memory");
    llvm_fdt_boot_test_step.dependOn(&llvm_fdt_boot_test_cmd.step);

    fdt_devices_test_cmd.step.dependOn(b.getInstallStep());
    const fdt_devices_test_step = b.step("fdt-devices-test", "Boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT compatible strings");
    fdt_devices_test_step.dependOn(&fdt_devices_test_cmd.step);
    llvm_fdt_devices_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fdt_devices_test_step = b.step("llvm-fdt-devices-test", "LLVM-lowered boot under OpenSBI + discover UART/PLIC/virtio-mmio via FDT");
    llvm_fdt_devices_test_step.dependOn(&llvm_fdt_devices_test_cmd.step);

    bootinfo_test_cmd.step.dependOn(b.getInstallStep());
    const bootinfo_test_step = b.step("bootinfo-test", "Boot under OpenSBI + normalize FDT into the arch-neutral BootInfo (§3.1)");
    bootinfo_test_step.dependOn(&bootinfo_test_cmd.step);
    llvm_bootinfo_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_bootinfo_test_step = b.step("llvm-bootinfo-test", "LLVM-lowered boot under OpenSBI + normalize FDT into the arch-neutral BootInfo");
    llvm_bootinfo_test_step.dependOn(&llvm_bootinfo_test_cmd.step);

    uart_driver_test_cmd.step.dependOn(b.getInstallStep());
    const uart_driver_test_step = b.step("uart-driver-test", "Boot under OpenSBI + discover UART base from FDT + drive first-class LSR-polled NS16550 driver");
    uart_driver_test_step.dependOn(&uart_driver_test_cmd.step);
    llvm_uart_driver_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_uart_driver_test_step = b.step("llvm-uart-driver-test", "LLVM-lowered boot under OpenSBI + FDT-discovered first-class NS16550 driver");
    llvm_uart_driver_test_step.dependOn(&llvm_uart_driver_test_cmd.step);

    smode_user_test_cmd.step.dependOn(b.getInstallStep());
    const smode_user_test_step = b.step("smode-user-test", "S-mode U-mode hello under OpenSBI (SYS_WRITE + bad-ptr -EFAULT)");
    smode_user_test_step.dependOn(&smode_user_test_cmd.step);
    llvm_smode_user_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smode_user_test_step = b.step("llvm-smode-user-test", "LLVM-lowered S-mode U-mode hello under OpenSBI");
    llvm_smode_user_test_step.dependOn(&llvm_smode_user_test_cmd.step);


    liveupdate_test_cmd.step.dependOn(b.getInstallStep());
    const liveupdate_test_step = b.step("liveupdate-test", "Live update (state handoff)");
    liveupdate_test_step.dependOn(&liveupdate_test_cmd.step);


    aarch64_test_cmd.step.dependOn(b.getInstallStep());
    const aarch64_test_step = b.step("aarch64-test", "Second architecture (aarch64) bring-up");
    aarch64_test_step.dependOn(&aarch64_test_cmd.step);
    llvm_aarch64_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_aarch64_test_step = b.step("llvm-aarch64-test", "LLVM-lowered second architecture (aarch64) bring-up");
    llvm_aarch64_test_step.dependOn(&llvm_aarch64_test_cmd.step);

    arm_vm_test_cmd.step.dependOn(b.getInstallStep());
    const arm_vm_test_step = b.step("arm-vm-test", "AArch64 stage-1 page-table VM + MMU enable (real VA->PA translation)");
    arm_vm_test_step.dependOn(&arm_vm_test_cmd.step);
    llvm_arm_vm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_arm_vm_test_step = b.step("llvm-arm-vm-test", "LLVM-lowered AArch64 stage-1 page-table VM + MMU enable");
    llvm_arm_vm_test_step.dependOn(&llvm_arm_vm_test_cmd.step);
    arm_user_test_cmd.step.dependOn(b.getInstallStep());
    const arm_user_test_step = b.step("arm-user-test", "AArch64 EL0 user hello: SYS_WRITE via svc #0, bad user ptr -> -EFAULT via a software page-table walk (no data abort), clean SYS_EXIT");
    arm_user_test_step.dependOn(&arm_user_test_cmd.step);
    llvm_arm_user_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_arm_user_test_step = b.step("llvm-arm-user-test", "LLVM-lowered AArch64 EL0 user hello: EL0 syscall round-trip + bad-ptr -EFAULT software walk under QEMU");
    llvm_arm_user_test_step.dependOn(&llvm_arm_user_test_cmd.step);

    // M9: confined QuickJS agent on AArch64 EL0 (the AArch64 analogue of x86 M7 / riscv M3).
    const arm_qjs_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "c" });
    arm_qjs_test_cmd.step.dependOn(b.getInstallStep());
    const arm_qjs_test_step = b.step("arm-qjs-test", "M9: run a PURE-JS agent (fixed generic C host) confined in an aarch64 EL0 space under QEMU, with async host I/O over svc #0");
    arm_qjs_test_step.dependOn(&arm_qjs_test_cmd.step);
    const llvm_arm_qjs_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_arm_qjs_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_arm_qjs_test_step = b.step("llvm-arm-qjs-test", "M9 (LLVM): run a PURE-JS agent confined in an aarch64 EL0 space under QEMU, with async host I/O");
    llvm_arm_qjs_test_step.dependOn(&llvm_arm_qjs_test_cmd.step);
    const arm_qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "arm-qjs-async" });
    arm_qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const arm_qjs_async_test_step = b.step("arm-qjs-async-test", "M9: a pure-JS agent proves overlap + back-pressure/denial over async host I/O in aarch64 EL0");
    arm_qjs_async_test_step.dependOn(&arm_qjs_async_test_cmd.step);
    const llvm_arm_qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/arm-qjs-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "arm-qjs-async" });
    llvm_arm_qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_arm_qjs_async_test_step = b.step("llvm-arm-qjs-async-test", "M9 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O in aarch64 EL0");
    llvm_arm_qjs_async_test_step.dependOn(&llvm_arm_qjs_async_test_cmd.step);


    dynlink_test_cmd.step.dependOn(b.getInstallStep());
    const dynlink_test_step = b.step("dynlink-test", "Dynamic-linking relocation core");
    dynlink_test_step.dependOn(&dynlink_test_cmd.step);


    fb_test_cmd.step.dependOn(b.getInstallStep());
    const fb_test_step = b.step("fb-test", "Linear framebuffer device");
    fb_test_step.dependOn(&fb_test_cmd.step);


    tcp_server_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_server_test_step = b.step("tcp-server-test", "TCP connection state machine as a server");
    tcp_server_test_step.dependOn(&tcp_server_test_cmd.step);
    llvm_tcp_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_tcp_server_test_step = b.step("llvm-tcp-server-test", "LLVM-lowered TCP connection state machine as a server");
    llvm_tcp_server_test_step.dependOn(&llvm_tcp_server_test_cmd.step);


    contain_test_cmd.step.dependOn(b.getInstallStep());
    const contain_test_step = b.step("contain-test", "MMU crash containment");
    contain_test_step.dependOn(&contain_test_cmd.step);
    llvm_contain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_contain_test_step = b.step("llvm-contain-test", "Run LLVM-lowered MMU crash containment under QEMU");
    llvm_contain_test_step.dependOn(&llvm_contain_test_cmd.step);


    rtc_test_cmd.step.dependOn(b.getInstallStep());
    const rtc_test_step = b.step("rtc-test", "Wall-clock via goldfish-RTC: read the 64-bit epoch and assert a plausible live 'now'");
    rtc_test_step.dependOn(&rtc_test_cmd.step);
    llvm_rtc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_rtc_test_step = b.step("llvm-rtc-test", "Run LLVM-lowered goldfish-RTC MMIO under QEMU");
    llvm_rtc_test_step.dependOn(&llvm_rtc_test_cmd.step);


    smprq_test_cmd.step.dependOn(b.getInstallStep());
    const smprq_test_step = b.step("smprq-test", "SMP per-core run queues + work stealing");
    smprq_test_step.dependOn(&smprq_test_cmd.step);


    userland_test_cmd.step.dependOn(b.getInstallStep());
    const userland_test_step = b.step("userland-test", "Userland echo utility");
    userland_test_step.dependOn(&userland_test_cmd.step);


    posix_test_cmd.step.dependOn(b.getInstallStep());
    const posix_test_step = b.step("posix-test", "POSIX syscall surface");
    posix_test_step.dependOn(&posix_test_cmd.step);


    fdspace_test_cmd.step.dependOn(b.getInstallStep());
    const fdspace_test_step = b.step("fdspace-test", "FdSpace (kernel/lib): fd alloc/select, sentinel-free");
    fdspace_test_step.dependOn(&fdspace_test_cmd.step);
    const snapshot_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "snapshot-test" });
    snapshot_test_cmd.step.dependOn(b.getInstallStep());
    const snapshot_test_step = b.step("snapshot-test", "proc_snapshot (kernel/lib): stable process enumeration");
    snapshot_test_step.dependOn(&snapshot_test_cmd.step);

    const waitqueue_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "waitqueue-test" });
    waitqueue_test_cmd.step.dependOn(b.getInstallStep());
    const waitqueue_test_step = b.step("waitqueue-test", "WaitQueue (kernel/lib): block/wake/idle policy");
    waitqueue_test_step.dependOn(&waitqueue_test_cmd.step);

    const service_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "service-test" });
    service_test_cmd.step.dependOn(b.getInstallStep());
    const service_test_step = b.step("service-test", "service (kernel/lib): request/reply server loop");
    service_test_step.dependOn(&service_test_cmd.step);

    const plugin_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "plugin-test" });
    plugin_test_cmd.step.dependOn(b.getInstallStep());
    const plugin_test_step = b.step("plugin-test", "pluggable boot flow: device/bus probe-attach + registry + discovery");
    plugin_test_step.dependOn(&plugin_test_cmd.step);

    const endpoint_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "endpoint-test" });
    endpoint_test_cmd.step.dependOn(b.getInstallStep());
    const endpoint_test_step = b.step("endpoint-test", "MINIX hardening: endpoints/generations, derived runnable, death cleanup");
    endpoint_test_step.dependOn(&endpoint_test_cmd.step);

    const supervisor_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "supervisor-test" });
    supervisor_test_cmd.step.dependOn(b.getInstallStep());
    const supervisor_test_step = b.step("supervisor-test", "service supervisor: declarative manifests + restart policy");
    supervisor_test_step.dependOn(&supervisor_test_cmd.step);

    const registry2_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "registry2-test" });
    registry2_test_cmd.step.dependOn(b.getInstallStep());
    const registry2_test_step = b.step("registry2-test", "Registry v2: multiple-per-class, generations, unregister-on-death");
    registry2_test_step.dependOn(&registry2_test_cmd.step);

    const manifest_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "manifest-test" });
    manifest_test_cmd.step.dependOn(b.getInstallStep());
    const manifest_test_step = b.step("manifest-test", "enforced service manifests: privileges applied + enforced");
    manifest_test_step.dependOn(&manifest_test_cmd.step);

    const scheduler_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scheduler-test" });
    scheduler_test_cmd.step.dependOn(b.getInstallStep());
    const scheduler_test_step = b.step("scheduler-test", "scheduler service: quantum expiry notify + refresh");
    scheduler_test_step.dependOn(&scheduler_test_cmd.step);

    const info_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "info-test" });
    info_test_cmd.step.dependOn(b.getInstallStep());
    const info_test_step = b.step("info-test", "info/snapshot service: top queries over IPC");
    info_test_step.dependOn(&info_test_cmd.step);

    const granttab_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "granttab-test" });
    granttab_test_cmd.step.dependOn(b.getInstallStep());
    const granttab_test_step = b.step("granttab-test", "owner-tracked grants: bounded IPC sharing + revoke-on-death");
    granttab_test_step.dependOn(&granttab_test_cmd.step);

    const x86_sched_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-sched-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_sched_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-sched-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_sched_test_cmd.step.dependOn(b.getInstallStep());
    const x86_sched_test_step = b.step("x86-sched-test", "x86-64 arch port: cooperative context switch (native)");
    x86_sched_test_step.dependOn(&x86_sched_test_cmd.step);
    llvm_x86_sched_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_sched_test_step = b.step("llvm-x86-sched-test", "LLVM-lowered x86-64 arch port: cooperative context switch (native)");
    llvm_x86_sched_test_step.dependOn(&llvm_x86_sched_test_cmd.step);

    const x86_qemu_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qemu-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_qemu_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qemu-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_qemu_test_cmd.step.dependOn(b.getInstallStep());
    const x86_qemu_test_step = b.step("x86-qemu-test", "x86-64 kernel boots under QEMU (multiboot -> long mode)");
    x86_qemu_test_step.dependOn(&x86_qemu_test_cmd.step);
    llvm_x86_qemu_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_qemu_test_step = b.step("llvm-x86-qemu-test", "LLVM-lowered x86-64 kernel boots under QEMU (multiboot -> long mode)");
    llvm_x86_qemu_test_step.dependOn(&llvm_x86_qemu_test_cmd.step);

    const x86_vm_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-vm-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_vm_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-vm-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_vm_test_cmd.step.dependOn(b.getInstallStep());
    const x86_vm_test_step = b.step("x86-vm-test", "x86-64 builds a fresh 4-level page table, loads CR3, reads a translation-only VA (real VA->PA)");
    x86_vm_test_step.dependOn(&x86_vm_test_cmd.step);
    llvm_x86_vm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_vm_test_step = b.step("llvm-x86-vm-test", "LLVM-lowered x86-64 4-level page-table VM: build, CR3 reload, translation-only readback under QEMU");
    llvm_x86_vm_test_step.dependOn(&llvm_x86_vm_test_cmd.step);

    // X4: x86-64 Local-APIC timer — REAL, non-polled interrupt delivery. PICs masked, LAPIC timer
    // periodic at IDT vec 0x20, sti + hlt-spin until ticks fire.
    const x86_timer_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-timer-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_timer_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-timer-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_timer_test_cmd.step.dependOn(b.getInstallStep());
    const x86_timer_test_step = b.step("x86-timer-test", "x86-64 Local-APIC timer fires real interrupts (PICs masked) at IDT vec 0x20; sti + hlt-spin until ticks>=3 under QEMU");
    x86_timer_test_step.dependOn(&x86_timer_test_cmd.step);
    llvm_x86_timer_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_timer_test_step = b.step("llvm-x86-timer-test", "LLVM-lowered x86-64 Local-APIC timer: real periodic interrupts at vec 0x20, hlt-spin until ticks>=3 under QEMU");
    llvm_x86_timer_test_step.dependOn(&llvm_x86_timer_test_cmd.step);

    // X5: x86-64 PCI / virtio-pci device discovery — REAL config-space enumeration via the legacy
    // CAM port-I/O mechanism (0xCF8/0xCFC). Scans bus 0, finds the QEMU virtio-blk-pci device
    // (vendor 0x1AF4), reports its identity over COM1 (the analogue of RISC-V FDT/ECAM discovery).
    const x86_pci_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-pci-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_pci_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-pci-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_pci_test_cmd.step.dependOn(b.getInstallStep());
    const x86_pci_test_step = b.step("x86-pci-test", "x86-64 enumerates PCI bus 0 via legacy CAM port I/O (0xCF8/0xCFC), discovers the QEMU virtio-pci device (vendor 0x1AF4) under QEMU");
    x86_pci_test_step.dependOn(&x86_pci_test_cmd.step);
    llvm_x86_pci_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_pci_test_step = b.step("llvm-x86-pci-test", "LLVM-lowered x86-64 PCI discovery: legacy CAM port-I/O enumeration of the QEMU virtio-pci device under QEMU");
    llvm_x86_pci_test_step.dependOn(&llvm_x86_pci_test_cmd.step);

    const x86_user_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-user-test.sh", "zig-out/bin/mcc", "c" });
    const llvm_x86_user_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-user-test.sh", "zig-out/bin/mcc", "llvm" });
    x86_user_test_cmd.step.dependOn(b.getInstallStep());
    const x86_user_test_step = b.step("x86-user-test", "x86-64 ring-3 user hello: SYS_WRITE via int 0x80, bad user ptr -> -EFAULT via a software page-table walk (no #PF), clean SYS_EXIT");
    x86_user_test_step.dependOn(&x86_user_test_cmd.step);
    llvm_x86_user_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_user_test_step = b.step("llvm-x86-user-test", "LLVM-lowered x86-64 ring-3 user hello: ring-3 syscall round-trip + bad-ptr -EFAULT software walk under QEMU");
    llvm_x86_user_test_step.dependOn(&llvm_x86_user_test_cmd.step);

    // M7: confined QuickJS agent on x86_64 ring-3 (the x86 analogue of the riscv M3 qjs-smode-agent).
    const x86_qjs_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "c" });
    x86_qjs_test_cmd.step.dependOn(b.getInstallStep());
    const x86_qjs_test_step = b.step("x86-qjs-test", "M7: run a PURE-JS agent (fixed generic C host) confined in an x86-64 ring-3 space under QEMU, with async host I/O over int 0x80");
    x86_qjs_test_step.dependOn(&x86_qjs_test_cmd.step);
    const llvm_x86_qjs_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_x86_qjs_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_qjs_test_step = b.step("llvm-x86-qjs-test", "M7 (LLVM): run a PURE-JS agent confined in an x86-64 ring-3 space under QEMU, with async host I/O");
    llvm_x86_qjs_test_step.dependOn(&llvm_x86_qjs_test_cmd.step);

    const x86_qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "x86-qjs-async" });
    x86_qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const x86_qjs_async_test_step = b.step("x86-qjs-async-test", "M7: a pure-JS agent proves overlap + back-pressure/denial over async host I/O in x86-64 ring 3");
    x86_qjs_async_test_step.dependOn(&x86_qjs_async_test_cmd.step);
    const llvm_x86_qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/x86-qjs-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "x86-qjs-async" });
    llvm_x86_qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_x86_qjs_async_test_step = b.step("llvm-x86-qjs-async-test", "M7 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O in x86-64 ring 3");
    llvm_x86_qjs_async_test_step.dependOn(&llvm_x86_qjs_async_test_cmd.step);


    shell_test_cmd.step.dependOn(b.getInstallStep());
    const shell_test_step = b.step("shell-test", "Minimal shell");
    shell_test_step.dependOn(&shell_test_cmd.step);


    args_test_cmd.step.dependOn(b.getInstallStep());
    const args_test_step = b.step("args-test", "argv/envp vector");
    args_test_step.dependOn(&args_test_cmd.step);


    pgroup_test_cmd.step.dependOn(b.getInstallStep());
    const pgroup_test_step = b.step("pgroup-test", "Process groups + sessions");
    pgroup_test_step.dependOn(&pgroup_test_cmd.step);


    bcache_test_cmd.step.dependOn(b.getInstallStep());
    const bcache_test_step = b.step("bcache-test", "Write-back block cache");
    bcache_test_step.dependOn(&bcache_test_cmd.step);

    const cow_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/cow-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    cow_test_cmd.step.dependOn(b.getInstallStep());
    const cow_test_step = b.step("cow-test", "Copy-on-write: shared RO page diverges on write");
    cow_test_step.dependOn(&cow_test_cmd.step);

    const llvm_cow_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/cow-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_cow_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cow_test_step = b.step("llvm-cow-test", "Run LLVM-lowered copy-on-write fault handling under QEMU");
    llvm_cow_test_step.dependOn(&llvm_cow_test_cmd.step);

    const usched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/usched-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    usched_test_cmd.step.dependOn(b.getInstallStep());
    const usched_test_step = b.step("usched-test", "Userspace-set scheduling policy (priority)");
    usched_test_step.dependOn(&usched_test_cmd.step);

    const llvm_usched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/usched-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_usched_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_usched_test_step = b.step("llvm-usched-test", "Run LLVM-lowered userspace-set scheduling policy under QEMU");
    llvm_usched_test_step.dependOn(&llvm_usched_test_cmd.step);

    const userserver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/userserver-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    userserver_test_cmd.step.dependOn(b.getInstallStep());
    const userserver_test_step = b.step("userserver-test", "A server running in user mode via syscalls");
    userserver_test_step.dependOn(&userserver_test_cmd.step);

    const llvm_userserver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/userserver-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_userserver_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_userserver_test_step = b.step("llvm-userserver-test", "Run LLVM-lowered user-mode server under QEMU");
    llvm_userserver_test_step.dependOn(&llvm_userserver_test_cmd.step);

    const isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/isolation-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    isolation_test_cmd.step.dependOn(b.getInstallStep());
    const isolation_test_step = b.step("isolation-test", "Per-server MMU isolation + cross-AS IPC");
    isolation_test_step.dependOn(&isolation_test_cmd.step);

    const llvm_isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/isolation-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_isolation_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_isolation_test_step = b.step("llvm-isolation-test", "Run LLVM-lowered per-server MMU isolation under QEMU");
    llvm_isolation_test_step.dependOn(&llvm_isolation_test_cmd.step);

    const demand_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/demand-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    demand_test_cmd.step.dependOn(b.getInstallStep());
    const demand_test_step = b.step("demand-test", "Demand paging: fault -> map -> retry");
    demand_test_step.dependOn(&demand_test_cmd.step);

    const llvm_demand_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/demand-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_demand_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_demand_test_step = b.step("llvm-demand-test", "Run LLVM-lowered demand paging under QEMU");
    llvm_demand_test_step.dependOn(&llvm_demand_test_cmd.step);

    const mmap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/mmap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    mmap_test_cmd.step.dependOn(b.getInstallStep());
    const mmap_test_step = b.step("mmap-test", "mmap anonymous pages into a page table (active satp)");
    mmap_test_step.dependOn(&mmap_test_cmd.step);

    const llvm_mmap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/mmap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_mmap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_mmap_test_step = b.step("llvm-mmap-test", "Run LLVM-lowered anonymous mmap under QEMU");
    llvm_mmap_test_step.dependOn(&llvm_mmap_test_cmd.step);

    const diskfs_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "diskfs-test",
    });
    diskfs_test_cmd.step.dependOn(b.getInstallStep());
    const diskfs_test_step = b.step("diskfs-test", "On-disk FS: persistent format + inodes + named lookup");
    diskfs_test_step.dependOn(&diskfs_test_cmd.step);

    const heartbeat_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/heartbeat-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    heartbeat_test_cmd.step.dependOn(b.getInstallStep());
    const heartbeat_test_step = b.step("heartbeat-test", "Reincarnation with heartbeat liveness detection");
    heartbeat_test_step.dependOn(&heartbeat_test_cmd.step);

    const llvm_heartbeat_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/heartbeat-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_heartbeat_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_heartbeat_test_step = b.step("llvm-heartbeat-test", "Run LLVM-lowered heartbeat restart detection under QEMU");
    llvm_heartbeat_test_step.dependOn(&llvm_heartbeat_test_cmd.step);

    const timeout_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/timeout-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    timeout_test_cmd.step.dependOn(b.getInstallStep());
    const timeout_test_step = b.step("timeout-test", "IPC timeout: bounded receive, no infinite block");
    timeout_test_step.dependOn(&timeout_test_cmd.step);

    const llvm_timeout_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/timeout-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_timeout_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_timeout_test_step = b.step("llvm-timeout-test", "Run LLVM-lowered IPC timeout under QEMU");
    llvm_timeout_test_step.dependOn(&llvm_timeout_test_cmd.step);

    const privilege_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/privilege-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    privilege_test_cmd.step.dependOn(b.getInstallStep());
    const privilege_test_step = b.step("privilege-test", "Least privilege: IPC allow-list + kernel-call gate");
    privilege_test_step.dependOn(&privilege_test_cmd.step);

    const llvm_privilege_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/privilege-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_privilege_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_privilege_test_step = b.step("llvm-privilege-test", "Run LLVM-lowered least-privilege IPC and kcall gates under QEMU");
    llvm_privilege_test_step.dependOn(&llvm_privilege_test_cmd.step);

    const signal_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/signal-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    signal_test_cmd.step.dependOn(b.getInstallStep());
    const signal_test_step = b.step("signal-test", "Signals: deliver + poll + take an async signal");
    signal_test_step.dependOn(&signal_test_cmd.step);

    const llvm_signal_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/signal-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_signal_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_signal_test_step = b.step("llvm-signal-test", "Run LLVM-lowered signal delivery under QEMU");
    llvm_signal_test_step.dependOn(&llvm_signal_test_cmd.step);

    const registry_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/registry-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    registry_test_cmd.step.dependOn(b.getInstallStep());
    const registry_test_step = b.step("registry-test", "Name/registry server: lookup a service by name");
    registry_test_step.dependOn(&registry_test_cmd.step);

    const llvm_registry_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/registry-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_registry_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_registry_test_step = b.step("llvm-registry-test", "Run LLVM-lowered name/registry server under QEMU");
    llvm_registry_test_step.dependOn(&llvm_registry_test_cmd.step);

    const ipc2_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc2-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipc2_test_cmd.step.dependOn(b.getInstallStep());
    const ipc2_test_step = b.step("ipc2-test", "IPC completeness: multi-slot + source filter + notify");
    ipc2_test_step.dependOn(&ipc2_test_cmd.step);

    const llvm_ipc2_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc2-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipc2_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipc2_test_step = b.step("llvm-ipc2-test", "Run LLVM-lowered IPC multi-slot/source-filter/notify under QEMU");
    llvm_ipc2_test_step.dependOn(&llvm_ipc2_test_cmd.step);

    const grant_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "grant-test",
    });
    grant_test_cmd.step.dependOn(b.getInstallStep());
    const grant_test_step = b.step("grant-test", "Memory grant: bounded delegation + revocation");
    grant_test_step.dependOn(&grant_test_cmd.step);

    const ipc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipc_test_cmd.step.dependOn(b.getInstallStep());
    const ipc_test_step = b.step("ipc-test", "kernel-mediated IPC: client/server message round-trip");
    ipc_test_step.dependOn(&ipc_test_cmd.step);

    const llvm_ipc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipc_test_step = b.step("llvm-ipc-test", "Run LLVM-lowered kernel-mediated IPC under QEMU");
    llvm_ipc_test_step.dependOn(&llvm_ipc_test_cmd.step);

    const cap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/cap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    cap_test_cmd.step.dependOn(b.getInstallStep());
    const cap_test_step = b.step("cap-test", "capability least-privilege: driver-as-server holds the console cap");
    cap_test_step.dependOn(&cap_test_cmd.step);

    const llvm_cap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/cap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_cap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cap_test_step = b.step("llvm-cap-test", "Run LLVM-lowered capability least-privilege server under QEMU");
    llvm_cap_test_step.dependOn(&llvm_cap_test_cmd.step);

    const restart_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/restart-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    restart_test_cmd.step.dependOn(b.getInstallStep());
    const restart_test_step = b.step("restart-test", "reincarnation: supervisor restarts a crashed server");
    restart_test_step.dependOn(&restart_test_cmd.step);

    const llvm_restart_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/restart-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_restart_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_restart_test_step = b.step("llvm-restart-test", "Run LLVM-lowered reincarnation restart under QEMU");
    llvm_restart_test_step.dependOn(&llvm_restart_test_cmd.step);

    const arc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-test",
    });
    arc_test_cmd.step.dependOn(b.getInstallStep());
    const arc_test_step = b.step("arc-test", "Arc<T> shared ownership: clone/last-drop-frees, handles leak-checked");
    arc_test_step.dependOn(&arc_test_cmd.step);

    const arc_pkt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-pkt-test",
    });
    arc_pkt_test_cmd.step.dependOn(b.getInstallStep());
    const arc_pkt_test_step = b.step("arc-pkt-test", "packet Arc-shared between two consumers (skb/mbuf pattern)");
    arc_pkt_test_step.dependOn(&arc_pkt_test_cmd.step);

    const alloc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "alloc-test",
    });
    alloc_test_cmd.step.dependOn(b.getInstallStep());
    const alloc_test_step = b.step("alloc-test", "Link + run the type-erased std/alloc Allocator over a captured heap");
    alloc_test_step.dependOn(&alloc_test_cmd.step);

    const closure_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "closure-test",
    });
    closure_test_cmd.step.dependOn(b.getInstallStep());
    const closure_test_step = b.step("closure-test", "Link + run a bind() closure (capture + call across calls)");
    closure_test_step.dependOn(&closure_test_cmd.step);

    const ring_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ring-test",
    });
    ring_test_cmd.step.dependOn(b.getInstallStep());
    const ring_test_step = b.step("ring-test", "Link + run the generic in-place Ring<T> (push/pop/wrap)");
    ring_test_step.dependOn(&ring_test_cmd.step);

    const trace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "trace-test",
    });
    trace_test_cmd.step.dependOn(b.getInstallStep());
    const trace_test_step = b.step("trace-test", "Link + run the trace ring buffer (retention/wrap/sequence)");
    trace_test_step.dependOn(&trace_test_cmd.step);

    const log_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "log-test",
    });
    log_test_cmd.step.dependOn(b.getInstallStep());
    const log_test_step = b.step("log-test", "Link + run the leveled tracepoint logger (threshold/levels)");
    log_test_step.dependOn(&log_test_cmd.step);

    const tcp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-test",
    });
    tcp_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_test_step = b.step("tcp-test", "Link + run the TCP segment build/parse + checksum");
    tcp_test_step.dependOn(&tcp_test_cmd.step);

    const tcp_conn_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-conn-test",
    });
    tcp_conn_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_conn_test_step = b.step("tcp-conn-test", "Link + run the TCP connection state machine (handshake/close)");
    tcp_conn_test_step.dependOn(&tcp_conn_test_cmd.step);

    const tcp_window_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-window-test",
    });
    tcp_window_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_window_test_step = b.step("tcp-window-test", "Link + run the TCP send/recv window + ACK processing (data plane)");
    tcp_window_test_step.dependOn(&tcp_window_test_cmd.step);

    const tcp_reasm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-reasm-test",
    });
    tcp_reasm_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_reasm_test_step = b.step("tcp-reasm-test", "Link + run TCP reassembly + go-back-N retransmit");
    tcp_reasm_test_step.dependOn(&tcp_reasm_test_cmd.step);

    const tcp_rtx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-rtx-test",
    });
    tcp_rtx_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_rtx_test_step = b.step("tcp-rtx-test", "Link + run the TCP retransmit timer (RTO -> go-back-N)");
    tcp_rtx_test_step.dependOn(&tcp_rtx_test_cmd.step);

    const symbols_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "symbols-test",
    });
    symbols_test_cmd.step.dependOn(b.getInstallStep());
    const symbols_test_step = b.step("symbols-test", "Link + run the symbol table (symbolize address -> function+offset)");
    symbols_test_step.dependOn(&symbols_test_cmd.step);

    const socket_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "socket-test",
    });
    socket_test_cmd.step.dependOn(b.getInstallStep());
    const socket_test_step = b.step("socket-test", "Link + run the UDP socket layer (bind/deliver/recv demux)");
    socket_test_step.dependOn(&socket_test_cmd.step);

    const net_rx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-rx-test",
    });
    net_rx_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_test_step = b.step("net-rx-test", "Link + run the RX demux path (frame -> socket_deliver -> recv)");
    net_rx_test_step.dependOn(&net_rx_test_cmd.step);

    const net_fuzz_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-fuzz-test",
    });
    net_fuzz_test_cmd.step.dependOn(b.getInstallStep());
    const net_fuzz_test_step = b.step("net-fuzz-test", "Fuzz the RX parser with random frames (no OOB)");
    net_fuzz_test_step.dependOn(&net_fuzz_test_cmd.step);

    // P1: parser fuzz oracle — drive the DNS + TCP parsers over a million random /
    // truncated / malformed byte buffers; every parse must terminate and never over-read
    // (each read now routes through std/bytes' total checked reader, br_try_*).
    const parser_fuzz_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "parser-fuzz-test",
    });
    parser_fuzz_test_cmd.step.dependOn(b.getInstallStep());
    const parser_fuzz_test_step = b.step("parser-fuzz-test", "Fuzz the DNS+TCP parsers with malformed bytes (total, no over-read)");
    parser_fuzz_test_step.dependOn(&parser_fuzz_test_cmd.step);

    const net_rx_live_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-rx-live-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_net_rx_live_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-rx-live-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    net_rx_live_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_live_test_step = b.step("net-rx-live-test", "Route a real virtio-net RX frame through net_rx_deliver under QEMU");
    net_rx_live_test_step.dependOn(&net_rx_live_test_cmd.step);
    llvm_net_rx_live_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_net_rx_live_test_step = b.step("llvm-net-rx-live-test", "Route a real LLVM-lowered virtio-net RX frame through net_rx_deliver under QEMU");
    llvm_net_rx_live_test_step.dependOn(&llvm_net_rx_live_test_cmd.step);

    const http_get_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/http-get-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_http_get_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/http-get-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    http_get_test_cmd.step.dependOn(b.getInstallStep());
    const http_get_test_step = b.step("http-get-test", "Active-open a real TCP connection and HTTP GET a live server over virtio-net under QEMU");
    http_get_test_step.dependOn(&http_get_test_cmd.step);
    llvm_http_get_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_http_get_test_step = b.step("llvm-http-get-test", "Active-open a real LLVM-lowered TCP connection and HTTP GET a live server over virtio-net under QEMU");
    llvm_http_get_test_step.dependOn(&llvm_http_get_test_cmd.step);

    const bearssl_smoke_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/tls/bearssl-smoke-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    bearssl_smoke_test_cmd.step.dependOn(b.getInstallStep());
    const bearssl_smoke_test_step = b.step("bearssl-smoke-test", "Compute a SHA-256 vector via freestanding BearSSL and pull live virtio-rng entropy in a bare-metal riscv64 kernel under QEMU (Phase 1 TLS de-risking)");
    bearssl_smoke_test_step.dependOn(&bearssl_smoke_test_cmd.step);

    // bearssl-smode-test revalidates the SAME freestanding BearSSL SHA-256 vector +
    // live virtio-rng entropy under REAL OpenSBI in S-mode (boot seam only: SBI
    // console/shutdown, sbi.ld, rdtime CSR; no `-bios none`). Deterministic — no
    // network egress — so it is gated in m0.
    const bearssl_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/bearssl-smode-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    bearssl_smode_test_cmd.step.dependOn(b.getInstallStep());
    const bearssl_smode_test_step = b.step("bearssl-smode-test", "Revalidate the freestanding BearSSL SHA-256 vector + live virtio-rng entropy under REAL OpenSBI in S-mode (TLS crypto stack on the OpenSBI boot seam)");
    bearssl_smode_test_step.dependOn(&bearssl_smode_test_cmd.step);

    // https-smode-test revalidates the SAME deterministic in-kernel REAL BearSSL
    // TLS 1.2 handshake + HTTPS GET (against the LOCAL self-signed python server
    // over slirp loopback — no internet egress) under REAL OpenSBI in S-mode.
    const https_smode_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/https-smode-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    https_smode_test_cmd.step.dependOn(b.getInstallStep());
    const https_smode_test_step = b.step("https-smode-test", "Revalidate the in-kernel REAL BearSSL TLS 1.2 handshake + HTTPS GET (local server over slirp) under REAL OpenSBI in S-mode");
    https_smode_test_step.dependOn(&https_smode_test_cmd.step);

    // https-get-test: a REAL BearSSL TLS 1.2 handshake over the kernel's TCP, validating
    // a self-signed trust anchor and decrypting an HTTPS GET from a local python HTTPS
    // server under QEMU (Phase 2 of in-kernel TLS; deterministic CI gate).
    const https_get_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/tls/https-get-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_https_get_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/tls/https-get-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    https_get_test_cmd.step.dependOn(b.getInstallStep());
    const https_get_test_step = b.step("https-get-test", "Run a REAL BearSSL TLS 1.2 handshake over the kernel TCP and decrypt an HTTPS GET from a local python HTTPS server under QEMU");
    https_get_test_step.dependOn(&https_get_test_cmd.step);
    llvm_https_get_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_https_get_test_step = b.step("llvm-https-get-test", "Run a REAL LLVM-lowered BearSSL TLS 1.2 handshake over the kernel TCP and decrypt an HTTPS GET from a local python HTTPS server under QEMU");
    llvm_https_get_test_step.dependOn(&llvm_https_get_test_cmd.step);

    // google-https-test: best-effort REAL google.com:443 fetch validating Google's actual
    // cert chain against the embedded GTS Root R1. Standalone (PASS or honest SKIP);
    // deliberately NOT added to the m0 gate (no flaky CI dependency on internet egress).
    const google_https_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/tls/google-https-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    google_https_test_cmd.step.dependOn(b.getInstallStep());
    const google_https_test_step = b.step("google-https-test", "Best-effort REAL google.com:443 HTTPS fetch validating Google's actual cert chain against the embedded GTS Root R1 under QEMU (standalone; PASS or honest SKIP)");
    google_https_test_step.dependOn(&google_https_test_cmd.step);

    const dns_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/dns-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    const llvm_dns_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/dns-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    dns_test_cmd.step.dependOn(b.getInstallStep());
    const dns_test_step = b.step("dns-test", "Resolve a name via a real DNS A-query then HTTP GET that host over virtio-net under QEMU");
    dns_test_step.dependOn(&dns_test_cmd.step);
    llvm_dns_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_dns_test_step = b.step("llvm-dns-test", "Resolve a name via a real LLVM-lowered DNS A-query then HTTP GET that host over virtio-net under QEMU");
    llvm_dns_test_step.dependOn(&llvm_dns_test_cmd.step);

    const backtrace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/backtrace-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    backtrace_test_cmd.step.dependOn(b.getInstallStep());
    const backtrace_test_step = b.step("backtrace-test", "Walk the frame-pointer chain and symbolize the frames under QEMU");
    backtrace_test_step.dependOn(&backtrace_test_cmd.step);

    const llvm_backtrace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/backtrace-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_backtrace_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_backtrace_test_step = b.step("llvm-backtrace-test", "Run LLVM-lowered backtrace symbolization under QEMU");
    llvm_backtrace_test_step.dependOn(&llvm_backtrace_test_cmd.step);

    const paging_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    paging_test_cmd.step.dependOn(b.getInstallStep());
    const paging_test_step = b.step("paging-test", "Link + run Sv39 page-table map/translate");
    paging_test_step.dependOn(&paging_test_cmd.step);

    const llvm_paging_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_paging_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_paging_test_step = b.step("llvm-paging-test", "Link + run the LLVM-lowered Sv39 page-table map/translate");
    llvm_paging_test_step.dependOn(&llvm_paging_test_cmd.step);

    const fnptr_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/fnptr-test.sh",
        "zig-out/bin/mcc",
    });
    fnptr_test_cmd.step.dependOn(b.getInstallStep());
    const fnptr_test_step = b.step("fnptr-test", "Link + run function-pointer dispatch (callback, vtable, return)");
    fnptr_test_step.dependOn(&fnptr_test_cmd.step);

    const trap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/trap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    trap_test_cmd.step.dependOn(b.getInstallStep());
    const trap_test_step = b.step("trap-test", "Run the typed-CPU trap/timer interrupt path under QEMU");
    trap_test_step.dependOn(&trap_test_cmd.step);

    const llvm_trap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/trap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_trap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_trap_test_step = b.step("llvm-trap-test", "Run the LLVM-lowered typed-CPU trap/timer path under QEMU");
    llvm_trap_test_step.dependOn(&llvm_trap_test_cmd.step);

    const thread_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/thread-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    thread_test_cmd.step.dependOn(b.getInstallStep());
    const thread_test_step = b.step("thread-test", "Run cooperative context switching (main/worker ping-pong) under QEMU");
    thread_test_step.dependOn(&thread_test_cmd.step);

    const llvm_thread_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/thread-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_thread_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_thread_test_step = b.step("llvm-thread-test", "Run LLVM-lowered cooperative context switching under QEMU");
    llvm_thread_test_step.dependOn(&llvm_thread_test_cmd.step);

    const sched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    sched_test_cmd.step.dependOn(b.getInstallStep());
    const sched_test_step = b.step("sched-test", "Run the round-robin scheduler (3 heap-stacked threads) under QEMU");
    sched_test_step.dependOn(&sched_test_cmd.step);

    const llvm_sched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_sched_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sched_test_step = b.step("llvm-sched-test", "Run the LLVM-lowered round-robin scheduler under QEMU");
    llvm_sched_test_step.dependOn(&llvm_sched_test_cmd.step);

    const preempt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/preempt-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    preempt_test_cmd.step.dependOn(b.getInstallStep());
    const preempt_test_step = b.step("preempt-test", "Run the timer-driven preemptive scheduler under QEMU");
    preempt_test_step.dependOn(&preempt_test_cmd.step);

    const llvm_preempt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/preempt-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_preempt_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_preempt_test_step = b.step("llvm-preempt-test", "Run LLVM-lowered timer-driven preemption under QEMU");
    llvm_preempt_test_step.dependOn(&llvm_preempt_test_cmd.step);

    const syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    syscall_test_cmd.step.dependOn(b.getInstallStep());
    const syscall_test_step = b.step("syscall-test", "Run the ecall syscall dispatch skeleton under QEMU");
    syscall_test_step.dependOn(&syscall_test_cmd.step);

    const llvm_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_syscall_test_step = b.step("llvm-syscall-test", "Run the LLVM-lowered ecall syscall dispatch skeleton under QEMU");
    llvm_syscall_test_step.dependOn(&llvm_syscall_test_cmd.step);

    const user_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/user-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    user_test_cmd.step.dependOn(b.getInstallStep());
    const user_test_step = b.step("user-test", "Run the M->U privilege drop + user-mode syscalls under QEMU");
    user_test_step.dependOn(&user_test_cmd.step);

    const llvm_user_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/user-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_user_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_user_test_step = b.step("llvm-user-test", "Run the LLVM-lowered M->U privilege drop + user-mode syscalls under QEMU");
    llvm_user_test_step.dependOn(&llvm_user_test_cmd.step);

    const process_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/process-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    process_test_cmd.step.dependOn(b.getInstallStep());
    const process_test_step = b.step("process-test", "Run process lifecycle (spawn/run/exit) under QEMU");
    process_test_step.dependOn(&process_test_cmd.step);

    const llvm_process_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/process-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_process_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_process_test_step = b.step("llvm-process-test", "Run the LLVM-lowered process lifecycle under QEMU");
    llvm_process_test_step.dependOn(&llvm_process_test_cmd.step);

    const elf_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/elf-run-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    elf_run_test_cmd.step.dependOn(b.getInstallStep());
    const elf_run_test_step = b.step("elf-run-test", "Load an ELF64 and run it in U-mode under QEMU");
    elf_run_test_step.dependOn(&elf_run_test_cmd.step);

    const llvm_elf_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/elf-run-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_elf_run_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_elf_run_test_step = b.step("llvm-elf-run-test", "Load an ELF64 from an LLVM-lowered kernel image and run it in U-mode under QEMU");
    llvm_elf_run_test_step.dependOn(&llvm_elf_run_test_cmd.step);

    // The uaccess demos exercise kernel/core/uaccess.mc, which imports riscv paging.mc
    // (sfence.vma) — not host-assemblable — so they run under QEMU on the real target,
    // not on the host driver suite. One generic runtime+harness, parameterized by the
    // fixture and its entry symbol.
    const uaccess_pt_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c",
        "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test",
    });
    uaccess_pt_test_cmd.step.dependOn(b.getInstallStep());
    const uaccess_pt_test_step = b.step("uaccess-pt-test", "Page-table-aware user copies under QEMU: Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected (imports riscv paging.mc, so QEMU-only)");
    uaccess_pt_test_step.dependOn(&uaccess_pt_test_cmd.step);

    const llvm_uaccess_pt_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm",
        "tests/qemu/mem/uaccess_pt_demo.mc", "uaccess_pt_run", "uaccess-pt-test",
    });
    llvm_uaccess_pt_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_uaccess_pt_test_step = b.step("llvm-uaccess-pt-test", "Page-table-aware user copies under QEMU (LLVM backend): Sv39 walk + per-page PTE_U/R/W checks; kernel-only page, unmapped hole, off-page straddle all rejected");
    llvm_uaccess_pt_test_step.dependOn(&llvm_uaccess_pt_test_cmd.step);

    // kernel/core/elf_loader: real multi-segment ELF loader (Phase 1 of the QuickJS-agent
    // plan / review F3) — maps every PT_LOAD at its vaddr with per-segment perms, zeroes bss.
    const elf_loader_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c",
        "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test",
    });
    elf_loader_test_cmd.step.dependOn(b.getInstallStep());
    const elf_loader_test_step = b.step("elf-loader-test", "Multi-segment ELF64 loader under QEMU: maps every PT_LOAD at its vaddr with per-segment R/W/X perms, copies file bytes, zeroes bss; synthetic 2-segment image, asserts mappings/content/bss/perms");
    elf_loader_test_step.dependOn(&elf_loader_test_cmd.step);

    const llvm_elf_loader_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm",
        "tests/qemu/mem/elf_loader_demo.mc", "elf_loader_run", "elf-loader-test",
    });
    llvm_elf_loader_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_elf_loader_test_step = b.step("llvm-elf-loader-test", "Multi-segment ELF64 loader under QEMU (LLVM backend): per-segment perms, file copy, bss zero");
    llvm_elf_loader_test_step.dependOn(&llvm_elf_loader_test_cmd.step);

    const uaccess_snapshot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c",
        "tests/qemu/mem/uaccess_snapshot_demo.mc", "uaccess_snapshot_run", "uaccess-snapshot-test",
    });
    uaccess_snapshot_test_cmd.step.dependOn(b.getInstallStep());
    const uaccess_snapshot_test_step = b.step("uaccess-snapshot-test", "Single-snapshot uaccess (U2 double-fetch/TOCTOU defense) under QEMU: fetch_user freezes a user datum once; later user-byte flips don't change the snapshot");
    uaccess_snapshot_test_step.dependOn(&uaccess_snapshot_test_cmd.step);

    const llvm_uaccess_snapshot_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm",
        "tests/qemu/mem/uaccess_snapshot_demo.mc", "uaccess_snapshot_run", "uaccess-snapshot-test",
    });
    llvm_uaccess_snapshot_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_uaccess_snapshot_test_step = b.step("llvm-uaccess-snapshot-test", "Single-snapshot uaccess (U2) under QEMU (LLVM backend): fetch_user freezes a user datum once; later user-byte flips don't change the snapshot");
    llvm_uaccess_snapshot_test_step.dependOn(&llvm_uaccess_snapshot_test_cmd.step);

    const uaccess_taint_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "c",
        "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test",
    });
    uaccess_taint_test_cmd.step.dependOn(b.getInstallStep());
    const uaccess_taint_test_step = b.step("uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU: a user-derived scalar must pass checked_len/checked_index/validate_bound (fail closed) before driving a copy length or index");
    uaccess_taint_test_step.dependOn(&uaccess_taint_test_cmd.step);

    const llvm_uaccess_taint_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/uaccess-entry-test.sh", "zig-out/bin/mcc", "llvm",
        "tests/qemu/mem/uaccess_taint_demo.mc", "uaccess_taint_run", "uaccess-taint-test",
    });
    llvm_uaccess_taint_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_uaccess_taint_test_step = b.step("llvm-uaccess-taint-test", "Tainted untrusted lengths/indices (U3) under QEMU (LLVM backend): a user-derived scalar must pass checked_len/checked_index/validate_bound before driving a copy length or index");
    llvm_uaccess_taint_test_step.dependOn(&llvm_uaccess_taint_test_cmd.step);

    const agent_confined_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-confined-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agent_confined_test_cmd.step.dependOn(b.getInstallStep());
    const agent_confined_test_step = b.step("agent-confined-test", "Step 0: load a separate ELF into an isolated Sv39 address space (kernel unmapped) and run it confined in U-mode under QEMU");
    agent_confined_test_step.dependOn(&agent_confined_test_cmd.step);

    const llvm_agent_confined_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-confined-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agent_confined_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agent_confined_test_step = b.step("llvm-agent-confined-test", "Step 0 (LLVM): load a separate ELF into an isolated Sv39 address space and run it confined in U-mode under QEMU");
    llvm_agent_confined_test_step.dependOn(&llvm_agent_confined_test_cmd.step);

    // QuickJS-agent Phase 1 spine: build a real MC app (examples/apps/hello.mc) into a
    // multi-segment U-mode ELF via the userspace SDK, load it with the real elf_loader into
    // an isolated Sv39 space, and run it confined under QEMU — prints via SYS_WRITE (uaccess),
    // exits via SYS_EXIT.
    const app_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/app-run-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    app_run_test_cmd.step.dependOn(b.getInstallStep());
    const app_run_test_step = b.step("app-run-test", "QuickJS-agent Phase 1: build an MC app into a multi-segment ELF, load it (real elf_loader) into an isolated U-mode space, run it confined under QEMU — SYS_WRITE via uaccess + SYS_EXIT");
    app_run_test_step.dependOn(&app_run_test_cmd.step);

    const llvm_app_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/app-run-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_app_run_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_app_run_test_step = b.step("llvm-app-run-test", "QuickJS-agent Phase 1 (LLVM): build + run a confined MC app in an isolated U-mode space under QEMU");
    llvm_app_run_test_step.dependOn(&llvm_app_run_test_cmd.step);

    // Direct syscall-ABI fault test (review item 2): a confined MC app hands bad user pointers to
    // SYS_WRITE/SYS_READ/SYS_POLL and asserts -E_FAULT at runtime — proving the uaccess path fails
    // closed, rather than relying on static review of the kernel. Both backends.
    const fault_probe_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/fault-probe-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fault_probe_test_cmd.step.dependOn(b.getInstallStep());
    const fault_probe_test_step = b.step("fault-probe-test", "Syscall-ABI fault test: a confined app gets -E_FAULT from SYS_WRITE/READ/POLL on bad pointers under QEMU");
    fault_probe_test_step.dependOn(&fault_probe_test_cmd.step);

    const llvm_fault_probe_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/fault-probe-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fault_probe_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fault_probe_test_step = b.step("llvm-fault-probe-test", "Syscall-ABI fault test (LLVM): bad pointers to SYS_WRITE/READ/POLL return -E_FAULT under QEMU");
    llvm_fault_probe_test_step.dependOn(&llvm_fault_probe_test_cmd.step);

    // Tool-ABI quota test (review item 4): a confined MC app submits ToolReqs that breach each
    // quota and asserts the SPECIFIC errno — payload>MAX_REQ_BYTES/cap>MAX_RES_BYTES => -E_NOCAP,
    // unknown op => -E_DENIED, ring full => -E_AGAIN. Reuses app-run-test.sh (app+marker params).
    const quota_probe_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c",
        "examples/apps/quota_probe.mc", "QUOTA-PROBE: PASS", "quota-probe",
    });
    quota_probe_test_cmd.step.dependOn(b.getInstallStep());
    const quota_probe_test_step = b.step("quota-probe-test", "Tool-ABI quota test: ToolReq quota breaches return -E_NOCAP/-E_DENIED/-E_AGAIN under QEMU");
    quota_probe_test_step.dependOn(&quota_probe_test_cmd.step);

    const llvm_quota_probe_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm",
        "examples/apps/quota_probe.mc", "QUOTA-PROBE: PASS", "quota-probe",
    });
    llvm_quota_probe_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_quota_probe_test_step = b.step("llvm-quota-probe-test", "Tool-ABI quota test (LLVM): quota breaches return the specific errno under QEMU");
    llvm_quota_probe_test_step.dependOn(&llvm_quota_probe_test_cmd.step);

    // Mock-broker cancellation/timeout (review item 3): a confined MC app submits a delayed request
    // and cancels it (-E_CANCELED), and a TIMEOUT op (-E_TIMEDOUT), asserting the completion status.
    const broker_probe_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c",
        "examples/apps/broker_probe.mc", "BROKER-PROBE: PASS", "broker-probe",
    });
    broker_probe_test_cmd.step.dependOn(b.getInstallStep());
    const broker_probe_test_step = b.step("broker-probe-test", "Mock-broker cancellation/timeout: completions carry -E_CANCELED / -E_TIMEDOUT under QEMU");
    broker_probe_test_step.dependOn(&broker_probe_test_cmd.step);

    const llvm_broker_probe_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm",
        "examples/apps/broker_probe.mc", "BROKER-PROBE: PASS", "broker-probe",
    });
    llvm_broker_probe_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_broker_probe_test_step = b.step("llvm-broker-probe-test", "Mock-broker cancellation/timeout (LLVM) under QEMU");
    llvm_broker_probe_test_step.dependOn(&llvm_broker_probe_test_cmd.step);

    // Out-of-order delivery (review item 3): a pure-JS agent submits a slow (delay 5) then a fast
    // (delay 1) request; the broker delivers fast first, so the resolve order is "FS". Both backends.
    const qjs_broker_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_broker.js", "broker-agent: order=FS", "qjs-broker-agent" });
    qjs_broker_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_broker_agent_test_step = b.step("qjs-broker-agent-test", "A pure-JS agent proves out-of-order broker completion (Promise reorder) under QEMU");
    qjs_broker_agent_test_step.dependOn(&qjs_broker_agent_test_cmd.step);

    const llvm_qjs_broker_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_broker.js", "broker-agent: order=FS", "qjs-broker-agent" });
    llvm_qjs_broker_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_broker_agent_test_step = b.step("llvm-qjs-broker-agent-test", "A pure-JS agent proves out-of-order broker completion under QEMU (LLVM)");
    llvm_qjs_broker_agent_test_step.dependOn(&llvm_qjs_broker_agent_test_cmd.step);

    // Unknown completion id is fatal (review item 6): a pure-JS agent drives the spurious op, whose
    // completion carries a bogus id; the host must fail loudly ("host: unknown completion id").
    const qjs_spurious_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_spurious.js", "host: unknown completion id", "qjs-spurious-agent" });
    qjs_spurious_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_spurious_agent_test_step = b.step("qjs-spurious-agent-test", "An unknown completion id is a fatal host error under QEMU");
    qjs_spurious_agent_test_step.dependOn(&qjs_spurious_agent_test_cmd.step);

    const llvm_qjs_spurious_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_spurious.js", "host: unknown completion id", "qjs-spurious-agent" });
    llvm_qjs_spurious_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_spurious_agent_test_step = b.step("llvm-qjs-spurious-agent-test", "An unknown completion id is a fatal host error under QEMU (LLVM)");
    llvm_qjs_spurious_agent_test_step.dependOn(&llvm_qjs_spurious_agent_test_cmd.step);

    // QuickJS-agent Phase 2: a confined C app (examples/apps/compute.c) over the freestanding
    // libc (user/libc: malloc arena + mem/str) — the C-app + libc path QuickJS (also C) uses.
    const compute_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c",
        "examples/apps/compute.c", "compute-ok", "compute-app",
    });
    compute_app_test_cmd.step.dependOn(b.getInstallStep());
    const compute_app_test_step = b.step("compute-app-test", "QuickJS-agent Phase 2: a confined C app over the freestanding libc (malloc+string) runs in an isolated U-mode space under QEMU");
    compute_app_test_step.dependOn(&compute_app_test_cmd.step);

    const llvm_compute_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm",
        "examples/apps/compute.c", "compute-ok", "compute-app",
    });
    llvm_compute_app_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_compute_app_test_step = b.step("llvm-compute-app-test", "QuickJS-agent Phase 2 (LLVM kernel): a confined C app over the freestanding libc runs under QEMU");
    llvm_compute_app_test_step.dependOn(&llvm_compute_app_test_cmd.step);

    // QuickJS-agent Phase 3: a confined C app over the freestanding libm (user/libc/math —
    // the exact half: classification/rounding/fmod + hardware sqrt) on real doubles. Proves
    // hardware FP is enabled for the app (kernel sets mstatus.FS before enter_user) — the
    // prerequisite for JS numbers.
    const math_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c",
        "examples/apps/mathtest.c", "math-ok", "math-app",
    });
    math_app_test_cmd.step.dependOn(b.getInstallStep());
    const math_app_test_step = b.step("math-app-test", "QuickJS-agent Phase 3: a confined C app over the freestanding libm (exact functions + hardware sqrt, FP enabled) runs under QEMU");
    math_app_test_step.dependOn(&math_app_test_cmd.step);

    const llvm_math_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm",
        "examples/apps/mathtest.c", "math-ok", "math-app",
    });
    llvm_math_app_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_math_app_test_step = b.step("llvm-math-app-test", "QuickJS-agent Phase 3 (LLVM kernel): a confined C app over the freestanding libm runs under QEMU");
    llvm_math_app_test_step.dependOn(&llvm_math_app_test_cmd.step);

    // QuickJS-agent Phase 3 (complete): a confined C app over the vendored-openlibm
    // transcendentals (pow/exp/log/sin/cos/tan/atan2/cbrt/hypot) — the full double libm JS
    // Math needs, built freestanding into a cached archive and linked confined under FP.
    const trig_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "c",
        "examples/apps/transcendental.c", "trig-ok", "trig-app",
    });
    trig_app_test_cmd.step.dependOn(b.getInstallStep());
    const trig_app_test_step = b.step("trig-app-test", "QuickJS-agent Phase 3: a confined C app over the vendored openlibm transcendentals runs under QEMU");
    trig_app_test_step.dependOn(&trig_app_test_cmd.step);

    const llvm_trig_app_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/proc/app-run-test.sh", "zig-out/bin/mcc", "llvm",
        "examples/apps/transcendental.c", "trig-ok", "trig-app",
    });
    llvm_trig_app_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_trig_app_test_step = b.step("llvm-trig-app-test", "QuickJS-agent Phase 3 (LLVM kernel): a confined C app over the vendored openlibm transcendentals runs under QEMU");
    llvm_trig_app_test_step.dependOn(&llvm_trig_app_test_cmd.step);

    // QuickJS-agent Phase 4: MC C-ABI varargs (the `va.*` intrinsics). A variadic MC function
    // is driven from a C runtime under QEMU on both backends — the printf-family interop the
    // (all-MC) libc needs so QuickJS can call our snprintf/printf shims.
    const vararg_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "c" });
    vararg_test_cmd.step.dependOn(b.getInstallStep());
    const vararg_test_step = b.step("vararg-test", "QuickJS-agent Phase 4: a C-ABI variadic MC fn (va.start/va.arg/va.end) runs under QEMU");
    vararg_test_step.dependOn(&vararg_test_cmd.step);

    const llvm_vararg_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/vararg-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_vararg_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vararg_test_step = b.step("llvm-vararg-test", "QuickJS-agent Phase 4 (LLVM): a C-ABI variadic MC fn runs under QEMU");
    llvm_vararg_test_step.dependOn(&llvm_vararg_test_cmd.step);

    // QuickJS-agent Phase 4: the all-MC C-ABI allocator (user/libc/alloc.mc), reusing
    // kernel/core/heap.mc's free-list. Driven via malloc/free/calloc/realloc from a C runtime
    // under QEMU on both backends — the heap QuickJS allocates against.
    const qjs_alloc_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/alloc-test.sh", "zig-out/bin/mcc", "c" });
    qjs_alloc_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_alloc_test_step = b.step("qjs-alloc-test", "QuickJS-agent Phase 4: the all-MC C-ABI allocator (reusing heap.mc) runs under QEMU");
    qjs_alloc_test_step.dependOn(&qjs_alloc_test_cmd.step);

    const qjs_llvm_alloc_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/alloc-test.sh", "zig-out/bin/mcc", "llvm" });
    qjs_llvm_alloc_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_llvm_alloc_test_step = b.step("llvm-qjs-alloc-test", "QuickJS-agent Phase 4 (LLVM): the all-MC C-ABI allocator runs under QEMU");
    qjs_llvm_alloc_test_step.dependOn(&qjs_llvm_alloc_test_cmd.step);

    // QuickJS-agent Phase 4: the all-MC mem/string core (user/libc/cstr.mc) — memcpy/memset/
    // memmove/memcmp/strlen/strcmp/strncmp/strchr/memchr, driven from a C runtime under QEMU on
    // both backends. The freestanding bytes QuickJS leans on constantly.
    const cstr_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "c" });
    cstr_test_cmd.step.dependOn(b.getInstallStep());
    const cstr_test_step = b.step("cstr-test", "QuickJS-agent Phase 4: the all-MC mem/string core runs under QEMU");
    cstr_test_step.dependOn(&cstr_test_cmd.step);

    const llvm_cstr_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/cstr-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_cstr_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cstr_test_step = b.step("llvm-cstr-test", "QuickJS-agent Phase 4 (LLVM): the all-MC mem/string core runs under QEMU");
    llvm_cstr_test_step.dependOn(&llvm_cstr_test_cmd.step);

    // QuickJS-agent Phase 4: the all-MC ctype + integer parsing (user/libc/cnum.mc) — is*/to*,
    // abs, strtol/strtoul/strtoll/strtoull/atoi (with endptr, sign, 0x/0 prefixes, wraparound),
    // driven from a C runtime under QEMU on both backends.
    const cnum_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "c" });
    cnum_test_cmd.step.dependOn(b.getInstallStep());
    const cnum_test_step = b.step("cnum-test", "QuickJS-agent Phase 4: the all-MC ctype + integer parsing runs under QEMU");
    cnum_test_step.dependOn(&cnum_test_cmd.step);

    const llvm_cnum_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/cnum-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_cnum_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cnum_test_step = b.step("llvm-cnum-test", "QuickJS-agent Phase 4 (LLVM): the all-MC ctype + integer parsing runs under QEMU");
    llvm_cnum_test_step.dependOn(&llvm_cnum_test_cmd.step);

    // QuickJS-agent Phase 4: the all-MC printf family (user/libc/stdio.mc, built on the va.*
    // varargs intrinsics), compiled as part of the AGGREGATED libc (user/libc/libc.mc — the
    // single-unit artifact QuickJS links). snprintf/printf checked against expected strings from
    // a C runtime under QEMU on both backends.
    const stdio_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "c" });
    stdio_test_cmd.step.dependOn(b.getInstallStep());
    const stdio_test_step = b.step("stdio-test", "QuickJS-agent Phase 4: the all-MC printf family (aggregated libc) runs under QEMU");
    stdio_test_step.dependOn(&stdio_test_cmd.step);

    const llvm_stdio_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/stdio-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_stdio_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_stdio_test_step = b.step("llvm-stdio-test", "QuickJS-agent Phase 4 (LLVM): the all-MC printf family runs under QEMU");
    llvm_stdio_test_step.dependOn(&llvm_stdio_test_cmd.step);

    // QuickJS-agent Phase 4 KEYSTONE: build the vendored QuickJS engine freestanding against the
    // all-MC libc + openlibm, link the confined qjs_agent, and EVALUATE JavaScript under QEMU
    // (1 + 2*3 == 7). Both backends.
    const qjs_run_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-run-test.sh", "zig-out/bin/mcc", "c" });
    qjs_run_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_run_test_step = b.step("qjs-run-test", "QuickJS-agent Phase 4: build QuickJS freestanding against the all-MC libc and evaluate JS under QEMU");
    qjs_run_test_step.dependOn(&qjs_run_test_cmd.step);

    const llvm_qjs_run_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-run-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_qjs_run_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_run_test_step = b.step("llvm-qjs-run-test", "QuickJS-agent Phase 4 (LLVM): build QuickJS freestanding and evaluate JS under QEMU");
    llvm_qjs_run_test_step.dependOn(&llvm_qjs_run_test_cmd.step);

    // QuickJS-agent Phase 6: run QuickJS CONFINED — build the engine + all-MC libc into a U-mode
    // ELF, load it with the real elf_loader into an isolated Sv39 space (kernel UNMAPPED), and
    // evaluate JS in U-mode, reaching the kernel only via SYS_WRITE/SYS_EXIT. Both backends.
    const qjs_confined_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c" });
    qjs_confined_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_confined_test_step = b.step("qjs-confined-test", "QuickJS-agent Phase 6: evaluate JS in a CONFINED isolated U-mode Sv39 space under QEMU");
    qjs_confined_test_step.dependOn(&qjs_confined_test_cmd.step);

    const llvm_qjs_confined_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_qjs_confined_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_confined_test_step = b.step("llvm-qjs-confined-test", "QuickJS-agent Phase 6 (LLVM): evaluate JS confined in an isolated U-mode space under QEMU");
    llvm_qjs_confined_test_step.dependOn(&llvm_qjs_confined_test_cmd.step);

    // M3a (first half): the SAME confined QuickJS agent, but the KERNEL runs in S-mode under REAL
    // OpenSBI (no `-bios none`) instead of M-mode. The agent's space additionally maps the kernel
    // as a supervisor-only gigapage (satp is effective in S-mode) + the UART MMIO page; JS is
    // evaluated in U-mode, reaching the kernel only via SYS_WRITE/SYS_EXIT. Both backends.
    const qjs_smode_confined_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-confined-test.sh", "zig-out/bin/mcc", "c" });
    qjs_smode_confined_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_smode_confined_test_step = b.step("qjs-smode-confined-test", "M3a: evaluate JS in a CONFINED isolated U-mode Sv39 space under REAL OpenSBI (S-mode)");
    qjs_smode_confined_test_step.dependOn(&qjs_smode_confined_test_cmd.step);

    const llvm_qjs_smode_confined_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-confined-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_qjs_smode_confined_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_smode_confined_test_step = b.step("llvm-qjs-smode-confined-test", "M3a (LLVM): evaluate JS confined in an isolated U-mode space under REAL OpenSBI (S-mode)");
    llvm_qjs_smode_confined_test_step.dependOn(&llvm_qjs_smode_confined_test_cmd.step);

    // M3 (M3b): the PURE-JS AGENT under REAL OpenSBI (S-mode). The S-mode analogue of
    // qjs-agent-test: same fixed generic C host + embedded JS agent doing async host I/O over
    // SYS_SUBMIT/SYS_POLL with back-pressure, but the kernel runs in S-mode under the real OpenSBI
    // firmware (no `-bios none`) and the kernel is mapped supervisor-only (unreachable from U). The
    // async agent is purely polled (no interrupts), so M3a's S-mode syscall dispatch already serves
    // it. Default agent.js -> "agent: done".
    const qjs_smode_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c" });
    qjs_smode_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_smode_agent_test_step = b.step("qjs-smode-agent-test", "M3: run a PURE-JS agent (fixed generic C host) confined under REAL OpenSBI (S-mode), with async host I/O");
    qjs_smode_agent_test_step.dependOn(&qjs_smode_agent_test_cmd.step);

    const llvm_qjs_smode_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_qjs_smode_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_smode_agent_test_step = b.step("llvm-qjs-smode-agent-test", "M3 (LLVM): run a PURE-JS agent confined under REAL OpenSBI (S-mode), with async host I/O");
    llvm_qjs_smode_agent_test_step.dependOn(&llvm_qjs_smode_agent_test_cmd.step);

    // M3 (M3b) async-under-load: the same agent_async.js + EXPECT the M-mode qjs-async-agent-test
    // uses, now under REAL OpenSBI (S-mode). Proves Promise overlap + back-pressure/denial over
    // async host I/O while the kernel stays unmapped (supervisor-only) from the agent.
    const qjs_smode_async_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-smode-async-agent" });
    qjs_smode_async_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_smode_async_agent_test_step = b.step("qjs-smode-async-agent-test", "M3: a pure-JS agent proves overlap + back-pressure/denial over async host I/O under REAL OpenSBI (S-mode)");
    qjs_smode_async_agent_test_step.dependOn(&qjs_smode_async_agent_test_cmd.step);

    const llvm_qjs_smode_async_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-smode-async-agent" });
    llvm_qjs_smode_async_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_smode_async_agent_test_step = b.step("llvm-qjs-smode-async-agent-test", "M3 (LLVM): a pure-JS agent proves overlap + back-pressure/denial over async host I/O under REAL OpenSBI (S-mode)");
    llvm_qjs_smode_async_agent_test_step.dependOn(&llvm_qjs_smode_async_agent_test_cmd.step);

    // M5b.2: a pure-JS agent drives the REAL, capability-checked FS tool path through the SAME
    // async ABI (SYS_SUBMIT/SYS_POLL). The shared app_run_demo broker dispatches host_fs_write /
    // host_fs_read / host_fs_mkdir through agent_fs_call (allowlist -> budget -> path cap), so the
    // agent proves allow (read=hi), deny (mkdir not allowlisted -> structured error), and audit
    // end-to-end from JS. EXPECT "fs: ok" is reached only AFTER both the read-back and the denied
    // mkdir, so the gate fails if the real capability checks did not run.
    const qjs_realtool_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_fs.js", "fs: ok", "qjs-realtool" });
    qjs_realtool_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_realtool_test_step = b.step("qjs-realtool-test", "M5b.2: a pure-JS agent drives the REAL capability-checked FS tool path (allow/deny/audit) over the async ABI under REAL OpenSBI (S-mode)");
    qjs_realtool_test_step.dependOn(&qjs_realtool_test_cmd.step);

    const llvm_qjs_realtool_test_cmd = b.addSystemCommand(&.{ "bash", "tools/arch/qjs-smode-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_fs.js", "fs: ok", "qjs-realtool" });
    llvm_qjs_realtool_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_realtool_test_step = b.step("llvm-qjs-realtool-test", "M5b.2 (LLVM): a pure-JS agent drives the REAL capability-checked FS tool path over the async ABI under REAL OpenSBI (S-mode)");
    llvm_qjs_realtool_test_step.dependOn(&llvm_qjs_realtool_test_cmd.step);

    // QuickJS-agent Phase 7: the EVENT LOOP. The confined agent evaluates a Promise chain and
    // drains the job queue (JS_ExecutePendingJob) — the microtask concurrency real agents need
    // (Promise/async do nothing without it). ASYNC=42 after the loop runs. Both backends.
    const qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_async_agent.c", "ASYNC=42", "qjs-async" });
    qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_async_test_step = b.step("qjs-async-test", "QuickJS-agent Phase 7: the confined agent's Promise/microtask event loop under QEMU");
    qjs_async_test_step.dependOn(&qjs_async_test_cmd.step);

    const llvm_qjs_async_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_async_agent.c", "ASYNC=42", "qjs-async" });
    llvm_qjs_async_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_async_test_step = b.step("llvm-qjs-async-test", "QuickJS-agent Phase 7 (LLVM): the confined agent's event loop under QEMU");
    llvm_qjs_async_test_step.dependOn(&llvm_qjs_async_test_cmd.step);

    // QuickJS-agent Phase 7 (full): NON-BLOCKING kernel I/O resolving a JS Promise. The confined
    // agent's host_async() does SYS_SUBMIT and returns a pending Promise; the event loop SYS_POLLs
    // the completion and resolves it (the .then then runs). IO=42, never blocking. Both backends.
    const qjs_io_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_io_agent.c", "IO=42", "qjs-io" });
    qjs_io_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_io_test_step = b.step("qjs-io-test", "QuickJS-agent Phase 7: non-blocking SYS_SUBMIT/SYS_POLL I/O resolving a JS Promise under QEMU");
    qjs_io_test_step.dependOn(&qjs_io_test_cmd.step);

    const llvm_qjs_io_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_io_agent.c", "IO=42", "qjs-io" });
    llvm_qjs_io_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_io_test_step = b.step("llvm-qjs-io-test", "QuickJS-agent Phase 7 (LLVM): non-blocking I/O resolving a JS Promise under QEMU");
    llvm_qjs_io_test_step.dependOn(&llvm_qjs_io_test_cmd.step);

    // QuickJS-agent Phase 8: WORKERS (single-core v0). The confined agent spawns a worker (a
    // separate, isolated JS context), posts a message, runs its event loop, and gets a result
    // back — the spawn/mailbox substrate. WORKER=42 isolated=1 (the worker scope didn't leak).
    const qjs_worker_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "c", "examples/apps/qjs_worker_agent.c", "WORKER=42 isolated=1", "qjs-worker" });
    qjs_worker_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_worker_test_step = b.step("qjs-worker-test", "QuickJS-agent Phase 8: a confined agent spawns an isolated JS worker (message-passing) under QEMU");
    qjs_worker_test_step.dependOn(&qjs_worker_test_cmd.step);

    const llvm_qjs_worker_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-confined-test.sh", "zig-out/bin/mcc", "llvm", "examples/apps/qjs_worker_agent.c", "WORKER=42 isolated=1", "qjs-worker" });
    llvm_qjs_worker_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_worker_test_step = b.step("llvm-qjs-worker-test", "QuickJS-agent Phase 8 (LLVM): a confined agent spawns an isolated JS worker under QEMU");
    llvm_qjs_worker_test_step.dependOn(&llvm_qjs_worker_test_cmd.step);

    // The payoff: a PURE-JS agent (examples/agents/agent.js — async/await over host I/O, no C) run
    // by the FIXED generic host (qjs_host.c), confined under QEMU. You write the agent in JS only.
    const qjs_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c" });
    qjs_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_agent_test_step = b.step("qjs-agent-test", "Run a PURE-JS agent (fixed generic C host) confined under QEMU, with async host I/O");
    qjs_agent_test_step.dependOn(&qjs_agent_test_cmd.step);

    const llvm_qjs_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm" });
    llvm_qjs_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_agent_test_step = b.step("llvm-qjs-agent-test", "Run a PURE-JS agent confined under QEMU (LLVM)");
    llvm_qjs_agent_test_step.dependOn(&llvm_qjs_agent_test_cmd.step);

    // Async-I/O UNDER LOAD: a pure-JS agent (examples/agents/agent_async.js) that fires overlapping
    // host_async() requests (Promise.all) AND bursts past the kernel's 8-deep completion queue, so
    // the excess is denied (-E_AGAIN) and those Promises REJECT instead of hanging. Proves overlap,
    // independent completion, and back-pressure/denial — not just the single-request happy path.
    const qjs_async_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-async-agent" });
    qjs_async_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_async_agent_test_step = b.step("qjs-async-agent-test", "A pure-JS agent proves overlap + back-pressure/denial over async host I/O under QEMU");
    qjs_async_agent_test_step.dependOn(&qjs_async_agent_test_cmd.step);

    const llvm_qjs_async_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_async.js", "async-agent: backpressure ok=8 rejected=4", "qjs-async-agent" });
    llvm_qjs_async_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_async_agent_test_step = b.step("llvm-qjs-async-agent-test", "A pure-JS agent proves overlap + back-pressure/denial over async host I/O under QEMU (LLVM)");
    llvm_qjs_async_agent_test_step.dependOn(&llvm_qjs_async_agent_test_cmd.step);

    // Structured-error surfacing (review item 4): a pure-JS agent bursts past the in-flight quota
    // and asserts the rejections arrive as structured { code:-11, name:"EAGAIN", retryable:true }
    // objects, not bare integers. Proves the host surfaces tool-ABI errno into JS as structured
    // errors. Both backends.
    const qjs_quota_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "c", "examples/agents/agent_quota.js", "quota-agent: reject code=-11 name=EAGAIN retryable=true", "qjs-quota-agent" });
    qjs_quota_agent_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_quota_agent_test_step = b.step("qjs-quota-agent-test", "A pure-JS agent proves tool-ABI back-pressure surfaces as a structured JS error under QEMU");
    qjs_quota_agent_test_step.dependOn(&qjs_quota_agent_test_cmd.step);

    const llvm_qjs_quota_agent_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-agent-test.sh", "zig-out/bin/mcc", "llvm", "examples/agents/agent_quota.js", "quota-agent: reject code=-11 name=EAGAIN retryable=true", "qjs-quota-agent" });
    llvm_qjs_quota_agent_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_quota_agent_test_step = b.step("llvm-qjs-quota-agent-test", "A pure-JS agent proves tool-ABI back-pressure surfaces as a structured JS error under QEMU (LLVM)");
    llvm_qjs_quota_agent_test_step.dependOn(&llvm_qjs_quota_agent_test_cmd.step);

    // The host ITSELF in MC (examples/apps/qjs_host.mc): MC drives the QuickJS C API directly —
    // JSValue (the 16-byte struct) by value, JS_Eval/JS_GetPropertyStr/JS_ToInt32 from MC —
    // evaluating 6*7=42 confined. Proves the host need not be C either. Both backends.
    const qjs_mc_host_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-mc-host-test.sh", "zig-out/bin/mcc", "c", "", "6*7 -> 42", "qjs-mc-host" });
    qjs_mc_host_test_cmd.step.dependOn(b.getInstallStep());
    const qjs_mc_host_test_step = b.step("qjs-mc-host-test", "An MC host (not C) drives QuickJS and evaluates JS, confined under QEMU");
    qjs_mc_host_test_step.dependOn(&qjs_mc_host_test_cmd.step);

    const llvm_qjs_mc_host_test_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/qjs-mc-host-test.sh", "zig-out/bin/mcc", "llvm", "", "6*7 -> 42", "qjs-mc-host" });
    llvm_qjs_mc_host_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qjs_mc_host_test_step = b.step("llvm-qjs-mc-host-test", "An MC host drives QuickJS, confined under QEMU (LLVM)");
    llvm_qjs_mc_host_test_step.dependOn(&llvm_qjs_mc_host_test_cmd.step);

    const agent_confined_tool_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-confined-tool-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agent_confined_tool_test_cmd.step.dependOn(b.getInstallStep());
    const agent_confined_tool_test_step = b.step("agent-confined-tool-test", "Step 0 + M1: a confined U-mode agent drives the capability tool front door via syscalls; /workspace allowed, /etc denied under QEMU");
    agent_confined_tool_test_step.dependOn(&agent_confined_tool_test_cmd.step);

    const llvm_agent_confined_tool_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-confined-tool-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agent_confined_tool_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agent_confined_tool_test_step = b.step("llvm-agent-confined-tool-test", "Step 0 + M1 (LLVM): a confined U-mode agent drives the capability tool front door; /workspace allowed, /etc denied under QEMU");
    llvm_agent_confined_tool_test_step.dependOn(&llvm_agent_confined_tool_test_cmd.step);

    const driver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/driver-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    driver_test_cmd.step.dependOn(b.getInstallStep());
    const driver_test_step = b.step("driver-test", "Run the char-device driver framework (vtable dispatch) under QEMU");
    driver_test_step.dependOn(&driver_test_cmd.step);

    const llvm_driver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/driver-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_driver_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_driver_test_step = b.step("llvm-driver-test", "Run LLVM-lowered char-device driver framework under QEMU");
    llvm_driver_test_step.dependOn(&llvm_driver_test_cmd.step);

    const fs_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fs_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const fs_syscall_test_step = b.step("fs-syscall-test", "Run U-mode file syscalls (open/write/read/close) over the VFS under QEMU");
    fs_syscall_test_step.dependOn(&fs_syscall_test_cmd.step);

    const llvm_fs_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fs_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fs_syscall_test_step = b.step("llvm-fs-syscall-test", "Run LLVM-lowered U-mode file syscalls over the VFS under QEMU");
    llvm_fs_syscall_test_step.dependOn(&llvm_fs_syscall_test_cmd.step);

    const socket_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/socket-syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    socket_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const socket_syscall_test_step = b.step("socket-syscall-test", "Run U-mode recvfrom over the UDP socket layer under QEMU");
    socket_syscall_test_step.dependOn(&socket_syscall_test_cmd.step);

    const llvm_socket_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/socket-syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_socket_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_socket_syscall_test_step = b.step("llvm-socket-syscall-test", "Run LLVM-lowered U-mode recvfrom over the UDP socket layer under QEMU");
    llvm_socket_syscall_test_step.dependOn(&llvm_socket_syscall_test_cmd.step);

    const exec_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/exec-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    exec_test_cmd.step.dependOn(b.getInstallStep());
    const exec_test_step = b.step("exec-test", "Run sys_exec: a U-mode program loads + runs another ELF under QEMU");
    exec_test_step.dependOn(&exec_test_cmd.step);

    const llvm_exec_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/exec-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_exec_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_exec_test_step = b.step("llvm-exec-test", "Run LLVM-lowered sys_exec under QEMU");
    llvm_exec_test_step.dependOn(&llvm_exec_test_cmd.step);

    const paging_activate_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-activate-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    paging_activate_test_cmd.step.dependOn(b.getInstallStep());
    const paging_activate_test_step = b.step("paging-activate-test", "Activate Sv39 satp in S-mode and read a translation-only VA under QEMU");
    paging_activate_test_step.dependOn(&paging_activate_test_cmd.step);

    const llvm_paging_activate_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-activate-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_paging_activate_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_paging_activate_test_step = b.step("llvm-paging-activate-test", "Run LLVM-lowered Sv39 activation under QEMU");
    llvm_paging_activate_test_step.dependOn(&llvm_paging_activate_test_cmd.step);

    const kmain_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/kmain-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kmain_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_test_step = b.step("kmain-test", "Boot one integrated kernel image (heap+console+log+VFS+scheduler) under QEMU");
    kmain_test_step.dependOn(&kmain_test_cmd.step);

    const llvm_kmain_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/kmain-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_kmain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kmain_test_step = b.step("llvm-kmain-test", "Boot one LLVM-lowered integrated kernel image under QEMU");
    llvm_kmain_test_step.dependOn(&llvm_kmain_test_cmd.step);

    const agentos_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agentos-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agentos_test_cmd.step.dependOn(b.getInstallStep());
    const agentos_test_step = b.step("agentos-test", "Boot the agent-OS governance keystone (OOM-kill + reclaim) under QEMU");
    agentos_test_step.dependOn(&agentos_test_cmd.step);

    const llvm_agentos_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agentos-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agentos_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agentos_test_step = b.step("llvm-agentos-test", "Boot the LLVM-lowered agent-OS governance keystone under QEMU");
    llvm_agentos_test_step.dependOn(&llvm_agentos_test_cmd.step);

    const fault_isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/fault-isolation-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fault_isolation_test_cmd.step.dependOn(b.getInstallStep());
    const fault_isolation_test_step = b.step("fault-isolation-test", "Boot the F1 fault-isolation keystone (a real agent trap is contained: faulting agent killed+reclaimed, kernel+others survive) under QEMU");
    fault_isolation_test_step.dependOn(&fault_isolation_test_cmd.step);

    const llvm_fault_isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/fault-isolation-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fault_isolation_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fault_isolation_test_step = b.step("llvm-fault-isolation-test", "Boot the LLVM-lowered F1 fault-isolation keystone under QEMU");
    llvm_fault_isolation_test_step.dependOn(&llvm_fault_isolation_test_cmd.step);

    const agent_e2e_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-e2e-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agent_e2e_test_cmd.step.dependOn(b.getInstallStep());
    const agent_e2e_test_step = b.step("agent-e2e-test", "Boot the end-to-end sandboxed-agent showcase (capability-checked/budgeted/audited tool calls) under QEMU");
    agent_e2e_test_step.dependOn(&agent_e2e_test_cmd.step);

    const llvm_agent_e2e_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-e2e-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agent_e2e_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agent_e2e_test_step = b.step("llvm-agent-e2e-test", "Boot the LLVM-lowered end-to-end sandboxed-agent showcase under QEMU");
    llvm_agent_e2e_test_step.dependOn(&llvm_agent_e2e_test_cmd.step);

    const agent_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-net-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agent_net_test_cmd.step.dependOn(b.getInstallStep());
    const agent_net_test_step = b.step("agent-net-test", "Boot the agent-OS network-model showcase (brokered/egress-checked/budgeted/audited network calls) under QEMU");
    agent_net_test_step.dependOn(&agent_net_test_cmd.step);

    const llvm_agent_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-net-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agent_net_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agent_net_test_step = b.step("llvm-agent-net-test", "Boot the LLVM-lowered agent-OS network-model showcase under QEMU");
    llvm_agent_net_test_step.dependOn(&llvm_agent_net_test_cmd.step);

    const agent_net_real_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-net-real-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    agent_net_real_test_cmd.step.dependOn(b.getInstallStep());
    const agent_net_real_test_step = b.step("agent-net-real-test", "Boot the agent-OS network model with the REAL tcp_socket transport: a sandboxed agent makes a genuinely brokered (egress-checked/budgeted/audited) network call to a live server under QEMU");
    agent_net_real_test_step.dependOn(&agent_net_real_test_cmd.step);

    const llvm_agent_net_real_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/agent-net-real-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_agent_net_real_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_agent_net_real_test_step = b.step("llvm-agent-net-real-test", "Boot the LLVM-lowered agent-OS real-transport brokered network call under QEMU");
    llvm_agent_net_real_test_step.dependOn(&llvm_agent_net_real_test_cmd.step);

    const kmain_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/kmain-net-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kmain_net_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_net_test_step = b.step("kmain-net-test", "Boot the integrated kernel + network in one image under QEMU");
    kmain_net_test_step.dependOn(&kmain_net_test_cmd.step);

    const llvm_kmain_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/kmain-net-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_kmain_net_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kmain_net_test_step = b.step("llvm-kmain-net-test", "Boot the LLVM-lowered integrated kernel + network image under QEMU");
    llvm_kmain_net_test_step.dependOn(&llvm_kmain_net_test_cmd.step);

    const vm_switch_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vm-switch-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vm_switch_test_cmd.step.dependOn(b.getInstallStep());
    const vm_switch_test_step = b.step("vm-switch-test", "Switch satp between two address spaces under QEMU (per-process VM)");
    vm_switch_test_step.dependOn(&vm_switch_test_cmd.step);

    const llvm_vm_switch_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vm-switch-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vm_switch_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vm_switch_test_step = b.step("llvm-vm-switch-test", "Run LLVM-lowered satp switching between two address spaces under QEMU");
    llvm_vm_switch_test_step.dependOn(&llvm_vm_switch_test_cmd.step);

    const vmspace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmspace-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vmspace_test_cmd.step.dependOn(b.getInstallStep());
    const vmspace_test_step = b.step("vmspace-test", "Per-process page tables: switch satp by process slot under QEMU");
    vmspace_test_step.dependOn(&vmspace_test_cmd.step);

    const llvm_vmspace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmspace-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vmspace_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vmspace_test_step = b.step("llvm-vmspace-test", "Run LLVM-lowered per-process page tables under QEMU");
    llvm_vmspace_test_step.dependOn(&llvm_vmspace_test_cmd.step);

    const vmctx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmctx-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vmctx_test_cmd.step.dependOn(b.getInstallStep());
    const vmctx_test_step = b.step("vmctx-test", "Context switch that swaps satp per thread under QEMU");
    vmctx_test_step.dependOn(&vmctx_test_cmd.step);

    const llvm_vmctx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmctx-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vmctx_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vmctx_test_step = b.step("llvm-vmctx-test", "Run LLVM-lowered context switching with satp swaps under QEMU");
    llvm_vmctx_test_step.dependOn(&llvm_vmctx_test_cmd.step);

    const sched_vm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-vm-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    sched_vm_test_cmd.step.dependOn(b.getInstallStep());
    const sched_vm_test_step = b.step("sched-vm-test", "Scheduler switching per-process address spaces (proc_yield_vm) under QEMU");
    sched_vm_test_step.dependOn(&sched_vm_test_cmd.step);

    const llvm_sched_vm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-vm-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_sched_vm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sched_vm_test_step = b.step("llvm-sched-vm-test", "Run LLVM-lowered scheduler switching per-process address spaces under QEMU");
    llvm_sched_vm_test_step.dependOn(&llvm_sched_vm_test_cmd.step);

    const run_ushell_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/run-ushell.sh", "c" });
    run_ushell_cmd.step.dependOn(b.getInstallStep());
    run_ushell_cmd.stdio = .inherit; // connect the terminal so QEMU is interactive
    const run_ushell_step = b.step("run-ushell", "Build + boot the user-mode MC shell in QEMU (interactive)");
    run_ushell_step.dependOn(&run_ushell_cmd.step);

    const run_llvm_ushell_cmd = b.addSystemCommand(&.{ "bash", "tools/lang/run-ushell.sh", "llvm" });
    run_llvm_ushell_cmd.step.dependOn(b.getInstallStep());
    run_llvm_ushell_cmd.stdio = .inherit; // connect the terminal so QEMU is interactive
    const run_llvm_ushell_step = b.step("run-llvm-ushell", "Build + boot the LLVM-lowered user-mode MC shell in QEMU (interactive)");
    run_llvm_ushell_step.dependOn(&run_llvm_ushell_cmd.step);

    // Preflight: explicit toolchain check for the QEMU milestone gates (clang/ld.lld/llc/qemu +
    // riscv64 target). `zig build preflight`. Milestone gates with MC_REQUIRE_TOOLS=1/CI=1 fail
    // rather than skip when a tool is missing (tools/qemu/kernel-boot-lib.sh).
    const preflight_cmd = b.addSystemCommand(&.{ "bash", "tools/preflight.sh" });
    const preflight_step = b.step("preflight", "Check the toolchain (clang/ld.lld/llc/qemu + riscv64 target) the QEMU milestone gates need");
    preflight_step.dependOn(&preflight_cmd.step);

    const m0_step = b.step("m0", "Run M0 conformance gates");
    m0_step.dependOn(&abi_consistency_cmd.step);
    m0_step.dependOn(&arch_emit_cmd.step);
    m0_step.dependOn(&test_cmd.step);
    m0_step.dependOn(&c_test_cmd.step);
    m0_step.dependOn(&sweep_cmd.step);
    m0_step.dependOn(&sanitize_cmd.step);
    m0_step.dependOn(&diff_backend_cmd.step);
    m0_step.dependOn(&diff_fuzz_cmd.step);
    m0_step.dependOn(&move_fuzz_cmd.step);
    m0_step.dependOn(&fuzz_cmd.step);
    m0_step.dependOn(&fuzz_sanitize_cmd.step);
    m0_step.dependOn(&fuzz_trap_cmd.step);
    m0_step.dependOn(&fuzz_robust_cmd.step);
    m0_step.dependOn(&fuzz_failclosed_cmd.step);
    m0_step.dependOn(&fuzz_determinism_cmd.step);
    m0_step.dependOn(&fuzz_pipeline_cmd.step);
    // LLVM backend gates: IR assembly, object lowering, spec sweep, broad
    // c_emit fixture sweeps, and host link/run smoke tests.
    m0_step.dependOn(&llvm_test_cmd.step);
    m0_step.dependOn(&llvm_obj_test_cmd.step);
    m0_step.dependOn(&llvm_debug_test_cmd.step);
    m0_step.dependOn(&llvm_sweep_cmd.step);
    m0_step.dependOn(&llvm_spec_obj_sweep_cmd.step);
    m0_step.dependOn(&llvm_c_sweep_cmd.step);
    m0_step.dependOn(&llvm_opt_sweep_cmd.step);
    m0_step.dependOn(&llvm_c_obj_sweep_cmd.step);
    m0_step.dependOn(&llvm_cc_test_cmd.step);
    m0_step.dependOn(&llvm_move_test_cmd.step);
    m0_step.dependOn(&llvm_runtime_test_cmd.step);
    m0_step.dependOn(&llvm_std_test_cmd.step);
    m0_step.dependOn(&llvm_toolchain_test_cmd.step);
    m0_step.dependOn(&llvm_pkg_test_cmd.step);
    m0_step.dependOn(&llvm_demo_test_cmd.step);
    m0_step.dependOn(&llvm_kernel_test_cmd.step);
    m0_step.dependOn(&llvm_hosted_demo_test_cmd.step);
    m0_step.dependOn(&llvm_host_suite_test_cmd.step);
    m0_step.dependOn(&llvm_qemu_test_cmd.step);
    m0_step.dependOn(&llvm_trap_test_cmd.step);
    m0_step.dependOn(&llvm_thread_test_cmd.step);
    m0_step.dependOn(&llvm_sched_test_cmd.step);
    m0_step.dependOn(&llvm_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_user_test_cmd.step);
    m0_step.dependOn(&llvm_process_test_cmd.step);
    m0_step.dependOn(&llvm_elf_run_test_cmd.step);
    m0_step.dependOn(&llvm_uaccess_pt_test_cmd.step);
    m0_step.dependOn(&llvm_elf_loader_test_cmd.step);
    m0_step.dependOn(&llvm_uaccess_snapshot_test_cmd.step);
    m0_step.dependOn(&llvm_uaccess_taint_test_cmd.step);
    m0_step.dependOn(&llvm_agent_confined_test_cmd.step);
    m0_step.dependOn(&llvm_app_run_test_cmd.step);
    m0_step.dependOn(&llvm_compute_app_test_cmd.step);
    m0_step.dependOn(&math_app_test_cmd.step);
    m0_step.dependOn(&llvm_math_app_test_cmd.step);
    m0_step.dependOn(&trig_app_test_cmd.step);
    m0_step.dependOn(&llvm_trig_app_test_cmd.step);
    m0_step.dependOn(&vararg_test_cmd.step);
    m0_step.dependOn(&llvm_vararg_test_cmd.step);
    m0_step.dependOn(&qjs_alloc_test_cmd.step);
    m0_step.dependOn(&qjs_llvm_alloc_test_cmd.step);
    m0_step.dependOn(&cstr_test_cmd.step);
    m0_step.dependOn(&llvm_cstr_test_cmd.step);
    m0_step.dependOn(&cnum_test_cmd.step);
    m0_step.dependOn(&llvm_cnum_test_cmd.step);
    m0_step.dependOn(&stdio_test_cmd.step);
    m0_step.dependOn(&llvm_stdio_test_cmd.step);
    m0_step.dependOn(&qjs_run_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_run_test_cmd.step);
    m0_step.dependOn(&qjs_confined_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_confined_test_cmd.step);
    m0_step.dependOn(&qjs_smode_confined_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_smode_confined_test_cmd.step);
    m0_step.dependOn(&qjs_smode_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_smode_agent_test_cmd.step);
    m0_step.dependOn(&qjs_smode_async_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_smode_async_agent_test_cmd.step);
    m0_step.dependOn(&qjs_realtool_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_realtool_test_cmd.step);
    m0_step.dependOn(&qjs_async_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_async_test_cmd.step);
    m0_step.dependOn(&qjs_io_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_io_test_cmd.step);
    m0_step.dependOn(&qjs_worker_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_worker_test_cmd.step);
    m0_step.dependOn(&qjs_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_agent_test_cmd.step);
    m0_step.dependOn(&qjs_async_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_async_agent_test_cmd.step);
    m0_step.dependOn(&fault_probe_test_cmd.step);
    m0_step.dependOn(&llvm_fault_probe_test_cmd.step);
    m0_step.dependOn(&quota_probe_test_cmd.step);
    m0_step.dependOn(&llvm_quota_probe_test_cmd.step);
    m0_step.dependOn(&qjs_quota_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_quota_agent_test_cmd.step);
    m0_step.dependOn(&broker_probe_test_cmd.step);
    m0_step.dependOn(&llvm_broker_probe_test_cmd.step);
    m0_step.dependOn(&qjs_broker_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_broker_agent_test_cmd.step);
    m0_step.dependOn(&qjs_spurious_agent_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_spurious_agent_test_cmd.step);
    m0_step.dependOn(&qjs_mc_host_test_cmd.step);
    m0_step.dependOn(&llvm_qjs_mc_host_test_cmd.step);
    m0_step.dependOn(&llvm_agent_confined_tool_test_cmd.step);
    m0_step.dependOn(&llvm_fs_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_socket_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_exec_test_cmd.step);
    m0_step.dependOn(&llvm_kmain_test_cmd.step);
    m0_step.dependOn(&llvm_kmain_net_test_cmd.step);
    m0_step.dependOn(&llvm_vm_switch_test_cmd.step);
    m0_step.dependOn(&llvm_vmspace_test_cmd.step);
    m0_step.dependOn(&llvm_vmctx_test_cmd.step);
    m0_step.dependOn(&llvm_sched_vm_test_cmd.step);
    m0_step.dependOn(&llvm_timeout_test_cmd.step);
    m0_step.dependOn(&llvm_signal_test_cmd.step);
    m0_step.dependOn(&llvm_registry_test_cmd.step);
    m0_step.dependOn(&llvm_ipc2_test_cmd.step);
    m0_step.dependOn(&llvm_ipc_test_cmd.step);
    m0_step.dependOn(&llvm_usched_test_cmd.step);
    m0_step.dependOn(&llvm_heartbeat_test_cmd.step);
    m0_step.dependOn(&llvm_privilege_test_cmd.step);
    m0_step.dependOn(&llvm_cap_test_cmd.step);
    m0_step.dependOn(&llvm_restart_test_cmd.step);
    m0_step.dependOn(&llvm_contain_test_cmd.step);
    m0_step.dependOn(&llvm_cow_test_cmd.step);
    m0_step.dependOn(&llvm_isolation_test_cmd.step);
    m0_step.dependOn(&llvm_demand_test_cmd.step);
    m0_step.dependOn(&llvm_mmap_test_cmd.step);
    m0_step.dependOn(&llvm_paging_activate_test_cmd.step);
    m0_step.dependOn(&llvm_block_server_test_cmd.step);
    m0_step.dependOn(&llvm_fs_server_test_cmd.step);
    m0_step.dependOn(&llvm_net_server_test_cmd.step);
    m0_step.dependOn(&llvm_rtc_test_cmd.step);
    m0_step.dependOn(&llvm_userserver_test_cmd.step);
    m0_step.dependOn(&llvm_backtrace_test_cmd.step);
    m0_step.dependOn(&llvm_driver_test_cmd.step);
    m0_step.dependOn(&llvm_preempt_test_cmd.step);
    m0_step.dependOn(&llvm_page_test_cmd.step);
    m0_step.dependOn(&llvm_heap_test_cmd.step);
    m0_step.dependOn(&llvm_paging_test_cmd.step);
    m0_step.dependOn(&llvm_smp_test_cmd.step);
    m0_step.dependOn(&llvm_smp_lock_test_cmd.step);
    m0_step.dependOn(&llvm_ipi_test_cmd.step);
    m0_step.dependOn(&llvm_tcp_server_test_cmd.step);
    m0_step.dependOn(&llvm_virtio_test_cmd.step);
    m0_step.dependOn(&llvm_udp_net_test_cmd.step);
    m0_step.dependOn(&llvm_blk_test_cmd.step);
    m0_step.dependOn(&llvm_blk_smode_test_cmd.step);
    m0_step.dependOn(&llvm_smode_timer_test_cmd.step);
    m0_step.dependOn(&llvm_net_smode_test_cmd.step);
    m0_step.dependOn(&llvm_net_test_cmd.step);
    m0_step.dependOn(&llvm_nic_test_cmd.step);
    m0_step.dependOn(&llvm_e1000_test_cmd.step);
    m0_step.dependOn(&llvm_net_rx_live_test_cmd.step);
    m0_step.dependOn(&llvm_http_get_test_cmd.step);
    m0_step.dependOn(&llvm_dns_test_cmd.step);
    m0_step.dependOn(&llvm_https_get_test_cmd.step);

    // qemu-test is gated separately (needs a riscv cross-toolchain + QEMU); it
    // self-skips when those are absent, so it is safe to include in m0 too.
    m0_step.dependOn(&qemu_test_cmd.step);
    // cc-test exercises the mcc-cc toolchain driver (needs clang); self-skips
    // when clang is absent.
    m0_step.dependOn(&cc_test_cmd.step);
    // std-test compiles and runs std/core through the toolchain (needs clang).
    m0_step.dependOn(&std_test_cmd.step);
    // import-test exercises the module system end-to-end (needs clang).
    m0_step.dependOn(&import_test_cmd.step);
    // mono-test exercises comptime-parameter monomorphization (needs clang).
    m0_step.dependOn(&mono_test_cmd.step);
    // reflect-test validates the comptime layout model against the C ABI.
    m0_step.dependOn(&reflect_test_cmd.step);
    // abi-test validates advanced packed/overlay/MMIO layout against the C ABI + LLVM.
    m0_step.dependOn(&abi_test_cmd.step);
    // opt-test validates the fact-gated MIR optimizer (const-index bounds-check elision).
    m0_step.dependOn(&opt_test_cmd.step);
    // opt-equiv-test validates the elided bounds check is behavior-preserving (C vs LLVM).
    m0_step.dependOn(&opt_equiv_test_cmd.step);
    // safe-release-parity (D2.5): SAFE/RELEASE profiles agree functionally; RELEASE elides
    // only the optimizer-proven-dead checks SAFE keeps.
    m0_step.dependOn(&safe_release_parity_cmd.step);
    // comptime-fold-test validates comptime-only folds (byte strings, wrap/sat domains).
    m0_step.dependOn(&comptime_fold_test_cmd.step);
    // asm-targets-test validates per-architecture precise-asm register vocabularies.
    m0_step.dependOn(&asm_targets_test_cmd.step);
    // mcmap-test validates .mcmap stable IDs + object-symbol correlation on both backends.
    m0_step.dependOn(&mcmap_test_cmd.step);
    // fmt-test validates the formatter; mcc-symbols-test the symbol index; lsp-test the server;
    // editor-client-test the VS Code client.
    m0_step.dependOn(&fmt_test_cmd.step);
    m0_step.dependOn(&mcc_symbols_test_cmd.step);
    m0_step.dependOn(&lsp_test_cmd.step);
    m0_step.dependOn(&editor_client_test_cmd.step);
    // pkg-test exercises the mcc-pkg manifest build (needs clang).
    m0_step.dependOn(&pkg_test_cmd.step);
    // pkg-registry-test exercises registry publish/resolve/install + lockfile reproducibility.
    m0_step.dependOn(&pkg_registry_test_cmd.step);
    // stack-test exercises the generic std/stack collection (needs clang).
    m0_step.dependOn(&stack_test_cmd.step);
    // move-test exercises linear `move` handle erasure (needs clang).
    m0_step.dependOn(&move_test_cmd.step);
    // try-defer-test checks `defer` runs on the `?` error branch in both backends (needs clang).
    m0_step.dependOn(&try_defer_test_cmd.step);
    // sync-test exercises std/sync locks + linear guards (needs clang).
    m0_step.dependOn(&sync_test_cmd.step);
    // nic-test runs the demo NIC driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(&nic_test_cmd.step);
    // virtio-test runs the real virtio-net driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(&virtio_test_cmd.step);
    // blk-test runs the virtio-blk driver reading a sector under QEMU.
    m0_step.dependOn(&blk_test_cmd.step);
    // blk-smode-test revalidates the same virtio-blk driver under REAL OpenSBI in S-mode.
    m0_step.dependOn(&blk_smode_test_cmd.step);
    // smode-timer-test proves REAL S-mode timer-interrupt delivery under OpenSBI (SBI TIME ext).
    m0_step.dependOn(&smode_timer_test_cmd.step);
    m0_step.dependOn(&net_smode_test_cmd.step);
    // bearssl-smode-test revalidates the freestanding BearSSL SHA-256 + virtio-rng
    // entropy (the TLS crypto stack) under REAL OpenSBI in S-mode. Deterministic (no
    // network egress), so gated in m0.
    m0_step.dependOn(&bearssl_smode_test_cmd.step);
    // https-smode-test revalidates the in-kernel REAL BearSSL TLS 1.2 handshake +
    // HTTPS GET under REAL OpenSBI in S-mode. Deterministic — the TLS peer is a
    // LOCAL python server over slirp loopback (no internet egress) — so gated in m0
    // (mirrors the M-mode https-get-test, which is also in m0).
    m0_step.dependOn(&https_smode_test_cmd.step);
    // udp-net-test transmits a real UDP datagram over virtio-net (pcap-verified).
    m0_step.dependOn(&udp_net_test_cmd.step);
    // smp-test boots multiple harts synchronizing on a shared atomic under QEMU.
    m0_step.dependOn(&smp_test_cmd.step);
    // smp-lock-test contends a ticket spinlock across harts under QEMU.
    m0_step.dependOn(&smp_lock_test_cmd.step);
    // ipi-test sends a CLINT software interrupt between harts under QEMU.
    m0_step.dependOn(&ipi_test_cmd.step);
    // demo-test compile-checks the whole demo/ suite (needs clang).
    m0_step.dependOn(&demo_test_cmd.step);
    // net-test runs the kernel virtio-net RX/TX ARP exchange under QEMU.
    m0_step.dependOn(&net_test_cmd.step);
    // kernel-test compile-checks kernel/ for riscv64 + typestate rejects.
    m0_step.dependOn(&kernel_test_cmd.step);
    // page-test links + runs the physical frame allocator (needs clang).
    m0_step.dependOn(&page_test_cmd.step);
    // heap-test links + runs the kernel heap (needs clang).
    m0_step.dependOn(&heap_test_cmd.step);
    // redzone-test boots the D2.4 redzone+canary demo under QEMU (needs clang+qemu).
    m0_step.dependOn(&redzone_test_cmd.step);
    m0_step.dependOn(&llvm_redzone_test_cmd.step);
    // ksan-test (D2.1): access-time UAF/OOB detection via KASAN shadow memory.
    m0_step.dependOn(&ksan_test_cmd.step);
    m0_step.dependOn(&llvm_ksan_test_cmd.step);
    // kmsan-test (D2.2): access-time use-of-uninitialized-heap detection on the ksan shadow.
    m0_step.dependOn(&kmsan_test_cmd.step);
    m0_step.dependOn(&llvm_kmsan_test_cmd.step);
    // kcsan-test (D2.3): data-race detection via a watchpoint on the shadow (csan profile).
    m0_step.dependOn(&kcsan_test_cmd.step);
    // elf-test links + runs the ELF64 parser (needs clang).
    m0_step.dependOn(&elf_test_cmd.step);
    // ramfs-test links + runs the in-memory filesystem (needs clang).
    m0_step.dependOn(&ramfs_test_cmd.step);
    // vfs-test links + runs the fd-table VFS over ramfs (needs clang).
    m0_step.dependOn(&vfs_test_cmd.step);
    // blockfs-test links + runs the block-backed file store (needs clang).
    m0_step.dependOn(&blockfs_test_cmd.step);
    // udp-test links + runs the UDP build/parse + checksum (needs clang).
    m0_step.dependOn(&udp_test_cmd.step);
    m0_step.dependOn(&dns_host_test_cmd.step);
    // alloc-test links + runs the type-erased Allocator (needs clang).
    m0_step.dependOn(&alloc_test_cmd.step);
    m0_step.dependOn(&arc_test_cmd.step);
    m0_step.dependOn(&constgen_test_cmd.step);
    m0_step.dependOn(&ipc2_test_cmd.step);
    m0_step.dependOn(&registry_test_cmd.step);
    m0_step.dependOn(&signal_test_cmd.step);
    m0_step.dependOn(&privilege_test_cmd.step);
    m0_step.dependOn(&timeout_test_cmd.step);
    m0_step.dependOn(&heartbeat_test_cmd.step);
    m0_step.dependOn(&diskfs_test_cmd.step);
    m0_step.dependOn(&mmap_test_cmd.step);
    m0_step.dependOn(&demand_test_cmd.step);
    m0_step.dependOn(&isolation_test_cmd.step);
    m0_step.dependOn(&userserver_test_cmd.step);
    m0_step.dependOn(&usched_test_cmd.step);
    m0_step.dependOn(&cow_test_cmd.step);
    m0_step.dependOn(&pipe_test_cmd.step);
    m0_step.dependOn(&bcache_test_cmd.step);
    m0_step.dependOn(&perm_test_cmd.step);
    m0_step.dependOn(&pgroup_test_cmd.step);
    m0_step.dependOn(&tty_test_cmd.step);
    m0_step.dependOn(&time_test_cmd.step);
    m0_step.dependOn(&vqfault_test_cmd.step);
    m0_step.dependOn(&wrap_test_cmd.step);
    m0_step.dependOn(&args_test_cmd.step);
    m0_step.dependOn(&libc_test_cmd.step);
    // hosted-test runs the hosted-profile float I/O round-trip (needs clang+python3).
    m0_step.dependOn(&hosted_test_cmd.step);
    m0_step.dependOn(&shell_test_cmd.step);
    m0_step.dependOn(&shell2_test_cmd.step);
    m0_step.dependOn(&ushell_test_cmd.step);
    m0_step.dependOn(&llvm_ushell_test_cmd.step);
    m0_step.dependOn(&vfsmount_test_cmd.step);
    // treefs-test links + runs the hierarchical tree filesystem (needs clang); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&treefs_test_cmd.step);
    // fs-toolserver-test links + runs the capability-checked FS tool server (M1); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&fs_toolserver_test_cmd.step);
    // agent-fs-test links + runs the agent FS tool front door (M3 seed); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&agent_fs_test_cmd.step);
    // policy-test links + runs the policy-plane drainer (M5 seed); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&policy_test_cmd.step);
    // netcap-test links + runs capability-gated network egress (milestone #3); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&netcap_test_cmd.step);
    // agent-containment-test links + runs the capstone M6-shape integration; LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&agent_containment_test_cmd.step);
    // mcp-test links + runs the MCP-compatible facade (M4); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&mcp_test_cmd.step);
    // showcase-test links + runs the language feature showcase (emit-c); LLVM side via llvm-host-suite-test.
    m0_step.dependOn(&showcase_test_cmd.step);
    // mc-test runs the native #[test] facility (process-isolated) on both backends.
    m0_step.dependOn(&mc_test_cmd.step);
    m0_step.dependOn(&llvm_mc_test_cmd.step);
    // mod-visibility-test checks opt-in `pub` module boundaries on both backends.
    m0_step.dependOn(&mod_visibility_test_cmd.step);
    m0_step.dependOn(&llvm_mod_visibility_test_cmd.step);
    // sort-test exercises std/sort on both backends.
    m0_step.dependOn(&sort_test_cmd.step);
    m0_step.dependOn(&llvm_sort_test_cmd.step);
    m0_step.dependOn(&fdspace_test_cmd.step);
    m0_step.dependOn(&snapshot_test_cmd.step);
    m0_step.dependOn(&waitqueue_test_cmd.step);
    m0_step.dependOn(&service_test_cmd.step);
    m0_step.dependOn(&plugin_test_cmd.step);
    m0_step.dependOn(&endpoint_test_cmd.step);
    m0_step.dependOn(&supervisor_test_cmd.step);
    m0_step.dependOn(&registry2_test_cmd.step);
    m0_step.dependOn(&manifest_test_cmd.step);
    m0_step.dependOn(&scheduler_test_cmd.step);
    m0_step.dependOn(&info_test_cmd.step);
    m0_step.dependOn(&granttab_test_cmd.step);
    m0_step.dependOn(&x86_sched_test_cmd.step);
    m0_step.dependOn(&x86_qemu_test_cmd.step);
    m0_step.dependOn(&llvm_x86_sched_test_cmd.step);
    m0_step.dependOn(&llvm_x86_qemu_test_cmd.step);
    m0_step.dependOn(&x86_vm_test_cmd.step);
    m0_step.dependOn(&llvm_x86_vm_test_cmd.step);
    m0_step.dependOn(&x86_timer_test_cmd.step);
    m0_step.dependOn(&llvm_x86_timer_test_cmd.step);
    m0_step.dependOn(&x86_pci_test_cmd.step);
    m0_step.dependOn(&llvm_x86_pci_test_cmd.step);
    m0_step.dependOn(&x86_user_test_cmd.step);
    m0_step.dependOn(&llvm_x86_user_test_cmd.step);
    m0_step.dependOn(&x86_qjs_test_cmd.step);
    m0_step.dependOn(&llvm_x86_qjs_test_cmd.step);
    m0_step.dependOn(&x86_qjs_async_test_cmd.step);
    // NOTE: llvm_x86_qjs_async is intentionally NOT in m0. The C-x86 async agent and the
    // LLVM-x86 SYNC agent both pass; the LLVM-x86 ASYNC case faults inside QuickJS's Error-string
    // handling during the heavy back-pressure burst (a separate x86-LLVM-backend codegen issue —
    // the IDENTICAL MC broker logic passes under C-x86 and under LLVM-riscv). The build step
    // exists (llvm-x86-qjs-async-test) for tracking, but is not gated until that is root-caused.
    m0_step.dependOn(&slotmap_test_cmd.step);
    m0_step.dependOn(&mask_test_cmd.step);
    m0_step.dependOn(&rights_test_cmd.step);
    m0_step.dependOn(&mmio_test_cmd.step);
    m0_step.dependOn(&synclock_test_cmd.step);
    m0_step.dependOn(&ipc_result_test_cmd.step);
    m0_step.dependOn(&arp_cache_test_cmd.step);
    m0_step.dependOn(&tlb_shootdown_test_cmd.step);
    m0_step.dependOn(&mutex_test_cmd.step);
    m0_step.dependOn(&mailbox_test_cmd.step);
    m0_step.dependOn(&tryelse_test_cmd.step);
    m0_step.dependOn(&byteview_test_cmd.step);
    m0_step.dependOn(&scan_test_cmd.step);
    m0_step.dependOn(&posix_test_cmd.step);
    m0_step.dependOn(&userland_test_cmd.step);
    m0_step.dependOn(&smprq_test_cmd.step);
    m0_step.dependOn(&rtc_test_cmd.step);
    m0_step.dependOn(&contain_test_cmd.step);
    m0_step.dependOn(&tcp_server_test_cmd.step);
    m0_step.dependOn(&fdt_test_cmd.step);
    m0_step.dependOn(&fb_test_cmd.step);
    m0_step.dependOn(&dynlink_test_cmd.step);
    m0_step.dependOn(&aarch64_test_cmd.step);
    m0_step.dependOn(&llvm_aarch64_test_cmd.step);
    m0_step.dependOn(&arm_vm_test_cmd.step);
    m0_step.dependOn(&llvm_arm_vm_test_cmd.step);
    m0_step.dependOn(&arm_user_test_cmd.step);
    m0_step.dependOn(&llvm_arm_user_test_cmd.step);
    m0_step.dependOn(&arm_qjs_test_cmd.step);
    m0_step.dependOn(&arm_qjs_async_test_cmd.step);
    // NOTE: the LLVM-aarch64 qjs cases (llvm-arm-qjs-test / llvm-arm-qjs-async-test) are
    // intentionally NOT in m0. The C-aarch64 agent passes for BOTH the sync and the async agent
    // (full EL0 confinement + svc host I/O + USER-EXIT), and the IDENTICAL MC fixture/libc passes
    // under LLVM-riscv (llvm-qjs-agent-test) and the C-aarch64 path here. Under the LLVM backend on
    // aarch64, however, even a trivial JS eval faults INSIDE the QuickJS workload: a data-dependent
    // near-null deref (a software walk shows a data abort at lc_ld8 with FAR=0x1, reached via
    // strlen of a pointer QuickJS computed as 1). The agent's address space, GOT relocations, and
    // confinement all verify correct (the kernel maps EL1-only, the GOT entries hold the right
    // global addresses), so this is an LLVM-aarch64 codegen divergence in the heavy QuickJS+MC-libc
    // workload — the same FAMILY of backend gap as M7's ungated llvm-x86-qjs-async (there the C and
    // LLVM-riscv paths pass but LLVM-x86 faults in QuickJS's Error-string handling). The build steps
    // exist (llvm-arm-qjs-test / llvm-arm-qjs-async-test) for tracking, but are not gated until that
    // aarch64-LLVM-backend issue is root-caused.
    m0_step.dependOn(&liveupdate_test_cmd.step);
    m0_step.dependOn(&sbi_boot_test_cmd.step);
    m0_step.dependOn(&llvm_sbi_boot_test_cmd.step);
    m0_step.dependOn(&smode_user_test_cmd.step);
    m0_step.dependOn(&llvm_smode_user_test_cmd.step);
    m0_step.dependOn(&bootinfo_test_cmd.step);
    m0_step.dependOn(&llvm_bootinfo_test_cmd.step);
    m0_step.dependOn(&uart_driver_test_cmd.step);
    m0_step.dependOn(&llvm_uart_driver_test_cmd.step);
    m0_step.dependOn(&e1000_test_cmd.step);
    m0_step.dependOn(&grant_test_cmd.step);
    m0_step.dependOn(&ipc_test_cmd.step);
    m0_step.dependOn(&block_server_test_cmd.step);
    m0_step.dependOn(&fs_server_test_cmd.step);
    m0_step.dependOn(&net_server_test_cmd.step);
    m0_step.dependOn(&cap_test_cmd.step);
    m0_step.dependOn(&restart_test_cmd.step);
    m0_step.dependOn(&arc_pkt_test_cmd.step);
    m0_step.dependOn(&arena_test_cmd.step);
    m0_step.dependOn(&genref_test_cmd.step);
    m0_step.dependOn(&owned_test_cmd.step);
    m0_step.dependOn(&net_arena_test_cmd.step);
    m0_step.dependOn(&pool_test_cmd.step);
    // closure-test links + runs a bind() capturing closure (needs clang).
    m0_step.dependOn(&closure_test_cmd.step);
    // ring-test links + runs the generic in-place Ring<T> (needs clang).
    m0_step.dependOn(&ring_test_cmd.step);
    // trace-test links + runs the trace ring buffer (needs clang).
    m0_step.dependOn(&trace_test_cmd.step);
    // log-test links + runs the leveled tracepoint logger (needs clang).
    m0_step.dependOn(&log_test_cmd.step);
    // tcp-test links + runs the TCP build/parse + checksum (needs clang).
    m0_step.dependOn(&tcp_test_cmd.step);
    // tcp-conn-test links + runs the TCP connection state machine (needs clang).
    m0_step.dependOn(&tcp_conn_test_cmd.step);
    // tcp-window-test links + runs the TCP window/data-plane bookkeeping (needs clang).
    m0_step.dependOn(&tcp_window_test_cmd.step);
    // tcp-reasm-test links + runs TCP reassembly + go-back-N retransmit (needs clang).
    m0_step.dependOn(&tcp_reasm_test_cmd.step);
    // tcp-rtx-test links + runs the TCP retransmit timer (needs clang).
    m0_step.dependOn(&tcp_rtx_test_cmd.step);
    // symbols-test links + runs the symbol table / address symbolizer (needs clang).
    m0_step.dependOn(&symbols_test_cmd.step);
    // socket-test links + runs the UDP socket bind/deliver/recv layer (needs clang).
    m0_step.dependOn(&socket_test_cmd.step);
    // net-rx-test links + runs the RX demux path (frame -> socket_deliver) (needs clang).
    m0_step.dependOn(&net_rx_test_cmd.step);
    // net-fuzz-test fuzzes the RX parser with random frames (needs clang).
    m0_step.dependOn(&net_fuzz_test_cmd.step);
    // parser-fuzz-test (P1) fuzzes the DNS+TCP parsers with malformed/truncated bytes:
    // every parse is total over its finite buffer — no over-read, garbage rejected (clang).
    m0_step.dependOn(&parser_fuzz_test_cmd.step);
    // net-rx-live-test routes a real virtio-net RX frame through net_rx_deliver under QEMU.
    m0_step.dependOn(&net_rx_live_test_cmd.step);
    // http-get-test active-opens a real TCP connection and HTTP GETs a live server under QEMU.
    m0_step.dependOn(&http_get_test_cmd.step);
    // dns-test resolves a name via a real DNS A-query then HTTP GETs that host under QEMU.
    m0_step.dependOn(&dns_test_cmd.step);
    // https-get-test runs a REAL BearSSL TLS 1.2 handshake over the kernel TCP and
    // decrypts an HTTPS GET from a local python HTTPS server under QEMU (Phase 2 TLS).
    m0_step.dependOn(&https_get_test_cmd.step);
    // NB: google-https-test (REAL google.com:443) is intentionally NOT in m0 -- it is a
    // standalone best-effort check (PASS or honest SKIP), to avoid a flaky internet gate.
    // backtrace-test walks the frame-pointer chain + symbolizes under QEMU.
    m0_step.dependOn(&backtrace_test_cmd.step);
    // paging-test links + runs the Sv39 page-table map/translate (needs clang).
    m0_step.dependOn(&paging_test_cmd.step);
    // fnptr-test links + runs function-pointer dispatch (needs clang).
    m0_step.dependOn(&fnptr_test_cmd.step);
    // trap-test runs the typed-CPU trap/timer interrupt path under QEMU.
    m0_step.dependOn(&trap_test_cmd.step);
    // thread-test runs cooperative context switching under QEMU.
    m0_step.dependOn(&thread_test_cmd.step);
    // sched-test runs the round-robin scheduler under QEMU.
    m0_step.dependOn(&sched_test_cmd.step);
    // preempt-test runs the timer-driven preemptive scheduler under QEMU.
    m0_step.dependOn(&preempt_test_cmd.step);
    // syscall-test runs the ecall syscall dispatch skeleton under QEMU.
    m0_step.dependOn(&syscall_test_cmd.step);
    // user-test runs the M->U privilege drop + user-mode syscalls under QEMU.
    m0_step.dependOn(&user_test_cmd.step);
    // process-test runs process lifecycle (spawn/run/exit) under QEMU.
    m0_step.dependOn(&process_test_cmd.step);
    // elf-run-test loads an ELF64 and runs it in U-mode under QEMU.
    m0_step.dependOn(&elf_run_test_cmd.step);
    // The uaccess demos run under QEMU (they import riscv paging.mc, so they can't run on the host suite).
    m0_step.dependOn(&uaccess_pt_test_cmd.step);
    m0_step.dependOn(&elf_loader_test_cmd.step);
    m0_step.dependOn(&uaccess_snapshot_test_cmd.step);
    m0_step.dependOn(&uaccess_taint_test_cmd.step);
    // agent-confined-test (step 0): separate ELF into an isolated address space, run confined in U-mode.
    m0_step.dependOn(&agent_confined_test_cmd.step);
    m0_step.dependOn(&app_run_test_cmd.step);
    m0_step.dependOn(&compute_app_test_cmd.step);
    // agent-confined-tool-test (step 0 + M1): confined U-mode agent drives the capability front door.
    m0_step.dependOn(&agent_confined_tool_test_cmd.step);
    // driver-test runs the char-device driver framework (vtable dispatch) under QEMU.
    m0_step.dependOn(&driver_test_cmd.step);
    // fs-syscall-test runs U-mode file syscalls over the VFS under QEMU.
    m0_step.dependOn(&fs_syscall_test_cmd.step);
    // socket-syscall-test runs U-mode recvfrom over the UDP socket layer under QEMU.
    m0_step.dependOn(&socket_syscall_test_cmd.step);
    // exec-test runs sys_exec: a U-mode program loads + runs another ELF under QEMU.
    m0_step.dependOn(&exec_test_cmd.step);
    // paging-activate-test activates Sv39 satp in S-mode + reads a translated VA.
    m0_step.dependOn(&paging_activate_test_cmd.step);
    // kmain-test boots one integrated kernel image (heap+console+log+VFS+scheduler).
    m0_step.dependOn(&kmain_test_cmd.step);
    // agentos-test boots the agent-OS governance keystone (OOM-kill + reclaim) under QEMU.
    m0_step.dependOn(&agentos_test_cmd.step);
    m0_step.dependOn(&llvm_agentos_test_cmd.step);
    // fault-isolation-test boots the F1 keystone: a real agent trap is CONTAINED (faulting agent
    // killed+reclaimed via the death path, kernel + other agents survive) under QEMU.
    m0_step.dependOn(&fault_isolation_test_cmd.step);
    m0_step.dependOn(&llvm_fault_isolation_test_cmd.step);
    // agent-e2e-test boots the end-to-end sandboxed-agent showcase under QEMU.
    m0_step.dependOn(&agent_e2e_test_cmd.step);
    m0_step.dependOn(&llvm_agent_e2e_test_cmd.step);
    m0_step.dependOn(&agent_net_test_cmd.step);
    m0_step.dependOn(&llvm_agent_net_test_cmd.step);
    // agent-net-real-test boots the broker's REAL tcp_socket transport: a sandboxed agent makes a
    // genuinely brokered (egress-checked/budgeted/audited) network call to a live server under QEMU.
    m0_step.dependOn(&agent_net_real_test_cmd.step);
    m0_step.dependOn(&llvm_agent_net_real_test_cmd.step);
    // vm-switch-test switches satp between two address spaces (per-process VM).
    m0_step.dependOn(&vm_switch_test_cmd.step);
    // vmspace-test switches satp per process slot (per-process page tables).
    m0_step.dependOn(&vmspace_test_cmd.step);
    // vmctx-test: a context switch that swaps satp per thread (address space in the switch).
    m0_step.dependOn(&vmctx_test_cmd.step);
    // sched-vm-test: the scheduler switches per-process address spaces (proc_yield_vm).
    m0_step.dependOn(&sched_vm_test_cmd.step);
    // kmain-net-test boots the integrated kernel + network in one image.
    m0_step.dependOn(&kmain_net_test_cmd.step);

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
    fast_step.dependOn(&test_cmd.step);
    fast_step.dependOn(&c_test_cmd.step);
    fast_step.dependOn(&sweep_cmd.step);
    fast_step.dependOn(&diff_backend_cmd.step);
    fast_step.dependOn(&diff_fuzz_cmd.step);
    fast_step.dependOn(&move_fuzz_cmd.step);
    fast_step.dependOn(&fuzz_cmd.step);
    fast_step.dependOn(&fuzz_trap_cmd.step);
    fast_step.dependOn(&fuzz_robust_cmd.step);
    fast_step.dependOn(&fuzz_failclosed_cmd.step);
    fast_step.dependOn(&fuzz_determinism_cmd.step);
    fast_step.dependOn(&fuzz_pipeline_cmd.step);

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
    c0_step.dependOn(&test_cmd.step);
    c0_step.dependOn(&c_test_cmd.step);
    c0_step.dependOn(&sweep_cmd.step);
    c0_step.dependOn(&demo_test_cmd.step);

    const c1_step = b.step("c1", "Spec §L.2 MC-C1 kernel-profile gates: c0 + kernel suite (MMIO, DMA, move checking, address-space lowering)");
    c1_step.dependOn(c0_step);
    c1_step.dependOn(&kernel_test_cmd.step);
}
