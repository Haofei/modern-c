// SPDX-License-Identifier: GPL-2.0-or-later
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

int main(void)
{
	uint8_t buffer[64];
	ssize_t result;
	int saved_errno;
	int fd;

	fd = open("/dev/hwrng", O_RDONLY | O_NONBLOCK);
	if (fd < 0)
		return 1;
	result = read(fd, buffer, sizeof(buffer));
	saved_errno = errno;
	close(fd);
	if (result >= 0 || saved_errno == EAGAIN || saved_errno == EWOULDBLOCK)
		return 0;
	return 2;
}
