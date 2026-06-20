#ifndef _STDLIB_H
#define _STDLIB_H
#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff

/* alloca: stack allocation via the compiler builtin (QuickJS uses it without <alloca.h>). */
#define alloca(n) __builtin_alloca(n)

void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);
void *aligned_alloc(size_t alignment, size_t size);

__attribute__((noreturn)) void abort(void);
__attribute__((noreturn)) void exit(int status);
int atexit(void (*fn)(void));

int   abs(int);
long  labs(long);
long long llabs(long long);

long               strtol(const char *, char **, int);
unsigned long      strtoul(const char *, char **, int);
long long          strtoll(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);
double             strtod(const char *, char **);
float              strtof(const char *, char **);
int                atoi(const char *);
long               atol(const char *);
double             atof(const char *);

void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compar)(const void *, const void *));

char *getenv(const char *name);

int  rand(void);
void srand(unsigned int seed);

#endif /* _STDLIB_H */
