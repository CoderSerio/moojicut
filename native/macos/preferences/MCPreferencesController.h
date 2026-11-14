#import <AppKit/AppKit.h>
#import "MCShortcutStore.h"

NS_ASSUME_NONNULL_BEGIN
@class MCUpdateController;
@interface MCPreferencesController : NSObject <NSWindowDelegate, NSToolbarDelegate>
@property (nonatomic, readonly, nullable) NSWindow *window;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onShortcutRecordingChanged)(BOOL recording);
@property (nonatomic, copy, nullable) NSString *shortcutRegistrationError;
@property (nonatomic, readonly) NSString *appearanceChoice;
@property (nonatomic, readonly) BOOL technicalDetailsVisible;
@property (nonatomic, readonly) MCShortcutStore *shortcutStore;
@property (nonatomic, strong, nullable) MCUpdateController *updateController;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults coreVersion:(NSString *)coreVersion diagnostics:(NSDictionary *)diagnostics;
- (void)show;
- (void)selectPage:(NSString *)identifier;
- (void)setAppearanceChoice:(NSString *)choice;
- (void)toggleTechnicalDetails:(nullable id)sender;
+ (void)applySavedAppearance:(NSUserDefaults *)defaults;
@end
NS_ASSUME_NONNULL_END
