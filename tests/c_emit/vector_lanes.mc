// Generated-kernel vector lane helpers: fixed f32x4 arrays should type-check and
// lower to scalar C lane operations today.

import "std/addr.mc";
import "std/vec.mc";

fn add_mul_sum(a: [4]f32, b: [4]f32) -> f32 {
    let s = f32x4_splat(2.0);
    let added = f32x4_add(a, b);
    let scaled = f32x4_mul(added, s);
    return f32x4_sum(scaled);
}

fn max_bits(a: [4]f32, b: [4]f32) -> u32 {
    let m = f32x4_max(a, b);
    let bits = f32x4_to_bits(m);
    return bits[0];
}

fn load_add_store(dst: PAddr, a: PAddr, b: PAddr) -> void {
    let av = f32x4_load(a);
    let bv = f32x4_load(b);
    let out = f32x4_add(av, bv);
    f32x4_store(dst, out);
}

fn from_bits_sum(bits: [4]u32) -> f32 {
    let values = f32x4_from_bits(bits);
    return f32x4_sum(values);
}
