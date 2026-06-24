// std/vec — explicit fixed-lane float helpers for generated kernels.
//
// MC does not currently expose target SIMD vector types. This module gives code
// generators a stable, reviewable lane abstraction over fixed arrays; the C
// backend emits ordinary scalar lane operations, and a later optimizer/backend
// can recognize these helpers as vectorization candidates without changing
// source semantics.

import "std/addr.mc";

export fn f32x4_splat(x: f32) -> [4]f32 {
    var out: [4]f32 = uninit;
    out[0] = x;
    out[1] = x;
    out[2] = x;
    out[3] = x;
    return out;
}

export fn f32x4_load(base: PAddr) -> [4]f32 {
    var out: [4]f32 = uninit;
    unsafe {
        out[0] = raw.load<f32>(base);
        out[1] = raw.load<f32>(pa_offset(base, 4));
        out[2] = raw.load<f32>(pa_offset(base, 8));
        out[3] = raw.load<f32>(pa_offset(base, 12));
    }
    return out;
}

export fn f32x4_store(base: PAddr, values: [4]f32) -> void {
    unsafe {
        raw.store<f32>(base, values[0]);
        raw.store<f32>(pa_offset(base, 4), values[1]);
        raw.store<f32>(pa_offset(base, 8), values[2]);
        raw.store<f32>(pa_offset(base, 12), values[3]);
    }
}

export fn f32x4_add(a: [4]f32, b: [4]f32) -> [4]f32 {
    var out: [4]f32 = uninit;
    out[0] = a[0] + b[0];
    out[1] = a[1] + b[1];
    out[2] = a[2] + b[2];
    out[3] = a[3] + b[3];
    return out;
}

export fn f32x4_mul(a: [4]f32, b: [4]f32) -> [4]f32 {
    var out: [4]f32 = uninit;
    out[0] = a[0] * b[0];
    out[1] = a[1] * b[1];
    out[2] = a[2] * b[2];
    out[3] = a[3] * b[3];
    return out;
}

export fn f32x4_max(a: [4]f32, b: [4]f32) -> [4]f32 {
    var out: [4]f32 = uninit;
    if a[0] > b[0] { out[0] = a[0]; } else { out[0] = b[0]; }
    if a[1] > b[1] { out[1] = a[1]; } else { out[1] = b[1]; }
    if a[2] > b[2] { out[2] = a[2]; } else { out[2] = b[2]; }
    if a[3] > b[3] { out[3] = a[3]; } else { out[3] = b[3]; }
    return out;
}

export fn f32x4_sum(values: [4]f32) -> f32 {
    return (values[0] + values[1]) + (values[2] + values[3]);
}

export fn f32x4_to_bits(values: [4]f32) -> [4]u32 {
    var out: [4]u32 = uninit;
    out[0] = bitcast<u32>(values[0]);
    out[1] = bitcast<u32>(values[1]);
    out[2] = bitcast<u32>(values[2]);
    out[3] = bitcast<u32>(values[3]);
    return out;
}

export fn f32x4_from_bits(values: [4]u32) -> [4]f32 {
    var out: [4]f32 = uninit;
    out[0] = bitcast<f32>(values[0]);
    out[1] = bitcast<f32>(values[1]);
    out[2] = bitcast<f32>(values[2]);
    out[3] = bitcast<f32>(values[3]);
    return out;
}
