#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Pure geometry, shared by the HUD and its regression fixture. NSZeroRect means
// no placement outside the selection fits any of the supplied visible frames.
FOUNDATION_EXPORT NSRect MCScrollControlFrame(NSRect selection, NSArray<NSValue *> *visibleFrames, NSSize size);
typedef void (^MCScrollFrameCompletion)(NSData * _Nullable PNGData, NSError * _Nullable error);
typedef void (^MCScrollFrameProvider)(MCScrollFrameCompletion completion);
// Own on the main thread. The controller does not synthesize scroll events or
// request Accessibility permission. The caller restores the source application's
// focus and removes frozen capture overlays before calling start.
@interface MCScrollCaptureController : NSObject
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL paused;
@property (nonatomic, readonly) NSUInteger capturedHeight;
@property (nonatomic, copy, readonly) NSString *status;
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
@property (nonatomic, copy, nullable) void (^onCompletion)(NSData * _Nullable PNGData, NSError * _Nullable error);
// Production capture: AppKit global coordinates, wholly inside one display.
// Include visible pinned windows from this process; all other host windows,
// including the HUD, are excluded from the captured pixels.
- (instancetype)initWithScreenRect:(NSRect)rect
            includedWindowNumbers:(nullable NSSet<NSNumber *> *(^)(void))windowNumbers;
// Fixture/alternate source seam. No screen access is performed by this variant.
- (instancetype)initWithFrameProvider:(MCScrollFrameProvider)provider;
- (void)start;
- (void)finish;
- (void)cancel;
- (void)retry;
@end
NS_ASSUME_NONNULL_END
