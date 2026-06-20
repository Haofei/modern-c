// Negative fixture: an importer that reaches for a PRIVATE item of a strict module.
// `secret_double` has no `pub` in modvis_lib, so this cross-file reference must be rejected
// with E_PRIVATE_IMPORT. Driven by tools/test/module-visibility-test.sh (expects failure).

import "modvis_lib.mc";

export fn run() -> u32 {
    return secret_double(5); // E_PRIVATE_IMPORT: private to modvis_lib
}
