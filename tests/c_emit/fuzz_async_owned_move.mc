// Owned resources may move into an async frame. Scoped borrows still cannot cross
// `await` (covered by tests/c_emit/bad/async_scoped_borrow_*); this fixture locks
// the positive side: the frame owns the value and consumes it after suspension.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

struct ValFut { deadline: u64, val: u32 }
fn mk_val(deadline: u64, val: u32) -> ValFut {
    return .{ .deadline = deadline, .val = val };
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> u32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

#[trivial_drop]
move struct Ticket { id: u32 }

struct TicketBox { ticket: Ticket }

fn consume_ticket(t: Ticket) -> u32 {
    return t.id;
}

fn consume_box(box: TicketBox) -> u32 {
    let id: u32 = consume_ticket(move box.ticket);
    unsafe { forget_unchecked(box); }
    return id;
}

async fn use_owned_ticket(ticket: Ticket, deadline: u64) -> u32 {
    let waited: u32 = await mk_val(deadline, 5);
    return consume_ticket(move ticket) + waited;
}

async fn use_owned_box(box: TicketBox, deadline: u64) -> u32 {
    let waited: u32 = await mk_val(deadline, 4);
    return consume_box(move box) + waited;
}

export fn async_owned_move_run() -> u32 {
    g_clock = 0;
    var fut: use_owned_ticket__Fut = use_owned_ticket(.{ .id = 37 }, 1);
    run_to_completion(&fut, tick_idle);
    let result: u32 = use_owned_ticket__Fut_take_result(&fut);
    unsafe { forget_unchecked(fut); }
    var box_fut: use_owned_box__Fut = use_owned_box(.{ .ticket = .{ .id = 38 } }, 1);
    run_to_completion(&box_fut, tick_idle);
    let box_result: u32 = use_owned_box__Fut_take_result(&box_fut);
    unsafe { forget_unchecked(box_fut); }
    if result == 42 && box_result == 42 { return 1; }
    return 0;
}
