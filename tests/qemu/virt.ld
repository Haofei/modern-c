/* Bare-metal link layout for the QEMU riscv64 `virt` machine. RAM starts at
   0x8000_0000, where QEMU (`-bios none`) jumps on reset. */
ENTRY(_start)

SECTIONS {
    . = 0x80000000;

    .text : {
        *(.text.start)
        /* RISC-V mtvec encodes the trap MODE in the low 2 bits, so the trap
           vector base MUST be 4-byte aligned. With compressed instructions the
           toolchain only aligns functions to 2 bytes, and MC has no function
           alignment attribute, so pin any `.text.mtrap` vector to a 4-byte
           boundary here. Empty (and thus a no-op) for every image that does not
           emit a `.text.mtrap` section. */
        . = ALIGN(4);
        *(.text.mtrap)
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .eh_frame : {
        *(.eh_frame .eh_frame.*)
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
