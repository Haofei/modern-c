// SPEC: section=0
// SPEC: milestone=import-loader-diagnostics
// SPEC: phase=parse
// SPEC: expect=compile_error
// SPEC: check=E_IMPORT_NOT_FOUND

import "missing/import_not_found_fixture.mc"; // EXPECT_ERROR: E_IMPORT_NOT_FOUND
