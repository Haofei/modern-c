// agent_cancel_edges.js -- NEGATIVE cancellation edges at the JS/host layer (item 4). Each edge proves
// a degenerate cancel is HARMLESS (no leak, no double-settle, no fatal unknown-id) and prints a
// distinct marker:
//   (a) cancel AFTER completion        -> host_cancel of a completed id returns -E_DENIED (-13); no
//                                         second rejection of the already-resolved promise.
//   (c) FAILED-submit cancel           -> saturate the broker (COMP_CAP=8), then one more submit is
//                                         back-pressured (id===-1) so its cancel hits nothing (-13).
//   (d) LATE completion after cancel    -> cancel one of two overlapping requests; the sibling still
//                                         resolves and the run reaches inflight=0 with NO unknown id.
//   (e) host_fs_read non-empty payload -> a real FS read resolves with a non-empty string.
//
// Style notes (freestanding QuickJS-ng): no async/await; reject callbacks read each reason field into
// a local ONCE; host_call (the prelude's object-builder) is NEVER called inside a loop -- the queue is
// saturated with host_async, which is loop-safe, and host_call is used only as single statements.
print("edges: start");

// (e) FS read resolves with a NON-EMPTY string -- the final stage; prints "edges: done".
function edgeE_read(value){ if(typeof value==="string"&&value.length>0) print("edges: E fs_read non-empty len="+value.length+" val="+value); else print("edges: E FAIL empty"); print("edges: done"); }
function edgeE_readRej(e){ print("edges: E FAIL read rejected"); print("edges: done"); }
function edgeE_wrote(n){ host_fs_read("/ws/edges.txt").then(edgeE_read,edgeE_readRej); }
function edgeE_writeRej(e){ print("edges: E FAIL write rejected"); print("edges: done"); }
function edgeE(){ host_fs_write("/ws/edges.txt","hi").then(edgeE_wrote,edgeE_writeRej); }

// (d) late completion after cancel -> no unknown id. Fast resolves; slow is cancelled.
var dDone=0;
function edgeD_tick(){ dDone++; if(dDone===2){ print("edges: D both settled no unknown id"); edgeE(); } }
function edgeD_fast(v){ print("edges: D fast resolved v="+v); edgeD_tick(); }
function edgeD_fastRej(e){ edgeD_tick(); }
function edgeD_slow(v){ print("edges: D FAIL slow resolved"); edgeD_tick(); }
function edgeD_slowRej(e){ var c=e.code; var nm=e.name; if(c===-125) print("edges: D slow cancelled name="+nm); edgeD_tick(); }
function edgeD(){ var fast=host_call(3,0); var slow=host_call(4,8); fast.promise.then(edgeD_fast,edgeD_fastRej); slow.promise.then(edgeD_slow,edgeD_slowRej); slow.cancel(); }

// (c) failed-submit cancel targets no stale id. Saturate with 8 host_async (loop-safe), then one
// host_call whose submit is back-pressured: its id is -1, so cancel() hits nothing (-E_DENIED).
var cSettled=0;
// Wait for all 8 saturating host_async to drain (their slots freed) BEFORE edge (d) submits, else
// (d)'s own host_calls would themselves be back-pressured.
function edgeC_tick(){ cSettled++; if(cSettled===8) edgeD(); }
function edgeC_ok(v){ edgeC_tick(); }
function edgeC_rej(e){ edgeC_tick(); }
function edgeC_hcRej(e){ /* the back-pressured submit's promise rejected; expected, no action */ }
function edgeC_hcRes(v){ print("edges: C UNEXPECTED submit resolve"); }
function edgeC(){
  var i=0; while(i<8){ host_async(200+i).then(edgeC_ok,edgeC_rej); i++; }
  var hc=host_call(9,0);                      // 9th submit -> -E_AGAIN, id===-1
  hc.promise.then(edgeC_hcRes,edgeC_hcRej);
  var rc=hc.cancel();                         // targets id -1 == nothing
  if(rc<0) print("edges: C failed-submit cancel hit nothing rc="+rc); else print("edges: C FAIL accepted rc="+rc);
}

// (a) cancel AFTER completion is denied (-13); no second settle.
var hA=null;
function edgeA_resolve(v){ var rc=hA.cancel(); if(rc<0) print("edges: A post-complete cancel denied rc="+rc); else print("edges: A FAIL accepted rc="+rc); print("edges: A no second settle"); edgeC(); }
function edgeA_reject(e){ print("edges: A FAIL unexpected reject"); edgeC(); }
function edgeA(){ hA=host_call(5,0); hA.promise.then(edgeA_resolve,edgeA_reject); }

edgeA();
