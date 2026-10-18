// Actual AudioOut state machine and PCM queues, with deterministic OS failures.
// Build/run through test_wonder_lifecycle.py on macOS. No audio device is opened.
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
#include <time.h>

static AudioComponent fake_find(AudioComponent, const AudioComponentDescription *);
static OSStatus fake_new(AudioComponent, AudioComponentInstance *);
static OSStatus fake_dispose(AudioComponentInstance);
static OSStatus fake_property(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus fake_initialize(AudioUnit);
static OSStatus fake_uninitialize(AudioUnit);
static OSStatus fake_start(AudioUnit);
static OSStatus fake_stop(AudioUnit);
static int observed_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
#define AudioComponentFindNext fake_find
#define AudioComponentInstanceNew fake_new
#define AudioComponentInstanceDispose fake_dispose
#define AudioUnitSetProperty fake_property
#define AudioUnitInitialize fake_initialize
#define AudioUnitUninitialize fake_uninitialize
#define AudioOutputUnitStart fake_start
#define AudioOutputUnitStop fake_stop
#define pthread_create observed_create
#include "../../nxnative/dm/host/hle_audio.c"
#undef pthread_create

typedef struct { AURenderCallbackStruct callback; } fake_unit;
static _Atomic int real_consumers, silent_consumers;
static int fail_initialize = 2, fail_start = 1, starts, disposals;
static _Atomic int signals;
static const void *guest_key;
static void *guest_output;
void *objmap_get(const void *key) { return key == guest_key ? guest_output : NULL; }
void objmap_put(const void *key, void *value) { assert(!guest_key); guest_key = key; guest_output = value; }
void *objmap_del(const void *key) { assert(key == guest_key); void *value = guest_output; guest_key = guest_output = NULL; return value; }
void hle_signal_system_event(void *event) { (void)event; atomic_fetch_add(&signals, 1); }
void hle_bind_system_event(void *event, int autoclear) { (void)event; (void)autoclear; }
module_t *module_of(const void *p) { (void)p; return NULL; }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }

static void *observed_sink(void *context) {
    assert(atomic_load(&real_consumers) == 0);
    assert(atomic_fetch_add(&silent_consumers, 1) == 0);
    null_sink(context);
    assert(atomic_fetch_sub(&silent_consumers, 1) == 1);
    return NULL;
}
static int observed_create(pthread_t *thread, const pthread_attr_t *attr, void *(*run)(void *), void *context) {
    return pthread_create(thread, attr, run == null_sink ? observed_sink : run, context);
}
static AudioComponent fake_find(AudioComponent previous, const AudioComponentDescription *description) {
    (void)previous; (void)description; return (AudioComponent)(uintptr_t)1;
}
static OSStatus fake_new(AudioComponent component, AudioComponentInstance *out) {
    (void)component; *out = (AudioComponentInstance)calloc(1, sizeof(fake_unit)); return noErr;
}
static OSStatus fake_dispose(AudioComponentInstance unit) {
    assert(atomic_load(&real_consumers) == 0); ++disposals; free(unit); return noErr;
}
static OSStatus fake_property(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                              AudioUnitElement element, const void *value, UInt32 size) {
    (void)scope; (void)element; (void)size;
    if (property == kAudioUnitProperty_SetRenderCallback) ((fake_unit *)unit)->callback = *(const AURenderCallbackStruct *)value;
    return noErr;
}
static OSStatus fake_initialize(AudioUnit unit) { (void)unit; if (fail_initialize) { --fail_initialize; return -1; } return noErr; }
static OSStatus fake_uninitialize(AudioUnit unit) { (void)unit; assert(!atomic_load(&real_consumers)); return noErr; }
static OSStatus fake_start(AudioUnit unit) {
    aout *output = ((fake_unit *)unit)->callback.inputProcRefCon;
    assert(!atomic_load(&output->null_run));
    assert(!atomic_load(&silent_consumers)); // Joining, not merely clearing null_run, is required.
    ++starts;
    if (fail_start) { --fail_start; return -2; }
    assert(atomic_fetch_add(&real_consumers, 1) == 0);
    return noErr;
}
static OSStatus fake_stop(AudioUnit unit) {
    (void)unit; assert(!atomic_load(&silent_consumers));
    assert(atomic_fetch_sub(&real_consumers, 1) == 1); return noErr;
}
static void wait_for_sink(void) {
    uint64_t deadline = now_ns() + 1000000000ull;
    while (!atomic_load(&silent_consumers) && now_ns() < deadline) usleep(1000);
    assert(atomic_load(&silent_consumers) == 1);
}
static void release_in_order(void *out, gbuf *buffers, int count) {
    uint64_t deadline = now_ns() + 2000000000ull;
    for (int index = 0; index < count;) {
        gbuf *released = h_au_Released(out);
        if (released) assert(released == &buffers[index++]);
        else { assert(now_ns() < deadline); usleep(1000); }
    }
    assert(!h_au_Released(out));
}
static void render(aout *output, uint8_t *bytes, unsigned count) {
    assert(output->real_running && atomic_load(&real_consumers) == 1 && !atomic_load(&silent_consumers));
    AudioBufferList list = {.mNumberBuffers = 1, .mBuffers = {{2, count, bytes}}};
    fake_unit *unit = (fake_unit *)output->au;
    assert(!unit->callback.inputProc(unit->callback.inputProcRefCon, NULL, NULL, 0, count / 4, &list));
}
int main(void) {
    setenv("DM_AUDIO", "1", 1);
    unsetenv("DM_AUDIO_MUTE"); unsetenv("DM_AUDIO_DUMP"); unsetenv("DM_DBG_AU_FRAMES");
    char out[64], event[64]; uint8_t param[16];
    h_au_InitParam(param);
    assert(!h_au_Open(out, event, NULL, param));
    aout *output = ao(out);
    assert(!output->au); // Open failed; guest output remains usable.
    gbuf background[3]; uint8_t silence[3][960] = {{0}};
    for (int i = 0; i < 3; ++i) {
        h_au_SetBuf(&background[i], silence[i], sizeof silence[i], sizeof silence[i]);
        assert(h_au_Append(out, &background[i]));
    }
    assert(!h_au_Start(out)); // The second open failure must leave a paced consumer.
    wait_for_sink(); release_in_order(out, background, 3);
    dm_audio_suspend(0); // Open succeeds; start fails. Silent consumption must survive.
    wait_for_sink(); assert(!output->real_running);
    dm_audio_suspend(0); // Retry: stop AND join the sink before starting the AudioUnit.
    assert(output->real_running && !atomic_load(&silent_consumers));

    // Reset partway through a buffer: preserve every remaining byte and release order.
    uint8_t pcm[2][64], rendered[128]; gbuf buffers[2];
    for (int i = 0; i < 128; ++i) ((uint8_t *)pcm)[i] = (uint8_t)(i + 1);
    for (int i = 0; i < 2; ++i) {
        h_au_SetBuf(&buffers[i], pcm[i], sizeof pcm[i], sizeof pcm[i]);
        assert(h_au_Append(out, &buffers[i]));
    }
    render(output, rendered, 16);
    int disposed_before = disposals;
    dm_audio_reset();
    assert(disposals == disposed_before + 1 && h_au_State(out) == STATE_STARTED);
    render(output, rendered + 16, sizeof rendered - 16);
    assert(!memcmp(rendered, pcm, sizeof rendered));
    release_in_order(out, buffers, 2);

    dm_audio_suspend(1); wait_for_sink();
    int starts_before = starts;
    dm_audio_reset(); wait_for_sink();
    assert(starts == starts_before && !output->au); // Reset during interruption stays suspended.
    for (int i = 0; i < 3; ++i) assert(h_au_Append(out, &background[i]));
    release_in_order(out, background, 3);
    dm_audio_suspend(0);
    assert(output->real_running && !atomic_load(&silent_consumers));
    h_au_Stop(out); dm_audio_reset();
    assert(h_au_State(out) == STATE_STOPPED && !atomic_load(&real_consumers) && !atomic_load(&silent_consumers));
    h_au_Close(out);
    assert(atomic_load(&signals) > 0);
    puts("AudioUnit failure, suspension and reset preserve PCM with one consumer");
    return 0;
}
