// examples/apps/wasm/wasi_js.c — the Phase-4 KEYSTONE guest: JavaScript running on the WASM path.
//
// This is QuickJS-on-WASM — exactly what Javy produces (Javy = QuickJS-ng compiled to
// wasm32-wasi). The Javy binary is not available in this build environment, so we compile the
// repo's already-vendored QuickJS (third_party/quickjs) to wasm32-wasi with the toolchain we have
// (`zig cc -target wasm32-wasi`, which links zig's wasi-libc); the result is the same QuickJS
// bytecode interpreter living inside a wasm module, run by the WAMR host + WASI shim — no opaque
// prebuilt tool. See docs/wasm-migration-plan.md Phase 4.
//
// It evaluates a representative JavaScript program (recursion, objects, arrays, JSON, closures —
// real engine features, not a toy expression) and prints the result through libc printf, which
// wasi-libc lowers to fd_write -> SYS_WRITE. PASS requires the JS result, proving a JS agent
// survives the migration: JS is preserved on the WASM runtime, as the "keep JS, retire the hack"
// direction requires.

#include "quickjs.h"
#include <stdio.h>
#include <string.h>

// A representative JS workload (the kind of logic real agents are written in): recursion + a
// closure-based map/reduce + JSON serialization. fib(10) = 55; JSON.stringify({a:[1,2,3]}) is
// '{"a":[1,2,3]}' (length 13); the array map/reduce of squares is 1+4+9 = 14. 55 + 13 + 14 = 82.
static const char *SCRIPT =
    "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2); }\n"
    "var json = JSON.stringify({ a: [1, 2, 3] });\n"
    "var sq = [1, 2, 3].map(function(x){ return x * x; }).reduce(function(p, c){ return p + c; }, 0);\n"
    "fib(10) + json.length + sq;\n";

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { printf("js: no-rt\n"); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { printf("js: no-ctx\n"); return 1; }

    JSValue val = JS_Eval(ctx, SCRIPT, strlen(SCRIPT), "<agent>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        printf("js: EXC\n");
        rc = 1;
    } else {
        int32_t r = 0;
        JS_ToInt32(ctx, &r, val);
        printf("js: result=%d\n", r);      // expect 82
        printf("js: ok\n");
    }

    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
