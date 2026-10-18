// Exercise the real Core Haptics driver with fake controller engines/players.
// Foundation and pattern construction are real; no controller or sound device is used.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <assert.h>
#include <unistd.h>
#include "../../nxnative/dm/tvos/Sources/haptics.m"

static unsigned player_starts, player_stops, player_creations;
static uint64_t start_times[16], stop_times[16];
static BOOL trace_submissions;
static unsigned submission_count;
static uint64_t submission_times[3], queue_released_ns;
// Called only on haptic_queue; preserve evidence before an assertion aborts.
static void report_timing(const char *reason) {
    fprintf(stderr, "haptics test %s: now=%llu starts=%u stops=%u creations=%u waiting=%d "
            "generation=%llu timeline=%llu last_submitted=%llu last_applied=%llu retries=%u\n",
            reason, (unsigned long long)monotonic_ns(), player_starts, player_stops, player_creations,
            waiting, (unsigned long long)dm_vibration_generation(), (unsigned long long)timeline_generation,
            (unsigned long long)last_submitted, (unsigned long long)last_applied, sides[0].retries);
    for (unsigned i = 0; i < submission_count; ++i)
        fprintf(stderr, "  submission[%u]=%llu age_at_queue_release_ms=%.3f\n", i,
                (unsigned long long)submission_times[i], (queue_released_ns - submission_times[i]) / 1e6);
    for (unsigned i = 0; i < player_starts; ++i) {
        unsigned submitted = i == 0 ? 0 : 2;
        fprintf(stderr, "  start[%u]=%llu submission_age_ms=%.3f\n", i,
                (unsigned long long)start_times[i], submitted < submission_count ?
                (start_times[i] - submission_times[submitted]) / 1e6 : -1.0);
    }
    for (unsigned i = 0; i < player_stops; ++i)
        fprintf(stderr, "  stop[%u]=%llu stop_submission_age_ms=%.3f\n", i,
                (unsigned long long)stop_times[i], submission_count > 1 ?
                (stop_times[i] - submission_times[1]) / 1e6 : -1.0);
}
@interface TestPlayer : NSObject
@property BOOL playing;
@end
@implementation TestPlayer
- (BOOL)startAtTime:(NSTimeInterval)time error:(NSError **)error {
    (void)time; (void)error; self.playing = YES;
    assert(player_starts < 16); start_times[player_starts++] = monotonic_ns(); return YES;
}
- (BOOL)stopAtTime:(NSTimeInterval)time error:(NSError **)error {
    (void)time; (void)error;
    if (self.playing) { assert(player_stops < 16); stop_times[player_stops++] = monotonic_ns(); }
    self.playing = NO; return YES;
}
- (BOOL)sendParameters:(NSArray *)parameters atTime:(NSTimeInterval)time error:(NSError **)error {
    (void)parameters; (void)time; (void)error; return YES;
}
@end

@interface TestEngine : NSObject
@property BOOL playsHapticsOnly, autoShutdownEnabled, failAfterFirstPlayer;
@property (copy) void (^stoppedHandler)(CHHapticEngineStoppedReason);
@property (copy) void (^resetHandler)(void);
@property (strong) dispatch_semaphore_t enteredStart, continueStart;
@end
@implementation TestEngine
- (BOOL)startAndReturnError:(NSError **)error {
    (void)error;
    if (self.enteredStart) {
        dispatch_semaphore_signal(self.enteredStart);
        assert(!dispatch_semaphore_wait(self.continueStart, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)));
    }
    return YES;
}
- (id<CHHapticPatternPlayer>)createPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)error {
    assert(pattern);
    if (player_creations++ && self.failAfterFirstPlayer) {
        if (error) *error = [NSError errorWithDomain:@"InjectedHighBandFailure" code:1 userInfo:nil];
        return nil;
    }
    return (id<CHHapticPatternPlayer>)[TestPlayer new];
}
- (void)stopWithCompletionHandler:(void (^)(NSError *))handler { if (handler) handler(nil); }
@end

@interface TestHaptics : NSObject
@property (strong) TestEngine *engine;
@end
@implementation TestHaptics
- (NSSet *)supportedLocalities { return [NSSet setWithObject:GCHapticsLocalityLeftHandle]; }
- (CHHapticEngine *)createEngineWithLocality:(GCHapticsLocality)locality {
    assert([locality isEqual:GCHapticsLocalityLeftHandle]); return (CHHapticEngine *)self.engine;
}
@end
@interface TestController : NSObject
@property (strong) TestHaptics *haptics;
@end
@implementation TestController
- (NSString *)vendorName { return @"Synthetic controller"; }
@end

static void flush(void) { dispatch_sync(haptic_queue, ^{}); }
static TestEngine *setup(void) {
    TestEngine *engine = [TestEngine new];
    TestController *controller = [TestController new];
    controller.haptics = [TestHaptics new]; controller.haptics.engine = engine;
    front_tv_haptics_active(1);
    front_tv_haptics_select((GCController *)controller);
    flush(); flush();
    assert(dm_vibration_mounted(3));
    return engine;
}
static void submit_vibration(float low, float high) {
    uint32_t handle = 3;
    dm_vibration_value value = {low, 160, high, 320};
    if (trace_submissions && submission_count < 3) submission_times[submission_count++] = monotonic_ns();
    dm_vibration_send(&handle, &value, 1);
}
static void wait_for_starts(unsigned count) {
    uint64_t deadline = monotonic_ns() + 2 * NSEC_PER_SEC;
    for (;;) {
        __block unsigned actual;
        dispatch_sync(haptic_queue, ^{ actual = player_starts; });
        if (actual >= count) return;
        if (monotonic_ns() >= deadline) {
            dispatch_sync(haptic_queue, ^{ report_timing("start deadline"); });
            assert(!"player start deadline exceeded");
        }
        usleep(1000);
    }
}
static dispatch_semaphore_t hold_queue(void) {
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), resume = dispatch_semaphore_create(0);
    dispatch_async(haptic_queue, ^{
        dispatch_semaphore_signal(entered);
        assert(!dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)));
    });
    assert(!dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    return resume;
}
int main(int argc, const char **argv) {
    assert(argc == 2);
    @autoreleasepool {
        TestEngine *engine = setup();
        if (!strcmp(argv[1], "retry")) {
            engine.failAfterFirstPlayer = YES;
            submit_vibration(0.5, 0.8);
            // A healthy low player must not reset the failing high band's budget.
            usleep(2100000); flush();
            dispatch_sync(haptic_queue, ^{
                assert(player_creations == 6); // Low + high/fallback + three delayed high retries.
                assert(player_starts == 1 && sides[0].retries == 3 && !sides[0].retryPending);
            });
        } else if (!strcmp(argv[1], "spacing") || !strcmp(argv[1], "cancel-timer")) {
            if (!strcmp(argv[1], "spacing")) {
                // Real CHHapticPattern construction may initialize framework state.
                // Pay that first-use cost before measuring a queue stall under
                // 100 ms; older effects are intentionally discarded by the driver.
                submit_vibration(0.7, 0); wait_for_starts(1);
                front_tv_haptics_active(0); flush();
                front_tv_haptics_active(1); flush(); flush();
                dispatch_sync(haptic_queue, ^{
                    assert(player_starts == 1 && player_stops == 1);
                    assert(!sides[0].low && !sides[0].high && !waiting);
                    player_starts = player_stops = player_creations = 0;
                    memset(start_times, 0, sizeof start_times);
                    memset(stop_times, 0, sizeof stop_times);
                });
                trace_submissions = YES;
            }
            dispatch_semaphore_t resume = hold_queue();
            submit_vibration(0.7, 0); usleep(20000);
            submit_vibration(0, 0); usleep(20000);
            submit_vibration(0.7, 0);
            if (trace_submissions) {
                queue_released_ns = monotonic_ns();
                fprintf(stderr, "haptics spacing queue hold: %.3f ms (must be <100 ms)\n",
                        (queue_released_ns - submission_times[0]) / 1e6);
                assert(queue_released_ns - submission_times[0] < 100000000ull);
            }
            dispatch_semaphore_signal(resume);
            if (!strcmp(argv[1], "spacing")) {
                wait_for_starts(2);
                dispatch_sync(haptic_queue, ^{
                    report_timing("spacing complete");
                    assert(player_starts == 2 && player_stops == 1);
                    assert(stop_times[0] - start_times[0] >= 10000000ull);
                    assert(start_times[1] - stop_times[0] >= 10000000ull);
                });
            } else {
                wait_for_starts(1);
                front_tv_haptics_active(0); flush();
                usleep(100000); flush();
                dispatch_sync(haptic_queue, ^{ assert(player_starts == 1 && player_stops == 1); });
            }
        } else if (!strcmp(argv[1], "cancel-start")) {
            engine.enteredStart = dispatch_semaphore_create(0);
            engine.continueStart = dispatch_semaphore_create(0);
            submit_vibration(0.8, 0.9);
            assert(!dispatch_semaphore_wait(engine.enteredStart, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)));
            front_tv_haptics_active(0); // Invalidate from the main thread while the OS start is blocked.
            dispatch_semaphore_signal(engine.continueStart);
            flush(); flush();
            dispatch_sync(haptic_queue, ^{ assert(!player_creations && !player_starts); });
        } else if (!strcmp(argv[1], "reset")) {
            submit_vibration(0.8, 0.9); wait_for_starts(2);
            engine.resetHandler(); flush();
            dispatch_sync(haptic_queue, ^{ assert(player_starts == 4 && player_stops == 2); });
            front_tv_haptics_active(0); flush();
            engine.resetHandler(); flush();
            dispatch_sync(haptic_queue, ^{ assert(player_starts == 4 && player_stops == 4); });
        } else {
            assert(!"unknown scenario");
        }
        front_tv_haptics_active(0); flush();
        printf("Core Haptics %s passed\n", argv[1]);
    }
    return 0;
}
