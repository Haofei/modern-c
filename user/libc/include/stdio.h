#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <stdarg.h>

#define EOF (-1)
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif
#define BUFSIZ 1024

/* Opaque stream type. The freestanding port routes everything to the console
 * via sys_write; FILE is never dereferenced by our stdio. */
typedef struct _FILE FILE;
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

int   printf(const char *fmt, ...);
int   fprintf(FILE *stream, const char *fmt, ...);
int   sprintf(char *buf, const char *fmt, ...);
int   snprintf(char *buf, size_t size, const char *fmt, ...);
int   vprintf(const char *fmt, va_list ap);
int   vfprintf(FILE *stream, const char *fmt, va_list ap);
int   vsprintf(char *buf, const char *fmt, va_list ap);
int   vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);

int   fputc(int c, FILE *stream);
int   fputs(const char *s, FILE *stream);
int   putc(int c, FILE *stream);
int   putchar(int c);
int   puts(const char *s);
int   getc(FILE *stream);
int   getchar(void);
int   fgetc(FILE *stream);
char *fgets(char *s, int size, FILE *stream);

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);

FILE *fopen(const char *path, const char *mode);
FILE *fdopen(int fd, const char *mode);
int   fclose(FILE *stream);
int   fflush(FILE *stream);
int   fseek(FILE *stream, long offset, int whence);
long  ftell(FILE *stream);
void  rewind(FILE *stream);
int   feof(FILE *stream);
int   ferror(FILE *stream);
int   fileno(FILE *stream);
void  setbuf(FILE *stream, char *buf);

#endif /* _STDIO_H */
