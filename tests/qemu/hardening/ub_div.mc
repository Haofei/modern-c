// UB class: division by zero, and INT_MIN / -1 (signed division overflow).  MC handling:
// CHECKED + TRAP — `i32 /` and `i32 %` lower to mc_checked_div_i32 / mc_checked_mod_i32,
// which trap (mc_trap_DivideByZero) when the divisor is 0 and (mc_trap_IntegerOverflow)
// when a == INT_MIN && b == -1.  This fixture divides only in the defined range; the two
// trapping cases (÷0 and INT_MIN/-1) are shown in the matrix, not exercised here.
export fn ub_div_run() -> u32 {
    var pass: u32 = 1;
    let a: i32 = -2147483648;   // INT32_MIN
    let b: i32 = 2;
    if a / b != -1073741824 { pass = 0; }   // INT_MIN / 2: defined, no trap
    if a % b != 0 { pass = 0; }
    let c: i32 = -2147483648;
    if c / -2 != 1073741824 { pass = 0; }   // INT_MIN / -2: in range (only /-1 traps)
    let p: i32 = 7;
    let q: i32 = 3;
    if p / q != 2 { pass = 0; }
    if p % q != 1 { pass = 0; }
    return pass;
}
