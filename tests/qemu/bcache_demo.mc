// Buffer cache: a write goes to the cache (dirty), is visible to reads (hit), but only
// reaches the device on flush (write-back). Verifies hit/miss accounting too.
import "kernel/fs/bcache.mc";
import "std/addr.mc";

global g_disk: [4096]u8;
global g_cache: BCache;
global g_src: [512]u8;
global g_dst: [512]u8;

export fn bcache_run() -> u32 {
    let dev: PAddr = pa((&g_disk[0]) as usize);
    var pass: u32 = 1;
    bcache_init(&g_cache, dev, 4096);

    g_src[0] = 0xAB;
    g_src[1] = 0xCD;
    bcache_write(&g_cache, 1, pa((&g_src[0]) as usize), 512); // miss + dirty

    bcache_read(&g_cache, 1, pa((&g_dst[0]) as usize), 512);  // hit
    if g_dst[0] != 0xAB { pass = 0; }
    if g_dst[1] != 0xCD { pass = 0; }

    if g_disk[512] != 0 { pass = 0; }  // write-back: device not yet updated
    bcache_flush(&g_cache);
    if g_disk[512] != 0xAB { pass = 0; } // flushed to device
    if g_disk[513] != 0xCD { pass = 0; }

    if bcache_hits(&g_cache) < 1 { pass = 0; }
    if bcache_misses(&g_cache) < 1 { pass = 0; }
    return pass;
}
