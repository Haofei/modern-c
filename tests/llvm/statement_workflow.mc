extern fn consume_u32(value: u32) -> void;
extern fn combine(left: u32, right: u32) -> u32;

fn void_call(value: u32) -> void {
    consume_u32(value);
}

fn discard_value(left: u32, right: u32) -> void {
    combine(left, right);
}

fn scoped_block(value: u32) -> u32 {
    var out: u32 = value;
    {
        let inner: u32 = combine(value, 1);
        consume_u32(inner);
    }
    return out;
}

fn unsafe_block_call(value: u32) -> void {
    unsafe {
        consume_u32(value);
    }
}

fn contract_block_call(value: u32) -> void {
    #[unsafe_contract(no_overflow)]
    {
        consume_u32(value);
    }
}

fn assignment_workflow(value: u32) -> u32 {
    var out: u32 = value;
    out = combine(out, 1);
    return out;
}

fn contract_block_return(value: u32) -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        return value + 1;
    }
}
