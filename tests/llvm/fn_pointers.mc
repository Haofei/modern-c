fn add(a: u32, b: u32) -> u32 {
    return a + b;
}

fn mul(a: u32, b: u32) -> u32 {
    return a * b;
}

global default_op: fn(u32, u32) -> u32 = add;
global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };

fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 {
    return op(x, y);
}

struct BinOp {
    combine: fn(u32, u32) -> u32,
}

global default_box: BinOp = .{ .combine = add };
global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };

fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 {
    return o.combine(x, y);
}

fn tick() -> void {}

fn entry_of() -> fn() -> void {
    return tick;
}

fn global_op_call(x: u32, y: u32) -> u32 {
    return default_op(x, y);
}

fn global_op_array_call(x: u32, y: u32) -> u32 {
    return default_ops[1](x, y);
}

fn global_op_array_get() -> fn(u32, u32) -> u32 {
    return default_ops[0];
}

fn global_box_call(x: u32, y: u32) -> u32 {
    return default_box.combine(x, y);
}

fn global_box_array_call(x: u32, y: u32) -> u32 {
    return default_boxes[1].combine(x, y);
}

fn local_fn_pointer_call(x: u32, y: u32) -> u32 {
    let op: fn(u32, u32) -> u32 = mul;
    return op(x, y);
}

fn local_vtable_call(x: u32, y: u32) -> u32 {
    var op: BinOp = .{ .combine = mul };
    return dispatch(&op, x, y);
}
