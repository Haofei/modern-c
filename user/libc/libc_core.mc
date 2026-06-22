// user/libc/libc_core — the stdio-free core of the freestanding libc: the C-ABI heap allocator
// (malloc/free/calloc/realloc) + the mem/string core (memcpy/memmove/memset/memcmp/strlen/…), as
// ONE compilation unit (MC flattens + dedupes imports within a unit, so a single root avoids
// cross-object duplicate definitions of the shared std/* helpers).
//
// This is the exact surface the old C `user/libc/libc.c` provided, now in pure MC. It is the right
// libc for a confined C app that reports via raw `SYS_WRITE` (from the crt0/ecall shim) and needs
// no formatted output: the full `libc.mc` additionally imports `stdio.mc`, whose formatter needs a
// `mc_console_write` host hook that a standalone app (compute/mathtest/transcendental) has no
// provider for. Apps that do want stdio (e.g. the QuickJS host) link `libc.mc` instead.
import "user/libc/alloc.mc";
import "user/libc/cstr.mc";
