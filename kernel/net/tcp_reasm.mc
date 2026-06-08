// kernel/net/tcp_reasm — TCP receive reassembly: accept segments that may arrive out
// of order, deliver the contiguous in-order prefix, and buffer the rest until the
// gaps fill. Sequence numbers are 32-bit modular (wrapping helpers from [[std-math]]);
// old/duplicate data is dropped, future data is held, in-order data advances rcv_nxt
// and coalesces any now-contiguous buffered segments.

import "std/math.mc";

const SEGS: usize = 8;
const SEQ_HALF: u32 = 0x8000_0000; // 2^31: the future/past boundary in modular space

struct Segment {
    seq: u32,
    len: u32,
    valid: bool,
}

struct Reassembler {
    rcv_nxt: u32,
    segs: [SEGS]Segment, // out-of-order holding queue (metadata)
}

export fn reasm_init(r: *mut Reassembler, irs: u32) -> void {
    r.rcv_nxt = irs;
    var i: usize = 0;
    while i < SEGS {
        r.segs[i].valid = false;
        i = i + 1;
    }
}

// Deliver any buffered segments that are now contiguous with rcv_nxt; return the
// additional in-order bytes delivered.
fn coalesce(r: *mut Reassembler) -> u32 {
    var advanced: u32 = 0;
    var again: bool = true;
    while again {
        again = false;
        var i: usize = 0;
        while i < SEGS {
            let v: bool = r.segs[i].valid;
            if v {
                if r.segs[i].seq == r.rcv_nxt {
                    let l: u32 = r.segs[i].len;
                    r.rcv_nxt = wrapping_add_u32(r.rcv_nxt, l);
                    advanced = advanced + l;
                    r.segs[i].valid = false;
                    again = true;
                }
            }
            i = i + 1;
        }
    }
    return advanced;
}

// Offer a segment [seq, seq+len). Returns the number of newly contiguous in-order
// bytes now deliverable (rcv_nxt advanced by that much). Out-of-order data is
// buffered; old/duplicate data is dropped.
export fn reasm_accept(r: *mut Reassembler, seq: u32, len: u32) -> u32 {
    let offset: u32 = wrapping_sub_u32(seq, r.rcv_nxt);
    if offset == 0 {
        r.rcv_nxt = wrapping_add_u32(r.rcv_nxt, len);
        let extra: u32 = coalesce(r);
        return len + extra;
    }
    if offset >= SEQ_HALF {
        return 0; // seq precedes rcv_nxt: old/duplicate
    }
    // Future segment: buffer it (skip if already held; need a free slot).
    var i: usize = 0;
    while i < SEGS {
        let v: bool = r.segs[i].valid;
        if v {
            if r.segs[i].seq == seq {
                return 0; // already buffered
            }
        }
        i = i + 1;
    }
    var slot: usize = SEGS;
    var j: usize = 0;
    while j < SEGS {
        let vj: bool = r.segs[j].valid;
        if !vj {
            slot = j;
            break;
        }
        j = j + 1;
    }
    if slot < SEGS {
        r.segs[slot].seq = seq;
        r.segs[slot].len = len;
        r.segs[slot].valid = true;
    }
    return 0;
}

export fn reasm_rcv_nxt(r: *mut Reassembler) -> u32 {
    return r.rcv_nxt;
}

// How many out-of-order segments are currently buffered (awaiting a gap fill).
export fn reasm_buffered(r: *mut Reassembler) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < SEGS {
        let v: bool = r.segs[i].valid;
        if v {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}
