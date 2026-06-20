// agent_async.js — a PURE-JavaScript agent that exercises the async-I/O contract under load,
// not just the happy path. It proves three things the sequential agent.js cannot:
//
//   1. OVERLAP + independent completion: fire several host_async() WITHOUT awaiting, then
//      Promise.all — multiple requests are outstanding at once and each resolves on its own
//      completion. With the kernel op = arg+2, [1,2,3,4] -> [3,4,5,6].
//   2. BACK-PRESSURE / DENIAL: burst MORE requests at once than the kernel completion queue
//      can hold (COMP_CAP = 8). The excess submissions get -E_AGAIN and their Promises REJECT
//      rather than hang forever. Promise.allSettled lets us count fulfilled vs rejected.
//   3. No silent drop: every request settles (fulfilled or rejected) — none is left pending.
//
// Everything here is plain JavaScript over the injected host API (print, host_async). No C.

async function main() {
  print("async-agent: start");

  // (1) Four overlapping requests, awaited together. Order is preserved by Promise.all.
  const xs = await Promise.all([host_async(1), host_async(2), host_async(3), host_async(4)]);
  print("async-agent: all=" + JSON.stringify(xs)); // [3,4,5,6]

  // (2) Burst 12 at once — past the kernel's 8-deep completion queue. The first 8 are accepted
  // and resolve; the last 4 are denied (-E_AGAIN) and reject. allSettled never throws.
  const burst = [];
  for (let i = 0; i < 12; i++) burst.push(host_async(100 + i));
  const settled = await Promise.allSettled(burst);

  let ok = 0;
  let rejected = 0;
  for (const s of settled) {
    if (s.status === "fulfilled") ok++;
    else rejected++;
  }
  print("async-agent: backpressure ok=" + ok + " rejected=" + rejected); // ok=8 rejected=4
  print("async-agent: done");
}

main();
