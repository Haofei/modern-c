// kernel/core/production_ops_rsa — optional RSA-backed VerifiedBundle proof adapter.
//
// Keep the BearSSL/RSA dependency out of production_ops.mc itself: metadata-only
// rollback and loader gates can compile without pulling in the crypto shim, while
// signed-image profiles import this adapter to turn real RSA verification into the
// linear BundleSignatureProof consumed by bundle admission.

import "kernel/core/production_ops.mc";
import "kernel/crypto/rsa_verify.mc";

pub fn bundle_signature_proof_mint_rsa_image(
    auth: *SignatureAuthority,
    h: *BundleHeader,
    image_base: usize,
    image_len: usize,
    sig_base: usize,
    sig_len: usize,
    n_base: usize,
    n_len: usize,
    e_base: usize,
    e_len: usize,
) -> BundleSignatureProof {
    let accepted: bool = rsa_pkcs1_sha256_verify(
        image_base,
        image_len,
        sig_base,
        sig_len,
        n_base,
        n_len,
        e_base,
        e_len,
    );
    return bundle_signature_proof_mint(auth, h, accepted);
}
