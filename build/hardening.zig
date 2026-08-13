const std = @import("std");
const h = @import("helpers.zig");

// Opt-in static audits (unsafe boundary / capability mint / coverage),
// the ASan/UBSan sanitize pass, and the checks=all/checks=elide-proven parity gate.
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "sanitize", "Run the host-driver corpus under ASan + UBSan over the emitted C", &.{ "bash", "tools/toolchain/sanitize-test.sh", "zig-out/bin/mcc" });

    // V3.2: function-level lowering-coverage report. The script instruments the split
    // backend files, builds an instrumented mcc itself, and restores the sources on
    // exit — so it deliberately does NOT depend on the normal install step.
    _ = h.addScriptTestOpts(ctx, "lowering-coverage", "Report and ratchet which split lower_c*/lower_llvm* functions the differential corpus never exercises (V3.2)", &.{ "bash", "tools/toolchain/lowering-coverage.sh", "--check" }, .{ .install = false });

    // Function-level parser/sema/monomorphize/async coverage. Like lowering coverage,
    // this builds an instrumented compiler in a temporary checkout and compares the
    // uncovered function count against a checked-in ratchet.
    _ = h.addScriptTestOpts(ctx, "compiler-coverage", "Report and ratchet parser/sema/monomorphize/async compiler frontend function coverage", &.{ "bash", "tools/toolchain/compiler-coverage.sh", "--check" }, .{ .install = false });

    // The source-level security audits (unsafe boundary / capability mint) are
    // now one parameterized tool, tools/toolchain/mc-audit.sh, invoked with `--mode`. Pure
    // source scans (no mcc dependency), so they do not depend on the install step.

    // S0.2: source-level audit of the unsafe boundary.
    _ = h.addScriptTestOpts(ctx, "unsafe-audit", "Audit the MC unsafe boundary: flag gated unsafe ops outside an unsafe/unsafe_contract region and inventory the audited sites in kernel/ + std/ (S0.2)", &.{ "bash", "tools/toolchain/mc-audit.sh", "--mode", "unsafe" }, .{ .install = false });

    // Source-level audit of capability mint authority.
    _ = h.addScriptTestOpts(ctx, "capability-mint-audit", "Audit capability authority roots: flag direct cap_mint/rcap_mint calls outside approved capability/rights roots", &.{ "bash", "tools/toolchain/mc-audit.sh", "--mode", "capability-mint" }, .{ .install = false });

    // D2.5: explicit checks=all vs checks=elide-proven build-safety profile (`--checks=all|elide-proven`).
    // Asserts the two profiles agree functionally and that checks=elide-proven elides exactly the
    // checks=all keeps (the optimizer-proven-dead ones).
    _ = h.addScriptTest(ctx, "checks-elision-parity", "D2.5: checks=all and checks=elide-proven agree functionally; checks=elide-proven elides only proven-dead checks", &.{ "bash", "tools/toolchain/checks-elision-parity.sh", "zig-out/bin/mcc" });

}
