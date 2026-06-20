// qjs_agent — the confined QuickJS agent front-end. NOT the stock qjs CLI: no argv, no host FS.
// It creates a runtime + context, evaluates a fixed script (Phase 6 will source it via the
// capability ingress), and reports the result via SYS_WRITE. Phase 4 bring-up: prove the
// engine links + evaluates basic JS against the all-MC libc.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
size_t strlen(const char *s);
int snprintf(char *, size_t, const char *, ...);

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { emit("no-rt\n", 6); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { emit("no-ctx\n", 7); return 1; }

    const char *script = "1 + 2 * 3";
    JSValue val = JS_Eval(ctx, script, strlen(script), "<agent>", JS_EVAL_TYPE_GLOBAL);

    int rc = 0;
    if (JS_IsException(val)) {
        emit("EXC\n", 4);
        rc = 1;
    } else {
        int32_t r = 0;
        JS_ToInt32(ctx, &r, val);
        char buf[32];
        int n = snprintf(buf, sizeof buf, "JS=%d\n", r); // expect JS=7
        emit(buf, (unsigned long)n);
    }

    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
