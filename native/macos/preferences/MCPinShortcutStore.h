#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCPinShortcutsDidChangeNotification;

// Local to the focused pinned-image window. Never registers global hotkeys.
@interface MCPinShortcutStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (nullable NSDictionary *)shortcutForAction:(NSString *)action;
- (BOOL)setShortcut:(nullable NSDictionary *)shortcut forAction:(NSString *)action error:(NSString * _Nullable * _Nullable)error;
- (void)restoreDefaults;
- (nullable NSString *)actionForEvent:(NSEvent *)event;
- (nullable NSString *)actionForKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers;
+ (nullable NSDictionary *)shortcutWithKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers;
+ (NSString *)displayStringForShortcut:(nullable NSDictionary *)shortcut;
@end
NS_ASSUME_NONNULL_END
