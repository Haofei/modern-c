// Thin MC binding over BearSSL's constant-time "i31" RSA engine: PKCS#1 v1.5
// signature verification with SHA-256. This is the MC-callable seam for signed-bundle /
// image / agent-manifest verification (production-readiness plan P4). The constant-time
// big-integer math lives in the vendored BearSSL (third_party/bearssl/src/{rsa,int});
// MC does NOT reimplement it. Crypto that is easy to get subtly wrong (constant-time
// modexp) stays in the audited library; this module only marshals arguments.
//
// FFI convention (matches the existing kernel/net BearSSL bindings): pointers are passed
// as `usize` addresses; BearSSL never retains them past the call. All inputs are
// caller-owned buffers. Big integers (n, e, signature) are unsigned big-endian, exactly
// as emitted by `openssl rsa -modulus` / a DER public key.

// Implemented by bearssl_rsa_shim.c. C owns the real br_rsa_public_key and
// br_sha256_context layout and validates all pointer/length pairs.
extern fn mc_rsa_pkcs1_sha256_verify(
    msg: usize, msg_len: usize,
    sig: usize, sig_len: usize,
    n: usize, nlen: usize,
    e: usize, elen: usize,
) -> u32;

// Verify an RSA PKCS#1 v1.5 signature over SHA-256(msg) under public key (n, e).
// Returns true iff `sig` is a valid signature. Both the modexp (BearSSL i31) and the
// final digest comparison here are constant-time.
export fn rsa_pkcs1_sha256_verify(
    msg: usize, msg_len: usize,
    sig: usize, sig_len: usize,
    n: usize, nlen: usize,
    e: usize, elen: usize,
) -> bool {
    return mc_rsa_pkcs1_sha256_verify(
        msg, msg_len, sig, sig_len, n, nlen, e, elen,
    ) == 1;
}
