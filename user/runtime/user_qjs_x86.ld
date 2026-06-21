/* user/runtime/user_qjs_x86.ld — link script for the confined QuickJS agent ELF on x86-64.
 *
 * The x86-64 sibling of user_qjs.ld, but loaded at 1 GiB (0x4000_0000) rather than 0x10000.
 * On x86-64 the kernel keeps itself mapped in the agent's CR3 as a SUPERVISOR-ONLY identity
 * window over the low 1 GiB (so long mode + the trap path survive the CR3 reload — see M6 /
 * qjs_x86_demo.mc). The agent's image + heap arena + stack must therefore live ABOVE that
 * window, exactly like M6's hand-assembled program at USER_CODE_VA = 1 GiB, so the agent's
 * user VAs (PDPT index 1+) never collide with the kernel's supervisor pages (PDPT index 0).
 * On riscv the kernel is UNMAPPED in the agent space, so the agent can sit at 0x10000 there.
 * Same distinct-by-permission load segments the elf_loader maps; the 512 KiB user stack lives
 * in .bss (the loader maps it R|W|U and zeroes it). Discards the x86 arch sections.
 */

ENTRY(_start)

SECTIONS {
    . = 0x40000000;

    .text : ALIGN(0x1000) {
        *(.text.start)   /* _start at the entry */
        *(.text .text.*)
    }

    .rodata : ALIGN(0x1000) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(0x1000) {
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
