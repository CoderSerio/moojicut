#import "MCVideoMedia.h"
#include <math.h>
#include <sys/stat.h>
#include <errno.h>

static void *MCMediaItemStatusContext=&MCMediaItemStatusContext;
// AppKit termination may enter a nested run loop from a main-queue callback.
// Resource terminal deliveries must still run there to complete CLOSE_MEDIA.
static void MCMediaOnMain(void (^block)(void)) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopCommonModes,block); CFRunLoopWakeUp(CFRunLoopGetMain());
}

static NSError *MCMediaError(NSString *message) {
    return [NSError errorWithDomain:@"MoojiCut.VideoMedia" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL MCMediaDistinctDestination(NSURL *source, NSURL *destination) {
    if(!destination.isFileURL || ![destination.pathExtension.lowercaseString isEqual:@"mp4"] ||
        [destination.URLByResolvingSymlinksInPath.path isEqual:source.URLByResolvingSymlinksInPath.path])return NO;
    struct stat original,target,entry;
    if(stat(source.fileSystemRepresentation,&original)!=0)return NO;
    if(lstat(destination.fileSystemRepresentation,&entry)!=0)return errno==ENOENT;
    if(stat(destination.fileSystemRepresentation,&target)!=0 || !S_ISREG(target.st_mode))return NO;
    return original.st_dev!=target.st_dev || original.st_ino!=target.st_ino;
}
static NSArray<AVAssetTrack *> *MCMediaTracks(AVAsset *asset, AVMediaType type) {
    NSMutableArray *result = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:type]) [result addObject:track];
    return result;
}
static CGRect MCMediaBounds(AVAssetTrack *track) {
    return CGRectApplyAffineTransform((CGRect){CGPointZero,track.naturalSize},track.preferredTransform);
}
static BOOL MCMediaInteger(id value, double minimum, double maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && floor(number)==number && number>=minimum && number<=maximum;
}
static BOOL MCMediaBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && ([value doubleValue]==0 || [value doubleValue]==1);
}
static CMTime MCMediaTick(int64_t ticks) { return CMTimeMake(ticks,90000); }
static AVMutableVideoCompositionInstruction *MCMediaInstruction(int64_t start,int64_t duration,
    AVVideoCompositionLayerInstruction *layer) {
    AVMutableVideoCompositionInstruction *instruction=[AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange=CMTimeRangeMake(MCMediaTick(start),MCMediaTick(duration));
    // With no source layer the standard compositor fills opaque black.
    instruction.layerInstructions=layer ? @[layer] : @[];
    return instruction;
}
static BOOL MCMediaDecodeBoundary(AVAsset *asset, AVAssetTrack *track, BOOL tail, NSError **error) {
    AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:error];
    AVAssetReaderTrackOutput *frames=[[AVAssetReaderTrackOutput alloc] initWithTrack:track
        outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    if (!reader || ![reader canAddOutput:frames]) {
        if(error)*error=MCMediaError(@"无法读取导出画面。"); return NO;
    }
    if (tail) {
        // Exported composition frames are 30fps. Read the final 100ms through
        // completion, so a readable first frame cannot hide a truncated tail.
        CMTime end=CMTimeRangeGetEnd(track.timeRange);
        CMTime start=CMTimeMaximum(track.timeRange.start,CMTimeSubtract(end,CMTimeMake(100,1000)));
        reader.timeRange=CMTimeRangeFromTimeToTime(start,end);
    }
    [reader addOutput:frames];
    if (![reader startReading]) { if(error)*error=reader.error ?: MCMediaError(@"无法解码导出画面。"); return NO; }
    BOOL readable=NO; CMSampleBufferRef sample=NULL;
    while ((sample=[frames copyNextSampleBuffer])) {
        readable=CMSampleBufferGetImageBuffer(sample)!=NULL;
        CFRelease(sample);
        if (!tail || !readable) break;
    }
    BOOL valid=readable && (!tail || reader.status==AVAssetReaderStatusCompleted);
    [reader cancelReading];
    if(!valid && error)*error=MCMediaError(tail ? @"导出视频尾部无法解码，未替换目标文件。" : @"导出画面无法解码，未替换目标文件。");
    return valid;
}

@interface MCVideoMedia ()
@property (nonatomic, readwrite, copy) NSDictionary *metadata;
@property (nonatomic, readwrite) AVPlayer *player;
@property (nonatomic, readwrite) double outputDurationMilliseconds;
@property (nonatomic, readwrite) BOOL previewingSource;
@property (nonatomic, readwrite) double previewRate;
@property (nonatomic, readwrite, nullable) NSError *previewPlaybackError;
@property AVURLAsset *asset;
@property AVAssetTrack *videoTrack;
@property AVMutableComposition *composition;
@property AVMutableVideoComposition *videoComposition;
@property AVAudioMix *audioMix;
@property NSInteger planSchemaVersion;
@property AVAssetExportSession *exporter;
@property NSUInteger generation;
@property BOOL closed, exportCancelled;
@property double savedOutputPosition;
@property AVPlayerItem *observedItem;
@property BOOL pendingPlayback;
@property (copy) void (^playCompletion)(NSError *);
@property NSMutableArray *closeCompletions;
@property NSUInteger pendingSeeks, statusDeliveries;
@property BOOL exportCallbackActive, drainScheduled;
- (void)finishCloseIfDrained;
- (void)finishPlay:(NSError *)error;
- (void)seekMilliseconds:(double)milliseconds limit:(double)limit terminal:(BOOL)terminal completion:(void (^)(BOOL))completion;
@end

@implementation MCVideoMedia
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ((self=[super init])) {
        if (!url.isFileURL) { if(error)*error=MCMediaError(@"请选择本地视频文件。"); return nil; }
        _asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        _videoTrack = MCMediaTracks(_asset,AVMediaTypeVideo).firstObject;
        double duration = _videoTrack ? CMTimeGetSeconds(CMTimeRangeGetEnd(_videoTrack.timeRange))*1000 : 0;
        CGRect bounds = _videoTrack ? MCMediaBounds(_videoTrack) : CGRectZero;
        double width=fabs(bounds.size.width), height=fabs(bounds.size.height);
        if (!isfinite(duration) || duration<1 || duration>604800000 || !isfinite(width) || !isfinite(height) ||
            width<2 || height<2 || width>32768 || height>32768) {
            if(error)*error=MCMediaError(@"视频没有可读取的画面或尺寸无效，原始文件未改动。"); return nil;
        }
        _metadata = @{@"durationMs":@(floor(duration)), @"width":@(llround(width)), @"height":@(llround(height)),
            @"hasAudio":MCMediaTracks(_asset,AVMediaTypeAudio).count>0 ? @YES : @NO};
        _outputDurationMilliseconds = floor(duration);
        _previewRate = 1; _closeCompletions = [NSMutableArray array];
        _player = [AVPlayer playerWithPlayerItem:nil];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        [self replacePreviewItem:[AVPlayerItem playerItemWithAsset:_asset]];
    }
    return self;
}
- (BOOL)buildPlan:(NSDictionary *)plan composition:(AVMutableComposition **)result
    videoComposition:(AVMutableVideoComposition **)videoResult error:(NSError **)error {
    // The reducer owns edit policy; these checks protect the media/I/O boundary
    // from malformed dictionaries and ranges beyond the actual source asset.
    double sourceDuration=[self.metadata[@"durationMs"] doubleValue];
    if (![plan isKindOfClass:NSDictionary.class]) {
        if(error)*error=MCMediaError(@"剪辑计划无效，已保留当前预览。"); return NO;
    }
    NSArray *segments=plan[@"segments"];
    id muted=plan[@"muted"];
    if (![segments isKindOfClass:NSArray.class] || segments.count==0 ||
        ![muted isKindOfClass:NSNumber.class] || ([muted doubleValue]!=0 && [muted doubleValue]!=1) ||
        !MCMediaInteger(plan[@"outputDurationMs"],1,sourceDuration)) goto invalid;
    double cursor=0, previousEnd=0;
    for (id item in segments) {
        if (![item isKindOfClass:NSDictionary.class]) goto invalid;
        NSDictionary *segment=item;
        for (NSString *key in @[@"sourceStartMs",@"sourceEndMs",@"outputStartMs",@"outputEndMs"])
            if (!MCMediaInteger(segment[key],0,sourceDuration)) goto invalid;
        double start=[segment[@"sourceStartMs"] doubleValue], end=[segment[@"sourceEndMs"] doubleValue];
        double outputStart=[segment[@"outputStartMs"] doubleValue], outputEnd=[segment[@"outputEndMs"] doubleValue];
        if (start>=end || start<previousEnd || outputStart!=cursor || outputEnd-outputStart!=end-start) goto invalid;
        previousEnd=end; cursor=outputEnd;
    }
    if (cursor!=[plan[@"outputDurationMs"] doubleValue]) goto invalid;
    {
        CGRect bounds=MCMediaBounds(self.videoTrack);
        double x=0,y=0,width=fabs(bounds.size.width),height=fabs(bounds.size.height);
        id crop=plan[@"crop"];
        if (crop && crop!=NSNull.null) {
            if (![crop isKindOfClass:NSDictionary.class] || !MCMediaInteger(crop[@"x"],0,width-2) ||
                !MCMediaInteger(crop[@"y"],0,height-2)) goto invalid;
            x=[crop[@"x"] doubleValue]; y=[crop[@"y"] doubleValue];
            if (!MCMediaInteger(crop[@"width"],2,width-x) || !MCMediaInteger(crop[@"height"],2,height-y)) goto invalid;
            width=[crop[@"width"] doubleValue]; height=[crop[@"height"] doubleValue];
        }
        AVMutableComposition *composition=[AVMutableComposition composition];
        AVMutableCompositionTrack *video=[composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        NSArray<AVAssetTrack *> *audioSources=[muted boolValue] ? @[] : MCMediaTracks(self.asset,AVMediaTypeAudio);
        NSMutableArray<AVMutableCompositionTrack *> *audioOutputs=[NSMutableArray array];
        for (__unused AVAssetTrack *track in audioSources)
            [audioOutputs addObject:[composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]];
        for (NSDictionary *segment in segments) {
            CMTimeRange range=CMTimeRangeFromTimeToTime(CMTimeMake([segment[@"sourceStartMs"] longLongValue],1000),CMTimeMake([segment[@"sourceEndMs"] longLongValue],1000));
            CMTime output=CMTimeMake([segment[@"outputStartMs"] longLongValue],1000);
            if (![video insertTimeRange:range ofTrack:self.videoTrack atTime:output error:error]) return NO;
            for (NSUInteger i=0;i<audioSources.count;i++) {
                CMTimeRange available=CMTimeRangeGetIntersection(range,audioSources[i].timeRange);
                if (CMTIMERANGE_IS_VALID(available) && CMTimeCompare(available.duration,kCMTimeZero)>0 &&
                    ![audioOutputs[i] insertTimeRange:available ofTrack:audioSources[i]
                        atTime:CMTimeAdd(output,CMTimeSubtract(available.start,range.start)) error:error]) return NO;
            }
        }
        AVMutableVideoComposition *videoComposition=[AVMutableVideoComposition videoComposition];
        videoComposition.renderSize=CGSizeMake(width,height); videoComposition.frameDuration=CMTimeMake(1,30);
        AVMutableVideoCompositionLayerInstruction *layer=[AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:video];
        [layer setTransform:CGAffineTransformConcat(self.videoTrack.preferredTransform,
            CGAffineTransformMakeTranslation(-bounds.origin.x-x,-bounds.origin.y-y)) atTime:kCMTimeZero];
        AVMutableVideoCompositionInstruction *instruction=[AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange=CMTimeRangeMake(kCMTimeZero,CMTimeMake((int64_t)cursor,1000));
        instruction.layerInstructions=@[layer]; videoComposition.instructions=@[instruction];
        *result=composition; *videoResult=videoComposition; return YES;
    }
invalid:
    if(error)*error=MCMediaError(@"剪辑计划与原片不匹配，已保留当前预览。"); return NO;
}
- (BOOL)buildProjectPlan:(NSDictionary *)plan composition:(AVMutableComposition **)result
    videoComposition:(AVMutableVideoComposition **)videoResult audioMix:(AVAudioMix **)audioResult error:(NSError **)error {
    // This is execution-boundary validation only. MoonBit owns project edits,
    // links, quantization and history; the native port never repairs the plan.
    int64_t sourceLimit=[self.metadata[@"durationMs"] longLongValue]*90;
    const int64_t maximum=604800000LL*90;
    NSDictionary *source=plan[@"source"], *frameRate=plan[@"frameRate"];
    NSArray *videos=plan[@"video"], *audios=plan[@"audio"];
    if (!MCMediaInteger(plan[@"timebase"],90000,90000) || ![frameRate isKindOfClass:NSDictionary.class] ||
        !MCMediaInteger(frameRate[@"num"],30,30) || !MCMediaInteger(frameRate[@"den"],1,1) ||
        ![source isKindOfClass:NSDictionary.class] || !MCMediaBoolean(source[@"hasAudio"]) ||
        [source[@"hasAudio"] boolValue]!=[self.metadata[@"hasAudio"] boolValue] ||
        ![videos isKindOfClass:NSArray.class] || videos.count<1 || videos.count>256 ||
        ![audios isKindOfClass:NSArray.class] || audios.count>256 || !MCMediaBoolean(plan[@"muted"]) ||
        ([plan[@"muted"] boolValue] && audios.count>0) ||
        !MCMediaInteger(plan[@"outputDurationTicks"],3000,maximum) ||
        [plan[@"outputDurationTicks"] longLongValue]%3000!=0) goto invalid;
    for (NSString *key in @[@"durationMs",@"width",@"height"])
        if (!MCMediaInteger(source[key],[self.metadata[key] doubleValue],[self.metadata[key] doubleValue])) goto invalid;
    {
        int64_t output=[plan[@"outputDurationTicks"] longLongValue];
        NSMutableSet *ids=[NSMutableSet set];
        for (NSString *kind in @[@"video",@"audio"]) for (id entry in plan[kind]) {
            if (![entry isKindOfClass:NSDictionary.class]) goto invalid;
            NSDictionary *clip=entry; NSString *identifier=clip[@"id"]; id link=clip[@"linkGroup"];
            if (![identifier isKindOfClass:NSString.class] || identifier.length==0 || [ids containsObject:identifier] ||
                ![clip[@"kind"] isEqual:kind] || !(link==NSNull.null || ([link isKindOfClass:NSString.class] && [link length]>0))) goto invalid;
            [ids addObject:identifier];
            for (NSString *key in @[@"sourceStartTicks",@"sourceEndTicks",@"startTicks",@"durationTicks"])
                if (!MCMediaInteger(clip[key],0,maximum)) goto invalid;
            int64_t begin=[clip[@"sourceStartTicks"] longLongValue], end=[clip[@"sourceEndTicks"] longLongValue];
            int64_t start=[clip[@"startTicks"] longLongValue], duration=[clip[@"durationTicks"] longLongValue];
            if (end-begin<3000 || end>sourceLimit || duration<3000 || start%3000!=0 || duration%3000!=0 || start+duration>output ||
                ((double)(end-begin)+0.5)*4<duration || (double)(end-begin)-0.5>duration*4 ||
                ([kind isEqual:@"audio"] && ![self.metadata[@"hasAudio"] boolValue])) goto invalid;
            if ([kind isEqual:@"audio"] && (double)(end-begin)+0.5<duration) {
                if(error)*error=MCMediaError(@"当前版本支持 1–4 倍音频变速；慢放音频会丢失尾部，请先移除该音频片段。"); return NO;
            }
        }
        NSArray *ordered=[videos sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
            return [a[@"startTicks"] compare:b[@"startTicks"]];
        }];
        int64_t cursor=0;
        for (NSDictionary *clip in ordered) {
            int64_t start=[clip[@"startTicks"] longLongValue];
            if (start<cursor) goto invalid;
            cursor=start+[clip[@"durationTicks"] longLongValue];
        }
        CGRect bounds=MCMediaBounds(self.videoTrack);
        double x=0,y=0,width=fabs(bounds.size.width),height=fabs(bounds.size.height);
        id crop=plan[@"crop"];
        if (crop!=NSNull.null) {
            if (![crop isKindOfClass:NSDictionary.class] || !MCMediaInteger(crop[@"x"],0,width-2) ||
                !MCMediaInteger(crop[@"y"],0,height-2)) goto invalid;
            x=[crop[@"x"] doubleValue]; y=[crop[@"y"] doubleValue];
            if (!MCMediaInteger(crop[@"width"],2,width-x) || !MCMediaInteger(crop[@"height"],2,height-y)) goto invalid;
            width=[crop[@"width"] doubleValue]; height=[crop[@"height"] doubleValue];
        }
        AVMutableComposition *composition=[AVMutableComposition composition];
        AVMutableCompositionTrack *video=[composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVMutableVideoCompositionLayerInstruction *layer=[AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:video];
        [layer setTransform:CGAffineTransformConcat(self.videoTrack.preferredTransform,
            CGAffineTransformMakeTranslation(-bounds.origin.x-x,-bounds.origin.y-y)) atTime:kCMTimeZero];
        NSMutableArray *instructions=[NSMutableArray array]; cursor=0;
        for (NSDictionary *clip in ordered) {
            int64_t start=[clip[@"startTicks"] longLongValue], duration=[clip[@"durationTicks"] longLongValue];
            int64_t begin=[clip[@"sourceStartTicks"] longLongValue], sourceLength=[clip[@"sourceEndTicks"] longLongValue]-begin;
            if (start>cursor) [instructions addObject:MCMediaInstruction(cursor,start-cursor,nil)];
            CMTimeRange range=CMTimeRangeMake(MCMediaTick(begin),MCMediaTick(sourceLength));
            if (!CMTimeRangeContainsTimeRange(self.videoTrack.timeRange,range)) goto invalid;
            if (![video insertTimeRange:range ofTrack:self.videoTrack atTime:MCMediaTick(start) error:error]) return NO;
            [video scaleTimeRange:CMTimeRangeMake(MCMediaTick(start),MCMediaTick(sourceLength)) toDuration:MCMediaTick(duration)];
            [instructions addObject:MCMediaInstruction(start,duration,layer)]; cursor=start+duration;
        }
        if (cursor<output) {
            [instructions addObject:MCMediaInstruction(cursor,output-cursor,nil)];
            // AVComposition explicitly cannot append empty time at its end.
            // Anchor the last frame so its duration covers the complete plan;
            // the no-layer instruction renders this entire tail opaque black.
            if (![video insertTimeRange:CMTimeRangeMake(self.videoTrack.timeRange.start,MCMediaTick(3000))
                ofTrack:self.videoTrack atTime:MCMediaTick(output-3000) error:error]) return NO;
        }
        NSMutableArray *mixParameters=[NSMutableArray array];
        for (NSDictionary *clip in audios) {
            int64_t start=[clip[@"startTicks"] longLongValue], duration=[clip[@"durationTicks"] longLongValue];
            int64_t begin=[clip[@"sourceStartTicks"] longLongValue], sourceLength=[clip[@"sourceEndTicks"] longLongValue]-begin;
            CMTimeRange range=CMTimeRangeMake(MCMediaTick(begin),MCMediaTick(sourceLength));
            for (AVAssetTrack *sourceTrack in MCMediaTracks(self.asset,AVMediaTypeAudio)) {
                CMTimeRange available=CMTimeRangeGetIntersection(range,sourceTrack.timeRange);
                if (!CMTIMERANGE_IS_VALID(available) || CMTimeCompare(available.duration,kCMTimeZero)<=0) continue;
                AVMutableCompositionTrack *track=[composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                CMTimeRange target=CMTimeRangeMake(MCMediaTick(start),MCMediaTick(duration));
                CMTime position=CMTimeMapTimeFromRangeToRange(available.start,range,target);
                CMTime scaledDuration=CMTimeMapDurationFromRangeToRange(available.duration,range,target);
                if (![track insertTimeRange:available ofTrack:sourceTrack atTime:position error:error]) return NO;
                [track scaleTimeRange:CMTimeRangeMake(position,available.duration) toDuration:scaledDuration];
                AVMutableAudioMixInputParameters *parameters=[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
                parameters.audioTimePitchAlgorithm=AVAudioTimePitchAlgorithmTimeDomain;
                [parameters setVolume:1 atTime:kCMTimeZero]; [mixParameters addObject:parameters];
            }
        }
        AVMutableAudioMix *mix=[AVMutableAudioMix audioMix]; mix.inputParameters=mixParameters;
        AVMutableCompositionTrack *timing=[composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        if (![timing insertTimeRange:CMTimeRangeMake(self.videoTrack.timeRange.start,MCMediaTick(3000))
            ofTrack:self.videoTrack atTime:MCMediaTick(output-3000) error:error]) return NO;
        AVMutableVideoCompositionLayerInstruction *timingLayer=[AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:timing];
        // A visible-rate timing source makes the compositor render all 30fps
        // output ticks through the final held slow-motion frame. Move it off
        // canvas instead of making it transparent (which AVFoundation elides).
        [timingLayer setTransform:CGAffineTransformMakeTranslation(width+1,height+1) atTime:kCMTimeZero];
        for (AVMutableVideoCompositionInstruction *instruction in instructions)
            if (instruction.layerInstructions.count>0) instruction.layerInstructions=[instruction.layerInstructions arrayByAddingObject:timingLayer];
        AVMutableVideoComposition *videoComposition=[AVMutableVideoComposition videoComposition];
        videoComposition.renderSize=CGSizeMake(width,height); videoComposition.frameDuration=CMTimeMake(1,30);
        videoComposition.sourceTrackIDForFrameTiming=kCMPersistentTrackID_Invalid;
        videoComposition.instructions=instructions;
        BOOL valid=NO;
        if (@available(macOS 15.0, *))
            valid=[videoComposition isValidForTracks:composition.tracks assetDuration:composition.duration
                timeRange:CMTimeRangeMake(kCMTimeZero,MCMediaTick(output)) validationDelegate:nil];
        else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            valid=[videoComposition isValidForAsset:composition timeRange:CMTimeRangeMake(kCMTimeZero,MCMediaTick(output)) validationDelegate:nil];
#pragma clang diagnostic pop
        }
        // AVFoundation may normalize a scaled track to a nanosecond timescale
        // (e.g. 5/3s -> 1.666666667s). Compare in the authoritative 90k clock.
        if (!valid || CMTimeConvertScale(composition.duration,90000,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value!=output) goto invalid;
        *result=composition; *videoResult=videoComposition; *audioResult=mix; return YES;
    }
invalid:
    if(error)*error=MCMediaError(@"多段剪辑计划与原片或支持的时间范围不匹配，已保留当前预览。"); return NO;
}
- (BOOL)applyPlan:(NSDictionary *)plan error:(NSError **)error {
    if (self.closed || self.exporting) { if(error)*error=MCMediaError(@"媒体已关闭或正在导出。"); return NO; }
    AVMutableComposition *composition=nil; AVMutableVideoComposition *video=nil;
    AVAudioMix *audio=nil;
    if (![plan isKindOfClass:NSDictionary.class]) { if(error)*error=MCMediaError(@"剪辑计划无效。"); return NO; }
    BOOL project=MCMediaInteger(plan[@"schemaVersion"],2,2);
    if (plan[@"schemaVersion"] && !project && !MCMediaInteger(plan[@"schemaVersion"],1,1)) {
        if(error)*error=MCMediaError(@"剪辑计划版本不受支持。"); return NO;
    }
    if (project) {
        if (![self buildProjectPlan:plan composition:&composition videoComposition:&video audioMix:&audio error:error]) return NO;
    } else if (![self buildPlan:plan composition:&composition videoComposition:&video error:error]) return NO;
    self.generation++; [self pause]; [self.player.currentItem cancelPendingSeeks];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:composition]; item.videoComposition=video; item.audioMix=audio;
    self.composition=composition; self.videoComposition=video; self.audioMix=audio;
    self.planSchemaVersion=project ? 2 : 1;
    self.previewingSource=NO;
    self.outputDurationMilliseconds=project ? [plan[@"outputDurationTicks"] doubleValue]/90 : [plan[@"outputDurationMs"] doubleValue];
    [self replacePreviewItem:item]; return YES;
}
- (void)replacePreviewItem:(AVPlayerItem *)item {
    [self pause];
    [self.observedItem removeObserver:self forKeyPath:@"status" context:MCMediaItemStatusContext];
    self.observedItem=nil;
    // TimeDomain preserves pitch and supports continuous rates from 1/32 to
    // 32, unlike the deprecated algorithm which quantizes playback rates.
    item.audioTimePitchAlgorithm=AVAudioTimePitchAlgorithmTimeDomain;
    [self.player replaceCurrentItemWithPlayerItem:item];
    self.observedItem=item;
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:MCMediaItemStatusContext];
}
- (NSError *)rateError:(double)rate forItem:(AVPlayerItem *)item {
    if (self.closed) return MCMediaError(@"媒体已关闭，无法调整预览倍率。");
    if (!isfinite(rate) || !(rate==0.5 || rate==1 || rate==1.5 || rate==2 || rate==3))
        return MCMediaError(@"预览倍率请选择 0.5、1、1.5、2 或 3 倍。");
    if (!item || item.status==AVPlayerItemStatusUnknown)
        return MCMediaError(@"视频仍在准备，请就绪后再调整预览倍率。");
    if (item.status==AVPlayerItemStatusFailed) return item.error ?: MCMediaError(@"视频预览无法播放。");
    // Ready items support 1–2x even when canPlayFastForward is NO (Apple QA1772).
    if ((rate<1 && !item.canPlaySlowForward) || (rate>2 && !item.canPlayFastForward))
        return MCMediaError([NSString stringWithFormat:@"当前视频不支持 %g 倍预览，请选择其他倍率。",rate]);
    return nil;
}
- (void)startAtPreviewRate {
    if (@available(macOS 13.0, *)) {
        self.player.defaultRate=(float)self.previewRate;
        [self.player play];
    } else self.player.rate=(float)self.previewRate;
}
- (BOOL)setPreviewRate:(double)rate error:(NSError **)error {
    NSError *failure=[self rateError:rate forItem:self.player.currentItem];
    if (failure) { if(error)*error=failure; return NO; }
    BOOL playing=self.pendingPlayback || self.player.rate!=0;
    self.previewRate=rate; self.previewPlaybackError=nil;
    if (@available(macOS 13.0, *)) self.player.defaultRate=(float)rate;
    if (playing) { self.pendingPlayback=NO; [self startAtPreviewRate]; }
    return YES;
}
- (void)finishPlay:(NSError *)error {
    void (^completion)(NSError *) = self.playCompletion; self.playCompletion = nil;
    if (completion) completion(error);
}
- (void)playWithCompletion:(void (^)(NSError *))completion {
    [self finishPlay:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    self.playCompletion = completion;
    [self play];
}
- (void)play {
    if (self.closed) { [self finishPlay:MCMediaError(@"媒体已关闭。")]; return; }
    AVPlayerItem *item=self.player.currentItem;
    if (item && item.status==AVPlayerItemStatusUnknown) {
        self.previewPlaybackError=nil; self.pendingPlayback=YES; return;
    }
    NSError *failure=[self rateError:self.previewRate forItem:item];
    if (failure) { self.pendingPlayback=NO; [self.player pause]; self.previewPlaybackError=failure; [self finishPlay:failure]; return; }
    self.previewPlaybackError=nil; self.pendingPlayback=NO; [self startAtPreviewRate]; [self finishPlay:nil];
}
- (void)pause {
    self.pendingPlayback=NO; [self.player pause];
    [self finishPlay:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
}
- (BOOL)playbackRequested { return self.pendingPlayback || self.player.rate!=0; }
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context!=MCMediaItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return;
    }
    @synchronized(self) { self.statusDeliveries++; }
    MCMediaOnMain(^{
        if (!self.closed && object==self.observedItem && self.pendingPlayback && self.observedItem.status!=AVPlayerItemStatusUnknown) [self play];
        @synchronized(self) { self.statusDeliveries--; }
        [self finishCloseIfDrained];
    });
}
- (double)currentOutputMilliseconds {
    double value=CMTimeGetSeconds(self.player.currentTime)*1000;
    return self.closed || !isfinite(value) ? 0 : self.previewingSource ? self.savedOutputPosition : fmax(0,fmin(self.outputDurationMilliseconds,value));
}
- (void)seekOutputMilliseconds:(double)milliseconds completion:(void (^)(BOOL))completion {
    if (self.previewingSource) [self restorePlanPreview];
    [self seekMilliseconds:milliseconds limit:self.outputDurationMilliseconds completion:completion];
}
- (void)seekOutputMilliseconds:(double)milliseconds terminal:(void (^)(BOOL))completion {
    if (self.previewingSource) [self restorePlanPreview];
    [self seekMilliseconds:milliseconds limit:self.outputDurationMilliseconds terminal:YES completion:completion];
}
- (void)seekMilliseconds:(double)milliseconds limit:(double)limit completion:(void (^)(BOOL))completion {
    [self seekMilliseconds:milliseconds limit:limit terminal:NO completion:completion];
}
- (void)seekMilliseconds:(double)milliseconds limit:(double)limit terminal:(BOOL)terminal completion:(void (^)(BOOL))completion {
    if (self.closed) { if (terminal && completion) completion(NO); return; }
    if (!isfinite(milliseconds) || milliseconds<0 || milliseconds>limit) {
        if(completion)completion(NO); return;
    }
    NSUInteger generation=++self.generation; AVPlayerItem *item=self.player.currentItem;
    [item cancelPendingSeeks];
    self.pendingSeeks++;
    [self.player seekToTime:CMTimeMakeWithSeconds(milliseconds/1000,1000000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        MCMediaOnMain(^{
            BOOL current=!self.closed && self.generation==generation && self.player.currentItem==item;
            if (completion && (terminal || current)) completion(current && finished);
            self.pendingSeeks--; [self finishCloseIfDrained];
        });
    }];
}
- (void)previewSourceMilliseconds:(double)milliseconds completion:(void (^)(BOOL))completion {
    if (self.closed) return;
    double duration=[self.metadata[@"durationMs"] doubleValue];
    if (!isfinite(milliseconds) || milliseconds<0 || milliseconds>duration) { if(completion)completion(NO); return; }
    if (!self.previewingSource) {
        self.savedOutputPosition=self.currentOutputMilliseconds; self.generation++;
        [self pause]; [self.player.currentItem cancelPendingSeeks];
        [self replacePreviewItem:[AVPlayerItem playerItemWithAsset:self.asset]];
        self.previewingSource=YES;
    }
    [self seekMilliseconds:milliseconds limit:duration completion:completion];
}
- (void)restorePlanPreview {
    if (self.closed || !self.previewingSource) return;
    self.generation++; [self pause]; [self.player.currentItem cancelPendingSeeks];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:self.composition ?: self.asset];
    item.videoComposition=self.videoComposition; item.audioMix=self.audioMix;
    [self replacePreviewItem:item]; self.previewingSource=NO;
    [self seekMilliseconds:self.savedOutputPosition limit:self.outputDurationMilliseconds completion:nil];
}
- (BOOL)exporting { return self.exporter!=nil; }
- (float)exportProgress { return self.exporter.progress; }
- (BOOL)validateExport:(NSURL *)url error:(NSError **)error {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track=MCMediaTracks(asset,AVMediaTypeVideo).firstObject;
    double duration=CMTimeGetSeconds(asset.duration)*1000;
    BOOL audio=NO;
    for (AVAssetTrack *candidate in MCMediaTracks(self.composition,AVMediaTypeAudio))
        audio=audio || CMTimeCompare(candidate.timeRange.duration,kCMTimeZero)>0;
    if (!track || !isfinite(duration) || fabs(duration-self.outputDurationMilliseconds)>120 ||
        !CGSizeEqualToSize(track.naturalSize,self.videoComposition.renderSize) ||
        (MCMediaTracks(asset,AVMediaTypeAudio).count>0)!=audio) {
        if(error)*error=MCMediaError(@"导出结果与剪辑计划不一致，未替换目标文件。"); return NO;
    }
    if (self.planSchemaVersion==2) {
        // AAC padding may affect the container duration. The v2 video itself
        // must still cover its authoritative timeline, including held/gap frames.
        double videoEnd=CMTimeGetSeconds(CMTimeRangeGetEnd(track.timeRange))*1000;
        if (!isfinite(videoEnd) || fabs(videoEnd-self.outputDurationMilliseconds)>1) {
            if(error)*error=MCMediaError(@"导出视频末尾与剪辑计划不一致，未替换目标文件。"); return NO;
        }
    }
    return MCMediaDecodeBoundary(asset,track,NO,error) && MCMediaDecodeBoundary(asset,track,YES,error);
}
- (void)exportToURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    if (self.closed || self.exporting || !self.composition) {
        completion(nil,MCMediaError(@"请先应用剪辑计划，并等待当前媒体任务完成。")); return;
    }
    if (!MCMediaDistinctDestination(self.asset.URL,url)) {
        completion(nil,MCMediaError(@"请选择新的 MP4 保存位置，不能覆盖原片。")); return;
    }
    NSURL *temporary=[url.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@".MoojiCut-media-%@.mp4",NSUUID.UUID.UUIDString]];
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:self.composition presetName:AVAssetExportPresetHighestQuality];
    if (!exporter) { completion(nil,MCMediaError(@"无法创建视频导出任务。")); return; }
    exporter.videoComposition=self.videoComposition; exporter.audioMix=self.audioMix;
    exporter.audioTimePitchAlgorithm=AVAudioTimePitchAlgorithmTimeDomain;
    exporter.timeRange=CMTimeRangeMake(kCMTimeZero,CMTimeMakeWithSeconds(self.outputDurationMilliseconds/1000,90000));
    exporter.outputURL=temporary; exporter.outputFileType=AVFileTypeMPEG4;
    exporter.shouldOptimizeForNetworkUse=YES; self.exporter=exporter; self.exportCancelled=NO; [self pause];
    [exporter exportAsynchronouslyWithCompletionHandler:^{ MCMediaOnMain(^{
        NSError *error=nil;
        if (self.closed || self.exportCancelled || exporter.status==AVAssetExportSessionStatusCancelled)
            error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"导出已取消，原片和目标文件未改动。"}];
        else if (exporter.status!=AVAssetExportSessionStatusCompleted) error=exporter.error ?: MCMediaError(@"视频导出失败。");
        else if (![self validateExport:temporary error:&error]) error=error ?: MCMediaError(@"无法读取导出结果。");
        if(!error && !MCMediaDistinctDestination(self.asset.URL,url))error=MCMediaError(@"保存目标关联到原片或无法确认文件身份，未替换。");
        if (!error) {
            BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:url.path];
            BOOL saved=exists ? [NSFileManager.defaultManager replaceItemAtURL:url withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:NULL error:&error] :
                [NSFileManager.defaultManager moveItemAtURL:temporary toURL:url error:&error];
            if (!saved) error=error ?: MCMediaError(@"无法保存视频，原片未改动。");
        }
        [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
        self.exporter=nil; self.exportCancelled=NO;
        self.exportCallbackActive=YES; completion(error ? nil : url,error); self.exportCallbackActive=NO;
        [self finishCloseIfDrained];
    }); }];
}
- (void)cancelExport { self.exportCancelled=YES; [self.exporter cancelExport]; }
- (void)finishCloseIfDrained {
    if (!self.closed || self.pendingSeeks || self.exporter || self.playCompletion || self.exportCallbackActive ||
        self.drainScheduled || !self.closeCompletions.count) return;
    @synchronized(self) { if (self.statusDeliveries) return; }
    self.drainScheduled=YES;
    MCMediaOnMain(^{
        self.drainScheduled=NO;
        if(self.pendingSeeks || self.exporter || self.playCompletion || self.exportCallbackActive)return;
        @synchronized(self) { if(self.statusDeliveries)return; }
        NSArray *callbacks=[self.closeCompletions copy]; [self.closeCompletions removeAllObjects];
        for(void (^completion)(void) in callbacks)completion();
    });
}
- (void)closeWithCompletion:(void (^)(void))completion {
    [self.closeCompletions addObject:[completion copy]]; [self close]; [self finishCloseIfDrained];
}
- (void)close {
    if(self.closed)return; self.closed=YES; self.generation++;
    self.planSchemaVersion=0;
    [self pause]; [self.player.currentItem cancelPendingSeeks];
    [self.observedItem removeObserver:self forKeyPath:@"status" context:MCMediaItemStatusContext]; self.observedItem=nil;
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [self cancelExport];
    [self finishCloseIfDrained];
}
- (void)dealloc {
    [_observedItem removeObserver:self forKeyPath:@"status" context:MCMediaItemStatusContext];
    [_player pause]; [_player.currentItem cancelPendingSeeks]; [_exporter cancelExport];
}
@end
