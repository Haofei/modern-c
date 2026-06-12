extern fn consume_u32(value: u32) -> void;

fn bitcast_return(x: i32) -> u32 {
    return bitcast<u32>(x);
}

fn bitcast_typed_local(x: u32) -> i32 {
    let y: i32 = bitcast<i32>(x);
    return y;
}

fn bitcast_inferred_local(x: i32) -> u32 {
    let y = bitcast<u32>(x);
    return y;
}

fn bitcast_assignment(x: i32) -> u32 {
    var y: u32 = 0;
    y = bitcast<u32>(x);
    return y;
}

fn bitcast_call_arg(x: i32) -> void {
    consume_u32(bitcast<u32>(x));
}

fn bitcast_float_to_bits(x: f32) -> u32 {
    return bitcast<u32>(x);
}

fn bitcast_bits_to_float(x: u32) -> f32 {
    return bitcast<f32>(x);
}
