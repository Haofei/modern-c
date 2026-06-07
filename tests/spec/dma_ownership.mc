// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_NO_IMPLICIT_CONVERSION

// DMA buffer ownership as two distinct `move` typestates (the std/dma model):
// a buffer is CPU-owned or device-owned, never both. The transitions consume one
// and produce the other, so the compiler rejects submitting a CPU-owned buffer
// (wrong typestate) and touching a buffer after handing it to the device.

move struct CpuOwned {
    addr: usize,
}

move struct DeviceOwned {
    addr: usize,
}

extern fn make() -> CpuOwned;
extern fn handoff(b: CpuOwned) -> DeviceOwned;     // clean caches, give to device
extern fn submit(b: DeviceOwned) -> DeviceOwned;   // queue it; returns in-flight handle
extern fn reclaim(b: DeviceOwned) -> CpuOwned;     // invalidate, take back
extern fn release(b: CpuOwned) -> void;            // free

// Accepted: the full ownership cycle, each handle consumed exactly once.
fn accept_cycle() -> void {
    let c: CpuOwned = make();
    let d: DeviceOwned = handoff(c);
    let inflight: DeviceOwned = submit(d);
    let back: CpuOwned = reclaim(inflight);
    release(back);
}

// Rejected: submitting a buffer the CPU still owns (never handed off).
fn reject_submit_cpu_owned() -> void {
    let c: CpuOwned = make();
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let inflight: DeviceOwned = submit(c);
    release(reclaim(inflight));
}

// Rejected: touching the buffer after it was handed to the device.
fn reject_use_after_handoff() -> void {
    let c: CpuOwned = make();
    let d: DeviceOwned = handoff(c);
    let inflight: DeviceOwned = submit(d);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let again: DeviceOwned = submit(d);
    release(reclaim(inflight));
    release(reclaim(again));
}
