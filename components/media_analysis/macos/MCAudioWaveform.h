#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Source-time peak envelope, independent of an editor, timeline or drawing API.
// At most 16,384 uniform bins, values in [0,1]; silence stays zero. Work is
// asynchronous and memory-bounded. Cancelling suppresses the main-thread callback.
@interface MCAudioWaveform : NSObject
+ (instancetype)readURL:(NSURL *)url durationMilliseconds:(double)duration
    completion:(void (^)(NSArray<NSNumber *> * _Nullable peaks, NSError * _Nullable error))completion;
- (void)cancel;
// Always delivered on main after the reader and its buffers have been released.
- (void)cancelWithCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
