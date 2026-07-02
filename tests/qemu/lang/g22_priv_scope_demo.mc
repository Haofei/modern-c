// G22 (§30 file-private name uniquification): two imported strict files each define a
// FILE-PRIVATE `fn advance` with DIFFERENT signatures. The loader flattens both into one
// unit; pre-G22 this was E_DUPLICATE_DECLARATION. Post-G22 each `advance` is file-locally
// resolved and gets a per-file-unique mangled symbol in BOTH backends, so each file's public
// entry calls ITS OWN `advance`.
//
// a_step(3)    = advance_A(3)    = 3 + 100      = 103
// b_step(4, 5) = advance_B(4, 5) = 4 * 5 + 7    = 27
// A wrong binding would either mis-count arguments (compile error) or yield a wrong value.
import "g22_priv_a.mc";
import "g22_priv_b.mc";

export fn g22_priv_scope_run() -> u32 {
    let ra: u32 = a_step(3);
    let rb: u32 = b_step(4, 5);
    if ra == 103 && rb == 27 {
        return 1;
    }
    return 0;
}
