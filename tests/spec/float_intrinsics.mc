// SPEC: section=3,8.3
// SPEC: milestone=float-math-intrinsics
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION

// Float math intrinsics (exp2/log2/sin/cos/sqrt) are not language built-ins:
// they are EXPLICIT extern bindings to the platform math library (libm), for
// both f32 (the `f`-suffixed C names) and f64 (the unsuffixed names). This is
// the same surface std/mathf provides; here it is self-contained so the spec
// fixture needs no imports.

extern "C" fn sqrt(x: f64) -> f64;
extern "C" fn sin(x: f64) -> f64;
extern "C" fn cos(x: f64) -> f64;
extern "C" fn exp2(x: f64) -> f64;
extern "C" fn log2(x: f64) -> f64;

extern "C" fn sqrtf(x: f32) -> f32;
extern "C" fn sinf(x: f32) -> f32;
extern "C" fn cosf(x: f32) -> f32;
extern "C" fn exp2f(x: f32) -> f32;
extern "C" fn log2f(x: f32) -> f32;

// f64 intrinsics type-check and return f64.
fn norm_f64(x: f64, y: f64) -> f64 {
    return sqrt(x * x + y * y);
}

fn wave_f64(t: f64) -> f64 {
    return sin(t) + cos(t);
}

fn gain_f64(p: f64) -> f64 {
    return exp2(p) + log2(p);
}

// f32 intrinsics type-check and return f32 (distinct overloads, no mixing).
fn norm_f32(x: f32, y: f32) -> f32 {
    return sqrtf(x * x + y * y);
}

fn wave_f32(t: f32) -> f32 {
    return sinf(t) + cosf(t);
}

fn gain_f32(p: f32) -> f32 {
    return exp2f(p) + log2f(p);
}

// The intrinsics compose with IEEE float arithmetic and explicit casts.
fn db_to_linear(db: f32) -> f32 {
    return exp2f(db * 0.166096);
}

fn elementwise_step(a: f32, b: f32) -> f32 {
    return sqrtf(a) + b;
}

// f32 and f64 intrinsics do not implicitly mix: passing an f32 result where an
// f64 is expected is a compile error, not a silent widen.
fn reject_f32_into_f64_intrinsic(a: f32) -> f64 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return sqrt(a);
}
