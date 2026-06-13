// kernel/lib/service — a small request/reply server loop over IPC messages. Servers (a
// filesystem, a name registry, a console) all follow the same shape: block for a request,
// dispatch on its tag, send a reply to the requester. This captures that loop once.
//
// The handler is a `closure(Message) -> Reply`: pure dispatch that also holds any server
// state in its captured environment, so the loop itself is stateless — a server can be
// restarted simply by running the loop again over fresh state. Unknown tags are the
// handler's concern (it returns an error-tagged reply), keeping policy out of the loop.

import "kernel/core/process.mc";
import "kernel/core/ipc.mc";

struct Reply {
    tag: u32, // reply tag (a handler signals "unknown request" with its own error tag)
    a0: u64,  // reply payload
}

// Build a reply (small constructor so handlers read declaratively).
export fn reply(tag: u32, a0: u64) -> Reply {
    return .{ .tag = tag, .a0 = a0 };
}

// One request/reply transaction: block for a request, hand it to `handler`, send the reply
// back to the requester. Returns the request tag so a driving loop can stop on a shutdown
// tag without the loop needing to know which tag that is.
export fn service_step(t: *mut ProcTable, handler: closure(Message) -> Reply) -> u32 {
    var req: Message = message_zero();
    ipc_receive(t, &req);
    let rep: Reply = handler(req);
    ipc_reply(t, &req, rep.tag, rep.a0, 0, 0); // echo the request's call id for correlation
    return req.tag;
}

// Serve requests until `handler` produces the `stop_tag` reply (e.g., a shutdown ack).
export fn service_loop(t: *mut ProcTable, handler: closure(Message) -> Reply, stop_tag: u32) -> void {
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(t, &req);
        let rep: Reply = handler(req);
        ipc_reply(t, &req, rep.tag, rep.a0, 0, 0); // echo the request's call id for correlation
        if rep.tag == stop_tag {
            running = false;
        }
    }
}
