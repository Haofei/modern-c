/* user/runtime/user.ld — link script for a confined MC app ELF.
 *
 * Produces a position-dependent ELF at a fixed user base (0x10000), with DISTINCT load
 * segments by permission so kernel/core/elf_loader maps each with the right PTE bits:
 *   .text   (R|X)  — _start first (the ELF entry), then code
 *   .rodata (R)
 *   .data   (R|W)
 *   .bss    (R|W)  — zero-init data + the app's stack (a NOBITS tail the loader zeroes)
 *
 * The stack lives in .bss so the app is self-contained: the loader maps the bss segment
 * R|W|U and zeroes it, and __user_stack_top is a valid user VA at link time. ld.lld groups
 * sections into PT_LOAD segments by flags, giving the three R/RX/RW segments the loader needs.
 */

ENTRY(_start)

SECTIONS {
    . = 0x10000;

    .text : ALIGN(0x1000) {
        *(.text.start)   /* _start at the entry */
        *(.text .text.*)
    }

    .rodata : ALIGN(0x1000) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(0x1000) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    .bss : ALIGN(0x1000) {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __user_stack_bottom = .;
        . += 0x4000;          /* 16 KiB user stack */
        __user_stack_top = .;
    }

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame) *(.riscv.attributes) }
}
