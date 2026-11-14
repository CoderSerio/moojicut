#import "MCCaptureController.h"
#import "MCImageEditorController.h"
#import <CoreGraphics/CoreGraphics.h>

@interface MCCaptureController ()
@property NSTask *captureTask;
@property NSURL *temporaryDirectory;
@property MCImageEditorController *editor;
@end

@implementation MCCaptureController
- (BOOL)busy { return self.captureTask != nil || self.editor != nil; }
- (void)showError:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"截图未完成";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"知道了"];
    [alert runModal];
}
- (void)removeTemporaryFiles {
    if (self.temporaryDirectory) [[NSFileManager defaultManager] removeItemAtURL:self.temporaryDirectory error:NULL];
    self.temporaryDirectory = nil;
}
- (BOOL)showEditorForPNGURL:(NSURL *)url error:(NSError **)error {
    if (self.editor) { [self.editor show]; return YES; }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return NO;
    self.editor = [[MCImageEditorController alloc] initWithPNGData:data error:error];
    if (!self.editor) return NO;
    __weak MCCaptureController *weakSelf = self;
    self.editor.onClose = ^{ weakSelf.editor = nil; };
    [self.editor show];
    return YES;
}
- (void)launchWhenKeysReleased:(NSTask *)task attempts:(NSUInteger)attempts {
    if (self.captureTask != task) return;
    NSEventModifierFlags held = NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (held) {
        if (attempts >= 40) {
            self.captureTask = nil;
            [self removeTemporaryFiles];
            [self showError:@"请松开快捷键后再试一次。"];
            return;
        }
        __weak MCCaptureController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf launchWhenKeysReleased:task attempts:attempts + 1];
        });
        return;
    }
    // Allow the compositor to remove our settings before the system picker freezes the desktop.
    __weak MCCaptureController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        MCCaptureController *owner = weakSelf;
        if (!owner || owner.captureTask != task) return;
        NSEventModifierFlags modifiers = NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
            NSEventModifierFlagControl | NSEventModifierFlagOption);
        if (modifiers) { [owner launchWhenKeysReleased:task attempts:attempts + 3]; return; }
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) {
            owner.captureTask = nil;
            [owner removeTemporaryFiles];
            [owner showError:error.localizedDescription];
        }
    });
}
- (void)capture {
    NSAssert(NSThread.isMainThread, @"Capture is a main-thread operation");
    if (self.editor) { [self.editor show]; return; }
    if (self.captureTask) return;
    if (!CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess()) {
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"允许 Mooji Cut 截取屏幕";
        alert.informativeText = @"请在系统设置的「隐私与安全性 → 屏幕与系统音频录制」中允许 Mooji Cut，然后重新打开应用并截图。";
        [alert addButtonWithTitle:@"打开系统设置"];
        [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        }
        return;
    }
    NSError *error = nil;
    self.temporaryDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"moojicut-capture-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:self.temporaryDirectory withIntermediateDirectories:NO
                                                  attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        self.temporaryDirectory = nil;
        [self showError:error.localizedDescription];
        return;
    }
    NSURL *output = [self.temporaryDirectory URLByAppendingPathComponent:@"capture.png"];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    task.arguments = @[@"-i", @"-x", @"-t", @"png", output.path];
    NSPipe *errors = [NSPipe pipe];
    task.standardError = errors;
    self.captureTask = task;
    __weak MCCaptureController *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *diagnostic = [errors.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            MCCaptureController *owner = weakSelf;
            if (!owner) return;
            owner.captureTask = nil;
            if ([[NSFileManager defaultManager] fileExistsAtPath:output.path]) {
                NSError *readError = nil;
                if (![owner showEditorForPNGURL:output error:&readError]) [owner showError:readError.localizedDescription ?: @"无法读取截图。请再试一次。"];
            } else if (!CGPreflightScreenCaptureAccess()) {
                [owner showError:@"屏幕录制权限尚未生效。请在系统设置中允许 Mooji Cut，重新打开应用后再试。"];
            } else if (finished.terminationStatus != 0 && diagnostic.length) {
                NSString *text = [[NSString alloc] initWithData:diagnostic encoding:NSUTF8StringEncoding] ?: @"";
                // Escape is a normal cancellation. macOS may describe it on stderr.
                if ([text rangeOfString:@"cancel" options:NSCaseInsensitiveSearch].location == NSNotFound)
                    [owner showError:@"系统未能生成截图。请确认屏幕录制权限后重试。"];
            }
            [owner removeTemporaryFiles];
        });
    };
    // Close our settings from the capture surface without terminating the app.
    [NSApp hide:nil];
    // The global shortcut may contain Control. Release it before entering the
    // system picker so it is not interpreted as "copy directly to clipboard".
    [self launchWhenKeysReleased:task attempts:0];
}
- (void)dealloc {
    self.captureTask.terminationHandler = nil;
    if (self.captureTask.running) [self.captureTask terminate];
    if (self.temporaryDirectory) [[NSFileManager defaultManager] removeItemAtURL:self.temporaryDirectory error:NULL];
}
@end
