#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCToolRegistryDidChangeNotification;

// Main-thread owner of the persisted layout and its validated MoonBit snapshot.
@interface MCToolRegistryStore : NSObject
@property (nonatomic, copy, readonly) NSDictionary *snapshot;
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *pluginManifests;
@property (nonatomic, strong, readonly, nullable) NSError *loadError;
// Preflight all live editors before changing any tool configuration. Returning
// NO leaves the snapshot, preferences, and toolbar configuration unchanged.
@property (nonatomic, copy, nullable) BOOL (^prepareChange)(NSDictionary *candidate, NSError * _Nullable * _Nullable error);
// Synchronous, non-failing publication after preflight. Do not start another
// store transaction from this callback or its change notification.
@property (nonatomic, copy, nullable) void (^applyChange)(NSDictionary *candidate);
@property (nonatomic, copy, nullable) void (^discardChange)(void);
// A managed v2 application is the sole durable owner. Once attached, commands
// never fall back to the legacy defaults/catalog path, including startup errors.
@property (nonatomic, copy, nullable) BOOL (^managedCommand)(NSDictionary *command, NSError * _Nullable * _Nullable error);
- (BOOL)prepareManagedSnapshot:(NSDictionary *)candidate error:(NSError * _Nullable * _Nullable)error;
- (void)publishManagedSnapshot:(NSDictionary *)candidate;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
// Resolve a complete validated installed catalog before its atomic disk commit.
// A nil commit publishes read-only startup state without rewriting preferences.
- (BOOL)replacePluginManifests:(NSArray<NSDictionary *> *)manifests
                       commit:(nullable BOOL (^)(NSError * _Nullable * _Nullable error))commit
                        error:(NSError * _Nullable * _Nullable)error;
// The callback runs after editor preflight and before any snapshot publication.
// Startup may publish the manager's validated in-memory records here while
// keeping persistLayout=NO, so callbacks see matching metadata without a write.
- (BOOL)replacePluginManifests:(NSArray<NSDictionary *> *)manifests
                       commit:(nullable BOOL (^)(NSError * _Nullable * _Nullable error))commit
                persistLayout:(BOOL)persistLayout
                        error:(NSError * _Nullable * _Nullable)error;
- (NSArray<NSDictionary *> *)toolsForGroup:(NSString *)group;
- (BOOL)setTool:(NSString *)identifier enabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;
- (BOOL)moveTool:(NSString *)identifier inGroup:(NSString *)group beforeTool:(nullable NSString *)before error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
