// SPDX-License-Identifier: GPL-2.0-or-later

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "vrng_core_spec.h"

#define HOST_BUFFER_SIZE 256U
#define HOST_MAX_STATES 1024U
#define HOST_MAX_DEPTH 7U
#define HOST_MAX_EVENTS (HOST_MAX_DEPTH + 1U)

struct vrng_host_ops {
	const char *name;
	int (*init)(struct vrng_core_state *, u32, u64);
	int (*begin_submit)(struct vrng_core_state *, u64 *);
	int (*abort_submit)(struct vrng_core_state *, u64);
	int (*complete)(struct vrng_core_state *, u64, u32, u32 *);
	int (*copy)(struct vrng_core_state *, const u8 *, u8 *, u32, u32 *,
		    u32 *);
	int (*begin_remove)(struct vrng_core_state *);
	int (*finish_remove)(struct vrng_core_state *);
	int (*validate)(const struct vrng_core_state *);
};

struct vrng_host_path {
	struct vrng_spec_event events[HOST_MAX_EVENTS];
	u32 count;
};

struct vrng_host_node {
	struct vrng_core_state state;
	struct vrng_host_path path;
	u32 depth;
};

struct vrng_host_injection {
	const char *candidate;
	u32 event_kind;
	bool enabled;
};

static const struct vrng_host_ops candidates[] = {
	{
		.name = "c",
		.init = vrng_core_c_init,
		.begin_submit = vrng_core_c_begin_submit,
		.abort_submit = vrng_core_c_abort_submit,
		.complete = vrng_core_c_complete,
		.copy = vrng_core_c_copy,
		.begin_remove = vrng_core_c_begin_remove,
		.finish_remove = vrng_core_c_finish_remove,
		.validate = vrng_core_c_validate,
	},
	{
		.name = "rust",
		.init = vrng_core_rust_init,
		.begin_submit = vrng_core_rust_begin_submit,
		.abort_submit = vrng_core_rust_abort_submit,
		.complete = vrng_core_rust_complete,
		.copy = vrng_core_rust_copy,
		.begin_remove = vrng_core_rust_begin_remove,
		.finish_remove = vrng_core_rust_finish_remove,
		.validate = vrng_core_rust_validate,
	},
	{
		.name = "mc",
		.init = vrng_core_mc_init,
		.begin_submit = vrng_core_mc_begin_submit,
		.abort_submit = vrng_core_mc_abort_submit,
		.complete = vrng_core_mc_complete,
		.copy = vrng_core_mc_copy,
		.begin_remove = vrng_core_mc_begin_remove,
		.finish_remove = vrng_core_mc_finish_remove,
		.validate = vrng_core_mc_validate,
	},
};

static const char *event_name(u32 kind)
{
	switch (kind) {
	case VRNG_EVENT_INIT: return "init";
	case VRNG_EVENT_BEGIN_SUBMIT: return "begin_submit";
	case VRNG_EVENT_ABORT_SUBMIT: return "abort_submit";
	case VRNG_EVENT_COMPLETE: return "complete";
	case VRNG_EVENT_COPY: return "copy";
	case VRNG_EVENT_BEGIN_REMOVE: return "begin_remove";
	case VRNG_EVENT_FINISH_REMOVE: return "finish_remove";
	case VRNG_EVENT_VALIDATE: return "validate";
	default: return "unknown";
	}
}

static int event_kind(const char *name, u32 *kind)
{
	u32 candidate;

	for (candidate = VRNG_EVENT_INIT; candidate <= VRNG_EVENT_VALIDATE;
	     candidate++) {
		if (!strcmp(name, event_name(candidate))) {
			*kind = candidate;
			return 0;
		}
	}
	return -EINVAL;
}

static int run_candidate(const struct vrng_host_ops *ops,
			 struct vrng_core_state *state,
			 const struct vrng_spec_event *event, const u8 *dma,
			 u8 *destination, struct vrng_spec_outcome *outcome)
{
	int result;

	memset(outcome, 0, sizeof(*outcome));
	switch (event->kind) {
	case VRNG_EVENT_INIT:
		result = ops->init(state, event->value, event->epoch);
		break;
	case VRNG_EVENT_BEGIN_SUBMIT:
		result = ops->begin_submit(state, &outcome->generation);
		break;
	case VRNG_EVENT_ABORT_SUBMIT:
		result = ops->abort_submit(state, event->generation);
		break;
	case VRNG_EVENT_COMPLETE:
		result = ops->complete(state, event->generation, event->value,
				       &outcome->need_resubmit);
		break;
	case VRNG_EVENT_COPY:
		result = ops->copy(state, dma, destination, event->value,
				   &outcome->copied, &outcome->need_resubmit);
		break;
	case VRNG_EVENT_BEGIN_REMOVE:
		result = ops->begin_remove(state);
		break;
	case VRNG_EVENT_FINISH_REMOVE:
		result = ops->finish_remove(state);
		break;
	case VRNG_EVENT_VALIDATE:
		result = ops->validate(state);
		break;
	default:
		result = -EINVAL;
		break;
	}
	outcome->result = result;
	return result;
}

static bool outcomes_equal(const struct vrng_spec_outcome *left,
			   const struct vrng_spec_outcome *right)
{
	return left->result == right->result &&
	       left->copied == right->copied &&
	       left->need_resubmit == right->need_resubmit &&
	       left->generation == right->generation;
}

static bool injection_matches(const struct vrng_host_injection *injection,
			      const struct vrng_host_ops *ops,
			      const struct vrng_spec_event *event)
{
	return injection->enabled &&
	       !strcmp(injection->candidate, ops->name) &&
	       injection->event_kind == event->kind;
}

static int compare_event(const struct vrng_host_ops *ops,
			 const struct vrng_core_state *base,
			 const struct vrng_spec_event *event,
			 const struct vrng_host_injection *injection,
			 struct vrng_core_state *next)
{
	struct vrng_core_state spec_state = *base;
	struct vrng_core_state candidate_state = *base;
	struct vrng_spec_outcome spec_outcome, candidate_outcome;
	u8 dma[HOST_BUFFER_SIZE], spec_destination[HOST_BUFFER_SIZE];
	u8 candidate_destination[HOST_BUFFER_SIZE];
	u32 index;

	for (index = 0; index < HOST_BUFFER_SIZE; index++)
		dma[index] = (u8)index;
	memset(spec_destination, 0xa5, sizeof(spec_destination));
	memset(candidate_destination, 0xa5, sizeof(candidate_destination));
	vrng_spec_step(&spec_state, event, dma, spec_destination,
		       &spec_outcome);
	run_candidate(ops, &candidate_state, event, dma,
		      candidate_destination, &candidate_outcome);
	if (injection_matches(injection, ops, event)) {
		candidate_outcome.result = candidate_outcome.result ? 0 : -EPROTO;
	}
	if (!outcomes_equal(&spec_outcome, &candidate_outcome) ||
	    memcmp(&spec_state, &candidate_state, sizeof(spec_state)) ||
	    memcmp(spec_destination, candidate_destination,
		   sizeof(spec_destination))) {
		fprintf(stderr,
			"mismatch candidate=%s event=%s spec=%d candidate=%d\n",
			ops->name, event_name(event->kind), spec_outcome.result,
			candidate_outcome.result);
		return -EPROTO;
	}
	*next = spec_state;
	return 0;
}

static uint64_t path_hash(const struct vrng_host_path *path)
{
	const uint8_t *bytes = (const uint8_t *)path->events;
	size_t length = path->count * sizeof(path->events[0]);
	uint64_t hash = UINT64_C(1469598103934665603);
	size_t index;

	for (index = 0; index < length; index++) {
		hash ^= bytes[index];
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}

static int persist_path(const char *directory, const char *candidate,
			const struct vrng_host_path *path, char *written,
			size_t written_size)
{
	FILE *file;
	u32 index;

	if (mkdir(directory, 0777) && errno != EEXIST)
		return -errno;
	snprintf(written, written_size, "%s/failure-%016" PRIx64 ".vrng",
		 directory, path_hash(path));
	file = fopen(written, "w");
	if (!file)
		return -errno;
	fprintf(file, "vrng-corpus-v1\n");
	fprintf(file, "candidate %s\n", candidate);
	for (index = 0; index < path->count; index++) {
		const struct vrng_spec_event *event = &path->events[index];

		fprintf(file, "event %s %u %" PRIu64 " %" PRIu64 "\n",
			event_name(event->kind), event->value,
			event->generation, event->epoch);
	}
	if (fclose(file))
		return -errno;
	return 0;
}

static bool contains_state(const struct vrng_host_node *nodes, u32 count,
			   const struct vrng_core_state *state)
{
	u32 index;

	for (index = 0; index < count; index++) {
		if (!memcmp(&nodes[index].state, state, sizeof(*state)))
			return true;
	}
	return false;
}

static u32 build_events(const struct vrng_core_state *state,
			struct vrng_spec_event *events)
{
	u32 count = 0;

	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_BEGIN_SUBMIT };
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_ABORT_SUBMIT,
		.generation = state->generation,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_ABORT_SUBMIT,
		.generation = state->generation + 1,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_COMPLETE,
		.generation = state->generation,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_COMPLETE,
		.value = 1,
		.generation = state->generation,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_COMPLETE,
		.value = state->capacity,
		.generation = state->generation,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_COMPLETE,
		.value = state->capacity + 1,
		.generation = state->generation,
	};
	events[count++] = (struct vrng_spec_event){
		.kind = VRNG_EVENT_COMPLETE,
		.value = 1,
		.generation = state->generation + 1,
	};
	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_COPY };
	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_COPY, .value = 1 };
	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_BEGIN_REMOVE };
	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_FINISH_REMOVE };
	events[count++] = (struct vrng_spec_event){ .kind = VRNG_EVENT_VALIDATE };
	return count;
}

static int enumerate(const char *corpus_directory,
		     const struct vrng_host_injection *injection)
{
	struct vrng_host_node nodes[HOST_MAX_STATES] = {};
	struct vrng_spec_event init = {
		.kind = VRNG_EVENT_INIT,
		.value = 3,
	};
	struct vrng_core_state zero = {}, next;
	u32 count = 0, cursor, candidate_index, event_index, event_count;
	struct vrng_spec_event events[13];
	char written[512];

	nodes[0].path.events[0] = init;
	nodes[0].path.count = 1;
	for (candidate_index = 0; candidate_index <
	     sizeof(candidates) / sizeof(candidates[0]); candidate_index++) {
		if (compare_event(&candidates[candidate_index], &zero, &init,
				  injection, &next))
			goto mismatch_root;
	}
	nodes[0].state = next;
	count = 1;

	for (cursor = 0; cursor < count; cursor++) {
		if (nodes[cursor].depth == HOST_MAX_DEPTH)
			continue;
		event_count = build_events(&nodes[cursor].state, events);
		for (event_index = 0; event_index < event_count; event_index++) {
			struct vrng_host_path path = nodes[cursor].path;

			path.events[path.count++] = events[event_index];
			for (candidate_index = 0; candidate_index <
			     sizeof(candidates) / sizeof(candidates[0]);
			     candidate_index++) {
				if (compare_event(&candidates[candidate_index],
						  &nodes[cursor].state,
						  &events[event_index], injection,
						  &next)) {
					if (persist_path(corpus_directory,
							 candidates[candidate_index].name,
							 &path, written,
							 sizeof(written)))
						return 1;
					printf("persisted %s\n", written);
					return 2;
				}
			}
			if (contains_state(nodes, count, &next))
				continue;
			if (count == HOST_MAX_STATES)
				return 1;
			nodes[count] = (struct vrng_host_node){
				.state = next,
				.path = path,
				.depth = nodes[cursor].depth + 1,
			};
			count++;
		}
	}
	printf("enumerated %u states across C, Rust, and MC\n", count);
	return count > 20 ? 0 : 1;

mismatch_root:
	if (persist_path(corpus_directory, candidates[candidate_index].name,
			 &nodes[0].path, written, sizeof(written)))
		return 1;
	printf("persisted %s\n", written);
	return 2;
}

static int load_path(const char *path_name, struct vrng_host_path *path)
{
	FILE *file = fopen(path_name, "r");
	char line[256], name[64];
	unsigned long long generation, epoch;
	u32 value, kind;

	if (!file)
		return -errno;
	if (!fgets(line, sizeof(line), file) ||
	    strcmp(line, "vrng-corpus-v1\n")) {
		fclose(file);
		return -EINVAL;
	}
	path->count = 0;
	while (fgets(line, sizeof(line), file)) {
		if (!strncmp(line, "candidate ", 10))
			continue;
		if (sscanf(line, "event %63s %u %llu %llu", name, &value,
			   &generation, &epoch) != 4 || event_kind(name, &kind) ||
		    path->count == HOST_MAX_EVENTS) {
			fclose(file);
			return -EINVAL;
		}
		path->events[path->count++] = (struct vrng_spec_event){
			.kind = kind,
			.value = value,
			.generation = generation,
			.epoch = epoch,
		};
	}
	fclose(file);
	return path->count ? 0 : -EINVAL;
}

static int replay(const char *path_name,
		  const struct vrng_host_injection *injection)
{
	struct vrng_host_path path;
	u32 candidate_index, event_index;

	if (load_path(path_name, &path))
		return 1;
	for (candidate_index = 0; candidate_index <
	     sizeof(candidates) / sizeof(candidates[0]); candidate_index++) {
		struct vrng_core_state state = {}, next;

		for (event_index = 0; event_index < path.count; event_index++) {
			if (compare_event(&candidates[candidate_index], &state,
					  &path.events[event_index], injection,
					  &next))
				return 2;
			state = next;
		}
	}
	printf("replayed %u events across C, Rust, and MC\n", path.count);
	return 0;
}

static int parse_injection(const char *argument,
			   struct vrng_host_injection *injection)
{
	char copy[128];
	char *separator;

	if (strlen(argument) >= sizeof(copy))
		return -EINVAL;
	strcpy(copy, argument);
	separator = strchr(copy, ':');
	if (!separator)
		return -EINVAL;
	*separator++ = '\0';
	if (event_kind(separator, &injection->event_kind))
		return -EINVAL;
	injection->candidate = strdup(copy);
	if (!injection->candidate)
		return -ENOMEM;
	injection->enabled = true;
	return 0;
}

static uint64_t elapsed_nanoseconds(const struct timespec *start,
				    const struct timespec *finish)
{
	return (uint64_t)(finish->tv_sec - start->tv_sec) * UINT64_C(1000000000) +
	       (uint64_t)(finish->tv_nsec - start->tv_nsec);
}

#define VRNG_BENCHMARK_MAX_SAMPLES 31

static void sort_nanoseconds(u64 *values, u32 count)
{
	u32 index;

	for (index = 1; index < count; index++) {
		u64 value = values[index];
		u32 position = index;

		while (position && values[position - 1] > value) {
			values[position] = values[position - 1];
			position--;
		}
		values[position] = value;
	}
}

static int benchmark(u64 iterations)
{
	u8 dma[64], destination[64];
	u64 nanoseconds[sizeof(candidates) / sizeof(candidates[0])]
		       [VRNG_BENCHMARK_MAX_SAMPLES];
	const char *samples_text = getenv("VRNG_BENCHMARK_SAMPLES");
	u32 candidate_count = sizeof(candidates) / sizeof(candidates[0]);
	u32 candidate_index, index, offset, sample;
	u32 samples = 7;
	volatile u64 checksum = 0;

	if (!iterations)
		return 1;
	if (samples_text) {
		char *end;
		unsigned long parsed = strtoul(samples_text, &end, 10);

		if (*end || !parsed || parsed > VRNG_BENCHMARK_MAX_SAMPLES ||
		    !(parsed & 1))
			return 1;
		samples = parsed;
	}
	for (index = 0; index < sizeof(dma); index++)
		dma[index] = (u8)index;
	for (sample = 0; sample < samples; sample++) {
		/*
		 * Rotate execution order so no implementation always receives the
		 * coldest or warmest position. The reported median rejects isolated
		 * scheduler and frequency-transition noise.
		 */
		for (offset = 0; offset < candidate_count; offset++) {
			struct vrng_core_state state = {};
			struct timespec start, finish;
			const struct vrng_host_ops *ops;
			u64 iteration, generation;
			u32 copied, need_resubmit;

			candidate_index = (sample + offset) % candidate_count;
			ops = &candidates[candidate_index];
			if (ops->init(&state, sizeof(dma), 0))
				return 1;
			if (clock_gettime(CLOCK_MONOTONIC, &start))
				return 1;
			for (iteration = 0; iteration < iterations; iteration++) {
				if (ops->begin_submit(&state, &generation) ||
				    ops->complete(&state, generation, sizeof(dma),
						  &need_resubmit) ||
				    ops->copy(&state, dma, destination,
					      sizeof(destination), &copied,
					      &need_resubmit) ||
				    copied != sizeof(dma))
					return 1;
				checksum +=
					destination[iteration % sizeof(destination)] +
					generation + need_resubmit;
			}
			if (clock_gettime(CLOCK_MONOTONIC, &finish))
				return 1;
			nanoseconds[candidate_index][sample] =
				elapsed_nanoseconds(&start, &finish);
		}
	}
	printf("implementation\titerations\tevents\tsamples\tmedian_nanoseconds"
	       "\tmin_nanoseconds\tmax_nanoseconds\tns_per_event"
	       "\tevents_per_second\n");
	for (candidate_index = 0; candidate_index < candidate_count;
	     candidate_index++) {
		u64 events = iterations * 3;
		u64 median;

		if (!events || events / 3 != iterations)
			return 1;
		sort_nanoseconds(nanoseconds[candidate_index], samples);
		median = nanoseconds[candidate_index][samples / 2];
		if (!median)
			return 1;
		printf("%s\t%" PRIu64 "\t%" PRIu64 "\t%u\t%" PRIu64
		       "\t%" PRIu64 "\t%" PRIu64 "\t%.3f\t%.0f\n",
		       candidates[candidate_index].name, iterations, events,
		       samples, median, nanoseconds[candidate_index][0],
		       nanoseconds[candidate_index][samples - 1],
		       (double)median / (double)events,
		       (double)events * 1000000000.0 / (double)median);
	}
	return checksum ? 0 : 1;
}

int main(int argc, char **argv)
{
	struct vrng_host_injection injection = {};
	const char *target;
	int result;

	if (argc != 3 && argc != 5) {
		fprintf(stderr,
			"usage: vrng-host enumerate CORPUS_DIR [--inject candidate:event]\n"
			"       vrng-host replay CORPUS [--inject candidate:event]\n"
			"       vrng-host benchmark ITERATIONS\n");
		return 1;
	}
	target = argv[2];
	if (!strcmp(argv[1], "benchmark")) {
		char *end;
		u64 iterations = strtoull(target, &end, 10);

		return *end ? 1 : benchmark(iterations);
	}
	if (argc == 5 && (strcmp(argv[3], "--inject") ||
			  parse_injection(argv[4], &injection)))
		return 1;
	if (!strcmp(argv[1], "enumerate"))
		result = enumerate(target, &injection);
	else if (!strcmp(argv[1], "replay"))
		result = replay(target, &injection);
	else
		result = 1;
	free((void *)injection.candidate);
	return result;
}
