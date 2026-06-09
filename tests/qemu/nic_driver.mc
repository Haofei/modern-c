// Demo network-card driver (Driver Library Profile, §28) — composes every
// driver library into one transmit path and runs on emulated hardware under
// QEMU. The "NIC" transmit register is the QEMU `virt` 16550 UART, so the
// harness can observe the frame the driver sends.
//
// One nic_transmit() call exercises:
//   - std/dma     : a linear DMA buffer, cpu-owned → device-owned → reclaimed
//   - std/sync    : a spinlock guard around the TX ring
//   - std/ring    : a TX descriptor ring
//   - std/endian  : a big-endian (network-order) length header
//   - std/barrier : ordering the descriptor write before the doorbell
//   - typed MMIO  : the device register writes (§17)
//
// The move/linear discipline makes "read after handoff", "double free", and
// "lock left held" compile errors — see std/dma.mc and std/sync.mc.

import "std/sync.mc";
import "std/dma.mc";
import "std/ring.mc";
import "std/endian.mc";
import "std/barrier.mc";

// The TX descriptor ring (const-generic std Ring; zero-initialized as a global).
global g_tx: Ring<usize, 16>;

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    ier: Reg<u8, .read_write>,
    iir: Reg<u8, .read_write>,
    lcr: Reg<u8, .read_write>,
    mcr: Reg<u8, .read_write>,
    lsr: Reg<u8, .read>,
}

fn uart_putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    uart.thr.write(ch, .release);
}

// Build a frame in the DMA buffer: a 2-byte big-endian length header, demonstrating
// std/endian writing into cpu-owned DMA memory before handoff.
fn fill_header(cpu_buf_addr: PAddr, payload_len: u16) -> void {
    let be: u16 = to_be16(payload_len);
    unsafe {
        raw.store<u8>(cpu_buf_addr, (be & 0x00FF) as u8);
        raw.store<u8>(pa_offset(cpu_buf_addr, 1), (be >> 8) as u8);
    }
}

// Transmit one frame, composing the whole driver library profile.
export fn nic_transmit(uart: MmioPtr<Uart16550>, l: *SpinLock) -> void {
    // 1. DMA buffer: allocate cpu-owned, build the header, hand to the device.
    let cpu0: CpuBuffer = alloc(16);
    fill_header(cpu_addr(&cpu0), 10);
    let dev: DeviceBuffer = clean_for_device(cpu0); // cpu0 consumed at handoff
    let desc_addr: usize = device_addr(&dev) as usize; // bus address as a ring word

    // 2. Under the lock, enqueue the TX descriptor on the ring and dequeue it for
    //    transmit; order the descriptor write before the doorbell.
    let g: Guard = lock(l);
    ring_init(usize, 16, &g_tx);
    let pushed: bool = ring_push(usize, 16, &g_tx, desc_addr); // enqueue the descriptor
    let queued: usize = ring_front(usize, 16, &g_tx);          // peek it for transmit
    wmb();

    // 3. Doorbell + payload: write the frame (fixed length) to the device
    //    register (the UART). `queued` is the descriptor that round-tripped the
    //    ring; transmit only when it matches what we enqueued.
    if queued == desc_addr {
        let frame: [10]u8 = .{ 'N', 'I', 'C', '-', 'T', 'X', '-', 'O', 'K', 10 };
        var i: usize = 0;
        while i < 10 {
            uart_putc(uart, frame[i]);
            i = i + 1;
        }
    }
    unlock(g); // guard consumed

    // 4. Reclaim the buffer for the CPU and free it.
    let cpu1: CpuBuffer = invalidate_for_cpu(dev); // dev consumed
    free(cpu1);
}
