// Differential fixture for language gaps G25 and G27, both about reading an enum's
// integer ordinal (`.raw()`).
//
// G25 — `.raw()` and switch-exhaustiveness are no longer mutually exclusive. A CLOSED
// enum's `switch` is exhaustiveness-checked (no `_`), and it now ALSO admits `.raw()`
// and the enum -> integer `as` cast. Reading the ordinal out can never mint an
// out-of-range enum value, so it cannot break the closed invariant (only the REVERSE,
// int -> enum, still requires an `open` enum). So a closed enum gets BOTH an exhaustive
// `switch` AND ordinal access — this fixture proves that tension is resolved.
//
// G27 — `.raw()` on a variant-path literal `Enum.variant.raw()` yields the case's
// ordinal constant, for both open and closed enums.
//
// Enums are transparent-repr, so a closed-enum `.raw()`/`as` and a variant-path
// `.raw()` must emit exactly what an open-enum `.raw()` does; entry mode diffs the C
// and LLVM return of the single `_run` entry to pin both backends agree.

// A CLOSED enum (no `open`): its `switch` is exhaustiveness-checked.
enum Color: u32 {
    red = 0,
    green = 10,
    blue = 20,
}

open enum OpenTag: u8 {
    lo = 1,
    hi = 2,
}

// closed-enum `.raw()` on a param.
fn color_raw(c: Color) -> u32 {
    return c.raw();
}

// closed-enum enum -> integer `as` cast (the same read as `.raw()`).
fn color_as_int(c: Color) -> u32 {
    return c as u32;
}

// closed-enum EXHAUSTIVE switch (no `_`) living in the SAME program as `.raw()`:
// exhaustiveness is still enforced, and the arms cover every case.
fn color_index(c: Color) -> u32 {
    switch c {
        .red => { return 0; }
        .green => { return 1; }
        .blue => { return 2; }
    }
}

// G27: variant-path `.raw()` on a CLOSED enum -> the case's ordinal constant.
fn blue_ordinal() -> u32 {
    return Color.blue.raw();
}

// G27: variant-path `.raw()` on an OPEN enum.
fn open_hi_ordinal() -> u8 {
    return OpenTag.hi.raw();
}

export fn enum_raw_closed_run() -> u32 {
    var acc: u32 = 0;

    // closed-enum `.raw()` reads the declared repr value.
    if color_raw(.red) == 0 { acc = acc | 0x001; }
    if color_raw(.green) == 10 { acc = acc | 0x002; }
    if color_raw(.blue) == 20 { acc = acc | 0x004; }

    // closed-enum `as` cast agrees with `.raw()`.
    if color_as_int(.green) == 10 { acc = acc | 0x008; }
    if color_as_int(.blue) == color_raw(.blue) { acc = acc | 0x010; }

    // exhaustive switch maps each case to its index.
    if color_index(.red) == 0 { acc = acc | 0x020; }
    if color_index(.green) == 1 { acc = acc | 0x040; }
    if color_index(.blue) == 2 { acc = acc | 0x080; }

    // variant-path `.raw()` yields the case's ordinal constant.
    if blue_ordinal() == 20 { acc = acc | 0x100; }
    if open_hi_ordinal() == 2 { acc = acc | 0x200; }

    // entry-mode contract: 1 = pass, 0 = fail. All ten bits must be set.
    if acc != 0x3FF { return 0; }
    return 1;
}
