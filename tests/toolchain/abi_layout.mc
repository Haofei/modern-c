// Advanced packed/overlay/MMIO ABI golden fixture. Every `comptime { assert(…) }`
// below folds through MC's own layout model (verified by `mcc check`). The companion
// `abi-test.sh` then emits this module to C and `_Static_assert`s the *same* numbers
// against clang's real `sizeof`/`_Alignof`/`offsetof`, proving MC's advanced-ABI layout
// model (nested packed-bits fields, overlay unions, and volatile MMIO register blocks
// with `@offset` padding) agrees with the host C ABI on both backends.

// --- packed bits over two repr widths ---
packed bits Lsr: u8 {
    data_ready: bool,
    tx_empty: bool,
    framing_err: bool,
}

packed bits Ctrl: u16 {
    enable: bool,
    irq: bool,
    loopback: bool,
}

// --- overlay union over mixed widths: size = max field size, align = max field align ---
overlay union Word {
    u: u32,
    bytes: [4]u8,
    half: u16,
}

// --- packed-bits field nested in a struct (Lsr lowers to its u8 repr) ---
extern struct Frame {
    status: Lsr,
    seq: u16,
    payload: [4]u8,
}

// --- overlay union nested in a struct (4-byte aligned body after a 1-byte tag) ---
extern struct Tagged {
    tag: u8,
    body: Word,
}

// --- MMIO register block: volatile fields, a packed-bits register, and `@offset` padding ---
extern mmio struct Uart {
    thr: Reg<u8, .write>,
    lsr: RegBits<u8, Lsr, .read>,
    ctrl: RegBits<u16, Ctrl, .read_write> @offset(2),
    div: Reg<u32, .read_write> @offset(8),
}

// Materialize the overlay union so both backends emit its byte-array representation.
fn pack_word(value: u32) -> Word {
    var w: Word = uninit;
    w.u = value;
    return w;
}

fn first_byte(w: Word) -> u8 {
    return w.bytes[0];
}

fn putc(u: MmioPtr<Uart>, ch: u8) -> void {
    u.thr.write(ch, .release);
}

fn tx_ready(u: MmioPtr<Uart>) -> bool {
    return u.lsr.read(.acquire).tx_empty;
}

fn abi_layout_checks() -> void {
    comptime {
        // packed bits: size is the repr width; each field is one sequential bit.
        assert(sizeof(Lsr) == 1);
        assert(alignof(Lsr) == 1);
        assert(bit_offset(Lsr, .data_ready) == 0);
        assert(bit_offset(Lsr, .tx_empty) == 1);
        assert(bit_offset(Lsr, .framing_err) == 2);
        assert(sizeof(Ctrl) == 2);
        assert(bit_offset(Ctrl, .loopback) == 2);

        // overlay union: size/align are the max over fields; all fields start at byte 0.
        assert(sizeof(Word) == 4);
        assert(alignof(Word) == 4);
        assert(field_offset(Word, .u) == 0);
        assert(field_offset(Word, .bytes) == 0);
        assert(field_offset(Word, .half) == 0);

        // nested packed-bits field in a struct: u8 status, u16 seq (2-aligned), [4]u8.
        assert(sizeof(Frame) == 8);
        assert(alignof(Frame) == 2);
        assert(field_offset(Frame, .status) == 0);
        assert(field_offset(Frame, .seq) == 2);
        assert(field_offset(Frame, .payload) == 4);

        // overlay nested in a struct: 1-byte tag, then the 4-aligned overlay body.
        assert(sizeof(Tagged) == 8);
        assert(alignof(Tagged) == 4);
        assert(field_offset(Tagged, .body) == 4);

        // MMIO register block: `@offset` padding lands ctrl at 2 and div at 8.
        assert(sizeof(Uart) == 12);
        assert(field_offset(Uart, .ctrl) == 2);
        assert(field_offset(Uart, .div) == 8);
    }
}
