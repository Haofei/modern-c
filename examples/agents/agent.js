// agent.js — a PURE-JavaScript agent. No C. It uses only the host API the runtime injects:
//   print(str)      -> console output (SYS_WRITE)
//   host_async(n)   -> a Promise resolving to a host-computed value (non-blocking SYS_SUBMIT/POLL)
// Everything else is plain JavaScript: async/await, for-of, arrays, closures, JSON.
//
// This is the whole agent. The C runtime (qjs_host) is fixed and generic — it never changes per
// agent; you just write more JS.

async function step(label, x) {
  const y = await host_async(x);            // non-blocking host call — the agent never blocks
  print("  " + label + "(" + x + ") -> " + y);
  return y;
}

async function main() {
  print("agent: hello from pure JS");

  let total = 0;
  for (const n of [10, 20, 12]) {           // await a host op per item
    total += await step("tool", n);
  }

  const evens = [1, 2, 3, 4, 5, 6].filter((x) => x % 2 === 0);
  const summary = JSON.stringify({ steps: 3, total: total, evens: evens });

  print("agent: summary " + summary);
  print("agent: done");
}

main();
