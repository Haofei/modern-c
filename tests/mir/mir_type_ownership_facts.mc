struct Plain { id: u32 }
move struct Ticket { id: u32 }
struct Wrapper { ticket: Ticket }
linear struct Token { id: u32 }
#[experimental_ownership]
region struct Node { id: u32 }
#[experimental_ownership]
view struct SliceView { len: usize }
#[experimental_ownership]
thread_move move struct WorkerTicket { id: u32 }
#[drop]
fn close_ticket(ticket: *mut Ticket) -> void {
    ticket.id = 0;
}
#[drop]
fn close_wrapper(wrapper: *mut Wrapper) -> void {
    wrapper.ticket.id = 0;
}
