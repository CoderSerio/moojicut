#import "MCCaptureController.h"
#import "components/desktop_capture/macos/MCDesktopSnapshot.h"
#import "components/selection/macos/MCSelectionSurface.h"
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>

static NSError *MCCaptureError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.capture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

@interface MCCaptureController ()
@property MCImageEditorController *editor;
@property NSArray<MCImageEditorController *> *overlayEditors;
@property NSString *captureSession;
@property NSRunningApplication *previousApplication;
@property BOOL snapshotsPending;
@property BOOL requestedScreenAccess;
@property BOOL showingPermissionHelp;
@property BOOL overlaysSuspended;
@property (weak) MCImageEditorController *suspendedEditor;
@property NSSet<NSNumber *> *captureWindowNumbers;
@property NSHashTable<NSMenu *> *trackingMenus;
@property (nonatomic, copy, readwrite) NSDictionary *toolConfiguration;
@end

@implementation MCCaptureController
- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenParametersChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
        _trackingMenus = [NSHashTable weakObjectsHashTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(menuTrackingBegan:) name:NSMenuDidBeginTrackingNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(menuTrackingEnded:) name:NSMenuDidEndTrackingNotification object:nil];
    }
    return self;
}
- (void)menuTrackingBegan:(NSNotification *)notification {
    if ([notification.object isKindOfClass:NSMenu.class]) [self.trackingMenus addObject:notification.object];
}
- (void)menuTrackingEnded:(NSNotification *)notification { [self.trackingMenus removeObject:notification.object]; }
- (BOOL)busy { return self.captureSession != nil || self.editor != nil; }
- (NSArray<MCImageEditorController *> *)toolConfigurationEditors {
    NSMutableOrderedSet *editors = [NSMutableOrderedSet orderedSetWithArray:self.overlayEditors ?: @[]];
    if (self.editor) [editors addObject:self.editor];
    return editors.array;
}
- (void)showEditingNotice:(NSString *)message {
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [editor showPluginMessage:message];
}
- (BOOL)canApplyToolConfiguration:(NSDictionary *)candidate error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Tool configuration must be applied on the main thread");
    for (MCImageEditorController *editor in [self toolConfigurationEditors])
        if (![editor canApplyToolConfiguration:candidate error:error]) return NO;
    return YES;
}
- (void)applyToolConfiguration:(NSDictionary *)candidate {
    NSAssert(NSThread.isMainThread, @"Tool configuration must be applied on the main thread");
    // No editor is changed until all existing screens accept the same snapshot.
    if (![self canApplyToolConfiguration:candidate error:NULL]) return;
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [editor applyToolConfiguration:candidate];
    self.toolConfiguration = candidate;
}

- (void)configureUserActionsForEditor:(MCImageEditorController *)editor {
    editor.onUserTool = self.onUserTool;
    editor.onOCR = self.onOCR;
    editor.onTranslate = self.onTranslate;
    editor.onScrollCapture = self.onScrollCapture;
    editor.onPluginContextClosed = self.onPluginContextClosed;
    editor.pluginIcons = self.pluginIcons ?: @{};
}
- (void)setOnUserTool:(void (^)(MCImageEditorController *,NSString *))handler {
    _onUserTool = [handler copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)setOnOCR:(void (^)(MCImageEditorController *))handler {
    _onOCR = [handler copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)setOnTranslate:(void (^)(MCImageEditorController *))handler {
    _onTranslate = [handler copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)setOnScrollCapture:(void (^)(MCImageEditorController *))handler {
    _onScrollCapture = [handler copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)setOnPluginContextClosed:(void (^)(NSString *))handler {
    _onPluginContextClosed = [handler copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)setPluginIcons:(NSDictionary<NSString *,NSImage *> *)icons {
    _pluginIcons = [icons copy];
    for (MCImageEditorController *editor in [self toolConfigurationEditors]) [self configureUserActionsForEditor:editor];
}
- (void)configurePinActionForEditor:(MCImageEditorController *)editor {
    if (!self.onPinPNGData) { editor.onPinPNGData = nil; return; }
    __weak MCCaptureController *weakSelf = self;
    __weak MCImageEditorController *weakEditor = editor;
    editor.onPinPNGData = ^BOOL(NSData *png) {
        MCCaptureController *owner = weakSelf;
        MCImageEditorController *current = weakEditor;
        return current && owner.onPinPNGData ? owner.onPinPNGData(png, current.pinScreenFrame) : NO;
    };
}
- (void)setOnPinPNGData:(BOOL (^)(NSData *, NSRect))handler {
    _onPinPNGData = [handler copy];
    if (self.editor) [self configurePinActionForEditor:self.editor];
    for (MCImageEditorController *editor in self.overlayEditors) [self configurePinActionForEditor:editor];
}
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (NSRunningApplication *)frontmostApplication {
    return NSWorkspace.sharedWorkspace.frontmostApplication;
}
- (NSArray<NSWindow *> *)captureWindows { return NSApp.windows; }
- (void)prepareCaptureFocus {
    // Keep visible pins on screen. Hiding the entire application would also
    // remove them before ScreenCaptureKit can include their pixels.
    for (NSWindow *window in [self captureWindows]) {
        if (window.visible && ![self.captureWindowNumbers containsObject:@(window.windowNumber)]) [window orderOut:nil];
    }
}
- (void)restoreCaptureFocus:(NSRunningApplication *)application {
    // The overlays are closed and ordinary windows remain ordered out. Do not
    // hide/unhide the app: existing pins must retain their visibility and order.
    if (!application || application.terminated) return;
    if (@available(macOS 14.0, *)) {
        [application activateFromApplication:NSRunningApplication.currentApplication options:0];
    } else {
        [application activateWithOptions:0];
    }
}
- (void)showError:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"截图未完成";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"知道了"];
    [alert runModal];
}
- (void)cancelCapture {
    BOOL active = self.captureSession != nil;
    self.captureSession = nil; // Invalidate callbacks before closing any windows.
    self.captureWindowNumbers = nil;
    self.snapshotsPending = NO;
    self.overlaysSuspended = NO;
    self.suspendedEditor = nil;
    NSArray *editors = self.overlayEditors;
    self.overlayEditors = nil;
    for (MCImageEditorController *editor in editors) {
        editor.onClose = nil;
        [editor cancel:nil];
    }
    NSRunningApplication *previous = self.previousApplication;
    self.previousApplication = nil;
    if (active) {
        [self restoreCaptureFocus:previous];
        // Existing pins keep their focus state. An explicitly created new pin
        // can select itself here, after the normal app-focus restoration.
        [self changed];
    }
}
- (BOOL)suspendCaptureForEditor:(MCImageEditorController *)editor error:(NSError **)error {
    if (!self.captureSession || self.snapshotsPending || self.overlaysSuspended ||
        ![self.overlayEditors containsObject:editor]) {
        if (error) *error = MCCaptureError(@"请先选择一个截图区域，再开始滚动截图。");
        return NO;
    }
    self.overlaysSuspended = YES;
    self.suspendedEditor = editor;
    for (MCImageEditorController *overlay in self.overlayEditors) [overlay.window orderOut:nil];
    [self restoreCaptureFocus:self.previousApplication];
    return YES;
}
- (void)resumeSuspendedCapture {
    if (!self.overlaysSuspended) return;
    self.overlaysSuspended = NO;
    MCImageEditorController *focused = self.suspendedEditor;
    self.suspendedEditor = nil;
    if (!self.captureSession) return;
    // show deliberately resets focus to the canvas for a new editor. Restoring
    // a suspended editor must keep its live text/numeric field editor instead.
    [NSApp activateIgnoringOtherApps:YES];
    for (MCImageEditorController *overlay in self.overlayEditors)
        if (overlay != focused) [overlay.window orderFront:nil];
    [focused.window makeKeyAndOrderFront:nil];
}
- (BOOL)completeSuspendedCaptureWithPNGData:(NSData *)data error:(NSError **)error {
    if (!self.captureSession || !self.overlaysSuspended) {
        if (error) *error = MCCaptureError(@"原截图已经结束，滚动结果未替换当前编辑。");
        return NO;
    }
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:data error:error];
    if (!editor) return NO;
    // Keep busy true throughout replacement, so a queued update cannot install
    // between closing the frozen selection and presenting the long image.
    self.editor = editor;
    [self cancelCapture];
    [self presentImageEditor:editor];
    return YES;
}
- (void)failSession:(NSString *)session error:(NSError *)error {
    if (![self.captureSession isEqualToString:session]) return;
    [self cancelCapture];
    [self showError:error.localizedDescription ?: @"无法冻结屏幕，请重试。"];
}
- (void)screenParametersChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.captureSession) return;
    // Geometry and backing scales belong to the frozen session. Never stretch
    // a snapshot onto a newly connected, rotated, or moved physical display.
    [self failSession:self.captureSession error:MCCaptureError(@"显示器配置已变化，请重新截图。")];
}
- (BOOL)showEditorForPNGURL:(NSURL *)url error:(NSError **)error {
    if (self.editor) { [self.editor show]; return YES; }
    if (self.captureSession) {
        if (error) *error = MCCaptureError(@"请先完成或取消当前截图。");
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return NO;
    return [self showEditorForPNGData:data error:error];
}
- (BOOL)showEditorForPNGData:(NSData *)data error:(NSError **)error {
    if (self.editor) { [self.editor show]; return YES; }
    if (self.captureSession) {
        if (error) *error = MCCaptureError(@"请先完成或取消当前截图。");
        return NO;
    }
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:data error:error];
    if (!editor) return NO;
    [self presentImageEditor:editor];
    return YES;
}
- (void)presentImageEditor:(MCImageEditorController *)editor {
    self.editor = editor;
    if (self.toolConfiguration) [self.editor applyToolConfiguration:self.toolConfiguration];
    __weak MCCaptureController *weakSelf = self;
    [self configurePinActionForEditor:self.editor];
    [self configureUserActionsForEditor:self.editor];
    self.editor.onClose = ^{ weakSelf.editor = nil; [weakSelf changed]; };
    [self.editor show];
    [self changed];
}
// Kept behind narrow methods so the regression test supplies synthetic displays
// and pixels. The test never requests real ScreenCaptureKit content or images.
- (NSArray<NSDictionary *> *)screenDescriptors {
    NSMutableArray *screens = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"];
        if (displayID) [screens addObject:@{@"displayID":displayID, @"frame":[NSValue valueWithRect:screen.frame]}];
    }
    return screens;
}
- (void)requestShareableContent:(void (^)(SCShareableContent *, NSError *))completion {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:completion];
}
- (NSArray<SCWindow *> *)includedWindowsFromContent:(SCShareableContent *)content windowNumbers:(NSSet<NSNumber *> *)numbers {
    NSMutableArray *windows = [NSMutableArray array];
    for (SCWindow *window in content.windows) {
        if (window.owningApplication.processID == NSProcessInfo.processInfo.processIdentifier &&
            [numbers containsObject:@(window.windowID)]) [windows addObject:window];
    }
    return windows;
}
- (void)captureDisplay:(SCDisplay *)display excludingApplications:(NSArray<SCRunningApplication *> *)applications
        exceptingWindows:(NSArray<SCWindow *> *)windows
            completion:(void (^)(NSData *, NSError *))completion {
    MCDesktopSnapshot(display,applications,windows,completion);
}

- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:snapshot[@"png"] error:error];
    if (self.toolConfiguration) [editor applyToolConfiguration:self.toolConfiguration];
    [self configureUserActionsForEditor:editor];
    [editor prepareOverlayInFrame:[snapshot[@"frame"] rectValue]];
    return editor;
}
- (void)showFrozenScreens:(NSArray<NSDictionary *> *)snapshots session:(NSString *)session {
    if (![self.captureSession isEqualToString:session]) return;
    NSMutableArray *editors = [NSMutableArray array];
    MCImageEditorController *focused = nil;
    NSPoint pointer = NSEvent.mouseLocation;
    __weak MCCaptureController *weakSelf = self;
    for (NSDictionary *snapshot in snapshots) {
        NSError *error = nil;
        MCImageEditorController *editor = [self editorForSnapshot:snapshot error:&error];
        if (!editor) {
            for (MCImageEditorController *created in editors) { created.onClose = nil; [created cancel:nil]; }
            [self failSession:session error:error];
            return;
        }
        editor.onClose = ^{
            MCCaptureController *owner = weakSelf;
            if ([owner.captureSession isEqualToString:session]) [owner cancelCapture];
        };
        [self configurePinActionForEditor:editor];
        [editors addObject:editor];
        if (NSPointInRect(pointer, [snapshot[@"frame"] rectValue])) focused = editor;
    }
    self.overlayEditors = editors;
    self.snapshotsPending = NO;
    // Only this process posts these notifications. Release our own menu's
    // mouse tracking after pixels are frozen; never dismiss another app's menu
    // before capture. Otherwise the menu can consume the overlay's first drag.
    for (NSMenu *menu in self.trackingMenus.allObjects) [menu cancelTrackingWithoutAnimation];
    // No overlay is presented until every screen's frozen pixels are ready.
    for (MCImageEditorController *editor in editors) if (editor != focused) [editor show];
    [focused show];
    [self changed];
}
- (void)captureDisplaysForSession:(NSString *)session {
    if (![self.captureSession isEqualToString:session]) return;
    NSArray<NSDictionary *> *screens = [self screenDescriptors];
    if (!screens.count) { [self failSession:session error:MCCaptureError(@"没有可用的显示器。")]; return; }
    __weak MCCaptureController *weakSelf = self;
    [self requestShareableContent:^(SCShareableContent *content, NSError *error) {
        MCSelectionPerformOnMain(^{
            MCCaptureController *owner = weakSelf;
            if (![owner.captureSession isEqualToString:session]) return;
            if (!content || error) {
                [owner failSession:session error:error ?: MCCaptureError(@"无法读取屏幕，请检查屏幕录制权限并重新打开应用。")];
                return;
            }
            NSMutableArray<SCDisplay *> *displays = [NSMutableArray array];
            for (NSDictionary *screen in screens) {
                SCDisplay *match = nil;
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == [screen[@"displayID"] unsignedIntValue]) { match = display; break; }
                }
                if (!match) {
                    [owner failSession:session error:MCCaptureError(@"显示器已断开或暂时无法采集，请重新截图。")];
                    return;
                }
                [displays addObject:match];
            }
            NSMutableArray *excluded = [NSMutableArray array];
            for (SCRunningApplication *application in content.applications) {
                if (application.processID == NSProcessInfo.processInfo.processIdentifier) [excluded addObject:application];
            }
            // Exceptions re-include visible pins and video editors while the app exclusion keeps
            // Settings, controls and any late-created host windows out.
            NSArray<SCWindow *> *includedWindows = [owner includedWindowsFromContent:content windowNumbers:owner.captureWindowNumbers];
            NSMutableArray *snapshots = [NSMutableArray array];
            for (NSUInteger index = 0; index < screens.count; index++) [snapshots addObject:NSNull.null];
            __block NSUInteger remaining = screens.count;
            [displays enumerateObjectsUsingBlock:^(SCDisplay *display, NSUInteger index, BOOL *stop) {
                (void)stop;
                [owner captureDisplay:display excludingApplications:excluded exceptingWindows:includedWindows completion:^(NSData *png, NSError *captureError) {
                    MCSelectionPerformOnMain(^{
                        MCCaptureController *current = weakSelf;
                        if (![current.captureSession isEqualToString:session]) return;
                        if (!png || captureError) {
                            [current failSession:session error:captureError ?: MCCaptureError(@"无法生成屏幕快照。")];
                            return;
                        }
                        if (snapshots[index] != NSNull.null) return;
                        NSMutableDictionary *snapshot = [screens[index] mutableCopy];
                        snapshot[@"png"] = png;
                        snapshots[index] = snapshot;
                        if (--remaining == 0) [current showFrozenScreens:snapshots session:session];
                    });
                }];
            }];
        });
    }];
}
- (NSEventModifierFlags)captureModifierFlags { return MCSelectionCurrentModifiers(); }
- (void)captureWhenKeysReleased:(NSString *)session attempts:(NSUInteger)attempts {
    __weak MCCaptureController *weakSelf = self;
    MCSelectionWhenKeysReleased(attempts, ^BOOL{ return [weakSelf.captureSession isEqualToString:session]; },
        ^NSEventModifierFlags{ return [weakSelf captureModifierFlags]; }, ^(BOOL released) {
        if (released) [weakSelf captureDisplaysForSession:session];
        else [weakSelf failSession:session error:MCCaptureError(@"请松开快捷键后再试一次。")];
    });
}

- (void)capture {
    NSAssert(NSThread.isMainThread, @"Capture is a main-thread operation");
    if (self.editor) { [self.editor show]; return; }
    if (self.captureSession || self.showingPermissionHelp) return;
    if (!CGPreflightScreenCaptureAccess()) {
        if (!self.requestedScreenAccess) {
            self.requestedScreenAccess = YES;
            // This API returns before the system's permission dialog closes.
            // Do not cover that dialog with our own modal alert. A grant may
            // require relaunching this process before preflight can see it.
            if (!CGRequestScreenCaptureAccess()) return;
        } else {
            self.showingPermissionHelp = YES;
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"屏幕录制权限尚未生效";
            alert.informativeText = @"请先处理系统的授权窗口，允许后完全退出 Mooji Cut，再重新打开。\n\n如果开关已经打开仍无法截图，列表可能关联了旧版本：移除旧条目，再添加当前应用。可用“显示当前应用”确认安装位置。";
            [alert addButtonWithTitle:@"打开系统设置"];
            [alert addButtonWithTitle:@"显示当前应用"];
            [alert addButtonWithTitle:@"取消"];
            NSModalResponse response = [alert runModal];
            self.showingPermissionHelp = NO;
            if (response == NSAlertFirstButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
            } else if (response == NSAlertSecondButtonReturn) {
                [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];
            }
            return;
        }
    }
    NSString *session = NSUUID.UUID.UUIDString;
    NSRunningApplication *previous = [self frontmostApplication];
    self.previousApplication = previous.processIdentifier == NSProcessInfo.processInfo.processIdentifier ? nil : previous;
    self.captureSession = session;
    self.captureWindowNumbers = [self.includedWindowNumbers ? self.includedWindowNumbers() : [NSSet set] copy];
    self.snapshotsPending = YES;
    [self changed];
    [self prepareCaptureFocus];
    [self captureWhenKeysReleased:session attempts:0];
    __weak MCCaptureController *weakSelf = self;
    MCSelectionAfter(15, ^{
        MCCaptureController *owner = weakSelf;
        if (owner.snapshotsPending && [owner.captureSession isEqualToString:session]) {
            [owner failSession:session error:MCCaptureError(@"读取屏幕超时，请重新截图。")];
        }
    });
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (MCImageEditorController *editor in _overlayEditors) { editor.onClose = nil; [editor cancel:nil]; }
}
@end
