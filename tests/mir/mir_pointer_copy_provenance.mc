global shared_counter: u32 = 0;

fn touch() {}

fn pointer_local_copy_fact() {
    let p: *mut u32 = &shared_counter;
    let q: *mut u32 = p;
    #[unsafe_contract(noalias)]
    {
        let noalias_q: *mut u32 = compiler.assume_noalias_unchecked(p, 4);
    }
    var r: *mut u32 = &shared_counter;
    r = p;
}

fn pointer_local_copy_fail_closed() {
    var local: u32 = 1;
    let lp: *mut u32 = &local;
    let local_copy: *mut u32 = lp;
    var p: *mut u32 = &shared_counter;
    p = p;
    let self_invalidated_copy: *mut u32 = p;
    let gp: *mut u32 = &shared_counter;
    touch();
    let call_invalidated_copy: *mut u32 = gp;
}
