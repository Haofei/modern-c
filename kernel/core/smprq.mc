// kernel/core/smprq — per-core run queues with work stealing, the scheduling structure
// for true SMP: each core enqueues/dequeues from its own ring (no contention on the hot
// path), and an idle core steals a runnable task from the busiest core (load balancing).

const NCORES: usize = 2;
const RQ_CAP: usize = 8;
const RQ_SLOTS: usize = 16; // NCORES * RQ_CAP
const RQ_NONE: u32 = 0xFFFF_FFFF;

struct RunQueues {
    pid: [RQ_SLOTS]u32,
    head: [NCORES]usize,
    count: [NCORES]usize,
}

export fn rq_init(rq: *mut RunQueues) -> void {
    var c: usize = 0;
    while c < NCORES {
        rq.head[c] = 0;
        rq.count[c] = 0;
        c = c + 1;
    }
}

export fn rq_push(rq: *mut RunQueues, core: usize, p: u32) -> bool {
    if rq.count[core] >= RQ_CAP {
        return false;
    }
    let base: usize = core * RQ_CAP;
    let tail: usize = (rq.head[core] + rq.count[core]) % RQ_CAP;
    rq.pid[base + tail] = p;
    rq.count[core] = rq.count[core] + 1;
    return true;
}

export fn rq_pop(rq: *mut RunQueues, core: usize) -> u32 {
    if rq.count[core] == 0 {
        return RQ_NONE;
    }
    let base: usize = core * RQ_CAP;
    let p: u32 = rq.pid[base + rq.head[core]];
    rq.head[core] = (rq.head[core] + 1) % RQ_CAP;
    rq.count[core] = rq.count[core] - 1;
    return p;
}

export fn rq_count(rq: *mut RunQueues, core: usize) -> usize {
    return rq.count[core];
}

// Idle `core` steals one task from the busiest other core; RQ_NONE if none available.
export fn rq_steal(rq: *mut RunQueues, core: usize) -> u32 {
    var best: usize = core;
    var best_count: usize = 0;
    var c: usize = 0;
    while c < NCORES {
        if c != core {
            if rq.count[c] > best_count {
                best = c;
                best_count = rq.count[c];
            }
        }
        c = c + 1;
    }
    if best == core {
        return RQ_NONE; // nothing to steal
    }
    return rq_pop(rq, best);
}
