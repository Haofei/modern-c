// Runtime proof for `#[naked]` (§20.1) on AArch64, run natively on both backends
// by tools/exec/naked-run.sh (`zig build naked-run-test`).
//
// The pointer argument arrives in x0 (AAPCS arg0). Because `#[naked]` emits no
// prologue, x0 is exactly the caller's pointer on entry, so the basic-asm body
// stores 42 through it and returns. A non-naked lowering would set up a frame
// (decrementing sp) before our hand-written `ret`, corrupting the caller — so the
// `42` the C harness reads back is the proof the prologue/epilogue were omitted and
// the asm body owns the calling convention.

#[naked]
export fn naked_store(out: *mut u32) -> void {
    asm opaque volatile {
        "mov w1, #42"
        "str w1, [x0]"
        "ret"
    }
}
