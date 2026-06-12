// Freestanding support routines needed by LLVM-lowered MC kernel objects.
// The C backend emits trap helpers in its generated prelude; LLVM emits
// external calls so bare-metal kernel links must provide them explicitly.
typedef unsigned long long u64;

__attribute__((noreturn)) static void mc_halt(void) {
    __builtin_trap();
    for (;;) {}
}

void mc_trap_Assert(void) { mc_halt(); }
void mc_trap_Bounds(void) { mc_halt(); }
void mc_trap_DivideByZero(void) { mc_halt(); }
void mc_trap_IntegerOverflow(void) { mc_halt(); }
void mc_trap_InvalidRepresentation(void) { mc_halt(); }
void mc_trap_InvalidShift(void) { mc_halt(); }
void mc_trap_NullUnwrap(void) { mc_halt(); }
void mc_trap_Unreachable(void) { mc_halt(); }

u64 __muldi3(u64 a, u64 b) {
    u64 result = 0;
    while (b != 0) {
        if ((b & 1) != 0) {
            result += a;
        }
        a <<= 1;
        b >>= 1;
    }
    return result;
}

static u64 udivmoddi4(u64 n, u64 d, u64 *rem) {
    if (d == 0) {
        mc_trap_DivideByZero();
    }

    u64 q = 0;
    u64 r = 0;
    int i = 63;
    while (i >= 0) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= ((u64)1 << i);
        }
        i -= 1;
    }
    if (rem != 0) {
        *rem = r;
    }
    return q;
}

u64 __udivdi3(u64 n, u64 d) {
    return udivmoddi4(n, d, 0);
}

u64 __umoddi3(u64 n, u64 d) {
    u64 r = 0;
    (void)udivmoddi4(n, d, &r);
    return r;
}
