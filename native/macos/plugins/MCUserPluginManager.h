#import <AppKit/AppKit.h>
@class MCToolRegistryStore, MCPluginPackageStore;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCUserPluginsDidChangeNotification;
@interface MCUserPluginManager : NSObject
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
@property (nonatomic, copy, readonly) NSString *statusMessage;
@property (nonatomic, copy, readonly) NSArray<NSString *> *installedPluginIDs;
- (instancetype)initWithRegistry:(MCToolRegistryStore *)registry packages:(MCPluginPackageStore *)packages workerURL:(NSURL *)workerURL;
- (void)loadInstalledPluginsWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)importZIPAtURL:(NSURL *)url completion:(void (^)(NSError * _Nullable error))completion;
- (void)uninstallPlugin:(NSString *)pluginID completion:(void (^)(NSError * _Nullable error))completion;
- (nullable NSString *)nameForPlugin:(NSString *)pluginID;
- (nullable NSImage *)iconForPlugin:(NSString *)pluginID;
- (void)applyToolConfiguration:(NSDictionary *)snapshot;
- (void)invokeTool:(NSString *)toolID owner:(NSString *)owner capture:(NSDictionary *)capture
        isCurrent:(BOOL (^)(void))isCurrent
       completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)cancelInvocationsForOwner:(NSString *)owner;
// Present the exact successful invokeTool result once; copied, stale, disabled,
// or owner-cancelled results have no presentation lease and are ignored.
- (void)presentResult:(NSDictionary *)result toolID:(NSString *)toolID owner:(NSString *)owner parentWindow:(nullable NSWindow *)window;
- (void)shutdownWithCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
