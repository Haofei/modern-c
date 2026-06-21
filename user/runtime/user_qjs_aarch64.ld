/* user/runtime/user_qjs_aarch64.ld — link script for the confined QuickJS agent ELF on AArch64.
 *
 * The AArch64 sibling of user_qjs_x86.ld. The agent is linked at 256 MiB (0x1000_0000), BELOW
 * the kernel's RAM identity window (QEMU virt RAM base 0x4000_0000 — kernel image + heap + page
 * tables + the agent's frame `region` pool all live at >= 1 GiB and are mapped EL1-only in the
 * agent's TTBR0, so EL1 + the SVC trap path survive the TTBR0 switch while staying unreachable
 * from EL0). The agent's image + heap arena + stack therefore live well below that window, so
 * the agent's EL0 VAs never collide with the kernel's EL1-only pages. This matches the M8 EL0
 * demo's UARM_CODE_VA = 256 MiB.
 *
 * Same distinct-by-permission load segments the elf_loader maps; the 512 KiB user stack lives in
 * .bss (the loader maps it EL0 R|W and zeroes it). Discards arch note/eh_frame sections.
 */

ENTRY(_start)

SECTIONS {
    . = 0x10000000;

    .text : ALIGN(0x1000) {
        *(.text.start)   /* _start at the entry */
        *(.text .text.*)
    }

    .rodata : ALIGN(0x1000) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(0x1000) {
        *(.got .got.plt)     /* fold the GOT into the writable data segment (see -z norelro) */
        *(.data .data.*)
    }

    .bss : ALIGN(0x1000) {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __user_stack_bottom = .;
        . += 0x80000;         /* 512 KiB user stack (QuickJS eval recursion) */
        __user_stack_top = .;
    }

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame) *(.eh_frame_hdr) }
}
