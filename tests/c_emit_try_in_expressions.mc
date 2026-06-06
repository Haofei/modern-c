// `?` nested inside other expressions. Previously only a few shapes lowered;
// these exercise: `?` unwrap in a typed local of a non-Result function (trap on
// err), `?` inside a Result constructor argument (ok(a?) / ok(f(a?))), and two
// `?` operands inside one checked-arithmetic constructor argument.

struct Error { code: u32 }
extern fn make_result_u32() -> Result<u32, Error>;
extern fn dbl(x: u32) -> u32;

// `?` as a typed-local initializer in a u32-returning function: the operand is
// unwrapped, trapping on err (the function cannot propagate).
fn unwrap_into_local() -> u32 {
    let a = make_result_u32();
    let v: u32 = a?;
    return v + 1;
}

// `?` inside an ok(...) constructor argument: propagates err, then re-wraps.
fn try_in_constructor() -> Result<u32, Error> {
    let a = make_result_u32();
    return ok(a?);
}

// `?` inside a call inside a constructor argument.
fn try_in_nested_call() -> Result<u32, Error> {
    let a = make_result_u32();
    return ok(dbl(a?));
}

// Two `?` operands inside one checked-add constructor argument: both hoisted.
fn two_tries_in_arith() -> Result<u32, Error> {
    let a = make_result_u32();
    let b = make_result_u32();
    return ok(a? + b?);
}
