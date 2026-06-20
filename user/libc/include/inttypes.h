#ifndef _INTTYPES_H
#define _INTTYPES_H
#include <stdint.h>

/* LP64: int64_t is long. Use the "l" length modifier accordingly. */
#define PRId8  "d"
#define PRId16 "d"
#define PRId32 "d"
#define PRId64 "ld"
#define PRIi32 "i"
#define PRIi64 "li"
#define PRIu8  "u"
#define PRIu16 "u"
#define PRIu32 "u"
#define PRIu64 "lu"
#define PRIx32 "x"
#define PRIx64 "lx"
#define PRIX32 "X"
#define PRIX64 "lX"
#define PRIo64 "lo"

#define PRIdPTR "ld"
#define PRIuPTR "lu"
#define PRIxPTR "lx"

#define PRIdMAX "ld"
#define PRIuMAX "lu"
#define PRIxMAX "lx"

intmax_t  strtoimax(const char *, char **, int);
uintmax_t strtoumax(const char *, char **, int);

#endif /* _INTTYPES_H */
