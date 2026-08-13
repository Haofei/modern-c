# MC driver demos — typed hardware

A demo suite showing how MC encodes hardware protocols — register permissions,
device state machines, capabilities, bus/DMA ownership, descriptor lifecycles,
and device-visible memory — in the **type system**, so the hazards a C driver
guards against by convention become **compile errors**.

| demo | hardware class | what the types enforce | status |
|------|----------------|------------------------|--------|
| `uart/` | MMIO registers | access direction (`Reg<T, .read/.write>`); writing a read-only register or reading a write-only one is rejected. `@offset(N)` pins the register map. | compile-gated contract |
| `gpio/` | pin capability | only a configured `OutputPin` can be driven, only an `InputPin` read; the capabilities are linear (`move`) and not interchangeable. | compile-gated contract |
| `timer/` | device state machine | linear typestate `TimerStopped` ↔ `TimerRunning`; `start`/`configure` need Stopped, `elapsed` needs Running, the handle must be closed. | compile-gated contract |
| `irq/` | interrupt lifecycle | `Masked → Enabled → Pending → Enabled`; `ack` needs an `IrqPending`; shared updates need an `IrqOff` witness. | compile-gated contract |
| `spi/` | bus transaction | a linear `SpiTransaction` holds chip-select; forgetting to end it leaks, using it after end is a move error. | compile-gated contract |
| `framebuffer/` | device-visible memory | a linear `Framebuffer` mapping; pixels carry their typed format (`Rgb888`, not a bare `u32`); a flush names the dirty rectangle; unmap exactly once. | compile-gated contract |

The register/capability/typestate demos (`uart`…`framebuffer`) are
compile-gated: their value is the static contract.

## Running

```sh
zig build demo-test     # lower every demo to C, compile-check it, and verify the
                        # demo/bad/ misuses are rejected (both in `zig build m0`)
```

## Compile-fail demos (`demo/bad/`)

The point of the suite is what it *rejects*. Each `demo/bad/*.mc` is a real misuse
that must not compile, checked by `demo-test`:

| misuse | rejected with |
|--------|---------------|
| read a write-only UART register | `E_MMIO_ACCESS_FORBIDDEN` |
| drive a pin configured as input | `E_NO_IMPLICIT_CONVERSION` |
| read `elapsed` from a stopped timer | `E_NO_IMPLICIT_CONVERSION` |
| `ack` an interrupt that has not fired | `E_NO_IMPLICIT_CONVERSION` |
| transfer after the SPI transaction ended | `E_USE_AFTER_MOVE` |
| draw after the framebuffer was unmapped | `E_USE_AFTER_MOVE` |
| get a CPU address of a device-owned DMA buffer | `E_NO_IMPLICIT_CONVERSION` |
