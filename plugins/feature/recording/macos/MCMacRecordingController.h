#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCMacRecordingController : NSObject
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL captureInProgress;
@property (nonatomic, readonly) BOOL exporting;
@property (nonatomic, readonly) BOOL canStop;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic, readonly) NSString *statusItemTitle;
@property (nonatomic, readonly) NSString *stopActionTitle;
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
- (void)startRecording;
- (void)stopRecording;
- (void)resumeLastDraft;
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
