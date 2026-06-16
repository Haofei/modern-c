// kernel/net/dns — build a DNS A-record query and parse a DNS response (RFC 1035),
// purely over bounds-checked byte readers/writers (std/bytes). No allocation, no I/O:
// the caller supplies the packet buffer and transports the bytes (over UDP) itself.
// This keeps the resolver a pure builder/parser (like kernel/net/tcp_tx), so it is
// unit-testable byte-for-byte on the host with captured fixtures.
//
// The query is a standard recursive A/IN lookup: a 12-byte header (txn id, flags
// 0x0100 = recursion-desired, qdcount=1), the QNAME as length-prefixed labels split
// on '.', then QTYPE=1 (A) and QCLASS=1 (IN). The parser validates the txn id and the
// response bit, skips the question section, walks the answer resource records honoring
// DNS name-compression pointers (0xC0) when skipping names, and returns the FIRST A
// record (type=1, class=1, rdlength=4) as a host-order u32 IPv4 address.
//
// IPv4-only: we never request AAAA. `hostname` is passed as a raw byte region
// [hostname_ptr, hostname_ptr+hostname_len) of ASCII (e.g. "google.com").

import "std/bytes.mc";

const DNS_FLAG_QR: u16 = 0x8000;       // response bit in the flags word
const DNS_TYPE_A: u16 = 1;             // A record
const DNS_CLASS_IN: u16 = 1;           // Internet class
const DNS_PTR_MASK: u8 = 0xC0;         // top two bits set => compression pointer

enum DnsError {
    Malformed,   // structural error (ran off the end, bad label, etc.)
    NoAnswer,    // valid response, but no A record present
    Truncated,   // the TC bit was set (answer did not fit)
    Mismatch,    // txn id did not match, or it was not a response
}

// Write a DNS A-query for `hostname` into the byte writer at offset `at`. The hostname
// bytes are read from the raw region [hostname_ptr, hostname_ptr+hostname_len). Returns
// the total query length in bytes (header + QNAME + QTYPE + QCLASS).
export fn dns_build_query(w: *ByteWriter, at: usize, txn_id: u16, hostname_ptr: usize, hostname_len: usize) -> usize {
    // 12-byte header.
    bw_be16(w, at + 0, txn_id);
    bw_be16(w, at + 2, 0x0100); // flags: standard query, recursion desired
    bw_be16(w, at + 4, 1);      // qdcount = 1
    bw_be16(w, at + 6, 0);      // ancount
    bw_be16(w, at + 8, 0);      // nscount
    bw_be16(w, at + 10, 0);     // arcount

    // QNAME: split the hostname on '.', emitting <len><label-bytes> for each label,
    // terminated by a zero-length root label.
    var hr: ByteReader = byte_reader(phys(hostname_ptr), hostname_len);
    var out: usize = at + 12;       // cursor in the output buffer
    var label_len_pos: usize = out; // where the current label's length byte goes
    out = out + 1;                  // reserve the length byte
    var label_count: u8 = 0;        // bytes in the current label
    var i: usize = 0;
    while i < hostname_len {
        let c: u8 = br_u8(&hr, i);
        if c == 0x2E { // '.'
            bw_u8(w, label_len_pos, label_count);
            label_len_pos = out;
            out = out + 1;
            label_count = 0;
        } else {
            bw_u8(w, out, c);
            out = out + 1;
            label_count = label_count + 1;
        }
        i = i + 1;
    }
    bw_u8(w, label_len_pos, label_count); // finalize the last label
    bw_u8(w, out, 0);                      // root label
    out = out + 1;

    // QTYPE = A, QCLASS = IN.
    bw_be16(w, out + 0, DNS_TYPE_A);
    bw_be16(w, out + 2, DNS_CLASS_IN);
    out = out + 4;

    return out - at;
}

// Skip a (possibly compressed) DNS name starting at `off` within the message
// [base, base+len). Returns the offset of the first byte AFTER the name in the linear
// stream (a compression pointer terminates the name, so we stop right after it). On a
// structural error returns len (which the caller treats as out-of-bounds).
fn dns_skip_name(r: *ByteReader, base_off: usize, len: usize) -> usize {
    var off: usize = base_off;
    while off < len {
        let b: u8 = br_u8(r, off);
        if b == 0 {
            return off + 1; // root label: name ends here
        }
        if (b & DNS_PTR_MASK) == DNS_PTR_MASK {
            // 2-byte compression pointer; the name continues elsewhere but the linear
            // stream resumes right after the pointer.
            if off + 1 >= len {
                return len;
            }
            return off + 2;
        }
        // A normal label: <len> followed by <len> bytes.
        off = off + 1 + (b as usize);
    }
    return len;
}

// Parse a DNS response in [base, base+len). Validates the txn id + response bit, skips
// the question section, and returns the first A record's IPv4 address as a host-order
// u32. `base` is the raw address of the first DNS header byte (the UDP payload start).
export fn dns_parse_response(base: usize, len: usize, txn_id: u16) -> Result<u32, DnsError> {
    if len < 12 {
        return err(.Malformed);
    }
    var r: ByteReader = byte_reader(phys(base), len);

    let id: u16 = br_be16(&r, 0);
    if id != txn_id {
        return err(.Mismatch);
    }
    let flags: u16 = br_be16(&r, 2);
    if (flags & DNS_FLAG_QR) == 0 {
        return err(.Mismatch); // not a response
    }
    if (flags & 0x0200) != 0 {
        return err(.Truncated); // TC bit
    }

    let qdcount: u16 = br_be16(&r, 4);
    let ancount: u16 = br_be16(&r, 6);
    if ancount == 0 {
        return err(.NoAnswer);
    }

    // Skip the question section: each question is NAME + QTYPE(2) + QCLASS(2).
    var off: usize = 12;
    var q: u16 = 0;
    while q < qdcount {
        off = dns_skip_name(&r, off, len);
        off = off + 4; // QTYPE + QCLASS
        if off > len {
            return err(.Malformed);
        }
        q = q + 1;
    }

    // Walk the answer RRs: NAME, TYPE(2), CLASS(2), TTL(4), RDLENGTH(2), RDATA.
    var a: u16 = 0;
    while a < ancount {
        off = dns_skip_name(&r, off, len);
        if off + 10 > len {
            return err(.Malformed);
        }
        let rtype: u16 = br_be16(&r, off + 0);
        let rclass: u16 = br_be16(&r, off + 2);
        let rdlength: u16 = br_be16(&r, off + 8);
        let rdata_off: usize = off + 10;
        if rdata_off + (rdlength as usize) > len {
            return err(.Malformed);
        }
        if rtype == DNS_TYPE_A {
            if rclass == DNS_CLASS_IN {
                if rdlength == 4 {
                    let ip: u32 = br_be32(&r, rdata_off);
                    return ok(ip);
                }
            }
        }
        off = rdata_off + (rdlength as usize);
        a = a + 1;
    }
    return err(.NoAnswer);
}
