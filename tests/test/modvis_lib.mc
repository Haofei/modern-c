// A module that opts into visibility by marking its public surface with `pub`. Because at
// least one declaration is `pub`, this file is "strict": its non-`pub` items
// (`secret_double`, `internal_sum`) are private to it and cannot be referenced from an
// importing file (E_PRIVATE_IMPORT). The `pub` API may use the private helpers freely —
// privacy is a cross-file boundary, not a within-file one.

fn secret_double(x: u32) -> u32 {
    return x * 2;
}

pub fn scaled(x: u32) -> u32 {
    return secret_double(x) + 1; // public API over a private helper
}

pub struct Point {
    x: u32,
    y: u32,
}

fn internal_sum(p: Point) -> u32 {
    return p.x + p.y;
}

pub fn point_sum(p: Point) -> u32 {
    return internal_sum(p);
}
