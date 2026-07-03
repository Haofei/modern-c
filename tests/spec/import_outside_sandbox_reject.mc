// SPEC: section=0
// SPEC: milestone=import-loader-diagnostics
// SPEC: phase=parse
// SPEC: expect=compile_error
// SPEC: check=E_IMPORT_OUTSIDE_SANDBOX

import "/tmp/modern-c-import-outside-sandbox-fixture.mc"; // EXPECT_ERROR: E_IMPORT_OUTSIDE_SANDBOX
