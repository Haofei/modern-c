# Remediation report for review baseline 77121c5e

Baseline: `77121c5edf69154d258f2865570fae07c55a8332`

This follow-up closes the directly actionable MC-only defects from the review while
keeping larger architecture work explicitly scoped as follow-up work.

## Closed in this change

- `kernel/fs/agent_fs.mc`: denial audit no longer computes
  `FD_TOOL_TAG_BIAS + tool_id`. The event uses a stable deny tag and stores the raw
  untrusted tool id in the event payload field, so extreme ids such as
  `0xffff_ffff` deny and audit without checked-overflow traps.
- `kernel/core/policy.mc`: policy counters now saturate instead of trapping after
  long-running traffic. After table overflow, an untracked subject no longer
  receives nominal `Allow`; `policy_decide` fails closed to `Throttle`. Invalid
  escalation thresholds are detected and legacy `policy_init` callers receive a
  conservative one-denial profile with overflow marked.
- `src/sema.zig`: ordinary inline assembly is treated as fallthrough for missing
  return analysis. Backends already emit normal asm statements and continue, so
  semantic return checking now matches backend control flow.
- `kernel/core/agent.mc`: tool registry construction rejects duplicate tool ids.
  Generic agent tool calls now audit denied, exhausted, and unregistered requests
  as denial events, not only dispatched calls.
- `kernel/agent/mcp.mc`: MCP catalog construction rejects duplicate method names
  to avoid silent shadowing.
- `kernel/core/ipc_trace.mc`: `next_seq` and `dropped` counters use saturating
  increments so tracing remains total at long uptime boundaries.
- `tools/lsp/mc-lsp.py`: compiler subprocess stdout/stderr are read through a
  bounded runner governed by `MC_LSP_MAX_COMPILER_OUTPUT_BYTES`; output floods are
  terminated without accumulating unbounded memory.
- Toolchain shell wrappers: `mcc-build.sh` now resolves PATH commands correctly,
  and `mcc-cc.sh -o` reports a stable usage error when the output path is missing.

## Regression coverage added or updated

- `tests/qemu/fs/agent_fs_demo.mc`: verifies front-door denial audit schema and
  the `0xffff_ffff` tool-id overflow case.
- `tests/qemu/proc/policy_demo.mc`: verifies table-overflow fail-closed behavior
  and invalid-threshold conservative initialization.
- `tests/spec/return_types.mc`: verifies a non-void function ending in ordinary
  asm still reports `E_RETURN_MISSING`.
- `tests/qemu/proc/agent_demo.mc`: verifies duplicate tool ids and full verdict
  audit records.
- `tests/qemu/proc/agent_e2e_demo.mc`: updates the end-to-end agent audit
  transcript to include denied/exhausted verdicts.
- `tests/qemu/proc/mcp_demo.mc`: verifies duplicate MCP method registration is
  rejected.
- `tools/lsp/lsp-test.py`: verifies compiler output-limit failure does not
  publish stale diagnostics and the server remains responsive.

## Still intentionally open

The following review items require larger design work and are not represented as
closed by this patch:

- Request-rate budgets separate from dispatch budgets for every future tool
  transport.
- A concurrent, per-CPU or MPSC audit publication model with durable security
  event retention.
- A full `CompilerSession`/query architecture that removes all compiler
  process-global mutable state.
- A single typed semantic authority (`Typed HIR`/`SemanticDb`/verified MIR) that
  removes backend-local semantic inference.
- Replacing textual import flattening with stable module identity, interface
  hashes, and separate/incremental compilation.
- Binding cryptographic bundle verification to immutable exact bytes consumed by
  the production loader.

Those are tracked as architecture follow-ups rather than claimed as fixed by
local hardening patches.
