// kernel/core/liveupdate — minimal live update (MINIX 3 style): a running service's state
// is checkpointed, a new version of the service is installed, and the state is restored
// into it. The service keeps its data across a code change — update without losing state.

import "std/addr.mc";

struct ServiceState {
    version: u32,
    counter: u32,
    total: u32,
}

// Serialize the live state to a handoff buffer.
export fn lu_checkpoint(s: *mut ServiceState, buf: PAddr) -> void {
    unsafe {
        raw.store<u32>(pa_offset(buf, 0), s.counter);
        raw.store<u32>(pa_offset(buf, 4), s.total);
    }
}

// Restore state into the *new* version `s` (its code is new; its data is the old data).
export fn lu_restore(s: *mut ServiceState, buf: PAddr, new_version: u32) -> void {
    unsafe {
        s.counter = raw.load<u32>(pa_offset(buf, 0));
        s.total = raw.load<u32>(pa_offset(buf, 4));
    }
    s.version = new_version;
}
