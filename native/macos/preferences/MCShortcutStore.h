#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Posted after a successful save/reset; object is the shared NSUserDefaults.
FOUNDATION_EXPORT NSNotificationName const MCShortcutsDidChangeNotification;
// macOS key codes and modifier flags belong to this platform adapter. Consumers
// can resolve capture/record/stop without depending on preference view objects.
@interface MCShortcutStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (nullable NSDictionary *)shortcutForAction:(NSString *)action;
- (BOOL)setShortcut:(nullable NSDictionary *)shortcut forAction:(NSString *)action error:(NSString * _Nullable * _Nullable)error;
- (void)restoreDefaults;
- (BOOL)restoreDefaultsWithError:(NSString * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)shortcutWithKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers;
+ (NSString *)displayStringForShortcut:(nullable NSDictionary *)shortcut;
@end
NS_ASSUME_NONNULL_END
