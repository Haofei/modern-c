# TODO — 通往完整 OS 的路线图

标记：

- `[x]` 已完成，已有测试或可运行 demo 覆盖
- `[~]` 部分完成，机制存在但还没接成生产路径
- `[ ]` 未完成

目标不是堆功能，而是把内核变成一个可以持续扩展的微内核式 OS。

---

## Tier 0：先补齐的架构债

这些项会影响后面所有服务 / 驱动 / POSIX 功能，优先级最高。

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[~]` | Endpoint 化 IPC | 已有 `Endpoint { slot, gen }`、`endpoint_slot`、`ipc_send_ep`，但大量调用仍用 raw pid | 新代码默认用 endpoint API；逐步让 `ipc_send` / `ipc_call` 返回 `Result` |
| `[~]` | 阻塞语义 | `ipc_receive` / waitqueue 已用 `proc_yield_or_idle`，但 `ipc_send` 对 dead/full 目标仍可能无限 yield | blocking send 改成 `Result` / timeout；dead endpoint 立即失败 |
| `[~]` | CPU idle / no-runnable 路径 | 有 `proc_set_idle`、RISC-V `arch/riscv64/idle.mc`，测试有 counting idle hook | 所有真实 `proc_table_init` 后安装 arch idle；最后 runnable 退出时进入 idle/reaper |
| `[~]` | `proc_wait` 真正阻塞 | `proc_wait` 现在还是 yield/retry | 用 waitqueue 挂到 child-exit 事件，子进程退出时唤醒 parent |
| `[~]` | 进程死亡清理 | 死亡时会释放等待 `ipc_receive_from` 的 waiter；waitqueue 已存 Endpoint | 扩展到 grants、registry、fdspace、service supervisor 的统一 cleanup |
| `[~]` | Service manifest enforcement | `ServiceManifest`、supervisor、registry update 已有 | 启动服务时真正应用 allow-list、kcall mask、priority、restart policy |

---

## Tier 1：微内核核心

### 隔离与保护

| 状态 | 缺什么 | 现状 | 为什么重要 |
|---|---|---|---|
| `[~]` | 跨地址空间 IPC | 已有 per-process `satp` / isolation / userserver demo；生产 IPC 仍主要是内核内 Message | 真正隔离需要 ecall IPC + grant/copy 跨 AS 路径 |
| `[~]` | Grant-based payload | `std/grant` 已有 bounded delegation / revoke 测试 | 大消息和跨 AS buffer 不能靠裸地址 |
| `[~]` | IRQ / MMIO 权限控制 | IPC allow-list、kcall mask、capability demo 已有 | 驱动隔离需要限制谁能访问哪些 IRQ / MMIO / bus resource |
| `[~]` | kcall 的实际操作 | kcall 网关已有，但很多 op 还是 stub | 需要实现 map/unmap、grant、program IRQ、resource bind 等真实特权操作 |

### 进程与内存

| 状态 | 缺什么 | 现状 | 为什么重要 |
|---|---|---|---|
| `[~]` | 完整 fork | COW / vmspace / demand paging 已有机制，但没有整合成 fork | fork 是 Unix 进程模型的根基 |
| `[~]` | exec / user image lifecycle | ELF load + U-mode run demo 已有 | 需要和 VFS、进程表、地址空间、fd inheritance 连接 |
| `[ ]` | 共享内存 | mmap 有匿名映射，没有共享映射对象 | 多进程协作需要 |
| `[ ]` | swap / page reclaim | demand paging 有，换出没有 | 内存超卖和长期运行需要 |
| `[~]` | POSIX 信号处理 | 内核有投递 / pending / take 原语 | 需要 PM server 实现 handler、default action、process group 语义 |

### 调度

| 状态 | 缺什么 | 现状 | 为什么重要 |
|---|---|---|---|
| `[~]` | Scheduler service | priority / quantum / sched endpoint 字段已有，`proc_tick` 已 edge-triggered | 需要把 quantum expiry 通知给 scheduler server，由 policy 刷新 quantum/priority |
| `[~]` | SMP runqueue 接入 | `smprq` 有 per-core queue + work stealing 测试 | 还没接入真实 scheduler / process table |
| `[ ]` | TLB shootdown | 没有 | SMP 多核切换/修改地址空间必须有 |

---

## Tier 2：OS 服务层

### Service / Registry / Supervisor

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[x]` | 基础 service loop | `kernel/lib/service.mc` request/reply loop 已有 | 用到更多真实 server |
| `[x]` | Registry v2 | 支持 multiple per key、generation、unregister endpoint | 把 bus/service discovery 全部迁移到 v2 语义 |
| `[~]` | Supervisor respawn | supervisor 可 respawn 并更新 registry | 接真实 process spawn、endpoint generation、dependency graph |
| `[ ]` | 依赖感知恢复 | heartbeat / restart 有，但服务依赖图不完整 | 服务失败时按依赖顺序 stop/restart |
| `[~]` | Live update | checkpoint / restore demo 有 | 还缺 quiescence、全服务迁移、兼容性检查 |

### Info / observability

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[~]` | top / ps snapshot | `proc_snapshot` 和 user `top` 已有 | 做成 Info service，不直接读 live ProcTable |
| `[~]` | tracing | trace ring / log 已有 | 统一事件 schema：sched、IPC、IRQ、service restart |
| `[ ]` | scheduler counters | 只有基础 ticks / quantum | 加 runnable time、blocked reason、context switches、IPC counts |

---

## Tier 3：文件系统 / POSIX

### 文件系统

| 状态 | 缺什么 | 现状 | 为什么重要 |
|---|---|---|---|
| `[~]` | VFS mount 路由 | `vfsmount` 有 mount / umount / resolve 测试 | 需要完整路径前缀分发和权限检查 |
| `[ ]` | 嵌套目录 / 路径 | diskfs 只有根目录级模型 | mkdir、lookup、rename、unlink 都依赖它 |
| `[ ]` | 完整 inode metadata | 现在 metadata 很少 | permissions、times、owner、link count |
| `[ ]` | FAT / ext2 支持 | 现在主要是 ramfs / 最小 diskfs | 需要和真实磁盘镜像互操作 |
| `[~]` | block cache | bcache 有 write-back 测试 | 接入 diskfs / block server 的生产路径 |

### POSIX surface

| 状态 | 缺什么 | 现状 | 为什么重要 |
|---|---|---|---|
| `[~]` | syscall 集 | 有 getpid/open/write/read/close/socket demo 等 | 还缺 fork/exec/wait/dup/ioctl/mmap/stat/readdir |
| `[~]` | fdspace | `kernel/lib/fdspace.mc` 已替代 fdtable | 接 VFS、socket、pipe、select/poll 的统一 fd layer |
| `[~]` | Shell 执行外部程序 | user shell + builtins + top 已有 | 需要 fork/exec 从 diskfs 加载程序 |
| `[~]` | libc | 有 memeq/strlen/atoi 等 | 缺 printf/malloc/readdir/stat/env 等 |
| `[~]` | 动态链接 | `R_RISCV_RELATIVE` 已有 | 缺 symbol resolution、PLT/GOT、`.so` |
| `[~]` | Job control | pgroup/session 基础有 | 缺 SIGTSTP、bg、fg、tty foreground process group |

---

## Tier 4：网络

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[~]` | socket API | UDP socket layer、socket syscall demo、net server demo 已有 | 补 bind/connect/sendto/recvfrom/listen/accept 的一致 syscall surface |
| `[~]` | TCP | segment parse/build、state machine、server demo、reasm/rtx/window 已有 | 接入 socket API、timeouts、close states、server isolation |
| `[ ]` | ARP cache | ARP 能工作，但没有完整 cache policy | 加 TTL、refresh、pending queue |
| `[ ]` | routing table | 现在基本是直连 / 固定网关 | 多网卡、多 subnet、默认路由 |
| `[ ]` | DHCP | 没有 | 自动配置 IP/gateway/DNS |
| `[ ]` | DNS | 没有 | 用户态 resolver 或 net service |
| `[~]` | interrupt-driven NIC RX | live RX demo 有，virtio-net 很多路径仍偏轮询 | 接 PLIC IRQ、RX budget、backpressure |

---

## Tier 5：驱动 / 平台

### 驱动

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[~]` | PCI / bus model | bus/provider/registry plugin flow 有；e1000 能 probe BAR | 把 PCI 作为 bus manager，驱动注册 provider |
| `[~]` | e1000 TX/RX | 能探测和读 BAR | 实现 descriptor rings、IRQ、TX/RX path |
| `[~]` | virtio-blk / block server | blk read、block server demo 有 | 完整 write/cache/fs 集成 |
| `[ ]` | AHCI / SATA | 没有 | 后续真实硬件存储 |
| `[ ]` | USB / keyboard / audio | 没有 | 输入和设备生态 |
| `[~]` | DTB 解析 | FDT header 基础有 | 遍历节点、reg/interrupts、compatible match |

### 平台

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[~]` | OpenSBI / 物理板子启动 | OpenSBI S-mode boot 测试通过 | 接 DTB、SBI timer/IPI、真实板子 UART/PLIC |
| `[~]` | aarch64 完整移植 | aarch64 QEMU 可 boot 一个最小 MC 程序 | trap、paging、context、interrupt 仍要补 |
| `[~]` | x86_64 完整移植 | 有 Multiboot/long-mode boot、context switch、native x86 sched test | 补 GDT/IDT、paging、APIC、trap、arch import 选择 |
| `[~]` | SMP | harts boot、IPI、spinlock、smprq 都有测试 | 接真实 scheduler、TLB shootdown、per-core current |

---

## Tier 6：语言 / 工具链

| 状态 | 缺什么 | 现状 | 下一步 |
|---|---|---|---|
| `[x]` | Move through switch / if-let | 已修复；`tests/spec/move_linear.mc` 覆盖 | 继续扩展 move diagnostics |
| `[~]` | closure/global lowering | global closure / fn pointer、global array element field read/write、direct closure call regression 已有 | 扩更多 nested aggregate/global assignment case |
| `[x]` | `mmio.map(...)` emit try on `MmioPtr` | 已接入 sema / MIR / C emission；移出 spec sweep allowlist | 继续扩展 MMIO map 组合用例 |
| `[x]` | `Result<GenericStruct, E>` 名字混淆 | 已有 `tests/c_emit/generic_structs.mc` 覆盖 lower-C monomorphized ABI | 继续扩展嵌套泛型 ABI regression |
| `[~]` | LLVM backend | 已有初始 `emit-llvm`：MIR 验证后输出 scalar 函数 / call / void call+expr stmt+assert+block workflow / trap+unreachable+never return / nullable pointer workflow(null、? unwrap、if-let、switch) / unsafe machine ops(raw load/store、raw.ptr、phys、cpu.pause、raw-many offset) / type alias + enum representation lowering / checked integer arithmetic+signed unary negation / checked div-rem / scalar casts+bitwise+checked shifts / target-typed integer/enum coercion / wrap<T>+sat<T> payload ABI、domain conversions/residue、wrap modular ops、unsigned sat arithmetic / char literal+checked u8 arithmetic / short-circuit bool ops / f32+f64 scalar ops / bool switch-if control flow with simple joins / scalar switch / simple scalar local / inferred local / while+for loop CFG / break+continue / basic pointer load-store / scalar-pointer global / local fixed scalar array / local scalar struct / scalar aggregate global / scalar aggregate ABI / aggregate layout ordering / nested aggregate access / aggregate rvalue materialization / aggregate assignment+copy / core slice value+index+range / atomic<T> init+load+store+fetch_add+fetch_sub / fn pointer value+static init+indirect call / 初始 LLVM debug metadata 的 textual LLVM IR，并用 `llvm-as` 验证 smoke；`mcc-llvm-cc.sh` 已通过 `llc` 产出代表性 object | 扩 richer iterable forms、broader aggregate ABI/layout、broader slice/pattern workflow、fuller debug mapping |
| `[~]` | debug info | `emit-c` 已输出 `#line` source hint；`emit-map` 已输出初始 `.mcmap`，含 deferred cleanup spans 和可匹配的 MIR block/instr label | 继续扩充覆盖范围 / native DWARF 映射 |
| `[~]` | package manager | `mcc-pkg.sh` 有本地 manifest/info、递归 deps 解析 + 版本校验、manifest build | 需要 registry、版本解析、发布 |
| `[ ]` | LSP / formatter | 没有 | 开发体验必需 |

---

## 建议的最近 10 个 must-do

1. 把新代码默认迁到 `Endpoint` IPC；raw-pid IPC 标记为 legacy。
2. 让 blocking `ipc_send` / `ipc_call` 返回 `Result`，dead endpoint 不再无限 yield。
3. 所有真实 process table 初始化后安装 arch idle hook。
4. `proc_wait` 接 waitqueue，child exit 唤醒 parent。
5. 统一 process death cleanup：IPC、waitqueue、grants、registry、fdspace。
6. Service manifest 真正 enforce 到 allow-list / kcall mask / scheduler policy。
7. Scheduler service：处理 quantum expiry、priority refresh、accounting。
8. Info service：`top`/`ps` 从 snapshot service 读，不直接读 live table。
9. Registry/supervisor 接真实 process endpoint generation 和 dependency graph。
10. fdspace 接 VFS/socket/pipe 的统一 select/poll 模型。
