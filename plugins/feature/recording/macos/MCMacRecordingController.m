#import "MCMacRecordingController.h"
#import "plugins/feature/video_editor/macos/MCVideoEditor.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import "native/macos/runtime/MCRuntimeProfile.h"

static NSURL *MCDraftsDirectory(void) {
    return [MCRuntimeSupportDirectory(@"MoojiCut") URLByAppendingPathComponent:@"Drafts" isDirectory:YES];
}
static void MCRecordingAlert(NSString *title, NSError *error) {
    NSAlert *alert = [NSAlert new]; alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: @"请重试。";
    [NSApp activateIgnoringOtherApps:YES]; [alert runModal];
}
@interface MCMacRecordingController () <SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate>
@property (nonatomic, readwrite) BOOL recording;
@property BOOL selecting, starting, stopping, captureAudio;
@property SCStream *stream;
@property SCRecordingOutput *output;
@property NSURL *draft;
@property MCVideoEditor *editor;
@end
@implementation MCMacRecordingController
- (BOOL)busy { return self.selecting || self.starting || self.recording || self.stopping || self.editor != nil; }
- (BOOL)captureInProgress { return self.selecting || self.starting || self.recording || self.stopping; }
- (BOOL)exporting { return self.editor.exporting; }
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (void)endPicker {
    [SCContentSharingPicker.sharedPicker removeObserver:self];
    SCContentSharingPicker.sharedPicker.active = NO;
    self.selecting = NO;
}
- (NSURL *)lastDraft {
    NSArray<NSURL *> *directories = [NSFileManager.defaultManager contentsOfDirectoryAtURL:MCDraftsDirectory()
        includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSURL *latest = nil; NSDate *date = nil;
    for (NSURL *directory in directories) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"source.mp4"].path]) continue;
        NSDate *candidate = nil; [directory getResourceValue:&candidate forKey:NSURLContentModificationDateKey error:NULL];
        if (!latest || [candidate compare:date] == NSOrderedDescending) { latest = directory; date = candidate; }
    }
    return latest;
}
- (void)openDraft:(NSURL *)directory {
    NSError *error = nil;
    MCVideoEditor *editor = [[MCVideoEditor alloc] initWithDraftDirectory:directory error:&error];
    if (!editor) { MCRecordingAlert(@"无法打开录屏", error); [self changed]; return; }
    self.editor = editor;
    __weak MCMacRecordingController *weakSelf = self;
    editor.onClose = ^{ weakSelf.editor = nil; [weakSelf changed]; };
    [editor show]; [self changed];
}
- (void)resumeLastDraft {
    if (self.editor) { [self.editor show]; return; }
    if (self.busy) { NSBeep(); return; }
    NSURL *draft = [self lastDraft];
    if (draft) [self openDraft:draft];
    else MCRecordingAlert(@"没有待编辑的录屏", [NSError errorWithDomain:@"MoojiCut" code:1 userInfo:@{NSLocalizedDescriptionKey:@"结束录屏后可以编辑；取消编辑会保留草稿。"}]);
}
- (void)startRecording {
    if (self.busy) { if (self.editor) [self.editor show]; else NSBeep(); return; }
    self.selecting = YES; [self changed];
    NSAlert *options = [NSAlert new]; options.messageText = @"开始录屏";
    options.informativeText = @"下一步选择一个显示器或窗口。使用菜单栏中的“停止录屏”结束，然后编辑并确认。麦克风不会录入。";
    [options addButtonWithTitle:@"选择画面"]; [options addButtonWithTitle:@"取消"];
    NSButton *audio = [NSButton checkboxWithTitle:@"录制系统声音" target:nil action:nil];
    audio.state = NSControlStateValueOn; audio.frame = NSMakeRect(0, 0, 280, 24); options.accessoryView = audio;
    [NSApp activateIgnoringOtherApps:YES];
    if ([options runModal] != NSAlertFirstButtonReturn) { self.selecting = NO; [self changed]; return; }
    self.captureAudio = audio.state == NSControlStateValueOn;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    SCContentSharingPickerConfiguration *configuration = [SCContentSharingPickerConfiguration new];
    configuration.allowedPickerModes = SCContentSharingPickerModeSingleDisplay | SCContentSharingPickerModeSingleWindow;
    configuration.allowsChangingSelectedContent = NO;
    if (NSBundle.mainBundle.bundleIdentifier) configuration.excludedBundleIDs = @[NSBundle.mainBundle.bundleIdentifier];
    picker.defaultConfiguration = configuration; picker.maximumStreamCount = @1;
    [picker addObserver:self]; picker.active = YES; [picker present];
}
- (void)contentSharingPicker:(__unused SCContentSharingPicker *)picker didCancelForStream:(__unused SCStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.selecting) { [self endPicker]; [self changed]; } });
}
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.selecting) { [self endPicker]; [self changed]; MCRecordingAlert(@"无法打开录屏选择器", error); } });
}
- (void)contentSharingPicker:(__unused SCContentSharingPicker *)picker didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.selecting || stream || self.stream) return;
        self.selecting = NO; self.starting = YES; [self changed];
        self.draft = [MCDraftsDirectory() URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:self.draft withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self fail:error]; return;
        }
        CGSize size = filter.contentRect.size;
        if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) {
            [self fail:[NSError errorWithDomain:@"MoojiCut" code:2 userInfo:@{NSLocalizedDescriptionKey:@"所选内容没有可录制的画面。"}]]; return;
        }
        CGFloat pixels = filter.pointPixelScale > 0 ? filter.pointPixelScale : 1;
        CGFloat scale = MIN(1, 3840 / MAX(size.width * pixels, size.height * pixels));
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = MAX(2, (size_t)floor(size.width * pixels * scale / 2) * 2);
        config.height = MAX(2, (size_t)floor(size.height * pixels * scale / 2) * 2);
        config.minimumFrameInterval = CMTimeMake(1, 30); config.showsCursor = YES;
        config.scalesToFit = YES; config.preservesAspectRatio = YES;
        config.capturesAudio = self.captureAudio; config.captureMicrophone = NO;
        config.excludesCurrentProcessAudio = YES; config.streamName = @"Mooji Cut 录屏";
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        SCRecordingOutputConfiguration *recording = [SCRecordingOutputConfiguration new];
        recording.outputURL = [self.draft URLByAppendingPathComponent:@"source.mp4"];
        recording.videoCodecType = AVVideoCodecTypeH264; recording.outputFileType = AVFileTypeMPEG4;
        self.output = [[SCRecordingOutput alloc] initWithConfiguration:recording delegate:self];
        if (![self.stream addRecordingOutput:self.output error:&error]) { [self fail:error]; return; }
        SCStream *startedStream = self.stream;
        [startedStream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) dispatch_async(dispatch_get_main_queue(), ^{ if (self.stream == startedStream) [self fail:startError]; });
        }];
    });
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.output != output || self.stopping) return;
        self.starting = NO; self.recording = YES; [self changed];
    });
}
- (void)stopRecording {
    if (!self.stream || self.stopping) return;
    self.stopping = YES; self.recording = NO; self.starting = NO; [self changed];
    SCStream *stoppedStream = self.stream;
    [stoppedStream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ if (self.stream == stoppedStream) [self fail:error]; });
    }];
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.output != output) return;
        NSURL *draft = self.draft;
        [self endPicker]; self.stream = nil; self.output = nil; self.draft = nil;
        self.recording = NO; self.starting = NO; self.stopping = NO;
        [self openDraft:draft];
    });
}
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.output == output) [self fail:error]; });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stream != stream) return;
        if ([error.domain isEqual:SCStreamErrorDomain] && error.code == SCStreamErrorUserStopped) {
            self.recording = NO; self.starting = NO; self.stopping = YES; [self changed];
            // SCRecordingOutput finishes writing before its delegate opens the editor.
            return;
        }
        [self fail:error];
    });
}
- (void)fail:(NSError *)error {
    SCStream *stream = self.stream;
    self.stream = nil; self.output = nil;
    [stream stopCaptureWithCompletionHandler:nil]; [self endPicker];
    self.recording = NO; self.starting = NO; self.stopping = NO;
    // Preserve any partial recording for recovery; never overwrite user material.
    if (self.draft && ![NSFileManager.defaultManager fileExistsAtPath:[self.draft URLByAppendingPathComponent:@"source.mp4"].path])
        [NSFileManager.defaultManager removeItemAtURL:self.draft error:NULL];
    self.draft = nil; [self changed]; MCRecordingAlert(@"录屏未能完成", error);
}
- (void)dealloc { [SCContentSharingPicker.sharedPicker removeObserver:self]; }
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error { return [MCVideoEditor runSmokeInDirectory:directory error:error]; }
@end
