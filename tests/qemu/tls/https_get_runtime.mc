// HTTPS-GET runtime — the REAL TLS bridge, in PURE MC (replaces
// kernel/drivers/virtio/https_get_runtime.c). The boot seam (virtio-mmio discovery, the split
// virtqueues, a virtio-rng entropy source, the clock seam) that drives a REAL BearSSL TLS 1.2
// client over the MC kernel's hand-rolled TCP (tls_demo.mc) under QEMU user networking, fetching
// real HTTPS content and verifying the decrypted response.
//
// THE BRIDGE: BearSSL's record layer is wired to our TCP via two callbacks — low_write -> tls_send
// and low_read -> tls_recv (passed to br_sslio_init as fn pointers). BearSSL + openlibm + the
// brssl-generated trust anchor (local_ta.c) stay vendored C; a 2-line C accessor (mc_trust_anchors
// / mc_trust_anchors_num, compiled with the cert data) hands MC the TAs pointer + count (an
// extern-DATA address into a BearSSL-flags object does not resolve cleanly from MC, but a function
// does). The std/dma + std/time platform (8 MiB pool + CLINT) is the separate mmode_dma_time.mc.
//
// BearSSL opaque contexts are over-sized u64 arrays (8-aligned; a [N]u8 global is only byte-
// aligned and the contexts hold pointers). Sizes: cc=3720, xc=3176, ioc=40, iobuf=BR_SSL_BUFSIZE_
// BIDI=33178. A too-small/misaligned context fails the CERT-CHAIN-VALIDATED + decrypted-token
// asserts, so the sizing is gate-verified.

import "tests/qemu/tls/tls_demo.mc"; // tls_net_up / tls_connect / tls_send / tls_recv + Virtq/MmioPtr

// The vendored trust anchor, via a C accessor (local_ta.c stays vendored cert data).
extern fn mc_trust_anchors() -> usize;
extern fn mc_trust_anchors_num() -> usize;

// Vendored BearSSL (third_party). &cc.eng == &cc (engine is the first field of br_ssl_client_context).
extern fn br_ssl_client_init_full(cc: usize, xc: usize, tas: usize, num: usize) -> void;
extern fn br_ssl_engine_set_buffer(eng: usize, iobuf: usize, len: usize, bidi: i32) -> void;
extern fn br_ssl_engine_inject_entropy(eng: usize, seed: usize, len: usize) -> void;
extern fn br_ssl_client_reset(cc: usize, name: usize, resume: i32) -> i32;
extern fn br_sslio_init(ioc: usize, eng: usize, lowread: usize, rctx: usize, lowwrite: usize, wctx: usize) -> void;
extern fn br_sslio_write_all(ioc: usize, data: usize, len: usize) -> i32;
extern fn br_sslio_flush(ioc: usize) -> i32;
extern fn br_sslio_read(ioc: usize, dst: usize, len: usize) -> i32;

// br_ssl_engine_last_error / br_x509_minimal_set_time are `static inline` header accessors in
// BearSSL (no linkable symbol) — they just read/write struct fields. Inline them in MC via the
// audited field offsets (br_ssl_engine_context.err@0; br_x509_minimal_context.days@340,
// .seconds@344). A wrong offset can only FAIL the gate (the decrypted-token/200/access-log asserts
// require a genuinely-validated handshake), never false-pass.
fn br_last_error(eng: usize) -> i32 {
    var v: i32 = 0;
    unsafe { v = raw.load<i32>(phys(eng)); } // eng->err is the first field
    return v;
}
fn br_set_time(xc: usize, days: u32, secs: u32) -> void {
    unsafe {
        raw.store<u32>(phys(xc + 340), days);
        raw.store<u32>(phys(xc + 344), secs);
        // itime (the optional validity callback) is already 0 (g_xc is zeroed BSS and
        // br_ssl_client_init_full does not set it); writing a wider type would clobber neighbours.
    }
}

// Shared virtio-rng entropy driver (virtio_rng.mc, linked separately).
extern fn vrng_find() -> usize;
extern fn vrng_init(rng: usize) -> u32;
extern fn vrng_fill(rng: usize, buf: usize, n: u32) -> u32;

// Real wall-clock (kernel/core/time.mc, linked as time.o) — seconds since the epoch.
extern fn time_now_epoch() -> u64;

// Per-invocation config the C runtime took via -D, threaded in as a harness-generated MC unit.
extern fn mc_https_port() -> u16;
extern fn mc_servername() -> *const u8;
extern fn mc_hosthdr() -> *const u8;
extern fn mc_build_epoch_fn() -> u64;
// Google (real-internet) path config: resolve mc_dnshost() via DNS at mc_dns_server_ip(), :443.
extern fn mc_tls_google() -> u32;
extern fn mc_dnshost() -> *const u8;
extern fn mc_dns_server_ip() -> u32;

const UART_THR: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;
const HG_MMIO_BASE: usize = 0x10001000;
const HG_MMIO_STRIDE: usize = 0x1000;
const HG_MMIO_COUNT: usize = 8;
const HG_MAGIC: u32 = 0x74726976;
const HG_NET: u32 = 1;
const LOCAL_IP: u32 = 0x0A00_0202;      // 10.0.2.2 slirp gateway -> host loopback
const IOBUF_LEN: usize = 33178;         // BR_SSL_BUFSIZE_BIDI

global framebuf: [2048]u8;
global g_iobuf: [33178]u8;
// 8-aligned opaque BearSSL contexts (u64 arrays sized >= the real struct: cc=3720, xc=3176, ioc=40).
global g_cc: [512]u64;
global g_xc: [512]u64;
global g_ioc: [8]u64;
global g_seed: [64]u8;
global g_req: [256]u8;
global g_tmp: [512]u8;
global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;

fn uputc(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART_THR), c); }
}
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        uputc(b);
        i = i + 1;
    }
}
fn uputhex(v: u64) -> void {
    uputc(48); uputc(120);
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 { uputc((48 + nib) as u8); } else { uputc((87 + nib) as u8); }
        s = s - 4;
    }
}
fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

fn find_net_device() -> MmioPtr<VirtioMmio> {
    var i: usize = 0;
    while i < HG_MMIO_COUNT {
        let slot: usize = HG_MMIO_BASE + i * HG_MMIO_STRIDE;
        var magic: u32 = 0;
        var devid: u32 = 0;
        unsafe {
            magic = raw.load<u32>(phys(slot));
            devid = raw.load<u32>(phys(slot + 8));
        }
        if magic == HG_MAGIC && devid == HG_NET {
            unsafe { return slot as MmioPtr<VirtioMmio>; }
        }
        i = i + 1;
    }
    unsafe { return (0 as usize) as MmioPtr<VirtioMmio>; }
}

// BearSSL low-level transport callbacks. Each forwards to the MC TCP primitive; return -1 on the
// MC error sentinel (0xFFFFFFFF), and low_read also returns -1 on a clean 0 (peer FIN).
export fn low_write(ctx: usize, buf: usize, len: usize) -> i32 {
    var chunk: usize = len;
    if chunk > 1400 { chunk = 1400; } // one segment carries the whole write
    let n: u32 = tls_send(buf, chunk);
    if n == 0xFFFF_FFFF { return -1; }
    return n as i32;
}
export fn low_read(ctx: usize, buf: usize, len: usize) -> i32 {
    let n: u32 = tls_recv(buf, len);
    if n == 0xFFFF_FFFF { return -1; } // error/timeout
    if n == 0 { return -1; }           // peer FIN -> BearSSL treats the read as failed
    return n as i32;
}

// Build "GET / HTTP/1.1\r\nHost: <hosthdr>\r\nConnection: close\r\n\r\n" into g_req; return length.
fn copy_into_req(off: usize, s: *const u8) -> usize {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        g_req[off + i] = b;
        i = i + 1;
    }
    return i;
}
fn build_request() -> usize {
    var n: usize = 0;
    n = n + copy_into_req(n, "GET / HTTP/1.1\r\nHost: ");
    n = n + copy_into_req(n, mc_hosthdr());
    n = n + copy_into_req(n, "\r\nConnection: close\r\n\r\n");
    return n;
}

export fn test_main() -> void {
    uputs("https-get booting\n");
    uputs("BUILD-EPOCH=");
    uputhex(mc_build_epoch_fn());
    uputc(10);
    uputs("SERVER-NAME=");
    uputs(mc_servername());
    uputc(10);

    let regs: MmioPtr<VirtioMmio> = find_net_device();
    if (regs as usize) == 0 {
        uputs("NODEV\n");
        halt();
    }

    // Entropy: pull >= 32 bytes of real randomness from virtio-rng.
    let rng: usize = vrng_find();
    if rng == 0 || vrng_init(rng) == 0 {
        uputs("RNG-INIT-FAILED\n");
        halt();
    }
    let seed_addr: usize = (&g_seed[0]) as usize;
    var got: u32 = 0;
    while got < 32 {
        let k: u32 = vrng_fill(rng, seed_addr + (got as usize), 32);
        if k == 0 { uputs("RNG-EMPTY\n"); halt(); }
        got = got + k;
    }
    if got > 64 { got = 64; }
    uputs("ENTROPY-OK len=");
    uputhex(got as u64);
    uputc(10);

    // Bring the NIC up + ARP the gateway.
    g_rxq.desc = &g_rx_desc; g_rxq.avail = &g_rx_avail; g_rxq.used = &g_rx_used;
    g_txq.desc = &g_tx_desc; g_txq.avail = &g_tx_avail; g_txq.used = &g_tx_used;
    if tls_net_up(regs, &g_rxq, &g_txq, (&framebuf[0]) as usize, 2048) == 0 {
        uputs("NIC-OR-ARP-FAILED\n");
        halt();
    }
    uputs("NET-UP\n");

    var dst_ip: u32 = LOCAL_IP;
    var dst_port: u16 = mc_https_port();
    if mc_tls_google() == 1 {
        // Resolve mc_dnshost() via DNS, then connect to the real IP on :443.
        tls_host_reset();
        let h: usize = mc_dnshost() as usize;
        var hi: usize = 0;
        while true {
            var b: u8 = 0;
            unsafe { b = raw.load<u8>(phys(h + hi)); }
            if b == 0 { break; }
            tls_host_push(b);
            hi = hi + 1;
        }
        dst_ip = tls_resolve(mc_dns_server_ip());
        if dst_ip == 0 {
            uputs("DNS-NO-RESPONSE\n");
            halt();
        }
        uputs("RESOLVED-IP=");
        uputhex(dst_ip as u64);
        uputc(10);
        dst_port = 443;
    }
    if tls_connect(dst_ip, dst_port) == 0 {
        uputs("NO-SYN-ACK\n");
        halt();
    }
    uputs("TCP-CONNECTED\n");

    // The REAL BearSSL TLS 1.2 client. &cc.eng == &cc (engine is the first field).
    let cc: usize = (&g_cc[0]) as usize;
    let xc: usize = (&g_xc[0]) as usize;
    let ioc: usize = (&g_ioc[0]) as usize;
    br_ssl_client_init_full(cc, xc, mc_trust_anchors(), mc_trust_anchors_num());
    br_ssl_engine_set_buffer(cc, (&g_iobuf[0]) as usize, IOBUF_LEN, 1);
    br_ssl_engine_inject_entropy(cc, seed_addr, got as usize);

    // X.509 validation time from the real RTC; fall back to the build epoch if implausible.
    var epoch: u64 = time_now_epoch();
    if epoch < 1700000000 || epoch >= 2000000000 {
        uputs("RTC-IMPLAUSIBLE-USING-BUILD-EPOCH\n");
        epoch = mc_build_epoch_fn();
    } else {
        uputs("X509-TIME-FROM-RTC=");
        uputhex(epoch);
        uputc(10);
    }
    let days: u32 = ((epoch / 86400) + 719528) as u32;
    let secs: u32 = (epoch % 86400) as u32;
    br_set_time(xc, days, secs);

    if br_ssl_client_reset(cc, mc_servername() as usize, 0) == 0 {
        uputs("CLIENT-RESET-FAILED\n");
        halt();
    }
    uputs("TLS-HANDSHAKE-START\n");

    br_sslio_init(ioc, cc, (&low_read) as usize, 0, (&low_write) as usize, 0);

    let reqlen: usize = build_request();
    if br_sslio_write_all(ioc, (&g_req[0]) as usize, reqlen) != 0 {
        uputs("TLS-WRITE-FAILED err=");
        uputhex(br_last_error(cc) as u64);
        uputc(10);
        halt();
    }
    if br_sslio_flush(ioc) != 0 {
        uputs("TLS-FLUSH-FAILED err=");
        uputhex(br_last_error(cc) as u64);
        uputc(10);
        halt();
    }
    uputs("TLS-REQUEST-SENT\n");

    // The handshake has now completed (write forces it). last_error == 0 here is the authoritative
    // proof the server's chain validated against our embedded trust anchor + matched the name.
    let hs_err: i32 = br_last_error(cc);
    uputs("HANDSHAKE-ERROR=");
    uputhex(hs_err as u64);
    uputc(10);
    // Session parameters (informational): br_ssl_engine_get_session_parameters is inline (copies
    // cc->session). Read version/cipher_suite straight from the engine's session field
    // (br_ssl_engine_context.session @1862; .version @+34, .cipher_suite @+36).
    var ver: u16 = 0;
    var cipher: u16 = 0;
    unsafe {
        ver = raw.load<u16>(phys(cc + 1862 + 34));
        cipher = raw.load<u16>(phys(cc + 1862 + 36));
    }
    uputs("TLS-VERSION=");
    uputhex(ver as u64);
    uputc(10);
    uputs("CIPHER-SUITE=");
    uputhex(cipher as u64);
    uputc(10);
    if hs_err == 0 {
        uputs("CERT-CHAIN-VALIDATED\n");
    }

    // Read the decrypted response.
    uputs("RESP-BEGIN\n");
    var total: usize = 0;
    let tmp_addr: usize = (&g_tmp[0]) as usize;
    while true {
        let rd: i32 = br_sslio_read(ioc, tmp_addr, 512);
        if rd <= 0 { break; }
        var i: usize = 0;
        while i < (rd as usize) {
            uputc(g_tmp[i]);
            i = i + 1;
        }
        total = total + (rd as usize);
        if total > 8192 { break; }
    }
    uputs("\nRESP-END\n");
    uputs("RESP-TOTAL=");
    uputhex(total as u64);
    uputc(10);

    let last_err: i32 = br_last_error(cc);
    uputs("LAST-ERROR=");
    uputhex(last_err as u64);
    uputc(10);

    // Honest success: the handshake validated the chain AND we decrypted real application data.
    if hs_err == 0 && total > 0 {
        uputs("HTTPS-GET-OK\n");
    } else {
        if total > 0 {
            uputs("HTTPS-PARTIAL\n");
        } else {
            uputs("HTTPS-NO-DATA\n");
        }
    }
    halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
