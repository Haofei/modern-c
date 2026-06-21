// user/runtime/fenv_aarch64_stub.c — minimal freestanding fenv for the confined AArch64 QuickJS
// agent.
//
// On AArch64, openlibm's fenv ops (openlibm_fenv_aarch64.h) are all INLINE (they manipulate FPCR/
// FPSR directly), exactly like RISC-V — so unlike amd64 there are no out-of-line fenv FUNCTION
// bodies to provide. The header does declare ONE external symbol though:
//     extern const fenv_t __fe_dfl_env;
// the "default FP environment" used by fesetenv(FE_DFL_ENV)/feupdateenv. It is reached only by
// lrint/llrint/rint-family helpers, which JS Math does not depend on for CORRECT RESULTS. An
// all-zero FPCR/FPSR is precisely "round-to-nearest, all exceptions masked, no sticky flags",
// the boot default, so a zero-initialized definition is the correct default environment.
//
// fenv_t on aarch64 is { __uint32_t __fpcr; __uint32_t __fpsr; } (8 bytes); we mirror it with a
// small opaque buffer so the symbol's size/alignment are ample regardless of header revision.
#include <stdint.h>

typedef struct {
    uint8_t opaque[16];
} mc_fenv_t;

// The default FP environment: all-zero == round-nearest, masked, no sticky exceptions.
const mc_fenv_t __fe_dfl_env;
