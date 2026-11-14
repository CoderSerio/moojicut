#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCMacRecordingController : NSObject
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL captureInProgress;
@property (nonatomic, readonly) BOOL exporting;
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
- (void)startRecording;
- (void)stopRecording;
- (void)resumeLastDraft;
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
