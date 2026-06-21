// user/runtime/fenv_amd64_stub.c — minimal freestanding fenv for the confined x86-64 QuickJS
// agent.
//
// The vendored openlibm (third_party/openlibm) was imported riscv-first: on riscv its fenv ops
// are inline (no FPU exception state), so nothing references out-of-line fenv symbols. On amd64
// openlibm_fenv_amd64.h declares a few fenv ops OUT OF LINE (feholdexcept / feupdateenv /
// feraiseexcept / fegetenv / __fe_dfl_env), whose bodies live in an amd64/fenv.c that was NOT
// vendored. They are reached only by lrint/llrint/rint-family routines, which JS Math does not
// depend on for CORRECT RESULTS — they touch the FP rounding/exception environment, which the
// confined agent neither inspects nor relies on.
//
// So provide do-nothing stubs that manipulate the real SSE control/status word just enough to be
// well-formed: feraiseexcept sets MXCSR exception flags, feholdexcept/feupdateenv save/restore
// MXCSR (the SSE unit is the one ring-3 QuickJS uses; the x87 unit is left at its default). No FP
// trap is ever enabled (boot.S masks all SSE exceptions), so these never change observed results.
#include <stdint.h>

// fenv_t mirrors openlibm_fenv_amd64.h: { __x87 (control,status,tag,others...) ; __mxcsr }.
// We only ever touch __mxcsr, but the struct must be large enough that fegetenv/fesetenv on a
// caller-provided fenv_t* stay in bounds. openlibm's amd64 fenv_t is 28 bytes; round up.
typedef struct {
    uint8_t opaque[32];
} mc_fenv_t;

const mc_fenv_t __fe_dfl_env; // default environment (all-zero is a fine "masked, round-nearest")

static inline uint32_t get_mxcsr(void) {
    uint32_t v;
    __asm__ volatile("stmxcsr %0" : "=m"(v));
    return v;
}
static inline void set_mxcsr(uint32_t v) {
    __asm__ volatile("ldmxcsr %0" : : "m"(v));
}

// The SSE exception flag bits live in MXCSR bits 0..5.
#define MC_SSE_EXCEPT_MASK 0x3F

int feraiseexcept(int excepts) {
    uint32_t m = get_mxcsr();
    m |= ((uint32_t)excepts & MC_SSE_EXCEPT_MASK);
    set_mxcsr(m);
    return 0;
}

int fegetenv(mc_fenv_t *envp) {
    uint32_t m = get_mxcsr();
    // Stash the MXCSR at the tail of the struct (where openlibm's amd64 layout keeps it); we
    // only need round-trip fidelity for our own feupdateenv/feholdexcept, not bit-for-bit ABI.
    uint32_t *slot = (uint32_t *)(void *)&envp->opaque[24];
    *slot = m;
    return 0;
}

int feholdexcept(mc_fenv_t *envp) {
    fegetenv(envp);
    // Clear the sticky exception flags, leave all exceptions masked (the boot default).
    uint32_t m = get_mxcsr();
    m &= ~(uint32_t)MC_SSE_EXCEPT_MASK;
    set_mxcsr(m);
    return 0;
}

int feupdateenv(const mc_fenv_t *envp) {
    uint32_t pending = get_mxcsr() & MC_SSE_EXCEPT_MASK;
    const uint32_t *slot = (const uint32_t *)(const void *)&envp->opaque[24];
    uint32_t restored = *slot;
    set_mxcsr(restored | pending);
    return 0;
}
