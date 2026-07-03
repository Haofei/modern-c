// SPEC: section=30
// SPEC: milestone=file-private-name-uniquification
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_PRIVATE_IMPORT

import "../spec_support/private_import_lib.mc";

export fn run() -> u32 {
    return private_import_secret(5); // EXPECT_ERROR: E_PRIVATE_IMPORT
}
