#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const MCPluginPackageErrorDomain;
typedef NS_ENUM(NSInteger, MCPluginPackageErrorCode) {
    MCPluginPackageInvalid = 1,
    MCPluginPackageStorage = 2,
    MCPluginPackageStale = 3,
    MCPluginPackageNotStaged = 4,
    MCPluginPackageBusy = 5,
};

// Immutable, bounded payload. Preparing a candidate does not write to the store.
// The host must validate manifestData and probe wasmData before committing it.
@interface MCPluginPackageCandidate : NSObject
@property (nonatomic, copy, readonly) NSString *digest;
@property (nonatomic, copy, readonly) NSData *manifestData;
@property (nonatomic, copy, readonly) NSData *wasmData;
@property (nonatomic, copy, readonly, nullable) NSData *iconData;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// Synchronous I/O: prepare/stage/load belong on the host's background queue.
// Commit/uninstall do bounded catalog I/O and never wait for another transaction;
// the host may use them at its final, synchronous publication point.
// The injected root contains only packages/<sha256>/ and an atomic catalog.json.
// No plugin code runs here. A successful commit is the catalog rename; readers
// see either complete catalog. Unreferenced blobs are deliberately retained:
// an existing worker may still be using them. Garbage collection is deferred.
@interface MCPluginPackageStore : NSObject
- (instancetype)initWithRootURL:(NSURL *)rootURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable MCPluginPackageCandidate *)prepareZIPAtURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
// Returns pluginId -> SHA-256, or nil on corrupt/unreadable saved data.
- (nullable NSDictionary<NSString *, NSString *> *)catalogWithError:(NSError * _Nullable * _Nullable)error;
- (nullable MCPluginPackageCandidate *)packageForPluginID:(NSString *)pluginID error:(NSError * _Nullable * _Nullable)error;
// After validation/probe, write and fsync the immutable payload on a background
// queue. Staged-but-uncommitted packages are invisible to restart discovery.
- (BOOL)stageCandidate:(MCPluginPackageCandidate *)candidate error:(NSError * _Nullable * _Nullable)error;
// validatedManifest must describe this exact candidate. expectedDigest is a CAS
// guard: nil requires no prior installation; a string requires that exact version.
// Requires stageCandidate on this store first (otherwise error code 4). Only the
// small catalog is written here; payload I/O has already finished in staging.
- (BOOL)commitCandidate:(MCPluginPackageCandidate *)candidate
      validatedManifest:(NSDictionary *)manifest
          expectedDigest:(nullable NSString *)expectedDigest
                   error:(NSError * _Nullable * _Nullable)error;
- (BOOL)uninstallPluginID:(NSString *)pluginID
          expectedDigest:(nullable NSString *)expectedDigest
                   error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
