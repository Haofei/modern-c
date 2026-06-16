#include <stdint.h>
#include <string.h>

extern uint32_t dns_build(uintptr_t buf, uintptr_t buflen, uint16_t txn, uintptr_t name, uintptr_t name_len);
extern uint32_t dns_byte(uintptr_t buf, uintptr_t buflen, uintptr_t off);
extern uint32_t dns_parse_ip(uintptr_t buf, uintptr_t buflen, uint16_t txn);
extern uint32_t dns_parse_err(uintptr_t buf, uintptr_t buflen, uint16_t txn);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    /* ---- 1. Build a query for "google.com" and assert the exact wire bytes. ---- */
    const char host[] = "google.com";
    uint8_t qbuf[64];
    memset(qbuf, 0xAA, sizeof(qbuf));
    uint32_t qlen = dns_build((uintptr_t)qbuf, sizeof(qbuf), 0x1234,
                              (uintptr_t)host, (uintptr_t)(sizeof(host) - 1));
    /* header(12) + 6"google" + 3"com" + root(1) + qtype(2) + qclass(2) = 12+7+4+1+4 = 28 */
    CHECK(qlen == 28);
    /* header */
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 0) == 0x12);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 1) == 0x34);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 2) == 0x01); /* flags hi = recursion desired */
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 3) == 0x00);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 5) == 0x01); /* qdcount = 1 */
    /* QNAME: 06 'g' 'o' 'o' 'g' 'l' 'e' 03 'c' 'o' 'm' 00 */
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 12) == 6);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 13) == 'g');
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 18) == 'e');
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 19) == 3);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 20) == 'c');
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 22) == 'm');
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 23) == 0); /* root */
    /* QTYPE = 1 (A), QCLASS = 1 (IN) */
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 24) == 0);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 25) == 1);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 26) == 0);
    CHECK(dns_byte((uintptr_t)qbuf, sizeof(qbuf), 27) == 1);

    /* ---- 2. Parse a captured google.com A response (with name compression). ---- */
    /* Header: id=0x1234, flags=0x8180 (response, RD, RA), qd=1, an=1, ns=0, ar=0. */
    uint8_t resp[] = {
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        /* Question: google.com A IN */
        0x06, 'g','o','o','g','l','e', 0x03, 'c','o','m', 0x00,
        0x00, 0x01, 0x00, 0x01,
        /* Answer: name = compression pointer to offset 12, A IN, TTL=300, rdlen=4, IP */
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04,
        142, 251, 219, 142,
    };
    /* The parsed IP must be the host-order u32 142.251.219.142 = 0x8EFBDB8E. */
    uint32_t ip = dns_parse_ip((uintptr_t)resp, sizeof(resp), 0x1234);
    CHECK(ip == 0x8EFBDB8Eu);
    CHECK(dns_parse_err((uintptr_t)resp, sizeof(resp), 0x1234) == 0);

    /* ---- 3. Error paths. ---- */
    /* Wrong txn id => Mismatch (4). */
    CHECK(dns_parse_err((uintptr_t)resp, sizeof(resp), 0x9999) == 4);
    /* Not a response (clear the QR bit) => Mismatch (4). */
    resp[2] = 0x01;
    CHECK(dns_parse_err((uintptr_t)resp, sizeof(resp), 0x1234) == 4);
    resp[2] = 0x81;
    /* No answers (ancount=0) => NoAnswer (2). */
    resp[7] = 0x00;
    CHECK(dns_parse_err((uintptr_t)resp, sizeof(resp), 0x1234) == 2);
    resp[7] = 0x01;
    /* TC bit (mask 0x0200, in the flags high byte) set => Truncated (3). */
    resp[2] = 0x83; /* was 0x81 (QR|RD); set TC too */
    CHECK(dns_parse_err((uintptr_t)resp, sizeof(resp), 0x1234) == 3);

    return 0;
}
