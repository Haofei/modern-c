// Language gap G24: the words `ok`, `err`, `type`, `use`, `open`, `sat`, `wrap`
// are contextual keywords — usable as ordinary identifiers (locals, params,
// struct fields, function names) while still keeping their keyword meaning in
// the positions that need it (Result ctor/pattern, `type` alias + metatype,
// `open enum`, `wrap<T>`/`sat<T>` domains).

// keyword use: `type` as a top-level alias
type Handle = u32;

// keyword use: `open enum`
open enum Mode { A, B }

// freed words as struct field names
struct Bag {
    ok: u32,
    err: u32,
    type: u32,
    use: u32,
    open: u32,
    sat: u32,
    wrap: u32,
}

// freed words as parameter names + as a function name (`use`)
fn use(ok: u32, err: u32, type: u32) -> u32 {
    // freed words as local names
    let open: u32 = ok + err;
    let sat: u32 = type + open;
    let wrap: u32 = sat + 1;
    return wrap;
}

// keyword use: Result ctor `ok(..)`/`err(..)` + switch patterns `ok(v)=>`/`err(e)=>`
fn pick(flag: bool) -> Result<u32, u32> {
    if (flag) { return ok(10); }
    return err(4);
}

fn drain(flag: bool) -> u32 {
    let r = pick(flag);
    switch r {
        ok(v) => { return v; }
        err(e) => { return e; }
    }
}

// keyword use: `wrap<T>` / `sat<T>` arithmetic domains, with a local named `wrap`/`sat`
fn domains(a: wrap<u32>, b: sat<u32>) -> u32 {
    let wrap: wrap<u32> = a + a;
    let sat: sat<u32> = b + b;
    return (wrap as u32) + (sat as u32);
}

export fn g24_run() -> u32 {
    let bag: Bag = .{ .ok = 1, .err = 2, .type = 3, .use = 4, .open = 5, .sat = 6, .wrap = 7 };
    // call the freed-word-named function `use` (no local shadows it)
    let blended: u32 = use(bag.ok, bag.err, bag.type);
    let ok: u32 = drain(true) + drain(false);
    let err: u32 = domains(20, 30);
    let wrap: u32 = bag.use + bag.open + bag.sat + bag.wrap;
    // blended=7, ok=14, err=100, wrap=22 -> 143. Entry-mode contract: return 1 on success.
    let total: u32 = blended + ok + err + wrap;
    if (total == 143) { return 1; }
    return 0;
}
