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
`1590cf0329716306e948a8fc29f1d3ee87d3989f`. Its current experiment commit is
`051c15fb80a0` (teardown implementation commit `2ecc560220c6`), published as
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

Select exactly one live controller with
`CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_C`,
`CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_RUST`, or
`CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_MC`. Every transition from the selected
core is checked against the executable specification before publication; the
other enabled cores remain differential shadows. M4 qualification runs the
same normal, fault, PM, and hotplug commands for each selection.

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

Use `shadow-register-fault` to pass the built-in
`virtio_rng.lang_fail_register_once=1` fault at boot. The guest requires the
virtio device to remain bound while `/dev/hwrng` returns `ENODEV`, then
explicitly unbinds it and verifies clean removal. This qualifies the documented
degraded state of the void `.scan` callback.

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
continuing to the ordinary synchronized-unbind gate. The kernel configuration
must include `CONFIG_HOTPLUG_PCI=y` and `CONFIG_HOTPLUG_PCI_ACPI=y`; the
control-matrix runner adds both options explicitly.

The 2026-07-23 teardown requalification runs the expanded 26-test x86-64 KUnit
suite for C, Rust, and MC control. Each controller passes the normal,
completion/queue fault, registration-failure, three-cycle PM, and QMP
hotplug/replug live modes. Strict KCSAN and combined
KASAN/UBSAN/lockdep/DEBUG_ATOMIC_SLEEP/DMA-API-debug builds also pass for all
three controllers, with no diagnostic; the C sanitizer runs additionally
cover completion/queue and registration-failure injection.

## Host differential corpus

Build the MC compiler, then run the host-side BFS and corpus replay against the
Linux experiment sources:

```sh
zig build
tools/virtio-rng-experiment/run-host-differential.sh \
  /home/zoe/src/linux zig-out/bin/mcc
```

The harness links the executable specification and the actual C, Rust, and MC
protocol candidates. A return/output/state/byte mismatch writes the shortest
discovered event path as a stable `.vrng` corpus. It also compares the driver
lifecycle specification with C, Rust-raw, Rust-safe-value, MC-raw, and
MC-contract implementations across every reachable state/event pair.
Registration failure, callback publication during removal, drain-before-final-
clear, and unregister-once are part of this second model. The gate replays all
committed protocol corpora and injects both a protocol mismatch and a lifecycle
final-clear mismatch to prove that both comparators fail deterministically.

The init process checks normal and `bs=1/3/7` reads, then sets the test-only
`lang_copy_chunk_limit=3` parameter to force repeated driver-level partial
copies from one completion. The `bs` cases alone exercise hwrng buffering and
are not evidence for the driver's partial-copy path. The script requires both
parameter writes and their read-backs to succeed before reporting this gate.
The test then unbinds the
virtio device while two long-running `/dev/hwrng` readers are active. Shadow
mode pauses a callback after its logical completion and before external
availability publication, starts unbind, waits until removal passes
``begin_remove``, and then releases the callback. The runner requires the final
logical state to be ``Dead/Empty`` and the captured external availability to be
zero. This makes the publication/removal interleaving deterministic. The runner
requires both readers to terminate, the init process to reach its completion
marker, and no kernel warning, sanitizer, lockdep, or hung-task diagnostic.
Shadow mode also requires a nonzero event count with zero C/Rust/MC differences.

Run the symmetric MC/Rust DMA typestate compile-pass/compile-fail gate:

```sh
tools/virtio-rng-experiment/run-dma-ownership.sh \
  /home/zoe/src/linux zig-out/bin/mcc
```

Run the first kernel-contract mutation matrix. It proves that raw C and raw-FFI
Rust accept the deliberate device-owned CPU access while Rust-safe and
MC-contract reject it. It also checks stable MC rejection for IRQ sleep,
unbounded IRQ flow, callback language traps, move/resource misuse, RCU and
callback lifetime escape, unguarded lock data, stack/borrow escape, direct or
misordered MMIO, address-space conversion, and DMA-address dereference. The
ordinary spec suite supplies the accepted controls for the mixed fixtures:

```sh
tools/virtio-rng-experiment/run-contract-mutations.sh \
  /home/zoe/src/linux zig-out/bin/mcc
```

Capture reproducible source/object/TCB-marker metrics and a protocol-core
microbenchmark:

```sh
tools/virtio-rng-experiment/run-comparison-metrics.sh \
  /home/zoe/src/linux zig-out/bin/mcc /tmp/vrng-comparison-metrics.tsv
```

The command writes a sibling `*-benchmark.tsv` report for the same optimized
`begin_submit`/`complete`/`copy` cycle in each core. It rotates controller order
across seven samples and reports the median, then rejects MC if its median
per-event cost exceeds either C or Rust by more than 1.25 times. Object sizes
exclude debug sections for all implementations. It is a controlled transition-
throughput measurement, not a whole-driver, IRQ-latency, reviewer-time, or
production-performance claim. Set `VRNG_BENCHMARK_ITERATIONS` to override the
default one million iterations, `VRNG_BENCHMARK_SAMPLES` to an odd value up to
31, or `VRNG_BENCHMARK_MAX_MC_RATIO` to change the registered limit (`0`
disables only the performance rejection).
