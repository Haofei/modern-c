// Function pointers: `fn(P) -> R` value types. A function name used as a value is
// a function pointer; calling a fn-pointer value (a parameter, a struct field, or
// a local) lowers to a C indirect call through a generated typedef. This is the
// foundation for IRQ-handler tables, thread entry points, and device vtables.

fn add(a: u32, b: u32) -> u32 { return a + b; }
fn mul(a: u32, b: u32) -> u32 { return a * b; }

global default_op: fn(u32, u32) -> u32 = add;
global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };

// fn-pointer as a parameter (callback).
fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 {
    return op(x, y);
}

// fn-pointer as a struct field (vtable).
struct BinOp {
    combine: fn(u32, u32) -> u32,
}

global default_box: BinOp = .{ .combine = add };
global copied_box: BinOp = default_box;
global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };

fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 {
    return o.combine(x, y);
}

// fn-pointer with no parameters and a void return (thread-entry shape).
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

fn copied_global_box_call(x: u32, y: u32) -> u32 {
    return copied_box.combine(x, y);
}

fn global_box_array_call(x: u32, y: u32) -> u32 {
    return default_boxes[1].combine(x, y);
}

fn replace_global_box() -> void {
    default_boxes[0] = .{ .combine = mul };
}

fn replace_global_box_op() -> void {
    default_boxes[1].combine = add;
}

// 3+4 (callback) + 3*4 (vtable) = 19
export fn run() -> u32 {
    let viaCallback: u32 = apply(add, 3, 4);
    var op: BinOp = .{ .combine = mul };
    let viaVtable: u32 = dispatch(&op, 3, 4);
    return viaCallback + viaVtable;
}

// An array of function pointers (a dispatch / vtable table) gets a distinct
// generated typedef name per signature — regression for the typeSuffix mangling
// used by the syscall table.
struct Dispatch {
    table: [4]fn(u64, u64) -> u64,
}
fn invoke(d: *Dispatch, i: usize, a: u64, b: u64) -> u64 {
    let h: fn(u64, u64) -> u64 = d.table[i];
    return h(a, b);
}
