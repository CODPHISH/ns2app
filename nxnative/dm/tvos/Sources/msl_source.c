#include "msl_source.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <zlib.h>

int dm_tv_msl_decode(const void *input, size_t length, char **output, size_t *output_length) {
    *output = NULL; *output_length = 0;
    if (length < 4 || memcmp(input, "DMZ1", 4)) return 0;
    if (length < 8 || length - 8 > UINT_MAX) return -1;
    const unsigned char *bytes = input;
    uint32_t size = (uint32_t)bytes[4] | (uint32_t)bytes[5] << 8 | (uint32_t)bytes[6] << 16 | (uint32_t)bytes[7] << 24;
    if (!size || size > 16u * 1024u * 1024u) return -1;
    char *decoded = malloc(size);
    if (!decoded) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)bytes + 8; stream.avail_in = (uInt)(length - 8);
    stream.next_out = (Bytef *)decoded; stream.avail_out = size;
    if (inflateInit(&stream) != Z_OK) { free(decoded); return -1; }
    int result = inflate(&stream, Z_FINISH);
    int valid = result == Z_STREAM_END && stream.total_out == size && stream.total_in == length - 8;
    inflateEnd(&stream);
    if (!valid) { free(decoded); return -1; }
    *output = decoded; *output_length = size;
    return 1;
}
