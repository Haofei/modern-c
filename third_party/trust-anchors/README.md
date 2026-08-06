# Trust anchors for the in-kernel TLS client

The committed C files are `br_x509_trust_anchor[]` tables generated from public
certificate material and embedded into the kernel HTTPS test runtime when needed.
Each defines `TAs[]` + `TAs_NUM`.

## Local deterministic CI gates

`tools/tls/https-get-test.sh` and `tools/arch/https-smode-test.sh` generate their
local self-signed certificate, private key, and BearSSL trust-anchor C table inside
the per-run temporary directory:

    openssl req -x509 -newkey rsa:2048 -keyout "$WORK/host_test.key" -out "$WORK/host_test.pem" \
        -days 3650 -nodes -subj "/CN=host.test" -addext "subjectAltName=DNS:host.test"
    python3 tools/tls/local-ta-from-cert.py "$WORK/host_test.pem" "$WORK/local_ta.c"

No local HTTPS test private key is committed to the repository. The generated
self-signed cert is its own trust anchor, so BearSSL validates the exact certificate
served by the local Python HTTPS server without relying on persistent private key
material.

## google_ta.c — the best-effort real fetch (`tools/tls/google-https-test.sh`)
Trust anchor = **GTS Root R1** (`C=US, O=Google Trust Services LLC, CN=GTS Root R1`),
SHA-256 fingerprint
`3E:E0:27:8D:F7:1F:A3:C1:25:C4:CD:48:7F:01:D7:74:69:4E:6F:C5:7E:0C:D9:4C:24:EF:D7:69:13:39:18:E5`.

It was extracted from google.com's live chain (the chain presents
`*.google.com <- WR2 <- GTS Root R1 <- GlobalSign Root CA`; the third cert IS GTS Root R1)
and converted:

    openssl s_client -connect google.com:443 -servername google.com -showcerts </dev/null
    # save the GTS Root R1 block as gts_root_r1.pem
    brssl ta gts_root_r1.pem > google_ta.c

BearSSL anchors on the subject DN + public key, so this validates Google's real chain:
the server-sent WR2 intermediate chains up to GTS Root R1, which we trust as the anchor.
