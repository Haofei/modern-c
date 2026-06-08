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

    const blk_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/blk-test.sh",
        "zig-out/bin/mcc",
    });
    blk_test_cmd.step.dependOn(b.getInstallStep());
    const blk_test_step = b.step("blk-test", "Build and run the virtio-blk driver reading a sector under QEMU");
    blk_test_step.dependOn(&blk_test_cmd.step);

    const udp_net_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/udp-net-test.sh",
        "zig-out/bin/mcc",
    });
    udp_net_test_cmd.step.dependOn(b.getInstallStep());
    const udp_net_test_step = b.step("udp-net-test", "Transmit a real UDP datagram over virtio-net under QEMU (pcap-verified)");
    udp_net_test_step.dependOn(&udp_net_test_cmd.step);

    const smp_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/smp-test.sh",
        "zig-out/bin/mcc",
    });
    smp_test_cmd.step.dependOn(b.getInstallStep());
    const smp_test_step = b.step("smp-test", "Boot multiple harts and synchronize on a shared atomic under QEMU");
    smp_test_step.dependOn(&smp_test_cmd.step);

    const smp_lock_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/smp-lock-test.sh",
        "zig-out/bin/mcc",
    });
    smp_lock_test_cmd.step.dependOn(b.getInstallStep());
    const smp_lock_test_step = b.step("smp-lock-test", "Contend a ticket spinlock across harts under QEMU (mutual exclusion)");
    smp_lock_test_step.dependOn(&smp_lock_test_cmd.step);

    const ipi_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/ipi-test.sh",
        "zig-out/bin/mcc",
    });
    ipi_test_cmd.step.dependOn(b.getInstallStep());
    const ipi_test_step = b.step("ipi-test", "Send a CLINT software interrupt (IPI) between harts under QEMU");
    ipi_test_step.dependOn(&ipi_test_cmd.step);

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

    const page_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/page-test.sh",
        "zig-out/bin/mcc",
    });
    page_test_cmd.step.dependOn(b.getInstallStep());
    const page_test_step = b.step("page-test", "Link + run the physical frame allocator (bump + free-list reclaim)");
    page_test_step.dependOn(&page_test_cmd.step);

    const heap_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/heap-test.sh",
        "zig-out/bin/mcc",
    });
    heap_test_cmd.step.dependOn(b.getInstallStep());
    const heap_test_step = b.step("heap-test", "Link + run the kernel heap (aligned bump over a PhysRange)");
    heap_test_step.dependOn(&heap_test_cmd.step);

    const elf_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/elf-test.sh",
        "zig-out/bin/mcc",
    });
    elf_test_cmd.step.dependOn(b.getInstallStep());
    const elf_test_step = b.step("elf-test", "Link + run the ELF64 parser (header + program headers, bounds-checked)");
    elf_test_step.dependOn(&elf_test_cmd.step);

    const ramfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/ramfs-test.sh",
        "zig-out/bin/mcc",
    });
    ramfs_test_cmd.step.dependOn(b.getInstallStep());
    const ramfs_test_step = b.step("ramfs-test", "Link + run the in-memory filesystem (create/write/read/lookup)");
    ramfs_test_step.dependOn(&ramfs_test_cmd.step);

    const vfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/vfs-test.sh",
        "zig-out/bin/mcc",
    });
    vfs_test_cmd.step.dependOn(b.getInstallStep());
    const vfs_test_step = b.step("vfs-test", "Link + run the fd-table VFS over ramfs (open/read/write/close)");
    vfs_test_step.dependOn(&vfs_test_cmd.step);

    const blockfs_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/blockfs-test.sh",
        "zig-out/bin/mcc",
    });
    blockfs_test_cmd.step.dependOn(b.getInstallStep());
    const blockfs_test_step = b.step("blockfs-test", "Link + run the block-backed file store (block device vtable)");
    blockfs_test_step.dependOn(&blockfs_test_cmd.step);

    const udp_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/udp-test.sh",
        "zig-out/bin/mcc",
    });
    udp_test_cmd.step.dependOn(b.getInstallStep());
    const udp_test_step = b.step("udp-test", "Link + run the UDP datagram build/parse + checksum");
    udp_test_step.dependOn(&udp_test_cmd.step);

    const closure_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/closure-test.sh",
        "zig-out/bin/mcc",
    });
    closure_test_cmd.step.dependOn(b.getInstallStep());
    const closure_test_step = b.step("closure-test", "Link + run a bind() closure (capture + call across calls)");
    closure_test_step.dependOn(&closure_test_cmd.step);

    const ring_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/ring-test.sh",
        "zig-out/bin/mcc",
    });
    ring_test_cmd.step.dependOn(b.getInstallStep());
    const ring_test_step = b.step("ring-test", "Link + run the generic in-place Ring<T> (push/pop/wrap)");
    ring_test_step.dependOn(&ring_test_cmd.step);

    const trace_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/trace-test.sh",
        "zig-out/bin/mcc",
    });
    trace_test_cmd.step.dependOn(b.getInstallStep());
    const trace_test_step = b.step("trace-test", "Link + run the trace ring buffer (retention/wrap/sequence)");
    trace_test_step.dependOn(&trace_test_cmd.step);

    const log_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/log-test.sh",
        "zig-out/bin/mcc",
    });
    log_test_cmd.step.dependOn(b.getInstallStep());
    const log_test_step = b.step("log-test", "Link + run the leveled tracepoint logger (threshold/levels)");
    log_test_step.dependOn(&log_test_cmd.step);

    const tcp_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/tcp-test.sh",
        "zig-out/bin/mcc",
    });
    tcp_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_test_step = b.step("tcp-test", "Link + run the TCP segment build/parse + checksum");
    tcp_test_step.dependOn(&tcp_test_cmd.step);

    const tcp_conn_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/tcp-conn-test.sh",
        "zig-out/bin/mcc",
    });
    tcp_conn_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_conn_test_step = b.step("tcp-conn-test", "Link + run the TCP connection state machine (handshake/close)");
    tcp_conn_test_step.dependOn(&tcp_conn_test_cmd.step);

    const tcp_window_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/tcp-window-test.sh",
        "zig-out/bin/mcc",
    });
    tcp_window_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_window_test_step = b.step("tcp-window-test", "Link + run the TCP send/recv window + ACK processing (data plane)");
    tcp_window_test_step.dependOn(&tcp_window_test_cmd.step);

    const tcp_reasm_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/tcp-reasm-test.sh",
        "zig-out/bin/mcc",
    });
    tcp_reasm_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_reasm_test_step = b.step("tcp-reasm-test", "Link + run TCP reassembly + go-back-N retransmit");
    tcp_reasm_test_step.dependOn(&tcp_reasm_test_cmd.step);

    const tcp_rtx_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/tcp-rtx-test.sh",
        "zig-out/bin/mcc",
    });
    tcp_rtx_test_cmd.step.dependOn(b.getInstallStep());
    const tcp_rtx_test_step = b.step("tcp-rtx-test", "Link + run the TCP retransmit timer (RTO -> go-back-N)");
    tcp_rtx_test_step.dependOn(&tcp_rtx_test_cmd.step);

    const symbols_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/symbols-test.sh",
        "zig-out/bin/mcc",
    });
    symbols_test_cmd.step.dependOn(b.getInstallStep());
    const symbols_test_step = b.step("symbols-test", "Link + run the symbol table (symbolize address -> function+offset)");
    symbols_test_step.dependOn(&symbols_test_cmd.step);

    const socket_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/socket-test.sh",
        "zig-out/bin/mcc",
    });
    socket_test_cmd.step.dependOn(b.getInstallStep());
    const socket_test_step = b.step("socket-test", "Link + run the UDP socket layer (bind/deliver/recv demux)");
    socket_test_step.dependOn(&socket_test_cmd.step);

    const net_rx_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net-rx-test.sh",
        "zig-out/bin/mcc",
    });
    net_rx_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_test_step = b.step("net-rx-test", "Link + run the RX demux path (frame -> socket_deliver -> recv)");
    net_rx_test_step.dependOn(&net_rx_test_cmd.step);

    const net_fuzz_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net-fuzz-test.sh",
        "zig-out/bin/mcc",
    });
    net_fuzz_test_cmd.step.dependOn(b.getInstallStep());
    const net_fuzz_test_step = b.step("net-fuzz-test", "Fuzz the RX parser with random frames (no OOB)");
    net_fuzz_test_step.dependOn(&net_fuzz_test_cmd.step);

    const net_rx_live_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/net-rx-live-test.sh",
        "zig-out/bin/mcc",
    });
    net_rx_live_test_cmd.step.dependOn(b.getInstallStep());
    const net_rx_live_test_step = b.step("net-rx-live-test", "Route a real virtio-net RX frame through net_rx_deliver under QEMU");
    net_rx_live_test_step.dependOn(&net_rx_live_test_cmd.step);

    const backtrace_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/backtrace-test.sh",
        "zig-out/bin/mcc",
    });
    backtrace_test_cmd.step.dependOn(b.getInstallStep());
    const backtrace_test_step = b.step("backtrace-test", "Walk the frame-pointer chain and symbolize the frames under QEMU");
    backtrace_test_step.dependOn(&backtrace_test_cmd.step);

    const paging_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/paging-test.sh",
        "zig-out/bin/mcc",
    });
    paging_test_cmd.step.dependOn(b.getInstallStep());
    const paging_test_step = b.step("paging-test", "Link + run Sv39 page-table map/translate");
    paging_test_step.dependOn(&paging_test_cmd.step);

    const fnptr_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/fnptr-test.sh",
        "zig-out/bin/mcc",
    });
    fnptr_test_cmd.step.dependOn(b.getInstallStep());
    const fnptr_test_step = b.step("fnptr-test", "Link + run function-pointer dispatch (callback, vtable, return)");
    fnptr_test_step.dependOn(&fnptr_test_cmd.step);

    const trap_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/trap-test.sh",
        "zig-out/bin/mcc",
    });
    trap_test_cmd.step.dependOn(b.getInstallStep());
    const trap_test_step = b.step("trap-test", "Run the typed-CPU trap/timer interrupt path under QEMU");
    trap_test_step.dependOn(&trap_test_cmd.step);

    const thread_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/thread-test.sh",
        "zig-out/bin/mcc",
    });
    thread_test_cmd.step.dependOn(b.getInstallStep());
    const thread_test_step = b.step("thread-test", "Run cooperative context switching (main/worker ping-pong) under QEMU");
    thread_test_step.dependOn(&thread_test_cmd.step);

    const sched_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/sched-test.sh",
        "zig-out/bin/mcc",
    });
    sched_test_cmd.step.dependOn(b.getInstallStep());
    const sched_test_step = b.step("sched-test", "Run the round-robin scheduler (3 heap-stacked threads) under QEMU");
    sched_test_step.dependOn(&sched_test_cmd.step);

    const preempt_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/preempt-test.sh",
        "zig-out/bin/mcc",
    });
    preempt_test_cmd.step.dependOn(b.getInstallStep());
    const preempt_test_step = b.step("preempt-test", "Run the timer-driven preemptive scheduler under QEMU");
    preempt_test_step.dependOn(&preempt_test_cmd.step);

    const syscall_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/syscall-test.sh",
        "zig-out/bin/mcc",
    });
    syscall_test_cmd.step.dependOn(b.getInstallStep());
    const syscall_test_step = b.step("syscall-test", "Run the ecall syscall dispatch skeleton under QEMU");
    syscall_test_step.dependOn(&syscall_test_cmd.step);

    const user_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/user-test.sh",
        "zig-out/bin/mcc",
    });
    user_test_cmd.step.dependOn(b.getInstallStep());
    const user_test_step = b.step("user-test", "Run the M->U privilege drop + user-mode syscalls under QEMU");
    user_test_step.dependOn(&user_test_cmd.step);

    const process_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/process-test.sh",
        "zig-out/bin/mcc",
    });
    process_test_cmd.step.dependOn(b.getInstallStep());
    const process_test_step = b.step("process-test", "Run process lifecycle (spawn/run/exit) under QEMU");
    process_test_step.dependOn(&process_test_cmd.step);

    const elf_run_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/elf-run-test.sh",
        "zig-out/bin/mcc",
    });
    elf_run_test_cmd.step.dependOn(b.getInstallStep());
    const elf_run_test_step = b.step("elf-run-test", "Load an ELF64 and run it in U-mode under QEMU");
    elf_run_test_step.dependOn(&elf_run_test_cmd.step);

    const driver_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/driver-test.sh",
        "zig-out/bin/mcc",
    });
    driver_test_cmd.step.dependOn(b.getInstallStep());
    const driver_test_step = b.step("driver-test", "Run the char-device driver framework (vtable dispatch) under QEMU");
    driver_test_step.dependOn(&driver_test_cmd.step);

    const fs_syscall_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/fs-syscall-test.sh",
        "zig-out/bin/mcc",
    });
    fs_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const fs_syscall_test_step = b.step("fs-syscall-test", "Run U-mode file syscalls (open/write/read/close) over the VFS under QEMU");
    fs_syscall_test_step.dependOn(&fs_syscall_test_cmd.step);

    const socket_syscall_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/socket-syscall-test.sh",
        "zig-out/bin/mcc",
    });
    socket_syscall_test_cmd.step.dependOn(b.getInstallStep());
    const socket_syscall_test_step = b.step("socket-syscall-test", "Run U-mode recvfrom over the UDP socket layer under QEMU");
    socket_syscall_test_step.dependOn(&socket_syscall_test_cmd.step);

    const exec_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/exec-test.sh",
        "zig-out/bin/mcc",
    });
    exec_test_cmd.step.dependOn(b.getInstallStep());
    const exec_test_step = b.step("exec-test", "Run sys_exec: a U-mode program loads + runs another ELF under QEMU");
    exec_test_step.dependOn(&exec_test_cmd.step);

    const paging_activate_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/paging-activate-test.sh",
        "zig-out/bin/mcc",
    });
    paging_activate_test_cmd.step.dependOn(b.getInstallStep());
    const paging_activate_test_step = b.step("paging-activate-test", "Activate Sv39 satp in S-mode and read a translation-only VA under QEMU");
    paging_activate_test_step.dependOn(&paging_activate_test_cmd.step);

    const kmain_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/kmain-test.sh",
        "zig-out/bin/mcc",
    });
    kmain_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_test_step = b.step("kmain-test", "Boot one integrated kernel image (heap+console+log+VFS+scheduler) under QEMU");
    kmain_test_step.dependOn(&kmain_test_cmd.step);

    const kmain_net_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/kmain-net-test.sh",
        "zig-out/bin/mcc",
    });
    kmain_net_test_cmd.step.dependOn(b.getInstallStep());
    const kmain_net_test_step = b.step("kmain-net-test", "Boot the integrated kernel + network in one image under QEMU");
    kmain_net_test_step.dependOn(&kmain_net_test_cmd.step);

    const vm_switch_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/vm-switch-test.sh",
        "zig-out/bin/mcc",
    });
    vm_switch_test_cmd.step.dependOn(b.getInstallStep());
    const vm_switch_test_step = b.step("vm-switch-test", "Switch satp between two address spaces under QEMU (per-process VM)");
    vm_switch_test_step.dependOn(&vm_switch_test_cmd.step);

    const vmspace_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/vmspace-test.sh",
        "zig-out/bin/mcc",
    });
    vmspace_test_cmd.step.dependOn(b.getInstallStep());
    const vmspace_test_step = b.step("vmspace-test", "Per-process page tables: switch satp by process slot under QEMU");
    vmspace_test_step.dependOn(&vmspace_test_cmd.step);

    const vmctx_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/vmctx-test.sh",
        "zig-out/bin/mcc",
    });
    vmctx_test_cmd.step.dependOn(b.getInstallStep());
    const vmctx_test_step = b.step("vmctx-test", "Context switch that swaps satp per thread under QEMU");
    vmctx_test_step.dependOn(&vmctx_test_cmd.step);

    const sched_vm_test_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/sched-vm-test.sh",
        "zig-out/bin/mcc",
    });
    sched_vm_test_cmd.step.dependOn(b.getInstallStep());
    const sched_vm_test_step = b.step("sched-vm-test", "Scheduler switching per-process address spaces (proc_yield_vm) under QEMU");
    sched_vm_test_step.dependOn(&sched_vm_test_cmd.step);

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
