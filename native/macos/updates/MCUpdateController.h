#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MCUpdateStateDidChangeNotification;

// All methods and the busy provider run on the main thread.
@interface MCUpdateController : NSObject <NSMenuItemValidation>
@property (nonatomic, copy, nullable) BOOL (^isOperationBusy)(void);
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) BOOL canCheckForUpdates;
@property (nonatomic, readonly) BOOL installationPending;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic) BOOL automaticallyChecksForUpdates;
- (instancetype)init;
// Allows offline configuration checks; only the main application bundle can start updates.
- (instancetype)initWithBundle:(NSBundle *)bundle;
+ (nullable NSString *)configurationErrorForBundle:(NSBundle *)bundle;
- (void)start;
- (void)checkForUpdates:(nullable id)sender;
- (void)operationStateDidChange;
@end

NS_ASSUME_NONNULL_END
