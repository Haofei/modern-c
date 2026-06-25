// host_fs_read completion must be backed by a real S-mode virtio-blk interrupt.

host_fs_read("/ws/disk").then(function (s) {
  if (s !== "DISK") {
    print("blk-irq: bad value " + s);
    return;
  }
  return host_fs_mkdir("/ws/sub").then(function () {
    print("blk-irq: mkdir FAIL");
  }, function (e) {
    print("blk-irq: ok");
  });
}, function (e) {
  print("blk-irq: read FAIL " + e);
});
