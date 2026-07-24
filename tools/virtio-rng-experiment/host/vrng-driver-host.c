// SPDX-License-Identifier: GPL-2.0-or-later
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vrng_driver_abi.h"

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define MAX_REACHABLE_STATES 128

struct candidate {
	const char *name;
	int (*step)(struct vrng_driver_state *, uint32_t, uint32_t,
		    struct vrng_driver_outcome *);
};

struct event {
	uint32_t kind;
	uint32_t value;
};

static const struct candidate candidates[] = {
	{ "c", vrng_driver_c_step },
	{ "rust-raw", vrng_driver_rust_raw_step },
	{ "rust-safe", vrng_driver_rust_safe_step },
	{ "mc-raw", vrng_driver_mc_raw_step },
	{ "mc-contract", vrng_driver_mc_contract_step },
};

static const struct event events[] = {
	{ VRNG_DRIVER_REGISTER, 0 },
	{ VRNG_DRIVER_REGISTER, 1 },
	{ VRNG_DRIVER_CALLBACK_COMPLETE, 0 },
	{ VRNG_DRIVER_CALLBACK_COMPLETE, 8 },
	{ VRNG_DRIVER_CALLBACK_COMPLETE, 32 },
	{ VRNG_DRIVER_PUBLISH, 0 },
	{ VRNG_DRIVER_BEGIN_REMOVE, 0 },
	{ VRNG_DRIVER_DRAIN, 0 },
	{ VRNG_DRIVER_FINAL_CLEAR, 0 },
	{ VRNG_DRIVER_FINISH_REMOVE, 0 },
};

static bool inject_c_final_clear;
static unsigned long comparisons;

static void fail(const char *candidate, const char *field, uint32_t event,
		 uint32_t value, int expected, int actual)
{
	fprintf(stderr,
		"driver lifecycle mismatch: candidate=%s field=%s event=%u value=%u expected=%d actual=%d\n",
		candidate, field, event, value, expected, actual);
	exit(2);
}

static void compare_step(const struct vrng_driver_state *input,
			 const struct event *event,
			 struct vrng_driver_state *next)
{
	struct vrng_driver_outcome expected_out = {};
	struct vrng_driver_state expected = *input;
	size_t i;
	int expected_result;

	expected_result = vrng_driver_spec_step(&expected, event->kind,
						event->value, &expected_out);
	for (i = 0; i < ARRAY_SIZE(candidates); i++) {
		struct vrng_driver_outcome actual_out = {};
		struct vrng_driver_state actual = *input;
		int actual_result;

		actual_result = candidates[i].step(&actual, event->kind,
						   event->value, &actual_out);
		if (inject_c_final_clear && i == 0 &&
		    event->kind == VRNG_DRIVER_FINAL_CLEAR)
			actual_result = actual_result ? actual_result : -1;
		comparisons++;
		if (actual_result != expected_result)
			fail(candidates[i].name, "result", event->kind,
			     event->value, expected_result, actual_result);
		if (memcmp(&actual_out, &expected_out, sizeof(expected_out)))
			fail(candidates[i].name, "outcome", event->kind,
			     event->value, 0, 1);
		if (memcmp(&actual, &expected, sizeof(expected)))
			fail(candidates[i].name, "state", event->kind,
			     event->value, 0, 1);
	}
	*next = expected;
}

static bool contains(const struct vrng_driver_state *states, size_t count,
		     const struct vrng_driver_state *candidate)
{
	size_t i;

	for (i = 0; i < count; i++)
		if (!memcmp(&states[i], candidate, sizeof(*candidate)))
			return true;
	return false;
}

int main(int argc, char **argv)
{
	struct vrng_driver_outcome ignored = {};
	struct vrng_driver_state states[MAX_REACHABLE_STATES] = {};
	size_t count = 1;
	size_t cursor;

	if (argc == 2 && !strcmp(argv[1], "--inject=c:final-clear"))
		inject_c_final_clear = true;
	else if (argc != 1) {
		fprintf(stderr, "usage: %s [--inject=c:final-clear]\n", argv[0]);
		return 64;
	}
	if (vrng_driver_spec_step(&states[0], VRNG_DRIVER_INIT, 0, &ignored))
		return 1;

	for (cursor = 0; cursor < count; cursor++) {
		size_t event_index;

		for (event_index = 0; event_index < ARRAY_SIZE(events);
		     event_index++) {
			struct vrng_driver_state next;

			compare_step(&states[cursor], &events[event_index],
				     &next);
			if (!contains(states, count, &next)) {
				if (count == ARRAY_SIZE(states)) {
					fprintf(stderr,
						"reachable-state capacity exceeded\n");
					return 1;
				}
				states[count++] = next;
			}
		}
	}

	printf("driver lifecycle differential passed: states=%zu comparisons=%lu candidates=%zu\n",
	       count, comparisons, ARRAY_SIZE(candidates));
	return 0;
}
