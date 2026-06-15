// Consumer of the registry dependency `mathlib`. After `mcc-registry install`, the resolved
// version is vendored under mc_packages/, so this relative import resolves.
import "mc_packages/mathlib/mathlib.mc";

export fn app_main() -> u32 {
    return mathlib_value() + 1;
}
