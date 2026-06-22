// Reject fixture (S0.1 definite-init): a scalar `var x: T = uninit;` read before it is
// assigned on every control-flow path is a compile error, not emittable C. This is the
// negative twin of `initialization.mc`'s positive cases (which assign before reading, or
// read an array element — an aggregate obligation that is intentionally NOT flagged).
//
// EXPECT: E_USE_BEFORE_INIT
//
// Harness: tools/toolchain/check-generated-c.sh runs `mcc emit-c` on every file under
// tests/c_emit/bad/ and requires it to FAIL with the diagnostic this EXPECT line names —
// exactly the kernel/bad/ reject convention, applied to the C-emit definite-init check.

fn read_materialized_uninit_scalar() -> u32 {
    var x: u32 = uninit;
    return x;
}
