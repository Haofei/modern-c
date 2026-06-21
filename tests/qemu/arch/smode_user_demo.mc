// M2 "RISC-V S-mode user hello" — MC side.
//
// Under REAL OpenSBI the kernel runs in S-mode (not M-mode), so satp IS effective
// for the kernel itself. We therefore build an Sv39 space that:
//   - identity-maps the kernel image + its working memory as SUPERVISOR pages
//     (R|W|X, NO PTE_U) via a gigapage, so the S-mode trap handler keeps running
//     after the satp is activated; and
//   - maps the agent's code (R|X|U) and stack (R|W|U) as USER pages at VAs far from
//     the kernel, valid ONLY through this page table.
// The MMU boundary: U-mode can reach the agent's own pages but NOT the kernel's
// (no PTE_U on the gigapage), so the agent can only enter the kernel by trapping
// (ecall -> SYS_WRITE / SYS_EXIT). copy_from_user_pt then walks THIS page table to
// validate a user pointer before the kernel ever touches it, returning -EFAULT for
// an unmapped/non-user/straddling pointer without dereferencing it.
//
// This is the S-mode analogue of agent_confined_demo.mc (which relies on M-mode
// ignoring satp). The boot/trap/U-mode-drop bring-up — once smode_user_runtime.c —
// is now folded in below (pure MC, no C).

import "kernel/core/elf.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/uaccess.mc";
import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "std/addr.mc";
import "std/bytes.mc";

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const PAGE: usize = 4096;
const GIGA: usize = 0x4000_0000; // 1 GiB Sv39 gigapage

// The agent's view of itself. Deliberately far from the kernel (0x8000_0000) and
// MMIO, so these VAs resolve ONLY through the agent's page table.
const AGENT_CODE_VA: usize = 0x4000_0000;
const AGENT_STACK_VA: usize = 0x5000_0000;

// The supervisor (kernel) identity window: the whole 1 GiB gigapage containing the
// OpenSBI payload load address 0x8020_0000. Mapped R|W|X with NO PTE_U.
const KERNEL_GIGA_BASE: usize = 0x8000_0000;

// Linux-conventional EFAULT. No E_FAULT symbol exists in-tree; we use 14 and return
// it negated as a 2's-complement i64 (sign bit set) so the U-mode app sees a0 < 0.
const EFAULT: i64 = 14;

global g_heap: Heap;
global g_pt: PageTable;
global g_stack_len: usize;

// ELF load (parse + copy the PT_LOAD segment to a physical landing frame). Same shape
// as agent_confined_demo.mc — the bring-up calls this before smode_space_build.
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

// Map [virt, virt+len) -> [phys, phys+len) one 4 KiB page at a time with `flags`.
fn map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_pt, &g_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + PAGE;
    }
}

// Build the agent's Sv39 space. `region` backs the page tables. `code_phys`/`stack_phys`
// are physical frames the bring-up already populated. Returns the satp to activate.
export fn smode_space_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    g_stack_len = stack_len;

    // Supervisor identity window for the kernel (no PTE_U): keeps the S-mode trap
    // handler executing after satp activation, while remaining unreachable from U.
    page_table_map_gigapage(&g_pt, va(KERNEL_GIGA_BASE), pa(KERNEL_GIGA_BASE), PTE_R | PTE_W | PTE_X);

    // The agent's user pages.
    map_pages(AGENT_CODE_VA, code_phys, code_len, PTE_R | PTE_X | PTE_U);
    map_pages(AGENT_STACK_VA, stack_phys, stack_len, PTE_R | PTE_W | PTE_U);

    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn agent_code_va() -> u64 { return AGENT_CODE_VA as u64; }
export fn agent_stack_top_va() -> u64 { return (AGENT_STACK_VA + g_stack_len) as u64; }

// Confinement proof: a kernel VA is mapped (so S-mode runs) but is NOT user-accessible,
// so a direct kernel touch from U-mode faults. 1 iff kernel page lacks PTE_U.
export fn kernel_not_user(kernel_va: usize) -> u32 {
    switch page_table_lookup(&g_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; } // unmapped: the kernel couldn't run — treat as not-proven
    }
}

// Confinement proof #2: the agent's code page is user-accessible (its own page).
export fn agent_code_is_user() -> u32 {
    switch page_table_lookup(&g_pt, va(AGENT_CODE_VA)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}

// Re-tag an integer user VA into the UserPtr<u8> address class (audited boundary —
// copy_from_user_pt still validates it against the page table). Matches the uaccess idiom.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

// SYS_WRITE copy-in handler: validate [user_ptr, user_ptr+len) against the agent's
// page table and copy into the kernel buffer at `kdst`. Returns bytes copied on Ok, or
// -EFAULT on any validation failure (unmapped / non-user / straddling) — the kernel
// never dereferences a bad user pointer. `len` is clamped by the caller's bounded buffer.
export fn sys_write_copyin(user_ptr: usize, len: usize, kdst: usize) -> i64 {
    // The agent's whole user range; copy_from_user_pt does the per-page PTE_U/PTE_R walk.
    var uas: UserAddrSpace = user_addr_space(&g_pt, 0, 0x8000_0000);
    switch copy_from_user_pt(&uas, pa(kdst), uptr(user_ptr), len) {
        ok(v) => { return len as i64; }
        err(e) => { return -EFAULT; }
    }
}

// ===========================================================================
// Bring-up (S-mode trap path + U-mode drop), once smode_user_runtime.c, in MC.
//
// Under REAL OpenSBI the kernel is entered in S-mode at 0x80200000 (a0=hartid,
// a1=dtb). OpenSBI has already configured PMP and delegated U/S traps to S-mode,
// so this uses ONLY S-mode CSRs — no M-mode prologue, no PMP, no mret.
// ===========================================================================

const ECALL_FROM_U: u64 = 8;
const SCAUSE_INSTR_PAGE_FAULT: u64 = 12;
const SCAUSE_LOAD_PAGE_FAULT: u64 = 13;
const SCAUSE_STORE_PAGE_FAULT: u64 = 15;

const SYS_WRITE: u64 = 1;
const SYS_EXIT: u64 = 3;

const RT_VADDR: u64 = 0x4000_0000; // must match AGENT_CODE_VA above
const RT_EH: usize = 64;           // ELF header size
const RT_PH: usize = 56;           // program header size

// The U-mode program layout (mirrors the C bring-up):
//   WRITE(hello): li a7/a0/a1 (6) + ecall (1) = 7 insns
//   WRITE(bad):   li a7/a0/a1 (6) + ecall (1) = 7 insns
//   bgez a0, +32 (skip the EFOK block)        = 1 insn
//   WRITE(efok):  li a7/a0/a1 (6) + ecall (1) = 7 insns
//   EXIT:         li a7 (2) + ecall (1)        = 3 insns
const RT_NINSN: usize = 25;
const RT_CODE_BYTES: usize = 100; // RT_NINSN * 4
const HELLO_LEN: usize = 17;      // "HELLO-FROM-UMODE\n"
const EFOK_LEN: usize = 10;       // "EFAULT-OK\n"
const HELLO_OFF: usize = 100;     // RT_CODE_BYTES
const EFOK_OFF: usize = 117;      // HELLO_OFF + HELLO_LEN
const SEG_BYTES: usize = 127;     // RT_CODE_BYTES + HELLO_LEN + EFOK_LEN
const ELF_BYTES: usize = 247;     // RT_EH + RT_PH + SEG_BYTES
const BAD_PTR: u64 = 0xDEAD_0000; // NOT mapped in the agent's space
const RT_PAGE: usize = 4096;

// Static images/regions. Page-aligned ones are over-allocated by a page so the base
// can be rounded up at runtime (MC has no align attribute).
global g_user_elf: [247]u8;       // ELF_BYTES
global g_load_buf: [8192]u8;      // 4 KiB usable landing zone (exec in U)
global g_user_stack: [12288]u8;   // 8 KiB usable agent stack
global g_heap_region: [266240]u8; // 256 KiB usable page tables
global g_kernel_stack: [12288]u8; // 8 KiB usable kernel trap stack
global g_kbuf: [256]u8;           // bounded copy-in landing buffer

const RT_STACK_LEN: usize = 8192;
const KBUF_LEN: usize = 256;

// ---- the saved S-mode integer frame (matches the trap vector layout) ----
struct Frame {
    ra: u64,
    t0: u64, t1: u64, t2: u64, t3: u64, t4: u64, t5: u64, t6: u64,
    a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64,
    s0: u64, s1: u64, s2: u64, s3: u64, s4: u64, s5: u64, s6: u64, s7: u64,
    s8: u64, s9: u64, s10: u64, s11: u64,
}

fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

// ---- little-endian byte writers into the in-memory ELF ----
fn elf_put_u8(off: usize, v: u8) -> void {
    let base: usize = (&g_user_elf) as usize;
    unsafe { raw.store<u8>(pa(base + off), v); }
}
fn elf_put_u16(off: usize, v: u16) -> void {
    elf_put_u8(off, v as u8);
    elf_put_u8(off + 1, (v >> 8) as u8);
}
fn elf_put_u32(off: usize, v: u32) -> void {
    var i: usize = 0;
    while i < 4 {
        elf_put_u8(off + i, (v >> ((8 * i) as u32)) as u8);
        i = i + 1;
    }
}
fn elf_put_u64(off: usize, v: u64) -> void {
    var i: usize = 0;
    while i < 8 {
        elf_put_u8(off + i, (v >> ((8 * i) as u32)) as u8);
        i = i + 1;
    }
}

// Emit `li rd, val` for a 32-bit constant via lui+addi (with the standard sign
// correction for addi's sign-extended 12-bit immediate). Two instructions.
fn emit_li32(code: usize, idx: usize, rd: u32, val: u32) -> usize {
    // Sign-extend the low 12 bits to 32 bits (two's complement), kept as u32 so all
    // arithmetic stays unsigned: addi's 12-bit immediate is sign-extended by the CPU,
    // so lui must carry the correction (val - sext(low12)) >> 12.
    var low12_sext: u32 = val & 0xfff;
    if (low12_sext & 0x800) != 0 {
        low12_sext = low12_sext | 0xFFFF_F000; // bit 11 set -> negative -> sign-extend
    }
    let up20: u32 = (val - low12_sext) >> 12;        // upper 20 bits for lui
    let lui: u32 = (up20 << 12) | (rd << 7) | 0x37;
    elf_put_u32(code + idx * 4, lui);
    let addi: u32 = ((val & 0xfff) << 20) | (rd << 15) | (rd << 7) | 0x13;
    elf_put_u32(code + (idx + 1) * 4, addi);
    return idx + 2;
}

// Write one byte of a string literal into the ELF segment.
fn put_str(seg_off: usize, s: *const u8, len: usize) -> void {
    let sb: usize = s as usize;
    var k: usize = 0;
    while k < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(pa(sb + k)); }
        elf_put_u8(seg_off + k, b);
        k = k + 1;
    }
}

fn build_elf() -> void {
    var i: usize = 0;
    while i < ELF_BYTES {
        elf_put_u8(i, 0);
        i = i + 1;
    }
    elf_put_u8(0, 0x7f);
    elf_put_u8(1, 69); // 'E'
    elf_put_u8(2, 76); // 'L'
    elf_put_u8(3, 70); // 'F'
    elf_put_u8(4, 2);  // ELFCLASS64
    elf_put_u8(5, 1);  // little-endian
    elf_put_u64(24, RT_VADDR);            // e_entry
    elf_put_u64(32, RT_EH as u64);        // e_phoff
    elf_put_u16(54, RT_PH as u16);        // e_phentsize
    elf_put_u16(56, 1);                   // e_phnum

    let ph: usize = RT_EH;
    elf_put_u32(ph + 0, 1);               // p_type = PT_LOAD
    elf_put_u32(ph + 4, 5);               // p_flags = R|X
    elf_put_u64(ph + 8, (RT_EH + RT_PH) as u64); // p_offset
    elf_put_u64(ph + 16, RT_VADDR);       // p_vaddr (== entry)
    elf_put_u64(ph + 32, SEG_BYTES as u64); // p_filesz
    elf_put_u64(ph + 40, SEG_BYTES as u64); // p_memsz

    let code: usize = RT_EH + RT_PH;
    var idx: usize = 0;
    // SYS_WRITE(HELLO, HELLO_LEN): expect a0 = HELLO_LEN
    idx = emit_li32(code, idx, 17, SYS_WRITE as u32);                 // a7 = SYS_WRITE
    idx = emit_li32(code, idx, 10, (RT_VADDR + (HELLO_OFF as u64)) as u32); // a0 = &HELLO
    idx = emit_li32(code, idx, 11, HELLO_LEN as u32);                 // a1 = HELLO_LEN
    elf_put_u32(code + idx * 4, 0x0000_0073); idx = idx + 1;          // ecall
    // SYS_WRITE(BAD_PTR, HELLO_LEN): expect a0 < 0 (-EFAULT)
    idx = emit_li32(code, idx, 17, SYS_WRITE as u32);                 // a7 = SYS_WRITE
    idx = emit_li32(code, idx, 10, BAD_PTR as u32);                   // a0 = bad pointer
    idx = emit_li32(code, idx, 11, HELLO_LEN as u32);                 // a1 = len
    elf_put_u32(code + idx * 4, 0x0000_0073); idx = idx + 1;          // ecall (a0 <- result)
    // if a0 >= 0, skip the EFAULT-OK report (bgez a0, +32 -> EXIT block)
    elf_put_u32(code + idx * 4, 0x0205_5063); idx = idx + 1;          // bgez a0, +32
    // a0 < 0: SYS_WRITE(EFOK, EFOK_LEN)
    idx = emit_li32(code, idx, 17, SYS_WRITE as u32);                 // a7 = SYS_WRITE
    idx = emit_li32(code, idx, 10, (RT_VADDR + (EFOK_OFF as u64)) as u32); // a0 = &EFOK
    idx = emit_li32(code, idx, 11, EFOK_LEN as u32);                  // a1 = EFOK_LEN
    elf_put_u32(code + idx * 4, 0x0000_0073); idx = idx + 1;          // ecall
    // SYS_EXIT(0)
    idx = emit_li32(code, idx, 17, SYS_EXIT as u32);                  // a7 = SYS_EXIT
    elf_put_u32(code + idx * 4, 0x0000_0073); idx = idx + 1;          // ecall

    // (idx must equal RT_NINSN; if not the assembler offsets are wrong.) The string
    // offsets are RELATIVE TO THE CODE/segment start, so add `code`.
    put_str(code + HELLO_OFF, "HELLO-FROM-UMODE\n", HELLO_LEN);
    put_str(code + EFOK_OFF, "EFAULT-OK\n", EFOK_LEN);
}

// Print n bytes from the kernel copy-in buffer over the SBI console.
fn sbi_putn(base: usize, n: u64) -> void {
    var i: u64 = 0;
    while i < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(pa(base + (i as usize))); }
        sbi_putchar(b);
        i = i + 1;
    }
}

// ---- S-mode CSR helpers ----
fn read_scause() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrr %0, scause" out("r") v: u64 }
    } }
    return v;
}
fn read_sepc() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrr %0, sepc" out("r") v: u64 }
    } }
    return v;
}
fn read_stval() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrr %0, stval" out("r") v: u64 }
    } }
    return v;
}
fn write_sepc(v: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrw sepc, %0" in("r") v: u64 }
    } }
}
fn write_stvec(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrw stvec, %0" in("r") addr: usize, clobber("memory") }
    } }
}
fn write_sscratch(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrw sscratch, %0" in("r") addr: usize, clobber("memory") }
    } }
}
fn activate_satp(satp: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "csrw satp, %0\n sfence.vma" in("r") satp: u64, clobber("memory") }
    } }
}
fn fence_i() -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "fence.i" clobber("memory") }
    } }
}

// S-mode trap dispatch. On ecall-from-U: route SYS_WRITE through sys_write_copyin
// (validates the user pointer, returns -EFAULT for the bad one, never deref'd) and
// SYS_EXIT to SBI shutdown; advance sepc past the 4-byte ecall. Any unexpected page
// fault fails closed (contained: the kernel survives to print and shut down).
export fn s_trap_handler(f: *mut Frame) -> void {
    let scause: u64 = read_scause();
    let sepc: u64 = read_sepc();
    let stval: u64 = read_stval();

    if scause == ECALL_FROM_U {
        if f.a7 == SYS_EXIT {
            sbi_puts("\nUSER-EXIT from U\n");
            sbi_shutdown();
        } else if f.a7 == SYS_WRITE {
            var len: u64 = f.a1;
            if len > (KBUF_LEN as u64) { len = KBUF_LEN as u64; } // clamp to bounded buffer
            let kdst: usize = (&g_kbuf) as usize;
            let r: i64 = sys_write_copyin(f.a0 as usize, len as usize, kdst);
            if r >= 0 {
                sbi_putn(kdst, r as u64); // print the validated bytes
                f.a0 = r as u64;
            } else {
                f.a0 = r as u64; // negative -> -EFAULT, the app sees a0 < 0
            }
        } else {
            sbi_puts("BAD-SYSCALL a7=");
            put_hex(f.a7);
            sbi_putchar(10);
            sbi_shutdown();
        }
        write_sepc(sepc + 4); // advance past the ecall so we do not re-execute it
        return;
    }

    if scause == SCAUSE_INSTR_PAGE_FAULT || scause == SCAUSE_LOAD_PAGE_FAULT || scause == SCAUSE_STORE_PAGE_FAULT {
        sbi_puts("UNEXPECTED-TRAP scause=");
        put_hex(scause);
        sbi_puts(" stval=");
        put_hex(stval);
        sbi_putchar(10);
        sbi_shutdown();
    }
    sbi_puts("UNEXPECTED-TRAP scause=");
    put_hex(scause);
    sbi_putchar(10);
    sbi_shutdown();
}

// S-mode trap vector: swap to the kernel stack via sscratch, save a full integer
// frame, dispatch, restore, sret. (Port of usermode_runtime.c's trap_vector, M->S.)
#[naked]
#[section(".text.strap")]
export fn s_trap() -> void {
    asm opaque volatile {
        ".balign 4\ncsrrw sp, sscratch, sp\n addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n mv a0, sp\n call s_trap_handler\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n csrrw sp, sscratch, sp\n sret"
    }
}

// Drop to U-mode (S-mode port of enter_user): set sepc + user sp, clear sstatus.SPP
// (mask 0x100, =0 for U), set sstatus.FS = Initial (0x2000), sret. A regular (non-
// naked) function: the precise-asm operands deliver entry/user_sp into temporaries,
// the template programs sepc + the user sp + sstatus, then sret leaves for U-mode and
// never returns (so the compiler-inserted epilogue is unreachable, which is fine).
fn enter_user(entry: usize, user_sp: usize) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw sepc, %0\n mv sp, %1\n li t5, 0x100\n csrc sstatus, t5\n li t6, 0x2000\n csrs sstatus, t6\n sret"
                in("t3") entry: usize,
                in("t4") user_sp: usize,
                clobber("memory")
            }
        }
    }
}

export fn s_entry() -> void {
    sbi_puts("kernel up in S-mode under OpenSBI (M2 user hello)\n");
    build_elf();

    let elf_base: usize = (&g_user_elf) as usize;
    let load_buf: usize = page_align((&g_load_buf) as usize);
    let user_stack: usize = page_align((&g_user_stack) as usize);
    let heap_region: usize = page_align((&g_heap_region) as usize);
    let kernel_stack: usize = page_align((&g_kernel_stack) as usize);

    // Land the agent's segment into a physical frame; it runs through its OWN page
    // table at VADDR, not at this physical address.
    let _r: u64 = elf_load_run(elf_base, ELF_BYTES, load_buf);
    fence_i(); // loaded bytes are instructions

    let satp: u64 = smode_space_build(heap_region, 262144, load_buf, SEG_BYTES, user_stack, RT_STACK_LEN);

    if kernel_not_user(0x8020_0000) == 1 {
        sbi_puts("CONFINED: kernel mapped supervisor-only (no PTE_U) in agent space\n");
    } else {
        sbi_puts("LEAK: kernel user-accessible in agent space\n");
    }
    if agent_code_is_user() == 1 {
        sbi_puts("CONFINED: agent code is U-only\n");
    } else {
        sbi_puts("LEAK: agent code not user\n");
    }

    // Install the S-mode trap vector + kernel trap stack, then activate satp. In
    // S-mode satp IS effective immediately, so the kernel's supervisor identity
    // window (built above) keeps this code + the trap path running.
    write_stvec((&s_trap) as usize);
    write_sscratch(kernel_stack + RT_STACK_LEN);
    activate_satp(satp);

    sbi_puts("kernel: entering confined U-mode agent\n");
    enter_user(agent_code_va() as usize, agent_stack_top_va() as usize);
    sbi_shutdown(); // not reached
}

// OpenSBI enters here in S-mode (a0=hartid, a1=dtb). Set the stack but do NOT
// clobber a0/a1 before the call.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
