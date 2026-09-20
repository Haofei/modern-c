global shared_counter: u32 = 0;
struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }

fn touch() {}

fn invalidations(index: usize) {
    var local: u32 = 1;
    var p: *mut u32 = &shared_counter;
    p = p;
    p = &shared_counter;
    touch();
    var q: *mut u32 = &shared_counter;
    let qp: *mut *mut u32 = &q;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    ptrs[index] = &local;
    var holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
    holder.ptr = &local;
    holder.ptr = q;
    holder.ptrs[index] = &local;
    holder.ptr = &shared_counter;
    touch();
}

fn absent_computed_pointer(index: usize) {
    var local: u32 = 2;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let p: *mut u32 = ptrs[index];
}
