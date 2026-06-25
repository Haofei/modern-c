// Production JS/tool-surface network broker smoke.
// host_net_fetch(endpoint, token) goes through SYS_SUBMIT/SYS_POLL into the kernel network broker.

let stage = "";

function fail(label) {
  print("net: fail " + label);
}

function doneIfReady() {
  if (stage === "WDB") {
    print("net: ok");
  }
}

host_net_fetch(1, 7).then(function (v) {
  if (v === 107) {
    stage = stage + "W";
  } else {
    fail("web-value");
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
}).then(function (v) {
  if (v !== 108) {
    fail("web2-value");
  }
  return host_net_fetch(1, 9);
}).then(function (v) {
  fail("budget-allowed");
}, function (e) {
  if (e.name === "EAGAIN") {
    stage = stage + "B";
    doneIfReady();
  } else {
    fail("budget-error");
  }
});
