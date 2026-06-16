// Host-test wrappers around the pure DNS resolver (kernel/net/dns): build a query into
// a plain byte buffer and read back fields, and parse a response buffer to its first A
// record. The driver feeds known query bytes and a captured google.com A response and
// asserts the parsed IPv4, giving deterministic byte-level correctness on both backends.

import "kernel/net/dns.mc";
import "std/bytes.mc";
import "std/addr.mc";

// Build a query for the hostname at [name, name+name_len) into `buf`; return its length.
export fn dns_build(buf: usize, buflen: usize, txn_id: u16, name: usize, name_len: usize) -> u32 {
    var w: ByteWriter = byte_writer(pa(buf), buflen);
    let n: usize = dns_build_query(&w, 0, txn_id, name, name_len);
    return n as u32;
}

// Read one byte of the built/known buffer (so the driver can assert exact query bytes).
export fn dns_byte(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    return br_u8(&r, off) as u32;
}

// Parse a response buffer; return the A-record IPv4 as host-order u32, or 0 on any
// error (the driver also calls dns_parse_err to distinguish the failure kind).
export fn dns_parse_ip(buf: usize, buflen: usize, txn_id: u16) -> u32 {
    switch dns_parse_response(buf, buflen, txn_id) {
        ok(ip) => { return ip; }
        err(e) => { return 0; }
    }
}

// Parse a response and report the error kind as a small code:
//   0 = ok (an A record was found), 1 = Malformed, 2 = NoAnswer, 3 = Truncated,
//   4 = Mismatch.
export fn dns_parse_err(buf: usize, buflen: usize, txn_id: u16) -> u32 {
    switch dns_parse_response(buf, buflen, txn_id) {
        ok(ip) => { return 0; }
        err(e) => {
            switch e {
                .Malformed => { return 1; }
                .NoAnswer => { return 2; }
                .Truncated => { return 3; }
                .Mismatch => { return 4; }
            }
        }
    }
    return 1; // unreachable: every switch arm returns
}
