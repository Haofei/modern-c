// agent_cancel.js — proves a JS agent can CANCEL an in-flight async request and have it surface as a
// structured ECANCELED Promise rejection, while a concurrent request still resolves normally, and the
// kernel broker slot is reclaimed (the host's event loop drains to inflight=0).
//
// Design: host_call(n, delay) returns an AbortController-like handle { promise, cancel, id }. We
// start two overlapping requests:
//   - a FAST one (delay 0) that completes normally -> resolves
//   - a SLOW one (delay 8 ticks) that we immediately cancel() -> its slot completes with -E_CANCELED
//     (ready NOW, ahead of its delayed completion), rejecting the promise as { code:-125, name:ECANCELED }.
//
// CALLBACK style (.then(onResolve, onReject)) deliberately: the freestanding QuickJS-ng compiler traps
// when reason-object fields are read inside an `await`-bearing script. Reading e.code/e.name inside a
// plain reject callback is fine.

function onWinResolve(v) {
  print("cancel-agent: winner resolved v=" + v);
}
function onWinReject(e) {
  print("cancel-agent: winner UNEXPECTED reject name=" + e.name);
}
function onLoserResolve(v) {
  print("cancel-agent: loser UNEXPECTED resolve v=" + v);
}
function onLoserReject(e) {
  print("cancel-agent: loser rejected code=" + e.code + " name=" + e.name);
}

print("cancel-agent: start");

var win = host_call(7, 0);     // completes immediately -> resolves
var loser = host_call(9, 8);   // would complete in 8 ticks, but we cancel it first

win.promise.then(onWinResolve, onWinReject);
loser.promise.then(onLoserResolve, onLoserReject);

var crc = loser.cancel();      // fire TOOL_OP_CANCEL targeting the slow request's id
print("cancel-agent: cancel submit rc=" + crc);

print("cancel-agent: submitted");
