// Differential regression for the LLVM backend's entry-block alloca hoist.
//
// A local declared INSIDE a loop body must lower to a single STATIC alloca in the function
// entry block, NOT a fresh alloca per iteration. An alloca emitted in a (non-entry) loop block
// is a dynamic stack allocation that grows the stack every iteration and is never reclaimed
// until the function returns — so a long-running loop silently exhausts the stack and corrupts
// adjacent memory. (Found via a 4096-byte ELF-loader copy loop corrupting the kernel heap under
// QEMU; the C backend was always correct because it emits a normal reused C local.)
//
// This fixture makes the bug observable on a HOST (where the stack is large): the in-loop local
// is a 256-byte array and the loop runs 1,000,000 times. With the bug the LLVM build allocates
// ~256 MB of stack and SEGFAULTs (exit code diverges from the C backend); with the fix it
// reuses one entry-block slot and returns the checksum. diff-backend compares stdout AND exit,
// so either symptom — wrong value or a crash — is caught.

const ITERS: u32 = 1000000;
const BUF: usize = 256;

export fn alloca_hoist_run() -> u32 {
    var sum: u32 = 0;
    var i: u32 = 0;
    while i < ITERS {
        // `scratch` is declared in the loop body: exactly the construct that mis-lowered.
        var scratch: [BUF]u8 = uninit;
        let slot: usize = (i as usize) % BUF;
        scratch[slot] = (i & 0xFF) as u8;
        sum = sum + (scratch[slot] as u32);
        i = i + 1;
    }
    // sum = Σ (i & 0xFF) for i in 0..1_000_000, taken mod 2^32. A fixed run returns this;
    // a buggy run never gets here (stack overflow). The exact value need only AGREE across
    // backends — diff-backend checks equality, not a hard-coded constant.
    return sum;
}
