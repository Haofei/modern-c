// kernel/core/smprq — per-core run queues with work stealing, the scheduling structure
// for true SMP: each core enqueues/dequeues from its own FIFO (no contention on the hot
// path), and an idle core steals a runnable task from the busiest core (load balancing).
// The per-core FIFOs are std `Ring<u32, RQ_CAP>` — no hand-rolled head/tail/count/`% CAP`.

import "std/ring.mc";

const NCORES: usize = 2;
const RQ_CAP: usize = 8;

enum RqError {
    Empty, // the run queue (or all steal targets) had no task
}

struct RunQueues {
    q: [NCORES]Ring<u32, RQ_CAP>, // one FIFO ring per core
}

export fn rq_init(rq: *mut RunQueues) -> void {
    var c: usize = 0;
    while c < NCORES {
        ring_init(u32, RQ_CAP, &rq.q[c]);
        c = c + 1;
    }
}

export fn rq_push(rq: *mut RunQueues, core: usize, p: u32) -> bool {
    return ring_push(u32, RQ_CAP, &rq.q[core], p);
}

export fn rq_pop(rq: *mut RunQueues, core: usize) -> Result<u32, RqError> {
    if ring_is_empty(u32, RQ_CAP, &rq.q[core]) {
        return err(.Empty);
    }
    return ok(ring_pop(u32, RQ_CAP, &rq.q[core]));
}

export fn rq_count(rq: *mut RunQueues, core: usize) -> usize {
    return ring_len(u32, RQ_CAP, &rq.q[core]);
}

// Idle `core` steals one task from the busiest other core; Empty if none available.
export fn rq_steal(rq: *mut RunQueues, core: usize) -> Result<u32, RqError> {
    var best: usize = core;
    var best_count: usize = 0;
    var c: usize = 0;
    while c < NCORES {
        if c != core {
            let n: usize = rq_count(rq, c);
            if n > best_count {
                best = c;
                best_count = n;
            }
        }
        c = c + 1;
    }
    if best == core {
        return err(.Empty); // nothing to steal
    }
    return rq_pop(rq, best);
}
