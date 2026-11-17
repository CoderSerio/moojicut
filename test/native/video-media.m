#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "plugins/feature/video_editor/macos/MCVideoMedia.h"
#include "moonbit.h"
#include <assert.h>
#include <math.h>

extern moonbit_string_t video_open(moonbit_string_t,moonbit_string_t);
extern moonbit_string_t video_command(int32_t,moonbit_string_t);
extern void video_dispose(int32_t);
@interface MCVideoMedia (MediaFixture)
- (BOOL)validateExport:(NSURL *)url error:(NSError **)error;
- (void)replacePreviewItem:(AVPlayerItem *)item;
@end
// Deterministically exercise capability refusal and delayed-ready intent using
// the same real source asset. Clock assertions below use unmodified real items.
@interface MCRateLimitedItem : AVPlayerItem
@property BOOL forceUnknown;
@end
@implementation MCRateLimitedItem
- (AVPlayerItemStatus)status { return self.forceUnknown ? AVPlayerItemStatusUnknown : super.status; }
- (BOOL)canPlayFastForward { return NO; }
- (BOOL)canPlaySlowForward { return NO; }
- (void)finishLoading {
    [self willChangeValueForKey:@"status"]; self.forceUnknown=NO; [self didChangeValueForKey:@"status"];
}
@end
static BOOL Wait(BOOL (^done)(void),double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
static moonbit_string_t CoreString(NSString *text) {
    moonbit_string_t string=moonbit_make_string_raw((int32_t)text.length);
    [text getCharacters:string range:NSMakeRange(0,text.length)]; return string;
}
static NSDictionary *Decode(moonbit_string_t value) {
    NSString *text=[[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value);
    NSDictionary *result=[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![result[@"ok"] boolValue]) NSLog(@"Core rejected media fixture: %@",text);
    assert([result[@"ok"] boolValue]); return result;
}
static NSDictionary *Command(int32_t session,NSDictionary *command) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:command options:0 error:NULL];
    moonbit_string_t input=CoreString([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    NSDictionary *result=Decode(video_command(session,input)); moonbit_decref(input); return result;
}
static NSArray<AVAssetTrack *> *Tracks(AVAsset *asset,AVMediaType type) {
    NSMutableArray *result=[NSMutableArray array];
    for(AVAssetTrack *track in asset.tracks)if([track.mediaType isEqual:type])[result addObject:track]; return result;
}
static void MakeSource(NSURL *directory) {
    NSError *error=nil;
    NSURL *raw=[directory URLByAppendingPathComponent:@"raw.mp4"];
    AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:raw fileType:AVFileTypeMPEG4 error:&error]; assert(writer);
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@320,AVVideoHeightKey:@240}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(NSString *)kCVPixelBufferWidthKey:@320,(NSString *)kCVPixelBufferHeightKey:@240}];
    [writer addInput:input]; assert([writer startWriting]); [writer startSessionAtSourceTime:kCMTimeZero];
    for(int frame=0;frame<120;frame++) {
        assert(Wait(^BOOL{return input.readyForMoreMediaData || writer.status==AVAssetWriterStatusFailed;},10));
        assert(writer.status!=AVAssetWriterStatusFailed); CVPixelBufferRef pixel=NULL;
        assert(CVPixelBufferPoolCreatePixelBuffer(NULL,adaptor.pixelBufferPool,&pixel)==kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel,0); uint8_t *bytes=CVPixelBufferGetBaseAddress(pixel); size_t stride=CVPixelBufferGetBytesPerRow(pixel);
        for(int y=0;y<240;y++)for(int x=0;x<320;x++) {
            uint8_t *p=bytes+y*stride+x*4; p[0]=(uint8_t)y;p[1]=(uint8_t)x;p[2]=(uint8_t)(frame*2);p[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(pixel,0); assert([adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame,30)]); CVPixelBufferRelease(pixel);
    }
    [input markAsFinished]; [writer endSessionAtSourceTime:CMTimeMake(4,1)]; __block BOOL written=NO;
    [writer finishWritingWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{written=YES;});}]; assert(Wait(^BOOL{return written;},30)); assert(writer.status==AVAssetWriterStatusCompleted);
    NSURL *tone=[directory URLByAppendingPathComponent:@"tone.caf"];
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:192000]; buffer.frameLength=192000;
    for(AVAudioFrameCount i=0;i<buffer.frameLength;i++)buffer.floatChannelData[0][i]=(float)(0.04*sin(2*M_PI*440*i/48000));
    AVAudioFile *audioFile=[[AVAudioFile alloc] initForWriting:tone settings:format.settings error:&error];
    assert(audioFile && [audioFile writeFromBuffer:buffer error:&error]); audioFile=nil;
    AVMutableComposition *source=[AVMutableComposition composition];
    AVURLAsset *video=[AVURLAsset URLAssetWithURL:raw options:nil],*audio=[AVURLAsset URLAssetWithURL:tone options:nil];
    AVMutableCompositionTrack *v=[source addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *a=[source addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTimeRange range=CMTimeRangeMake(kCMTimeZero,CMTimeMake(4,1));
    assert([v insertTimeRange:range ofTrack:Tracks(video,AVMediaTypeVideo).firstObject atTime:kCMTimeZero error:&error]);
    assert([a insertTimeRange:range ofTrack:Tracks(audio,AVMediaTypeAudio).firstObject atTime:kCMTimeZero error:&error]);
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:source presetName:AVAssetExportPresetHighestQuality];
    exporter.outputURL=[directory URLByAppendingPathComponent:@"source.mp4"]; exporter.outputFileType=AVFileTypeMPEG4;
    __block BOOL done=NO; [exporter exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{done=YES;});}];
    assert(Wait(^BOOL{return done;},30)); assert(exporter.status==AVAssetExportSessionStatusCompleted);
}
static void CheckExport(NSURL *url,BOOL audio) {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track=Tracks(asset,AVMediaTypeVideo).firstObject;
    assert(track && fabs(CMTimeGetSeconds(asset.duration)-2)<0.12 && track.naturalSize.width==160 && track.naturalSize.height==100);
    assert((Tracks(asset,AVMediaTypeAudio).count>0)==audio);
    NSError *error=nil; AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *frames=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    assert(reader && [reader canAddOutput:frames]);[reader addOutput:frames];assert([reader startReading]);
    CMSampleBufferRef sample=[frames copyNextSampleBuffer]; assert(sample);
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample); assert(pixels); CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
    uint8_t *center=(uint8_t *)CVPixelBufferGetBaseAddress(pixels)+50*CVPixelBufferGetBytesPerRow(pixels)+80*4;
    assert(abs(center[0]-80)<18 && abs(center[1]-100)<18 && abs(center[2]-30)<18);
    CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly); CFRelease(sample);[reader cancelReading];
}
static void SeekAndWait(MCVideoMedia *media,double position) {
    __block BOOL done=NO;
    [media seekOutputMilliseconds:position completion:^(BOOL finished){assert(finished);done=YES;}];
    assert(Wait(^BOOL{return done;},15));
}
static double MeasureRate(MCVideoMedia *media,double rate) {
    [media pause]; SeekAndWait(media,0); NSError *error=nil;
    assert([media setPreviewRate:rate error:&error] && !error && media.previewRate==rate);
    assert(media.player.rate==0 && !media.previewPlaybackError);
    double paused=media.currentOutputMilliseconds, start=NSProcessInfo.processInfo.systemUptime;
    assert(Wait(^BOOL{return NSProcessInfo.processInfo.systemUptime-start>=0.1;},1));
    assert(fabs(media.currentOutputMilliseconds-paused)<1 && media.player.rate==0);
    [media play];
    assert(Wait(^BOOL{return media.player.timeControlStatus==AVPlayerTimeControlStatusPlaying && media.currentOutputMilliseconds>30;},10));
    double time=media.currentOutputMilliseconds; start=NSProcessInfo.processInfo.systemUptime;
    assert(Wait(^BOOL{return NSProcessInfo.processInfo.systemUptime-start>=0.24;},1));
    double measured=(media.currentOutputMilliseconds-time)/(1000*(NSProcessInfo.processInfo.systemUptime-start));
    [media pause]; assert(fabs(measured-rate)<0.12+rate*0.12);
    assert(fabs(media.previewRate-rate)<0.001 && !media.previewPlaybackError);
    return measured;
}
static void CheckRateCapabilities(NSURL *source) {
    NSError *error=nil; MCVideoMedia *media=[[MCVideoMedia alloc] initWithURL:source error:&error];
    media.player.muted=YES;
    assert(Wait(^BOOL{return media.player.currentItem.status==AVPlayerItemStatusReadyToPlay;},15));
    assert([media setPreviewRate:3 error:&error]);
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:source options:nil];
    MCRateLimitedItem *limited=[MCRateLimitedItem playerItemWithAsset:asset]; limited.forceUnknown=YES;
    [media replacePreviewItem:limited];
    error=nil; assert(![media setPreviewRate:1 error:&error] && error && media.previewRate==3);
    __block NSUInteger playReplies=0;
    [media playWithCompletion:^(NSError *failure){assert(failure.code==NSUserCancelledError);playReplies++;}];
    assert(playReplies==0 && media.player.rate==0 && media.playbackRequested);
    [media pause]; assert(playReplies==1 && !media.playbackRequested); [limited finishLoading];
    assert(Wait(^BOOL{return limited.status==AVPlayerItemStatusReadyToPlay;},15));
    assert(media.player.rate==0 && !media.playbackRequested && media.previewRate==3 && !media.previewPlaybackError);
    // 1–2x does not depend on canPlayFastForward. 0.5x and 3x do.
    error=nil; assert(![media setPreviewRate:0.5 error:&error] && error && media.previewRate==3);
    [media play]; assert(media.player.rate==0 && media.previewPlaybackError && media.previewRate==3);
    error=nil; assert([media setPreviewRate:2 error:&error] && !media.previewPlaybackError);
    error=nil; assert(![media setPreviewRate:3 error:&error] && error && media.previewRate==2 && media.player.rate==0);
    assert([media setPreviewRate:1 error:NULL]); [media play];
    assert(Wait(^BOOL{return media.currentOutputMilliseconds>50;},5)); [media pause];
    [media close];

    // An asynchronously completed load reports the preserved unsupported rate,
    // and a later successful selection/play clears that error.
    media=[[MCVideoMedia alloc] initWithURL:source error:NULL]; media.player.muted=YES;
    assert(Wait(^BOOL{return media.player.currentItem.status==AVPlayerItemStatusReadyToPlay;},15));
    assert([media setPreviewRate:3 error:NULL]);
    limited=[MCRateLimitedItem playerItemWithAsset:asset]; limited.forceUnknown=YES;
    [media replacePreviewItem:limited]; playReplies=0;
    [media playWithCompletion:^(NSError *failure){assert(failure && failure.code!=NSUserCancelledError);playReplies++;}];
    assert(playReplies==0); [limited finishLoading];
    assert(Wait(^BOOL{return playReplies==1 && media.previewPlaybackError!=nil;},15));
    assert(media.player.rate==0 && !media.playbackRequested && media.previewRate==3);
    assert([media setPreviewRate:1 error:NULL] && !media.previewPlaybackError);
    [media play]; assert(Wait(^BOOL{return media.currentOutputMilliseconds>50;},5)); [media close];
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        assert(argc==2);moonbit_init(); NSError *error=nil;
        NSURL *directory=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        assert(![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"source.mp4"].path]);
        assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]);
        MakeSource(directory); NSURL *source=[directory URLByAppendingPathComponent:@"source.mp4"];
        NSData *originalSource=[NSData dataWithContentsOfURL:source];
        MCVideoMedia *media=[[MCVideoMedia alloc] initWithURL:source error:&error]; assert(media && !error);
        assert([media.metadata[@"durationMs"] intValue]==4000 && [media.metadata[@"width"] intValue]==320 && [media.metadata[@"height"] intValue]==240 && [media.metadata[@"hasAudio"] boolValue]);
        media.player.muted=YES; // Exercise playback without playing the test tone aloud.
        NSData *json=[NSJSONSerialization dataWithJSONObject:media.metadata options:0 error:&error];
        moonbit_string_t metadata=CoreString([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]),empty=CoreString(@"");
        NSDictionary *state=Decode(video_open(metadata,empty));moonbit_decref(metadata);moonbit_decref(empty);
        int32_t session=[state[@"session"] intValue];
        Command(session,@{@"type":@"trim",@"trim":@{@"startMs":@500,@"endMs":@3500}});
        Command(session,@{@"type":@"cut",@"cut":@{@"startMs":@1000,@"endMs":@1500}});
        Command(session,@{@"type":@"cut",@"cut":@{@"startMs":@2000,@"endMs":@2500}});
        state=Command(session,@{@"type":@"crop",@"crop":@{@"x":@20,@"y":@30,@"width":@160,@"height":@100}});
        NSDictionary *plan=state[@"plan"];assert([media applyPlan:plan error:&error]);assert(media.outputDurationMilliseconds==2000);
        assert(Wait(^BOOL{return media.player.currentItem.status!=AVPlayerItemStatusUnknown;},15));assert(media.player.currentItem.status==AVPlayerItemStatusReadyToPlay);
        __block NSUInteger oldSeeks=0,newSeeks=0;
        [media seekOutputMilliseconds:100 completion:^(__unused BOOL finished){oldSeeks++;}];
        [media seekOutputMilliseconds:700 completion:^(__unused BOOL finished){oldSeeks++;}];
        [media seekOutputMilliseconds:1200 completion:^(BOOL finished){assert(finished);newSeeks++;}];
        assert(Wait(^BOOL{return newSeeks==1;},15));assert(oldSeeks==0 && fabs(media.currentOutputMilliseconds-1200)<40);
        NSMutableDictionary *rateMeasurements=[NSMutableDictionary dictionary];
        for (NSNumber *rate in @[@0.5,@1,@1.5,@2,@3])
            rateMeasurements[rate.stringValue]=@(MeasureRate(media,rate.doubleValue));
        assert([media.player.currentItem.audioTimePitchAlgorithm isEqual:AVAudioTimePitchAlgorithmTimeDomain]);
        for (NSNumber *invalidRate in @[@0,@(-1),@0.75,@4,@(NAN),@(INFINITY),@(-INFINITY)]) {
            error=nil; AVPlayerItem *item=media.player.currentItem; double time=media.currentOutputMilliseconds;
            assert(![media setPreviewRate:invalidRate.doubleValue error:&error] && error);
            assert(media.previewRate==3 && media.player.rate==0 && item==media.player.currentItem && fabs(media.currentOutputMilliseconds-time)<1);
        }
        CheckRateCapabilities(source);
        SeekAndWait(media,1200); // pause/play and seeks keep the selected 3x.
        [media play];assert(Wait(^BOOL{return media.currentOutputMilliseconds>1300;},5));[media pause];
        assert(media.previewRate==3);
        double stopped=media.currentOutputMilliseconds;
        __block BOOL sourcePreview=NO;
        [media previewSourceMilliseconds:3800 completion:^(BOOL finished){assert(finished);sourcePreview=YES;}];
        assert(Wait(^BOOL{return sourcePreview;},15));assert(media.previewingSource && fabs(CMTimeGetSeconds(media.player.currentTime)*1000-3800)<40);
        assert(media.previewRate==3 && media.player.rate==0);
        assert(fabs(media.currentOutputMilliseconds-stopped)<1);[media restorePlanPreview];
        assert(!media.previewingSource && Wait(^BOOL{return fabs(media.currentOutputMilliseconds-stopped)<40;},15));
        assert(media.previewRate==3 && media.player.rate==0);
        AVPlayerItem *previous=media.player.currentItem;NSMutableDictionary *invalid=[plan mutableCopy];invalid[@"outputDurationMs"]=@999;
        error=nil;assert(![media applyPlan:invalid error:&error] && error && previous==media.player.currentItem);
        [media seekOutputMilliseconds:100 completion:^(__unused BOOL finished){oldSeeks++;}];
        error=nil;assert([media applyPlan:plan error:&error]);
        assert(media.previewRate==3 && media.player.rate==0);
        [media play]; // Readiness is asynchronous; queued play uses 3x.
        assert(Wait(^BOOL{return media.player.timeControlStatus==AVPlayerTimeControlStatusPlaying && media.currentOutputMilliseconds>60;},15));
        assert(media.player.rate==3 && !media.previewPlaybackError); [media pause];
        // A rate change while already playing applies immediately without 1x.
        SeekAndWait(media,0); [media play];
        assert(Wait(^BOOL{return media.currentOutputMilliseconds>60;},5));
        assert([media setPreviewRate:1.5 error:NULL] && media.player.rate==1.5); [media pause];
        assert([media setPreviewRate:3 error:NULL]);
        NSURL *audible=[directory URLByAppendingPathComponent:@"cropped-audio.mp4"];
        assert([[@"previous destination" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:audible options:0 error:&error]);
        __block BOOL exported=NO;__block NSUInteger exportCalls=0;
        [media exportToURL:audible completion:^(NSURL *url,NSError *failure){assert(url && !failure);exportCalls++;exported=YES;}];
        assert(media.exporting && ![media applyPlan:plan error:NULL]);
        assert(Wait(^BOOL{return exported;},30) && exportCalls==1 && oldSeeks==0);CheckExport(audible,YES);
        // Fast-start MP4 retains its header and readable first frame when its
        // media tail is removed. Boundary validation must still reject it.
        NSData *complete=[NSData dataWithContentsOfURL:audible];
        NSURL *truncated=[directory URLByAppendingPathComponent:@"truncated-tail.mp4"];
        assert([[complete subdataWithRange:NSMakeRange(0,complete.length*3/4)] writeToURL:truncated options:0 error:&error]);
        CheckExport(truncated,YES);error=nil;
        assert(![media validateExport:truncated error:&error] && [error.localizedDescription containsString:@"尾部"]);
        [media previewSourceMilliseconds:3800 completion:^(__unused BOOL finished){oldSeeks++;}];
        state=Command(session,@{@"type":@"mute",@"muted":@YES});assert([media applyPlan:state[@"plan"] error:&error]);assert(!media.previewingSource);
        NSURL *muted=[directory URLByAppendingPathComponent:@"cropped-muted.mp4"];exported=NO;
        [media exportToURL:muted completion:^(NSURL *url,NSError *failure){assert(url && !failure);exported=YES;}];
        assert(Wait(^BOOL{return exported;},30));CheckExport(muted,NO);assert(oldSeeks==0);
        __block BOOL protected=NO;[media exportToURL:source completion:^(NSURL *url,NSError *failure){assert(!url && failure);protected=YES;}];assert(protected);
        NSURL *alias=[directory URLByAppendingPathComponent:@"source-hardlink.mp4"];
        assert([NSFileManager.defaultManager linkItemAtURL:source toURL:alias error:&error]);
        protected=NO;[media exportToURL:alias completion:^(NSURL *url,NSError *failure){assert(!url && failure);protected=YES;}];
        assert(protected && [[NSData dataWithContentsOfURL:alias] isEqual:originalSource]);
        NSData *existing=[@"keep the existing destination" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *cancelled=[directory URLByAppendingPathComponent:@"cancelled.mp4"];assert([existing writeToURL:cancelled options:0 error:&error]);
        __block BOOL cancellation=NO;[media exportToURL:cancelled completion:^(NSURL *url,NSError *failure){assert(!url && failure.code==NSUserCancelledError);cancellation=YES;}];
        [media cancelExport];assert(Wait(^BOOL{return cancellation;},30));assert([[NSData dataWithContentsOfURL:cancelled] isEqual:existing]);
        __block NSUInteger closedCallbacks=0;
        [media seekOutputMilliseconds:500 completion:^(__unused BOOL finished){closedCallbacks++;}];
        [media exportToURL:cancelled completion:^(__unused NSURL *url,__unused NSError *failure){closedCallbacks++;}];
        __block NSUInteger terminalSeeks=0,drains=0;
        [media seekOutputMilliseconds:600 terminal:^(BOOL finished){assert(!finished);terminalSeeks++;}];
        [media closeWithCompletion:^{assert(terminalSeeks==1 && closedCallbacks==1);drains++;}];
        [media close];assert(!media.player.currentItem && ![media applyPlan:plan error:NULL]);
        error=nil; assert(![media setPreviewRate:1 error:&error] && error && media.previewRate==3);
        assert(Wait(^BOOL{return drains==1;},30));assert(closedCallbacks==1 && [[NSData dataWithContentsOfURL:cancelled] isEqual:existing]);
        assert([[NSData dataWithContentsOfURL:source] isEqual:originalSource]);
        NSURL *bad=[directory URLByAppendingPathComponent:@"invalid.mp4"];assert([existing writeToURL:bad options:0 error:&error]);
        assert(![[MCVideoMedia alloc] initWithURL:bad error:NULL]);
        for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:&error])assert(![file hasPrefix:@".MoojiCut-media-"]);
        video_dispose(session);
        NSDictionary *report=@{@"passed":@YES,@"source":source.path,@"sourceDurationMs":@4000,@"outputDurationMs":@2000,@"outputWidth":@160,@"outputHeight":@100,@"audioAndMutedReadback":@YES,@"truncatedTailRejected":@YES,@"seekGeneration":@YES,@"sourcePreviewRestore":@YES,@"atomicExportCancellation":@YES,@"legacySeekCallbacksSuppressed":@YES,@"terminalCallbacksDrained":@YES,@"sourceUnchanged":@YES,@"previewRateMeasurements":rateMeasurements,@"previewRatePreserved":@YES,@"pausedRateDoesNotPlay":@YES,@"rateCapabilityRefusal":@YES,@"exportDurationIgnoresPreviewRate":@YES};
        assert([[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error] writeToURL:[directory URLByAppendingPathComponent:@"report.json"] atomically:YES]);
        puts("PASS: real media rates/preview/seek/source preview/plan replacement; cropped audio/muted MP4 readback, atomic cancellation, source protection and close");
    }
}
