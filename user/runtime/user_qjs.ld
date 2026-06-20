/* user/runtime/user_qjs.ld — link script for the confined QuickJS agent ELF.
 *
 * Identical to user.ld but with a larger user stack: QuickJS's parser/evaluator recurses,
 * and the 16 KiB default is too small. Same fixed base + distinct-by-permission load segments
 * the elf_loader maps; the stack lives in .bss (the loader maps it R|W|U and zeroes it).
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
        . += 0x80000;         /* 512 KiB user stack (QuickJS eval recursion) */
        __user_stack_top = .;
    }

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame) *(.riscv.attributes) }
}
