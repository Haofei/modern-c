// examples/apps/wasm/tool_abi.h — the kernel Tool ABI (user/abi.mc) mirrored byte-for-byte for the
// WASI shim's submit/poll path, exactly as examples/apps/qjs_host.c mirrors it for the JS host.
// Keep in sync with user/abi.mc: the kernel copies ToolReq IN and ToolEvent OUT by these offsets.

#ifndef MC_WASM_TOOL_ABI_H
#define MC_WASM_TOOL_ABI_H

#include <stdint.h>

// Tool op selectors (user/abi.mc).
#define TOOL_OP_FS_WRITE 6u
#define TOOL_OP_FS_READ  7u
#define TOOL_OP_FS_MKDIR 8u
#define TOOL_OP_NET_FETCH 9u

// Hard ABI bounds (user/abi.mc).
#define TOOL_MAX_REQ_BYTES 256u
#define TOOL_MAX_RES_BYTES 256u

// ToolReq: copied IN from user memory on SYS_SUBMIT (40 bytes; mirrors user/abi.mc).
typedef struct {
    uint32_t op;       // +0  one of TOOL_OP_*
    uint32_t flags;    // +4  reserved (0)
    uint64_t arg;      // +8  scalar argument (FS ops: path length in bytes)
    uint64_t in_ptr;   // +16 user pointer to the request payload
    uint32_t in_len;   // +24 request payload length
    uint32_t out_cap;  // +28 capacity reserved for the result payload
    uint64_t out_ptr;  // +32 user pointer to where the result payload is written on poll
} ToolReq;

// ToolEvent: copied OUT to user memory on SYS_POLL (24 bytes; mirrors user/abi.mc).
typedef struct {
    uint64_t id;       // +0  the request id this completes
    int32_t  status;   // +8  0 | -errno
    int32_t  result;   // +12 scalar result
    uint32_t out_len;  // +16 result-payload bytes written to out_ptr
    uint32_t reserved; // +20 reserved (0)
} ToolEvent;

#endif // MC_WASM_TOOL_ABI_H
