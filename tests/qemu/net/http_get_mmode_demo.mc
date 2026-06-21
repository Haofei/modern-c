// Bare-metal riscv64 M-mode (`-bios none`) HTTP-GET runtime — in PURE MC.
// The all-MC replacement for kernel/drivers/virtio/http_get_runtime.c. Drives the
// EXISTING MC TCP/HTTP path (tests/qemu/net/http_get_demo.mc -> the kernel net stack)
// against a real python http.server: ARP -> TCP handshake -> GET -> capture response.
//
// Same boot-seam shape as net_mmode_demo.mc: shared MMIO probe (sbi_virtio_probe.mc),
// two split virtqueues over zeroed Virtq/vring globals, bare-16550 console, and the
// std/dma + std/time platform primitives from the separate mmode_dma_time.mc (8 MiB
// bump pool — TCP drives many unfreed RX refills + TX segments).

import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "tests/qemu/net/http_get_demo.mc"; // http_get_drive / http_resp_len / http_resp_byte

const VIRTIO_ID_NET: u32 = 1;
const HTTP_PORT: u16 = 8080;          // must match tools/net/http-get-test.sh
const UART_THR: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;
global g_framebuf: [2048]u8;

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
    uputc(48); uputc(120); // "0x"
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

// Print the captured response, raw (it is text; CR/LF render as newlines).
fn dump_response() -> void {
    let n: usize = http_resp_len();
    uputs("RESP-LEN=");
    uputhex(n as u64);
    uputc(10);
    uputs("RESP-BEGIN\n");
    var i: usize = 0;
    while i < n {
        uputc(http_resp_byte(i));
        i = i + 1;
    }
    uputs("\nRESP-END\n");
}

export fn test_main() -> void {
    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        uputs("NODEV\n");
        halt();
    }

    g_rxq.desc = &g_rx_desc;
    g_rxq.avail = &g_rx_avail;
    g_rxq.used = &g_rx_used;
    g_txq.desc = &g_tx_desc;
    g_txq.avail = &g_tx_avail;
    g_txq.used = &g_tx_used;

    uputs("http-get booting\n");
    let rxbuf: usize = (&g_framebuf[0]) as usize;
    let st: u32 = http_get_drive(regs, &g_rxq, &g_txq, HTTP_PORT, rxbuf, 2048);
    uputs("DRIVE-STATUS=");
    uputhex(st as u64);
    uputc(10);
    if st == 0 { uputs("NIC-OR-ARP-FAILED\n"); }
    else { if st == 1 { uputs("NO-SYN-ACK\n"); }
    else { if st == 2 { uputs("HANDSHAKE-OK-GET-TX-FAILED\n"); }
    else { if st == 3 { uputs("HANDSHAKE+GET-OK-NO-RESPONSE\n"); }
    else { if st == 4 { uputs("HANDSHAKE+GET+RESPONSE-OK\n"); }
    else { uputs("UNKNOWN\n"); } } } } }

    if st == 4 {
        dump_response();
        uputs("HTTP-GET-OK\n");
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
