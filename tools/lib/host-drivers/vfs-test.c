#include <stdint.h>

extern void     v_init(void);
extern uint64_t v_open(uintptr_t name, uintptr_t name_len);
extern uint64_t v_write(uintptr_t fd, uintptr_t src, uintptr_t len);
extern uint64_t v_read(uintptr_t fd, uintptr_t dst, uintptr_t len);
extern uint64_t v_close(uintptr_t fd);

#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    v_init();
    static const char log[] = "log";

    // open (creates), write twice (appends, advancing the fd position).
    uint64_t w = v_open((uintptr_t)log, 3);
    CHECK(w == 0);
    CHECK(v_write(w, (uintptr_t)"abc", 3) == 3);
    CHECK(v_write(w, (uintptr_t)"de", 2) == 2);

    // re-open the same file -> a fresh fd at position 0.
    uint64_t r = v_open((uintptr_t)log, 3);
    CHECK(r == 1);

    char buf[8];
    for (int i = 0; i < 8; i++) buf[i] = 0;
    CHECK(v_read(r, (uintptr_t)buf, 8) == 5); // reads "abcde"
    CHECK(buf[0] == 'a' && buf[1] == 'b' && buf[2] == 'c' && buf[3] == 'd' && buf[4] == 'e');
    CHECK(v_read(r, (uintptr_t)buf, 8) == 0);  // position now at end

    // close + use-after-close is rejected.
    CHECK(v_close(w) == 0);
    CHECK(v_write(w, (uintptr_t)"x", 1) == ERR); // bad fd
    CHECK(v_close(w) == ERR);                    // already closed

    return 0;
}
