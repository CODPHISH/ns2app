// Native tvOS presentation and the standard, system-paired extended gamepad.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFAudio/AVFAudio.h>
#include <math.h>
#include <errno.h>
#include "front.h"
#include "dm_input.h"
#include "hle.h"
#include "dm.h"

void front_tv_boot(void);
int front_tv_boot_ok(void);
static CAMetalLayer *game_layer;
static GCController *active_controller;
static BOOL app_active, modal_active;
static void reset_pad(void) { dm_pad_set(0, 0, 0, 0, 0); }

@interface TVGameView : UIView
@end
@implementation TVGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.opaque = YES;
        layer.drawableSize = CGSizeMake(1920, 1080);
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; ((CAMetalLayer *)self.layer).drawableSize = CGSizeMake(1920, 1080); }
@end
@interface TVRoot : GCEventViewController
@property (strong, nonatomic) TVGameView *game;
@property (strong, nonatomic) UILabel *controllerHint;
@end
static __weak TVRoot *root;

static int32_t axis(float value) {
    if (!isfinite(value)) return 0;
    return (int32_t)lrintf(fmaxf(-1, fminf(1, value)) * DM_STICK_MAX);
}
static void publish_pad(void) {
    GCExtendedGamepad *pad = active_controller.extendedGamepad;
    if (!app_active || modal_active || !pad) { reset_pad(); return; }
    uint64_t buttons = 0;
#define BUTTON(input, bit) if ((input).isPressed) buttons |= (bit)
    // Match physical positions: DualSense circle=A, cross=B, triangle=X, square=Y.
    BUTTON(pad.buttonB, DM_BTN_A); BUTTON(pad.buttonA, DM_BTN_B);
    BUTTON(pad.buttonY, DM_BTN_X); BUTTON(pad.buttonX, DM_BTN_Y);
    BUTTON(pad.leftShoulder, DM_BTN_L); BUTTON(pad.rightShoulder, DM_BTN_R);
    BUTTON(pad.leftTrigger, DM_BTN_ZL); BUTTON(pad.rightTrigger, DM_BTN_ZR);
    BUTTON(pad.buttonMenu, DM_BTN_PLUS); BUTTON(pad.buttonOptions, DM_BTN_MINUS);
    BUTTON(pad.leftThumbstickButton, DM_BTN_LS); BUTTON(pad.rightThumbstickButton, DM_BTN_RS);
    BUTTON(pad.dpad.left, DM_BTN_LEFT); BUTTON(pad.dpad.up, DM_BTN_UP);
    BUTTON(pad.dpad.right, DM_BTN_RIGHT); BUTTON(pad.dpad.down, DM_BTN_DOWN);
#undef BUTTON
    dm_pad_set(buttons, axis(pad.leftThumbstick.xAxis.value), axis(pad.leftThumbstick.yAxis.value),
               axis(pad.rightThumbstick.xAxis.value), axis(pad.rightThumbstick.yAxis.value));
}
static void route_controller(void) {
    // A gamepad must not drive UIKit focus/Home while it drives the game.
    root.controllerUserInteractionEnabled = modal_active || !app_active;
    if (app_active && !modal_active) [root.game becomeFirstResponder];
    reset_pad();
}
static void choose_controller(void) {
    if (active_controller && ![GCController.controllers containsObject:active_controller]) {
        active_controller.extendedGamepad.valueChangedHandler = nil;
        active_controller.playerIndex = GCControllerPlayerIndexUnset;
        active_controller = nil;
        reset_pad();
    }
    if (!active_controller) {
        for (GCController *controller in GCController.controllers) {
            if (!controller.extendedGamepad) continue;
            active_controller = controller;
            controller.playerIndex = GCControllerPlayerIndex1;
            controller.handlerQueue = dispatch_get_main_queue();
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
                if (pad == active_controller.extendedGamepad) publish_pad();
            };
            fprintf(stderr, "controller: %s connected\n", controller.vendorName.UTF8String ?: "extended gamepad");
            break;
        }
    }
    root.controllerHint.hidden = active_controller != nil;
    publish_pad();
}
static void end_modal(void) {
    // UIAlertController finishes dismissing after its action handler returns.
    dispatch_async(dispatch_get_main_queue(), ^{ modal_active = NO; route_controller(); });
}
@implementation TVRoot
- (void)viewDidLoad {
    [super viewDidLoad]; root = self;
    self.view.backgroundColor = UIColor.blackColor;
    if (!front_tv_boot_ok()) {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.text = @"游戏资源不完整，请重新打包安装。\nGame resources are missing. Rebuild the local package.";
        label.numberOfLines = 0; label.textAlignment = NSTextAlignmentCenter; label.textColor = UIColor.whiteColor;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:label]; return;
    }
    self.game = [[TVGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game]; game_layer = (CAMetalLayer *)self.game.layer;
    self.controllerHint = [[UILabel alloc] initWithFrame:CGRectZero];
    self.controllerHint.text = @"请在 Apple TV「设置 → 遥控器与设备 → 蓝牙」连接 PS5 手柄。\nConnect a controller in Apple TV Settings → Remotes and Devices → Bluetooth.";
    self.controllerHint.numberOfLines = 0; self.controllerHint.textAlignment = NSTextAlignmentCenter;
    self.controllerHint.textColor = UIColor.whiteColor; self.controllerHint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    [self.view addSubview:self.controllerHint];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidDisconnectNotification object:nil];
    choose_controller(); route_controller();
}
- (void)controllerChanged:(NSNotification *)notification { choose_controller(); }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = fmin(bounds.size.width, bounds.size.height * 16.0 / 9.0), height = width * 9.0 / 16.0;
    self.game.frame = CGRectMake((bounds.size.width - width) / 2, (bounds.size.height - height) / 2, width, height);
    self.controllerHint.frame = CGRectMake(60, bounds.size.height - 180, bounds.size.width - 120, 130);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; route_controller();
    static BOOL shown; if (shown || !front_tv_boot_ok()) return; shown = YES;
    modal_active = YES; route_controller();
    UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"实验版 / Preview" message:@"存档暂存在本机缓存，系统清理空间或删除应用时可能丢失。\n○ 确认，× 返回，Options 暂停。\n\nSaves use local cache and may be removed by tvOS. Circle: confirm; Cross: back; Options: pause." preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:@"开始 / Start" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { end_modal(); front_tv_boot(); }]];
    [self presentViewController:notice animated:YES completion:nil];
}
@end
UIViewController *front_tv_root(void) { return [TVRoot new]; }
void *front_metal_layer(void) { return (__bridge void *)game_layer; }
uint64_t front_game_res(int docked) { (void)docked; return 720ull << 32 | 1280; }
void front_run(void (*guest)(void)) { guest(); }

int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!game_layer || out_cap < 1) return -1;
    __block int accepted = 0; __block NSString *text;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *heading = title ? @(title) : @"";
    NSString *message = [NSString stringWithFormat:@"%s\n%s", sub ?: "", guide ?: ""];
    NSString *initialText = initial ? @(initial) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!root || root.presentedViewController) { dispatch_semaphore_signal(done); return; }
        modal_active = YES; route_controller();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:heading message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = initialText; }];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定 / OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            text = alert.textFields.firstObject.text; accepted = 1; end_modal(); dispatch_semaphore_signal(done);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消 / Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { end_modal(); dispatch_semaphore_signal(done); }]];
        [root presentViewController:alert animated:YES completion:nil];
    });
    guest_clock_freeze_for(2, 1);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    guest_clock_freeze_for(2, 0);
    if (accepted) snprintf(out, out_cap, "%s", text.UTF8String ?: "");
    return accepted;
}
void front_save_failed(int error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        fprintf(stderr, "save: failed errno=%d\n", error);
        if (!root || root.presentedViewController) return;
        modal_active = YES; route_controller();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"存档失败 / Save failed" message:@"进度未保存，请检查 Apple TV 的可用空间。\nProgress was not saved. Check available storage." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定 / OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { end_modal(); }]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}
void front_tv_audio_session(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setPreferredSampleRate:48000 error:nil];
    [session setPreferredIOBufferDuration:0.005 error:nil];
    [session setActive:YES error:nil];
}
void front_tv_focus_event(int event) {
    switch (event) {
        case 0: app_active = NO; route_controller(); dm_focus_set(2); break;
        case 1: reset_pad(); dm_focus_set(3); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_tv_audio_session(); dm_audio_suspend(0); dm_focus_set(2); break;
        case 3: app_active = YES; route_controller(); choose_controller(); dm_focus_set(1); break;
    }
}
