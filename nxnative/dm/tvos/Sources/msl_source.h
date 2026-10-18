#pragma once
#include <stddef.h>
// DMZ1 + little-endian uint32 output length + one zlib stream.
// Returns 1 with malloc-owned output, 0 for ordinary source, -1 for invalid data.
int dm_tv_msl_decode(const void *input, size_t length, char **output, size_t *output_length);
