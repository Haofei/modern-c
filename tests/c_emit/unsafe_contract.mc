fn checked_inside_contract() -> u32 {
    var x: u32 = 1;
    #[unsafe_contract(no_overflow)]
    {
        x = x + 1;
    }
    return x;
}

fn unchecked_add_inside_contract(a: u32, b: u32) -> u32 {
    var x: u32 = 0;
    #[unsafe_contract(no_overflow)]
    {
        x = unchecked.add(a, b);
    }
    return x;
}

extern fn next_value() -> u32;
extern fn consume_value(value: u32) -> void;

fn unchecked_add_return_order() -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        return unchecked.add(next_value(), next_value());
    }
    return 0;
}

fn unchecked_add_local_order() -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        let value: u32 = unchecked.add(next_value(), next_value());
        return value;
    }
    return 0;
}

fn unchecked_add_assignment_order() -> u32 {
    var value: u32 = 0;
    #[unsafe_contract(no_overflow)]
    {
        value = unchecked.add(next_value(), next_value());
    }
    return value;
}

fn unchecked_add_arg_order() -> void {
    #[unsafe_contract(no_overflow)]
    {
        consume_value(unchecked.add(next_value(), next_value()));
    }
}
