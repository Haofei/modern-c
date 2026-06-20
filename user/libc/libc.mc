// user/libc/libc — the single-compilation-unit aggregator for the all-MC freestanding libc.
// MC compiles one object per root file (imports flatten + dedupe within the unit), so the whole
// libc must be ONE unit to avoid cross-object duplicate definitions of shared std/* helpers.
import "user/libc/alloc.mc";
import "user/libc/cstr.mc";
import "user/libc/cnum.mc";
import "user/libc/stdio.mc";
