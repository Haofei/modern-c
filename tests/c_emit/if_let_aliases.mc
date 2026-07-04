type MaybeU32 = ?u32;
type MyResult = Result<u32, u32>;

extern fn maybe() -> MaybeU32;
extern fn make_result() -> MyResult;

export fn alias_nullable_iflet() -> u32 {
    if let v = maybe() {
        return v;
    }
    return 0;
}

export fn alias_result_iflet() -> u32 {
    if let ok(v) = make_result() {
        return v;
    }
    return 0;
}
