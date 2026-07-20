// std/vec — explicit fixed-lane float helpers for generated kernels.
//
// MC does not currently expose target SIMD vector types. This module gives code
// generators a stable, reviewable lane abstraction over fixed arrays; the C
// backend emits ordinary scalar lane operations, and a later optimizer/backend
// can recognize these helpers as vectorization candidates without changing
// source semantics.

import "std/addr.mc";

#[mc_abi]
export fn f32x4_splat(x: f32) -> [4]f32 {
    return .{ x, x, x, x };
}

#[mc_abi]
export fn f32x4_load(base: PAddr) -> [4]f32 {
    unsafe {
        return .{
            raw.load<f32>(base),
            raw.load<f32>(pa_offset(base, 4)),
            raw.load<f32>(pa_offset(base, 8)),
            raw.load<f32>(pa_offset(base, 12)),
        };
    }
}

#[mc_abi]
export fn f32x4_store(base: PAddr, values: [4]f32) -> void {
    unsafe {
        raw.store<f32>(base, values[0]);
        raw.store<f32>(pa_offset(base, 4), values[1]);
        raw.store<f32>(pa_offset(base, 8), values[2]);
        raw.store<f32>(pa_offset(base, 12), values[3]);
    }
}

#[mc_abi]
export fn f32x4_add(a: [4]f32, b: [4]f32) -> [4]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

#[mc_abi]
export fn f32x4_mul(a: [4]f32, b: [4]f32) -> [4]f32 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3] };
}

fn f32_max_lane(a: f32, b: f32) -> f32 {
    if a > b { return a; }
    return b;
}

#[mc_abi]
export fn f32x4_max(a: [4]f32, b: [4]f32) -> [4]f32 {
    return .{
        f32_max_lane(a[0], b[0]),
        f32_max_lane(a[1], b[1]),
        f32_max_lane(a[2], b[2]),
        f32_max_lane(a[3], b[3]),
    };
}

#[mc_abi]
export fn f32x4_sum(values: [4]f32) -> f32 {
    return (values[0] + values[1]) + (values[2] + values[3]);
}

#[mc_abi]
export fn f32x4_to_bits(values: [4]f32) -> [4]u32 {
    return .{
        bitcast<u32>(values[0]),
        bitcast<u32>(values[1]),
        bitcast<u32>(values[2]),
        bitcast<u32>(values[3]),
    };
}

#[mc_abi]
export fn f32x4_from_bits(values: [4]u32) -> [4]f32 {
    return .{
        bitcast<f32>(values[0]),
        bitcast<f32>(values[1]),
        bitcast<f32>(values[2]),
        bitcast<f32>(values[3]),
    };
}
