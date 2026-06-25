// host_net_fetch completion must be backed by a real S-mode virtio-net interrupt.

host_net_fetch(1, 7).then(function (v) {
  if (v !== 1) {
    print("net-irq: bad value " + v);
    return;
  }
  return host_net_fetch(9, 999).then(function () {
    print("net-irq: denied FAIL");
  }, function (e) {
    return host_net_fetch(1, 8).then(function () {
      print("net-irq: budget FAIL");
    }, function (b) {
      print("net-irq: ok");
    });
  });
}, function (e) {
  print("net-irq: first fetch FAIL " + e);
});
