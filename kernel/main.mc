// kernel/main — the typed kernel entry logic.
//
// The platform layer (arch entry + runtime) clears BSS, sets the stack, provides
// the queue memory, and does UART I/O. This is the typed orchestration on top:
// read the board description, discover the NIC on the virtio-mmio bus, bring it
// up, and exercise the network stack. Returns 0 on success or a nonzero stage
// code, which the platform reports.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/platform/qemu_virt/machine.mc";

export fn kernel_main(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq) -> u32 {
    var m: Machine = qemu_virt(); // board description — the single source of config
    var dev: NetDevice = .{ .regs = regs, .rxq = rxq, .txq = txq }; // device-class surface

    // The driver reports typed `NetError`s; the platform boundary is a small
    // stage code (0 = ok). The error tag is available for richer logging.
    switch nic_init(&dev) {
        ok(ready) => {}
        err(e) => { return 1; } // device bring-up failed
    }
    switch nic_ping_gateway(&dev, &m.our_mac, m.our_ip, m.gateway_ip) {
        ok(done) => { return 0; }
        err(e) => { return 2; } // ARP/ICMP round-trip failed
    }
}
