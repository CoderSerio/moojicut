// An isolated host for the shared MoonBit component. No application defaults,
// screen capture, global shortcuts, installation or production draft access.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import "plugins/feature/video_editor/macos/MCVideoMedia.h"
#include "native/shared/video_ui.h"
#include "native/shared/video_timeline.h"
#include "native/shared/video_project.h"

extern moonbit_string_t video_open(moonbit_string_t, moonbit_string_t);
extern moonbit_string_t video_command(int32_t, moonbit_string_t);
extern moonbit_string_t video_snapshot(int32_t);
extern moonbit_string_t video_seek(int32_t, double);
extern void video_dispose(int32_t);

@interface MCSharedCanvasView (OffscreenFixture)
- (void)drawCommands:(NSArray *)commands dirtyRect:(NSRect)dirtyRect;
@end

static moonbit_string_t Input(NSString *value) {
    moonbit_string_t result = moonbit_make_string_raw((int32_t)value.length);
    [value getCharacters:result range:NSMakeRange(0, value.length)];
    return result;
}
static NSString *JSON(id value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
                                encoding:NSUTF8StringEncoding];
}
static NSDictionary *Output(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)];
    moonbit_decref(value);
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSCAssert([result isKindOfClass:NSDictionary.class], @"JSON ABI response: %@", text);
    return result;
}
static BOOL Wait(BOOL (^condition)(void), double timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

@interface SharedVideoHarness : NSObject <NSWindowDelegate>
@property MCVideoMedia *media;
@property MCSharedCanvasView *canvas;
@property NSWindow *window;
@property NSTimer *timer;
@property NSDictionary *snapshot;
@property NSURL *exportDirectory;
@property NSURL *lastExport;
@property NSError *lastError;
@property NSError *reportedPreviewError;
@property int32_t session;
@property int32_t ui;
@property NSUInteger commands;
@property NSUInteger exports;
@property NSUInteger exportRequests;
@property BOOL closed;
@property BOOL interactive;
@property BOOL projectMode;
@property NSUInteger nextRequest;
@property BOOL exporting;
@property BOOL mediaSynchronized;
@property BOOL rejectNextPlanForTest;
@property BOOL pendingSeek;
@property BOOL clockDelivered;
@property BOOL lastClockPlaying;
@property double lastClockSource;
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)initWithURL:(NSURL *)url project:(BOOL)project error:(NSError **)error;
- (void)send:(NSDictionary *)event;
- (void)render;
- (void)tick;
- (void)close;
@end

@implementation SharedVideoHarness
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    return [self initWithURL:url project:NO error:error];
}
- (instancetype)initWithURL:(NSURL *)url project:(BOOL)project error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _projectMode = project;
    _session = -1; _ui = -1;
    _media = [[MCVideoMedia alloc] initWithURL:url error:error];
    if (!_media) return nil;
    moonbit_string_t source = Input(JSON(_media.metadata)), draft = Input(@"");
    _snapshot = Output(project ? video_project_open(source, draft) : video_open(source, draft));
    moonbit_decref(source); moonbit_decref(draft);
    if (![_snapshot[@"ok"] boolValue]) return nil;
    _session = [_snapshot[@"session"] intValue];
    if (![_media applyPlan:_snapshot[@"plan"] error:error]) return nil;
    _mediaSynchronized = YES;
    moonbit_string_t initial = Input(JSON(_snapshot));
    _ui = video_ui_open(initial); moonbit_decref(initial);
    NSAssert(_ui >= 0, @"Shared UI opens valid document");
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Mooji Cut · 共享编辑组件原型";
    _window.minSize = NSMakeSize(720, 510);
    _window.releasedWhenClosed = NO; _window.delegate = self;
    _canvas = [[MCSharedCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 1040, 720)];
    _window.contentView = _canvas;
    [_canvas setVideoPlayer:_media.player];
    __weak SharedVideoHarness *weak = self;
    _canvas.onEvent = ^(NSDictionary *event) { [weak send:event]; };
    _canvas.onFrameNeeded = ^(__unused CGSize size) { [weak render]; };
    NSAppearanceName appearance = [_canvas.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    [self send:@{@"type":@"appearance", @"mode":[appearance isEqualToString:NSAppearanceNameDarkAqua] ? @"dark" : @"light"}];
    [self render];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES
        block:^(__unused NSTimer *timer) { [weak tick]; }];
    return self;
}
- (void)render {
    if (self.closed) return;
    CGSize size = self.canvas.bounds.size;
    NSDictionary *frame = Output(video_ui_frame(self.ui, size.width, size.height));
    NSAssert([frame[@"ok"] boolValue], @"Shared UI frame: %@", frame);
    self.canvas.frameDescription = frame;
}
- (void)reportError:(NSError *)error {
    self.lastError = error;
    [self send:@{@"type":@"error", @"message":error.localizedDescription ?: @"操作失败"}];
}
- (void)seekSource:(double)source preview:(BOOL)preview {
    if (!self.mediaSynchronized) return;
    // Even a seek that resolves to the unchanged retained frame must publish
    // its canonical position back to the optimistic shared playhead.
    self.clockDelivered = NO;
    if (preview) {
        self.pendingSeek = YES;
        __weak SharedVideoHarness *weak = self;
        [self.media previewSourceMilliseconds:source completion:^(__unused BOOL finished) { weak.pendingSeek = NO; }];
    } else {
        NSDictionary *position = Output(video_seek(self.session, source));
        if ([position[@"ok"] boolValue]) {
            self.pendingSeek = YES;
            __weak SharedVideoHarness *weak = self;
            [self.media seekOutputMilliseconds:[position[@"outputMs"] doubleValue]
                completion:^(__unused BOOL finished) { weak.pendingSeek = NO; }];
        }
    }
}
- (void)seekOutput:(double)milliseconds {
    if (!self.mediaSynchronized) return;
    self.clockDelivered = NO; self.pendingSeek = YES;
    __weak SharedVideoHarness *weak = self;
    [self.media seekOutputMilliseconds:MAX(0, MIN(milliseconds, self.media.outputDurationMilliseconds-1))
        completion:^(__unused BOOL finished) { weak.pendingSeek = NO; }];
}
- (void)export {
    if (self.exporting) return;
    if (!self.mediaSynchronized) {
        [self send:@{@"type":@"exportStatus", @"busy":@NO, @"message":@"预览尚未同步，请撤销后重试。", @"error":@YES}];
        return;
    }
    NSURL *destination;
    if (self.exportDirectory) {
        destination = [self.exportDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"shared-ui-export-%lu.mp4", (unsigned long)++self.exportRequests]];
    } else {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.nameFieldStringValue = @"Mooji Cut.mp4";
        if ([panel runModal] != NSModalResponseOK) {
            [self send:@{@"type":@"exportStatus", @"busy":@NO, @"message":@"", @"error":@NO}];
            return;
        }
        destination = panel.URL;
    }
    self.exporting = YES;
    [self send:@{@"type":@"exportStatus", @"busy":@YES, @"message":@"正在保存视频…", @"error":@NO}];
    __weak SharedVideoHarness *weak = self;
    [self.media exportToURL:destination completion:^(NSURL *url, NSError *error) {
        SharedVideoHarness *self = weak;
        if (!self || self.closed) return;
        self.exporting = NO; self.lastError = error;
        if (url) { self.lastExport = url; self.exports++; }
        [self send:@{@"type":@"exportStatus", @"busy":@NO,
            @"message":error.localizedDescription ?: @"视频已保存，原片保持完整。", @"error":error ? @YES : @NO}];
    }];
}
- (void)send:(NSDictionary *)event {
    if (self.closed) return;
    moonbit_string_t input = Input(JSON(event));
    NSDictionary *result = Output(video_ui_event(self.ui, input)); moonbit_decref(input);
    NSAssert([result[@"ok"] boolValue], @"Shared UI event: %@ -> %@", event, result);
    for (NSDictionary *effect in result[@"effects"]) {
        NSString *type = effect[@"type"];
        if ([type isEqualToString:@"command"]) {
            if (self.exporting) continue;
            BOOL playing = self.media.playbackRequested;
            double sourceTime = self.projectMode ? self.media.currentOutputMilliseconds :
                self.media.previewingSource ? CMTimeGetSeconds(self.media.player.currentTime)*1000.0 :
                video_source_time(self.session, self.media.currentOutputMilliseconds);
            NSMutableDictionary *request = [effect[@"command"] mutableCopy];
            if (self.projectMode) {
                request[@"expectedRevision"] = self.snapshot[@"revision"];
                request[@"requestId"] = [NSString stringWithFormat:@"ui-%lu", (unsigned long)++self.nextRequest];
            }
            moonbit_string_t command = Input(JSON(request));
            NSDictionary *next = Output(self.projectMode ? video_project_command(self.session, command) : video_command(self.session, command)); moonbit_decref(command);
            if (![next[@"ok"] boolValue]) {
                self.lastError = [NSError errorWithDomain:@"SharedVideoCore" code:1
                    userInfo:@{NSLocalizedDescriptionKey:next[@"error"][@"message"] ?: @"编辑失败"}];
                [self send:@{@"type":@"error", @"message":next[@"error"][@"message"] ?: @"编辑失败"}];
                [self send:@{@"type":@"snapshot", @"snapshot":self.snapshot}];
                continue;
            }
            self.snapshot = next; self.commands++;
            NSError *error = nil;
            [self send:@{@"type":@"snapshot", @"snapshot":next}];
            // Fault injection exercises a real rejected media plan in smoke.
            // The document remains authoritative; never play/export old media
            // while presenting the newly committed document as synchronized.
            NSDictionary *plan = self.rejectNextPlanForTest ? @{} : next[@"plan"];
            self.rejectNextPlanForTest = NO;
            self.mediaSynchronized = [self.media applyPlan:plan error:&error];
            [self.canvas setVideoPlayer:self.mediaSynchronized ? self.media.player : nil];
            if (!self.mediaSynchronized) {
                [self.media pause]; self.lastError = error; self.pendingSeek = NO;
                [self send:@{@"type":@"mediaStatus", @"ready":@NO,
                    @"message":@"预览无法同步，已停止播放和导出。可以撤销后重试。"}];
                return;
            }
            self.lastError = nil;
            [self send:@{@"type":@"mediaStatus", @"ready":@YES, @"message":@""}];
            if (self.projectMode) [self seekOutput:sourceTime];
            else [self seekSource:MAX(0, sourceTime) preview:NO];
            if (playing) [self.media play];
        } else if ([type isEqualToString:@"seek"]) {
            [self seekSource:[effect[@"sourceMs"] doubleValue] preview:[effect[@"preview"] boolValue]];
        } else if ([type isEqualToString:@"seekOutput"]) {
            [self seekOutput:[effect[@"outputMs"] doubleValue]];
        } else if ([type isEqualToString:@"restorePreview"]) {
            if (!self.mediaSynchronized) continue;
            [self.media restorePlanPreview];
            [self seekSource:[effect[@"sourceMs"] doubleValue] preview:NO];
        } else if ([type isEqualToString:@"play"]) {
            if ([effect[@"playing"] boolValue]) [self.media play]; else [self.media pause];
            // A rejected play can leave the clock exactly where it was. Still
            // acknowledge the real state instead of retaining optimistic UI.
            self.clockDelivered = NO;
        } else if ([type isEqualToString:@"previewRate"]) {
            NSError *error = nil;
            BOOL accepted = self.mediaSynchronized &&
                [self.media setPreviewRate:[effect[@"rate"] doubleValue] error:&error];
            [self send:@{@"type":@"previewRateStatus", @"rate":@(self.media.previewRate),
                @"message":accepted ? @"" : (error.localizedDescription ?: @"预览尚未同步，暂时无法调整速度。"),
                @"error":accepted ? @NO : @YES}];
        } else if ([type isEqualToString:@"export"]) [self export];
        else NSAssert(NO, @"Unhandled effect: %@", effect);
    }
    [self render];
}
- (void)tick {
    if (self.closed || !self.mediaSynchronized) return;
    NSError *previewError = self.media.previewPlaybackError;
    if (previewError != self.reportedPreviewError) {
        self.reportedPreviewError = previewError;
        [self send:@{@"type":@"previewRateStatus", @"rate":@(self.media.previewRate),
            @"message":previewError.localizedDescription ?: @"", @"error":previewError ? @YES : @NO}];
    }
    if (self.pendingSeek) return;
    double output = self.media.currentOutputMilliseconds;
    // A trim gesture owns its preview playhead. Do not replace that position
    // with the retained output clock while the media port previews raw source.
    if (self.media.previewingSource) return;
    double source = self.projectMode ? output : video_source_time(self.session, output);
    BOOL playing = self.media.playbackRequested;
    if (self.clockDelivered && self.lastClockPlaying == playing && fabs(self.lastClockSource-source) < 0.5) return;
    self.clockDelivered = YES; self.lastClockPlaying = playing; self.lastClockSource = source;
    [self send:@{@"type":@"playback", self.projectMode ? @"outputMs" : @"sourceMs":@(MAX(0, source)), @"playing":playing ? @YES : @NO}];
}
- (void)close {
    if (self.closed) return;
    [self send:@{@"type":@"cancel"}];
    self.closed = YES;
    [self.timer invalidate]; self.timer = nil;
    self.canvas.onEvent = nil; self.canvas.onFrameNeeded = nil;
    [self.canvas setVideoPlayer:nil]; [self.media close];
    video_ui_close(self.ui);
    if (self.projectMode) video_project_close(self.session); else video_dispose(self.session);
    self.ui = -1; self.session = -1;
}
- (void)windowWillClose:(__unused NSNotification *)notification {
    [self close];
    if (self.interactive) [NSApp stop:nil];
}
- (void)dealloc {
    [_timer invalidate];
    [_media close];
    if (_ui >= 0) video_ui_close(_ui);
    if (_session >= 0) { if (_projectMode) video_project_close(_session); else video_dispose(_session); }
}
@end

static NSDictionary *Semantic(SharedVideoHarness *host, NSString *identifier) {
    for (NSDictionary *item in host.canvas.frameDescription[@"semantics"])
        if ([item[@"id"] isEqualToString:identifier]) return item;
    NSCAssert(NO, @"Missing shared semantic: %@", identifier); return nil;
}
static NSPoint Center(NSDictionary *item) {
    return NSMakePoint([item[@"x"] doubleValue]+[item[@"width"] doubleValue]/2,
                      [item[@"y"] doubleValue]+[item[@"height"] doubleValue]/2);
}
static void Mouse(SharedVideoHarness *host, NSEventType type, NSPoint point) {
    NSPoint location = [host.canvas convertPoint:point toView:nil];
    NSEvent *event = [NSEvent mouseEventWithType:type location:location modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:host.window.windowNumber context:nil
        eventNumber:1 clickCount:1 pressure:1];
    if (type == NSEventTypeLeftMouseDown) [host.canvas mouseDown:event];
    else if (type == NSEventTypeLeftMouseDragged) [host.canvas mouseDragged:event];
    else [host.canvas mouseUp:event];
}
static void Key(SharedVideoHarness *host, NSString *characters, unsigned short keyCode) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:host.window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
    [host.canvas keyDown:event];
}
static void Click(SharedVideoHarness *host, NSString *identifier) {
    NSPoint point = Center(Semantic(host, identifier));
    Mouse(host, NSEventTypeLeftMouseDown, point);
    Mouse(host, NSEventTypeLeftMouseUp, point);
}
static double TrimStart(SharedVideoHarness *host) {
    return [host.snapshot[@"document"][@"trim"][@"startMs"] doubleValue];
}
static void SaveLayout(SharedVideoHarness *host, NSURL *url) {
    // This artifact is a native offscreen layout with an actual decoded video
    // frame, not a screen capture or evidence of on-screen compositor behavior.
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:host.media.player.currentItem.asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.videoComposition = host.media.player.currentItem.videoComposition;
    __block CGImageRef image = NULL;
    __block BOOL decoded = NO;
    [generator generateCGImageAsynchronouslyForTime:host.media.player.currentTime
        completionHandler:^(CGImageRef frame, __unused CMTime actualTime, __unused NSError *error) {
            CGImageRef retained = frame ? CGImageRetain(frame) : NULL;
            dispatch_async(dispatch_get_main_queue(), ^{ image = retained; decoded = YES; });
        }];
    NSCAssert(Wait(^BOOL { return decoded; }, 10) && image, @"Decode real preview frame");
    CGSize size = host.canvas.bounds.size;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)size.width pixelsHigh:(NSInteger)size.height bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [host.canvas cacheDisplayInRect:host.canvas.bounds toBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    if (image) {
        NSDictionary *r = host.canvas.frameDescription[@"videoRect"];
        NSRect rect = NSMakeRect([r[@"x"] doubleValue], size.height-[r[@"y"] doubleValue]-[r[@"height"] doubleValue], [r[@"width"] doubleValue], [r[@"height"] doubleValue]);
        NSImage *frame = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
        [frame drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
        CGImageRelease(image);
    }
    // Reapply the shared overlay above the decoded image, matching the real
    // sibling overlay view above the AVPlayerLayer in the running component.
    NSAffineTransform *flipped=[NSAffineTransform transform];
    [flipped translateXBy:0 yBy:size.height]; [flipped scaleXBy:1 yBy:-1]; [flipped concat];
    [host.canvas drawCommands:host.canvas.frameDescription[@"overlayCommands"] dirtyRect:host.canvas.bounds];
    [NSGraphicsContext restoreGraphicsState];
    NSCAssert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:url atomically:YES], @"Layout PNG");
}

static void Smoke(SharedVideoHarness *host, NSURL *directory) {
    host.exportDirectory = directory;
    host.media.player.muted = YES;
    [host.window orderBack:nil];
    [host.window makeFirstResponder:host.canvas];
    NSCAssert(Wait(^BOOL { return host.media.player.currentItem.status == AVPlayerItemStatusReadyToPlay; }, 10), @"Player loads real media");
    NSPoint left = Center(Semantic(host, @"trim-start")), right = Center(Semantic(host, @"trim-end"));
    NSPoint quarter = NSMakePoint(left.x + (right.x-left.x)/4, left.y);
    Mouse(host, NSEventTypeLeftMouseDown, left); Mouse(host, NSEventTypeLeftMouseDragged, quarter);
    NSCAssert(TrimStart(host) == 0 && host.commands == 0, @"Drag previews without editing the document");
    NSCAssert(host.media.previewingSource, @"Trim preview uses original media");
    Key(host, @"\x1b", 53);
    NSCAssert(TrimStart(host) == 0 && host.commands == 0 && !host.media.previewingSource, @"Escape rolls preview back without history");
    Mouse(host, NSEventTypeLeftMouseDown, left); Mouse(host, NSEventTypeLeftMouseDragged, quarter);
    Mouse(host, NSEventTypeLeftMouseUp, quarter);
    NSCAssert(fabs(TrimStart(host)-1000) < 80 && host.commands == 1, @"One drag produces one core trim: %@", host.snapshot);
    [host send:@{@"type":@"activate", @"id":@"undo"}];
    NSCAssert(TrimStart(host) == 0, @"Shared undo reaches core");
    [host send:@{@"type":@"activate", @"id":@"redo"}];
    NSCAssert(fabs(TrimStart(host)-1000) < 80, @"Shared redo reaches core");
    // Re-expand past the committed start: preview must be able to show frames
    // no longer present in the current output composition.
    left = Center(Semantic(host, @"trim-start"));
    NSPoint earlier = NSMakePoint(left.x-(right.x-left.x)/6, left.y);
    Mouse(host, NSEventTypeLeftMouseDown, left); Mouse(host, NSEventTypeLeftMouseDragged, earlier);
    NSCAssert(Wait(^BOOL { return host.media.previewingSource && CMTimeGetSeconds(host.media.player.currentTime)*1000 < 900; }, 10), @"Expanded trim previews excluded source frames");
    Key(host, @"\x1b", 53);
    NSCAssert(fabs(TrimStart(host)-1000) < 80 && host.commands == 3, @"Expanded trim cancel preserves document");
    NSCAssert(Wait(^BOOL { return !host.pendingSeek && host.media.player.currentItem.status == AVPlayerItemStatusReadyToPlay; }, 10), @"Restored media is ready for transport");
    NSDictionary *beforePreviewRate = host.snapshot;
    NSUInteger beforePreviewCommands = host.commands;
    Click(host, @"preview-rate"); Click(host, @"rate-2");
    NSCAssert(host.media.previewRate == 2 && host.media.player.rate == 0,
              @"Changing preview speed while paused does not start playback");
    Click(host, @"preview-rate"); Key(host, @"\uf700", 126); Key(host, @"\r", 36);
    NSCAssert(host.media.previewRate == 1.5 && host.media.player.rate == 0,
              @"Native arrow/enter input selects a shared menu item");
    Click(host, @"preview-rate"); Key(host, @"\uf701", 125); Key(host, @"\r", 36);
    NSCAssert(host.media.previewRate == 2, @"Keyboard menu can return to two-times preview");
    NSCAssert([host.snapshot isEqual:beforePreviewRate] && host.commands == beforePreviewCommands,
              @"Preview speed changes neither document nor undo history");
    Click(host, @"start");
    NSCAssert(Wait(^BOOL { return !host.pendingSeek; }, 10), @"Transport starts at retained media");
    [host tick];
    double jump = MIN(host.media.outputDurationMilliseconds * 0.01, 5000);
    Click(host, @"forward");
    NSCAssert(Wait(^BOOL { return !host.pendingSeek; }, 10) && fabs(host.media.currentOutputMilliseconds-jump) < 8,
              @"Forward uses one percent of output duration, capped at five seconds");
    [host tick]; Click(host, @"backward");
    NSCAssert(Wait(^BOOL { return !host.pendingSeek; }, 10) && host.media.currentOutputMilliseconds < 8, @"Backward uses the same dynamic step");
    NSCAssert(host.media.player.rate == 0 && host.commands == beforePreviewCommands,
              @"Transport buttons seek without document edits");
    [host tick];
    NSDictionary *playhead = Semantic(host, @"playhead");
    NSPoint excludedSource = NSMakePoint([playhead[@"x"] doubleValue]+1, [playhead[@"y"] doubleValue]+5);
    Mouse(host, NSEventTypeLeftMouseDown, excludedSource); Mouse(host, NSEventTypeLeftMouseUp, excludedSource);
    NSCAssert(Wait(^BOOL { return !host.pendingSeek; }, 10), @"Seek before trim resolves to the same retained frame");
    [host tick];
    NSCAssert(fabs([Semantic(host, @"playhead")[@"value"] doubleValue]-TrimStart(host)) < 40,
              @"Unchanged media clock still corrects a playhead in excluded source time");
    [host send:@{@"type":@"activate", @"id":@"play"}];
    NSCAssert(Wait(^BOOL { return host.media.currentOutputMilliseconds > 180; }, 10), @"Actual AVPlayer clock advances");
    NSCAssert(host.media.player.rate == 2, @"Shared preview rate reaches actual playback");
    [host send:@{@"type":@"activate", @"id":@"play"}]; [host tick];
    NSCAssert(host.media.player.rate == 0, @"Shared transport pauses actual player");
    [host send:@{@"type":@"key", @"key":@"End", @"mod":@NO, @"shift":@NO}];
    NSCAssert(Wait(^BOOL { return host.media.currentOutputMilliseconds >= host.media.outputDurationMilliseconds-40; }, 10), @"Seek to final output frame");
    [host tick];
    [host send:@{@"type":@"activate", @"id":@"play"}];
    NSCAssert(Wait(^BOOL { return host.media.player.rate > 0 && host.media.currentOutputMilliseconds < 500; }, 10), @"Play at the end restarts retained media");
    [host send:@{@"type":@"activate", @"id":@"play"}]; [host tick];
    NSCAssert(Wait(^BOOL { return !host.pendingSeek; }, 10), @"Replay seek settles before testing playback rejection");
    // Remove only this fixture's player item to produce a real backend play
    // rejection. The document remains valid and the old clock stays paused.
    [host.media.player replaceCurrentItemWithPlayerItem:nil]; [host tick];
    [host send:@{@"type":@"activate", @"id":@"play"}]; [host tick];
    NSCAssert(host.media.previewPlaybackError && !host.media.playbackRequested &&
              [Semantic(host, @"play")[@"label"] containsString:@"播放"],
              @"Rejected play corrects optimistic UI even at an unchanged paused clock: %@ / %@",
              host.media.previewPlaybackError, Semantic(host, @"play"));
    NSError *restoreError = nil;
    NSCAssert([host.media applyPlan:host.snapshot[@"plan"] error:&restoreError] && !restoreError,
              @"Restore fixture media after the transport failure");
    NSCAssert(Wait(^BOOL { return host.media.player.currentItem.status == AVPlayerItemStatusReadyToPlay; }, 10), @"Restored fixture becomes ready");
    NSCAssert([host.media setPreviewRate:2 error:&restoreError], @"A supported preview rate clears the failure");
    [host tick];
    [host send:@{@"type":@"appearance", @"mode":@"dark"}];
    SaveLayout(host, [directory URLByAppendingPathComponent:@"shared-editor.png"]);
    Click(host, @"preview-rate");
    SaveLayout(host, [directory URLByAppendingPathComponent:@"shared-editor-speed-menu.png"]);
    Key(host, @"\x1b", 53);
    [host send:@{@"type":@"appearance", @"mode":@"light"}];
    SaveLayout(host, [directory URLByAppendingPathComponent:@"shared-editor-light.png"]);
    [host send:@{@"type":@"appearance", @"mode":@"dark"}];
    [host.window setContentSize:NSMakeSize(720, 480)]; [host render];
    SaveLayout(host, [directory URLByAppendingPathComponent:@"shared-editor-compact.png"]);
    [host.window setContentSize:NSMakeSize(1040, 720)]; [host render];
    [host send:@{@"type":@"activate", @"id":@"export"}];
    NSCAssert(Wait(^BOOL { return !host.exporting; }, 30) && host.exports == 1 && !host.lastError, @"Actual export: %@", host.lastError);
    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:host.lastExport options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    NSCAssert(fabs(CMTimeGetSeconds(exported.duration)*1000-[host.snapshot[@"plan"][@"outputDurationMs"] doubleValue]) < 40,
              @"Preview speed does not retime the saved video");
    double beforeFailedSync = TrimStart(host);
    host.rejectNextPlanForTest = YES;
    [host send:@{@"type":@"activate", @"id":@"trim-start"}];
    [host send:@{@"type":@"key", @"key":@"ArrowRight", @"mod":@NO, @"shift":@NO}];
    NSCAssert(!host.mediaSynchronized && TrimStart(host) > beforeFailedSync && host.media.player.rate == 0,
              @"A failed media sync keeps the committed document but stops stale preview");
    NSCAssert(![Semantic(host,@"export")[@"enabled"] boolValue] && ![Semantic(host,@"play")[@"enabled"] boolValue], @"Stale plan cannot play or export");
    [host send:@{@"type":@"activate", @"id":@"undo"}];
    NSCAssert(host.mediaSynchronized && TrimStart(host) == beforeFailedSync && [Semantic(host,@"export")[@"enabled"] boolValue], @"Undo resynchronizes actual media and document");
    NSDictionary *report = @{@"ok":@YES, @"sharedComponent":@"MoonBit video_ui", @"platform":@"macOS",
        @"dragPreviewNoHistory":@YES, @"cancelRestores":@YES, @"oneCommitPerDrag":@YES,
        @"undoRedo":@YES, @"expandTrimPreview":@YES, @"actualPlayback":@YES, @"replayAtEnd":@YES, @"actualExport":@YES, @"mediaSyncFailureRecovery":@YES,
        @"transportButtons":@YES, @"previewRate":@YES, @"previewRatePreservesDocumentAndExport":@YES, @"rejectedPlayResetsUI":@YES, @"unchangedSeekCorrectsUI":@YES,
        @"layoutArtifact":@"NSView drawing plus actual decoded video frame; not a screen capture",
        @"windowsInteractive":@"not tested", @"linuxInteractive":@"not tested"};
    [JSON(report) writeToURL:[directory URLByAppendingPathComponent:@"shared-ui-report.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [host close]; [host.window orderOut:nil];
    NSCAssert(host.media.player.currentItem == nil, @"Closing releases player item");
    puts("Shared MoonBit UI + native input + real media: passed");
}

static NSArray<NSDictionary *> *ProjectClips(SharedVideoHarness *host, NSString *kind) {
    NSMutableArray *clips = [NSMutableArray array];
    for (NSDictionary *clip in host.snapshot[@"document"][@"clips"])
        if ([clip[@"kind"] isEqual:kind]) [clips addObject:clip];
    return [clips sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"startTicks"] compare:b[@"startTicks"]];
    }];
}
static void ProjectSettle(SharedVideoHarness *host) {
    NSCAssert(Wait(^BOOL { return !host.pendingSeek && host.media.player.currentItem.status == AVPlayerItemStatusReadyToPlay; }, 10),
              @"Project media is synchronized: %@", host.lastError);
    [host tick];
}
static void SelectClip(SharedVideoHarness *host, NSString *identifier) {
    [host send:@{@"type":@"activate", @"id":[@"clip:" stringByAppendingString:identifier]}];
}
static void ProjectSmoke(SharedVideoHarness *host, NSURL *directory) {
    host.exportDirectory = directory; host.media.player.muted = YES;
    [host.window orderBack:nil]; [host.window makeFirstResponder:host.canvas];
    ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count == 1 && ProjectClips(host,@"audio").count == 1, @"A source opens as linked video and audio clips");
    Click(host,@"project-speed");
    NSDictionary *slow=Semantic(host,@"clip-rate-0.5");
    NSString *slowTip=[(id<NSViewToolTipOwner>)host.canvas view:host.canvas stringForToolTip:0 point:Center(slow) userData:NULL];
    NSCAssert(![slow[@"enabled"] boolValue] && [slowTip containsString:@"有声慢放暂不支持"],
              @"Disabled speed choice retains a discoverable explanation above underlying controls");
    NSDictionary *speedMenu=Semantic(host,@"project-speed-menu");
    NSPoint menuPadding=NSMakePoint([speedMenu[@"x"] doubleValue]+2,[speedMenu[@"y"] doubleValue]+2);
    NSString *menuTip=[(id<NSViewToolTipOwner>)host.canvas view:host.canvas stringForToolTip:0 point:menuPadding userData:NULL];
    NSCAssert([menuTip containsString:@"片段"] && [menuTip containsString:@"速度"],
              @"Menu padding occludes unrelated tooltips underneath it");
    BOOL foundDisabled=NO;
    for (id element in host.canvas.accessibilityChildren) {
        if ([[element accessibilityIdentifier] isEqualToString:@"clip-rate-0.5"]) {
            foundDisabled=YES;
            NSCAssert([[element accessibilityHelp] containsString:@"有声慢放暂不支持"] && ![element accessibilityPerformPress],
                      @"Icon accessibility exposes the disabled reason and cannot activate it");
        }
    }
    NSCAssert(foundDisabled,@"Disabled menu actions remain in the native accessibility tree");
    Key(host,@"\x1b",53);
    NSString *first = ProjectClips(host,@"video")[0][@"id"];
    SelectClip(host,first); [host seekOutput:1000]; ProjectSettle(host);
    Click(host,@"project-split"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count == 2 && ProjectClips(host,@"audio").count == 2, @"Split edits both linked streams");
    NSString *second = ProjectClips(host,@"video")[1][@"id"];
    SelectClip(host,second); [host seekOutput:2000]; ProjectSettle(host);
    Click(host,@"project-split"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count == 3, @"UI splits source into three clips");
    NSString *third = ProjectClips(host,@"video")[2][@"id"];
    SelectClip(host,third); Click(host,@"project-move-earlier"); ProjectSettle(host);
    NSCAssert([ProjectClips(host,@"video")[1][@"id"] isEqual:third], @"UI reorders actual clips");
    Click(host,@"project-speed"); Click(host,@"clip-rate-3"); ProjectSettle(host);
    NSDictionary *fast = ProjectClips(host,@"video")[1];
    NSCAssert([fast[@"sourceEndTicks"] longLongValue]-[fast[@"sourceStartTicks"] longLongValue] == 3*[fast[@"durationTicks"] longLongValue], @"Three-times clip speed changes the authoritative duration");
    double editedDuration = host.media.outputDurationMilliseconds;
    NSCAssert(fabs(editedDuration-8000.0/3.0)<1, @"Two original seconds now occupy two thirds of a second");
    SelectClip(host,second); Click(host,@"project-remove"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count==2 && host.media.outputDurationMilliseconds < editedDuration,
              @"Removing the last clip shortens actual output: %@ / %@ / %f",host.lastError,host.snapshot,host.media.outputDurationMilliseconds);
    Click(host,@"undo"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count==3 && fabs(host.media.outputDurationMilliseconds-editedDuration)<1, @"Undo restores clips, links and duration together");
    SelectClip(host,third);
    NSPoint trimLeft=Center(Semantic(host,@"project-trim-start")), trimRight=Center(Semantic(host,@"project-trim-end"));
    NSPoint shorter=NSMakePoint(trimRight.x-(trimRight.x-trimLeft.x)/10,trimRight.y);
    NSUInteger beforeTrim=host.commands;
    Mouse(host,NSEventTypeLeftMouseDown,trimRight); Mouse(host,NSEventTypeLeftMouseDragged,shorter);
    NSCAssert(host.commands==beforeTrim,@"Clip trim gesture previews without committing");
    Key(host,@"\x1b",53);
    NSCAssert(host.commands==beforeTrim && fabs(host.media.outputDurationMilliseconds-editedDuration)<1,@"Escape cancels a multi-clip trim");
    Mouse(host,NSEventTypeLeftMouseDown,trimRight); Mouse(host,NSEventTypeLeftMouseDragged,shorter); Mouse(host,NSEventTypeLeftMouseUp,shorter);
    ProjectSettle(host);
    NSCAssert(host.commands==beforeTrim+1 && host.media.outputDurationMilliseconds<editedDuration,@"One trim release edits linked media once");
    Click(host,@"undo"); ProjectSettle(host);
    NSCAssert(fabs(host.media.outputDurationMilliseconds-editedDuration)<1,@"Undo restores retimed clip trim");
    NSUInteger beforeView=host.commands;
    NSDictionary *beforeViewDocument=host.snapshot[@"document"];
    Click(host,@"project-zoom-in");
    NSDictionary *viewport=host.canvas.frameDescription[@"viewport"];
    NSCAssert([viewport[@"spanMs"] doubleValue]>0 && [viewport[@"spanMs"] doubleValue]<editedDuration,
              @"Timeline zoom changes the visible time granularity");
    NSPoint timelinePoint=Center(Semantic(host,[@"clip:" stringByAppendingString:third]));
    double startBeforePan=[viewport[@"startMs"] doubleValue];
    [host send:@{@"type":@"scroll",@"x":@(timelinePoint.x),@"y":@(timelinePoint.y),
                 @"deltaX":@(-80),@"deltaY":@0,@"precise":@YES,@"mod":@NO,@"shift":@NO}];
    viewport=host.canvas.frameDescription[@"viewport"];
    NSCAssert([viewport[@"startMs"] doubleValue]>startBeforePan,@"Timeline scroll pans to later content");
    NSCAssert(host.commands==beforeView && [host.snapshot[@"document"] isEqual:beforeViewDocument],
              @"Zoom and pan do not edit the document or its undo history");
    [host send:@{@"type":@"appearance",@"mode":@"dark"}];
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor-zoom.png"]);
    Click(host,@"project-zoom-fit");
    NSCAssert(fabs([host.canvas.frameDescription[@"viewport"][@"spanMs"] doubleValue]-editedDuration)<1,
              @"Fit restores the whole output timeline");
    SelectClip(host,third); Click(host,@"project-remove"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count==2 && fabs(host.media.outputDurationMilliseconds-editedDuration)<1,
              @"Ordinary deletion leaves the middle gap without moving later clips");
    NSUInteger beforeGap=host.commands;
    Click(host,@"gap:90000:150000");
    NSCAssert(host.commands==beforeGap,@"Selecting a gap is transient UI state");
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor-gap.png"]);
    Key(host,@"\uf728",117); ProjectSettle(host);
    NSCAssert(host.commands==beforeGap+1 && fabs(host.media.outputDurationMilliseconds-2000)<1,
              @"Delete on the selected gap closes linked media in one edit: %@",host.lastError);
    NSCAssert([ProjectClips(host,@"video")[1][@"startTicks"] longLongValue]==90000 &&
              [ProjectClips(host,@"audio")[1][@"startTicks"] longLongValue]==90000,
              @"Closing a video gap moves its linked audio by the same amount");
    Click(host,@"undo"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count==2 && fabs(host.media.outputDurationMilliseconds-editedDuration)<1,
              @"One undo restores the gap");
    Click(host,@"undo"); ProjectSettle(host);
    NSCAssert(ProjectClips(host,@"video").count==3 && fabs(host.media.outputDurationMilliseconds-editedDuration)<1,
              @"A second undo restores the deleted linked clip");
    SelectClip(host,third);
    Click(host,@"project-audio-toggle");
    NSString *group = nil, *audioID = nil;
    for (NSDictionary *clip in ProjectClips(host,@"video")) if ([clip[@"id"] isEqual:third]) group=clip[@"linkGroup"];
    for (NSDictionary *clip in ProjectClips(host,@"audio")) if ([clip[@"linkGroup"] isEqual:group]) audioID=clip[@"id"];
    NSCAssert(audioID, @"The selected video has one independent linked audio instance");
    Click(host,@"project-unlink"); ProjectSettle(host);
    SelectClip(host,audioID);
    double oldAudioStart = 0;
    for (NSDictionary *clip in ProjectClips(host,@"audio")) if ([clip[@"id"] isEqual:audioID]) oldAudioStart=[clip[@"startTicks"] doubleValue];
    Click(host,@"project-offset-later"); ProjectSettle(host);
    BOOL offset = NO;
    for (NSDictionary *clip in ProjectClips(host,@"audio")) if ([clip[@"id"] isEqual:audioID]) {
        offset=[clip[@"startTicks"] doubleValue]>oldAudioStart && clip[@"linkGroup"]==NSNull.null;
    }
    NSCAssert(offset && ProjectClips(host,@"audio").count==3, @"Unlinked audio moves independently without duplicating sound");
    SelectClip(host,third); [host seekOutput:1200]; ProjectSettle(host);
    NSUInteger beforeCrop=host.commands;
    Click(host,@"project-crop");
    NSDictionary *surface=Semantic(host,@"project-crop-region");
    double vx=[surface[@"x"] doubleValue],vy=[surface[@"y"] doubleValue];
    double vw=[surface[@"width"] doubleValue],vh=[surface[@"height"] doubleValue];
    NSPoint cropA=NSMakePoint(vx+vw*0.1,vy+vh*0.2),cropB=NSMakePoint(vx+vw*0.9,vy+vh*0.8);
    Mouse(host,NSEventTypeLeftMouseDown,cropA); Mouse(host,NSEventTypeLeftMouseDragged,cropB); Mouse(host,NSEventTypeLeftMouseUp,cropB);
    NSCAssert(host.commands==beforeCrop && [host.canvas.frameDescription[@"overlayCommands"] count]>0,
              @"Crop selection draws above video without changing the document");
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor-crop-preview.png"]);
    Key(host,@"\x1b",53);
    NSCAssert(host.commands==beforeCrop && host.snapshot[@"document"][@"crop"]==NSNull.null,@"Cancel discards a tentative crop");
    Click(host,@"project-crop");
    Mouse(host,NSEventTypeLeftMouseDown,cropA); Mouse(host,NSEventTypeLeftMouseDragged,cropB); Mouse(host,NSEventTypeLeftMouseUp,cropB);
    Click(host,@"project-crop-apply"); ProjectSettle(host);
    NSDictionary *crop=host.snapshot[@"document"][@"crop"];
    NSCAssert([crop[@"width"] integerValue]==256 && [crop[@"height"] integerValue]==144,
              @"Shared crop coordinates map to normalized source pixels: %@",crop);
    Click(host,@"project-mute"); ProjectSettle(host);
    NSCAssert([host.snapshot[@"document"][@"muted"] boolValue],@"Global mute commits through the shared project");
    Click(host,@"export");
    NSCAssert(Wait(^BOOL{return !host.exporting;},30) && host.exports==1 && !host.lastError,@"Cropped muted project exports");
    AVURLAsset *cropExport=[AVURLAsset URLAssetWithURL:host.lastExport options:nil];
    NSUInteger audioCount=0; AVAssetTrack *croppedTrack=nil;
    for (AVAssetTrack *track in cropExport.tracks) {
        if ([track.mediaType isEqual:AVMediaTypeVideo]) croppedTrack=track;
        if ([track.mediaType isEqual:AVMediaTypeAudio]) audioCount++;
    }
    NSCAssert(CGSizeEqualToSize(croppedTrack.naturalSize,CGSizeMake(256,144)) && audioCount==0,
              @"Actual file preserves crop geometry and global mute");
    Click(host,@"undo"); ProjectSettle(host); Click(host,@"undo"); ProjectSettle(host);
    NSCAssert(host.snapshot[@"document"][@"crop"]==NSNull.null && ![host.snapshot[@"document"][@"muted"] boolValue],
              @"Undo restores full picture and linked/independent sound");
    [host send:@{@"type":@"appearance", @"mode":@"dark"}];
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor.png"]);
    [host send:@{@"type":@"appearance", @"mode":@"light"}];
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor-light.png"]);
    [host send:@{@"type":@"appearance", @"mode":@"dark"}];
    [host.window setContentSize:NSMakeSize(720,480)]; [host render];
    SaveLayout(host,[directory URLByAppendingPathComponent:@"project-editor-compact.png"]);
    [host.window setContentSize:NSMakeSize(1040,720)]; [host render];
    Click(host,@"preview-rate"); Click(host,@"rate-2");
    Click(host,@"export");
    NSCAssert(Wait(^BOOL { return !host.exporting; },30) && host.exports==2 && !host.lastError,@"Project output exports: %@",host.lastError);
    AVURLAsset *saved=[AVURLAsset URLAssetWithURL:host.lastExport options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    NSCAssert(fabs(CMTimeGetSeconds(saved.duration)*1000-editedDuration)<40,@"Real file uses clip speed and ignores preview speed");
    NSURL *draftURL=[directory URLByAppendingPathComponent:@"project.json"];
    NSCAssert([JSON(host.snapshot[@"document"]) writeToURL:draftURL atomically:YES encoding:NSUTF8StringEncoding error:nil],@"Save the actual project document");
    moonbit_string_t source=Input(JSON(host.snapshot[@"document"][@"source"])), draft=Input([NSString stringWithContentsOfURL:draftURL encoding:NSUTF8StringEncoding error:nil]);
    NSDictionary *reopened=Output(video_project_open(source,draft)); moonbit_decref(source);moonbit_decref(draft);
    NSCAssert([reopened[@"ok"] boolValue] && [reopened[@"plan"] isEqual:host.snapshot[@"plan"]],@"Save/reopen preserves the same media plan");
    video_project_close([reopened[@"session"] intValue]);
    NSDictionary *report=@{@"ok":@YES,@"split":@YES,@"reorder":@YES,@"linkedAudio":@YES,@"clipSpeed":@YES,
        @"removeUndo":@YES,@"trimCancelCommitUndo":@YES,@"timelineZoomPan":@YES,@"gapSelectRemoveUndo":@YES,
        @"unlinkOffset":@YES,@"saveReopen":@YES,@"actualExport":@YES,@"disabledIconHelp":@YES,@"cropMuteExportUndo":@YES,
        @"outputDurationMs":@(CMTimeGetSeconds(saved.duration)*1000),@"previewRateDoesNotChangeExport":@YES,
        @"scope":@"Single source; shared MoonBit UI with macOS media adapter; not production integration"};
    [JSON(report) writeToURL:[directory URLByAppendingPathComponent:@"project-ui-report.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [host close];[host.window orderOut:nil];
    puts("Shared multi-clip UI + actual reordered/retimed media: passed");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *sourcePath = argc >= 3 ? @(argv[1]) : [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutFixturePath"];
        NSString *outputPath = argc >= 3 ? @(argv[2]) : [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutOutputPath"];
        if (!sourcePath.length || !outputPath.length) { fprintf(stderr, "usage: shared-video-ui SOURCE.mp4 OUTPUT_DIR [--interactive]\n"); return 2; }
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        moonbit_init();
        NSURL *source = [NSURL fileURLWithPath:sourcePath], *directory = [NSURL fileURLWithPath:outputPath isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) { NSLog(@"%@", error); return 1; }
        BOOL project = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutProjectMode"] boolValue];
        BOOL interactive = argc < 3;
        for (int i=3; i<argc; i++) {
            if (strcmp(argv[i],"--project")==0) project=YES;
            if (strcmp(argv[i],"--interactive")==0) interactive=YES;
        }
        SharedVideoHarness *host = [[SharedVideoHarness alloc] initWithURL:source project:project error:&error];
        if (!host) { NSLog(@"Unable to load fixture: %@", error); return 1; }
        if (interactive) {
            host.interactive = YES; [host.window center]; [host.window makeKeyAndOrderFront:nil];
            [host.window makeFirstResponder:host.canvas]; [NSApp activateIgnoringOtherApps:YES]; [NSApp run];
        } else if (project) ProjectSmoke(host,directory);
        else Smoke(host, directory);
        [host close];
    }
    return 0;
}
