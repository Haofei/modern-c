# Milestone — MC as an Agent-Containment Runtime

> **Positioning.** Not "a new OS." **A typed, capability-secure substrate for *containing*
> AI agents and the tools they call.** The product is a *trust boundary* for agents that
> read files, run code, call tools, touch networks, and persist state **without inheriting
> the user's full authority.**
>
> Companion docs: [`agent-os-vision.md`](agent-os-vision.md) (the why),
> [`spec/MC_Kernel_Design.md`](spec/MC_Kernel_Design.md) (the what), this doc (the *next
> milestone* and its acceptance bar).

---

## 1. The thesis, and the moat

The agent world has converged on **tools + sandboxes**, and tool usage is shifting from
read-only to *action* tools that modify external state — which is exactly a containment
problem. Many things already sandbox agents (Firecracker, gVisor, containers, WASM, hosted
sandboxes). So "we can sandbox an agent" is **not** the moat.

**The moat is granularity + TCB + provenance:**

- **Attenuated capabilities, not a coarse boundary** — authority is per-tool, per-path,
  per-call-budget, monotone-narrowing, instead of one VM/container wall. A Firecracker VM
  says "this whole box is isolated"; MC says "this agent may `read` under `/workspace`, call
  `grep` and `edit` but not `exec`, open no sockets, spend ≤ N tool calls, and every action
  is attributed."
- **Tiny, auditable TCB** — sandbox-as-language-guarantee (typed capabilities, linear
  `move`, opaque address classes), not sandbox-as-hypervisor.
- **Total, replayable provenance** — the kernel mediates every message and recognized
  authority use, so `agent → tool → file/net/resource action → result` is a structural audit
  trail, not bolted-on logging.

**Pitch:** *"This is not Linux. It's a capability microkernel that contains AI agents and
their tools, where every action is least-privilege by construction and fully attributable."*

---

## 2. The non-negotiable prerequisite (step 0)

> **The containment story is only as strong as the agent's own confinement.**

Today the "agent" (`kernel/core/agent.mc`) is **trusted MC code compiled into the kernel**
that voluntarily calls `agent_tool_call`. Containing a *cooperative* agent proves nothing —
a real adversarial agent would bypass the tool server and touch memory/FS/net directly.

So before any demo is credible, the agent must run as **genuinely untrusted code behind a
hard boundary**:

- short term: a **confined U-mode ELF** loaded into its own isolated Sv39 address space;
- target: **QuickJS-in-U-mode** (GC scripting for agent fluency; BearSSL is the C-linking
  precedent).

Both the confined-ELF spine and QuickJS-in-U-mode are now present in the RISC-V M-mode/QEMU
prototype. The remaining credibility work is to drive the full capability-tool surface from
that confined QuickJS agent and then carry the same path onto the S-mode/OpenSBI platform.

The agent must have **no ambient authority**: it cannot reach the FS, network, or other
agents except through capability-checked tool IPC. If it can, the boundary is theater.

---

## 3. Two more design lines in the sand

**Tool execution is a separate principal.** The spec already marks in-process tool handlers
as **MOCK / not a trust boundary**. The next architectural commitment: a tool call becomes
**IPC to a tool server** that runs as its own process with its own manifest and capabilities.
The agent holds only an endpoint + an allowlist; the server holds the real authority and
mediates every action against MC capabilities.

**Speak MCP, don't *run* MCP.** Make MC the **authority layer underneath** MCP-shaped tools,
not a host for arbitrary third-party MCP servers (which would drag opaque foreign runtimes
back inside the trust boundary). MC exposes **native, capability-checked tools** through an
**MCP-compatible descriptor + JSON-RPC façade** so MCP clients can drive them. MCP = the
compatibility layer; MC capabilities = the enforcement layer.

---

## 4. What exists vs what's missing

| Capability | Status (per kernel spec) |
|------------|--------------------------|
| Capability attenuation (rights ∩, masks) | **GATED** |
| IPC mediation, endpoint-generation safety | **GATED** |
| Resource quota + OOM-kill + fault containment | **GATED** (mechanism under explicit charge sites) |
| Provenance + cap audit | **GATED** (kcall allowed+denied; tool calls dispatched-only) |
| Service manifests (privileges-as-data) | **GATED** |
| Agent sandbox + tool-call ABI | **GATED**. Legacy `agent_tool_call` **MOCK** (in-process); confined-JS **FS** broker **REAL** on RISC-V/S-mode (`qjs-realtool-test`); net-fetch + out-of-process tool-server transport **pending** |
| Agent checkpoint/restore/migrate | **IMPLEMENTED** (fd-space + account) |
| Real DNS/TCP/HTTP/TLS | **GATED** (per-agent capability-gated egress now built — see `netcap` below) |
| **Hierarchical VFS / workspace paths** | **GATED** — `treefs` (`treefs-test`) |
| **Untrusted agent execution (confined U-mode ELF)** | **GATED** — `agent-confined-test` (QEMU): separate ELF in an isolated Sv39 space, kernel unmapped. |
| **QuickJS-in-U-mode** | **GATED** — `qjs-confined-test` / `qjs-agent-test` (QEMU): QuickJS runs as the confined U-mode ELF with a fixed host and pure JS ingress. |
| **Confined agent drives the capability stack** | **GATED** — `agent-confined-tool-test` (QEMU): the untrusted U-mode agent's only FS path is a syscall → capability front door; /workspace allowed, /etc denied |
| **Capability-checked FS tool server** | **GATED** — `fs_toolserver` (`fs-toolserver-test`); path-cap deny+audit+attribute |
| **Agent tool front door (allowlist + budget)** | **GATED** — `agent_fs` (`agent-fs-test`); audits denied attempts too |
| **Out-of-process tool server (IPC transport)** | **PARTIAL** — server logic + dispatch done; in-process call today, real IPC transport pending (M3-full) |
| **Capability-gated network egress** | **GATED** — `netcap` (`netcap-test`); default-deny, audited |
| **MCP-compatible tool façade** | **PARTIAL** — `mcp` (`mcp-test`): method name → capability-checked native tool mapping is gated; the JSON-RPC wire envelope + MCP descriptors (what a client actually speaks) are **not** built |
| **Policy daemon (consume audit → act)** | **PARTIAL** — `policy` (`policy-test`): the *decision* logic is gated; an external daemon that *actuates* (revoke/throttle/kill a running agent) is not wired (actuation = governance keystone) |
| **Native tool catalog breadth** (`grep/find/edit/exec/checkpoint`) | **ABSENT** — only `write/read/mkdir/list` implemented |

The kernel's core mechanism slices — capability checks, the audit ring, and the governance
*decision* logic — are **gated**. What remains is **integration and actuation**, not new
primitives: real out-of-process IPC transport (today's tool calls are in-process), policy
*actuation* (revoke/throttle/kill a running agent), the full M6 vectors under QEMU, and a real
demo. (See the table above: IPC transport, MCP wire, and policy actuation are all PARTIAL.)

---

## 5. Build sequence

### M1 — Walking skeleton (prove the whole loop, minimal surface)

One untrusted U-mode agent → one capability-checked FS tool server → a 2-level in-memory
VFS. Manifest restricts the agent to `/workspace`. The agent performs **one benign write**
inside `/workspace` and **one forbidden write** to `/etc`. Acceptance:

- benign write succeeds; forbidden write is **denied at the tool server** (capability check),
  **audited**, and **attributable** to the agent in the provenance trace;
- the agent has **no path** to the VFS except via tool IPC (verified: direct access doesn't
  compile / isn't reachable);
- gated on both backends under QEMU.

This is the entire thesis in miniature. Everything after is breadth.

### M2 — Hierarchical VFS

Directories, path resolution, `getdents`-style listing, cwd, workspace-rooted mounts. Start
as a single in-memory tree (no diskfs rewrite). This is the prerequisite the whole sandbox
needs (kernel spec §18 / roadmap).

### M3 — Native tool catalog (out-of-process)

`read · write · ls · grep · find · edit · exec · checkpoint`, each a capability-checked
operation in the FS/exec tool server, dispatched via `agent_tool_call` → IPC. `exec` runs a
*confined sub-agent* (Layer-2 ELF), not arbitrary host binaries.

### M4 — MCP-compatible façade

Expose the native tools as MCP tool descriptors over a JSON-RPC surface; map each MCP tool
invocation onto a capability-checked MC tool call. MCP clients see standard tools; MC enforces
authority.

### M5 — Policy plane MVP

A minimal external policy daemon that consumes the audit/provenance stream and issues
**pause / revoke / throttle / kill / checkpoint / deny** decisions. Kernel stays *mechanism*;
the daemon is the *controller* (vision § Policy plane). Per-agent **network egress** becomes
a capability the daemon can grant/deny/scope.

### M6 — The killer demo

> An AI coding agent works on an **untrusted repository**. The repo contains
> prompt-injection text trying to (a) read a secret outside the workspace, (b) write files
> outside the workspace, (c) open an unauthorized network connection, (d) exhaust memory.
> The agent still completes the **benign task**, while **every forbidden action is denied,
> audited, and attributable**, and the host is never destabilized.

---

## 6. Acceptance criteria for M6 (the bar)

For each adversarial vector, a **typed denial + audit record + attribution**, proven on both
backends under QEMU:

1. **Secret exfiltration** — agent holds no capability to the secret path; read denied. (A
   *capability* property — the agent never gets the cap — not compile-time `Secret` taint.)
2. **Workspace escape** — write to `/etc` (or any non-`/workspace` path) denied by the FS
   tool server's path capability.
3. **Unauthorized network** — egress denied because the agent holds no network capability;
   the net stack is unreachable except via a capability-checked tool.
4. **Memory exhaustion** — over-quota allocation fails closed; a runaway is OOM-killed and
   reclaimed while other agents survive (governance keystone, already gated).
5. **Tool-auth bypass** — calling an un-allowlisted tool id returns `Denied`; (hardening:
   denied tool attempts should also be audited — see kernel spec §15, currently dispatched-only).
6. **Benign task completes** — the agent's legitimate work succeeds throughout.

Every line of the demo output should be a `Result` (ok / typed error), and every forbidden
attempt should appear in the replayable `agent → tool → action → verdict` trace.

---

## 7. Explicit non-goals

Do **not** prioritize: x86_64/aarch64 full-kernel completeness, a full POSIX layer, broad
driver/hardware breadth, GUI, general filesystem compatibility, a package manager, or hosting
arbitrary foreign MCP servers/binaries. Linux owns that world; chasing it dilutes the one
story MC can win. Every feature must serve **agent confinement, communication, storage, or
bootstrapping** — the §1 thesis is the filter.

---

## 8. Sequencing summary

```
step 0  untrusted agent execution (U-mode ELF → QuickJS)   ← credibility gate
  M1    walking skeleton: 1 agent, 1 FS tool server, deny+audit+attribute
  M2    hierarchical VFS (workspace paths)
  M3    out-of-process native tool catalog (read/ls/grep/edit/exec/checkpoint)
  M4    MCP-compatible façade (speak MCP, enforce with MC caps)
  M5    policy plane MVP + capability-gated network egress
  M6    adversarial untrusted-repo demo
```

**First concrete code step:** the hierarchical VFS (M2) is the unblocker that M1's tool
server and everything above depend on — and step 0's confined-ELF loader is its parallel
prerequisite for credibility. Build those two, and the containment loop becomes
demonstrable.

---

## 9. Progress

The **enforcement substrate** is built and gated on both backends (emit-c + emit-llvm) — the
host-fixture layers via `llvm-host-suite-test`, the U-mode confinement pieces (items 6–7) via
their own QEMU gates — proving the containment thesis at the mechanism level. Delivered:

1. **M2 — hierarchical VFS** (`kernel/fs/treefs.mc`, `treefs-test`). Directories, absolute
   path resolution, `.`/`..` traversal with **no escape above the tree root**, `getdents`
   listing, typed errors. The unblocker.
2. **M1 (core) — capability-checked FS tool server** (`kernel/fs/fs_toolserver.mc`,
   `fs-toolserver-test`). `PathCap` (subtree root + rights + agent attribution); every op
   resolves a path, checks subtree containment **and** the right, and audits the verdict
   (allow **and** deny). Benign `/workspace` write succeeds; `/etc` write/read and `..`
   escapes are denied, audited, attributed. Attenuation only narrows. → acceptance **#2**,
   and the deny+audit+attribute shape of **#1/#5**.
3. **M3 (seed) — agent tool front door** (`kernel/fs/agent_fs.mc`, `agent-fs-test`). Tool
   **allowlist** + call **budget** in front of the path cap (three gates: allowlist → budget
   → path cap). Audits the **denied** attempts too (the hardening flagged in #5). The
   acceptance demo runs the M6 vectors this layer covers: benign task completes; secret read,
   workspace escape, un-allowlisted tool, budget exhaustion all denied+audited+attributed.
4. **M5 (seed) — policy plane** (`kernel/core/policy.mc`, `policy-test`). Drains the
   provenance ring the layers above emit into per-agent allow/deny counters; denial pressure
   escalates Allow → Throttle → Revoke → Kill. Decides only; actuation = the gated governance
   keystone. Closes the *provenance → controller* loop.
5. **M5 (egress) — capability-gated network egress** (`kernel/net/netcap.mc`, `netcap-test`).
   `NetCap` (default deny-all); audited allow/deny per destination; attenuation only narrows.
   → acceptance **#3**.

6. **step 0 — genuinely untrusted, confined execution** (`kernel/arch/riscv64/agent_confined_runtime.mc`
   + `tests/qemu/proc/agent_confined_demo.mc`, `agent-confined-test`). A separate ELF loaded
   into its OWN Sv39 address space — kernel **unmapped**, agent pages `PTE_U` — and run in
   U-mode under QEMU. The MMU, not goodwill, is the boundary: the agent can reach the kernel
   only by `ecall`. The credibility gate.
7. **step 0 + M1 — the confined agent drives the capability stack** (`agent-confined-tool-test`).
   The untrusted U-mode agent's only FS path is a `SYS_TOOL` syscall routed through the
   capability front door: its `/workspace` write is **allowed**, its `/etc` write **denied** at
   the path cap — and it has no mapping to bypass it. This is M1 with an adversarial-shaped
   agent, not a cooperative one.
8. **M4 (partial) — MCP-compatible façade** (`kernel/agent/mcp.mc`, `mcp-test`). The structured
   binding is done: MCP method names resolve to native capability-checked tools, so an MCP call
   can never exceed the agent's caps. NOT done: the JSON-RPC wire envelope and the MCP tool
   *descriptors* (input schemas) a real client speaks — those remain a thin adapter on top.
9. **M6 (shape) — capstone integration** (`tests/qemu/proc/agent_containment_demo.mc`,
   `agent-containment-test`). Composes every layer over a shared audit ring as a single
   scenario. It is the M6 *shape*, not the literal §5 demo (no real repo, no real coding task —
   the "injection" is hand-coded calls).

**Acceptance coverage.** §6 sets the bar as "proven on both backends **under QEMU**" with a
real confined agent. What is actually proven, and how:
- **#2 workspace escape** — proven **under QEMU** by a genuinely confined U-mode agent
  (`agent-confined-tool-test`): its `/etc` write is denied at the path cap, no bypass.
- **#1 secret exfil, #3 unauthorized network, #5 tool-auth bypass, #6 benign completes** —
  proven at the **mechanism level as host fixtures** (emit-c + emit-llvm), NOT yet under QEMU
  with a confined agent. So the *enforcement* is gated on both backends, but §6's literal
  "under QEMU, real agent" bar is met only for #2 so far.
- **#4 memory exhaustion** — the already-gated governance keystone (`agentos-test`/
  `contain-test`); not wired into the confined-agent demo.

**Remaining (the milestone is NOT finished):**
- **Full M6 vectors from QuickJS** — a pure-JS agent already drives the **real**
  capability-checked **FS** tool path (allow/deny/audit) from JS through
  `SYS_SUBMIT`/`SYS_POLL` into `agent_fs_call` under S-mode, gated in `m0`
  (`qjs-realtool-test` / `llvm-qjs-realtool-test`; `examples/agents/agent_fs.js`). Still
  pending *from the JS surface*: the **secret** path (#1), **network** denial/fetch (#3),
  **policy actuation**, and the **real-repo** M6 demo.
- **M3 (full) — out-of-process IPC** — move the tool server to a separate process behind real
  **IPC** (dispatch + checks already in the shape an IPC server uses; only the transport is
  in-process).
- **M3 — native tool catalog breadth** — `grep · find · edit · exec · checkpoint` are not
  built (only `write/read/mkdir/list`); `exec` running a confined sub-agent is not built.
- **M4 — JSON-RPC wire + MCP descriptors** — only the name→capability mapping exists.
- **M5 — policy actuation** — an external daemon that consumes the live stream and *acts*
  (revoke/throttle/kill a running agent); only the decision logic is built.
- **M6 — the literal demo** — a real coding agent on a real untrusted repo with real
  prompt-injection text; only the composed *shape* exists.
- **Acceptance under QEMU** — drive #1/#3/#5 (and ideally #4) through the confined U-mode agent
  under QEMU, not just as host fixtures.
