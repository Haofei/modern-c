// G22 helper A. A "strict" file (>= 1 `pub` decl) whose `advance` is FILE-PRIVATE.
// A's `advance` takes ONE argument and adds 100. It shares the bare name `advance` with
// helper B's file-private `advance` (a DIFFERENT signature) — pre-G22 this was a global
// E_DUPLICATE_DECLARATION even though neither is visible cross-file.
pub fn a_step(x: u32) -> u32 {
    return advance(x); // must bind to THIS file's advance, not B's
}

fn advance(x: u32) -> u32 {
    return x + 100;
}
