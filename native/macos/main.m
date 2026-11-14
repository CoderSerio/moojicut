#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <unistd.h>
#import "preferences/MCPreferencesController.h"
#import "shortcuts/MCGlobalShortcutManager.h"
#import "capture/MCCaptureController.h"
#import "capture/MCImageEditorController.h"
#import "recording/MCMacRecordingController.h"
#include "moonbit.h"
#include <stdlib.h>

extern moonbit_string_t image_create(moonbit_string_t);
extern moonbit_string_t image_apply(moonbit_string_t);
typedef moonbit_string_t (*MCCoreFunction)(moonbit_string_t);
static NSDictionary *MCCall(MCCoreFunction function, NSDictionary *request) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0, json.length)];
    moonbit_string_t output = function(input); moonbit_decref(input);
    NSString *result = [[NSString alloc] initWithCharacters:output length:Moonbit_array_length(output)]; moonbit_decref(output);
    return [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
static NSDictionary *MCCoreCheck(void) {
    NSDictionary *created = MCCall(image_create, @{ @"width": @320, @"height": @200 });
    if (![created[@"ok"] boolValue]) return @{ @"passed": @NO, @"error": created ?: @{} };
    NSDictionary *annotation = @{ @"id": @"native-state-check", @"type": @"text", @"x": @20, @"y": @20, @"width": @250, @"height": @40,
        @"text": @"MoonBit 原生状态 ✅", @"fontSize": @18, @"color": @"#3478f6", @"stroke": @3, @"opacity": @1 };
    NSDictionary *applied = MCCall(image_apply, @{ @"document": created[@"document"], @"expectedRevision": @0,
        @"command": @{ @"type": @"add", @"annotations": @[annotation] } });
    NSDictionary *document = applied[@"document"];
    NSArray *annotations = document[@"annotations"];
    BOOL valid = [applied[@"ok"] boolValue] && [document[@"revision"] isEqual:@1] && annotations.count == 1 && [annotations[0][@"text"] isEqual:annotation[@"text"]];
    return @{ @"passed": @(valid), @"exportsCalled": @[@"image_create", @"image_apply"], @"document": document ?: @{} };
}
static void MCAfter(NSTimeInterval seconds, dispatch_block_t action) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @autoreleasepool { action(); } });
}

@interface MCNativeHost : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property MCPreferencesController *preferences;
@property NSUserDefaults *defaults;
@property NSDictionary *diagnostics;
@property NSMutableDictionary *report;
@property NSString *outputDirectory;
@property BOOL smoke;
@property (weak) NSWindow *closedWindow;
@property (weak) MCPreferencesController *closedController;
@property NSMutableArray *lifecycleCycles;
@property MCCaptureController *captureController;
@property MCGlobalShortcutManager *globalShortcuts;
@property MCMacRecordingController *recordingController;
@property NSMenuItem *recordMenuItem;
@property NSMenuItem *stopMenuItem;
@end

@implementation MCNativeHost
- (NSDictionary *)snapshot {
    task_vm_info_data_t info = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    NSMutableArray *classes = [NSMutableArray array]; for (NSWindow *window in NSApp.windows) [classes addObject:NSStringFromClass(window.class)];
    return @{ @"pid": @(getpid()), @"residentBytes": @(info.resident_size), @"physicalFootprintBytes": @(info.phys_footprint), @"taskInfoSucceeded": @(status == KERN_SUCCESS),
        @"contentWindows": @(self.preferences.window ? 1 : 0), @"accessoryActivationPolicy": @(NSApp.activationPolicy == NSApplicationActivationPolicyAccessory), @"appKitWindowClasses": classes };
}
- (void)writeReport {
    if (!self.outputDirectory) return;
    self.report[@"memoryMeasurement"] = @"Own-process TASK_VM_INFO: resident_size is RSS bytes; phys_footprint is macOS physical footprint bytes.";
    self.report[@"scope"] = @"AppKit screenshot capture and MoonBit annotation editor; native tray and settings.";
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    [data writeToFile:[self.outputDirectory stringByAppendingPathComponent:@"report.json"] atomically:YES];
}
- (void)showPreferences:(__unused id)sender {
    if (!self.preferences) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoonBitCoreVersion"] ?: @"开发版本";
        self.preferences = [[MCPreferencesController alloc] initWithDefaults:self.defaults coreVersion:version diagnostics:self.diagnostics];
        __weak MCNativeHost *weakSelf = self;
        self.preferences.onClose = ^{ [weakSelf.globalShortcuts resume]; weakSelf.preferences = nil; };
        self.preferences.onShortcutRecordingChanged = ^(BOOL recording) {
            if (recording) [weakSelf.globalShortcuts suspend]; else [weakSelf.globalShortcuts resume];
        };
        self.preferences.shortcutRegistrationError = self.globalShortcuts.registrationError;
    }
    [self.preferences show];
    self.report[@"windowNumber"] = @(self.preferences.window.windowNumber); [self writeReport];
}
- (void)capture:(__unused id)sender {
    [self.captureController capture];
}
- (void)startRecording:(__unused id)sender { [self.recordingController startRecording]; }
- (void)stopRecording:(__unused id)sender { [self.recordingController stopRecording]; }
- (void)resumeRecordingDraft:(__unused id)sender { [self.recordingController resumeLastDraft]; }
- (void)updateRecordingState {
    self.recordMenuItem.enabled = !self.recordingController.busy;
    self.stopMenuItem.enabled = self.recordingController.recording;
    self.statusItem.button.toolTip = self.recordingController.recording ? @"Mooji Cut · 录制中，点击停止录屏" : @"Mooji Cut";
    self.statusItem.button.title = self.recordingController.recording ? @" ●" : @"";
}
- (BOOL)applicationShouldHandleReopen:(__unused NSApplication *)sender hasVisibleWindows:(__unused BOOL)flag {
    // Finder and Spotlight send a reopen event to an already running menu bar
    // app. Reuse (or recreate) settings so opening Mooji Cut has a visible result.
    [self showPreferences:nil];
    return NO;
}
- (void)applicationDidFinishLaunching:(__unused NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.smoke = [NSProcessInfo.processInfo.arguments containsObject:@"--smoke"];
    // Keep the existing user preferences domain across the product rename.
    NSString *domain = NSProcessInfo.processInfo.environment[@"MOOJICUT_NATIVE_DEFAULTS_DOMAIN"] ?: (self.smoke ? @"dev.moojicut.native.smoke" : @"dev.mooncap.native.preferences");
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
    self.captureController = [MCCaptureController new];
    self.recordingController = [MCMacRecordingController new];
    __weak MCNativeHost *weakSelf = self;
    self.recordingController.onStateChange = ^{ [weakSelf updateRecordingState]; };
    self.globalShortcuts = [[MCGlobalShortcutManager alloc] initWithDefaults:self.defaults onCapture:^{ [weakSelf capture:nil]; }];
    self.globalShortcuts.onRecord = ^{ [weakSelf startRecording:nil]; };
    self.globalShortcuts.onStop = ^{ [weakSelf stopRecording:nil]; };
    self.globalShortcuts.onStatusChanged = ^(NSString *error) { weakSelf.preferences.shortcutRegistrationError = error; };
    if (!self.smoke) [self.globalShortcuts start];
    [MCPreferencesController applySavedAppearance:self.defaults];
    self.diagnostics = MCCoreCheck(); self.report = [NSMutableDictionary dictionaryWithDictionary:@{ @"coreAction": self.diagnostics, @"defaultsDomain": domain }];
    self.outputDirectory = NSProcessInfo.processInfo.environment[@"MOOJICUT_NATIVE_OUTPUT"];
    if (self.outputDirectory) [[NSFileManager defaultManager] createDirectoryAtPath:self.outputDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *statusImage = [NSImage imageNamed:@"MoojiCutStatusTemplate"];
    statusImage.template = YES;
    statusImage.size = NSMakeSize(18, 18);
    self.statusItem.button.image = statusImage;
    self.statusItem.button.accessibilityLabel = @"Mooji Cut";
    if (!self.statusItem.button.image) self.statusItem.button.title = @"Mooji Cut";
    self.statusItem.button.toolTip = @"Mooji Cut";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Mooji Cut"];
    menu.autoenablesItems = NO;
    NSMenuItem *capture = [[NSMenuItem alloc] initWithTitle:@"截图…" action:@selector(capture:) keyEquivalent:@""];
    capture.target = self; [menu addItem:capture]; [menu addItem:NSMenuItem.separatorItem];
    self.recordMenuItem = [[NSMenuItem alloc] initWithTitle:@"开始录屏…" action:@selector(startRecording:) keyEquivalent:@""];
    self.recordMenuItem.target = self; [menu addItem:self.recordMenuItem];
    self.stopMenuItem = [[NSMenuItem alloc] initWithTitle:@"停止录屏并编辑" action:@selector(stopRecording:) keyEquivalent:@""];
    self.stopMenuItem.target = self; [menu addItem:self.stopMenuItem];
    NSMenuItem *draft = [[NSMenuItem alloc] initWithTitle:@"继续编辑上次录屏…" action:@selector(resumeRecordingDraft:) keyEquivalent:@""];
    draft.target = self; [menu addItem:draft]; [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *preferences = [[NSMenuItem alloc] initWithTitle:@"设置…" action:@selector(showPreferences:) keyEquivalent:@","];
    preferences.target = self; [menu addItem:preferences]; [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 Mooji Cut" action:@selector(terminate:) keyEquivalent:@"q"]; quit.target = NSApp; [menu addItem:quit];
    self.statusItem.menu = menu;
    [self updateRecordingState];
    if (self.smoke) [self runSmoke];
    else if ([NSProcessInfo.processInfo.arguments containsObject:@"--capture"]) [self capture:nil];
    else if ([NSProcessInfo.processInfo.arguments containsObject:@"--preferences"]) [self showPreferences:nil];
}
- (void)closeForSmoke {
    self.closedWindow = self.preferences.window; self.closedController = self.preferences;
    [self.preferences.window performClose:nil];
}
- (NSDictionary *)closedSnapshot {
    NSUInteger contentCount = 0;
    for (NSWindow *window in NSApp.windows) if ([window isMemberOfClass:NSWindow.class]) contentCount++;
    BOOL resourcesReleased = !self.closedWindow || (!self.closedWindow.contentView && !self.closedWindow.toolbar && !self.closedWindow.visible);
    return @{ @"retainedAppKitContentWindows": @(contentCount), @"controllerReleased": @(self.closedController == nil),
        @"closedWindowResourcesReleased": @(resourcesReleased), @"windowObjectReleasedImmediately": @(self.closedWindow == nil) };
}
- (void)runLifecycleCycle:(NSUInteger)index {
    [self showPreferences:nil];
    MCAfter(0.2, ^{
        BOOL priorReleased = self.closedWindow == nil;
        [self closeForSmoke];
        MCAfter(0.2, ^{
            NSMutableDictionary *cycle = [[self closedSnapshot] mutableCopy];
            cycle[@"previousWindowReleasedAfterOpen"] = @(priorReleased);
            [self.lifecycleCycles addObject:cycle];
            if (index < 4) { [self runLifecycleCycle:index + 1]; return; }
            self.report[@"lifecycleCycles"] = self.lifecycleCycles;
            BOOL bounded = YES;
            for (NSDictionary *entry in self.lifecycleCycles) bounded = bounded &&
                [entry[@"retainedAppKitContentWindows"] unsignedIntegerValue] <= 1 &&
                [entry[@"controllerReleased"] boolValue] && [entry[@"closedWindowResourcesReleased"] boolValue] &&
                [entry[@"previousWindowReleasedAfterOpen"] boolValue];
            self.report[@"boundedWindowLifecycle"] = @(bounded);
            self.report[@"lifecyclePolicy"] = @"AppKit may retain its last key NSWindow. Closed controllers, content views and toolbars are released; each prior window is released after opening its successor; five cycles must remain bounded to at most one cached empty NSWindow.";
            self.report[@"final"] = [self snapshot]; self.report[@"phase"] = @"complete";
            BOOL passed = [self.diagnostics[@"passed"] boolValue] && bounded;
            for (NSString *key in @[@"lightAppearancePassed", @"darkAppearancePassed", @"appearanceRestoredOnReopen", @"aboutDisclosurePassed", @"applicationReopenPassed"])
                passed = passed && [self.report[key] boolValue];
            passed = passed && [self.report[@"startup"][@"contentWindows"] integerValue] == 0 && [self.report[@"final"][@"contentWindows"] integerValue] == 0;
            self.report[@"smokePassed"] = @(passed); [self writeReport];
            puts(passed ? "Native settings smoke passed." : "Native settings smoke FAILED."); [NSApp terminate:nil];
        });
    });
}
- (void)runSmoke {
    MCAfter(1, ^{
        self.report[@"startup"] = [self snapshot]; [self showPreferences:nil];
        self.report[@"phase"] = @"general"; [self writeReport];
        MCAfter(1, ^{
            [self.preferences selectPage:@"about"]; [self.preferences toggleTechnicalDetails:nil];
            self.report[@"aboutDisclosurePassed"] = @(self.preferences.technicalDetailsVisible);
            self.report[@"phase"] = @"about"; [self writeReport];
            MCAfter(1, ^{
                [self.preferences selectPage:@"general"]; [self.preferences setAppearanceChoice:@"light"]; [self.defaults synchronize];
                self.report[@"lightAppearancePassed"] = @([NSApp.appearance.name isEqual:NSAppearanceNameAqua]);
                self.report[@"phase"] = @"light"; [self writeReport];
                MCAfter(1, ^{
                    [self.preferences setAppearanceChoice:@"dark"]; [self.defaults synchronize];
                    self.report[@"darkAppearancePassed"] = @([NSApp.appearance.name isEqual:NSAppearanceNameDarkAqua]);
                    self.report[@"open"] = [self snapshot]; [self closeForSmoke];
                    MCAfter(1, ^{
                        self.report[@"afterClose"] = [self snapshot]; self.report[@"firstCloseLifecycle"] = [self closedSnapshot];
                        [self applicationShouldHandleReopen:NSApp hasVisibleWindows:NO];
                        NSWindow *reopenedWindow = self.preferences.window;
                        [self applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];
                        self.report[@"applicationReopenPassed"] = @(reopenedWindow.visible && self.preferences.window == reopenedWindow);
                        self.report[@"appearanceRestoredOnReopen"] = @([self.preferences.appearanceChoice isEqualToString:@"dark"]);
                        self.report[@"phase"] = @"reopened"; [self writeReport];
                        MCAfter(1, ^{
                            [self.preferences setAppearanceChoice:@"system"]; [self.defaults synchronize]; [self closeForSmoke];
                            MCAfter(0.2, ^{ self.lifecycleCycles = [NSMutableArray array]; [self runLifecycleCycle:0]; });
                        });
                    });
                });
            });
        });
    });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(__unused NSApplication *)sender { return NO; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(__unused NSApplication *)sender {
    if (self.recordingController.captureInProgress || self.recordingController.exporting) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"录屏还未完成";
        alert.informativeText = @"请先停止录屏，或等待视频导出完成，再退出 Mooji Cut，以免损坏视频文件。";
        [alert addButtonWithTitle:@"继续使用"]; [NSApp activateIgnoringOtherApps:YES]; [alert runModal];
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}
- (void)applicationWillTerminate:(__unused NSNotification *)notification {
    [self.globalShortcuts invalidate];
    [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    // NSApplication terminate exits directly; code after run is not a test exit hook.
    if (self.smoke) exit([self.report[@"smokePassed"] boolValue] ? 0 : 1);
}
@end

int main(__unused int argc, __unused const char *argv[]) {
    @autoreleasepool {
        moonbit_init();
        NSApplication *application = NSApplication.sharedApplication;
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--recording-smoke"]) {
            NSError *error = nil;
            NSString *root = NSProcessInfo.processInfo.environment[@"MOOJICUT_NATIVE_OUTPUT"] ?: NSTemporaryDirectory();
            NSURL *directory = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[@"video-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
            BOOL passed = [MCMacRecordingController runSmokeInDirectory:directory error:&error];
            if (!passed) NSLog(@"Recording editor smoke failed: %@", error);
            puts(passed ? "Native recording editor smoke passed." : "Native recording editor smoke FAILED.");
            return passed ? 0 : 1;
        }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--capture-smoke"]) {
            NSError *error = nil;
            NSString *directory = NSProcessInfo.processInfo.environment[@"MOOJICUT_NATIVE_OUTPUT"] ?: NSTemporaryDirectory();
            BOOL passed = [MCImageEditorController runSmokeInDirectory:directory error:&error];
            if (!passed) NSLog(@"Capture editor smoke failed: %@", error);
            puts(passed ? "Native capture editor smoke passed." : "Native capture editor smoke FAILED.");
            return passed ? 0 : 1;
        }
        MCNativeHost *host = [MCNativeHost new]; application.delegate = host; [application run];
        return host.smoke && ![host.report[@"smokePassed"] boolValue] ? 1 : 0;
    }
}
