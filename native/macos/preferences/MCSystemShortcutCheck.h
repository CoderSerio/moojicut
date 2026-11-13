#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Main thread only. Checks enabled system symbolic shortcuts, without
// registering or monitoring keys. nil means no confirmed conflict; the API
// cannot enumerate other applications' menu shortcuts or global registrations.
FOUNDATION_EXPORT NSString * _Nullable MCSystemShortcutConflict(unsigned short keyCode, NSEventModifierFlags modifiers);

NS_ASSUME_NONNULL_END
