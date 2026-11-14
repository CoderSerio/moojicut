#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCCaptureController : NSObject
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
@property (nonatomic, copy, nullable) BOOL (^onPinPNGData)(NSData *data);
- (void)capture;
- (void)cancelCapture;
- (BOOL)showEditorForPNGURL:(NSURL *)url error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
