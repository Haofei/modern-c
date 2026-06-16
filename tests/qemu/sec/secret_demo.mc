// secret<T> constant-time key material — both-backend differential demo.
//
// A `Secret<u8>` carries a key byte. Arithmetic/bitwise over it stays secret
// (taint propagates), so the compiler forbids using it to drive a branch or an
// array index (those would leak it through timing / the cache). The controlled
// escape is `declassify`/`reveal` inside `unsafe`. This entry returns a u32
// status word; the C and LLVM backends must agree on it.

// Constant-time XOR keystream step: ciphertext = plaintext ^ key, both secret.
fn ct_xor(plain: Secret<u8>, key: Secret<u8>) -> Secret<u8> {
    return plain ^ key;
}

// Constant-time equality of two secret bytes, surfaced as a public 0/1 word.
// The comparison result is itself secret; revealing the single bit is the
// deliberate, audited declassification (e.g. a MAC tag check result).
fn ct_eq_byte(a: Secret<u8>, b: Secret<u8>) -> u8 {
    let same: Secret<bool> = a == b;
    unsafe {
        // reveal the one-bit verdict, not the secret bytes themselves
        if reveal(same) {
            return 1;
        }
    }
    return 0;
}

export fn secret_run() -> u32 {
    var pass: u32 = 1;

    let key: Secret<u8> = 0x5A;
    let plain: Secret<u8> = 0x0F;

    // XOR round-trips: (plain ^ key) ^ key == plain.
    let cipher: Secret<u8> = ct_xor(plain, key);
    let back: Secret<u8> = ct_xor(cipher, key);

    // The recovered byte equals the plaintext (compared in constant time).
    if ct_eq_byte(back, plain) != 1 { pass = 0; }
    // The ciphertext differs from the plaintext (0x0F ^ 0x5A == 0x55).
    if ct_eq_byte(cipher, plain) != 0 { pass = 0; }

    // Declassified arithmetic value matches the hand-computed constant.
    unsafe {
        let revealed: u8 = reveal(cipher);
        if revealed != 0x55 { pass = 0; }
    }

    return pass;
}
