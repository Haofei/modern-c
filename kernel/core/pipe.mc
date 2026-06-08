// kernel/core/pipe — an in-kernel byte pipe (FIFO): a bounded ring buffer with
// write/read, the primitive behind POSIX pipes and FIFOs. Backpressure is explicit:
// a write to a full pipe fails, a read of an empty pipe reports empty (no blocking
// here — a PM/VFS server layers blocking semantics on top).

const PIPE_CAP: usize = 16;
const PIPE_EMPTY: u32 = 0x100; // sentinel: out of the u8 range

struct Pipe {
    buf: [PIPE_CAP]u8,
    head: usize,
    tail: usize,
    count: usize,
}

export fn pipe_init(p: *mut Pipe) -> void {
    p.head = 0;
    p.tail = 0;
    p.count = 0;
}

export fn pipe_write(p: *mut Pipe, b: u8) -> bool {
    if p.count == PIPE_CAP {
        return false; // full
    }
    p.buf[p.tail] = b;
    p.tail = (p.tail + 1) % PIPE_CAP;
    p.count = p.count + 1;
    return true;
}

// Read one byte (0..255), or PIPE_EMPTY if the pipe is empty.
export fn pipe_read(p: *mut Pipe) -> u32 {
    if p.count == 0 {
        return PIPE_EMPTY;
    }
    let b: u8 = p.buf[p.head];
    p.head = (p.head + 1) % PIPE_CAP;
    p.count = p.count - 1;
    return b as u32;
}

export fn pipe_len(p: *Pipe) -> usize {
    return p.count;
}
