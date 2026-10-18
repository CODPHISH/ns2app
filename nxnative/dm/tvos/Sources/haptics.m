#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <stdatomic.h>
#include <stdio.h>
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
static void drain(void);
static void apply(dm_vibration_frame frame);
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
        dm_vibration_frame frame; dm_vibration_snapshot(&frame); apply(frame);
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
    }
}
static void drain(void) {
    dm_vibration_frame frame;
    while (dm_vibration_take(&frame)) apply(frame);
}
static void create_sides(void) {
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
                retry_side(s);
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
                dm_vibration_frame f; dm_vibration_snapshot(&f);
                apply(f);
            });
        };
        sides[i] = side; mask |= 1u << i;
    }
    dm_vibration_set_available(mask);
    fprintf(stderr, "haptics: %s left=%d right=%d; two HD bands per handle\n", selected.vendorName.UTF8String ?: "no controller", !!(mask & 1), !!(mask & 2));
}
void front_tv_haptics_select(GCController *controller) {
    initialize();
    if (requested == controller) return;
    requested = controller;
    dm_vibration_set_available(0);
    dispatch_async(haptic_queue, ^{
        if (selected == controller) return;
        dm_vibration_set_available(0); destroy_sides(); selected = controller;
        create_sides();
    });
}
void front_tv_haptics_active(int active) {
    initialize(); dm_vibration_set_active(active);
    if (active) dispatch_async(haptic_queue, ^{
        for (int i = 0; i < 2; ++i) { sides[i].failed = NO; sides[i].retries = 0; }
    });
}
void front_tv_haptics_reset(void) {
    initialize();
    dispatch_async(haptic_queue, ^{ dm_vibration_set_available(0); destroy_sides(); create_sides(); });
}
