// Driver-framework demo: register a 16550 UART as a char device, then write
// "DRV" to the console *through the registry* — each byte dispatches through the
// driver's function-pointer `putc`, decoupled from the concrete device.

import "kernel/bus/chardev.mc";

const UART_BASE: usize = 0x1000_0000;

struct Uart { base: usize }

global g_chardevs: CharRegistry;
global g_uart: Uart;

// A UART driver's write op: store the byte to the device's transmit register. The
// device arrives as a *typed* `*Uart` (captured by the closure) — no untyped ctx
// word and no u64->pointer cast.
impl CharDevice for Uart {
    fn putc(self: *Uart, b: u8) -> void {
        unsafe {
            raw.store<u8>(phys(self.base), b);
        }
    }
}

export fn driver_demo() -> u32 {
    char_registry_init(&g_chardevs);
    g_uart.base = UART_BASE;
    let uart_id: usize = register_chardev(&g_chardevs, &g_uart);
    chardev_putc(&g_chardevs, uart_id, 'D');
    chardev_putc(&g_chardevs, uart_id, 'R');
    chardev_putc(&g_chardevs, uart_id, 'V');
    return uart_id as u32;
}
