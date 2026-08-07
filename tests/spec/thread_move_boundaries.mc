// SPEC: section=18.1,18.2
// SPEC: milestone=scoped-affine-ownership
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_THREAD_MOVE_RESOURCE,E_BORROW_THREAD_BOUNDARY

// Thread/task spawn boundaries are outside the safe ownership v0 proof.
// `thread_move` is only an experimental marker; transfer requires an
// unsafe/trusted wrapper rather than ordinary safe call admission.

#[trivial_drop]
move struct Ticket { id: u32 }

#[trivial_drop]
#[experimental_ownership]
thread_move move struct SendTicket { id: u32 }

struct Cell { value: u32 }

fn make_ticket() -> Ticket {
    return .{ .id = 1 };
}

fn make_send_ticket() -> SendTicket {
    return .{ .id = 2 };
}

fn thread_spawn(t: Ticket) -> void {
    unsafe { forget_unchecked(t); }
}

fn task_spawn(t: SendTicket) -> void {
    unsafe { forget_unchecked(t); }
}

fn proc_spawn(p: *Cell) -> void {}

fn spawn(p: *Ticket) -> void {}

fn reject_non_thread_move_transfer() -> void {
    thread_spawn(make_ticket()); // EXPECT_ERROR: E_THREAD_MOVE_RESOURCE
}

fn reject_thread_move_transfer() -> void {
    task_spawn(make_send_ticket()); // EXPECT_ERROR: E_THREAD_MOVE_RESOURCE
}

fn reject_explicit_borrow_transfer() -> void {
    let t: Ticket = make_ticket();
    spawn(borrow t); // EXPECT_ERROR: E_BORROW_THREAD_BOUNDARY
}

fn reject_local_address_transfer() -> void {
    var cell: Cell = .{ .value = 3 };
    proc_spawn(&cell); // EXPECT_ERROR: E_BORROW_THREAD_BOUNDARY
}
