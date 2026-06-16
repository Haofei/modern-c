#include <stdint.h>
// Stub the arch context-switch primitives (proc_spawn/proc_exit/proc_oom_kill reference them; the
// host has no real CPU contexts — the test only exercises the accounting + reclaim bookkeeping).
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t oom_run(void);
int main(void){ return oom_run()==1 ? 0 : 1; }
