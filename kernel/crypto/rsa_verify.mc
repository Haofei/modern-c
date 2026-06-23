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

extern fn br_sha256_init(ctx: usize) -> void;
// `br_sha256_update` is a header macro aliasing the linked symbol `br_sha224_update`.
extern fn br_sha224_update(ctx: usize, data: usize, len: usize) -> void;
extern fn br_sha256_out(ctx: usize, out: usize) -> void;

// uint32_t br_rsa_i31_pkcs1_vrfy(const unsigned char *x, size_t xlen,
//     const unsigned char *hash_oid, size_t hash_len,
//     const br_rsa_public_key *pk, unsigned char *hash_out);  -> 1 on success.
extern fn br_rsa_i31_pkcs1_vrfy(
    x: usize, xlen: usize,
    hash_oid: usize, hash_len: usize,
    pk: usize, hash_out: usize,
) -> u32;

const SHA256_LEN: usize = 32;

// BearSSL's encoded SHA-256 OID for PKCS#1 (a length byte 0x09 followed by the 9 OID
// bytes) — BR_HASH_OID_SHA256 in bearssl_rsa.h.
global SHA256_OID: [10]u8 = .{ 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };

// Compute SHA-256(msg[0..msg_len]) into the 32-byte buffer at `out32`.
fn sha256(msg: usize, msg_len: usize, out32: usize) -> void {
    var ctx: [128]u8 = uninit;   // >= sizeof(br_sha256_context) (112)
    let c: usize = (&ctx[0]) as usize;
    br_sha256_init(c);
    br_sha224_update(c, msg, msg_len);
    br_sha256_out(c, out32);
}

// Verify an RSA PKCS#1 v1.5 signature over SHA-256(msg) under public key (n, e).
// Returns true iff `sig` is a valid signature. Both the modexp (BearSSL i31) and the
// final digest comparison here are constant-time.
export fn rsa_pkcs1_sha256_verify(
    msg: usize, msg_len: usize,
    sig: usize, sig_len: usize,
    n: usize, nlen: usize,
    e: usize, elen: usize,
) -> bool {
    // br_rsa_public_key = { u8* n; usize nlen; u8* e; usize elen; } — 32 bytes on lp64.
    // Built into a byte buffer so this module owns the layout without an extern struct.
    var pk: [32]u8 = uninit;
    let pkp: usize = (&pk[0]) as usize;
    unsafe {
        raw.store<usize>(phys(pkp + 0), n);
        raw.store<usize>(phys(pkp + 8), nlen);
        raw.store<usize>(phys(pkp + 16), e);
        raw.store<usize>(phys(pkp + 24), elen);
    }

    var recovered: [32]u8 = uninit;
    let rok: u32 = br_rsa_i31_pkcs1_vrfy(
        sig, sig_len,
        (&SHA256_OID[0]) as usize, SHA256_LEN,
        pkp, (&recovered[0]) as usize,
    );
    if rok != 1 { return false; }

    var computed: [32]u8 = uninit;
    sha256(msg, msg_len, (&computed[0]) as usize);

    // Constant-time 32-byte digest compare (no early exit on first mismatch).
    var diff: u8 = 0;
    var i: usize = 0;
    while i < SHA256_LEN {
        diff = diff | (computed[i] ^ recovered[i]);
        i = i + 1;
    }
    return diff == 0;
}
