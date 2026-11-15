#if !defined(CGPreflightScreenCaptureAccess) || !defined(CGRequestScreenCaptureAccess)
#error "Compile this test and MCCaptureController.m with both CG permission APIs redirected to MCFakePreflight/MCFakeRequest."
#endif
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "plugins/feature/capture/macos/MCCaptureController.h"
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "moonbit.h"

// Compile MCCaptureController.m with both CG APIs redirected to these fakes.
// No real TCC request, screencapture process, modal window, or clipboard access
// is permitted by this test, even when checking the granted branch.
static bool preflightResult, requestResult;
static NSUInteger preflightCalls, requestCalls, alertCalls, unexpectedLaunches, unexpectedCaptures, appHides;
static __weak MCCaptureController *reentrantController;

bool MCFakePreflight(void) { preflightCalls++; return preflightResult; }
bool MCFakeRequest(void) { requestCalls++; return requestResult; }

@interface NSAlert (MCPermissionTest)
- (NSModalResponse)mc_permission_runModal;
@end
@implementation NSAlert (MCPermissionTest)
- (NSModalResponse)mc_permission_runModal {
    alertCalls++;
    MCCaptureController *controller = reentrantController;
    reentrantController = nil;
    [controller capture]; // A nested shortcut must not stack another help alert.
    return NSAlertThirdButtonReturn; // Cancel; never open System Settings/Finder.
}
@end

@interface NSApplication (MCPermissionTest)
- (void)mc_permission_activateIgnoringOtherApps:(BOOL)flag;
- (void)mc_permission_hide:(id)sender;
@end
@implementation NSApplication (MCPermissionTest)
- (void)mc_permission_activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (void)mc_permission_hide:(id)sender { (void)sender; appHides++; }
@end

@interface NSTask (MCPermissionTest)
- (BOOL)mc_permission_launchAndReturnError:(NSError **)error;
- (void)mc_permission_launch;
@end
@implementation NSTask (MCPermissionTest)
- (BOOL)mc_permission_launchAndReturnError:(NSError **)error {
    unexpectedLaunches++;
    if (error) *error = [NSError errorWithDomain:@"MoojiCut.PermissionTest" code:1 userInfo:nil];
    return NO;
}
- (void)mc_permission_launch { unexpectedLaunches++; }
@end

@interface MCCaptureController (MCPermissionTestHooks)
- (void)captureWhenKeysReleased:(NSString *)session attempts:(NSUInteger)attempts;
- (void)captureDisplaysForSession:(NSString *)session;
- (NSArray<NSDictionary *> *)screenDescriptors;
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion;
- (void)captureDisplay:(SCDisplay *)display excludingApplications:(NSArray<SCRunningApplication *> *)applications
        exceptingWindows:(NSArray<SCWindow *> *)windows
            completion:(void (^)(NSData *, NSError *))completion;
- (NSArray<NSWindow *> *)captureWindows;
- (NSEventModifierFlags)captureModifierFlags;
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
- (void)screenParametersChanged:(NSNotification *)notification;
- (NSRunningApplication *)frontmostApplication;
- (void)prepareCaptureFocus;
- (void)restoreCaptureFocus:(NSRunningApplication *)application;
@end
@interface MCFakeDisplay : NSObject
@property CGDirectDisplayID displayID;
@end
@implementation MCFakeDisplay
@end
@interface MCFakeContent : NSObject
@property NSArray *displays;
@property NSArray *applications;
@property NSArray *windows;
@end
@implementation MCFakeContent
@end
@interface MCFakeApplication : NSObject
@property pid_t processID;
@end
@implementation MCFakeApplication
@end
@interface MCFakeCaptureWindow : NSObject
@property CGWindowID windowID;
@property MCFakeApplication *owningApplication;
@end
@implementation MCFakeCaptureWindow
@end
@interface MCFakeOwnWindow : NSObject
@property NSInteger windowNumber;
@property (getter=isVisible) BOOL visible;
@property NSUInteger orderOutCalls;
- (void)orderOut:(id)sender;
@end
@implementation MCFakeOwnWindow
- (void)orderOut:(id)sender { (void)sender; self.visible = NO; self.orderOutCalls++; }
@end
@interface MCFakeRunningApplication : NSObject
@property pid_t processIdentifier;
@end
@implementation MCFakeRunningApplication
@end
@interface MCFakeOverlay : MCImageEditorController
@property NSUInteger shows;
@property NSUInteger cancellations;
@end
@implementation MCFakeOverlay
- (void)show { self.shows++; }
- (void)cancel:(id)sender {
    (void)sender;
    self.cancellations++;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    if (closed) closed();
}
@end
@interface MCPermissionCapture : MCCaptureController
@property NSUInteger launchCount;
@property BOOL invalidLaunch;
@property NSString *interceptedSession;
@property (copy) void (^pendingContent)(SCShareableContent *, NSError *);
@property NSMutableDictionary<NSNumber *, id> *imageCompletions;
@property NSMutableArray<NSNumber *> *requestedDisplayIDs;
@property NSMutableArray<NSDictionary *> *createdSnapshots;
@property NSMutableArray<MCFakeOverlay *> *createdEditors;
@property NSArray *excludedApplications;
@property NSArray<SCWindow *> *includedWindows;
@property NSArray *fakeWindows;
@property BOOL realFocusPreparation, realKeyReleaseCheck;
@property NSRunningApplication *fakeFrontmost;
@property NSRunningApplication *restoredApplication;
@property NSMutableArray<NSString *> *focusEvents;
@end
@implementation MCPermissionCapture
- (instancetype)init {
    if ((self = [super init])) {
        _imageCompletions = [NSMutableDictionary dictionary];
        _requestedDisplayIDs = [NSMutableArray array];
        _createdSnapshots = [NSMutableArray array];
        _createdEditors = [NSMutableArray array];
        _focusEvents = [NSMutableArray array];
        MCFakeRunningApplication *external = [MCFakeRunningApplication new];
        external.processIdentifier = NSProcessInfo.processInfo.processIdentifier + 1;
        _fakeFrontmost = (NSRunningApplication *)external;
    }
    return self;
}
- (NSRunningApplication *)frontmostApplication { return self.fakeFrontmost; }
- (NSArray<NSWindow *> *)captureWindows { return self.fakeWindows ?: @[]; }
- (NSEventModifierFlags)captureModifierFlags { return 0; }
- (void)prepareCaptureFocus {
    if (self.realFocusPreparation) [super prepareCaptureFocus];
    [self.focusEvents addObject:@"prepare"];
}
- (void)restoreCaptureFocus:(NSRunningApplication *)application {
    self.restoredApplication = application;
    [self.focusEvents addObject:@"restore"];
}
- (void)captureWhenKeysReleased:(NSString *)session attempts:(NSUInteger)attempts {
    if (self.realKeyReleaseCheck) { [super captureWhenKeysReleased:session attempts:attempts]; return; }
    self.launchCount++;
    self.invalidLaunch = session.length == 0 || attempts != 0;
    self.interceptedSession = session;
}
- (NSArray<NSDictionary *> *)screenDescriptors {
    return @[
        @{@"displayID":@14, @"frame":[NSValue valueWithRect:NSMakeRect(0,0,1440,900)]},
        @{@"displayID":@27, @"frame":[NSValue valueWithRect:NSMakeRect(-1920,-180,1920,1080)]}
    ];
}
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion { self.pendingContent = completion; }
- (void)captureDisplay:(SCDisplay *)display excludingApplications:(NSArray<SCRunningApplication *> *)applications
        exceptingWindows:(NSArray<SCWindow *> *)windows
            completion:(void (^)(NSData *, NSError *))completion {
    [self.requestedDisplayIDs addObject:@(display.displayID)];
    self.imageCompletions[@(display.displayID)] = [completion copy];
    self.excludedApplications = applications;
    self.includedWindows = windows;
}
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    (void)error;
    [self.createdSnapshots addObject:snapshot];
    MCFakeOverlay *editor = [MCFakeOverlay new];
    [self.createdEditors addObject:editor];
    return editor;
}
@end

// Last-resort interceptions make an accidental call to a real capture API fail
// this test without reading the desktop, even if a future refactor bypasses a fake.
@interface SCShareableContent (MCPermissionTest)
+ (void)mc_permission_content:(BOOL)exclude onScreenWindowsOnly:(BOOL)onScreen completionHandler:(void (^)(SCShareableContent *, NSError *))completion;
@end
@implementation SCShareableContent (MCPermissionTest)
+ (void)mc_permission_content:(BOOL)exclude onScreenWindowsOnly:(BOOL)onScreen completionHandler:(void (^)(SCShareableContent *, NSError *))completion {
    (void)exclude; (void)onScreen;
    unexpectedCaptures++;
    completion(nil, [NSError errorWithDomain:@"MoojiCut.PermissionTest" code:1 userInfo:nil]);
}
@end
@interface SCScreenshotManager (MCPermissionTest)
+ (void)mc_permission_image:(SCContentFilter *)filter configuration:(SCStreamConfiguration *)configuration
        completionHandler:(void (^)(CGImageRef, NSError *))completion;
@end
@implementation SCScreenshotManager (MCPermissionTest)
+ (void)mc_permission_image:(SCContentFilter *)filter configuration:(SCStreamConfiguration *)configuration
        completionHandler:(void (^)(CGImageRef, NSError *))completion {
    (void)filter; (void)configuration;
    unexpectedCaptures++;
    completion(NULL, [NSError errorWithDomain:@"MoojiCut.PermissionTest" code:1 userInfo:nil]);
}
@end

static SCShareableContent *fakeContent(NSArray<NSNumber *> *ids) {
    MCFakeContent *content = [MCFakeContent new];
    NSMutableArray *displays = [NSMutableArray array];
    for (NSNumber *identifier in ids) {
        MCFakeDisplay *display = [MCFakeDisplay new]; display.displayID = identifier.unsignedIntValue;
        [displays addObject:display];
    }
    content.displays = displays;
    MCFakeApplication *ownApplication = [MCFakeApplication new];
    ownApplication.processID = NSProcessInfo.processInfo.processIdentifier;
    MCFakeApplication *otherApplication = [MCFakeApplication new]; otherApplication.processID = 1;
    content.applications = @[otherApplication, ownApplication];
    NSMutableArray *windows = [NSMutableArray array];
    // 101: Settings, 201: visible pin, 202: user-hidden pin, 401: other app.
    for (NSNumber *number in @[@101,@201,@202,@401]) {
        MCFakeCaptureWindow *window = [MCFakeCaptureWindow new]; window.windowID = number.unsignedIntValue;
        window.owningApplication = number.intValue == 401 ? otherApplication : ownApplication;
        [windows addObject:window];
    }
    content.windows = windows;
    return (SCShareableContent *)content;
}
static void drainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    }
    NSCAssert(drained, @"The test must drain asynchronous capture completions");
}
static void finishImage(MCPermissionCapture *controller, NSNumber *displayID, NSString *pixels, NSError *error) {
    void (^completion)(NSData *, NSError *) = controller.imageCompletions[displayID];
    NSCAssert(completion, @"Expected an intercepted screenshot request");
    completion([pixels dataUsingEncoding:NSUTF8StringEncoding], error);
    drainMainQueue();
}

static void exchange(Class type, SEL original, SEL replacement) {
    Method first = class_getInstanceMethod(type, original);
    Method second = class_getInstanceMethod(type, replacement);
    NSCAssert(first && second, @"The test interception methods must exist");
    method_exchangeImplementations(first, second);
}
static void toggleInterceptions(void) {
    exchange(NSAlert.class, @selector(runModal), @selector(mc_permission_runModal));
    exchange(NSApplication.class, @selector(activateIgnoringOtherApps:), @selector(mc_permission_activateIgnoringOtherApps:));
    exchange(NSApplication.class, @selector(hide:), @selector(mc_permission_hide:));
    exchange(NSTask.class, @selector(launchAndReturnError:), @selector(mc_permission_launchAndReturnError:));
    exchange(NSTask.class, @selector(launch), @selector(mc_permission_launch));
    exchange(object_getClass(SCShareableContent.class),
        @selector(getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:),
        @selector(mc_permission_content:onScreenWindowsOnly:completionHandler:));
    if (@available(macOS 14.0, *)) {
        exchange(object_getClass(SCScreenshotManager.class), @selector(captureImageWithFilter:configuration:completionHandler:),
            @selector(mc_permission_image:configuration:completionHandler:));
    }
}
static void reset(bool preflight, bool request) {
    preflightResult = preflight; requestResult = request;
    preflightCalls = requestCalls = alertCalls = 0;
    reentrantController = nil;
}
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); passed = NO; } \
} while (0)

int main(void) {
    @autoreleasepool {
        moonbit_init();
        BOOL passed = YES;
        toggleInterceptions();
        @try {
            // The first denied/pending request must return to the system prompt.
            reset(false, false);
            MCPermissionCapture *controller = [MCPermissionCapture new];
            [controller capture];
            CHECK(preflightCalls == 1 && requestCalls == 1, "first capture requests permission once");
            CHECK(alertCalls == 0, "a pending system request must not be covered by an app alert");
            CHECK(controller.launchCount == 0 && !controller.busy, "denied permission never reaches launch");

            // Only the next explicit capture offers help; nested input is ignored.
            reentrantController = controller;
            [controller capture];
            CHECK(preflightCalls == 2 && requestCalls == 1, "retry does not repeat the system request");
            CHECK(alertCalls == 1 && controller.launchCount == 0 && !controller.busy,
                  "retry presents one help alert and suppresses a nested capture");
            [controller capture];
            CHECK(alertCalls == 2 && requestCalls == 1, "cancelled help allows a later explicit retry");

            preflightResult = true;
            [controller capture];
            CHECK(controller.launchCount == 1 && !controller.invalidLaunch && controller.busy,
                  "permission granted on retry reaches the intercepted launch");
            CHECK(requestCalls == 1 && alertCalls == 2, "granted retry does not show more permission UI");
            NSUInteger checksBeforeBusyRetry = preflightCalls;
            preflightResult = false;
            [controller capture];
            CHECK(controller.launchCount == 1 && preflightCalls == checksBeforeBusyRetry,
                  "an active capture does not launch or request permission again");
            controller = nil;

            reset(false, true);
            controller = [MCPermissionCapture new];
            [controller capture];
            CHECK(preflightCalls == 1 && requestCalls == 1 && alertCalls == 0 && controller.launchCount == 1,
                  "a successful initial permission request proceeds without an app alert");
            CHECK(!controller.invalidLaunch, "the granted request supplies a new capture session");
            controller = nil;

            reset(true, false);
            controller = [MCPermissionCapture new];
            [controller capture];
            CHECK(preflightCalls == 1 && requestCalls == 0 && alertCalls == 0 && controller.launchCount == 1,
                  "an existing grant bypasses permission UI and reaches launch");
            CHECK(!controller.invalidLaunch, "an existing grant supplies a new capture session");
            controller = nil;
            // Capture never hides the application or a visible pin. Explicit
            // window filtering also removes the need for a fixed post-key delay.
            reset(true, false);
            controller = [MCPermissionCapture new];
            controller.realFocusPreparation = YES;
            controller.realKeyReleaseCheck = YES;
            MCFakeOwnWindow *settings = [MCFakeOwnWindow new]; settings.windowNumber = 101; settings.visible = YES;
            MCFakeOwnWindow *pin = [MCFakeOwnWindow new]; pin.windowNumber = 201; pin.visible = YES;
            MCFakeOwnWindow *hiddenPin = [MCFakeOwnWindow new]; hiddenPin.windowNumber = 202;
            controller.fakeWindows = @[settings,pin,hiddenPin];
            controller.includedWindowNumbers = ^{ return [NSSet setWithObject:@201]; };
            [controller capture];
            CHECK(!settings.visible && settings.orderOutCalls == 1 && pin.visible && pin.orderOutCalls == 0 &&
                  !hiddenPin.visible && hiddenPin.orderOutCalls == 0 && appHides == 0,
                  "capture orders out host controls without hiding the app, visible pins or restoring hidden pins");
            CHECK(controller.pendingContent != nil, "released keys begin content acquisition immediately without a hide delay");
            [controller cancelCapture];
            CHECK(pin.visible && !hiddenPin.visible, "cancelling capture does not change pin visibility");
            controller = nil;
            // Display enumeration order differs from NSScreen order; callbacks
            // complete out of order. Both snapshots must retain their own frame.
            reset(true, false);
            controller = [MCPermissionCapture new];
            NSMutableSet *visibleNumbers = [NSMutableSet setWithObjects:@201,@401,nil];
            controller.includedWindowNumbers = ^{ return visibleNumbers; };
            __block NSUInteger pinCalls = 0;
            controller.onPinPNGData = ^BOOL(NSData *data, NSRect screenFrame) { (void)screenFrame; pinCalls++; return data.length > 0; };
            [controller capture];
            [visibleNumbers removeAllObjects]; // Session owns its visibility snapshot.
            [controller captureDisplaysForSession:controller.interceptedSession];
            controller.pendingContent(fakeContent(@[@27,@14]), nil);
            drainMainQueue();
            CHECK(([controller.requestedDisplayIDs isEqual:@[@14,@27]]), "display IDs map snapshots to NSScreen frames, not enumeration indices");
            CHECK(controller.excludedApplications.count == 1 &&
                  [(SCRunningApplication *)controller.excludedApplications.firstObject processID] == NSProcessInfo.processInfo.processIdentifier,
                  "the app exclusion still removes Settings and other host controls");
            CHECK(controller.includedWindows.count == 1 && controller.includedWindows.firstObject.windowID == 201,
                  "visible own pins are re-included in captured pixels; hidden pins and foreign windows are not exceptions");
            finishImage(controller, @27, @"left screen pixels", nil);
            CHECK(controller.createdEditors.count == 0, "no overlay is shown while any screen is still being captured");
            finishImage(controller, @14, @"main screen pixels", nil);
            CHECK(controller.createdEditors.count == 2 && controller.createdEditors[0].shows == 1 && controller.createdEditors[1].shows == 1,
                  "all frozen overlays are shown after every image has arrived");
            CHECK(NSEqualRects([controller.createdSnapshots[1][@"frame"] rectValue], NSMakeRect(-1920,-180,1920,1080)) &&
                  [controller.createdSnapshots[1][@"png"] isEqual:[@"left screen pixels" dataUsingEncoding:NSUTF8StringEncoding]],
                  "secondary display keeps its negative coordinates and corresponding pixels");
            CHECK(controller.createdEditors[1].onPinPNGData([@"pin" dataUsingEncoding:NSUTF8StringEncoding]) && pinCalls == 1,
                  "overlay pin actions delegate the final PNG to the application");
            BOOL (^oldPinAction)(NSData *) = controller.createdEditors[1].onPinPNGData;
            controller.onPinPNGData = nil;
            CHECK(!controller.createdEditors[0].onPinPNGData && !controller.createdEditors[1].onPinPNGData && controller.busy,
                  "disabling pin capability clears all active overlay actions without canceling editing");
            CHECK(!oldPinAction([@"pin" dataUsingEncoding:NSUTF8StringEncoding]) && pinCalls == 1,
                  "a retained pin callback cannot invoke a capability removed while editing");
            controller.onPinPNGData = ^BOOL(NSData *data, NSRect frame) { (void)frame; pinCalls++; return data.length > 0; };
            CHECK(controller.createdEditors[0].onPinPNGData && controller.createdEditors[1].onPinPNGData && controller.busy,
                  "re-enabling pin capability updates existing editors in place");
            [controller.createdEditors[1] cancel:nil];
            CHECK(!controller.busy && controller.createdEditors[0].cancellations > 0 && controller.createdEditors[1].cancellations > 0,
                  "closing any overlay closes the whole capture session");
            controller = nil;

            // Cancellation and monitor reconfiguration invalidate asynchronous
            // results. A stale callback must not reopen an old capture session.
            reset(true, false);
            controller = [MCPermissionCapture new];
            [controller capture];
            [controller captureDisplaysForSession:controller.interceptedSession];
            void (^oldContent)(SCShareableContent *, NSError *) = controller.pendingContent;
            [controller cancelCapture];
            CHECK(!controller.busy, "pending capture can be cancelled");
            [controller capture];
            oldContent(fakeContent(@[@14,@27]), nil);
            drainMainQueue();
            CHECK(controller.busy && controller.requestedDisplayIDs.count == 0, "late content from a cancelled session cannot affect the new session");
            [controller screenParametersChanged:nil];
            CHECK(!controller.busy && controller.createdEditors.count == 0, "monitor changes cancel pending capture without showing an overlay");
            controller = nil;

            // App focus is restored before a newly confirmed pin can take key. All app
            // access and activation is intercepted; no external app is touched.
            reset(true, false);
            controller = [MCPermissionCapture new];
            __weak MCPermissionCapture *weakCapture = controller;
            controller.onStateChange = ^{
                MCPermissionCapture *current = weakCapture;
                [current.focusEvents addObject:current.busy ? @"busy" : @"idle"];
            };
            NSRunningApplication *external = controller.fakeFrontmost;
            [controller capture];
            [controller capture];
            [controller cancelCapture];
            CHECK(controller.restoredApplication == external, "capture returns focus to the original external application");
            CHECK(([controller.focusEvents isEqual:@[@"busy", @"prepare", @"restore", @"idle"]]),
                  "prepare runs once and focus restores before a new pin can appear");
            [controller cancelCapture];
            CHECK(controller.focusEvents.count == 4, "cancelling an ended session does not steal focus again");
            MCFakeRunningApplication *ownApplication = [MCFakeRunningApplication new];
            ownApplication.processIdentifier = NSProcessInfo.processInfo.processIdentifier;
            controller.fakeFrontmost = (NSRunningApplication *)ownApplication;
            [controller capture];
            [controller cancelCapture];
            CHECK(controller.restoredApplication == nil, "a capture started from Settings does not reactivate Settings afterwards");
            controller = nil;

            // A missing screen or a failed screenshot produces no partial UI.
            reset(true, false);
            controller = [MCPermissionCapture new];
            [controller capture];
            [controller captureDisplaysForSession:controller.interceptedSession];
            controller.pendingContent(fakeContent(@[@14]), nil);
            drainMainQueue();
            CHECK(!controller.busy && controller.requestedDisplayIDs.count == 0 && alertCalls == 1,
                  "a missing display is reported before any screenshots or overlays are created");
            controller = nil;
            reset(true, false);
            controller = [MCPermissionCapture new];
            [controller capture];
            [controller captureDisplaysForSession:controller.interceptedSession];
            controller.pendingContent(fakeContent(@[@14,@27]), nil);
            drainMainQueue();
            finishImage(controller, @14, nil, [NSError errorWithDomain:@"SyntheticCaptureFailure" code:1 userInfo:nil]);
            finishImage(controller, @27, @"late pixels", nil);
            CHECK(!controller.busy && controller.createdEditors.count == 0 && alertCalls == 1,
                  "screenshot failure closes the session and discards late results");
            controller = nil;
            CHECK(unexpectedLaunches == 0 && unexpectedCaptures == 0, "no real process or ScreenCaptureKit capture API was invoked");
        } @finally {
            reentrantController = nil;
            toggleInterceptions();
        }
        printf("Capture sessions (fake TCC/pixels, display mapping, cancellation, pin dispatch, no modal UI): %s\n",
               passed ? "passed" : "FAILED");
        return passed ? 0 : 1;
    }
}
