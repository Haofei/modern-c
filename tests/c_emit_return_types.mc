extern fn get_count() -> u32;

global shared_count: u32 = 0;

enum TrafficLight: u8 {
    red = 0,
    yellow = 1,
    green = 2,
}

open enum OpenTrafficLight: u8 {
    red = 0,
    yellow = 1,
    green = 2,
}

fn returns_u32() -> u32 {
    return 1;
}

fn accept_same_return(a: u32) -> u32 {
    return a;
}

fn accept_call_return_type() -> u32 {
    return returns_u32();
}

fn accept_extern_call_return_type() -> u32 {
    return get_count();
}

fn accept_global_return_type() -> u32 {
    return shared_count;
}

fn accept_context_integer_literal() -> u8 {
    return 255;
}

fn accept_exhaustive_switch_return(n: u32) -> u32 {
    switch n {
        0 => { return 0; },
        _ => { return 1; },
    }
}

fn accept_closed_enum_switch_return(light: TrafficLight) -> u32 {
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { return 2; },
    }
}

fn accept_open_enum_switch_with_wildcard(light: OpenTrafficLight) -> u32 {
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { return 2; },
        _ => { return 3; },
    }
}
