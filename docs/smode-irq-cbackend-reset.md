# C-backend S-mode async-IRQ "reset" — ROOT-CAUSED AND FIXED

Status: **resolved** (was the load-bearing blocker for the interrupt-driven I/O work in
`docs/production-readiness-plan.md` §4.1 / Phase P1 and the `s_trap_vector` rework in
`docs/platform-portability-plan.md` §12 item 5).

## What looked like a reset

A flat S-mode kernel (under real OpenSBI) that serviced an *async* S-mode interrupt in a
`#[naked]` trap vector and then resumed (re-armed the source, or preempted U-mode) appeared
to **reset-loop on the C backend** while the LLVM backend was clean: the boot banner
reprinted endlessly. It looked timing/codegen-sensitive — adding an SBI ecall at handler
entry "masked" it, and the single-shot PLIC proof passed while the re-armed one did not.

## Actual root cause (NOT a reset)

QEMU `-d int` showed OpenSBI booting **once** while our `s_entry` ran thousands of times,
re-arming and taking one `s_external` each loop — i.e. `sret` kept landing at the *wrong PC*.
The cause: the `#[naked]` `s_trap_vector` was placed on a **2-byte boundary**
(`0x….f6`), but a RISC-V `stvec`/`mtvec` base **must be 4-byte aligned** — the low two bits
of those CSRs are the **MODE** field. Writing a 2-byte-aligned address sets MODE=2
(reserved) and a base 2 bytes below the vector, so every trap entered mid-instruction and
garbled control flow back into `s_entry`. The LLVM backend happened to place the same naked
function 4-byte aligned (`0x….ac`), so it worked; the C backend (clang on the emit-c output)
placed it 2-byte aligned. Pure layout luck — which is why incidental code changes (an extra
ecall, single- vs multi-shot) flipped pass/fail.

Confirmed empirically: forcing 4-byte alignment on the vector makes the C backend pass; the
2-byte-aligned build is the only failing case.

## Fix

A language-level alignment guarantee (commit adds `#[align(N)]`):

- New `#[align(N)]` function attribute (N a power of two) → C `__attribute__((aligned(N)))`,
  LLVM `align N` on the `define`. Parser/AST/sema/both backends.
- **`#[naked]` defaults to 4-byte alignment** (entry/vector stubs whose address may go into
  `stvec`/`mtvec`), so every existing naked trap vector is now safe by construction; an
  explicit `#[align(N)]` with a larger N wins.

## Regression gate

`smode-plic-multishot-test` / `llvm-smode-plic-multishot-test` (in m0):
`tests/qemu/arch/smode_plic_multishot_demo.mc` re-arms the UART THRE source and takes **3
discrete** S-mode external interrupts (the steady-state trap→service→sret→re-trap path), and
the test asserts the vector is 4-byte aligned. Both backends pass. The single-shot
`smode-plic-test` and the existing `smode-timer-test` / `smode-user-test` remain green.

## Implication

The interrupt-driven S-mode device work (production plan §4.1 / Phase P1) and the preemptive
`s_trap_vector` rework (R1b/R2) are **no longer blocked** by a backend-specific reset — the
steady-state re-armed path is parity-clean. Any future naked vector inherits the 4-byte
alignment default; use explicit `#[align(N)]` where the intent should be visible.

## Pointers

- Attribute + default: `src/ast.zig`, `src/parser.zig`, `src/lower_c.zig`, `src/lower_llvm.zig`
  (`effectiveAlign`); spec `docs/spec/MC_0.7_Final_Design.md` (`#[align(N)]`).
- Gate: `tests/qemu/arch/smode_plic_multishot_demo.mc`, `tools/arch/smode-plic-multishot-test.sh`.
- Roadmap context: `docs/platform-portability-plan.md` §12 item 5.
