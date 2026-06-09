import "kernel/lib/registry.mc";
global g_reg: Registry;
export fn registry2_run() -> u32 {
    var pass: u32 = 1;
    registry_init(&g_reg);

    // multiple endpoints per class (key 2 = "Net"): two NICs, each with its own generation
    switch registry_add(&g_reg, 2, 100, 7) { ok(s) => {} err(e) => { pass = 0; } }
    switch registry_add(&g_reg, 2, 101, 9) { ok(s) => {} err(e) => { pass = 0; } }
    switch registry_add(&g_reg, 1, 200, 3) { ok(s) => {} err(e) => { pass = 0; } } // a Block
    if registry_count(&g_reg) != 3 { pass = 0; }
    if registry_count_key(&g_reg, 2) != 2 { pass = 0; } // two of class Net

    // enumerate the multiple endpoints of class Net, in registration order
    switch registry_find_nth(&g_reg, 2, 0) { ok(ep) => { if ep != 100 { pass = 0; } } err(e) => { pass = 0; } }
    switch registry_find_nth(&g_reg, 2, 1) { ok(ep) => { if ep != 101 { pass = 0; } } err(e) => { pass = 0; } }
    switch registry_find_nth(&g_reg, 2, 2) { ok(ep) => { pass = 0; } err(e) => {} } // only two

    // generation stored with the endpoint (for stale-registration detection)
    switch registry_find_gen(&g_reg, 2) { ok(gn) => { if gn != 7 { pass = 0; } } err(e) => { pass = 0; } }

    // unregister-on-death: NIC endpoint 100 (a dead pid) -> all its entries revoked
    if registry_unregister_endpoint(&g_reg, 100) != 1 { pass = 0; }
    if registry_count_key(&g_reg, 2) != 1 { pass = 0; }       // only 101 remains for Net
    switch registry_find(&g_reg, 2) { ok(ep) => { if ep != 101 { pass = 0; } } err(e) => { pass = 0; } }

    // unregistering a non-existent endpoint removes nothing
    if registry_unregister_endpoint(&g_reg, 999) != 0 { pass = 0; }
    return pass;
}
