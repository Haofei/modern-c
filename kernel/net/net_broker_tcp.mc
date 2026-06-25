// kernel/net/net_broker_tcp — REAL TCP transport for the shared agent network broker.
//
// `kernel/net/net_broker.mc` owns the reusable policy/control plane and the mock transport used by
// non-device images. This file adds the TCP dispatch layer, so consumers that only need the
// production tool ABI can import the broker without pulling virtio-net/tcp_socket into their image.

import "kernel/net/net_broker.mc";
import "kernel/net/tcp_socket.mc";  // TcpSocket + tcp_socket_connect/send/recv
import "kernel/net/ethernet.mc";    // MacAddr

// THE BROKERED CALL (REAL TCP transport). Runs the EXACT SAME policy as net_fetch (Denied before
// Budget before NoEndpoint; a Denied call sends NO packet and is not audited), then dispatches over
// a genuine TCP connection: it active-opens the socket to the resolved endpoint's (dst_ip, dst_port),
// sends `req_len` request bytes from `req_src`, and drains the response into `resp_dst`/`resp_max`.
// The caller supplies the bound socket, the source MAC, the resolved gateway MAC, the guest source
// IP + ephemeral source port, and the RX scratch region the socket receives frames into (the same
// shape http_get_demo uses). `req` (the audit size, an application request token) is recorded by the
// policy; the bytes actually sent are `req_src`/`req_len`.
//
// Returns ok(resp_len) — the number of response bytes drained into resp_dst (>0 on a real reply) —
// or err(.NoEndpoint) if the TCP active-open/send fails after admission (the dispatch could not
// reach the resolved endpoint). Policy failures return Denied/Budget/NoEndpoint as usual, BEFORE any
// socket work, so a denied destination never touches the wire.
export fn net_fetch_tcp(
    t: *mut ProcTable, reg: *mut EndpointRegistry, sb: *mut Sandbox, nc: *mut NetCap,
    endpoint_id: u32, req: u32,
    sock: *mut TcpSocket,
    src_mac: *MacAddr, gw_mac: *MacAddr, src_ip: u32, src_port: u16,
    req_src: usize, req_len: usize,
    resp_dst: usize, resp_max: usize,
) -> Result<u32, BrokerError> {
    switch net_policy_admit(t, reg, sb, nc, endpoint_id, req) {
        ok(slot) => {
            // Dispatch: the REAL transport. Resolve the destination, then put packets on the wire.
            let dst_ip: u32 = endpoint_dst_ip_at(reg, slot);
            let dst_port: u16 = endpoint_dst_port_at(reg, slot);

            // Active-open (SYN -> SYN-ACK -> ACK -> ESTABLISHED) to the resolved endpoint.
            if tcp_socket_connect(sock, src_mac, gw_mac, src_ip, dst_ip, src_port, dst_port) == 0 {
                return err(.NoEndpoint); // could not reach the resolved endpoint
            }
            // Send the request bytes as one PSH|ACK segment.
            if tcp_socket_send(sock, req_src, req_len) == 0xFFFF_FFFF {
                return err(.NoEndpoint); // TX failure after connect
            }
            // Drain the response: the socket layer reassembles multi-record segments and ACKs them.
            var total: usize = 0;
            while true {
                if total >= resp_max {
                    break;
                }
                let n: u32 = tcp_socket_recv(sock, resp_dst + total, resp_max - total);
                if n == 0 {
                    break; // clean EOF (FIN)
                }
                if n == 0xFFFF_FFFF {
                    break; // timeout / no more segments
                }
                total = total + (n as usize);
            }
            return ok(total as u32);
        }
        err(e) => { return err(e); } // Denied / Budget / NoEndpoint — no dispatch, NO packet on the wire.
    }
}
