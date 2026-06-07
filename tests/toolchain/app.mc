// Exercises the `import` module system, including diamond imports: both this
// file and sub/deep.mc import `mathutil` (via different relative paths), so the
// loader must include it exactly once. Also pulls in the standard library.
import "mathutil.mc";
import "sub/deep.mc";
import "../../std/core.mc";

export fn app_main(x: u32) -> u32 {
    // triple from mathutil (shared), deep_fn from sub/deep, clamp_u32 from std.
    return clamp_u32(triple(x) + deep_fn(x), 0, 1000);
}
