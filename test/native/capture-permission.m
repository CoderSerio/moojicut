#if !defined(CGPreflightScreenCaptureAccess) || !defined(CGRequestScreenCaptureAccess)
#error "Compile this test and MCCaptureController.m with both CG permission APIs redirected to MCFakePreflight/MCFakeRequest."
#endif
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "plugins/feature/capture/macos/MCCaptureController.h"
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "moonbit.h"
#include <string.h>

// Compile MCCaptureController.m with both CG APIs redirected to these fakes.
// No real TCC request, screencapture process, modal window, or clipboard access
// is permitted by this test, even when checking the granted branch.
static bool preflightResult, requestResult;
static NSUInteger preflightCalls, requestCalls, alertCalls, unexpectedLaunches, unexpectedCaptures, appHides;
static __weak MCCaptureController *reentrantController;
static NSMutableArray<NSWindow *> *shownWindows;
static NSMutableArray<NSWindow *> *keyWindows;
static NSMutableArray<NSWindow *> *orderedOutWindows;

@interface MCImageCanvas : NSView
@property NSTextView *textView;
- (BOOL)finishTextEditing:(BOOL)commit;
@end
@interface MCImageEditorController (MCSuspensionTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSTextField *fontSize;
@property (readonly) NSSegmentedControl *tools;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)addTextAtPoint:(NSPoint)point;
- (void)chooseTool:(id)sender;
@end
@interface NSWindow (MCSuspensionTest)
- (void)mc_permission_orderOut:(id)sender;
- (void)mc_permission_orderFront:(id)sender;
- (void)mc_permission_makeKeyAndOrderFront:(id)sender;
@end
@implementation NSWindow (MCSuspensionTest)
- (void)mc_permission_orderFront:(id)sender {
    (void)sender;
    [shownWindows addObject:self]; // Never order a fixture window onto the desktop.
}
- (void)mc_permission_makeKeyAndOrderFront:(id)sender {
    (void)sender;
    [shownWindows addObject:self];
    [keyWindows addObject:self];
}
- (void)mc_permission_orderOut:(id)sender {
    [orderedOutWindows addObject:self];
    [self mc_permission_orderOut:sender];
}
@end

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
- (void)mc_permission_unhide:(id)sender;
@end
@implementation NSApplication (MCPermissionTest)
- (void)mc_permission_activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (void)mc_permission_hide:(id)sender { (void)sender; appHides++; }
- (void)mc_permission_unhide:(id)sender { (void)sender; }
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
@property (readonly) NSString *captureSession;
@property (readonly) MCImageEditorController *editor;
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
@interface MCFakeTrackingMenu : NSMenu
@property NSUInteger cancellations;
@end
@implementation MCFakeTrackingMenu
- (void)cancelTrackingWithoutAnimation {
    self.cancellations++;
    [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidEndTrackingNotification object:self];
}
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
@property NSEventModifierFlags heldModifiers;
@property BOOL realEditors;
@property NSMutableArray<MCImageEditorController *> *realCreatedEditors;
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
        _realCreatedEditors = [NSMutableArray array];
        _focusEvents = [NSMutableArray array];
        MCFakeRunningApplication *external = [MCFakeRunningApplication new];
        external.processIdentifier = NSProcessInfo.processInfo.processIdentifier + 1;
        _fakeFrontmost = (NSRunningApplication *)external;
    }
    return self;
}
- (NSRunningApplication *)frontmostApplication { return self.fakeFrontmost; }
- (NSArray<NSWindow *> *)captureWindows { return self.fakeWindows ?: @[]; }
- (NSEventModifierFlags)captureModifierFlags { return self.heldModifiers; }
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
    [self.createdSnapshots addObject:snapshot];
    if (self.realEditors) {
        MCImageEditorController *editor = [super editorForSnapshot:snapshot error:error];
        if (editor) [self.realCreatedEditors addObject:editor];
        return editor;
    }
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
    // 101: Settings, 201: visible pin, 202: hidden pin, 301: video editor, 401: other app.
    for (NSNumber *number in @[@101,@201,@202,@301,@401]) {
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
static void finishPNG(MCPermissionCapture *controller, NSNumber *displayID, NSData *pixels, NSError *error) {
    void (^completion)(NSData *, NSError *) = controller.imageCompletions[displayID];
    NSCAssert(completion, @"Expected an intercepted screenshot request");
    completion(pixels, error);
    drainMainQueue();
}
static void finishImage(MCPermissionCapture *controller, NSNumber *displayID, NSString *pixels, NSError *error) {
    finishPNG(controller, displayID, [pixels dataUsingEncoding:NSUTF8StringEncoding], error);
}
static NSData *syntheticPNG(NSInteger width, NSInteger height) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:width * 4 bitsPerPixel:32];
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * height);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static void completeSyntheticScreens(MCPermissionCapture *controller, NSData *png) {
    [controller captureDisplaysForSession:controller.interceptedSession];
    controller.pendingContent(fakeContent(@[@27,@14]), nil);
    drainMainQueue();
    finishPNG(controller, @27, png, nil);
    finishPNG(controller, @14, png, nil);
}

static void exchange(Class type, SEL original, SEL replacement) {
    Method first = class_getInstanceMethod(type, original);
    Method second = class_getInstanceMethod(type, replacement);
    NSCAssert(first && second, @"The test interception methods must exist");
    method_exchangeImplementations(first, second);
}
static void toggleInterceptions(void) {
    exchange(NSWindow.class, @selector(orderOut:), @selector(mc_permission_orderOut:));
    exchange(NSWindow.class, @selector(orderFront:), @selector(mc_permission_orderFront:));
    exchange(NSWindow.class, @selector(makeKeyAndOrderFront:), @selector(mc_permission_makeKeyAndOrderFront:));
    exchange(NSAlert.class, @selector(runModal), @selector(mc_permission_runModal));
    exchange(NSApplication.class, @selector(activateIgnoringOtherApps:), @selector(mc_permission_activateIgnoringOtherApps:));
    exchange(NSApplication.class, @selector(hide:), @selector(mc_permission_hide:));
    exchange(NSApplication.class, @selector(unhide:), @selector(mc_permission_unhide:));
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

static BOOL exerciseSuspendedCapture(void) {
    BOOL passed = YES;
    reset(true, false);
    shownWindows = [NSMutableArray array];
    keyWindows = [NSMutableArray array];
    orderedOutWindows = [NSMutableArray array];
    NSData *png = syntheticPNG(800, 500);
    NSData *longPNG = syntheticPNG(640, 1200);
    MCPermissionCapture *controller = [MCPermissionCapture new];
    controller.realEditors = YES;
    controller.realFocusPreparation = YES;
    MCFakeOwnWindow *pin = [MCFakeOwnWindow new]; pin.windowNumber = 201; pin.visible = YES;
    MCFakeOwnWindow *hiddenPin = [MCFakeOwnWindow new]; hiddenPin.windowNumber = 202;
    controller.fakeWindows = @[pin,hiddenPin];
    controller.includedWindowNumbers = ^{ return [NSSet setWithObject:@201]; };
    NSMutableArray<NSNumber *> *busySamples = [NSMutableArray array];
    NSMutableArray<NSString *> *closedContexts = [NSMutableArray array];
    __weak MCPermissionCapture *weakCapture = controller;
    controller.onStateChange = ^{ [busySamples addObject:@(weakCapture.busy)]; };
    controller.onPluginContextClosed = ^(NSString *identifier) {
        [closedContexts addObject:identifier];
        [busySamples addObject:@(weakCapture.busy)];
    };
    NSMutableArray<MCImageEditorController *> *ocrCalls = [NSMutableArray array];
    NSMutableArray<MCImageEditorController *> *translateCalls = [NSMutableArray array];
    NSMutableArray<MCImageEditorController *> *scrollCalls = [NSMutableArray array];
    controller.onOCR = ^(MCImageEditorController *editor) { [ocrCalls addObject:editor]; };
    controller.onTranslate = ^(MCImageEditorController *editor) { [translateCalls addObject:editor]; };
    controller.onScrollCapture = ^(MCImageEditorController *editor) { [scrollCalls addObject:editor]; };
    controller.onPinPNGData = ^BOOL(NSData *data, NSRect frame) { (void)frame; return data.length > 0; };
    [controller capture];
    CHECK(![controller suspendCaptureForEditor:[MCImageEditorController new] error:NULL] && controller.busy,
          "a pending capture cannot be suspended before its overlays exist");
    completeSyntheticScreens(controller, png);
    CHECK(controller.realCreatedEditors.count == 2 && shownWindows.count == 2,
          "suspension fixture creates two real editors from synthetic screen pixels");
    if (controller.realCreatedEditors.count != 2) { [controller cancelCapture]; return NO; }
    MCImageEditorController *first = controller.realCreatedEditors[0];
    MCImageEditorController *focused = controller.realCreatedEditors[1];
    NSArray *overlays = @[first, focused];
    NSArray *overlayWindows = @[first.window, focused.window];
    for (MCImageEditorController *editor in overlays) {
        CHECK(editor.onOCR && editor.onTranslate && editor.onScrollCapture && editor.onPinPNGData,
              "new screen overlays inherit OCR, translation, scrolling and pin actions");
        if (editor.onOCR) editor.onOCR(editor);
        if (editor.onTranslate) editor.onTranslate(editor);
        if (editor.onScrollCapture) editor.onScrollCapture(editor);
    }
    CHECK([ocrCalls isEqual:overlays] && [translateCalls isEqual:overlays] && [scrollCalls isEqual:overlays],
          "overlay actions pass their own editor to the configured callbacks");
    CHECK([focused setCaptureRegion:NSMakeRect(20,20,700,440)], "suspension fixture has a selected region");
    CHECK(([focused applyAnnotation:@{@"id":@"retained", @"type":@"rect", @"x":@60, @"y":@60,
        @"width":@100, @"height":@80, @"stroke":@3, @"opacity":@1, @"color":@"#dd2222"}]),
          "suspension fixture has an undoable annotation");
    CHECK([first setCaptureRegion:NSMakeRect(20,20,700,440)], "second overlay can keep independent property input");
    for (MCImageEditorController *editor in overlays) {
        for (NSInteger index = 0; index < editor.tools.segmentCount; index++) {
            if ([editor.tools tagForSegment:index] != 3) continue;
            editor.tools.selectedSegment = index;
            [editor chooseTool:editor.tools];
            break;
        }
    }
    [first.window makeFirstResponder:first.fontSize];
    NSText *numericInput = first.fontSize.currentEditor;
    numericInput.string = @"48";
    NSDictionary *numericDocument = first.document;
    NSDictionary *numericSnapshot = first.captureContentSnapshot;
    [focused addTextAtPoint:NSMakePoint(160,180)];
    focused.canvas.textView.string = @"unfinished text stays editable";
    [focused.window makeFirstResponder:focused.canvas.textView];
    NSTextView *textInput = focused.canvas.textView;
    CHECK(numericInput && first.window.firstResponder == numericInput &&
          textInput && focused.window.firstResponder == textInput,
          "fixture has real text and numeric first responders, not simulated draft dictionaries");
    NSDictionary *document = focused.document;
    NSDictionary *snapshot = focused.captureContentSnapshot;
    NSString *session = controller.captureSession;
    CHECK([document[@"undo"] count] == 1 && focused.canvas.textView != nil,
          "fixture retains both document undo and an uncommitted text draft");
    NSError *error = nil;
    [shownWindows removeAllObjects];
    [keyWindows removeAllObjects];
    [orderedOutWindows removeAllObjects];
    [busySamples removeAllObjects];
    CHECK([controller suspendCaptureForEditor:focused error:&error] && error == nil,
          "a current selected overlay can suspend its capture session");
    CHECK([orderedOutWindows isEqual:overlayWindows] && shownWindows.count == 0,
          "suspension orders out precisely the frozen overlays without recreating them");
    CHECK(controller.restoredApplication == controller.fakeFrontmost && controller.busy &&
          [controller.captureSession isEqual:session] && [focused.document isEqual:document] &&
          [focused.captureContentSnapshot isEqual:snapshot] && closedContexts.count == 0,
          "suspension restores external focus while preserving the session, document, draft and plugin context");
    CHECK(pin.visible && pin.orderOutCalls == 0 && !hiddenPin.visible && hiddenPin.orderOutCalls == 0 && appHides == 0,
          "suspension leaves visible and hidden pins alone and never hides the application");
    CHECK(![controller suspendCaptureForEditor:first error:NULL] && orderedOutWindows.count == 2,
          "a duplicate suspension cannot replace the original focused editor");
    error = nil;
    CHECK(![controller completeSuspendedCaptureWithPNGData:[@"not a PNG" dataUsingEncoding:NSUTF8StringEncoding] error:&error] && error,
          "invalid scrolling output fails before closing the original edit");
    CHECK(controller.busy && [controller.captureSession isEqual:session] && !controller.editor &&
          [focused.document isEqual:document] && [focused.captureContentSnapshot isEqual:snapshot] && closedContexts.count == 0,
          "a failed replacement preserves original history and pending text for recovery");
    controller.onOCR = nil; controller.onTranslate = nil; controller.onScrollCapture = nil;
    CHECK(!first.onOCR && !focused.onOCR && !first.onTranslate && !focused.onTranslate &&
          !first.onScrollCapture && !focused.onScrollCapture,
          "capability changes reach suspended overlays in place");
    controller.onOCR = ^(MCImageEditorController *editor) { [ocrCalls addObject:editor]; };
    controller.onTranslate = ^(MCImageEditorController *editor) { [translateCalls addObject:editor]; };
    controller.onScrollCapture = ^(MCImageEditorController *editor) { [scrollCalls addObject:editor]; };
    [controller resumeSuspendedCapture];
    CHECK([shownWindows isEqual:overlayWindows] && keyWindows.count == 1 && keyWindows.lastObject == focused.window &&
          focused.window == overlayWindows[1] && first.window == overlayWindows[0],
          "cancel/failure resumes the same windows and presents the previously focused editor last");
    CHECK(controller.busy && [controller.captureSession isEqual:session] &&
          [focused.document isEqual:document] && [focused.captureContentSnapshot isEqual:snapshot] &&
          ![busySamples containsObject:@NO] && closedContexts.count == 0,
          "resuming leaves editing, undo, draft and capture identity intact without reporting idle");
    CHECK(focused.window.firstResponder == textInput && [textInput.string isEqual:@"unfinished text stays editable"] &&
          first.window.firstResponder == numericInput && first.fontSize.currentEditor == numericInput &&
          [numericInput.string isEqual:@"48"] && [first.document isEqual:numericDocument] &&
          [first.captureContentSnapshot isEqual:numericSnapshot],
          "resume preserves text focus and uncommitted numeric field input without committing or replacing either responder");
    [controller resumeSuspendedCapture];
    CHECK(shownWindows.count == 2 && pin.visible && !hiddenPin.visible && appHides == 0,
          "repeated resume is a no-op and does not restore user-hidden pins");
    error = nil;
    CHECK(![controller completeSuspendedCaptureWithPNGData:longPNG error:&error] && error &&
          [focused.document isEqual:document] && !controller.editor,
          "a result arriving after the suspended attempt was resumed cannot replace the original edit");
    [focused.canvas finishTextEditing:NO];
    [focused undo:nil];
    CHECK([focused.document[@"annotations"] count] == 0 && [focused.document[@"redo"] count] == 1,
          "original annotation undo still works after cancellation or failure");
    [focused redo:nil];
    CHECK([focused.document[@"annotations"] count] == 1 && [focused.document[@"undo"] count] == 1,
          "redo restores the same annotation after the suspended round trip");

    CHECK([controller suspendCaptureForEditor:focused error:NULL], "restored capture can start another scrolling attempt");
    [busySamples removeAllObjects];
    [shownWindows removeAllObjects];
    error = nil;
    CHECK([controller completeSuspendedCaptureWithPNGData:longPNG error:&error] && error == nil,
          "a valid long PNG replaces the suspended capture");
    MCImageEditorController *replacement = controller.editor;
    CHECK(replacement && replacement != focused && controller.busy && !controller.captureSession &&
          busySamples.count > 0 && ![busySamples containsObject:@NO],
          "replacement remains busy throughout old-context closure and state-change callbacks");
    CHECK(first.window == nil && focused.window == nil && closedContexts.count == 2 &&
          shownWindows.count == 1 && shownWindows.firstObject == replacement.window,
          "successful replacement closes every old overlay and presents exactly one new editor");
    NSBitmapImageRep *result = [NSBitmapImageRep imageRepWithData:[replacement renderPNGData:NULL]];
    CHECK(result.pixelsWide == 640 && result.pixelsHigh == 1200 && [replacement.document[@"undo"] count] == 0,
          "replacement edits the long image at its real dimensions with fresh history");
    CHECK(replacement.onOCR && replacement.onTranslate && replacement.onScrollCapture && replacement.onPinPNGData,
          "replacement editor inherits content and pin callbacks");
    if (replacement.onOCR) replacement.onOCR(replacement);
    if (replacement.onTranslate) replacement.onTranslate(replacement);
    if (replacement.onScrollCapture) replacement.onScrollCapture(replacement);
    CHECK(ocrCalls.lastObject == replacement && translateCalls.lastObject == replacement && scrollCalls.lastObject == replacement,
          "replacement callbacks receive the new editor instead of a closed overlay");
    CHECK(![controller completeSuspendedCaptureWithPNGData:png error:NULL] && controller.editor == replacement,
          "duplicate old completion cannot overwrite the replacement editor");
    [replacement cancel:nil];
    CHECK(!controller.busy, "closing the replacement finally releases busy state");

    // Ending a suspended session invalidates it, including when a fresh capture
    // has already started. The host separately guards scroll-operation identity.
    [controller capture];
    completeSyntheticScreens(controller, png);
    MCImageEditorController *cancelled = controller.realCreatedEditors.lastObject;
    CHECK([cancelled setCaptureRegion:NSMakeRect(20,20,700,440)] &&
          [controller suspendCaptureForEditor:cancelled error:NULL], "next synthetic session can suspend");
    void (^staleClose)(void) = cancelled.onClose;
    [controller cancelCapture];
    CHECK(!controller.busy && cancelled.window == nil, "explicit cancellation ends a suspended session");
    [shownWindows removeAllObjects];
    [controller resumeSuspendedCapture];
    CHECK(shownWindows.count == 0 && ![controller completeSuspendedCaptureWithPNGData:longPNG error:NULL],
          "resuming or completing an ended suspension cannot reopen its overlays");
    [controller capture];
    NSString *newSession = controller.captureSession;
    if (staleClose) staleClose();
    CHECK(![controller completeSuspendedCaptureWithPNGData:longPNG error:NULL] &&
          controller.busy && [controller.captureSession isEqual:newSession] && shownWindows.count == 0,
          "old close/result callbacks cannot end or replace a new pending capture session");
    [controller cancelCapture];
    CHECK(pin.visible && pin.orderOutCalls == 0 && !hiddenPin.visible && hiddenPin.orderOutCalls == 0 && appHides == 0,
          "all suspend, resume, replacement and cancellation paths preserve pin visibility");
    shownWindows = nil;
    keyWindows = nil;
    orderedOutWindows = nil;
    return passed;
}

// NSMenu runs a nested tracking loop. Enter it from a queued main-thread
// action as well, so the regression cannot accidentally drain main GCD work.
static BOOL trackUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSEventTrackingRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    return done();
}
static BOOL captureWhileTracking(void) {
    __block BOOL passed = YES, finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        MCPermissionCapture *controller = [MCPermissionCapture new];
        controller.realKeyReleaseCheck = YES;
        controller.heldModifiers = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        MCFakeTrackingMenu *menu = [MCFakeTrackingMenu new];
        [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidBeginTrackingNotification object:menu];
        [controller capture];
        CHECK(menu.cancellations == 0, "menu is not dismissed before pixels are frozen");
        NSTimer *release = [NSTimer timerWithTimeInterval:0.02 repeats:NO block:^(__unused NSTimer *timer) {
            controller.heldModifiers = 0;
        }];
        [NSRunLoop.currentRunLoop addTimer:release forMode:NSEventTrackingRunLoopMode];
        CHECK(trackUntil(^BOOL{ return controller.pendingContent != nil; }), "held keys release during nested menu tracking without closing the menu");
        if (controller.pendingContent) {
            void (^content)(SCShareableContent *, NSError *) = controller.pendingContent;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ content(fakeContent(@[@27,@14]), nil); });
            CHECK(trackUntil(^BOOL{ return controller.imageCompletions.count == 2; }), "background source callback reaches main while menu tracks");
            if (controller.imageCompletions.count == 2) {
                void (^first)(NSData *, NSError *) = controller.imageCompletions[@14];
                void (^second)(NSData *, NSError *) = controller.imageCompletions[@27];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                    second([@"menu pixels second screen" dataUsingEncoding:NSUTF8StringEncoding],nil);
                    first([@"menu pixels first screen" dataUsingEncoding:NSUTF8StringEncoding],nil);
                });
                CHECK(trackUntil(^BOOL{ return controller.createdEditors.count == 2; }), "frozen menu snapshots reach overlays before leaving tracking mode");
                CHECK(menu.cancellations == 1 && controller.createdEditors.count == 2 && controller.createdEditors[0].shows == 1,
                    "own menu releases mouse tracking only after all frozen snapshots are ready");
            }
        }
        [release invalidate];
        [controller cancelCapture];
        finished = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!finished && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    return finished && passed;
}

int main(void) {
    @autoreleasepool {
        moonbit_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
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
            MCFakeOwnWindow *videoEditor = [MCFakeOwnWindow new]; videoEditor.windowNumber = 301; videoEditor.visible = YES;
            controller.fakeWindows = @[settings,pin,hiddenPin,videoEditor];
            controller.includedWindowNumbers = ^{ return [NSSet setWithObjects:@201,@301,nil]; };
            [controller capture];
            CHECK(!settings.visible && settings.orderOutCalls == 1 && pin.visible && pin.orderOutCalls == 0 &&
                  !hiddenPin.visible && hiddenPin.orderOutCalls == 0 && videoEditor.visible && videoEditor.orderOutCalls == 0 && appHides == 0,
                  "capture preserves the video editor and pins while hiding host controls");
            CHECK(controller.pendingContent != nil, "released keys begin content acquisition immediately without a hide delay");
            [controller cancelCapture];
            CHECK(pin.visible && !hiddenPin.visible, "cancelling capture does not change pin visibility");
            controller = nil;
            reset(true, false);
            CHECK(captureWhileTracking(), "capture lifecycle progresses inside menu tracking mode");
            // Display enumeration order differs from NSScreen order; callbacks
            // complete out of order. Both snapshots must retain their own frame.
            reset(true, false);
            controller = [MCPermissionCapture new];
            NSMutableSet *visibleNumbers = [NSMutableSet setWithObjects:@201,@301,@401,nil];
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
            CHECK(controller.includedWindows.count == 2 && controller.includedWindows.firstObject.windowID == 201 && controller.includedWindows.lastObject.windowID == 301,
                  "visible pins and video editor are re-included; settings, hidden pins and foreign windows are not exceptions");
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
            passed = exerciseSuspendedCapture() && passed;
            CHECK(unexpectedLaunches == 0 && unexpectedCaptures == 0, "no real process or ScreenCaptureKit capture API was invoked");
        } @finally {
            reentrantController = nil;
            toggleInterceptions();
        }
        printf("Capture sessions (fake TCC/pixels, suspension/replacement, undo, callbacks, pin isolation, no modal UI): %s\n",
               passed ? "passed" : "FAILED");
        return passed ? 0 : 1;
    }
}
