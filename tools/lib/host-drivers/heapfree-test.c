#include <stdint.h>
// The reclaiming kernel heap (kernel/core/heap) only does typed address arithmetic
// and keeps its free list inside the Heap struct, so it needs no arch primitives on
// the host — the fixture runs as plain computation.
#include <stdio.h>
extern uint32_t heapfree_run(void);
int main(void){
    uint32_t result = heapfree_run();
    if (result != 1) fprintf(stderr, "heapfree_run=%u\n", result);
    return result == 1 ? 0 : 1;
}
