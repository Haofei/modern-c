// qjs_host — the GENERIC, fixed agent host. It is written ONCE and never changes per agent: it
// injects the host API (print, host_async) as JS globals, SYS_READs the agent source the kernel
// holds (the §0 ingress — the host embeds NO agent), evaluates it, and runs the event loop. The
// agent itself is PURE JAVASCRIPT (examples/agents/agent.js).
//
// host_async(n) is the non-blocking-I/O binding: SYS_SUBMIT starts the op and returns a PENDING
// Promise; the event loop SYS_POLLs the completion and resolves it. The agent uses plain
// async/await over it — it never blocks and never touches C.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_submit(unsigned long req_ptr); // pointer to a ToolReq
extern long sys_poll(unsigned long ev_ptr);    // pointer to a ToolEvent to fill
extern long sys_read(unsigned long buf, unsigned long max); // §0 ingress
size_t strlen(const char *s);

// The tool ABI, mirrored byte-for-byte from user/abi.mc (ToolReq=40B, ToolEvent=24B). host_async
// builds a ToolReq and submits its address; the event loop polls completions into a ToolEvent.
#define TOOL_OP_SUM 1u
typedef struct {
    uint32_t op;      // +0
    uint32_t flags;   // +4
    uint64_t arg;     // +8
    uint64_t in_ptr;  // +16
    uint32_t in_len;  // +24
    uint32_t out_cap; // +28
    uint64_t out_ptr; // +32
} ToolReq; // 40 bytes
typedef struct {
    uint64_t id;       // +0
    int32_t status;    // +8
    int32_t result;    // +12
    uint32_t out_len;  // +16
    uint32_t reserved; // +20
} ToolEvent; // 24 bytes

// The agent source is NOT embedded in the host — the host SYS_READs it from the kernel at boot,
// so this host ELF is a FIXED artifact: shipping a different agent changes only the JS.
static char agent_src[262144]; // 256 KiB scratch for the agent JS

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

// ---- host API exposed to JS ----

// print(str): write a line to the console.
static JSValue js_print(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc > 0) {
        const char *s = JS_ToCString(ctx, argv[0]);
        if (s) {
            emit(s, (unsigned long)strlen(s));
            emit("\n", 1);
            JS_FreeCString(ctx, s);
        }
    }
    return JS_UNDEFINED;
}

// host_async(n): start a non-blocking op, return a pending Promise (resolved by the event loop).
#define MAXREQ 32
static JSValue g_resolvers[MAXREQ];
static int64_t g_ids[MAXREQ];
static int g_inflight = 0;

// Reject `promise` with the raw integer errno and free the capability — the request was never
// registered, so JS observes a rejection instead of a forever-pending Promise. The integer is
// turned into a STRUCTURED error object by the JS prelude that wraps __host_async_raw (see
// HOST_PRELUDE in main) — building the object in JS sidesteps C-API object construction and keeps
// the structured shape { code, name, retryable } close to where agents consume it.
static void reject_async(JSContext *ctx, JSValue *resolving, JSValue promise, int32_t code) {
    JSValue reason = JS_NewInt32(ctx, code);
    JSValue rr = JS_Call(ctx, resolving[1], JS_UNDEFINED, 1, &reason);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, reason);
    JS_FreeValue(ctx, resolving[0]);
    JS_FreeValue(ctx, resolving[1]);
    (void)promise;
}

// The host prelude: a JS shim evaluated before the agent. It wraps the raw host binding
// (__host_async_raw, which resolves to a number or rejects with an integer errno) into the
// agent-facing host_async, which on rejection throws a STRUCTURED error { code, name, retryable }.
// Built as a JS object literal (property reads on literals work in the freestanding engine).
static const char *HOST_PRELUDE =
    "globalThis.host_async = function (n) {"
    "  return globalThis.__host_async_raw(n).then(function (v) { return v; },"
    "    function (code) {"
    "      var names = {'-1':'EBUSY','-11':'EAGAIN','-13':'EDENIED','-14':'EFAULT','-105':'ENOCAP','-125':'ECANCELED'};"
    "      var name = names[String(code)] || 'EUNKNOWN';"
    "      throw { code: code, name: name, retryable: code === -11 || code === -1 };"
    "    });"
    "};";

static JSValue js_host_async(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t arg = 0;
    if (argc > 0) JS_ToInt32(ctx, &arg, argv[0]);

    // Create the Promise FIRST so failure here submits nothing to the kernel.
    JSValue resolving[2]; // [0] = resolve, [1] = reject
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) return promise;

    // Check LOCAL capacity before submitting: a saturated resolver table means we could not
    // record a completion, so reject without ever touching the kernel.
    if (g_inflight >= MAXREQ) {
        reject_async(ctx, resolving, promise, -1);
        return promise;
    }

    // Submit a ToolReq (SUM op). The kernel returns -errno (e.g. -E_AGAIN under back-pressure or
    // -E_NOCAP/-E_DENIED on policy) — reject, don't register.
    ToolReq req;
    req.op = TOOL_OP_SUM;
    req.flags = 0;
    req.arg = (uint64_t)arg;
    req.in_ptr = 0;
    req.in_len = 0;
    req.out_cap = 0;
    req.out_ptr = 0;
    int64_t id = sys_submit((unsigned long)&req);
    if (id < 0) {
        reject_async(ctx, resolving, promise, (int32_t)id);
        return promise;
    }

    g_ids[g_inflight] = id;
    g_resolvers[g_inflight] = resolving[0]; // retain resolve until the completion arrives
    g_inflight++;
    JS_FreeValue(ctx, resolving[1]); // reject unused for an accepted request
    return promise;
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { emit("host: no runtime\n", 16); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { emit("host: no context\n", 16); return 1; }

    // Inject the host API. host_async is exposed RAW as __host_async_raw; the prelude wraps it
    // into the agent-facing host_async that surfaces structured errors.
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "print", JS_NewCFunction(ctx, js_print, "print", 1));
    JS_SetPropertyStr(ctx, global, "__host_async_raw", JS_NewCFunction(ctx, js_host_async, "__host_async_raw", 1));
    JS_FreeValue(ctx, global);

    // Evaluate the host prelude (defines host_async = structured-error wrapper over the raw call).
    JSValue pv = JS_Eval(ctx, HOST_PRELUDE, strlen(HOST_PRELUDE), "host-prelude.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(pv)) {
        emit("host: prelude threw\n", 20);
        JS_FreeValue(ctx, pv);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return 1;
    }
    JS_FreeValue(ctx, pv);

    // §0 ingress: read the agent source from the kernel (SYS_READ), then run it.
    long alen = sys_read((unsigned long)agent_src, sizeof agent_src - 1);
    if (alen <= 0) {
        emit("host: no agent source\n", 22);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return 1;
    }
    agent_src[alen] = '\0';

    JSValue v = JS_Eval(ctx, agent_src, (size_t)alen, "agent.js", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(v)) {
        emit("host: agent threw\n", 18);
        rc = 1;
    }
    JS_FreeValue(ctx, v);

    // The event loop: drain microtasks (async/await reactions), poll non-blocking completions and
    // resolve their Promises, until nothing is queued and nothing is in flight.
    if (rc == 0) {
        int guard = 0;
        for (;;) {
            JSContext *jctx;
            int jerr = 0;
            while ((jerr = JS_ExecutePendingJob(rt, &jctx)) > 0) {
            }
            if (jerr < 0) { emit("host: job threw\n", 16); rc = 1; break; }

            ToolEvent ev;
            long got = sys_poll((unsigned long)&ev);
            if (got > 0) {
                int64_t id = (int64_t)ev.id;
                int32_t val = ev.result;
                int found = 0;
                for (int i = 0; i < g_inflight; i++) {
                    if (g_ids[i] == id) {
                        found = 1;
                        JSValue a = JS_NewInt32(ctx, val);
                        JSValue ret = JS_Call(ctx, g_resolvers[i], JS_UNDEFINED, 1, &a);
                        JS_FreeValue(ctx, ret);
                        JS_FreeValue(ctx, a);
                        JS_FreeValue(ctx, g_resolvers[i]);
                        g_resolvers[i] = g_resolvers[g_inflight - 1];
                        g_ids[i] = g_ids[g_inflight - 1];
                        g_inflight--;
                        break;
                    }
                }
                // An id with no matching resolver is a host/runtime invariant violation (the kernel
                // emitted a completion the host never registered). Fail loudly — never silently drop.
                if (!found) {
                    emit("host: unknown completion id\n", 28);
                    rc = 1;
                    break;
                }
            } else if (got < 0) {
                // SYS_POLL faulted (should not happen with a valid &ev) — fail rather than spin.
                emit("host: poll fault\n", 17);
                rc = 1;
                break;
            } else if (g_inflight == 0) {
                break;
            }
            // Guard against a stuck loop. Expiring while requests are still in flight means a
            // completion never arrived — surface it as a failure with a clear marker, not a hang.
            if (++guard > 1000000) {
                if (g_inflight > 0) {
                    emit("host: event-loop guard expired with in-flight requests\n", 55);
                    rc = 1;
                }
                break;
            }
        }
        for (int i = 0; i < g_inflight; i++) JS_FreeValue(ctx, g_resolvers[i]);
        g_inflight = 0;
    }

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
