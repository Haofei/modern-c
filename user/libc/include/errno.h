#ifndef _ERRNO_H
#define _ERRNO_H

/* A single-threaded errno (the agent runs one JS context). Defined in stubs.c. */
extern int errno;

#define EPERM    1
#define ENOENT   2
#define EINTR    4
#define EIO      5
#define EBADF    9
#define EAGAIN   11
#define ENOMEM   12
#define EACCES   13
#define EFAULT   14
#define EBUSY    16
#define EEXIST   17
#define ENODEV   19
#define ENOTDIR  20
#define EISDIR   21
#define EINVAL   22
#define ENFILE   23
#define EMFILE   24
#define ENOSPC   28
#define ESPIPE   29
#define EPIPE    32
#define ERANGE   34
#define ENOSYS   38
#define ENOTSUP  95
#define EOVERFLOW 75
#define ETIMEDOUT 110

#endif /* _ERRNO_H */
