// MC standard library — `mathf`: IEEE floating-point math intrinsics for f32/f64.
//
// `std/math` is integer-only (pure `const fn`s that fold at comptime). Real
// kernels — DSP, graphics, ML inference — also need transcendental float math:
// `exp2`, `log2`, `sin`, `cos`, `sqrt`. MC has no built-in for these, so this
// module makes the machine contract EXPLICIT: each one is an `extern "C"`
// binding to the platform math library (libm), exactly as the spec wants
// low-level contracts surfaced rather than assumed.
//
// LINKING: every symbol here is a standard C99 libm function, so a program
// that uses `mathf` must link `-lm`. The toolchain driver does this
// automatically under the hosted profile (`mcc-cc.sh --profile=hosted`);
// freestanding kernels that want these must supply their own libm-equivalent
// (e.g. a soft-float library) under the same C names.
//
// These are NOT `const fn`: libm calls are a runtime effect (rounding mode,
// errno on some libms), so they do not fold at comptime — by design, comptime
// code cannot perform runtime effects (§22). Float arithmetic is non-trapping
// (IEEE inf/NaN), so these never trap; an out-of-domain input yields NaN, the
// IEEE-defined result, never a silent wrong number.

// ----- f64 (C `double`) intrinsics: the libm names are unsuffixed -----

extern "C" fn sqrt(x: f64) -> f64;
extern "C" fn sin(x: f64) -> f64;
extern "C" fn cos(x: f64) -> f64;
extern "C" fn exp2(x: f64) -> f64;
extern "C" fn log2(x: f64) -> f64;

export fn sqrt_f64(x: f64) -> f64 { return sqrt(x); }
export fn sin_f64(x: f64) -> f64 { return sin(x); }
export fn cos_f64(x: f64) -> f64 { return cos(x); }
export fn exp2_f64(x: f64) -> f64 { return exp2(x); }
export fn log2_f64(x: f64) -> f64 { return log2(x); }

// ----- f32 (C `float`) intrinsics: the libm names take the `f` suffix -----

extern "C" fn sqrtf(x: f32) -> f32;
extern "C" fn sinf(x: f32) -> f32;
extern "C" fn cosf(x: f32) -> f32;
extern "C" fn exp2f(x: f32) -> f32;
extern "C" fn log2f(x: f32) -> f32;

export fn sqrt_f32(x: f32) -> f32 { return sqrtf(x); }
export fn sin_f32(x: f32) -> f32 { return sinf(x); }
export fn cos_f32(x: f32) -> f32 { return cosf(x); }
export fn exp2_f32(x: f32) -> f32 { return exp2f(x); }
export fn log2_f32(x: f32) -> f32 { return log2f(x); }
