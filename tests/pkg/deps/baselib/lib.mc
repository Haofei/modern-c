// Transitive package dependency: mathlib imports this helper, and mcc-pkg
// resolves/version-checks baselib through mathlib's manifest.
export const fn square(x: u32) -> u32 {
    return x * x;
}
