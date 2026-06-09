// kernel/lib/proc_snapshot — a stable snapshot of the process table for top/ps. The live
// table (kernel/core/process) changes as processes spawn/exit; a reader that wants a
// consistent view (enumerate pids + states, summarize counts) captures a snapshot once and
// iterates that, instead of racing the live table across multiple reads.
//
// Builds on the core introspection accessors (proc_count / proc_pid_at / proc_state_code);
// the policy here is only the stable copy + summary, keeping kernel/core as the mechanism.

import "kernel/core/process.mc";

const SNAP_MAX: usize = 8; // capacity; must be >= the process table's MAX_PROCS

struct ProcInfo {
    pid: u32,
    state: u32, // the stable state code from proc_state_code
}

struct Snapshot {
    entries: [SNAP_MAX]ProcInfo,
    count: usize,
}

// Capture pid + state for every live slot. After this, the snapshot is independent of the
// table — later spawn/exit does not change what a reader enumerates.
export fn snapshot_take(t: *mut ProcTable, snap: *mut Snapshot) -> void {
    var n: usize = proc_count(t);
    if n > SNAP_MAX {
        n = SNAP_MAX;
    }
    var i: usize = 0;
    while i < n {
        snap.entries[i].pid = proc_pid_at(t, i);
        snap.entries[i].state = proc_state_code(t, i);
        i = i + 1;
    }
    snap.count = n;
}

export fn snapshot_count(snap: *mut Snapshot) -> usize {
    return snap.count;
}

export fn snapshot_pid(snap: *mut Snapshot, i: usize) -> u32 {
    if i < snap.count {
        return snap.entries[i].pid;
    }
    return 0;
}

export fn snapshot_state(snap: *mut Snapshot, i: usize) -> u32 {
    if i < snap.count {
        return snap.entries[i].state;
    }
    return 0;
}

// SYS_PROC_INFO register ABI: a (pid, state code) row packed into one word, so a userspace
// top/ps reads one process per syscall. A struct can't cross the register boundary, so this
// is the "named packed type" — the bit layout lives here, not in scattered `<< 4` literals.
export fn proc_info_encode(pid: u32, state: u32) -> u64 {
    return ((pid as u64) << 4) | ((state as u64) & 0xF);
}
export fn proc_info_pid(word: u64) -> u32 {
    return (word >> 4) as u32;
}
export fn proc_info_state(word: u64) -> u32 {
    return (word & 0xF) as u32;
}

// How many captured processes are in a given state code (e.g., a top "running" summary).
export fn snapshot_count_state(snap: *mut Snapshot, state: u32) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < snap.count {
        if snap.entries[i].state == state {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}
