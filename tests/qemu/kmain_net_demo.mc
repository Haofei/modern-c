// The integrated kernel, now including the network path: boot the five core
// subsystems (heap + console + logger + VFS + scheduler, via `kmain`), then bring up
// the virtio-net device and transmit a real UDP datagram (via `udp_transmit`). One
// image doing storage, scheduling, logging, AND networking together.

import "tests/qemu/kmain_demo.mc";    // kmain() — heap/console/log/VFS/scheduler
import "demo/virtio-net/udp_send.mc"; // nic_init + udp_transmit (+ virtio_net)

export fn kmain_net(region_base: usize, region_len: usize, regs: MmioPtr<VirtioMmio>, txq: *mut Virtq) -> u32 {
    let stages: u32 = kmain(region_base, region_len); // 0x1F if all core subsystems up
    if nic_init(regs, txq) {
        if udp_transmit(regs, txq) {
            return stages | 0x20; // 0x3F = core + networking
        }
    }
    return stages;
}
