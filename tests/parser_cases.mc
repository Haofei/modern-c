// Parser fixture for the initial MC AST/parser slice.
// Cases are source-level examples; the current parser consumes tokens from a
// future lexer and does not include a lexer implementation.

extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
extern "C" fn strlen(s: cstr) -> usize;

extern struct Timespec {
    sec: i64,
    nsec: i64,
}

type Bytes = []mut u8;
type LoadResult = Result<Module, LoadError>;

#[no_lang_trap]
fn boot_entry() -> never {
    return trap(.Unreachable);
}

const fn align_up(x: usize, a: usize) -> usize {
    return (x + a - 1) & ~(a - 1);
}

fn load_module(path: []const u8) -> Result<Module, LoadError> {
    let file = fs.open(path)?;
    defer file.close();

    let image = alloc.read_all(file)?;
    defer alloc.free(image);

    let module = parse_module(image)?;
    return ok(module);
}

fn copy_from_uart(pa: PAddr, len: usize) -> Result<usize, Error> {
    var tmp: [256]u8 = uninit;
    let n = min(len, tmp.len);

    unsafe {
        let uart = mmio.map<Uart16550>(phys(0x1000_0000))?;
        let lsr = uart.raw_lsr.read(.acquire);
        raw.store<u64>(pa.residue(), lsr);
    }

    return ok(n);
}

fn optional_and_result(maybe: ?*mut Node, result: Result<u32, Error>) -> u32 {
    if let p = maybe {
        return p.value;
    } else {
        if let ok(v) = result {
            return v;
        }
    }

    return 0;
}

fn classify(status: Status) -> u32 {
    switch status {
        .ready => 1,
        ok(v) => v + 1,
        err(e) => {
            log(e);
            return 0;
        },
        _ => 0,
    }
}

fn checked_and_contract(xs: []const u32) -> u32 {
    var sum: u32 = 0;

    #[unsafe_contract(no_overflow)]
    {
        sum = unchecked.add(sum, xs[0]);
    }

    let masked = (sum & 0xff_u32) << 1;
    return masked / 2;
}
