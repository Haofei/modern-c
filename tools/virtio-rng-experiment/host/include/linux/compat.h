#ifndef VRNG_HOST_LINUX_COMPAT_H
#define VRNG_HOST_LINUX_COMPAT_H

#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef uint8_t u8;
typedef int32_t s32;
typedef uint32_t u32;
typedef uint64_t u64;

#define __aligned(value) __attribute__((aligned(value)))
#define static_assert(condition, ...) _Static_assert(condition, "" __VA_ARGS__)
#define U64_MAX UINT64_MAX
#define min(left, right) ((left) < (right) ? (left) : (right))
#define array_index_nospec(index, size) ((index) < (size) ? (index) : 0U)
#define check_add_overflow(left, right, result) \
	__builtin_add_overflow((left), (right), (result))
#define check_sub_overflow(left, right, result) \
	__builtin_sub_overflow((left), (right), (result))

#endif
