#import <AppKit/AppKit.h>
@class MCToolRegistryStore;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCUserPluginsDidChangeNotification;

// AppKit projection of the shared v2 application/worker driver. The manager
// owns native presentation only; installation, grants and result acceptance
// belong to MoonBit and the shared driver.
@interface MCUserPluginManager : NSObject
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
@property (nonatomic, copy, readonly) NSString *statusMessage;
@property (nonatomic, copy, readonly) NSArray<NSString *> *installedPluginIDs;
@property (nonatomic, copy, nullable) NSWindow * _Nullable (^windowForCapture)(int32_t capture);
@property (nonatomic, copy, nullable) void (^documentChanged)(int32_t capture);
- (instancetype)initWithRegistry:(MCToolRegistryStore *)registry rootURL:(NSURL *)rootURL workerURL:(NSURL *)workerURL;
- (void)loadInstalledPluginsWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)importZIPAtURL:(NSURL *)url completion:(void (^)(NSError * _Nullable error))completion;
- (void)uninstallPlugin:(NSString *)pluginID completion:(void (^)(NSError * _Nullable error))completion;
- (nullable NSString *)nameForPlugin:(NSString *)pluginID;
- (nullable NSImage *)iconForPlugin:(NSString *)pluginID;
- (BOOL)invokeTool:(NSString *)toolID payload:(NSString *)payload capture:(int32_t)capture;
- (void)closeCapture:(int32_t)capture;
- (void)shutdownWithCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
