// P1 parser fuzz oracle: feed RANDOM and TRUNCATED/MALFORMED byte buffers to the
// kernel's two parsers over the most attacker-controlled input — dns_parse_response
// and tcp_parse_frame — and confirm each is a TOTAL function over its finite buffer:
// it always terminates and always returns a typed result, never over-reading past the
// end (which would trap the bounds-checked reader and abort the process).
//
// Because every read in those parsers now routes through the total checked reader
// (std/bytes br_try_*), an out-of-bounds field yields a clean rejection (DnsError /
// is_tcp=false), not a trap. The C driver runs many thousands of iterations across all
// lengths 0..N and arbitrary content; if any parse over-read, the bounds check would
// fire `unreachable` and the process would abort with a nonzero exit (test FAIL). The
// fixture returns 0/1 = ok/rejected; "rejected" is the expected outcome for garbage.

import "kernel/net/dns.mc";
import "kernel/net/tcp_tx.mc";
import "std/bytes.mc";
import "std/addr.mc";
import "std/math.mc"; // wrapping_shl_u32

global g_buf: [512]u8;

// xorshift32 PRNG (deterministic, seedable). The left shifts use the wrapping helper
// because MC's `<<` is checked — xorshift relies on bits wrapping away, not trapping.
fn rng(state: u32) -> u32 {
    var x: u32 = state;
    x = x ^ wrapping_shl_u32(x, 13);
    x = x ^ (x >> 17);
    x = x ^ wrapping_shl_u32(x, 5);
    return x;
}

// Fill g_buf[0, len) with pseudo-random bytes (len <= 512).
fn fill_random(seed: u32, len: usize) -> void {
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 512);
    var state: u32 = seed | 1;
    var i: usize = 0;
    while i < len {
        state = rng(state);
        bw_u8(&w, i, (state & 0x0000_00FF) as u8);
        i = i + 1;
    }
}

// ---- DNS parser oracle ----------------------------------------------------------

// Parse a RANDOM buffer of `len` bytes as a DNS response. Returns 0 if it parsed to an
// A record (ok), 1 if it returned any typed error. Either way it MUST return (no OOB).
export fn fuzz_dns_random(seed: u32, len: usize) -> u32 {
    fill_random(seed, len);
    switch dns_parse_response((&g_buf[0]) as usize, len, 0x1234) {
        ok(ip) => { return 0; }
        err(e) => { return 1; }
    }
}

// Parse a buffer that is well-formed enough to enter the answer-walk (valid header with
// our txn id, qdcount/ancount taken from the random tail) but TRUNCATED at `len`. This
// drives the name-compression skip + RR length handling against a short buffer — the
// classic over-read trigger. Returns 0/1 = ok/rejected; must always return.
export fn fuzz_dns_truncated(seed: u32, len: usize) -> u32 {
    fill_random(seed, len);
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 512);
    if len >= 12 {
        bw_be16(&w, 0, 0x1234);   // txn id matches
        bw_be16(&w, 2, 0x8000);   // QR=1 (a response), TC=0
        // qdcount/ancount keep their random values (drive the section walks).
    }
    switch dns_parse_response((&g_buf[0]) as usize, len, 0x1234) {
        ok(ip) => { return 0; }
        err(e) => { return 1; }
    }
}

// Build a structurally VALID DNS response with one A-record RR (qdcount=0, ancount=1,
// type=A, class=IN, rdlength=4) but cut the buffer off at `len` so the 4-byte rdata
// (and/or the RR fixed fields) are partly or wholly missing. This is the precise
// over-read trigger an answer-walk that trusts rdlength without re-checking the buffer
// would hit; the total reader must reject it (Malformed) for every truncation point.
// Returns 0/1 = ok/rejected; must always return (no trap).
export fn fuzz_dns_answer_trunc(len: usize) -> u32 {
    // Lay the full record into the buffer first (cap the layout at the 512-byte buffer).
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 512);
    bw_be16(&w, 0, 0x1234);   // txn id
    bw_be16(&w, 2, 0x8000);   // QR=1, TC=0
    bw_be16(&w, 4, 0);        // qdcount = 0 (skip the question section entirely)
    bw_be16(&w, 6, 1);        // ancount = 1
    bw_be16(&w, 8, 0);        // nscount
    bw_be16(&w, 10, 0);       // arcount
    // Answer RR at offset 12: NAME=root(0), TYPE=A, CLASS=IN, TTL, RDLENGTH=4, RDATA.
    bw_u8(&w, 12, 0);         // root-label name (1 byte)
    bw_be16(&w, 13, 1);       // TYPE = A
    bw_be16(&w, 15, 1);       // CLASS = IN
    bw_be16(&w, 17, 0);       // TTL hi
    bw_be16(&w, 19, 60);      // TTL lo
    bw_be16(&w, 21, 4);       // RDLENGTH = 4
    bw_u8(&w, 23, 10);        // RDATA: 10.0.0.1
    bw_u8(&w, 24, 0);
    bw_u8(&w, 25, 0);
    bw_u8(&w, 26, 1);
    // Now parse only [0, len): for len < 27 the rdata/RR fields are truncated.
    switch dns_parse_response((&g_buf[0]) as usize, len, 0x1234) {
        ok(ip) => { return 0; }
        err(e) => { return 1; }
    }
}

// ---- TCP frame parser oracle ----------------------------------------------------

// Parse a RANDOM Ethernet/IPv4/TCP frame of `len` bytes. Returns 0 if classified as
// TCP, 1 otherwise. Must always return (no OOB read of the claimed header lengths).
export fn fuzz_tcp_random(seed: u32, len: usize) -> u32 {
    fill_random(seed, len);
    var rx: TcpRx = tcp_parse_frame((&g_buf[0]) as usize, len);
    if rx.is_tcp {
        return 0;
    }
    return 1;
}

// Shape a frame as IPv4/TCP but with HOSTILE length fields: a random IHL nibble, a
// random IP total-length, and a random TCP data-offset nibble — each of which, if
// trusted blindly, would read past `len`. The total reader must reject cleanly.
export fn fuzz_tcp_hostile(seed: u32, len: usize) -> u32 {
    fill_random(seed, len);
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 512);
    var state: u32 = (seed | 1);
    if len >= 14 {
        bw_be16(&w, 12, 0x0800); // ethertype IPv4 -> enter the IP parse
    }
    if len >= 15 {
        state = rng(state);
        // version 4 (high nibble) + RANDOM IHL (low nibble): a large IHL pushes the TCP
        // header offset far out; the reader must reject, not over-read.
        bw_u8(&w, 14, 0x40 | ((state & 0x0F) as u8));
    }
    if len >= 24 {
        bw_u8(&w, 23, 6); // IP protocol TCP (offset 14+9)
        state = rng(state);
        bw_be16(&w, 16, (state & 0x0000_FFFF) as u16); // RANDOM IP total length
    }
    // RANDOM TCP data-offset nibble lands wherever the (random IHL) header puts byte 12;
    // we just leave the random tail to supply it. tcp_parse_frame reads it via br_try_*.
    var rx: TcpRx = tcp_parse_frame((&g_buf[0]) as usize, len);
    if rx.is_tcp {
        return 0;
    }
    return 1;
}
