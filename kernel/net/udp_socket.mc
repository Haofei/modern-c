// kernel/net/udp_socket — a minimal UDP socket layer: bind local ports and
// demultiplex incoming datagrams to the bound socket, with a per-table receive
// queue. This is the socket abstraction the syscall layer (recvfrom/sendto) sits on.
//
// Each queued datagram stores its payload inline (`queue[k].payload[j]` — a field
// array of an array element, which the compiler now lowers, so the old flat
// pool+offset bookkeeping is gone). Delivery to an unbound port is a typed error
// (NoListener), not a silent drop; every bind is checked for conflicts.

import "std/bytes.mc";
import "std/addr.mc";
import "std/byteview.mc";

const MAX_SOCKETS: usize = 8;
const QDEPTH: usize = 8;
const DGRAM_MAX: usize = 64;

struct Socket {
    local_port: u16,
    bound: bool,
    last_src_ip: u32,
    last_src_port: u16,
}

struct Datagram {
    valid: bool,
    dst_port: u16,
    src_ip: u32,
    src_port: u16,
    len: u16,
    payload: ByteBuf<DGRAM_MAX>, // inline buffer (bulk copy via std/byteview)
}

struct SocketTable {
    socks: [MAX_SOCKETS]Socket,
    queue: [QDEPTH]Datagram,
}

enum SockError {
    BadSocket,
    PortInUse,
    NoListener, // no socket bound to the datagram's destination port
    QueueFull,
    TooLarge,
    Empty, // no datagram pending for this socket
}

export fn socket_table_init(t: *mut SocketTable) -> void {
    var i: usize = 0;
    while i < MAX_SOCKETS {
        t.socks[i].bound = false;
        i = i + 1;
    }
    var k: usize = 0;
    while k < QDEPTH {
        t.queue[k].valid = false;
        k = k + 1;
    }
}

// Index of a socket bound to `port`, or MAX_SOCKETS if none.
fn bound_socket(t: *mut SocketTable, port: u16) -> usize {
    var i: usize = 0;
    while i < MAX_SOCKETS {
        if t.socks[i].bound {
            if t.socks[i].local_port == port {
                return i;
            }
        }
        i = i + 1;
    }
    return MAX_SOCKETS;
}

// Bind socket `idx` to `port`; the port must be free.
export fn socket_bind(t: *mut SocketTable, idx: usize, port: u16) -> Result<bool, SockError> {
    if idx >= MAX_SOCKETS {
        return err(.BadSocket);
    }
    let existing: usize = bound_socket(t, port);
    if existing < MAX_SOCKETS {
        return err(.PortInUse);
    }
    t.socks[idx].local_port = port;
    t.socks[idx].bound = true;
    t.socks[idx].last_src_ip = 0;
    t.socks[idx].last_src_port = 0;
    return ok(true);
}

// Deliver a received datagram: demux to the socket bound to `dst_port` and queue it
// (copying the payload into the pool). No listener / no room are typed errors.
export fn socket_deliver(t: *mut SocketTable, dst_port: u16, src_ip: u32, src_port: u16, src_addr: usize, len: usize) -> Result<bool, SockError> {
    if len > DGRAM_MAX {
        return err(.TooLarge);
    }
    let target: usize = bound_socket(t, dst_port);
    if target >= MAX_SOCKETS {
        return err(.NoListener);
    }
    // find a free queue slot
    var slot: usize = QDEPTH;
    var k: usize = 0;
    while k < QDEPTH {
        if !t.queue[k].valid {
            slot = k;
            break;
        }
        k = k + 1;
    }
    if slot >= QDEPTH {
        return err(.QueueFull);
    }
    let copied: usize = bytebuf_copy_from(DGRAM_MAX, &t.queue[slot].payload, pa(src_addr), len);
    t.queue[slot].valid = true;
    t.queue[slot].dst_port = dst_port;
    t.queue[slot].src_ip = src_ip;
    t.queue[slot].src_port = src_port;
    t.queue[slot].len = copied as u16;
    return ok(true);
}

// Receive the next datagram for socket `idx` into `out_addr` (up to `max` bytes).
// Records the sender for socket_last_src_*; returns the payload length.
export fn socket_recv(t: *mut SocketTable, idx: usize, out_addr: usize, max: usize) -> Result<u64, SockError> {
    if idx >= MAX_SOCKETS {
        return err(.BadSocket);
    }
    if !t.socks[idx].bound {
        return err(.BadSocket);
    }
    let port: u16 = t.socks[idx].local_port;
    // find the oldest queued datagram for this port
    var slot: usize = QDEPTH;
    var k: usize = 0;
    while k < QDEPTH {
        if t.queue[k].valid {
            if t.queue[k].dst_port == port {
                slot = k;
                break;
            }
        }
        k = k + 1;
    }
    if slot >= QDEPTH {
        return err(.Empty);
    }
    let len: usize = t.queue[slot].len as usize;
    var n: usize = len;
    if max < n {
        n = max;
    }
    bytebuf_copy_to(DGRAM_MAX, &t.queue[slot].payload, phys(out_addr), n);
    t.socks[idx].last_src_ip = t.queue[slot].src_ip;
    t.socks[idx].last_src_port = t.queue[slot].src_port;
    t.queue[slot].valid = false;
    return ok(len as u64);
}

export fn socket_last_src_ip(t: *mut SocketTable, idx: usize) -> u32 {
    return t.socks[idx].last_src_ip;
}

export fn socket_last_src_port(t: *mut SocketTable, idx: usize) -> u16 {
    return t.socks[idx].last_src_port;
}
