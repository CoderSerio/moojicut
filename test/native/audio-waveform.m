#import <AVFoundation/AVFoundation.h>
#import "components/media_analysis/macos/MCAudioWaveform.h"
#include <assert.h>
#include <math.h>

static BOOL Wait(BOOL (^done)(void), double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return done();
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc == 2);
        NSURL *directory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSError *error = nil;
        assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]);
        NSURL *url = [directory URLByAppendingPathComponent:@"envelope.caf"];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        NSMutableDictionary *settings = [format.settings mutableCopy]; settings[AVLinearPCMIsNonInterleaved] = @NO;
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error]; assert(file);
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:192000];
        buffer.frameLength = 192000;
        for (NSUInteger i=0;i<buffer.frameLength;i++) {
            float amplitude = i>=48000 && i<96000 ? .8 : i>=96000 && i<144000 ? .1 : 0;
            float value = amplitude*sinf((float)(2*M_PI*440*i/48000));
            buffer.floatChannelData[0][i] = value; buffer.floatChannelData[1][i] = -value;
        }
        assert([file writeFromBuffer:buffer error:&error]); file = nil;
        __block BOOL done=NO; __block NSArray<NSNumber *> *result=nil; __block NSError *failure=nil;
        MCAudioWaveform *task = [MCAudioWaveform readURL:url durationMilliseconds:4000 completion:^(NSArray *peaks,NSError *problem){
            assert(NSThread.isMainThread); result=peaks;failure=problem;done=YES;
        }];
        assert(task && Wait(^BOOL{return done;},15) && result.count==400 && !failure);
        for(NSUInteger i=10;i<90;i++)assert(result[i].floatValue<.0001);
        for(NSUInteger i=110;i<190;i++)assert(result[i].floatValue>.79 && result[i].floatValue<=.81);
        for(NSUInteger i=210;i<290;i++)assert(result[i].floatValue>.09 && result[i].floatValue<.11);
        for(NSUInteger i=310;i<390;i++)assert(result[i].floatValue<.0001);
        done=NO;
        [MCAudioWaveform readURL:url durationMilliseconds:2000 completion:^(NSArray *peaks,NSError *problem){result=peaks;failure=problem;done=YES;}];
        assert(Wait(^BOOL{return done;},15) && result.count==200 && !failure);
        assert(result[50].floatValue<.0001 && result[150].floatValue>.79);
        __block BOOL cancelledCalled=NO;
        MCAudioWaveform *cancelled=[MCAudioWaveform readURL:url durationMilliseconds:4000 completion:^(__unused NSArray *p,__unused NSError *e){cancelledCalled=YES;}];
        [cancelled cancel];
        done=NO;
        [MCAudioWaveform readURL:[directory URLByAppendingPathComponent:@"missing.caf"] durationMilliseconds:4000 completion:^(NSArray *peaks,NSError *problem){
            assert(!peaks && problem);done=YES;
        }];
        assert(Wait(^BOOL{return done;},15) && !cancelledCalled);
        puts("PASS: real stereo PCM waveform preserves silence, quiet/loud regions and opposite-phase channels; cancellation and errors are isolated");
    }
    return 0;
}
