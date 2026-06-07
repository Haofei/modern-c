const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mcc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MC compiler");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const c_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check-generated-c.sh",
        "zig-out/bin/mcc",
        "tests/c_emit_*.mc",
        "zig-out/c-test",
    });
    c_test_cmd.step.dependOn(b.getInstallStep());
    const c_test_step = b.step("c-test", "Emit C for smoke fixture and compile-check it with clang");
    c_test_step.dependOn(&c_test_cmd.step);

    const sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/spec-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    sweep_cmd.step.dependOn(b.getInstallStep());
    const sweep_step = b.step("sweep", "Emit C for every valid spec-corpus function and compile-check it with clang");
    sweep_step.dependOn(&sweep_cmd.step);

    const qemu_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/qemu-mmio-test.sh",
        "zig-out/bin/mcc",
    });
    qemu_test_cmd.step.dependOn(b.getInstallStep());
    const qemu_test_step = b.step("qemu-test", "Run the typed-MMIO program on emulated hardware under QEMU");
    qemu_test_step.dependOn(&qemu_test_cmd.step);

    const cc_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/mcc-cc-test.sh",
        "zig-out/bin/mcc",
    });
    cc_test_cmd.step.dependOn(b.getInstallStep());
    const cc_test_step = b.step("cc-test", "Compile an MC module to an object with mcc-cc, link, and run it");
    cc_test_step.dependOn(&cc_test_cmd.step);

    const std_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/std-test.sh",
        "zig-out/bin/mcc",
    });
    std_test_cmd.step.dependOn(b.getInstallStep());
    const std_test_step = b.step("std-test", "Compile std/core, link it against a C driver, and run the checks");
    std_test_step.dependOn(&std_test_cmd.step);

    const import_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/import-test.sh",
        "zig-out/bin/mcc",
    });
    import_test_cmd.step.dependOn(b.getInstallStep());
    const import_test_step = b.step("import-test", "Compile an import-merged module (sibling + std), link, and run it");
    import_test_step.dependOn(&import_test_cmd.step);

    const mono_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/mono-test.sh",
        "zig-out/bin/mcc",
    });
    mono_test_cmd.step.dependOn(b.getInstallStep());
    const mono_test_step = b.step("mono-test", "Compile a comptime-param type-generic module, link, and run the specialization");
    mono_test_step.dependOn(&mono_test_cmd.step);

    const reflect_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/reflect-test.sh",
        "zig-out/bin/mcc",
    });
    reflect_test_cmd.step.dependOn(b.getInstallStep());
    const reflect_test_step = b.step("reflect-test", "Validate comptime sizeof/alignof folding against clang's C ABI");
    reflect_test_step.dependOn(&reflect_test_cmd.step);

    const stack_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/stack-test.sh",
        "zig-out/bin/mcc",
    });
    stack_test_cmd.step.dependOn(b.getInstallStep());
    const stack_test_step = b.step("stack-test", "Build, link, and run the generic std/stack collection");
    stack_test_step.dependOn(&stack_test_cmd.step);

    const pkg_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/pkg-test.sh",
        "zig-out/bin/mcc",
    });
    pkg_test_cmd.step.dependOn(b.getInstallStep());
    const pkg_test_step = b.step("pkg-test", "Build a package from its manifest with mcc-pkg, link, and run it");
    pkg_test_step.dependOn(&pkg_test_cmd.step);

    const move_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/move-test.sh",
        "zig-out/bin/mcc",
    });
    move_test_cmd.step.dependOn(b.getInstallStep());
    const move_test_step = b.step("move-test", "Build, link, and run a linear `move` handle through the toolchain");
    move_test_step.dependOn(&move_test_cmd.step);

    const sync_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/sync-test.sh",
        "zig-out/bin/mcc",
    });
    sync_test_cmd.step.dependOn(b.getInstallStep());
    const sync_test_step = b.step("sync-test", "Build, link, and run a std/sync guarded critical section");
    sync_test_step.dependOn(&sync_test_cmd.step);

    const nic_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/nic-test.sh",
        "zig-out/bin/mcc",
    });
    nic_test_cmd.step.dependOn(b.getInstallStep());
    const nic_test_step = b.step("nic-test", "Build and run the demo NIC driver (driver-library profile) under QEMU");
    nic_test_step.dependOn(&nic_test_cmd.step);

    const virtio_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/virtio-test.sh",
        "zig-out/bin/mcc",
    });
    virtio_test_cmd.step.dependOn(b.getInstallStep());
    const virtio_test_step = b.step("virtio-test", "Build and run the real virtio-net driver against virtio-net-device under QEMU");
    virtio_test_step.dependOn(&virtio_test_cmd.step);

    const demo_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/demo-test.sh",
        "zig-out/bin/mcc",
    });
    demo_test_cmd.step.dependOn(b.getInstallStep());
    const demo_test_step = b.step("demo-test", "Lower every demo/ driver to C and compile-check it");
    demo_test_step.dependOn(&demo_test_cmd.step);

    const net_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net-test.sh",
        "zig-out/bin/mcc",
    });
    net_test_cmd.step.dependOn(b.getInstallStep());
    const net_test_step = b.step("net-test", "Run the kernel virtio-net RX/TX ARP exchange under QEMU");
    net_test_step.dependOn(&net_test_cmd.step);

    const kernel_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/kernel-test.sh",
        "zig-out/bin/mcc",
    });
    kernel_test_cmd.step.dependOn(b.getInstallStep());
    const kernel_test_step = b.step("kernel-test", "Compile-check kernel/ for riscv64 and verify typestate rejects");
    kernel_test_step.dependOn(&kernel_test_cmd.step);

    const trap_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/trap-test.sh",
        "zig-out/bin/mcc",
    });
    trap_test_cmd.step.dependOn(b.getInstallStep());
    const trap_test_step = b.step("trap-test", "Run the typed-CPU trap/timer interrupt path under QEMU");
    trap_test_step.dependOn(&trap_test_cmd.step);

    const m0_step = b.step("m0", "Run M0 conformance gates");
    m0_step.dependOn(&test_cmd.step);
    m0_step.dependOn(&c_test_cmd.step);
    m0_step.dependOn(&sweep_cmd.step);

    // qemu-test is gated separately (needs a riscv cross-toolchain + QEMU); it
    // self-skips when those are absent, so it is safe to include in m0 too.
    m0_step.dependOn(&qemu_test_cmd.step);
    // cc-test exercises the mcc-cc toolchain driver (needs clang); self-skips
    // when clang is absent.
    m0_step.dependOn(&cc_test_cmd.step);
    // std-test compiles and runs std/core through the toolchain (needs clang).
    m0_step.dependOn(&std_test_cmd.step);
    // import-test exercises the module system end-to-end (needs clang).
    m0_step.dependOn(&import_test_cmd.step);
    // mono-test exercises comptime-parameter monomorphization (needs clang).
    m0_step.dependOn(&mono_test_cmd.step);
    // reflect-test validates the comptime layout model against the C ABI.
    m0_step.dependOn(&reflect_test_cmd.step);
    // pkg-test exercises the mcc-pkg manifest build (needs clang).
    m0_step.dependOn(&pkg_test_cmd.step);
    // stack-test exercises the generic std/stack collection (needs clang).
    m0_step.dependOn(&stack_test_cmd.step);
    // move-test exercises linear `move` handle erasure (needs clang).
    m0_step.dependOn(&move_test_cmd.step);
    // sync-test exercises std/sync locks + linear guards (needs clang).
    m0_step.dependOn(&sync_test_cmd.step);
    // nic-test runs the demo NIC driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(&nic_test_cmd.step);
    // virtio-test runs the real virtio-net driver under QEMU (self-skips without QEMU).
    m0_step.dependOn(&virtio_test_cmd.step);
    // demo-test compile-checks the whole demo/ suite (needs clang).
    m0_step.dependOn(&demo_test_cmd.step);
    // net-test runs the kernel virtio-net RX/TX ARP exchange under QEMU.
    m0_step.dependOn(&net_test_cmd.step);
    // kernel-test compile-checks kernel/ for riscv64 + typestate rejects.
    m0_step.dependOn(&kernel_test_cmd.step);
    // trap-test runs the typed-CPU trap/timer interrupt path under QEMU.
    m0_step.dependOn(&trap_test_cmd.step);
}
