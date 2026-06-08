// kernel/core/args — argv/envp passed to a program: NUL-terminated strings packed into
// a buffer with per-arg offsets, so exec can hand a process its argument vector.

const ARG_MAX: usize = 8;
const ARG_BUF: usize = 128;

struct Args {
    off: [ARG_MAX]usize,
    argc: usize,
    buf: [ARG_BUF]u8,
    used: usize,
}

export fn args_init(a: *mut Args) -> void {
    a.argc = 0;
    a.used = 0;
}

// Begin a new argument at the current buffer position.
export fn args_begin(a: *mut Args) -> void {
    if a.argc < ARG_MAX {
        a.off[a.argc] = a.used;
    }
}

export fn args_push_byte(a: *mut Args, ch: u8) -> void {
    if a.used < ARG_BUF {
        a.buf[a.used] = ch;
        a.used = a.used + 1;
    }
}

// Finish the current argument (NUL-terminate it).
export fn args_end(a: *mut Args) -> void {
    if a.used < ARG_BUF {
        a.buf[a.used] = 0;
        a.used = a.used + 1;
    }
    a.argc = a.argc + 1;
}

export fn args_count(a: *mut Args) -> usize {
    return a.argc;
}

// Byte j of argument i.
export fn args_byte(a: *mut Args, i: usize, j: usize) -> u8 {
    return a.buf[a.off[i] + j];
}

// Length of argument i (excluding the NUL terminator).
export fn args_len(a: *mut Args, i: usize) -> usize {
    var next: usize = a.used;
    if i + 1 < a.argc {
        next = a.off[i + 1];
    }
    return next - a.off[i] - 1;
}
