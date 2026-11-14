#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCPinShortcutsDidChangeNotification;

// Zoom/opacity act locally. Visibility and click-through use recoverable global
// combinations while pins exist; registration belongs to the pin controller.
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
