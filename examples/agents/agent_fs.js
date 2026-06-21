// agent_fs.js — a PURE-JavaScript agent driving the REAL, capability-checked FS tool path
// (M5b.2). Unlike host_async (a mock SUM op), host_fs_write/read/mkdir dispatch through the
// kernel's capability front door (agent_fs_call -> fs_toolserver: allowlist -> budget -> path
// cap). The agent has NO authority of its own; the kernel minted it a cap rooted at "/ws" with
// read+write, and an allowlist of {FS_WRITE, FS_READ} ONLY. So:
//   - write then read under /ws  -> ALLOWED  (proves the real tool ran: read back == "hi")
//   - mkdir                      -> DENIED   (not allowlisted) -> a STRUCTURED error
//
// IMPORTANT: this uses .then(onResolve, onReject) chaining, NOT async/await. The freestanding
// QuickJS-ng build traps its bytecode compiler when reason-object fields (e.name) are read inside
// an `await`-bearing script (see agent_quota.js), so the callback style keeps every structured
// read in a plain function the compiler handles correctly.

print("fs: start");

function onMkdirReject(e) {
  // EXPECTED: mkdir is not in the allowlist, so the front door denies it. Read the structured
  // error fields in this plain callback (safe; no `await` in scope).
  print("fs: mkdir denied " + e.name);
  print("fs: ok");
}

function onMkdirResolve(v) {
  // UNEXPECTED: the deny gate failed.
  print("fs: mkdir UNEXPECTED ok");
  print("fs: ok");
}

function afterRead(value) {
  // The real FS tool returned the bytes we wrote.
  print("fs: read=" + value);
  // Now probe the denied op: mkdir is not allowlisted.
  host_fs_mkdir("/ws/sub").then(onMkdirResolve, onMkdirReject);
}

function afterWrite(n) {
  host_fs_read("/ws/a.txt").then(afterRead);
}

host_fs_write("/ws/a.txt", "hi").then(afterWrite);
