import "kernel/lib/pgroup.mc";
global g_pg: PGroups;
export fn pgroup_run() -> u32 {
    var pass: u32 = 1;
    pgroups_init(&g_pg);
    setsid(&g_pg, 5);            // pid 5 leads a new session
    if getsid(&g_pg, 5) != 5 { pass = 0; }
    if getpgid(&g_pg, 5) != 5 { pass = 0; }
    setpgid(&g_pg, 7, 5);        // pid 7 joins pid 5's group
    if getpgid(&g_pg, 7) != 5 { pass = 0; }
    setpgid(&g_pg, 7, 7);        // pid 7 starts its own group
    if getpgid(&g_pg, 7) != 7 { pass = 0; }
    return pass;
}
