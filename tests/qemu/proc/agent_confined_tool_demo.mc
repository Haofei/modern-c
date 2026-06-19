// Step 0 + M1/M3 united — a GENUINELY untrusted agent driving the capability
// stack. The agent runs confined in its own Sv39 address space (kernel unmapped,
// U-mode, no ambient authority — exactly as in agent_confined_demo), and its ONLY
// way to touch the filesystem is a SYS_TOOL syscall that the kernel routes through
// the capability tool front door (agent_fs_call → fs_toolserver path cap).
//
// The agent (untrusted U-mode code it cannot escape) issues two tool calls:
//   write under /workspace  -> ALLOWED by its path capability
//   write under /etc        -> DENIED at the capability check, audited
// The kernel prints ">A<" / ">D<" per verdict. Because the agent has NO mapping of
// the kernel or the tree, it cannot bypass this — the syscall boundary is its only
// exit and the capability check is enforced on the trusted side. This is the M1
// walking skeleton with a real adversarial-shaped agent, not a cooperative one.

import "kernel/core/elf.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/console.mc";
import "kernel/fs/treefs.mc";
import "kernel/fs/fs_toolserver.mc";
import "kernel/fs/agent_fs.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";
import "std/bytes.mc";
import "std/addr.mc";

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const PAGE: usize = 4096;
const SYS_PUTC: usize = 2;
const SYS_TOOL: usize = 5;
const AGENT_PID: u32 = 7;

const AGENT_CODE_VA: usize = 0x4000_0000;
const AGENT_STACK_VA: usize = 0x5000_0000;

global g_heap: Heap;
global g_pt: PageTable;
global g_syscalls: SyscallTable;
global g_tree: Tree;
global g_audit: IpcTrace;
global g_agent: AgentFs;
global g_path: [64]u8;
global g_src: [16]u8;

fn gp() -> usize { return (&g_path[0]) as usize; }
fn put(i: usize, b: u8) -> void { g_path[i] = b; }

// "/workspace"
fn load_ws() -> usize {
    put(0,0x2F); put(1,0x77); put(2,0x6F); put(3,0x72); put(4,0x6B);
    put(5,0x73); put(6,0x70); put(7,0x61); put(8,0x63); put(9,0x65);
    return 10;
}
// "/etc"
fn load_etc() -> usize {
    put(0,0x2F); put(1,0x65); put(2,0x74); put(3,0x63);
    return 4;
}
// "/workspace/f"
fn load_ws_file() -> usize {
    load_ws();
    put(10,0x2F); put(11,0x66);
    return 12;
}
// "/etc/x"
fn load_etc_file() -> usize {
    load_etc();
    put(4,0x2F); put(5,0x78);
    return 6;
}

// Print a verdict marker ">x<\n" so the harness can grep per-call outcomes.
fn mark(c: u8) -> void {
    console_putc(0x3E); // '>'
    console_putc(c);
    console_putc(0x3C); // '<'
    console_putc(0x0A); // '\n'
}

// ----- the agent's syscall surface (its only exit from the isolated space) -----

fn sys_putc(ch: u64, a: u64, b: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

// SYS_TOOL(tool_id, path_id): route a tool request from the untrusted agent
// through the capability front door. path_id 0 = a benign /workspace target,
// 1 = a forbidden /etc target. The agent never names a raw path (no user-pointer
// copy needed); the kernel resolves the id to a path it controls and lets the
// path capability decide.
fn sys_tool(tool: u64, path_id: u64, unused: u64) -> u64 {
    var plen: usize = 0;
    if path_id == 0 {
        plen = load_ws_file();
    } else {
        plen = load_etc_file();
    }
    g_src[0] = 0x7A; // 'z'
    switch agent_fs_call(&g_tree, &g_audit, &g_agent, tool as u32, gp(), plen, 0, (&g_src[0]) as usize, 1, 64) {
        ok(v) => {
            mark(0x41); // '>A<' — allowed
            return 0;
        }
        err(e) => {
            mark(0x44); // '>D<' — denied at the capability check
            return 0xDEAD;
        }
    }
}

export fn syscall_setup() -> void {
    // Build the world + the agent's authority (trusted, kernel-side, before the
    // agent runs): /workspace (its home) and /etc (off-limits).
    tree_init(&g_tree);
    ipc_trace_init(&g_audit);
    var ws: usize = 0;
    switch tree_mkdir(&g_tree, gp(), load_ws()) { ok(i) => { ws = i; } err(e) => {} }
    switch tree_mkdir(&g_tree, gp(), load_etc()) { ok(i) => {} err(e) => {} }
    var tl: Mask32 = mask32_zero();
    mask32_set(&tl, TOOL_FS_WRITE);
    mask32_set(&tl, TOOL_FS_READ);
    g_agent = agent_fs_new(tl, 16, pathcap_root(AGENT_PID, ws, FS_WRITE | FS_READ));

    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
    syscall_register(&g_syscalls, SYS_TOOL, sys_tool);
}

export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}

// ----- ELF load + the isolated address space (as in agent_confined_demo) -----

export fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(elf_base), elf_len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var i: u16 = 0;
            while i < h.phnum {
                var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i as usize);
                if ph_is_load(&ph) {
                    switch elf_load_segment(&r, &ph, pa(dst)) {
                        ok(u) => { return (dst as u64) + (h.entry - ph.vaddr); }
                        err(e) => { return 0; }
                    }
                }
                i = i + 1;
            }
            return 0;
        }
        err(e) => { return 0; }
    }
}

fn map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_pt, &g_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + PAGE;
    }
}

export fn agent_confined_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    map_pages(AGENT_CODE_VA, code_phys, code_len, PTE_R | PTE_X | PTE_U);
    map_pages(AGENT_STACK_VA, stack_phys, stack_len, PTE_R | PTE_W | PTE_U);
    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn agent_code_va() -> u64 {
    return AGENT_CODE_VA as u64;
}

export fn agent_stack_top_va(stack_len: usize) -> u64 {
    return (AGENT_STACK_VA + stack_len) as u64;
}

export fn agent_kernel_unmapped(kernel_va: usize) -> u32 {
    if page_table_is_mapped(&g_pt, va(kernel_va)) {
        return 0;
    }
    return 1;
}
