/* AArch64 VM demo: flat image loaded by QEMU 'virt' -kernel at RAM base 0x40000000.
   _start (.text.boot) leads the image so the entry is at the load address. The exception
   vector table (.text.vectors) needs VBAR_EL1's 2 KiB alignment; MC has no function-align
   attribute, so we ALIGN it here (the pure-MC kmain emits it into its own section). */
ENTRY(_start)
SECTIONS {
    . = 0x40000000;
    .text : { KEEP(*(.text.boot)) . = ALIGN(2048); KEEP(*(.text.vectors)) *(.text*) }
    .rodata : { *(.rodata*) }
    .eh_frame : { *(.eh_frame .eh_frame.*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    . = . + 0x10000;
    _stack_top = .;
}
