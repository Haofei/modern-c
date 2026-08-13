// user/libc/libc — the single-compilation-unit aggregator for retained MC stdio validation.
// MC compiles one object per root file (imports flatten + dedupe within the unit), so the whole
// validation libc is kept as ONE unit to avoid cross-object duplicate definitions of shared helpers.
import "user/libc/cstr.mc";
import "user/libc/cnum.mc";
import "user/libc/stdio.mc";
