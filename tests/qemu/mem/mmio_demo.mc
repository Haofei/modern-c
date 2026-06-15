import "std/mmio.mc";
import "std/addr.mc";

// Two byte buffers standing in for a device window and CPU memory; on the host the
// MMIO raw load/store address these real globals, so the ordered block copy runs.
global g_dev: [16]u8;
global g_cpu: [16]u8;
global g_regs: [4]u32;

export fn mmio_run() -> u32 {
    var pass: u32 = 1;

    // ----- register bit-fields (pure) -----
    // A control register: bits[0]=enable, bits[3:1]=mode (3 bits), bits[11:4]=divisor.
    let enable: RegField = reg_field(0, 1);
    let mode: RegField = reg_field(1, 3);
    let divisor: RegField = reg_field(4, 8);

    if reg_field_mask(mode) != 0x0000_000E { pass = 0; }     // bits 1..3
    if reg_field_mask(divisor) != 0x0000_0FF0 { pass = 0; }  // bits 4..11

    var ctrl: u32 = 0;
    ctrl = reg_field_set(ctrl, enable, 1);
    ctrl = reg_field_set(ctrl, mode, 5);       // 0b101
    ctrl = reg_field_set(ctrl, divisor, 0xAB);
    if reg_field_get(ctrl, enable) != 1 { pass = 0; }
    if reg_field_get(ctrl, mode) != 5 { pass = 0; }
    if reg_field_get(ctrl, divisor) != 0xAB { pass = 0; }

    // overwriting one field leaves the neighbours intact
    ctrl = reg_field_set(ctrl, mode, 2);
    if reg_field_get(ctrl, mode) != 2 { pass = 0; }
    if reg_field_get(ctrl, divisor) != 0xAB { pass = 0; }
    if reg_field_get(ctrl, enable) != 1 { pass = 0; }

    // an over-wide value is masked to the field width (does not bleed upward)
    ctrl = reg_field_set(ctrl, mode, 0xFF);    // only low 3 bits land
    if reg_field_get(ctrl, mode) != 7 { pass = 0; }
    if reg_field_get(ctrl, divisor) != 0xAB { pass = 0; }

    // ----- single-bit helpers -----
    var flags: u32 = 0;
    flags = reg_bit_set(flags, 0);
    flags = reg_bit_set(flags, 31);
    if !reg_bit_test(flags, 0) { pass = 0; }
    if !reg_bit_test(flags, 31) { pass = 0; }
    if reg_bit_test(flags, 1) { pass = 0; }
    flags = reg_bit_clear(flags, 0);
    if reg_bit_test(flags, 0) { pass = 0; }
    flags = reg_bit_toggle(flags, 7);
    if !reg_bit_test(flags, 7) { pass = 0; }
    flags = reg_bit_toggle(flags, 7);
    if reg_bit_test(flags, 7) { pass = 0; }

    // ----- ordered IO-memory block copy -----
    var i: usize = 0;
    while i < 16 { g_cpu[i] = (i + 1) as u8; i = i + 1; }
    let dev: PAddr = pa((&g_dev[0]) as usize);
    let cpu: PAddr = pa((&g_cpu[0]) as usize);

    mmio_write_block(dev, cpu, 16);   // CPU -> device
    if g_dev[0] != 1 { pass = 0; }
    if g_dev[15] != 16 { pass = 0; }

    // read it back into a fresh window and check it round-trips
    g_dev[7] = 0x99;
    let cpu_back: PAddr = pa((&g_cpu[0]) as usize);
    mmio_read_block(cpu_back, dev, 16);  // device -> CPU
    if g_cpu[7] != 0x99 { pass = 0; }
    if g_cpu[0] != 1 { pass = 0; }

    // ----- ordered 32-bit register access + field RMW at a computed address -----
    let r0: PAddr = pa((&g_regs[0]) as usize);
    mmio_write32(r0, 0x1234_5678);
    if mmio_read32(r0) != 0x1234_5678 { pass = 0; }

    // flip just the `divisor` field of the live register word
    mmio_modify_field(r0, divisor, 0x42);
    let after: u32 = mmio_read32(r0);
    if reg_field_get(after, divisor) != 0x42 { pass = 0; }
    if reg_field_get(after, enable) != 0 { pass = 0; }      // bit 0 of 0x...5678 is 0
    if (after & 0xFFFF_F00F) != (0x1234_5678 & 0xFFFF_F00F) { pass = 0; }  // other bits unchanged

    // ----- comptime fold: a field built from constants verifies at compile time -----
    comptime {
        assert(reg_field_mask(reg_field(4, 8)) == 0x0000_0FF0);
        assert(reg_field_get(0x0000_0AB0, reg_field(4, 8)) == 0xAB);
        assert(reg_field_set(0, reg_field(1, 3), 5) == 0x0000_000A);
        assert(reg_bit(31) == 0x8000_0000);
    }

    return pass;
}
