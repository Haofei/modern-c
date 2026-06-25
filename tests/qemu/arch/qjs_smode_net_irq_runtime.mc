// S-mode/OpenSBI QuickJS runtime with an IRQ-backed virtio-net host_net_fetch tool.

fn sbi_ecall(ext: u64, fid: u64, arg0: u64, arg1: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a6, %2\n mv a0, %3\n mv a1, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") ext: u64,
                in("t2") fid: u64,
                in("t3") arg0: u64,
                in("t4") arg1: u64,
                clobber("a0"), clobber("a1"), clobber("a6"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}
fn sbi_putchar(c: u8) -> void {
    sbi_ecall(1, 0, c as u64, 0);
}
fn sbi_puts(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        sbi_putchar(b);
        i = i + 1;
    }
}
fn sbi_shutdown() -> void {
    sbi_ecall(8, 0, 0, 0);
    while true {}
}

const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_REGION_LEN: usize = 16 * 1024 * 1024;
const VIRTIO_MMIO_BASE: usize = 0x1000_1000;
const VIRTIO_MMIO_STRIDE: usize = 0x1000;
const VIRTIO_MMIO_COUNT: usize = 8;
const VIRTIO_MMIO_MAGIC: u32 = 0x7472_6976;
const VIRTIO_ID_NET: u32 = 1;

extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn qjs_smode_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64;
extern fn qjs_smode_kernel_not_user(satp: u64, kernel_va: usize) -> u32;
extern fn app_entry() -> u64;
extern fn app_build_status() -> u32;
extern fn mc_app_image() -> usize;
extern fn mc_app_image_len() -> usize;
extern fn app_net_irq_config(regs_base: usize) -> void;

global g_region: [16781312]u8; // 16 MiB + 4 KiB

#[weak]
export fn mc_agent_source(out_len: *mut usize) -> usize {
    unsafe { raw.store<u64>(phys(out_len as usize), 0); }
    return 0;
}

fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

fn print_load_status(s: u32) -> void {
    if s == 1 { sbi_puts("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { sbi_puts("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { sbi_puts("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { sbi_puts("APP-LOAD-FAIL: BadSegment\n"); }
    else { sbi_puts("APP-LOAD-FAIL: unknown\n"); } } } }
}

fn activate_satp(satp: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw satp, %0\n sfence.vma"
                in("t0") satp: u64,
                clobber("memory")
            }
        }
    }
}

fn probe_virtio_net() -> usize {
    var i: usize = 0;
    while i < VIRTIO_MMIO_COUNT {
        let slot: usize = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
        var magic: u32 = 0;
        var devid: u32 = 0;
        unsafe {
            magic = raw.load<u32>(phys(slot));
            devid = raw.load<u32>(phys(slot + 8));
        }
        if magic == VIRTIO_MMIO_MAGIC && devid == VIRTIO_ID_NET {
            return slot;
        }
        i = i + 1;
    }
    return 0;
}

export fn s_entry() -> void {
    sbi_puts("kernel up in S-mode under OpenSBI: loading confined QuickJS IRQ-net agent\n");
    usermode_setup();

    let regs: usize = probe_virtio_net();
    if regs == 0 {
        sbi_puts("NODEV\n");
        sbi_shutdown();
    }
    app_net_irq_config(regs);

    let image_base: usize = mc_app_image();
    let image_len: usize = mc_app_image_len();
    let region: usize = page_align((&g_region[0]) as usize);

    let satp: u64 = qjs_smode_build(image_base, image_len, region, RT_REGION_LEN);
    if satp == 0 {
        print_load_status(app_build_status());
        sbi_shutdown();
    }
    if qjs_smode_kernel_not_user(satp, RT_KERNEL_VA) == 1 {
        sbi_puts("CONFINED: kernel not user-accessible in agent space\n");
    } else {
        sbi_puts("LEAK: kernel user-accessible in agent space\n");
    }

    sbi_puts("kernel: entering confined QuickJS IRQ-net agent\n");
    let entry: u64 = app_entry();
    activate_satp(satp);
    enter_user(entry as usize, entry as usize);
    sbi_shutdown();
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile { "la sp, _stack_top\n call s_entry\n 1: j 1b" }
}
