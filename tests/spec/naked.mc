// SPEC: section=20.1
// SPEC: milestone=naked-functions
// SPEC: phase=parse,sema,lower-c,lower-ir
// SPEC: expect=pass,compile_error
// SPEC: check=E_NAKED_BODY,E_NAKED_RETURN

// `#[naked]` (docs/spec/MC_0.7_Final_Design.md §20.1): the compiler emits no
// prologue or epilogue. The body is a single `asm` block that owns the entire
// calling convention — reset vectors, trap/interrupt entry stubs, context-switch
// trampolines. The body is an implicit strict-unsafe context, so the `asm` needs
// no `unsafe {}` wrapper. (The asm here uses `ret`/`nop`, which assemble on every
// supported target; the runtime proof with real ABI register access lives in the
// arch-dispatched `naked-run-test`.)

// Accept: a `-> void` naked function whose body is exactly one asm block that
// performs the ABI-correct return itself.
#[naked]
export fn naked_return() -> void {
    asm opaque volatile {
        "ret"
    }
}

// Accept: `-> never` is allowed — the asm diverges and never returns to the caller.
#[naked]
export fn naked_diverge() -> never {
    asm opaque volatile {
        "nop"
    }
}

// Reject: a non-asm body. There is no frame for locals/statements to live in, so
// anything other than a single asm block is ill-formed.
#[naked]
export fn naked_with_locals() -> void {
    // EXPECT_ERROR: E_NAKED_BODY
    let x: u32 = 0;
}

// Reject: a value return. A naked function cannot synthesize a value return; the
// asm body owns the calling convention, so the return type must be `void`/`never`.
#[naked]
// EXPECT_ERROR: E_NAKED_RETURN
export fn naked_value() -> u32 {
    asm opaque volatile {
        "ret"
    }
}
