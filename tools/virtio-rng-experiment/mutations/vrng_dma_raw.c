/* SPDX-License-Identifier: GPL-2.0-or-later */

#include <stddef.h>
#include <stdint.h>

enum dma_owner { CPU_OWNED, DEVICE_OWNED };

struct dma_buffer {
	uint8_t *cpu;
	size_t len;
	enum dma_owner owner;
};

/* Deliberate mutation: C accepts CPU access while the runtime tag says device. */
uint8_t mutated_device_owned_read(struct dma_buffer *buffer)
{
	return buffer->cpu[0];
}
