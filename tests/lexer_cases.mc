// Representative MC lexer corpus. This file is not a parser test.
#[unsafe_contract(no_overflow)]
extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;

extern mmio struct Uart16550 {
    thr: mmio.Reg<u8, .write_only, 0>,
    lsr: mmio.Reg<RegBits, .read_only, 4>,
}

fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    while !uart.lsr.read(.acquire).tx_empty {
        asm opaque volatile { "pause" clobber("memory") }
    }

    let status = uart.lsr.read(.acquire);
    if (status.raw & 0x20_u8) != 0_u8 {
        uart.thr.write(ch, .release);
    } else {
        trap(.WouldBlock);
    }
}

fn examples(buf: []mut u8, maybe: ?*mut Node, flags: u32) -> Result<u32, Error> {
    let x: u32 = 123_456;
    let y = wrap<u32>.from_mod(0xffff_ffff);
    let range = buf[0..16];
    let ch = 'x';
    let escaped = '\n';
    let text = "mc string with \"quotes\" and \\ escapes";

    if let p = maybe {
        p.* = Node.init(ch, text);
    } else {
        return err(.NotFound);
    }

    switch flags {
        .ok(v) => return ok(v + x),
        .err(e) => return err(e),
        _ => return ok(y.residue() >> 1),
    }

    return ok(range.len);
}

/* block comments are inferred for lexer recovery */
type Cursor = counter<u64>;
