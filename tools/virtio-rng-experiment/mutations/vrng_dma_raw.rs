// SPDX-License-Identifier: GPL-2.0-or-later

pub enum DmaOwner { CpuOwned, DeviceOwned }

pub struct DmaBuffer {
    pub cpu: *mut u8,
    pub len: usize,
    pub owner: DmaOwner,
}

// Deliberate raw-FFI-style mutation: the runtime tag does not constrain access.
pub unsafe fn mutated_device_owned_read(buffer: &DmaBuffer) -> u8 {
    unsafe { *buffer.cpu }
}
