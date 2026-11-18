#import <AppKit/AppKit.h>
#import "MCReleaseSource.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MCUpdateStateDidChangeNotification;

// All methods and the busy provider run on the main thread.
@interface MCUpdateController : NSObject <NSMenuItemValidation>
@property (nonatomic, copy, nullable) BOOL (^isOperationBusy)(void);
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) BOOL canCheckForUpdates;
@property (nonatomic, readonly) BOOL installationPending;
@property (nonatomic, readonly) BOOL checkingSource;
@property (nonatomic, readonly, nullable) NSURL *uninstallTargetURL;
@property (nonatomic, readonly) BOOL canUninstall;
@property (nonatomic, readonly, nullable) NSURL *releasePageURL;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic) BOOL automaticallyChecksForUpdates;
- (instancetype)init;
// Allows offline configuration checks; only the main application bundle can start updates.
- (instancetype)initWithBundle:(NSBundle *)bundle;
- (instancetype)initWithBundle:(NSBundle *)bundle releaseSource:(id<MCReleaseSource>)source;
+ (nullable NSString *)configurationErrorForBundle:(NSBundle *)bundle;
- (void)start;
- (void)checkForUpdates:(nullable id)sender;
- (void)cancelCheck;
- (void)openReleasePage:(nullable id)sender;
// Accepts the target shown in the user's confirmation. The host quits after success.
- (BOOL)moveInstallationToTrash:(NSURL *)confirmedURL error:(NSError **)error;
- (void)operationStateDidChange;
@end

NS_ASSUME_NONNULL_END
