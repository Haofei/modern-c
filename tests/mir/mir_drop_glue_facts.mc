move struct Ticket { id: u32 }
struct Wrapper { ticket: Ticket }
#[drop]
fn close_ticket(ticket: *mut Ticket) -> void {
    ticket.id = 0;
}
#[drop]
fn close_wrapper(wrapper: *mut Wrapper) -> void {
    wrapper.ticket.id = 0;
}
fn use_wrapper() -> u32 {
    var wrapper: Wrapper = .{ .ticket = .{ .id = 1 } };
    return wrapper.ticket.id;
}
