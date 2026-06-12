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
        "tools/toolchain/check-generated-c.sh",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
        "zig-out/c-test",
    });
    c_test_cmd.step.dependOn(b.getInstallStep());
    const c_test_step = b.step("c-test", "Emit C for smoke fixture and compile-check it with clang");
    c_test_step.dependOn(&c_test_cmd.step);

    const llvm_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-test.sh",
        "zig-out/bin/mcc",
        "zig-out/llvm-test",
    });
    llvm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_test_step = b.step("llvm-test", "Emit LLVM IR for the initial backend slice and validate it with llvm-as");
    llvm_test_step.dependOn(&llvm_test_cmd.step);

    const llvm_obj_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-obj-test.sh",
        "zig-out/bin/mcc",
        "zig-out/llvm-obj-test",
    });
    llvm_obj_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_obj_test_step = b.step("llvm-obj-test", "Compile LLVM backend fixtures to object files with llc");
    llvm_obj_test_step.dependOn(&llvm_obj_test_cmd.step);

    const llvm_debug_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-debug-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_debug_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_debug_test_step = b.step("llvm-debug-test", "Verify LLVM object DWARF source and line mappings");
    llvm_debug_test_step.dependOn(&llvm_debug_test_cmd.step);

    const sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    sweep_cmd.step.dependOn(b.getInstallStep());
    const sweep_step = b.step("sweep", "Emit C for every valid spec-corpus function and compile-check it with clang");
    sweep_step.dependOn(&sweep_cmd.step);

    const llvm_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-llvm-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
    });
    llvm_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_sweep_step = b.step("llvm-sweep", "Emit LLVM IR for every in-scope valid spec-corpus fixture and validate it with llvm-as");
    llvm_sweep_step.dependOn(&llvm_sweep_cmd.step);

    const llvm_spec_obj_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/spec-llvm-obj-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
        "zig-out/llvm-spec-obj-sweep",
    });
    llvm_spec_obj_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_spec_obj_sweep_step = b.step("llvm-spec-obj-sweep", "Compile every in-scope valid spec-corpus fixture to an LLVM object with llc");
    llvm_spec_obj_sweep_step.dependOn(&llvm_spec_obj_sweep_cmd.step);

    const llvm_c_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-c-emit-sweep.py",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
    });
    llvm_c_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_c_sweep_step = b.step("llvm-c-sweep", "Emit LLVM IR for every checked C-emission fixture and validate it with llvm-as");
    llvm_c_sweep_step.dependOn(&llvm_c_sweep_cmd.step);

    const llvm_opt_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-opt-sweep.py",
        "zig-out/bin/mcc",
        "tests/spec",
        "tests/c_emit/*.mc",
    });
    llvm_opt_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_opt_sweep_step = b.step("llvm-opt-sweep", "Run LLVM verifier, O2 optimizer, and optimized object checks over broad emitted IR");
    llvm_opt_sweep_step.dependOn(&llvm_opt_sweep_cmd.step);

    const llvm_c_obj_sweep_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/toolchain/llvm-c-obj-sweep.py",
        "zig-out/bin/mcc",
        "tests/c_emit/*.mc",
        "zig-out/llvm-c-obj-sweep",
    });
    llvm_c_obj_sweep_cmd.step.dependOn(b.getInstallStep());
    const llvm_c_obj_sweep_step = b.step("llvm-c-obj-sweep", "Compile every checked C-emission fixture to an LLVM object with llc");
    llvm_c_obj_sweep_step.dependOn(&llvm_c_obj_sweep_cmd.step);

    const qemu_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/qemu-mmio-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    qemu_test_cmd.step.dependOn(b.getInstallStep());
    const qemu_test_step = b.step("qemu-test", "Run the typed-MMIO program on emulated hardware under QEMU");
    qemu_test_step.dependOn(&qemu_test_cmd.step);

    const llvm_qemu_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/qemu-mmio-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_qemu_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_qemu_test_step = b.step("llvm-qemu-test", "Run the LLVM-lowered typed-MMIO program under QEMU");
    llvm_qemu_test_step.dependOn(&llvm_qemu_test_cmd.step);

    const cc_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/mcc-cc-test.sh",
        "zig-out/bin/mcc",
    });
    cc_test_cmd.step.dependOn(b.getInstallStep());
    const cc_test_step = b.step("cc-test", "Compile an MC module to an object with mcc-cc, link, and run it");
    cc_test_step.dependOn(&cc_test_cmd.step);

    const llvm_cc_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/mcc-llvm-cc-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_cc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cc_test_step = b.step("llvm-cc-test", "Compile an MC module to an object with mcc-llvm-cc, link, and run it");
    llvm_cc_test_step.dependOn(&llvm_cc_test_cmd.step);

    const std_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/std-test.sh",
        "zig-out/bin/mcc",
    });
    std_test_cmd.step.dependOn(b.getInstallStep());
    const std_test_step = b.step("std-test", "Compile std/core, link it against a C driver, and run the checks");
    std_test_step.dependOn(&std_test_cmd.step);

    const llvm_std_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-std-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_std_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_std_test_step = b.step("llvm-std-test", "Compile std modules through LLVM, link them against a C driver, and run the checks");
    llvm_std_test_step.dependOn(&llvm_std_test_cmd.step);

    const llvm_toolchain_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-toolchain-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_toolchain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_toolchain_test_step = b.step("llvm-toolchain-test", "Build, link, and run import, monomorphization, and reflection modules through LLVM");
    llvm_toolchain_test_step.dependOn(&llvm_toolchain_test_cmd.step);

    const import_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/import-test.sh",
        "zig-out/bin/mcc",
    });
    import_test_cmd.step.dependOn(b.getInstallStep());
    const import_test_step = b.step("import-test", "Compile an import-merged module (sibling + std), link, and run it");
    import_test_step.dependOn(&import_test_cmd.step);

    const mono_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/mono-test.sh",
        "zig-out/bin/mcc",
    });
    mono_test_cmd.step.dependOn(b.getInstallStep());
    const mono_test_step = b.step("mono-test", "Compile a comptime-param type-generic module, link, and run the specialization");
    mono_test_step.dependOn(&mono_test_cmd.step);

    const reflect_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/reflect-test.sh",
        "zig-out/bin/mcc",
    });
    reflect_test_cmd.step.dependOn(b.getInstallStep());
    const reflect_test_step = b.step("reflect-test", "Validate comptime sizeof/alignof folding against clang's C ABI");
    reflect_test_step.dependOn(&reflect_test_cmd.step);

    const stack_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/stack-test.sh",
        "zig-out/bin/mcc",
    });
    stack_test_cmd.step.dependOn(b.getInstallStep());
    const stack_test_step = b.step("stack-test", "Build, link, and run the generic std/stack collection");
    stack_test_step.dependOn(&stack_test_cmd.step);

    const pkg_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/pkg-test.sh",
        "zig-out/bin/mcc",
    });
    pkg_test_cmd.step.dependOn(b.getInstallStep());
    const pkg_test_step = b.step("pkg-test", "Build a package from its manifest with mcc-pkg, link, and run it");
    pkg_test_step.dependOn(&pkg_test_cmd.step);

    const llvm_pkg_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-pkg-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_pkg_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_pkg_test_step = b.step("llvm-pkg-test", "Build a package from its manifest through LLVM, link, and run it");
    llvm_pkg_test_step.dependOn(&llvm_pkg_test_cmd.step);

    const llvm_demo_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-demo-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_demo_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_demo_test_step = b.step("llvm-demo-test", "Compile supported demo drivers through LLVM to objects");
    llvm_demo_test_step.dependOn(&llvm_demo_test_cmd.step);

    const llvm_kernel_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-kernel-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_kernel_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kernel_test_step = b.step("llvm-kernel-test", "Compile kernel modules through LLVM to target objects");
    llvm_kernel_test_step.dependOn(&llvm_kernel_test_cmd.step);

    const llvm_hosted_demo_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-hosted-demo-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_hosted_demo_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_hosted_demo_test_step = b.step("llvm-hosted-demo-test", "Compile the hosted demo through LLVM, link it, and run the stdin/stdout check");
    llvm_hosted_demo_test_step.dependOn(&llvm_hosted_demo_test_cmd.step);

    const llvm_host_suite_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/toolchain/llvm-host-suite-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_host_suite_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_host_suite_test_step = b.step("llvm-host-suite-test", "Compile host-driver manifest fixtures through LLVM, link them, and run them");
    llvm_host_suite_test_step.dependOn(&llvm_host_suite_test_cmd.step);

    const move_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/move-test.sh",
        "zig-out/bin/mcc",
    });
    move_test_cmd.step.dependOn(b.getInstallStep());
    const move_test_step = b.step("move-test", "Build, link, and run a linear `move` handle through the toolchain");
    move_test_step.dependOn(&move_test_cmd.step);

    const llvm_move_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-move-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_move_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_move_test_step = b.step("llvm-move-test", "Build, link, and run a linear `move` handle through the LLVM toolchain");
    llvm_move_test_step.dependOn(&llvm_move_test_cmd.step);

    const llvm_runtime_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/llvm-runtime-test.sh",
        "zig-out/bin/mcc",
    });
    llvm_runtime_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_runtime_test_step = b.step("llvm-runtime-test", "Build, link, and run imported generic, sync, and fn-pointer modules through the LLVM toolchain");
    llvm_runtime_test_step.dependOn(&llvm_runtime_test_cmd.step);

    const sync_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/sync-test.sh",
        "zig-out/bin/mcc",
    });
    sync_test_cmd.step.dependOn(b.getInstallStep());
    const sync_test_step = b.step("sync-test", "Build, link, and run a std/sync guarded critical section");
    sync_test_step.dependOn(&sync_test_cmd.step);

    const nic_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net/nic-test.sh",
        "zig-out/bin/mcc",
    });
    nic_test_cmd.step.dependOn(b.getInstallStep());
    const nic_test_step = b.step("nic-test", "Build and run the demo NIC driver (driver-library profile) under QEMU");
    nic_test_step.dependOn(&nic_test_cmd.step);

    const virtio_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net/virtio-test.sh",
        "zig-out/bin/mcc",
    });
    virtio_test_cmd.step.dependOn(b.getInstallStep());
    const virtio_test_step = b.step("virtio-test", "Build and run the real virtio-net driver against virtio-net-device under QEMU");
    virtio_test_step.dependOn(&virtio_test_cmd.step);

    const blk_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/fs/blk-test.sh",
        "zig-out/bin/mcc",
    });
    blk_test_cmd.step.dependOn(b.getInstallStep());
    const blk_test_step = b.step("blk-test", "Build and run the virtio-blk driver reading a sector under QEMU");
    blk_test_step.dependOn(&blk_test_cmd.step);

    const udp_net_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net/udp-net-test.sh",
        "zig-out/bin/mcc",
    });
    udp_net_test_cmd.step.dependOn(b.getInstallStep());
    const udp_net_test_step = b.step("udp-net-test", "Transmit a real UDP datagram over virtio-net under QEMU (pcap-verified)");
    udp_net_test_step.dependOn(&udp_net_test_cmd.step);

    const smp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    smp_test_cmd.step.dependOn(b.getInstallStep());
    const smp_test_step = b.step("smp-test", "Boot multiple harts and synchronize on a shared atomic under QEMU");
    smp_test_step.dependOn(&smp_test_cmd.step);

    const llvm_smp_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_smp_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smp_test_step = b.step("llvm-smp-test", "Run LLVM-lowered SMP boot/sync under QEMU");
    llvm_smp_test_step.dependOn(&llvm_smp_test_cmd.step);

    const smp_lock_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-lock-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    smp_lock_test_cmd.step.dependOn(b.getInstallStep());
    const smp_lock_test_step = b.step("smp-lock-test", "Contend a ticket spinlock across harts under QEMU (mutual exclusion)");
    smp_lock_test_step.dependOn(&smp_lock_test_cmd.step);

    const llvm_smp_lock_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/smp-lock-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_smp_lock_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_smp_lock_test_step = b.step("llvm-smp-lock-test", "Run LLVM-lowered SMP ticket-lock contention under QEMU");
    llvm_smp_lock_test_step.dependOn(&llvm_smp_lock_test_cmd.step);

    const ipi_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/ipi-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipi_test_cmd.step.dependOn(b.getInstallStep());
    const ipi_test_step = b.step("ipi-test", "Send a CLINT software interrupt (IPI) between harts under QEMU");
    ipi_test_step.dependOn(&ipi_test_cmd.step);

    const llvm_ipi_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/ipi-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipi_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipi_test_step = b.step("llvm-ipi-test", "Run LLVM-lowered inter-processor interrupt under QEMU");
    llvm_ipi_test_step.dependOn(&llvm_ipi_test_cmd.step);

    const demo_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/demo-test.sh",
        "zig-out/bin/mcc",
    });
    demo_test_cmd.step.dependOn(b.getInstallStep());
    const demo_test_step = b.step("demo-test", "Lower every demo/ driver to C and compile-check it");
    demo_test_step.dependOn(&demo_test_cmd.step);

    const net_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net/net-test.sh",
        "zig-out/bin/mcc",
    });
    net_test_cmd.step.dependOn(b.getInstallStep());
    const net_test_step = b.step("net-test", "Run the kernel virtio-net RX/TX ARP exchange under QEMU");
    net_test_step.dependOn(&net_test_cmd.step);

    const kernel_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/kernel-test.sh",
        "zig-out/bin/mcc",
    });
    kernel_test_cmd.step.dependOn(b.getInstallStep());
    const kernel_test_step = b.step("kernel-test", "Compile-check kernel/ for riscv64 and verify typestate rejects");
    kernel_test_step.dependOn(&kernel_test_cmd.step);

    const page_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/page-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    page_test_cmd.step.dependOn(b.getInstallStep());
    const page_test_step = b.step("page-test", "Link + run the physical frame allocator (bump + free-list reclaim)");
    page_test_step.dependOn(&page_test_cmd.step);

    const llvm_page_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/page-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_page_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_page_test_step = b.step("llvm-page-test", "Link + run the LLVM-lowered physical frame allocator");
    llvm_page_test_step.dependOn(&llvm_page_test_cmd.step);

    const heap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/heap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    heap_test_cmd.step.dependOn(b.getInstallStep());
    const heap_test_step = b.step("heap-test", "Link + run the kernel heap (aligned bump over a PhysRange)");
    heap_test_step.dependOn(&heap_test_cmd.step);

    const llvm_heap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/heap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_heap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_heap_test_step = b.step("llvm-heap-test", "Link + run the LLVM-lowered kernel heap");
    llvm_heap_test_step.dependOn(&llvm_heap_test_cmd.step);

    const elf_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "elf-test",
    });
    elf_test_cmd.step.dependOn(b.getInstallStep());
    const elf_test_step = b.step("elf-test", "Link + run the ELF64 parser (header + program headers, bounds-checked)");
    elf_test_step.dependOn(&elf_test_cmd.step);

    const ramfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ramfs-test",
    });
    ramfs_test_cmd.step.dependOn(b.getInstallStep());
    const ramfs_test_step = b.step("ramfs-test", "Link + run the in-memory filesystem (create/write/read/lookup)");
    ramfs_test_step.dependOn(&ramfs_test_cmd.step);

    const vfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfs-test",
    });
    vfs_test_cmd.step.dependOn(b.getInstallStep());
    const vfs_test_step = b.step("vfs-test", "Link + run the fd-table VFS over ramfs (open/read/write/close)");
    vfs_test_step.dependOn(&vfs_test_cmd.step);

    const blockfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "blockfs-test",
    });
    blockfs_test_cmd.step.dependOn(b.getInstallStep());
    const blockfs_test_step = b.step("blockfs-test", "Link + run the block-backed file store (block device vtable)");
    blockfs_test_step.dependOn(&blockfs_test_cmd.step);

    const udp_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "udp-test",
    });
    udp_test_cmd.step.dependOn(b.getInstallStep());
    const udp_test_step = b.step("udp-test", "Link + run the UDP datagram build/parse + checksum");
    udp_test_step.dependOn(&udp_test_cmd.step);

    const arena_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arena-test",
    });
    arena_test_cmd.step.dependOn(b.getInstallStep());
    const arena_test_step = b.step("arena-test", "move Arena: bump alloc, reset/reuse, destroy");
    arena_test_step.dependOn(&arena_test_cmd.step);

    const genref_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "genref-test",
    });
    genref_test_cmd.step.dependOn(b.getInstallStep());
    const genref_test_step = b.step("genref-test", "generational handle: live resolve, stale-after-reset trap");
    genref_test_step.dependOn(&genref_test_cmd.step);

    const owned_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "owned-test",
    });
    owned_test_cmd.step.dependOn(b.getInstallStep());
    const owned_test_step = b.step("owned-test", "create<T> typed linear allocation, leak-checked");
    owned_test_step.dependOn(&owned_test_cmd.step);

    const net_arena_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-arena-test",
    });
    net_arena_test_cmd.step.dependOn(b.getInstallStep());
    const net_arena_test_step = b.step("net-arena-test", "RX scratch from a move Arena + generational handle");
    net_arena_test_step.dependOn(&net_arena_test_cmd.step);

    const pool_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pool-test",
    });
    pool_test_cmd.step.dependOn(b.getInstallStep());
    const pool_test_step = b.step("pool-test", "generational pool: use-after-free/double-free caught");
    pool_test_step.dependOn(&pool_test_cmd.step);

    const block_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/block-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    block_server_test_cmd.step.dependOn(b.getInstallStep());
    const block_server_test_step = b.step("block-server-test", "storage driver as a user-mode server (block read/write via IPC)");
    block_server_test_step.dependOn(&block_server_test_cmd.step);

    const llvm_block_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/block-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_block_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_block_server_test_step = b.step("llvm-block-server-test", "Run LLVM-lowered block server under QEMU");
    llvm_block_server_test_step.dependOn(&llvm_block_server_test_cmd.step);

    const fs_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fs_server_test_cmd.step.dependOn(b.getInstallStep());
    const fs_server_test_step = b.step("fs-server-test", "filesystem as a user-mode server (open/write/read via IPC)");
    fs_server_test_step.dependOn(&fs_server_test_cmd.step);

    const llvm_fs_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fs_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fs_server_test_step = b.step("llvm-fs-server-test", "Run LLVM-lowered filesystem server under QEMU");
    llvm_fs_server_test_step.dependOn(&llvm_fs_server_test_cmd.step);

    const net_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-server-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    net_server_test_cmd.step.dependOn(b.getInstallStep());
    const net_server_test_step = b.step("net-server-test", "UDP socket layer as a user-mode server (bind/recv via IPC)");
    net_server_test_step.dependOn(&net_server_test_cmd.step);

    const llvm_net_server_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/net-server-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_net_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_net_server_test_step = b.step("llvm-net-server-test", "Run LLVM-lowered network server under QEMU");
    llvm_net_server_test_step.dependOn(&llvm_net_server_test_cmd.step);

    const constgen_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "constgen-test",
    });
    constgen_test_cmd.step.dependOn(b.getInstallStep());
    const constgen_test_step = b.step("constgen-test", "Const-generic Ring<T,N> at two capacities");
    constgen_test_step.dependOn(&constgen_test_cmd.step);

    const pipe_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pipe-test",
    });
    pipe_test_cmd.step.dependOn(b.getInstallStep());
    const pipe_test_step = b.step("pipe-test", "Pipe FIFO");
    pipe_test_step.dependOn(&pipe_test_cmd.step);

    const bcache_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "bcache-test",
    });
    const perm_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "perm-test",
    });
    perm_test_cmd.step.dependOn(b.getInstallStep());
    const perm_test_step = b.step("perm-test", "POSIX permission checks");
    perm_test_step.dependOn(&perm_test_cmd.step);

    const pgroup_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "pgroup-test",
    });
    const tty_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tty-test",
    });
    tty_test_cmd.step.dependOn(b.getInstallStep());
    const tty_test_step = b.step("tty-test", "TTY line discipline");
    tty_test_step.dependOn(&tty_test_cmd.step);

    const args_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "args-test",
    });
    const libc_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "libc-test",
    });
    libc_test_cmd.step.dependOn(b.getInstallStep());
    const libc_test_step = b.step("libc-test", "Minimal libc core");
    libc_test_step.dependOn(&libc_test_cmd.step);

    // hosted-test runs the hosted-profile float round-trip end to end: MC ->
    // C (--profile=hosted) -> clang -lm -> execute, feeding a binary f32 buffer
    // on stdin and verifying the f32 results on stdout. Self-skips without
    // clang/python3.
    const hosted_test_cmd = b.addSystemCommand(&.{
        "sh", "demo/hosted/run.sh", "zig-out/bin/mcc",
    });
    hosted_test_cmd.step.dependOn(b.getInstallStep());
    const hosted_test_step = b.step("hosted-test", "Hosted-profile elementwise float kernel: stdin/stdout f32 round-trip via libc/libm");
    hosted_test_step.dependOn(&hosted_test_cmd.step);

    const shell_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell-test",
    });
    const shell2_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "shell2-test",
    });
    const ushell_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lang/ushell-test.sh", "zig-out/bin/mcc",
    });
    ushell_test_cmd.step.dependOn(b.getInstallStep());
    const ushell_test_step = b.step("ushell-test", "Shell running in user mode via syscalls");
    ushell_test_step.dependOn(&ushell_test_cmd.step);


    shell2_test_cmd.step.dependOn(b.getInstallStep());
    const shell2_test_step = b.step("shell2-test", "Shell: tokenize + builtins with output");
    shell2_test_step.dependOn(&shell2_test_cmd.step);


    const vfsmount_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "vfsmount-test",
    });
    vfsmount_test_cmd.step.dependOn(b.getInstallStep());
    const vfsmount_test_step = b.step("vfsmount-test", "VFS mount switch");
    vfsmount_test_step.dependOn(&vfsmount_test_cmd.step);

    const fdspace_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdspace-test",
    });
    const slotmap_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "slotmap-test",
    });
    const mask_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mask-test",
    });
    const mailbox_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "mailbox-test",
    });
    const tryelse_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tryelse-test",
    });
    const byteview_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "byteview-test",
    });
    const scan_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scan-test",
    });
    scan_test_cmd.step.dependOn(b.getInstallStep());
    const scan_test_step = b.step("scan-test", "find_index/any closure scan");
    scan_test_step.dependOn(&scan_test_cmd.step);


    byteview_test_cmd.step.dependOn(b.getInstallStep());
    const byteview_test_step = b.step("byteview-test", "ByteBuf<N> inline buffer view");
    byteview_test_step.dependOn(&byteview_test_cmd.step);


    tryelse_test_cmd.step.dependOn(b.getInstallStep());
    const tryelse_test_step = b.step("tryelse-test", "EXPR? else MAPPED error remap");
    tryelse_test_step.dependOn(&tryelse_test_cmd.step);


    mailbox_test_cmd.step.dependOn(b.getInstallStep());
    const mailbox_test_step = b.step("mailbox-test", "Mailbox<T,N> bounded queue + source filter");
    mailbox_test_step.dependOn(&mailbox_test_cmd.step);


    mask_test_cmd.step.dependOn(b.getInstallStep());
    const mask_test_step = b.step("mask-test", "Mask32 bit set");
    mask_test_step.dependOn(&mask_test_cmd.step);


    slotmap_test_cmd.step.dependOn(b.getInstallStep());
    const slotmap_test_step = b.step("slotmap-test", "SlotMap<T,N> index handle table");
    slotmap_test_step.dependOn(&slotmap_test_cmd.step);


    const posix_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "posix-test",
    });
    const userland_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "userland-test",
    });
    const smprq_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "smprq-test",
    });
    const rtc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_rtc_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/arch/rtc-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const contain_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_contain_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/mem/contain-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const tcp_server_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "c",
    });
    const llvm_tcp_server_test_cmd = b.addSystemCommand(&.{
        "bash", "tools/net/tcp-server-test.sh", "zig-out/bin/mcc", "llvm",
    });
    const fdt_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fdt-test",
    });
    fdt_test_cmd.step.dependOn(b.getInstallStep());
    const fdt_test_step = b.step("fdt-test", "Device-tree (FDT) header parsing");
    fdt_test_step.dependOn(&fdt_test_cmd.step);

    const fb_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "fb-test",
    });
    const dynlink_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "dynlink-test",
    });
    const aarch64_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/arch/aarch64-test.sh", "zig-out/bin/mcc",
    });
    const liveupdate_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "liveupdate-test",
    });
    const sbi_boot_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/arch/sbi-boot-test.sh", "zig-out/bin/mcc",
    });
    const e1000_test_cmd = b.addSystemCommand(&.{
        "sh", "tools/net/e1000-test.sh", "zig-out/bin/mcc",
    });
    e1000_test_cmd.step.dependOn(b.getInstallStep());
    const e1000_test_step = b.step("e1000-test", "Real e1000 NIC PCI probe");
    e1000_test_step.dependOn(&e1000_test_cmd.step);


    sbi_boot_test_cmd.step.dependOn(b.getInstallStep());
    const sbi_boot_test_step = b.step("sbi-boot-test", "Boot under OpenSBI (real firmware)");
    sbi_boot_test_step.dependOn(&sbi_boot_test_cmd.step);


    liveupdate_test_cmd.step.dependOn(b.getInstallStep());
    const liveupdate_test_step = b.step("liveupdate-test", "Live update (state handoff)");
    liveupdate_test_step.dependOn(&liveupdate_test_cmd.step);


    aarch64_test_cmd.step.dependOn(b.getInstallStep());
    const aarch64_test_step = b.step("aarch64-test", "Second architecture (aarch64) bring-up");
    aarch64_test_step.dependOn(&aarch64_test_cmd.step);


    dynlink_test_cmd.step.dependOn(b.getInstallStep());
    const dynlink_test_step = b.step("dynlink-test", "Dynamic-linking relocation core");
    dynlink_test_step.dependOn(&dynlink_test_cmd.step);


    fb_test_cmd.step.dependOn(b.getInstallStep());
    const fb_test_step = b.step("fb-test", "Linear framebuffer device");
    fb_test_step.dependOn(&fb_test_cmd.step);


    tcp_server_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_server_test_step = b.step("tcp-server-test", "TCP connection state machine as a server");
    tcp_server_test_step.dependOn(&tcp_server_test_cmd.step);
    llvm_tcp_server_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_tcp_server_test_step = b.step("llvm-tcp-server-test", "LLVM-lowered TCP connection state machine as a server");
    llvm_tcp_server_test_step.dependOn(&llvm_tcp_server_test_cmd.step);


    contain_test_cmd.step.dependOn(b.getInstallStep());
    const contain_test_step = b.step("contain-test", "MMU crash containment");
    contain_test_step.dependOn(&contain_test_cmd.step);
    llvm_contain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_contain_test_step = b.step("llvm-contain-test", "Run LLVM-lowered MMU crash containment under QEMU");
    llvm_contain_test_step.dependOn(&llvm_contain_test_cmd.step);


    rtc_test_cmd.step.dependOn(b.getInstallStep());
    const rtc_test_step = b.step("rtc-test", "Wall-clock via goldfish-RTC");
    rtc_test_step.dependOn(&rtc_test_cmd.step);
    llvm_rtc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_rtc_test_step = b.step("llvm-rtc-test", "Run LLVM-lowered goldfish-RTC MMIO under QEMU");
    llvm_rtc_test_step.dependOn(&llvm_rtc_test_cmd.step);


    smprq_test_cmd.step.dependOn(b.getInstallStep());
    const smprq_test_step = b.step("smprq-test", "SMP per-core run queues + work stealing");
    smprq_test_step.dependOn(&smprq_test_cmd.step);


    userland_test_cmd.step.dependOn(b.getInstallStep());
    const userland_test_step = b.step("userland-test", "Userland echo utility");
    userland_test_step.dependOn(&userland_test_cmd.step);


    posix_test_cmd.step.dependOn(b.getInstallStep());
    const posix_test_step = b.step("posix-test", "POSIX syscall surface");
    posix_test_step.dependOn(&posix_test_cmd.step);


    fdspace_test_cmd.step.dependOn(b.getInstallStep());
    const fdspace_test_step = b.step("fdspace-test", "FdSpace (kernel/lib): fd alloc/select, sentinel-free");
    fdspace_test_step.dependOn(&fdspace_test_cmd.step);
    const snapshot_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "snapshot-test" });
    snapshot_test_cmd.step.dependOn(b.getInstallStep());
    const snapshot_test_step = b.step("snapshot-test", "proc_snapshot (kernel/lib): stable process enumeration");
    snapshot_test_step.dependOn(&snapshot_test_cmd.step);

    const waitqueue_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "waitqueue-test" });
    waitqueue_test_cmd.step.dependOn(b.getInstallStep());
    const waitqueue_test_step = b.step("waitqueue-test", "WaitQueue (kernel/lib): block/wake/idle policy");
    waitqueue_test_step.dependOn(&waitqueue_test_cmd.step);

    const service_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "service-test" });
    service_test_cmd.step.dependOn(b.getInstallStep());
    const service_test_step = b.step("service-test", "service (kernel/lib): request/reply server loop");
    service_test_step.dependOn(&service_test_cmd.step);

    const plugin_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "plugin-test" });
    plugin_test_cmd.step.dependOn(b.getInstallStep());
    const plugin_test_step = b.step("plugin-test", "pluggable boot flow: device/bus probe-attach + registry + discovery");
    plugin_test_step.dependOn(&plugin_test_cmd.step);

    const endpoint_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "endpoint-test" });
    endpoint_test_cmd.step.dependOn(b.getInstallStep());
    const endpoint_test_step = b.step("endpoint-test", "MINIX hardening: endpoints/generations, derived runnable, death cleanup");
    endpoint_test_step.dependOn(&endpoint_test_cmd.step);

    const supervisor_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "supervisor-test" });
    supervisor_test_cmd.step.dependOn(b.getInstallStep());
    const supervisor_test_step = b.step("supervisor-test", "service supervisor: declarative manifests + restart policy");
    supervisor_test_step.dependOn(&supervisor_test_cmd.step);

    const registry2_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "registry2-test" });
    registry2_test_cmd.step.dependOn(b.getInstallStep());
    const registry2_test_step = b.step("registry2-test", "Registry v2: multiple-per-class, generations, unregister-on-death");
    registry2_test_step.dependOn(&registry2_test_cmd.step);

    const manifest_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "manifest-test" });
    manifest_test_cmd.step.dependOn(b.getInstallStep());
    const manifest_test_step = b.step("manifest-test", "enforced service manifests: privileges applied + enforced");
    manifest_test_step.dependOn(&manifest_test_cmd.step);

    const scheduler_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "scheduler-test" });
    scheduler_test_cmd.step.dependOn(b.getInstallStep());
    const scheduler_test_step = b.step("scheduler-test", "scheduler service: quantum expiry notify + refresh");
    scheduler_test_step.dependOn(&scheduler_test_cmd.step);

    const info_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "info-test" });
    info_test_cmd.step.dependOn(b.getInstallStep());
    const info_test_step = b.step("info-test", "info/snapshot service: top queries over IPC");
    info_test_step.dependOn(&info_test_cmd.step);

    const granttab_test_cmd = b.addSystemCommand(&.{ "sh", "tools/lib/host-harness.sh", "zig-out/bin/mcc", "granttab-test" });
    granttab_test_cmd.step.dependOn(b.getInstallStep());
    const granttab_test_step = b.step("granttab-test", "owner-tracked grants: bounded IPC sharing + revoke-on-death");
    granttab_test_step.dependOn(&granttab_test_cmd.step);

    const x86_sched_test_cmd = b.addSystemCommand(&.{ "sh", "tools/arch/x86-sched-test.sh", "zig-out/bin/mcc" });
    x86_sched_test_cmd.step.dependOn(b.getInstallStep());
    const x86_sched_test_step = b.step("x86-sched-test", "x86-64 arch port: cooperative context switch (native)");
    x86_sched_test_step.dependOn(&x86_sched_test_cmd.step);

    const x86_qemu_test_cmd = b.addSystemCommand(&.{ "sh", "tools/arch/x86-qemu-test.sh", "zig-out/bin/mcc" });
    x86_qemu_test_cmd.step.dependOn(b.getInstallStep());
    const x86_qemu_test_step = b.step("x86-qemu-test", "x86-64 kernel boots under QEMU (multiboot -> long mode)");
    x86_qemu_test_step.dependOn(&x86_qemu_test_cmd.step);


    shell_test_cmd.step.dependOn(b.getInstallStep());
    const shell_test_step = b.step("shell-test", "Minimal shell");
    shell_test_step.dependOn(&shell_test_cmd.step);


    args_test_cmd.step.dependOn(b.getInstallStep());
    const args_test_step = b.step("args-test", "argv/envp vector");
    args_test_step.dependOn(&args_test_cmd.step);


    pgroup_test_cmd.step.dependOn(b.getInstallStep());
    const pgroup_test_step = b.step("pgroup-test", "Process groups + sessions");
    pgroup_test_step.dependOn(&pgroup_test_cmd.step);


    bcache_test_cmd.step.dependOn(b.getInstallStep());
    const bcache_test_step = b.step("bcache-test", "Write-back block cache");
    bcache_test_step.dependOn(&bcache_test_cmd.step);

    const cow_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/cow-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    cow_test_cmd.step.dependOn(b.getInstallStep());
    const cow_test_step = b.step("cow-test", "Copy-on-write: shared RO page diverges on write");
    cow_test_step.dependOn(&cow_test_cmd.step);

    const llvm_cow_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/cow-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_cow_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cow_test_step = b.step("llvm-cow-test", "Run LLVM-lowered copy-on-write fault handling under QEMU");
    llvm_cow_test_step.dependOn(&llvm_cow_test_cmd.step);

    const usched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/usched-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    usched_test_cmd.step.dependOn(b.getInstallStep());
    const usched_test_step = b.step("usched-test", "Userspace-set scheduling policy (priority)");
    usched_test_step.dependOn(&usched_test_cmd.step);

    const llvm_usched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/usched-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_usched_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_usched_test_step = b.step("llvm-usched-test", "Run LLVM-lowered userspace-set scheduling policy under QEMU");
    llvm_usched_test_step.dependOn(&llvm_usched_test_cmd.step);

    const userserver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/userserver-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    userserver_test_cmd.step.dependOn(b.getInstallStep());
    const userserver_test_step = b.step("userserver-test", "A server running in user mode via syscalls");
    userserver_test_step.dependOn(&userserver_test_cmd.step);

    const llvm_userserver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/userserver-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_userserver_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_userserver_test_step = b.step("llvm-userserver-test", "Run LLVM-lowered user-mode server under QEMU");
    llvm_userserver_test_step.dependOn(&llvm_userserver_test_cmd.step);

    const isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/isolation-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    isolation_test_cmd.step.dependOn(b.getInstallStep());
    const isolation_test_step = b.step("isolation-test", "Per-server MMU isolation + cross-AS IPC");
    isolation_test_step.dependOn(&isolation_test_cmd.step);

    const llvm_isolation_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/isolation-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_isolation_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_isolation_test_step = b.step("llvm-isolation-test", "Run LLVM-lowered per-server MMU isolation under QEMU");
    llvm_isolation_test_step.dependOn(&llvm_isolation_test_cmd.step);

    const demand_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/demand-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    demand_test_cmd.step.dependOn(b.getInstallStep());
    const demand_test_step = b.step("demand-test", "Demand paging: fault -> map -> retry");
    demand_test_step.dependOn(&demand_test_cmd.step);

    const llvm_demand_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/demand-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_demand_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_demand_test_step = b.step("llvm-demand-test", "Run LLVM-lowered demand paging under QEMU");
    llvm_demand_test_step.dependOn(&llvm_demand_test_cmd.step);

    const mmap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/mmap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    mmap_test_cmd.step.dependOn(b.getInstallStep());
    const mmap_test_step = b.step("mmap-test", "mmap anonymous pages into a page table (active satp)");
    mmap_test_step.dependOn(&mmap_test_cmd.step);

    const llvm_mmap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/mmap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_mmap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_mmap_test_step = b.step("llvm-mmap-test", "Run LLVM-lowered anonymous mmap under QEMU");
    llvm_mmap_test_step.dependOn(&llvm_mmap_test_cmd.step);

    const diskfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "diskfs-test",
    });
    diskfs_test_cmd.step.dependOn(b.getInstallStep());
    const diskfs_test_step = b.step("diskfs-test", "On-disk FS: persistent format + inodes + named lookup");
    diskfs_test_step.dependOn(&diskfs_test_cmd.step);

    const heartbeat_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/heartbeat-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    heartbeat_test_cmd.step.dependOn(b.getInstallStep());
    const heartbeat_test_step = b.step("heartbeat-test", "Reincarnation with heartbeat liveness detection");
    heartbeat_test_step.dependOn(&heartbeat_test_cmd.step);

    const llvm_heartbeat_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/heartbeat-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_heartbeat_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_heartbeat_test_step = b.step("llvm-heartbeat-test", "Run LLVM-lowered heartbeat restart detection under QEMU");
    llvm_heartbeat_test_step.dependOn(&llvm_heartbeat_test_cmd.step);

    const timeout_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/timeout-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    timeout_test_cmd.step.dependOn(b.getInstallStep());
    const timeout_test_step = b.step("timeout-test", "IPC timeout: bounded receive, no infinite block");
    timeout_test_step.dependOn(&timeout_test_cmd.step);

    const llvm_timeout_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/timeout-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_timeout_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_timeout_test_step = b.step("llvm-timeout-test", "Run LLVM-lowered IPC timeout under QEMU");
    llvm_timeout_test_step.dependOn(&llvm_timeout_test_cmd.step);

    const privilege_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/privilege-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    privilege_test_cmd.step.dependOn(b.getInstallStep());
    const privilege_test_step = b.step("privilege-test", "Least privilege: IPC allow-list + kernel-call gate");
    privilege_test_step.dependOn(&privilege_test_cmd.step);

    const llvm_privilege_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/privilege-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_privilege_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_privilege_test_step = b.step("llvm-privilege-test", "Run LLVM-lowered least-privilege IPC and kcall gates under QEMU");
    llvm_privilege_test_step.dependOn(&llvm_privilege_test_cmd.step);

    const signal_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/signal-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    signal_test_cmd.step.dependOn(b.getInstallStep());
    const signal_test_step = b.step("signal-test", "Signals: deliver + poll + take an async signal");
    signal_test_step.dependOn(&signal_test_cmd.step);

    const llvm_signal_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/signal-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_signal_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_signal_test_step = b.step("llvm-signal-test", "Run LLVM-lowered signal delivery under QEMU");
    llvm_signal_test_step.dependOn(&llvm_signal_test_cmd.step);

    const registry_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/registry-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    registry_test_cmd.step.dependOn(b.getInstallStep());
    const registry_test_step = b.step("registry-test", "Name/registry server: lookup a service by name");
    registry_test_step.dependOn(&registry_test_cmd.step);

    const llvm_registry_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/registry-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_registry_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_registry_test_step = b.step("llvm-registry-test", "Run LLVM-lowered name/registry server under QEMU");
    llvm_registry_test_step.dependOn(&llvm_registry_test_cmd.step);

    const ipc2_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc2-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipc2_test_cmd.step.dependOn(b.getInstallStep());
    const ipc2_test_step = b.step("ipc2-test", "IPC completeness: multi-slot + source filter + notify");
    ipc2_test_step.dependOn(&ipc2_test_cmd.step);

    const llvm_ipc2_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc2-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipc2_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipc2_test_step = b.step("llvm-ipc2-test", "Run LLVM-lowered IPC multi-slot/source-filter/notify under QEMU");
    llvm_ipc2_test_step.dependOn(&llvm_ipc2_test_cmd.step);

    const grant_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "grant-test",
    });
    grant_test_cmd.step.dependOn(b.getInstallStep());
    const grant_test_step = b.step("grant-test", "Memory grant: bounded delegation + revocation");
    grant_test_step.dependOn(&grant_test_cmd.step);

    const ipc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    ipc_test_cmd.step.dependOn(b.getInstallStep());
    const ipc_test_step = b.step("ipc-test", "kernel-mediated IPC: client/server message round-trip");
    ipc_test_step.dependOn(&ipc_test_cmd.step);

    const llvm_ipc_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/ipc/ipc-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_ipc_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_ipc_test_step = b.step("llvm-ipc-test", "Run LLVM-lowered kernel-mediated IPC under QEMU");
    llvm_ipc_test_step.dependOn(&llvm_ipc_test_cmd.step);

    const cap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/cap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    cap_test_cmd.step.dependOn(b.getInstallStep());
    const cap_test_step = b.step("cap-test", "capability least-privilege: driver-as-server holds the console cap");
    cap_test_step.dependOn(&cap_test_cmd.step);

    const llvm_cap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/cap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_cap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_cap_test_step = b.step("llvm-cap-test", "Run LLVM-lowered capability least-privilege server under QEMU");
    llvm_cap_test_step.dependOn(&llvm_cap_test_cmd.step);

    const restart_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/restart-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    restart_test_cmd.step.dependOn(b.getInstallStep());
    const restart_test_step = b.step("restart-test", "reincarnation: supervisor restarts a crashed server");
    restart_test_step.dependOn(&restart_test_cmd.step);

    const llvm_restart_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/restart-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_restart_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_restart_test_step = b.step("llvm-restart-test", "Run LLVM-lowered reincarnation restart under QEMU");
    llvm_restart_test_step.dependOn(&llvm_restart_test_cmd.step);

    const arc_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-test",
    });
    arc_test_cmd.step.dependOn(b.getInstallStep());
    const arc_test_step = b.step("arc-test", "Arc<T> shared ownership: clone/last-drop-frees, handles leak-checked");
    arc_test_step.dependOn(&arc_test_cmd.step);

    const arc_pkt_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "arc-pkt-test",
    });
    arc_pkt_test_cmd.step.dependOn(b.getInstallStep());
    const arc_pkt_test_step = b.step("arc-pkt-test", "packet Arc-shared between two consumers (skb/mbuf pattern)");
    arc_pkt_test_step.dependOn(&arc_pkt_test_cmd.step);

    const alloc_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "alloc-test",
    });
    alloc_test_cmd.step.dependOn(b.getInstallStep());
    const alloc_test_step = b.step("alloc-test", "Link + run the type-erased std/alloc Allocator over a captured heap");
    alloc_test_step.dependOn(&alloc_test_cmd.step);

    const closure_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "closure-test",
    });
    closure_test_cmd.step.dependOn(b.getInstallStep());
    const closure_test_step = b.step("closure-test", "Link + run a bind() closure (capture + call across calls)");
    closure_test_step.dependOn(&closure_test_cmd.step);

    const ring_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "ring-test",
    });
    ring_test_cmd.step.dependOn(b.getInstallStep());
    const ring_test_step = b.step("ring-test", "Link + run the generic in-place Ring<T> (push/pop/wrap)");
    ring_test_step.dependOn(&ring_test_cmd.step);

    const trace_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "trace-test",
    });
    trace_test_cmd.step.dependOn(b.getInstallStep());
    const trace_test_step = b.step("trace-test", "Link + run the trace ring buffer (retention/wrap/sequence)");
    trace_test_step.dependOn(&trace_test_cmd.step);

    const log_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "log-test",
    });
    log_test_cmd.step.dependOn(b.getInstallStep());
    const log_test_step = b.step("log-test", "Link + run the leveled tracepoint logger (threshold/levels)");
    log_test_step.dependOn(&log_test_cmd.step);

    const tcp_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-test",
    });
    tcp_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_test_step = b.step("tcp-test", "Link + run the TCP segment build/parse + checksum");
    tcp_test_step.dependOn(&tcp_test_cmd.step);

    const tcp_conn_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-conn-test",
    });
    tcp_conn_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_conn_test_step = b.step("tcp-conn-test", "Link + run the TCP connection state machine (handshake/close)");
    tcp_conn_test_step.dependOn(&tcp_conn_test_cmd.step);

    const tcp_window_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-window-test",
    });
    tcp_window_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_window_test_step = b.step("tcp-window-test", "Link + run the TCP send/recv window + ACK processing (data plane)");
    tcp_window_test_step.dependOn(&tcp_window_test_cmd.step);

    const tcp_reasm_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-reasm-test",
    });
    tcp_reasm_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_reasm_test_step = b.step("tcp-reasm-test", "Link + run TCP reassembly + go-back-N retransmit");
    tcp_reasm_test_step.dependOn(&tcp_reasm_test_cmd.step);

    const tcp_rtx_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "tcp-rtx-test",
    });
    tcp_rtx_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_rtx_test_step = b.step("tcp-rtx-test", "Link + run the TCP retransmit timer (RTO -> go-back-N)");
    tcp_rtx_test_step.dependOn(&tcp_rtx_test_cmd.step);

    const symbols_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "symbols-test",
    });
    symbols_test_cmd.step.dependOn(b.getInstallStep());
    const symbols_test_step = b.step("symbols-test", "Link + run the symbol table (symbolize address -> function+offset)");
    symbols_test_step.dependOn(&symbols_test_cmd.step);

    const socket_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "socket-test",
    });
    socket_test_cmd.step.dependOn(b.getInstallStep());
    const socket_test_step = b.step("socket-test", "Link + run the UDP socket layer (bind/deliver/recv demux)");
    socket_test_step.dependOn(&socket_test_cmd.step);

    const net_rx_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-rx-test",
    });
    net_rx_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_test_step = b.step("net-rx-test", "Link + run the RX demux path (frame -> socket_deliver -> recv)");
    net_rx_test_step.dependOn(&net_rx_test_cmd.step);

    const net_fuzz_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/lib/host-harness.sh", "zig-out/bin/mcc", "net-fuzz-test",
    });
    net_fuzz_test_cmd.step.dependOn(b.getInstallStep());
    const net_fuzz_test_step = b.step("net-fuzz-test", "Fuzz the RX parser with random frames (no OOB)");
    net_fuzz_test_step.dependOn(&net_fuzz_test_cmd.step);

    const net_rx_live_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net/net-rx-live-test.sh",
        "zig-out/bin/mcc",
    });
    net_rx_live_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_live_test_step = b.step("net-rx-live-test", "Route a real virtio-net RX frame through net_rx_deliver under QEMU");
    net_rx_live_test_step.dependOn(&net_rx_live_test_cmd.step);

    const backtrace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/backtrace-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    backtrace_test_cmd.step.dependOn(b.getInstallStep());
    const backtrace_test_step = b.step("backtrace-test", "Walk the frame-pointer chain and symbolize the frames under QEMU");
    backtrace_test_step.dependOn(&backtrace_test_cmd.step);

    const llvm_backtrace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/backtrace-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_backtrace_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_backtrace_test_step = b.step("llvm-backtrace-test", "Run LLVM-lowered backtrace symbolization under QEMU");
    llvm_backtrace_test_step.dependOn(&llvm_backtrace_test_cmd.step);

    const paging_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    paging_test_cmd.step.dependOn(b.getInstallStep());
    const paging_test_step = b.step("paging-test", "Link + run Sv39 page-table map/translate");
    paging_test_step.dependOn(&paging_test_cmd.step);

    const llvm_paging_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_paging_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_paging_test_step = b.step("llvm-paging-test", "Link + run the LLVM-lowered Sv39 page-table map/translate");
    llvm_paging_test_step.dependOn(&llvm_paging_test_cmd.step);

    const fnptr_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/toolchain/fnptr-test.sh",
        "zig-out/bin/mcc",
    });
    fnptr_test_cmd.step.dependOn(b.getInstallStep());
    const fnptr_test_step = b.step("fnptr-test", "Link + run function-pointer dispatch (callback, vtable, return)");
    fnptr_test_step.dependOn(&fnptr_test_cmd.step);

    const trap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/trap-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    trap_test_cmd.step.dependOn(b.getInstallStep());
    const trap_test_step = b.step("trap-test", "Run the typed-CPU trap/timer interrupt path under QEMU");
    trap_test_step.dependOn(&trap_test_cmd.step);

    const llvm_trap_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/trap-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_trap_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_trap_test_step = b.step("llvm-trap-test", "Run the LLVM-lowered typed-CPU trap/timer path under QEMU");
    llvm_trap_test_step.dependOn(&llvm_trap_test_cmd.step);

    const thread_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/thread-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    thread_test_cmd.step.dependOn(b.getInstallStep());
    const thread_test_step = b.step("thread-test", "Run cooperative context switching (main/worker ping-pong) under QEMU");
    thread_test_step.dependOn(&thread_test_cmd.step);

    const llvm_thread_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/thread-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_thread_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_thread_test_step = b.step("llvm-thread-test", "Run LLVM-lowered cooperative context switching under QEMU");
    llvm_thread_test_step.dependOn(&llvm_thread_test_cmd.step);

    const sched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    sched_test_cmd.step.dependOn(b.getInstallStep());
    const sched_test_step = b.step("sched-test", "Run the round-robin scheduler (3 heap-stacked threads) under QEMU");
    sched_test_step.dependOn(&sched_test_cmd.step);

    const llvm_sched_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_sched_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sched_test_step = b.step("llvm-sched-test", "Run the LLVM-lowered round-robin scheduler under QEMU");
    llvm_sched_test_step.dependOn(&llvm_sched_test_cmd.step);

    const preempt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/preempt-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    preempt_test_cmd.step.dependOn(b.getInstallStep());
    const preempt_test_step = b.step("preempt-test", "Run the timer-driven preemptive scheduler under QEMU");
    preempt_test_step.dependOn(&preempt_test_cmd.step);

    const llvm_preempt_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/preempt-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_preempt_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_preempt_test_step = b.step("llvm-preempt-test", "Run LLVM-lowered timer-driven preemption under QEMU");
    llvm_preempt_test_step.dependOn(&llvm_preempt_test_cmd.step);

    const syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    syscall_test_cmd.step.dependOn(b.getInstallStep());
    const syscall_test_step = b.step("syscall-test", "Run the ecall syscall dispatch skeleton under QEMU");
    syscall_test_step.dependOn(&syscall_test_cmd.step);

    const llvm_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_syscall_test_step = b.step("llvm-syscall-test", "Run the LLVM-lowered ecall syscall dispatch skeleton under QEMU");
    llvm_syscall_test_step.dependOn(&llvm_syscall_test_cmd.step);

    const user_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/user-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    user_test_cmd.step.dependOn(b.getInstallStep());
    const user_test_step = b.step("user-test", "Run the M->U privilege drop + user-mode syscalls under QEMU");
    user_test_step.dependOn(&user_test_cmd.step);

    const llvm_user_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/user-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_user_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_user_test_step = b.step("llvm-user-test", "Run the LLVM-lowered M->U privilege drop + user-mode syscalls under QEMU");
    llvm_user_test_step.dependOn(&llvm_user_test_cmd.step);

    const process_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/process-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    process_test_cmd.step.dependOn(b.getInstallStep());
    const process_test_step = b.step("process-test", "Run process lifecycle (spawn/run/exit) under QEMU");
    process_test_step.dependOn(&process_test_cmd.step);

    const llvm_process_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/process-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_process_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_process_test_step = b.step("llvm-process-test", "Run the LLVM-lowered process lifecycle under QEMU");
    llvm_process_test_step.dependOn(&llvm_process_test_cmd.step);

    const elf_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/elf-run-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    elf_run_test_cmd.step.dependOn(b.getInstallStep());
    const elf_run_test_step = b.step("elf-run-test", "Load an ELF64 and run it in U-mode under QEMU");
    elf_run_test_step.dependOn(&elf_run_test_cmd.step);

    const llvm_elf_run_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/elf-run-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_elf_run_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_elf_run_test_step = b.step("llvm-elf-run-test", "Load an ELF64 from an LLVM-lowered kernel image and run it in U-mode under QEMU");
    llvm_elf_run_test_step.dependOn(&llvm_elf_run_test_cmd.step);

    const driver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/driver-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    driver_test_cmd.step.dependOn(b.getInstallStep());
    const driver_test_step = b.step("driver-test", "Run the char-device driver framework (vtable dispatch) under QEMU");
    driver_test_step.dependOn(&driver_test_cmd.step);

    const llvm_driver_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/arch/driver-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_driver_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_driver_test_step = b.step("llvm-driver-test", "Run LLVM-lowered char-device driver framework under QEMU");
    llvm_driver_test_step.dependOn(&llvm_driver_test_cmd.step);

    const fs_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    fs_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const fs_syscall_test_step = b.step("fs-syscall-test", "Run U-mode file syscalls (open/write/read/close) over the VFS under QEMU");
    fs_syscall_test_step.dependOn(&fs_syscall_test_cmd.step);

    const llvm_fs_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/fs/fs-syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_fs_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_fs_syscall_test_step = b.step("llvm-fs-syscall-test", "Run LLVM-lowered U-mode file syscalls over the VFS under QEMU");
    llvm_fs_syscall_test_step.dependOn(&llvm_fs_syscall_test_cmd.step);

    const socket_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/socket-syscall-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    socket_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const socket_syscall_test_step = b.step("socket-syscall-test", "Run U-mode recvfrom over the UDP socket layer under QEMU");
    socket_syscall_test_step.dependOn(&socket_syscall_test_cmd.step);

    const llvm_socket_syscall_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/socket-syscall-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_socket_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_socket_syscall_test_step = b.step("llvm-socket-syscall-test", "Run LLVM-lowered U-mode recvfrom over the UDP socket layer under QEMU");
    llvm_socket_syscall_test_step.dependOn(&llvm_socket_syscall_test_cmd.step);

    const exec_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/exec-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    exec_test_cmd.step.dependOn(b.getInstallStep());
    const exec_test_step = b.step("exec-test", "Run sys_exec: a U-mode program loads + runs another ELF under QEMU");
    exec_test_step.dependOn(&exec_test_cmd.step);

    const llvm_exec_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/lang/exec-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_exec_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_exec_test_step = b.step("llvm-exec-test", "Run LLVM-lowered sys_exec under QEMU");
    llvm_exec_test_step.dependOn(&llvm_exec_test_cmd.step);

    const paging_activate_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-activate-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    paging_activate_test_cmd.step.dependOn(b.getInstallStep());
    const paging_activate_test_step = b.step("paging-activate-test", "Activate Sv39 satp in S-mode and read a translation-only VA under QEMU");
    paging_activate_test_step.dependOn(&paging_activate_test_cmd.step);

    const llvm_paging_activate_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/paging-activate-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_paging_activate_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_paging_activate_test_step = b.step("llvm-paging-activate-test", "Run LLVM-lowered Sv39 activation under QEMU");
    llvm_paging_activate_test_step.dependOn(&llvm_paging_activate_test_cmd.step);

    const kmain_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/kmain-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kmain_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_test_step = b.step("kmain-test", "Boot one integrated kernel image (heap+console+log+VFS+scheduler) under QEMU");
    kmain_test_step.dependOn(&kmain_test_cmd.step);

    const llvm_kmain_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/kmain-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_kmain_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kmain_test_step = b.step("llvm-kmain-test", "Boot one LLVM-lowered integrated kernel image under QEMU");
    llvm_kmain_test_step.dependOn(&llvm_kmain_test_cmd.step);

    const kmain_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/kmain-net-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    kmain_net_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_net_test_step = b.step("kmain-net-test", "Boot the integrated kernel + network in one image under QEMU");
    kmain_net_test_step.dependOn(&kmain_net_test_cmd.step);

    const llvm_kmain_net_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/net/kmain-net-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_kmain_net_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_kmain_net_test_step = b.step("llvm-kmain-net-test", "Boot the LLVM-lowered integrated kernel + network image under QEMU");
    llvm_kmain_net_test_step.dependOn(&llvm_kmain_net_test_cmd.step);

    const vm_switch_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vm-switch-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vm_switch_test_cmd.step.dependOn(b.getInstallStep());
    const vm_switch_test_step = b.step("vm-switch-test", "Switch satp between two address spaces under QEMU (per-process VM)");
    vm_switch_test_step.dependOn(&vm_switch_test_cmd.step);

    const llvm_vm_switch_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vm-switch-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vm_switch_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vm_switch_test_step = b.step("llvm-vm-switch-test", "Run LLVM-lowered satp switching between two address spaces under QEMU");
    llvm_vm_switch_test_step.dependOn(&llvm_vm_switch_test_cmd.step);

    const vmspace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmspace-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vmspace_test_cmd.step.dependOn(b.getInstallStep());
    const vmspace_test_step = b.step("vmspace-test", "Per-process page tables: switch satp by process slot under QEMU");
    vmspace_test_step.dependOn(&vmspace_test_cmd.step);

    const llvm_vmspace_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmspace-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vmspace_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vmspace_test_step = b.step("llvm-vmspace-test", "Run LLVM-lowered per-process page tables under QEMU");
    llvm_vmspace_test_step.dependOn(&llvm_vmspace_test_cmd.step);

    const vmctx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmctx-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    vmctx_test_cmd.step.dependOn(b.getInstallStep());
    const vmctx_test_step = b.step("vmctx-test", "Context switch that swaps satp per thread under QEMU");
    vmctx_test_step.dependOn(&vmctx_test_cmd.step);

    const llvm_vmctx_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/mem/vmctx-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_vmctx_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_vmctx_test_step = b.step("llvm-vmctx-test", "Run LLVM-lowered context switching with satp swaps under QEMU");
    llvm_vmctx_test_step.dependOn(&llvm_vmctx_test_cmd.step);

    const sched_vm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-vm-test.sh",
        "zig-out/bin/mcc",
        "c",
    });
    sched_vm_test_cmd.step.dependOn(b.getInstallStep());
    const sched_vm_test_step = b.step("sched-vm-test", "Scheduler switching per-process address spaces (proc_yield_vm) under QEMU");
    sched_vm_test_step.dependOn(&sched_vm_test_cmd.step);

    const llvm_sched_vm_test_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/proc/sched-vm-test.sh",
        "zig-out/bin/mcc",
        "llvm",
    });
    llvm_sched_vm_test_cmd.step.dependOn(b.getInstallStep());
    const llvm_sched_vm_test_step = b.step("llvm-sched-vm-test", "Run LLVM-lowered scheduler switching per-process address spaces under QEMU");
    llvm_sched_vm_test_step.dependOn(&llvm_sched_vm_test_cmd.step);

    const run_ushell_cmd = b.addSystemCommand(&.{ "sh", "tools/lang/run-ushell.sh" });
    run_ushell_cmd.step.dependOn(b.getInstallStep());
    run_ushell_cmd.stdio = .inherit; // connect the terminal so QEMU is interactive
    const run_ushell_step = b.step("run-ushell", "Build + boot the user-mode MC shell in QEMU (interactive)");
    run_ushell_step.dependOn(&run_ushell_cmd.step);

    const m0_step = b.step("m0", "Run M0 conformance gates");
    m0_step.dependOn(&test_cmd.step);
    m0_step.dependOn(&c_test_cmd.step);
    m0_step.dependOn(&sweep_cmd.step);
    // LLVM backend gates: IR assembly, object lowering, spec sweep, broad
    // c_emit fixture sweeps, and host link/run smoke tests.
    m0_step.dependOn(&llvm_test_cmd.step);
    m0_step.dependOn(&llvm_obj_test_cmd.step);
    m0_step.dependOn(&llvm_debug_test_cmd.step);
    m0_step.dependOn(&llvm_sweep_cmd.step);
    m0_step.dependOn(&llvm_spec_obj_sweep_cmd.step);
    m0_step.dependOn(&llvm_c_sweep_cmd.step);
    m0_step.dependOn(&llvm_opt_sweep_cmd.step);
    m0_step.dependOn(&llvm_c_obj_sweep_cmd.step);
    m0_step.dependOn(&llvm_cc_test_cmd.step);
    m0_step.dependOn(&llvm_move_test_cmd.step);
    m0_step.dependOn(&llvm_runtime_test_cmd.step);
    m0_step.dependOn(&llvm_std_test_cmd.step);
    m0_step.dependOn(&llvm_toolchain_test_cmd.step);
    m0_step.dependOn(&llvm_pkg_test_cmd.step);
    m0_step.dependOn(&llvm_demo_test_cmd.step);
    m0_step.dependOn(&llvm_kernel_test_cmd.step);
    m0_step.dependOn(&llvm_hosted_demo_test_cmd.step);
    m0_step.dependOn(&llvm_host_suite_test_cmd.step);
    m0_step.dependOn(&llvm_qemu_test_cmd.step);
    m0_step.dependOn(&llvm_trap_test_cmd.step);
    m0_step.dependOn(&llvm_thread_test_cmd.step);
    m0_step.dependOn(&llvm_sched_test_cmd.step);
    m0_step.dependOn(&llvm_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_user_test_cmd.step);
    m0_step.dependOn(&llvm_process_test_cmd.step);
    m0_step.dependOn(&llvm_elf_run_test_cmd.step);
    m0_step.dependOn(&llvm_fs_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_socket_syscall_test_cmd.step);
    m0_step.dependOn(&llvm_exec_test_cmd.step);
    m0_step.dependOn(&llvm_kmain_test_cmd.step);
    m0_step.dependOn(&llvm_kmain_net_test_cmd.step);
    m0_step.dependOn(&llvm_vm_switch_test_cmd.step);
    m0_step.dependOn(&llvm_vmspace_test_cmd.step);
    m0_step.dependOn(&llvm_vmctx_test_cmd.step);
    m0_step.dependOn(&llvm_sched_vm_test_cmd.step);
    m0_step.dependOn(&llvm_timeout_test_cmd.step);
    m0_step.dependOn(&llvm_signal_test_cmd.step);
    m0_step.dependOn(&llvm_registry_test_cmd.step);
    m0_step.dependOn(&llvm_ipc2_test_cmd.step);
    m0_step.dependOn(&llvm_ipc_test_cmd.step);
    m0_step.dependOn(&llvm_usched_test_cmd.step);
    m0_step.dependOn(&llvm_heartbeat_test_cmd.step);
    m0_step.dependOn(&llvm_privilege_test_cmd.step);
    m0_step.dependOn(&llvm_cap_test_cmd.step);
    m0_step.dependOn(&llvm_restart_test_cmd.step);
    m0_step.dependOn(&llvm_contain_test_cmd.step);
    m0_step.dependOn(&llvm_cow_test_cmd.step);
    m0_step.dependOn(&llvm_isolation_test_cmd.step);
    m0_step.dependOn(&llvm_demand_test_cmd.step);
    m0_step.dependOn(&llvm_mmap_test_cmd.step);
    m0_step.dependOn(&llvm_paging_activate_test_cmd.step);
    m0_step.dependOn(&llvm_block_server_test_cmd.step);
    m0_step.dependOn(&llvm_fs_server_test_cmd.step);
    m0_step.dependOn(&llvm_net_server_test_cmd.step);
    m0_step.dependOn(&llvm_rtc_test_cmd.step);
    m0_step.dependOn(&llvm_userserver_test_cmd.step);
    m0_step.dependOn(&llvm_backtrace_test_cmd.step);
    m0_step.dependOn(&llvm_driver_test_cmd.step);
    m0_step.dependOn(&llvm_preempt_test_cmd.step);
    m0_step.dependOn(&llvm_page_test_cmd.step);
    m0_step.dependOn(&llvm_heap_test_cmd.step);
    m0_step.dependOn(&llvm_paging_test_cmd.step);
    m0_step.dependOn(&llvm_smp_test_cmd.step);
    m0_step.dependOn(&llvm_smp_lock_test_cmd.step);
    m0_step.dependOn(&llvm_ipi_test_cmd.step);
    m0_step.dependOn(&llvm_tcp_server_test_cmd.step);

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
    // blk-test runs the virtio-blk driver reading a sector under QEMU.
    m0_step.dependOn(&blk_test_cmd.step);
    // udp-net-test transmits a real UDP datagram over virtio-net (pcap-verified).
    m0_step.dependOn(&udp_net_test_cmd.step);
    // smp-test boots multiple harts synchronizing on a shared atomic under QEMU.
    m0_step.dependOn(&smp_test_cmd.step);
    // smp-lock-test contends a ticket spinlock across harts under QEMU.
    m0_step.dependOn(&smp_lock_test_cmd.step);
    // ipi-test sends a CLINT software interrupt between harts under QEMU.
    m0_step.dependOn(&ipi_test_cmd.step);
    // demo-test compile-checks the whole demo/ suite (needs clang).
    m0_step.dependOn(&demo_test_cmd.step);
    // net-test runs the kernel virtio-net RX/TX ARP exchange under QEMU.
    m0_step.dependOn(&net_test_cmd.step);
    // kernel-test compile-checks kernel/ for riscv64 + typestate rejects.
    m0_step.dependOn(&kernel_test_cmd.step);
    // page-test links + runs the physical frame allocator (needs clang).
    m0_step.dependOn(&page_test_cmd.step);
    // heap-test links + runs the kernel heap (needs clang).
    m0_step.dependOn(&heap_test_cmd.step);
    // elf-test links + runs the ELF64 parser (needs clang).
    m0_step.dependOn(&elf_test_cmd.step);
    // ramfs-test links + runs the in-memory filesystem (needs clang).
    m0_step.dependOn(&ramfs_test_cmd.step);
    // vfs-test links + runs the fd-table VFS over ramfs (needs clang).
    m0_step.dependOn(&vfs_test_cmd.step);
    // blockfs-test links + runs the block-backed file store (needs clang).
    m0_step.dependOn(&blockfs_test_cmd.step);
    // udp-test links + runs the UDP build/parse + checksum (needs clang).
    m0_step.dependOn(&udp_test_cmd.step);
    // alloc-test links + runs the type-erased Allocator (needs clang).
    m0_step.dependOn(&alloc_test_cmd.step);
    m0_step.dependOn(&arc_test_cmd.step);
    m0_step.dependOn(&constgen_test_cmd.step);
    m0_step.dependOn(&ipc2_test_cmd.step);
    m0_step.dependOn(&registry_test_cmd.step);
    m0_step.dependOn(&signal_test_cmd.step);
    m0_step.dependOn(&privilege_test_cmd.step);
    m0_step.dependOn(&timeout_test_cmd.step);
    m0_step.dependOn(&heartbeat_test_cmd.step);
    m0_step.dependOn(&diskfs_test_cmd.step);
    m0_step.dependOn(&mmap_test_cmd.step);
    m0_step.dependOn(&demand_test_cmd.step);
    m0_step.dependOn(&isolation_test_cmd.step);
    m0_step.dependOn(&userserver_test_cmd.step);
    m0_step.dependOn(&usched_test_cmd.step);
    m0_step.dependOn(&cow_test_cmd.step);
    m0_step.dependOn(&pipe_test_cmd.step);
    m0_step.dependOn(&bcache_test_cmd.step);
    m0_step.dependOn(&perm_test_cmd.step);
    m0_step.dependOn(&pgroup_test_cmd.step);
    m0_step.dependOn(&tty_test_cmd.step);
    m0_step.dependOn(&args_test_cmd.step);
    m0_step.dependOn(&libc_test_cmd.step);
    // hosted-test runs the hosted-profile float I/O round-trip (needs clang+python3).
    m0_step.dependOn(&hosted_test_cmd.step);
    m0_step.dependOn(&shell_test_cmd.step);
    m0_step.dependOn(&shell2_test_cmd.step);
    m0_step.dependOn(&ushell_test_cmd.step);
    m0_step.dependOn(&vfsmount_test_cmd.step);
    m0_step.dependOn(&fdspace_test_cmd.step);
    m0_step.dependOn(&snapshot_test_cmd.step);
    m0_step.dependOn(&waitqueue_test_cmd.step);
    m0_step.dependOn(&service_test_cmd.step);
    m0_step.dependOn(&plugin_test_cmd.step);
    m0_step.dependOn(&endpoint_test_cmd.step);
    m0_step.dependOn(&supervisor_test_cmd.step);
    m0_step.dependOn(&registry2_test_cmd.step);
    m0_step.dependOn(&manifest_test_cmd.step);
    m0_step.dependOn(&scheduler_test_cmd.step);
    m0_step.dependOn(&info_test_cmd.step);
    m0_step.dependOn(&granttab_test_cmd.step);
    m0_step.dependOn(&x86_sched_test_cmd.step);
    m0_step.dependOn(&x86_qemu_test_cmd.step);
    m0_step.dependOn(&slotmap_test_cmd.step);
    m0_step.dependOn(&mask_test_cmd.step);
    m0_step.dependOn(&mailbox_test_cmd.step);
    m0_step.dependOn(&tryelse_test_cmd.step);
    m0_step.dependOn(&byteview_test_cmd.step);
    m0_step.dependOn(&scan_test_cmd.step);
    m0_step.dependOn(&posix_test_cmd.step);
    m0_step.dependOn(&userland_test_cmd.step);
    m0_step.dependOn(&smprq_test_cmd.step);
    m0_step.dependOn(&rtc_test_cmd.step);
    m0_step.dependOn(&contain_test_cmd.step);
    m0_step.dependOn(&tcp_server_test_cmd.step);
    m0_step.dependOn(&fdt_test_cmd.step);
    m0_step.dependOn(&fb_test_cmd.step);
    m0_step.dependOn(&dynlink_test_cmd.step);
    m0_step.dependOn(&aarch64_test_cmd.step);
    m0_step.dependOn(&liveupdate_test_cmd.step);
    m0_step.dependOn(&sbi_boot_test_cmd.step);
    m0_step.dependOn(&e1000_test_cmd.step);
    m0_step.dependOn(&grant_test_cmd.step);
    m0_step.dependOn(&ipc_test_cmd.step);
    m0_step.dependOn(&block_server_test_cmd.step);
    m0_step.dependOn(&fs_server_test_cmd.step);
    m0_step.dependOn(&net_server_test_cmd.step);
    m0_step.dependOn(&cap_test_cmd.step);
    m0_step.dependOn(&restart_test_cmd.step);
    m0_step.dependOn(&arc_pkt_test_cmd.step);
    m0_step.dependOn(&arena_test_cmd.step);
    m0_step.dependOn(&genref_test_cmd.step);
    m0_step.dependOn(&owned_test_cmd.step);
    m0_step.dependOn(&net_arena_test_cmd.step);
    m0_step.dependOn(&pool_test_cmd.step);
    // closure-test links + runs a bind() capturing closure (needs clang).
    m0_step.dependOn(&closure_test_cmd.step);
    // ring-test links + runs the generic in-place Ring<T> (needs clang).
    m0_step.dependOn(&ring_test_cmd.step);
    // trace-test links + runs the trace ring buffer (needs clang).
    m0_step.dependOn(&trace_test_cmd.step);
    // log-test links + runs the leveled tracepoint logger (needs clang).
    m0_step.dependOn(&log_test_cmd.step);
    // tcp-test links + runs the TCP build/parse + checksum (needs clang).
    m0_step.dependOn(&tcp_test_cmd.step);
    // tcp-conn-test links + runs the TCP connection state machine (needs clang).
    m0_step.dependOn(&tcp_conn_test_cmd.step);
    // tcp-window-test links + runs the TCP window/data-plane bookkeeping (needs clang).
    m0_step.dependOn(&tcp_window_test_cmd.step);
    // tcp-reasm-test links + runs TCP reassembly + go-back-N retransmit (needs clang).
    m0_step.dependOn(&tcp_reasm_test_cmd.step);
    // tcp-rtx-test links + runs the TCP retransmit timer (needs clang).
    m0_step.dependOn(&tcp_rtx_test_cmd.step);
    // symbols-test links + runs the symbol table / address symbolizer (needs clang).
    m0_step.dependOn(&symbols_test_cmd.step);
    // socket-test links + runs the UDP socket bind/deliver/recv layer (needs clang).
    m0_step.dependOn(&socket_test_cmd.step);
    // net-rx-test links + runs the RX demux path (frame -> socket_deliver) (needs clang).
    m0_step.dependOn(&net_rx_test_cmd.step);
    // net-fuzz-test fuzzes the RX parser with random frames (needs clang).
    m0_step.dependOn(&net_fuzz_test_cmd.step);
    // net-rx-live-test routes a real virtio-net RX frame through net_rx_deliver under QEMU.
    m0_step.dependOn(&net_rx_live_test_cmd.step);
    // backtrace-test walks the frame-pointer chain + symbolizes under QEMU.
    m0_step.dependOn(&backtrace_test_cmd.step);
    // paging-test links + runs the Sv39 page-table map/translate (needs clang).
    m0_step.dependOn(&paging_test_cmd.step);
    // fnptr-test links + runs function-pointer dispatch (needs clang).
    m0_step.dependOn(&fnptr_test_cmd.step);
    // trap-test runs the typed-CPU trap/timer interrupt path under QEMU.
    m0_step.dependOn(&trap_test_cmd.step);
    // thread-test runs cooperative context switching under QEMU.
    m0_step.dependOn(&thread_test_cmd.step);
    // sched-test runs the round-robin scheduler under QEMU.
    m0_step.dependOn(&sched_test_cmd.step);
    // preempt-test runs the timer-driven preemptive scheduler under QEMU.
    m0_step.dependOn(&preempt_test_cmd.step);
    // syscall-test runs the ecall syscall dispatch skeleton under QEMU.
    m0_step.dependOn(&syscall_test_cmd.step);
    // user-test runs the M->U privilege drop + user-mode syscalls under QEMU.
    m0_step.dependOn(&user_test_cmd.step);
    // process-test runs process lifecycle (spawn/run/exit) under QEMU.
    m0_step.dependOn(&process_test_cmd.step);
    // elf-run-test loads an ELF64 and runs it in U-mode under QEMU.
    m0_step.dependOn(&elf_run_test_cmd.step);
    // driver-test runs the char-device driver framework (vtable dispatch) under QEMU.
    m0_step.dependOn(&driver_test_cmd.step);
    // fs-syscall-test runs U-mode file syscalls over the VFS under QEMU.
    m0_step.dependOn(&fs_syscall_test_cmd.step);
    // socket-syscall-test runs U-mode recvfrom over the UDP socket layer under QEMU.
    m0_step.dependOn(&socket_syscall_test_cmd.step);
    // exec-test runs sys_exec: a U-mode program loads + runs another ELF under QEMU.
    m0_step.dependOn(&exec_test_cmd.step);
    // paging-activate-test activates Sv39 satp in S-mode + reads a translated VA.
    m0_step.dependOn(&paging_activate_test_cmd.step);
    // kmain-test boots one integrated kernel image (heap+console+log+VFS+scheduler).
    m0_step.dependOn(&kmain_test_cmd.step);
    // vm-switch-test switches satp between two address spaces (per-process VM).
    m0_step.dependOn(&vm_switch_test_cmd.step);
    // vmspace-test switches satp per process slot (per-process page tables).
    m0_step.dependOn(&vmspace_test_cmd.step);
    // vmctx-test: a context switch that swaps satp per thread (address space in the switch).
    m0_step.dependOn(&vmctx_test_cmd.step);
    // sched-vm-test: the scheduler switches per-process address spaces (proc_yield_vm).
    m0_step.dependOn(&sched_vm_test_cmd.step);
    // kmain-net-test boots the integrated kernel + network in one image.
    m0_step.dependOn(&kmain_net_test_cmd.step);
}
