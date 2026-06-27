// examples/apps/wasm/wasi_js_net.c — Phase-4b: a JavaScript agent that DRIVES THE KERNEL BROKER on
// the WASM path, the WASM mirror of examples/agents/agent_net_tool.js. QuickJS-on-wasm with the JS
// host surface re-exposed: a registered net_fetch(endpoint, token) JS global backed by the
// mc.net_fetch wasm import, routed by the shim to TOOL_OP_NET_FETCH through the net broker.
#include "quickjs.h"
#include <stdio.h>
#include <string.h>

__attribute__((import_module("mc"), import_name("net_fetch")))
extern int mc_net_fetch(int endpoint, int token);

static JSValue js_net_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t ep = 0, tok = 0;
    if (argc > 0) JS_ToInt32(ctx, &ep, argv[0]);
    if (argc > 1) JS_ToInt32(ctx, &tok, argv[1]);
    return JS_NewInt32(ctx, mc_net_fetch(ep, tok));
}

static const char *SCRIPT =
    "var ok = (net_fetch(1, 7) === 107) && (net_fetch(9, 999) === -13) &&\n"
    "         (net_fetch(1, 8) === 108) && (net_fetch(1, 9) === -11);\n"
    "ok ? \"JSNET-OK\" : \"JSNET-FAIL\";\n";

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { printf("js-net: no-rt\n"); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { printf("js-net: no-ctx\n"); return 1; }
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "net_fetch", JS_NewCFunction(ctx, js_net_fetch, "net_fetch", 2));
    JS_FreeValue(ctx, global);
    JSValue val = JS_Eval(ctx, SCRIPT, strlen(SCRIPT), "<agent>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) { printf("js-net: EXC\n"); rc = 1; }
    else {
        const char *s = JS_ToCString(ctx, val);
        printf("js-net: %s\n", s ? s : "(null)");
        if (s && strcmp(s, "JSNET-OK") == 0) printf("js-net: ok\n");
        if (s) JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
