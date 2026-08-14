# MC specification layers

The current implementation-aligned draft is
[`MC_0.7_Final_Design.md`](MC_0.7_Final_Design.md). The filename is historical;
the document is now treated as a design draft, not a final stable language
contract.

The active project split is:

| Layer | Role |
| --- | --- |
| Core | Scalar values, control flow, checked arithmetic, `Result`, optionals, tagged unions, pointers, traps, C ABI, and narrow comptime. |
| Machine contracts | Address spaces, MMIO, DMA/cache transitions, atomics/fences, IRQ context, inline asm, move resources, and unsafe contracts. |
| Experimental | Traits, closures, broad generics, async/await, `view struct`, `region struct`, `thread_move`, and borrowed-return contracts. |
| Validation | Hosted, QEMU, freestanding, and differential workloads used as compiler evidence, not product scope. |

Feature status is machine-readable in
[`../feature-maturity.json`](../feature-maturity.json). A feature is not part of
the stable core merely because parser, sema, or backend support exists.
