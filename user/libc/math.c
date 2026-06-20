// user/libc/math — the EXACT (bit-precise) half of a freestanding libm: sign/classification,
// integral rounding, fmod, and hardware sqrt. These are computed exactly (bit manipulation on
// the IEEE-754 double, and the riscv fsqrt.d instruction), not approximated — no accuracy
// hack. Phase 3 of the QuickJS-agent plan.
//
// The TRANSCENDENTALS QuickJS's Math also needs (pow/exp/log/log2/log10/sin/cos/tan/asin/
// acos/atan/atan2/hypot/cbrt/sinh/cosh/tanh/...) are deliberately NOT here: a correct
// implementation is a vendored libm (openlibm), which is the remaining Phase-3 work. This file
// is the part that can be made exact by hand.
#include <stdint.h>

typedef union {
    double d;
    uint64_t u;
} du;

#define EXP_MASK 0x7FF0000000000000ULL
#define SIGN_MASK 0x8000000000000000ULL
#define MANT_MASK 0x000FFFFFFFFFFFFFULL

int __isnan(double x) {
    du v = {x};
    return ((v.u & EXP_MASK) == EXP_MASK) && ((v.u & MANT_MASK) != 0);
}
int __isinf(double x) {
    du v = {x};
    return ((v.u & EXP_MASK) == EXP_MASK) && ((v.u & MANT_MASK) == 0);
}
int __isfinite(double x) {
    du v = {x};
    return (v.u & EXP_MASK) != EXP_MASK;
}
int __signbit(double x) {
    du v = {x};
    return (int)(v.u >> 63);
}

double fabs(double x) {
    du v = {x};
    v.u &= ~SIGN_MASK;
    return v.d;
}

double copysign(double x, double y) {
    du vx = {x};
    du vy = {y};
    vx.u = (vx.u & ~SIGN_MASK) | (vy.u & SIGN_MASK);
    return vx.d;
}

// Truncate toward zero: clear the fractional bits below the binary point implied by the
// exponent. Exact, branch-light, handles all magnitudes/NaN/Inf.
double trunc(double x) {
    du v = {x};
    int e = (int)((v.u >> 52) & 0x7FF) - 1023; // unbiased exponent
    if (e < 0) {
        // |x| < 1: result is +/-0 (keep sign), unless NaN/Inf (e<0 can't be those).
        v.u &= SIGN_MASK;
        return v.d;
    }
    if (e >= 52) {
        return x; // already integral (or NaN/Inf)
    }
    uint64_t frac = MANT_MASK >> e; // fractional mantissa bits
    if ((v.u & frac) == 0) {
        return x; // already integral
    }
    v.u &= ~frac;
    return v.d;
}

double floor(double x) {
    double t = trunc(x);
    if (t > x) {
        return t - 1.0; // x was negative non-integer: trunc rounded toward zero (up)
    }
    return t;
}

double ceil(double x) {
    double t = trunc(x);
    if (t < x) {
        return t + 1.0;
    }
    return t;
}

// Round half away from zero (C round()).
double round(double x) {
    double t = trunc(x);
    double frac = x - t;
    if (frac >= 0.5) {
        return t + 1.0;
    }
    if (frac <= -0.5) {
        return t - 1.0;
    }
    return t;
}

// x - n*y for the integral n making the result have |.| < |y|, same sign as x. Exact.
double fmod(double x, double y) {
    if (__isnan(x) || __isnan(y) || __isinf(x) || y == 0.0) {
        du nan = {0x7FF8000000000000ULL};
        return nan.d;
    }
    if (__isinf(y) || x == 0.0) {
        return x;
    }
    double ax = fabs(x);
    double ay = fabs(y);
    if (ax < ay) {
        return x;
    }
    // Repeated scaled subtraction (binary long division on the magnitudes). Bounded by the
    // exponent difference, so it terminates; each step is exact.
    double r = ax;
    for (int guard = 0; guard < 4096 && r >= ay; guard++) {
        double scaled = ay;
        // double `scaled` while it still fits under r, then subtract once.
        while (scaled + scaled <= r) {
            scaled = scaled + scaled;
        }
        r = r - scaled;
    }
    return __signbit(x) ? -r : r;
}

// Hardware double sqrt (exact, correctly-rounded by the FPU).
double sqrt(double x) {
    double r;
    __asm__("fsqrt.d %0, %1" : "=f"(r) : "f"(x));
    return r;
}

// scalbn(x, n) = x * 2^n, exact for in-range results (used by many libm paths).
double scalbn(double x, int n) {
    double r = x;
    // Multiply by 2 in steps of at most +/-1023 to stay in normal range; bounded loop.
    while (n > 0) {
        int step = n > 1023 ? 1023 : n;
        du f = {0};
        f.u = (uint64_t)(step + 1023) << 52; // 2^step
        r = r * f.d;
        n -= step;
    }
    while (n < 0) {
        int step = n < -1022 ? -1022 : n;
        du f = {0};
        f.u = (uint64_t)(step + 1023) << 52; // 2^step
        r = r * f.d;
        n -= step;
    }
    return r;
}

double ldexp(double x, int n) {
    return scalbn(x, n);
}
