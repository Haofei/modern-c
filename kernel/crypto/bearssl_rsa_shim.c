#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "bearssl.h"

/*
 * The C compiler, not MC byte offsets, is authoritative for BearSSL ABI
 * layout. This wrapper also validates every pointer/length pair before the
 * vendored implementation sees it.
 */
uint32_t mc_rsa_pkcs1_sha256_verify(
    const uint8_t *msg, size_t msg_len,
    const uint8_t *sig, size_t sig_len,
    const uint8_t *n, size_t n_len,
    const uint8_t *e, size_t e_len)
{
    const unsigned char *sha256_oid = BR_HASH_OID_SHA256;
    br_sha256_context sha;
    br_rsa_public_key key;
    unsigned char recovered[32] = {0};
    unsigned char computed[32] = {0};
    uint32_t diff = 0;
    uint32_t verified;
    size_t i;

    if ((msg == NULL && msg_len != 0) || sig == NULL || n == NULL || e == NULL)
        return 0;
    if (sig_len == 0 || n_len == 0 || e_len == 0 || sig_len != n_len)
        return 0;

    key.n = (unsigned char *)(uintptr_t)n;
    key.nlen = n_len;
    key.e = (unsigned char *)(uintptr_t)e;
    key.elen = e_len;

    verified = br_rsa_i31_pkcs1_vrfy(
        sig, sig_len, sha256_oid, sizeof recovered, &key, recovered);
    if (verified != 1)
        return 0;

    br_sha256_init(&sha);
    br_sha256_update(&sha, msg, msg_len);
    br_sha256_out(&sha, computed);

    for (i = 0; i < sizeof computed; ++i)
        diff |= (uint32_t)(computed[i] ^ recovered[i]);

    /* Keep signature validity independent of the first mismatching byte. */
    return (uint32_t)(diff == 0);
}
