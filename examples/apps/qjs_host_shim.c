// qjs_host_shim.c — the JSValue-by-value ABI seam for the MC QuickJS host
// (examples/apps/qjs_host.mc). mcc extern fns cannot pass or return structs by
// value (E_EXTERN_STRUCT_BY_VALUE: no C ABI classification yet), so the MC host
// reaches the engine's by-value API through these pointer-seam wrappers: each
// forwards a JSValue through a pointer/out-pointer, keeping the actual by-value
// call on the C side where the ABI is the compiler's problem.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

void mc_js_eval(JSContext *ctx, const char *input, size_t len, const char *name,
                int flags, JSValue *out) {
    *out = JS_Eval(ctx, input, len, name, flags);
}

void mc_js_get_global_object(JSContext *ctx, JSValue *out) {
    *out = JS_GetGlobalObject(ctx);
}

void mc_js_get_property_str(JSContext *ctx, const JSValue *this_obj,
                            const char *name, JSValue *out) {
    *out = JS_GetPropertyStr(ctx, *this_obj, name);
}

int mc_js_to_int32(JSContext *ctx, int32_t *pres, const JSValue *val) {
    return JS_ToInt32(ctx, pres, *val);
}
