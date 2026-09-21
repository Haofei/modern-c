enum Irq: u8 {
    timer,
}

open enum DeviceState: u8 {
    ready,
}

fn checked_ptr_param(p: *mut u8) -> *mut u8 {
    return p;
}

fn checked_irq_param(irq: Irq) -> Irq {
    return irq;
}

fn checked_open_enum(state: DeviceState) -> DeviceState {
    return state;
}

#[no_lang_trap]
fn reject_no_lang_ptr_param(p: *mut u8) -> *mut u8 {
    return p;
}

#[no_lang_trap]
fn reject_no_lang_irq_param(irq: Irq) -> Irq {
    return irq;
}
