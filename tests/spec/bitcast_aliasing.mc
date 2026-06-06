// SPEC: section=15,I.9
// SPEC: milestone=bitcast-aliasing
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_CALL_ARG_COUNT,E_BITCAST_TYPE,bitcast-lowering

fn bitcast_u32_from_i32(x: i32) -> u32 {
    return bitcast<u32>(x);
}

fn bitcast_i32_from_u32(x: u32) -> i32 {
    return bitcast<i32>(x);
}

fn reject_bitcast_missing_type(x: u32) -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return bitcast(x);
}

fn reject_bitcast_missing_value() -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return bitcast<u32>();
}

fn reject_bitcast_array_target(x: u32) -> void {
    // EXPECT_ERROR: E_BITCAST_TYPE
    bitcast<[4]u8>(x);
}
