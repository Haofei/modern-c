#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
extern const unsigned char tiny_wasm[];
extern const unsigned int tiny_wasm_len;
#define MARK(s) do { fprintf(stderr, "step:%s\n", s); fflush(stderr); } while(0)
int main(void) {
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    MARK("pre-init");
    if (!wasm_runtime_full_init(&ia)) { printf("wamr: init fail\n"); return 1; }
    MARK("post-init");
    char err[160];
    static unsigned char wbuf[65536]; memcpy(wbuf, tiny_wasm, tiny_wasm_len);
    wasm_module_t mod = wasm_runtime_load(wbuf, tiny_wasm_len, err, sizeof err);
    MARK("post-load");
    if (!mod) { printf("wamr: load fail: %s\n", err); return 1; }
    wasm_module_inst_t inst = wasm_runtime_instantiate(mod, 65536, 65536, err, sizeof err);
    MARK("post-instantiate");
    if (!inst) { printf("wamr: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 65536);
    MARK("post-exec-env");
    wasm_function_inst_t fn = wasm_runtime_lookup_function(inst, "compute");
    if (!fn) { printf("wamr: no compute\n"); return 1; }
    MARK("pre-call");
    uint32_t argv[1] = { 0 };
    if (!wasm_runtime_call_wasm(env, fn, 0, argv)) { printf("wamr: call fail: %s\n", wasm_runtime_get_exception(inst)); return 1; }
    printf("WAMR-RESULT=%u\n", argv[0]);
    return 0;
}
