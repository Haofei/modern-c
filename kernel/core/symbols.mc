// kernel/core/symbols — a sorted kernel symbol table for symbolizing addresses
// (the symbolization half of a backtrace: turning a raw return address into
// "function + offset").
//
// Entries are function start addresses kept in increasing order; `symbolize` binary-
// searches for the function containing a PC and reports its index + the byte offset
// of the PC into it. Lookups below the first symbol fail with a typed error rather
// than aliasing to symbol 0.

const MAX_SYMS: usize = 64;

struct Symbol {
    addr: u64,
    id: u32, // caller's handle for the name (index into its own name table)
}

struct SymbolTable {
    syms: [MAX_SYMS]Symbol,
    count: usize,
}

enum SymError {
    BelowFirst, // pc precedes every known symbol
    Full,       // table is full
    Unsorted,   // an entry was added out of order
}

struct SymHit {
    index: usize,
    offset: u64, // pc - symbol.addr
}

export fn symtab_init(t: *mut SymbolTable) -> void {
    t.count = 0;
}

// Append a symbol. Entries must arrive in non-decreasing address order (as a linker
// emits them); out-of-order or overflow is a typed error, not silent corruption.
export fn symtab_add(t: *mut SymbolTable, addr: u64, id: u32) -> Result<usize, SymError> {
    let n: usize = t.count;
    if n >= MAX_SYMS {
        return err(.Full);
    }
    if n > 0 {
        let prev: u64 = t.syms[n - 1].addr;
        if addr < prev {
            return err(.Unsorted);
        }
    }
    t.syms[n].addr = addr;
    t.syms[n].id = id;
    t.count = n + 1;
    return ok(n);
}

// Find the function containing `pc`: the symbol with the greatest address <= pc.
export fn symbolize(t: *SymbolTable, pc: u64) -> Result<SymHit, SymError> {
    if t.count == 0 {
        return err(.BelowFirst);
    }
    let first: u64 = t.syms[0].addr;
    if pc < first {
        return err(.BelowFirst);
    }
    // Greatest index whose addr <= pc (the table is sorted ascending).
    var lo: usize = 0;
    var hi: usize = t.count; // exclusive
    while (lo + 1) < hi {
        let mid: usize = (lo + hi) / 2;
        let a: u64 = t.syms[mid].addr;
        if a <= pc {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let base: u64 = t.syms[lo].addr;
    return ok(.{ .index = lo, .offset = pc - base });
}

// The caller's name handle for a symbol index (after a successful symbolize).
export fn symtab_id(t: *SymbolTable, index: usize) -> u32 {
    return t.syms[index].id;
}
