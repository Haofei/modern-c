// kernel/core/pgroup — process groups & sessions (job control bookkeeping a PM owns).
// Each pid maps to a process-group id and a session id; setsid starts a new session
// (pgid = sid = pid), setpgid joins/creates a group within the session.

const PG_MAX: usize = 16;

struct PGroups {
    pgid: [PG_MAX]u32,
    sid: [PG_MAX]u32,
}

export fn pgroups_init(g: *mut PGroups) -> void {
    var i: usize = 0;
    while i < PG_MAX {
        g.pgid[i] = 0;
        g.sid[i] = 0;
        i = i + 1;
    }
}

// Start a new session led by `pid`: it becomes its own session + group leader.
export fn setsid(g: *mut PGroups, pid: u32) -> void {
    let i: usize = pid as usize;
    if i < PG_MAX {
        g.sid[i] = pid;
        g.pgid[i] = pid;
    }
}

// Put `pid` into process group `pgid` (joining an existing group in its session).
export fn setpgid(g: *mut PGroups, pid: u32, pgid: u32) -> void {
    let i: usize = pid as usize;
    if i < PG_MAX {
        g.pgid[i] = pgid;
    }
}

export fn getpgid(g: *mut PGroups, pid: u32) -> u32 {
    let i: usize = pid as usize;
    if i < PG_MAX {
        return g.pgid[i];
    }
    return 0;
}
export fn getsid(g: *mut PGroups, pid: u32) -> u32 {
    let i: usize = pid as usize;
    if i < PG_MAX {
        return g.sid[i];
    }
    return 0;
}
