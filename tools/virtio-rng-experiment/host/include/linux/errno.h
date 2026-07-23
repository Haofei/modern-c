#ifndef VRNG_HOST_LINUX_ERRNO_H
#define VRNG_HOST_LINUX_ERRNO_H

#include <linux/compat.h>

/* The executable ABI uses Linux errno numbers even when the host runner is
 * built on another Unix.  libc errno values are not portable (notably
 * EALREADY, ENODATA, EOVERFLOW, and ESTALE on Darwin).
 */
#undef EAGAIN
#undef ENOMEM
#undef EBUSY
#undef EEXIST
#undef EINVAL
#undef ENODEV
#undef ENODATA
#undef EOVERFLOW
#undef EALREADY
#undef ESTALE
#undef EPROTO
#define EAGAIN 11
#define ENOMEM 12
#define EBUSY 16
#define EEXIST 17
#define ENODEV 19
#define EINVAL 22
#define ENODATA 61
#define EOVERFLOW 75
#define EPROTO 71
#define EALREADY 114
#define ESTALE 116

#endif
