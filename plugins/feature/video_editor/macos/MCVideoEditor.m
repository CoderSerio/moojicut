#import "MCVideoEditor.h"
#import "MCVideoMedia.h"
#import "components/media_analysis/macos/MCAudioWaveform.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "bindings/c/video_project.h"
#include "bindings/c/video_ui.h"
#include <sys/stat.h>
#include <errno.h>
#include <math.h>

// v1 is used only to generate a legacy recovery fixture in runSmoke.
extern moonbit_string_t video_open(moonbit_string_t, moonbit_string_t);
extern moonbit_string_t video_command(int32_t, moonbit_string_t);
extern void video_dispose(int32_t);
static NSError *MCVideoError(NSString *message) {
    return [NSError errorWithDomain:@"MoojiCut.Video" code:1 userInfo:@{NSLocalizedDescriptionKey:message ?: @"视频处理失败。"}];
}
static moonbit_string_t MCVideoString(NSString *string) {
    moonbit_string_t value = moonbit_make_string_raw((int32_t)string.length);
    [string getCharacters:value range:NSMakeRange(0, string.length)]; return value;
}
static NSString *MCVideoJSON(id object) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] encoding:NSUTF8StringEncoding];
}
static NSDictionary *MCVideoDecode(moonbit_string_t value) {
    NSString *string = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value);
    id decoded = [NSJSONSerialization JSONObjectWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : @{@"ok":@NO,@"error":@{@"message":@"共享编辑器返回了无效数据。"}};
}
static NSArray<AVAssetTrack *> *MCVideoTracks(AVAsset *asset, AVMediaType type) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:type]) [tracks addObject:track];
    return tracks;
}
// lstat distinguishes a missing file from an unreadable or dangling saved draft.
// Only absence permits migration; malformed/empty v2 never falls back to v1.
static NSString *MCReadDraft(NSURL *url, NSInteger schema, BOOL *exists, NSError **error) {
    struct stat info;
    if (lstat(url.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) { *exists = NO; return @""; }
        *exists = YES;
        if (error) *error = MCVideoError(@"无法检查编辑草稿。原片和编辑文件已保留。");
        return nil;
    }
    *exists = YES;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    id object = text.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    id version = [object isKindOfClass:NSDictionary.class] ? object[@"schemaVersion"] : nil;
    if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        [version doubleValue] != schema) {
        if (error) *error = MCVideoError([NSString stringWithFormat:@"%@ 无法读取或格式损坏，未回退或覆盖。原片和编辑文件已保留。", url.lastPathComponent]);
        return nil;
    }
    return text; // MoonBit validates the original text, including duplicate keys.
}
static BOOL MCWaitUntil(BOOL (^done)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
static BOOL MCExportSync(AVComposition *composition, AVVideoComposition *videoComposition, NSURL *url, NSError **error) {
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
    if (!exporter) { if (error) *error = MCVideoError(@"无法创建视频导出任务。"); return NO; }
    exporter.outputURL = url; exporter.outputFileType = AVFileTypeMPEG4; exporter.videoComposition = videoComposition;
    __block BOOL done = NO;
    [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_async(dispatch_get_main_queue(), ^{ done = YES; }); }];
    if (!MCWaitUntil(^BOOL { return done; }, 90)) { [exporter cancelExport]; if (error) *error = MCVideoError(@"导出超时。"); return NO; }
    if (exporter.status != AVAssetExportSessionStatusCompleted) { if (error) *error = exporter.error ?: MCVideoError(@"导出未完成。"); return NO; }
    return YES;
}


@interface MCVideoEditor ()
@property NSURL *directory;
@property NSDictionary *state;
@property MCVideoMedia *media;
@property MCAudioWaveform *waveformTask;
@property MCSharedCanvasView *canvas;
@property NSWindow *window;
@property NSTimer *timer;
@property int32_t session, ui;
@property BOOL closed, draftDirty, mediaPrepared, mediaSynchronized;
@property BOOL choosingExport, exportActive, pendingSeek, clockDelivered, lastClockPlaying;
@property BOOL closeAfterExportCancellation;
@property NSUInteger nextRequest, exportGeneration, seekGeneration;
@property NSInteger lastExportPercent;
@property double lastClockOutput;
@property NSError *lastError, *draftError, *reportedPreviewError;
- (void)sendUIEvent:(NSDictionary *)event;
- (void)render;
- (void)tick;
- (void)buildWindow;
- (BOOL)saveDraft:(NSError **)error;
- (BOOL)applyCommand:(NSDictionary *)command error:(NSError **)error;
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error;
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion;
- (void)cancelExportKeepingDraft;
- (BOOL)confirmCancelExport;
@end

@implementation MCVideoEditor
- (BOOL)exporting { return self.choosingExport || self.exportActive; }
- (NSSet<NSNumber *> *)visibleWindowNumbers {
    return !self.closed && self.window.visible && !self.window.miniaturized && self.window.windowNumber > 0 ?
        [NSSet setWithObject:@(self.window.windowNumber)] : [NSSet set];
}
- (instancetype)initWithDraftDirectory:(NSURL *)directory error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _session = -1; _ui = -1; _lastExportPercent = -1; _directory = directory;
    _media = [[MCVideoMedia alloc] initWithURL:[directory URLByAppendingPathComponent:@"source.mp4"] error:error];
    if (!_media) return nil;
    BOOL exists = NO;
    NSString *draft = MCReadDraft([directory URLByAppendingPathComponent:@"edit-v2.json"], 2, &exists, error);
    if (!draft) return nil;
    _draftDirty = !exists;
    if (!exists) {
        draft = MCReadDraft([directory URLByAppendingPathComponent:@"edit.json"], 1, &exists, error);
        if (!draft) return nil;
    }
    moonbit_string_t input = MCVideoString(MCVideoJSON(_media.metadata)), saved = MCVideoString(draft);
    _state = MCVideoDecode(video_project_open(input, saved)); moonbit_decref(input); moonbit_decref(saved);
    if (![_state[@"ok"] boolValue]) {
        if (error) *error = MCVideoError([NSString stringWithFormat:@"%@ 原片和编辑草稿已保留。", _state[@"error"][@"message"] ?: @"无法恢复编辑。"]);
        return nil;
    }
    _session = [_state[@"session"] intValue];
    moonbit_string_t initial = MCVideoString(MCVideoJSON(_state));
    _ui = video_ui_open(initial); moonbit_decref(initial);
    if (_ui < 0) { if (error) *error = MCVideoError(@"无法初始化共享编辑界面，草稿已保留。"); return nil; }
    // Recovery scanning stops here: no window, timer, write or migration on disk.
    return self;
}
- (void)changed { if (self.onStateChange) self.onStateChange(); }
- (void)reportError:(NSError *)error {
    self.lastError = error;
    [self sendUIEvent:@{@"type":@"error", @"message":error.localizedDescription ?: @"操作失败，请重试。"}];
}
- (BOOL)saveDraft:(NSError **)error {
    if (self.closed) { if (error) *error = MCVideoError(@"编辑器已关闭。"); return NO; }
    NSError *failure = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.state[@"document"] options:NSJSONWritingPrettyPrinted error:&failure];
    BOOL saved = data && [data writeToURL:[self.directory URLByAppendingPathComponent:@"edit-v2.json"] options:NSDataWritingAtomic error:&failure];
    self.draftDirty = !saved;
    self.draftError = saved ? nil : MCVideoError([NSString stringWithFormat:@"草稿保存失败，编辑仍保留在内存中。%@", failure.localizedDescription ?: @""]);
    if (!saved && error) *error = self.draftError;
    return saved;
}
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error { return [self.media applyPlan:plan error:error]; }
- (BOOL)synchronizeMedia:(NSError **)error {
    self.mediaPrepared = YES; self.seekGeneration++; self.pendingSeek = NO; self.clockDelivered = NO;
    self.mediaSynchronized = [self applyMediaPlan:self.state[@"plan"] error:error];
    [self.canvas setVideoPlayer:self.mediaSynchronized ? self.media.player : nil];
    if (!self.mediaSynchronized) [self.media pause];
    [self sendUIEvent:@{@"type":@"mediaStatus", @"ready":self.mediaSynchronized ? @YES : @NO,
        @"message":self.mediaSynchronized ? @"" : @"预览无法同步，已停止播放和导出。可以撤销后重试。"}];
    return self.mediaSynchronized;
}
- (BOOL)applyCommand:(NSDictionary *)command error:(NSError **)error {
    if (self.closed || self.exporting) { if (error) *error = MCVideoError(@"请等待当前保存完成。"); return NO; }
    double position = self.media.currentOutputMilliseconds;
    BOOL playing = self.media.playbackRequested;
    NSMutableDictionary *request = [command mutableCopy];
    request[@"expectedRevision"] = self.state[@"revision"];
    request[@"requestId"] = [NSString stringWithFormat:@"editor-%lu", (unsigned long)++self.nextRequest];
    moonbit_string_t input = MCVideoString(MCVideoJSON(request));
    NSDictionary *next = MCVideoDecode(video_project_command(self.session, input)); moonbit_decref(input);
    if (![next[@"ok"] boolValue]) {
        NSError *failure = MCVideoError(next[@"error"][@"message"] ?: @"编辑未应用。");
        [self reportError:failure]; [self sendUIEvent:@{@"type":@"snapshot", @"snapshot":self.state}];
        if (error) *error = failure; return NO;
    }
    self.state = next; self.draftDirty = YES;
    [self sendUIEvent:@{@"type":@"snapshot", @"snapshot":next}];
    NSError *mediaError = nil, *saveError = nil;
    BOOL synchronized = [self synchronizeMedia:&mediaError];
    BOOL saved = [self saveDraft:&saveError];
    if (synchronized) { [self seekOutput:position]; if (playing) [self.media play]; }
    if (!synchronized || !saved) {
        NSString *message = !synchronized ? @"预览无法同步，已停止播放和导出；可以撤销后重试。" : @"";
        if (!saved) message = [message stringByAppendingFormat:@"编辑仍保留在内存，但草稿保存失败。请检查文件权限后重试保存或关闭。%@", saveError.localizedDescription ?: @""];
        NSError *failure = MCVideoError(message);
        [self reportError:failure]; if (error) *error = failure; return NO;
    }
    self.lastError = nil; return YES;
}
- (void)buildWindow {
    if (self.closed || self.window) return;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"编辑录屏 · Mooji Cut"; self.window.releasedWhenClosed = NO; self.window.delegate = self;
    self.window.contentMinSize = NSMakeSize(720, 480);
    self.canvas = [[MCSharedCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 1040, 720)];
    self.window.contentView = self.canvas;
    __weak MCVideoEditor *weak = self;
    self.canvas.onEvent = ^(NSDictionary *event) { [weak sendUIEvent:event]; };
    self.canvas.onFrameNeeded = ^(__unused CGSize size) { [weak render]; };
    NSAppearanceName appearance = [self.canvas.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]];
    [self sendUIEvent:@{@"type":@"appearance", @"mode":[appearance isEqual:NSAppearanceNameDarkAqua] ? @"dark" : @"light"}];
    NSError *error = nil;
    if (!self.mediaPrepared && ![self synchronizeMedia:&error]) [self reportError:error];
    else [self.canvas setVideoPlayer:self.mediaSynchronized ? self.media.player : nil];
    [self render]; [self.window center];
    if ([self.media.metadata[@"hasAudio"] boolValue]) {
        NSNumber *duration = self.media.metadata[@"durationMs"];
        self.waveformTask = [MCAudioWaveform readURL:[self.directory URLByAppendingPathComponent:@"source.mp4"]
            durationMilliseconds:duration.doubleValue completion:^(NSArray<NSNumber *> *peaks, NSError *failure) {
                MCVideoEditor *owner = weak;
                if (!owner || owner.closed) return;
                owner.waveformTask = nil;
                // Analysis is optional; failure never pauses editing or export.
                if (failure) NSLog(@"Audio waveform unavailable: %@", failure.localizedDescription);
                [owner sendUIEvent:@{@"type":@"waveform",@"durationMs":duration,@"peaks":peaks ?: @[]}];
            }];
    }
    self.timer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(__unused NSTimer *timer) { [weak tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)show {
    if (self.closed) return;
    [self buildWindow]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self.canvas];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)render {
    if (self.closed || !self.canvas || self.ui < 0) return;
    CGSize size = self.canvas.bounds.size;
    moonbit_string_t frame = video_ui_frame(self.ui,size.width,size.height);
    if ([self.canvas setFrameJSON:frame]) moonbit_decref(frame);
    else self.lastError = MCVideoError(MCVideoDecode(frame)[@"error"][@"message"]);
}
- (void)seekOutput:(double)milliseconds {
    if (self.closed || !self.mediaSynchronized) return;
    self.pendingSeek = YES; self.clockDelivered = NO; NSUInteger request = ++self.seekGeneration;
    __weak MCVideoEditor *weak = self;
    [self.media seekOutputMilliseconds:MAX(0, MIN(milliseconds,self.media.outputDurationMilliseconds-1)) completion:^(__unused BOOL finished) {
        MCVideoEditor *self = weak; if (!self || self.closed || self.seekGeneration != request) return;
        self.pendingSeek = NO;
    }];
}
- (void)sendUIEvent:(NSDictionary *)event {
    if (self.closed || self.ui < 0) return;
    moonbit_string_t input = MCVideoString(MCVideoJSON(event));
    NSDictionary *result = MCVideoDecode(video_ui_event(self.ui, input)); moonbit_decref(input);
    if (![result[@"ok"] boolValue]) { self.lastError = MCVideoError(result[@"error"][@"message"]); return; }
    for (NSDictionary *effect in result[@"effects"]) {
        NSString *type = effect[@"type"];
        if ([type isEqual:@"command"]) { NSError *error = nil; [self applyCommand:effect[@"command"] error:&error]; }
        else if ([type isEqual:@"seekOutput"]) [self seekOutput:[effect[@"outputMs"] doubleValue]];
        else if ([type isEqual:@"play"]) {
            if (self.mediaSynchronized && [effect[@"playing"] boolValue]) [self.media play]; else [self.media pause];
            self.clockDelivered = NO;
        } else if ([type isEqual:@"previewRate"]) {
            NSError *error = nil;
            BOOL accepted = self.mediaSynchronized && [self.media setPreviewRate:[effect[@"rate"] doubleValue] error:&error];
            NSError *statusError = accepted ? self.draftError : error ?: MCVideoError(@"预览尚未同步。");
            [self sendUIEvent:@{@"type":@"previewRateStatus", @"rate":@(self.media.previewRate),
                @"message":statusError.localizedDescription ?: @"", @"error":statusError ? @YES : @NO}];
        } else if ([type isEqual:@"export"]) [self saveAs:nil];
        else [self reportError:MCVideoError(@"共享界面请求了当前版本尚不支持的操作。")];
        if (self.closed) return;
    }
    [self render];
}
- (void)tick {
    if (self.closed) return;
    if (self.exportActive) {
        NSInteger percent = (NSInteger)floor(self.media.exportProgress * 100);
        if (percent != self.lastExportPercent) {
            self.lastExportPercent = percent;
            [self sendUIEvent:@{@"type":@"exportStatus", @"busy":@YES,
                @"message":[NSString stringWithFormat:@"正在保存视频 %ld%%…", (long)percent], @"error":@NO}];
        }
    }
    if (!self.mediaSynchronized) return;
    NSError *failure = self.media.previewPlaybackError;
    if (failure != self.reportedPreviewError) {
        self.reportedPreviewError = failure;
        NSError *statusError = failure ?: self.draftError;
        [self sendUIEvent:@{@"type":@"previewRateStatus", @"rate":@(self.media.previewRate),
            @"message":statusError.localizedDescription ?: @"", @"error":statusError ? @YES : @NO}];
    }
    if (self.pendingSeek) return;
    double output = self.media.currentOutputMilliseconds; BOOL playing = self.media.playbackRequested;
    if (self.clockDelivered && self.lastClockPlaying == playing && fabs(self.lastClockOutput-output)<0.5) return;
    self.clockDelivered = YES; self.lastClockPlaying = playing; self.lastClockOutput = output;
    [self sendUIEvent:@{@"type":@"playback", @"outputMs":@(MAX(0,output)), @"playing":playing ? @YES : @NO}];
}
- (void)exportStatus:(BOOL)busy error:(NSError *)error message:(NSString *)message {
    NSError *statusError = error ?: (busy ? nil : self.draftError);
    self.lastError = statusError;
    [self sendUIEvent:@{@"type":@"exportStatus", @"busy":busy ? @YES : @NO,
        @"message":statusError.localizedDescription ?: message ?: @"", @"error":statusError ? @YES : @NO}];
}
- (NSString *)defaultExportName {
    NSDate *created = nil;
    [[self.directory URLByAppendingPathComponent:@"source.mp4"] getResourceValue:&created forKey:NSURLCreationDateKey error:NULL];
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyyMMdd_HHmmss";
    return [NSString stringWithFormat:@"moojicut_%@.mp4",[format stringFromDate:created ?: NSDate.date]];
}
- (NSURL *)chooseExportDestination {
    NSSavePanel *panel = NSSavePanel.savePanel;
    panel.allowedContentTypes = @[UTTypeMPEG4Movie]; panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = self.defaultExportName; panel.prompt = @"保存视频";
    return [panel runModal] == NSModalResponseOK ? panel.URL : nil;
}
- (void)saveAs:(__unused id)sender {
    if (self.closed || self.exporting) return;
    self.choosingExport = YES; [self changed];
    NSURL *destination = [self chooseExportDestination];
    self.choosingExport = NO;
    if (destination && !self.closed) {
        // The next method raises exportActive before notifying the host; there
        // is no false idle notification between the panel and the encoder.
        [self exportToURL:destination copyToPasteboard:NO completion:nil];
    } else { [self exportStatus:NO error:nil message:@""]; [self changed]; }
}
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion {
    if (self.closed || self.exporting) { if (completion) completion(nil,MCVideoError(@"编辑器已关闭或已有保存正在进行。")); return; }
    NSError *error = nil;
    if (!self.mediaPrepared) [self synchronizeMedia:&error];
    if (!self.mediaSynchronized) error = error ?: MCVideoError(@"预览尚未同步，无法导出旧计划。请撤销后重试。");
    if (!error && ![self saveDraft:&error]) error = error ?: MCVideoError(@"草稿保存失败，编辑仍保留在内存中。请重试。");
    if (error) {
        [self exportStatus:NO error:error message:nil]; [self changed]; if (completion) completion(nil,error); return;
    }
    self.exportActive = YES; self.lastExportPercent = -1; self.closeAfterExportCancellation = NO;
    NSUInteger generation = ++self.exportGeneration;
    [self exportStatus:YES error:nil message:@"正在保存视频…"]; [self changed];
    __weak MCVideoEditor *weak = self;
    [self.media exportToURL:url completion:^(NSURL *saved, NSError *failure) {
        MCVideoEditor *self = weak; if (!self || self.closed || generation != self.exportGeneration) return;
        self.exportActive = NO;
        BOOL closeAfter = self.closeAfterExportCancellation; self.closeAfterExportCancellation = NO;
        if (!failure && copy) {
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard; [pasteboard clearContents];
            if (![pasteboard writeObjects:@[saved]]) failure = MCVideoError(@"视频已保存，但复制文件失败。请从保存位置打开。");
        }
        [self exportStatus:NO error:failure message:saved ? [NSString stringWithFormat:@"已保存：%@", saved.path] : @""];
        [self changed]; if (completion) completion(failure ? nil : saved,failure);
        if (closeAfter && !self.closed && generation == self.exportGeneration && !self.exporting) [self.window performClose:nil];
    }];
}
- (void)cancelExportKeepingDraft { [self.media cancelExport]; }
- (BOOL)confirmCancelExport {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"正在保存视频"; alert.informativeText = @"停止保存会保留原片与编辑草稿。";
    [alert addButtonWithTitle:@"继续保存"]; [alert addButtonWithTitle:@"停止保存并关闭"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}
- (BOOL)windowShouldClose:(__unused NSWindow *)sender {
    if (self.closed) return YES;
    if (self.choosingExport) return NO;
    if (self.exportActive) {
        NSUInteger pending = self.exportGeneration; BOOL cancel = [self confirmCancelExport];
        // A modal confirmation can deliver completion or start a newer export.
        // Never attach the close request to that finished/newer task.
        if (self.exportActive && self.exportGeneration == pending) {
            if (cancel) { self.closeAfterExportCancellation = YES; [self cancelExportKeepingDraft]; }
            return NO;
        }
        if (!cancel || self.exporting || self.exportGeneration != pending) return NO;
    }
    NSError *error = nil;
    if (![self saveDraft:&error]) { [self reportError:MCVideoError([NSString stringWithFormat:@"草稿保存失败，窗口保持打开，编辑仍在内存。%@",error.localizedDescription ?: @""])]; return NO; }
    return YES;
}
- (BOOL)prepareForTermination:(NSError **)error {
    if (self.closed) return YES;
    if (self.exporting) { if (error) *error = MCVideoError(@"视频仍在保存，请等待完成或取消后退出。"); return NO; }
    [self sendUIEvent:@{@"type":@"cancel"}];
    NSError *failure = nil;
    if (![self saveDraft:&failure]) {
        failure = MCVideoError([NSString stringWithFormat:@"编辑草稿保存失败，已取消退出，编辑仍保留在内存中。%@", failure.localizedDescription ?: @""]);
        [self reportError:failure]; if (error) *error = failure; return NO;
    }
    return YES;
}
- (void)windowWillClose:(__unused NSNotification *)notification {
    if (self.closed) return;
    [self sendUIEvent:@{@"type":@"cancel"}]; self.closed = YES; self.seekGeneration++; self.exportGeneration++;
    self.exportActive = NO; self.choosingExport = NO; self.closeAfterExportCancellation = NO;
    [self.timer invalidate]; self.timer = nil;
    [self.waveformTask cancel]; self.waveformTask = nil;
    self.canvas.onEvent = nil; self.canvas.onFrameNeeded = nil; [self.canvas setVideoPlayer:nil]; [self.media close];
    if (self.ui >= 0) { video_ui_close(self.ui); self.ui = -1; }
    if (self.session >= 0) { video_project_close(self.session); self.session = -1; }
    self.window.delegate = nil; self.window.contentView = nil; self.window = nil; self.canvas = nil;
    void (^closed)(void) = self.onClose; self.onClose = nil; self.onStateChange = nil;
    if (closed) closed();
}
- (void)dealloc {
    [_timer invalidate]; _canvas.onEvent = nil; _canvas.onFrameNeeded = nil;
    [_media close];
    [_waveformTask cancel];
    if (_ui >= 0) video_ui_close(_ui);
    if (_session >= 0) video_project_close(_session);
}
+ (BOOL)makeSyntheticVideo:(NSURL *)url error:(NSError **)error {
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:error];
    if (!writer) return NO;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264, AVVideoWidthKey:@320, AVVideoHeightKey:@240}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA), (NSString *)kCVPixelBufferWidthKey:@320, (NSString *)kCVPixelBufferHeightKey:@240}];
    [writer addInput:input]; if (![writer startWriting]) { if (error) *error = writer.error; return NO; }
    [writer startSessionAtSourceTime:kCMTimeZero];
    for (int frame = 0; frame < 120; frame++) {
        if (!MCWaitUntil(^BOOL { return input.readyForMoreMediaData || writer.status == AVAssetWriterStatusFailed; }, 10) || writer.status == AVAssetWriterStatusFailed) { [writer cancelWriting]; if (error) *error = writer.error ?: MCVideoError(@"合成视频写入超时。"); return NO; }
        CVPixelBufferRef pixel = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixel) != kCVReturnSuccess) { [writer cancelWriting]; if (error) *error = MCVideoError(@"无法分配测试帧。"); return NO; }
        CVPixelBufferLockBaseAddress(pixel, 0); uint8_t *bytes = CVPixelBufferGetBaseAddress(pixel); size_t row = CVPixelBufferGetBytesPerRow(pixel);
        for (int y=0; y<240; y++) for (int x=0; x<320; x++) {
            uint8_t *p = bytes + y*row + x*4; p[0]=(uint8_t)y; p[1]=(uint8_t)x; p[2]=(uint8_t)(frame*2); p[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        BOOL appended = [adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame, 30)]; CVPixelBufferRelease(pixel);
        if (!appended) { [writer cancelWriting]; if (error) *error = writer.error; return NO; }
    }
    [input markAsFinished]; [writer endSessionAtSourceTime:CMTimeMake(4, 1)];
    __block BOOL done = NO; [writer finishWritingWithCompletionHandler:^{ dispatch_async(dispatch_get_main_queue(), ^{ done = YES; }); }];
    if (!MCWaitUntil(^BOOL { return done; }, 30) || writer.status != AVAssetWriterStatusCompleted) { [writer cancelWriting]; if (error) *error = writer.error ?: MCVideoError(@"合成视频未完成。"); return NO; }
    return YES;
}

+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSURL *raw = [directory URLByAppendingPathComponent:@"raw.mp4"], *audioURL = [directory URLByAppendingPathComponent:@"tone.caf"];
    if (![self makeSyntheticVideo:raw error:error]) return NO;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:192000]; buffer.frameLength = 192000;
    for (AVAudioFrameCount i=0; i<buffer.frameLength; i++) buffer.floatChannelData[0][i] = (float)(0.04*sin(2*M_PI*440*i/48000));
    AVAudioFile *audioFile = [[AVAudioFile alloc] initForWriting:audioURL settings:format.settings error:error];
    if (!audioFile || ![audioFile writeFromBuffer:buffer error:error]) return NO;
    audioFile = nil;
    AVURLAsset *video = [AVURLAsset URLAssetWithURL:raw options:nil], *audio = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    AVMutableComposition *source = [AVMutableComposition composition];
    AVMutableCompositionTrack *v = [source addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *a = [source addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTimeRange full = CMTimeRangeMake(kCMTimeZero, CMTimeMake(4,1));
    if (![v insertTimeRange:full ofTrack:MCVideoTracks(video, AVMediaTypeVideo).firstObject atTime:kCMTimeZero error:error] ||
        ![a insertTimeRange:full ofTrack:MCVideoTracks(audio, AVMediaTypeAudio).firstObject atTime:kCMTimeZero error:error]) return NO;
    NSURL *sourceURL = [directory URLByAppendingPathComponent:@"source.mp4"];
    if (!MCExportSync(source,nil,sourceURL,error)) return NO;
    NSData *sourceBytes = [NSData dataWithContentsOfURL:sourceURL];
    // Prepare a genuine v1 draft. Production initialization must migrate only
    // in memory, preserving both the original movie and the old edit file.
    MCVideoMedia *metadata = [[MCVideoMedia alloc] initWithURL:sourceURL error:error];
    if (!metadata) return NO;
    moonbit_string_t src = MCVideoString(MCVideoJSON(metadata.metadata)), empty = MCVideoString(@"");
    NSDictionary *legacy = MCVideoDecode(video_open(src,empty)); moonbit_decref(src); moonbit_decref(empty); [metadata close];
    int32_t oldSession = [legacy[@"session"] intValue];
    for (NSDictionary *op in @[
        @{@"type":@"trim",@"trim":@{@"startMs":@500,@"endMs":@3500}},
        @{@"type":@"cut",@"cut":@{@"startMs":@1000,@"endMs":@1500}},
        @{@"type":@"cut",@"cut":@{@"startMs":@2000,@"endMs":@2500}},
        @{@"type":@"crop",@"crop":@{@"x":@20,@"y":@30,@"width":@160,@"height":@100}}
    ]) {
        moonbit_string_t input = MCVideoString(MCVideoJSON(op)); legacy = MCVideoDecode(video_command(oldSession,input)); moonbit_decref(input);
        if (![legacy[@"ok"] boolValue]) { video_dispose(oldSession); if (error) *error=MCVideoError(@"无法准备旧草稿测试数据。"); return NO; }
    }
    video_dispose(oldSession);
    NSData *legacyBytes = [NSJSONSerialization dataWithJSONObject:legacy[@"document"] options:0 error:error];
    NSURL *oldURL = [directory URLByAppendingPathComponent:@"edit.json"], *newURL = [directory URLByAppendingPathComponent:@"edit-v2.json"];
    if (![legacyBytes writeToURL:oldURL options:NSDataWritingAtomic error:error]) return NO;
    MCVideoEditor *editor = [[self alloc] initWithDraftDirectory:directory error:error];
    if (!editor || editor.window || [files fileExistsAtPath:newURL.path] || [editor.state[@"document"][@"schemaVersion"] intValue]!=2) return NO;
    [editor buildWindow];
    BOOL (^click)(NSString *) = ^BOOL(NSString *identifier) {
        [editor render];
        for (NSDictionary *item in editor.canvas.frameDescription[@"semantics"]) if ([item[@"id"] isEqual:identifier]) {
            if (![item[@"enabled"] boolValue]) return NO;
            double x=[item[@"x"] doubleValue]+[item[@"width"] doubleValue]/2;
            double y=[item[@"y"] doubleValue]+[item[@"height"] doubleValue]/2;
            editor.canvas.onEvent(@{@"type":@"pointerDown",@"x":@(x),@"y":@(y)});
            editor.canvas.onEvent(@{@"type":@"pointerUp",@"x":@(x),@"y":@(y)});
            return YES;
        }
        return NO;
    };
    NSDictionary *before = editor.state[@"plan"];
    [editor sendUIEvent:@{@"type":@"playback",@"outputMs":@250,@"playing":@NO}];
    if (!click(@"project-split") || [editor.state[@"plan"][@"video"] count]!=4 || !click(@"undo") ||
        ![editor.state[@"plan"] isEqual:before] || editor.draftDirty || editor.window.visible) {
        if (error) *error=editor.lastError ?: MCVideoError(@"正式共享编辑器输入、撤销或草稿写入检查失败。"); return NO;
    }
    for (NSUInteger pass=0; pass<2; pass++) {
        if (pass && (!click(@"project-mute") || ![editor.state[@"document"][@"muted"] boolValue])) return NO;
        NSURL *output=[directory URLByAppendingPathComponent:pass ? @"muted.mp4" : @"audible.mp4"];
        __block BOOL done=NO; __block NSError *failure=nil;
        [editor exportToURL:output copyToPasteboard:NO completion:^(__unused NSURL *saved,NSError *problem){failure=problem;done=YES;}];
        if (!MCWaitUntil(^BOOL{return done;},60) || failure) { if(error)*error=failure ?: MCVideoError(@"正式适配器导出超时。"); return NO; }
        AVURLAsset *result=[AVURLAsset URLAssetWithURL:output options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        AVAssetTrack *track=MCVideoTracks(result,AVMediaTypeVideo).firstObject;
        if (!track || fabs(CMTimeGetSeconds(result.duration)-2)>0.12 || track.naturalSize.width!=160 || track.naturalSize.height!=100 ||
            MCVideoTracks(result,AVMediaTypeAudio).count!=(pass ? 0u:1u)) { if(error)*error=MCVideoError(@"正式导出时长、裁画面或音轨不一致。"); return NO; }
        AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:result error:error];
        AVAssetReaderTrackOutput *frames=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        if (!reader || ![reader canAddOutput:frames]) return NO;
        [reader addOutput:frames]; if(![reader startReading]) { if(error)*error=reader.error;return NO; }
        CMSampleBufferRef sample=[frames copyNextSampleBuffer]; CVPixelBufferRef pixels=sample ? CMSampleBufferGetImageBuffer(sample):NULL;
        BOOL correct=NO;
        if(pixels) { CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
            uint8_t *center=(uint8_t *)CVPixelBufferGetBaseAddress(pixels)+50*CVPixelBufferGetBytesPerRow(pixels)+80*4;
            correct=abs(center[0]-80)<18 && abs(center[1]-100)<18;
            CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly); }
        if(sample)CFRelease(sample); [reader cancelReading];
        if(!correct){if(error)*error=MCVideoError(@"正式导出裁剪原点不正确。");return NO;}
    }
    MCVideoEditor *reopened=[[self alloc] initWithDraftDirectory:directory error:error];
    if(!reopened || ![reopened.state[@"plan"] isEqual:editor.state[@"plan"]] ||
        ![[NSData dataWithContentsOfURL:sourceURL] isEqual:sourceBytes] || ![[NSData dataWithContentsOfURL:oldURL] isEqual:legacyBytes]) {
        if(error && !*error)*error=MCVideoError(@"v2草稿恢复或原片保护检查失败。");return NO;
    }
    [editor.window close];
    return YES;
}
@end
