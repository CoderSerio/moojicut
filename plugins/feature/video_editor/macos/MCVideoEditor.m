#import "MCVideoEditor.h"
#import "MCVideoMedia.h"
#import "components/media_analysis/macos/MCAudioWaveform.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "bindings/c/video_project.h"
#include "bindings/c/video_editor.h"
#include "bindings/c/video_media_plan.h"
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


// The root owns every product state. These fields own only OS resources and
// callbacks; state/draftDirty/mediaSynchronized are read-only root projections.
@interface MCVideoEditor ()
@property NSURL *directory;
@property MCVideoMedia *media;
@property MCAudioWaveform *waveformTask;
@property MCSharedCanvasView *canvas;
@property NSWindow *window;
@property NSTimer *timer;
@property int32_t editor, chooserTicket, exportTicket, closeTicket;
@property int32_t appliedGeneration;
@property NSDictionary *initialState, *executionPlan;
@property NSString *initialDraft;
@property BOOL initialUnsaved, closed, pumping, refreshAgain, lastNotifiedBusy;
@property BOOL clockDelivered, lastClockPlaying, mediaDrained, waveformDrained;
@property double lastClockOutput;
@property NSMutableSet<NSNumber *> *seekTickets;
@property NSError *lastError, *reportedPreviewError;
@property NSURL *directExportURL;
@property NSSavePanel *savePanel;
@property BOOL panelPresented;
@property (copy) void (^panelCompletion)(NSURL *);
@property (copy) void (^afterChooser)(void);
@property BOOL copyExport, suppressPresentationCompletion;
@property (copy) void (^exportCompletion)(NSURL *, NSError *);
@property (copy) void (^terminationCompletion)(NSError *);
@property MCVideoEditor *lifetime;
- (void)sendUIEvent:(NSDictionary *)event;
- (void)render;
- (void)tick;
- (void)buildWindow;
- (void)pump;
- (BOOL)saveDraft:(NSError **)error;
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error;
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion;
- (void)cancelExportKeepingDraft;
- (BOOL)confirmCancelExport;
@end

// Copy a borrowed immutable effect plan before ACK releases it. The temporary
// dictionary is an AVFoundation transport, never an editable project model.
static NSDictionary *MCExecutionPlan(int32_t handle, NSDictionary *metadata) {
    if (handle <= 0 || video_media_plan_value(handle,MC_MEDIA_PLAN_WIDTH)!=[metadata[@"width"] intValue] ||
        video_media_plan_value(handle,MC_MEDIA_PLAN_HEIGHT)!=[metadata[@"height"] intValue] ||
        video_media_plan_number(handle,MC_MEDIA_PLAN_SOURCE_DURATION_MS)!=[metadata[@"durationMs"] doubleValue]) return nil;
    NSMutableArray *streams[2] = {[NSMutableArray array],[NSMutableArray array]};
    for (int kind=0;kind<2;kind++) {
        int count=video_media_plan_value(handle,kind ? MC_MEDIA_PLAN_AUDIO_COUNT : MC_MEDIA_PLAN_VIDEO_COUNT);
        if (count<0 || count>256) return nil;
        for (int i=0;i<count;i++) [streams[kind] addObject:@{
            @"id":[NSString stringWithFormat:@"port-%d-%d",kind,i],@"kind":kind ? @"audio":@"video",@"linkGroup":NSNull.null,
            @"startTicks":@(video_media_plan_clip_number(handle,kind,i,MC_MEDIA_CLIP_START_TICKS)),
            @"sourceStartTicks":@(video_media_plan_clip_number(handle,kind,i,MC_MEDIA_CLIP_SOURCE_START_TICKS)),
            @"sourceEndTicks":@(video_media_plan_clip_number(handle,kind,i,MC_MEDIA_CLIP_SOURCE_END_TICKS)),
            @"durationTicks":@(video_media_plan_clip_number(handle,kind,i,MC_MEDIA_CLIP_DURATION_TICKS))}];
    }
    return @{@"schemaVersion":@2,@"timebase":@90000,@"frameRate":@{@"num":@30,@"den":@1},@"source":metadata,
        @"video":streams[0],@"audio":streams[1],@"muted":@(video_media_plan_value(handle,MC_MEDIA_PLAN_MUTED)==1),
        @"outputDurationTicks":@(video_media_plan_number(handle,MC_MEDIA_PLAN_DURATION_TICKS)),
        @"crop":@{@"x":@(video_media_plan_number(handle,MC_MEDIA_PLAN_CROP_X)),@"y":@(video_media_plan_number(handle,MC_MEDIA_PLAN_CROP_Y)),
            @"width":@(video_media_plan_number(handle,MC_MEDIA_PLAN_CROP_WIDTH)),@"height":@(video_media_plan_number(handle,MC_MEDIA_PLAN_CROP_HEIGHT))}};
}
static NSString *MCVideoText(moonbit_string_t value) {
    NSString *text=[[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value); return text;
}
@implementation MCVideoEditor
- (NSDictionary *)state { return self.editor ? MCVideoDecode(video_editor_state(self.editor)) : self.initialState; }
- (BOOL)draftDirty { return self.editor ? video_editor_value(self.editor,MC_EDITOR_DIRTY)==1 : self.initialUnsaved; }
- (BOOL)mediaSynchronized { return self.editor && video_editor_value(self.editor,MC_EDITOR_MEDIA_READY)==1; }
- (BOOL)pendingSeek { return self.seekTickets.count!=0; }
- (BOOL)exporting { return self.editor && video_editor_value(self.editor,MC_EDITOR_EXPORT_BUSY)==1; }
- (NSSet<NSNumber *> *)visibleWindowNumbers {
    return !self.closed && self.window.visible && !self.window.miniaturized && self.window.windowNumber>0 ? [NSSet setWithObject:@(self.window.windowNumber)] : [NSSet set];
}
- (instancetype)initWithDraftDirectory:(NSURL *)directory error:(NSError **)error {
    if (!(self=[super init])) return nil;
    _directory=directory; _seekTickets=[NSMutableSet set];
    _media=[[MCVideoMedia alloc] initWithURL:[directory URLByAppendingPathComponent:@"source.mp4"] error:error];
    if (!_media) return nil;
    BOOL exists=NO;
    _initialDraft=MCReadDraft([directory URLByAppendingPathComponent:@"edit-v2.json"],2,&exists,error);
    if (!_initialDraft) return nil;
    _initialUnsaved=!exists;
    if (!exists) { _initialDraft=MCReadDraft([directory URLByAppendingPathComponent:@"edit.json"],1,&exists,error); if (!_initialDraft) return nil; }
    moonbit_string_t meta=MCVideoString(MCVideoJSON(_media.metadata)),draft=MCVideoString(_initialDraft);
    _initialState=MCVideoDecode(video_project_open(meta,draft)); moonbit_decref(meta); moonbit_decref(draft);
    if (![_initialState[@"ok"] boolValue]) {
        if(error)*error=MCVideoError([NSString stringWithFormat:@"%@ 原片和编辑草稿已保留。",_initialState[@"error"][@"message"] ?: @"无法恢复编辑。"]); return nil;
    }
    video_project_close([_initialState[@"session"] intValue]);
    // Recovery scanning validates without retaining any root/effects or writing.
    return self;
}
- (BOOL)openRoot {
    if (self.editor) return YES;
    if (self.closed) return NO;
    moonbit_string_t path=MCVideoString([self.directory URLByAppendingPathComponent:@"source.mp4"].path);
    moonbit_string_t meta=MCVideoString(MCVideoJSON(self.media.metadata)),draft=MCVideoString(self.initialDraft);
    self.editor=self.initialUnsaved ? video_editor_open_unsaved(path,meta,draft) : video_editor_open(path,meta,draft);
    moonbit_decref(path); moonbit_decref(meta); moonbit_decref(draft);
    if (!self.editor) { self.lastError=MCVideoError(@"无法初始化共享编辑会话，草稿已保留。"); return NO; }
    self.initialState=nil; self.initialDraft=nil; self.lifetime=self;
    return YES;
}
- (void)changed {
    BOOL busy=self.exporting;
    if (busy!=self.lastNotifiedBusy) { self.lastNotifiedBusy=busy; if(self.onStateChange)self.onStateChange(); }
}
- (void)ack:(int32_t)ticket error:(NSError *)error {
    if (!self.editor) return;
    moonbit_string_t message=MCVideoString(error.localizedDescription ?: @"");
    video_editor_ack(self.editor,ticket,error ? (error.code==NSUserCancelledError ? MC_EDITOR_ACK_CANCELLED:MC_EDITOR_ACK_FAILED):MC_EDITOR_ACK_OK,message);
    moonbit_decref(message); self.clockDelivered=NO; [self pump];
}
- (BOOL)writeDraftBytes:(NSString *)text error:(NSError **)error {
    NSError *failure=nil;
    BOOL saved=[[text dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[self.directory URLByAppendingPathComponent:@"edit-v2.json"] options:NSDataWritingAtomic error:&failure];
    if (!saved && error) *error=MCVideoError([NSString stringWithFormat:@"草稿保存失败，编辑仍保留在内存中。%@",failure.localizedDescription ?: @""]);
    return saved;
}
- (BOOL)saveDraft:(NSError **)error {
    if (![self openRoot]) { if(error)*error=self.lastError; return NO; }
    video_editor_retry(self.editor); [self pump];
    BOOL saved=!self.draftDirty;
    if(!saved && error)*error=self.lastError ?: MCVideoError(@"草稿保存失败，编辑仍在内存中。"); return saved;
}
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error { return [self.media applyPlan:plan error:error]; }
- (void)finishClose {
    if (!self.editor || video_editor_value(self.editor,MC_EDITOR_PHASE)!=MC_EDITOR_CLOSED) return;
    self.closed=YES; [self.timer invalidate]; self.timer=nil;
    self.canvas.onEvent=nil; self.canvas.onFrameNeeded=nil; [self.canvas setVideoPlayer:nil];
    video_editor_release(self.editor); self.editor=0;
    self.window.delegate=nil; [self.window close]; self.window.contentView=nil; self.window=nil; self.canvas=nil;
    void (^completion)(NSError *)=self.terminationCompletion; self.terminationCompletion=nil;
    void (^closed)(void)=self.onClose; self.onClose=nil; self.onStateChange=nil;
    if(closed)closed(); if(completion)completion(nil); self.lifetime=nil;
}
- (void)ackCloseIfDrained {
    if (self.closeTicket && self.mediaDrained && self.waveformDrained) {
        int32_t ticket=self.closeTicket; self.closeTicket=0; [self ack:ticket error:nil];
    }
}
- (void)pump {
    if (!self.editor || self.closed) return;
    if (self.pumping) { self.refreshAgain=YES; return; }
    self.pumping=YES;
    do {
        self.refreshAgain=NO;
        for (int i=0;i<64;i++) {
            int32_t ticket=video_editor_take_effect(self.editor); if(!ticket)break;
            int kind=video_editor_effect_kind(self.editor,ticket);
            int32_t generation=video_editor_effect_generation(self.editor,ticket);
            double number=video_editor_effect_number(self.editor,ticket);
            NSError *failure=nil;
            switch(kind) {
            case MC_EDITOR_SAVE_DRAFT: {
                NSString *bytes=MCVideoText(video_editor_effect_text(self.editor,ticket));
                [self writeDraftBytes:bytes error:&failure]; [self ack:ticket error:failure]; break;
            }
            case MC_EDITOR_APPLY_PLAN: {
                NSDictionary *plan=MCExecutionPlan(video_editor_effect_plan(self.editor,ticket),self.media.metadata);
                BOOL ok=plan && [self applyMediaPlan:plan error:&failure];
                if(ok) { self.executionPlan=plan; self.appliedGeneration=generation; self.clockDelivered=NO; }
                else { [self.media pause]; failure=failure ?: MCVideoError(@"无法复制媒体计划。"); }
                [self ack:ticket error:failure]; break;
            }
            case MC_EDITOR_SEEK: {
                [self.seekTickets addObject:@(ticket)];
                [self.media seekOutputMilliseconds:fmax(0,fmin(number,self.media.outputDurationMilliseconds-1)) terminal:^(BOOL finished) {
                    [self.seekTickets removeObject:@(ticket)];
                    [self ack:ticket error:finished ? nil : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
                }]; break;
            }
            case MC_EDITOR_PLAY:
                if(number!=0) [self.media playWithCompletion:^(NSError *error){ [self ack:ticket error:error]; }];
                else { [self.media pause]; [self ack:ticket error:nil]; } break;
            case MC_EDITOR_PREVIEW_RATE:
                [self.media setPreviewRate:number error:&failure]; [self ack:ticket error:failure]; break;
            case MC_EDITOR_CHOOSE_EXPORT: {
                self.chooserTicket=ticket; [self changed];
                NSURL *direct=self.directExportURL; self.directExportURL=nil;
                if(direct) [self completeChooser:ticket destination:direct];
                else [self chooseExportDestinationWithCompletion:^(NSURL *destination){ [self completeChooser:ticket destination:destination]; }];
                break;
            }
            case MC_EDITOR_EXPORT: {
                NSDictionary *plan=MCExecutionPlan(video_editor_effect_plan(self.editor,ticket),self.media.metadata);
                if (generation!=self.appliedGeneration || ![plan isEqual:self.executionPlan]) { [self ack:ticket error:MCVideoError(@"预览计划尚未同步，无法导出旧计划。")]; break; }
                NSURL *url=[NSURL fileURLWithPath:MCVideoText(video_editor_effect_text(self.editor,ticket))];
                self.exportTicket=ticket;
                [self.media exportToURL:url completion:^(NSURL *saved,NSError *error) {
                    self.exportTicket=0;
                    void (^completion)(NSURL *,NSError *)=self.exportCompletion; self.exportCompletion=nil;
                    BOOL suppressed=self.suppressPresentationCompletion;
                    if (!error && self.copyExport) { [NSPasteboard.generalPasteboard clearContents];
                        if(![NSPasteboard.generalPasteboard writeObjects:@[saved]])error=MCVideoError(@"视频已保存，但复制文件失败。"); }
                    self.copyExport=NO; [self ack:ticket error:error];
                    if(completion && !suppressed)completion(error ? nil:saved,error);
                }]; break;
            }
            case MC_EDITOR_CANCEL_EXPORT:
                [self.media cancelExport]; [self ack:ticket error:nil]; break;
            case MC_EDITOR_CLOSE_MEDIA: {
                self.closeTicket=ticket; [self.canvas setVideoPlayer:nil];
                self.waveformDrained=self.waveformTask==nil; self.mediaDrained=NO;
                [self.waveformTask cancelWithCompletion:^{ self.waveformTask=nil; self.waveformDrained=YES; [self ackCloseIfDrained]; }];
                [self.media closeWithCompletion:^{ self.mediaDrained=YES; [self ackCloseIfDrained]; }]; break; }
            default: [self ack:ticket error:MCVideoError(@"未知的编辑器媒体操作。")]; break;
            }
        }
    } while(self.refreshAgain);
    self.pumping=NO;
    NSString *message=MCVideoText(video_editor_text(self.editor,MC_EDITOR_ERROR));
    self.lastError=message.length ? MCVideoError(message):nil;
    [self changed];
    if (video_editor_value(self.editor,MC_EDITOR_PHASE)==MC_EDITOR_CLOSED) { [self finishClose]; return; }
    if(self.terminationCompletion && video_editor_value(self.editor,MC_EDITOR_PHASE)==MC_EDITOR_OPEN) {
        void (^completion)(NSError *)=self.terminationCompletion; self.terminationCompletion=nil;
        completion(self.lastError ?: MCVideoError(@"编辑器未能关闭，原片和草稿已保留。"));
    }
    if (!self.exporting && self.exportCompletion) {
        void (^completion)(NSURL *,NSError *)=self.exportCompletion; self.exportCompletion=nil; self.directExportURL=nil;
        if(!self.suppressPresentationCompletion)completion(nil,self.lastError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
    }
    [self.canvas setVideoPlayer:self.mediaSynchronized ? self.media.player:nil]; [self render];
}
- (void)buildWindow {
    if (self.closed || self.window || ![self openRoot]) return;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1040,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"编辑录屏 · Mooji Cut"; self.window.releasedWhenClosed=NO; self.window.delegate=self; self.window.contentMinSize=NSMakeSize(720,480);
    self.canvas=[[MCSharedCanvasView alloc] initWithFrame:NSMakeRect(0,0,1040,720)]; self.window.contentView=self.canvas;
    __weak MCVideoEditor *weak=self;
    self.canvas.onEvent=^(NSDictionary *event){ [weak sendUIEvent:event]; };
    self.canvas.onFrameNeeded=^(__unused CGSize size){ [weak render]; };
    NSAppearanceName appearance=[self.canvas.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]];
    [self sendUIEvent:@{@"type":@"appearance",@"mode":[appearance isEqual:NSAppearanceNameDarkAqua] ? @"dark":@"light"}];
    [self.window center];
    if([self.media.metadata[@"hasAudio"] boolValue]) {
        NSNumber *duration=self.media.metadata[@"durationMs"];
        self.waveformTask=[MCAudioWaveform readURL:[self.directory URLByAppendingPathComponent:@"source.mp4"] durationMilliseconds:duration.doubleValue completion:^(NSArray *peaks,NSError *error){
            MCVideoEditor *owner=weak; if(!owner || !owner.editor)return;
            owner.waveformTask=nil;
            if(error)NSLog(@"Audio waveform unavailable: %@",error.localizedDescription);
            moonbit_string_t value=MCVideoString(MCVideoJSON(@{@"type":@"waveform",@"durationMs":duration,@"peaks":peaks ?: @[]}));
            video_editor_waveform(owner.editor,value); moonbit_decref(value); [owner render];
        }];
    }
    self.timer=[NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(__unused NSTimer *timer){ [weak tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)show { if(self.closed)return; [self buildWindow]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self.canvas]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)render {
    if(!self.editor || self.closed || !self.canvas)return;
    moonbit_string_t frame=video_editor_frame(self.editor,self.canvas.bounds.size.width,self.canvas.bounds.size.height);
    [self.canvas setFrameJSON:frame]; moonbit_decref(frame);
}
- (void)sendUIEvent:(NSDictionary *)event {
    if(!self.editor || self.closed)return;
    moonbit_string_t input=MCVideoString(MCVideoJSON(event)); video_editor_event(self.editor,input); moonbit_decref(input); [self pump];
}
- (void)tick {
    if(!self.editor || self.closed)return;
    BOOL changed=NO;
    if(self.exportTicket)changed=video_editor_export_progress(self.editor,self.exportTicket,self.media.exportProgress);
    NSError *failure=self.media.previewPlaybackError;
    if(failure!=self.reportedPreviewError) {
        self.reportedPreviewError=failure;
        if(failure && self.media.player.currentItem.status==AVPlayerItemStatusFailed) { moonbit_string_t text=MCVideoString(failure.localizedDescription); video_editor_media_failed(self.editor,self.appliedGeneration,text); moonbit_decref(text); changed=YES; }
    }
    double output=self.media.currentOutputMilliseconds; BOOL playing=self.media.playbackRequested;
    if(!self.clockDelivered || self.lastClockPlaying!=playing || fabs(output-self.lastClockOutput)>=0.5) {
        if(video_editor_playback(self.editor,self.appliedGeneration,output,playing)) {
            self.clockDelivered=YES; self.lastClockPlaying=playing; self.lastClockOutput=output; changed=YES;
        }
    }
    if(changed)[self pump];
}
- (NSString *)defaultExportName {
    NSDate *created=nil; [[self.directory URLByAppendingPathComponent:@"source.mp4"] getResourceValue:&created forKey:NSURLCreationDateKey error:NULL];
    NSDateFormatter *format=[NSDateFormatter new]; format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; format.dateFormat=@"yyyyMMdd_HHmmss";
    return [NSString stringWithFormat:@"moojicut_%@.mp4",[format stringFromDate:created ?: NSDate.date]];
}
- (void)completeChooser:(int32_t)ticket destination:(NSURL *)destination {
    if(!self.editor || ticket!=self.chooserTicket)return;
    self.chooserTicket=0;
    if(self.afterChooser)destination=nil; // A late OK cannot defeat a pending close.
    moonbit_string_t path=MCVideoString(destination.path ?: @"");
    video_editor_ack(self.editor,ticket,destination ? MC_EDITOR_ACK_OK:MC_EDITOR_ACK_CANCELLED,path); moonbit_decref(path);
    void (^next)(void)=self.afterChooser; self.afterChooser=nil;
    if(next)next(); [self pump];
}
- (void)chooseExportDestinationWithCompletion:(void (^)(NSURL *))completion {
    NSSavePanel *panel=NSSavePanel.savePanel; self.savePanel=panel; self.panelCompletion=completion; self.panelPresented=NO;
    panel.allowedContentTypes=@[UTTypeMPEG4Movie]; panel.canCreateDirectories=YES;
    panel.nameFieldStringValue=self.defaultExportName; panel.prompt=@"保存视频";
    // Never keep the effect dispatcher on the stack during a modal UI session.
    __weak MCVideoEditor *weak=self;
    CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopCommonModes,^{
        MCVideoEditor *owner=weak; if(!owner || owner.savePanel!=panel || !owner.panelCompletion)return;
        owner.panelPresented=YES;
        void (^finished)(NSModalResponse)=^(NSModalResponse response) {
            MCVideoEditor *self=weak; if(!self || self.savePanel!=panel)return;
            void (^callback)(NSURL *)=self.panelCompletion; self.panelCompletion=nil; self.savePanel=nil; self.panelPresented=NO;
            if(callback)callback(response==NSModalResponseOK ? panel.URL:nil);
        };
        if(owner.window.visible)[panel beginSheetModalForWindow:owner.window completionHandler:finished];
        else [panel beginWithCompletionHandler:finished];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)cancelChooser {
    if(!self.savePanel)return;
    if(self.panelPresented) { [self.savePanel cancel:nil]; return; }
    void (^callback)(NSURL *)=self.panelCompletion; self.panelCompletion=nil; self.savePanel=nil;
    if(callback)callback(nil);
}
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *,NSError *))completion {
    if (![self openRoot] || self.exporting || self.closed) { if(completion)completion(nil,MCVideoError(@"编辑器已关闭或正在保存。")); return; }
    [self pump]; self.directExportURL=url; self.copyExport=copy; self.exportCompletion=completion;
    [self sendUIEvent:@{@"type":@"activate",@"id":@"export"}];
}
- (void)cancelExportKeepingDraft { [self.media cancelExport]; }
- (BOOL)confirmCancelExport {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"正在保存视频"; alert.informativeText=@"停止保存会保留原片与编辑草稿。";
    [alert addButtonWithTitle:@"继续保存"]; [alert addButtonWithTitle:@"停止保存并关闭"]; return [alert runModal]==NSAlertSecondButtonReturn;
}
- (BOOL)windowShouldClose:(__unused NSWindow *)sender {
    if(self.closed)return YES;
    if(self.afterChooser)return NO;
    BOOL cancel=NO;
    if(self.chooserTicket) {
        __weak MCVideoEditor *weak=self;
        self.afterChooser=^{ MCVideoEditor *owner=weak; if(owner) { video_editor_request_close(owner.editor,0); [owner pump]; } };
        [self cancelChooser]; return NO;
    }
    if(self.exporting) { int32_t ticket=self.exportTicket; cancel=[self confirmCancelExport];
        if(!cancel || (self.exportTicket && self.exportTicket!=ticket))return NO; }
    if(self.editor) { video_editor_request_close(self.editor,cancel); [self pump]; }
    return NO; // The root's actual CLOSED transition closes the NSWindow.
}
- (BOOL)prepareForTermination:(NSError **)error {
    if(self.closed || !self.editor)return YES;
    if(self.exporting) { if(error)*error=MCVideoError(@"视频仍在保存，请等待完成或取消后退出。"); return NO; }
    [self sendUIEvent:@{@"type":@"cancel"}]; return [self saveDraft:error];
}
- (void)requestTermination:(void (^)(NSError *))completion {
    if(self.closed || !self.editor) { completion(nil); return; }
    if(self.terminationCompletion) { completion(MCVideoError(@"正在关闭编辑器。")); return; }
    if(self.chooserTicket) {
        if(self.afterChooser) { completion(MCVideoError(@"正在关闭保存对话框，请稍后重试退出。")); return; }
        __weak MCVideoEditor *weak=self;
        self.afterChooser=^{ [weak requestTermination:completion]; };
        [self cancelChooser]; return;
    }
    if(!video_editor_request_close(self.editor,0)) { completion(MCVideoError(@"请先结束保存视频。")); return; }
    self.terminationCompletion=completion; [self pump];
}
- (void)windowWillClose:(__unused NSNotification *)notification {
    if(self.closed || !self.editor || self.afterChooser)return;
    self.suppressPresentationCompletion=YES;
    if(self.chooserTicket) {
        __weak MCVideoEditor *weak=self;
        self.afterChooser=^{ MCVideoEditor *owner=weak; if(owner) { video_editor_request_close(owner.editor,1); [owner pump]; } };
        [self cancelChooser]; return;
    }
    video_editor_request_close(self.editor,1); [self pump];
    if(self.editor && video_editor_value(self.editor,MC_EDITOR_PHASE)==MC_EDITOR_OPEN) {
        self.suppressPresentationCompletion=NO;
        dispatch_async(dispatch_get_main_queue(),^{ [self show]; });
    }
}
- (void)dealloc { [_timer invalidate]; [_media close]; [_waveformTask cancel]; }
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
    __block BOOL positioned=NO;
    [editor.media seekOutputMilliseconds:250 terminal:^(BOOL ok){positioned=ok;}];
    if(!MCWaitUntil(^BOOL{return positioned;},10))return NO;
    [editor tick];
    if (!click(@"project-split") || [editor.state[@"plan"][@"video"] count]!=4 || !click(@"undo") ||
        ![editor.state[@"plan"] isEqual:before] || editor.draftDirty || editor.window.visible) {
        if (error) *error=editor.lastError ?: MCVideoError(@"正式共享编辑器输入、撤销或草稿写入检查失败。"); return NO;
    }
    for (NSUInteger pass=0; pass<2; pass++) {
        if (pass && (!click(@"project-mute") || ![editor.state[@"document"][@"muted"] boolValue])) return NO;
        if(!MCWaitUntil(^BOOL{return editor.mediaSynchronized && !editor.pendingSeek;},10))return NO;
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
    [editor.window performClose:nil];
    return MCWaitUntil(^BOOL{return editor.closed;},10);
}
@end
