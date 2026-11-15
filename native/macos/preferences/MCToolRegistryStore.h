#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MCToolRegistryDidChangeNotification;

// Main-thread owner of the persisted layout and its validated MoonBit snapshot.
@interface MCToolRegistryStore : NSObject
@property (nonatomic, copy, readonly) NSDictionary *snapshot;
@property (nonatomic, strong, readonly, nullable) NSError *loadError;
// Preflight all live editors before changing any tool configuration. Returning
// NO leaves the snapshot, preferences, and toolbar configuration unchanged.
@property (nonatomic, copy, nullable) BOOL (^prepareChange)(NSDictionary *candidate, NSError * _Nullable * _Nullable error);
// Synchronous, non-failing publication after preflight. Do not start another
// store transaction from this callback or its change notification.
@property (nonatomic, copy, nullable) void (^applyChange)(NSDictionary *candidate);
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSArray<NSDictionary *> *)toolsForGroup:(NSString *)group;
- (BOOL)setTool:(NSString *)identifier enabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;
- (BOOL)moveTool:(NSString *)identifier inGroup:(NSString *)group beforeTool:(nullable NSString *)before error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
