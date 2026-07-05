// kernel/platform/qemu_virt — board description for QEMU `virt`.
//
// Centralizes the board-level configuration that was otherwise hard-coded across
// the kernel: the static network identity (our IP, the gateway, our MAC). MMIO
// base addresses that are fixed by the RISC-V platform (CLINT, PLIC) live in
// their arch drivers; the device MMIO base is discovered by the runtime. An ARM
// board provides its own `Machine` constructor with the same shape.

import "kernel/net/ethernet.mc";
import "kernel/net/packet.mc";

pub struct Machine {
    our_ip: Ipv4Addr,
    gateway_ip: Ipv4Addr,
    our_mac: MacAddr,
}

// The default QEMU `virt` slirp network: gateway 10.0.2.2, guest 10.0.2.15.
pub fn qemu_virt() -> Machine {
    return .{
        .our_ip = ipv4(10, 0, 2, 15),
        .gateway_ip = ipv4(10, 0, 2, 2),
        .our_mac = .{ .bytes = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 } },
    };
}
