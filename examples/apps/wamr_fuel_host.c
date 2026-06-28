// examples/apps/wamr_fuel_host.c — confined WAMR fuel host. Demonstrates DETERMINISTIC
// per-instruction fuel via wasm_runtime_set_instruction_count_limit: the SAME burn() guest is
// terminated mid-execution under a LOW limit ("instruction limit exceeded") and runs to completion
// under a HIGH limit. Deterministic (instruction-counted), unlike the coarse wall-clock watchdog —
// the concrete payoff of swapping wasm3 for WAMR. Prints "WAMR-FUEL: ok" only if both hold.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"

static unsigned char g_wbuf[262144];

static wasm_module_inst_t inst_new(wasm_module_t module) {
    char err[192];
    return wasm_runtime_instantiate(module, 65536, 131072, err, sizeof err);
}

int main(void) {
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&ia)) { printf("WAMR-FUEL: init fail\n"); return 1; }
    if (wasm_blob_len > sizeof g_wbuf) { printf("WAMR-FUEL: module too big\n"); return 1; }
    memcpy(g_wbuf, wasm_blob, wasm_blob_len);
    char err[192];
    wasm_module_t module = wasm_runtime_load(g_wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR-FUEL: load fail: %s\n", err); return 1; }

    // (1) LOW fuel: burn() must be terminated with "instruction limit exceeded".
    wasm_module_inst_t i1 = inst_new(module);
    wasm_exec_env_t e1 = wasm_runtime_create_exec_env(i1, 65536);
    wasm_function_inst_t f1 = wasm_runtime_lookup_function(i1, "burn");
    if (!f1) { printf("WAMR-FUEL: no burn\n"); return 1; }
    wasm_runtime_set_instruction_count_limit(e1, 100000);     // ~0.1M instr — far below the loop
    uint32_t a1[1] = { 0 };
    int capped = 0;
    if (!wasm_runtime_call_wasm(e1, f1, 0, a1)) {
        const char *ex = wasm_runtime_get_exception(i1);
        if (ex && strstr(ex, "instruction limit")) { capped = 1; printf("WAMR-FUEL: capped (%s)\n", ex); }
        else { printf("WAMR-FUEL: low-limit wrong failure: %s\n", ex ? ex : "?"); return 1; }
    } else { printf("WAMR-FUEL: low limit did NOT cap\n"); return 1; }

    // (2) HIGH fuel: the same burn() runs to completion.
    wasm_module_inst_t i2 = inst_new(module);
    wasm_exec_env_t e2 = wasm_runtime_create_exec_env(i2, 65536);
    wasm_function_inst_t f2 = wasm_runtime_lookup_function(i2, "burn");
    wasm_runtime_set_instruction_count_limit(e2, 2000000000);  // generous
    uint32_t a2[1] = { 0 };
    int completed = 0;
    if (wasm_runtime_call_wasm(e2, f2, 0, a2)) { completed = 1; printf("WAMR-FUEL: full run result=%u\n", a2[0]); }
    else { printf("WAMR-FUEL: high limit failed: %s\n", wasm_runtime_get_exception(i2)); return 1; }

    if (capped && completed) printf("WAMR-FUEL: ok\n");
    return 0;
}
