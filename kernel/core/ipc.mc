// kernel/core/ipc — the microkernel's message type. Kernel-mediated IPC is the
// backbone of the MINIX-style design: user-mode servers (drivers, FS, net) never call
// each other directly; they exchange fixed-size messages through the kernel. A fixed
// layout keeps the trusted path tiny and the protocol checkable (the `tag` selects a
// request type; servers switch on it exhaustively). The send/receive primitives live
// in process.mc because they drive the scheduler (block/wake on rendezvous).

struct Message {
    from: u32, // sender pid — stamped by the kernel on delivery (unforgeable)
    tag: u32,  // request/reply opcode the receiver switches on
    a0: u64,
    a1: u64,
    a2: u64,
}

// An empty message (a convenient zero value for `var reply: Message = message_zero();`).
export fn message_zero() -> Message {
    return .{ .from = 0, .tag = 0, .a0 = 0, .a1 = 0, .a2 = 0 };
}
