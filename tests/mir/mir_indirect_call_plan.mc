fn add(left: u32, right: u32) -> u32 { return left + right; }
fn mul(left: u32, right: u32) -> u32 { return left * right; }
global default_op: fn(u32, u32) -> u32 = add;
global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };
struct BinOp { combine: fn(u32, u32) -> u32 }
global default_box: BinOp = .{ .combine = add };
global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };
fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 { return op(x, y); }
fn global_op_call(x: u32, y: u32) -> u32 { return default_op(x, y); }
fn global_op_array_call(x: u32, y: u32) -> u32 { return default_ops[1](x, y); }
fn global_box_call(x: u32, y: u32) -> u32 { return default_box.combine(x, y); }
fn global_box_array_call(x: u32, y: u32) -> u32 { return default_boxes[1].combine(x, y); }
fn local_fn_pointer_call(x: u32, y: u32) -> u32 {
    let op: fn(u32, u32) -> u32 = mul;
    return op(x, y);
}
