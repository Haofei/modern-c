// std/spinlock — a fair (ticket) spinlock built on the atomic cell.
//
// `lock` draws a ticket (fetch_add) and spins until `now_serving` reaches it;
// `unlock` advances `now_serving`. Uses only fetch_add/load/store (acquire on
// entry, release on exit), so it needs no compare-exchange primitive and grants the
// lock in FIFO order (no starvation). Zero-initialized storage is a valid unlocked
// lock (both counters 0).

struct Spinlock {
    next_ticket: atomic<u32>,
    now_serving: atomic<u32>,
}

export fn spinlock_init(l: *mut Spinlock) -> void {
    l.next_ticket.store(0, .release);
    l.now_serving.store(0, .release);
}

export fn spin_lock(l: *mut Spinlock) -> void {
    let my: u32 = l.next_ticket.fetch_add(1, .acq_rel);
    var served: bool = false;
    while !served {
        let cur: u32 = l.now_serving.load(.acquire);
        if cur == my {
            served = true;
        }
    }
}

export fn spin_unlock(l: *mut Spinlock) -> void {
    let cur: u32 = l.now_serving.load(.acquire);
    l.now_serving.store(cur + 1, .release);
}
