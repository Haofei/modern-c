// kernel/arch/x86_64/kmain_runtime — the C `kmain` reached from boot.S in 64-bit long mode:
// bring up the 16550 serial port (COM1), run the cooperative-scheduler demo, report on the
// serial line, and exit QEMU via the isa-debug-exit device. Output is observable with
// `-nographic`/`-serial`, so the harness greps for the result string.
#include <stdint.h>

extern uint32_t sched_x86_run(void);

static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t r;
    __asm__ volatile("inb %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}

#define COM1 0x3F8

static void serial_init(void) {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // DLAB
    outb(COM1 + 0, 0x03); // divisor low (38400)
    outb(COM1 + 1, 0x00); // divisor high
    outb(COM1 + 3, 0x03); // 8N1
    outb(COM1 + 2, 0xC7); // FIFO
    outb(COM1 + 4, 0x0B); // RTS/DSR
}

static void putc_(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {
    }
    outb(COM1, (uint8_t)c);
}

static void puts_(const char *s) {
    while (*s) putc_(*s++);
}

// isa-debug-exit device (iobase 0xf4): writing V exits QEMU with status (V<<1)|1.
static void qemu_exit(uint8_t code) {
    outb(0xf4, code);
}

void mc_halt(void) {
    for (;;) __asm__ volatile("hlt");
}

void kmain(void) {
    serial_init();
    puts_("x86-64 long mode: boot OK\n");
    uint32_t r = sched_x86_run();
    if (r == 1) {
        puts_("X86-OK\n");
        qemu_exit(0);
    } else {
        puts_("X86-FAIL\n");
        qemu_exit(1);
    }
    mc_halt();
}
