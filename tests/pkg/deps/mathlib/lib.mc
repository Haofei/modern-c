// mathlib dependency: a pure exported utility used by the demo package.
import "../baselib/lib.mc";

export const fn cube(x: u32) -> u32 {
    return square(x) * x;
}
