// SPEC: section=20.1
// SPEC: milestone=naked-functions
// SPEC: phase=parse,sema,lower-c,lower-ir
// SPEC: expect=pass
// SPEC: check=section-attr-accept

// `#[section("name")]` (docs/spec/MC_0.7_Final_Design.md §20.1): place the
// declaration's object symbol in the named linker section. Needed for bare-metal
// entry points pinned to a fixed load address by the linker script (e.g. OpenSBI's
// `_start` at 0x80200000 via `KEEP(*(.text.boot))`). It composes with `#[naked]`
// and `export`. Both backends honor it (C `__attribute__((section("…")))`; LLVM a
// `section "…"` clause on the `define`).

// Accept: a naked boot vector placed in `.text.boot` (the OpenSBI payload entry).
#[naked]
#[section(".text.boot")]
export fn boot_entry() -> void {
    asm opaque volatile {
        "ret"
    }
}

// Accept: `#[section]` on an ordinary (non-naked) function — placement only, the
// compiler still emits the normal prologue/epilogue.
#[section(".text.hot")]
export fn hot_path(x: u32) -> u32 {
    return x + 1;
}

// Accept: `#[noinline]` forbids inlining so the function keeps a distinct physical call
// frame (needed e.g. by a frame-pointer backtrace walking nested frames). Both backends
// honor it (C `__attribute__((noinline))`; LLVM the `noinline` function attribute). It
// composes with `#[section]`.
#[noinline]
export fn never_inlined(x: u32) -> u32 {
    return x + 1;
}
