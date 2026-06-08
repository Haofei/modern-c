// std/libc — a minimal freestanding libc core for userland: byte-string compare,
// length, and decimal parsing over typed addresses. (The shell + utilities build on it.)

import "std/addr.mc";

export fn mc_memeq(a: PAddr, b: PAddr, n: usize) -> bool {
    var i: usize = 0;
    while i < n {
        var x: u8 = 0;
        var y: u8 = 0;
        unsafe {
            x = raw.load<u8>(pa_offset(a, i));
            y = raw.load<u8>(pa_offset(b, i));
        }
        if x != y {
            return false;
        }
        i = i + 1;
    }
    return true;
}

export fn mc_strlen(s: PAddr) -> usize {
    var n: usize = 0;
    var go: bool = true;
    while go {
        var b: u8 = 0;
        unsafe {
            b = raw.load<u8>(pa_offset(s, n));
        }
        if b == 0 {
            go = false;
        } else {
            n = n + 1;
        }
    }
    return n;
}

// Parse `n` ASCII decimal digits into a u32 (non-digits skipped).
export fn mc_atoi(s: PAddr, n: usize) -> u32 {
    var v: u32 = 0;
    var i: usize = 0;
    while i < n {
        var c: u8 = 0;
        unsafe {
            c = raw.load<u8>(pa_offset(s, i));
        }
        if c >= 0x30 {
            if c <= 0x39 {
                v = v * 10 + ((c - 0x30) as u32);
            }
        }
        i = i + 1;
    }
    return v;
}
