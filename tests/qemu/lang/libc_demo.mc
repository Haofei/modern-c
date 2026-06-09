import "std/libc.mc";
import "std/addr.mc";
global g_a: [6]u8;
global g_b: [6]u8;
global g_num: [4]u8;
export fn libc_run() -> u32 {
    var pass: u32 = 1;
    g_a[0]=0x61; g_a[1]=0x62; g_a[2]=0x63; g_a[3]=0;  // "abc"
    g_b[0]=0x61; g_b[1]=0x62; g_b[2]=0x63; g_b[3]=0;  // "abc"
    if !mc_memeq(pa((&g_a[0]) as usize), pa((&g_b[0]) as usize), 3) { pass = 0; }
    g_b[2]=0x64; // "abd"
    if mc_memeq(pa((&g_a[0]) as usize), pa((&g_b[0]) as usize), 3) { pass = 0; }
    if mc_strlen(pa((&g_a[0]) as usize)) != 3 { pass = 0; }
    g_num[0]=0x34; g_num[1]=0x32; g_num[2]=0x37; // "427"
    if mc_atoi(pa((&g_num[0]) as usize), 3) != 427 { pass = 0; }
    return pass;
}
