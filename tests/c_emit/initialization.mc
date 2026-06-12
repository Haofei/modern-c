fn initialized_local() -> u32 {
    var x: u32 = 1;
    return x;
}

fn explicit_uninit_scalar(value: u32) -> u32 {
    var x: u32 = uninit;
    x = value;
    return x;
}

fn explicit_grouped_uninit_scalar(value: u32) -> u32 {
    var x: u32 = (uninit);
    x = value;
    return x;
}

fn explicit_uninit_array() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    return buf[0];
}

fn read_materialized_uninit_scalar() -> u32 {
    var x: u32 = uninit;
    return x;
}

fn read_materialized_uninit_byte() -> u8 {
    var buf: [4]u8 = uninit;
    return buf[0];
}
