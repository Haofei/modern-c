// examples/apps/mathtest.c — a confined C app exercising the freestanding libm (user/libc/math)
// on real doubles. It proves the FPU is enabled for the app (mstatus.FS set by the kernel before
// enter_user) and that the EXACT math functions are bit-correct. Reports "math-ok" via SYS_WRITE.
// Phase 3 of the QuickJS-agent plan (the exact half of libm + hardware FP enablement).
#include "user/runtime/usys.h"
#include <stddef.h>

double fabs(double);
double floor(double);
double ceil(double);
double trunc(double);
double round(double);
double fmod(double, double);
double sqrt(double);
double copysign(double, double);
double scalbn(double, int);
int __signbit(double);
size_t strlen(const char *);

// Exact comparison: every case below has an exactly-representable double result.
static int eq(double a, double b) { return a == b; }

int main(void) {
    int ok = 1;
    ok &= eq(sqrt(16.0), 4.0);
    ok &= eq(sqrt(2.0) * sqrt(2.0), 2.0000000000000004); // fsqrt.d is correctly rounded
    ok &= eq(floor(3.7), 3.0);
    ok &= eq(floor(-3.2), -4.0);
    ok &= eq(ceil(3.2), 4.0);
    ok &= eq(ceil(-3.7), -3.0);
    ok &= eq(trunc(-3.7), -3.0);
    ok &= eq(trunc(3.7), 3.0);
    ok &= eq(round(2.5), 3.0);
    ok &= eq(round(-2.5), -3.0);
    ok &= eq(round(2.4), 2.0);
    ok &= eq(fabs(-5.5), 5.5);
    ok &= eq(fmod(10.0, 3.0), 1.0);
    ok &= eq(fmod(-7.0, 3.0), -1.0);
    ok &= eq(fmod(5.5, 2.0), 1.5);
    ok &= eq(copysign(3.0, -1.0), -3.0);
    ok &= (__signbit(-0.0) == 1);
    ok &= eq(scalbn(1.5, 3), 12.0); // 1.5 * 2^3

    if (ok) {
        const char m[] = "math-ok\n";
        sys_print(m, strlen(m));
        return 0;
    }
    const char m[] = "math-bad\n";
    sys_print(m, strlen(m));
    return 1;
}
