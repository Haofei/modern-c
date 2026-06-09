// Test wrappers around the symbol table for the host driver.

import "kernel/core/symbols.mc";

global g_symtab: SymbolTable;

export fn st_init() -> void {
    symtab_init(&g_symtab);
}

// Returns 1 on success, 0 on a typed error (full / unsorted).
export fn st_add(addr: u64, id: u32) -> u32 {
    switch symtab_add(&g_symtab, addr, id) {
        ok(i) => {
            return 1;
        }
        err(e) => {
            return 0;
        }
    }
}

export fn st_index(pc: u64) -> u64 {
    switch symbolize(&g_symtab, pc) {
        ok(hit) => {
            return hit.index as u64;
        }
        err(e) => {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
    }
}

export fn st_offset(pc: u64) -> u64 {
    switch symbolize(&g_symtab, pc) {
        ok(hit) => {
            return hit.offset;
        }
        err(e) => {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
    }
}

export fn st_id(pc: u64) -> u64 {
    switch symbolize(&g_symtab, pc) {
        ok(hit) => {
            return symtab_id(&g_symtab, hit.index) as u64;
        }
        err(e) => {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
    }
}
