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
// Vector poll: drain up to `max` completions into a ToolEvent[] at events_ptr, advancing the
// broker clock up to `timeout` extra ticks. Returns the count delivered (0..max) or -E_FAULT.
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);
extern long sys_read(unsigned long buf, unsigned long max); // §0 ingress
size_t strlen(const char *s);

// The tool ABI, mirrored byte-for-byte from user/abi.mc (ToolReq=40B, ToolEvent=24B). host_async
// builds a ToolReq and submits its address; the event loop polls completions into a ToolEvent.
#define TOOL_OP_SUM 1u
#define TOOL_OP_SPURIOUS 5u
// REAL capability-checked FS ops (M5b.2): the kernel dispatches these through agent_fs_call (the
// capability front door). The request payload packs the path then the data (FS_WRITE only); arg =
// path length. FS_READ stages the file bytes back to out_ptr (host resolves with the string).
#define TOOL_OP_FS_WRITE 6u
#define TOOL_OP_FS_READ 7u
#define TOOL_OP_FS_MKDIR 8u
// CANCEL: complete the in-flight request whose id == arg with -E_CANCELED. Enqueues no new slot;
// sys_submit returns 0 on accept, -E_DENIED if the target id is unknown to the kernel broker.
#define TOOL_OP_CANCEL 3u
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
#define FS_OUT_CAP 256 /* mirrors MAX_RES_BYTES — the read-result staging cap per request */
static JSValue g_resolvers[MAXREQ];
static JSValue g_rejectors[MAXREQ]; // retained too: a completion with a negative status REJECTS
static int64_t g_ids[MAXREQ];
// Per-request result KIND, so the event loop knows how to resolve a completion: a scalar (the mock
// SUM op + FS_WRITE/FS_MKDIR resolve with result count) or a STRING (FS_READ — the file bytes were
// staged to this request's out buffer; resolve with them as a JS string).
#define RES_KIND_SCALAR 0
#define RES_KIND_STRING 1
static int g_kinds[MAXREQ];
// A pool of per-request out buffers for FS_READ: the kernel copies the read bytes here on SYS_POLL
// (the ToolReq.out_ptr points at one buffer). A buffer must outlive submit (lives until the poll),
// so it is static, not on the submit stack. The inflight table is compacted on completion (swap
// with last), so each inflight entry carries the INDEX of its assigned buffer (g_bufidx[]) rather
// than relying on the slot position — the kernel's out_ptr was baked at submit and never moves.
static char g_outbuf[MAXREQ][FS_OUT_CAP];
static int g_outbuf_used[MAXREQ]; // 1 if pool buffer i is currently assigned to an inflight request
static int g_bufidx[MAXREQ];      // for inflight entry j: its pool-buffer index, or -1 (no out buffer)
static uint32_t g_outlens[MAXREQ]; // for inflight entry j: bytes the kernel reports staged (set on poll)
static int g_inflight = 0;

// The kernel request id of the MOST RECENT successful sys_submit (set by start_request_full on the
// accept path). The JS prelude reads it via __host_last_id_raw() right after a host_call() so it can
// build a cancel() closure bound to THIS request's id — exposing the otherwise-opaque id to JS
// WITHOUT returning a {promise,id} object from a raw C binding (object construction in raw bindings
// is fragile in the freestanding engine; pure-JS object literals in the prelude are proven safe).
// Single-threaded JS + synchronous submit means this is read before any other submit can clobber it.
static int64_t g_last_id = -1;

// Reserve a free out-buffer from the pool, or -1 if none. Released when its completion is dispatched.
static int alloc_outbuf(void) {
    for (int i = 0; i < MAXREQ; i++) {
        if (!g_outbuf_used[i]) { g_outbuf_used[i] = 1; return i; }
    }
    return -1;
}

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
    "globalThis.host_async = function (n, delay) {"
    "  return globalThis.__host_async_raw(n, delay).then(function (v) { return v; },"
    "    globalThis.__host_errify);"
    "};"
    "globalThis.__host_errify = function (code) {"
    "  var names = {'-1':'EBUSY','-2':'ENOENT','-11':'EAGAIN','-13':'EDENIED','-14':'EFAULT','-22':'EINVAL','-105':'ENOCAP','-125':'ECANCELED'};"
    "  var name = names[String(code)] || 'EUNKNOWN';"
    "  throw { code: code, name: name, retryable: code === -11 || code === -1 };"
    "};"
    "globalThis.host_spurious = function () { return globalThis.__host_spurious_raw(); };"
    // REAL FS tools: wrap each raw binding so a rejected (denied/failed) op surfaces the SAME
    // structured error shape the agent already handles for host_async.
    "globalThis.host_fs_write = function (p, d) { return globalThis.__host_fs_write_raw(p, d).then(function (v) { return v; }, globalThis.__host_errify); };"
    "globalThis.host_fs_read = function (p) { return globalThis.__host_fs_read_raw(p).then(function (v) { return v; }, globalThis.__host_errify); };"
    "globalThis.host_fs_mkdir = function (p) { return globalThis.__host_fs_mkdir_raw(p).then(function (v) { return v; }, globalThis.__host_errify); };"
    // host_call(n, delay): an AbortController-like handle over a cancellable async request. Returns a
    // plain JS object { promise, cancel } built ENTIRELY in the prelude (object literals are proven
    // safe in the freestanding engine — unlike returning an object from a raw C binding). It submits
    // the request via the raw SUM binding, then reads THIS request's kernel id back via
    // __host_last_id_raw() (single-threaded + synchronous submit guarantees the id is still current),
    // and closes over it. Calling cancel() fires __host_cancel_raw(id) -> TOOL_OP_CANCEL, which the
    // kernel completes with -E_CANCELED; the existing status<0 poll path rejects the promise, and
    // __host_errify maps -125 to a structured { code:-125, name:'ECANCELED' }. Agents consume the
    // rejection in CALLBACK style (.then(onResolve, onReject)) to stay clear of the await/reason-field
    // freestanding quirk. cancel() is idempotent: a second call (or one after completion) just gets a
    // -E_DENIED from the kernel (the slot is gone) and is harmless.
    "globalThis.host_call = function (n, delay) {"
    "  var rawp = globalThis.__host_async_raw(n, delay);"
    "  var id = globalThis.__host_last_id_raw();"
    "  var promise = rawp.then(function (v) { return v; }, globalThis.__host_errify);"
    "  var cancel = function () { return globalThis.__host_cancel_raw(id); };"
    "  return { promise: promise, cancel: cancel, id: id };"
    "};";

// Start a tool request: create the Promise first, check local capacity, submit a ToolReq, and
// register the resolver (or reject on saturation / kernel -errno). Shared by ALL host bindings.
//
//   op             one of TOOL_OP_*
//   arg            the scalar arg (SUM) / the path length (FS ops: arg = path byte count)
//   delay          mock-broker completion delay in ticks (FS ops ignore it — they complete now)
//   in_payload     request payload bytes (path[+data] for FS ops), or NULL/0 for the mock ops
//   in_len         request payload length (path_len + data_len for FS_WRITE)
//   kind           RES_KIND_SCALAR (resolve with result int) or RES_KIND_STRING (resolve with the
//                  bytes the kernel stages to out_ptr — FS_READ)
static JSValue start_request_full(JSContext *ctx, uint32_t op, uint64_t arg, int32_t delay,
                                  const char *in_payload, uint32_t in_len, int kind) {
    JSValue resolving[2]; // [0] = resolve, [1] = reject
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) return promise;

    // Invalidate the last-id BEFORE any rejection path: every early return below (local saturation,
    // out-buffer exhaustion, kernel -errno) leaves g_last_id == -1, so the prelude's host_call()
    // builds a cancel() that targets nothing (a no-op) instead of cancelling a PREVIOUS, unrelated
    // in-flight request whose id was still sitting here. Only a successful submit sets it (below).
    g_last_id = -1;

    // Check LOCAL capacity before submitting: a saturated resolver table means we could not
    // record a completion, so reject without ever touching the kernel.
    if (g_inflight >= MAXREQ) {
        reject_async(ctx, resolving, promise, -1);
        return promise;
    }

    // A STRING result (FS_READ) needs a persistent out buffer for the kernel to stage bytes into.
    int bi = -1;
    if (kind == RES_KIND_STRING) {
        bi = alloc_outbuf();
        if (bi < 0) { // pool exhausted — treat as local back-pressure, don't touch the kernel
            reject_async(ctx, resolving, promise, -1);
            return promise;
        }
    }

    // Submit the ToolReq. The kernel returns -errno (e.g. -E_AGAIN under back-pressure or
    // -E_NOCAP/-E_DENIED on policy) — reject, don't register.
    ToolReq req;
    req.op = op;
    req.flags = (uint32_t)delay; // the mock broker reads flags as a completion delay (ticks)
    req.arg = arg;
    req.in_ptr = (uint64_t)(unsigned long)in_payload;
    req.in_len = in_len;
    if (bi >= 0) {
        req.out_cap = FS_OUT_CAP;
        req.out_ptr = (uint64_t)(unsigned long)g_outbuf[bi];
    } else {
        req.out_cap = 0;
        req.out_ptr = 0;
    }
    int64_t id = sys_submit((unsigned long)&req);
    if (id < 0) {
        if (bi >= 0) g_outbuf_used[bi] = 0; // never registered — release the reserved buffer
        reject_async(ctx, resolving, promise, (int32_t)id);
        return promise;
    }

    g_ids[g_inflight] = id;
    g_resolvers[g_inflight] = resolving[0]; // retain resolve until the completion arrives
    g_rejectors[g_inflight] = resolving[1]; // retain reject too: a -errno completion status rejects
    g_kinds[g_inflight] = kind;
    g_bufidx[g_inflight] = bi;
    g_outlens[g_inflight] = 0;
    g_inflight++;
    g_last_id = id; // expose THIS request's id to JS (read by the prelude to build cancel())
    return promise;
}

// Back-compat shim for the mock ops: a scalar-result request with no payload.
static JSValue start_request(JSContext *ctx, uint32_t op, int32_t arg, int32_t delay) {
    return start_request_full(ctx, op, (uint64_t)(uint32_t)arg, delay, 0, 0, RES_KIND_SCALAR);
}

// host_async(arg [, delay]): a SUM op completing after `delay` virtual ticks (default 0).
static JSValue js_host_async(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t arg = 0, delay = 0;
    if (argc > 0) JS_ToInt32(ctx, &arg, argv[0]);
    if (argc > 1) JS_ToInt32(ctx, &delay, argv[1]);
    return start_request(ctx, TOOL_OP_SUM, arg, delay);
}

// host_spurious(): a TEST-ONLY op whose completion carries a bogus id, exercising the host event
// loop's fatal "unknown completion id" path.
static JSValue js_host_spurious(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return start_request(ctx, TOOL_OP_SPURIOUS, 0, 0);
}

// ---- REAL capability-checked FS bindings (M5b.2): host_fs_write/read/mkdir ----
// Each packs the request payload (path bytes, then data bytes for write), sets arg = path length,
// and submits the matching TOOL_OP_FS_*. The kernel routes it through agent_fs_call (allowlist ->
// budget -> path cap) and completes it immediately; the result comes back through the SAME
// poll/ToolEvent path. WRITE/MKDIR resolve with a scalar (bytes written / dir count); READ resolves
// with the file bytes as a JS string. A denied/failed op rejects with the kernel -errno, which the
// host prelude turns into a structured error — exactly like host_async.
#define FS_PAYLOAD_CAP 384 /* path (<=128) + data (<=256), comfortably within MAX_REQ_BYTES checks */

// Copy a JS string arg into `buf` (up to cap), returning its byte length, or -1 on a bad arg.
static int copy_str_arg(JSContext *ctx, JSValueConst v, char *buf, int cap, int off) {
    const char *s = JS_ToCString(ctx, v);
    if (!s) return -1;
    int n = (int)strlen(s);
    if (off + n > cap) { JS_FreeCString(ctx, s); return -1; }
    for (int i = 0; i < n; i++) buf[off + i] = s[i];
    JS_FreeCString(ctx, s);
    return n;
}

// host_fs_write(path, data): write `data` under `path` (resolves with bytes written).
static JSValue js_host_fs_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    static char payload[FS_PAYLOAD_CAP];
    if (argc < 2) return start_request_full(ctx, TOOL_OP_FS_WRITE, 0, 0, payload, 0, RES_KIND_SCALAR);
    int plen = copy_str_arg(ctx, argv[0], payload, FS_PAYLOAD_CAP, 0);
    if (plen < 0) return start_request_full(ctx, TOOL_OP_FS_WRITE, 0, 0, payload, 0, RES_KIND_SCALAR);
    int dlen = copy_str_arg(ctx, argv[1], payload, FS_PAYLOAD_CAP, plen);
    if (dlen < 0) return start_request_full(ctx, TOOL_OP_FS_WRITE, 0, 0, payload, 0, RES_KIND_SCALAR);
    return start_request_full(ctx, TOOL_OP_FS_WRITE, (uint64_t)plen, 0, payload, (uint32_t)(plen + dlen), RES_KIND_SCALAR);
}

// host_fs_read(path): read `path` back (resolves with its bytes as a string).
static JSValue js_host_fs_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    static char payload[FS_PAYLOAD_CAP];
    int plen = (argc < 1) ? -1 : copy_str_arg(ctx, argv[0], payload, FS_PAYLOAD_CAP, 0);
    if (plen < 0) plen = 0;
    return start_request_full(ctx, TOOL_OP_FS_READ, (uint64_t)plen, 0, payload, (uint32_t)plen, RES_KIND_STRING);
}

// host_fs_mkdir(path): create a directory at `path` (resolves with the dir index). NOT allowlisted
// in the demo broker, so this REJECTS with EDENIED — the agent observes a structured error.
static JSValue js_host_fs_mkdir(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    static char payload[FS_PAYLOAD_CAP];
    int plen = (argc < 1) ? -1 : copy_str_arg(ctx, argv[0], payload, FS_PAYLOAD_CAP, 0);
    if (plen < 0) plen = 0;
    return start_request_full(ctx, TOOL_OP_FS_MKDIR, (uint64_t)plen, 0, payload, (uint32_t)plen, RES_KIND_SCALAR);
}

// __host_last_id_raw(): return the kernel request id of the most recent successful submit as a JS
// number. The prelude calls it immediately after host_call()'s submit to capture that request's id
// for a cancel() closure. Returns -1 if the last submit was rejected (no id was assigned).
static JSValue js_host_last_id(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewInt64(ctx, g_last_id);
}

// __host_cancel_raw(id): submit a TOOL_OP_CANCEL targeting the in-flight request `id`. The kernel
// completes that request's slot with -E_CANCELED (ready immediately) and frees the broker slot; the
// next event-loop poll delivers the -125 completion, which the existing status<0 path REJECTS — and
// the prelude's __host_errify turns -125 into { code:-125, name:'ECANCELED' }. Returns the cancel
// submit result (0 = accepted, negative errno e.g. -E_DENIED if the id is already gone/unknown).
static JSValue js_host_cancel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = -1;
    if (argc > 0) JS_ToInt64(ctx, &id, argv[0]);
    ToolReq req;
    req.op = TOOL_OP_CANCEL;
    req.flags = 0;
    req.arg = (uint64_t)id; // the target in-flight request id
    req.in_ptr = 0;
    req.in_len = 0;
    req.out_cap = 0;
    req.out_ptr = 0;
    int64_t rc = sys_submit((unsigned long)&req);
    return JS_NewInt64(ctx, rc);
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
    JS_SetPropertyStr(ctx, global, "__host_async_raw", JS_NewCFunction(ctx, js_host_async, "__host_async_raw", 2));
    JS_SetPropertyStr(ctx, global, "__host_spurious_raw", JS_NewCFunction(ctx, js_host_spurious, "__host_spurious_raw", 0));
    JS_SetPropertyStr(ctx, global, "__host_fs_write_raw", JS_NewCFunction(ctx, js_host_fs_write, "__host_fs_write_raw", 2));
    JS_SetPropertyStr(ctx, global, "__host_fs_read_raw", JS_NewCFunction(ctx, js_host_fs_read, "__host_fs_read_raw", 1));
    JS_SetPropertyStr(ctx, global, "__host_fs_mkdir_raw", JS_NewCFunction(ctx, js_host_fs_mkdir, "__host_fs_mkdir_raw", 1));
    JS_SetPropertyStr(ctx, global, "__host_last_id_raw", JS_NewCFunction(ctx, js_host_last_id, "__host_last_id_raw", 0));
    JS_SetPropertyStr(ctx, global, "__host_cancel_raw", JS_NewCFunction(ctx, js_host_cancel, "__host_cancel_raw", 1));
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

            // Vector drain: poll up to POLL_BATCH completions in ONE syscall, then dispatch each.
            // The kernel writes the i-th ToolEvent at evbuf[i]; `got` is how many it delivered.
            #define POLL_BATCH 4
            ToolEvent evbuf[POLL_BATCH];
            long got = sys_poll((unsigned long)evbuf, POLL_BATCH, 0);
            if (got > 0) {
                int drained = 0;
                for (long k = 0; k < got; k++) {
                    int64_t id = (int64_t)evbuf[k].id;
                    int32_t val = evbuf[k].result;
                    int32_t status = evbuf[k].status;
                    uint32_t olen = evbuf[k].out_len;
                    int found = 0;
                    for (int i = 0; i < g_inflight; i++) {
                        if (g_ids[i] == id) {
                            found = 1;
                            int bi = g_bufidx[i];
                            JSValue arg;
                            JSValue handler;
                            if (status < 0) {
                                // A failed/denied op (e.g. FS_MKDIR not allowlisted -> EDENIED):
                                // REJECT with the raw errno; the JS prelude (__host_errify) turns
                                // it into the structured error the agent catches.
                                arg = JS_NewInt32(ctx, status);
                                handler = g_rejectors[i];
                            } else if (g_kinds[i] == RES_KIND_STRING) {
                                // FS_READ: the kernel staged `olen` bytes to this request's out
                                // buffer — resolve with them as a JS string.
                                uint32_t n = olen;
                                if (bi < 0) { n = 0; }
                                else if (n > FS_OUT_CAP) { n = FS_OUT_CAP; }
                                arg = (bi >= 0) ? JS_NewStringLen(ctx, g_outbuf[bi], n)
                                                : JS_NewStringLen(ctx, "", 0);
                                handler = g_resolvers[i];
                            } else {
                                arg = JS_NewInt32(ctx, val);
                                handler = g_resolvers[i];
                            }
                            JSValue ret = JS_Call(ctx, handler, JS_UNDEFINED, 1, &arg);
                            JS_FreeValue(ctx, ret);
                            JS_FreeValue(ctx, arg);
                            JS_FreeValue(ctx, g_resolvers[i]);
                            JS_FreeValue(ctx, g_rejectors[i]);
                            if (bi >= 0) g_outbuf_used[bi] = 0; // release the out buffer
                            // Compact the inflight table (swap with the last entry).
                            g_resolvers[i] = g_resolvers[g_inflight - 1];
                            g_rejectors[i] = g_rejectors[g_inflight - 1];
                            g_ids[i] = g_ids[g_inflight - 1];
                            g_kinds[i] = g_kinds[g_inflight - 1];
                            g_bufidx[i] = g_bufidx[g_inflight - 1];
                            g_outlens[i] = g_outlens[g_inflight - 1];
                            g_inflight--;
                            break;
                        }
                    }
                    // An id with no matching resolver is a host/runtime invariant violation (the kernel
                    // emitted a completion the host never registered). Fail loudly — never silently drop.
                    if (!found) {
                        emit("host: unknown completion id\n", 28);
                        rc = 1;
                        drained = -1;
                        break;
                    }
                }
                if (drained < 0) break; // unknown id surfaced above
            } else if (got < 0) {
                // SYS_POLL faulted (should not happen with a valid evbuf) — fail rather than spin.
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
        // The event loop only exits cleanly when g_inflight == 0 (no completion outstanding), so a
        // clean exit IS the slot-reclamation proof: a cancelled request's completion was delivered
        // (rejecting its Promise) and its inflight entry was compacted away. Emit the final count as
        // a deterministic, greppable token so a gate can assert reclamation rather than infer it.
        if (rc == 0 && g_inflight == 0) {
            emit("host: inflight=0 (all slots reclaimed)\n", 39);
        }
        for (int i = 0; i < g_inflight; i++) {
            JS_FreeValue(ctx, g_resolvers[i]);
            JS_FreeValue(ctx, g_rejectors[i]);
        }
        g_inflight = 0;
    }

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
