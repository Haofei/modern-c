enum Irq: u8 {
    timer,
}

open enum DeviceState: u8 {
    ready,
}

struct Packet {
    ptr: *mut u8,
    irq: Irq,
    state: DeviceState,
}

extern fn make_ptr() -> *mut u8;
extern fn make_irq() -> Irq;
extern fn make_state() -> DeviceState;
extern fn make_ptrs() -> [2]*mut u8;
extern fn make_irqs() -> [2]Irq;
extern fn make_packet() -> Packet;

fn use_ptr() -> *mut u8 {
    return make_ptr();
}

fn use_irq() -> Irq {
    return make_irq();
}

fn use_open_enum() -> DeviceState {
    return make_state();
}

fn use_ptr_param(p: *mut u8) -> *mut u8 {
    return p;
}

fn use_irq_param(irq: Irq) -> Irq {
    return irq;
}

fn use_packet_ptr(packet: Packet) -> *mut u8 {
    return packet.ptr;
}

fn use_packet_irq(packet: Packet) -> Irq {
    return packet.irq;
}

fn use_packet_open_enum(packet: Packet) -> DeviceState {
    return packet.state;
}

fn use_copied_packet_ptr(packet: Packet) -> *mut u8 {
    let copy = packet;
    return copy.ptr;
}

fn use_copied_packet_irq(packet: Packet) -> Irq {
    let copy = packet;
    return copy.irq;
}

fn use_copied_call_packet_ptr() -> *mut u8 {
    let copy = make_packet();
    return copy.ptr;
}

fn use_copied_call_packet_irq() -> Irq {
    let copy = make_packet();
    return copy.irq;
}

fn use_packet_ptr_deref(packet: Packet) -> u8 {
    return packet.ptr.*;
}

fn compare_packet_ptrs(left: Packet, right: Packet) -> bool {
    return left.ptr == right.ptr;
}

fn compare_irq_values(left: Packet, right: Packet) -> bool {
    return left.irq == right.irq;
}

fn compare_irq_literal(irq: Irq) -> bool {
    return .timer == irq;
}

fn use_array_ptr(values: [2]*mut u8) -> *mut u8 {
    return values[0];
}

fn use_array_irq(values: [2]Irq) -> Irq {
    return values[0];
}

fn use_copied_array_ptr(values: [2]*mut u8) -> *mut u8 {
    let copy = values;
    return copy[0];
}

fn use_copied_array_irq(values: [2]Irq) -> Irq {
    let copy = values;
    return copy[0];
}

fn use_call_array_ptr() -> *mut u8 {
    return make_ptrs()[0];
}

fn use_call_array_irq() -> Irq {
    return make_irqs()[0];
}

fn use_copied_call_array_ptr() -> *mut u8 {
    let copy = make_ptrs();
    return copy[0];
}

fn use_copied_call_array_irq() -> Irq {
    let copy = make_irqs();
    return copy[0];
}
