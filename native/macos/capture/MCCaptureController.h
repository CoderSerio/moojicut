#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCCaptureController : NSObject
@property (nonatomic, readonly) BOOL busy;
- (void)capture;
- (BOOL)showEditorForPNGURL:(NSURL *)url error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
