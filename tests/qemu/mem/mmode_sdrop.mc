// Shared M-mode -> S-mode privilege drop, in PURE MC. The bare M-mode VM runtimes
// (`-bios none`) all do the SAME thing once their page table is built: delegate every
// trap to S-mode (medeleg/mideleg = all-ones), open a full-memory PMP window so S/U
// may touch physical RAM (pmpaddr0 = all-ones TOR/NAPOT, pmpcfg0 = 0x1f = NAPOT R|W|X),
// set mstatus.MPP = S (clear bits 12:11, set bit 11), point mepc at the S-mode entry,
// and `mret`. This factors that asm out of each runtime.
//
// MC precise-asm operands lower to GENERIC `"r"` constraints (the names are provenance
// only, not pinning), so the immediate constants are passed AS register operands rather
// than open-coded with `li t0, ...` — that avoids naming any hard temp register (a `t0`
// clobber is rejected by the C backend's clang as an unknown register name), and the
// allocator is free to place each value in whatever caller-saved temporary it likes.

const DELEG_ALL: u64 = 0xFFFF;                       // medeleg/mideleg: delegate all
const PMP_ALL: u64 = 0xFFFF_FFFF_FFFF_FFFF;          // pmpaddr0: cover all of memory
const PMP_NAPOT_RWX: u64 = 0x1F;                     // pmpcfg0: NAPOT, R|W|X
const MPP_MASK: u64 = 0x1800;                        // mstatus.MPP field (bits 12:11)
const MPP_S: u64 = 0x800;                            // mstatus.MPP = 01 (S-mode)

// Drop from M-mode to S-mode, resuming at `entry` (an S-mode function address) with
// paging already configured by the caller's satp. Never returns.
export fn drop_to_smode(entry: usize) -> void {
    let deleg: u64 = DELEG_ALL;
    let pmpaddr: u64 = PMP_ALL;
    let pmpcfg: u64 = PMP_NAPOT_RWX;
    let mpp_mask: u64 = MPP_MASK;
    let mpp_s: u64 = MPP_S;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw medeleg, %1\n csrw mideleg, %1\n csrw pmpaddr0, %2\n csrw pmpcfg0, %3\n csrc mstatus, %4\n csrs mstatus, %5\n csrw mepc, %0\n mret"
                in("r") entry: usize,
                in("r") deleg: u64,
                in("r") pmpaddr: u64,
                in("r") pmpcfg: u64,
                in("r") mpp_mask: u64,
                in("r") mpp_s: u64
                clobber("memory")
            }
        }
    }
    while true {}
}

// Activate a page table (write satp) and flush the TLB. Used by S-mode entry code to
// turn paging on, and to switch between address spaces.
export fn activate_satp(satp: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw satp, %0\n sfence.vma"
                in("r") satp: u64
                clobber("memory")
            }
        }
    }
}
