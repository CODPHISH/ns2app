#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include "haptics.h"
#include "dm_vibration.h"

@interface TVHapticSide : NSObject
@property (strong) CHHapticEngine *engine;
@property (strong) id<CHHapticPatternPlayer> low;
@property (strong) id<CHHapticPatternPlayer> high;
@property BOOL sharpnessSupported;
@property BOOL failed;
@property unsigned retries;
@property BOOL retryPending;
@end
@implementation TVHapticSide
@end

static dispatch_queue_t haptic_queue;
static GCController *selected; // Accessed only on haptic_queue.
static GCController *requested; // Accessed only on the main queue.
static TVHapticSide *sides[2];
static _Atomic int wake_pending;
static BOOL waiting;
static uint64_t waiting_generation, timer_serial, last_submitted, last_applied, timeline_generation;
static uint64_t monotonic_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * NSEC_PER_SEC + t.tv_nsec;
}
static void drain(void);
static void apply(dm_vibration_frame frame);
static void recover(void);
static void retry_side(TVHapticSide *side) {
    if (side.retryPending || side.retries >= 3) return;
    side.retryPending = YES;
    uint64_t generation = dm_vibration_generation();
    int64_t delay = (250ll << side.retries++) * NSEC_PER_MSEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), haptic_queue, ^{
        side.retryPending = NO;
        if (sides[0] != side && sides[1] != side) return;
        side.failed = NO;
        if (generation != dm_vibration_generation()) return;
        recover();
    });
}
static void wake_driver(void) {
    if (atomic_exchange(&wake_pending, 1)) return;
    dispatch_async(haptic_queue, ^{
        // Clear before draining: a concurrent producer can schedule the next
        // drain without losing the final sample or growing an unbounded queue.
        atomic_store(&wake_pending, 0);
        @autoreleasepool { drain(); }
    });
}
static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        haptic_queue = dispatch_queue_create("org.nxnative.tv.haptics", DISPATCH_QUEUE_SERIAL);
        dm_vibration_set_wake(wake_driver);
    });
}
static void stop_side(TVHapticSide *side) {
    [side.low stopAtTime:CHHapticTimeImmediate error:nil];
    [side.high stopAtTime:CHHapticTimeImmediate error:nil];
    side.low = nil; side.high = nil;
}
static void destroy_sides(void) {
    for (int i = 0; i < 2; ++i) {
        TVHapticSide *side = sides[i];
        side.engine.stoppedHandler = nil; side.engine.resetHandler = nil;
        stop_side(side); [side.engine stopWithCompletionHandler:nil]; sides[i] = nil;
    }
}
static NSArray<CHHapticDynamicParameter *> *parameters(float amplitude, float frequency, BOOL sharpness) {
    CHHapticDynamicParameter *gain = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0];
    if (!sharpness) return @[gain];
    CHHapticDynamicParameter *tone = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:dm_vibration_sharpness(frequency) relativeTime:0];
    return @[gain, tone];
}
static id<CHHapticPatternPlayer> update_band(TVHapticSide *side, id<CHHapticPatternPlayer> player, float amplitude, float frequency, uint64_t generation) {
    if (generation != dm_vibration_generation() || amplitude <= 0 || side.failed) { [player stopAtTime:CHHapticTimeImmediate error:nil]; return nil; }
    NSError *error = nil;
    NSArray *values = parameters(amplitude, frequency, side.sharpnessSupported);
    if (player && [player sendParameters:values atTime:CHHapticTimeImmediate error:&error]) {
        if (generation == dm_vibration_generation()) return player;
        [player stopAtTime:CHHapticTimeImmediate error:nil]; return nil;
    }
    if (generation != dm_vibration_generation()) { [player stopAtTime:CHHapticTimeImmediate error:nil]; return nil; }
    if (player && side.sharpnessSupported && [player sendParameters:parameters(amplitude, frequency, NO) atTime:CHHapticTimeImmediate error:&error]) {
        side.sharpnessSupported = NO;
        if (generation == dm_vibration_generation()) return player;
        [player stopAtTime:CHHapticTimeImmediate error:nil]; return nil;
    }
    [player stopAtTime:CHHapticTimeImmediate error:nil];
    if (generation != dm_vibration_generation()) return nil;
    if (![side.engine startAndReturnError:&error]) {
        fprintf(stderr, "haptics: engine start failed: %s\n", error.localizedDescription.UTF8String);
        side.failed = YES; retry_side(side); return nil;
    }
    if (generation != dm_vibration_generation()) return nil;
    // Infinite controller events preserve sustained effects until the SDK sends
    // zero, or the frontend explicitly cancels them on focus/disconnect.
    NSArray *eventParameters = @[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0]];
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:eventParameters relativeTime:0 duration:GCHapticDurationInfinite];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:values error:&error];
    player = pattern ? [side.engine createPlayerWithPattern:pattern error:&error] : nil;
    if (!player && side.sharpnessSupported) {
        // Some controllers expose intensity alone. Keep vibration available.
        side.sharpnessSupported = NO;
        return update_band(side, nil, amplitude, frequency, generation);
    }
    if (generation != dm_vibration_generation()) return nil;
    if (!player || ![player startAtTime:CHHapticTimeImmediate error:&error]) {
        fprintf(stderr, "haptics: player failed: %s\n", error.localizedDescription.UTF8String);
        [player stopAtTime:CHHapticTimeImmediate error:nil];
        side.failed = YES; retry_side(side); return nil;
    }
    if (generation != dm_vibration_generation()) { [player stopAtTime:CHHapticTimeImmediate error:nil]; return nil; }
    return player;
}
static void apply(dm_vibration_frame frame) {
    if (frame.generation != dm_vibration_generation()) return;
    for (int i = 0; i < 2; ++i) {
        TVHapticSide *side = sides[i]; if (!side) continue;
        dm_vibration_value v = frame.value[i];
        side.low = update_band(side, side.low, v.low_amplitude, v.low_frequency, frame.generation);
        side.high = update_band(side, side.high, v.high_amplitude, v.high_frequency, frame.generation);
        if (!side.failed && (v.low_amplitude > 0 || v.high_amplitude > 0)) side.retries = 0;
    }
}
static void play_timed(dm_vibration_frame frame) {
    BOOL running = sides[0].low || sides[0].high || sides[1].low || sides[1].high;
    BOOL audible = frame.value[0].low_amplitude > 0 || frame.value[0].high_amplitude > 0 ||
                   frame.value[1].low_amplitude > 0 || frame.value[1].high_amplitude > 0;
    apply(frame);
    // Anchor once after initial engine startup. Advancing to completion on
    // every update would accumulate IPC cost and stretch the whole envelope.
    if (!last_submitted || (!running && audible)) {
        last_submitted = frame.submitted_ns; last_applied = monotonic_ns();
    }
}
static void recover(void) {
    // OS recovery adopts current state; an older scheduled frame must not
    // overwrite it after the engine has recovered.
    waiting = NO; ++timer_serial;
    last_submitted = last_applied = 0;
    dm_vibration_frame latest, queued; dm_vibration_snapshot(&latest);
    while (dm_vibration_take(&queued)) latest = queued;
    timeline_generation = latest.generation;
    play_timed(latest);
}
static void drain(void) {
    uint64_t generation = dm_vibration_generation();
    if (waiting) {
        if (waiting_generation == generation) return;
        // A cancellation must not wait behind an earlier effect's timer.
        waiting = NO; ++timer_serial;
    }
    dm_vibration_frame frame;
    while (dm_vibration_take(&frame)) {
        uint64_t now = monotonic_ns();
        if (timeline_generation != frame.generation || now - frame.submitted_ns > 100000000ull) {
            timeline_generation = frame.generation; last_submitted = last_applied = 0;
        }
        // Preserve spacing when engine startup or IPC briefly stalls. A queued
        // impact followed by zero must not become two calls in the same instant.
        uint64_t due = last_submitted && frame.submitted_ns >= last_submitted ?
            last_applied + frame.submitted_ns - last_submitted : now;
        if (due > now && due - now <= 100000000ull) {
            waiting = YES; waiting_generation = frame.generation;
            uint64_t serial = ++timer_serial;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due - now)), haptic_queue, ^{
                if (serial != timer_serial) return;
                waiting = NO;
                if (monotonic_ns() - frame.submitted_ns > 100000000ull) {
                    // A delayed timer is subject to the same stale policy as
                    // the FIFO; never briefly replay an old hit before a stop.
                    recover();
                } else play_timed(frame);
                drain();
            });
            return;
        }
        play_timed(frame);
    }
}
static void create_sides(uint64_t revision) {
    unsigned mask = 0;
    GCDeviceHaptics *device = selected.haptics;
    NSArray *localities = @[GCHapticsLocalityLeftHandle, GCHapticsLocalityRightHandle];
    for (int i = 0; i < 2; ++i) {
        if (![device.supportedLocalities containsObject:localities[i]]) continue;
        TVHapticSide *side = [TVHapticSide new];
        side.engine = [device createEngineWithLocality:localities[i]];
        if (!side.engine) continue;
        side.sharpnessSupported = YES;
        side.engine.playsHapticsOnly = YES;
        side.engine.autoShutdownEnabled = YES;
        __weak TVHapticSide *weakSide = side;
        side.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            dispatch_async(haptic_queue, ^{
                TVHapticSide *s = weakSide; if (!s) return;
                if (sides[i] != s) return;
                stop_side(s); s.failed = NO;
                fprintf(stderr, "haptics: engine stopped (%ld)\n", (long)reason);
                dm_vibration_frame f; dm_vibration_snapshot(&f);
                if (f.value[i].low_amplitude > 0 || f.value[i].high_amplitude > 0) retry_side(s);
            });
        };
        side.engine.resetHandler = ^{
            dispatch_async(haptic_queue, ^{
                TVHapticSide *s = weakSide; if (!s) return;
                if (sides[i] != s) return;
                stop_side(s); s.failed = NO;
                // Recreate players from current accepted values only; values
                // preceding a focus or connection reset cannot replay here.
                s.retries = 0;
                recover();
            });
        };
        sides[i] = side; mask |= 1u << i;
    }
    dm_vibration_controller_mount(mask, revision);
    fprintf(stderr, "haptics: %s left=%d right=%d; two HD bands per handle\n", selected.vendorName.UTF8String ?: "no controller", !!(mask & 1), !!(mask & 2));
}
void front_tv_haptics_select(GCController *controller) {
    initialize();
    if (requested == controller) return;
    requested = controller;
    uint64_t revision = dm_vibration_controller_begin();
    dispatch_async(haptic_queue, ^{
        destroy_sides(); selected = controller;
        create_sides(revision);
    });
}
void front_tv_haptics_active(int active) {
    initialize();
    static int was_active;
    if (was_active == !!active) return;
    was_active = !!active; dm_vibration_set_active(active);
    if (active) dispatch_async(haptic_queue, ^{
        for (int i = 0; i < 2; ++i) { sides[i].failed = NO; sides[i].retries = 0; }
        recover();
    });
}
void front_tv_haptics_reset(void) {
    initialize();
    uint64_t revision = dm_vibration_controller_begin();
    dispatch_async(haptic_queue, ^{ destroy_sides(); create_sides(revision); });
}
