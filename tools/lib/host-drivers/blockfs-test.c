#include <stdint.h>
extern void     bfs_setup(void);
extern uint64_t bfs_create_(uint64_t nblocks);
extern uint64_t bfs_write_(uintptr_t idx, uintptr_t src, uintptr_t len);
extern uint64_t bfs_read_(uintptr_t idx, uintptr_t dst, uintptr_t len);
extern uint64_t bfs_size_(uintptr_t idx);
extern uint32_t disk_byte(uintptr_t off);
#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    bfs_setup();

    // File 0: two blocks (1024 bytes) of a known pattern.
    CHECK(bfs_create_(2) == 0);
    static uint8_t src[1024];
    for (int i = 0; i < 1024; i++) src[i] = (uint8_t)(i * 7 + 3);
    CHECK(bfs_write_(0, (uintptr_t)src, 1024) == 1024);
    CHECK(bfs_size_(0) == 1024);

    // The bytes really landed on the device (file 0 starts at block 0 -> offset 0).
    CHECK(disk_byte(0) == src[0]);
    CHECK(disk_byte(1023) == src[1023]);

    // Read it back through the device.
    static uint8_t dst[1024];
    for (int i = 0; i < 1024; i++) dst[i] = 0;
    CHECK(bfs_read_(0, (uintptr_t)dst, 1024) == 1024);
    for (int i = 0; i < 1024; i++) CHECK(dst[i] == src[i]);

    // File 1: distinct blocks (starts at block 2 -> offset 1024).
    CHECK(bfs_create_(2) == 1);
    static uint8_t src2[512];
    for (int i = 0; i < 512; i++) src2[i] = (uint8_t)(0xA0 + (i & 0xF));
    CHECK(bfs_write_(1, (uintptr_t)src2, 512) == 512);
    CHECK(disk_byte(1024) == src2[0]);   // file 1 at device offset 1024
    CHECK(disk_byte(0) == src[0]);       // file 0 untouched
    return 0;
}
