fn main() -> void {
    let x: u32 = 1;
    let y: u32 = x + 2;
    return;
}

type Uart = u32;

extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;

fn hot_sum(xs: []const u32) -> u32 {
    var sum: u32 = 0;

    #[unsafe_contract(no_overflow)]
    {
        for x in xs {
            sum = unchecked.add(sum, x);
        }
    }

    return sum;
}
