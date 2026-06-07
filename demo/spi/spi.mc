// demo/spi — a bus transaction as a linear resource.
//
// `spi_begin` asserts chip-select and returns a `SpiTransaction`; bytes are
// exchanged only while it is held, and `spi_end` deasserts CS and consumes it.
// Because the transaction is a `move` handle, the compiler rejects:
//   - leaving CS asserted (forgetting spi_end → E_RESOURCE_LEAK)
//   - transferring after the transaction ended (use-after-move)
//   - overlapping two transactions that forget to close.

move struct SpiTransaction { bus: u32, cs: u32 }

extern fn mc_spi_begin(bus: u32, cs: u32) -> SpiTransaction; // assert CS
extern fn mc_spi_transfer(t: *SpiTransaction, out: u8) -> u8; // exchange one byte (borrow)
extern fn mc_spi_end(t: SpiTransaction) -> void;             // deassert CS (consume)

export fn spi_begin(bus: u32, cs: u32) -> SpiTransaction {
    return mc_spi_begin(bus, cs);
}
export fn spi_transfer(t: *SpiTransaction, out: u8) -> u8 {
    return mc_spi_transfer(t, out);
}
export fn spi_end(t: SpiTransaction) -> void {
    mc_spi_end(t);
}

// Read one register over SPI: chip-select is held for the whole command/response
// exchange and released exactly once.
export fn read_reg(bus: u32, cs: u32, reg: u8) -> u8 {
    let txn: SpiTransaction = spi_begin(bus, cs);
    spi_transfer(&txn, reg);             // send the register address
    let value: u8 = spi_transfer(&txn, 0); // clock out the response
    spi_end(txn);                        // release CS (consumes txn)
    return value;
}

// what the types forbid:
//   spi_transfer(&txn, 0) after spi_end(txn)  // E_USE_AFTER_MOVE
//   omitting spi_end(txn)                      // E_RESOURCE_LEAK: CS left asserted
