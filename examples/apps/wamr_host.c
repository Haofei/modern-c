// examples/apps/wamr_host.c — the confined U-mode WAMR host: the WAMR analogue of wasm_host.c. It
// boots WAMR (classic interpreter, freestanding against the all-MC libc via the `mc` platform port),
// loads an embedded wasm module, calls its exported compute(), and prints the result over the kernel
// syscall ABI (printf -> SYS_WRITE). A successful run from an ISOLATED U-mode space proves WAMR runs
// a real WebAssembly module CONFINED, exactly as wasm3 does today — the foundation for replacing the
// wasm3 engine. NOTE: WAMR processes the module buffer in place, so load() is given a WRITABLE copy.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"   // const unsigned char wasm_blob[]; const unsigned int wasm_blob_len;

static unsigned char g_wbuf[262144];

int main(void) {
    RuntimeInitArgs init_args;
    memset(&init_args, 0, sizeof init_args);
    init_args.mem_alloc_type = Alloc_With_System_Allocator;   // os_malloc -> all-MC libc heap
    if (!wasm_runtime_full_init(&init_args)) { printf("WAMR: init fail\n"); return 1; }

    if (wasm_blob_len > sizeof g_wbuf) { printf("WAMR: module too big\n"); return 1; }
    memcpy(g_wbuf, wasm_blob, wasm_blob_len);   // writable copy (WAMR edits in place)

    char err[192];
    wasm_module_t module = wasm_runtime_load(g_wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR: load fail: %s\n", err); return 1; }
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, 65536, 131072, err, sizeof err);
    if (!inst) { printf("WAMR: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t exec_env = wasm_runtime_create_exec_env(inst, 65536);
    if (!exec_env) { printf("WAMR: exec-env fail\n"); return 1; }

    wasm_function_inst_t fn = wasm_runtime_lookup_function(inst, "compute");
    if (!fn) { printf("WAMR: no compute export\n"); return 1; }
    uint32_t argv[1] = { 0 };
    if (!wasm_runtime_call_wasm(exec_env, fn, 0, argv)) {
        printf("WAMR: call fail: %s\n", wasm_runtime_get_exception(inst));
        return 1;
    }
    printf("WAMR=%u\n", argv[0]);   // expect WAMR=5050

    wasm_runtime_destroy_exec_env(exec_env);
    wasm_runtime_deinstantiate(inst);
    wasm_runtime_unload(module);
    wasm_runtime_destroy();
    return 0;
}
