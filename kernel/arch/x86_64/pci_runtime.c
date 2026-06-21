// kernel/arch/x86_64/pci_runtime — the C `kmain` for the x86-64 PCI device-discovery proof
// (pci_x86_demo). This proves REAL PCI device discovery on x86-64 under QEMU — the analogue of
// the RISC-V FDT/ECAM device discovery, but using the legacy port-I/O CAM mechanism instead of
// memory-mapped ECAM.
//
// In 64-bit long mode (reached from boot.S, which identity-maps the low 1 GiB and runs us at
// 1 MiB):
//   1. bring up COM1;
//   2. install an IDT with exception stubs (#GP/#PF etc.) PURELY for diagnostics — PCI config
//      access is synchronous port I/O (no interrupts needed), so unlike the timer demo there is
//      no async ISR and we never `sti`;
//   3. drive the MC enumerator (tests/x86/pci_x86_demo.mc :: pci_x86_scan), which scans bus 0 via
//      the config mechanism below and finds QEMU's attached virtio-blk-pci device (vendor 0x1AF4);
//   4. report the discovered identity (vendor/device/class/BAR0) over COM1; the gate asserts a
//      REAL device (vendor 0x1AF4, not an all-ones absent read) was found.
//
// The config-space read primitive (pci_x86_cfg_read32) lives HERE in C because x86 PCI CAM is
// port I/O (write the CONFIG_ADDRESS dword to 0xCF8, read CONFIG_DATA from 0xCFC) and MC has no
// `in`/`out` instruction and its `raw` ops are MMIO-only. The MC fixture calls this extern,
// mirroring how console_putc is a C extern — the bus scan / field decode itself stays in MC.
//
// STRETCH: after discovery, if BAR0 is an I/O BAR holding the LEGACY virtio header, bring the
// legacy virtio-pci transport up far enough for a clean handshake (reset -> ACKNOWLEDGE|DRIVER,
// read device features) and read one device-config field (virtio-blk capacity). This is reported
// but NOT gated on (full virtqueue/sector I/O is out of scope).
#include <stdint.h>

void *memset(void *dst, int c, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    for (unsigned long i = 0; i < n; i++) p[i] = (unsigned char)c;
    return dst;
}
void *memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

// ---------------------------- port I/O ----------------------------
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t r;
    __asm__ volatile("inb %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}
static inline void outl(uint16_t port, uint32_t val) {
    __asm__ volatile("outl %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint32_t inl(uint16_t port) {
    uint32_t r;
    __asm__ volatile("inl %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}
static inline uint16_t inw(uint16_t port) {
    uint16_t r;
    __asm__ volatile("inw %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}

#define COM1 0x3F8

static void serial_init(void) {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);
}
static void putc_(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {
    }
    outb(COM1, (uint8_t)c);
}
static void puts_(const char *s) {
    while (*s) putc_(*s++);
}
static void puthexw(uint32_t v, int nibbles) {
    for (int i = (nibbles - 1) * 4; i >= 0; i -= 4)
        putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void puthex32(uint32_t v) { putc_('0'); putc_('x'); puthexw(v, 8); }
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

static void qemu_exit(uint8_t code) { outb(0xf4, code); }
static void halt_forever(void) { for (;;) __asm__ volatile("hlt"); }

// ---------------------------- PCI config (legacy CAM port I/O) ----------------------------
// CONFIG_ADDRESS (0xCF8): bit 31 = enable; bits 23..16 = bus; 15..11 = device; 10..8 = function;
// 7..2 = register (dword-aligned). CONFIG_DATA (0xCFC) then exposes the selected dword. This is
// the canonical x86 PCI configuration mechanism #1; it works on both `pc` (i440FX) and `q35`.
//
// Exported as the MC fixture's `pci_x86_cfg_read32` extern — the only arch-specific dependency of
// the otherwise arch-neutral MC enumerator.
#define PCI_CONFIG_ADDRESS 0xCF8
#define PCI_CONFIG_DATA    0xCFC

uint32_t pci_x86_cfg_read32(uint32_t bus, uint32_t dev, uint32_t func, uint32_t off) {
    uint32_t addr = 0x80000000u
                  | ((bus  & 0xFFu) << 16)
                  | ((dev  & 0x1Fu) << 11)
                  | ((func & 0x07u) << 8)
                  | (off & 0xFCu);
    outl(PCI_CONFIG_ADDRESS, addr);
    return inl(PCI_CONFIG_DATA);
}

// ---------------------------- IDT (diagnostics only) ----------------------------
struct idt_entry {
    uint16_t off_lo;
    uint16_t sel;
    uint8_t  ist;
    uint8_t  type_attr;
    uint16_t off_mid;
    uint32_t off_hi;
    uint32_t zero;
} __attribute__((packed));
struct idt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));
static struct idt_entry g_idt[256];
static struct idt_ptr g_idtr;

#define KCODE_SEL 0x08

static void idt_set(int vec, void (*handler)(void)) {
    uint64_t addr = (uint64_t)(uintptr_t)handler;
    g_idt[vec].off_lo = (uint16_t)(addr & 0xFFFF);
    g_idt[vec].sel = KCODE_SEL;
    g_idt[vec].ist = 0;
    g_idt[vec].type_attr = 0x8E; // present, DPL=0, 64-bit interrupt gate
    g_idt[vec].off_mid = (uint16_t)((addr >> 16) & 0xFFFF);
    g_idt[vec].off_hi = (uint32_t)((addr >> 32) & 0xFFFFFFFF);
    g_idt[vec].zero = 0;
}

// Exception diagnostics: print a marker + faulting RIP/CR2 and halt, so a config-access bug is
// DIAGNOSED rather than silently triple-faulting. on_fault never returns.
__attribute__((used)) static void on_fault(uint64_t *frame, uint64_t vec) {
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    puts_("\nX86-PCI-BAD TRAP vec="); puthex64(vec);
    puts_(" cr2="); puthex64(cr2);
    puts_(" w0="); puthex64(frame[0]);
    puts_(" w1="); puthex64(frame[1]);
    puts_(" w2="); puthex64(frame[2]); putc_('\n');
    qemu_exit(1);
    halt_forever();
}
#define FAULT_STUB(n) \
    __attribute__((naked, used)) static void fault_stub_##n(void) { \
        __asm__ volatile("cli\n mov %%rsp, %%rdi\n mov $" #n ", %%rsi\n call on_fault\n 1: hlt\n jmp 1b\n" : : : "memory"); \
    }
FAULT_STUB(0) FAULT_STUB(1) FAULT_STUB(2) FAULT_STUB(3) FAULT_STUB(4) FAULT_STUB(5)
FAULT_STUB(6) FAULT_STUB(7) FAULT_STUB(8) FAULT_STUB(9) FAULT_STUB(10) FAULT_STUB(11)
FAULT_STUB(12) FAULT_STUB(13) FAULT_STUB(14) FAULT_STUB(15) FAULT_STUB(16) FAULT_STUB(17)
FAULT_STUB(18) FAULT_STUB(19)
__attribute__((naked, used)) static void unk_stub(void) {
    __asm__ volatile("cli\n mov %%rsp, %%rdi\n mov $255, %%rsi\n call on_fault\n 1: hlt\n jmp 1b\n" : : : "memory");
}

static void idt_install(void) {
    for (int i = 0; i < 256; i++) idt_set(i, unk_stub);
    idt_set(0, fault_stub_0);   idt_set(1, fault_stub_1);   idt_set(2, fault_stub_2);
    idt_set(3, fault_stub_3);   idt_set(4, fault_stub_4);   idt_set(5, fault_stub_5);
    idt_set(6, fault_stub_6);   idt_set(7, fault_stub_7);   idt_set(8, fault_stub_8);
    idt_set(9, fault_stub_9);   idt_set(10, fault_stub_10); idt_set(11, fault_stub_11);
    idt_set(12, fault_stub_12); idt_set(13, fault_stub_13); idt_set(14, fault_stub_14);
    idt_set(15, fault_stub_15); idt_set(16, fault_stub_16); idt_set(17, fault_stub_17);
    idt_set(18, fault_stub_18); idt_set(19, fault_stub_19);
    g_idtr.limit = (uint16_t)(sizeof(g_idt) - 1);
    g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
    __asm__ volatile("lidt %0" : : "m"(g_idtr) : "memory");
}

// ---------------------------- virtio-pci legacy transport (STRETCH) ----------------------------
// Legacy (transitional) virtio-pci header at the start of the device's I/O BAR (no MSI-X):
//   0x00 device features (u32, RO)      0x12 device status (u8)
//   0x14 device-specific config begins  (virtio-blk: capacity u64 = sectors)
#define VIRTIO_PCI_HOST_FEATURES 0x00
#define VIRTIO_PCI_STATUS        0x12
#define VIRTIO_PCI_CONFIG_LEGACY 0x14   // device config offset when MSI-X is disabled

#define VIRTIO_STATUS_ACKNOWLEDGE 0x01
#define VIRTIO_STATUS_DRIVER      0x02

// Try the legacy virtio-pci transport handshake over the device's I/O BAR. `bar0` is the raw BAR
// register: bit 0 set => I/O space, base = bar0 & ~0x3. Returns 1 if the handshake looked sane
// (status read back our ACKNOWLEDGE|DRIVER bits) and writes the device features + first 8 bytes of
// device config (virtio-blk capacity) through the out-pointers. Returns 0 if BAR0 is not I/O space.
static int virtio_legacy_handshake(uint32_t bar0, uint32_t *out_features, uint64_t *out_capacity, uint8_t *out_status) {
    if ((bar0 & 0x1u) == 0) return 0; // not an I/O BAR — legacy transport lives in I/O space
    uint16_t io = (uint16_t)(bar0 & 0xFFFCu);

    // Reset: write 0 to the status register (the device acks by clearing it).
    outb(io + VIRTIO_PCI_STATUS, 0);
    // Drive the spec handshake: ACKNOWLEDGE then DRIVER.
    outb(io + VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACKNOWLEDGE);
    outb(io + VIRTIO_PCI_STATUS, (uint8_t)(VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER));

    uint8_t st = inb(io + VIRTIO_PCI_STATUS);
    uint32_t feat = inl(io + VIRTIO_PCI_HOST_FEATURES);

    // virtio-blk device config: capacity is a little-endian u64 at config offset 0 (== 0x14).
    uint32_t cap_lo = inl(io + VIRTIO_PCI_CONFIG_LEGACY + 0);
    uint32_t cap_hi = inl(io + VIRTIO_PCI_CONFIG_LEGACY + 4);

    *out_features = feat;
    *out_capacity = ((uint64_t)cap_hi << 32) | cap_lo;
    *out_status = st;
    // The handshake is sane iff the device latched our ACKNOWLEDGE|DRIVER bits.
    return (st & (VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER))
            == (VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);
}

// ---------------------------- MC enumerator ----------------------------
// tests/x86/pci_x86_demo.mc :: pci_x86_scan — arch-neutral bus scan, calls pci_x86_cfg_read32.
extern uint32_t pci_x86_scan(uint32_t *out_vendor, uint32_t *out_device, uint32_t *out_class, uint32_t *out_bar0);

void kmain(void) {
    serial_init();
    puts_("x86-64 long mode: PCI device-discovery demo boot OK\n");

    idt_install();
    puts_("pci: IDT installed (fault stubs for diagnostics)\n");

    // Sanity: read the host bridge at 00:00.0 — bus 0 always has the i440FX/Q35 host bridge
    // (Intel vendor 0x8086). A real bus answers; an all-ones read would mean no CAM at all.
    uint32_t hb = pci_x86_cfg_read32(0, 0, 0, 0);
    puts_("pci: host-bridge id @00:00.0 = "); puthex32(hb);
    puts_(" (vendor="); puthexw(hb & 0xFFFF, 4); puts_(")\n");

    // Drive the MC enumerator: scan bus 0 for the QEMU virtio-blk-pci device (vendor 0x1AF4).
    uint32_t vendor = 0, device = 0, class_reg = 0, bar0 = 0;
    uint32_t found = pci_x86_scan(&vendor, &device, &class_reg, &bar0);

    if (found != 1) {
        puts_("X86-PCI-BAD no virtio device (vendor 0x1AF4) found on bus 0\n");
        qemu_exit(1);
        halt_forever();
    }

    // Class code is in bits 24..31, subclass in 16..23 of register 0x08.
    uint32_t cls = (class_reg >> 24) & 0xFF;
    uint32_t sub = (class_reg >> 16) & 0xFF;
    puts_("X86-PCI virtio vendor="); puthexw(vendor, 4);
    puts_(" device="); puthexw(device, 4);
    puts_(" class="); puthexw(cls, 2);
    puts_(" subclass="); puthexw(sub, 2);
    puts_(" bar0="); puthex32(bar0);
    putc_('\n');

    // The discovered vendor MUST be 0x1AF4 and NOT an all-ones absent read — this is the floor
    // proof that real config-space enumeration found the QEMU-attached virtio-pci device.
    if (vendor != 0x1AF4u) {
        puts_("X86-PCI-BAD vendor mismatch\n");
        qemu_exit(1);
        halt_forever();
    }

    // STRETCH: bring up the legacy virtio-pci transport over the I/O BAR and read a config field.
    uint32_t feat = 0; uint64_t cap = 0; uint8_t st = 0;
    if (virtio_legacy_handshake(bar0, &feat, &cap, &st)) {
        puts_("X86-PCI-VIRTIO legacy handshake OK status="); puthexw(st, 2);
        puts_(" features="); puthex32(feat);
        puts_(" capacity="); puthex64(cap);
        puts_(" sectors\n");
    } else {
        puts_("pci: BAR0 not an I/O BAR (modern virtio transport); skipping legacy handshake\n");
    }

    puts_("X86-PCI-OK\n");
    qemu_exit(0);
    halt_forever();
}
