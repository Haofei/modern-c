// EXPECT: E_MMIO_ACCESS_FORBIDDEN — reading a write-only register.
import "demo/uart/uart.mc";
fn bad(u: MmioPtr<Uart16550>) -> u8 {
    return u.thr.read(.acquire);
}
