#import "MCMacRecordingController.h"
#import "MCRecordingSelectionView.h"
#import "components/desktop_capture/macos/MCDesktopSnapshot.h"
#import "plugins/feature/video_editor/macos/MCVideoEditor.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import "native/macos/runtime/MCRuntimeProfile.h"
#include "moonbit.h"
#include "bindings/c/recording_flow.h"
#include <math.h>

extern moonbit_string_t recording_plan(moonbit_string_t);
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
@property int32_t flowHandle;
@property NSError *pendingFailure;
@property BOOL awaitingStartCallback, stopAcknowledged, outputAttached, outputStarted, outputFinished;
@property BOOL captureAudio, discardOnFinish;
@property SCStream *stream;
@property SCRecordingOutput *output;
@property SCContentFilter *pendingFilter;
@property NSDictionary *capturePlan;
@property NSURL *draft;
@property MCVideoEditor *editor;
@property NSPanel *countdownPanel;
@property MCRecordingCountdownView *countdownView;
@property NSArray<NSWindow *> *selectionPanels;
@property BOOL selectionPreparing;
@property NSScreen *selectionScreen;
@property NSRect captureRegion;
@property NSTimer *timer;
@property NSUInteger generation, stopRequestGeneration;
@property NSHashTable<NSWindow *> *hiddenWindows;
@property NSRunningApplication *previousApplication;
@end
@implementation MCMacRecordingController
- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenParametersChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)screenParametersChanged:(__unused NSNotification *)notification {
    if (self.selecting || self.countingDown) [self stopRecording];
}
- (int32_t)phase { return self.flowHandle ? recording_flow_value(self.flowHandle,MC_RECORDING_PHASE) : MC_RECORDING_IDLE; }
- (BOOL)selecting { return self.phase == MC_RECORDING_SELECTING; }
- (BOOL)starting { return self.phase == MC_RECORDING_STARTING; }
- (BOOL)stopping { return self.phase == MC_RECORDING_STOPPING; }
- (BOOL)recording { return self.phase == MC_RECORDING_ACTIVE; }
- (BOOL)countingDown { return self.phase == MC_RECORDING_COUNTDOWN; }
- (BOOL)busy { return self.captureInProgress || self.editor != nil; }
- (BOOL)captureInProgress { return self.flowHandle && recording_flow_value(self.flowHandle,MC_RECORDING_BUSY) == 1; }
- (BOOL)canStop { return self.flowHandle && (recording_flow_value(self.flowHandle,MC_RECORDING_CAN_CANCEL) == 1 ||
    recording_flow_value(self.flowHandle,MC_RECORDING_CAN_STOP) == 1); }
- (BOOL)exporting { return self.editor.exporting; }
- (NSSet<NSNumber *> *)visibleEditorWindowNumbers { return self.editor.visibleWindowNumbers ?: [NSSet set]; }
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
- (NSString *)flowText {
    moonbit_string_t value=recording_ui_text(self.flowHandle);
    NSString *text=[[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value);
    return text;
}
- (NSString *)statusItemTitle {
    if (self.countingDown) return [NSString stringWithFormat:@" %@…",self.flowText];
    if (self.recording) return [@" ● " stringByAppendingString:self.flowText];
    if (self.starting) return @" 准备…";
    if (self.stopping) return @" 保存…";
    return @"";
}
- (NSString *)statusText {
    if (self.selecting) return @"拖拽框选或单击窗口，回车开始录制";
    if (self.countingDown) return [NSString stringWithFormat:@"%@ 秒后开始录屏",self.flowText];
    if (self.starting) return @"正在开始录屏…";
    if (self.stopping) return @"正在保存录屏，请稍候…";
    if (self.recording) return [NSString stringWithFormat:@"录制中 %@ · %@",self.flowText,self.captureAudio ? @"含系统声音" : @"无声"];
    if (self.editor) return self.exporting ? @"正在导出录屏…" : @"正在编辑录屏";
    return @"Mooji Cut";
}
- (double)flowNow { return NSProcessInfo.processInfo.systemUptime * 1000; }
- (int32_t)sendFlowEvent:(int32_t)event { return recording_flow_event(self.flowHandle,event,self.flowNow); }
- (void)releaseFlow {
    if (self.flowHandle && recording_flow_close(self.flowHandle)) self.flowHandle=0;
}
- (BOOL)beginFlow {
    [self releaseFlow];
    if (self.flowHandle) return NO;
    self.awaitingStartCallback=NO; self.stopAcknowledged=NO;
    self.outputAttached=NO; self.outputStarted=NO; self.outputFinished=NO; self.pendingFailure=nil;
    self.flowHandle=recording_flow_open();
    return self.flowHandle && [self sendFlowEvent:MC_RECORDING_BEGIN] == MC_RECORDING_REQUEST_SOURCE;
}
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (void)closeSelection {
    for (NSWindow *panel in self.selectionPanels) { [panel orderOut:nil]; [panel close]; }
    self.selectionPanels = nil; self.selectionPreparing = NO;
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
    if (![self beginFlow]) return;
    self.previousApplication = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.generation++; self.discardOnFinish = NO; [self changed];
    self.captureAudio = YES; self.captureRegion = NSZeroRect; self.selectionScreen = nil;
    [self hideOrdinaryWindows];
    self.selectionPreparing = YES;
    NSUInteger generation = self.generation;
    __weak MCMacRecordingController *weakSelf = self;
    MCSelectionWhenKeysReleased(0, ^BOOL{ return weakSelf.generation == generation && weakSelf.selecting; },
        ^NSEventModifierFlags{ return [weakSelf selectionModifierFlags]; }, ^(BOOL released) {
        MCMacRecordingController *owner = weakSelf;
        if (!released) { [owner fail:MCRecordingError(@"请松开快捷键后再试一次。")]; return; }
        [owner requestSelectionContent:^(SCShareableContent *content, NSError *error) {
            MCSelectionPerformOnMain(^{
                MCMacRecordingController *current = weakSelf;
                if (current.generation != generation || !current.selecting) return;
                if (!content || error) { [current fail:error ?: MCRecordingError(@"无法读取桌面内容。")]; return; }
                [current showSelectionWithContent:content];
            });
        }];
    });
    MCSelectionAfter(15, ^{
        MCMacRecordingController *owner = weakSelf;
        if (owner.generation == generation && owner.selecting && owner.selectionPreparing)
            [owner fail:MCRecordingError(@"读取屏幕超时，请重新录屏。")];
    });
}
- (NSEventModifierFlags)selectionModifierFlags { return MCSelectionCurrentModifiers(); }
- (void)requestSelectionContent:(void (^)(SCShareableContent *, NSError *))completion {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:completion];
}
- (void)snapshotDisplay:(SCDisplay *)display completion:(void (^)(NSData *, NSError *))completion {
    MCDesktopSnapshot(display,@[],@[],completion);
}
- (NSArray<NSScreen *> *)selectionScreens { return NSScreen.screens; }
- (void)showSelectionWithContent:(SCShareableContent *)content {
    NSMutableDictionary<NSNumber *, SCWindow *> *windows = [NSMutableDictionary dictionary];
    for (SCWindow *window in content.windows) windows[@(window.windowID)] = window;
    // CGWindowList is front-to-back; shareable content doesn't guarantee z-order.
    NSArray *ordered = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray<NSWindow *> *panels = [NSMutableArray array];
    NSMutableArray<SCDisplay *> *displays = [NSMutableArray array];
    __weak MCMacRecordingController *weakSelf = self;
    NSUInteger generation = self.generation;
    for (NSScreen *screen in self.selectionScreens) {
        SCDisplay *display = nil;
        for (SCDisplay *candidate in content.displays)
            if (candidate.displayID == [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]) { display = candidate; break; }
        if (!display) {
            self.selectionPanels = panels;
            [self fail:MCRecordingError(@"显示器已断开或暂时无法采集，请重新录屏。")]; return;
        }
        NSMutableArray *candidates = [NSMutableArray array];
        for (NSDictionary *info in ordered) {
            SCWindow *window = windows[info[(NSString *)kCGWindowNumber]];
            if (!window || window.windowLayer != 0 || window.owningApplication.processID == NSProcessInfo.processInfo.processIdentifier) continue;
            NSRect intersection = NSIntersectionRect(window.frame, display.frame);
            if (intersection.size.width < 2 || intersection.size.height < 2) continue;
            intersection.origin.x -= display.frame.origin.x; intersection.origin.y -= display.frame.origin.y;
            [candidates addObject:@{@"windowID":@(window.windowID), @"rect":[NSValue valueWithRect:intersection]}];
        }
        MCSelectionWindow *panel = [[MCSelectionWindow alloc] initWithContentRect:screen.frame
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed = NO; [panel configureForScreenFrame:screen.frame];
        MCRecordingSelectionView *view = [[MCRecordingSelectionView alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)];
        view.windowCandidates = candidates;
        view.onCancel = ^{ [weakSelf stopRecording]; };
        __weak MCRecordingSelectionView *weakView = view;
        view.onBeginSelection = ^{
            for (NSWindow *other in weakSelf.selectionPanels)
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
        panel.contentView = view; [panels addObject:panel]; [displays addObject:display];
    }
    self.selectionPanels = panels;
    if (!panels.count) { [self fail:MCRecordingError(@"没有可录制的显示器。")]; return; }
    __block NSUInteger remaining = panels.count;
    for (NSUInteger index=0;index<panels.count;index++) {
        [self snapshotDisplay:displays[index] completion:^(NSData *png, NSError *error) {
            MCSelectionPerformOnMain(^{
                MCMacRecordingController *owner = weakSelf;
                if (owner.generation != generation || !owner.selecting || owner.selectionPanels != panels) return;
                NSImage *image = png ? [[NSImage alloc] initWithData:png] : nil;
                if (!image || error) { [owner fail:error ?: MCRecordingError(@"无法生成桌面选区，请重试。")]; return; }
                MCRecordingSelectionView *view = (MCRecordingSelectionView *)panels[index].contentView;
                if (view.backdrop) return;
                view.backdrop = image;
                if (--remaining == 0) { owner.selectionPreparing = NO; [owner presentSelection]; }
            });
        }];
    }
}
- (void)presentSelection {
    [NSApp activateIgnoringOtherApps:YES];
    for (NSWindow *panel in self.selectionPanels) {
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
    if ([self sendFlowEvent:MC_RECORDING_SELECTED] == MC_RECORDING_REJECTED) return;
    self.pendingFilter = filter;
    [self showCountdown]; [self changed];
    __weak MCMacRecordingController *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf flowTick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)showCountdown {
    self.countdownPanel = [[MCRecordingOverlayPanel alloc] initWithContentRect:NSMakeRect(0,0,240,208)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.countdownPanel.releasedWhenClosed = NO; self.countdownPanel.level = NSScreenSaverWindowLevel;
    self.countdownPanel.backgroundColor = NSColor.clearColor; self.countdownPanel.opaque = NO; self.countdownPanel.hasShadow = NO;
    self.countdownPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.countdownView = [[MCRecordingCountdownView alloc] initWithFrame:NSMakeRect(0,0,240,208)];
    self.countdownView.flowHandle = self.flowHandle;
    __weak MCMacRecordingController *weakSelf = self;
    self.countdownView.onAction = ^(int32_t action) {
        if (action == MC_RECORDING_CANCEL || action == MC_RECORDING_STOP) [weakSelf stopRecording];
    };
    self.countdownPanel.contentView = self.countdownView;
    NSRect screen = (self.selectionScreen ?: NSScreen.mainScreen).frame;
    NSSize size=self.countdownView.frame.size;
    [self.countdownPanel setFrameOrigin:NSMakePoint(NSMidX(screen)-size.width/2,NSMidY(screen)-size.height/2)];
    [self.countdownPanel makeKeyAndOrderFront:nil]; [self.countdownPanel makeFirstResponder:self.countdownView];
}
- (void)flowTick {
    if (!self.captureInProgress) return;
    int32_t effect=[self sendFlowEvent:MC_RECORDING_TICK];
    [self.countdownView refresh]; [self changed];
    if (effect != MC_RECORDING_START_MEDIA) return;
    [self closeCountdown]; [self restorePreviousFocusIfUnchanged];
    NSUInteger generation=self.generation; int32_t handle=self.flowHandle;
    // The core owns the deadline. This short host-only drain removes the
    // countdown's WindowServer pixels before capture can acquire its first frame.
    MCSelectionAfter(0.2, ^{
        if (self.generation == generation && self.flowHandle == handle && self.starting)
            [self beginCaptureWithFilter:self.pendingFilter];
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
    if (![self.stream addRecordingOutput:self.output error:&error]) {
        self.stopAcknowledged=YES; // No start was submitted and no writer was attached.
        [self fail:error]; return;
    }
    self.outputAttached=YES;
    SCStream *startedStream = self.stream; self.awaitingStartCallback=YES;
    [startedStream startCaptureWithCompletionHandler:^(NSError *startError) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self captureStarted:startedStream error:startError]; });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.stream == startedStream && self.starting) [self fail:MCRecordingError(@"录屏启动超时。请检查屏幕录制权限，然后重试。")];
    });
}
- (void)captureStarted:(SCStream *)stream error:(NSError *)error {
    if (self.stream != stream) { if (!error) [stream stopCaptureWithCompletionHandler:nil]; return; }
    self.awaitingStartCallback=NO;
    if (error) {
        // An unsuccessful start cannot keep capturing. If its writer never
        // started there is no encoder finalization to wait for.
        self.stopAcknowledged=YES;
        if (!self.outputStarted) self.outputFinished=YES;
        [self fail:error]; [self finishPendingMediaIfReady];
    }
    else if (self.stopping) {
        // The earlier stop may have completed before start did. Stop this
        // exact stream again and keep its flow busy until that acknowledgement.
        [self requestNativeStop:stream];
    }
}
- (void)requestNativeStop:(SCStream *)stream {
    self.stopAcknowledged=NO;
    NSUInteger request=++self.stopRequestGeneration;
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
        MCSelectionPerformOnMain(^{
            if (self.stream != stream || self.stopRequestGeneration != request) return;
            // A didStop delegate may already have acknowledged the actual stop.
            if (error && self.stopAcknowledged) { [self finishPendingMediaIfReady]; return; }
            self.stopAcknowledged=error==nil;
            if (error && !self.pendingFailure) [self fail:error];
            else [self finishPendingMediaIfReady];
        });
    }];
}
- (void)finishPendingMediaIfReady {
    if (!self.stream || !self.flowHandle || self.awaitingStartCallback || !self.stopAcknowledged) return;
    if (self.pendingFailure) {
        if (!self.outputAttached || self.outputFinished) [self finishFailureForStream:self.stream];
        return;
    }
    if (!self.outputFinished) return;
    NSURL *draft=self.draft; BOOL discard=self.discardOnFinish;
    [self closeSelection]; [self closeCountdown];
    self.stream=nil; self.output=nil; self.draft=nil; self.capturePlan=nil;
    [self restoreOrdinaryWindows];
    int32_t effect=[self sendFlowEvent:MC_RECORDING_COMPLETE]; [self releaseFlow];
    if (discard) { if (draft) [NSFileManager.defaultManager removeItemAtURL:draft error:NULL]; [self changed]; }
    else if (effect == MC_RECORDING_DELIVER_MEDIA) [self openDraft:draft];
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.output != output) return;
        self.outputStarted=YES;
        if (!self.starting) return;
        if ([self sendFlowEvent:MC_RECORDING_STARTED] == MC_RECORDING_REJECTED) return;
        [self changed];
        __weak MCMacRecordingController *weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf flowTick]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    });
}
- (void)stopRecording {
    if (!self.canStop) return;
    self.discardOnFinish=self.starting;
    int32_t effect=[self sendFlowEvent:MC_RECORDING_STOP];
    if (effect == MC_RECORDING_RELEASE_SOURCE || (effect == MC_RECORDING_STOP_MEDIA && !self.stream)) {
        self.generation++; self.pendingFilter=nil; self.capturePlan=nil;
        [self closeCountdown]; [self closeSelection]; [self restoreOrdinaryWindows];
        [self sendFlowEvent:MC_RECORDING_COMPLETE]; [self releaseFlow];
        [self changed]; return;
    }
    if (effect != MC_RECORDING_STOP_MEDIA || !self.stream) return;
    [self.timer invalidate]; self.timer=nil; [self changed];
    SCStream *stoppedStream=self.stream;
    [self requestNativeStop:stoppedStream];
    [self watchFinalization:stoppedStream];
}
- (void)watchFinalization:(SCStream *)stoppedStream {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.stream == stoppedStream && self.stopping) [self fail:MCRecordingError(@"录屏保存超时，已有文件保留在草稿目录。请稍后尝试继续编辑。")];
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    MCSelectionPerformOnMain(^{
        if (self.output != output) return;
        self.outputFinished=YES;
        if (!self.stopping) {
            [self sendFlowEvent:MC_RECORDING_STOP]; [self requestNativeStop:self.stream];
        }
        [self finishPendingMediaIfReady];
    });
}
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    MCSelectionPerformOnMain(^{
        if (self.output != output) return;
        self.outputFinished=YES; [self fail:error]; [self finishPendingMediaIfReady];
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stream != stream) return;
        self.stopAcknowledged=YES;
        if ([error.domain isEqual:SCStreamErrorDomain] && error.code == SCStreamErrorUserStopped) {
            if (!self.stopping) [self sendFlowEvent:MC_RECORDING_STOP];
            [self.timer invalidate]; self.timer = nil; [self changed];
            [self finishPendingMediaIfReady];
            [self watchFinalization:stream];
            // The output delegate fires only after the encoder has finalized MP4.
            return;
        }
        [self fail:error]; [self finishPendingMediaIfReady];
    });
}
- (void)finishFailureForStream:(SCStream *)stream {
    if (!self.pendingFailure || self.stream != stream) return;
    NSError *error=self.pendingFailure; self.pendingFailure=nil;
    BOOL cancelled=self.discardOnFinish;
    self.stream=nil; self.output=nil; self.pendingFilter=nil; self.capturePlan=nil;
    if (self.draft && ![NSFileManager.defaultManager fileExistsAtPath:[self.draft URLByAppendingPathComponent:@"source.mp4"].path])
        [NSFileManager.defaultManager removeItemAtURL:self.draft error:NULL];
    self.draft=nil; [self restoreOrdinaryWindows];
    [self sendFlowEvent:MC_RECORDING_FAIL]; [self releaseFlow]; [self changed];
    if (cancelled) return;
    NSString *message=error.localizedDescription ?: @"请重试。";
    if ([error.domain isEqual:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined)
        message=@"未获得屏幕录制权限。请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”允许当前应用，按系统提示重新打开后再试。";
    [self presentFailure:MCRecordingError(message)];
}
- (void)presentFailure:(NSError *)error { MCRecordingAlert(@"录屏未能完成",error); }
- (void)fail:(NSError *)error {
    if (self.pendingFailure || !self.captureInProgress) return;
    self.pendingFailure=error; self.generation++; self.pendingFilter=nil;
    if (self.canStop) [self sendFlowEvent:MC_RECORDING_STOP];
    [self closeSelection]; [self closeCountdown]; [self changed];
    SCStream *stream=self.stream;
    if (!stream) { [self finishFailureForStream:nil]; return; }
    // The shared flow must remain busy until the native stop acknowledges
    // cleanup. Do not publish ERROR while a capture still owns its resources.
    if (self.stopAcknowledged) [self finishPendingMediaIfReady];
    else [self requestNativeStop:stream];
}
- (void)dealloc { [self.timer invalidate]; if (_flowHandle) recording_flow_close(_flowHandle); [[NSNotificationCenter defaultCenter] removeObserver:self]; }
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error { return [MCVideoEditor runSmokeInDirectory:directory error:error]; }
@end
