// Runtime proof for `#[naked]` (§20.1) on x86-64, run natively on both backends by
// tools/exec/naked-run.sh (`zig build naked-run-test`).
//
// The pointer argument arrives in %rdi (System V AMD64 arg0). Because `#[naked]`
// emits no prologue, %rdi is exactly the caller's pointer on entry, so the
// basic-asm body stores 42 through it and returns. A non-naked lowering would set
// up a frame before our hand-written `ret`, corrupting the caller — so the `42` the
// C harness reads back is the proof the prologue/epilogue were omitted and the asm
// body owns the calling convention. (AT&T syntax: `movl $imm, (%reg)`.)

#[naked]
export fn naked_store(out: *mut u32) -> void {
    asm opaque volatile {
        "movl $42, (%rdi)"
        "ret"
    }
}
