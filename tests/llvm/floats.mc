global gain: f32 = 1.5;
global bias: f64 = -(0.25);

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

fn fne(a: f64, b: f64) -> bool {
    return a != b;
}

fn fneg(a: f64) -> f64 {
    return -a;
}

fn fliteral(a: f32) -> f32 {
    return a + 2.5;
}

fn flocal(a: f32, b: f32) -> f32 {
    let x: f32 = a + b;
    return x * b;
}

fn fcall(a: f64, b: f64) -> f64 {
    return fmix(a, b, a);
}

fn read_gain() -> f32 {
    return gain;
}

fn read_bias() -> f64 {
    return bias;
}
