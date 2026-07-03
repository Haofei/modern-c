const std = @import("std");
const h = @import("helpers.zig");

// Spec / C / LLVM IR + object emit sweeps and the cross-backend differential gates.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "c-test", "Emit-C compile-check the pass corpus and diagnostic-check the bad/ reject corpus", &.{ "bash", "tools/toolchain/check-generated-c.sh", "zig-out/bin/mcc", "tests/c_emit/*.mc", "zig-out/c-test", "tests/c_emit/bad/*.mc" });

    _ = h.addScriptTest(ctx, "llvm-test", "Emit LLVM IR for the initial backend slice and validate it with llvm-as", &.{ "bash", "tools/toolchain/llvm-test.sh", "zig-out/bin/mcc", "zig-out/llvm-test" });

    _ = h.addScriptTest(ctx, "llvm-obj-test", "Compile LLVM backend fixtures to object files with llc", &.{ "bash", "tools/toolchain/llvm-obj-test.sh", "zig-out/bin/mcc", "zig-out/llvm-obj-test" });

    _ = h.addScriptTest(ctx, "llvm-debug-test", "Verify LLVM object DWARF source and line mappings", &.{ "bash", "tools/toolchain/llvm-debug-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "sweep", "Emit C for every valid spec-corpus function and compile-check it with clang", &.{ "python3", "tools/toolchain/spec-emit-sweep.py", "zig-out/bin/mcc", "tests/spec" });

    // Contract lint: fast, tool-free static check that every fixture's declared
    // contract (reject EXPECT: lines, sweep OUT_OF_SCOPE entries, host-tests.tsv rows)
    // is well-formed — see docs/test-architecture.md. Keeps the fixture-semantics
    // invariant from rotting back in. No mcc/clang/QEMU, so it joins the inner loop.
    _ = h.addScriptTestOpts(ctx, "test-lint", "Lint fixture contracts (reject EXPECT lines, sweep OUT_OF_SCOPE, host-tests.tsv)", &.{ "python3", "tools/test/contract-lint.py", "." }, .{ .install = false });

    _ = h.addScriptTest(ctx, "bad-diagnostics-test", "Check golden first-line diagnostics for bad/ reject fixtures", &.{ "python3", "tools/toolchain/bad-diagnostics-test.py", "--check", "--mcc", "zig-out/bin/mcc" });
    _ = h.addScriptTest(ctx, "install-layout-test", "Validate --std-dir/MC_PATH installed std import fallback without relaxing explicit import sandboxing", &.{ "bash", "tools/toolchain/install-layout-test.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "diff-backend", "Run each host fixture through both backends and assert C and LLVM agree", &.{ "bash", "tools/toolchain/diff-backend.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "diff-fuzz", "Generate random MC programs and assert the C and LLVM backends agree on each", &.{ "bash", "tools/toolchain/diff-fuzz.sh", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "llvm-sweep", "Emit LLVM IR for every in-scope valid spec-corpus fixture and validate it with llvm-as", &.{ "python3", "tools/toolchain/spec-llvm-sweep.py", "zig-out/bin/mcc", "tests/spec" });

    _ = h.addScriptTest(ctx, "llvm-spec-obj-sweep", "Compile every in-scope valid spec-corpus fixture to an LLVM object with llc", &.{ "python3", "tools/toolchain/spec-llvm-obj-sweep.py", "zig-out/bin/mcc", "tests/spec", "zig-out/llvm-spec-obj-sweep" });

    _ = h.addScriptTest(ctx, "llvm-c-sweep", "Emit LLVM IR for every checked C-emission fixture and validate it with llvm-as", &.{ "python3", "tools/toolchain/llvm-c-emit-sweep.py", "zig-out/bin/mcc", "tests/c_emit/*.mc" });

    _ = h.addScriptTest(ctx, "llvm-opt-sweep", "Run LLVM verifier, O2 optimizer, and optimized object checks over broad emitted IR", &.{ "python3", "tools/toolchain/llvm-opt-sweep.py", "zig-out/bin/mcc", "tests/spec", "tests/c_emit/*.mc" });

    _ = h.addScriptTest(ctx, "llvm-c-obj-sweep", "Compile every checked C-emission fixture to an LLVM object with llc", &.{ "python3", "tools/toolchain/llvm-c-obj-sweep.py", "zig-out/bin/mcc", "tests/c_emit/*.mc", "zig-out/llvm-c-obj-sweep" });
}
