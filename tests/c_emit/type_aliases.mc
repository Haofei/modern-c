type Count = u32;
type HashWord = wrap<u32>;
type Level = sat<u8>;
type BytePtr = *mut u8;
type MaybeBytePtr = ?*mut u8;
type RawBytes = [*]mut u8;
type Counts = [4]Count;

packed bits Flags: u8 {
    ready: bool,
    busy: bool,
}

type FlagAlias = Flags;

global total: Count = 0;
global counters: Counts = .{ 1, 2, 3, 4 };
global default_flags: FlagAlias = .{ .ready = true, .busy = false };

fn accept_alias_param_return(value: Count) -> Count {
    let local: Count = value;
    return local;
}

fn accept_alias_checked_arithmetic(a: Count, b: Count) -> Count {
    return a + b;
}

fn accept_wrap_alias(a: HashWord, b: HashWord) -> HashWord {
    return a + b;
}

fn accept_sat_alias(a: Level, b: Level) -> Level {
    return a + b;
}

fn accept_pointer_alias(p: BytePtr) -> MaybeBytePtr {
    let q: BytePtr = p;
    return q;
}

fn accept_raw_alias(p: RawBytes, i: usize) -> RawBytes {
    unsafe {
        return p.offset(i);
    }
}

fn accept_array_alias(xs: Counts, i: usize) -> Count {
    return xs[i];
}

fn accept_packed_alias(flags: FlagAlias) -> bool {
    return flags.ready;
}
