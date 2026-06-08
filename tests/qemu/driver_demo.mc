// Driver-framework demo: register a 16550 UART as a char device, then write
// "DRV" to the console *through the registry* — each byte dispatches through the
// driver's function-pointer `putc`, decoupled from the concrete device.

import "kernel/core/device.mc";

const UART_BASE: u64 = 0x1000_0000;

global g_chardevs: CharRegistry;

// A UART driver's write op: store the byte to the device's transmit register
// (the base address arrives as the driver context).
fn uart_putc(ctx: u64, b: u8) -> void {
    unsafe {
        raw.store<u8>(phys(ctx as usize), b);
    }
}

export fn driver_demo() -> u32 {
    char_registry_init(&g_chardevs);
    let uart_id: usize = register_chardev(&g_chardevs, uart_putc, UART_BASE);
    chardev_putc(&g_chardevs, uart_id, 'D');
    chardev_putc(&g_chardevs, uart_id, 'R');
    chardev_putc(&g_chardevs, uart_id, 'V');
    return uart_id as u32;
}
