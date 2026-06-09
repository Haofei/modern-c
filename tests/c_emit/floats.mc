fn fadd(a: f32, b: f32) -> f32 {
    return a + b;
}

fn fsub(a: f64, b: f64) -> f64 {
    return a - b;
}

fn fmul(a: f32, b: f32) -> f32 {
    return a * b;
}

fn fdiv(a: f64, b: f64) -> f64 {
    return a / b;
}

fn fmix(a: f64, b: f64, c: f64) -> f64 {
    return a * b + c;
}

fn fcmp(a: f32, b: f32) -> bool {
    return a < b;
}

fn feq(a: f64, b: f64) -> bool {
    return a == b;
}

fn fneg(a: f64) -> f64 {
    return -a;
}

fn flocal(a: f32, b: f32) -> f32 {
    let x: f32 = a + b;
    return x * b;
}

fn fcall(a: f64, b: f64) -> f64 {
    return fmix(a, b, a);
}
