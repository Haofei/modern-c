/* demo/hosted — the C entry point for the hosted elementwise kernel.
 *
 * MC does not emit a `main` (it is freestanding-by-default); a hosted program
 * supplies one in C that calls the exported MC entry. This is deliberately
 * trivial: all the work, and all the fallible I/O, lives in elementwise.mc.
 */
#include <stdint.h>

extern int32_t hosted_kernel_run(void);

int main(void) {
    return hosted_kernel_run();
}
