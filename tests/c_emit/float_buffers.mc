// Float raw memory I/O + libm intrinsics lower to C: `raw.load`/`raw.store` of
// f32/f64 (the cells a float-buffer kernel reads/writes) and the std/mathf
// intrinsics (bound to libm). Compiled with clang under `zig build c-test`.
import "std/addr.mc";
import "std/mathf.mc";

// raw.load/store<f32> and <f64> emit the float volatile-access helpers.
fn load_f32(a: PAddr) -> f32 {
    var v: f32 = 0.0;
    unsafe {
        v = raw.load<f32>(a);
    }
    return v;
}

fn store_f32(a: PAddr, v: f32) -> void {
    unsafe {
        raw.store<f32>(a, v);
    }
}

fn load_f64(a: PAddr) -> f64 {
    var v: f64 = 0.0;
    unsafe {
        v = raw.load<f64>(a);
    }
    return v;
}

fn store_f64(a: PAddr, v: f64) -> void {
    unsafe {
        raw.store<f64>(a, v);
    }
}

// The mathf intrinsics lower to libm calls (sqrtf/sinf/... and sqrt/sin/...).
fn kernel_f32(a: f32, b: f32) -> f32 {
    return sqrt_f32(a) + b;
}

fn kernel_f64(a: f64, b: f64) -> f64 {
    return exp2_f64(a) + log2_f64(b);
}

// An in-place elementwise pass over a raw f32 buffer: load, transform, store.
fn elementwise_inplace(base: PAddr, i: usize) -> void {
    let cell: PAddr = pa_offset(base, i * 4);
    var x: f32 = 0.0;
    unsafe {
        x = raw.load<f32>(cell);
        raw.store<f32>(cell, sqrt_f32(x));
    }
}
