// SPEC: section=18.1,22
// SPEC: milestone=scoped-affine-ownership
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RAW_RESOURCE_PAYLOAD,E_EXPLICIT_MOVE_REQUIRED

// A generic struct that stores `T` by value inherits `T`'s ownership class after
// substitution. A phantom type parameter does not.

#[trivial_drop]
move struct Ticket { id: u32 }

struct Box<T> { value: T }
struct Phantom<T> { id: usize }

fn reject_raw_ptr_box(addr: PAddr) -> void {
    unsafe {
        raw.ptr<Box<Ticket>>(addr); // EXPECT_ERROR: E_RAW_RESOURCE_PAYLOAD
    }
}

fn accept_raw_ptr_phantom(addr: PAddr) -> *mut Phantom<Ticket> {
    unsafe {
        return raw.ptr<Phantom<Ticket>>(addr);
    }
}

fn reject_struct_literal_implicit_move(ticket: Ticket) -> u32 {
    let b: Box<Ticket> = .{ .value = ticket }; // EXPECT_ERROR: E_EXPLICIT_MOVE_REQUIRED
    unsafe { forget_unchecked(b); }
    return 1;
}

fn accept_struct_literal_explicit_move(ticket: Ticket) -> u32 {
    let b: Box<Ticket> = .{ .value = move ticket };
    unsafe { forget_unchecked(b); }
    return 1;
}
