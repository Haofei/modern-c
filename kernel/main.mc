// kernel/main — the typed kernel entry logic.
//
// The platform layer (arch entry + runtime) clears BSS, sets the stack, discovers
// the virtio-net device, provides the queue memory, and does UART I/O. This is
// the typed orchestration on top: bring the NIC up and exercise the network stack.
// Returns 0 on success or a nonzero stage code, which the platform reports.

import "kernel/drivers/virtio/virtio_net.mc";

const OUR_IP: u32 = 0x0A00_020F;     // 10.0.2.15
const GATEWAY_IP: u32 = 0x0A00_0202; // 10.0.2.2 (slirp gateway)

export fn kernel_main(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq) -> u32 {
    if !nic_init(regs, rxq, txq) {
        return 1; // device bring-up failed
    }
    if !nic_ping_gateway(regs, rxq, txq, OUR_IP, GATEWAY_IP) {
        return 2; // ARP/ICMP round-trip failed
    }
    return 0;
}
