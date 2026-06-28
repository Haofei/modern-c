// examples/apps/wamr/burn.c — a compute-heavy no-WASI guest for the WAMR deterministic-fuel gate.
// burn() runs a long loop (~millions of wasm instructions). The fuel host runs it twice: once with a
// LOW instruction-count limit (terminated mid-loop) and once with a HIGH limit (runs to completion),
// proving WAMR enforces a DETERMINISTIC per-instruction budget — the capability wasm3 lacks.
__attribute__((export_name("burn"))) int burn(void) {
    volatile int s = 0;
    for (int i = 0; i < 1000000; i++) s += i;
    return s;
}
