// agent_smoke.js -- THE canonical "agent async smoke" demo. A confined PURE-JS agent walks the whole
// async-agent happy path in ONE run and prints AGENT-SMOKE-OK only if every stage passed:
//   stage1 host_call    -- a SUM tool call that RESOLVES (op = arg+2, host_call(7) -> 9)
//   stage2 host_fs_read -- a REAL capability-checked FS read that RESOLVES with bytes ("hi" round-trip)
//   stage3 host_sleep   -- an async TIMEOUT; the fired timer surfaces as a structured ETIMEDOUT reject
//   stage4 cancel       -- a CANCEL of an in-flight request; rejects structured ECANCELED (code -125)
// The host then drains to "inflight=0 (all slots reclaimed)" with NO "unknown completion id".
//
// CALLBACK style (.then), NAMED top-level callbacks, and a deliberately TERSE body. Two freestanding
// QuickJS-ng quirks shape this code: (1) reading reason-object fields inside an `await`-bearing script
// traps the bytecode compiler -- so no async/await; (2) reading the SAME reason field TWICE in one
// callback also traps -- so a reject callback reads each of e.code/e.name into a local ONCE, then uses
// the locals. The four stages CHAIN through each other's settle callbacks for a deterministic run.
var okCall=false, okRead=false, okSleep=false, okCancel=false;
print("smoke-agent: start");
// AGENT-SMOKE-OK is a strict AND of every stage; any missing stage withholds the token (gate fails).
function finish(){ if(okCall&&okRead&&okSleep&&okCancel) print("AGENT-SMOKE-OK"); else print("smoke-agent: FAIL call="+okCall+" read="+okRead+" sleep="+okSleep+" cancel="+okCancel); }
// stage4: cancel an in-flight request -> structured ECANCELED. Read each reason field into a local ONCE.
function onCancelReject(e){ var c=e.code; var nm=e.name; if(c===-125&&nm==="ECANCELED"){okCancel=true;print("smoke-agent: stage4 cancel rejected code="+c+" name="+nm);} finish(); }
function onCancelResolve(v){ print("smoke-agent: stage4 UNEXPECTED resolve"); finish(); }
function stageCancel(){ var slow=host_call(9,8); slow.promise.then(onCancelResolve,onCancelReject); var rc=slow.cancel(); print("smoke-agent: stage4 cancel submit rc="+rc); }
// stage3: async timeout -> ETIMEDOUT (the fired timer == "slept").
function onSleepReject(e){ var c=e.code; var nm=e.name; if(c===-110&&nm==="ETIMEDOUT"){okSleep=true;print("smoke-agent: stage3 slept (timer fired) name="+nm);} stageCancel(); }
function onSleepResolve(v){ print("smoke-agent: stage3 UNEXPECTED resolve"); stageCancel(); }
function stageSleep(){ host_sleep(3).then(onSleepResolve,onSleepReject); }
// stage2: real capability-checked FS read -> resolves with non-empty bytes.
function afterRead(value){ print("smoke-agent: stage2 read="+value); if(typeof value==="string"&&value.length>0&&value==="hi")okRead=true; stageSleep(); }
function onReadReject(e){ print("smoke-agent: stage2 FAIL read rejected"); stageSleep(); }
function afterWrite(n){ host_fs_read("/ws/smoke.txt").then(afterRead,onReadReject); }
function onWriteReject(e){ print("smoke-agent: stage2 FAIL write rejected"); stageSleep(); }
function stageRead(){ host_fs_write("/ws/smoke.txt","hi").then(afterWrite,onWriteReject); }
// stage1: host_call SUM that RESOLVES.
function onCallResolve(v){ if(v===9){okCall=true;print("smoke-agent: stage1 resolved v="+v);} stageRead(); }
function onCallReject(e){ print("smoke-agent: stage1 UNEXPECTED reject"); stageRead(); }
function stageCall(){ var h=host_call(7,0); h.promise.then(onCallResolve,onCallReject); }
stageCall();
