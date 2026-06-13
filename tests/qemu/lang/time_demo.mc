// Host exercise of std/time wrap-correct timeout arithmetic (§28.4). Tick counters
// are a `wrap<u64>` domain, so the elapsed difference must stay wrap-correct even
// when the counter rolls past u64 max between two reads. These thin wrappers let the
// host driver feed raw u64 endpoints (entering the wrap domain internally) and read
// back the magnitude / timeout decision; u32 results keep the C ABI unambiguous.

import "std/time.mc";

type Tk = wrap<u64>;

export fn t_elapsed(start: u64, now: u64) -> u64 {
    return elapsed(Tk.from(start), Tk.from(now));
}

export fn t_timed_out(start: u64, now: u64, limit: u64) -> u32 {
    if timed_out(Tk.from(start), Tk.from(now), limit) {
        return 1;
    }
    return 0;
}
