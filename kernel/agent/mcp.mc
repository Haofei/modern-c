// kernel/agent/mcp — the MCP-compatible façade (M4): speak MCP, enforce with MC
// capabilities.
//
// The strategy is "speak MCP, don't RUN MCP": MC does not host arbitrary foreign
// MCP servers (that would drag opaque runtimes back inside the trust boundary).
// Instead it exposes its OWN native, capability-checked tools under an
// MCP-shaped surface — a catalog of named tool descriptors an MCP client can list
// and invoke by name. This module is the name→authority bridge: it resolves an
// MCP method name to a native tool id and dispatches it through the SAME
// capability front door (agent_fs_call → path capability). MCP is the
// compatibility layer; MC capabilities are the enforcement layer. An MCP call can
// never do more than the agent's capabilities allow, and an unknown method is
// simply NoSuchTool.
//
// (The JSON-RPC wire envelope is a thin adapter on top of this: parse
// method/params, call mcp_call, format the Result. The substance — and the place
// authority is enforced — is this structured mapping.)

import "kernel/fs/agent_fs.mc";   // agent_fs_call, AgentFs, AgentToolError, TOOL_FS_*
import "kernel/fs/treefs.mc";     // Tree
import "kernel/core/ipc_trace.mc";// IpcTrace
import "std/bytes.mc";
import "std/addr.mc";
import "std/mem.mc";

const MCP_MAX: usize = 8;       // tools the catalog can advertise
const MCP_NAME_POOL: usize = 256;
const MCP_NONE: u32 = 0xFFFF_FFFF;

// One advertised MCP tool: its method name (interned) and the native tool id it
// maps to. A real descriptor would also carry a JSON input schema; the schema is
// presentation, the tool_id is the authority binding.
struct McpTool {
    name_off: usize,
    name_len: usize,
    tool_id: u32,
    used: bool,
}

struct McpCatalog {
    tools: [MCP_MAX]McpTool,
    names: [MCP_NAME_POOL]u8,
    name_used: usize,
}

export fn mcp_init(c: *mut McpCatalog) -> void {
    var i: usize = 0;
    while i < MCP_MAX {
        c.tools[i].used = false;
        i = i + 1;
    }
    c.name_used = 0;
}

// Advertise an MCP method `name` bound to native `tool_id`. false if the catalog
// or its name pool is full. (Kernel-side catalog construction; the agent only
// gets to CALL names, never to bind new ones.)
export fn mcp_register(c: *mut McpCatalog, name: usize, name_len: usize, tool_id: u32) -> bool {
    var slot: usize = MCP_MAX;
    var i: usize = 0;
    while i < MCP_MAX {
        if !c.tools[i].used {
            slot = i;
            break;
        }
        i = i + 1;
    }
    if slot == MCP_MAX {
        return false;
    }
    if !fits_within(c.name_used, name_len, MCP_NAME_POOL) {
        return false;
    }
    var r: ByteReader = byte_reader(pa(name), name_len);
    let noff: usize = c.name_used;
    var j: usize = 0;
    while j < name_len {
        c.names[noff + j] = br_u8(&r, j);
        j = j + 1;
    }
    c.tools[slot].name_off = noff;
    c.tools[slot].name_len = name_len;
    c.tools[slot].tool_id = tool_id;
    c.tools[slot].used = true;
    c.name_used = noff + name_len;
    return true;
}

fn mcp_name_eq(c: *mut McpCatalog, idx: usize, r: *ByteReader, qlen: usize) -> bool {
    if c.tools[idx].name_len != qlen {
        return false;
    }
    let noff: usize = c.tools[idx].name_off;
    var j: usize = 0;
    while j < qlen {
        if c.names[noff + j] != br_u8(r, j) {
            return false;
        }
        j = j + 1;
    }
    return true;
}

// Resolve an MCP method name to its native tool id, or MCP_NONE if unadvertised.
export fn mcp_resolve(c: *mut McpCatalog, name: usize, name_len: usize) -> u32 {
    var q: ByteReader = byte_reader(pa(name), name_len);
    var i: usize = 0;
    while i < MCP_MAX {
        if c.tools[i].used {
            if mcp_name_eq(c, i, &q, name_len) {
                return c.tools[i].tool_id;
            }
        }
        i = i + 1;
    }
    return MCP_NONE;
}

// Invoke an MCP tool by method name on behalf of `agent`. The name is resolved to
// a native tool id and dispatched through the capability front door — so the path
// capability + tool allowlist + budget all apply exactly as for a native call. An
// unadvertised method is NoSuchTool; everything else is the front door's verdict.
export fn mcp_call(c: *mut McpCatalog, t: *mut Tree, sink: *mut IpcTrace, agent: *mut AgentFs, name: usize, name_len: usize, path: usize, path_len: usize, offset: usize, buf: usize, n: usize, capacity: usize) -> Result<usize, AgentToolError> {
    let tid: u32 = mcp_resolve(c, name, name_len);
    if tid == MCP_NONE {
        return err(.NoSuchTool);
    }
    return agent_fs_call(t, sink, agent, tid, path, path_len, offset, buf, n, capacity);
}
