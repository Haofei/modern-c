// Real TCP-backed production JS network tool smoke.
// host_net_fetch(1, token) reaches a live HTTP server through the kernel broker's net_fetch_tcp.

let stage = "";

function fail(label) {
  print("net-real: fail " + label);
}

function maybeDone() {
  if (stage === "WDB") {
    print("net-real: ok");
  }
}

host_net_fetch(1, 7).then(function (n) {
  if (n > 0) {
    stage = stage + "W";
  } else {
    fail("web-empty");
  }
  return host_net_fetch(9, 999);
}).then(function (v) {
  fail("evil-allowed");
}, function (e) {
  if (e.name === "EDENIED") {
    stage = stage + "D";
  } else {
    fail("evil-error");
  }
  return host_net_fetch(1, 8);
}).then(function (n) {
  fail("budget-allowed");
}, function (e) {
  if (e.name === "EAGAIN") {
    stage = stage + "B";
    maybeDone();
  } else {
    fail("budget-error-" + e.name);
  }
});
