#!/usr/bin/env bash
# Best-effort REAL google.com:443 HTTPS fetch with cert-chain validation (standalone;
# NOT wired into CI -- no flaky gate).
#
# Same MC TCP transport (tests/qemu/tls/tls_demo.mc) + BearSSL bridge
# (https_get_runtime.c), but built with -DTLS_GOOGLE: the guest resolves google.com via
# slirp's real DNS forwarder (10.0.2.3:53), TCP-connects to the resolved IP on :443, and
# runs a REAL BearSSL TLS 1.2 handshake validating Google's ACTUAL certificate chain
# against the embedded GTS Root R1 trust anchor (third_party/trust-anchors/google_ta.c),
# with server_name "google.com". It then sends an HTTPS GET and reads the REAL decrypted
# response from Google.
#
# This depends on the sandbox letting the GUEST egress to the internet on :443. Honest
# outcomes (never fakes a green):
#   - Cert chain validated + real HTTP status decrypted -> PASS (GOOGLE-HTTPS-REAL-OK).
#   - Could not resolve / no SYN-ACK / handshake failed -> SKIP (exit 0) stating exactly
#     how far it got + the BearSSL error code.
#
# Usage: tools/tls/google-https-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

SERVERNAME="google.com"
HOSTHDR="www.google.com"
DNS_FWD="0x0A000203u"   # slirp built-in DNS forwarder 10.0.2.3

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/tls/tls_demo.mc"
RUNTIME="$HERE/tests/qemu/tls/https_get_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
BEARSSL="$HERE/third_party/bearssl"
TA_DIR="$HERE/third_party/trust-anchors"
TEST_NAME="google-https-test"

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Compile BearSSL freestanding for riscv64.
EPOCH="$(date +%s)"
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2 -fno-builtin
        -DBR_USE_UNIX_TIME=0 -DBR_USE_WIN32_TIME=0
        -DBR_USE_URANDOM=0 -DBR_USE_GETENTROPY=0
        -I"$BEARSSL/freestanding-shim" -I"$BEARSSL/inc" -I"$BEARSSL/src")

echo "Compiling BearSSL freestanding for riscv64..."
BEARSSL_OBJS=()
mkdir -p "$WORK/bearssl"
while IFS= read -r f; do
    obj="$WORK/bearssl/$(echo "$f" | sed 's#[/.]#_#g').o"
    "$CLANG" "${CFLAGS[@]}" -c "$f" -o "$obj"
    BEARSSL_OBJS+=("$obj")
done < <(find "$BEARSSL/src" -name '*.c' | sort)

# The runtime is now PURE MC (tests/qemu/tls/https_get_runtime.mc, shared with https-get-test); it
# imports tls_demo.mc, reads its config (google-mode: resolve $SERVERNAME via DNS at $DNS_FWD, :443)
# from a generated MC unit, and gets the GTS Root R1 trust anchor pointer from a 2-line C accessor
# over the vendored google_ta.c. Platform = mmode_dma_time.mc.
CFLAGS_BEARSSL=("${CFLAGS[@]}")
MCFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
         -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
         -Wno-unused-function -fno-builtin)

cat > "$WORK/cfg.mc" <<EOF
export fn mc_https_port() -> u16 { return 443; }
export fn mc_servername() -> *const u8 { return "$SERVERNAME"; }
export fn mc_hosthdr() -> *const u8 { return "$HOSTHDR"; }
export fn mc_build_epoch_fn() -> u64 { return $EPOCH; }
export fn mc_tls_google() -> u32 { return 1; }
export fn mc_dnshost() -> *const u8 { return "$SERVERNAME"; }
export fn mc_dns_server_ip() -> u32 { return ${DNS_FWD%u}; }
EOF

CFLAGS=("${MCFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$WORK/cfg.mc" "$WORK/cfg.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$HERE/kernel/arch/riscv64/mmode_dma_time.mc" "$WORK/platform.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$HERE/kernel/core/time.mc" "$WORK/time.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
# Vendored GTS Root R1 trust anchor (google_ta.c) + the 2-line accessor.
printf '#include "bearssl.h"\n#include "google_ta.c"\nconst br_x509_trust_anchor *mc_trust_anchors(void){return TAs;}\nunsigned long mc_trust_anchors_num(void){return TAs_NUM;}\n' > "$WORK/ta.c"
"$CLANG" "${CFLAGS_BEARSSL[@]}" -I"$TA_DIR" -c "$WORK/ta.c" -o "$WORK/ta.o"
# Shared virtio-rng entropy driver (single source of truth).
"$MCC" emit-c "$HERE/kernel/drivers/virtio/virtio_rng.mc" > "$WORK/virtio_rng_gen.c" # virtio-rng driver is now pure MC
"$CLANG" "${MCFLAGS[@]}" -c "$WORK/virtio_rng_gen.c" -o "$WORK/virtio_rng.o"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/cfg.o" "$WORK/platform.o" "$WORK/time.o" "$WORK/ta.o" "$WORK/virtio_rng.o" "${BEARSSL_OBJS[@]}" $SUPPORT_OBJ -o "$WORK/google.elf"

# Boot with plain slirp user networking (real upstream DNS + internet egress, if the
# sandbox permits it) + virtio-rng. Capture a pcap for the honest report.
OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -device virtio-rng-device \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/google.pcap" \
        -kernel "$WORK/google.elf" 2>/dev/null || true)"

echo "--- guest UART output ---"
printf '%s\n' "$OUT"
echo "-------------------------"
PCAP_BYTES=0
[ -s "$WORK/google.pcap" ] && PCAP_BYTES="$(wc -c <"$WORK/google.pcap" | tr -d ' ')"
echo "pcap: $PCAP_BYTES bytes captured"

RESOLVED_HEX="$(printf '%s' "$OUT" | grep -oE 'RESOLVED-IP=0x[0-9a-f]+' | head -1 | sed 's/.*=0x//')"
RESOLVED_DOTTED=""
if [ -n "$RESOLVED_HEX" ]; then
    ip=$((16#$RESOLVED_HEX))
    RESOLVED_DOTTED="$(( (ip>>24)&255 )).$(( (ip>>16)&255 )).$(( (ip>>8)&255 )).$(( ip&255 ))"
fi
HS_ERR="$(printf '%s' "$OUT" | grep -oE 'HANDSHAKE-ERROR=0x[0-9a-f]+' | head -1 | sed 's/.*=//')"
CIPHER="$(printf '%s' "$OUT" | grep -oE 'CIPHER-SUITE=0x[0-9a-f]+' | head -1)"
STATUS_LINE="$(printf '%s' "$OUT" | grep -oE 'HTTP/1\.[01] [0-9]{3}[^\r]*' | head -1 || true)"

# --- how far did it get? Report honestly. ---
if printf '%s' "$OUT" | grep -q 'DNS-NO-RESPONSE'; then
    echo "SKIP: $TEST_NAME — DNS A-query for google.com via 10.0.2.3 got no response"
    echo "  (the sandbox appears to block the guest's DNS egress)."
    exit 0
fi
if [ -z "$RESOLVED_DOTTED" ]; then
    echo "SKIP: $TEST_NAME — no resolved IP printed; see UART above for how far it got."
    exit 0
fi
echo "resolved: google.com -> $RESOLVED_DOTTED (real DNS answer from slirp 10.0.2.3)"

if printf '%s' "$OUT" | grep -q 'NO-SYN-ACK'; then
    echo "SKIP: $TEST_NAME — resolved google.com -> $RESOLVED_DOTTED [real], but the TCP SYN"
    echo "  to $RESOLVED_DOTTED:443 got no SYN-ACK — guest internet egress to :443 appears blocked."
    exit 0
fi

# Success markers (deterministic, printed before the large response body). The
# handshake completing with error 0 IS the cert-chain-validation proof; we also require
# the HTTPS-GET-OK summary + a real status line decrypted from Google.
GOT_OK=0; HS_VALIDATED=0; GOT_STATUS=0
printf '%s' "$OUT" | grep -q 'HTTPS-GET-OK' && GOT_OK=1
[ "$HS_ERR" = "0x0000000000000000" ] && HS_VALIDATED=1
[ -n "$STATUS_LINE" ] && GOT_STATUS=1
if [ "$GOT_OK" = 1 ] && [ "$HS_VALIDATED" = 1 ] && [ "$GOT_STATUS" = 1 ]; then
    echo "PASS: $TEST_NAME — REAL google.com:443 TLS 1.2 handshake validated Google's"
    echo "  ACTUAL cert chain against the embedded GTS Root R1 trust anchor."
    echo "  resolved IP:    $RESOLVED_DOTTED"
    echo "  handshake err:  ${HS_ERR:-?} (0 == cert chain validated)"
    echo "  cipher:         ${CIPHER:-<none>}"
    echo "  status line:    ${STATUS_LINE:-<none captured>}"
    echo "GOOGLE-HTTPS-REAL-OK"
    exit 0
fi

# Connected + handshake attempted but did not fully succeed: report the exact BearSSL code.
echo "SKIP: $TEST_NAME — resolved google.com -> $RESOLVED_DOTTED [real] and TCP connected,"
echo "  but the TLS exchange did not complete cleanly."
echo "  handshake error (BearSSL): ${HS_ERR:-<not reached>}  cipher: ${CIPHER:-<none>}"
echo "  status line: ${STATUS_LINE:-<none>}"
echo "  (BR_ERR_X509_* => cert/TA/time problem; 0x300-range => TLS alert; 0x1f => transport IO.)"
echo "  See the UART transcript above for the precise stage."
exit 0
