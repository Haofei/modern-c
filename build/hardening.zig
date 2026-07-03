const std = @import("std");
const h = @import("helpers.zig");

// Opt-in static audits (unsafe boundary / double-fetch / taint / lowering-coverage),
// the ASan/UBSan sanitize pass, the SAFE/RELEASE parity gate, and the KASAN/KMSAN/KCSAN
// + redzone sanitizer-profile QEMU boots.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "sanitize", "Run the host-driver corpus under ASan + UBSan over the emitted C", &.{ "bash", "tools/toolchain/sanitize-test.sh", "zig-out/bin/mcc" });

    // V3.2: function-level lowering-coverage report. The script instruments the split
    // backend files, builds an instrumented mcc itself, and restores the sources on
    // exit — so it deliberately does NOT depend on the normal install step.
    _ = h.addScriptTestOpts(ctx, "lowering-coverage", "Report and ratchet which split lower_c*/lower_llvm* functions the differential corpus never exercises (V3.2)", &.{ "bash", "tools/toolchain/lowering-coverage.sh", "--check" }, .{ .install = false });

    // The three source-level security audits (unsafe boundary / double-fetch / taint) are
    // now one parameterized tool, tools/toolchain/mc-audit.sh, invoked with `--mode`. Pure
    // source scans (no mcc dependency), so they do not depend on the install step.

    // S0.2: source-level audit of the unsafe boundary.
    _ = h.addScriptTestOpts(ctx, "unsafe-audit", "Audit the MC unsafe boundary: flag gated unsafe ops outside an unsafe/unsafe_contract region and inventory the audited sites in kernel/ + std/ (S0.2)", &.{ "bash", "tools/toolchain/mc-audit.sh", "--mode", "unsafe" }, .{ .install = false });

    // U2: source-level audit of double-fetch / TOCTOU on user memory.
    _ = h.addScriptTestOpts(ctx, "double-fetch-audit", "Audit user-memory double-fetch / TOCTOU: flag a function that copies the same UserPtr in more than once (U2)", &.{ "bash", "tools/toolchain/mc-audit.sh", "--mode", "double-fetch" }, .{ .install = false });

    // U3: source-level audit of untrusted (user-derived) lengths/indices.
    _ = h.addScriptTestOpts(ctx, "taint-audit", "Audit user-derived (tainted) values: flag a value from copy_from_user/fetch_user used as a length/index/loop-bound without passing checked_len/checked_index/validate_bound (U3)", &.{ "bash", "tools/toolchain/mc-audit.sh", "--mode", "taint" }, .{ .install = false });

    // D2.5: explicit SAFE vs RELEASE build-safety profile (`--checks=all|elide-proven`).
    // Asserts the two profiles agree functionally and that RELEASE elides exactly the
    // checks SAFE keeps (the optimizer-proven-dead ones).
    _ = h.addScriptTest(ctx, "safe-release-parity", "D2.5: SAFE (--checks=all) and RELEASE (--checks=elide-proven) agree functionally; RELEASE elides only proven-dead checks", &.{ "bash", "tools/toolchain/safe-release-parity.sh", "zig-out/bin/mcc" });

    // D2.4: heap-redzone + stack-canary runtime detection under QEMU.
    _ = h.addScriptTest(ctx, "redzone-test", "Boot the redzone+canary demo under QEMU (detects heap overflow + smashed canary)", &.{ "bash", "tools/mem/redzone-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-redzone-test", "Boot the LLVM-lowered redzone+canary demo under QEMU", &.{ "bash", "tools/mem/redzone-test.sh", "zig-out/bin/mcc", "llvm" });

    // ksan-test boots the D2.1 KASAN demo under QEMU: access-time use-after-free + OOB
    // detection via shadow memory (the `--checks=ksan` profile), strictly finer than D2.4.
    _ = h.addScriptTest(ctx, "ksan-test", "Boot the KASAN demo under QEMU (access-time use-after-free + OOB detection)", &.{ "bash", "tools/mem/ksan-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-ksan-test", "Boot the LLVM-lowered KASAN demo under QEMU", &.{ "bash", "tools/mem/ksan-test.sh", "zig-out/bin/mcc", "llvm" });

    // kmsan-test boots the D2.2 KMSAN demo under QEMU: access-time use-of-uninitialized-heap
    // detection on the ksan shadow (the `--checks=msan` profile) — a read of never-written
    // heap memory traps, the dynamic complement to S0.1's static check.
    _ = h.addScriptTest(ctx, "kmsan-test", "Boot the KMSAN demo under QEMU (access-time uninitialized-heap-use detection)", &.{ "bash", "tools/mem/kmsan-test.sh", "zig-out/bin/mcc", "c" });

    _ = h.addScriptTest(ctx, "llvm-kmsan-test", "Boot the LLVM-lowered KMSAN demo under QEMU", &.{ "bash", "tools/mem/kmsan-test.sh", "zig-out/bin/mcc", "llvm" });

    // kcsan-test boots the D2.3 KCSAN demo under QEMU: data-race detection via a watchpoint
    // on the shadow (the `--checks=csan` profile). An unsynchronized boot-thread access
    // racing a REAL preempting timer-IRQ access is caught by the watchpoint conflict check
    // (CSAN-DETECTED); a properly-synchronized (mc_race_*) access is clean (CSAN-OK). C
    // backend only — the LLVM backend does not implement the csan watchpoint instrumentation.
    _ = h.addScriptTest(ctx, "kcsan-test", "Boot the KCSAN demo under QEMU (data-race detection on the watchpoint)", &.{ "bash", "tools/mem/kcsan-test.sh", "zig-out/bin/mcc", "c" });
}
