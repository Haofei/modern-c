// agent_quota.js — proves tool-ABI back-pressure surfaces into JavaScript as a STRUCTURED error
// (object with code/name/retryable), not a bare integer. Bursts more concurrent host_async() calls
// than the kernel completion ring holds (MAX_INFLIGHT = 8); the excess are denied (-E_AGAIN) and
// their Promises reject with a structured error. A plain (non-async) rejection callback reads the
// fields and prints them; the harness verifies the shape.
//
// Uses .then(onResolve, onReject) rather than async/await: the freestanding QuickJS-ng build traps
// its bytecode compiler when reason-object fields are read inside an `await`-bearing script, so the
// callback style keeps the structured read in a plain function the compiler handles correctly.

function onResolve(v) {}

function onReject(e) {
  print("quota-agent: reject code=" + e.code + " name=" + e.name + " retryable=" + e.retryable);
}

print("quota-agent: start");
for (let i = 0; i < 12; i++) {
  host_async(i).then(onResolve, onReject);
}
print("quota-agent: submitted");
