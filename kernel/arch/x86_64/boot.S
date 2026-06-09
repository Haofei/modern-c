# kernel/arch/x86_64/boot.S — Multiboot1 entry + 32->64-bit long-mode bring-up for QEMU.
# QEMU `-kernel` loads this multiboot ELF and enters `_start` in 32-bit protected mode
# (paging off). We build identity-mapped page tables (first 1 GiB, 2 MiB huge pages), enable
# PAE + SSE + long mode + paging, load a 64-bit GDT, far-jump into 64-bit code, and call
# `kmain`. No external assembler features beyond what clang's integrated assembler provides.

.set MB_MAGIC,    0x1BADB002
# bit0 align modules, bit1 mem info, bit16 a.out kludge (load addresses in the header, so QEMU
# loads a flat binary by address and never parses the ELF class — lets a 64-bit kernel boot).
.set MB_FLAGS,    0x00010003
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

    .section .multiboot, "a"
    .align 4
mb_header:
    .long MB_MAGIC
    .long MB_FLAGS
    .long MB_CHECKSUM
    .long mb_header                    # header_addr
    .long _load_start                  # load_addr  (start of the image to load)
    .long 0                            # load_end_addr = 0 -> load to end of file
    .long _bss_end                     # bss_end_addr (QEMU zeroes file-end..here)
    .long _start                       # entry_addr

    .section .bss, "aw", @nobits
    .align 4096
pml4:  .skip 4096
pdpt:  .skip 4096
pd:    .skip 4096
    .align 16
stack_bottom:
    .skip 16384
stack_top:

    .section .rodata
    .align 8
gdt64:
    .quad 0                                              # null descriptor
    .set CODE_SEG, . - gdt64
    .quad (1<<43) | (1<<44) | (1<<47) | (1<<53)          # 64-bit code: exec, S, present, long
    .set DATA_SEG, . - gdt64
    .quad (1<<41) | (1<<44) | (1<<47)                    # data: writable, S, present
gdt64_ptr:
    .word . - gdt64 - 1
    .quad gdt64

    .section .text.start, "ax"
    .code32
    .global _start
    .type _start, @function
_start:
    mov $stack_top, %esp

    # --- identity-map the first 1 GiB with 2 MiB pages: PML4[0]->PDPT[0]->PD[0..511] ---
    mov $pdpt, %eax
    or  $0x3, %eax
    mov %eax, pml4                     # PML4[0] = PDPT | P|W

    mov $pd, %eax
    or  $0x3, %eax
    mov %eax, pdpt                     # PDPT[0] = PD | P|W

    mov $pd, %edi
    xor %ecx, %ecx
1:
    mov %ecx, %eax
    shl $21, %eax                      # i * 2 MiB
    or  $0x83, %eax                    # P|W|PS(huge)
    mov %eax, (%edi)
    movl $0, 4(%edi)                   # high dword = 0
    add $8, %edi
    inc %ecx
    cmp $512, %ecx
    jne 1b

    mov $pml4, %eax
    mov %eax, %cr3                     # CR3 = PML4

    # CR4: PAE (bit5) + OSFXSR (bit9) + OSXMMEXCPT (bit10) so SSE is usable in long mode
    mov %cr4, %eax
    or  $((1<<5) | (1<<9) | (1<<10)), %eax
    mov %eax, %cr4

    # EFER.LME (MSR 0xC0000080, bit 8)
    mov $0xC0000080, %ecx
    rdmsr
    or  $(1<<8), %eax
    wrmsr

    # CR0: clear EM(bit2), set MP(bit1) for SSE; set PG(bit31) to turn on paging
    mov %cr0, %eax
    and $~(1<<2), %eax
    or  $((1<<1) | (1<<31)), %eax
    mov %eax, %cr0

    lgdt gdt64_ptr
    ljmp $CODE_SEG, $long_mode_start

    .code64
    .type long_mode_start, @function
long_mode_start:
    mov $DATA_SEG, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $stack_top, %rsp

    call kmain

    cli
2:
    hlt
    jmp 2b
