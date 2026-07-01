#include <stdint.h>
/* The scheduler differential gate exercises only runnability state (block reasons / process
 * state) and compares the pick — it never takes a context switch — but proc_spawn / the yield
 * family still reference the arch context primitives at link time. Stub them (no switch is ever
 * performed on this path), same as endpoint-test. */
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t sched_difftest_run(void);
int main(void){ return sched_difftest_run()==1 ? 0 : 1; }
