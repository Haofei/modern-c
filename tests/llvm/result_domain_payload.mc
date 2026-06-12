enum ResolveError {
    Stale,
}

fn stale_addr() -> Result<PAddr, ResolveError> {
    return err(.Stale);
}

fn ok_addr(addr: PAddr) -> Result<PAddr, ResolveError> {
    return ok(addr);
}
