#import "MCVideoEditor.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "native/macos/runtime/MCRuntimeProfile.h"
#include "moonbit.h"
#include <math.h>

extern moonbit_string_t video_open(moonbit_string_t, moonbit_string_t);
extern moonbit_string_t video_command(int32_t, moonbit_string_t);
extern moonbit_string_t video_snapshot(int32_t);
extern moonbit_string_t video_seek(int32_t, double);
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
    NSString *string = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)];
    moonbit_decref(value);
    return [NSJSONSerialization JSONObjectWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
static NSArray<AVAssetTrack *> *MCVideoTracks(AVAsset *asset, AVMediaType type) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:type]) [tracks addObject:track];
    return tracks;
}
static CGRect MCVideoBounds(AVAssetTrack *track) {
    return CGRectApplyAffineTransform(CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height), track.preferredTransform);
}
static NSURL *MCExportDirectory(void) {
    return [MCRuntimeSupportDirectory(@"MoojiCut") URLByAppendingPathComponent:@"Exports" isDirectory:YES];
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

@interface MCVideoEditor () <NSTextFieldDelegate>
@property NSURL *directory;
@property AVURLAsset *asset;
@property AVAssetTrack *videoTrack;
@property NSDictionary *state;
@property int32_t session;
@property BOOL sessionOpen;
@property NSWindow *window;
@property AVPlayerView *playerView;
@property NSTextField *trimStart, *trimEnd, *cutStart, *cutEnd, *cropX, *cropY, *cropWidth, *cropHeight, *seekTime;
@property NSTextField *status, *cutsLabel;
@property NSButton *mute, *confirm, *undoButton, *redoButton;
@property NSSlider *trimStartSlider, *trimEndSlider;
@property NSStackView *advanced;
@property NSMutableArray<NSControl *> *editingControls;
@property AVAssetExportSession *exporter;
@property NSTimer *progressTimer;
@property BOOL closeAfterExportCancellation;
@property BOOL pendingTrim, pendingCrop, pendingCut;
@property BOOL choosingExport, exportCancellationRequested;
- (BOOL)applyCommand:(NSDictionary *)command error:(NSError **)error;
- (BOOL)buildComposition:(AVMutableComposition * _Nullable * _Nonnull)composition videoComposition:(AVMutableVideoComposition * _Nullable * _Nonnull)videoComposition error:(NSError **)error;
@end

@implementation MCVideoEditor
- (BOOL)exporting { return self.exporter != nil || self.choosingExport; }
- (instancetype)initWithDraftDirectory:(NSURL *)directory error:(NSError **)error {
    if ((self = [super init])) {
        _directory = directory;
        NSURL *source = [directory URLByAppendingPathComponent:@"source.mp4"];
        _asset = [AVURLAsset URLAssetWithURL:source options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        _videoTrack = MCVideoTracks(_asset, AVMediaTypeVideo).firstObject;
        if (!_videoTrack) { if (error) *error = MCVideoError(@"录屏没有可读取的画面，原始文件已保留。"); return nil; }
        // Audio can outlast the last recorded video frame. Keep the source
        // timeline inside the video track, with no rounding past its end.
        double duration = CMTimeGetSeconds(CMTimeRangeGetEnd(_videoTrack.timeRange));
        if (!isfinite(duration) || duration <= 0) {
            if (error) *error = MCVideoError(@"录屏没有可读取的画面。原始文件已保留在草稿目录。"); return nil;
        }
        CGRect bounds = MCVideoBounds(_videoTrack);
        NSDictionary *metadata = @{ @"durationMs":@(floor(duration * 1000)), @"width":@(llround(fabs(bounds.size.width))),
            @"height":@(llround(fabs(bounds.size.height))), @"hasAudio":MCVideoTracks(_asset, AVMediaTypeAudio).count > 0 ? @YES : @NO };
        NSString *draft = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:@"edit.json"] encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        moonbit_string_t input = MCVideoString(MCVideoJSON(metadata)), saved = MCVideoString(draft);
        _state = MCVideoDecode(video_open(input, saved)); moonbit_decref(input); moonbit_decref(saved);
        if (![_state[@"ok"] boolValue]) { if (error) *error = MCVideoError(_state[@"error"][@"message"] ?: @"无法恢复视频编辑草稿。"); return nil; }
        _session = [_state[@"session"] intValue]; _sessionOpen = YES;
        _editingControls = [NSMutableArray array];
    }
    return self;
}
- (BOOL)saveDraft:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.state[@"document"] options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:[self.directory URLByAppendingPathComponent:@"edit.json"] options:NSDataWritingAtomic error:error];
}
- (BOOL)applyCommand:(NSDictionary *)command error:(NSError **)error {
    moonbit_string_t input = MCVideoString(MCVideoJSON(command));
    NSDictionary *next = MCVideoDecode(video_command(self.session, input)); moonbit_decref(input);
    if (![next[@"ok"] boolValue]) { if (error) *error = MCVideoError(next[@"error"][@"message"] ?: @"无法应用这项编辑。"); return NO; }
    self.state = next;
    return [self saveDraft:error];
}
- (BOOL)buildComposition:(AVMutableComposition **)result videoComposition:(AVMutableVideoComposition **)videoResult error:(NSError **)error {
    NSDictionary *plan = self.state[@"plan"];
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *video = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    NSArray<AVAssetTrack *> *audioSources = [plan[@"muted"] boolValue] ? @[] : MCVideoTracks(self.asset, AVMediaTypeAudio);
    NSMutableArray<AVMutableCompositionTrack *> *audioOutputs = [NSMutableArray array];
    for (__unused AVAssetTrack *source in audioSources)
        [audioOutputs addObject:[composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]];
    for (NSDictionary *segment in plan[@"segments"]) {
        CMTime begin = CMTimeMake([segment[@"sourceStartMs"] longLongValue], 1000);
        CMTime end = CMTimeMake([segment[@"sourceEndMs"] longLongValue], 1000);
        CMTime output = CMTimeMake([segment[@"outputStartMs"] longLongValue], 1000);
        CMTimeRange range = CMTimeRangeFromTimeToTime(begin, end);
        if (![video insertTimeRange:range ofTrack:self.videoTrack atTime:output error:error]) return NO;
        for (NSUInteger i = 0; i < audioSources.count; i++) {
            CMTimeRange available = CMTimeRangeGetIntersection(range, audioSources[i].timeRange);
            if (CMTIMERANGE_IS_VALID(available) && CMTimeCompare(available.duration, kCMTimeZero) > 0) {
                CMTime position = CMTimeAdd(output, CMTimeSubtract(available.start, range.start));
                if (![audioOutputs[i] insertTimeRange:available ofTrack:audioSources[i] atTime:position error:error]) return NO;
            }
        }
    }
    NSDictionary *crop = [plan[@"crop"] isKindOfClass:NSDictionary.class] ? plan[@"crop"] : nil;
    CGRect bounds = MCVideoBounds(self.videoTrack);
    CGFloat x = [crop[@"x"] doubleValue], y = [crop[@"y"] doubleValue];
    CGFloat width = crop ? [crop[@"width"] doubleValue] : fabs(bounds.size.width);
    CGFloat height = crop ? [crop[@"height"] doubleValue] : fabs(bounds.size.height);
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.renderSize = CGSizeMake(width, height); videoComposition.frameDuration = CMTimeMake(1, 30);
    AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:video];
    CGAffineTransform transform = CGAffineTransformConcat(self.videoTrack.preferredTransform, CGAffineTransformMakeTranslation(-bounds.origin.x - x, -bounds.origin.y - y));
    [layer setTransform:transform atTime:kCMTimeZero];
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake([plan[@"outputDurationMs"] longLongValue], 1000));
    instruction.layerInstructions = @[layer]; videoComposition.instructions = @[instruction];
    *result = composition; *videoResult = videoComposition; return YES;
}
- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action]; button.bezelStyle = NSBezelStyleRounded;
    [self.editingControls addObject:button]; return button;
}
- (NSTextField *)field:(NSString *)label width:(CGFloat)width {
    NSTextField *field = [NSTextField textFieldWithString:@"0"];
    field.delegate = self;
    field.accessibilityLabel = label; field.alignment = NSTextAlignmentRight;
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    [self.editingControls addObject:field]; return field;
}
- (NSStackView *)row:(NSArray<NSView *> *)views {
    NSStackView *row = [NSStackView stackViewWithViews:views]; row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 10; row.alignment = NSLayoutAttributeCenterY; return row;
}
- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 710)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"编辑录屏 · Mooji Cut"; self.window.releasedWhenClosed = NO; self.window.delegate = self;
    self.window.minSize = NSMakeSize(950, 720);
    self.playerView = [AVPlayerView new]; self.playerView.controlsStyle = AVPlayerViewControlsStyleDefault;
    [self.playerView.heightAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    self.trimStart = [self field:@"保留片段起点，秒" width:84]; self.trimEnd = [self field:@"保留片段终点，秒" width:84];
    self.cutStart = [self field:@"删除片段起点，秒" width:84]; self.cutEnd = [self field:@"删除片段终点，秒" width:84];
    self.cropX = [self field:@"画面左侧像素" width:62]; self.cropY = [self field:@"画面顶部像素" width:62];
    self.cropWidth = [self field:@"画面宽度像素" width:72]; self.cropHeight = [self field:@"画面高度像素" width:72];
    self.seekTime = [self field:@"原片预览位置，秒" width:84];
    self.mute = [NSButton checkboxWithTitle:@"静音" target:self action:@selector(muteChanged:)]; [self.editingControls addObject:self.mute];
    self.cutsLabel = [NSTextField wrappingLabelWithString:@""]; self.cutsLabel.font = [NSFont systemFontOfSize:11]; self.cutsLabel.textColor = NSColor.secondaryLabelColor;
    self.status = [NSTextField wrappingLabelWithString:@""]; self.status.font = [NSFont systemFontOfSize:12];
    self.undoButton = [self button:@"撤销" action:@selector(undo:)]; self.redoButton = [self button:@"重做" action:@selector(redo:)];
    self.confirm = [self button:@"保存 MP4…" action:@selector(saveAs:)]; self.confirm.keyEquivalent = @"\r";
    double duration = [self.state[@"document"][@"source"][@"durationMs"] doubleValue] / 1000;
    self.trimStartSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:duration target:self action:@selector(sliderTrim:)];
    self.trimEndSlider = [NSSlider sliderWithValue:duration minValue:0 maxValue:duration target:self action:@selector(sliderTrim:)];
    self.trimStartSlider.continuous = NO; self.trimEndSlider.continuous = NO;
    self.trimStartSlider.accessibilityLabel = @"保留起点"; self.trimEndSlider.accessibilityLabel = @"保留终点";
    [self.editingControls addObjectsFromArray:@[self.trimStartSlider,self.trimEndSlider]];
    NSTextField *(^label)(NSString *) = ^NSTextField *(NSString *text) { return [NSTextField labelWithString:text]; };
    NSStackView *trim = [self row:@[label(@"保留范围（原片秒数）"), self.trimStart, label(@"到"), self.trimEnd, [self button:@"应用裁剪" action:@selector(trim:)]]];
    NSStackView *trimSliders = [self row:@[label(@"起点"), self.trimStartSlider, label(@"终点"), self.trimEndSlider]];
    [self.trimStartSlider.widthAnchor constraintEqualToAnchor:self.trimEndSlider.widthAnchor].active = YES;
    NSStackView *cuts = [self row:@[label(@"删除片段（原片秒数）"), self.cutStart, label(@"到"), self.cutEnd, [self button:@"添加删除区间" action:@selector(cut:)], [self button:@"清除删除区间" action:@selector(clearCuts:)]]];
    NSStackView *crop = [self row:@[label(@"裁画面（像素） X"), self.cropX, label(@"Y"), self.cropY, label(@"宽"), self.cropWidth, label(@"高"), self.cropHeight, [self button:@"应用画面" action:@selector(crop:)], [self button:@"完整画面" action:@selector(resetCrop:)]]];
    NSStackView *preview = [self row:@[label(@"预览原片位置（秒）"), self.seekTime, [self button:@"跳到保留画面" action:@selector(seek:)], self.mute, self.undoButton, self.redoButton, [self button:@"重置编辑" action:@selector(reset:)]]];
    NSView *spacer = [NSView new]; [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *cancel = [NSButton buttonWithTitle:@"保留草稿并关闭" target:self action:@selector(cancel:)]; cancel.bezelStyle = NSBezelStyleRounded;
    NSButton *more = [NSButton checkboxWithTitle:@"更多编辑：删除片段、裁画面、静音" target:self action:@selector(toggleAdvanced:)];
    [self.editingControls addObject:more];
    self.advanced = [NSStackView stackViewWithViews:@[cuts,self.cutsLabel,crop,preview]];
    self.advanced.orientation = NSUserInterfaceLayoutOrientationVertical; self.advanced.alignment = NSLayoutAttributeLeading;
    self.advanced.spacing = 10; self.advanced.hidden = YES;
    NSStackView *footer = [self row:@[cancel, spacer, [self button:@"复制视频文件" action:@selector(confirm:)], self.confirm]];
    NSStackView *stack = [NSStackView stackViewWithViews:@[self.playerView, trimSliders, trim, more, self.advanced, self.status, footer]];
    stack.detachesHiddenViews = YES;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.spacing = 12; stack.alignment = NSLayoutAttributeLeading; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [trimSliders.widthAnchor constraintEqualToAnchor:self.playerView.widthAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor constant:-20],
        [self.playerView.widthAnchor constraintEqualToAnchor:stack.widthAnchor], [footer.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.status.widthAnchor constraintEqualToAnchor:stack.widthAnchor], [self.cutsLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [self.playerView setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self.window center]; [self refresh];
}
- (void)show { if (!self.window) [self buildWindow]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)feedback:(NSError *)error { self.status.stringValue = error.localizedDescription ?: @"编辑已保存。"; self.status.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor; }
- (void)refresh {
    NSDictionary *document = self.state[@"document"], *source = document[@"source"], *trim = document[@"trim"];
    self.trimStart.stringValue = [NSString stringWithFormat:@"%.3f", [trim[@"startMs"] doubleValue] / 1000];
    self.trimEnd.stringValue = [NSString stringWithFormat:@"%.3f", [trim[@"endMs"] doubleValue] / 1000];
    self.trimStartSlider.doubleValue = [trim[@"startMs"] doubleValue] / 1000;
    self.trimEndSlider.doubleValue = [trim[@"endMs"] doubleValue] / 1000;
    NSDictionary *crop = [document[@"crop"] isKindOfClass:NSDictionary.class] ? document[@"crop"] : nil;
    self.cropX.integerValue = [crop[@"x"] integerValue]; self.cropY.integerValue = [crop[@"y"] integerValue];
    self.cropWidth.integerValue = [crop ? crop[@"width"] : source[@"width"] integerValue];
    self.cropHeight.integerValue = [crop ? crop[@"height"] : source[@"height"] integerValue];
    self.pendingTrim = NO; self.pendingCrop = NO;
    self.mute.state = [document[@"muted"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.mute.enabled = [source[@"hasAudio"] boolValue];
    self.undoButton.enabled = [self.state[@"canUndo"] boolValue]; self.redoButton.enabled = [self.state[@"canRedo"] boolValue];
    NSMutableArray *ranges = [NSMutableArray array];
    for (NSDictionary *cut in document[@"cuts"]) [ranges addObject:[NSString stringWithFormat:@"%.3f–%.3f 秒", [cut[@"startMs"] doubleValue]/1000, [cut[@"endMs"] doubleValue]/1000]];
    self.cutsLabel.stringValue = ranges.count ? [@"已删除：" stringByAppendingString:[ranges componentsJoinedByString:@"；"]] : @"尚未删除片段。所有编辑保留原片，可撤销。";
    AVMutableComposition *composition = nil; AVMutableVideoComposition *videoComposition = nil; NSError *error = nil;
    if (![self buildComposition:&composition videoComposition:&videoComposition error:&error]) { [self feedback:error]; return; }
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:composition]; item.videoComposition = videoComposition;
    [self.playerView.player pause]; self.playerView.player = [AVPlayer playerWithPlayerItem:item];
    self.status.textColor = NSColor.secondaryLabelColor;
    self.status.stringValue = [NSString stringWithFormat:@"成片 %.3f 秒 · %.0f × %.0f · 选择保存位置或复制视频文件 · 原片和编辑草稿保留", [self.state[@"plan"][@"outputDurationMs"] doubleValue]/1000, videoComposition.renderSize.width, videoComposition.renderSize.height];
}
- (BOOL)number:(NSTextField *)field value:(double *)value integer:(BOOL)integer {
    NSScanner *scanner = [NSScanner scannerWithString:field.stringValue]; double number = 0;
    if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number) || (integer && floor(number) != number)) {
        [self feedback:MCVideoError(integer ? @"像素值需要填写整数。" : @"时间需要填写有效秒数，例如 1.250。")]; return NO;
    }
    *value = number; return YES;
}
- (void)controlTextDidChange:(NSNotification *)notification {
    id field = notification.object;
    if (field == self.trimStart || field == self.trimEnd) self.pendingTrim = YES;
    if (field == self.cropX || field == self.cropY || field == self.cropWidth || field == self.cropHeight) self.pendingCrop = YES;
    if (field == self.cutStart || field == self.cutEnd) self.pendingCut = YES;
}
- (BOOL)command:(NSDictionary *)command {
    if (self.exporter) return NO;
    NSError *error = nil;
    if (![self applyCommand:command error:&error]) { [self feedback:error]; return NO; }
    [self refresh];
    return YES;
}
- (void)trim:(__unused id)sender {
    double start, end; if (![self number:self.trimStart value:&start integer:NO] || ![self number:self.trimEnd value:&end integer:NO]) return;
    [self command:@{@"type":@"trim", @"trim":@{@"startMs":@(round(start*1000)), @"endMs":@(round(end*1000))}}];
}
- (void)sliderTrim:(__unused id)sender {
    self.trimStart.stringValue = [NSString stringWithFormat:@"%.3f", self.trimStartSlider.doubleValue];
    self.trimEnd.stringValue = [NSString stringWithFormat:@"%.3f", self.trimEndSlider.doubleValue];
    self.pendingTrim = YES; [self trim:nil];
}
- (void)toggleAdvanced:(NSButton *)sender { self.advanced.hidden = sender.state != NSControlStateValueOn; }
- (void)cut:(__unused id)sender {
    double start, end; if (![self number:self.cutStart value:&start integer:NO] || ![self number:self.cutEnd value:&end integer:NO]) return;
    if ([self command:@{@"type":@"cut", @"cut":@{@"startMs":@(round(start*1000)), @"endMs":@(round(end*1000))}}]) {
        self.pendingCut = NO;
        self.cutStart.stringValue = @"0"; self.cutEnd.stringValue = @"0";
    }
}
- (void)clearCuts:(__unused id)sender { [self command:@{@"type":@"clearCuts"}]; }
- (void)crop:(__unused id)sender {
    double x,y,w,h; if (![self number:self.cropX value:&x integer:YES] || ![self number:self.cropY value:&y integer:YES] || ![self number:self.cropWidth value:&w integer:YES] || ![self number:self.cropHeight value:&h integer:YES]) return;
    [self command:@{@"type":@"crop", @"crop":@{@"x":@(x), @"y":@(y), @"width":@(w), @"height":@(h)}}];
}
- (void)resetCrop:(__unused id)sender { [self command:@{@"type":@"crop", @"crop":NSNull.null}]; }
- (void)muteChanged:(__unused id)sender { [self command:@{@"type":@"mute", @"muted":self.mute.state == NSControlStateValueOn ? @YES : @NO}]; }
- (void)undo:(__unused id)sender { [self command:@{@"type":@"undo"}]; }
- (void)redo:(__unused id)sender { [self command:@{@"type":@"redo"}]; }
- (void)reset:(__unused id)sender { [self command:@{@"type":@"reset"}]; }
- (void)seek:(__unused id)sender {
    double seconds; if (![self number:self.seekTime value:&seconds integer:NO]) return;
    NSDictionary *seek = MCVideoDecode(video_seek(self.session, seconds*1000));
    if (![seek[@"ok"] boolValue]) { [self feedback:MCVideoError(seek[@"error"][@"message"])]; return; }
    [self.playerView.player seekToTime:CMTimeMake([seek[@"outputMs"] longLongValue], 1000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}
- (BOOL)confirmPendingEdits {
    if (self.exporting) return NO;
    [self.window makeFirstResponder:nil];
    if (self.pendingTrim || self.pendingCrop || self.pendingCut) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"还有未应用的编辑";
        alert.informativeText = @"输入框中有尚未应用的编辑。请返回并点击对应的应用按钮；也可只导出当前预览。";
        [alert addButtonWithTitle:@"返回编辑"]; [alert addButtonWithTitle:@"导出当前预览"];
        if ([alert runModal] != NSAlertSecondButtonReturn) return NO;
    }
    return YES;
}
- (void)saveAs:(__unused id)sender {
    if (![self confirmPendingEdits]) return;
    NSSavePanel *panel = NSSavePanel.savePanel;
    panel.allowedContentTypes = @[UTTypeMPEG4Movie]; panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = @"MoojiCut.mp4"; panel.prompt = @"保存视频";
    self.choosingExport = YES; if (self.onStateChange) self.onStateChange();
    NSModalResponse response = [panel runModal];
    self.choosingExport = NO; if (self.onStateChange) self.onStateChange();
    if (response == NSModalResponseOK) [self exportToURL:panel.URL copyToPasteboard:NO completion:nil];
}
- (void)confirm:(__unused id)sender {
    if (![self confirmPendingEdits]) return;
    NSError *error = nil; NSURL *directory = MCExportDirectory();
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) { [self feedback:error]; return; }
    NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"MoojiCut-%@.mp4", NSUUID.UUID.UUIDString]];
    [self exportToURL:url copyToPasteboard:YES completion:nil];
}
- (BOOL)validateExport:(NSURL *)url error:(NSError **)error {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track = MCVideoTracks(asset, AVMediaTypeVideo).firstObject;
    NSDictionary *plan = self.state[@"plan"], *source = self.state[@"document"][@"source"];
    NSDictionary *crop = [plan[@"crop"] isKindOfClass:NSDictionary.class] ? plan[@"crop"] : nil;
    double duration = CMTimeGetSeconds(asset.duration), expected = [plan[@"outputDurationMs"] doubleValue]/1000;
    CGSize size = track.naturalSize;
    BOOL audio = NO;
    if (![plan[@"muted"] boolValue]) for (AVAssetTrack *audioTrack in MCVideoTracks(self.asset, AVMediaTypeAudio)) {
        for (NSDictionary *segment in plan[@"segments"]) {
            CMTimeRange range = CMTimeRangeFromTimeToTime(CMTimeMake([segment[@"sourceStartMs"] longLongValue],1000), CMTimeMake([segment[@"sourceEndMs"] longLongValue],1000));
            CMTimeRange intersection = CMTimeRangeGetIntersection(range,audioTrack.timeRange);
            if (CMTIMERANGE_IS_VALID(intersection) && CMTimeCompare(intersection.duration,kCMTimeZero)>0) audio = YES;
        }
    }
    if (!track || !isfinite(duration) || fabs(duration-expected)>0.12 ||
        size.width != [crop ? crop[@"width"] : source[@"width"] doubleValue] ||
        size.height != [crop ? crop[@"height"] : source[@"height"] doubleValue] ||
        (MCVideoTracks(asset, AVMediaTypeAudio).count > 0) != audio) {
        if (error) *error = MCVideoError(@"导出结果与预览不一致，未替换目标文件。原片和草稿保留，请重试。"); return NO;
    }
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    AVAssetReaderTrackOutput *frames = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
        outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    if (!reader || ![reader canAddOutput:frames]) return NO;
    [reader addOutput:frames];
    if (![reader startReading]) { if (error) *error = reader.error; return NO; }
    CMSampleBufferRef frame = [frames copyNextSampleBuffer];
    BOOL readable = frame && CMSampleBufferGetImageBuffer(frame); if (frame) CFRelease(frame); [reader cancelReading];
    if (!readable && error) *error = MCVideoError(@"导出的视频无法读取，原片和草稿仍然保留。");
    return readable;
}
// A destination is published only after the MP4 encoder finishes and the actual
// media has been read back. Until then, an existing destination stays untouched.
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion {
    if (self.exporting) { if (completion) completion(nil, MCVideoError(@"已有导出正在进行。")); return; }
    NSError *error = nil;
    if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqual:@"mp4"] ||
        [url.URLByResolvingSymlinksInPath.path isEqual:self.asset.URL.URLByResolvingSymlinksInPath.path]) {
        error = MCVideoError(@"请选择新的 MP4 保存位置，不能覆盖录屏原片。");
        [self feedback:error]; if (completion) completion(nil,error); return;
    }
    AVMutableComposition *composition = nil; AVMutableVideoComposition *videoComposition = nil;
    if (![self saveDraft:&error] || ![self buildComposition:&composition videoComposition:&videoComposition error:&error]) {
        [self feedback:error]; if (completion) completion(nil,error); return;
    }
    NSURL *temporary = [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@".MoojiCut-export-%@.mp4", NSUUID.UUID.UUIDString]];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
    if (!exporter) { error = MCVideoError(@"无法创建导出任务。"); [self feedback:error]; if (completion) completion(nil,error); return; }
    exporter.videoComposition = videoComposition; exporter.outputURL = temporary; exporter.outputFileType = AVFileTypeMPEG4; exporter.shouldOptimizeForNetworkUse = YES;
    self.exporter = exporter; self.exportCancellationRequested = NO; [self.playerView.player pause];
    for (NSControl *control in self.editingControls) control.enabled = NO;
    self.status.stringValue = @"正在导出 0%…";
    if (self.onStateChange) self.onStateChange();
    __weak MCVideoEditor *weakSelf = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(__unused NSTimer *timer) {
        weakSelf.status.stringValue = [NSString stringWithFormat:@"正在导出 %.0f%%…", weakSelf.exporter.progress * 100];
    }];
    [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressTimer invalidate]; self.progressTimer = nil;
        NSError *failure = nil;
        BOOL cancelled = self.exportCancellationRequested || exporter.status == AVAssetExportSessionStatusCancelled;
        if (cancelled) failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"导出已取消，原片和草稿仍然保留。"}];
        else if (exporter.status != AVAssetExportSessionStatusCompleted) failure = exporter.error ?: MCVideoError(@"视频导出失败，请重试。");
        else if (![self validateExport:temporary error:&failure]) failure = failure ?: MCVideoError(@"无法读取导出结果。");
        if (!failure) {
            BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:url.path];
            BOOL published = exists ? [NSFileManager.defaultManager replaceItemAtURL:url withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:NULL error:&failure] :
                [NSFileManager.defaultManager moveItemAtURL:temporary toURL:url error:&failure];
            if (!published) failure = failure ?: MCVideoError(@"无法保存到所选位置，原片和草稿仍然保留。");
        }
        [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
        self.exporter = nil; self.exportCancellationRequested = NO;
        for (NSControl *control in self.editingControls) control.enabled = YES;
        [self refresh];
        if (!failure && copy) {
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard; [pasteboard clearContents];
            if (![pasteboard writeObjects:@[url]]) failure = MCVideoError([@"视频已保存，但复制失败：" stringByAppendingString:url.path]);
        }
        if (failure) [self feedback:failure];
        else { self.status.textColor = NSColor.secondaryLabelColor; self.status.stringValue = [NSString stringWithFormat:@"%@：%@ · 草稿已保留，可继续编辑", copy ? @"已复制视频文件，文件保存在" : @"已保存", url.path]; }
        if (self.onStateChange) self.onStateChange();
        if (completion) completion(failure ? nil : url,failure);
        if (self.closeAfterExportCancellation) { self.closeAfterExportCancellation = NO; [self.window performClose:nil]; }
    }); }];
}
- (void)cancelExportKeepingDraft { self.exportCancellationRequested = YES; [self.exporter cancelExport]; }
- (void)cancel:(__unused id)sender { [self.window performClose:nil]; }
- (BOOL)confirmCancelExport {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"正在导出视频"; alert.informativeText = @"停止导出会保留原片与编辑草稿。";
    [alert addButtonWithTitle:@"继续导出"]; [alert addButtonWithTitle:@"停止导出并关闭"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}
- (BOOL)windowShouldClose:(__unused NSWindow *)sender {
    if (self.choosingExport) return NO;
    if (self.exporter) {
        AVAssetExportSession *pending = self.exporter;
        BOOL cancel = [self confirmCancelExport];
        // The modal loop may run the encoder completion. Never leave a close
        // request attached to a finished task (or to a later unrelated export).
        if (self.exporter == pending) {
            if (cancel) { self.closeAfterExportCancellation = YES; [self cancelExportKeepingDraft]; }
            return NO;
        }
        if (!cancel || self.exporter) return NO;
    }
    NSError *error = nil; if (![self saveDraft:&error]) { [self feedback:error]; return NO; } return YES;
}
- (void)windowWillClose:(__unused NSNotification *)notification {
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    [self.playerView.player pause]; self.playerView.player = nil;
    self.window.delegate = nil; self.window.contentView = nil; self.window.toolbar = nil;
    self.window = nil; self.playerView = nil;
    [self.editingControls removeAllObjects];
    if (closed) closed();
}
- (void)dealloc {
    [self.progressTimer invalidate]; [self.exporter cancelExport];
    if (_sessionOpen) video_dispose(_session);
}

// Deterministic local media only: no desktop permission or general clipboard.
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
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSURL *raw = [directory URLByAppendingPathComponent:@"raw.mp4"], *audioURL = [directory URLByAppendingPathComponent:@"tone.caf"];
    if (![self makeSyntheticVideo:raw error:error]) return NO;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:192000]; buffer.frameLength = 192000;
    for (AVAudioFrameCount i=0; i<buffer.frameLength; i++) buffer.floatChannelData[0][i] = (float)(0.04*sin(2*M_PI*440*i/48000));
    AVAudioFile *audioFile = [[AVAudioFile alloc] initForWriting:audioURL settings:format.settings error:error];
    if (!audioFile || ![audioFile writeFromBuffer:buffer error:error]) return NO; audioFile = nil;
    AVURLAsset *video = [AVURLAsset URLAssetWithURL:raw options:nil], *audio = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    AVMutableComposition *source = [AVMutableComposition composition];
    AVMutableCompositionTrack *v = [source addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *a = [source addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTimeRange full = CMTimeRangeMake(kCMTimeZero, CMTimeMake(4,1));
    if (![v insertTimeRange:full ofTrack:MCVideoTracks(video, AVMediaTypeVideo).firstObject atTime:kCMTimeZero error:error] ||
        ![a insertTimeRange:full ofTrack:MCVideoTracks(audio, AVMediaTypeAudio).firstObject atTime:kCMTimeZero error:error]) return NO;
    NSURL *sourceURL = [directory URLByAppendingPathComponent:@"source.mp4"];
    if (!MCExportSync(source, nil, sourceURL, error)) return NO;
    MCVideoEditor *editor = [[self alloc] initWithDraftDirectory:directory error:error]; if (!editor) return NO;
    NSArray *commands = @[
        @{@"type":@"trim", @"trim":@{@"startMs":@500, @"endMs":@3500}},
        @{@"type":@"cut", @"cut":@{@"startMs":@1000, @"endMs":@1500}},
        @{@"type":@"cut", @"cut":@{@"startMs":@2000, @"endMs":@2500}},
        @{@"type":@"crop", @"crop":@{@"x":@20, @"y":@30, @"width":@160, @"height":@100}}
    ];
    for (NSDictionary *command in commands) if (![editor applyCommand:command error:error]) return NO;
    NSDictionary *seek = MCVideoDecode(video_seek(editor.session, 1200));
    if ([seek[@"sourceMs"] integerValue] != 1500 || [seek[@"outputMs"] integerValue] != 500) { if (error) *error = MCVideoError(@"MoonBit seek检查失败。"); return NO; }
    for (NSUInteger iteration=0; iteration<2; iteration++) {
        if (iteration && ![editor applyCommand:@{@"type":@"mute", @"muted":@YES} error:error]) return NO;
        AVMutableComposition *composition = nil; AVMutableVideoComposition *videoComposition = nil;
        if (![editor buildComposition:&composition videoComposition:&videoComposition error:error]) return NO;
        NSURL *output = [directory URLByAppendingPathComponent:iteration ? @"muted.mp4" : @"audible.mp4"];
        if (!MCExportSync(composition, videoComposition, output, error)) return NO;
        AVURLAsset *result = [AVURLAsset URLAssetWithURL:output options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        AVAssetTrack *track = MCVideoTracks(result, AVMediaTypeVideo).firstObject;
        if (!track || fabs(CMTimeGetSeconds(result.duration)-2.0)>0.08 || track.naturalSize.width !=160 || track.naturalSize.height!=100 ||
            MCVideoTracks(result, AVMediaTypeAudio).count != (iteration ? 0u : 1u)) {
            if (error) *error = MCVideoError(@"导出时长、画面尺寸或音轨检查失败。"); return NO;
        }
        // The synthetic source encodes its X/Y coordinates into green/blue.
        // Checking the decoded crop center catches a translated/wrong-origin crop.
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:result error:error];
        AVAssetReaderTrackOutput *frames = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        if (!reader || ![reader canAddOutput:frames]) return NO;
        [reader addOutput:frames]; if (![reader startReading]) { if (error) *error = reader.error; return NO; }
        CMSampleBufferRef sample = [frames copyNextSampleBuffer];
        CVPixelBufferRef pixels = sample ? CMSampleBufferGetImageBuffer(sample) : NULL;
        BOOL cropCorrect = NO;
        if (pixels) {
            CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
            uint8_t *center = (uint8_t *)CVPixelBufferGetBaseAddress(pixels) + 50*CVPixelBufferGetBytesPerRow(pixels) + 80*4;
            cropCorrect = abs(center[0]-80) < 18 && abs(center[1]-100) < 18;
            CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        }
        if (sample) CFRelease(sample); [reader cancelReading];
        if (!cropCorrect) { if (error) *error = MCVideoError(@"导出画面裁剪位置不正确。"); return NO; }
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
        BOOL copied = [pasteboard writeObjects:@[output]] && [[pasteboard readObjectsForClasses:@[NSURL.class] options:@{}].firstObject isEqual:output];
        [pasteboard releaseGlobally];
        if (!copied) { if (error) *error = MCVideoError(@"隔离剪贴板文件复制检查失败。"); return NO; }
    }
    MCVideoEditor *reopened = [[self alloc] initWithDraftDirectory:directory error:error];
    if (!reopened || [reopened.state[@"plan"][@"outputDurationMs"] integerValue] != 2000 || ![reopened.state[@"document"][@"muted"] boolValue]) { if (error && !*error) *error = MCVideoError(@"草稿恢复检查失败。"); return NO; }
    if (![editor applyCommand:@{@"type":@"undo"} error:error] || [editor.state[@"document"][@"muted"] boolValue] || ![editor applyCommand:@{@"type":@"redo"} error:error] || ![editor.state[@"document"][@"muted"] boolValue]) return NO;
    return YES;
}
@end
