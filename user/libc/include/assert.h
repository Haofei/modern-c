#ifndef _ASSERT_H
#define _ASSERT_H

/* assert: on failure, report and abort. __assert_fail is in stubs.c. */
__attribute__((noreturn))
void __assert_fail(const char *expr, const char *file, int line, const char *func);

#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : __assert_fail(#e, __FILE__, __LINE__, __func__))
#endif

#endif /* _ASSERT_H */
