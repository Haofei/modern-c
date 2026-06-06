// `Result<void, E>` is a valid marker result (`return ok(())`). C has no void
// struct member, so the void payload lowers to a 1-byte placeholder.

struct Error { code: u32 }

fn ok_marker() -> Result<void, Error> {
    return ok(());
}

fn err_marker(e: Error) -> Result<void, Error> {
    return err(e);
}
