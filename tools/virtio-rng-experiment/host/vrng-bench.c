// SPDX-License-Identifier: GPL-2.0-or-later

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "vrng_core_abi.h"

#define BENCH_CAPACITY 256U
#define BENCH_COPY 64U
#define BENCH_SAMPLES 15U
#define BENCH_ITERATIONS 250000U

struct bench_ops {
	const char *name;
	int (*init)(struct vrng_core_state *, u32, u64);
	int (*begin_submit)(struct vrng_core_state *, u64 *);
	int (*abort_submit)(struct vrng_core_state *, u64);
	int (*complete)(struct vrng_core_state *, u64, u32, u32 *);
	int (*copy)(struct vrng_core_state *, const u8 *, u8 *, u32, u32 *, u32 *);
	int (*validate)(const struct vrng_core_state *);
};

static const struct bench_ops candidates[] = {
	{ "c", vrng_core_c_init, vrng_core_c_begin_submit,
	  vrng_core_c_abort_submit, vrng_core_c_complete, vrng_core_c_copy,
	  vrng_core_c_validate },
	{ "rust", vrng_core_rust_init, vrng_core_rust_begin_submit,
	  vrng_core_rust_abort_submit, vrng_core_rust_complete,
	  vrng_core_rust_copy, vrng_core_rust_validate },
	{ "mc", vrng_core_mc_init, vrng_core_mc_begin_submit,
	  vrng_core_mc_abort_submit, vrng_core_mc_complete, vrng_core_mc_copy,
	  vrng_core_mc_validate },
};

static uint64_t now_ns(void)
{
	struct timespec value;

	clock_gettime(CLOCK_MONOTONIC, &value);
	return (uint64_t)value.tv_sec * UINT64_C(1000000000) + value.tv_nsec;
}

static uint64_t bench_validate(const struct bench_ops *ops, uint64_t *checksum)
{
	struct vrng_core_state state = {};
	uint64_t start;
	u32 index;

	ops->init(&state, BENCH_CAPACITY, 1);
	start = now_ns();
	for (index = 0; index < BENCH_ITERATIONS; index++)
		*checksum += (uint64_t)ops->validate(&state);
	return now_ns() - start;
}

static uint64_t bench_transition(const struct bench_ops *ops, uint64_t *checksum)
{
	struct vrng_core_state state = {};
	uint64_t generation, start;
	u32 index;

	ops->init(&state, BENCH_CAPACITY, 1);
	start = now_ns();
	for (index = 0; index < BENCH_ITERATIONS; index++) {
		*checksum += (uint64_t)ops->begin_submit(&state, &generation);
		*checksum += (uint64_t)ops->abort_submit(&state, generation);
	}
	return now_ns() - start;
}

static uint64_t bench_cycle(const struct bench_ops *ops, uint64_t *checksum)
{
	struct vrng_core_state state = {};
	u8 dma[BENCH_CAPACITY], destination[BENCH_COPY];
	uint64_t generation, start;
	u32 copied, index, need_resubmit;

	memset(dma, 0x5a, sizeof(dma));
	ops->init(&state, BENCH_CAPACITY, 1);
	start = now_ns();
	for (index = 0; index < BENCH_ITERATIONS; index++) {
		ops->begin_submit(&state, &generation);
		ops->complete(&state, generation, BENCH_COPY, &need_resubmit);
		ops->copy(&state, dma, destination, BENCH_COPY, &copied,
			  &need_resubmit);
		*checksum += destination[index % BENCH_COPY] + copied +
			     need_resubmit;
	}
	return now_ns() - start;
}

int main(void)
{
	uint64_t checksum = 0, elapsed;
	u32 candidate, sample;

	puts("sample,language,benchmark,iterations,total_ns,ns_per_operation");
	for (candidate = 0; candidate < sizeof(candidates) / sizeof(candidates[0]);
	     candidate++) {
		const struct bench_ops *ops = &candidates[candidate];

		bench_validate(ops, &checksum);
		bench_transition(ops, &checksum);
		bench_cycle(ops, &checksum);
		for (sample = 0; sample < BENCH_SAMPLES; sample++) {
			elapsed = bench_validate(ops, &checksum);
			printf("%u,%s,validate,%u,%" PRIu64 ",%.3f\n", sample,
			       ops->name, BENCH_ITERATIONS, elapsed,
			       (double)elapsed / BENCH_ITERATIONS);
			elapsed = bench_transition(ops, &checksum);
			printf("%u,%s,submit_abort,%u,%" PRIu64 ",%.3f\n", sample,
			       ops->name, BENCH_ITERATIONS, elapsed,
			       (double)elapsed / BENCH_ITERATIONS);
			elapsed = bench_cycle(ops, &checksum);
			printf("%u,%s,copy_cycle_64,%u,%" PRIu64 ",%.3f\n", sample,
			       ops->name, BENCH_ITERATIONS, elapsed,
			       (double)elapsed / BENCH_ITERATIONS);
		}
	}
	fprintf(stderr, "checksum=%" PRIu64 "\n", checksum);
	return 0;
}
