// agent_broker.js — proves the mock broker delivers completions OUT OF submit order: a short-delay
// request submitted AFTER a long-delay one completes FIRST. host_async(arg, delay) sets the broker
// delay (virtual ticks); the resolve callbacks append to an order string, so "FS" proves the fast
// (delay 1) request resolved before the slow (delay 5) one even though slow was submitted first.
//
// Callback (non-async) style — see the QuickJS-ng await/reason-field quirk noted in agent_quota.js.

print("broker-agent: start");

let order = "";
let slow = host_async(10, 5).then(function (v) { order = order + "S"; });
let fast = host_async(20, 1).then(function (v) { order = order + "F"; });

Promise.all([slow, fast]).then(function () {
  print("broker-agent: order=" + order);
  print("broker-agent: done");
});

print("broker-agent: submitted");
