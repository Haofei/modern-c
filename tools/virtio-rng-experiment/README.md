# virtio-rng language experiment environment

The host Linux checkout lives outside this repository at `/home/zoe/src/linux`.
This keeps a multi-gigabyte upstream Git repository out of the MC worktree.

Install the Arch host dependencies:

```sh
tools/virtio-rng-experiment/install-arch.sh
```

Check the host afterwards:

```sh
tools/virtio-rng-experiment/check-environment.sh /home/zoe/src/linux
```

If root access is unavailable, build the reproducible toolchain container:

```sh
docker build \
  -t vrng-kernel-dev:arch \
  -f tools/virtio-rng-experiment/Dockerfile \
  tools/virtio-rng-experiment

docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  --device /dev/kvm \
  -v /home/zoe/src/linux:/work/linux \
  -v /home/zoe/modern-c:/work/modern-c \
  vrng-kernel-dev:arch
```

The initial upstream checkout was created with:

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
  /home/zoe/src/linux
git -C /home/zoe/src/linux switch -c vrng-lang-experiment v7.2-rc4
```

The experiment branch is based on `v7.2-rc4` /
`1590cf0329716306e948a8fc29f1d3ee87d3989f`. Its current implementation commit
is `2ed40c97aa7a0401ce9ef545af8fc9e1d421ae6f`, published as
[`Haofei/linux:vrng-lang-experiment`](https://github.com/Haofei/linux/tree/vrng-lang-experiment).

The container is sufficient for compilation and QEMU execution. Performance
numbers must be collected on the host, not inside the container, unless the
container configuration and overhead are deliberately part of the benchmark.

## Live tests

Build a kernel with the C, Rust, and MC cores plus
`CONFIG_HW_RANDOM_VIRTIO_LANG_SHADOW=y`, `CONFIG_HW_RANDOM_VIRTIO=y`, PCI
virtio, devtmpfs, and initrd support. Then create the static BusyBox initramfs:

```sh
tools/virtio-rng-experiment/make-initramfs.sh \
  /usr/sbin/busybox /home/zoe/build/vrng-live-initramfs.cpio
```

Run the real virtio-rng device test:

```sh
tools/virtio-rng-experiment/run-live-qemu.sh \
  /home/zoe/build/kunit-vrng-shadow/arch/x86/boot/bzImage \
  /home/zoe/build/vrng-live-initramfs.cpio \
  /home/zoe/build/vrng-live-qemu.log
```

For the ordinary driver path, build the Linux
`virtio_rng_lang/kunitconfig-no-shadow` fragment and run the same command with
`no-shadow` as its fourth argument.

Run the deterministic completion and queue failure matrix against a shadow
kernel with `shadow-fault` as the fourth argument. This injects zero-length and
oversized completions, a stale generation, and one queue-add failure. Every
injection must be accepted by sysfs, consumed by a live driver transition, and
followed by a successful read before the test proceeds.

Build the shadow kernel with `CONFIG_PM_DEBUG=y` and use `shadow-pm` as the
fourth argument to run three deterministic device-level suspend/restore cycles.
The test selects `pm_test=devices`, invokes the normal suspend entry point, and
requires `/dev/hwrng` plus live reads to recover after every restore without
depending on platform S3 wakeup support.

Use `shadow-hotplug` as the fourth argument for transport-level PCI removal and
re-addition. The runner opens QMP, waits until a reader is blocked behind a held
completion, deletes the `virtio-rng-pci` device, waits for the guest to observe
removal, and then adds a fresh device backed by the same QEMU RNG object. The
guest requires the blocked reader to terminate and live reads to recover before
continuing to the ordinary synchronized-unbind gate.

The init process checks normal and `bs=1/3/7` reads, then sets the test-only
`lang_copy_chunk_limit=3` parameter to force repeated driver-level partial
copies from one completion. The `bs` cases alone exercise hwrng buffering and
are not evidence for the driver's partial-copy path. The script requires both
parameter writes and their read-backs to succeed before reporting this gate.
The test then unbinds the
virtio device while two long-running `/dev/hwrng` readers are active. Shadow
mode holds one consumed completion and waits for the exported held-state marker
before unbind, making the blocked-reader condition deterministic. The runner
requires both readers to terminate, the init process to reach its completion
marker, and no kernel warning, sanitizer, lockdep, or hung-task diagnostic.
Shadow mode also requires a nonzero event count with zero C/Rust/MC differences.
