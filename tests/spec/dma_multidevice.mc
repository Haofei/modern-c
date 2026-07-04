// SPEC: section=18.1,18.2
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_NO_IMPLICIT_CONVERSION,E_RESOURCE_LEAK,E_MOVE_BRANCH_MISMATCH

// Library-scale DMA ownership: the std/dma typestate (section 18.2) carried across
// *several* devices and *several* in-flight buffers at once. The point is that the
// linear `move` discipline scales — ownership is single, not device-tagged, so the
// compiler enforces "each buffer is consumed exactly once" no matter how many
// engines and slots are live. A buffer is CPU-owned or device-owned, never both;
// the transitions consume one handle and produce the other.

move struct CpuOwned {
    addr: usize,
}

move struct DeviceOwned {
    addr: usize,
    queue: u8,        // which engine it was submitted to (data, not a typestate)
}

// Two independent DMA engines (a TX path and an RX path) plus a copy engine — the
// "multi-device" axis. Each handoff names its engine; the typestate is the same.
const ENGINE_TX: u8 = 0;
const ENGINE_RX: u8 = 1;
const ENGINE_COPY: u8 = 2;

fn make() -> CpuOwned {
    return .{ .addr = 1 };
}
fn handoff(b: CpuOwned, engine: u8) -> DeviceOwned {  // clean caches, give to engine
    let addr: usize = b.addr;
    unsafe { forget_unchecked(b); }
    return .{ .addr = addr, .queue = engine };
}
fn reclaim(b: DeviceOwned) -> CpuOwned {              // invalidate, take back
    let addr: usize = b.addr;
    unsafe { forget_unchecked(b); }
    return .{ .addr = addr };
}
fn release(b: CpuOwned) -> void {                     // free
    unsafe { forget_unchecked(b); }
}

// ----- accepted: two engines with a buffer in flight on each, simultaneously --
fn accept_two_engines_concurrent() -> void {
    let a: CpuOwned = make();
    let b: CpuOwned = make();
    let tx: DeviceOwned = handoff(a, ENGINE_TX);   // a consumed
    let rx: DeviceOwned = handoff(b, ENGINE_RX);   // b consumed; both in flight at once
    let a_back: CpuOwned = reclaim(tx);
    let b_back: CpuOwned = reclaim(rx);
    release(a_back);
    release(b_back);
}

// ----- accepted: a buffer migrates between engines (TX done -> reused for COPY) -
// Cross-device reuse is fine: ownership is linear, not pinned to one engine.
fn accept_buffer_migrates_engines() -> void {
    let buf: CpuOwned = make();
    let on_tx: DeviceOwned = handoff(buf, ENGINE_TX);
    let after_tx: CpuOwned = reclaim(on_tx);        // back to CPU
    let on_copy: DeviceOwned = handoff(after_tx, ENGINE_COPY);
    release(reclaim(on_copy));
}

// ----- accepted: a 3-slot ring drained in order, each slot a distinct handle ----
// (MC has no array of `move` — E_MOVE_ARRAY_UNSUPPORTED — so the slots are distinct
// locals, which is exactly how a fixed-depth descriptor ring is unrolled.)
fn accept_ring_drain() -> void {
    let s0: CpuOwned = make();
    let s1: CpuOwned = make();
    let s2: CpuOwned = make();
    let d0: DeviceOwned = handoff(s0, ENGINE_RX);
    let d1: DeviceOwned = handoff(s1, ENGINE_RX);
    let d2: DeviceOwned = handoff(s2, ENGINE_RX);
    release(reclaim(d0));
    release(reclaim(d1));
    release(reclaim(d2));
}

// ----- accepted: conditional engine dispatch, buffer consumed on every path -----
fn accept_conditional_dispatch(to_rx: bool) -> void {
    let buf: CpuOwned = make();
    switch to_rx {
        true => {
            let d: DeviceOwned = handoff(buf, ENGINE_RX);
            release(reclaim(d));
        },
        false => {
            let d: DeviceOwned = handoff(buf, ENGINE_TX);
            release(reclaim(d));
        },
    }
}

// ----- rejected: handing the SAME buffer to two engines (double submit) ---------
fn reject_same_buffer_two_engines() -> void {
    let buf: CpuOwned = make();
    let tx: DeviceOwned = handoff(buf, ENGINE_TX);    // buf consumed here
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let rx: DeviceOwned = handoff(buf, ENGINE_RX);    // ...used again — second engine can't have it
    release(reclaim(tx));
    release(reclaim(rx));
}

// ----- rejected: submitting a CPU-owned buffer where a device handle is required -
fn reject_submit_cpu_owned() -> void {
    let buf: CpuOwned = make();
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let back: CpuOwned = reclaim(buf);                // reclaim takes DeviceOwned
    release(back);
}

// ----- rejected: one engine's buffer leaks while the other is cleaned up --------
fn reject_leak_one_engine() -> void {
    let a: CpuOwned = make();
    let b: CpuOwned = make();
    let tx: DeviceOwned = handoff(a, ENGINE_TX);
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let rx: DeviceOwned = handoff(b, ENGINE_RX);      // rx is never reclaimed/freed — leaks
    release(reclaim(tx));
}

// ----- rejected: buffer consumed on one branch only (asymmetric dispatch) -------
fn reject_branch_mismatch(to_rx: bool) -> void {
    // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    let buf: CpuOwned = make();           // consumed on the true branch only
    switch to_rx {
        true => {
            let d: DeviceOwned = handoff(buf, ENGINE_RX);
            release(reclaim(d));
        },
        false => {
            // buf left CPU-owned and un-freed on this path
        },
    }
}
