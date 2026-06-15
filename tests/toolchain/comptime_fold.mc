// Check-only comptime fold coverage (section 22) for constructs that are comptime-only and
// not lowerable as runtime code (so they cannot live in the emit-swept tests/spec): byte
// strings and wrap/sat arithmetic domains. The companion `comptime-fold-test.sh` runs
// `mcc check` and asserts EXACTLY the intended number of E_COMPTIME_TRAP — so a skipped fold
// (a should-trap assert that doesn't) or a wrong value (a should-pass assert that does)
// both fail the gate.

const fn wrap_add(a: wrap<u8>, b: wrap<u8>) -> u8 { return (a + b) as u8; }
const fn sat_add(a: sat<u8>, b: sat<u8>) -> u8 { return (a + b) as u8; }

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
    }
}

// --- the script counts these: exactly four FALSE asserts must each trap ---
fn reject_four_false_folds() -> void {
    comptime {
        assert("abcd".len == 99);                // FALSE-TRAP (real value 4)
        assert("abc"[0] == 99);                  // FALSE-TRAP (real value 97)
        assert(wrap_add(200, 100) == 99);        // FALSE-TRAP (real value 44)
        assert(sat_add(200, 100) == 99);         // FALSE-TRAP (real value 255)
    }
}
