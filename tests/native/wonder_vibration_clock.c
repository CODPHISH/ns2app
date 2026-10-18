// Run the production queue against a controlled monotonic clock, without sleeps.
#include <time.h>
#include <stdint.h>
static uint64_t test_ns = 1000000000ull;
static int test_clock_gettime(clockid_t clock, struct timespec *out) {
    (void)clock;
    out->tv_sec = test_ns / 1000000000ull;
    out->tv_nsec = test_ns % 1000000000ull;
    return 0;
}
void test_advance_ns(uint64_t delta) { test_ns += delta; }
#define clock_gettime test_clock_gettime
#include "../../nxnative/dm/tvos/Sources/vibration.c"
