#import "MCCaptureController.h"
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
@end

@implementation MCCaptureController
- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenParametersChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (BOOL)busy { return self.captureSession != nil || self.editor != nil; }
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (NSRunningApplication *)frontmostApplication {
    return NSWorkspace.sharedWorkspace.frontmostApplication;
}
- (void)prepareCaptureFocus {
    // Hide ordinary windows explicitly before hiding the application. Otherwise
    // showing the overlay with unhide also restores Settings behind it, which
    // then resurfaces as soon as the user confirms their screenshot.
    for (NSWindow *window in NSApp.windows) {
        if (window.visible && (window.styleMask & NSWindowStyleMaskTitled)) [window orderOut:nil];
    }
    [NSApp hide:nil];
}
- (void)restoreCaptureFocus:(NSRunningApplication *)application {
    [NSApp hide:nil];
    // The normal windows were explicitly ordered out, and overlays are closed.
    // Let nonactivating pins reappear in changed without bringing Settings back.
    [NSApp unhideWithoutActivation];
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
    self.snapshotsPending = NO;
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
        // Existing pins restore without focus. An explicitly created new pin
        // can select itself here, after the normal app-focus restoration.
        [self changed];
    }
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
    self.editor = [[MCImageEditorController alloc] initWithPNGData:data error:error];
    if (!self.editor) return NO;
    __weak MCCaptureController *weakSelf = self;
    if (self.onPinPNGData) self.editor.onPinPNGData = ^BOOL(NSData *png) {
        MCCaptureController *owner = weakSelf;
        return owner.onPinPNGData ? owner.onPinPNGData(png, owner.editor.pinScreenFrame) : NO;
    };
    self.editor.onClose = ^{ weakSelf.editor = nil; [weakSelf changed]; };
    [self.editor show];
    [self changed];
    return YES;
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
- (void)captureDisplay:(SCDisplay *)display excludingApplications:(NSArray<SCRunningApplication *> *)applications
            completion:(void (^)(NSData *, NSError *))completion {
    if (@available(macOS 14.0, *)) {
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
            excludingApplications:applications exceptingWindows:@[]];
        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        configuration.width = (size_t)llround(filter.contentRect.size.width * filter.pointPixelScale);
        configuration.height = (size_t)llround(filter.contentRect.size.height * filter.pointPixelScale);
        configuration.showsCursor = NO;
        if (!configuration.width || !configuration.height || configuration.width > 32768 || configuration.height > 32768 ||
            configuration.width * configuration.height > 80000000) {
            completion(nil, MCCaptureError(@"屏幕尺寸无法处理，请调整显示器分辨率后重试。"));
            return;
        }
        [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
            completionHandler:^(CGImageRef image, NSError *error) {
                @autoreleasepool {
                    NSData *png = image ? [[[NSBitmapImageRep alloc] initWithCGImage:image]
                        representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
                    completion(png, error ?: (png ? nil : MCCaptureError(@"系统未能生成屏幕快照，请检查屏幕录制权限。")));
                }
            }];
    } else {
        completion(nil, MCCaptureError(@"原地截图需要 macOS 14 或更新版本。"));
    }
}
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:snapshot[@"png"] error:error];
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
        __weak MCImageEditorController *weakEditor = editor;
        if (self.onPinPNGData) editor.onPinPNGData = ^BOOL(NSData *png) {
            MCCaptureController *owner = weakSelf;
            return owner.onPinPNGData ? owner.onPinPNGData(png, weakEditor.pinScreenFrame) : NO;
        };
        [editors addObject:editor];
        if (NSPointInRect(pointer, [snapshot[@"frame"] rectValue])) focused = editor;
    }
    self.overlayEditors = editors;
    self.snapshotsPending = NO;
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
        dispatch_async(dispatch_get_main_queue(), ^{
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
            NSMutableArray *snapshots = [NSMutableArray array];
            for (NSUInteger index = 0; index < screens.count; index++) [snapshots addObject:NSNull.null];
            __block NSUInteger remaining = screens.count;
            [displays enumerateObjectsUsingBlock:^(SCDisplay *display, NSUInteger index, BOOL *stop) {
                (void)stop;
                [owner captureDisplay:display excludingApplications:excluded completion:^(NSData *png, NSError *captureError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
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
- (void)captureWhenKeysReleased:(NSString *)session attempts:(NSUInteger)attempts {
    if (![self.captureSession isEqualToString:session]) return;
    NSEventModifierFlags held = NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (held) {
        if (attempts >= 40) {
            [self failSession:session error:MCCaptureError(@"请松开快捷键后再试一次。")];
            return;
        }
        __weak MCCaptureController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf captureWhenKeysReleased:session attempts:attempts + 1];
        });
        return;
    }
    __weak MCCaptureController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([weakSelf.captureSession isEqualToString:session]) [weakSelf captureDisplaysForSession:session];
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
    self.snapshotsPending = YES;
    [self changed];
    [self prepareCaptureFocus];
    [self captureWhenKeysReleased:session attempts:0];
    __weak MCCaptureController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
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
