#include <stdint.h>
// Platform context-switch hooks the process table references; stubbed for the host (the test
// drives the table's data structures, not a real context switch).
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t ipc_result_run(void);
int main(void){ return ipc_result_run()==1 ? 0 : 1; }
