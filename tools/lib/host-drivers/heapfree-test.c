#include <stdint.h>
// The reclaiming kernel heap (kernel/core/heap) only does typed address arithmetic
// and keeps its free list inside the Heap struct, so it needs no arch primitives on
// the host — the fixture runs as plain computation.
extern uint32_t heapfree_run(void);
int main(void){ return heapfree_run()==1 ? 0 : 1; }
