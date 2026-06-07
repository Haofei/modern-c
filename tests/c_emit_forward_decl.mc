// A function may call another that is defined later in the (possibly
// import-merged) source. The C backend forward-declares every defined function
// up front so such calls resolve under clang -Werror, regardless of order.

fn caller(x: u32) -> u32 {
    return callee(x) + 1;
}

fn callee(x: u32) -> u32 {
    return x + x;
}

export fn exported_caller(x: u32) -> u32 {
    return helper(x);
}

fn helper(x: u32) -> u32 {
    return x + 7;
}
