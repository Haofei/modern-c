#include <stdint.h>
extern void     st_init(void);
extern uint32_t st_add(uint64_t addr, uint32_t id);
extern uint64_t st_index(uint64_t pc);
extern uint64_t st_offset(uint64_t pc);
extern uint64_t st_id(uint64_t pc);
#define NONE ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    st_init();
    CHECK(st_add(0x1000, 10) == 1);
    CHECK(st_add(0x1100, 11) == 1);
    CHECK(st_add(0x1250, 12) == 1);
    CHECK(st_add(0x1400, 13) == 1);
    CHECK(st_add(0x1300, 99) == 0); // out of order -> rejected

    // exact start of the first function
    CHECK(st_index(0x1000) == 0 && st_offset(0x1000) == 0 && st_id(0x1000) == 10);
    // inside the second function
    CHECK(st_index(0x1180) == 1 && st_offset(0x1180) == 0x80 && st_id(0x1180) == 11);
    // exact start of the third
    CHECK(st_index(0x1250) == 2 && st_offset(0x1250) == 0 && st_id(0x1250) == 12);
    // just before the fourth (still in the third)
    CHECK(st_index(0x13FF) == 2 && st_offset(0x13FF) == 0x1AF && st_id(0x13FF) == 12);
    // past the last symbol (open-ended last function)
    CHECK(st_index(0x1500) == 3 && st_offset(0x1500) == 0x100 && st_id(0x1500) == 13);
    // below the first symbol -> not found
    CHECK(st_index(0x0500) == NONE && st_id(0x0500) == NONE);
    return 0;
}
