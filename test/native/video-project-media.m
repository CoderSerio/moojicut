#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "plugins/feature/video_editor/macos/MCVideoMedia.h"
#include <assert.h>
#include <math.h>

@interface MCVideoMedia (ExportValidationFixture)
- (BOOL)validateExport:(NSURL *)url error:(NSError **)error;
@end

static BOOL Wait(BOOL (^done)(void),double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
static NSArray<AVAssetTrack *> *Tracks(AVAsset *asset,AVMediaType type) {
    NSMutableArray *result=[NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:type]) [result addObject:track];
    return result;
}
static const uint8_t Colors[6][3]={{230,30,30},{30,230,30},{30,30,230},{230,230,30},{230,30,230},{30,230,230}};
static NSURL *MakeSource(NSURL *directory) {
    NSError *error=nil; NSURL *raw=[directory URLByAppendingPathComponent:@"raw.mp4"];
    AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:raw fileType:AVFileTypeMPEG4 error:&error]; assert(writer && !error);
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@160,AVVideoHeightKey:@90}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(NSString *)kCVPixelBufferWidthKey:@160,(NSString *)kCVPixelBufferHeightKey:@90}];
    [writer addInput:input]; assert([writer startWriting]); [writer startSessionAtSourceTime:kCMTimeZero];
    for(int frame=0;frame<180;frame++) {
        assert(Wait(^BOOL{return input.readyForMoreMediaData || writer.status==AVAssetWriterStatusFailed;},10)); assert(writer.status!=AVAssetWriterStatusFailed);
        CVPixelBufferRef pixel=NULL; assert(CVPixelBufferPoolCreatePixelBuffer(NULL,adaptor.pixelBufferPool,&pixel)==kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel,0); uint8_t *bytes=CVPixelBufferGetBaseAddress(pixel); size_t stride=CVPixelBufferGetBytesPerRow(pixel);
        const uint8_t *color=Colors[frame/30];
        for(int y=0;y<90;y++)for(int x=0;x<160;x++) {
            uint8_t *p=bytes+y*stride+x*4; p[0]=color[2];p[1]=color[1];p[2]=color[0];p[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(pixel,0); assert([adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame,30)]); CVPixelBufferRelease(pixel);
    }
    [input markAsFinished]; [writer endSessionAtSourceTime:CMTimeMake(6,1)]; __block BOOL written=NO;
    [writer finishWritingWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{written=YES;});}]; assert(Wait(^BOOL{return written;},30)); assert(writer.status==AVAssetWriterStatusCompleted);
    NSURL *tone=[directory URLByAppendingPathComponent:@"tone.caf"];
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:288000]; buffer.frameLength=288000;
    for(AVAudioFrameCount i=0;i<buffer.frameLength;i++)buffer.floatChannelData[0][i]=(float)(0.04*sin(2*M_PI*440*i/48000));
    AVAudioFile *audioFile=[[AVAudioFile alloc] initForWriting:tone settings:format.settings error:&error]; assert(audioFile && [audioFile writeFromBuffer:buffer error:&error]); audioFile=nil;
    AVMutableComposition *source=[AVMutableComposition composition];
    AVURLAsset *video=[AVURLAsset URLAssetWithURL:raw options:nil],*audio=[AVURLAsset URLAssetWithURL:tone options:nil];
    CMTimeRange range=CMTimeRangeMake(kCMTimeZero,CMTimeMake(6,1));
    assert([[source addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid] insertTimeRange:range ofTrack:Tracks(video,AVMediaTypeVideo).firstObject atTime:kCMTimeZero error:&error]);
    assert([[source addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid] insertTimeRange:range ofTrack:Tracks(audio,AVMediaTypeAudio).firstObject atTime:kCMTimeZero error:&error]);
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:source presetName:AVAssetExportPresetHighestQuality];
    NSURL *url=[directory URLByAppendingPathComponent:@"source.mp4"]; exporter.outputURL=url; exporter.outputFileType=AVFileTypeMPEG4;
    __block BOOL done=NO; [exporter exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{done=YES;});}];
    assert(Wait(^BOOL{return done;},30) && exporter.status==AVAssetExportSessionStatusCompleted); return url;
}
static NSURL *MakeShortAudioSource(NSURL *directory,NSURL *sourceURL) {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:sourceURL options:nil]; NSError *error=nil;
    AVMutableComposition *composition=[AVMutableComposition composition];
    assert([[composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid]
        insertTimeRange:CMTimeRangeMake(kCMTimeZero,CMTimeMake(6,1)) ofTrack:Tracks(asset,AVMediaTypeVideo).firstObject atTime:kCMTimeZero error:&error]);
    assert([[composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]
        insertTimeRange:CMTimeRangeMake(kCMTimeZero,CMTimeMake(3,1)) ofTrack:Tracks(asset,AVMediaTypeAudio).firstObject atTime:CMTimeMake(3,2) error:&error]);
    NSURL *url=[directory URLByAppendingPathComponent:@"short-offset-audio-source.mp4"];
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    exporter.outputURL=url; exporter.outputFileType=AVFileTypeMPEG4;
    __block BOOL done=NO; [exporter exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{done=YES;});}];
    assert(Wait(^BOOL{return done;},30) && exporter.status==AVAssetExportSessionStatusCompleted); return url;
}
static NSDictionary *Clip(NSString *identifier,NSString *kind,int64_t sourceStart,int64_t sourceEnd,int64_t start,int64_t duration) {
    return @{@"id":identifier,@"kind":kind,@"sourceStartTicks":@(sourceStart),@"sourceEndTicks":@(sourceEnd),@"startTicks":@(start),@"durationTicks":@(duration),@"linkGroup":NSNull.null};
}
static NSMutableDictionary *Plan(MCVideoMedia *media,NSArray *video,NSArray *audio,int64_t duration) {
    return [@{@"schemaVersion":@2,@"timebase":@90000,@"frameRate":@{@"num":@30,@"den":@1},@"source":media.metadata,@"outputDurationTicks":@(duration),@"video":video,@"audio":audio,@"crop":NSNull.null,@"muted":@NO} mutableCopy];
}
static void Apply(MCVideoMedia *media,NSDictionary *plan) {
    NSError *error=nil; BOOL success=[media applyPlan:plan error:&error]; if(!success)NSLog(@"apply: %@",error); assert(success);
    assert(Wait(^BOOL{return media.player.currentItem.status!=AVPlayerItemStatusUnknown;},15));
    if(media.player.currentItem.status!=AVPlayerItemStatusReadyToPlay)NSLog(@"ready: %@",media.player.currentItem.error);
    assert(media.player.currentItem.status==AVPlayerItemStatusReadyToPlay);
}
static void Export(MCVideoMedia *media,NSURL *url,double duration) {
    __block BOOL done=NO;
    [media exportToURL:url completion:^(NSURL *result,NSError *error){if(error)NSLog(@"export %@: %@",url.lastPathComponent,error);assert(result && !error);done=YES;}];
    assert(Wait(^BOOL{return done;},45));
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    if(fabs(CMTimeGetSeconds(asset.duration)-duration)>=0.06)NSLog(@"duration %@ actual=%g expected=%g",url.lastPathComponent,CMTimeGetSeconds(asset.duration),duration);
    assert(fabs(CMTimeGetSeconds(asset.duration)-duration)<0.06);
    NSError *error=nil; AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *frames=[[AVAssetReaderTrackOutput alloc] initWithTrack:Tracks(asset,AVMediaTypeVideo).firstObject
        outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    assert(reader && [reader canAddOutput:frames]); [reader addOutput:frames]; assert([reader startReading]);
    NSUInteger count=0; CMSampleBufferRef sample=NULL;
    while ((sample=[frames copyNextSampleBuffer])) { count+=CMSampleBufferGetNumSamples(sample); CFRelease(sample); }
    assert(reader.status==AVAssetReaderStatusCompleted && count==(NSUInteger)llround(duration*30));
}
static void ColorAt(AVAsset *asset,AVVideoComposition *composition,double seconds,int index) {
    AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform=YES; generator.videoComposition=composition;
    generator.requestedTimeToleranceBefore=kCMTimeZero; generator.requestedTimeToleranceAfter=kCMTimeZero;
    __block NSError *error=nil; __block CGImageRef image=NULL; __block BOOL done=NO;
    [generator generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(seconds,90000) completionHandler:^(CGImageRef result,__unused CMTime actual,NSError *failure) {
        CGImageRef retained=result ? CGImageRetain(result) : NULL;
        dispatch_async(dispatch_get_main_queue(),^{ image=retained; error=failure; done=YES; });
    }];
    assert(Wait(^BOOL{return done;},15));
    if(!image)NSLog(@"frame %g: %@",seconds,error); assert(image);
    uint8_t rgba[4]={0}; CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(rgba,1,1,8,4,colorSpace,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextDrawImage(context,CGRectMake(0,0,1,1),image); CGContextRelease(context); CGColorSpaceRelease(colorSpace); CGImageRelease(image);
    for(int i=0;i<3;i++) {
        // ImageGenerator/ColorSync may convert transfer functions. Distinct
        // primary/secondary colors identify time order without conflating that
        // conversion with a frame-selection failure.
        BOOL correct=index<0 ? rgba[i]<20 : Colors[index][i]>128 ? rgba[i]>180 : rgba[i]<120;
        if(!correct)NSLog(@"frame %g component %d actual %d palette %d",seconds,i,rgba[i],index);
        assert(correct);
    }
}
static NSData *ReadAudio(NSURL *url,double duration) {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil]; NSError *error=nil;
    NSMutableData *samples=[NSMutableData dataWithLength:(NSUInteger)ceil(duration*48000)*sizeof(float)];
    AVAssetTrack *track=Tracks(asset,AVMediaTypeAudio).firstObject; if(!track)return samples;
    AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@48000,AVNumberOfChannelsKey:@1,AVLinearPCMBitDepthKey:@32,AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsNonInterleaved:@NO}];
    assert(reader && [reader canAddOutput:output]); [reader addOutput:output]; assert([reader startReading]);
    CMSampleBufferRef sample=NULL;
    while ((sample=[output copyNextSampleBuffer])) {
        int64_t position=llround(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))*48000);
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample); size_t bytes=CMBlockBufferGetDataLength(block);
        if(position>=0 && (size_t)position*sizeof(float)<samples.length) {
            size_t length=MIN(bytes,samples.length-(size_t)position*sizeof(float));
            assert(CMBlockBufferCopyDataBytes(block,0,length,(uint8_t *)samples.mutableBytes+(size_t)position*sizeof(float))==kCMBlockBufferNoErr);
        }
        CFRelease(sample);
    }
    assert(reader.status==AVAssetReaderStatusCompleted); return samples;
}
static double RMS(NSData *data,double start,double end) {
    const float *samples=data.bytes; size_t first=(size_t)(start*48000),last=(size_t)(end*48000); assert(last*sizeof(float)<=data.length);
    double sum=0; for(size_t i=first;i<last;i++)sum+=samples[i]*samples[i]; return sqrt(sum/(last-first));
}
static double Frequency(NSData *data,double start,double end) {
    const float *samples=data.bytes; size_t first=(size_t)(start*48000),last=(size_t)(end*48000); int crossings=0;
    for(size_t i=first+1;i<last;i++)if(samples[i-1]<=0 && samples[i]>0)crossings++;
    return crossings/(end-start);
}
static void Seek(MCVideoMedia *media,double ms) {
    __block BOOL done=NO; [media seekOutputMilliseconds:ms completion:^(BOOL finished){assert(finished);done=YES;}];
    assert(Wait(^BOOL{return done;},15)); assert(fabs(media.currentOutputMilliseconds-ms)<1);
}
static NSURL *ShortenTail(NSURL *source,NSURL *directory) {
    NSURL *url=[directory URLByAppendingPathComponent:@"readable-short-video-tail.mp4"];
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:[AVURLAsset URLAssetWithURL:source options:nil]
        presetName:AVAssetExportPresetHighestQuality];
    exporter.outputURL=url; exporter.outputFileType=AVFileTypeMPEG4;
    exporter.timeRange=CMTimeRangeMake(kCMTimeZero,CMTimeMake(9,10));
    __block BOOL done=NO; [exporter exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{done=YES;});}];
    assert(Wait(^BOOL{return done;},30) && exporter.status==AVAssetExportSessionStatusCompleted);
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
    assert(fabs(CMTimeGetSeconds(asset.duration)-0.9)<0.001); return url;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        assert(argc==2); NSError *error=nil;
        NSURL *directory=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        assert(![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"source.mp4"].path]);
        assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]);
        NSURL *source=MakeSource(directory); NSData *original=[NSData dataWithContentsOfURL:source];
        MCVideoMedia *media=[[MCVideoMedia alloc] initWithURL:source error:&error]; assert(media && !error); media.player.muted=YES;
        NSMutableDictionary *fast=Plan(media,@[Clip(@"v1",@"video",0,540000,0,180000)],@[Clip(@"a1",@"audio",0,540000,0,180000)],180000);
        Apply(media,fast); assert(media.outputDurationMilliseconds==2000);
        assert(media.player.currentItem.audioMix.inputParameters.count==1);
        assert([media.player.currentItem.audioMix.inputParameters[0].audioTimePitchAlgorithm isEqual:AVAudioTimePitchAlgorithmTimeDomain]);
        ColorAt(media.player.currentItem.asset,media.player.currentItem.videoComposition,0.5,1);
        ColorAt(media.player.currentItem.asset,media.player.currentItem.videoComposition,1.8,5);
        assert([media setPreviewRate:2 error:&error]); Seek(media,500);
        [media play]; assert(Wait(^BOOL{return media.currentOutputMilliseconds>650;},5)); [media pause];
        NSURL *fastURL=[directory URLByAppendingPathComponent:@"three-times.mp4"]; Export(media,fastURL,2);
        AVURLAsset *fastAsset=[AVURLAsset URLAssetWithURL:fastURL options:nil];
        ColorAt(fastAsset,nil,0.15,0); ColorAt(fastAsset,nil,0.5,1); ColorAt(fastAsset,nil,1.15,3); ColorAt(fastAsset,nil,1.8,5);
        NSData *fastAudio=ReadAudio(fastURL,2); double frequency=Frequency(fastAudio,0.3,1.7);
        assert(frequency>425 && frequency<455 && RMS(fastAudio,0.3,1.7)>0.015 && RMS(fastAudio,1.92,1.97)>0.02);
        Apply(media,Plan(media,@[Clip(@"v-one",@"video",0,90000,0,90000),Clip(@"v-three",@"video",180000,360000,90000,60000)],
            @[Clip(@"a-one",@"audio",0,90000,0,90000),Clip(@"a-three",@"audio",180000,360000,90000,60000)],150000));
        Export(media,[directory URLByAppendingPathComponent:@"split-move-speed-delete.mp4"],5.0/3);

        // Exercise the supported rate endpoints with actual exported frames.
        Apply(media,Plan(media,@[Clip(@"slow-v",@"video",0,180000,0,720000)],@[],720000));
        NSURL *slowURL=[directory URLByAppendingPathComponent:@"quarter-speed.mp4"]; Export(media,slowURL,8);
        AVURLAsset *slowAsset=[AVURLAsset URLAssetWithURL:slowURL options:nil];
        ColorAt(slowAsset,nil,2,0); ColorAt(slowAsset,nil,6,1); ColorAt(slowAsset,nil,239.0/30,1);
        assert(Tracks(slowAsset,AVMediaTypeAudio).count==0);
        Apply(media,Plan(media,@[Clip(@"half-v",@"video",0,180000,0,360000)],@[],360000));
        NSURL *halfURL=[directory URLByAppendingPathComponent:@"half-speed-video-only.mp4"]; Export(media,halfURL,4);
        ColorAt([AVURLAsset URLAssetWithURL:halfURL options:nil],nil,119.0/30,1);
        Apply(media,Plan(media,@[Clip(@"four-v",@"video",0,360000,0,90000)],@[Clip(@"four-a",@"audio",0,360000,0,90000)],90000));
        NSURL *fourURL=[directory URLByAppendingPathComponent:@"four-times.mp4"]; Export(media,fourURL,1);
        AVURLAsset *fourAsset=[AVURLAsset URLAssetWithURL:fourURL options:nil];
        ColorAt(fourAsset,nil,0.4,1); ColorAt(fourAsset,nil,0.8,3);
        NSData *fourAudio=ReadAudio(fourURL,1); double fourFrequency=Frequency(fourAudio,0.2,0.8);
        assert(fourFrequency>425 && fourFrequency<455 && RMS(fourAudio,0.92,0.97)>0.02);
        NSMutableDictionary *audioTailMeasurements=[NSMutableDictionary dictionary];
        for (NSNumber *rate in @[@1,@1.5,@2]) {
            int64_t duration=llround(180000/rate.doubleValue); double seconds=duration/90000.0;
            Apply(media,Plan(media,@[Clip(@"v",@"video",0,180000,0,duration)],@[Clip(@"a",@"audio",0,180000,0,duration)],duration));
            NSURL *url=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"audio-rate-%@.mp4",rate]]; Export(media,url,seconds);
            NSData *samples=ReadAudio(url,seconds); double rms=RMS(samples,seconds-0.08,seconds-0.03);
            double audioEnd=CMTimeGetSeconds(CMTimeRangeGetEnd(Tracks([AVURLAsset URLAssetWithURL:url options:nil],AVMediaTypeAudio).firstObject.timeRange));
            assert(rms>0.02 && seconds-audioEnd<0.02); audioTailMeasurements[rate.stringValue]=@{@"rms":@(rms),@"endSeconds":@(audioEnd)};
        }

        // Source audio may itself begin late and finish before the video. Its
        // intersection must be mapped proportionally, including both gaps.
        NSURL *shortSource=MakeShortAudioSource(directory,source);
        AVURLAsset *shortAsset=[AVURLAsset URLAssetWithURL:shortSource options:nil];
        assert(CMTimeGetSeconds(CMTimeRangeGetEnd(Tracks(shortAsset,AVMediaTypeAudio).firstObject.timeRange))<5);
        MCVideoMedia *shortMedia=[[MCVideoMedia alloc] initWithURL:shortSource error:NULL]; assert(shortMedia); shortMedia.player.muted=YES;
        Apply(shortMedia,Plan(shortMedia,@[Clip(@"v",@"video",0,540000,0,180000)],@[Clip(@"a",@"audio",0,540000,0,180000)],180000));
        NSURL *shortURL=[directory URLByAppendingPathComponent:@"short-offset-audio-three-times.mp4"]; Export(shortMedia,shortURL,2);
        NSData *shortAudio=ReadAudio(shortURL,2);
        assert(RMS(shortAudio,0.1,0.3)<0.001 && RMS(shortAudio,0.7,1.2)>0.02 && RMS(shortAudio,1.7,1.9)<0.001); [shortMedia close];

        // Reordering includes a repeated source interval, an internal black gap,
        // and a tail whose duration is driven solely by independent audio.
        NSArray *video=@[Clip(@"v-late",@"video",360000,540000,0,180000),Clip(@"v-early",@"video",0,180000,225000,180000),Clip(@"v-repeat",@"video",360000,450000,405000,90000)];
        NSArray *audio=@[Clip(@"a-offset",@"audio",0,90000,45000,90000),Clip(@"a-tail",@"audio",180000,270000,540000,90000)];
        NSMutableDictionary *reordered=Plan(media,video,audio,630000); Apply(media,reordered); assert(media.previewRate==2 && media.outputDurationMilliseconds==7000);
        assert(media.player.currentItem.audioMix.inputParameters.count==2);
        Seek(media,2250); ColorAt(media.player.currentItem.asset,media.player.currentItem.videoComposition,2.25,-1);
        Seek(media,6500); ColorAt(media.player.currentItem.asset,media.player.currentItem.videoComposition,6.5,-1);
        NSURL *reorderedURL=[directory URLByAppendingPathComponent:@"reordered-independent-audio.mp4"]; Export(media,reorderedURL,7);
        AVURLAsset *reorderedAsset=[AVURLAsset URLAssetWithURL:reorderedURL options:nil];
        ColorAt(reorderedAsset,nil,0.4,4); ColorAt(reorderedAsset,nil,1.4,5); ColorAt(reorderedAsset,nil,2.25,-1);
        ColorAt(reorderedAsset,nil,2.9,0); ColorAt(reorderedAsset,nil,3.9,1); ColorAt(reorderedAsset,nil,4.9,4); ColorAt(reorderedAsset,nil,6.5,-1);
        NSData *reorderedAudio=ReadAudio(reorderedURL,7); double singleRMS=RMS(reorderedAudio,0.7,1.2);
        assert(RMS(reorderedAudio,0.1,0.3)<0.001 && RMS(reorderedAudio,1.8,2.2)<0.001);
        assert(singleRMS>0.02 && singleRMS<0.035 && RMS(reorderedAudio,6.2,6.7)>0.02);

        // Leading black and muted audio-tail duration are not discarded.
        NSMutableDictionary *leading=Plan(media,@[Clip(@"v",@"video",0,90000,90000,90000)],@[],270000); leading[@"muted"]=@YES;
        Apply(media,leading); NSURL *leadingURL=[directory URLByAppendingPathComponent:@"leading-muted-tail.mp4"]; Export(media,leadingURL,3);
        AVURLAsset *leadingAsset=[AVURLAsset URLAssetWithURL:leadingURL options:nil];
        ColorAt(leadingAsset,nil,0.5,-1); ColorAt(leadingAsset,nil,1.5,0); ColorAt(leadingAsset,nil,2.5,-1); assert(Tracks(leadingAsset,AVMediaTypeAudio).count==0);

        // Split-derived source positions retain sub-frame precision (4500 ticks).
        NSMutableDictionary *fractional=Plan(media,@[Clip(@"fractional",@"video",4500,139500,0,90000)],@[],90000);
        Apply(media,fractional); NSURL *fractionalURL=[directory URLByAppendingPathComponent:@"fractional-source.mp4"]; Export(media,fractionalURL,1);
        ColorAt([AVURLAsset URLAssetWithURL:fractionalURL options:nil],nil,0.8,1);
        // A complete, decodable file shortened by 100ms passed the legacy
        // container tolerance. v2 must reject it using the video track's end.
        NSURL *shortTail=ShortenTail(fractionalURL,directory); error=nil;
        assert(![media validateExport:shortTail error:&error] && [error.localizedDescription containsString:@"视频末尾"]);
        NSDictionary *legacy=@{@"schemaVersion":@1,@"muted":@YES,@"crop":NSNull.null,@"outputDurationMs":@1000,
            @"segments":@[@{@"sourceStartMs":@0,@"sourceEndMs":@1000,@"outputStartMs":@0,@"outputEndMs":@1000}]};
        Apply(media,legacy); error=nil; assert([media validateExport:shortTail error:&error] && !error);
        Apply(media,fractional); error=nil;
        assert(![media validateExport:shortTail error:&error] && [error.localizedDescription containsString:@"视频末尾"]);
        AVPlayerItem *kept=media.player.currentItem;
        for (NSDictionary *bad in @[
            Clip(@"bad",@"video",0,90000,1,90000),Clip(@"bad",@"video",0,90000,0,15000),
            Clip(@"bad",@"video",0,900000,0,90000),Clip(@"bad",@"video",0,3001,0,90000)]) {
            error=nil; assert(![media applyPlan:Plan(media,@[bad],@[],90000) error:&error] && error && kept==media.player.currentItem);
        }
        error=nil; assert(![media applyPlan:Plan(media,@[Clip(@"a",@"video",0,90000,0,90000),Clip(@"b",@"video",90000,180000,45000,90000)],@[],135000) error:&error] && error && kept==media.player.currentItem);
        NSMutableDictionary *unknown=[fractional mutableCopy];unknown[@"schemaVersion"]=@3; assert(![media applyPlan:unknown error:NULL]);
        for (NSNumber *duration in @[@360000,@720000]) {
            error=nil;
            assert(![media applyPlan:Plan(media,@[Clip(@"v",@"video",0,180000,0,duration.longLongValue)],
                @[Clip(@"a",@"audio",0,180000,0,duration.longLongValue)],duration.longLongValue) error:&error]);
            assert([error.localizedDescription containsString:@"慢放音频"] && kept==media.player.currentItem);
        }

        // Existing destination and source remain untouched when export cancels.
        NSURL *cancelled=[directory URLByAppendingPathComponent:@"cancelled.mp4"]; NSData *sentinel=[@"keep destination" dataUsingEncoding:NSUTF8StringEncoding];
        assert([sentinel writeToURL:cancelled atomically:YES]); __block BOOL done=NO;
        [media exportToURL:cancelled completion:^(NSURL *url,NSError *failure){assert(!url && failure.code==NSUserCancelledError);done=YES;}];
        [media cancelExport]; assert(Wait(^BOOL{return done;},30)); assert([[NSData dataWithContentsOfURL:cancelled] isEqual:sentinel]);
        __block BOOL protected=NO; [media exportToURL:source completion:^(NSURL *url,NSError *failure){assert(!url && failure);protected=YES;}]; assert(protected);
        [media close]; assert([[NSData dataWithContentsOfURL:source] isEqual:original]);
        NSDictionary *report=@{@"passed":@YES,@"source":source.path,@"sourceDurationMs":@6000,@"threeTimesOutputMs":@2000,@"pitchHzAfterThreeTimes":@(frequency),@"videoOnlySlowMotion":@YES,@"slowAudioRejectedAtomically":@YES,@"audioTailMeasurements":audioTailMeasurements,@"fourTimesPitchHz":@(fourFrequency),@"sourceAudioOffsetScaled":@YES,@"independentAudioRMS":@(singleRMS),@"reorderedRepeatedFrames":@YES,@"blackGapsAndAudioTail":@YES,@"fractionalSourceTicks":@YES,@"previewRateIndependent":@YES,@"atomicInvalidPlan":@YES,@"cancelPreservesDestination":@YES,@"sourceUnchanged":@YES,@"readableShortVideoTailRejected":@YES,@"legacyValidationRestored":@YES};
        assert([[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error] writeToURL:[directory URLByAppendingPathComponent:@"report.json"] atomically:YES]);
        puts("PASS: v2 real 3x export/pitch, reorder/repeat, independent audio/gaps/tail, fractional source, validation, cancellation and source protection");
    }
    return 0;
}
