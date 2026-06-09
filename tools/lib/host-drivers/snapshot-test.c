#include <stdint.h>
// Stub the context-switch primitives: proc_snapshot never switches, but proc_spawn
// references mc_thread_init. No real threads needed to enumerate the table.
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t snapshot_run(void);
int main(void){ return snapshot_run()==1 ? 0 : 1; }
