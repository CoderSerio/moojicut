#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
#define MCPinFeatureEnabledDefaultsKey @"feature.pin.enabled"
// Pinned images are independent of capture/editor lifetime and keep only the
// user's finalized PNG. No source document or unredacted source is retained.
@interface MCPinnedImageController : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL disabling;
@property (nonatomic, readonly) NSUInteger count;
- (BOOL)pinPNGData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
- (BOOL)pinPNGData:(NSData *)data screenFrame:(NSRect)frame error:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, readonly, nullable) NSString *shortcutRegistrationError;
@property (nonatomic, copy, nullable) void (^onShortcutStatus)(NSString * _Nullable error);
- (void)toggleVisibility;
- (void)toggleClickThrough;
- (void)restoreHiddenPins;
- (void)disableClickThrough;
- (void)setShortcutsSuspended:(BOOL)suspended;
- (void)closeAll;
// Capture suspends pin interaction, not visibility. User-hidden pins stay hidden.
// Newly confirmed pins wait until capture ends before showing or taking key.
- (void)setCaptureActive:(BOOL)active;
@property (nonatomic, readonly) NSSet<NSNumber *> *visibleWindowNumbers;
@end
NS_ASSUME_NONNULL_END
