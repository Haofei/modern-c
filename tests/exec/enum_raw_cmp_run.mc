// Runtime proof (G23) that a value-producing comparison over an enum `.raw()` operand
// — `enum.raw() == N` in a typed `let bool` and in a `return` — emits and executes
// correctly on BOTH backends. The C backend previously failed such value contexts with
// UnsupportedCEmission because the comparison-operand type recovery could not resolve the
// `.raw()` call's repr integer type (it only worked inside an `if` condition). LLVM
// already handled it; this fixture keeps the backends in lockstep.

open enum Color: u32 {
    red,    // 0
    green,  // 1
    blue,   // 2
}

// A CLOSED enum: `.raw()` is legal (default u32 repr) but the value-context compare was the real
// residual on master (the C emitter hit UnsupportedCEmission recovering the closed-enum `.raw()`
// operand type). Guard it here so the fix cannot regress.
enum Tag {
    a,      // 0
    b,      // 1
    c,      // 2
}

fn tag_is_b_let(t: Tag) -> bool {
    let r: bool = t.raw() == 1;
    return r;
}

fn tag_is_c_return(t: Tag) -> bool {
    return t.raw() == 2;
}

// `.raw()` operand in a typed `let bool =` value context.
fn is_green_let(k: Color) -> bool {
    let r: bool = k.raw() == 1;
    return r;
}

// `.raw()` operand in a `return <cmp>` value context.
fn is_blue_return(k: Color) -> bool {
    return k.raw() == 2;
}

export fn run() -> u32 {
    let red: Color = .red;
    let green: Color = .green;
    let blue: Color = .blue;
    var sum: u32 = 0;
    if is_green_let(green) { sum = sum + 1; }      // 1.raw()==1 -> true  (+1)
    if is_green_let(red) { sum = sum + 100; }      // 0.raw()==1 -> false
    if is_blue_return(blue) { sum = sum + 10; }    // 2.raw()==2 -> true  (+10)
    if is_blue_return(red) { sum = sum + 1000; }   // 0.raw()==2 -> false
    // Closed-enum cases (the real master residual):
    let tb: Tag = .b;
    let tc: Tag = .c;
    let ta: Tag = .a;
    if tag_is_b_let(tb) { sum = sum + 4; }         // 1.raw()==1 -> true  (+4)
    if tag_is_b_let(ta) { sum = sum + 400; }       // 0.raw()==1 -> false
    if tag_is_c_return(tc) { sum = sum + 40; }     // 2.raw()==2 -> true  (+40)
    if tag_is_c_return(ta) { sum = sum + 4000; }   // 0.raw()==2 -> false
    return sum;                                    // expect 11 + 44 = 55
}
