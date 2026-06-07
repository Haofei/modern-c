/* Bare-metal link layout for the QEMU riscv64 `virt` machine. RAM starts at
   0x8000_0000, where QEMU (`-bios none`) jumps on reset. */
ENTRY(_start)

SECTIONS {
    . = 0x80000000;

    .text : {
        *(.text.start)
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    . = ALIGN(16);
    . += 0x10000;          /* 64 KiB stack */
    _stack_top = .;
}
