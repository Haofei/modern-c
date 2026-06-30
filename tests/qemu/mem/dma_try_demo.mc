// Exercises std/dma's typed fallible allocation (`try_alloc` -> Result<CpuBuffer, DmaError>).
// The host driver (tools/lib/host-drivers/dma-try-test.c) supplies a TINY one-shot DMA pool via
// the `mc_dma_alloc_base_try` provider primitive, so a small request succeeds while a request the
// pool can't satisfy returns `err(.OutOfMemory)` instead of trapping. Returns a bitmask:
//   bit0 (0x1) = a small request succeeded (ok path, buffer minted + freed)
//   bit1 (0x2) = an oversized request returned the typed DmaError.OutOfMemory (no trap)
// PASS iff both bits set (0x3).

import "std/alloc/dma.mc";

export fn dma_try_run() -> u32 {
    var result: u32 = 0;

    // A small request fits the tiny pool: ok, mint + free the buffer.
    let r1: Result<CpuBuffer, DmaError> = try_alloc(64);
    switch r1 {
        ok(b) => {
            result = result | 1;
            free(b);
        }
        err(e) => {
            // unexpected: leave bit0 clear so the gate fails
        }
    }

    // A request larger than the pool exhausts it: typed error, no trap, no buffer.
    let r2: Result<CpuBuffer, DmaError> = try_alloc(1024 * 1024);
    switch r2 {
        ok(b) => {
            free(b); // unexpected: still consume the linear buffer to avoid a leak
        }
        err(e) => {
            switch e {
                .OutOfMemory => { result = result | 2; }
            }
        }
    }

    return result;
}
