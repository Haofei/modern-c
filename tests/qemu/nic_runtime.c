// Bare-metal riscv64 runtime + platform primitives for the demo NIC driver.
// Provides the std/sync and std/dma platform hooks (single-core: locks are
// uncontended, DMA is a flat static pool — the linear `move` types provide the
// real safety at compile time), drives one nic_transmit(), then exits QEMU.
#include <stdint.h>

// ----- structs matching the MC-emitted layout (std/sync.mc, std/dma.mc) -----
typedef struct SpinLock { uint32_t state; } SpinLock;
typedef struct Guard { SpinLock *lock; } Guard;
typedef struct IrqGuard { SpinLock *lock; uintptr_t flags; } IrqGuard;
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct Uart16550 Uart16550;

// ----- std/sync platform primitives (single-core) -----
Guard mc_spin_acquire(SpinLock *l) { l->state = 1; return (Guard){ l }; }
void mc_spin_release(Guard g) { g.lock->state = 0; }
IrqGuard mc_spin_acquire_irqsave(SpinLock *l) { l->state = 1; return (IrqGuard){ l, 0 }; }
void mc_spin_release_irqrestore(IrqGuard g) { g.lock->state = 0; }

// ----- std/dma platform primitives (single-slot pool) -----
// The platform hook must honor the same linear contract the MC types promise:
// one outstanding allocation, and the length must fit. Violations halt rather
// than silently hand out an aliasing buffer.
static uint8_t dma_pool[256];
static int dma_in_use = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    if (len > sizeof(dma_pool) || dma_in_use) {
        for (;;) {
        } // contract violation: too large, or a buffer is already outstanding
    }
    dma_in_use = 1;
    for (uintptr_t i = 0; i < len; ++i) dma_pool[i] = 0;
    return (uintptr_t)dma_pool;
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; dma_in_use = 0; }
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

// ----- the driver under test -----
void nic_transmit(volatile Uart16550 *uart, SpinLock *lock);

#define UART ((volatile Uart16550 *)0x10000000UL)   // QEMU virt 16550
#define FINISHER ((volatile uint32_t *)0x00100000UL) // SiFive test device

__attribute__((used)) void test_main(void) {
    SpinLock nic_lock = { 0 };
    nic_transmit(UART, &nic_lock);
    *FINISHER = 0x5555; // exit QEMU, status 0
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
