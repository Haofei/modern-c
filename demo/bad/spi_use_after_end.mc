// EXPECT: E_USE_AFTER_MOVE — transferring after the transaction ended.
import "demo/spi/spi.mc";
fn bad(bus: u32, cs: u32) -> u8 {
    var txn: SpiTransaction = spi_begin(bus, cs);
    spi_end(txn);
    return spi_transfer(&txn, 0);
}
