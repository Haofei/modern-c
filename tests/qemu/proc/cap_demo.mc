// A device driver as a user-mode server, with capability-based least privilege.
// The console server is *granted* the console capability (Cap<usize> over the UART
// base) and is the only process that touches the device. The client holds no
// capability — it cannot name the UART; it prints "HI" only by sending IPC requests.
// This is the MINIX driver-isolation pattern, with least privilege enforced by types.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/capability.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const UART_BASE: usize = 0x1000_0000;
const CONSOLE_PID: u32 = 1;
const TAG_PRINT: u32 = 1;
const TAG_STOP: u32 = 9;

global g_procs: ProcTable;
global g_reaped: u32;

// The console driver server: holds the console capability, serves PRINT requests.
fn console_server() -> void {
    var cap: Cap<usize> = cap_mint(usize, UART_BASE); // granted the console at setup
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == TAG_STOP {
            running = false;
        } else {
            let base: usize = cap_resource(usize, &cap); // use the capability
            let b: u8 = req.a0 as u8;
            unsafe {
                raw.store<u8>(phys(base), b);
            }
        }
    }
    cap_revoke(usize, cap); // consume the (linear) capability before exiting
    proc_exit(&g_procs, 0);
}

// The client: no capability, so it can only print by asking the console server.
fn client() -> void {
    ipc_send(&g_procs, CONSOLE_PID, TAG_PRINT, 0x48, 0, 0); // 'H'
    ipc_send(&g_procs, CONSOLE_PID, TAG_PRINT, 0x49, 0, 0); // 'I'
    ipc_send(&g_procs, CONSOLE_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn cap_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_reaped = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), console_server); // pid 1
    proc_spawn(&g_procs, alloc_stack(&heap), client); // pid 2
    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => {
                g_reaped = g_reaped + 1;
                done = done + 1;
            }
            err(e) => {
                done = 2;
            }
        }
    }
    return g_reaped;
}
