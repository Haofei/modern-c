// HTTPS-GET runtime, S-mode under REAL OpenSBI — in PURE MC (replaces
// kernel/arch/riscv64/https_get_smode_runtime.c). The S-mode sibling of
// tests/qemu/tls/https_get_runtime.mc: identical REAL BearSSL TLS 1.2 client over the MC TCP
// (tls_demo.mc), but OpenSBI boots us in S-mode at 0x80200000 (a0=hartid, a1=dtb), the console +
// power go through SBI ecalls, the DMA pool + time source (rdtime; the CLINT is not PMP-mapped
// into S-mode) come from sbi_dma_time.mc, and satp stays 0 (Bare). The wall clock for X.509
// validity is the goldfish RTC via time.mc (OpenSBI's PMP permits S-mode MMIO).
//
// BearSSL/openlibm + the brssl-generated trust anchor (local_ta.c) stay vendored C; a 2-line C
// accessor hands MC the TAs pointer + count. Opaque BearSSL contexts are over-sized u64 arrays
// (8-aligned); the static-inline header accessors are inlined via audited field offsets.

import "tests/qemu/tls/tls_demo.mc"; // tls_net_up / tls_connect / tls_send / tls_recv + Virtq/MmioPtr

extern fn mc_trust_anchors() -> usize;
extern fn mc_trust_anchors_num() -> usize;

extern fn br_ssl_client_init_full(cc: usize, xc: usize, tas: usize, num: usize) -> void;
extern fn br_ssl_engine_set_buffer(eng: usize, iobuf: usize, len: usize, bidi: i32) -> void;
extern fn br_ssl_engine_inject_entropy(eng: usize, seed: usize, len: usize) -> void;
extern fn br_ssl_client_reset(cc: usize, name: usize, resume: i32) -> i32;
extern fn br_sslio_init(ioc: usize, eng: usize, lowread: usize, rctx: usize, lowwrite: usize, wctx: usize) -> void;
extern fn br_sslio_write_all(ioc: usize, data: usize, len: usize) -> i32;
extern fn br_sslio_flush(ioc: usize) -> i32;
extern fn br_sslio_read(ioc: usize, dst: usize, len: usize) -> i32;

// br_ssl_engine_last_error / _get_session_parameters / br_x509_minimal_set_time are static-inline
// header accessors (no symbol) — inline them via the audited field offsets.
fn br_last_error(eng: usize) -> i32 {
    var v: i32 = 0;
    unsafe { v = raw.load<i32>(phys(eng)); }
    return v;
}
fn br_set_time(xc: usize, days: u32, secs: u32) -> void {
    unsafe {
        raw.store<u32>(phys(xc + 340), days);
        raw.store<u32>(phys(xc + 344), secs);
    }
}

extern fn vrng_find() -> usize;
extern fn vrng_init(rng: usize) -> u32;
extern fn vrng_fill(rng: usize, buf: usize, n: u32) -> u32;
extern fn time_now_epoch() -> u64;

extern fn mc_https_port() -> u16;
extern fn mc_servername() -> *const u8;
extern fn mc_hosthdr() -> *const u8;
extern fn mc_build_epoch_fn() -> u64;
extern fn mc_tls_google() -> u32;
extern fn mc_dnshost() -> *const u8;
extern fn mc_dns_server_ip() -> u32;

const HG_MMIO_BASE: usize = 0x10001000;
const HG_MMIO_STRIDE: usize = 0x1000;
const HG_MMIO_COUNT: usize = 8;
const HG_MAGIC: u32 = 0x74726976;
const HG_NET: u32 = 1;
const LOCAL_IP: u32 = 0x0A00_0202;
const IOBUF_LEN: usize = 33178;

global framebuf: [2048]u8;
global g_iobuf: [33178]u8;
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

// Local SBI ecall console/power (NOT importing sbi.mc — that pulls std/addr, duplicating tls_demo's).
fn sbi_ecall(ext: u64, fid: u64, arg0: u64, arg1: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a6, %2\n mv a0, %3\n mv a1, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") ext: u64,
                in("t2") fid: u64,
                in("t3") arg0: u64,
                in("t4") arg1: u64,
                clobber("a0"), clobber("a1"), clobber("a6"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}
fn uputc(c: u8) -> void {
    sbi_ecall(1, 0, c as u64, 0); // legacy console putchar
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
    sbi_ecall(8, 0, 0, 0); // legacy shutdown
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

export fn low_write(ctx: usize, buf: usize, len: usize) -> i32 {
    var chunk: usize = len;
    if chunk > 1400 { chunk = 1400; }
    let n: u32 = tls_send(buf, chunk);
    if n == 0xFFFF_FFFF { return -1; }
    return n as i32;
}
export fn low_read(ctx: usize, buf: usize, len: usize) -> i32 {
    let n: u32 = tls_recv(buf, len);
    if n == 0xFFFF_FFFF { return -1; }
    if n == 0 { return -1; }
    return n as i32;
}

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

// OpenSBI enters in S-mode with a0=hartid, a1=dtb.
export fn s_entry(hartid: u64, dtb: u64) -> void {
    uputs("https-smode booting under OpenSBI\n");
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
        if dst_ip == 0 { uputs("DNS-NO-RESPONSE\n"); halt(); }
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

    let cc: usize = (&g_cc[0]) as usize;
    let xc: usize = (&g_xc[0]) as usize;
    let ioc: usize = (&g_ioc[0]) as usize;
    br_ssl_client_init_full(cc, xc, mc_trust_anchors(), mc_trust_anchors_num());
    br_ssl_engine_set_buffer(cc, (&g_iobuf[0]) as usize, IOBUF_LEN, 1);
    br_ssl_engine_inject_entropy(cc, seed_addr, got as usize);

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

    let hs_err: i32 = br_last_error(cc);
    uputs("HANDSHAKE-ERROR=");
    uputhex(hs_err as u64);
    uputc(10);
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

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb; preserve them for s_entry.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
