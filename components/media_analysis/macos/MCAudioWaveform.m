#import "MCAudioWaveform.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

static NSError *MCWaveformError(void) {
    return [NSError errorWithDomain:@"MoojiCut.AudioWaveform" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"无法生成音频波形，仍可正常剪辑。"}];
}
@interface MCAudioWaveform ()
@property (atomic) BOOL cancelled;
@property BOOL finished;
@property NSMutableArray *drainCompletions;
@end

@implementation MCAudioWaveform
+ (instancetype)readURL:(NSURL *)url durationMilliseconds:(double)duration
    completion:(void (^)(NSArray<NSNumber *> *, NSError *))completion {
    MCAudioWaveform *task = [self new]; task.drainCompletions=[NSMutableArray array];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSError *error=nil;
        NSArray *peaks=nil;
        @autoreleasepool { peaks=[task readURL:url duration:duration error:&error]; }
        // No AVAssetReader/asset/autoreleased PCM remains when the UI sees drain.
        CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopCommonModes,^{
            task.finished=YES;
            if (!task.cancelled) completion(peaks,error);
            NSArray *callbacks=[task.drainCompletions copy]; [task.drainCompletions removeAllObjects];
            for (void (^drained)(void) in callbacks) drained();
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
    return task;
}
- (void)cancel { self.cancelled = YES; }
- (void)cancelWithCompletion:(void (^)(void))completion {
    self.cancelled=YES;
    if (self.finished) completion(); else [self.drainCompletions addObject:[completion copy]];
}
- (NSArray<NSNumber *> *)readURL:(NSURL *)url duration:(double)duration error:(NSError **)error {
    if (!url.isFileURL || !isfinite(duration) || duration < 1 || duration > 604800000) {
        *error = MCWaveformError(); return nil;
    }
    if (self.cancelled) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if (!asset.readable) { *error = MCWaveformError(); return nil; }
    NSMutableArray<AVAssetTrack *> *tracks = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) if ([track.mediaType isEqual:AVMediaTypeAudio]) [tracks addObject:track];
    if (!tracks.count) return @[];
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    // Stereo float PCM avoids cancelling opposite-phase channels in a mono
    // downmix. The waveform is an envelope of the same source audio mix.
    AVAssetReaderAudioMixOutput *output = [[AVAssetReaderAudioMixOutput alloc] initWithAudioTracks:tracks
        audioSettings:@{AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMIsFloatKey:@YES,
            AVLinearPCMBitDepthKey:@32, AVLinearPCMIsBigEndianKey:@NO,
            AVLinearPCMIsNonInterleaved:@NO, AVSampleRateKey:@48000, AVNumberOfChannelsKey:@2}];
    if (!reader || ![reader canAddOutput:output]) { *error = *error ?: MCWaveformError(); return nil; }
    reader.timeRange = CMTimeRangeMake(kCMTimeZero,CMTimeMakeWithSeconds(duration/1000,48000));
    [reader addOutput:output];
    if (![reader startReading]) { *error = reader.error ?: MCWaveformError(); return nil; }
    NSUInteger count = (NSUInteger)MIN(16384,MAX(1,ceil(duration/10.0)));
    NSMutableData *storage = [NSMutableData dataWithLength:count*sizeof(float)];
    float *peaks = storage.mutableBytes;
    BOOL valid = YES;
    while (!self.cancelled) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
            CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(sample);
            double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            CMItemCount frames = CMSampleBufferGetNumSamples(sample);
            size_t bytes = buffer ? CMBlockBufferGetDataLength(buffer) : 0;
            valid = format && isfinite(time) && isfinite(format->mSampleRate) && format->mSampleRate > 0 &&
                format->mFormatID == kAudioFormatLinearPCM && (format->mFormatFlags & kAudioFormatFlagIsFloat) &&
                !(format->mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) &&
                format->mBitsPerChannel == 32 && format->mChannelsPerFrame > 0 && format->mChannelsPerFrame <= 32 &&
                format->mBytesPerFrame == format->mChannelsPerFrame*sizeof(float) && frames > 0 &&
                bytes <= 8*1024*1024 && (uint64_t)frames*format->mBytesPerFrame == bytes;
            if (valid) {
                NSMutableData *pcm = [NSMutableData dataWithLength:bytes];
                valid = CMBlockBufferCopyDataBytes(buffer,0,bytes,pcm.mutableBytes) == kCMBlockBufferNoErr;
                const float *values = pcm.bytes;
                if (valid) for (CMItemCount frame = 0; frame < frames; frame++) {
                    double position = (time+(double)frame/format->mSampleRate)*1000/duration;
                    if (position < 0 || position >= 1) continue;
                    NSUInteger bin = MIN(count-1,(NSUInteger)floor(position*count));
                    for (UInt32 channel = 0; channel < format->mChannelsPerFrame; channel++) {
                        float amplitude = fabsf(values[frame*format->mChannelsPerFrame+channel]);
                        if (isfinite(amplitude)) peaks[bin] = MAX(peaks[bin],MIN(1,amplitude));
                    }
                }
            }
            CFRelease(sample);
        }
        if (!valid) break;
    }
    if (self.cancelled || !valid || reader.status != AVAssetReaderStatusCompleted) {
        if (!self.cancelled) *error = reader.error ?: MCWaveformError();
        [reader cancelReading]; return nil;
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) [result addObject:@(peaks[index])];
    return [result copy];
}
@end
