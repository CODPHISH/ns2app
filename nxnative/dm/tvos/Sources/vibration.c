#include "dm_vibration.h"
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

_Static_assert(sizeof(dm_vibration_value) == 16, "Nintendo vibration value ABI");
#define QUEUE_SIZE 256
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned available, queued, first;
static int active, permitted = 1, forced;
static uint64_t generation = 1;
static uint64_t controller_revision;
static dm_vibration_value current[2];
static dm_vibration_frame frames[QUEUE_SIZE];
static void (*wake_driver)(void);
static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static dm_vibration_value silence(void) { return (dm_vibration_value){0, 160, 0, 320}; }
static float amplitude(float a) { return isfinite(a) ? fminf(1, fmaxf(0, a)) : 0; }
static dm_vibration_value sanitize(dm_vibration_value v) {
    v.low_amplitude = amplitude(v.low_amplitude);
    v.high_amplitude = amplitude(v.high_amplitude);
    if (!isfinite(v.low_frequency) || v.low_frequency <= 0) v.low_frequency = 160;
    if (!isfinite(v.high_frequency) || v.high_frequency <= 0) v.high_frequency = 320;
    v.low_frequency = fminf(626.286f, fmaxf(40.875f, v.low_frequency));
    v.high_frequency = fminf(1252.572f, fmaxf(81.75f, v.high_frequency));
    return v;
}
float dm_vibration_sharpness(float frequency) {
    if (!isfinite(frequency) || frequency <= 0) return 0;
    return fminf(1, fmaxf(0, log2f(frequency / 40.875f) / log2f(1252.572f / 40.875f)));
}
int dm_vibration_side(uint32_t h) {
    unsigned style = h & 255, id = (h >> 8) & 255, side = (h >> 16) & 255;
    if ((h >> 24) || side > 1) return -1;
    if (id == 0x20) return style == 4 ? (int)side : -1;
    if (id != 0 || style < 3 || style > 7 || style == 4) return -1;
    if ((style == 6 && side != 0) || (style == 7 && side != 1)) return -1;
    return (int)side;
}
int dm_vibration_handles(uint32_t *out, int capacity, uint32_t id, uint32_t style) {
    if (!out || capacity <= 0 || (id != 0 && id != 0x20)) return 0;
    unsigned index = 0, side = 0; int count = 2;
    if (id == 0x20) { if (!(style & 2)) return 0; index = 4; }
    else if (style & 1) index = 3;
    else if (style & 4) index = 5;
    else if (style & 8) { index = 6; count = 1; }
    else if (style & 16) { index = 7; side = 1; count = 1; }
    else return 0;
    if (count > capacity) count = capacity;
    for (int i = 0; i < count; ++i) out[i] = index | (id << 8) | ((side + (unsigned)i) << 16);
    return count;
}
void dm_vibration_info(uint32_t handle, uint32_t info[2]) {
    int side = dm_vibration_side(handle);
    info[0] = side < 0 ? 0 : 1; // Linear resonant actuator.
    info[1] = side < 0 ? 0 : (uint32_t)side + 1;
}
static void enqueue_locked(void) {
    // Bounded even if the OS haptic server stalls. Keep the newest full state.
    if (queued == QUEUE_SIZE) { first = (first + 1) % QUEUE_SIZE; --queued; }
    dm_vibration_frame *f = &frames[(first + queued++) % QUEUE_SIZE];
    memcpy(f->value, current, sizeof current); f->generation = generation; f->submitted_ns = now_ns();
}
static void reset_locked(void) {
    ++generation; first = queued = 0;
    current[0] = current[1] = silence(); enqueue_locked();
}
void dm_vibration_set_wake(void (*wake)(void)) {
    pthread_mutex_lock(&lock); wake_driver = wake; pthread_mutex_unlock(&lock);
    if (wake) wake();
}
void dm_vibration_set_available(unsigned sides) {
    pthread_mutex_lock(&lock);
    if (available != (sides & 3)) { available = sides & 3; reset_locked(); }
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
}
uint64_t dm_vibration_controller_begin(void) {
    pthread_mutex_lock(&lock);
    uint64_t revision = ++controller_revision;
    available = 0; reset_locked();
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
    return revision;
}
void dm_vibration_controller_mount(unsigned sides, uint64_t revision) {
    pthread_mutex_lock(&lock);
    if (revision == controller_revision && available != (sides & 3)) {
        available = sides & 3; reset_locked();
    }
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
}
void dm_vibration_set_active(int on) {
    pthread_mutex_lock(&lock);
    if (active != !!on) { active = !!on; reset_locked(); }
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
}
int dm_vibration_mounted(uint32_t handle) {
    int side = dm_vibration_side(handle);
    pthread_mutex_lock(&lock); int mounted = side >= 0 && (available & (1u << side)); pthread_mutex_unlock(&lock);
    return !!mounted;
}
int dm_vibration_permitted(void) {
    pthread_mutex_lock(&lock); int enabled = permitted || forced; pthread_mutex_unlock(&lock); return enabled;
}
void dm_vibration_permit(int enabled) {
    pthread_mutex_lock(&lock);
    if (permitted != !!enabled) { permitted = !!enabled; if (!permitted && !forced) reset_locked(); }
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
}
void dm_vibration_force(int enabled) {
    pthread_mutex_lock(&lock);
    if (forced != !!enabled) { forced = !!enabled; if (!permitted && !forced) reset_locked(); }
    void (*wake)(void) = wake_driver; pthread_mutex_unlock(&lock); if (wake) wake();
}
void dm_vibration_send(const uint32_t *handles, const dm_vibration_value *values, int count) {
    if (!handles || !values || count <= 0 || count > 64) return;
    pthread_mutex_lock(&lock);
    int changed = 0;
    if (active && (permitted || forced)) for (int i = 0; i < count; ++i) {
        int side = dm_vibration_side(handles[i]);
        if (side < 0 || !(available & (1u << side))) continue;
        dm_vibration_value v = sanitize(values[i]);
        if (memcmp(&current[side], &v, sizeof v)) { current[side] = v; changed = 1; }
    }
    if (changed) enqueue_locked();
    void (*wake)(void) = changed ? wake_driver : NULL; pthread_mutex_unlock(&lock); if (wake) wake();
}
void dm_vibration_actual(uint32_t handle, dm_vibration_value *out) {
    int side = dm_vibration_side(handle);
    pthread_mutex_lock(&lock);
    *out = side >= 0 && active && (available & (1u << side)) && (permitted || forced) ? current[side] : silence();
    pthread_mutex_unlock(&lock);
}
int dm_vibration_take(dm_vibration_frame *out) {
    pthread_mutex_lock(&lock);
    // If the OS server blocked, do not replay a backlog of old impacts. The
    // final state (especially a stop) is always delivered, including sustains.
    uint64_t now = now_ns();
    while (queued > 1 && now - frames[first].submitted_ns > 100000000ull) { first = (first + 1) % QUEUE_SIZE; --queued; }
    int found = queued != 0;
    if (found) { *out = frames[first]; first = (first + 1) % QUEUE_SIZE; --queued; }
    pthread_mutex_unlock(&lock); return found;
}
uint64_t dm_vibration_generation(void) {
    pthread_mutex_lock(&lock); uint64_t value = generation; pthread_mutex_unlock(&lock); return value;
}
void dm_vibration_snapshot(dm_vibration_frame *out) {
    pthread_mutex_lock(&lock);
    memcpy(out->value, current, sizeof current);
    out->generation = generation; out->submitted_ns = now_ns();
    pthread_mutex_unlock(&lock);
}
