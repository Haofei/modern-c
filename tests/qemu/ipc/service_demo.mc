import "kernel/lib/service.mc";
import "kernel/core/process.mc";
import "kernel/core/ipc.mc";

const TAG_DOUBLE: u32 = 1;
const TAG_UNKNOWN: u32 = 0xEE;

struct Server { calls: u32 } // server state lives outside the loop (restart-friendly)
global g_t: ProcTable;
global g_srv: Server;

fn handle(s: *mut Server, req: Message) -> Reply {
    s.calls = s.calls + 1;
    if req.tag == TAG_DOUBLE {
        return reply(TAG_DOUBLE, req.a0 * 2);
    }
    return reply(TAG_UNKNOWN, 0); // unknown request -> error reply
}

export fn service_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    g_srv.calls = 0;
    let h: closure(Message) -> Reply = bind(&g_srv, handle);
    var rep: Message = message_zero();

    // a request lands in the server's inbox; service_step receives, handles, replies
    if !ipc_send_try(&g_t, 0, TAG_DOUBLE, 21, 0, 0) { pass = 0; }
    if service_step(&g_t, h) != TAG_DOUBLE { pass = 0; } // returns the request tag
    ipc_receive(&g_t, &rep);
    if rep.tag != TAG_DOUBLE { pass = 0; }
    if rep.a0 != 42 { pass = 0; }                        // 21 doubled

    // unknown request tag -> the handler's error reply
    if !ipc_send_try(&g_t, 0, 999, 5, 0, 0) { pass = 0; }
    if service_step(&g_t, h) != 999 { pass = 0; }
    ipc_receive(&g_t, &rep);
    if rep.tag != TAG_UNKNOWN { pass = 0; }

    // the loop is stateless; the server's state accumulated in the handler env
    if g_srv.calls != 2 { pass = 0; }
    return pass;
}
