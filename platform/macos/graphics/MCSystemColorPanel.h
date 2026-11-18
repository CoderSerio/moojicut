#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Process-wide routing for the system's single color panel. The owner is weak;
// use the callback's owner parameter rather than capturing the owner strongly.
// Main-thread only. No method orders a window or changes its window level.
@interface MCSystemColorPanelLease : NSObject
@property (nonatomic, readonly, getter=isActive) BOOL active;
+ (instancetype)beginWithOwner:(id)owner color:(NSColor *)color showsAlpha:(BOOL)showsAlpha
                      onColor:(void (^)(id owner, NSColor *color))handler;
// Silent updates only affect the current lease. They never emit onColor.
- (void)updateColor:(NSColor *)color;
// Stale leases cannot disconnect a newer owner. Safe to call more than once.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
