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
is `83a4ba9acbf65b45a2f73e0472b492d26ddc94e5`, published as
[`Haofei/linux:vrng-lang-experiment`](https://github.com/Haofei/linux/tree/vrng-lang-experiment).

The container is sufficient for compilation and QEMU execution. Performance
numbers must be collected on the host, not inside the container, unless the
container configuration and overhead are deliberately part of the benchmark.

## Live shadow test

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

The init process first checks normal reads, then unbinds the virtio device while
two long-running `/dev/hwrng` readers are active. The runner requires both
readers to terminate, the init process to reach its completion marker, a
nonzero event count with zero C/Rust/MC differences, and no kernel warning,
sanitizer, lockdep, or hung-task diagnostic.
