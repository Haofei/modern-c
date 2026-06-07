// Imports the generic `std/stack` collection and exercises it at a concrete
// type, exporting a wrapper the stack-test driver calls.
import "std/stack.mc";

export fn stack_top_two_sum(a: u32, b: u32, c: u32) -> u32 {
    var s: Stack<u32> = uninit;
    s.len = 0;
    let s1: Stack<u32> = push(u32, s, a);
    let s2: Stack<u32> = push(u32, s1, b);
    let s3: Stack<u32> = push(u32, s2, c);
    // get(s3, 1) + get(s3, 2) == b + c ; plus the length (3).
    return get(u32, s3, 1) + get(u32, s3, 2) + len(u32, s3) as u32;
}
