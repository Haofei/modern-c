#include <stdint.h>
extern uint32_t cl_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(cl_run() == 220); // 105 + 115: closure captured &counter, state persisted
    return 0;
}
