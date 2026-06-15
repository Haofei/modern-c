#include <stdint.h>

extern void     v_init(void);
extern uint64_t v_open(uintptr_t name, uintptr_t name_len);
extern uint64_t v_write(uintptr_t fd, uintptr_t src, uintptr_t len);
extern uint64_t v_read(uintptr_t fd, uintptr_t dst, uintptr_t len);
extern uint64_t v_close(uintptr_t fd);
extern uint64_t v_stat_size(uintptr_t fd);
extern uint64_t v_stat_position(uintptr_t fd);
extern uint64_t v_stat_capacity(uintptr_t fd);
extern uint64_t v_dup(uintptr_t fd);

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

    // Writes use the fd's current position. A fresh fd reads two bytes, then
    // writes in the middle; the write must not append to the file.
    uint64_t rw = v_open((uintptr_t)log, 3);
    CHECK(rw == 2);
    for (int i = 0; i < 8; i++) buf[i] = 0;
    CHECK(v_read(rw, (uintptr_t)buf, 2) == 2);
    CHECK(v_write(rw, (uintptr_t)"XY", 2) == 2);
    uint64_t check = v_open((uintptr_t)log, 3);
    CHECK(check == 3);
    for (int i = 0; i < 8; i++) buf[i] = 0;
    CHECK(v_read(check, (uintptr_t)buf, 8) == 5);
    CHECK(buf[0] == 'a' && buf[1] == 'b' && buf[2] == 'X' && buf[3] == 'Y' && buf[4] == 'e');

    // stat: the file holds 5 bytes ("abXYe"); a fresh fd is positioned at 0; capacity is the
    // VFS reservation. `dup` clones the descriptor onto the same file with the position copied.
    uint64_t st = v_open((uintptr_t)log, 3);
    CHECK(st == 4);
    CHECK(v_stat_size(st) == 5);
    CHECK(v_stat_position(st) == 0);
    CHECK(v_stat_capacity(st) == 512);     // FILE_CAPACITY in vfs.mc
    CHECK(v_read(st, (uintptr_t)buf, 3) == 3);  // advance to position 3
    CHECK(v_stat_position(st) == 3);

    uint64_t du = v_dup(st);
    CHECK(du == 5);                          // a fresh fd
    CHECK(v_stat_position(du) == 3);         // position copied from the source fd
    CHECK(v_stat_size(du) == 5);             // same backing file
    // the two descriptors advance independently after the dup
    CHECK(v_read(du, (uintptr_t)buf, 2) == 2);
    CHECK(v_stat_position(du) == 5);
    CHECK(v_stat_position(st) == 3);

    // stat / dup of a bad fd is rejected.
    CHECK(v_stat_size(99) == ERR);
    CHECK(v_dup(99) == ERR);

    // close + use-after-close is rejected.
    CHECK(v_close(w) == 0);
    CHECK(v_write(w, (uintptr_t)"x", 1) == ERR); // bad fd
    CHECK(v_close(w) == ERR);                    // already closed

    return 0;
}
