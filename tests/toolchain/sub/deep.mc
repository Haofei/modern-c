// Imports `mathutil` via a *different* relative path than app.mc does
// (`../mathutil.mc` vs `mathutil.mc`); the loader must canonicalize and include
// it once (no duplicate `triple`).
import "../mathutil.mc";

export fn deep_fn(x: u32) -> u32 {
    return triple(x) + 100;
}
