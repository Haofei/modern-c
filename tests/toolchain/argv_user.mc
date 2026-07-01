// Gate program for Phase 0.4 hosted argv access. Imports the opt-in
// `std/hosted_args` and exports `mc_main` (the entry the C shim
// `tools/toolchain/hosted_args_rt.c` calls after stashing argc/argv).
//
// It exercises the whole surface deterministically, avoiding argv[0] (whose
// value is the nondeterministic program path):
//   * argument count (must be exactly 3: program + two known args),
//   * exact-string match of arg 1 and arg 2 (byte-checked view + arg_eq),
//   * bounds-checked byte read (arg_byte) and length accounting.
// On any mismatch it returns a distinct non-zero code; on full success it
// returns the summed lengths of args 1..argc (5 + 2 = 7), which the argv-test
// script asserts as the process exit code.
import "std/hosted_args.mc";

export fn mc_main() -> i32 {
    if args_count() != 3 {
        return 101; // wrong argc (expected: program name + "hello" + "wo")
    }
    if !arg_eq(1, "hello") {
        return 102; // arg 1 did not match the expected string
    }
    if !arg_eq(2, "wo") {
        return 103; // arg 2 did not match the expected string
    }
    // Bounds-checked single-byte read: first byte of arg 1 must be 'h' (104).
    if arg_byte(1, 0) != 104 {
        return 104;
    }
    // Sum the lengths of the real arguments (skip argv[0]'s nondeterministic path).
    var total: usize = 0;
    var i: i32 = 1;
    while i < args_count() {
        total = total + arg_len(i);
        i = i + 1;
    }
    return total as i32; // 5 ("hello") + 2 ("wo") = 7
}
