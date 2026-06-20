#ifndef _SETJMP_H
#define _SETJMP_H

/*
 * setjmp/longjmp for RISC-V 64-bit, lp64d ABI (hardware double float).
 *
 * jmp_buf holds all callee-saved state that must survive a longjmp:
 *   ra (1) + sp (1) + s0-s11 (12) + fs0-fs11 (12) = 26 doubleword slots.
 * `unsigned long` is 8 bytes on lp64d, which also guarantees 8-byte alignment.
 */

typedef unsigned long jmp_buf[26];

__attribute__((returns_twice))
int setjmp(jmp_buf env);

__attribute__((noreturn))
void longjmp(jmp_buf env, int val);

#endif /* _SETJMP_H */
