// examples/apps/transcendental.c — a confined C app exercising the vendored openlibm
// transcendentals (pow/exp/log/sin/cos/tan/atan2/cbrt/hypot/...) on real doubles. This is the
// full libm QuickJS's Math needs; it proves the openlibm freestanding build links and runs
// confined under hardware FP. Reports "trig-ok" via SYS_WRITE. Phase 3 of the QuickJS plan.
#include "user/runtime/usys.h"
#include <stddef.h>

double pow(double, double);
double exp(double);
double log(double);
double log2(double);
double log10(double);
double sin(double);
double cos(double);
double tan(double);
double atan2(double, double);
double cbrt(double);
double hypot(double, double);
double fabs(double);
size_t strlen(const char *);

// Transcendentals are correctly rounded but not bit-predictable across the board; compare with
// a small absolute tolerance. The exactly-representable cases (pow(2,10), hypot(3,4)) are exact.
static int near(double a, double b) {
    double d = a - b;
    if (d < 0) d = -d;
    return d < 1e-9;
}

int main(void) {
    int ok = 1;
    ok &= (pow(2.0, 10.0) == 1024.0); // exact
    ok &= near(exp(0.0), 1.0);
    ok &= near(log(1.0), 0.0);
    ok &= near(exp(log(5.0)), 5.0);
    ok &= near(log2(8.0), 3.0);
    ok &= near(log10(1000.0), 3.0);
    ok &= near(sin(0.0), 0.0);
    ok &= near(cos(0.0), 1.0);
    ok &= near(sin(1.5707963267948966), 1.0); // sin(pi/2)
    ok &= near(tan(0.0), 0.0);
    ok &= near(4.0 * atan2(1.0, 1.0), 3.141592653589793); // 4*atan(1) = pi
    ok &= near(cbrt(27.0), 3.0);
    ok &= (hypot(3.0, 4.0) == 5.0); // exact
    ok &= near(pow(2.0, 0.5) * pow(2.0, 0.5), 2.0);

    if (ok) {
        const char m[] = "trig-ok\n";
        sys_print(m, strlen(m));
        return 0;
    }
    const char m[] = "trig-bad\n";
    sys_print(m, strlen(m));
    return 1;
}
