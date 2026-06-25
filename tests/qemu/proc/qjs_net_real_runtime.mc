// M-mode runtime for a confined QuickJS agent with a TCP-backed host_net_fetch tool.
//
// This is qjs_confined_runtime plus the virtio-net seam: probe the NIC, wire RX/TX queues, configure
// app_run_demo's TCP-backed broker hook, then load and enter the fixed QuickJS host. The JS agent
// still reaches the kernel only through SYS_SUBMIT/SYS_POLL; the kernel-side tool dispatch uses the
// real net_fetch_tcp transport.

import "tests/qemu/lib/test_report.mc";
import "std/virtio.mc";
import "std/virtqueue.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";

const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_REGION_LEN: usize = 16 * 1024 * 1024;
const VIRTIO_ID_NET: u32 = 1;
const HTTP_PORT: u16 = 8080;

extern fn mc_halt() -> void;
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn mc_app_image() -> usize;
extern fn mc_app_image_len() -> usize;
extern fn app_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64;
extern fn app_build_status() -> u32;
extern fn app_entry() -> u64;
extern fn app_kernel_unmapped(kernel_va: usize) -> u32;
extern fn app_net_real_config(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, dst_port: u16) -> void;

global g_region: [16781312]u8; // 16 MiB + 4 KiB
global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;

#[weak]
export fn mc_agent_source(out_len: *mut usize) -> usize {
    unsafe { raw.store<u64>(phys(out_len as usize), 0); }
    return 0;
}

fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

fn print_load_status(s: u32) -> void {
    if s == 1 { uputs("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { uputs("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { uputs("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { uputs("APP-LOAD-FAIL: BadSegment\n"); }
    else { uputs("APP-LOAD-FAIL: unknown\n"); } } } }
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

export fn test_main() -> void {
    uputs("kernel: loading confined QuickJS agent with real net tool\n");
    usermode_setup();

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        uputs("NODEV\n");
        mc_halt();
    }

    g_rxq.desc = &g_rx_desc;
    g_rxq.avail = &g_rx_avail;
    g_rxq.used = &g_rx_used;
    g_txq.desc = &g_tx_desc;
    g_txq.avail = &g_tx_avail;
    g_txq.used = &g_tx_used;
    app_net_real_config(regs, &g_rxq, &g_txq, HTTP_PORT);

    let image_base: usize = mc_app_image();
    let image_len: usize = mc_app_image_len();
    let region: usize = page_align((&g_region[0]) as usize);

    let satp: u64 = app_build(image_base, image_len, region, RT_REGION_LEN);
    if satp == 0 {
        print_load_status(app_build_status());
        mc_halt();
    }
    if app_kernel_unmapped(RT_KERNEL_VA) == 1 {
        uputs("CONFINED: kernel unmapped in agent space\n");
    } else {
        uputs("LEAK: kernel mapped in agent space\n");
    }

    uputs("kernel: entering confined QuickJS agent\n");
    let entry: u64 = app_entry();
    activate_satp(satp);
    enter_user(entry as usize, entry as usize);
    mc_halt();
}
