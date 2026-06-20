// examples/apps/compute.c — a confined C app exercising the freestanding libc (malloc +
// string + write). It allocates an array, sums it, and reports via SYS_WRITE — proving the
// C-app + libc path that QuickJS (also C) will use. main returns 0 on success.
#include "user/runtime/usys.h"
#include <stdint.h>
#include <stddef.h>

void *malloc(size_t);
void free(void *);
size_t strlen(const char *);

int main(void) {
    const int n = 100;
    int *a = (int *)malloc((size_t)n * sizeof(int));
    if (!a) {
        const char m[] = "alloc-fail\n";
        sys_print(m, strlen(m));
        return 1;
    }
    long sum = 0;
    for (int i = 0; i < n; i++) {
        a[i] = i;
        sum += a[i];
    }
    free(a);
    if (sum == 4950) { // 0 + 1 + ... + 99
        const char m[] = "compute-ok\n";
        sys_print(m, strlen(m));
        return 0;
    }
    const char m[] = "compute-bad\n";
    sys_print(m, strlen(m));
    return 1;
}
