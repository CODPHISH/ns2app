// tvOS entry point. Game resources are bundled; writable state uses Caches.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "game_profile.h"
#include "front.h"

int dm_main(int argc, char **argv);
UIViewController *front_tv_root(void);
void front_tv_focus_event(int event);
void front_tv_audio_session(void);
static char *guest_argv[3];
static int boot_ok;

static void boot_environment(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *res = NSBundle.mainBundle.resourcePath;
    NSString *state = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Wonder"];
    for (NSString *name in @[@"save", @"temp"])
        if (![fm createDirectoryAtPath:[state stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil]) return;
    NSString *log = [state stringByAppendingPathComponent:@"log.txt"];
    NSString *previous = [state stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:previous error:nil];
    [fm moveItemAtPath:log toPath:previous error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    NSString *settings = [NSString stringWithContentsOfFile:[dm stringByAppendingPathComponent:@"env.txt"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [settings componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
        setenv([line substringToIndex:eq.location].UTF8String, [line substringFromIndex:eq.location + 1].UTF8String, 0);
    }
    NSString *romfs = [res stringByAppendingPathComponent:@"romfs"];
    if (![fm fileExistsAtPath:[romfs stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) {
        fprintf(stderr, "boot: bundled game resources missing\n"); return;
    }
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 1);
    setenv("DM_SAVE", [state stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 1);
    setenv("DM_TEMP", [state stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 1);
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 1);
    setenv("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 1);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 1);
    if (chdir(state.fileSystemRepresentation)) return;
    guest_argv[0] = strdup("dmhost"); guest_argv[1] = strdup(dm.fileSystemRepresentation);
    boot_ok = 1;
    fprintf(stderr, "boot: Wonder tvOS / A15 / 720p render / 1080p output; saves in purgeable Caches\n");
}
int front_tv_boot_ok(void) { return boot_ok; }
static void *guest_thread(void *unused) {
    (void)unused;
    int result = dm_main(2, guest_argv);
    fprintf(stderr, "boot: guest returned %d\n", result);
    return NULL;
}
void front_tv_boot(void) {
    static int started;
    if (started || !boot_ok) return;
    started = 1;
    front_tv_audio_session();
    dm_host_preload_start(2, guest_argv);
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 64u << 20);
    pthread_t thread;
    int error = pthread_create(&thread, &attributes, guest_thread, NULL);
    pthread_attr_destroy(&attributes);
    if (!error) pthread_detach(thread);
    else fprintf(stderr, "boot: pthread_create failed: %d\n", error);
}
@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
}
@end
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_tv_root();
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)scene { front_tv_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)scene { front_tv_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)scene { front_tv_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)scene { front_tv_focus_event(3); }
@end
int main(int argc, char **argv) {
    @autoreleasepool { boot_environment(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
