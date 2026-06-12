/* Multiboot x86-64 kernel, a.out-kludge flat binary loaded at 1 MiB. The multiboot header
   (with header_addr/load_addr/entry_addr) leads the image, so QEMU loads the flat binary by
   address without parsing the 64-bit ELF class. */
ENTRY(_start)
SECTIONS {
    . = 1M;
    _load_start = .;
    .boot : {
        *(.multiboot)
        *(.text.start)
    }
    .text : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .eh_frame : { *(.eh_frame .eh_frame.*) }
    .data : { *(.data .data.*) }
    . = ALIGN(8);
    _load_end = .;
    .bss : { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(8);
    _bss_end = .;
}
