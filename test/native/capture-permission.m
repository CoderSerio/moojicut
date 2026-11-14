#if !defined(CGPreflightScreenCaptureAccess) || !defined(CGRequestScreenCaptureAccess)
#error "Compile this test and MCCaptureController.m with both CG permission APIs redirected to MCFakePreflight/MCFakeRequest."
#endif
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "capture/MCCaptureController.h"
#include "moonbit.h"

// Compile MCCaptureController.m with both CG APIs redirected to these fakes.
// No real TCC request, screencapture process, modal window, or clipboard access
// is permitted by this test, even when checking the granted branch.
static bool preflightResult, requestResult;
static NSUInteger preflightCalls, requestCalls, alertCalls, unexpectedLaunches;
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
- (void)mc_permission_hide:(id)sender { (void)sender; }
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
- (void)launchWhenKeysReleased:(NSTask *)task attempts:(NSUInteger)attempts;
@end
@interface MCPermissionCapture : MCCaptureController
@property NSUInteger launchCount;
@property BOOL invalidLaunch;
@end
@implementation MCPermissionCapture
- (void)launchWhenKeysReleased:(NSTask *)task attempts:(NSUInteger)attempts {
    self.launchCount++;
    self.invalidLaunch = task == nil || task.running || attempts != 0;
}
@end

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
            CHECK(!controller.invalidLaunch, "the granted request supplies a new unstarted task");
            controller = nil;

            reset(true, false);
            controller = [MCPermissionCapture new];
            [controller capture];
            CHECK(preflightCalls == 1 && requestCalls == 0 && alertCalls == 0 && controller.launchCount == 1,
                  "an existing grant bypasses permission UI and reaches launch");
            CHECK(!controller.invalidLaunch, "an existing grant supplies a new unstarted task");
            controller = nil;
            CHECK(unexpectedLaunches == 0, "no NSTask launch API was invoked");
        } @finally {
            reentrantController = nil;
            toggleInterceptions();
        }
        printf("Capture permission sequencing (fake TCC, intercepted launch, no modal UI): %s\n",
               passed ? "passed" : "FAILED");
        return passed ? 0 : 1;
    }
}
