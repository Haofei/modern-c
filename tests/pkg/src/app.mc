// Package entry module: imports a package-local module, a declared dependency
// (mathlib), and the standard library, then exports the package's public API.
import "util.mc";
import "../deps/mathlib/lib.mc";
import "../../../std/core.mc";

export fn demo_main(x: u32) -> u32 {
    // scale from util, cube from the mathlib dependency, clamp from std/core.
    return clamp_u32(scale(x) + cube(x), 0, 1000);
}
