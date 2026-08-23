extern fn transform(value: u32) -> u32;

fn local_pipeline(a: u32, b: u32) -> u32 {
    let left: u32 = transform(a);
    let right: u32 = transform(b);
    let mixed: u32 = left ^ right;
    return mixed;
}
