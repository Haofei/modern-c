// agent_spurious.js — drives the TEST-ONLY spurious op, whose completion carries a BOGUS id the
// host never registered. This exercises the host event loop's FATAL "unknown completion id" path
// (item 6 hardening): the host must fail loudly rather than silently drop the stray completion.

print("spurious-agent: start");
host_spurious().then(function () {}, function () {});
print("spurious-agent: submitted");
