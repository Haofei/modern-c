// Check-only comptime fold coverage (section 22) for constructs that are comptime-only and
// not lowerable as runtime code (so they cannot live in the emit-swept tests/spec): byte
// strings and wrap/sat arithmetic domains. The companion `comptime-fold-test.sh` runs
// `mcc check` and asserts EXACTLY the intended number of E_COMPTIME_TRAP — so a skipped fold
// (a should-trap assert that doesn't) or a wrong value (a should-pass assert that does)
// both fail the gate.

const fn wrap_add(a: wrap<u8>, b: wrap<u8>) -> u8 { return (a + b) as u8; }
const fn sat_add(a: sat<u8>, b: sat<u8>) -> u8 { return (a + b) as u8; }
const F32_EDGE: f32 = 16777216.0;
const F32_ONE: f32 = 1.0;
const F32_RESULT: f32 = (F32_EDGE + F32_ONE) - F32_EDGE;
const GLOBAL_WRAP: wrap<u8> = 255;
const GLOBAL_SAT: sat<u8> = 255;
const fn global_wrap_add() -> u8 { return (GLOBAL_WRAP + (1 as wrap<u8>)) as u8; }
const fn global_sat_add() -> u8 { return (GLOBAL_SAT + (1 as sat<u8>)) as u8; }

// --- accepted: every assert is TRUE, so a correct fold produces no diagnostic ---
fn accept_true_folds() -> void {
    comptime {
        // byte strings: a string literal's `.len` and byte indexing fold directly
        assert("abcd".len == 4);
        assert("abc"[0] == 97);
        assert("abc"[2] == 99);
        // wrap<u8>: 300 mod 256 == 44
        assert(wrap_add(200, 100) == 44);
        // sat<u8>: clamp to 255
        assert(sat_add(200, 100) == 255);
        // no-overflow is the plain sum
        assert(wrap_add(10, 20) == 30);
        assert(sat_add(10, 20) == 30);
        // IEEE division is nontrapping and f32 rounds after each operation.
        let one: f64 = 1.0;
        let zero: f64 = 0.0;
        assert(one / zero == inf);
        assert(F32_RESULT == 0.0);
        assert(global_wrap_add() == 0);
        assert(global_sat_add() == 255);
        // Same-width signed/unsigned bitcasts preserve all 128 bits.
        let negative_one: i128 = -1;
        let all_ones: u128 = bitcast<u128>(negative_one);
        assert(all_ones == 340282366920938463463374607431768211455);
    }
}

// --- the script counts these: every FALSE assert / checked operation must trap ---
fn reject_false_folds() -> void {
    comptime {
        assert("abcd".len == 99);                // FALSE-TRAP (real value 4)
        assert("abc"[0] == 99);                  // FALSE-TRAP (real value 97)
        assert(wrap_add(200, 100) == 99);        // FALSE-TRAP (real value 44)
        assert(sat_add(200, 100) == 99);         // FALSE-TRAP (real value 255)
        assert(F32_RESULT == 1.0);                // FALSE-TRAP (per-step f32 result 0)
        assert(((GLOBAL_WRAP + (1 as wrap<u8>)) as u8) == 255); // FALSE-TRAP (real value 0)
        assert(((GLOBAL_SAT + (1 as sat<u8>)) as u8) == 0); // FALSE-TRAP (real value 255)
        assert(global_wrap_add() == 255);           // FALSE-TRAP through const-fn scope
        assert(global_sat_add() == 0);             // FALSE-TRAP through const-fn scope
        let wide: wrap<u128> = 340282366920938463463374607431768211455;
        assert(((wide + (1 as wrap<u128>)) as u128) == 123); // FALSE-TRAP (real value 0)
        let negative_one: i128 = -1;
        assert(bitcast<u128>(negative_one) == 0); // FALSE-TRAP (real value u128::MAX)
    }
}

fn reject_checked_width_operations() -> void {
    comptime {
        let one: u8 = 1;
        let invalid_shift: u8 = one << 8;        // TRAP: count equals declared width
    }
}

fn reject_checked_min_negation() -> void {
    comptime {
        let minimum: i8 = -128;
        let invalid_negation: i8 = -minimum;     // TRAP: checked i8 minimum
    }
}
