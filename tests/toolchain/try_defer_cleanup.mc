// Regression for review issue #3: a `defer` must run on the error branch of `?`,
// not only on the success path. `bump()` (defined in the C driver) records that the
// deferred cleanup actually ran; `fail()` returns Err so the `?` takes its error edge
// and propagates out of `try_path`. `run_try_defer` returns 7 on that error path.
//
// The driver asserts the propagated value is 7 AND that `bump` ran exactly once — which
// only holds if the backend routes `?` propagation through the defer cleanup path.

enum E { Bad }

extern fn bump() -> void;

fn fail() -> Result<u32, E> {
    return err(.Bad);
}

fn try_path() -> Result<u32, E> {
    defer bump();          // must run on the `?` error branch below
    let x: u32 = fail()?;  // takes the error edge -> defer must fire before returning
    return ok(x);
}

export fn run_try_defer() -> u32 {
    switch try_path() {
        ok(v) => {
            return v;
        }
        err(e) => {
            return 7; // error was propagated out of try_path
        }
    }
}
