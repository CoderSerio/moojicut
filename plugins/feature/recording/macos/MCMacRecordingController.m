#import "MCMacRecordingController.h"
#import "MCRecordingSelectionView.h"
#import "plugins/feature/video_editor/macos/MCVideoEditor.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import "native/macos/runtime/MCRuntimeProfile.h"
#include "moonbit.h"
#include <math.h>

extern moonbit_string_t recording_transition(moonbit_string_t, moonbit_string_t);
extern moonbit_string_t recording_plan(moonbit_string_t);
extern moonbit_string_t recording_status(moonbit_string_t);
static moonbit_string_t MCRecordingString(NSString *text) {
    moonbit_string_t value = moonbit_make_string_raw((int32_t)text.length);
    [text getCharacters:value range:NSMakeRange(0, text.length)]; return value;
}
static NSDictionary *MCRecordingDecode(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value);
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
static NSError *MCRecordingError(NSString *message) {
    return [NSError errorWithDomain:@"MoojiCut.Recording" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSURL *MCDraftsDirectory(void) {
    return [MCRuntimeSupportDirectory(@"MoojiCut") URLByAppendingPathComponent:@"Drafts" isDirectory:YES];
}
static void MCRecordingAlert(NSString *title, NSError *error) {
    NSAlert *alert = [NSAlert new]; alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: @"请重试。";
    [NSApp activateIgnoringOtherApps:YES]; [alert runModal];
}
@interface MCMacRecordingController () <SCStreamDelegate, SCRecordingOutputDelegate>
@property NSString *phase;
@property NSDictionary *stateCapabilities;
@property BOOL captureAudio, discardOnFinish;
@property SCStream *stream;
@property SCRecordingOutput *output;
@property SCContentFilter *pendingFilter;
@property NSDictionary *capturePlan;
@property NSURL *draft;
@property MCVideoEditor *editor;
@property NSPanel *countdownPanel;
@property MCRecordingCountdownView *countdownView;
@property NSArray<NSPanel *> *selectionPanels;
@property NSScreen *selectionScreen;
@property NSRect captureRegion;
@property NSTimer *timer;
@property NSTimeInterval countdownDeadline;
@property NSUInteger generation;
@property NSHashTable<NSWindow *> *hiddenWindows;
@property NSRunningApplication *previousApplication;
@end
@implementation MCMacRecordingController
- (instancetype)init {
    if ((self = [super init])) {
        _phase = @"idle"; [self updateCapabilities];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenParametersChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)screenParametersChanged:(__unused NSNotification *)notification {
    if (self.selecting || self.countingDown) [self stopRecording];
}
- (BOOL)selecting { return [self.phase isEqual:@"requesting"]; }
- (BOOL)starting { return [self.phase isEqual:@"starting"]; }
- (BOOL)stopping { return [self.phase isEqual:@"stopping"]; }
- (BOOL)recording { return [self.stateCapabilities[@"recording"] boolValue]; }
- (BOOL)countingDown { return [self.phase isEqual:@"countdown"]; }
- (BOOL)busy { return self.captureInProgress || self.editor != nil; }
- (BOOL)captureInProgress { return [self.stateCapabilities[@"captureInProgress"] boolValue]; }
- (BOOL)canStop { return [self.stateCapabilities[@"canStop"] boolValue]; }
- (BOOL)exporting { return self.editor.exporting; }
- (BOOL)prepareForTermination:(NSError **)error {
    if (self.captureInProgress || self.exporting) {
        if (error) *error = MCRecordingError(@"请先结束录屏或导出。");
        return NO;
    }
    if (!self.editor) return YES;
    if ([self.editor prepareForTermination:error]) return YES;
    [self.editor show];
    return NO;
}
- (NSString *)stopActionTitle { return self.recording ? @"停止录屏并编辑" : self.stopping ? @"正在结束录屏…" : @"取消录屏"; }
- (NSString *)elapsedText {
    double seconds = CMTimeGetSeconds(self.output.recordedDuration);
    NSInteger elapsed = isfinite(seconds) ? MAX(0, (NSInteger)floor(seconds)) : 0;
    return [NSString stringWithFormat:@"%02ld:%02ld",(long)(elapsed/60),(long)(elapsed%60)];
}
- (NSString *)statusItemTitle {
    if (self.countingDown) return [NSString stringWithFormat:@" %ld…",(long)MAX(1,ceil(self.countdownDeadline-NSProcessInfo.processInfo.systemUptime))];
    if (self.recording) return [@" ● " stringByAppendingString:self.elapsedText];
    if (self.starting) return @" 准备…";
    if (self.stopping) return @" 保存…";
    return @"";
}
- (NSString *)statusText {
    if (self.selecting) return @"拖拽框选或单击窗口，回车开始录制";
    if (self.countingDown) return [NSString stringWithFormat:@"%ld 秒后开始录屏", (long)MAX(1, ceil(self.countdownDeadline - NSProcessInfo.processInfo.systemUptime))];
    if (self.starting) return @"正在开始录屏…";
    if (self.stopping) return @"正在保存录屏，请稍候…";
    if (self.recording) {
        return [NSString stringWithFormat:@"录制中 %@ · %@", self.elapsedText, self.captureAudio ? @"含系统声音" : @"无声"];
    }
    if (self.editor) return self.exporting ? @"正在导出录屏…" : @"正在编辑录屏";
    return @"Mooji Cut";
}
- (BOOL)transition:(NSString *)event {
    moonbit_string_t state = MCRecordingString(self.phase), input = MCRecordingString(event);
    NSDictionary *next = MCRecordingDecode(recording_transition(state, input)); moonbit_decref(state); moonbit_decref(input);
    if (![next[@"ok"] boolValue]) return NO;
    self.phase = next[@"state"]; [self updateCapabilities]; return YES;
}
- (void)updateCapabilities {
    moonbit_string_t input = MCRecordingString(self.phase);
    self.stateCapabilities = MCRecordingDecode(recording_status(input)); moonbit_decref(input);
}
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (void)closeSelection {
    for (NSPanel *panel in self.selectionPanels) { [panel orderOut:nil]; [panel close]; }
    self.selectionPanels = nil;
}
- (void)closeCountdown {
    [self.timer invalidate]; self.timer = nil;
    [self.countdownPanel orderOut:nil]; [self.countdownPanel close]; self.countdownPanel = nil; self.countdownView = nil;
}
- (void)hideOrdinaryWindows {
    self.hiddenWindows = [NSHashTable weakObjectsHashTable];
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || window.level != NSNormalWindowLevel || [window isKindOfClass:NSPanel.class] ||
            !(window.styleMask & NSWindowStyleMaskTitled) || window == NSApp.modalWindow) continue;
        [self.hiddenWindows addObject:window]; [window orderOut:nil];
    }
}
- (void)restoreOrdinaryWindows {
    for (NSWindow *window in self.hiddenWindows) if (!window.visible && window.contentView) [window orderFront:nil];
    self.hiddenWindows = nil; self.previousApplication = nil;
}
- (void)restorePreviousFocusIfUnchanged {
    NSRunningApplication *previous = self.previousApplication;
    if (!previous || previous.terminated || previous.processIdentifier == NSProcessInfo.processInfo.processIdentifier ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != NSProcessInfo.processInfo.processIdentifier) return;
    [previous activateFromApplication:NSRunningApplication.currentApplication options:0];
}
- (NSURL *)draftsDirectory { return MCDraftsDirectory(); }
- (MCVideoEditor *)latestRecoverableDraftWithError:(NSError **)error {
    NSError *listingError = nil;
    NSArray<NSURL *> *directories = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.draftsDirectory
        includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:&listingError];
    if (!directories && listingError.code != NSFileReadNoSuchFileError) {
        if (error) *error = listingError; return nil;
    }
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSURL *directory in directories) {
        NSNumber *isDirectory = nil; [directory getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (!isDirectory.boolValue) continue;
        if (![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"source.mp4"].path]) continue;
        NSDate *date = nil; [directory getResourceValue:&date forKey:NSURLContentModificationDateKey error:NULL];
        [candidates addObject:@{@"directory":directory, @"date":date ?: NSDate.distantPast}];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"date"] compare:left[@"date"]];
    }];
    for (NSDictionary *candidate in candidates) {
        // Initialization validates media and saved edits without opening a
        // window or writing files. Reuse the successful session when showing it.
        MCVideoEditor *editor = [[MCVideoEditor alloc] initWithDraftDirectory:candidate[@"directory"] error:NULL];
        if (editor) return editor;
    }
    if (error) *error = MCRecordingError(candidates.count ?
        @"未找到可以打开的录屏草稿。原片和编辑文件均已保留，请稍后重试。" :
        @"结束录屏后可以编辑；关闭编辑器会保留草稿。");
    return nil;
}
- (void)presentEditor:(MCVideoEditor *)editor {
    self.editor = editor;
    __weak MCMacRecordingController *weakSelf = self;
    editor.onClose = ^{ weakSelf.editor = nil; [weakSelf changed]; };
    editor.onStateChange = ^{ [weakSelf changed]; };
    [editor show]; [self changed];
}
- (void)openDraft:(NSURL *)directory {
    NSError *error = nil;
    MCVideoEditor *editor = [[MCVideoEditor alloc] initWithDraftDirectory:directory error:&error];
    if (!editor) { MCRecordingAlert(@"无法打开录屏", error); [self changed]; return; }
    [self presentEditor:editor];
}
- (void)resumeLastDraft {
    if (self.editor) { [self.editor show]; return; }
    if (self.busy) { NSBeep(); return; }
    NSError *error = nil;
    MCVideoEditor *editor = [self latestRecoverableDraftWithError:&error];
    if (editor) [self presentEditor:editor];
    else MCRecordingAlert(@"没有可恢复的录屏", error);
}
- (void)startRecording {
    if (self.busy) { if (self.editor) [self.editor show]; else NSBeep(); return; }
    if (![self transition:@"start"]) return;
    self.previousApplication = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.generation++; self.discardOnFinish = NO; [self changed];
    self.captureAudio = YES; self.captureRegion = NSZeroRect; self.selectionScreen = nil;
    [self hideOrdinaryWindows];
    NSUInteger generation = self.generation;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation || !self.selecting) return;
            if (!content || error) { [self fail:error ?: MCRecordingError(@"无法读取桌面内容。")]; return; }
            [self showSelectionWithContent:content];
        });
    }];
}
- (void)showSelectionWithContent:(SCShareableContent *)content {
    NSMutableDictionary<NSNumber *, SCWindow *> *windows = [NSMutableDictionary dictionary];
    for (SCWindow *window in content.windows) windows[@(window.windowID)] = window;
    // CGWindowList is front-to-back; shareable content doesn't guarantee z-order.
    NSArray *ordered = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray<NSPanel *> *panels = [NSMutableArray array];
    __weak MCMacRecordingController *weakSelf = self;
    NSUInteger generation = self.generation;
    for (NSScreen *screen in NSScreen.screens) {
        SCDisplay *display = nil;
        for (SCDisplay *candidate in content.displays)
            if (candidate.displayID == [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]) { display = candidate; break; }
        if (!display) continue;
        NSMutableArray *candidates = [NSMutableArray array];
        for (NSDictionary *info in ordered) {
            SCWindow *window = windows[info[(NSString *)kCGWindowNumber]];
            if (!window || window.windowLayer != 0 || window.owningApplication.processID == NSProcessInfo.processInfo.processIdentifier) continue;
            NSRect intersection = NSIntersectionRect(window.frame, display.frame);
            if (intersection.size.width < 2 || intersection.size.height < 2) continue;
            intersection.origin.x -= display.frame.origin.x; intersection.origin.y -= display.frame.origin.y;
            [candidates addObject:@{@"windowID":@(window.windowID), @"rect":[NSValue valueWithRect:intersection]}];
        }
        MCRecordingOverlayPanel *panel = [[MCRecordingOverlayPanel alloc] initWithContentRect:screen.frame
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        panel.opaque = NO; panel.backgroundColor = NSColor.clearColor; panel.hasShadow = NO;
        panel.level = NSScreenSaverWindowLevel; panel.releasedWhenClosed = NO; panel.acceptsMouseMovedEvents = YES;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        MCRecordingSelectionView *view = [[MCRecordingSelectionView alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)];
        view.windowCandidates = candidates;
        view.onCancel = ^{ [weakSelf stopRecording]; };
        __weak MCRecordingSelectionView *weakView = view;
        view.onBeginSelection = ^{
            for (NSPanel *other in weakSelf.selectionPanels)
                if (other.contentView != weakView) [(MCRecordingSelectionView *)other.contentView resetSelection];
        };
        view.onConfirm = ^(NSRect region, NSNumber *windowID, BOOL audio) {
            MCMacRecordingController *owner = weakSelf;
            if (!owner || owner.generation != generation || !owner.selecting) return;
            owner.captureAudio = audio; owner.selectionScreen = screen;
            SCWindow *window = windowID ? windows[windowID] : nil;
            SCContentFilter *filter;
            if (window) {
                // A desktop-independent stream follows the window when it moves.
                owner.captureRegion = NSZeroRect;
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
            } else {
                owner.captureRegion = region;
                filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            }
            [owner closeSelection]; [owner selectFilter:filter];
        };
        panel.contentView = view; [panels addObject:panel];
    }
    self.selectionPanels = panels;
    if (!panels.count) { [self fail:MCRecordingError(@"没有可录制的显示器。")]; return; }
    [NSApp activateIgnoringOtherApps:YES];
    for (NSPanel *panel in panels) {
        [panel orderFrontRegardless];
        if (NSPointInRect(NSEvent.mouseLocation,panel.frame)) { [panel makeKeyWindow]; [panel makeFirstResponder:panel.contentView]; }
    }
}
- (void)selectFilter:(SCContentFilter *)filter {
    if (!self.selecting || self.stream) return;
    CGSize size = NSIsEmptyRect(self.captureRegion) ? filter.contentRect.size : self.captureRegion.size;
    CGFloat pixels = filter.pointPixelScale;
    if (!isfinite(size.width) || !isfinite(size.height) || !isfinite(pixels) || pixels <= 0 || size.width <= 0 || size.height <= 0 || size.width*pixels > 32768 || size.height*pixels > 32768) {
        [self fail:MCRecordingError(@"所选内容没有可录制的画面，请重新选择。")]; return;
    }
    NSDictionary *input = @{@"width":@(floor(size.width*pixels)), @"height":@(floor(size.height*pixels)), @"systemAudio":@(self.captureAudio)};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:input options:0 error:NULL] encoding:NSUTF8StringEncoding];
    moonbit_string_t request = MCRecordingString(json); self.capturePlan = MCRecordingDecode(recording_plan(request)); moonbit_decref(request);
    if (![self.capturePlan[@"ok"] boolValue]) { [self fail:MCRecordingError(@"所选画面太小或尺寸无效，请重新选择。")]; return; }
    [self transition:@"selected"]; self.pendingFilter = filter;
    self.countdownDeadline = NSProcessInfo.processInfo.systemUptime + [self.capturePlan[@"countdownSeconds"] doubleValue];
    [self showCountdown]; [self changed];
    __weak MCMacRecordingController *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf countdownTick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)showCountdown {
    self.countdownPanel = [[MCRecordingOverlayPanel alloc] initWithContentRect:NSMakeRect(0,0,200,212)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.countdownPanel.releasedWhenClosed = NO; self.countdownPanel.level = NSScreenSaverWindowLevel;
    self.countdownPanel.backgroundColor = NSColor.clearColor; self.countdownPanel.opaque = NO; self.countdownPanel.hasShadow = NO;
    self.countdownPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.countdownView = [[MCRecordingCountdownView alloc] initWithFrame:NSMakeRect(0,0,200,212)];
    self.countdownView.duration = [self.capturePlan[@"countdownSeconds"] doubleValue];
    self.countdownView.remaining = self.countdownView.duration;
    __weak MCMacRecordingController *weakSelf = self;
    self.countdownView.onCancel = ^{ [weakSelf stopRecording]; };
    self.countdownPanel.contentView = self.countdownView;
    NSRect screen = (self.selectionScreen ?: NSScreen.mainScreen).frame;
    [self.countdownPanel setFrameOrigin:NSMakePoint(NSMidX(screen)-100,NSMidY(screen)-106)];
    [self.countdownPanel makeKeyAndOrderFront:nil]; [self.countdownPanel makeFirstResponder:self.countdownView];
}
- (void)countdownTick {
    if (!self.countingDown) return;
    if (NSProcessInfo.processInfo.systemUptime < self.countdownDeadline) {
        double remaining = self.countdownDeadline - NSProcessInfo.processInfo.systemUptime;
        if (ceil(self.countdownView.remaining) != ceil(remaining)) [self changed];
        self.countdownView.remaining = remaining; self.countdownView.needsDisplay = YES;
        return;
    }
    [self closeCountdown]; [self transition:@"countdown_finished"]; [self changed];
    [self restorePreviousFocusIfUnchanged];
    NSUInteger generation = self.generation;
    // Let the WindowServer remove the countdown before the first recorded frame.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.generation == generation && self.starting) [self beginCaptureWithFilter:self.pendingFilter];
    });
}
- (SCStreamConfiguration *)streamConfiguration {
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = [self.capturePlan[@"width"] unsignedIntegerValue]; config.height = [self.capturePlan[@"height"] unsignedIntegerValue];
    config.minimumFrameInterval = CMTimeMake(1, [self.capturePlan[@"framesPerSecond"] intValue]); config.showsCursor = YES;
    if (!NSIsEmptyRect(self.captureRegion)) config.sourceRect = self.captureRegion;
    config.scalesToFit = YES; config.preservesAspectRatio = YES;
    config.capturesAudio = self.captureAudio; config.captureMicrophone = NO;
    config.excludesCurrentProcessAudio = YES; config.streamName = @"Mooji Cut 录屏";
    return config;
}
- (void)beginCaptureWithFilter:(SCContentFilter *)filter {
    self.pendingFilter = nil;
    self.draft = [self.draftsDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.draft withIntermediateDirectories:YES attributes:nil error:&error]) { [self fail:error]; return; }
    SCStreamConfiguration *config = [self streamConfiguration];
    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    SCRecordingOutputConfiguration *recording = [SCRecordingOutputConfiguration new];
    recording.outputURL = [self.draft URLByAppendingPathComponent:@"source.mp4"];
    recording.videoCodecType = AVVideoCodecTypeH264; recording.outputFileType = AVFileTypeMPEG4;
    self.output = [[SCRecordingOutput alloc] initWithConfiguration:recording delegate:self];
    if (![self.stream addRecordingOutput:self.output error:&error]) { [self fail:error]; return; }
    SCStream *startedStream = self.stream;
    [startedStream startCaptureWithCompletionHandler:^(NSError *startError) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self captureStarted:startedStream error:startError]; });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.stream == startedStream && self.starting) [self fail:MCRecordingError(@"录屏启动超时。请检查屏幕录制权限，然后重试。")];
    });
}
- (void)captureStarted:(SCStream *)stream error:(NSError *)error {
    // stopCapture can race an asynchronous start. A late successful start must
    // stop its exact stream even if cancellation has already cleared the owner.
    if (self.stream != stream) { if (!error) [stream stopCaptureWithCompletionHandler:nil]; return; }
    if (error) [self fail:error];
    else if (self.stopping) [stream stopCaptureWithCompletionHandler:nil];
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.output != output || !self.starting) return;
        [self transition:@"capture_started"]; [self changed];
        __weak MCMacRecordingController *weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf changed]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    });
}
- (void)stopRecording {
    if (self.selecting || self.countingDown || (self.starting && !self.stream)) {
        if (self.starting) { [self transition:@"stop"]; [self transition:@"complete"]; }
        else [self transition:@"cancel"];
        self.generation++; self.pendingFilter = nil; [self closeCountdown]; [self closeSelection];
        [self restoreOrdinaryWindows];
        [self changed]; return;
    }
    if (!self.stream || !self.canStop) return;
    self.discardOnFinish = self.starting;
    [self transition:@"stop"]; [self.timer invalidate]; self.timer = nil; [self changed];
    SCStream *stoppedStream = self.stream;
    [stoppedStream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ if (self.stream == stoppedStream) [self fail:error]; });
    }];
    [self watchFinalization:stoppedStream];
}
- (void)watchFinalization:(SCStream *)stoppedStream {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.stream == stoppedStream && self.stopping) [self fail:MCRecordingError(@"录屏保存超时，已有文件保留在草稿目录。请稍后尝试继续编辑。")];
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.output != output) return;
        NSURL *draft = self.draft; BOOL discard = self.discardOnFinish;
        if (!self.stopping) [self transition:@"stop"];
        [self transition:@"complete"]; [self closeSelection]; [self closeCountdown];
        self.stream = nil; self.output = nil; self.draft = nil; self.capturePlan = nil;
        [self restoreOrdinaryWindows];
        // A cancellation while starting must not unexpectedly open an editor.
        if (discard) { [NSFileManager.defaultManager removeItemAtURL:draft error:NULL]; [self changed]; }
        else [self openDraft:draft];
    });
}
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.output == output) [self fail:error]; });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stream != stream) return;
        if ([error.domain isEqual:SCStreamErrorDomain] && error.code == SCStreamErrorUserStopped) {
            if (!self.stopping) [self transition:@"stop"];
            [self.timer invalidate]; self.timer = nil; [self changed];
            [self watchFinalization:stream];
            // The output delegate fires only after the encoder has finalized MP4.
            return;
        }
        [self fail:error];
    });
}
- (void)fail:(NSError *)error {
    BOOL cancelled = self.discardOnFinish;
    SCStream *stream = self.stream; self.stream = nil; self.output = nil;
    self.generation++; self.pendingFilter = nil; [self transition:@"fail"];
    [stream stopCaptureWithCompletionHandler:nil]; [self closeSelection]; [self closeCountdown];
    if (self.draft && ![NSFileManager.defaultManager fileExistsAtPath:[self.draft URLByAppendingPathComponent:@"source.mp4"].path])
        [NSFileManager.defaultManager removeItemAtURL:self.draft error:NULL];
    self.draft = nil; [self changed];
    [self restoreOrdinaryWindows];
    if (cancelled) return;
    NSString *message = error.localizedDescription ?: @"请重试。";
    if ([error.domain isEqual:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined)
        message = @"未获得屏幕录制权限。请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”允许当前应用，按系统提示重新打开后再试。";
    MCRecordingAlert(@"录屏未能完成", MCRecordingError(message));
}
- (void)dealloc { [self.timer invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error { return [MCVideoEditor runSmokeInDirectory:directory error:error]; }
@end
