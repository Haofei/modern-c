fn asm_in_unsafe() -> void {
    unsafe {
        asm opaque volatile {
            "pause"
            clobber("memory")
        }
    }
}
