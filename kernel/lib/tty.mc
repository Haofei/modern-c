// kernel/lib/tty — terminal line discipline in canonical mode: input bytes are
// assembled into a line, backspace erases the last byte, and a newline completes the
// line so it can be read as a unit. This is the core of a TTY server (cooked input).

import "std/addr.mc";

const TTY_LINE: usize = 64;
const TTY_BS: u8 = 0x08;  // backspace
const TTY_NL: u8 = 0x0A;  // newline completes the line

struct Tty {
    line: [TTY_LINE]u8,  // line being assembled
    len: usize,
    rbuf: [TTY_LINE]u8,  // last completed line
    rlen: usize,
    ready: bool,
}

export fn tty_init(t: *mut Tty) -> void {
    t.len = 0;
    t.rlen = 0;
    t.ready = false;
}

// Feed one input byte through the line discipline.
export fn tty_input(t: *mut Tty, ch: u8) -> void {
    if ch == TTY_NL {
        var i: usize = 0;
        while i < t.len {
            t.rbuf[i] = t.line[i];
            i = i + 1;
        }
        t.rlen = t.len;
        t.len = 0;
        t.ready = true;
    } else {
        if ch == TTY_BS {
            if t.len > 0 {
                t.len = t.len - 1; // erase
            }
        } else {
            if t.len < TTY_LINE {
                t.line[t.len] = ch;
                t.len = t.len + 1;
            }
        }
    }
}

export fn tty_ready(t: *Tty) -> bool {
    return t.ready;
}

// Copy the completed line into `dst` (up to `max`); returns its length, clears ready.
export fn tty_readline(t: *mut Tty, dst: PAddr, max: usize) -> usize {
    var n: usize = t.rlen;
    if max < n {
        n = max;
    }
    var i: usize = 0;
    while i < n {
        unsafe {
            raw.store<u8>(pa_offset(dst, i), t.rbuf[i]);
        }
        i = i + 1;
    }
    t.ready = false;
    return n;
}
