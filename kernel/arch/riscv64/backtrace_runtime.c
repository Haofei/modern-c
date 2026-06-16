// Backtrace runtime: nested calls, and the deepest frame walks the RISC-V frame-
// pointer chain (s0/fp: [fp-8]=return address, [fp-16]=caller fp) to capture return
// addresses, then symbolizes each through the MC symbol table. Demonstrates both
// halves of a symbolized backtrace: stack unwinding + address->function mapping.
// Compiled with frame pointers; the level functions are noinline so frames exist.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void putdec(uint32_t v) {
    char b[12]; int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) putc_(b[--n]);
}

// MC symbol table (tests/qemu/symbols_demo.mc).
void     st_init(void);
uint32_t st_add(uint64_t addr, uint32_t id);
uint64_t st_index(uint64_t pc);

#define MAXF 16
static uint64_t frames[MAXF];

// Walk the frame-pointer chain from the current frame; returns the number of return
// addresses captured.
static int capture_backtrace(uint64_t *out, int max) {
    uintptr_t fp;
    __asm__ volatile("mv %0, s0" : "=r"(fp));
    int n = 0;
    while (n < max && fp != 0) {
        uint64_t ra = ((const uint64_t *)fp)[-1];     // saved ra at fp-8
        uintptr_t prev = ((const uintptr_t *)fp)[-2]; // saved fp at fp-16
        out[n++] = ra;
        if (prev <= fp) break; // the stack grows down; the chain must ascend
        fp = prev;
    }
    return n;
}

static int g_nframes;
static int g_resolved;

__attribute__((noinline)) static void level3(void) {
    g_nframes = capture_backtrace(frames, MAXF);
    g_resolved = 0;
    for (int i = 0; i < g_nframes; i++) {
        if (st_index(frames[i]) != (uint64_t)-1) g_resolved++;
    }
}
__attribute__((noinline)) static void level2(void) { level3(); __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void level1(void) { level2(); __asm__ volatile("" ::: "memory"); }

static void sort3(uint64_t *a) { // tiny ascending sort of 3 addresses
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2 - i; j++)
            if (a[j] > a[j + 1]) { uint64_t t = a[j]; a[j] = a[j + 1]; a[j + 1] = t; }
}

__attribute__((used)) void test_main(void) {
    puts_("backtrace booting\n");
    // Build a symbol table from the (sorted) level function addresses.
    st_init();
    uint64_t addrs[3] = { (uint64_t)(uintptr_t)&level1,
                          (uint64_t)(uintptr_t)&level2,
                          (uint64_t)(uintptr_t)&level3 };
    sort3(addrs);
    st_add(addrs[0], 1);
    st_add(addrs[1], 2);
    st_add(addrs[2], 3);

    level1(); // nest 3 deep, capture + symbolize at the bottom

    puts_("BT frames="); putdec((uint32_t)g_nframes);
    puts_(" resolved="); putdec((uint32_t)g_resolved); putc_('\n');
    // >=3 frames proves the unwind; >=2 resolved proves symbolization of the inner
    // level2/level3 return addresses.
    if (g_nframes >= 3 && g_resolved >= 2) puts_("BT-OK\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
