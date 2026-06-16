// SPEC: section=D.4,16
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_SECRET_BRANCH,E_SECRET_INDEX,E_UNSAFE_REQUIRED,E_DECLASSIFY_NOT_SECRET

// secret<T> — a constant-time type for key/crypto material. A secret value (and
// anything derived from it by arithmetic/bitwise propagation) MUST NOT steer a
// branch, a switch, an array index, or a pointer offset: those are timing /
// cache side channels. The only escape is declassify/reveal, behind `unsafe`.

// ---- allowed: constant-time arithmetic / bitwise propagation -----------------

fn accept_secret_xor(plain: Secret<u8>, key: Secret<u8>) -> Secret<u8> {
    return plain ^ key;
}

fn accept_secret_add(a: Secret<u8>, b: Secret<u8>) -> Secret<u8> {
    return a + b;
}

fn accept_secret_mix_public(secret: Secret<u32>, mask: u32) -> Secret<u32> {
    // Mixing a secret with public data stays secret (taint propagates).
    return secret & mask;
}

fn accept_secret_literal_init() -> Secret<u8> {
    let key: Secret<u8> = 0x5A;
    return key;
}

// ---- allowed: declassify / reveal inside unsafe ------------------------------

fn accept_declassify(tag_a: Secret<u8>, tag_b: Secret<u8>) -> u8 {
    let verdict: Secret<bool> = tag_a == tag_b;
    unsafe {
        if reveal(verdict) {
            return 1;
        }
    }
    return 0;
}

fn accept_reveal_value(c: Secret<u8>) -> u8 {
    unsafe {
        return reveal(c);
    }
}

// ---- rejected: secret-dependent branch ---------------------------------------

fn reject_secret_if(secret: Secret<u32>) -> u32 {
    // EXPECT_ERROR: E_SECRET_BRANCH
    if secret != 0 {
        return 1;
    }
    return 0;
}

fn reject_secret_switch(secret: Secret<u8>) -> u32 {
    // EXPECT_ERROR: E_SECRET_BRANCH
    switch secret {
        _ => { return 0; }
    }
}

fn reject_secret_while(secret: Secret<u32>) -> u32 {
    // EXPECT_ERROR: E_SECRET_BRANCH
    while secret != 0 {
        return 1;
    }
    return 0;
}

// ---- rejected: secret-dependent memory access --------------------------------

fn reject_secret_array_index(table: [256]u8, secret: Secret<usize>) -> u8 {
    // EXPECT_ERROR: E_SECRET_INDEX
    return table[secret];
}

fn reject_secret_slice_index(table: []const u8, secret: Secret<usize>) -> u8 {
    // EXPECT_ERROR: E_SECRET_INDEX
    return table[secret];
}

// ---- rejected: declassify discipline -----------------------------------------

fn reject_declassify_without_unsafe(c: Secret<u8>) -> u8 {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    return reveal(c);
}

fn reject_declassify_non_secret(x: u8) -> u8 {
    unsafe {
        // EXPECT_ERROR: E_DECLASSIFY_NOT_SECRET
        return reveal(x);
    }
}

// ---- rejected: secrecy must survive an overlay-union reinterpret -------------
// (Gap #1) An `overlay union` whose arms alias the same bytes: if ANY arm is a
// Secret<…>, writing the secret arm and reading a DIFFERENT (plain) arm would
// otherwise strip secrecy and let the secret steer a branch. Reading ANY arm of
// such a union is therefore secret.

overlay union SecretWord {
    s: Secret<u32>,
    plain: u32,
}

fn reject_overlay_secret_arm_strip(v: Secret<u32>) -> u32 {
    var u: SecretWord = uninit;
    u.s = v;             // secret written into one arm
    // EXPECT_ERROR: E_SECRET_BRANCH
    if u.plain != 0 {    // reading a plain arm aliasing the secret bytes stays secret
        return 1;
    }
    return 0;
}

// ---- accepted: an overlay union with NO secret arm is not secret -------------
// (Gap #1, no-over-broaden) The secrecy classification fires ONLY when a secret
// arm exists; a plain-only overlay union still drives ordinary control flow.

overlay union PlainWord {
    a: u32,
    b: u32,
}

fn accept_overlay_plain_branch(v: u32) -> u32 {
    var u: PlainWord = uninit;
    u.a = v;
    if u.b != 0 {        // no secret arm — plain bool, ordinary branch
        return 1;
    }
    return 0;
}
