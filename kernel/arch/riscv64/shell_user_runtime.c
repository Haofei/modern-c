// Test bring-up for the user-mode shell: drop to U-mode and enter the shell. The kernel
// logic (UART IRQ routing, wfi, syscalls) is all in MC now — this file is just the test
// harness entry + the U-mode stack. `mc-shell`'s IRQ setup is shell_irq_setup (MC).
#include <stdint.h>
#include <stddef.h>
void *memset(void *d,int c,size_t n){uint8_t*p=d;for(size_t i=0;i<n;++i)p[i]=(uint8_t)c;return d;}
void *memcpy(void *d,const void*s,size_t n){uint8_t*a=d;const uint8_t*b=s;for(size_t i=0;i<n;++i)a[i]=b[i];return d;}
void puts_(const char *s); void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint32_t shell_user(void);
void shell_irq_setup(void); // MC: enable UART RX IRQ -> PLIC -> mie.MEIE
__attribute__((aligned(16))) static uint8_t user_stack[16384];

__attribute__((used)) void test_main(void){
    puts_("mc-shell (user mode) — builtins: echo true false top exit\n");
    usermode_setup();   // trap vector (UART ISR + ecalls), PMP, syscall table
    shell_irq_setup();  // MC: route the UART RX interrupt + unmask mie.MEIE
    enter_user((uintptr_t)&shell_user, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt();
}
