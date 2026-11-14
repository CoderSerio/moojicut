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
// Temporarily remove our own pins from a capture without discarding them.
// Existing pins restore without taking key. A newly confirmed pin may take key
// when capture finishes, using a nonactivating panel (never app activation).
- (void)setCaptureHidden:(BOOL)hidden;
@end
NS_ASSUME_NONNULL_END
