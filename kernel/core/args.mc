// kernel/core/args — argv/envp passed to a program: NUL-terminated strings packed into
// a buffer with per-arg offsets, so exec can hand a process its argument vector.
//
// Capacity-safe: argc never exceeds ARG_MAX and the buffer never overflows. When input
// would exceed either bound it is dropped and a sticky `truncated` flag is set (queried
// via args_truncated) rather than corrupting argc/offsets — so args_byte/args_len always
// index within bounds.

const ARG_MAX: usize = 8;
const ARG_BUF: usize = 128;

struct Args {
    off: [ARG_MAX]usize,
    argc: usize,
    buf: [ARG_BUF]u8,
    used: usize,
    truncated: bool, // set if any arg or byte was dropped for lack of capacity
}

export fn args_init(a: *mut Args) -> void {
    a.argc = 0;
    a.used = 0;
    a.truncated = false;
}

// Begin a new argument at the current buffer position. If the table is already full the
// argument is not recorded (and will be dropped); marked truncated.
export fn args_begin(a: *mut Args) -> void {
    if a.argc < ARG_MAX {
        a.off[a.argc] = a.used;
    } else {
        a.truncated = true;
    }
}

export fn args_push_byte(a: *mut Args, ch: u8) -> void {
    // Drop the byte if the table slot is overflow, or the buffer is full, or there is no
    // room left for this byte *and* a following NUL terminator.
    if a.argc >= ARG_MAX {
        a.truncated = true;
        return;
    }
    if a.used + 1 < ARG_BUF {
        a.buf[a.used] = ch;
        a.used = a.used + 1;
    } else {
        a.truncated = true;
    }
}

// Finish the current argument (NUL-terminate it). Commits the arg only if it fits in both
// the offset table and the buffer; otherwise marks truncated and commits nothing.
export fn args_end(a: *mut Args) -> void {
    if a.argc >= ARG_MAX {
        a.truncated = true;
        return; // table full — do not grow argc past ARG_MAX
    }
    if a.used < ARG_BUF {
        a.buf[a.used] = 0;
        a.used = a.used + 1;
        a.argc = a.argc + 1;
    } else {
        a.truncated = true; // no room for the NUL — drop this arg rather than corrupt it
    }
}

export fn args_count(a: *mut Args) -> usize {
    return a.argc;
}

// True if any argument or byte was dropped because a capacity bound was hit.
export fn args_truncated(a: *mut Args) -> bool {
    return a.truncated;
}

// Byte j of argument i (0 if i is out of range).
export fn args_byte(a: *mut Args, i: usize, j: usize) -> u8 {
    if i >= a.argc {
        return 0;
    }
    return a.buf[a.off[i] + j];
}

// Length of argument i (excluding the NUL terminator); 0 if i is out of range.
export fn args_len(a: *mut Args, i: usize) -> usize {
    if i >= a.argc {
        return 0;
    }
    var next: usize = a.used;
    if i + 1 < a.argc {
        next = a.off[i + 1];
    }
    return next - a.off[i] - 1;
}
