// SPEC: section=13
// SPEC: milestone=enum-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_ENUM_CASE,E_ENUM_REPR_NOT_INTEGER

enum OpenError {
    not_found,
    denied,
    bad_path,
}

enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    error = 2,
}

enum RejectDuplicateEnumCase: u8 {
    ready = 1,
    // EXPECT_ERROR: E_DUPLICATE_ENUM_CASE
    ready = 2,
}

// EXPECT_ERROR: E_ENUM_REPR_NOT_INTEGER
enum RejectBoolRepresentation: bool {
    yes = 1,
}
