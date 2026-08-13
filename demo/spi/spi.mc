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
extern fn mc_spi_transfer(bus: u32, cs: u32, out: u8) -> u8; // exchange one byte
extern fn mc_spi_end(t: SpiTransaction) -> void;             // deassert CS (consume)

#[mc_abi]
export fn spi_begin(bus: u32, cs: u32) -> SpiTransaction {
    return mc_spi_begin(bus, cs);
}
fn spi_transfer(t: SpiTransaction, out: u8) -> SpiTransaction {
    let _value: u8 = mc_spi_transfer(t.bus, t.cs, out);
    return move t;
}
#[mc_abi]
export fn spi_end(t: SpiTransaction) -> void {
    mc_spi_end(move t);
}

// Read one register over SPI: chip-select is held for the whole command/response
// exchange and released exactly once.
export fn read_reg(bus: u32, cs: u32, reg: u8) -> u8 {
    let txn0: SpiTransaction = spi_begin(bus, cs);
    let txn1: SpiTransaction = spi_transfer(move txn0, reg); // send the register address
    let value: u8 = mc_spi_transfer(txn1.bus, txn1.cs, 0);   // clock out the response
    let txn: SpiTransaction = move txn1;
    spi_end(move txn);                                      // release CS (consumes txn)
    return value;
}

// what the types forbid:
//   spi_transfer(move txn, 0) after spi_end(move txn) // E_USE_AFTER_MOVE
//   omitting spi_end(move txn)                        // E_RESOURCE_LEAK: CS left asserted
