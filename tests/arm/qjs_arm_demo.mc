// M9 "confined QuickJS agent on AArch64 EL0" — MC side.
//
// The AArch64 analogue of tests/x86/qjs_x86_demo.mc (x86 M7) and tests/qemu/arch/qjs_smode_demo.mc
// (RISC-V M3). It is the same composition the x86 fixture is — a real multi-segment ELF loader +
// the QuickJS syscall ABI (SYS_WRITE / SYS_READ §0 ingress / SYS_GETPID / SYS_SUBMIT / SYS_POLL +
// the mock broker) + a confinement proof — but built on the AArch64 stage-1 paging stack:
//   - the loader is the GENERIC kernel/core/elf_loader.mc and user-copy is the GENERIC
//     kernel/core/uaccess_pt.mc; both resolve AArch64 paging via the arch-selection seam
//     (compiled with --arch=aarch64, R0b). Arch-specific leaf attributes come from the paging
//     module's pte_flags_for_user hook;
//   - console output goes through an EXTERN mc_console_putc the AArch64 C runtime provides over
//     the PL011 UART MMIO. Unlike x86's port-IO COM1, the UART is MMIO, so the agent's TTBR0
//     maps the UART page as a Device EL1-only page (EL0 never touches it; only the kernel's
//     SYS_WRITE handler writes the MMIO);
//   - the address space is built like M8's user_arm_demo.mc: app_build_aarch64 loads the agent's
//     own EL0 pages (via the loader), then adds the kernel's RAM identity window as EL1-only
//     2 MiB blocks (FLAGS_KERNEL_RWX => not EL0-accessible) so the EL1 kernel + the SVC trap path
//     survive the TTBR0 switch while staying unreachable from EL0. The confinement proof is M8's
//     "kernel mapped but NOT EL0-accessible".
//
// app_build_aarch64 returns the TTBR0 (L0 table phys) through an out-pointer — no by-value
// >16-byte FFI struct return (the AArch64 ABI note). All fixture-local consts/symbols are
// prefixed (QA_/qa_/app_*_aarch64) to avoid emit-c const-flatten collisions; there is no riscv/
// x86 fixture imported here, so the names are fully disjoint.

import "kernel/core/elf_loader.mc"; // generic loader; arch PTE flags via --arch=aarch64
import "kernel/arch/aarch64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/uaccess_pt.mc"; // arch-neutral page-table uaccess (resolves aarch64 paging via --arch)
import "std/addr.mc";
import "user/abi.mc"; // SYS_* numbers + E_* + ToolReq/ToolEvent — the single ABI source of truth

// The agent ELF is linked at 256 MiB (user_qjs_aarch64.ld), BELOW the kernel's RAM identity
// window (QEMU virt RAM base 0x4000_0000 = 1 GiB), so the agent's EL0 VAs never collide with the
// kernel's EL1-only pages.
const QA_USER_BASE: usize = 0x1000_0000;
// Upper bound for uaccess validation: must cover the agent's whole VA span from USER_BASE
// (multi-MiB engine image + the 8 MiB malloc arena + the 512 KiB stack, all in .bss right after
// the image). 256 MiB + 256 MiB gives ample headroom above the agent's top while staying below
// the kernel's 1 GiB window.
const QA_USER_LIMIT: usize = 0x1000_0000 + 0x1000_0000;
const QA_KBUF: usize = 256;
const QA_AGENT_PID: u64 = 7;
const QA_COMP_CAP: usize = 8;

// QEMU virt: RAM base 0x4000_0000. The kernel image/stack/heap/vectors + the frame `region` pool
// (the agent's page tables + per-page frames) all live in low RAM here. Map the RAM identity
// window as EL1-only 2 MiB blocks so the kernel survives the TTBR0 switch yet EL0 cannot reach
// it. 256 MiB covers the kernel image + the 16 MiB region with ample headroom; the agent sits at
// 256 MiB (below this window), so there is no overlap.
const QA_RAM_BASE: usize = 0x4000_0000;
const QA_RAM_SPAN: usize = 0x1000_0000; // 256 MiB of low RAM mapped EL1-only
const QA_BLOCK_2MIB: usize = 0x20_0000;
const QA_UART_PA: usize = 0x0900_0000;  // PL011 UART (Device memory, EL1-only)

// app_build status codes (typed LoadError preserved across the u64-TTBR0 C ABI boundary).
const QA_LS_OK: u32 = 0;
const QA_LS_BADELF: u32 = 1;
const QA_LS_TOOMANY: u32 = 2;
const QA_LS_NOFRAME: u32 = 3;
const QA_LS_BADSEG: u32 = 4;

global qa_heap: Heap;
global qa_pt: PageTable;
global qa_uas: UserAddrSpace;
global qa_syscalls: SyscallTable;
global qa_kbuf: [QA_KBUF]u8;
global qa_entry: u64;
global qa_load_status: u32;

// Result-payload buffer sizes (mirror MAX_REQ_BYTES / MAX_RES_BYTES).
const QA_REQ_BYTES: usize = 256;
const QA_RES_BYTES: usize = 256;
const QA_DELAY_MAX: u64 = 64;

global qa_slot_active: [QA_COMP_CAP]bool;
global qa_slot_id: [QA_COMP_CAP]u64;
global qa_slot_status: [QA_COMP_CAP]i32;
global qa_slot_result: [QA_COMP_CAP]i32;
global qa_slot_outptr: [QA_COMP_CAP]u64;
global qa_slot_outcap: [QA_COMP_CAP]u32;
global qa_slot_outlen: [QA_COMP_CAP]u32;
global qa_slot_res: [QA_COMP_CAP][QA_RES_BYTES]u8;
global qa_slot_ready: [QA_COMP_CAP]u64;
global qa_clock: u64;
global qa_active_count: usize;
global qa_next_req: u64;
global qa_reqbuf: [QA_REQ_BYTES]u8;

// The AArch64 console: PL011 UART MMIO, written by the C runtime (qjs_user_runtime.c). EL0 never
// touches it; only this kernel SYS_WRITE handler reaches the MMIO (via the extern).
extern fn mc_console_putc(c: u8) -> void;

fn qa_free_slot() -> usize {
    var i: usize = 0;
    while i < QA_COMP_CAP {
        if !qa_slot_active[i] {
            return i;
        }
        i = i + 1;
    }
    return QA_COMP_CAP;
}

fn qa_slot_by_id(target: u64) -> usize {
    var i: usize = 0;
    while i < QA_COMP_CAP {
        if qa_slot_active[i] && qa_slot_id[i] == target {
            return i;
        }
        i = i + 1;
    }
    return QA_COMP_CAP;
}

// Forge a UserPtr<u8> from a user-supplied integer address (the uaccess idiom): re-tagging an
// int into the UserPtr class needs `unsafe`; copy_*_user_pt still validates it per-page.
fn qa_uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe {
        p = a as UserPtr<u8>;
    }
    return p;
}

// SYS_WRITE(fd, buf, len): copy the user buffer in through the agent's page table, emit it via
// the PL011 UART. Returns bytes written, or -E_FAULT on a bad user pointer.
fn qa_sys_write(fd: u64, buf: u64, len: u64) -> u64 {
    var n: usize = len as usize;
    if n > QA_KBUF {
        n = QA_KBUF;
    }
    let dst: PAddr = pa((&qa_kbuf[0]) as usize);
    switch copy_from_user_pt(&qa_uas, dst, qa_uptr(buf as usize), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    var i: usize = 0;
    while i < n {
        mc_console_putc(qa_kbuf[i]);
        i = i + 1;
    }
    return n as u64;
}

fn qa_sys_getpid(a: u64, b: u64, c: u64) -> u64 {
    return QA_AGENT_PID;
}

// The agent source the kernel holds (embedded by the harness): returns its kernel address and
// length. A weak default in the C runtime returns nothing for tests that embed no agent.
extern fn mc_agent_source(out_len: *mut usize) -> usize;

// SYS_READ(buf, max): §0 ingress — copy the kernel-held agent source into the agent's buffer
// (through its page table), capped at `max`. Returns bytes delivered.
fn qa_sys_read(buf: u64, max: u64, c: u64) -> u64 {
    var src_len: usize = 0;
    let src_addr: usize = mc_agent_source(&src_len);
    if src_addr == 0 || src_len == 0 {
        return 0;
    }
    var n: usize = src_len;
    if n > (max as usize) {
        n = max as usize;
    }
    switch copy_to_user_pt(&qa_uas, qa_uptr(buf as usize), pa(src_addr), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    return n as u64;
}

// SYS_SUBMIT(req_ptr): start a non-blocking mock tool op described by a ToolReq the agent points
// at. Snapshot-copy the struct in, validate payload sizes against the hard quotas, copy the
// request payload into a bounded kernel buffer, arm a completion slot with a delay-driven ready
// tick (so completions can arrive out of submit order). Returns the request id, or a -errno.
fn qa_sys_submit(req_ptr: u64, b: u64, c: u64) -> u64 {
    var req_buf: ToolReq = uninit;
    let rsz: usize = sizeof(ToolReq);
    switch copy_from_user_pt(&qa_uas, pa((&req_buf) as usize), qa_uptr(req_ptr as usize), rsz) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    // Re-read the snapshot through the same raw address the copy filled: definite-init
    // (S0.1) cannot see writes made through a raw address, so direct `req_buf.` reads
    // would be rejected (the kernel/core/uaccess.mc fetch idiom).
    let req: *ToolReq = raw.ptr<ToolReq>(pa((&req_buf) as usize));

    if req.in_len > MAX_REQ_BYTES {
        return bitcast<u64>(E_NOCAP);
    }
    if req.out_cap > MAX_RES_BYTES {
        return bitcast<u64>(E_NOCAP);
    }

    if req.op == TOOL_OP_CANCEL {
        let s: usize = qa_slot_by_id(req.arg);
        if s == QA_COMP_CAP {
            return bitcast<u64>(E_DENIED);
        }
        qa_slot_status[s] = E_CANCELED as i32;
        qa_slot_result[s] = 0;
        qa_slot_outlen[s] = 0;
        qa_slot_ready[s] = qa_clock;
        return 0;
    }

    if req.op != TOOL_OP_SUM && req.op != TOOL_OP_ECHO && req.op != TOOL_OP_TIMEOUT && req.op != TOOL_OP_SPURIOUS {
        return bitcast<u64>(E_DENIED);
    }

    let slot: usize = qa_free_slot();
    if slot == QA_COMP_CAP {
        return bitcast<u64>(E_AGAIN);
    }

    let in_len: usize = req.in_len as usize;
    if in_len > 0 {
        switch copy_from_user_pt(&qa_uas, pa((&qa_reqbuf[0]) as usize), qa_uptr(req.in_ptr as usize), in_len) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }

    let id: u64 = qa_next_req;
    qa_next_req = qa_next_req + 1;
    var delay: u64 = req.flags as u64;
    if delay > QA_DELAY_MAX {
        delay = QA_DELAY_MAX;
    }
    qa_slot_active[slot] = true;
    qa_slot_id[slot] = id;
    qa_slot_status[slot] = 0;
    qa_slot_outptr[slot] = req.out_ptr;
    qa_slot_outcap[slot] = req.out_cap;
    qa_slot_outlen[slot] = 0;
    qa_slot_ready[slot] = qa_clock + delay;
    qa_active_count = qa_active_count + 1;

    if req.op == TOOL_OP_SUM {
        let mask: u64 = 0x7FFF_FFFF;
        let a32: u32 = (req.arg & mask) as u32;
        qa_slot_result[slot] = (a32 + 2) as i32;
    } else if req.op == TOOL_OP_ECHO {
        var n: usize = in_len;
        if n > (req.out_cap as usize) {
            n = req.out_cap as usize;
        }
        var i: usize = 0;
        while i < n {
            qa_slot_res[slot][i] = qa_reqbuf[i];
            i = i + 1;
        }
        qa_slot_outlen[slot] = n as u32;
        qa_slot_result[slot] = n as i32;
    } else if req.op == TOOL_OP_TIMEOUT {
        qa_slot_status[slot] = E_TIMEDOUT as i32;
        qa_slot_result[slot] = 0;
    } else {
        qa_slot_result[slot] = 0;
        qa_slot_id[slot] = id + 1000000;
    }

    return id;
}

// SYS_POLL(events_ptr, max_arg, timeout): the VECTOR completion drain. Advances the virtual clock
// up to (1 + timeout) times, delivering every READY completion (smallest ready tick first —
// out-of-order delivery) into the ToolEvent[] at events_ptr (i-th event at offset i*sizeof(ToolEvent)),
// up to `max`. Returns the count delivered (0..max), or -E_FAULT if the FIRST event copy faults.
// max_arg==0 is treated as 1 (single-event back-compat); (max==1, timeout==0) matches the original.
fn qa_sys_poll(events_ptr: u64, max_arg: u64, timeout: u64) -> u64 {
    var want: usize = max_arg as usize;
    if max_arg == 0 {
        want = 1; // back-compat: a1==0 means a single event
    }
    var count: usize = 0;

    var steps: u64 = 0;
    let max_steps: u64 = 1 + timeout;
    while steps < max_steps {
        steps = steps + 1;
        qa_clock = qa_clock + 1;

        while count < want {
            if qa_active_count == 0 {
                break;
            }
            var best: usize = QA_COMP_CAP;
            var i: usize = 0;
            while i < QA_COMP_CAP {
                if qa_slot_active[i] && qa_slot_ready[i] <= qa_clock {
                    if best == QA_COMP_CAP || qa_slot_ready[i] < qa_slot_ready[best] || (qa_slot_ready[i] == qa_slot_ready[best] && qa_slot_id[i] < qa_slot_id[best]) {
                        best = i;
                    }
                }
                i = i + 1;
            }
            if best == QA_COMP_CAP {
                break;
            }

            let outlen: usize = qa_slot_outlen[best] as usize;

            if outlen > 0 {
                switch copy_to_user_pt(&qa_uas, qa_uptr(qa_slot_outptr[best] as usize), pa((&qa_slot_res[best][0]) as usize), outlen) {
                    ok(v) => {}
                    err(e) => {
                        if count > 0 { return count as u64; }
                        return bitcast<u64>(E_FAULT);
                    }
                }
            }

            var ev: ToolEvent = uninit;
            ev.id = qa_slot_id[best];
            ev.status = qa_slot_status[best];
            ev.result = qa_slot_result[best];
            ev.out_len = qa_slot_outlen[best];
            ev.reserved = 0;
            let esz: usize = sizeof(ToolEvent);
            switch copy_to_user_pt(&qa_uas, qa_uptr((events_ptr as usize) + count * esz), pa((&ev) as usize), esz) {
                ok(v) => {}
                err(e) => {
                    if count > 0 { return count as u64; }
                    return bitcast<u64>(E_FAULT);
                }
            }

            qa_slot_active[best] = false;
            qa_active_count = qa_active_count - 1;
            count = count + 1;
        }

        if count == want || qa_active_count == 0 {
            break;
        }
    }

    return count as u64;
}

// Register the userspace ABI handlers. Called by the C trap bring-up before the app runs.
export fn syscall_setup() -> void {
    syscall_init(&qa_syscalls);
    syscall_register(&qa_syscalls, SYS_WRITE as usize, qa_sys_write);
    syscall_register(&qa_syscalls, SYS_READ as usize, qa_sys_read);
    syscall_register(&qa_syscalls, SYS_GETPID as usize, qa_sys_getpid);
    syscall_register(&qa_syscalls, SYS_SUBMIT as usize, qa_sys_submit);
    syscall_register(&qa_syscalls, SYS_POLL as usize, qa_sys_poll);
}

// Called by the C trap for each svc #0 syscall (number x8, args x0/x1/x2). SYS_EXIT is handled
// by the trap before this; everything else dispatches through the registered table.
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&qa_syscalls, number, arg0, arg1, arg2);
}

// Build the agent's isolated AArch64 EL0 space from the app image: load the QuickJS ELF (its own
// EL0 pages only) via the AArch64 loader, then add the kernel's RAM identity window (EL1-only)
// plus the UART Device page so the kernel survives the TTBR0 switch. Returns 1 on success and
// writes the TTBR0 (L0 table phys) through `out_ttbr0`; on a load failure returns 0 and records
// the cause in qa_load_status.
export fn app_build_aarch64(image_base: usize, image_len: usize, region_base: usize, region_len: usize, out_ttbr0: *mut u64) -> u32 {
    qa_load_status = QA_LS_OK;
    *out_ttbr0 = 0;
    qa_heap = heap_new(phys_range(pa(region_base), region_len));

    switch page_table_try_new(&qa_heap) {
        ok(pt) => { qa_pt = pt; }
        err(e) => { qa_load_status = QA_LS_NOFRAME; return 0; }
    }

    switch elf_load_image(image_base, image_len, &qa_pt, &qa_heap) {
        ok(e) => { qa_entry = e; }
        err(e) => {
            switch e {
                .BadElf => { qa_load_status = QA_LS_BADELF; }
                .TooManyPages => { qa_load_status = QA_LS_TOOMANY; }
                .NoFrame => { qa_load_status = QA_LS_NOFRAME; }
                .BadSegment => { qa_load_status = QA_LS_BADSEG; }
            }
            return 0;
        }
    }

    // Kernel RAM identity window: low RAM as 2 MiB blocks, EL1 RW + PXN clear (FLAGS_KERNEL_RWX)
    // so the EL1 kernel (image + stack + heap + vectors + the frame `region` pool, all in low
    // RAM) keeps fetching/executing after the TTBR0 switch while staying unreachable from EL0
    // (mapping_is_user is false here). The agent lives at 256 MiB (below this window), so there
    // is no overlap.
    var off: usize = 0;
    while off < QA_RAM_SPAN {
        let addr: usize = QA_RAM_BASE + off;
        page_table_map_block_2mib(&qa_pt, &qa_heap, va(addr), pa(addr), FLAGS_KERNEL_RWX);
        off = off + QA_BLOCK_2MIB;
    }

    // PL011 UART page as Device memory (EL1 RW, no execute) so the SYS_WRITE MMIO survives the
    // TTBR0 switch. EL0 never maps this — it is the kernel's alone.
    page_table_map(&qa_pt, &qa_heap, va(QA_UART_PA), pa(QA_UART_PA), FLAGS_DEVICE);

    qa_uas = user_addr_space(&qa_pt, QA_USER_BASE, QA_USER_LIMIT);
    *out_ttbr0 = page_table_ttbr0(&qa_pt);
    return 1;
}

export fn app_build_status_aarch64() -> u32 {
    return qa_load_status;
}

export fn app_entry_aarch64() -> u64 {
    return qa_entry;
}

// Confinement proof (M8 form): a kernel VA is mapped (so EL1 + the trap path survive the TTBR0
// switch) but is NOT EL0-accessible (AP low bit clear at the leaf), so an EL0 touch faults.
// Returns 1 iff the kernel page lacks EL0 access.
export fn app_kernel_not_user_aarch64(kernel_va: usize) -> u32 {
    switch page_table_lookup(&qa_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; } // unmapped: the kernel couldn't run — not proven
    }
}

// Confinement proof #2: the agent's own entry (code) page IS EL0-accessible.
export fn app_entry_is_user_aarch64() -> u32 {
    switch page_table_lookup(&qa_pt, va(qa_entry as usize)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}
