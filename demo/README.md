# MC driver demos — typed hardware

A demo suite showing how MC encodes hardware protocols — register permissions,
device state machines, capabilities, bus/DMA ownership, descriptor lifecycles,
and device-visible memory — in the **type system**, so the hazards a C driver
guards against by convention become **compile errors**.

| demo | hardware class | what the types enforce |
|------|----------------|------------------------|
| `uart/` | MMIO registers | access direction (`Reg<T, .read/.write>`); writing a read-only register or reading a write-only one is rejected. `@offset(N)` pins the register map. |
| `gpio/` | pin capability | only a configured `OutputPin` can be driven, only an `InputPin` read; the capability types are not interchangeable. |
| `timer/` | device state machine | linear typestate `TimerStopped` ↔ `TimerRunning`; `start`/`configure` need Stopped, `elapsed` needs Running, the handle must be closed. |
| `irq/` | interrupt lifecycle | `Masked → Enabled → Pending → Enabled`; `ack` needs an `IrqPending`; shared updates need an `IrqOff` witness. |
| `spi/` | bus transaction | a linear `SpiTransaction` holds chip-select; forgetting to end it leaks, using it after end is a move error. |
| `virtio-blk/` | DMA queue, request/response | block buffers cross the queue as linear DMA handles with device directions; the CPU can't read the result until it is reclaimed. |
| `virtio-net/` | DMA queue, streaming packet | the full virtio 1.x driver — runs on emulated hardware under QEMU. |
| `framebuffer/` | device-visible memory | a linear `Framebuffer` mapping; pixels carry their format; a flush names the dirty rectangle; unmap exactly once. |

## Running

```sh
zig build demo-test     # lower every demo to C and compile-check it
zig build virtio-test   # run the virtio-net driver against virtio-net-device under QEMU
```

Both are part of `zig build m0`. The non-`virtio-net` demos are compile-gated
(their value is the static contract); their forbidden operations are noted in
each file and exercised by the spec fixtures `tests/spec/move_linear.mc`,
`tests/spec/dma_ownership.mc`, and the MMIO fixtures.
