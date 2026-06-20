/*
 * setjmp/longjmp for RISC-V 64-bit, lp64d ABI (rv64imafdc, hardware double FP).
 *
 * jmp_buf slot layout (each slot = 8 bytes / one doubleword):
 *
 *   offset  register        offset  register
 *   ------  --------        ------  --------
 *      0    ra                112    fs0
 *      8    sp                120    fs1
 *     16    s0                128    fs2
 *     24    s1                136    fs3
 *     32    s2                144    fs4
 *     40    s3                152    fs5
 *     48    s4                160    fs6
 *     56    s5                168    fs7
 *     64    s6                176    fs8
 *     72    s7                184    fs9
 *     80    s8                192    fs10
 *     88    s9                200    fs11
 *     96    s10
 *    104    s11
 *   total: 26 slots = 208 bytes
 *
 * env pointer is passed in a0 (first argument, lp64d).
 */

	.text

/* ---------------------------------------------------------------------- */
/* int setjmp(jmp_buf env)                                                */
/* ---------------------------------------------------------------------- */
	.global setjmp
	.type   setjmp,@function
setjmp:
	sd   ra,   0(a0)
	sd   sp,   8(a0)
	sd   s0,  16(a0)
	sd   s1,  24(a0)
	sd   s2,  32(a0)
	sd   s3,  40(a0)
	sd   s4,  48(a0)
	sd   s5,  56(a0)
	sd   s6,  64(a0)
	sd   s7,  72(a0)
	sd   s8,  80(a0)
	sd   s9,  88(a0)
	sd   s10, 96(a0)
	sd   s11,104(a0)

	fsd  fs0, 112(a0)
	fsd  fs1, 120(a0)
	fsd  fs2, 128(a0)
	fsd  fs3, 136(a0)
	fsd  fs4, 144(a0)
	fsd  fs5, 152(a0)
	fsd  fs6, 160(a0)
	fsd  fs7, 168(a0)
	fsd  fs8, 176(a0)
	fsd  fs9, 184(a0)
	fsd  fs10,192(a0)
	fsd  fs11,200(a0)

	li   a0, 0
	ret
	.size setjmp, .-setjmp

/* ---------------------------------------------------------------------- */
/* void longjmp(jmp_buf env, int val)                                     */
/* ---------------------------------------------------------------------- */
	.global longjmp
	.type   longjmp,@function
longjmp:
	ld   ra,   0(a0)
	ld   sp,   8(a0)        /* sp restored before ret */
	ld   s0,  16(a0)
	ld   s1,  24(a0)
	ld   s2,  32(a0)
	ld   s3,  40(a0)
	ld   s4,  48(a0)
	ld   s5,  56(a0)
	ld   s6,  64(a0)
	ld   s7,  72(a0)
	ld   s8,  80(a0)
	ld   s9,  88(a0)
	ld   s10, 96(a0)
	ld   s11,104(a0)

	fld  fs0, 112(a0)
	fld  fs1, 120(a0)
	fld  fs2, 128(a0)
	fld  fs3, 136(a0)
	fld  fs4, 144(a0)
	fld  fs5, 152(a0)
	fld  fs6, 160(a0)
	fld  fs7, 168(a0)
	fld  fs8, 176(a0)
	fld  fs9, 184(a0)
	fld  fs10,192(a0)
	fld  fs11,200(a0)

	/* return value: (val != 0 ? val : 1) */
	mv   a0, a1
	bnez a1, 1f
	li   a0, 1
1:
	ret                     /* jumps to restored ra = setjmp call site */
	.size longjmp, .-longjmp

	.section .note.GNU-stack,"",@progbits
